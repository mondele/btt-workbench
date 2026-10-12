unit ModTStudioImport;

{$mode objfpc}{$H+}

(* tstudio-import: import a BTT-Writer .tstudio package into
   targetTranslations, with a preflight (--dry-run) that says whether each
   project is new, already present, or needs merging, and which chunks a
   merge would leave in conflict.

   Follows BTT-Writer Desktop 1.6.0 (/usr/lib/btt-writer: src/js/
   importer.js, migrator.js, gitnative.js, render.js), so the result opens
   cleanly there:
   - Package: zip with manifest.json (package_version 1 or 2, list in
     target_translations, or projects in v1) and one folder per project,
     .git included.
   - Same project = same folder name, built from the project's manifest as
     <language>_<book>_<type>[_<resource>].
   - Project manifests must end up at package_version 8. Version 7 gets
     Desktop's small v7->v8 step (resource.name filled in,
     source_translations defaulted). Older ones need BTT-Writer's full
     migration, so they are refused rather than guessed at; newer ones too.
   - The project must have a 'master' branch: Desktop merges later
     imports with "git pull <path> master".
   - Merge: local is "ours", imported is "theirs". translators and
     finished_chunks become the union of both; conflicted chunks are
     un-finished. Conflicts are committed with standard markers
       <<<<<<< HEAD / ======= / >>>>>>> <40-char commit hash>
     which is exactly what Desktop's conflict parser looks for (render.js).
     We merge by commit hash, not branch, so 'master' vs 'main' does not
     matter, and force merge.conflictStyle=merge (diff3 would break
     Desktop's parser).
   - Overwrite moves the existing project to <data>/workbench-backups/
     instead of deleting it (Desktop deletes it).

   The preflight never touches the existing project: it fetches into a
   throwaway shared bare clone and asks git merge-tree (git 2.38+).

   Several packages (copies of one project from different devices, say)
   are imported in the order given. The check runs them in that order too:
   each package is imported into a scratch copy of the project, so the next
   one is checked against the result. Under 'stop' the check assumes merge,
   since that is what the user will be choosing. A chunk that conflicts
   again on top of an unresolved conflict gets nested markers; Desktop's
   parser (render.js parseConflicts) unwraps those into one list of all the
   versions, so that is reported, not refused. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TTStudioImportModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  fpjson, Zipper, DateUtils,
  WBJson, WBGit, WBFiles, WBDataPaths;

resourcestring
  rsTitle = 'Import .tstudio package';
  rsDescription = 'Imports a BTT-Writer project package (.tstudio) into the ' +
    'BTT-Writer projects folder. Check first: it tells you whether the ' +
    'project is new or already here, and which chunks a merge would leave ' +
    'in conflict.';
  rsOptFile = 'Package files';
  rsOptFileHelp = 'The .tstudio file(s) to import, in order';
  rsOptOnExisting = 'If the project exists';
  rsOptOnExistingHelp = 'stop: change nothing; merge: combine with the ' +
    'existing project (as BTT-Writer does); overwrite: replace it (the old ' +
    'copy is kept in workbench-backups)';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Report what the import would do without changing anything';

  rsNoGit = 'git was not found. BTT-Writer projects are git repositories; ' +
    'install git first.';
  rsNoFile = 'File not found: %s';
  rsNotZip = 'Not a readable .tstudio package (%s)';
  rsUnsafeEntry = 'The package contains an unsafe path (%s). Nothing was imported.';
  rsNoPackageManifest = 'The package has no manifest.json.';
  rsBadPackageVersion = 'Unsupported package version %s.';
  rsEmptyPackage = 'The package contains no projects.';
  rsPackageInfo = 'Package: %s, made by %s on %s, %d project(s).';
  rsTargetDir = 'Projects folder: %s';
  rsTargetDirMissing = 'The projects folder does not exist yet; it will be created.';

  rsBadEntryPath = 'Project entry has an unsafe or missing path: "%s". Skipped.';
  rsEntryMissing = 'Project folder %s is listed but not in the package. Skipped.';
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
  rsCheckInOrder = 'Checking %d packages in the order given, each as if the ' +
    'ones before it had been imported.';
  rsCheckAssumesMerge = 'Where a project already exists, the check assumes ' +
    'you will choose merge.';
  rsDuplicateFile = '%s is listed more than once; importing it once.';
  rsExistsEarlier = '%s is also in an earlier package; checking against that ' +
    'result.';
  rsStacked = 'These chunks already have an unresolved conflict, so the ' +
    'conflicts will stack. BTT-Writer will offer every version to choose ' +
    'from: %s';
  rsSimulateFailed = 'Could not simulate importing %s; checks of later ' +
    'packages for this project may be incomplete.';

const
  ProjectManifestVersion = 8;
  WorkbenchIdentity: array[0..3] of string =
    ('-c', 'user.name=BTT Workbench', '-c', 'user.email=btt-workbench@localhost');

type
  TMergeKind = (mkUpToDate, mkFastForward, mkClean, mkConflicts);

  TPreflight = record
    Kind: TMergeKind;
    Unrelated: Boolean;
    ConflictPaths: TStringArray;
  end;

  TImportContext = record
    PackageFile: string;
    TargetDir: string;
    WorkRoot: string;     // this package's scratch folder
    SimRoot: string;      // check of several packages: projects as imported so far
    BackupRoot: string;
    OnExisting: string;
    DryRun: Boolean;
    Simulate: Boolean;    // DryRun with more than one package
    Reporter: TWBReporter;
  end;

{ --- small helpers --- }

function JoinNames(const Items: TStringArray): string;
begin
  Result := String.Join(', ', Items);
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

function StrField(Obj: TJSONObject; const Path: string): string;
var
  D: TJSONData;
begin
  Result := '';
  D := Obj.FindPath(Path);
  if (D <> nil) and (D.JSONType in [jtString, jtNumber]) then
    Result := D.AsString;
end;

{ Desktop's unique_id: <lang>_<book>_<type>[_<resource>] (migrator.js). }
function ProjectFolderName(Manifest: TJSONObject; const Fallback: string): string;
var
  Lang, Book, Kind, Res: string;
begin
  Lang := StrField(Manifest, 'target_language.id');
  Book := StrField(Manifest, 'project.id');
  Kind := StrField(Manifest, 'type.id');
  Res := StrField(Manifest, 'resource.id');
  if (Lang = '') or (Book = '') or (Kind = '') then
    Exit(Fallback);
  Result := Lang + '_' + Book + '_' + Kind;
  if Res <> '' then
    Result := Result + '_' + Res;
end;

{ 03/01.txt -> 03-01, front/title.txt -> front-title (gitnative.js). }
function ChunkIdFromPath(const Path: string): string;
begin
  Result := '';
  if LowerCase(ExtractFileExt(Path)) <> '.txt' then
    Exit;
  Result := StringReplace(ChangeFileExt(Path, ''), '/', '-', [rfReplaceAll]);
end;

function StringsOf(Arr: TJSONData): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  if (Arr = nil) or (Arr.JSONType <> jtArray) then
    Exit;
  for I := 0 to Arr.Count - 1 do
    if Arr.Items[I].JSONType = jtString then
      Result := Concat(Result, [Arr.Items[I].AsString]);
end;

function Contains(const Items: TStringArray; const S: string): Boolean;
var
  X: string;
begin
  for X in Items do
    if X = S then
      Exit(True);
  Result := False;
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

{ True if the file already holds committed conflict markers. }
function HasConflictMarkers(const FileName: string): Boolean;
var
  L: TStringList;
  Line: string;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    for Line in L do
      if Copy(Line, 1, 8) = '<<<<<<< ' then
        Exit(True);
  finally
    L.Free;
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
    'Import ' + ExtractFileName(Ctx.PackageFile), Sha]);
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
    if not CommitAll(LocalDir, 'Import ' + ExtractFileName(Ctx.PackageFile)) then
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
    Ctx.Reporter.Warn(Format(rsSimulateFailed, [ExtractFileName(Ctx.PackageFile)]));
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
    Ctx.Reporter.Warn(Format(rsSimulateFailed, [ExtractFileName(Ctx.PackageFile)]));
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
      Ctx.Reporter.Warn(Format(rsSimulateFailed, [ExtractFileName(Ctx.PackageFile)]));
  finally
    SimManifest.Free;
    Quiet.Free;
  end;
