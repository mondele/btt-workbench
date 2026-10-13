unit WBImport;

{$mode objfpc}{$H+}

(* Bringing a copy of a project (from a .tstudio package, or later a WACS
   repo) into targetTranslations: place it if new, else check and merge or
   overwrite, as BTT-Writer Desktop 1.6.0 does. Shared by the modules that
   import. See ModTStudioImport for the BTT-Writer rules followed:
   project format 8 (v7 upgraded), branch master, merge by commit hash with
   Desktop-readable conflict markers committed, overwrite keeping a backup,
   and a preflight (git merge-tree in a throwaway shared bare clone) that
   never touches the existing project. With Simulate, a check of several
   incoming copies runs each against a scratch copy of the project as the
   earlier ones would leave it. *)

interface

uses
  Classes, SysUtils, fpjson, WBGit, WBReporter;

const
  ProjectManifestVersion = 8;

type
  TMergeKind = (mkUpToDate, mkFastForward, mkClean, mkConflicts);

  TPreflight = record
    Kind: TMergeKind;
    Unrelated: Boolean;
    ConflictPaths: TStringArray;
  end;

  TImportContext = record
    SourceLabel: string;  // what is being imported, for messages and commits
    TargetDir: string;
    WorkRoot: string;     // this copy's scratch folder (preflight clones)
    SimRoot: string;      // check of several copies: projects as imported so far
    BackupRoot: string;
    OnExisting: string;   // stop, merge, overwrite
    OnConflict: string;   // merge that would conflict: 'skip' it, else commit markers
    FromServer: Boolean;  // a WACS repo, not a package (wording only)
    DryRun: Boolean;
    Simulate: Boolean;    // DryRun with more than one incoming copy
    Reporter: TWBReporter;
  end;

{ Non-empty trimmed lines. }
function Lines(const Text: string): TStringArray;
function IsDirty(const RepoDir: string): Boolean;
function IsRepo(const Dir: string): Boolean;
{ git add --all and commit, with a fallback identity if none is set. }
function CommitAll(const RepoDir, Message: string): Boolean;
function RunGitCommitting(const RepoDir: string; const Args: array of string): TGitResult;
function MigrateV7(Manifest: TJSONObject): Boolean;
function MergeManifests(Local, Imported: TJSONObject;
  const Conflicted: TStringArray): TJSONObject;
function AnalyzeMerge(const LocalDir, ImportedDir, ScratchDir: string;
  out Info: TPreflight; out ErrorMsg: string): Boolean;
procedure ReportConflicts(const Info: TPreflight; const LocalDir: string;
  LocalManifest: TJSONObject; Reporter: TWBReporter);
function DoMerge(const Ctx: TImportContext; const LocalDir, ImportedDir: string;
  var LocalManifest: TJSONObject; ImportedManifest: TJSONObject): Integer;
function DoOverwrite(const Ctx: TImportContext; const LocalDir, ImportedDir: string): Integer;
{ The project folder Src (a git repo with manifest.json, ours to change)
  into Ctx.TargetDir. EntryPath names it in messages. 0 OK, 1 failed. }
function ImportProject(const Ctx: TImportContext; const Src, EntryPath: string): Integer;
{ Scratch session folder and backup folder next to the projects folder, on
  the same disk, so moving a project into place is a rename. }
function ImportSessionRoot(const TargetDir: string): string;
function ImportBackupRoot(const TargetDir: string): string;
{ Moves a project on git branch main to master, the only branch BTT-Writer
  uses (gitnative.js: git init -b master, pull and push master by name).
  Refuses when both exist; reports other branches and a detached HEAD.
  True if it was moved, or would be with DryRun. }
function FixBranch(const Dir: string; DryRun: Boolean; R: TWBReporter): Boolean;

implementation

uses
  WBJson, WBFiles, WBProject;

