unit ModWacsUpload;

{$mode objfpc}{$H+}

(* wacs-upload: push the checked local projects to WACS, one after the
   other, as BTT-Writer Desktop's Upload does for one: commit loose work,
   make sure the branch is master, create the repo <owner>/<project> if it
   is missing (public, "btt-writer-desktop: <name>"), push master.

   The owner is the logged-in user unless --owner names an organisation
   (or another user whose repo the login may push to). When the server
   copy has work the local project lacks, --when-ahead decides: skip
   (default) leaves that project for later; merge brings the server work
   in first, through WBImport's merge, with --on-conflict skip or commit
   as for downloads, then pushes. The comparison clones the server copy
   into a scratch folder, so nothing local changes during the check.
   --dry-run reports what each project would need. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TWacsUploadModule = class(TWBModule)
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
  fpjson, WBJson, WBGit, WBGitea, WBWacs, WBDataPaths, WBProject, WBImport, WBFiles;

resourcestring
  rsTitle = 'Upload to WACS';
  rsDescription = 'Uploads the projects you check to WACS, one after another, ' +
    'as BTT-Writer''s Upload does: creates the repo if needed and pushes. If ' +
    'the server has newer work, you choose whether to merge it first or skip ' +
    'that project. Check first to see what each project needs.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Only these target language codes, comma-separated';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only these book codes, comma-separated';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these types or resources, comma-separated (text, tn, ' +
    'reg, ulb, or text_reg)';
  rsOptProject = 'Projects';
  rsOptProjectHelp = 'The project folders to upload';
  rsOptOwner = 'Owner';
  rsOptOwnerHelp = 'Upload into this organisation (or user) instead of your ' +
    'own account';
  rsOptWhenAhead = 'If WACS has newer work';
  rsOptWhenAheadHelp = 'skip: leave that project for later; merge: bring the ' +
    'server''s work in first, then upload';
  rsOptOnConflict = 'If a merge would conflict';
  rsOptOnConflictHelp = 'skip: leave that project as it is; commit: merge and ' +
    'leave the conflicts for BTT-Writer to resolve';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Report what uploading would do without changing anything';

  rsColLanguage = 'Language';
  rsColBook = 'Book';
  rsColType = 'Type';
  rsColChanges = 'Changes';
  rsColOnWacs = 'On WACS';
  rsUncommitted = 'uncommitted';
  rsOnWacsYes = 'exists';
  rsOnWacsNo = 'new';
  rsNotLoggedIn = 'Log in to WACS first (wacs-account).';
  rsNoTargetDir = 'Projects folder not found: %s';
  rsNoGit = 'git was not found. BTT-Writer projects are git repositories; ' +
    'install git first.';
  rsNoOwner = 'There is no WACS user or organisation called %s.';
  rsLookupFailed = 'Could not reach WACS: %s';
  rsNothingChecked = 'No projects checked.';
  rsUploadAs = 'Uploading to %s/%s as %s.';
  rsProject = 'Project %s:';
  rsNoProject = '%s is not a project folder here. Skipped.';
  rsBadManifest = 'manifest.json could not be read (%s). Skipped.';
  rsNotRepo = 'It has no git history, so it cannot be uploaded. Skipped.';
  rsMidMerge = 'It has an unfinished merge; finish it in BTT-Writer first. Skipped.';
  rsConflicts = 'It still has unresolved conflicts (%s); they are uploaded as ' +
    'they are, as BTT-Writer does.';
  rsRepoName = 'Its WACS repo is %s (from manifest.json, not the folder name).';
  rsWouldCommit = 'Uncommitted changes would be committed first.';
  rsCommitted = 'Committed uncommitted changes first.';
  rsCommitFailed = 'Could not commit the uncommitted changes. Skipped.';
  rsWouldCreate = 'The repo %s does not exist yet; it would be created.';
  rsCreated = 'Created the repo %s.';
  rsCreateFailed = 'Could not create the repo %s: %s';
  rsNoPushRight = 'You cannot push to %s. Skipped.';
  rsFetchFailed = 'Could not get the server copy of %s: %s';
  rsUpToDate = 'WACS already has everything in this project. Nothing to upload.';
  rsWouldPush = 'Only new local work: it would be pushed.';
  rsServerAhead = 'WACS has newer work that this project does not have.';
  rsDiverged = 'Both WACS and this project have work the other lacks.';
  rsSkipAhead = 'Skipped (newer work on WACS is set to skip). Download and ' +
    'merge it, or upload with merge.';
  rsSkipConflicts = 'Skipped: merging the server''s work would leave conflicts ' +
    '(conflicts are set to skip).';
  rsNotYours = '%s does not exist, and it can only be created in your own ' +
    'account or an organisation. Skipped.';
  rsWouldMerge = 'The server''s work would be merged in first, then pushed.';
  rsPushed = 'Pushed to %s.';
  rsPushFailed = 'Could not push to %s: %s';
  rsSummary = '%d project(s): %d pushed, %d already up to date, %d skipped, %d failed.';
  rsSummaryCheck = '%d project(s) checked: %d would be pushed, %d up to date, %d ' +
    'would be skipped, %d have problems.';

function TWacsUploadModule.Id: string;
begin
  Result := 'wacs-upload';
end;

function TWacsUploadModule.Title: string;
begin
  Result := rsTitle;
end;

function TWacsUploadModule.Description: string;
begin
  Result := rsDescription;
end;

function TWacsUploadModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('language', okString, False, False, rsOptLanguage, rsOptLanguageHelp),
    OptionDef('book', okString, False, False, rsOptBook, rsOptBookHelp),
    OptionDef('type', okString, False, False, rsOptType, rsOptTypeHelp),
    ChecklistOptionDef('project', True, rsOptProject, rsOptProjectHelp),
    OptionDef('owner', okString, False, False, rsOptOwner, rsOptOwnerHelp),
    ChoiceOptionDef('when-ahead', ['skip', 'merge'], 'skip', rsOptWhenAhead, rsOptWhenAheadHelp),
    ChoiceOptionDef('on-conflict', ['skip', 'commit'], 'skip', rsOptOnConflict, rsOptOnConflictHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp)];
