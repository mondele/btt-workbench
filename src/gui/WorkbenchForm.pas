unit WorkbenchForm;

{$mode objfpc}{$H+}

{ Main window. There is no .lfm: every control is built in code from
  resourcestrings, so the whole UI is translatable through the same .po as
  the modules, and switching language just rebuilds the window.

  The option panel is generated from each module's OptionDefs, so a new
  module shows up here with no GUI code.

  Modules run on the GUI thread for now; the reporter pumps messages so
  the log stays live. Move to a worker thread once a module is slow. }

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, Graphics,
  WBReporter, WBModule;

type
  TOptionEditor = record
    Def: TWBOptionDef;
    Edit: TEdit;
    Check: TCheckBox;
  end;

  TWorkbenchForm = class(TForm)
  private
    FLangCombo: TComboBox;
    FModuleList: TListBox;
    FTitleLabel: TLabel;
    FDescLabel: TLabel;
    FOptionsPanel: TPanel;
    FRunButton: TButton;
    FLog: TMemo;
    FEditors: array of TOptionEditor;
    FLanguages: TStringArray;
    FSelected: Integer;
    procedure BuildUI;
    procedure RebuildUI(Data: PtrInt);
    procedure ShowModule(Index: Integer);
    procedure ModuleListSelectionChange(Sender: TObject; User: Boolean);
    procedure LangComboChange(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure RunClick(Sender: TObject);
  public
    constructor Create(TheOwner: TComponent); override;
  end;

var
  WorkbenchMain: TWorkbenchForm;

implementation

uses
  WBI18n, WBVersion;

resourcestring
  rsAppTitle = 'BTT Workbench';
  rsLanguage = 'Language:';
  rsModules = 'Modules';
  rsBrowse = 'Browse…';
  rsRun = 'Run';
  rsWarningPrefix = 'Warning: ';
  rsErrorPrefix = 'Error: ';
  rsFinishedOk = 'Finished.';
  rsFinishedFail = 'Finished with errors (code %d).';
  rsNoModules = 'No modules are installed.';

type
  TMemoReporter = class(TWBReporter)
  private
    FMemo: TMemo;
  public
    constructor Create(AMemo: TMemo);
    procedure Message(Level: TWBMessageLevel; const Text: string); override;
  end;

constructor TMemoReporter.Create(AMemo: TMemo);
begin
  inherited Create;
  FMemo := AMemo;
end;

procedure TMemoReporter.Message(Level: TWBMessageLevel; const Text: string);
begin
  case Level of
    mlInfo:    FMemo.Lines.Add(Text);
    mlWarning: FMemo.Lines.Add(rsWarningPrefix + Text);
    mlError:   FMemo.Lines.Add(rsErrorPrefix + Text);
  end;
  Application.ProcessMessages;
end;

{ TWorkbenchForm }

constructor TWorkbenchForm.Create(TheOwner: TComponent);
begin
  inherited CreateNew(TheOwner, 1);
  Width := 900;
  Height := 600;
  Position := poScreenCenter;
  FSelected := 0;
  BuildUI;
end;

procedure TWorkbenchForm.BuildUI;
var
  TopBar, Detail, Buttons: TPanel;
  LangLabel, ListLabel: TLabel;
  Splitter: TSplitter;
  I: Integer;
begin
  DisableAutoSizing;
  try
    Caption := rsAppTitle + ' ' + WorkbenchVersion;
    if IsRightToLeftLanguage(CurrentLanguage) then
      BiDiMode := bdRightToLeft
    else
      BiDiMode := bdLeftToRight;

    TopBar := TPanel.Create(Self);
    TopBar.Parent := Self;
    TopBar.Align := alTop;
    TopBar.AutoSize := True;
    TopBar.BevelOuter := bvNone;
    TopBar.BorderSpacing.Around := 6;

    FLangCombo := TComboBox.Create(Self);
    FLangCombo.Parent := TopBar;
    FLangCombo.Align := alRight;
    FLangCombo.Style := csDropDownList;
    FLangCombo.Width := 120;
    FLanguages := AvailableLanguages;
    for I := 0 to High(FLanguages) do
    begin
      FLangCombo.Items.Add(FLanguages[I]);
      if FLanguages[I] = CurrentLanguage then
        FLangCombo.ItemIndex := I;
    end;
    FLangCombo.OnChange := @LangComboChange;

    LangLabel := TLabel.Create(Self);
    LangLabel.Parent := TopBar;
    LangLabel.Align := alRight;
    LangLabel.Layout := tlCenter;
    LangLabel.BorderSpacing.Right := 6;
    LangLabel.Caption := rsLanguage;

    ListLabel := TLabel.Create(Self);
    ListLabel.Parent := TopBar;
    ListLabel.Align := alLeft;
    ListLabel.Layout := tlCenter;
    ListLabel.Font.Style := [fsBold];
    ListLabel.Caption := rsModules;

    FModuleList := TListBox.Create(Self);
    FModuleList.Parent := Self;
    FModuleList.Align := alLeft;
    FModuleList.Width := 240;
    FModuleList.BorderSpacing.Left := 6;
    FModuleList.BorderSpacing.Bottom := 6;
    for I := 0 to ModuleCount - 1 do
      FModuleList.Items.Add(ModuleAt(I).Title);

    Splitter := TSplitter.Create(Self);
    Splitter.Parent := Self;
    Splitter.Align := alLeft;
    Splitter.Left := FModuleList.Left + FModuleList.Width + 1;

    Detail := TPanel.Create(Self);
    Detail.Parent := Self;
    Detail.Align := alClient;
    Detail.BevelOuter := bvNone;
    Detail.BorderSpacing.Around := 6;

    FTitleLabel := TLabel.Create(Self);
    FTitleLabel.Parent := Detail;
    FTitleLabel.Align := alTop;
    FTitleLabel.Font.Style := [fsBold];
    FTitleLabel.Font.Size := 12;

    FDescLabel := TLabel.Create(Self);
    FDescLabel.Parent := Detail;
    FDescLabel.Align := alTop;
    FDescLabel.Top := 100;
    FDescLabel.WordWrap := True;
    FDescLabel.AutoSize := True;
    FDescLabel.BorderSpacing.Top := 6;
    FDescLabel.BorderSpacing.Bottom := 12;

    FOptionsPanel := TPanel.Create(Self);
    FOptionsPanel.Parent := Detail;
    FOptionsPanel.Align := alTop;
    FOptionsPanel.Top := 200;
    FOptionsPanel.AutoSize := True;
    FOptionsPanel.BevelOuter := bvNone;

    Buttons := TPanel.Create(Self);
    Buttons.Parent := Detail;
    Buttons.Align := alTop;
    Buttons.Top := 300;
    Buttons.AutoSize := True;
    Buttons.BevelOuter := bvNone;
    Buttons.BorderSpacing.Top := 6;
    Buttons.BorderSpacing.Bottom := 6;

    FRunButton := TButton.Create(Self);
    FRunButton.Parent := Buttons;
    FRunButton.Align := alLeft;
    FRunButton.AutoSize := True;
    FRunButton.Caption := rsRun;
    FRunButton.OnClick := @RunClick;

    FLog := TMemo.Create(Self);
    FLog.Parent := Detail;
    FLog.Align := alClient;
    FLog.ReadOnly := True;
    FLog.ScrollBars := ssAutoBoth;

    { alLeft/alRight do not mirror by themselves. }
    if BiDiMode = bdRightToLeft then
      FlipChildren(True);
  finally
    EnableAutoSizing;
  end;

  FModuleList.OnSelectionChange := @ModuleListSelectionChange;
  if ModuleCount = 0 then
  begin
    FTitleLabel.Caption := rsNoModules;
    FRunButton.Enabled := False;
  end
  else
  begin
    if FSelected >= ModuleCount then
      FSelected := 0;
    FModuleList.ItemIndex := FSelected;
    ShowModule(FSelected);
  end;
end;

procedure TWorkbenchForm.RebuildUI(Data: PtrInt);
begin
  while ControlCount > 0 do
    Controls[0].Free;
  FEditors := nil;
  BuildUI;
end;

procedure TWorkbenchForm.ShowModule(Index: Integer);
var
  M: TWBModule;
  Defs: TWBOptionDefs;
  Row: TPanel;
  Lbl: TLabel;
  Btn: TButton;
  I: Integer;
begin
  FSelected := Index;
  M := ModuleAt(Index);
  FTitleLabel.Caption := M.Title;
  FDescLabel.Caption := M.Description;
  FLog.Clear;

  FOptionsPanel.DisableAutoSizing;
  try
    while FOptionsPanel.ControlCount > 0 do
      FOptionsPanel.Controls[0].Free;
    Defs := M.OptionDefs;
    SetLength(FEditors, Length(Defs));
    for I := 0 to High(Defs) do
    begin
      FEditors[I].Def := Defs[I];
      FEditors[I].Edit := nil;
      FEditors[I].Check := nil;

      Row := TPanel.Create(Self);
      Row.Parent := FOptionsPanel;
      Row.Align := alTop;
      Row.Top := I * 100;          // keeps rows in declared order
      Row.AutoSize := True;
      Row.BevelOuter := bvNone;
      Row.BorderSpacing.Bottom := 4;
      Row.Hint := Defs[I].Help;
      Row.ShowHint := True;

      if Defs[I].Kind = okFlag then
      begin
        FEditors[I].Check := TCheckBox.Create(Self);
        FEditors[I].Check.Parent := Row;
        FEditors[I].Check.Align := alLeft;
        FEditors[I].Check.Caption := Defs[I].Caption;
        FEditors[I].Check.Hint := Defs[I].Help;
        FEditors[I].Check.ShowHint := True;
        Continue;
      end;

      Lbl := TLabel.Create(Self);
      Lbl.Parent := Row;
      Lbl.Align := alLeft;
      Lbl.AutoSize := False;
      Lbl.Width := 160;
      Lbl.Layout := tlCenter;
      Lbl.Caption := Defs[I].Caption;
      if Defs[I].Required then
        Lbl.Caption := Lbl.Caption + ' *';

      if Defs[I].Kind in [okDirectory, okFile] then
      begin
        Btn := TButton.Create(Self);
        Btn.Parent := Row;
        Btn.Align := alRight;
        Btn.AutoSize := True;
        Btn.BorderSpacing.Left := 4;
        Btn.Caption := rsBrowse;
        Btn.Tag := I;
        Btn.OnClick := @BrowseClick;
      end;

      FEditors[I].Edit := TEdit.Create(Self);
      FEditors[I].Edit.Parent := Row;
      FEditors[I].Edit.Align := alClient;
      FEditors[I].Edit.Hint := Defs[I].Help;
      FEditors[I].Edit.ShowHint := True;
      FEditors[I].Edit.TextHint := Defs[I].Help;
    end;
    if BiDiMode = bdRightToLeft then
      FOptionsPanel.FlipChildren(True);
  finally
    FOptionsPanel.EnableAutoSizing;
  end;
end;

procedure TWorkbenchForm.ModuleListSelectionChange(Sender: TObject; User: Boolean);
begin
  if (FModuleList.ItemIndex >= 0) and (FModuleList.ItemIndex <> FSelected) then
    ShowModule(FModuleList.ItemIndex);
end;

procedure TWorkbenchForm.LangComboChange(Sender: TObject);
begin
  if FLangCombo.ItemIndex < 0 then
    Exit;
  LoadLanguage(FLanguages[FLangCombo.ItemIndex]);
  { The combo is about to be destroyed; rebuild after this handler returns. }
  Application.QueueAsyncCall(@RebuildUI, 0);
end;

procedure TWorkbenchForm.BrowseClick(Sender: TObject);
var
  I: Integer;
  DirDlg: TSelectDirectoryDialog;
  FileDlg: TOpenDialog;
begin
  I := TComponent(Sender).Tag;
  if FEditors[I].Def.Kind = okDirectory then
  begin
    DirDlg := TSelectDirectoryDialog.Create(nil);
    try
      DirDlg.Title := FEditors[I].Def.Caption;
      if FEditors[I].Edit.Text <> '' then
        DirDlg.InitialDir := ExtractFileDir(FEditors[I].Edit.Text);
      if DirDlg.Execute then
        FEditors[I].Edit.Text := DirDlg.FileName;
    finally
      DirDlg.Free;
    end;
  end
  else
  begin
    FileDlg := TOpenDialog.Create(nil);
    try
      FileDlg.Title := FEditors[I].Def.Caption;
      if FileDlg.Execute then
        FEditors[I].Edit.Text := FileDlg.FileName;
    finally
      FileDlg.Free;
    end;
  end;
end;

procedure TWorkbenchForm.RunClick(Sender: TObject);
var
  M: TWBModule;
  Options: TStringList;
  Reporter: TMemoReporter;
  E: TOptionEditor;
  Code: Integer;
begin
  M := ModuleAt(FSelected);
  Options := TStringList.Create;
  Reporter := TMemoReporter.Create(FLog);
  FRunButton.Enabled := False;
  Screen.BeginWaitCursor;
  try
    FLog.Clear;
    for E in FEditors do
      if E.Check <> nil then
      begin
        if E.Check.Checked then
          Options.Values[E.Def.Name] := 'true';
      end
      else if Trim(E.Edit.Text) <> '' then
        Options.Values[E.Def.Name] := Trim(E.Edit.Text);
    if M.ValidateOptions(Options, Reporter) then
    begin
      Code := M.Execute(Options, Reporter);
      if Code = 0 then
        FLog.Lines.Add(rsFinishedOk)
      else
        FLog.Lines.Add(Format(rsFinishedFail, [Code]));
    end;
  finally
    Screen.EndWaitCursor;
    FRunButton.Enabled := True;
    Reporter.Free;
    Options.Free;
  end;
end;

end.
