unit WBProcesses;

{$mode objfpc}{$H+}

(* Whether BTT-Writer is running, before its files are replaced: it keeps
   index.sqlite in memory (sql.js) and writes all of it back when it saves,
   so a file replaced under a running BTT-Writer would be overwritten with
   the old data.

   A process counts when its program file is named BTT-Writer (any case,
   with or without .exe): /usr/lib/btt-writer/BTT-Writer, BTT-Writer.exe.
   Linux reads /proc; Windows lists processes with Toolhelp (kernel32). *)

interface

uses
  Classes, SysUtils;

{ True if a BTT-Writer process runs; Detail names one (pid and program). }
function BttWriterRunning(out Detail: string): Boolean;

var
  { Tests: '' as found, 'yes' or 'no' to pretend. }
  BttWriterRunningOverride: string = '';

implementation

{$IFDEF WINDOWS}
uses
  Windows;

const
  TH32CS_SNAPPROCESS = $00000002;

type
  TProcessEntry32W = record
    dwSize: DWORD;
    cntUsage: DWORD;
    th32ProcessID: DWORD;
    th32DefaultHeapID: ULONG_PTR;
    th32ModuleID: DWORD;
    cntThreads: DWORD;
    th32ParentProcessID: DWORD;
    pcPriClassBase: LONG;
    dwFlags: DWORD;
    szExeFile: array[0..MAX_PATH - 1] of WideChar;
  end;

function CreateToolhelp32Snapshot(Flags, ProcessID: DWORD): THandle; stdcall;
  external 'kernel32' name 'CreateToolhelp32Snapshot';
function Process32FirstW(Snapshot: THandle; var Entry: TProcessEntry32W): BOOL; stdcall;
  external 'kernel32' name 'Process32FirstW';
function Process32NextW(Snapshot: THandle; var Entry: TProcessEntry32W): BOOL; stdcall;
  external 'kernel32' name 'Process32NextW';
{$ELSE}
uses
  BaseUnix;
{$ENDIF}

function IsBttWriterName(const FileName: string): Boolean;
var
  N: string;
begin
  N := LowerCase(ExtractFileName(FileName));
  Result := (N = 'btt-writer') or (N = 'btt-writer.exe');
end;

function BttWriterRunning(out Detail: string): Boolean;
{$IFDEF WINDOWS}
var
  Snap: THandle;
  E: TProcessEntry32W;
  Name: string;
begin
  Detail := '';
  if BttWriterRunningOverride <> '' then
  begin
    Result := BttWriterRunningOverride = 'yes';
    if Result then
      Detail := 'BTT-Writer';
    Exit;
  end;
  Result := False;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    E := Default(TProcessEntry32W);
    E.dwSize := SizeOf(E);
    if Process32FirstW(Snap, E) then
      repeat
        Name := UTF8Encode(UnicodeString(PWideChar(@E.szExeFile[0])));
        if IsBttWriterName(Name) then
        begin
          Detail := Format('%s (process %d)', [Name, E.th32ProcessID]);
          Exit(True);
        end;
      until not Process32NextW(Snap, E);
  finally
    CloseHandle(Snap);
  end;
end;
{$ELSE}
var
  SR: TSearchRec;
  Exe: string;
begin
  Detail := '';
  if BttWriterRunningOverride <> '' then
  begin
    Result := BttWriterRunningOverride = 'yes';
    if Result then
      Detail := 'BTT-Writer';
    Exit;
  end;
  Result := False;
  if FindFirst('/proc/*', faDirectory, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name = '') or not (SR.Name[1] in ['0'..'9']) then
        Continue;
      Exe := fpReadLink('/proc/' + SR.Name + '/exe');   // others' processes: ''
      if (Exe <> '') and IsBttWriterName(Exe) then
      begin
        Detail := Format('%s (process %s)', [Exe, SR.Name]);
        Exit(True);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;
{$ENDIF}

end.
