unit TestGitRepair;

{$mode objfpc}{$H+}

(* Tests for WBImport.RepairGitFolder through the projects module: a .git
   folder that lost HEAD, config and its index (as a copy can leave it, an
   Icelandic Sign Language project in October 2026), one that lost only its
   index, one whose history is damaged too (left as it was), and one with no
   branch to point HEAD at. *)

interface

procedure TestGitRepairs(const TempRoot: string);

implementation

uses
  Classes, SysUtils, WBReporter, WBGit, WBDataPaths, TestUtil;

var
  Target: string;

function MakeRepo(const Name: string): string;
begin
  Result := Target + Name + PathDelim;
  ForceDirectories(Result + '01');
  WriteFileText(Result + 'manifest.json', '{"package_version": 8, "target_language": ' +
    '{"id": "aa", "name": "Lang aaa", "direction": "ltr"}, "project": {"id": "3jn", ' +
    '"name": "3 John"}, "type": {"id": "text"}, "resource": {"id": "reg"}}');
  WriteFileText(Result + '01' + PathDelim + '01.txt', '\v 1 Words.');
  RunGit(Result, ['-c', 'init.defaultBranch=master', 'init', '-q']);
  RunGit(Result, ['add', '--all']);
  RunGit(Result, ['-c', 'user.name=Translator', '-c', 'user.email=t@example.com',
    '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'start']);
end;

function Run(const Args: array of string; out Code: Integer): string;
var
  R: TWBListReporter;
  I: Integer;
begin
  Code := RunModule('projects', Args, R);
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

function Clean(const Dir: string): Boolean;
begin
  Result := (RunGit(Dir, ['rev-parse', '--verify', '-q', 'HEAD']).ExitCode = 0) and
    (Trim(RunGit(Dir, ['status', '--porcelain']).Output) = '');
end;

{ Extra chunks: files no compared source has. A source with chunks 01, 04
  and 06; a project with those plus 01-02 (verse 2 again: removable) and
  01-10 (verse 10, in no other chunk: kept). }
procedure TestExtraChunks(const TempRoot: string);
var
  Data, Lib, Dir, Output, OldBundled: string;
  Code: Integer;

  procedure PutFile(const Path, Text: string);
  begin
    ForceDirectories(ExtractFileDir(Path));
    WriteFileText(Path, Text);
  end;

begin
  Section('projects: extra chunks');
  Data := TempRoot + 'extrachunks' + PathDelim;
  Target := Data + 'targetTranslations' + PathDelim;
  Lib := Data + 'library' + PathDelim + 'resource_containers' + PathDelim + 'en_tit_ulb' +
    PathDelim + 'content' + PathDelim + '01' + PathDelim;
  PutFile(Lib + '01.usx', '<verse number="1" style="v" />a <verse number="2" style="v" />b ' +
    '<verse number="3" style="v" />c');
  PutFile(Lib + '04.usx', '<verse number="4" style="v" />d <verse number="5" style="v" />e');
  PutFile(Lib + '06.usx', '<verse number="6" style="v" />f');
  OldBundled := BundledSourcesOverride;
  BundledSourcesOverride := TempRoot + 'no-bundled-sources';
  try
    Dir := Target + 'aa_tit_text_reg' + PathDelim;
    PutFile(Dir + 'manifest.json', '{"package_version": 8, "target_language": {"id": "aa", ' +
      '"name": "A", "direction": "ltr"}, "project": {"id": "tit", "name": "Titus"}, ' +
      '"type": {"id": "text"}, "resource": {"id": "reg"}, "source_translations": ' +
      '[{"language_id": "en", "resource_id": "ulb"}], "finished_chunks": ["01-01", "01-02", "01-04"]}');
    PutFile(Dir + '01' + PathDelim + '01.txt', '\v 1 a \v 2 b \v 3 c');
    PutFile(Dir + '01' + PathDelim + '02.txt', '\v 2 pasted');
    PutFile(Dir + '01' + PathDelim + '04.txt', '\v 4 d \v 5 e');
    PutFile(Dir + '01' + PathDelim + '06.txt', '\v 6 f');
    PutFile(Dir + '01' + PathDelim + '10.txt', '\v 10 only here');
    RunGit(Dir, ['-c', 'init.defaultBranch=master', 'init', '-q']);
    RunGit(Dir, ['add', '--all']);
    RunGit(Dir, ['-c', 'user.name=Paster', '-c', 'user.email=p@example.com', '-c',
      'commit.gpgsign=false', 'commit', '-q', '-m', 'start']);

    Output := Run(['--target-dir', Target, '--dry-run'], Code);
    Check((Pos('Chunks no compared source has: 01-02, 01-10.', Output) > 0) and
      (Pos('--remove-extra-chunks', Output) > 0) and
      (Pos('01-02: added by ', Output) > 0) and (Pos('Paster', Output) > 0) and
      FileExists(Dir + '01' + PathDelim + '02.txt'),
      'extra chunks reported, with who added them and how they begin; removal offered');
    Output := Run(['--target-dir', Target, '--dry-run', '--remove-extra-chunks'], Code);
    Check((Pos('Would remove: 01-02 (dry run)', Output) > 0) and
      (Pos('01-10 holds verses no other chunk has (10); kept', Output) > 0) and
      FileExists(Dir + '01' + PathDelim + '02.txt'),
      'a check with the option says what would go, and keeps a chunk with a verse found nowhere else');
    Output := Run(['--target-dir', Target, '--remove-extra-chunks'], Code);
    Check((Pos('Removed 01-02, and committed', Output) > 0) and
      not FileExists(Dir + '01' + PathDelim + '02.txt') and
      FileExists(Dir + '01' + PathDelim + '10.txt') and
      (Pos('"01-02"', ReadFileText(Dir + 'manifest.json')) = 0) and
      (Pos('Remove chunks no source has', RunGit(Dir, ['log', '-1', '--format=%B']).Output) > 0) and
      (Trim(RunGit(Dir, ['status', '--porcelain']).Output) = ''),
      'Run removes it, takes it out of finished_chunks and commits');
  finally
    BundledSourcesOverride := OldBundled;
  end;
end;

procedure TestGitRepairs(const TempRoot: string);
var
  Lost, IndexOnly, Broken, NoBranch, Output, Obj: string;
  Code: Integer;
begin
  Section('projects: .git folder repair');
  Target := TempRoot + 'gitrepair' + PathDelim;
  Lost := MakeRepo('aa_3jn_text_reg');
  DeleteFile(Lost + '.git' + PathDelim + 'HEAD');
  DeleteFile(Lost + '.git' + PathDelim + 'config');
  DeleteFile(Lost + '.git' + PathDelim + 'index');

  Output := Run(['--target-dir', Target, '--dry-run'], Code);
  Check((Pos('lost HEAD, config and its index, though its history is there (branch master',
    Output) > 0) and not FileExists(Lost + '.git' + PathDelim + 'HEAD'),
    'a check reports a .git folder that lost HEAD, config and index, and changes nothing');
  Output := Run(['--target-dir', Target], Code);
  Check((Code = 0) and (Pos('Rebuilt them', Output) > 0) and Clean(Lost) and
    (Pos('1 project(s) had their .git folder rebuilt', Output) > 0),
    'a run rebuilds them: history back, files as committed');

  IndexOnly := MakeRepo('aa_2jn_text_reg');
  DeleteFile(IndexOnly + '.git' + PathDelim + 'index');
  Output := Run(['--target-dir', Target], Code);
  Check((Pos('lost its index', Output) > 0) and Clean(IndexOnly),
    'a lost index alone is rebuilt from the last commit');

  { history damaged too: the last commit's object gone. Nothing is kept. }
  Broken := MakeRepo('aa_jud_text_reg');
  Obj := Trim(RunGit(Broken, ['rev-parse', 'HEAD']).Output);
  Check(Length(Obj) = 40, 'test repo has a commit');
  if Length(Obj) = 40 then
    DeleteFile(Broken + '.git' + PathDelim + 'objects' + PathDelim + Copy(Obj, 1, 2) +
      PathDelim + Copy(Obj, 3, MaxInt));
  DeleteFile(Broken + '.git' + PathDelim + 'HEAD');
  DeleteFile(Broken + '.git' + PathDelim + 'config');
  Output := Run(['--target-dir', Target], Code);
  Check((Pos('Could not rebuild them', Output) > 0) and
    not FileExists(Broken + '.git' + PathDelim + 'HEAD') and
    not FileExists(Broken + '.git' + PathDelim + 'config'),
    'with history damaged too it is left as it was');

  NoBranch := MakeRepo('aa_phm_text_reg');
  DeleteFile(NoBranch + '.git' + PathDelim + 'HEAD');
  DeleteFile(NoBranch + '.git' + PathDelim + 'refs' + PathDelim + 'heads' + PathDelim + 'master');
  Output := Run(['--target-dir', Target], Code);
  Check(Pos('no HEAD and no branch', Output) > 0, 'with no branch to point at it is only reported');
  TestExtraChunks(TempRoot);
end;

end.
