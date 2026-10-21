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
  WBSettings, TestUtil, TestTStudioImport, TestProjects, TestSettings, TestWacs, TestTextCheck, TestCrossCheck,
  TestSuggest, TestLibraryUpdate, TestGitRepair, TestLanguageChange;

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

type
  { Not registered: exercises checklist and password options. }
  TPickModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
    function Choices(const OptionName: string; Options: TStrings;
      Reporter: TWBReporter; out List: TWBChoiceList): Boolean; override;
  end;

function TPickModule.Id: string; begin Result := 'pick'; end;
function TPickModule.Title: string; begin Result := 'Pick'; end;
function TPickModule.Description: string; begin Result := 'Test'; end;

function TPickModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('prefix', okString, False, False, 'Prefix', ''),
    OptionDef('user', okString, False, False, 'User', ''),
    PasswordOptionDef('password', 'user', 'Password', ''),
    ChecklistOptionDef('item', True, 'Item', '')];
end;

function TPickModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Values: TStringArray;
begin
  if not ChecklistValues(Self, 'item', Options, Reporter, Values) then
    Exit(1);
  Reporter.Info(String.Join(',', Values));
  Result := 0;
end;

{ Items a1, a2, b1 filtered by --prefix. }
function TPickModule.Choices(const OptionName: string; Options: TStrings;
  Reporter: TWBReporter; out List: TWBChoiceList): Boolean;
var
  V: string;
begin
  List.Headers := ['Size'];
  List.Items := nil;
  if Options.Values['prefix'] = 'fail' then
  begin
    Reporter.Error('cannot list');
    Exit(False);
  end;
  for V in TStringArray.Create('a1', 'a2', 'b1') do
    if Copy(V, 1, Length(Options.Values['prefix'])) = Options.Values['prefix'] then
    begin
      SetLength(List.Items, Length(List.Items) + 1);
      List.Items[High(List.Items)].Value := V;
      List.Items[High(List.Items)].Columns := [IntToStr(Length(V))];
    end;
  Result := True;
end;

procedure TestChecklists;
var
  M: TPickModule;
  Args, Options: TStringList;
  Err: string;
  R: TWBListReporter;
  Values: TStringArray;
  List: TWBChoiceList;
begin
  Section('checklist and password options');
  M := TPickModule.Create;
  Args := TStringList.Create;
  Options := TStringList.Create;
  R := TWBListReporter.Create;
  try
    Check(ChecklistOption(M) = 'item', 'checklist option found');
    Check(ChecklistOption(FindModule('ulb2reg')) = '', 'modules without one have none');
    Check((OptionKindName(okChecklist) = 'checklist') and (OptionKindName(okPassword) = 'password'),
      'kind names');

    Args.CommaText := '--item,a2,--item,b1';
    Check(ParseModuleArgs(M, Args, Options, Err) and
      (String.Join(',', OptionValues(Options, 'item')) = 'a2,b1'), 'checklist values repeat');
    Check(ChecklistValues(M, 'item', Options, R, Values) and (String.Join(',', Values) = 'a2,b1'),
      'checked values used as given');

    Options.Clear;
    Args.CommaText := '--prefix,a,--all';
    Check(ParseModuleArgs(M, Args, Options, Err) and (Options.Values['item'] = AllChoices),
      '--all checks every item');
    Check(ChecklistValues(M, 'item', Options, R, Values) and (String.Join(',', Values) = 'a1,a2'),
      '--all expands through Choices with the filters');
    Check(M.ValidateOptions(Options, R), 'a required checklist is satisfied by --all');

    Options.Values['prefix'] := 'fail';
    Check(not ChecklistValues(M, 'item', Options, R, Values) and R.HasErrors,
      'a failing Choices fails the expansion');

    Check(not FindModule('ulb2reg').Choices('x', Options, R, List), 'default Choices refuses');
  finally
    R.Free;
    Options.Free;
    Args.Free;
    M.Free;
  end;
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
    TestChecklists;
    TestUlb2Reg;
    TestI18n;
    TestTStudioImportModule(TempRoot);
    TestProjectsModule(TempRoot);
    TestSettingsModule(TempRoot);
    TestWacsModules(TempRoot);
    TestTextChecks(TempRoot);
    TestCrossChecks(TempRoot);
    TestSuggestions(TempRoot);
    TestLibraryUpdates(TempRoot);
    TestGitRepairs(TempRoot);
    TestLanguageChanges(TempRoot);
  finally
    if GetEnvironmentVariable('BTW_KEEP_TEST') = '' then   // set it to inspect fixtures
      DeleteTree(TempRoot)
    else
      WriteLn('fixtures kept in ', TempRoot);
  end;
  WriteLn;
  WriteLn(Checks - Failures, '/', Checks, ' checks passed');
  ExitCode := Ord(Failures > 0);   // not the count: 256 would wrap to 0
end.