end;

function ImportEntry(const Ctx: TImportContext; Entry: TJSONObject): Integer;
var
  EntryPath, Src, Name, Dest, Local, ErrorMsg, Version, Branch: string;
  Manifest, LocalManifest: TJSONObject;
  Info: TPreflight;
  InSim: Boolean;
begin
  Result := 1;
  EntryPath := StrField(Entry, 'path');
  if not IsSafeName(EntryPath) then
  begin
    Ctx.Reporter.Error(Format(rsBadEntryPath, [EntryPath]));
    Exit;
  end;
  Src := Ctx.WorkRoot + PathDelim + EntryPath;
  if not DirectoryExists(Src) then
  begin
    Ctx.Reporter.Error(Format(rsEntryMissing, [EntryPath]));
    Exit;
  end;
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
      Ctx.Reporter.Error(Format(rsNoGitRepo, [EntryPath]));
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
      Ctx.Reporter.Info(rsPackageDirty);
    end;
    Branch := Trim(RunGit(Src, ['symbolic-ref', '--short', 'HEAD']).Output);
    if (Branch <> '') and (Branch <> 'master') and
       (RunGit(Src, ['branch', '-m', Branch, 'master']).ExitCode = 0) then
      Ctx.Reporter.Info(Format(rsRenamedBranch, [Branch]));

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
      Ctx.Reporter.Info(Format(rsExistsEarlier, [Name]))
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
      mkUpToDate:    Ctx.Reporter.Info(rsUpToDate);
      mkFastForward: Ctx.Reporter.Info(rsFastForward);
      mkClean:       Ctx.Reporter.Info(rsCleanMerge);
      mkConflicts:
        begin
          if Info.Unrelated then
            Ctx.Reporter.Warn(rsUnrelated);
          ReportConflicts(Info, Local, LocalManifest, Ctx.Reporter);
        end;
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

