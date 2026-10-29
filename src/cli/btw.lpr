program btw;

{$mode objfpc}{$H+}
{$R *.res}   // version information (Windows file properties)

{ btw: command-line front end for BTT Workbench.

    btw [--lang <code>] list
    btw [--lang <code>] help <module>
    btw [--lang <code>] <module> [options]
    btw [--lang <code>] <module> --list [filters]   items a checklist can take
    btw --version

  A module with a checklist option (e.g. repos to download) takes the
  items as repeated --<option> values, or --all for every item. A password
  option is asked for without echo when left out (stdin may be piped).

  Messages go to stdout (info) and stderr (warnings, errors). Exit code is
  the module's result: 0 success, 1 module failure, 2 usage error. }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  {$IFDEF UNIX}termio,{$ENDIF}{$IFDEF WINDOWS}Windows,{$ENDIF}
  WBReporter, WBModule, WBCommandLine, WBI18n, WBVersion, WBAllModules;

resourcestring
  rsUsage =
    'Usage:'#10 +
    '  btw [--lang <code>] list               List modules'#10 +
    '  btw [--lang <code>] help <module>      Show a module''s options'#10 +
    '  btw [--lang <code>] <module> [options] Run a module'#10 +
    '  btw --version';
  rsModules = 'Modules:';
  rsOptions = 'Options:';
  rsRequired = '(required)';
  rsDefault = '(default: %s)';
  rsUnknownModule = 'Unknown module: %s. Run "btw list" to see modules.';
  rsUnknownGlobal = 'Unknown option: %s';
  rsChecklistHelp = '  --%s takes items from "btw %s --list"; --all takes every item.';
  rsNoItems = 'Nothing found.';
  rsItemCount = '%d item(s).';
  rsWarningPrefix = 'warning: ';
  rsErrorPrefix = 'error: ';

type
  TConsoleReporter = class(TWBReporter)
  public
    procedure Message(Level: TWBMessageLevel; const Text: string); override;
  end;

{ Warnings and errors go to stderr. Flush after each line so the two
  streams stay in order on a terminal (stdout is buffered when piped). }
procedure TConsoleReporter.Message(Level: TWBMessageLevel; const Text: string);
begin
  case Level of
    mlInfo:
      begin
        WriteLn(Text);
        Flush(Output);
      end;
    mlWarning:
      begin
        WriteLn(StdErr, rsWarningPrefix, Text);
        Flush(StdErr);
      end;
    mlError:
      begin
        WriteLn(StdErr, rsErrorPrefix, Text);
        Flush(StdErr);
      end;
  end;
end;

procedure ListModules;
var
  I, Width: Integer;
  M: TWBModule;
begin
  Width := 0;
  for I := 0 to ModuleCount - 1 do
    if Length(ModuleAt(I).Id) > Width then
      Width := Length(ModuleAt(I).Id);
  WriteLn(rsModules);
  for I := 0 to ModuleCount - 1 do
  begin
    M := ModuleAt(I);
    WriteLn('  ', M.Id.PadRight(Width + 2), M.Title);
  end;
end;

procedure ShowModuleHelp(M: TWBModule);
var
  Def: TWBOptionDef;
  Usage, Left: string;
begin
  Usage := 'btw ' + M.Id;
  for Def in M.OptionDefs do
    if Def.Positional and Def.Multiple then
      Usage := Usage + ' <' + Def.Name + '>...'
    else if Def.Positional then
      Usage := Usage + ' <' + Def.Name + '>'
    else if Def.Kind = okFlag then
      Usage := Usage + ' [--' + Def.Name + ']'
    else if Def.Kind = okChoice then
      Usage := Usage + ' [--' + Def.Name + ' ' + String.Join('|', Def.Choices) + ']'
    else if Def.Kind = okChecklist then
      Usage := Usage + ' [--' + Def.Name + ' <value>... | --all]'
    else
      Usage := Usage + ' [--' + Def.Name + ' <' + OptionKindName(Def.Kind) + '>]';
  WriteLn(M.Title);
  WriteLn;
  WriteLn(M.Description);
  WriteLn;
  WriteLn('  ', Usage);
  WriteLn;
  WriteLn(rsOptions);
  for Def in M.OptionDefs do
  begin
    Left := '--' + Def.Name;
    if Def.Kind = okChoice then
      Left := Left + ' ' + String.Join('|', Def.Choices)
    else if Def.Kind <> okFlag then
      Left := Left + ' <' + OptionKindName(Def.Kind) + '>';
    Write('  ', Left.PadRight(26), Def.Caption, ': ', Def.Help);
    if Def.Required then
      Write(' ', rsRequired);
    if Def.Default <> '' then
      Write(' ', Format(rsDefault, [Def.Default]));
    WriteLn;
  end;
  if ChecklistOption(M) <> '' then
    WriteLn(Format(rsChecklistHelp, [ChecklistOption(M), M.Id]));
end;

{ A line from stdin without echo when it is a terminal. }
function ReadSecret(const Prompt: string): string;
{$IFDEF UNIX}
var
  Old, T: Termios;
  Tty: Boolean;
{$ENDIF}
{$IFDEF WINDOWS}
var
  H: THandle;
  Mode: DWORD;
  Tty: Boolean;
{$ENDIF}
begin
  Write(StdErr, Prompt, ': ');
  Flush(StdErr);
  Result := '';
  {$IFDEF UNIX}
  Tty := IsATTY(StdInputHandle) = 1;
  if Tty then
  begin
    TCGetAttr(StdInputHandle, Old);
    T := Old;
    T.c_lflag := T.c_lflag and not ECHO;
    TCSetAttr(StdInputHandle, TCSANOW, T);
  end;
  try
    ReadLn(Result);
  finally
    if Tty then
    begin
      TCSetAttr(StdInputHandle, TCSANOW, Old);
      WriteLn(StdErr);
    end;
  end;
  {$ENDIF}
  {$IFDEF WINDOWS}
  H := GetStdHandle(STD_INPUT_HANDLE);
  Tty := GetConsoleMode(H, Mode);
  if Tty then
    SetConsoleMode(H, Mode and not ENABLE_ECHO_INPUT);
  try
    ReadLn(Result);
  finally
    if Tty then
    begin
      SetConsoleMode(H, Mode);
      WriteLn(StdErr);
    end;
  end;
  {$ENDIF}
end;

{ Asks for passwords left out whose PromptWith option was given. }
procedure PromptPasswords(M: TWBModule; Options: TStrings);
var
  Def: TWBOptionDef;
begin
  for Def in M.OptionDefs do
    if (Def.Kind = okPassword) and (Def.PromptWith <> '') and
       (Options.Values[Def.PromptWith] <> '') and (Options.Values[Def.Name] = '') then
      Options.Values[Def.Name] := ReadSecret(Def.Caption);
end;

{ btw <module> --list [filters]: the checklist's items as a table, the
  value to pass first. }
function ListChoices(M: TWBModule; Args: TStrings): Integer;
var
  Options: TStringList;
  Reporter: TConsoleReporter;
  ErrorMsg, OptName, Line: string;
  List: TWBChoiceList;
  Def: TWBOptionDef;
  Widths: array of Integer;
  Rows: array of TStringArray;
  Header: TStringArray;
  I, J: Integer;
begin
  Result := 2;
  OptName := ChecklistOption(M);
  Options := TStringList.Create;
  Reporter := TConsoleReporter.Create;
  try
    if not ParseModuleArgs(M, Args, Options, ErrorMsg) then
    begin
      Reporter.Error(ErrorMsg);
      Exit;
    end;
    PromptPasswords(M, Options);
    if not M.Choices(OptName, Options, Reporter, List) then
      Exit(1);
    Header := [OptName];
    for Def in M.OptionDefs do
      if Def.Name = OptName then
        Header := [Def.Caption];
    Header := Concat(Header, List.Headers);
    Rows := [Header];
    for I := 0 to High(List.Items) do
      Rows := Concat(Rows, [Concat([List.Items[I].Value], List.Items[I].Columns)]);
    Widths := nil;
    SetLength(Widths, Length(Header));
    for I := 0 to High(Rows) do
      for J := 0 to High(Rows[I]) do
        if (J <= High(Widths)) and (Length(Rows[I][J]) > Widths[J]) then
          Widths[J] := Length(Rows[I][J]);
    if Length(List.Items) = 0 then
    begin
      WriteLn(rsNoItems);
      Exit(0);
    end;
    for I := 0 to High(Rows) do
    begin
      Line := '';
      for J := 0 to High(Rows[I]) do
        if J < High(Rows[I]) then
          Line := Line + Rows[I][J].PadRight(Widths[J] + 2)
        else
          Line := Line + Rows[I][J];
      WriteLn(TrimRight(Line));
    end;
    WriteLn(Format(rsItemCount, [Length(List.Items)]));
    Result := 0;
  finally
    Reporter.Free;
    Options.Free;
  end;
end;

function RunModule(M: TWBModule; Args: TStrings): Integer;
var
  Options: TStringList;
  Reporter: TConsoleReporter;
  ErrorMsg: string;
begin
  Options := TStringList.Create;
  Reporter := TConsoleReporter.Create;
  try
    if not ParseModuleArgs(M, Args, Options, ErrorMsg) then
    begin
      Reporter.Error(ErrorMsg);
      Exit(2);
    end;
    PromptPasswords(M, Options);
    if not M.ValidateOptions(Options, Reporter) then
      Exit(2);
    Result := M.Execute(Options, Reporter);
  finally
    Reporter.Free;
    Options.Free;
  end;
end;

function Main: Integer;
var
  Args: TStringList;
  I: Integer;
  Lang, Cmd: string;
  M: TWBModule;
begin
  Result := 0;
  Args := TStringList.Create;
  try
    for I := 1 to ParamCount do
      Args.Add(ParamStr(I));

    { Global options come before the command. }
    Lang := StartupLanguage;
    while (Args.Count > 0) and (Copy(Args[0], 1, 2) = '--') do
    begin
      if Args[0] = '--version' then
      begin
        WriteLn('btw ', WorkbenchVersionLong);
        Exit(0);
      end
      else if (Args[0] = '--help') then
        Break
      else if Copy(Args[0], 1, 7) = '--lang=' then
      begin
        Lang := Copy(Args[0], 8, MaxInt);
        Args.Delete(0);
      end
      else if (Args[0] = '--lang') and (Args.Count > 1) then
      begin
        Lang := Args[1];
        Args.Delete(0);
        Args.Delete(0);
      end
      else
      begin
        LoadLanguage(Lang);
        WriteLn(StdErr, rsErrorPrefix, Format(rsUnknownGlobal, [Args[0]]));
        WriteLn(StdErr, rsUsage);
        Exit(2);
      end;
    end;
    LoadLanguage(Lang);

    if Args.Count = 0 then
    begin
      WriteLn(rsUsage);
      WriteLn;
      ListModules;
      Exit(2);
    end;

    Cmd := Args[0];
    Args.Delete(0);
    if (Cmd = '--help') or (Cmd = '-h') then
    begin
      WriteLn(rsUsage);
      Exit(0);
    end;
    if Cmd = 'list' then
    begin
      ListModules;
      Exit(0);
    end;
    if Cmd = 'help' then
    begin
      if Args.Count = 0 then
      begin
        WriteLn(rsUsage);
        Exit(0);
      end;
      Cmd := Args[0];
      M := FindModule(Cmd);
      if M = nil then
      begin
        WriteLn(StdErr, rsErrorPrefix, Format(rsUnknownModule, [Cmd]));
        Exit(2);
      end;
      ShowModuleHelp(M);
      Exit(0);
    end;

    M := FindModule(Cmd);
    if M = nil then
    begin
      WriteLn(StdErr, rsErrorPrefix, Format(rsUnknownModule, [Cmd]));
      Exit(2);
    end;
    if (Args.Count = 1) and ((Args[0] = '--help') or (Args[0] = '-h')) then
    begin
      ShowModuleHelp(M);
      Exit(0);
    end;
    if (ChecklistOption(M) <> '') and (Args.IndexOf('--list') >= 0) then
    begin
      Args.Delete(Args.IndexOf('--list'));
      Exit(ListChoices(M, Args));
    end;
    Result := RunModule(M, Args);
  finally
    Args.Free;
  end;
end;

begin
  ExitCode := Main;
end.
