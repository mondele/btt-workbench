program BttWorkbench;

{$mode objfpc}{$H+}

{ Desktop GUI. Options: --lang <code> picks the interface language
  (default: the system language). }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Interfaces, Forms,
  WBI18n, WBAllModules, WorkbenchForm;

function LanguageFromCommandLine: string;
var
  I: Integer;
begin
  Result := SystemLanguage;
  for I := 1 to ParamCount do
    if (ParamStr(I) = '--lang') and (I < ParamCount) then
      Result := ParamStr(I + 1)
    else if Copy(ParamStr(I), 1, 7) = '--lang=' then
      Result := Copy(ParamStr(I), 8, MaxInt);
end;

begin
  LoadLanguage(LanguageFromCommandLine);
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TWorkbenchForm, WorkbenchMain);
  Application.Run;
end.
