unit WBChunkHistory;

{$mode objfpc}{$H+}

(* Every committed version of a project's chunk files, read from git in one
   call: git log --all -p with a context so large that each diff shows the
   whole new file, so a version is the diff's context and added lines.
   Merge commits show no diff and add no versions; their parents do.
   Deleted files have no new version. Text stays UTF-8. *)

interface

uses
  Classes, SysUtils;

type
  TChunkVersion = record
    Path: string;      // 01/04.txt, with '/'
    Commit: string;    // full hash
    Time: Int64;       // author time, Unix seconds
    Date: string;      // author time in the author's zone: 2026-10-08 22:56
    Author: string;
    Text: string;
  end;
  TChunkVersions = array of TChunkVersion;

  TCommitFiles = record
    Commit: string;
    Files: Integer;    // chunk files the commit changed
  end;
  TCommitFilesList = array of TCommitFiles;

{ False (and nothing read) if Dir has no readable git history. }
function ReadChunkHistory(const Dir: string; out Versions: TChunkVersions;
  out Commits: TCommitFilesList): Boolean;
{ Parses the output of the git log call above (exposed for tests). }
procedure ParseChunkLog(const Log: string; out Versions: TChunkVersions;
  out Commits: TCommitFilesList);

implementation

uses
  WBGit;

procedure ParseChunkLog(const Log: string; out Versions: TChunkVersions;
  out Commits: TCommitFilesList);
var
  P, E, NV, NC: Integer;
  Line, Commit, Author, Date, Path, Buf: string;
  Time: Int64;
  Parts: TStringArray;
  InFile: Boolean;

  procedure Flush;
  begin
    if InFile and (Path <> '') then
    begin
      if NV > High(Versions) then
        SetLength(Versions, NV * 2 + 16);
      Versions[NV].Path := Path;
      Versions[NV].Commit := Commit;
      Versions[NV].Time := Time;
      Versions[NV].Author := Author;
      Versions[NV].Date := Date;
      Versions[NV].Text := Buf;
      Inc(NV);
    end;
    InFile := False;
    Path := '';
    Buf := '';
  end;

begin
  Versions := nil;
  Commits := nil;
  NV := 0;
  NC := 0;
  InFile := False;
  Path := '';
  Buf := '';
  Commit := '';
  Date := '';
  Author := '';
  Time := 0;
  P := 1;
  while P <= Length(Log) do
  begin
    E := P;
    while (E <= Length(Log)) and (Log[E] <> #10) do
      Inc(E);
    Line := Copy(Log, P, E - P);
    P := E + 1;
    if (Line <> '') and (Line[1] = #1) then
    begin
      Flush;
      Parts := Copy(Line, 2, MaxInt).Split([#9], 4);
      Commit := Parts[0];
      Time := 0;
      Date := '';
      Author := '';
      if Length(Parts) > 1 then
        Time := StrToInt64Def(Parts[1], 0);
      if Length(Parts) > 2 then
        Date := Copy(Parts[2], 1, 16);
      if Length(Parts) > 3 then
        Author := Parts[3];
      if NC > High(Commits) then
        SetLength(Commits, NC * 2 + 16);
      Commits[NC].Commit := Commit;
      Commits[NC].Files := 0;
      Inc(NC);
    end
    else if Copy(Line, 1, 11) = 'diff --git ' then
    begin
      Flush;
      if NC > 0 then
        Inc(Commits[NC - 1].Files);
    end
    else if Copy(Line, 1, 4) = '+++ ' then
    begin
      Flush;
      InFile := True;
      if Line = '+++ /dev/null' then
        Path := ''
      else
        Path := Copy(Line, 7, MaxInt);    // '+++ b/01/04.txt'
    end
    else if InFile and (Line <> '') and (Line[1] in [' ', '+']) then
      Buf := Buf + Copy(Line, 2, MaxInt) + #10;
  end;
  Flush;
  SetLength(Versions, NV);
  SetLength(Commits, NC);
end;

function ReadChunkHistory(const Dir: string; out Versions: TChunkVersions;
  out Commits: TCommitFilesList): Boolean;
var
  R: TGitResult;
begin
  Versions := nil;
  Commits := nil;
  if not (GitAvailable and DirectoryExists(IncludeTrailingPathDelimiter(Dir) + '.git')) then
    Exit(False);
  R := RunGit(Dir, ['-c', 'core.quotepath=off', 'log', '--all', '--no-renames',
    '--no-color', '--no-ext-diff', '-p', '-U1000000', '--format=%x01%H%x09%at%x09%ai%x09%an',
    '--', ':(glob)*/*.txt']);
  if R.ExitCode <> 0 then
    Exit(False);
  ParseChunkLog(R.Output, Versions, Commits);
  Result := True;
end;

end.
