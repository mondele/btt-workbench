unit ModWacsDownload;

{$mode objfpc}{$H+}

(* wacs-download: find BTT-Writer projects on WACS by language, book and
   type (and owner), show each repo's state from the BIEL Public Data API
   (Primary, Active, Inactive; information only), and download the checked
   ones into targetTranslations.

   Finding: WACS repo search (paged to the end) for "<lang>_<book>_" or
   "<lang>_", then names parsed as <lang>_<book>_<type>[_<resource>] and
   filtered exactly. --owner limits it to one user or organisation.

   Downloading goes through WBImport like a .tstudio import: a new project
   is placed; an existing one is left alone (stop), merged, or replaced
   with a backup (overwrite). --on-conflict skip leaves a project alone
   when a merge would conflict; commit merges anyway, committing conflict
   markers for BTT-Writer as Desktop does. --dry-run checks the whole list
   in order without changing anything. Clones use the saved WACS login, so
   private repos work when logged in. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TWacsDownloadModule = class(TWBModule)
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
  WBGit, WBGitea, WBWacs, WBBielCatalog, WBDataPaths, WBProject, WBImport, WBFiles;

resourcestring
  rsTitle = 'Download from WACS';
  rsDescription = 'Finds BTT-Writer projects on WACS by language, book and type, ' +
    'shows their state (Primary, Active, Inactive), and downloads the ones you ' +
    'check into the projects folder, merging with projects already here if ' +
    'you choose. Check first to see what would happen.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Language codes to look for, comma-separated (e.g. udm,sah)';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only these book codes, comma-separated (e.g. mat,jhn)';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these types or resources, comma-separated (text, tn, ' +
    'reg, ulb, or text_reg)';
  rsOptOwner = 'Owner';
  rsOptOwnerHelp = 'Only repos of this WACS user or organisation';
  rsOptRepo = 'Repos';
  rsOptRepoHelp = 'The repos to download (owner/name)';
  rsOptOnExisting = 'If the project exists';
  rsOptOnExistingHelp = 'stop: leave it; merge: combine with the downloaded ' +
    'copy; overwrite: replace it (the old copy is kept in workbench-backups)';
  rsOptOnConflict = 'If a merge would conflict';
  rsOptOnConflictHelp = 'skip: leave that project as it is; commit: merge and ' +
    'leave the conflicts for BTT-Writer to resolve';
  rsOptNoState = 'Skip the state lookup';
  rsOptNoStateHelp = 'Do not ask the BIEL Public Data API for Primary/Active state';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Report what downloading would do without changing anything';

  rsColState = 'State';
  rsColUpdated = 'Updated';
  rsColHere = 'Here';
  rsColNotes = 'Notes';
  rsHereNew = 'new';
  rsHereExists = 'exists';
  rsNoteConsolidated = 'consolidated';
  rsNotePrivate = 'private';
  rsNoteEmpty = 'empty';
  rsNeedFilter = 'Give at least one language code, or an owner.';
  rsNoOwner = 'There is no WACS user or organisation called %s.';
  rsSearchFailed = 'Could not search WACS: %s';
  rsStateFailed = 'Could not get Primary/Active state from the BIEL Public Data ' +
    'API (%s); states are left blank.';
  rsNoGit = 'git was not found. BTT-Writer projects are git repositories; ' +
    'install git first.';
  rsNothingChecked = 'No repos checked.';
  rsServer = 'WACS: %s';
  rsAsUser = 'Logged in as %s.';
  rsAnonymous = 'Not logged in: only public repos can be downloaded.';
  rsTargetDir = 'Projects folder: %s';
  rsCheckInOrder = 'Checking %d repos in the order given, each as if the ones ' +
    'before it had been downloaded.';
  rsCheckAssumesMerge = 'Where a project already exists, the check assumes you ' +
    'will choose merge.';
  rsDuplicate = '%s is listed more than once; downloading it once.';
  rsBadRepoName = '%s is not an owner/name repo. Skipped.';
  rsRepo = 'Repo %s:';
  rsNotFound = '%s was not found on WACS (or it is private and you are not ' +
    'logged in as someone who can see it). Skipped.';
  rsEmptyRepo = '%s is empty. Skipped.';
  rsCloneFailed = 'Could not download %s: %s';
  rsSummary = '%d of %d repo(s) done, %d failed.';

function RepoSearchTerms(const Langs, Books: TStringArray): TStringArray;
var
  L, B: string;
begin
  Result := nil;
  for L in Langs do
    if Length(Books) = 0 then
      Result := Concat(Result, [L + '_'])
    else
      for B in Books do
        Result := Concat(Result, [L + '_' + B + '_']);
end;

function TWacsDownloadModule.Id: string;
begin
  Result := 'wacs-download';
end;

function TWacsDownloadModule.Title: string;
begin
  Result := rsTitle;
end;

function TWacsDownloadModule.Description: string;
begin
  Result := rsDescription;
end;

function TWacsDownloadModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('language', okString, False, False, rsOptLanguage, rsOptLanguageHelp),
    OptionDef('book', okString, False, False, rsOptBook, rsOptBookHelp),
    OptionDef('type', okString, False, False, rsOptType, rsOptTypeHelp),
    OptionDef('owner', okString, False, False, rsOptOwner, rsOptOwnerHelp),
    ChecklistOptionDef('repo', True, rsOptRepo, rsOptRepoHelp),
    ChoiceOptionDef('on-existing', ['stop', 'merge', 'overwrite'], 'stop',
      rsOptOnExisting, rsOptOnExistingHelp),
    ChoiceOptionDef('on-conflict', ['skip', 'commit'], 'skip',
      rsOptOnConflict, rsOptOnConflictHelp),
    OptionDef('no-state', okFlag, False, False, rsOptNoState, rsOptNoStateHelp),
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

function TWacsDownloadModule.Choices(const OptionName: string; Options: TStrings;
  Reporter: TWBReporter; out List: TWBChoiceList): Boolean;
var
  Langs, Books, Types, Terms, Seen, Notes: TStringArray;
  Account: TWacsAccount;
  Client: TGiteaClient;
  Owner: TGiteaUser;
  OwnerId: Int64;
  Found, Repos: TGiteaRepos;
  R: TGiteaRepo;
  States: TBielStates;
  Term, Err, Here, TargetDir: string;
  Sorted: TStringList;
  I, J: Integer;
  Item: TWBChoice;
begin
  Result := False;
  List.Headers := [rsColState, rsColUpdated, rsColHere, rsColNotes];
  List.Items := nil;
  Langs := SplitList(Options.Values['language']);
  Books := SplitList(Options.Values['book']);
  Types := SplitList(Options.Values['type']);
  if (Length(Langs) = 0) and (Trim(Options.Values['owner']) = '') then
  begin
    Reporter.Error(rsNeedFilter);
    Exit;
  end;
  TargetDir := TargetDirOf(Options);
  Account := LoadWacsAccount;
  Client := WacsClient(Account);
  try
    try
      OwnerId := 0;
      if Trim(Options.Values['owner']) <> '' then
      begin
        if not Client.FindOwner(Trim(Options.Values['owner']), Owner) then
        begin
          Reporter.Error(Format(rsNoOwner, [Trim(Options.Values['owner'])]));
          Exit;
        end;
        OwnerId := Owner.Id;
      end;
      Terms := RepoSearchTerms(Langs, Books);
      if Length(Terms) = 0 then
        Terms := [''];      // everything of that owner
      Repos := nil;
      Seen := nil;
      for Term in Terms do
      begin
        Found := Client.SearchRepos(Term, OwnerId);
        for R in Found do
          if not Contains(Seen, LowerCase(R.FullName)) and
             FolderMatches(R.Name, Langs, Books, Types, False) then
          begin
            Seen := Concat(Seen, [LowerCase(R.FullName)]);
            Repos := Concat(Repos, [R]);
          end;
      end;
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsSearchFailed, [E.Message]));
        Exit;
      end;
    end;
  finally
    Client.Free;
  end;

  States := nil;
  if (Length(Repos) > 0) and not OptionIsSet(Options, 'no-state') then
  begin
    Terms := nil;
    for R in Repos do
      if not Contains(Terms, LowerCase(R.Name)) then
        Terms := Concat(Terms, [LowerCase(R.Name)]);
    if not BielStates(Terms, States, Err) then
      Reporter.Warn(Format(rsStateFailed, [Err]));
  end;

  { Sorted by project, then owner. }
  Sorted := TStringList.Create;
  try
    for I := 0 to High(Repos) do
      Sorted.AddObject(LowerCase(Repos[I].Name + ' ' + Repos[I].Owner), TObject(PtrInt(I)));
    Sorted.Sort;
    for J := 0 to Sorted.Count - 1 do
    begin
      R := Repos[PtrInt(Sorted.Objects[J])];
      Notes := nil;
      if Contains(R.Topics, 'consolidated') then
        Notes := Concat(Notes, [rsNoteConsolidated]);
      if R.IsPrivate then
        Notes := Concat(Notes, [rsNotePrivate]);
      if R.Empty then
        Notes := Concat(Notes, [rsNoteEmpty]);
      if DirectoryExists(TargetDir + R.Name) then
        Here := rsHereExists
      else
        Here := rsHereNew;
      Item.Value := R.FullName;
      Item.Columns := [BielStateOf(States, R.FullName), Copy(R.Updated, 1, 10), Here,
        String.Join(', ', Notes)];
      List.Items := Concat(List.Items, [Item]);
    end;
  finally
    Sorted.Free;
  end;
  Result := True;
