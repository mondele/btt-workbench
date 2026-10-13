program TestCore;

{$mode objfpc}{$H+}

{ Headless tests for the core and modules. Exit code = number of failures.
  Builds throwaway fixtures under the system temp dir. }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, fpjson, jsonparser,
  WBReporter, WBModule, WBCommandLine, WBI18n, WBAllModules,
  WBSettings, TestUtil, TestTStudioImport, TestProjects, TestSettings;

const
  { Real BTT-Writer layout: tabs, non-ASCII names, empty object and array,
  a quote and a slash that must round-trip unescaped / escaped as JS does. }
  ManifestTemplate =
    '{'#10 +
    #9'"package_version": 8,'#10 +
    #9'"format": "usfm",'#10 +
    #9'"target_language": {'#10 +
    #9#9'"id": "duf",'#10 +
    #9#9'"name": "Drubéa – ʼÉ",'#10 +
    #9#9'"direction": "ltr"'#10 +
    #9'},'#10 +
    #9'"project": {'#10 +
    #9#9'"id": "phm",'#10 +
    #9#9'"name": "Philemon \"Phm\" 1/1"'#10 +
    #9'},'#10 +
    #9'"resource": {'#10 +
    #9#9'"id": "%s",'#10 +
    #9#9'"name": "%s"'#10 +
    #9'},'#10 +
    #9'"parent_draft": {},'#10 +
    #9'"translators": [],'#10 +
    #9'"finished_chunks": ['#10 +
    #9#9'"01-01"'#10 +
    #9']'#10 +
    '}';

var
  TempRoot: string;

function MakeProject(const FolderName, ResId, ResName: string): string;
begin
  Result := TempRoot + FolderName;
  ForceDirectories(Result + PathDelim + '01');
  WriteFileText(Result + PathDelim + 'manifest.json', Format(ManifestTemplate, [ResId, ResName]));
  WriteFileText(Result + PathDelim + '01' + PathDelim + '01.txt', '\c 1 \v 1 Text');
end;

procedure TestRegistry;
begin
  Section('registry');
  Check(ModuleCount >= 1, 'at least one module registered');
  Check(FindModule('ulb2reg') <> nil, 'ulb2reg is registered');
  Check(FindModule('nope') = nil, 'unknown id gives nil');
end;

procedure TestCommandLine;
var
  M: TWBModule;
  Args, Options: TStringList;
  Err: string;
begin
  Section('command line parsing');
  M := FindModule('ulb2reg');
  Args := TStringList.Create;
  Options := TStringList.Create;
  try
    Args.CommaText := 'some/path,--dry-run';
    Check(ParseModuleArgs(M, Args, Options, Err), 'positional + flag parse');
    Check(Options.Values['project'] = 'some/path', 'positional fills project');
    Check(OptionIsSet(Options, 'dry-run'), 'flag set');

    Options.Clear;
    Args.CommaText := '--project=a/b';
    Check(ParseModuleArgs(M, Args, Options, Err) and (Options.Values['project'] = 'a/b'),
      '--name=value form');

    Options.Clear;
    Args.CommaText := '--project,x,y';
    Check(not ParseModuleArgs(M, Args, Options, Err), 'surplus positional rejected');

    Options.Clear;
    Args.CommaText := '--bogus';
    Check(not ParseModuleArgs(M, Args, Options, Err) and (Pos('--bogus', Err) > 0),
      'unknown option rejected');

    Options.Clear;
    Args.CommaText := '--project';
    Check(not ParseModuleArgs(M, Args, Options, Err), 'missing value rejected');

    Options.Clear;
    Args.CommaText := '--dry-run=yes';
    Check(not ParseModuleArgs(M, Args, Options, Err), 'value on a flag rejected');
  finally
    Args.Free;
    Options.Free;
  end;
end;

procedure TestUlb2Reg;
var
  Dir, Text: string;
  R: TWBListReporter;
  Code: Integer;
  J: TJSONData;
