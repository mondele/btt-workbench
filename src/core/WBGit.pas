unit WBGit;

{$mode objfpc}{$H+}

{ Runs the git command-line tool (BTT-Writer projects are git repos, and
  BTT-Writer itself needs git installed). No shell is involved: arguments
  go straight to the process, so paths with spaces or quotes are safe.

  LC_ALL=C keeps git's messages in English so callers can parse them;
  anything shown to a person is translated by the caller instead. }

interface

uses
  Classes, SysUtils;

type
  TGitResult = record
    ExitCode: Integer;
    Output: string;      // stdout
    ErrorOutput: string; // stderr
  end;

function GitAvailable: Boolean;
function RunGit(const WorkDir: string; const Args: array of string): TGitResult;
{ Stdout of a git command that must succeed, trimmed; raises on failure. }
function GitText(const WorkDir: string; const Args: array of string): string;

implementation

uses
  Process, Pipes;

function GitExecutable: string;
begin
  Result := Trim(GetEnvironmentVariable('BTW_GIT'));
  if Result = '' then
    Result := ExeSearch({$IFDEF WINDOWS}'git.exe'{$ELSE}'git'{$ENDIF},
      GetEnvironmentVariable('PATH'));
end;

function GitAvailable: Boolean;
begin
  Result := GitExecutable <> '';
end;

function ReadAll(Stream: TInputPipeStream; Into: TStream): Boolean;
var
  Buf: array[0..4095] of Byte;
  N: LongInt;
begin
  Result := False;
  while Stream.NumBytesAvailable > 0 do
  begin
    N := Stream.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    Into.WriteBuffer(Buf, N);
    Result := True;
  end;
end;

function RunGit(const WorkDir: string; const Args: array of string): TGitResult;
var
  P: TProcess;
  OutS, ErrS: TStringStream;
  A: string;
  I: Integer;
begin
  Result.ExitCode := -1;
  Result.Output := '';
  Result.ErrorOutput := '';
  if not GitAvailable then
  begin
    Result.ErrorOutput := 'git not found';
    Exit;
  end;
  P := TProcess.Create(nil);
  OutS := TStringStream.Create('');
  ErrS := TStringStream.Create('');
  try
    P.Executable := GitExecutable;
    P.CurrentDirectory := WorkDir;
    for A in Args do
      P.Parameters.Add(A);
    for I := 0 to GetEnvironmentVariableCount - 1 do
      P.Environment.Add(GetEnvironmentString(I));
    P.Environment.Values['LC_ALL'] := 'C';
    P.Environment.Values['GIT_TERMINAL_PROMPT'] := '0';
    P.Options := [poUsePipes, poNoConsole];
    P.ShowWindow := swoHIDE;
    P.Execute;
    { Drain both pipes while running so a chatty git cannot block. }
    while P.Running do
      if not (ReadAll(P.Output, OutS) or ReadAll(P.Stderr, ErrS)) then
        Sleep(5);
    ReadAll(P.Output, OutS);
    ReadAll(P.Stderr, ErrS);
    Result.ExitCode := P.ExitCode;   // ExitStatus is the raw wait status (1 -> 256)
    Result.Output := OutS.DataString;
    Result.ErrorOutput := ErrS.DataString;
  finally
    ErrS.Free;
    OutS.Free;
    P.Free;
  end;
end;

function GitText(const WorkDir: string; const Args: array of string): string;
var
  R: TGitResult;
begin
  R := RunGit(WorkDir, Args);
  if R.ExitCode <> 0 then
    raise Exception.CreateFmt('git %s failed (%d): %s',
      [Args[0], R.ExitCode, Trim(R.ErrorOutput)]);
  Result := Trim(R.Output);
end;

end.