end;

function TWacsDownloadModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Ctx: TImportContext;
  Values, Wanted, Seen: TStringArray;
  V, SessionRoot, Owner, Name, Dest: string;
  Account: TWacsAccount;
  Client: TGiteaClient;
  Repo: TGiteaRepo;
  G: TGitResult;
  I, Code, Failed: Integer;
begin
  Result := 1;
  if not GitAvailable then
  begin
    Reporter.Error(rsNoGit);
    Exit;
  end;
  if not ChecklistValues(Self, 'repo', Options, Reporter, Values) then
    Exit;
  Wanted := nil;
  Seen := nil;
  for V in Values do
    if Contains(Seen, LowerCase(V)) then
      Reporter.Warn(Format(rsDuplicate, [V]))
    else
    begin
      Seen := Concat(Seen, [LowerCase(V)]);
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
  Ctx.OnExisting := OptionValue(Self, Options, 'on-existing');
  Ctx.OnConflict := OptionValue(Self, Options, 'on-conflict');
  Ctx.DryRun := OptionIsSet(Options, 'dry-run');
  Ctx.Simulate := Ctx.DryRun and (Length(Wanted) > 1);
  Ctx.TargetDir := TargetDirOf(Options);
  SessionRoot := ImportSessionRoot(Ctx.TargetDir);
  Ctx.SimRoot := SessionRoot + PathDelim + 'projects';
  Ctx.BackupRoot := ImportBackupRoot(Ctx.TargetDir);

  Account := LoadWacsAccount;
  Reporter.Info(Format(rsServer, [Account.Server]));
  if LoggedIn(Account) then
    Reporter.Info(Format(rsAsUser, [Account.User]))
  else
    Reporter.Info(rsAnonymous);
  Reporter.Info(Format(rsTargetDir, [ExcludeTrailingPathDelimiter(Ctx.TargetDir)]));
  if Ctx.Simulate then
  begin
    Reporter.Info(Format(rsCheckInOrder, [Length(Wanted)]));
    if Ctx.OnExisting = 'stop' then
      Reporter.Info(rsCheckAssumesMerge);
  end;

  Result := 0;
  Failed := 0;
  Client := WacsClient(Account);
  try
    for I := 0 to High(Wanted) do
    begin
      Reporter.Info('');
      V := Wanted[I];
      Owner := Copy(V, 1, Pos('/', V) - 1);
      Name := Copy(V, Pos('/', V) + 1, MaxInt);
      Reporter.Info(Format(rsRepo, [V]));
      if (Owner = '') or not IsSafeName(Name) or not IsSafeName(Owner) then
      begin
        Reporter.Error(Format(rsBadRepoName, [V]));
        Inc(Failed);
        Continue;
      end;
      try
        if not Client.GetRepo(Owner, Name, Repo) then
        begin
          Reporter.Error(Format(rsNotFound, [V]));
          Inc(Failed);
          Continue;
        end;
      except
        on E: Exception do
        begin
          Reporter.Error(Format(rsCloneFailed, [V, E.Message]));
          Inc(Failed);
          Continue;
        end;
      end;
      if Repo.Empty then
      begin
        Reporter.Warn(Format(rsEmptyRepo, [V]));
        Continue;
      end;

      Ctx.SourceLabel := Repo.FullName;
      Ctx.WorkRoot := SessionRoot + PathDelim + 'repo-' + IntToStr(I + 1);
      ForceDirectories(Ctx.WorkRoot);
      Dest := Ctx.WorkRoot + PathDelim + Repo.Name;
      G := RunGitAs(Account, Ctx.WorkRoot, ['clone', '-q', Repo.CloneUrl, Dest]);
      if G.ExitCode <> 0 then
      begin
        Reporter.Error(Format(rsCloneFailed, [V, Trim(G.ErrorOutput)]));
        Inc(Failed);
        DeleteTree(Ctx.WorkRoot);
        Continue;
      end;
      { The clone's origin is the plain URL (no token); drop it anyway so
        the project does not point BTT-Writer at someone else's repo. }
      RunGit(Dest, ['remote', 'remove', 'origin']);
      Code := ImportProject(Ctx, Dest, Repo.FullName);
      DeleteTree(Ctx.WorkRoot);
      if Code <> 0 then
        Inc(Failed);
    end;
  finally
    Client.Free;
    DeleteTree(SessionRoot);
  end;
  Reporter.Info('');
  Reporter.Info(Format(rsSummary, [Length(Wanted) - Failed, Length(Wanted), Failed]));
  if Failed > 0 then
    Result := 1;
end;

initialization
  RegisterModule(TWacsDownloadModule.Create);

end.