resourcestring
  rsBranchRenamed = 'The git branch was main; moved it to master, the only ' +
    'branch BTT-Writer uses.';
  rsBranchWouldRename = 'The git branch is main, but BTT-Writer only uses ' +
    'master; it would be moved to master (dry run).';
  rsBranchBoth = 'The project is on git branch main, and a master branch ' +
    'exists too; not changed. BTT-Writer only uses master, so merge main into ' +
    'master by hand.';
  rsBranchOther = 'The git branch is %s, not master; BTT-Writer only uses master.';
  rsDetached = 'git is not on any branch (detached HEAD); BTT-Writer only uses master.';
  rsBranchFailed = 'Could not move the git branch from main to master: %s';
  rsBadEntryPath = 'Project entry has an unsafe or missing path: "%s". Skipped.';
  rsNoProjectManifest = '%s has no manifest.json. Skipped.';
  rsBadProjectManifest = '%s: manifest.json could not be read (%s). Skipped.';
  rsOldProjectVersion = '%s is an older project format (version %s). Import it ' +
    'with BTT-Writer, which can upgrade it. Skipped.';
  rsMigratedV7 = 'Upgraded the project format from version 7 to 8, as BTT-Writer does.';
  rsRenamedBranch = 'Renamed the package''s branch "%s" to "master", which BTT-Writer expects.';
  rsNewProjectVersion = '%s uses a newer project format (version %s) than this ' +
    'tool knows. Skipped.';
  rsNoGitRepo = '%s has no git history in the package. Skipped.';
  rsProject = 'Project %s: %s, %s (last change %s).';
  rsPackageDirty = 'The package had uncommitted changes; they were committed in ' +
    'the temporary copy.';
  rsNewProject = 'New project: will be added as %s.';
  rsAdded = 'Imported %s.';
  rsExists = 'A project named %s already exists.';
  rsLocalNotRepo = 'The existing %s is not a git repository, so it cannot be ' +
    'merged. Use overwrite (the old copy is backed up) or fix it first.';
  rsLocalMidMerge = 'The existing %s has an unfinished merge. Finish or abort ' +
    'it in BTT-Writer first. Nothing changed.';
  rsLocalDirty = 'The existing project has uncommitted changes. A merge will ' +
    'commit them first; the conflict list below does not include them.';
  rsUpToDate = 'The existing project already contains everything in the ' +
    'package. Nothing to import.';
  rsFastForward = 'The package only adds newer work to the existing project. ' +
    'A merge will have no conflicts.';
  rsCleanMerge = 'Both copies have changes. A merge will combine them with ' +
    'no conflicts.';
  rsUnrelated = 'The two copies were started separately (no shared history), ' +
    'so every chunk that differs will conflict.';
  rsConflictCount = 'A merge would leave %d chunk(s) in conflict, to be ' +
    'resolved in BTT-Writer: %s';
  rsConflictFiles = 'Other files in conflict: %s';
  rsReopened = 'These finished chunks would be marked unfinished again: %s';
  rsManifestMerged = 'manifest.json differs; it is merged automatically ' +
    '(translators and finished chunks are combined).';
  rsChooseAction = 'To import it, choose merge or overwrite.';
  rsStopped = '%s already exists. Choose merge or overwrite to import it. ' +
    'Nothing changed.';
  rsPreflightFailed = 'Could not check the merge: %s';
  rsSnapshot = 'Committed uncommitted changes in the existing project first.';
  rsMerged = 'Merged into %s.';
  rsMergedConflicts = 'Merged into %s with %d chunk(s) in conflict. Open the ' +
    'project in BTT-Writer to choose between the versions.';
  rsMergeFailed = 'Merge failed: %s. The existing project was left as it was.';
  rsBackedUp = 'The existing project was moved to %s.';
  rsOverwritten = 'Replaced %s with the imported copy.';
  rsMoveFailed = 'Could not move %s to %s. Nothing changed.';
  rsExistsEarlier = '%s is also in an earlier package; checking against that ' +
    'result.';
  rsStacked = 'These chunks already have an unresolved conflict, so the ' +
    'conflicts will stack. BTT-Writer will offer every version to choose ' +
    'from: %s';
  rsRenamedBranchRepo = 'Renamed the downloaded branch "%s" to "master", which ' +
    'BTT-Writer expects.';
  rsNoGitRepoRepo = '%s has no git history on the server. Skipped.';
  rsRepoDirty = 'The downloaded copy had uncommitted changes; they were ' +
    'committed in the temporary copy.';
  rsUpToDateRepo = 'The existing project already contains everything in the ' +
    'server copy. Nothing to download.';
  rsFastForwardRepo = 'The server copy only adds newer work to the existing ' +
    'project. A merge will have no conflicts.';
  rsExistsEarlierRepo = '%s is also in an earlier repo; checking against that result.';
  rsSimulateFailedRepo = 'Could not simulate downloading %s; checks of later ' +
    'repos for this project may be incomplete.';
  rsWouldSkipConflicts = '%s would not be merged, because it would leave ' +
    'conflicts and conflicts are set to skip.';
  rsSkippedConflicts = '%s was not merged, because it would leave conflicts ' +
    '(conflicts are set to skip). The existing project was not changed.';
  rsSimulateFailed = 'Could not simulate importing %s; checks of later ' +
    'packages for this project may be incomplete.';

