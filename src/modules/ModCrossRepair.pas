unit ModCrossRepair;

{$mode objfpc}{$H+}

(* cross-repair: puts back chunks damaged by text copied from another book
   (what cross-check reports), one chunk file at a time (WBCrossRepair).
   The chunks to repair are a checklist found fresh each time; the check
   (dry-run) says what each would become. Each repaired project gets one
   commit listing what was done; uploading is left to wacs-upload. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TCrossRepairModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Choices(const OptionName: string; Options: TStrings;
      Reporter: TWBReporter; out List: TWBChoiceList): Boolean; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  WBDataPaths, WBProject, WBSources, WBGit, WBImport, WBCrossCheck, WBCrossScan,
  WBCrossRepair;

resourcestring
  rsTitle = 'Repair copied text';
  rsDescription = 'Puts back chunks that hold text copied from another book (as ' +
    'Text copied between books finds them): a chunk that was there before ' +
    'gets its version from before the damaging commit back, a chunk the ' +
    'damage added is removed. Everything else those commits changed stays. ' +
    'Chunks edited since are left alone. Find, check the chunks to repair, ' +
    'then Check to see what would happen. Upload afterwards with Upload to WACS.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Only these target language codes, comma-separated';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only these book codes, comma-separated';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these resources, comma-separated (reg, ulb, ...)';
  rsOptChunk = 'Chunks';
  rsOptChunkHelp = 'The damaged chunks to repair (project/chapter/chunk)';
  rsOptIncludeMixed = 'Also mixed chunks';
  rsOptIncludeMixedHelp = 'Also repair chunks whose damaging commit changed ' +
    'their own words too (those changes are undone with it)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Report what repairing would do without changing anything';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';

  rsColFrom = 'Copied from';
  rsColBy = 'Brought in by';
  rsColRepair = 'Repair';
  rsActRestore = 'restore';
  rsActRemove = 'remove';
  rsActMixed = '%s (mixed)';
  rsHoldEdited = 'leave: edited since';
  rsHoldUncommitted = 'leave: uncommitted changes';
  rsHoldNoHistory = 'leave: not in history';

  rsNoTargetDir = 'Projects folder not found: %s';
  rsNoGit = 'git was not found. BTT-Writer projects are git repositories; ' +
    'install git first.';
  rsFolder = 'Projects folder: %s';
  rsNothingChecked = 'No chunks checked.';
  rsNotFound = '%s: not damaged now (already repaired?). Skipped.';
  rsProject = 'Project %s:';
  rsRestore = '%s: restored to its version from before %s (%s, %s); it held text from %s.';
  rsWouldRestore = '%s: would be restored to its version from before %s (%s, %s); it holds text from %s.';
  rsRemove = '%s: removed; %s (%s, %s) added it with text from %s.';
  rsWouldRemove = '%s: would be removed; %s (%s, %s) added it with text from %s.';
  rsMixedNote = '%s: that commit also changed this chunk''s own words; repairing undoes them too.';
  rsMixedSkipped = '%s: left alone: that commit also changed this chunk''s own ' +
    'words, which repairing would undo. Check "Also mixed chunks" (--include-mixed) to repair it anyway.';
  rsEditedSince = '%s: left alone: changed since by %s (%s, %s). Repair it by hand.';
  rsUncommittedHold = '%s: left alone: it has changes not yet committed.';
  rsNoHistoryHold = '%s: left alone: the copied text is not in its history.';
  rsCommitFirst = 'Uncommitted work was committed first.';
  rsWouldCommitFirst = 'Uncommitted work would be committed first.';
  rsCommitted = 'Committed: %d chunk(s) repaired.';
  rsFailed = 'Repair failed (%s); the project may be partly changed: check it with git.';
  rsStillFound = '%s: still holds text from other books after the repair.';
  rsAllClean = 'Checked again: no text from other books is left in the repaired chunks.';
  rsSummary = '%d chunk(s) repaired, %d left alone.';
  rsWouldSummary = '%d chunk(s) would be repaired, %d left alone.';
  rsAfter = 'Next: upload the repaired projects (Upload to WACS). The devices that ' +
    'sent the damage must delete these projects and import them again, or ' +
    'their next upload brings the damage back.';
  rsCommitMessage = 'Repair text copied from other books (BTT Workbench)';
  rsMsgRestore = '%s: restored from before %s';
  rsMsgRemove = '%s: removed (added by %s)';

function TCrossRepairModule.Id: string;
begin
  Result := 'cross-repair';
end;

function TCrossRepairModule.Title: string;
begin
  Result := rsTitle;
end;

function TCrossRepairModule.Description: string;
begin
  Result := rsDescription;
end;

function TCrossRepairModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('language', okString, False, False, rsOptLanguage, rsOptLanguageHelp),
    OptionDef('book', okString, False, False, rsOptBook, rsOptBookHelp),
    OptionDef('type', okString, False, False, rsOptType, rsOptTypeHelp),
    ChecklistOptionDef('chunk', True, rsOptChunk, rsOptChunkHelp),
    OptionDef('include-mixed', okFlag, False, False, rsOptIncludeMixed, rsOptIncludeMixedHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp)];
