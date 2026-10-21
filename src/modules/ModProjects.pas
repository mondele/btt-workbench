unit ModProjects;

{$mode objfpc}{$H+}

(* projects: list the projects in targetTranslations, like the project
   list in btt-writer-two, with any problems found in each.

   It changes one thing: a project whose git branch is main is moved to
   master, the only branch BTT-Writer uses (gitnative.js: git init -b
   master, then pull and push master by name). --dry-run only reports it.
   It refuses when both branches exist, and only reports other branches
   and a detached HEAD.

   Filters: --language, --book and --type, each a comma-separated list
   (codes, any case). --type matches the project type (text, tn, tq, tw),
   the resource (reg, ulb, udb) or both as text_reg. A project whose
   manifest cannot be read is matched by its folder name instead.

   Problems looked for:
   - not a project (no manifest.json), manifest unreadable or with merge
     conflict markers, missing ids, an unknown project format version;
   - folder name not what BTT-Writer would call it (<lang>_<book>_<type>
     [_<resource>]), which breaks matching on import;
   - the language name or text direction differing from BTT-Writer's
     language database (index.sqlite), which is corrected over time while
     projects keep what it said when they were made; a language code the
     database does not have; a temporary code (qaa-x-...) that has since
     been approved as a real one;
   - manifest fields of the wrong type (finished_chunks not a list of
     strings, source_translations entries without ids, ...);
   - no git history, a damaged repo, an unfinished merge; with
     --deep-git, git fsck for corrupt or missing objects;
   - chunks with unresolved conflicts, and conflict markers BTT-Writer
     Desktop's parser cannot read (render.js: "<<<<<<< HEAD" and
     ">>>>>>> <40-char hash>" only);
   - chunks marked finished that have no file;
   - for text projects, chunk files that do not match the chunking of
     en_ulb or of a source listed in the manifest (BTT-Writer only shows
     chunks its source has, so those are invisible with that source);
   - verse markers in a chunk that the source does not have there, or
     twice. BTT-Writer's validateVerseMarkers drops such markers and adds
     the missing ones at the end of the chunk, so they move when the chunk
     is opened. Checked against the first listed source whose chunking the
     project follows, else en_ulb if it follows that; and always against
     en_ulb too, for the chunks en_ulb has (a project that follows another
     source is still compared with English).

   Sources come from the library next to the projects folder, or from
   BTT-Writer's bundled .tsrc files (WBSources). *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TProjectsModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
    function Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions; override;
  end;

implementation

uses
  WBSuggest, fpjson, WBJson, WBGit, WBDataPaths, WBProject, WBSources, WBLanguages, WBImport,
  WBLangTag, WBCrossScan, WBCrossRepair, WBCrossCheck;

