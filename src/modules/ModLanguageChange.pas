unit ModLanguageChange;

{$mode objfpc}{$H+}

(* language-change: gives the checked projects another language code, name
   or text direction, so that one language's projects agree. BTT-Writer
   copies a language's code, name and direction into each project when the
   project is made and never refreshes them, so one language ends up under
   several names (the Udmurt projects under "удмурт кыл" and
   "Удмуртский", as the language database changed) or several codes
   (Chimanika under mxc-MZ-x-manika and mxc-MZ-chimanika), and codes get
   replaced (temporary codes approved, codes that are not BCP 47 and so
   not usable in Scripture Burrito).

   For each checked project: the manifest's target_language gets the new
   code, name and direction, the change is committed (as cross-repair
   commits), and the folder is renamed to match the code. Uncommitted
   work is committed first. WACS is not touched: a project with a new
   code uploads to a repo of its new name. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TLanguageChangeModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Choices(const OptionName: string; Options: TStrings;
      Reporter: TWBReporter; out List: TWBChoiceList): Boolean; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
    function Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions; override;
  end;

implementation

uses
  fpjson, WBJson, WBDataPaths, WBSuggest, WBProject, WBGit, WBImport, WBLanguages, WBLangTag,
  WBCrossScan, WBCrossRepair;

resourcestring
  rsTitle = 'Change project language';
  rsDescription = 'Gives the checked projects another language code, name or ' +
    'text direction, so that a language''s projects agree: BTT-Writer copies ' +
    'these into each project when it is made and never updates them. The ' +
    'manifest is changed and committed, and the folder renamed to match a new ' +
    'code. WACS is not changed: a project with a new code uploads to a repo of ' +
    'its new name, and devices with the old project must import the new one. ' +
    'Find, check the projects, set what they should become, then Check to see ' +
    'what would happen.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Find projects of these language codes, comma-separated ' +
    '(a first part such as mxc takes every code that starts with it)';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only these book codes, comma-separated';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these types or resources, comma-separated (text, reg, tn, ...)';
  rsOptProject = 'Projects';
  rsOptProjectHelp = 'The projects to change';
  rsOptCode = 'New language code';
  rsOptCodeHelp = 'The code the projects should have (empty: keep each one''s code)';
  rsOptName = 'New language name';
  rsOptNameHelp = 'The name (empty: the language database''s name for the code, ' +
    'or the project''s own name if the database has none)';
  rsOptDirection = 'Text direction';
  rsOptDirectionHelp = 'database: the language database''s direction for the ' +
    'code (the project''s own if the database has none)';
  rsOptLanguageDb = 'Language database';
  rsOptLanguageDbHelp = 'BTT-Writer''s index.sqlite to take names and directions ' +
    'from (default: the one in BTT-Writer''s data folder)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Report what would change without changing anything';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';

  rsColLanguage = 'Language now';
  rsColChange = 'Change';
  rsNoChange = 'none';
  rsChangeCode = 'code %s';
  rsChangeName = 'name "%s"';
  rsChangeDirection = 'direction %s';
  rsChangeFolder = 'folder %s';
  rsFolderTaken = 'blocked: %s exists';

  rsNoTargetDir = 'Projects folder not found: %s';
  rsNoGit = 'git was not found. BTT-Writer projects are git repositories; ' +
    'install git first.';
  rsFolder = 'Projects folder: %s';
  rsLanguageDb = 'Language database: %s';
  rsNoLanguageDb = 'No language database found: names and directions stay as ' +
    'the projects have them unless given.';
  rsBadLanguageDb = 'Cannot read the language database %s (%s).';
  rsBadCode = 'A language code cannot contain "%s": %s';
  rsNotBcp47 = '%s is not a well-formed BCP 47 language tag, so tools that ' +
    'need one (Scripture Burrito) will not accept it.';
  rsUnknownCode = '%s is not in the language database.';
  rsNothingChecked = 'No projects checked.';
  rsNotFound = '%s: not found (or not shown by the filters). Skipped.';
  rsSame = '%s: already %s, "%s", %s.';
  rsTaken = '%s: cannot rename it to %s, which already exists. Left alone.';
  rsWould = '%s: would become %s, "%s", %s%s.';
  rsDone = '%s: now %s, "%s", %s%s.';
  rsRenamedTo = '; folder %s';
  rsLooseWork = 'Uncommitted work, before a language change';
  rsCommit = 'Language: %s "%s" %s -> %s "%s" %s (BTT Workbench)';
  rsFailed = '%s: could not change it (%s).';
  rsRenameFailed = '%s: changed and committed, but the folder could not be ' +
    'renamed to %s; rename it by hand.';
  rsSummary = '%d project(s) changed, %d left alone.';
  rsWouldSummary = '%d project(s) would be changed, %d left alone.';
  rsAfter = 'Projects with a new code upload to WACS under their new names; the ' +
    'repos under the old names stay. Devices with the old projects should ' +
    'delete them and import the changed ones.';

type
  TPlan = record
    Folder, NewFolder: string;
    Code, Name, Direction: string;
    NewCode, NewName, NewDirection: string;
  end;
  TPlans = array of TPlan;

function TLanguageChangeModule.Id: string;
begin
  Result := 'language-change';
end;

function TLanguageChangeModule.Title: string;
begin
  Result := rsTitle;
end;

function TLanguageChangeModule.Description: string;
begin
  Result := rsDescription;
end;

function TLanguageChangeModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    SuggestingOptionDef('language', rsOptLanguage, rsOptLanguageHelp),
    SuggestingOptionDef('book', rsOptBook, rsOptBookHelp),
    SuggestingOptionDef('type', rsOptType, rsOptTypeHelp),
    ChecklistOptionDef('project', True, rsOptProject, rsOptProjectHelp),
    SuggestingOptionDef('code', rsOptCode, rsOptCodeHelp),
    OptionDef('name', okString, False, False, rsOptName, rsOptNameHelp),
    ChoiceOptionDef('direction', ['database', 'ltr', 'rtl'], 'database',
      rsOptDirection, rsOptDirectionHelp),
    OptionDef('language-db', okFile, False, False, rsOptLanguageDb, rsOptLanguageDbHelp),
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

{ The projects the filters show, with what they would become. False (and
  reported) if the folder, the code or the database is unusable. }
function PlanAll(const TargetDir: string; Options: TStrings; out Plans: TPlans;
  Reporter: TWBReporter; Quiet: Boolean): Boolean;
var
  SR: TSearchRec;
  List: TStringList;
  Langs, Books, Types: TStringArray;
  Db: TLanguageIndex;
  DbPath, Code, Book, Kind, Res: string;
  Manifest: TJSONObject;
  P: TPlan;
  Lng: TLanguageInfo;
  Known: Boolean;
  I: Integer;
  C: Char;
begin
  Plans := nil;
  Result := False;
  if not DirectoryExists(TargetDir) then
  begin
    Reporter.Error(Format(rsNoTargetDir, [ExcludeTrailingPathDelimiter(TargetDir)]));
    Exit;
  end;
  Code := Trim(Options.Values['code']);
  for C in Code do
    if C in ['_', '/', '\', ' ', '.'] then
    begin
      Reporter.Error(Format(rsBadCode, [C, Code]));
      Exit;
    end;
  DbPath := Options.Values['language-db'];
  if DbPath = '' then
    DbPath := LanguageIndexPath(TargetDir);
  Db := nil;
  if DbPath <> '' then
    try
      Db := TLanguageIndex.Create(DbPath);
      if not Quiet then
        Reporter.Info(Format(rsLanguageDb, [DbPath]));
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsBadLanguageDb, [DbPath, E.Message]));
        Exit;
      end;
    end
  else if not Quiet then
    Reporter.Warn(rsNoLanguageDb);
  if not Quiet and (Code <> '') then
  begin
    if not IsWellFormedTag(Code) then
      Reporter.Warn(Format(rsNotBcp47, [Code]));
    if (Db <> nil) and not Db.Find(Code, Lng) then
      Reporter.Info(Format(rsUnknownCode, [Code]));
  end;

  Langs := SplitList(Options.Values['language']);
  Books := SplitList(Options.Values['book']);
  Types := SplitList(Options.Values['type']);
  List := TStringList.Create;
  try
    if FindFirst(TargetDir + AllFilesMask, faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name[1] <> '.') and ((SR.Attr and faDirectory) <> 0) then
          List.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    List.Sort;
    for I := 0 to List.Count - 1 do
    begin
      if not FileExists(TargetDir + List[I] + PathDelim + 'manifest.json') then
        Continue;
      try
        Manifest := ReadJSONObjectFile(TargetDir + List[I] + PathDelim + 'manifest.json');
      except
        Continue;   // the projects module reports unreadable manifests
      end;
      try
        P := Default(TPlan);
        P.Folder := List[I];
        P.Code := StrField(Manifest, 'target_language.id');
        P.Name := StrField(Manifest, 'target_language.name');
        P.Direction := StrField(Manifest, 'target_language.direction');
        Book := StrField(Manifest, 'project.id');
        Kind := StrField(Manifest, 'type.id');
        Res := StrField(Manifest, 'resource.id');
      finally
        Manifest.Free;
      end;
      if (P.Code = '') or (Book = '') or (Kind = '') or
         not Matches(Langs, [P.Code, LanguageGroup(P.Code)]) or
         not Matches(Books, [Book]) or not Matches(Types, [Kind, Res, Kind + '_' + Res]) then
        Continue;
      P.NewCode := Code;
      if P.NewCode = '' then
        P.NewCode := P.Code;
      Known := (Db <> nil) and Db.Find(P.NewCode, Lng);
      P.NewName := Trim(Options.Values['name']);
      if P.NewName = '' then
        if Known then
          P.NewName := Lng.Name
        else
          P.NewName := P.Name;
      P.NewDirection := Options.Values['direction'];
      if (P.NewDirection <> 'ltr') and (P.NewDirection <> 'rtl') then
        if Known and (Lng.Direction <> '') then
          P.NewDirection := Lng.Direction
        else
          P.NewDirection := P.Direction;
      P.NewFolder := P.NewCode + '_' + Book + '_' + Kind;
      if Res <> '' then
        P.NewFolder := P.NewFolder + '_' + Res;
      if P.NewCode = P.Code then
        P.NewFolder := P.Folder;   // a misnamed folder is the projects module's matter
      Plans := Concat(Plans, [P]);
    end;
  finally
    List.Free;
    Db.Free;
  end;
  Result := True;
