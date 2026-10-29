unit WBProcesses;

{$mode objfpc}{$H+}

(* Whether BTT-Writer is running, before its files are replaced: it keeps
   index.sqlite in memory (sql.js) and writes all of it back when it saves,
   so a file replaced under a running BTT-Writer would be overwritten with
   the old data.

   A process counts when its program file is named BTT-Writer (any case,
   with or without .exe): /usr/lib/btt-writer/BTT-Writer, BTT-Writer.exe,
   BTT-Writer.app/Contents/MacOS/BTT-Writer (its Electron helpers, "BTT-Writer
   Helper (Renderer)" and so on, do not count).
   Linux reads /proc; Windows lists processes with Toolhelp (kernel32); macOS
   with proc_listpids and proc_pidpath (libproc, part of libSystem). *)

interface

uses
  Classes, SysUtils;

{ True if a BTT-Writer process runs; Detail names one (pid and program). }
function BttWriterRunning(out Detail: string): Boolean;

var
  { Tests: '' as found, 'yes' or 'no' to pretend. }
  BttWriterRunningOverride: string = '';

implementation

{$IF DEFINED(WINDOWS)}
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
{$ELSEIF DEFINED(DARWIN)}
const
  PROC_ALL_PIDS = 1;
  PROC_PIDPATHINFO_MAXSIZE = 4 * 1024;

function proc_listpids(ProcType, TypeInfo: UInt32; Buffer: Pointer;
  BufferSize: Int32): Int32; cdecl; external 'c' name 'proc_listpids';
function proc_pidpath(Pid: Int32; Buffer: Pointer; BufferSize: UInt32): Int32; cdecl;
  external 'c' name 'proc_pidpath';
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
{$IF DEFINED(WINDOWS)}
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
{$ELSEIF DEFINED(DARWIN)}
var
  Pids: array of Int32;
  Bytes, I, Len: Int32;
  Path: array[0..PROC_PIDPATHINFO_MAXSIZE - 1] of AnsiChar;
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
  Bytes := proc_listpids(PROC_ALL_PIDS, 0, nil, 0);   // size needed now
  if Bytes <= 0 then
    Exit;
  SetLength(Pids, Bytes div SizeOf(Int32) + 64);       // room for new processes
  Bytes := proc_listpids(PROC_ALL_PIDS, 0, @Pids[0], Length(Pids) * SizeOf(Int32));
  if Bytes <= 0 then
    Exit;
  for I := 0 to Bytes div SizeOf(Int32) - 1 do
  begin
    if Pids[I] <= 0 then
      Continue;
    Len := proc_pidpath(Pids[I], @Path[0], SizeOf(Path));   // others' processes: 0
    if Len <= 0 then
      Continue;
    SetString(Exe, PAnsiChar(@Path[0]), Len);
    if IsBttWriterName(Exe) then
    begin
      Detail := Format('%s (process %d)', [Exe, Pids[I]]);
      Exit(True);
    end;
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