end;

function TargetDirOf(Options: TStrings): string;
begin
  if Options.Values['target-dir'] <> '' then
    Result := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    Result := TargetTranslationsPath;
end;

{ Every damaged chunk the filters show, planned. }
function PlanAll(const TargetDir: string; Options: TStrings; out Items: TRepairItems;
  Reporter: TWBReporter): Boolean;
var
  Projects: TCrossProjects;
  Sources: TSourceLibrary;
  Scan: TCrossScan;
  Lang: string;
begin
  Items := nil;
  Result := False;
  if not DirectoryExists(TargetDir) then
  begin
    Reporter.Error(Format(rsNoTargetDir, [ExcludeTrailingPathDelimiter(TargetDir)]));
    Exit;
  end;
  if not GitAvailable then
  begin
    Reporter.Error(rsNoGit);
    Exit;
  end;
  Projects := ListTextProjects(TargetDir, SplitList(Options.Values['language']),
    SplitList(Options.Values['book']), SplitList(Options.Values['type']));
  Sources := TSourceLibrary.Create(LibrarySourcesPath(TargetDir), BundledSourcesPath);
  try
    for Lang in ReportLanguages(Projects) do
    begin
      Scan := ScanLanguage(TargetDir, Lang, Projects, False, Sources);
      try
        Items := Concat(Items, PlanRepairs(Scan, TargetDir));
      finally
        Scan.Free;
      end;
    end;
  finally
    Sources.Free;
  end;
  Result := True;
end;

function RepairColumn(const Item: TRepairItem): string;
begin
  case Item.Hold of
    rhEditedSince: Exit(rsHoldEdited);
    rhUncommitted: Exit(rsHoldUncommitted);
    rhNoHistory: Exit(rsHoldNoHistory);
  end;
  if Item.Action = raRestore then
    Result := rsActRestore
  else
    Result := rsActRemove;
  if Item.Mixed then
    Result := Format(rsActMixed, [Result]);
end;

function TCrossRepairModule.Choices(const OptionName: string; Options: TStrings;
  Reporter: TWBReporter; out List: TWBChoiceList): Boolean;
var
  Items: TRepairItems;
  Item: TRepairItem;
  C: TWBChoice;
begin
  List.Headers := [rsColFrom, rsColBy, rsColRepair];
  List.Items := nil;
  Result := PlanAll(TargetDirOf(Options), Options, Items, Reporter);
  if not Result then
    Exit;
  for Item in Items do
  begin
    C.Value := RepairValue(Item);
    C.Columns := [Item.Origins, Copy(Item.Commit, 1, 7) + ' ' + Item.Date + ' ' + Item.Author,
      RepairColumn(Item)];
    List.Items := Concat(List.Items, [C]);
  end;
end;

function TCrossRepairModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  TargetDir, Dir, Chunk, Msg, Failure, Project, Value: string;
  Wanted, Projects: TStringArray;
  Items, ToApply, Again: TRepairItems;
  Item: TRepairItem;
  DryRun, Mixed, All, Found, Clean: Boolean;
  Repaired, Left, I: Integer;