end;

function Unchanged(const P: TPlan): Boolean;
begin
  Result := (P.NewCode = P.Code) and (P.NewName = P.Name) and
    (P.NewDirection = P.Direction) and (P.NewFolder = P.Folder);
end;

function ChangeColumn(const P: TPlan; const TargetDir: string): string;
var
  Parts: TStringArray;
begin
  if Unchanged(P) then
    Exit(rsNoChange);
  if (P.NewFolder <> P.Folder) and DirectoryExists(TargetDir + P.NewFolder) then
    Exit(Format(rsFolderTaken, [P.NewFolder]));
  Parts := nil;
  if P.NewCode <> P.Code then
    Parts := Concat(Parts, [Format(rsChangeCode, [P.NewCode])]);
  if P.NewName <> P.Name then
    Parts := Concat(Parts, [Format(rsChangeName, [P.NewName])]);
  if P.NewDirection <> P.Direction then
    Parts := Concat(Parts, [Format(rsChangeDirection, [P.NewDirection])]);
  if P.NewFolder <> P.Folder then
    Parts := Concat(Parts, [Format(rsChangeFolder, [P.NewFolder])]);
  Result := String.Join(', ', Parts);
end;

function TLanguageChangeModule.Choices(const OptionName: string; Options: TStrings;
  Reporter: TWBReporter; out List: TWBChoiceList): Boolean;
