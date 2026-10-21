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
  Classes, SysUtils, WBReporter, WBGit, TestUtil;

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
end;

end.