end;

function TargetDirOf(Options: TStrings): string;
begin
  if Options.Values['target-dir'] <> '' then
    Result := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    Result := TargetTranslationsPath;
end;

{ The owner to upload into: --owner, else the logged-in user. }
function ResolveOwner(Client: TGiteaClient; const Account: TWacsAccount;
  Options: TStrings; out Owner: TGiteaUser; Reporter: TWBReporter): Boolean;
var
  Name: string;
begin
  Name := Trim(Options.Values['owner']);
  if Name = '' then
    Name := Account.User;
  Result := Client.FindOwner(Name, Owner);
  if not Result then
    Reporter.Error(Format(rsNoOwner, [Name]));
end;

function TWacsUploadModule.Choices(const OptionName: string; Options: TStrings;
  Reporter: TWBReporter; out List: TWBChoiceList): Boolean;
var
  TargetDir, Name, Dir, Lang, Book, Kind, Res: string;
  Langs, Books, Types, OnServer: TStringArray;
  SR: TSearchRec;
  Names: TStringList;
  Manifest: TJSONObject;
  Account: TWacsAccount;
  Client: TGiteaClient;
  Owner: TGiteaUser;
  Repo: TGiteaRepo;
  Item: TWBChoice;
  Known: Boolean;
  I: Integer;
