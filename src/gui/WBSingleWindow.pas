unit WBSingleWindow;

{$mode objfpc}{$H+}

{ One BTT Workbench window per user for files opened from the desktop.

  The file manager starts a new btt-workbench for every double-click. If a
  window is already open, the new process hands its module and options to
  that window (SendToRunningInstance) and exits, so several .tstudio files
  end up in one import list. Otherwise it becomes the receiving window
  (StartInstanceServer).

  Uses FPC's SimpleIPC: on Unix a named pipe in $XDG_RUNTIME_DIR (private
  to the user), on Windows a message window. A plain text payload: the
  module id on the first line, then name=value lines; a Multiple option
  repeats its name. Paths are made absolute by the sender, since the two
  processes need not share a working directory. }

interface

uses
  Classes, SysUtils, WBModule;

type
  TInstancePayloadEvent = procedure(Module: TWBModule; Options: TStrings) of object;

{ True if a running window took the request. }
function SendToRunningInstance(Module: TWBModule; Options: TStrings): Boolean;
{ Start receiving; call after Application.Initialize. Safe to call when
  another window already receives (then this one simply does not). }
procedure StartInstanceServer(OnPayload: TInstancePayloadEvent);
procedure StopInstanceServer;

implementation

uses
  SimpleIPC, ExtCtrls
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  TInstanceReceiver = class(TComponent)
  private
    FServer: TSimpleIPCServer;
    FTimer: TTimer;
    FOnPayload: TInstancePayloadEvent;
    procedure TimerTick(Sender: TObject);
  end;

var
  Receiver: TInstanceReceiver = nil;

function ServerId: string;
var
  Dir: string;
begin
  {$IFDEF UNIX}
  Dir := GetEnvironmentVariable('XDG_RUNTIME_DIR');
  if (Dir = '') or not DirectoryExists(Dir) then
    Dir := GetTempDir(False);
  Result := IncludeTrailingPathDelimiter(Dir) + 'btt-workbench-' +
    IntToStr(FpGetuid) + '.ipc';
  {$ELSE}
  Result := 'btt-workbench-' + GetEnvironmentVariable('USERNAME');
  {$ENDIF}
end;

function Encode(Module: TWBModule; Options: TStrings): string;
var
  L: TStringList;
  Def: TWBOptionDef;
  V: string;
begin
  L := TStringList.Create;
  try
    L.Add(Module.Id);
    for Def in Module.OptionDefs do
      if Def.Multiple then
      begin
        for V in OptionValues(Options, Def.Name) do
          if Def.Kind in [okFile, okDirectory] then
            L.Add(Def.Name + '=' + ExpandFileName(V))
          else
            L.Add(Def.Name + '=' + V);
      end
      else if Options.Values[Def.Name] <> '' then
      begin
        V := Options.Values[Def.Name];
        if Def.Kind in [okFile, okDirectory] then
          V := ExpandFileName(V);
        L.Add(Def.Name + '=' + V);
      end;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function Decode(const Payload: string; Options: TStrings): TWBModule;
var
  L: TStringList;
  Def: TWBOptionDef;
  I: Integer;
  Name: string;
begin
  Result := nil;
  L := TStringList.Create;
  try
    L.Text := Payload;
    if L.Count = 0 then
      Exit;
    Result := FindModule(L[0]);
    if Result = nil then
      Exit;
    for I := 1 to L.Count - 1 do
    begin
      Name := L.Names[I];
      for Def in Result.OptionDefs do
        if Def.Name = Name then
          if Def.Multiple then
            AddOptionValue(Options, Name, L.ValueFromIndex[I])
          else
            Options.Values[Name] := L.ValueFromIndex[I];
    end;
  finally
    L.Free;
  end;
end;

function SendToRunningInstance(Module: TWBModule; Options: TStrings): Boolean;
var
  Client: TSimpleIPCClient;
begin
  Result := False;
  Client := TSimpleIPCClient.Create(nil);
  try
    Client.ServerID := ServerId;
    try
      if not Client.ServerRunning then
        Exit;
      Client.Connect;
      try
        Client.SendStringMessage(Encode(Module, Options));
      finally
        Client.Disconnect;
      end;
      Result := True;
    except
      Result := False;   // stale or unreachable: open our own window
    end;
  finally
    Client.Free;
  end;
end;

procedure TInstanceReceiver.TimerTick(Sender: TObject);
var
  Options: TStringList;
  Module: TWBModule;
begin
  while FServer.PeekMessage(0, True) do
  begin
    Options := TStringList.Create;
    try
      Module := Decode(FServer.StringMessage, Options);
      if (Module <> nil) and Assigned(FOnPayload) then
        FOnPayload(Module, Options);
    finally
      Options.Free;
    end;
  end;
end;

procedure StartInstanceServer(OnPayload: TInstancePayloadEvent);
var
  Probe: TSimpleIPCClient;
  Running: Boolean;
begin
  if Receiver <> nil then
    Exit;
  Probe := TSimpleIPCClient.Create(nil);
  try
    Probe.ServerID := ServerId;
    Running := Probe.ServerRunning;
  finally
    Probe.Free;
  end;
  if Running then
    Exit;
  Receiver := TInstanceReceiver.Create(nil);
  Receiver.FOnPayload := OnPayload;
  Receiver.FServer := TSimpleIPCServer.Create(Receiver);
  Receiver.FServer.ServerID := ServerId;
  Receiver.FServer.Global := True;   // ServerID is already per user; no PID suffix
  try
    Receiver.FServer.StartServer(False);
    {$IFDEF UNIX}
    FpChmod(ServerId, &600);
    {$ENDIF}
  except
    FreeAndNil(Receiver);    // single-window mode is a convenience, not required
    Exit;
  end;
  Receiver.FTimer := TTimer.Create(Receiver);
  Receiver.FTimer.Interval := 200;
  Receiver.FTimer.OnTimer := @Receiver.TimerTick;
  Receiver.FTimer.Enabled := True;
end;

procedure StopInstanceServer;
begin
  if Receiver = nil then
    Exit;
  Receiver.FTimer.Enabled := False;
  try
    Receiver.FServer.StopServer;
  except
    // pipe already gone; nothing to clean up
  end;
  FreeAndNil(Receiver);
end;

finalization
  StopInstanceServer;

end.
