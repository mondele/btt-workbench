unit TestLanguageChange;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Tests for WBLangTag, the language-change module, and the projects
   module's notes on one language under several names or codes. Projects of
   language aaa under a stale name, under a private-use code (aaa-x-old)
   and under a code that is not BCP 47 (aaa-MZ-chimanika, as Chimanika's
   Luke was), with tests/fixtures/langs.sqlite as the language database
   (aaa is "Lang aaa", ppp is right-to-left). *)

interface

procedure TestLanguageChanges(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fpjson,
  WBReporter, WBGit, WBJson, WBProject, WBLangTag, TestUtil;

var
  Target, LangDb: string;

function MakeProject(const Lang, Name, Direction, Book: string): string;
var
  M: TJSONObject;
begin
  Result := Target + Lang + '_' + Book + '_text_reg' + PathDelim;
  ForceDirectories(Result + '01');
  M := TJSONObject.Create(['package_version', 8,
    'target_language', TJSONObject.Create(['id', Lang, 'name', Name, 'direction', Direction]),
    'project', TJSONObject.Create(['id', Book, 'name', Book]),
    'type', TJSONObject.Create(['id', 'text', 'name', 'Text']),
    'resource', TJSONObject.Create(['id', 'reg', 'name', 'Regular'])]);
  try
    WriteBttJSONFile(Result + 'manifest.json', M);
  finally
    M.Free;
  end;
  WriteFileText(Result + '01' + PathDelim + '01.txt', '\v 1 Words.');
  RunGit(Result, ['-c', 'init.defaultBranch=master', 'init', '-q']);
  RunGit(Result, ['add', '--all']);
  RunGit(Result, ['-c', 'user.name=Translator', '-c', 'user.email=t@example.com',
    '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'start']);
end;

function Run(const ModuleId: string; const Args: array of string; out Code: Integer): string;
var
  R: TWBListReporter;
  I: Integer;
begin
  Code := RunModule(ModuleId, Args, R);
  try
    Result := '';
    for I := 0 to R.Count - 1 do
      Result := Result + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
  finally
    R.Free;
  end;
  if GetEnvironmentVariable('BTW_SHOW') <> '' then
    WriteLn(Result);
end;

function Lang(const Dir: string; out Name, Direction: string): string;
var
  M: TJSONObject;
begin
  M := ReadJSONObjectFile(Dir + 'manifest.json');
  try
    Result := StrField(M, 'target_language.id');
    Name := StrField(M, 'target_language.name');
    Direction := StrField(M, 'target_language.direction');
  finally
    M.Free;
  end;
end;

function Commits(const Dir: string): Integer;
begin
  Result := StrToIntDef(Trim(RunGit(Dir, ['rev-list', '--count', 'HEAD']).Output), -1);
end;

procedure TestTags;
const
  Good: array[0..9] of string = ('en', 'mxc', 'mxc-MZ-x-manika', 'udm-x-udmurt',
    'qaa-x-123456', 'zh-Hant-TW', 'sl-rozaj-biske', 'de-CH-1901', 'es-419',
    'x-private');
  { a variant or private-use part of nine letters, as in BTT-Writer's
    mxc-MZ-chimanika and udm-x-norudmurt }
  Bad: array[0..8] of string = ('mxc-MZ-chimanika', 'udm-x-norudmurt', '', 'e', 'en-',
    'en--us', 'en-x', 'toolonglang', 'en-a-ab-a-cd');
var
  S: string;
  OK: Boolean;
begin
  Section('language tags (BCP 47)');
  OK := True;
  for S in Good do
    if not IsWellFormedTag(S) then
    begin
      OK := False;
      WriteLn('  not accepted: ', S);
    end;
  Check(OK, 'well-formed tags are accepted');
  OK := True;
  for S in Bad do
    if IsWellFormedTag(S) then
    begin
      OK := False;
      WriteLn('  accepted: ', S);
    end;
  Check(OK, 'malformed ones are not (parts of nine letters, empty parts, ' +
    'a repeated extension)');
end;

procedure TestLanguageChanges(const TempRoot: string);
var
  Output, S, Name, Direction: string;
  Code, Before: Integer;
  Tit, Phm, Jud, Rut: string;
begin
  TestTags;
  Section('language-change module');
  Target := TempRoot + 'langchange' + PathDelim;
  LangDb := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'tests' +
    PathDelim + 'fixtures' + PathDelim + 'langs.sqlite');
  Tit := MakeProject('aaa', 'Old name', 'ltr', 'tit');
  Phm := MakeProject('aaa', 'Lang aaa', 'ltr', 'phm');
  Jud := MakeProject('aaa-x-old', 'Lang aaa', 'ltr', 'jud');
  Rut := MakeProject('aaa-MZ-chimanika', 'Lang aaa', 'ltr', 'rut');

  Output := Run('projects', ['--target-dir', Target, '--language-db', LangDb], Code);
  Check(Pos('The projects of aaa use 2 language names: "Lang aaa", "Old name"', Output) > 0,
    'projects: one code under several names');
  Check(Pos('Language aaa has projects under 3 codes: aaa, aaa-MZ-chimanika, aaa-x-old',
    Output) > 0, 'projects: one language under several codes');
  Check(Pos('Language code aaa-MZ-chimanika is not a well-formed BCP 47 tag', Output) > 0,
    'projects: a code that is not BCP 47');
  Output := Run('projects', ['--target-dir', Target, '--language-db', LangDb,
    '--language', 'aaa'], Code);
  Check(Pos('aaa-x-old_jud_text_reg', Output) > 0, 'projects --language takes a first part');

  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--project', 'aaa_tit_text_reg', '--dry-run'], Code);
  Check((Code = 0) and (Pos('aaa_tit_text_reg: would become aaa, "Lang aaa", ltr.', Output) > 0),
    'without a code: the name from the language database');
  Check((Lang(Tit, Name, Direction) = 'aaa') and (Name = 'Old name'), 'a check changes nothing');

  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--language', 'aaa', '--code', 'aaa_x', '--all'], Code);
  Check((Code = 1) and (Pos('cannot contain "_"', Output) > 0),
    'a code with "_" (the folder name separator) is refused');
  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--code', 'aaa-MZ-chimanika', '--project', 'aaa_tit_text_reg', '--dry-run'], Code);
  Check(Pos('aaa-MZ-chimanika is not a well-formed BCP 47 language tag', Output) > 0,
    'a new code that is not BCP 47 is warned about');

  { uncommitted work in Titus is committed first }
  WriteFileText(Tit + '01' + PathDelim + '01.txt', '\v 1 Words, edited.');
  Before := Commits(Tit);
  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--language', 'aaa', '--code', 'aaa', '--all'], Code);
  Check((Code = 0) and (Pos('4 project(s) changed, 0 left alone', Output) = 0) and
    (Pos('3 project(s) changed, 0 left alone', Output) > 0),
    'the language''s projects under every code are changed (one was already right)');
  Check(Pos('aaa_phm_text_reg: already aaa, "Lang aaa", ltr.', Output) > 0,
    'one already right is said so');
  Check((Lang(Tit, Name, Direction) = 'aaa') and (Name = 'Lang aaa') and
    (Commits(Tit) = Before + 2) and
    (Trim(RunGit(Tit, ['status', '--porcelain']).Output) = ''),
    'a name put right, loose work committed first, then the change');
  Jud := Target + 'aaa_jud_text_reg' + PathDelim;
  Check(not DirectoryExists(Target + 'aaa-x-old_jud_text_reg') and
    (Lang(Jud, Name, Direction) = 'aaa'), 'a new code renames the folder');
  S := RunGit(Jud, ['log', '-1', '--format=%an|%s']).Output;
  Check(Pos('BTT Workbench|Language: aaa-x-old "Lang aaa" ltr -> aaa "Lang aaa" ltr', S) = 1,
    'committed as BTT Workbench, saying what changed');
  Check(DirectoryExists(Target + 'aaa_rut_text_reg') and
    (Pos('upload to WACS under their new names', Output) > 0),
    'a code that was not BCP 47 replaced; WACS is left as it is');

  { a folder in the way; a code with its database name and direction }
  MakeProject('ppp', 'Lang ppp', 'rtl', 'tit');
  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--code', 'ppp', '--project', 'aaa_tit_text_reg', '--project', 'aaa_phm_text_reg'], Code);
  Check((Pos('aaa_tit_text_reg: cannot rename it to ppp_tit_text_reg, which already exists',
    Output) > 0) and (Lang(Tit, Name, Direction) = 'aaa'),
    'a project whose new folder exists is left alone');
  Phm := Target + 'ppp_phm_text_reg' + PathDelim;
  Check((Lang(Phm, Name, Direction) = 'ppp') and (Name = 'Lang ppp') and (Direction = 'rtl'),
    'name and direction come from the language database for the new code');

  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--project', 'aaa_tit_text_reg', '--name', 'Мой язык', '--direction', 'rtl'], Code);
  Check((Lang(Tit, Name, Direction) = 'aaa') and (Name = 'Мой язык') and (Direction = 'rtl'),
    'a name and direction given are used');
  Output := Run('language-change', ['--target-dir', Target, '--language-db', LangDb,
    '--language', 'zzz', '--project', 'nothing_here'], Code);
  Check((Code = 0) and (Pos('nothing_here: not found', Output) > 0),
    'an unknown project is reported');
end;

end.