begin
  Result := False;
  List.Headers := [rsColLanguage, rsColBook, rsColType, rsColChanges, rsColOnWacs];
  List.Items := nil;
  TargetDir := TargetDirOf(Options);
  if not DirectoryExists(TargetDir) then
  begin
    Reporter.Error(Format(rsNoTargetDir, [ExcludeTrailingPathDelimiter(TargetDir)]));
    Exit;
  end;
  Langs := SplitList(Options.Values['language']);
  Books := SplitList(Options.Values['book']);
  Types := SplitList(Options.Values['type']);

  { Which repos the owner already has, in one search, if logged in. }
  OnServer := nil;
  Known := False;
  Account := LoadWacsAccount;
  if LoggedIn(Account) then
  begin
    Client := WacsClient(Account);
    try
      try
        if ResolveOwner(Client, Account, Options, Owner, Reporter) then
        begin
          for Repo in Client.SearchRepos('', Owner.Id) do
            OnServer := Concat(OnServer, [LowerCase(Repo.Name)]);
          Known := True;
        end;
      except
        on E: Exception do
          Reporter.Warn(Format(rsLookupFailed, [E.Message]));
      end;
    finally
      Client.Free;
    end;
  end;

  Names := TStringList.Create;
  try
    if FindFirst(TargetDir + AllFilesMask, faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Name[1] <> '.') and
           ((SR.Attr and faDirectory) <> 0) then
          Names.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Names.Sort;
    for I := 0 to Names.Count - 1 do
    begin
      Dir := TargetDir + Names[I] + PathDelim;
      if not FileExists(Dir + 'manifest.json') then
        Continue;
      try
        Manifest := ReadJSONObjectFile(Dir + 'manifest.json');
      except
        Continue;
      end;
      try
        Lang := StrField(Manifest, 'target_language.id');
        Book := StrField(Manifest, 'project.id');
        Kind := StrField(Manifest, 'type.id');
        Res := StrField(Manifest, 'resource.id');
        if not (Matches(Langs, [Lang]) and Matches(Books, [Book]) and
                Matches(Types, [Kind, Res, Kind + '_' + Res])) then
          Continue;
        Name := ProjectFolderName(Manifest, Names[I]);
        Item.Value := Names[I];
        Item.Columns := [StrField(Manifest, 'target_language.name') + ' (' + Lang + ')',
          StrField(Manifest, 'project.name'), Kind + '/' + Res, '', ''];
        if IsDirty(ExcludeTrailingPathDelimiter(Dir)) then
          Item.Columns[3] := rsUncommitted;
        if Known then
          if Contains(OnServer, LowerCase(Name)) then
            Item.Columns[4] := rsOnWacsYes
          else
            Item.Columns[4] := rsOnWacsNo;
        List.Items := Concat(List.Items, [Item]);
      finally
        Manifest.Free;
      end;
    end;
  finally
    Names.Free;
  end;
  Result := True;
end;

type
  TOutcome = (ocPushed, ocUpToDate, ocSkipped, ocFailed);

function UploadProject(const Folder: string; const Ctx: TImportContext;
  const Account: TWacsAccount; Client: TGiteaClient; const Owner: TGiteaUser;
  const WhenAhead, Scratch: string): TOutcome;
var
  R: TWBReporter;
  Dir, Name, RemoteDir, ErrorMsg: string;
  Manifest, LocalManifest, RemoteManifest: TJSONObject;
  Repo: TGiteaRepo;
  Exists: Boolean;
  G: TGitResult;
  Info: TPreflight;
  Conflicted: TStringArray;
  C: string;