begin
  Section('ulb2reg');

  Dir := MakeProject('duf_phm_text_ulb', 'ulb', 'Unlocked Literal Bible');
  Code := RunModule('ulb2reg', [Dir, '--dry-run'], R);
  Check((Code = 0) and not R.HasErrors, 'dry run succeeds');
  Check(DirectoryExists(Dir) and (Pos('"ulb"', ReadFileText(Dir + '/manifest.json')) > 0),
    'dry run changes nothing');
  R.Free;

  Code := RunModule('ulb2reg', [Dir + PathDelim], R);
  Check(Code = 0, 'conversion succeeds (trailing slash accepted)');
  R.Free;
  Check(not DirectoryExists(Dir), 'old _ulb folder gone');
  Check(DirectoryExists(TempRoot + 'duf_phm_text_reg'), 'new _reg folder exists');
  Check(FileExists(TempRoot + 'duf_phm_text_reg/01/01.txt'), 'chunk files carried over');
  Text := ReadFileText(TempRoot + 'duf_phm_text_reg/manifest.json');
  J := GetJSON(Text);
  try
    Check(J.FindPath('resource.id').AsString = 'reg', 'resource.id = reg');
    Check(J.FindPath('resource.name').AsString = 'Regular', 'resource.name = Regular');
    Check(J.FindPath('finished_chunks[0]').AsString = '01-01', 'other keys kept');
  finally
    J.Free;
  end;
  Check(Pos('"Drubéa – ʼÉ"', Text) > 0, 'non-ASCII kept as UTF-8, not escaped');
  Check(Text = Format(ManifestTemplate, ['reg', 'Regular']), 'BTT-Writer layout kept exactly');
  if Text <> Format(ManifestTemplate, ['reg', 'Regular']) then
    WriteLn('--- got:'#10, Text, #10'---');

  { The bug in the Python script: folder renamed though manifest is not ULB. }
  Dir := MakeProject('aaa_mat_text_ulb', 'reg', 'Regular');
  Code := RunModule('ulb2reg', [Dir], R);
  Check((Code <> 0) and R.HasErrors, 'refuses when manifest is not ULB');
  R.Free;
  Check(DirectoryExists(Dir), '... and leaves the folder alone');

  { Both _ulb and _reg exist (seen on a real machine: duf_phm_text_*). }
  Dir := MakeProject('bbb_mat_text_ulb', 'ulb', 'Unlocked Literal Bible');
  ForceDirectories(TempRoot + 'bbb_mat_text_reg');
  Code := RunModule('ulb2reg', [Dir], R);
  Check((Code <> 0) and DirectoryExists(Dir) and
    (Pos('"ulb"', ReadFileText(Dir + '/manifest.json')) > 0),
    'refuses when the _reg folder already exists');
  R.Free;

  Dir := MakeProject('ccc_mat_text_reg', 'ulb', 'Unlocked Literal Bible');
  Code := RunModule('ulb2reg', [Dir], R);
  Check(Code <> 0, 'refuses folder not ending in _ulb');
  R.Free;

  ForceDirectories(TempRoot + 'ddd_mat_text_ulb');
  Code := RunModule('ulb2reg', [TempRoot + 'ddd_mat_text_ulb'], R);
  Check(Code <> 0, 'refuses folder with no manifest');
  R.Free;

  Code := RunModule('ulb2reg', [TempRoot + 'does_not_exist_ulb'], R);
  Check(Code <> 0, 'refuses missing folder');
  R.Free;

  Code := RunModule('ulb2reg', [], R);
  Check((Code = 2) and R.HasErrors, 'missing required option reported');
  R.Free;
end;

procedure TestI18n;
var
  LocaleDir: string;
  R: TWBListReporter;
begin
  Section('i18n');
  Check(NormalizeLanguage('pt_BR.UTF-8') = 'pt-br', 'normalize pt_BR.UTF-8');
  Check(NormalizeLanguage('C') = 'en', 'C locale is English');
  Check(IsRightToLeftLanguage('fa') and IsRightToLeftLanguage('ar_EG') and not IsRightToLeftLanguage('fr'), 'RTL detection');

  LocaleDir := TempRoot + 'locale' + PathDelim;
  ForceDirectories(LocaleDir + 'xx');
  WriteFileText(LocaleDir + 'xx' + PathDelim + LocaleDomain + '.po',
    'msgid ""'#10'msgstr ""'#10'"Content-Type: text/plain; charset=UTF-8\n"'#10#10 +
    '#: modulb2reg.rsnotafolder'#10'msgid "Not a folder: %s"'#10'msgstr "Pas un dossier : %s"'#10);

  Check(LoadLanguage('xx-yy', LocaleDir) <> '', 'regional code falls back to base .po');
  Check(CurrentLanguage = 'xx-yy', 'current language set');
  RunModule('ulb2reg', [TempRoot + 'nowhere_ulb'], R);
  Check((R.Count > 0) and (Pos('Pas un dossier', R.Texts[0]) = 1), 'module message translated');
  R.Free;

  Check(LoadLanguage('en') = '', 'back to English');
  RunModule('ulb2reg', [TempRoot + 'nowhere_ulb'], R);
  Check((R.Count > 0) and (Pos('Not a folder', R.Texts[0]) = 1), 'English restored');
  R.Free;

  Check(LoadLanguage('zz', LocaleDir) = '', 'unknown language loads nothing');
end;

begin
  TempRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'btw-test-' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(TempRoot);
  SettingsFileOverride := TempRoot + 'settings.ini';   // never the user's settings
  try
    TestRegistry;
    TestCommandLine;
    TestUlb2Reg;
    TestI18n;
    TestTStudioImportModule(TempRoot);
    TestProjectsModule(TempRoot);
    TestSettingsModule(TempRoot);
  finally
    if GetEnvironmentVariable('BTW_KEEP_TEST') = '' then   // set it to inspect fixtures
      DeleteTree(TempRoot)
    else
      WriteLn('fixtures kept in ', TempRoot);
  end;
  WriteLn;
  WriteLn(Checks - Failures, '/', Checks, ' checks passed');
  ExitCode := Failures;
end.