resourcestring
  rsTitle = 'Project list and problems';
  rsDescription = 'Lists the projects in BTT-Writer''s projects folder and ' +
    'any problems with them: damaged manifests or git history, unresolved ' +
    'conflicts, and chunks or verse markers that do not match en_ulb or the ' +
    'project''s source chunking. Two repairs: projects on git branch main are ' +
    'moved to master, the only branch BTT-Writer uses, and a .git folder that ' +
    'has lost HEAD, config or its index while its history is intact (as a ' +
    'copy can leave it) is rebuilt. Nothing else is changed.';
  rsOptDryRun = 'Dry run';
  rsOptDryRunHelp = 'Report what the repairs would do without doing them';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Only these target language codes, comma-separated (e.g. sah,udm; ' +
    'a first part such as mxc takes every code that starts with it)';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only these book codes, comma-separated (e.g. tit,jon)';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these types or resources, comma-separated (text, tn, ' +
    'tq, tw, reg, ulb, or text_reg)';
  rsOptProblemsOnly = 'Problems only';
  rsOptProblemsOnlyHelp = 'List only projects that have problems';
  rsOptDeepGit = 'Check git history in depth';
  rsOptDeepGitHelp = 'Also run git fsck on each project to find corrupt or ' +
    'missing history (slower)';
  rsOptLanguageDb = 'Language database';
  rsOptLanguageDbHelp = 'BTT-Writer''s index.sqlite to compare project ' +
    'languages with (default: the one in BTT-Writer''s library folder, else ' +
    'the one bundled with BTT-Writer)';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';

  rsNoTargetDir = 'Projects folder not found: %s';
  rsFolder = 'Projects folder: %s';
  rsFilter = 'Showing: %s';
  rsFilterLanguage = 'language %s';
  rsFilterBook = 'book %s';
  rsFilterType = 'type %s';
  rsNoBundled = 'BTT-Writer''s bundled source texts were not found, so ' +
    'chunking is only checked against sources BTT-Writer has downloaded. If ' +
    'BTT-Writer is installed, say where in Settings (btw settings ' +
    '--btt-writer <folder>).';
  rsBundled = 'Bundled source texts: %s';
  rsLanguageDb = 'Language database: %s (%d languages)';
  rsNoLanguageDb = 'BTT-Writer''s language database (index.sqlite) was not ' +
    'found, so project languages were not checked.';
  rsBadLanguageDb = 'Cannot read the language database %s (%s), so project ' +
    'languages were not checked.';
  rsLangUnknown = 'Language %s is not in the language database.';
  rsLangApproved = 'Temporary language %s has been approved as %s; the ' +
    'project still uses the temporary code.';
  rsLangName = 'Language name is out of date: the project says "%s", the ' +
    'language database says "%s". Change project language sets it.';
  rsLangDirection = 'Text direction is out of date: the project says %s, the ' +
    'language database says %s. Change project language sets it.';
  rsLangNotBcp47 = 'Language code %s is not a well-formed BCP 47 tag, which ' +
    'tools such as Scripture Burrito need. Change project language can give ' +
    'the project another code.';
  rsMixedNames = 'The projects of %s use %d language names: %s. Change project ' +
    'language can make them one.';
  rsMixedCodes = 'Language %s has projects under %d codes: %s. Change project ' +
    'language can give them one code.';
  rsNoDirection = '(none)';
  rsSummary = '%d project(s) listed, %d with problems.';
  rsSummaryHidden = '%d project(s) without problems not shown.';

  rsHeader = '%s: %s (%s), %s (%s), %s - %s';
  rsProgress = '%d of %d chunks finished';
  rsProgressFiles = '%d chunk files, %d finished';
  rsStrayFile = '%s: a file, not a project folder.';
  rsNoManifest = '%s: no manifest.json, so this is not a BTT-Writer project ' +
    '(or it is damaged).';
  rsManifestConflict = 'manifest.json has unresolved merge conflict markers, ' +
    'so BTT-Writer cannot open the project.';
  rsManifestInvalid = 'manifest.json cannot be read (%s).';
  rsManifestIds = 'manifest.json is missing the language, book or type.';
  rsManifestTypes = 'manifest.json has fields that are missing or of the wrong ' +
    'type: %s';
  rsMatchedByFolder = 'Listed by its folder name, as the manifest cannot be read.';
  rsOldFormat = 'Older project format (version %s); BTT-Writer upgrades it ' +
    'when the project is opened.';
  rsNewFormat = 'Project format version %s is newer than this tool knows; ' +
    'checks may be incomplete.';
  rsFolderName = 'The folder should be named %s. BTT-Writer matches projects ' +
    'by folder name, so imports of this project will not merge with it.';
  rsNoGit = 'No git history. BTT-Writer cannot save versions of this project ' +
    'or merge it.';
  rsBadGit = 'The git history is damaged or empty.';
  rsMidMerge = 'An unfinished merge is in progress.';
  rsDirty = 'Has changes that are not committed yet.';
  rsFsck = 'git fsck found problems in the history: %s';
  rsSummaryRenamed = '%d project(s) moved from git branch main to master.';
  rsSummaryRebuilt = '%d project(s) had their .git folder rebuilt.';
  rsSummaryWouldRebuild = '%d project(s) would have their .git folder rebuilt (dry run).';
  rsOptRemoveExtra = 'Remove extra chunks';
  rsOptRemoveExtraHelp = 'On Run, delete chunk files that no compared source has (the listed ' +
    'sources and en_ulb), when every verse in them is also in another chunk';
  rsExtraChunks = 'Chunks no compared source has: %s.';
  rsExtraLine = '  %s: added by %s; "%s"';
  rsExtraNoHistory = 'not in git history';
  rsExtraHint = ' Remove extra chunks (--remove-extra-chunks) deletes them on Run.';
  rsExtraKept = '%s holds verses no other chunk has (%s); kept, to be sorted out by hand.';
  rsExtraWouldRemove = 'Would remove: %s (dry run).';
  rsExtraRemoved = 'Removed %s, and committed.';
  rsExtraFailed = 'Could not remove the extra chunks: %s';
  rsExtraMessage = 'Remove chunks no source has (BTT Workbench)';
  rsExtraLoose = 'Uncommitted work, before removing extra chunks';
  rsSummaryRemovedExtra = '%d extra chunk(s) removed.';
  rsSummaryWouldRemoveExtra = '%d extra chunk(s) would be removed (dry run).';
  rsSummaryWouldRename = '%d project(s) would be moved from git branch main ' +
    'to master.';
  rsConflicts = '%d chunk(s) have unresolved conflicts: %s';
  rsUnreadableConflicts = '%d chunk(s) have conflict markers BTT-Writer cannot ' +
    'read: %s';
  rsFinishedNoFile = 'Marked finished but have no file: %s';
  rsNotChecked = 'Chunking is only checked for text projects.';
  rsSourceMissing = 'Source %s is neither downloaded nor bundled with ' +
    'BTT-Writer, so its chunking was not checked.';
  rsUnknownBook = 'No en_ulb text for book "%s"; is the book code right?';
  rsSourceListed = '%s (listed as a source)';
  rsSourceAlways = '%s (always compared)';
  rsSourceLine = 'Compared with %s: %s.';
  rsNoExtra = 'no extra chunks';
  rsExtra = 'extra chunks (not in it; BTT-Writer does not show them with it): %s';
  rsNoMissing = 'no chunks missing';
  rsMissing = 'missing %s';
  rsMissingCovered = 'missing %s, whose verses are in other chunks here';
  rsNoOutside = 'verse markers all in its chunks';
  rsOutside = 'verse markers outside its chunks (BTT-Writer drops them when the chunk ' +
    'is opened with it): %s';
  rsMatches = 'Matches %s: nothing is lost when the project is opened with it.';
  rsOthersDiffer = ' The differences from %s are only another chunking; they matter only ' +
    'if the project is opened with that source.';
  rsNoneMatches = 'No compared source matches this project''s chunks and verse markers.';
  rsVersesTwice = 'Verse markers given twice in one chunk: %s';
  rsMore = '%s and %d more';

const
  ListLimit = 20;
  ProjectManifestVersion = 8;


function ShortList(const Items: TStringArray): string;
var
  Shown: TStringArray;
  I: Integer;
begin
  if Length(Items) <= ListLimit then
    Exit(String.Join(', ', Items));
  SetLength(Shown, ListLimit);
  for I := 0 to ListLimit - 1 do
    Shown[I] := Items[I];
  Result := Format(rsMore, [String.Join(', ', Shown), Length(Items) - ListLimit]);
end;

function ReadText(const FileName: string): string;
var
  F: TFileStream;
begin
  Result := '';
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

function ChunkLabel(const C: TProjectChunk): string;
begin
  Result := C.Chapter + '-' + C.Chunk;
end;

{ 'ok', 'none' or 'bad': whether a file's conflict markers are ones
  Desktop's parser accepts. }
function ConflictState(const FileName: string): string;
var
  L: TStringList;
  Line, Rest: string;
  I: Integer;
  Hex: Boolean;
begin
  Result := 'none';
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    for Line in L do
    begin
      if Copy(Line, 1, 7) = '<<<<<<<' then
      begin
        if Result = 'none' then
          Result := 'ok';
        if Line <> '<<<<<<< HEAD' then
          Exit('bad');
      end
      else if Copy(Line, 1, 7) = '|||||||' then
        Exit('bad')
      else if Copy(Line, 1, 7) = '>>>>>>>' then
      begin
        Rest := Copy(Line, 9, MaxInt);
        Hex := (Copy(Line, 8, 1) = ' ') and (Length(Rest) = 40);
        for I := 1 to Length(Rest) do
          if not (Rest[I] in ['0'..'9', 'a'..'z', 'A'..'Z', '_']) then
            Hex := False;
        if not Hex then
          Exit('bad');
      end;
    end;
  finally
    L.Free;
  end;
end;

function IntIn(const Items: TVerseList; V: Integer): Boolean;
var
  X: Integer;
begin
  for X in Items do
    if X = V then
      Exit(True);
  Result := False;
end;

{ Project chunks the source does not have. }
function ExtraChunks(const Chunks: TProjectChunks; Source: TSourceChunking): TStringArray;
var
  C: TProjectChunk;
begin
  Result := nil;
  for C in Chunks do
    if Source.IndexOf(C.Chapter, C.Chunk) < 0 then
      Result := Concat(Result, [ChunkLabel(C)]);
end;

{ Whether the project has a file for Chapter-Chunk. }
function HasChunk(const Chunks: TProjectChunks; const Chapter, Chunk: string): Boolean;
var
  C: TProjectChunk;
begin
  for C in Chunks do
    if (C.Chapter = Chapter) and (C.Chunk = Chunk) then
      Exit(True);
  Result := False;
end;

{ The verse markers of all the project's chunks in Chapter. }
function ChapterMarkers(const Chunks: TProjectChunks; const Chapter: string): TVerseList;
var
  C: TProjectChunk;
begin
  Result := nil;
  for C in Chunks do
    if C.Chapter = Chapter then
      Result := Concat(Result, UsfmVerseMarkers(ReadText(C.Path)));
end;

function AllIn(const A, B: TVerseList): Boolean;
var
  V: Integer;
begin
  for V in A do
    if not IntIn(B, V) then
      Exit(False);
  Result := True;
end;

type
  { How the project compares with one source. }
  TSourceReport = record
    Name: string;
    IsListed: Boolean;
    Extra: TStringArray;     // chunks here it does not have
    Missing: TStringArray;   // its chunks with no file here
    Covered: TStringArray;   // ... whose verses are in other chunks here
    Outside: TStringArray;   // verse markers outside its chunk
  end;

{ Source chunks with no project file. }
function MissingChunks(const Chunks: TProjectChunks; Source: TSourceChunking): TStringArray;
var
  Have: TStringList;
  C: TProjectChunk;
  S: TSourceChunk;
begin
  Result := nil;
  Have := TStringList.Create;
  try
    Have.Sorted := True;
    for C in Chunks do
      Have.Add(ChunkKey(C.Chapter, C.Chunk));
    for S in Source.Chunks do
      if Have.IndexOf(ChunkKey(S.Chapter, S.Chunk)) < 0 then
        Result := Concat(Result, [S.Chapter + '-' + S.Chunk]);
  finally
    Have.Free;
  end;
end;

{ Manifest fields BTT-Writer reads that are present with the wrong type,
  and source_translations entries without their ids. Missing language,
  book and type ids are reported separately (rsManifestIds). }
type
  TJSONKinds = set of TJSONtype;

const
  ManifestObjects: array of string = ('target_language', 'project', 'type', 'resource');
  SourceIds: array of string = ('language_id', 'resource_id');

function ManifestTypeProblems(M: TJSONObject): TStringArray;
var
  Bad: TStringArray;

  procedure Need(const Path: string; Kinds: TJSONKinds);
  var
    D: TJSONData;
  begin
    D := M.FindPath(Path);
    if (D <> nil) and not (D.JSONType in Kinds) then
      Bad := Concat(Bad, [Path]);
  end;

var
  D, Item: TJSONData;
  I: Integer;
  Key: string;
begin
  Bad := nil;
  Need('package_version', [jtNumber]);
  for Key in ManifestObjects do
  begin
    Need(Key, [jtObject]);
    if M.Find(Key) is TJSONObject then
    begin
      Need(Key + '.id', [jtString]);
      Need(Key + '.name', [jtString]);
    end;
  end;
  Need('translators', [jtArray]);
  D := M.Find('finished_chunks');
  if (D <> nil) and (D.JSONType <> jtArray) then
    Bad := Concat(Bad, ['finished_chunks'])
  else if D <> nil then
    for I := 0 to D.Count - 1 do
      if D.Items[I].JSONType <> jtString then
        Bad := Concat(Bad, [Format('finished_chunks[%d]', [I])]);
  D := M.Find('source_translations');
  if (D <> nil) and (D.JSONType <> jtArray) then
    Bad := Concat(Bad, ['source_translations'])
  else if D <> nil then
    for I := 0 to D.Count - 1 do
    begin
      Item := D.Items[I];
      if not (Item is TJSONObject) then
        Bad := Concat(Bad, [Format('source_translations[%d]', [I])])
      else
        for Key in SourceIds do
          if (TJSONObject(Item).Find(Key) = nil) or
             (TJSONObject(Item).Find(Key).JSONType <> jtString) or
             (TJSONObject(Item).Find(Key).AsString = '') then
            Bad := Concat(Bad, [Format('source_translations[%d].%s', [I, Key])]);
    end;
  Result := Bad;
end;

{ First lines of git fsck's complaints, or '' if the history is sound. }
function FsckProblems(const Dir: string): string;
var
  G: TGitResult;
  Lines: TStringArray;
  Line: string;
  Shown: TStringArray;
begin
  G := RunGit(Dir, ['fsck', '--no-progress', '--no-dangling']);
  if G.ExitCode = 0 then
    Exit('');
  Shown := nil;
  Lines := (G.ErrorOutput + #10 + G.Output).Split([#10]);
  for Line in Lines do
    if Trim(Line) <> '' then
      Shown := Concat(Shown, [Trim(Line)]);
  if Length(Shown) = 0 then
    Exit(Format('exit code %d', [G.ExitCode]));
  Result := ShortList(Shown);
end;

{ Messages for one project. Problems are warnings; the rest is info. }
{ Chunk files no compared source has. Each is removable when every verse
  marker in it is also in a chunk that stays (none would be lost); with
  RemoveExtra they are deleted, taken out of finished_chunks and committed
  (dry run: only said). Removed counts them. }
procedure HandleExtraChunks(const Dir: string; const Chunks: TProjectChunks;
  const Containers, Conflicted: TStringArray; Sources: TSourceLibrary;
  RemoveExtra, DryRun: Boolean; var Removed: Integer; R: TWBReporter);
var
  C: TProjectChunk;
  Extra, Removable, Labels: TStringArray;
  Items: TRepairItems;
  Item: TRepairItem;
  Others: TVerseList;
  Own, Lost, Added: string;
  Container, Failure, CommitName, CommitEmail: string;
  Found, InSome: Boolean;
  V: Integer;
begin
  Found := False;
  for Container in Containers do
    if Sources.Find(Container) <> nil then
      Found := True;
  if not Found then
    Exit;   // nothing to judge by
  Extra := nil;
  for C in Chunks do
  begin
    if (C.Chunk = 'title') or Contains(Conflicted, ChunkLabel(C)) then
      Continue;
    InSome := False;
    for Container in Containers do
      if (Sources.Find(Container) <> nil) and
         (Sources.Find(Container).IndexOf(C.Chapter, C.Chunk) >= 0) then
        InSome := True;
    if not InSome then
      Extra := Concat(Extra, [ChunkLabel(C)]);
  end;
  if Length(Extra) = 0 then
    Exit;
  { the verses of the chunks that stay }
  Others := nil;
  for C in Chunks do
    if not Contains(Extra, ChunkLabel(C)) then
      Others := Concat(Others, UsfmVerseMarkers(ReadText(C.Path)));
  Removable := nil;
  Items := nil;
  for C in Chunks do
  begin
    if not Contains(Extra, ChunkLabel(C)) then
      Continue;
    Lost := '';
    for V in UsfmVerseMarkers(ReadText(C.Path)) do
      if not IntIn(Others, V) then
      begin
        if Lost <> '' then
          Lost := Lost + ', ';
        Lost := Lost + IntToStr(V);
      end;
    if Lost <> '' then
    begin
      R.Warn(Format(rsExtraKept, [ChunkLabel(C), Lost]));
      Continue;
    end;
    Removable := Concat(Removable, [ChunkLabel(C)]);
    Item := Default(TRepairItem);
    Item.Chapter := C.Chapter;
    Item.Chunk := C.Chunk;
    Item.Action := raRemove;
    Items := Concat(Items, [Item]);
  end;
  Own := String.Join(', ', Extra);
  if not RemoveExtra or (Length(Removable) = 0) then
  begin
    if Length(Removable) > 0 then
      R.Warn(Format(rsExtraChunks, [Own]) + rsExtraHint)
    else
      R.Warn(Format(rsExtraChunks, [Own]));
  end
  else
    R.Warn(Format(rsExtraChunks, [Own]));
  { what each holds and where it came from, to judge before removing }
  for C in Chunks do
    if Contains(Extra, ChunkLabel(C)) then
    begin
      Added := Trim(RunGit(ExcludeTrailingPathDelimiter(Dir), ['log', '--diff-filter=A',
        '--format=%h (%ad, %an)', '--date=format:%Y-%m-%d', '-1', '--',
        C.Chapter + '/' + C.Chunk + '.txt']).Output);
      if Added = '' then
        Added := rsExtraNoHistory;
      R.Info(Format(rsExtraLine, [ChunkLabel(C), Added,
        Copy(NormalText(ReadText(C.Path)), 1, 70) + '...']));
    end;
  if not RemoveExtra or (Length(Removable) = 0) then
    Exit;
  Labels := Removable;
  if DryRun then
  begin
    R.Warn(Format(rsExtraWouldRemove, [String.Join(', ', Labels)]));
    Inc(Removed, Length(Removable));
    Exit;
  end;
  if IsDirty(ExcludeTrailingPathDelimiter(Dir)) and
     not CommitAll(ExcludeTrailingPathDelimiter(Dir), rsExtraLoose) then
  begin
    R.Error(Format(rsExtraFailed, ['git commit']));
    Exit;
  end;
  RepairIdentity(CommitName, CommitEmail);
  if not ApplyRepairs(Dir, Items, rsExtraMessage + #10#10 + String.Join(#10, Labels),
     CommitName, CommitEmail, Failure) then
  begin
    R.Error(Format(rsExtraFailed, [Failure]));
    Exit;
  end;
  R.Warn(Format(rsExtraRemoved, [String.Join(', ', Labels)]));
  Inc(Removed, Length(Removable));
end;

procedure CheckProject(const Dir, Name: string; Manifest: TJSONObject;
  Sources: TSourceLibrary; Languages: TLanguageIndex; DeepGit, DryRun, RemoveExtra: Boolean;
  var Renamed, Rebuilt, RemovedExtra: Integer; R: TWBReporter);
var
  Chunks: TProjectChunks;
  C: TProjectChunk;
  Lang, Book, Kind, Res, Version, Expected, State, Container, TypeLabel,
    Progress, Fsck, ProjectDir: string;
  Lng: TLanguageInfo;
  Conflicted, Unreadable, Finished, NoFile, Extra, Missing, Twice, Containers, Differ,
    Parts: TStringArray;
  Reports: array of TSourceReport;
  Matching: Integer;
  Line: string;
  Listed: TStringArray;
  Src, FollowSrc, EnUlb: TSourceChunking;
  Have: TStringList;
  I, Idx, Total: Integer;
  Markers: TVerseList;
  Seen: TVerseList;
  V: Integer;
  Entries: TJSONData;
begin
  Lang := StrField(Manifest, 'target_language.id');
  Book := StrField(Manifest, 'project.id');
  Kind := StrField(Manifest, 'type.id');
  Res := StrField(Manifest, 'resource.id');
  Chunks := ProjectChunks(Dir);
  Finished := StringsOf(Manifest.Find('finished_chunks'));

  { Sources to compare with: those listed in the manifest, then en_ulb. }
  Listed := nil;
  Entries := Manifest.Find('source_translations');
  if (Entries <> nil) and (Entries.JSONType = jtArray) then
    for I := 0 to Entries.Count - 1 do
      if (Entries.Items[I] is TJSONObject) and
         (StrField(TJSONObject(Entries.Items[I]), 'language_id') <> '') and
         (StrField(TJSONObject(Entries.Items[I]), 'resource_id') <> '') then
      begin
        Container := StrField(TJSONObject(Entries.Items[I]), 'language_id') + '_' + Book +
          '_' + StrField(TJSONObject(Entries.Items[I]), 'resource_id');
        if not Contains(Listed, Container) then
          Listed := Concat(Listed, [Container]);
      end;
  Containers := Copy(Listed);
  if not Contains(Containers, 'en_' + Book + '_ulb') then
    Containers := Concat(Containers, ['en_' + Book + '_ulb']);

  EnUlb := nil;
  FollowSrc := nil;
  if Kind = 'text' then
  begin
    EnUlb := Sources.Find('en_' + Book + '_ulb');
    for Container in Containers do
    begin
      Src := Sources.Find(Container);
      if (Src <> nil) and (FollowSrc = nil) and (Length(ExtraChunks(Chunks, Src)) = 0) then
        FollowSrc := Src;
    end;
  end;

  { Header: name, language, book, type, progress. }
  if FollowSrc <> nil then
    Total := Length(FollowSrc.Chunks)
  else if EnUlb <> nil then
    Total := Length(EnUlb.Chunks)
  else
    Total := 0;
  TypeLabel := Kind;
  if Res <> '' then
    TypeLabel := Kind + '/' + Res;
  if Total > 0 then
    Progress := Format(rsProgress, [Length(Finished), Total])
  else
    Progress := Format(rsProgressFiles, [Length(Chunks), Length(Finished)]);
  R.Info(Format(rsHeader, [Name, StrField(Manifest, 'target_language.name'), Lang,
    StrField(Manifest, 'project.name'), Book, TypeLabel, Progress]));

  if (Lang = '') or (Book = '') or (Kind = '') then
    R.Warn(rsManifestIds);
  Extra := ManifestTypeProblems(Manifest);
  if Length(Extra) > 0 then
    R.Warn(Format(rsManifestTypes, [ShortList(Extra)]));

  if (Lang <> '') and not IsWellFormedTag(Lang) then
    R.Warn(Format(rsLangNotBcp47, [Lang]));
  { Language against BTT-Writer's language database }
  if (Languages <> nil) and (Lang <> '') then
  begin
    if not Languages.Find(Lang, Lng) then
      R.Warn(Format(rsLangUnknown, [Lang]))
    else if Lng.IsTemp and (Lng.ApprovedAs <> '') then
      R.Warn(Format(rsLangApproved, [Lang, Lng.ApprovedAs]))
    else
    begin
      if StrField(Manifest, 'target_language.name') <> Lng.Name then
        R.Warn(Format(rsLangName, [StrField(Manifest, 'target_language.name'), Lng.Name]));
      ProjectDir := StrField(Manifest, 'target_language.direction');
      if ProjectDir <> Lng.Direction then
      begin
        if ProjectDir = '' then
          ProjectDir := rsNoDirection;
        R.Warn(Format(rsLangDirection, [ProjectDir, Lng.Direction]));
      end;
    end;
  end;
  Version := StrField(Manifest, 'package_version');
  if StrToIntDef(Version, 0) < ProjectManifestVersion then
    R.Info(Format(rsOldFormat, [Version]))
  else if StrToIntDef(Version, 0) > ProjectManifestVersion then
    R.Warn(Format(rsNewFormat, [Version]));

  Expected := ProjectFolderName(Manifest, Name);
  if Expected <> Name then
    R.Warn(Format(rsFolderName, [Expected]));

  { Git }
  if RepairGitFolder(Dir, DryRun, R) then
    Inc(Rebuilt);
  if FixBranch(Dir, DryRun, R) then
    Inc(Renamed);
  if not DirectoryExists(Dir + '.git') then
    R.Warn(rsNoGit)
  else if RunGit(Dir, ['rev-parse', '--verify', '-q', 'HEAD']).ExitCode <> 0 then
    R.Warn(rsBadGit)
  else
  begin
    if FileExists(Dir + '.git' + PathDelim + 'MERGE_HEAD') then
      R.Warn(rsMidMerge);
    if Trim(RunGit(Dir, ['status', '--porcelain']).Output) <> '' then
      R.Info(rsDirty);
    if DeepGit then
    begin
      Fsck := FsckProblems(Dir);
      if Fsck <> '' then
        R.Warn(Format(rsFsck, [Fsck]));
    end;
  end;

  { Conflicts, finished chunks without files }
  Conflicted := nil;
  Unreadable := nil;
  Have := TStringList.Create;
  try
    Have.Sorted := True;
    for C in Chunks do
    begin
      Have.Add(ChunkLabel(C));
      State := ConflictState(C.Path);
      if State = 'ok' then
        Conflicted := Concat(Conflicted, [ChunkLabel(C)])
      else if State = 'bad' then
        Unreadable := Concat(Unreadable, [ChunkLabel(C)]);
    end;
    NoFile := nil;
    for Container in Finished do
      if Have.IndexOf(Container) < 0 then
        NoFile := Concat(NoFile, [Container]);
  finally
    Have.Free;
  end;
  if Length(Conflicted) > 0 then
    R.Warn(Format(rsConflicts, [Length(Conflicted), ShortList(Conflicted)]));
  if Length(Unreadable) > 0 then
    R.Warn(Format(rsUnreadableConflicts, [Length(Unreadable), ShortList(Unreadable)]));
  if Length(NoFile) > 0 then
    R.Warn(Format(rsFinishedNoFile, [ShortList(NoFile)]));

  { Chunking }
  if Kind <> 'text' then
  begin
    R.Info(rsNotChecked);
    Exit;
  end;
  for Container in Containers do
    if Sources.Find(Container) = nil then
      R.Info(Format(rsSourceMissing, [Container]));
  if (FollowSrc = nil) and (EnUlb = nil) and (Book <> '') and (Sources.Find(Containers[0]) = nil) then
  begin
    R.Warn(Format(rsUnknownBook, [Book]));
    Exit;
  end;

  { Each source found: chunks here it does not have, its chunks with no
    file here (those whose verses are in other chunks here apart), and
    verse markers outside its chunk. A source with no extra chunks and no
    misplaced markers matches; differences from a listed source are
    problems (BTT-Writer opens the project with it), from en_ulb only when
    nothing matches. }
  Reports := nil;
  Matching := -1;
  for Container in Containers do
  begin
    Src := Sources.Find(Container);
    if Src = nil then
      Continue;
    SetLength(Reports, Length(Reports) + 1);
    with Reports[High(Reports)] do
    begin
      Name := Container;
      IsListed := Contains(Listed, Container);
      Extra := ExtraChunks(Chunks, Src);
      Missing := nil;
      Covered := nil;
      for I := 0 to High(Src.Chunks) do
        if not HasChunk(Chunks, Src.Chunks[I].Chapter, Src.Chunks[I].Chunk) then
          if (Length(Src.Chunks[I].Verses) > 0) and
             AllIn(Src.Chunks[I].Verses, ChapterMarkers(Chunks, Src.Chunks[I].Chapter)) then
            Covered := Concat(Covered, [Src.Chunks[I].Chapter + '-' + Src.Chunks[I].Chunk])
          else
            Missing := Concat(Missing, [Src.Chunks[I].Chapter + '-' + Src.Chunks[I].Chunk]);
      Outside := nil;
      for C in Chunks do
      begin
        if Contains(Conflicted, ChunkLabel(C)) or Contains(Unreadable, ChunkLabel(C)) then
          Continue;
        Idx := Src.IndexOf(C.Chapter, C.Chunk);
        if (Idx < 0) or (Length(Src.Chunks[Idx].Verses) = 0) then
          Continue;
        for V in UsfmVerseMarkers(ReadText(C.Path)) do
          if not IntIn(Src.Chunks[Idx].Verses, V) and
             not Contains(Outside, ChunkLabel(C) + ' \v ' + IntToStr(V)) then
            Outside := Concat(Outside, [ChunkLabel(C) + ' \v ' + IntToStr(V)]);
      end;
      if (Matching < 0) and (Length(Extra) = 0) and (Length(Outside) = 0) then
        Matching := High(Reports);
    end;
  end;
  Differ := nil;
  for I := 0 to High(Reports) do
    with Reports[I] do
    begin
      if IsListed then
        Line := Format(rsSourceListed, [Name])
      else
        Line := Format(rsSourceAlways, [Name]);
      if Length(Extra) = 0 then
        Parts := [rsNoExtra]
      else
        Parts := [Format(rsExtra, [ShortList(Extra)])];
      if (Length(Missing) = 0) and (Length(Covered) = 0) then
        Parts := Concat(Parts, [rsNoMissing]);
      if Length(Missing) > 0 then
        Parts := Concat(Parts, [Format(rsMissing, [ShortList(Missing)])]);
      if Length(Covered) > 0 then
        Parts := Concat(Parts, [Format(rsMissingCovered, [ShortList(Covered)])]);
      if Length(Outside) = 0 then
        Parts := Concat(Parts, [rsNoOutside])
      else
        Parts := Concat(Parts, [Format(rsOutside, [ShortList(Outside)])]);
      Line := Format(rsSourceLine, [Line, String.Join('; ', Parts)]);
      if (Length(Extra) + Length(Outside) > 0) and (IsListed or (Matching < 0)) then
        R.Warn(Line)
      else
        R.Info(Line);
      if (I <> Matching) and (Length(Extra) + Length(Outside) > 0) then
        Differ := Concat(Differ, [Name]);
    end;
  if Matching >= 0 then
  begin
    Line := Format(rsMatches, [Reports[Matching].Name]);
    if Length(Differ) > 0 then
      Line := Line + Format(rsOthersDiffer, [String.Join(', ', Differ)]);
    R.Info(Line);
  end
  else if Length(Reports) > 1 then
    R.Warn(rsNoneMatches);

  { verse markers given twice in one chunk }
  Twice := nil;
  for C in Chunks do
  begin
    if Contains(Conflicted, ChunkLabel(C)) or Contains(Unreadable, ChunkLabel(C)) then
      Continue;
    Seen := nil;
    for V in UsfmVerseMarkers(ReadText(C.Path)) do
    begin
      if IntIn(Seen, V) then
        Twice := Concat(Twice, [ChunkLabel(C) + ' \v ' + IntToStr(V)]);
      Seen := Concat(Seen, [V]);
    end;
  end;
  if Length(Twice) > 0 then
    R.Warn(Format(rsVersesTwice, [ShortList(Twice)]));

  HandleExtraChunks(Dir, Chunks, Containers, Conflicted, Sources, RemoveExtra, DryRun,
    RemovedExtra, R);
end;

{ --- module --- }

function TProjectsModule.Id: string;
begin
  Result := 'projects';
end;

function TProjectsModule.Title: string;
begin
  Result := rsTitle;
end;

function TProjectsModule.Description: string;
begin
  Result := rsDescription;
end;

function TProjectsModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    SuggestingOptionDef('language', rsOptLanguage, rsOptLanguageHelp),
    SuggestingOptionDef('book', rsOptBook, rsOptBookHelp),
    SuggestingOptionDef('type', rsOptType, rsOptTypeHelp),
    OptionDef('problems-only', okFlag, False, False, rsOptProblemsOnly, rsOptProblemsOnlyHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp),
    OptionDef('deep-git', okFlag, False, False, rsOptDeepGit, rsOptDeepGitHelp),
    OptionDef('remove-extra-chunks', okFlag, False, False, rsOptRemoveExtra, rsOptRemoveExtraHelp),
    OptionDef('language-db', okFile, False, False, rsOptLanguageDb, rsOptLanguageDbHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp)];
end;

function TProjectsModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  TargetDir, Name, Dir, Bundled, FilterText: string;
  Langs, Books, Types: TStringArray;
  ProblemsOnly, HasProblem, Filtered, DeepGit, DryRun: Boolean;
  Renamed, Rebuilt, RemovedExtra: Integer;
  RemoveExtra: Boolean;
  Names: TStringList;
  SR: TSearchRec;
  Sources: TSourceLibrary;
  Languages: TLanguageIndex;
  LanguageDb: string;
  Buffer: TWBListReporter;
  Manifest: TJSONObject;
  ManifestText: string;
  Listed, WithProblems, Hidden, I, J: Integer;
  LangNames: TStringList;   // code#9name, sorted, once each

  { Several names for one code, several codes for one language. }
  procedure ReportMixed;
  var
    K, N: Integer;
    Key, Code, List: string;
    Groups: TStringList;    // group#9code
  begin
    K := 0;
    while K < LangNames.Count do
    begin
      Code := Copy(LangNames[K], 1, Pos(#9, LangNames[K]) - 1);
      List := '';
      N := 0;
      while (K < LangNames.Count) and
            (Copy(LangNames[K], 1, Pos(#9, LangNames[K]) - 1) = Code) do
      begin
        if List <> '' then
          List := List + ', ';
        List := List + '"' + Copy(LangNames[K], Pos(#9, LangNames[K]) + 1, MaxInt) + '"';
        Inc(N);
        Inc(K);
      end;
      if N > 1 then
        Reporter.Warn(Format(rsMixedNames, [Code, N, List]));
    end;
    Groups := TStringList.Create;
    try
      Groups.UseLocale := False;
      Groups.CaseSensitive := True;
      Groups.Sorted := True;
      Groups.Duplicates := dupIgnore;
      for K := 0 to LangNames.Count - 1 do
      begin
        Code := Copy(LangNames[K], 1, Pos(#9, LangNames[K]) - 1);
        Groups.Add(LanguageGroup(Code) + #9 + Code);
      end;
      K := 0;
      while K < Groups.Count do
      begin
        Key := Copy(Groups[K], 1, Pos(#9, Groups[K]) - 1);
        List := '';
        N := 0;
        while (K < Groups.Count) and (Copy(Groups[K], 1, Pos(#9, Groups[K]) - 1) = Key) do
        begin
          if List <> '' then
            List := List + ', ';
          List := List + Copy(Groups[K], Pos(#9, Groups[K]) + 1, MaxInt);
          Inc(N);
          Inc(K);
        end;
        if N > 1 then
          Reporter.Warn(Format(rsMixedCodes, [Key, N, List]));
      end;
    finally
      Groups.Free;
    end;
  end;

begin
  Result := 1;
  if Options.Values['target-dir'] <> '' then
    TargetDir := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    TargetDir := TargetTranslationsPath;
  if not DirectoryExists(TargetDir) then
  begin
    Reporter.Error(Format(rsNoTargetDir, [ExcludeTrailingPathDelimiter(TargetDir)]));
    Exit;
  end;
  Langs := SplitList(Options.Values['language']);
  Books := SplitList(Options.Values['book']);
  Types := SplitList(Options.Values['type']);
  ProblemsOnly := OptionIsSet(Options, 'problems-only');
  DeepGit := OptionIsSet(Options, 'deep-git');
  RemoveExtra := OptionIsSet(Options, 'remove-extra-chunks');
  RemovedExtra := 0;
  DryRun := OptionIsSet(Options, 'dry-run');
  Renamed := 0;
  Rebuilt := 0;
  Filtered := (Length(Langs) > 0) or (Length(Books) > 0) or (Length(Types) > 0);

  Reporter.Info(Format(rsFolder, [ExcludeTrailingPathDelimiter(TargetDir)]));
  if Filtered then
  begin
    FilterText := '';
    if Length(Langs) > 0 then
      FilterText := Format(rsFilterLanguage, [String.Join(', ', Langs)]);
    if Length(Books) > 0 then
    begin
      if FilterText <> '' then
        FilterText := FilterText + '; ';
      FilterText := FilterText + Format(rsFilterBook, [String.Join(', ', Books)]);
    end;
    if Length(Types) > 0 then
    begin
      if FilterText <> '' then
        FilterText := FilterText + '; ';
      FilterText := FilterText + Format(rsFilterType, [String.Join(', ', Types)]);
    end;
    Reporter.Info(Format(rsFilter, [FilterText]));
  end;
  Bundled := BundledSourcesPath;
  if Bundled = '' then
    Reporter.Warn(rsNoBundled)
  else
    Reporter.Info(Format(rsBundled, [ExcludeTrailingPathDelimiter(Bundled)]));

  Languages := nil;
  LanguageDb := Options.Values['language-db'];
  if LanguageDb = '' then
    LanguageDb := LanguageIndexPath(TargetDir);
  if LanguageDb = '' then
    Reporter.Warn(rsNoLanguageDb)
  else
    try
      Languages := TLanguageIndex.Create(LanguageDb);
      Reporter.Info(Format(rsLanguageDb, [LanguageDb, Languages.Count]));
    except
      on E: Exception do
        Reporter.Warn(Format(rsBadLanguageDb, [LanguageDb, E.Message]));
    end;

  Names := TStringList.Create;
  LangNames := TStringList.Create;
  LangNames.UseLocale := False;     // ordinal: locale order ignores tab and '-'
  LangNames.CaseSensitive := True;
  LangNames.Sorted := True;
  LangNames.Duplicates := dupIgnore;
  Sources := TSourceLibrary.Create(LibrarySourcesPath(TargetDir), Bundled);
  try
    if FindFirst(TargetDir + AllFilesMask, faAnyFile or faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Name[1] <> '.') then
          Names.AddObject(SR.Name, TObject(PtrInt(Ord((SR.Attr and faDirectory) <> 0))));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Names.Sort;

    Listed := 0;
    WithProblems := 0;
    Hidden := 0;
    for I := 0 to Names.Count - 1 do
    begin
      Name := Names[I];
      Dir := TargetDir + Name + PathDelim;
      Buffer := TWBListReporter.Create;
      Manifest := nil;
      try
        if PtrInt(Names.Objects[I]) = 0 then
        begin
          if Filtered then
            Continue;
          Buffer.Warn(Format(rsStrayFile, [Name]));
        end
        else if not FileExists(Dir + 'manifest.json') then
        begin
          if Filtered and not FolderMatches(Name, Langs, Books, Types, False) then
            Continue;
          Buffer.Warn(Format(rsNoManifest, [Name]));
        end
        else
        begin
          try
            Manifest := ReadJSONObjectFile(Dir + 'manifest.json');
          except
            on E: Exception do
            begin
              if Filtered and not FolderMatches(Name, Langs, Books, Types, True) then
                Continue;
              Buffer.Info(Name);
              if Filtered then
                Buffer.Info(rsMatchedByFolder);
              ManifestText := ReadText(Dir + 'manifest.json');
              if Pos('<<<<<<<', ManifestText) > 0 then
                Buffer.Warn(rsManifestConflict)
              else
                Buffer.Warn(Format(rsManifestInvalid, [E.Message]));
              if RepairGitFolder(Dir, DryRun, Buffer) then
                Inc(Rebuilt);
              if FixBranch(Dir, DryRun, Buffer) then
                Inc(Renamed);
            end;
          end;
          if Manifest <> nil then
          begin
            if not (Matches(Langs, [StrField(Manifest, 'target_language.id'),
                      LanguageGroup(StrField(Manifest, 'target_language.id'))]) and
                    Matches(Books, [StrField(Manifest, 'project.id')]) and
                    Matches(Types, [StrField(Manifest, 'type.id'),
                      StrField(Manifest, 'resource.id'),
                      StrField(Manifest, 'type.id') + '_' + StrField(Manifest, 'resource.id')])) then
              Continue;
            CheckProject(Dir, Name, Manifest, Sources, Languages, DeepGit, DryRun, RemoveExtra,
              Renamed, Rebuilt, RemovedExtra, Buffer);
            if StrField(Manifest, 'target_language.id') <> '' then
              LangNames.Add(StrField(Manifest, 'target_language.id') + #9 +
                StrField(Manifest, 'target_language.name'));
          end;
        end;

        HasProblem := False;
        for J := 0 to Buffer.Count - 1 do
          if Buffer.Levels[J] <> mlInfo then
            HasProblem := True;
        Inc(Listed);
        if HasProblem then
          Inc(WithProblems);
        if ProblemsOnly and not HasProblem then
        begin
          Inc(Hidden);
          Continue;
        end;
        Reporter.Info('');
        for J := 0 to Buffer.Count - 1 do
          Reporter.Message(Buffer.Levels[J], Buffer.Texts[J]);
      finally
        Manifest.Free;
        Buffer.Free;
      end;
    end;

    Reporter.Info('');
    ReportMixed;
    Reporter.Info(Format(rsSummary, [Listed, WithProblems]));
    if Hidden > 0 then
      Reporter.Info(Format(rsSummaryHidden, [Hidden]));
    if RemovedExtra > 0 then
      if DryRun then
        Reporter.Warn(Format(rsSummaryWouldRemoveExtra, [RemovedExtra]))
      else
        Reporter.Warn(Format(rsSummaryRemovedExtra, [RemovedExtra]));
    if Rebuilt > 0 then
      if DryRun then
        Reporter.Warn(Format(rsSummaryWouldRebuild, [Rebuilt]))
      else
        Reporter.Warn(Format(rsSummaryRebuilt, [Rebuilt]));
    if Renamed > 0 then
      if DryRun then
        Reporter.Warn(Format(rsSummaryWouldRename, [Renamed]))
      else
        Reporter.Warn(Format(rsSummaryRenamed, [Renamed]));
    Result := 0;
  finally
    Languages.Free;
    Sources.Free;
    LangNames.Free;
    Names.Free;
  end;
end;

function TProjectsModule.Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions;
begin
  Result := FolderSuggestions(OptionName, TargetDirOption(Options));
end;

initialization
  RegisterModule(TProjectsModule.Create);

end.