var
  Plans: TPlans;
  P: TPlan;
  C: TWBChoice;
  TargetDir: string;
begin
  List.Headers := [rsColLanguage, rsColChange];
  List.Items := nil;
  TargetDir := TargetDirOf(Options);
  Result := PlanAll(TargetDir, Options, Plans, Reporter, True);
  if not Result then
    Exit;
  for P in Plans do
  begin
    C.Value := P.Folder;
    C.Columns := [Format('%s, "%s", %s', [P.Code, P.Name, P.Direction]),
      ChangeColumn(P, TargetDir)];
    List.Items := Concat(List.Items, [C]);
  end;
end;

function SetLanguage(const Dir: string; const P: TPlan; out Failure: string): Boolean;
var
  Manifest, TL: TJSONObject;
  D: TJSONData;
begin
  Result := False;
  Failure := '';
  try
    Manifest := ReadJSONObjectFile(Dir + 'manifest.json');
  except
    on E: Exception do
    begin
      Failure := E.Message;
      Exit;
    end;
  end;
  try
    D := Manifest.Find('target_language');
    if D is TJSONObject then
      TL := TJSONObject(D)
    else
    begin
      if D <> nil then
        Manifest.Delete('target_language');
      TL := TJSONObject.Create;
      Manifest.Add('target_language', TL);
    end;
    TL.Strings['id'] := P.NewCode;
    TL.Strings['name'] := P.NewName;
    TL.Strings['direction'] := P.NewDirection;
    try
      WriteBttJSONFile(Dir + 'manifest.json', Manifest);
    except
      on E: Exception do
      begin
        Failure := E.Message;
        Exit;
      end;
    end;
  finally
    Manifest.Free;
  end;
  Result := True;
end;

function TLanguageChangeModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  TargetDir, Dir, Failure, Renamed, CommitName, CommitEmail, Value: string;
  Wanted: TStringArray;
  Plans: TPlans;
  P: TPlan;
  DryRun, All, Found, CodeChanged: Boolean;
  Changed, Left: Integer;
  R: TGitResult;