const
  WorkbenchIdentity: array[0..3] of string =
    ('-c', 'user.name=BTT Workbench', '-c', 'user.email=btt-workbench@localhost');

{ --- small helpers --- }

function JoinNames(const Items: TStringArray): string;
begin
  Result := String.Join(', ', Items);
end;

{ Package or server wording. }
function Pick(const Ctx: TImportContext; const ForPackage, ForRepo: string): string;
begin
  if Ctx.FromServer then
    Result := ForRepo
  else
    Result := ForPackage;
end;

function Lines(const Text: string): TStringArray;
var
  L: string;
begin
  Result := nil;
  for L in Text.Split([#10]) do
    if Trim(L) <> '' then
      Result := Concat(Result, [Trim(L)]);
end;

{ Local manifest as base; translators and finished_chunks are the union
  (local order first); conflicted chunks are removed from finished_chunks.
  Same rules as Desktop's gitnative.merge. }
const
  { A typed array: a bare ['a', 'bb'] literal in for-in becomes fixed-length
    short strings sized to the first item, truncating the rest. }
  MergedLists: array[0..1] of string = ('translators', 'finished_chunks');

function MergeManifests(Local, Imported: TJSONObject;
  const Conflicted: TStringArray): TJSONObject;
var
  Key, S: string;
  Merged: TStringArray;
  Arr: TJSONArray;
begin
  Result := TJSONObject(Local.Clone);
  for Key in MergedLists do
  begin
    Merged := StringsOf(Local.Find(Key));
    for S in StringsOf(Imported.Find(Key)) do
      if not Contains(Merged, S) then
        Merged := Concat(Merged, [S]);
    Arr := TJSONArray.Create;
    for S in Merged do
      if (Key <> 'finished_chunks') or not Contains(Conflicted, S) then
        Arr.Add(S);
    if Result.IndexOfName(Key) >= 0 then
      Result.Elements[Key] := Arr     // in place: keeps the key order
    else
      Result.Add(Key, Arr);
  end;
end;

function CommitDate(const RepoDir: string): string;
var
  R: TGitResult;
begin
  R := RunGit(RepoDir, ['log', '-1', '--format=%cs']);
  Result := Trim(R.Output);
  if Result = '' then
    Result := '?';
end;

function HasIdentity(const RepoDir: string): Boolean;
begin
  Result := Trim(RunGit(RepoDir, ['config', 'user.email']).Output) <> '';
end;

{ git <identity if missing> <Args>: commits must not fail just because
  this machine has no git user configured. }
function RunGitCommitting(const RepoDir: string; const Args: array of string): TGitResult;
var
  All: array of string;
  I, N: Integer;
begin
  All := nil;
  if not HasIdentity(RepoDir) then
    for I := 0 to High(WorkbenchIdentity) do
      All := Concat(All, [WorkbenchIdentity[I]]);
  N := Length(All);
  SetLength(All, N + Length(Args));
  for I := 0 to High(Args) do
    All[N + I] := Args[I];
  Result := RunGit(RepoDir, All);
end;

function IsDirty(const RepoDir: string): Boolean;
begin
  Result := Trim(RunGit(RepoDir, ['status', '--porcelain']).Output) <> '';
end;

function IsRepo(const Dir: string): Boolean;
begin
  Result := DirectoryExists(Dir + PathDelim + '.git') and
    (RunGit(Dir, ['rev-parse', '--verify', 'HEAD']).ExitCode = 0);
end;

function CommitAll(const RepoDir, Message: string): Boolean;
var
  R: TGitResult;
begin
  R := RunGit(RepoDir, ['add', '--all']);
  if R.ExitCode <> 0 then
    Exit(False);
  R := RunGitCommitting(RepoDir, ['commit', '-q', '-m', Message]);
  Result := R.ExitCode = 0;
end;

{ Desktop 1.6.0 migrateV7 (migrator.js): fill resource.name, default
  source_translations, bump to 8. Returns True if it changed anything. }
function MigrateV7(Manifest: TJSONObject): Boolean;
var
  Res: TJSONData;
  Id, Name: string;
begin
  Result := False;
  if StrToIntDef(StrField(Manifest, 'package_version'), 0) <> 7 then
    Exit;
  if Manifest.Find('source_translations') = nil then
    Manifest.Add('source_translations', TJSONObject.Create);
  Res := Manifest.Find('resource');
  if Res is TJSONObject then
  begin
    Id := TJSONObject(Res).Get('id', '');
    Name := TJSONObject(Res).Get('name', '');
    if Name = '' then
    begin
      if Id = 'reg' then Name := 'Regular'
      else if (Id = 'ulb') or (Id = 'udb') then Name := 'Unlocked Literal Bible'
      else if Id = 'obs' then Name := 'Open Bible Stories'
      else Name := Id;
      TJSONObject(Res).Strings['name'] := Name;
    end;
  end;
  Manifest.Integers['package_version'] := 8;
  Result := True;
end;

{ --- preflight --- }

function AnalyzeMerge(const LocalDir, ImportedDir, ScratchDir: string;
  out Info: TPreflight; out ErrorMsg: string): Boolean;
var
  R: TGitResult;
  Bare: string;
  OutLines: TStringArray;
  I: Integer;
begin
  Result := False;
  ErrorMsg := '';
  Info.Kind := mkClean;
  Info.Unrelated := False;
  Info.ConflictPaths := nil;
  Bare := ScratchDir + PathDelim + 'preflight.git';

  R := RunGit(ScratchDir, ['clone', '-q', '--bare', '--shared', '--no-tags', LocalDir, Bare]);
  if R.ExitCode <> 0 then
  begin
    ErrorMsg := Trim(R.ErrorOutput);
    Exit;
  end;
  try
    R := RunGit(Bare, ['fetch', '-q', '--no-tags', ImportedDir, 'HEAD']);
    if R.ExitCode <> 0 then
    begin
      ErrorMsg := Trim(R.ErrorOutput);
      Exit;
    end;
    if RunGit(Bare, ['merge-base', '--is-ancestor', 'FETCH_HEAD', 'HEAD']).ExitCode = 0 then
      Info.Kind := mkUpToDate
    else if RunGit(Bare, ['merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD']).ExitCode = 0 then
      Info.Kind := mkFastForward
    else
    begin
      Info.Unrelated := RunGit(Bare, ['merge-base', 'HEAD', 'FETCH_HEAD']).ExitCode <> 0;
      R := RunGit(Bare, ['-c', 'merge.conflictStyle=merge', 'merge-tree', '--write-tree',
        '--name-only', '--no-messages', '--allow-unrelated-histories', 'HEAD', 'FETCH_HEAD']);
      if not (R.ExitCode in [0, 1]) then
      begin
        ErrorMsg := Trim(R.ErrorOutput);
        Exit;
      end;
      if R.ExitCode = 1 then
      begin
        Info.Kind := mkConflicts;
        OutLines := Lines(R.Output);
        for I := 1 to High(OutLines) do      // line 0 is the tree id
          if not Contains(Info.ConflictPaths, OutLines[I]) then
            Info.ConflictPaths := Concat(Info.ConflictPaths, [OutLines[I]]);
      end;
    end;
    Result := True;
  finally
    DeleteTree(Bare);
  end;
end;

procedure ReportConflicts(const Info: TPreflight; const LocalDir: string;
  LocalManifest: TJSONObject; Reporter: TWBReporter);
var
  P, C: string;
  Chunks, Others, Reopened, Stacked: TStringArray;
  Finished: TStringArray;
begin
  Chunks := nil;
  Others := nil;
  Reopened := nil;
  Stacked := nil;
  Finished := StringsOf(LocalManifest.Find('finished_chunks'));
  for P in Info.ConflictPaths do
  begin
    if P = 'manifest.json' then
      Continue;
    C := ChunkIdFromPath(P);
    if C <> '' then
    begin
      Chunks := Concat(Chunks, [C]);
      if Contains(Finished, C) then
        Reopened := Concat(Reopened, [C]);
      if HasConflictMarkers(LocalDir + PathDelim + SetDirSeparators(P)) then
        Stacked := Concat(Stacked, [C]);
    end
    else
      Others := Concat(Others, [P]);
  end;
  if Contains(Info.ConflictPaths, 'manifest.json') then
    Reporter.Info(rsManifestMerged);
  if Length(Chunks) > 0 then
    Reporter.Warn(Format(rsConflictCount, [Length(Chunks), JoinNames(Chunks)]));
  if Length(Others) > 0 then
    Reporter.Warn(Format(rsConflictFiles, [JoinNames(Others)]));
  if Length(Reopened) > 0 then
    Reporter.Warn(Format(rsReopened, [JoinNames(Reopened)]));
  if Length(Stacked) > 0 then
    Reporter.Warn(Format(rsStacked, [JoinNames(Stacked)]));
end;

{ --- actions --- }

function DoMerge(const Ctx: TImportContext; const LocalDir, ImportedDir: string;
  var LocalManifest: TJSONObject; ImportedManifest: TJSONObject): Integer;
var
  R: TGitResult;
  Sha, Name: string;
  Conflicted, ChunkIds: TStringArray;
  P, C: string;
  Merged: TJSONObject;
begin
  Result := 1;
  Name := ExtractFileName(LocalDir);
  if IsDirty(LocalDir) then
  begin
    if not CommitAll(LocalDir, 'Snapshot before import') then
    begin
      Ctx.Reporter.Error(Format(rsMergeFailed, ['git commit']));
      Exit;
    end;
    Ctx.Reporter.Info(rsSnapshot);
    FreeAndNil(LocalManifest);  // re-read: the snapshot may include manifest edits
    LocalManifest := ReadJSONObjectFile(LocalDir + PathDelim + 'manifest.json');
  end;

  Sha := Trim(RunGit(ImportedDir, ['rev-parse', 'HEAD']).Output);
  R := RunGit(LocalDir, ['fetch', '-q', '--no-tags', ImportedDir, 'HEAD']);
  if R.ExitCode <> 0 then
  begin
    Ctx.Reporter.Error(Format(rsMergeFailed, [Trim(R.ErrorOutput)]));
    Exit;
  end;

  { Merging the full hash makes the theirs marker ">>>>>>> <sha>". }
  R := RunGitCommitting(LocalDir, ['-c', 'merge.conflictStyle=merge',
    '-c', 'core.autocrlf=input', 'merge', '-q', '--no-edit',
    '--allow-unrelated-histories', '-m',
    'Import ' + Ctx.SourceLabel, Sha]);
  Conflicted := Lines(RunGit(LocalDir, ['diff', '--name-only', '--diff-filter=U']).Output);
  if (R.ExitCode <> 0) and (Length(Conflicted) = 0) then
  begin
    RunGit(LocalDir, ['merge', '--abort']);
    Ctx.Reporter.Error(Format(rsMergeFailed, [Trim(R.ErrorOutput + ' ' + R.Output)]));
    Exit;
  end;

  ChunkIds := nil;
  for P in Conflicted do
  begin
    C := ChunkIdFromPath(P);
    if C <> '' then
      ChunkIds := Concat(ChunkIds, [C]);
  end;

  Merged := MergeManifests(LocalManifest, ImportedManifest, ChunkIds);
  try
    WriteBttJSONFile(LocalDir + PathDelim + 'manifest.json', Merged);
  finally
    Merged.Free;
  end;

  { Commit everything, markers included, as Desktop does. Harmless no-op
    when the merge already committed and the manifest did not change. }
  if (Length(Conflicted) > 0) or IsDirty(LocalDir) then
    if not CommitAll(LocalDir, 'Import ' + Ctx.SourceLabel) then
    begin
      Ctx.Reporter.Error(Format(rsMergeFailed, ['git commit']));
      Exit;
    end;

  if Length(ChunkIds) > 0 then
    Ctx.Reporter.Warn(Format(rsMergedConflicts, [Name, Length(ChunkIds)]))
  else
    Ctx.Reporter.Info(Format(rsMerged, [Name]));
  Result := 0;
end;

function DoOverwrite(const Ctx: TImportContext; const LocalDir, ImportedDir: string): Integer;
var
  Backup: string;
begin
  Result := 1;
  ForceDirectories(Ctx.BackupRoot);
  Backup := IncludeTrailingPathDelimiter(Ctx.BackupRoot) + ExtractFileName(LocalDir) +
    '-' + FormatDateTime('yyyymmdd-hhnnss', Now);
  if not RenameFile(LocalDir, Backup) then
  begin
    Ctx.Reporter.Error(Format(rsMoveFailed, [LocalDir, Backup]));
    Exit;
  end;
  if not RenameFile(ImportedDir, LocalDir) then
  begin
    RenameFile(Backup, LocalDir);
    Ctx.Reporter.Error(Format(rsMoveFailed, [ImportedDir, LocalDir]));
    Exit;
  end;
  Ctx.Reporter.Info(Format(rsBackedUp, [Backup]));
  Ctx.Reporter.Info(Format(rsOverwritten, [ExtractFileName(LocalDir)]));
  Result := 0;
end;

{ --- check of several packages: keep a scratch copy of each project as
  the earlier packages would leave it --- }

function SimDir(const Ctx: TImportContext; const Name: string): string;
begin
  Result := Ctx.SimRoot + PathDelim + Name;
end;

{ The imported copy becomes the project (new project, or overwrite). }
procedure SimulatePlace(const Ctx: TImportContext; const Name, Src: string);
begin
  if DirectoryExists(SimDir(Ctx, Name)) then
    DeleteTree(SimDir(Ctx, Name));
  ForceDirectories(Ctx.SimRoot);
  if not RenameFile(Src, SimDir(Ctx, Name)) then
    Ctx.Reporter.Warn(Format(Pick(Ctx, rsSimulateFailed, rsSimulateFailedRepo), [Ctx.SourceLabel]));
end;

{ Merge into the scratch copy, cloning the real project first if needed.
  The real project is only read (a --shared clone borrows its objects). }
procedure SimulateMerge(const Ctx: TImportContext; const Name, LocalDir, Src: string;
  ImportedManifest: TJSONObject);
var
  Sim: string;
  Quiet: TWBListReporter;
  QuietCtx: TImportContext;
  SimManifest: TJSONObject;
  Ok: Boolean;
begin
  Sim := SimDir(Ctx, Name);
  ForceDirectories(Ctx.SimRoot);
  if (LocalDir <> Sim) and
     (RunGit(Ctx.SimRoot, ['clone', '-q', '--shared', '--no-tags', LocalDir, Sim]).ExitCode <> 0) then
  begin
    Ctx.Reporter.Warn(Format(Pick(Ctx, rsSimulateFailed, rsSimulateFailedRepo), [Ctx.SourceLabel]));
    Exit;
  end;
  Quiet := TWBListReporter.Create;
  SimManifest := nil;
  try
    QuietCtx := Ctx;
    QuietCtx.Reporter := Quiet;
    try
      SimManifest := ReadJSONObjectFile(Sim + PathDelim + 'manifest.json');
      Ok := DoMerge(QuietCtx, Sim, Src, SimManifest, ImportedManifest) = 0;
    except
      Ok := False;
    end;
    if not Ok then
      Ctx.Reporter.Warn(Format(Pick(Ctx, rsSimulateFailed, rsSimulateFailedRepo), [Ctx.SourceLabel]));
  finally
    SimManifest.Free;
    Quiet.Free;
  end;
end;

function ImportProject(const Ctx: TImportContext; const Src, EntryPath: string): Integer;
var
  Name, Dest, Local, ErrorMsg, Version, Branch: string;
  Manifest, LocalManifest: TJSONObject;
  Info: TPreflight;
  InSim: Boolean;
begin
  Result := 1;
  if not FileExists(Src + PathDelim + 'manifest.json') then
  begin
    Ctx.Reporter.Error(Format(rsNoProjectManifest, [EntryPath]));
    Exit;
  end;
  try
    Manifest := ReadJSONObjectFile(Src + PathDelim + 'manifest.json');
  except
    on E: Exception do
    begin
      Ctx.Reporter.Error(Format(rsBadProjectManifest, [EntryPath, E.Message]));
      Exit;
    end;
  end;

  LocalManifest := nil;
  try
    Version := StrField(Manifest, 'package_version');
    if StrToIntDef(Version, 0) < ProjectManifestVersion - 1 then
    begin
      Ctx.Reporter.Error(Format(rsOldProjectVersion, [EntryPath, Version]));
      Exit;
    end;
    if StrToIntDef(Version, 0) > ProjectManifestVersion then
    begin
      Ctx.Reporter.Error(Format(rsNewProjectVersion, [EntryPath, Version]));
      Exit;
    end;
    if not IsRepo(Src) then
    begin
      Ctx.Reporter.Error(Format(Pick(Ctx, rsNoGitRepo, rsNoGitRepoRepo), [EntryPath]));
      Exit;
    end;

    Name := ProjectFolderName(Manifest, EntryPath);
    if not IsSafeName(Name) then
    begin
      Ctx.Reporter.Error(Format(rsBadEntryPath, [Name]));
      Exit;
    end;
    Dest := Ctx.TargetDir + Name;
    { What the project looks like now: the real one, or in a check of
      several packages, the result of the earlier ones. }
    InSim := Ctx.Simulate and DirectoryExists(SimDir(Ctx, Name));
    if InSim then
      Local := SimDir(Ctx, Name)
    else
      Local := Dest;
    Ctx.Reporter.Info(Format(rsProject, [Name,
      StrField(Manifest, 'target_language.name'), StrField(Manifest, 'project.name'),
      CommitDate(Src)]));

    { The package copy is ours to change. Like Desktop's migrate step:
      upgrade v7, then commit loose work so it is part of what gets merged. }
    if MigrateV7(Manifest) then
    begin
      WriteBttJSONFile(Src + PathDelim + 'manifest.json', Manifest);
      Ctx.Reporter.Info(rsMigratedV7);
    end;
    if IsDirty(Src) then
    begin
      CommitAll(Src, 'Import snapshot');
      Ctx.Reporter.Info(Pick(Ctx, rsPackageDirty, rsRepoDirty));
    end;
    Branch := Trim(RunGit(Src, ['symbolic-ref', '--short', 'HEAD']).Output);
    if (Branch <> '') and (Branch <> 'master') and
       (RunGit(Src, ['branch', '-m', Branch, 'master']).ExitCode = 0) then
      Ctx.Reporter.Info(Format(Pick(Ctx, rsRenamedBranch, rsRenamedBranchRepo), [Branch]));

    if not DirectoryExists(Local) then
    begin
      Ctx.Reporter.Info(Format(rsNewProject, [Dest]));
      if Ctx.DryRun then
      begin
        if Ctx.Simulate then
          SimulatePlace(Ctx, Name, Src);
        Exit(0);
      end;
      ForceDirectories(Ctx.TargetDir);
      if not RenameFile(Src, Dest) then
      begin
        Ctx.Reporter.Error(Format(rsMoveFailed, [Src, Dest]));
        Exit;
      end;
      Ctx.Reporter.Info(Format(rsAdded, [Name]));
      Exit(0);
    end;

    if InSim then
      Ctx.Reporter.Info(Format(Pick(Ctx, rsExistsEarlier, rsExistsEarlierRepo), [Name]))
    else
      Ctx.Reporter.Warn(Format(rsExists, [Name]));

    if not IsRepo(Local) then
    begin
      if (Ctx.OnExisting = 'overwrite') and not Ctx.DryRun then
        Exit(DoOverwrite(Ctx, Dest, Src));
      if Ctx.DryRun then
      begin
        Ctx.Reporter.Warn(Format(rsLocalNotRepo, [Name]));
        if Ctx.Simulate and (Ctx.OnExisting = 'overwrite') then
          SimulatePlace(Ctx, Name, Src);
      end
      else
        Ctx.Reporter.Error(Format(rsLocalNotRepo, [Name]));
      Exit(Ord(not Ctx.DryRun));
    end;
    if FileExists(Local + PathDelim + '.git' + PathDelim + 'MERGE_HEAD') then
    begin
      Ctx.Reporter.Error(Format(rsLocalMidMerge, [Name]));
      Exit;
    end;
    if IsDirty(Local) then
      Ctx.Reporter.Warn(rsLocalDirty);

    if not AnalyzeMerge(Local, Src, Ctx.WorkRoot, Info, ErrorMsg) then
    begin
      Ctx.Reporter.Error(Format(rsPreflightFailed, [ErrorMsg]));
      Exit;
    end;
    LocalManifest := ReadJSONObjectFile(Local + PathDelim + 'manifest.json');
    case Info.Kind of
      mkUpToDate:    Ctx.Reporter.Info(Pick(Ctx, rsUpToDate, rsUpToDateRepo));
      mkFastForward: Ctx.Reporter.Info(Pick(Ctx, rsFastForward, rsFastForwardRepo));
      mkClean:       Ctx.Reporter.Info(rsCleanMerge);
      mkConflicts:
        begin
          if Info.Unrelated then
            Ctx.Reporter.Warn(rsUnrelated);
          ReportConflicts(Info, Local, LocalManifest, Ctx.Reporter);
        end;
    end;

    { Merging is wanted, but not if it would leave conflicts. }
    if (Info.Kind = mkConflicts) and (Ctx.OnConflict = 'skip') and
       (Ctx.OnExisting <> 'overwrite') then
    begin
      if Ctx.DryRun then
        Ctx.Reporter.Warn(Format(rsWouldSkipConflicts, [Name]))
      else if Ctx.OnExisting = 'merge' then
        Ctx.Reporter.Warn(Format(rsSkippedConflicts, [Name]));
      if Ctx.DryRun or (Ctx.OnExisting = 'merge') then
        Exit(0);
    end;

    if Ctx.DryRun then
    begin
      if (Ctx.OnExisting = 'stop') and (Info.Kind <> mkUpToDate) then
        Ctx.Reporter.Info(rsChooseAction);
      if Ctx.Simulate then
        if Ctx.OnExisting = 'overwrite' then
          SimulatePlace(Ctx, Name, Src)
        else if Info.Kind <> mkUpToDate then
          SimulateMerge(Ctx, Name, Local, Src, Manifest);
      Exit(0);
    end;

    if Ctx.OnExisting = 'overwrite' then
      Exit(DoOverwrite(Ctx, Dest, Src));
    if Info.Kind = mkUpToDate then
      Exit(0);
    if Ctx.OnExisting = 'merge' then
      Exit(DoMerge(Ctx, Dest, Src, LocalManifest, Manifest));

    Ctx.Reporter.Error(Format(rsStopped, [Name]));
  finally
    Manifest.Free;
    LocalManifest.Free;
  end;
end;

function ImportSessionRoot(const TargetDir: string): string;
begin
  Result := ExtractFileDir(ExcludeTrailingPathDelimiter(TargetDir)) + PathDelim +
    '.btw-import-' + IntToStr(GetProcessID) + '-' + IntToStr(GetTickCount64);
end;

function ImportBackupRoot(const TargetDir: string): string;
begin
  Result := ExtractFileDir(ExcludeTrailingPathDelimiter(TargetDir)) + PathDelim +
    'workbench-backups';
end;

{ Moves a project on branch main to master (see the unit comment). True if
  it was moved, or would be with DryRun. }
function FixBranch(const Dir: string; DryRun: Boolean; R: TWBReporter): Boolean;
var
  G: TGitResult;
  Ref: string;
begin
  Result := False;
  if not DirectoryExists(IncludeTrailingPathDelimiter(Dir) + '.git') then
    Exit;
  G := RunGit(Dir, ['symbolic-ref', '-q', 'HEAD']);
  if G.ExitCode <> 0 then
  begin
    if RunGit(Dir, ['rev-parse', '--verify', '-q', 'HEAD']).ExitCode = 0 then
      R.Warn(rsDetached);
    Exit;
  end;
  Ref := Trim(G.Output);
  if Ref = 'refs/heads/master' then
    Exit;
  if Ref <> 'refs/heads/main' then
  begin
    R.Warn(Format(rsBranchOther, [StringReplace(Ref, 'refs/heads/', '', [])]));
    Exit;
  end;
  if RunGit(Dir, ['rev-parse', '--verify', '-q', 'refs/heads/master']).ExitCode = 0 then
  begin
    R.Warn(rsBranchBoth);
    Exit;
  end;
  if DryRun then
  begin
    R.Warn(rsBranchWouldRename);
    Exit(True);
  end;
  if RunGit(Dir, ['rev-parse', '--verify', '-q', 'refs/heads/main']).ExitCode = 0 then
    G := RunGit(Dir, ['branch', '-m', 'main', 'master'])
  else
    { No commits yet: only HEAD names the branch. }
    G := RunGit(Dir, ['symbolic-ref', 'HEAD', 'refs/heads/master']);
  if G.ExitCode <> 0 then
  begin
    R.Error(Format(rsBranchFailed, [Trim(G.ErrorOutput)]));
    Exit;
  end;
  R.Warn(rsBranchRenamed);
  Result := True;
end;

end.