{ --- module --- }

function TTStudioImportModule.Id: string;
begin
  Result := 'tstudio-import';
end;

function TTStudioImportModule.Title: string;
begin
  Result := rsTitle;
end;

function TTStudioImportModule.Description: string;
begin
  Result := rsDescription;
end;

function TTStudioImportModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    ListOptionDef('file', okFile, True, True, rsOptFile, rsOptFileHelp),
    ChoiceOptionDef('on-existing', ['stop', 'merge', 'overwrite'], 'stop',
      rsOptOnExisting, rsOptOnExistingHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp)];
end;

function ExtractPackage(const PackageFile, WorkRoot: string; Reporter: TWBReporter): Boolean;
var
  Unzip: TUnZipper;
  I: Integer;
  Entry: string;
begin
  Result := False;
  Unzip := TUnZipper.Create;
  try
    Unzip.FileName := PackageFile;
    Unzip.OutputPath := WorkRoot;
    try
      Unzip.Examine;
      for I := 0 to Unzip.Entries.Count - 1 do
      begin
        Entry := Unzip.Entries[I].ArchiveFileName;
        if not IsSafeRelativePath(Entry) then
        begin
          Reporter.Error(Format(rsUnsafeEntry, [Entry]));
          Exit;
        end;
      end;
      Unzip.UnZipAllFiles;
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsNotZip, [E.Message]));
        Exit;
      end;
    end;
    Result := True;
  finally
    Unzip.Free;
  end;
end;

