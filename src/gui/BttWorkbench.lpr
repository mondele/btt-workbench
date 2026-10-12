program BttWorkbench;

{$mode objfpc}{$H+}

{ Desktop GUI.

    btt-workbench [--lang <code>] [<module> [options]]

  --lang picks the interface language (default: the system language).
  A module id plus options (same syntax as btw) opens that module with its
  fields filled in, and runs its check if it has one. The .desktop file
  uses this for double-clicked .tstudio files:
    btt-workbench tstudio-import %f }

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, Interfaces, Forms, Dialogs,
  WBI18n, WBModule, WBCommandLine, WBAllModules, WorkbenchForm;

var
  Args, StartOptions: TStringList;
  Lang, ErrorMsg: string;
  StartModule: TWBModule;
  I: Integer;

begin
  Args := TStringList.Create;
  StartOptions := TStringList.Create;
  try
    Lang := SystemLanguage;
    I := 1;
    while I <= ParamCount do
    begin
      if (ParamStr(I) = '--lang') and (I < ParamCount) then
      begin
        Lang := ParamStr(I + 1);
        Inc(I);
      end
      else if Copy(ParamStr(I), 1, 7) = '--lang=' then
        Lang := Copy(ParamStr(I), 8, MaxInt)
      else
        Args.Add(ParamStr(I));
      Inc(I);
    end;
    LoadLanguage(Lang);

    StartModule := nil;
    ErrorMsg := '';
    if Args.Count > 0 then
    begin
      StartModule := FindModule(Args[0]);
      if StartModule <> nil then
      begin
        Args.Delete(0);
        if not ParseModuleArgs(StartModule, Args, StartOptions, ErrorMsg) then
          StartOptions.Clear;
      end;
    end;

    Application.Scaled := True;
    Application.Initialize;
    Application.CreateForm(TWorkbenchForm, WorkbenchMain);
    if StartModule <> nil then
      WorkbenchMain.StartWith(StartModule, StartOptions);
    if ErrorMsg <> '' then
      MessageDlg(ErrorMsg, mtWarning, [mbOK], 0);
    Application.Run;
  finally
    StartOptions.Free;
    Args.Free;
  end;
end.
