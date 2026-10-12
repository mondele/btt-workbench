program btw;

{$mode objfpc}{$H+}

{ btw: command-line front end for BTT Workbench.

    btw [--lang <code>] list
    btw [--lang <code>] help <module>
    btw [--lang <code>] <module> [options]
    btw --version

  Messages go to stdout (info) and stderr (warnings, errors). Exit code is
  the module's result: 0 success, 1 module failure, 2 usage error. }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
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
  rsUnknownModule = 'Unknown module: %s. Run "btw list" to see modules.';
  rsUnknownGlobal = 'Unknown option: %s';
  rsWarningPrefix = 'warning: ';
  rsErrorPrefix = 'error: ';

type
  TConsoleReporter = class(TWBReporter)
  public
    procedure Message(Level: TWBMessageLevel; const Text: string); override;
  end;

procedure TConsoleReporter.Message(Level: TWBMessageLevel; const Text: string);
begin
  case Level of
    mlInfo:    WriteLn(Text);
    mlWarning: WriteLn(StdErr, rsWarningPrefix, Text);
    mlError:   WriteLn(StdErr, rsErrorPrefix, Text);
  end;
end;

procedure ListModules;
var
  I: Integer;
  M: TWBModule;
begin
  WriteLn(rsModules);
  for I := 0 to ModuleCount - 1 do
  begin
    M := ModuleAt(I);
    WriteLn('  ', M.Id.PadRight(14), M.Title);
  end;
end;

procedure ShowModuleHelp(M: TWBModule);
var
  Def: TWBOptionDef;
  Usage, Left: string;
begin
  Usage := 'btw ' + M.Id;
  for Def in M.OptionDefs do
    if Def.Positional then
      Usage := Usage + ' <' + Def.Name + '>'
    else if Def.Kind = okFlag then
      Usage := Usage + ' [--' + Def.Name + ']'
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
    if Def.Kind <> okFlag then
      Left := Left + ' <' + OptionKindName(Def.Kind) + '>';
    Write('  ', Left.PadRight(26), Def.Caption, ': ', Def.Help);
    if Def.Required then
      Write(' ', rsRequired);
    WriteLn;
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
    Lang := SystemLanguage;
    while (Args.Count > 0) and (Copy(Args[0], 1, 2) = '--') do
    begin
      if Args[0] = '--version' then
      begin
        WriteLn('btw ', WorkbenchVersion);
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
    Result := RunModule(M, Args);
  finally
    Args.Free;
  end;
end;

begin
  ExitCode := Main;
end.