{ One package. Ctx.PackageFile and Ctx.WorkRoot are this package's. }
function ImportPackage(const Ctx: TImportContext): Integer;
var
  Reporter: TWBReporter;
  Pkg: TJSONObject;
  Entries: TJSONData;
  Version: Integer;
  I, Code: Integer;
  Stamp: Int64;
  When, Generator: string;
begin
  Result := 1;
  Reporter := Ctx.Reporter;
  if not FileExists(Ctx.PackageFile) then
  begin
    Reporter.Error(Format(rsNoFile, [Ctx.PackageFile]));
    Exit;
  end;
  if not ForceDirectories(Ctx.WorkRoot) then
  begin
    Reporter.Error(Format(rsMoveFailed, [Ctx.PackageFile, Ctx.WorkRoot]));
    Exit;
  end;
  Pkg := nil;
  try
    if not ExtractPackage(Ctx.PackageFile, Ctx.WorkRoot, Reporter) then
      Exit;
    if not FileExists(Ctx.WorkRoot + PathDelim + 'manifest.json') then
    begin
      Reporter.Error(rsNoPackageManifest);
      Exit;
    end;
    try
      Pkg := ReadJSONObjectFile(Ctx.WorkRoot + PathDelim + 'manifest.json');
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsNotZip, [E.Message]));
        Exit;
      end;
    end;

    Version := StrToIntDef(StrField(Pkg, 'package_version'), 0);
    if Version = 1 then
      Entries := Pkg.Find('projects')
    else if Version = 2 then
      Entries := Pkg.Find('target_translations')
    else
    begin
      Reporter.Error(Format(rsBadPackageVersion, [StrField(Pkg, 'package_version')]));
      Exit;
    end;
    if (Entries = nil) or (Entries.JSONType <> jtArray) or (Entries.Count = 0) then
    begin
      Reporter.Error(rsEmptyPackage);
      Exit;
    end;

    Stamp := StrToInt64Def(StrField(Pkg, 'timestamp'), 0);
    if Stamp > 0 then
      When := FormatDateTime('yyyy-mm-dd hh:nn', UnixToDateTime(Stamp div 1000, False))
    else
      When := '?';
    Generator := StrField(Pkg, 'generator.name');
    if Generator = '' then
      Generator := '?';
    Reporter.Info(Format(rsPackageInfo, [ExtractFileName(Ctx.PackageFile),
      Generator, When, Entries.Count]));

    Result := 0;
    for I := 0 to Entries.Count - 1 do
    begin
      if Entries.Items[I].JSONType <> jtObject then
      begin
        Reporter.Error(Format(rsBadEntryPath, ['?']));
        Result := 1;
        Continue;
      end;
      Code := ImportEntry(Ctx, TJSONObject(Entries.Items[I]));
      if Code > Result then
        Result := Code;
    end;
  finally
    Pkg.Free;
    DeleteTree(Ctx.WorkRoot);
  end;
end;

function TTStudioImportModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Ctx: TImportContext;
  Files, Seen: TStringArray;
  F, SessionRoot: string;
  I, Code: Integer;
begin
  Result := 1;
  Ctx.Reporter := Reporter;
  Ctx.OnExisting := OptionValue(Self, Options, 'on-existing');
  Ctx.DryRun := OptionIsSet(Options, 'dry-run');
  if Options.Values['target-dir'] <> '' then
    Ctx.TargetDir := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    Ctx.TargetDir := TargetTranslationsPath;
  { Scratch and backup dirs sit next to the projects folder, on the same
    disk, so moving a project into place is a rename. }
  SessionRoot := ExtractFileDir(ExcludeTrailingPathDelimiter(Ctx.TargetDir)) + PathDelim +
    '.btw-import-' + IntToStr(GetProcessID) + '-' + IntToStr(GetTickCount64);
  Ctx.SimRoot := SessionRoot + PathDelim + 'projects';
  Ctx.BackupRoot := ExtractFileDir(ExcludeTrailingPathDelimiter(Ctx.TargetDir)) + PathDelim +
    'workbench-backups';

  if not GitAvailable then
  begin
    Reporter.Error(rsNoGit);
    Exit;
  end;

  Files := nil;
  Seen := nil;
  for F in OptionValues(Options, 'file') do
    if Contains(Seen, ExpandFileName(F)) then
      Reporter.Warn(Format(rsDuplicateFile, [ExtractFileName(F)]))
    else
    begin
      Seen := Concat(Seen, [ExpandFileName(F)]);
      Files := Concat(Files, [ExpandFileName(F)]);
    end;
  Ctx.Simulate := Ctx.DryRun and (Length(Files) > 1);

  Reporter.Info(Format(rsTargetDir, [ExcludeTrailingPathDelimiter(Ctx.TargetDir)]));
  if not DirectoryExists(Ctx.TargetDir) and Ctx.DryRun then
    Reporter.Info(rsTargetDirMissing);
  if Ctx.Simulate then
  begin
    Reporter.Info(Format(rsCheckInOrder, [Length(Files)]));
    if Ctx.OnExisting = 'stop' then
      Reporter.Info(rsCheckAssumesMerge);
  end;

  Result := 0;
  try
    for I := 0 to High(Files) do
    begin
      if Length(Files) > 1 then
        Reporter.Info('');
      Ctx.PackageFile := Files[I];
      Ctx.WorkRoot := SessionRoot + PathDelim + 'package-' + IntToStr(I + 1);
      Code := ImportPackage(Ctx);
      if Code > Result then
        Result := Code;
    end;
  finally
    DeleteTree(SessionRoot);
  end;
end;

initialization
  RegisterModule(TTStudioImportModule.Create);

end.