begin
  Result := ocFailed;
  R := Ctx.Reporter;
  Dir := Ctx.TargetDir + Folder;
  if not IsSafeName(Folder) or not FileExists(Dir + PathDelim + 'manifest.json') then
  begin
    R.Error(Format(rsNoProject, [Folder]));
    Exit;
  end;
  try
    Manifest := ReadJSONObjectFile(Dir + PathDelim + 'manifest.json');
  except
    on E: Exception do
    begin
      R.Error(Format(rsBadManifest, [E.Message]));
      Exit;
    end;
  end;
  try
    Name := ProjectFolderName(Manifest, Folder);
  finally
    Manifest.Free;
  end;
  if Name <> Folder then
    R.Info(Format(rsRepoName, [Owner.Login + '/' + Name]));
  if not IsRepo(Dir) then
  begin
    R.Error(rsNotRepo);
    Exit;
  end;
  if FileExists(Dir + PathDelim + '.git' + PathDelim + 'MERGE_HEAD') then
  begin
    R.Error(rsMidMerge);
    Exit;
  end;
  Conflicted := nil;
  for C in Lines(RunGit(Dir, ['grep', '-l', '-e', '^<<<<<<< ', 'HEAD', '--', '*.txt']).Output) do
    Conflicted := Concat(Conflicted, [ChunkIdFromPath(Copy(C, Pos(':', C) + 1, MaxInt))]);
  if Length(Conflicted) > 0 then
    R.Warn(Format(rsConflicts, [String.Join(', ', Conflicted)]));

  { Loose work and the branch, as Desktop's commitAll before an upload. }
  if IsDirty(Dir) then
    if Ctx.DryRun then
      R.Info(rsWouldCommit)
    else if CommitAll(Dir, FormatDateTime('ddd mmm dd yyyy hh:nn:ss', Now)) then
      R.Info(rsCommitted)
    else
    begin
      R.Error(rsCommitFailed);
      Exit;
    end;
  FixBranch(Dir, Ctx.DryRun, R);
  if Trim(RunGit(Dir, ['symbolic-ref', '-q', '--short', 'HEAD']).Output) <> 'master' then
    if not Ctx.DryRun then
      Exit(ocSkipped);

  { The repo on WACS }
  try
    Exists := Client.GetRepo(Owner.Login, Name, Repo);
    if not Exists and not Owner.IsOrg and not SameText(Owner.Login, Account.User) then
    begin
      R.Error(Format(rsNotYours, [Owner.Login + '/' + Name]));
      Exit;
    end;
    if not Exists then
    begin
      if Ctx.DryRun then
      begin
        R.Info(Format(rsWouldCreate, [Owner.Login + '/' + Name]));
        R.Info(rsWouldPush);
        Exit(ocPushed);
      end;
      Repo := Client.CreateRepo(Owner.Login, Name, Owner.IsOrg);
      R.Info(Format(rsCreated, [Repo.FullName]));
    end
    else if not Repo.CanPush then
    begin
      R.Error(Format(rsNoPushRight, [Repo.FullName]));
      Exit;
    end;
  except
    on E: Exception do
    begin
      R.Error(Format(rsCreateFailed, [Owner.Login + '/' + Name, E.Message]));
      Exit;
    end;
  end;

  { Compare with the server copy, cloned into scratch. }
  if Exists and not Repo.Empty then
  begin
    RemoteDir := Scratch + PathDelim + 'server';
    G := RunGitAs(Account, Scratch, ['clone', '-q', '--no-tags', Repo.CloneUrl, RemoteDir]);
    if G.ExitCode <> 0 then
    begin
      R.Error(Format(rsFetchFailed, [Repo.FullName, Trim(G.ErrorOutput)]));
      Exit;
    end;
    if not AnalyzeMerge(Dir, RemoteDir, Scratch, Info, ErrorMsg) then
    begin
      R.Error(Format(rsFetchFailed, [Repo.FullName, ErrorMsg]));
      Exit;
    end;
    { Info.Kind from the local side: up to date = the server has nothing new. }
    if Info.Kind <> mkUpToDate then
    begin
      if Info.Kind = mkFastForward then
        R.Info(rsServerAhead)
      else
        R.Warn(rsDiverged);
      if WhenAhead <> 'merge' then
      begin
        R.Warn(rsSkipAhead);
        Exit(ocSkipped);
      end;
      LocalManifest := nil;
      RemoteManifest := nil;
      try
        LocalManifest := ReadJSONObjectFile(Dir + PathDelim + 'manifest.json');
        RemoteManifest := ReadJSONObjectFile(RemoteDir + PathDelim + 'manifest.json');
        if Info.Kind = mkConflicts then
        begin
          ReportConflicts(Info, Dir, LocalManifest, R);
          if Ctx.OnConflict = 'skip' then
          begin
            R.Warn(rsSkipConflicts);
            Exit(ocSkipped);
          end;
        end;
        if Ctx.DryRun then
        begin
          R.Info(rsWouldMerge);
          Exit(ocPushed);
        end;
        if DoMerge(Ctx, Dir, RemoteDir, LocalManifest, RemoteManifest) <> 0 then
          Exit;
      finally
        LocalManifest.Free;
        RemoteManifest.Free;
      end;
    end
    else if Trim(RunGit(Dir, ['rev-parse', 'HEAD']).Output) =
            Trim(RunGit(RemoteDir, ['rev-parse', 'HEAD']).Output) then
    begin
      R.Info(rsUpToDate);
      Exit(ocUpToDate);
    end;
  end;

  if Ctx.DryRun then
  begin
    R.Info(rsWouldPush);
    Exit(ocPushed);
  end;
  G := RunGitAs(Account, Dir, ['push', '-q', Repo.CloneUrl, 'master:master', '--follow-tags']);
  if G.ExitCode <> 0 then
  begin
    R.Error(Format(rsPushFailed, [Repo.FullName, Trim(G.ErrorOutput)]));
    Exit;
  end;
  R.Info(Format(rsPushed, [Repo.FullName]));
  Result := ocPushed;
end;

function TWacsUploadModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Ctx: TImportContext;
  Values, Wanted, Seen: TStringArray;
  V, SessionRoot, Scratch: string;
  Account: TWacsAccount;
  Client: TGiteaClient;
  Owner: TGiteaUser;
  Counts: array[TOutcome] of Integer;
  Outcome: TOutcome;
  I: Integer;
begin
  Result := 1;
  if not GitAvailable then
  begin
    Reporter.Error(rsNoGit);
    Exit;
  end;
  Account := LoadWacsAccount;
  if not LoggedIn(Account) then
  begin
    Reporter.Error(rsNotLoggedIn);
    Exit;
  end;
  if not ChecklistValues(Self, 'project', Options, Reporter, Values) then
    Exit;
  Wanted := nil;
  Seen := nil;
  for V in Values do
    if not Contains(Seen, V) then
    begin
      Seen := Concat(Seen, [V]);
      Wanted := Concat(Wanted, [V]);
    end;
  if Length(Wanted) = 0 then
  begin
    Reporter.Error(rsNothingChecked);
    Exit;
  end;

  Ctx := Default(TImportContext);
  Ctx.Reporter := Reporter;
  Ctx.FromServer := True;
  Ctx.OnConflict := OptionValue(Self, Options, 'on-conflict');
  Ctx.OnExisting := 'merge';
  Ctx.DryRun := OptionIsSet(Options, 'dry-run');
  Ctx.TargetDir := TargetDirOf(Options);
  SessionRoot := ImportSessionRoot(Ctx.TargetDir);
  for Outcome in TOutcome do
    Counts[Outcome] := 0;

  Client := WacsClient(Account);
  try
    try
      if not ResolveOwner(Client, Account, Options, Owner, Reporter) then
        Exit;
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsLookupFailed, [E.Message]));
        Exit;
      end;
    end;
    Reporter.Info(Format(rsUploadAs, [Account.Server, Owner.Login, Account.User]));
    for I := 0 to High(Wanted) do
    begin
      Reporter.Info('');
      Reporter.Info(Format(rsProject, [Wanted[I]]));
      Scratch := SessionRoot + PathDelim + 'up-' + IntToStr(I + 1);
      ForceDirectories(Scratch);
      Ctx.SourceLabel := Owner.Login + '/' + Wanted[I];
      Ctx.WorkRoot := Scratch;
      try
        Outcome := UploadProject(Wanted[I], Ctx, Account, Client, Owner,
          OptionValue(Self, Options, 'when-ahead'), Scratch);
      except
        on E: Exception do
        begin
          Reporter.Error(E.Message);
          Outcome := ocFailed;
        end;
      end;
      Inc(Counts[Outcome]);
      DeleteTree(Scratch);
    end;
  finally
    Client.Free;
    DeleteTree(SessionRoot);
  end;
  Reporter.Info('');
  if Ctx.DryRun then
    Reporter.Info(Format(rsSummaryCheck, [Length(Wanted), Counts[ocPushed],
      Counts[ocUpToDate], Counts[ocSkipped], Counts[ocFailed]]))
  else
    Reporter.Info(Format(rsSummary, [Length(Wanted), Counts[ocPushed],
      Counts[ocUpToDate], Counts[ocSkipped], Counts[ocFailed]]));
  if Counts[ocFailed] = 0 then
    Result := 0;
end;

initialization
  RegisterModule(TWacsUploadModule.Create);

end.