begin
  Result := 1;
  TargetDir := TargetDirOf(Options);
  DryRun := OptionIsSet(Options, 'dry-run');
  Wanted := OptionValues(Options, 'project');
  if Length(Wanted) = 0 then
  begin
    Reporter.Error(rsNothingChecked);
    Exit;
  end;
  if not GitAvailable then
  begin
    Reporter.Error(rsNoGit);
    Exit;
  end;
  Reporter.Info(Format(rsFolder, [ExcludeTrailingPathDelimiter(TargetDir)]));
  if not PlanAll(TargetDir, Options, Plans, Reporter, False) then
    Exit;
  All := Contains(Wanted, AllChoices);
  for Value in Wanted do
    if Value <> AllChoices then
    begin
      Found := False;
      for P in Plans do
        if P.Folder = Value then
          Found := True;
      if not Found then
        Reporter.Warn(Format(rsNotFound, [Value]));
    end;

  RepairIdentity(CommitName, CommitEmail);
  Changed := 0;
  Left := 0;
  CodeChanged := False;
  for P in Plans do
  begin
    if not (All or Contains(Wanted, P.Folder)) then
      Continue;
    if Unchanged(P) then
    begin
      Reporter.Info(Format(rsSame, [P.Folder, P.Code, P.Name, P.Direction]));
      Continue;
    end;
    if (P.NewFolder <> P.Folder) and DirectoryExists(TargetDir + P.NewFolder) then
    begin
      Reporter.Warn(Format(rsTaken, [P.Folder, P.NewFolder]));
      Inc(Left);
      Continue;
    end;
    Renamed := '';
    if P.NewFolder <> P.Folder then
      Renamed := Format(rsRenamedTo, [P.NewFolder]);
    if DryRun then
    begin
      Reporter.Info(Format(rsWould, [P.Folder, P.NewCode, P.NewName, P.NewDirection, Renamed]));
      Inc(Changed);
      CodeChanged := CodeChanged or (P.NewCode <> P.Code);
      Continue;
    end;

    Dir := TargetDir + P.Folder + PathDelim;
    if IsDirty(ExcludeTrailingPathDelimiter(Dir)) and
       not CommitAll(ExcludeTrailingPathDelimiter(Dir), rsLooseWork) then
    begin
      Reporter.Warn(Format(rsFailed, [P.Folder, 'git commit']));
      Inc(Left);
      Continue;
    end;
    if not SetLanguage(Dir, P, Failure) then
    begin
      Reporter.Warn(Format(rsFailed, [P.Folder, Failure]));
      Inc(Left);
      Continue;
    end;
    R := RunGit(ExcludeTrailingPathDelimiter(Dir), ['add', 'manifest.json']);
    if R.ExitCode = 0 then
      R := RunGit(ExcludeTrailingPathDelimiter(Dir), ['-c', 'user.name=' + CommitName,
        '-c', 'user.email=' + CommitEmail, 'commit', '-q', '-m',
        Format(rsCommit, [P.Code, P.Name, P.Direction, P.NewCode, P.NewName, P.NewDirection])]);
    if R.ExitCode <> 0 then
    begin
      RunGit(ExcludeTrailingPathDelimiter(Dir), ['checkout', '--', 'manifest.json']);
      Reporter.Warn(Format(rsFailed, [P.Folder, 'git commit: ' + Trim(R.ErrorOutput)]));
      Inc(Left);
      Continue;
    end;
    if (P.NewFolder <> P.Folder) and
       not RenameFile(TargetDir + P.Folder, TargetDir + P.NewFolder) then
    begin
      Reporter.Warn(Format(rsRenameFailed, [P.Folder, P.NewFolder]));
      Inc(Changed);
      Continue;
    end;
    Reporter.Info(Format(rsDone, [P.Folder, P.NewCode, P.NewName, P.NewDirection, Renamed]));
    Inc(Changed);
    CodeChanged := CodeChanged or (P.NewCode <> P.Code);
  end;

  Reporter.Info('');
  if DryRun then
    Reporter.Info(Format(rsWouldSummary, [Changed, Left]))
  else
    Reporter.Info(Format(rsSummary, [Changed, Left]));
  if CodeChanged then
    Reporter.Info(rsAfter);
  Result := 0;
end;

function TLanguageChangeModule.Suggestions(const OptionName: string;
  Options: TStrings): TWBSuggestions;
begin
  { the new code: what the folder has, then every language in the database }
  if OptionName = 'code' then
    Result := MergeSuggestions(FolderSuggestions('language', TargetDirOption(Options)),
      DatabaseLanguages(TargetDirOption(Options)))
  else
    Result := FolderSuggestions(OptionName, TargetDirOption(Options));
end;

initialization
  RegisterModule(TLanguageChangeModule.Create);

end.