begin
  Result := 1;
  TargetDir := TargetDirOf(Options);
  DryRun := OptionIsSet(Options, 'dry-run');
  Mixed := OptionIsSet(Options, 'include-mixed');
  Wanted := OptionValues(Options, 'chunk');
  if Length(Wanted) = 0 then
  begin
    Reporter.Error(rsNothingChecked);
    Exit;
  end;
  Reporter.Info(Format(rsFolder, [ExcludeTrailingPathDelimiter(TargetDir)]));
  if not PlanAll(TargetDir, Options, Items, Reporter) then
    Exit;
  All := Contains(Wanted, AllChoices);
  for Value in Wanted do
    if Value <> AllChoices then
    begin
      Found := False;
      for Item in Items do
        if RepairValue(Item) = Value then
          Found := True;
      if not Found then
        Reporter.Warn(Format(rsNotFound, [Value]));
    end;

  { the projects with checked chunks, in order }
  Projects := nil;
  for Item in Items do
    if (All or Contains(Wanted, RepairValue(Item))) and not Contains(Projects, Item.Project) then
      Projects := Concat(Projects, [Item.Project]);

  Repaired := 0;
  Left := 0;
  for Project in Projects do
  begin
    Dir := TargetDir + Project + PathDelim;
    Reporter.Info('');
    Reporter.Info(Format(rsProject, [Project]));
    ToApply := nil;
    Msg := rsCommitMessage + #10;
    for Item in Items do
    begin
      if (Item.Project <> Project) or not (All or Contains(Wanted, RepairValue(Item))) then
        Continue;
      Chunk := Item.Chapter + '/' + Item.Chunk;
      case Item.Hold of
        rhEditedSince:
          begin
            Reporter.Warn(Format(rsEditedSince, [Chunk, Copy(Item.LaterCommit, 1, 7),
              Item.LaterDate, Item.LaterAuthor]));
            Inc(Left);
            Continue;
          end;
        rhUncommitted:
          begin
            Reporter.Warn(Format(rsUncommittedHold, [Chunk]));
            Inc(Left);
            Continue;
          end;
        rhNoHistory:
          begin
            Reporter.Warn(Format(rsNoHistoryHold, [Chunk]));
            Inc(Left);
            Continue;
          end;
      end;
      if Item.Mixed and not Mixed then
      begin
        Reporter.Warn(Format(rsMixedSkipped, [Chunk]));
        Inc(Left);
        Continue;
      end;
      if Item.Action = raRestore then
      begin
        if DryRun then
          Reporter.Info(Format(rsWouldRestore, [Chunk, Copy(Item.Commit, 1, 7), Item.Date,
            Item.Author, Item.Origins]))
        else
          Reporter.Info(Format(rsRestore, [Chunk, Copy(Item.Commit, 1, 7), Item.Date,
            Item.Author, Item.Origins]));
        Msg := Msg + #10 + Format(rsMsgRestore, [Chunk, Copy(Item.Commit, 1, 7)]);
      end
      else
      begin
        if DryRun then
          Reporter.Info(Format(rsWouldRemove, [Chunk, Copy(Item.Commit, 1, 7), Item.Date,
            Item.Author, Item.Origins]))
        else
          Reporter.Info(Format(rsRemove, [Chunk, Copy(Item.Commit, 1, 7), Item.Date,
            Item.Author, Item.Origins]));
        Msg := Msg + #10 + Format(rsMsgRemove, [Chunk, Copy(Item.Commit, 1, 7)]);
      end;
      if Item.Mixed then
        Reporter.Warn(Format(rsMixedNote, [Chunk]));
      ToApply := Concat(ToApply, [Item]);
    end;
    if Length(ToApply) = 0 then
      Continue;
    if DryRun then
    begin
      if IsDirty(ExcludeTrailingPathDelimiter(Dir)) then
        Reporter.Info(rsWouldCommitFirst);
      Inc(Repaired, Length(ToApply));
      Continue;
    end;
    if IsDirty(ExcludeTrailingPathDelimiter(Dir)) then
    begin
      if not CommitAll(ExcludeTrailingPathDelimiter(Dir),
        FormatDateTime('ddd mmm dd yyyy hh:nn:ss', Now)) then
      begin
        Reporter.Error(Format(rsFailed, ['git commit']));
        Continue;
      end;
      Reporter.Info(rsCommitFirst);
    end;
    if ApplyRepairs(Dir, ToApply, Msg, Failure) then
    begin
      Reporter.Info(Format(rsCommitted, [Length(ToApply)]));
      Inc(Repaired, Length(ToApply));
    end
    else
      Reporter.Error(Format(rsFailed, [Failure]));
  end;

  Reporter.Info('');
  if DryRun then
    Reporter.Info(Format(rsWouldSummary, [Repaired, Left]))
  else
  begin
    if Repaired > 0 then
    begin
      { check again: anything still found in the chunks just repaired? }
      Clean := True;
      if PlanAll(TargetDir, Options, Again, Reporter) then
        for I := 0 to High(Again) do
          if (All or Contains(Wanted, RepairValue(Again[I]))) and
             (Again[I].Hold = rhNone) and not (Again[I].Mixed and not Mixed) then
          begin
            Reporter.Warn(Format(rsStillFound, [RepairValue(Again[I])]));
            Clean := False;
          end;
      if Clean then
        Reporter.Info(rsAllClean);
    end;
    Reporter.Info(Format(rsSummary, [Repaired, Left]));
  end;
  if (Repaired > 0) and not DryRun then
    Reporter.Info(rsAfter);
  Result := 0;
end;

initialization
  RegisterModule(TCrossRepairModule.Create);

end.
