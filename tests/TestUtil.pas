unit TestUtil;

{$mode objfpc}{$H+}

{ Shared helpers for the headless tests. }

interface

uses
  Classes, SysUtils, WBReporter;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
procedure Section(const Name: string);
function ReadFileText(const Path: string): string;
procedure WriteFileText(const Path, Text: string);
procedure DeleteTree(const Dir: string);
{ Parse Args with the module's CLI parser, validate, execute. Caller frees
  Reporter. }
function RunModule(const ModuleId: string; const Args: array of string;
  out Reporter: TWBListReporter): Integer;

implementation

uses
  WBModule, WBCommandLine, WBFiles;


procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if Condition then
    WriteLn('  ok   ', What)
  else
  begin
    Inc(Failures);
    WriteLn('  FAIL ', What);
  end;
end;

procedure Section(const Name: string);
begin
  WriteLn;
  WriteLn(Name);
end;

function ReadFileText(const Path: string): string;
var
  S: TStringStream;
begin
  S := TStringStream.Create('');
  try
    S.LoadFromFile(Path);
    Result := S.DataString;
  finally
    S.Free;
  end;
end;

procedure WriteFileText(const Path, Text: string);
var
  S: TStringStream;
begin
  S := TStringStream.Create(Text);
  try
    S.SaveToFile(Path);
  finally
    S.Free;
  end;
end;

procedure DeleteTree(const Dir: string);
begin
  WBFiles.DeleteTree(Dir);
end;

function RunModule(const ModuleId: string; const Args: array of string;
  out Reporter: TWBListReporter): Integer;
var
  ArgList, Options: TStringList;
  ErrorMsg, A: string;
  M: TWBModule;
begin
  M := FindModule(ModuleId);
  Reporter := TWBListReporter.Create;
  ArgList := TStringList.Create;
  Options := TStringList.Create;
  try
    for A in Args do
      ArgList.Add(A);
    if not ParseModuleArgs(M, ArgList, Options, ErrorMsg) then
    begin
      Reporter.Error(ErrorMsg);
      Exit(2);
    end;
    if not M.ValidateOptions(Options, Reporter) then
      Exit(2);
    Result := M.Execute(Options, Reporter);
  finally
    ArgList.Free;
    Options.Free;
  end;
end;

end.
