unit WorkbenchForm;

{$mode objfpc}{$H+}

{ Main window. There is no .lfm: every control is built in code from
  resourcestrings, so the whole UI is translatable through the same .po as
  the modules, and switching language just rebuilds the window.

  The option panel is generated from each module's OptionDefs, so a new
  module shows up here with no GUI code. A module's 'dry-run' flag becomes
  a Check button next to Run. StartWith opens a module with options from
  the command line and, if it has a check, runs it straight away: that is
  how a double-clicked .tstudio file lands on a preflight report.
  AddFromOtherInstance does the same for a file double-clicked while the
  window is open: it is added to the list and the check runs again.
  A Multiple file/directory option is a multi-line field, one per line.
  A password option is a masked field. A checklist option is a list with
  check boxes: Find fills it from the module's Choices using the other
  fields as filters; nothing starts checked.

  Modules run on the GUI thread for now; the reporter pumps messages so
  the log stays live. Move to a worker thread once a module is slow. }

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, Graphics,
  ComCtrls, WBReporter, WBModule;

type
  TOptionEditor = record
    Def: TWBOptionDef;
    Edit: TEdit;
    Memo: TMemo;        // Multiple options: one value per line
    Check: TCheckBox;
    Combo: TComboBox;
    List: TListView;    // checklist options
  end;

  TWorkbenchForm = class(TForm)
  private
    FLangCombo: TComboBox;
    FModuleList: TListBox;
    FTitleLabel: TLabel;
    FDescLabel: TLabel;
    FOptionsPanel: TPanel;
    FRunButton: TButton;
    FCheckButton: TButton;
    FHasCheck: Boolean;
    FLog: TMemo;
    FEditors: array of TOptionEditor;
    FLanguages: TStringArray;
    FSelected: Integer;
    FBusy: Boolean;
    FPendingModule: TWBModule;     // arrived while a module was running
    FPendingOptions: TStringList;
    procedure BuildUI;
    procedure RebuildUI(Data: PtrInt);
    procedure ShowModule(Index: Integer);
    procedure ModuleListSelectionChange(Sender: TObject; User: Boolean);
    procedure LangComboChange(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure RunClick(Sender: TObject);
    procedure AutoCheck(Data: PtrInt);
    procedure ApplyPending(Data: PtrInt);
    procedure FillFields(Options: TStrings; Append: Boolean);
    procedure CollectOptions(Options: TStrings);
    procedure FindClick(Sender: TObject);
    procedure DoFind(Index: Integer);
    procedure AutoFind(Data: PtrInt);
    { After options arrive from the command line: Find if a checklist has
      nothing checked yet (its check could only complain), else Check. }
    procedure AutoStart(Module: TWBModule; Options: TStrings);
    procedure CheckAllClick(Sender: TObject);
    procedure CheckNoneClick(Sender: TObject);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    { Select Module, fill its fields from Options, run its check if any. }
    procedure StartWith(Module: TWBModule; Options: TStrings);
    { A request from another btt-workbench process: for the module already
      shown, add its values (list options are extended) and check again;
      otherwise like StartWith. }
    procedure AddFromOtherInstance(Module: TWBModule; Options: TStrings);
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
  rsCheck = 'Check';
  rsCheckOk = 'Check finished. Nothing has been changed yet; press Run to go ahead.';
  rsCheckFail = 'Check found problems (code %d). Nothing has been changed.';
  rsWarningPrefix = 'Warning: ';
  rsErrorPrefix = 'Error: ';
  rsFinishedOk = 'Finished.';
  rsFinishedFail = 'Finished with errors (code %d).';
  rsNoModules = 'No modules are installed.';
  rsFind = 'Find';
  rsSelectAll = 'Select all';
  rsSelectNone = 'None';
  rsFound = 'Found %d item(s). Check the ones you want, then press Run.';

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
  Height := 720;
  Position := poScreenCenter;
  FSelected := 0;
  FPendingOptions := TStringList.Create;
  BuildUI;
end;

destructor TWorkbenchForm.Destroy;
begin
  FreeAndNil(FPendingOptions);
  inherited Destroy;
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

    FCheckButton := TButton.Create(Self);
    FCheckButton.Parent := Buttons;
    FCheckButton.Align := alLeft;
    FCheckButton.AutoSize := True;
    FCheckButton.Caption := rsCheck;
    FCheckButton.OnClick := @RunClick;

    FRunButton := TButton.Create(Self);
    FRunButton.Parent := Buttons;
    FRunButton.Align := alLeft;
    FRunButton.Left := 1000;     // right of Check
    FRunButton.BorderSpacing.Left := 6;
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
    FCheckButton.Visible := False;
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
  BtnHolder: TPanel;
  I, J: Integer;
begin
  FSelected := Index;
  FHasCheck := False;
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
      FEditors[I].Memo := nil;
      FEditors[I].Check := nil;
      FEditors[I].Combo := nil;
      FEditors[I].List := nil;
      if (Defs[I].Kind = okFlag) and (Defs[I].Name = 'dry-run') then
      begin
        FHasCheck := True;     // shown as the Check button, not a checkbox
        Continue;
      end;

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

      if Defs[I].Kind = okChoice then
      begin
        FEditors[I].Combo := TComboBox.Create(Self);
        FEditors[I].Combo.Parent := Row;
        FEditors[I].Combo.Align := alLeft;
        FEditors[I].Combo.Left := 1000;  // right of the label (alLeft orders by Left)
        FEditors[I].Combo.Width := 200;
        FEditors[I].Combo.Style := csDropDownList;
        FEditors[I].Combo.Hint := Defs[I].Help;
        FEditors[I].Combo.ShowHint := True;
        for J := 0 to High(Defs[I].Choices) do
        begin
          FEditors[I].Combo.Items.Add(Defs[I].Choices[J]);
          if Defs[I].Choices[J] = Defs[I].Default then
            FEditors[I].Combo.ItemIndex := J;
        end;
        Continue;
      end;

      if Defs[I].Kind = okChecklist then
      begin
        Row.AutoSize := False;
        Row.Height := 220;
        Lbl.Layout := tlTop;
        BtnHolder := TPanel.Create(Self);
        BtnHolder.Parent := Row;
        BtnHolder.Align := alRight;
        BtnHolder.AutoSize := True;
        BtnHolder.BevelOuter := bvNone;
        BtnHolder.BorderSpacing.Left := 4;
        Btn := TButton.Create(Self);
        Btn.Parent := BtnHolder;
        Btn.Align := alTop;
        Btn.AutoSize := True;
        Btn.Caption := rsFind;
        Btn.Tag := I;
        Btn.OnClick := @FindClick;
        Btn := TButton.Create(Self);
        Btn.Parent := BtnHolder;
        Btn.Align := alTop;
        Btn.Top := 100;
        Btn.AutoSize := True;
        Btn.BorderSpacing.Top := 4;
        Btn.Caption := rsSelectAll;
        Btn.Tag := I;
        Btn.OnClick := @CheckAllClick;
        Btn := TButton.Create(Self);
        Btn.Parent := BtnHolder;
        Btn.Align := alTop;
        Btn.Top := 200;
        Btn.AutoSize := True;
        Btn.BorderSpacing.Top := 4;
        Btn.Caption := rsSelectNone;
        Btn.Tag := I;
        Btn.OnClick := @CheckNoneClick;
        FEditors[I].List := TListView.Create(Self);
        FEditors[I].List.Parent := Row;
        FEditors[I].List.Align := alClient;
        FEditors[I].List.ViewStyle := vsReport;
        FEditors[I].List.Checkboxes := True;
        FEditors[I].List.RowSelect := True;
        FEditors[I].List.ReadOnly := True;
        FEditors[I].List.Hint := Defs[I].Help;
        FEditors[I].List.ShowHint := True;
        FEditors[I].List.Columns.Add.Caption := Defs[I].Caption;
        Continue;
      end;

      if Defs[I].Multiple then
      begin
        Row.AutoSize := False;
        Row.Height := 96;
        Lbl.Layout := tlTop;
        BtnHolder := TPanel.Create(Self);
        BtnHolder.Parent := Row;
        BtnHolder.Align := alRight;
        BtnHolder.AutoSize := True;
        BtnHolder.BevelOuter := bvNone;
        BtnHolder.BorderSpacing.Left := 4;
        if Defs[I].Kind in [okDirectory, okFile] then
        begin
          Btn := TButton.Create(Self);
          Btn.Parent := BtnHolder;
          Btn.Align := alTop;
          Btn.AutoSize := True;
          Btn.Caption := rsBrowse;
          Btn.Tag := I;
          Btn.OnClick := @BrowseClick;
        end;
        FEditors[I].Memo := TMemo.Create(Self);
        FEditors[I].Memo.Parent := Row;
        FEditors[I].Memo.Align := alClient;
        FEditors[I].Memo.ScrollBars := ssAutoBoth;
        FEditors[I].Memo.WordWrap := False;
        FEditors[I].Memo.Hint := Defs[I].Help;
        FEditors[I].Memo.ShowHint := True;
        Continue;
      end;

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
      if Defs[I].Kind = okPassword then
        FEditors[I].Edit.PasswordChar := '*';
    end;
    if BiDiMode = bdRightToLeft then
      FOptionsPanel.FlipChildren(True);
  finally
    FOptionsPanel.EnableAutoSizing;
  end;
  FCheckButton.Visible := FHasCheck;
end;

procedure TWorkbenchForm.FillFields(Options: TStrings; Append: Boolean);
var
  I, J: Integer;
  Value, V: string;
begin
  for I := 0 to High(FEditors) do
  begin
    Value := Options.Values[FEditors[I].Def.Name];
    if Value = '' then
      Continue;
    if FEditors[I].List <> nil then
    begin
      if not Append then
        FEditors[I].List.Items.Clear;
      for V in OptionValues(Options, FEditors[I].Def.Name) do
        if (V <> AllChoices) and (FEditors[I].List.FindCaption(0, V, False, True, False) = nil) then
          FEditors[I].List.Items.Add.Caption := V;
      for J := 0 to FEditors[I].List.Items.Count - 1 do
        if Pos(#10 + FEditors[I].List.Items[J].Caption + #10, #10 + Value + #10) > 0 then
          FEditors[I].List.Items[J].Checked := True;
    end
    else if FEditors[I].Memo <> nil then
    begin
      if not Append then
        FEditors[I].Memo.Clear;
      for V in OptionValues(Options, FEditors[I].Def.Name) do
        if FEditors[I].Memo.Lines.IndexOf(V) < 0 then
          FEditors[I].Memo.Lines.Add(V);
    end
    else if FEditors[I].Edit <> nil then
      FEditors[I].Edit.Text := Value
    else if FEditors[I].Check <> nil then
      FEditors[I].Check.Checked := OptionIsSet(Options, FEditors[I].Def.Name)
    else if FEditors[I].Combo <> nil then
      FEditors[I].Combo.ItemIndex := FEditors[I].Combo.Items.IndexOf(Value);
  end;
end;

procedure TWorkbenchForm.StartWith(Module: TWBModule; Options: TStrings);
var
  I, Idx: Integer;
begin
  Idx := -1;
  for I := 0 to ModuleCount - 1 do
    if ModuleAt(I) = Module then
      Idx := I;
  if Idx < 0 then
    Exit;
  FModuleList.ItemIndex := Idx;
  ShowModule(Idx);
  FillFields(Options, False);
  AutoStart(Module, Options);
end;

procedure TWorkbenchForm.AddFromOtherInstance(Module: TWBModule; Options: TStrings);
var
  Def: TWBOptionDef;
  V: string;
begin
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  ShowOnTop;
  if FBusy then
  begin
    { Keep it until the running module finishes (RunClick picks it up). }
    if FPendingModule <> Module then
      FPendingOptions.Clear;
    FPendingModule := Module;
    for Def in Module.OptionDefs do
      if Def.Multiple then
      begin
        for V in OptionValues(Options, Def.Name) do
          AddOptionValue(FPendingOptions, Def.Name, V);
      end
      else if Options.Values[Def.Name] <> '' then
        FPendingOptions.Values[Def.Name] := Options.Values[Def.Name];
    Exit;
  end;
  if (ModuleCount = 0) or (ModuleAt(FSelected) <> Module) then
  begin
    StartWith(Module, Options);
    Exit;
  end;
  FillFields(Options, True);
  AutoStart(Module, Options);
end;

procedure TWorkbenchForm.ApplyPending(Data: PtrInt);
var
  Module: TWBModule;
  Options: TStringList;
begin
  if FPendingModule = nil then
    Exit;
  Module := FPendingModule;
  Options := TStringList.Create;
  try
    Options.Assign(FPendingOptions);
    FPendingModule := nil;
    FPendingOptions.Clear;
    AddFromOtherInstance(Module, Options);
  finally
    Options.Free;
  end;
end;

procedure TWorkbenchForm.AutoCheck(Data: PtrInt);
begin
  RunClick(FCheckButton);
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
  J: Integer;
begin
  I := TComponent(Sender).Tag;
  if FEditors[I].Memo <> nil then
  begin
    { List: add the chosen files (or folder) to the end. }
    if FEditors[I].Def.Kind = okDirectory then
    begin
      DirDlg := TSelectDirectoryDialog.Create(nil);
      try
        DirDlg.Title := FEditors[I].Def.Caption;
        if DirDlg.Execute and (FEditors[I].Memo.Lines.IndexOf(DirDlg.FileName) < 0) then
          FEditors[I].Memo.Lines.Add(DirDlg.FileName);
      finally
        DirDlg.Free;
      end;
    end
    else
    begin
      FileDlg := TOpenDialog.Create(nil);
      try
        FileDlg.Title := FEditors[I].Def.Caption;
        FileDlg.Options := FileDlg.Options + [ofAllowMultiSelect];
        if FileDlg.Execute then
          for J := 0 to FileDlg.Files.Count - 1 do
            if FEditors[I].Memo.Lines.IndexOf(FileDlg.Files[J]) < 0 then
              FEditors[I].Memo.Lines.Add(FileDlg.Files[J]);
      finally
        FileDlg.Free;
      end;
    end;
    Exit;
  end;
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

{ The fields as name=value options: checked list items, memo lines, ... }
procedure TWorkbenchForm.CollectOptions(Options: TStrings);
var
  E: TOptionEditor;
  Line: string;
  J: Integer;
begin
  for E in FEditors do
    if E.List <> nil then
    begin
      for J := 0 to E.List.Items.Count - 1 do
        if E.List.Items[J].Checked then
          AddOptionValue(Options, E.Def.Name, E.List.Items[J].Caption);
    end
    else if E.Check <> nil then
    begin
      if E.Check.Checked then
        Options.Values[E.Def.Name] := 'true';
    end
    else if E.Memo <> nil then
    begin
      for Line in E.Memo.Lines do
        if Trim(Line) <> '' then
          AddOptionValue(Options, E.Def.Name, Trim(Line));
    end
    else if E.Combo <> nil then
    begin
      if E.Combo.ItemIndex >= 0 then
        Options.Values[E.Def.Name] := E.Combo.Items[E.Combo.ItemIndex];
    end
    else if (E.Edit <> nil) and (Trim(E.Edit.Text) <> '') then
    begin
      if E.Def.Kind = okPassword then
        Options.Values[E.Def.Name] := E.Edit.Text   // spaces may be part of it
      else
        Options.Values[E.Def.Name] := Trim(E.Edit.Text);
    end;
end;

{ Fill a checklist from the module's Choices; checked items stay checked. }
procedure TWorkbenchForm.FindClick(Sender: TObject);
begin
  DoFind(TComponent(Sender).Tag);
end;

procedure TWorkbenchForm.AutoFind(Data: PtrInt);
begin
  DoFind(Data);
end;

procedure TWorkbenchForm.AutoStart(Module: TWBModule; Options: TStrings);
var
  I: Integer;
begin
  for I := 0 to High(FEditors) do
    if (FEditors[I].List <> nil) and (FEditors[I].List.Items.Count = 0) then
    begin
      Application.QueueAsyncCall(@AutoFind, I);
      Exit;
    end;
  if FHasCheck then
    Application.QueueAsyncCall(@AutoCheck, 0);
end;

procedure TWorkbenchForm.DoFind(Index: Integer);
var
  I, J: Integer;
  M: TWBModule;
  Options: TStringList;
  Reporter: TMemoReporter;
  List: TWBChoiceList;
  View: TListView;
  Checked: TStringList;
  Item: TListItem;
  S: string;
begin
  if FBusy then
    Exit;
  FBusy := True;
  I := Index;
  View := FEditors[I].List;
  M := ModuleAt(FSelected);
  Options := TStringList.Create;
  Checked := TStringList.Create;
  Reporter := TMemoReporter.Create(FLog);
  FRunButton.Enabled := False;
  FCheckButton.Enabled := False;
  Screen.BeginWaitCursor;
  try
    FLog.Clear;
    CollectOptions(Options);
    for J := 0 to View.Items.Count - 1 do
      if View.Items[J].Checked then
        Checked.Add(View.Items[J].Caption);
    if M.Choices(FEditors[I].Def.Name, Options, Reporter, List) then
    begin
      View.BeginUpdate;
      try
        View.Items.Clear;
        while View.Columns.Count > 1 do
          View.Columns.Delete(View.Columns.Count - 1);
        for S in List.Headers do
          View.Columns.Add.Caption := S;
        for J := 0 to High(List.Items) do
        begin
          Item := View.Items.Add;
          Item.Caption := List.Items[J].Value;
          for S in List.Items[J].Columns do
            Item.SubItems.Add(S);
          Item.Checked := Checked.IndexOf(List.Items[J].Value) >= 0;
        end;
        for J := 0 to View.Columns.Count - 1 do
          View.Columns[J].AutoSize := True;
      finally
        View.EndUpdate;
      end;
      FLog.Lines.Add(Format(rsFound, [Length(List.Items)]));
    end;
  finally
    Screen.EndWaitCursor;
    FRunButton.Enabled := True;
    FCheckButton.Enabled := True;
    Reporter.Free;
    Checked.Free;
    Options.Free;
    FBusy := False;
  end;
end;

procedure TWorkbenchForm.CheckAllClick(Sender: TObject);
var
  J: Integer;
begin
  with FEditors[TComponent(Sender).Tag] do
    for J := 0 to List.Items.Count - 1 do
      List.Items[J].Checked := True;
end;

procedure TWorkbenchForm.CheckNoneClick(Sender: TObject);
var
  J: Integer;
begin
  with FEditors[TComponent(Sender).Tag] do
    for J := 0 to List.Items.Count - 1 do
      List.Items[J].Checked := False;
end;

procedure TWorkbenchForm.RunClick(Sender: TObject);
var
  M: TWBModule;
  Options: TStringList;
  Reporter: TMemoReporter;
  Code: Integer;
  IsCheck: Boolean;
begin
  if FBusy then
    Exit;
  FBusy := True;
  IsCheck := Sender = FCheckButton;
  M := ModuleAt(FSelected);
  Options := TStringList.Create;
  Reporter := TMemoReporter.Create(FLog);
  FRunButton.Enabled := False;
  FCheckButton.Enabled := False;
  Screen.BeginWaitCursor;
  try
    FLog.Clear;
    CollectOptions(Options);
    if IsCheck then
      Options.Values['dry-run'] := 'true';
    if M.ValidateOptions(Options, Reporter) then
    begin
      Code := M.Execute(Options, Reporter);
      FLog.Lines.Add('');
      if IsCheck and (Code = 0) then
        FLog.Lines.Add(rsCheckOk)
      else if IsCheck then
        FLog.Lines.Add(Format(rsCheckFail, [Code]))
      else if Code = 0 then
        FLog.Lines.Add(rsFinishedOk)
      else
        FLog.Lines.Add(Format(rsFinishedFail, [Code]));
    end;
  finally
    Screen.EndWaitCursor;
    FRunButton.Enabled := True;
    FCheckButton.Enabled := True;
    Reporter.Free;
    Options.Free;
    FBusy := False;
  end;
  if FPendingModule <> nil then
    Application.QueueAsyncCall(@ApplyPending, 0);
end;

end.
