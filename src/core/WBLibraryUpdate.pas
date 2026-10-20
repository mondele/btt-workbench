unit WBLibraryUpdate;

{$mode objfpc}{$H+}

(* BTT-Writer's library updates, done faster: the target languages
   (langnames, temporary languages, their approved codes, the new-language
   questionnaire) and the source list (projects, source languages and
   resources of the source server's catalog, and translationAcademy).

   BTT-Writer 1.6.0 does these in npm door43-client-fork 0.9.11 (main.js
   updateCatalogs and updateSources, library.js), downloading one catalog
   at a time: the source list took 5.5 minutes, nearly all of it waiting
   for 2584 downloads in turn. Here the downloads run several at once
   (FetchAll), and the database work follows BTT-Writer step by step: the
   same SQL (library.js insertOrUpdate and friends) in the same order,
   with the same values, so the result is the database BTT-Writer would
   have written, row ids included, only sooner. Where BTT-Writer gives up
   on a catalog file at an invalid entry, so does this.

   Two things BTT-Writer gets wrong are not copied: it decodes each network
   chunk as UTF-8 on its own, turning a few characters at random into
   U+FFFD (fphttpclient and WinHTTP read the whole reply first), and its
   failures to download a catalog are only logged; they are reported here. *)

interface

uses
  Classes, SysUtils, fpjson, WBReporter, WBSqliteDb;

const
  DefaultLanguagesUrl = 'https://langnames.bibleineverylanguage.org/langnames.json';
  DefaultSourceServer = 'https://api.bibletranslationtools.org';
  DefaultConnections = 8;

var
  { BTT-Writer's fixed addresses for the temporary languages and the
    questionnaire (translationDatabase) and for translationAcademy; tests
    point them at a local server. }
  TranslationDatabaseApi: string = 'https://td.unfoldingword.org/api/';
  TranslationAcademyBase: string = 'https://api.unfoldingword.org/ta/txt/1/en/';

type
  TFetched = record
    Url: string;
    Data: TJSONData;     // nil if it failed; the owner frees it
    Error: string;
  end;
  TFetchedList = array of TFetched;

{ Downloads and parses every URL, Connections at a time, reporting
  progress now and then. The caller frees each Data. }
function FetchAll(const Urls: array of string; Connections: Integer;
  Reporter: TWBReporter; const What: string): TFetchedList;
procedure FreeFetched(var List: TFetchedList);

type
  TLibraryUpdateKind = (luLanguages, luSources);

  TLibraryRun = record
    Kind: TLibraryUpdateKind;
    Input: string;        // the index.sqlite to start from
    Output: string;       // where to write; '' = replace Input (a backup is kept)
    DryRun: Boolean;      // report what would change; write nothing
    Url: string;          // languages: langnames URL; sources: the server
    Connections: Integer;
  end;

{ Runs an update as the modules do: on a copy, with a report of what
  changed, then (unless DryRun) writes Output or replaces Input, the latter
  only while BTT-Writer is not running, keeping the old file as a backup.
  Returns the exit code. }
function RunLibraryUpdate(const Run: TLibraryRun; Reporter: TWBReporter): Integer;

{ BTT-Writer's own index.sqlite: <data>/library/index.sqlite. }
function LibraryIndexFile: string;
{ Copies Source to Target (the update works on the copy) and opens it.
  nil with Problem set if that fails. }
function OpenCopy(const Source, Target: string; out Problem: string): TSqliteDb;

{ BTT-Writer's "Update languages" on Db. False (reported) if it failed;
  the changes are then rolled back. }
function UpdateTargetLanguages(Db: TSqliteDb; const LanguagesUrl: string;
  Connections: Integer; Reporter: TWBReporter): Boolean;
{ BTT-Writer's "Update sources" on Db, from Server's /v2/ts/catalog.json. }
function UpdateSourceList(Db: TSqliteDb; const Server: string;
  Connections: Integer; Reporter: TWBReporter): Boolean;

implementation

uses
  SyncObjs, jsonparser, WBHttp, WBDataPaths, WBProcesses;

resourcestring
  rsFetching = 'Downloading %s: %d of %d...';
  rsFetchFailed = 'Could not download %s (%s); it is left out, as BTT-Writer leaves it out.';
  rsCatalogFailed = 'Could not download %s: %s';
  rsBadCatalog = '%s is not what was expected (%s).';
  rsIndexing = 'Writing %s...';
  rsInvalidEntry = '%s: an entry BTT-Writer would refuse (%s); it stops there, and so ' +
    'does this.';
  rsLanguagesFailed = 'The language update stopped at %s, as BTT-Writer''s does; ' +
    'nothing was changed.';
  rsNoSqlite = 'No SQLite library was found on this computer, so index.sqlite cannot be written.';
  rsNoInput = 'The language database was not found: %s';
  rsCannotCopy = 'Cannot write %s: %s';
  rsRunning = 'BTT-Writer is running (%s). Close it first: it keeps index.sqlite in memory ' +
    'and would write the old one back. Nothing was changed.';
  rsUsingInPlace = 'Updating %s (SQLite %s).';
  rsUsingCopy = 'From %s, written to %s (SQLite %s).';
  rsUsingCheck = 'Checking what an update of %s would change (SQLite %s).';
  rsNoChanges = '%s: no changes.';
  rsAdded = '%s added: %d';
  rsRemoved = '%s removed: %d';
  rsChanged = '%s changed: %d';
  rsChangedLine = '  * %s  %s  ->  %s';
  rsTargetLanguages = 'Target languages';
  rsTempLanguages = 'Temporary languages';
  rsQuestions = 'New-language questions';
  rsSourceLanguages = 'Source languages';
  rsResources = 'Resources (language/project/resource)';
  rsTook = 'Done in %.1f s.';
  rsCheckOnly = 'Check only: nothing was written.';
  rsWrote = 'Written to %s.';
  rsReplaced = '%s updated; the old one is kept as %s.';
  rsReplaceFailed = 'Could not put the new index.sqlite in place (%s). %s is unchanged.';
  rsProjectsLoseLanguage = 'Projects in %s whose language code this update removes ' +
    '(BTT-Writer will no longer know the code; the projects keep it):';
  rsProjectLine = '  %s: %s';

const
  PackageVersion = '0.1';   // resource-container spec.version
  MimeBase = 'application/tsrc+';

{ ---- what changed ---- }

{ key -> description, from SQL giving key || char(9) || description }
function Snapshot(Db: TSqliteDb; const SQL: string): TStringList;
var
  Row: string;
begin
  Result := TStringList.Create;
  Result.UseLocale := False;
  Result.CaseSensitive := True;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  for Row in Db.QueryTexts(SQL, []) do
    Result.Add(Row);
end;

function KeyOf(const Row: string): string;
begin
  Result := Copy(Row, 1, Pos(#9, Row) - 1);
end;

function DescOf(const Row: string): string;
begin
  Result := Copy(Row, Pos(#9, Row) + 1, MaxInt);
end;

{ Reports what was added, removed and changed; Gone gets the removed keys. }
procedure ReportChanges(Reporter: TWBReporter; const What: string; Before, After: TStringList;
  out Gone: TStringArray);
var
  Keys: TStringList;
  Added, Removed, Changed: TStringArray;
  I, J: Integer;
  K: string;
begin
  Keys := TStringList.Create;
  try
    Keys.UseLocale := False;
    Keys.CaseSensitive := True;
    Keys.Sorted := True;
    for I := 0 to Before.Count - 1 do
      Keys.AddObject(KeyOf(Before[I]), TObject(PtrInt(I)));
    Added := nil;
    Removed := nil;
    Changed := nil;
    for I := 0 to After.Count - 1 do
    begin
      K := KeyOf(After[I]);
      J := Keys.IndexOf(K);
      if J < 0 then
        Added := Concat(Added, ['  + ' + K + '  ' + DescOf(After[I])])
      else
      begin
        if DescOf(Before[PtrInt(Keys.Objects[J])]) <> DescOf(After[I]) then
          Changed := Concat(Changed, [Format(rsChangedLine, [K,
            DescOf(Before[PtrInt(Keys.Objects[J])]), DescOf(After[I])])]);
        Keys.Objects[J] := TObject(PtrInt(-1));
      end;
    end;
    Gone := nil;
    for J := 0 to Keys.Count - 1 do
      if PtrInt(Keys.Objects[J]) >= 0 then
      begin
        Removed := Concat(Removed, ['  - ' + Keys[J] + '  ' +
          DescOf(Before[PtrInt(Keys.Objects[J])])]);
        Gone := Concat(Gone, [Keys[J]]);
      end;
  finally
    Keys.Free;
  end;
  if Length(Added) + Length(Removed) + Length(Changed) = 0 then
  begin
    Reporter.Info(Format(rsNoChanges, [What]));
    Exit;
  end;
  if Length(Added) > 0 then
  begin
    Reporter.Info(Format(rsAdded, [What, Length(Added)]));
    for K in Added do
      Reporter.Info(K);
  end;
  if Length(Removed) > 0 then
  begin
    Reporter.Info(Format(rsRemoved, [What, Length(Removed)]));
    for K in Removed do
      Reporter.Info(K);
  end;
  if Length(Changed) > 0 then
  begin
    Reporter.Info(Format(rsChanged, [What, Length(Changed)]));
    for K in Changed do
      Reporter.Info(K);
  end;
end;

{ Projects in Folder whose target language is one of Codes. }
procedure ReportProjectsUsing(Reporter: TWBReporter; const Folder: string;
  const Codes: TStringArray);
var
  SR: TSearchRec;
  Set_: TStringList;
  Lines: TStringArray;
  M: TJSONData;
  Code: string;
begin
  if (Length(Codes) = 0) or not DirectoryExists(Folder) then
    Exit;
  Set_ := TStringList.Create;
  try
    Set_.UseLocale := False;
    Set_.Sorted := True;
    for Code in Codes do
      Set_.Add(LowerCase(Code));
    Lines := nil;
    if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name[1] = '.') or not FileExists(IncludeTrailingPathDelimiter(Folder) + SR.Name +
           PathDelim + 'manifest.json') then
          Continue;
        try
          with TStringList.Create do
          try
            LoadFromFile(IncludeTrailingPathDelimiter(Folder) + SR.Name + PathDelim + 'manifest.json');
            M := GetJSON(Text, True);
          finally
            Free;
          end;
        except
          Continue;
        end;
        try
          Code := '';
          if (M is TJSONObject) and (TJSONObject(M).FindPath('target_language.id') <> nil) then
            Code := TJSONObject(M).FindPath('target_language.id').AsString;
        finally
          M.Free;
        end;
        if (Code <> '') and (Set_.IndexOf(LowerCase(Code)) >= 0) then
          Lines := Concat(Lines, [Format(rsProjectLine, [Code, SR.Name])]);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    if Length(Lines) = 0 then
      Exit;
    Reporter.Warn(Format(rsProjectsLoseLanguage, [Folder]));
    for Code in Lines do
      Reporter.Warn(Code);
  finally
    Set_.Free;
  end;
end;

const
  TargetSQL = 'select slug || char(9) || name || '' ('' || coalesce(anglicized_name, '''') || ''), '' ' +
    '|| direction || '', '' || region || case when is_gateway_language = 1 then '', gateway'' ' +
    'else '''' end from target_language';
  TempSQL = 'select slug || char(9) || name || '', '' || direction || ' +
    'coalesce('', approved as '' || approved_target_language_slug, '''') from temp_target_language';
  QuestionsSQL = 'select q.language_slug || ''/'' || qn.td_id || char(9) || qn.text from question qn ' +
    'join questionnaire q on q.id = qn.questionnaire_id';
  SourceLanguagesSQL = 'select slug || char(9) || name || '', '' || direction from source_language';
  ResourcesSQL = 'select l.slug || ''/'' || p.slug || ''/'' || r.slug || char(9) || ''version '' || ' +
    'r.version || '', checking level '' || r.checking_level || '', '' || r.type || '', modified '' || ' +
    'coalesce((select group_concat(f.modified_at) from resource_format f where f.resource_id = r.id), ' +
    '''-'') from resource r join project p on p.id = r.project_id join source_language l ' +
    'on l.id = p.source_language_id';

function RunLibraryUpdate(const Run: TLibraryRun; Reporter: TWBReporter): Integer;
var
  Version, Work, Target, Detail, Backup, Problem: string;
  InPlace, Ok: Boolean;
  Db: TSqliteDb;
  SQLs: array of string;
  Titles: array of string;
  Before, After: array of TStringList;
  I, K: Integer;
  Started: QWord;
  Gone, StillTemp: TStringArray;
  Temps: TStringList;
begin
  Result := 1;
  Version := SqliteLibraryVersion;
  if Version = '' then
  begin
    Reporter.Error(rsNoSqlite);
    Exit;
  end;
  if not FileExists(Run.Input) then
  begin
    Reporter.Error(Format(rsNoInput, [Run.Input]));
    Exit;
  end;
  InPlace := Run.Output = '';
  if InPlace then
    Target := Run.Input
  else
    Target := ExpandFileName(Run.Output);
  if InPlace and not Run.DryRun and BttWriterRunning(Detail) then
  begin
    Reporter.Error(Format(rsRunning, [Detail]));
    Exit;
  end;
  if Run.DryRun then
    Work := GetTempFileName(GetTempDir(False), 'btw-index-')
  else if InPlace then
    Work := Target + '.workbench-new'
  else
    Work := Target;
  if Run.DryRun then
    Reporter.Info(Format(rsUsingCheck, [Run.Input, Version]))
  else if InPlace then
    Reporter.Info(Format(rsUsingInPlace, [Run.Input, Version]))
  else
    Reporter.Info(Format(rsUsingCopy, [Run.Input, Target, Version]));

  if Run.Kind = luLanguages then
  begin
    SQLs := [TargetSQL, TempSQL, QuestionsSQL];
    Titles := [rsTargetLanguages, rsTempLanguages, rsQuestions];
  end
  else
  begin
    SQLs := [SourceLanguagesSQL, ResourcesSQL];
    Titles := [rsSourceLanguages, rsResources];
  end;
  SetLength(Before, Length(SQLs));
  SetLength(After, Length(SQLs));
  Db := OpenCopy(Run.Input, Work, Problem);
  if Db = nil then
  begin
    Reporter.Error(Format(rsCannotCopy, [Work, Problem]));
    Exit;
  end;
  Ok := False;
  try
    try
      for I := 0 to High(SQLs) do
        Before[I] := Snapshot(Db, SQLs[I]);
      Started := GetTickCount64;
      if Run.Kind = luLanguages then
        Ok := UpdateTargetLanguages(Db, Run.Url, Run.Connections, Reporter)
      else
        Ok := UpdateSourceList(Db, Run.Url, Run.Connections, Reporter);
      if Ok then
      begin
        for I := 0 to High(SQLs) do
          After[I] := Snapshot(Db, SQLs[I]);
        Reporter.Info('');
        for I := 0 to High(SQLs) do
        begin
          ReportChanges(Reporter, Titles[I], Before[I], After[I], Gone);
          if (Run.Kind = luLanguages) and (I = 0) then
          begin
            { a code dropped from the target languages but still a
              temporary one is known to BTT-Writer }
            Temps := TStringList.Create;
            try
              Temps.UseLocale := False;
              Temps.Sorted := True;
              for K := 0 to After[1].Count - 1 do
                Temps.Add(LowerCase(KeyOf(After[1][K])));
              StillTemp := nil;
              for K := 0 to High(Gone) do
                if Temps.IndexOf(LowerCase(Gone[K])) < 0 then
                  StillTemp := Concat(StillTemp, [Gone[K]]);
            finally
              Temps.Free;
            end;
            ReportProjectsUsing(Reporter, ExtractFilePath(ExtractFileDir(Run.Input)) +
              'targetTranslations', StillTemp);
          end;
        end;
        Reporter.Info('');
        Reporter.Info(Format(rsTook, [(GetTickCount64 - Started) / 1000]));
      end;
    finally
      Db.Free;
      for I := 0 to High(SQLs) do
      begin
        Before[I].Free;
        After[I].Free;
      end;
    end;
  except
    on E: Exception do
    begin
      Reporter.Error(E.Message);
      Ok := False;
    end;
  end;

  if not Ok or Run.DryRun then
  begin
    if Run.DryRun or InPlace then
      DeleteFile(Work);
    if Ok then
    begin
      Reporter.Info(rsCheckOnly);
      Result := 0;
    end;
    Exit;
  end;
  if not InPlace then
  begin
    Reporter.Info(Format(rsWrote, [Target]));
    Exit(0);
  end;
  { replace BTT-Writer's file, if it is still not running }
  if BttWriterRunning(Detail) then
  begin
    DeleteFile(Work);
    Reporter.Error(Format(rsRunning, [Detail]));
    Exit;
  end;
  Backup := Target + '.before-' + FormatDateTime('yyyy-mm-dd-hhnnss', Now);
  if not RenameFile(Target, Backup) then
  begin
    DeleteFile(Work);
    Reporter.Error(Format(rsReplaceFailed, ['cannot rename it', Target]));
    Exit;
  end;
  if not RenameFile(Work, Target) then
  begin
    RenameFile(Backup, Target);
    DeleteFile(Work);
    Reporter.Error(Format(rsReplaceFailed, ['cannot rename the new one', Target]));
    Exit;
  end;
  Reporter.Info(Format(rsReplaced, [Target, Backup]));
  Result := 0;
end;

function LibraryIndexFile: string;
begin
  Result := BttWriterDataPath + 'library' + PathDelim + 'index.sqlite';
end;

function OpenCopy(const Source, Target: string; out Problem: string): TSqliteDb;
var
  Src, Dst: TFileStream;
begin
  Result := nil;
  Problem := '';
  if ExpandFileName(Source) = ExpandFileName(Target) then
  begin
    Problem := 'the output must be another file';
    Exit;
  end;
  try
    Src := TFileStream.Create(Source, fmOpenRead or fmShareDenyWrite);
    try
      ForceDirectories(ExtractFileDir(ExpandFileName(Target)));
      Dst := TFileStream.Create(Target, fmCreate);
      try
        Dst.CopyFrom(Src, 0);
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
    Result := TSqliteDb.Create(Target);
  except
    on E: Exception do
    begin
      FreeAndNil(Result);
      Problem := E.Message;
    end;
  end;
end;

{ ---- downloads ---- }

type
  TFetchJob = class
    Urls: array of string;
    Results: TFetchedList;
    Next, Done: Integer;
    Lock: TCriticalSection;
  end;

  TFetchThread = class(TThread)
  protected
    procedure Execute; override;
  public
    Job: TFetchJob;
  end;

procedure TFetchThread.Execute;
var
  I: Integer;
  D: TJSONData;
  Err: string;
begin
  HttpKeepConnections;
  try
    repeat
      Job.Lock.Acquire;
      try
        I := Job.Next;
        Inc(Job.Next);
      finally
        Job.Lock.Release;
      end;
      if I > High(Job.Urls) then
        Break;
      D := nil;
      Err := '';
      try
        D := HttpJson('GET', Job.Urls[I], NoAuth, nil, 60000);
      except
        on E: Exception do
          Err := E.Message;
      end;
      Job.Lock.Acquire;
      try
        Job.Results[I].Url := Job.Urls[I];
        Job.Results[I].Data := D;
        Job.Results[I].Error := Err;
        Inc(Job.Done);
      finally
        Job.Lock.Release;
      end;
    until False;
  finally
    HttpReleaseConnection;
  end;
end;

function FetchAll(const Urls: array of string; Connections: Integer;
  Reporter: TWBReporter; const What: string): TFetchedList;
var
  Job: TFetchJob;
  Threads: array of TFetchThread;
  I, Done, Shown: Integer;
  Last: QWord;
begin
  Result := nil;
  if Length(Urls) = 0 then
    Exit;
  if Connections < 1 then
    Connections := 1;
  if Connections > Length(Urls) then
    Connections := Length(Urls);
  Job := TFetchJob.Create;
  Job.Lock := TCriticalSection.Create;
  try
    SetLength(Job.Urls, Length(Urls));
    for I := 0 to High(Urls) do
      Job.Urls[I] := Urls[I];
    SetLength(Job.Results, Length(Urls));
    SetLength(Threads, Connections);
    for I := 0 to High(Threads) do
    begin
      Threads[I] := TFetchThread.Create(True);
      Threads[I].Job := Job;
      Threads[I].FreeOnTerminate := False;
      Threads[I].Start;
    end;
    Shown := -1;
    Last := GetTickCount64;
    repeat
      Sleep(50);
      Job.Lock.Acquire;
      Done := Job.Done;
      Job.Lock.Release;
      if (Length(Urls) > 20) and (Done <> Shown) and (GetTickCount64 - Last >= 3000) then
      begin
        Reporter.Info(Format(rsFetching, [What, Done, Length(Urls)]));
        Shown := Done;
        Last := GetTickCount64;
      end;
    until Done >= Length(Urls);
    for I := 0 to High(Threads) do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
    Result := Job.Results;
  finally
    Job.Lock.Free;
    Job.Free;
  end;
end;

procedure FreeFetched(var List: TFetchedList);
var
  I: Integer;
begin
  for I := 0 to High(List) do
    FreeAndNil(List[I].Data);
  List := nil;
end;

{ ---- values as door43-client binds them ---- }

type
  EInvalidEntry = class(Exception);

{ A JSON value as sql.js 0.3.2 binds the JavaScript value: a number that is
  a 32-bit integer as an integer, other numbers as reals, booleans as 0/1,
  strings as text; undefined and null as NULL. }
function JV(D: TJSONData): TDbValue;
var
  F: Double;
begin
  if (D = nil) or (D.JSONType = jtNull) then
    Exit(DbNull);
  case D.JSONType of
    jtBoolean:
      if D.AsBoolean then
        Result := DbInt(1)
      else
        Result := DbInt(0);
    jtNumber:
      begin
        F := D.AsFloat;
        if (Frac(F) = 0) and (F >= -2147483648.0) and (F <= 2147483647.0) then
          Result := DbInt(Trunc(F))
        else
          Result := DbFloat(F);
      end;
    jtString:
      Result := DbText(D.AsString);
  else
    Result := DbText(D.AsJSON);
  end;
end;

function Field(O: TJSONData; const Path: string): TJSONData;
begin
  Result := nil;
  if O is TJSONObject then
    Result := TJSONObject(O).FindPath(Path);
end;

{ JavaScript: typeof x === 'string' ? x : '' }
function StrOrEmpty(D: TJSONData): TDbValue;
begin
  if (D <> nil) and (D.JSONType = jtString) then
    Result := DbText(D.AsString)
  else
    Result := DbText('');
end;

{ JavaScript: x || 0 }
function OrZero(D: TJSONData): TDbValue;
begin
  Result := JV(D);
  if (Result.Kind = dvNull) or ((Result.Kind = dvInt) and (Result.I = 0)) or
     ((Result.Kind = dvFloat) and (Result.F = 0)) or
     ((Result.Kind = dvText) and (Result.S = '')) then
    Result := DbInt(0);
end;

{ JavaScript truthiness of a JSON value. }
function Truthy(D: TJSONData): Boolean;
var
  V: TDbValue;
begin
  if D = nil then
    Exit(False);
  if D.JSONType in [jtObject, jtArray] then
    Exit(True);
  V := OrZero(D);
  Result := not ((V.Kind = dvInt) and (V.I = 0));
end;

{ library.js validateNotEmpty }
procedure Need(const V: TDbValue; const Prop: string);
begin
  if (V.Kind = dvNull) or ((V.Kind = dvText) and (V.S = '')) then
    raise EInvalidEntry.CreateFmt('missing %s', [Prop]);
end;

{ ---- library.js ---- }

type
  TLibrary = class
  private
    Db: TSqliteDb;
  public
    constructor Create(ADb: TSqliteDb);
    { insertOrUpdate: the row id, or -1 }
    function InsertOrUpdate(const Table: string; const Params: TDbParams;
      const Unique: array of string): Int64;
    procedure AddCatalog(const Slug, Url: string);
    function AddSourceLanguage(const Slug, Name, Direction: TDbValue): Int64;
    function AddProject(const Slug, Name, Desc, Icon, Sort, ChunksUrl: TDbValue;
      const CatSlugs, CatNames: array of TDbValue; SourceLanguageId: Int64): Int64;
    { PubDate: the status field BTT-Writer takes the date from (publish_date
      for the source catalog's resources, pub_date for tA, which has none) }
    function AddResource(const Slug, Name, Kind, TranslateMode: TDbValue; Status: TJSONData;
      const PubDate: string; const FormatModified, FormatUrl, TwAssignmentsUrl: TDbValue;
      ProjectId: Int64): Int64;
  end;

constructor TLibrary.Create(ADb: TSqliteDb);
begin
  Db := ADb;
end;

function TLibrary.InsertOrUpdate(const Table: string; const Params: TDbParams;
  const Unique: array of string): Int64;
var
  Columns, Holders, Updated, Wheres: string;
  Prm: TDbParam;
  U: string;
begin
  Columns := '';
  Holders := '';
  Updated := '';
  for Prm in Params do
  begin
    if Columns <> '' then
    begin
      Columns := Columns + ', ';
      Holders := Holders + ', ';
    end;
    Columns := Columns + Prm.Name;
    Holders := Holders + ':' + Prm.Name;
    { JavaScript filter(c => unique.indexOf(c)): every column but the first
      unique one }
    if (Length(Unique) = 0) or (Prm.Name <> Unique[0]) then
    begin
      if Updated <> '' then
        Updated := Updated + ', ';
      Updated := Updated + Prm.Name + '=:' + Prm.Name;
    end;
  end;
  Wheres := '';
  for U in Unique do
  begin
    if Wheres <> '' then
      Wheres := Wheres + ' and ';
    Wheres := Wheres + U + '=:' + U;
  end;
  Db.Run('insert or ignore into ' + Table + ' (' + Columns + ') values (' + Holders + ')', Params);
  Db.Run('update or fail ' + Table + ' set ' + Updated + ' where ' + Wheres, Params);
  Result := Db.QueryInt('select id from ' + Table + ' where ' + Wheres +
    ' order by id asc limit 1', Params);
end;

procedure TLibrary.AddCatalog(const Slug, Url: string);
begin
  InsertOrUpdate('catalog', [P('slug', DbText(Slug)), P('url', DbText(Url)),
    P('modified_at', DbInt(0))], ['slug']);
end;

function TLibrary.AddSourceLanguage(const Slug, Name, Direction: TDbValue): Int64;
begin
  Need(Slug, 'slug');
  Need(Name, 'name');
  Need(Direction, 'direction');
  Result := InsertOrUpdate('source_language', [P('slug', Slug), P('name', Name),
    P('direction', Direction)], ['slug']);
end;

function TLibrary.AddProject(const Slug, Name, Desc, Icon, Sort, ChunksUrl: TDbValue;
  const CatSlugs, CatNames: array of TDbValue; SourceLanguageId: Int64): Int64;
var
  Parent: Int64;
  I: Integer;
begin
  Need(Slug, 'slug');
  Need(Name, 'name');
  Parent := 0;
  for I := 0 to High(CatSlugs) do
  begin
    Need(CatSlugs[I], 'slug');
    Need(CatNames[I], 'name');
    Db.Run('insert or ignore into category (slug, parent_id) values (:slug, :parent_id)',
      [P('slug', CatSlugs[I]), P('parent_id', DbInt(Parent))]);
    Parent := Db.QueryInt('select id from category where slug=:slug and parent_id=:parent_id',
      [P('slug', CatSlugs[I]), P('parent_id', DbInt(Parent))]);
    if Parent = -1 then
    begin
      Parent := 0;
      Continue;
    end;
    InsertOrUpdate('category_name', [P('source_language_id', DbInt(SourceLanguageId)),
      P('category_id', DbInt(Parent)), P('name', CatNames[I])],
      ['source_language_id', 'category_id']);
  end;
  Result := InsertOrUpdate('project', [P('slug', Slug), P('name', Name), P('desc', Desc),
    P('icon', Icon), P('sort', Sort), P('chunks_url', ChunksUrl),
    P('source_language_id', DbInt(SourceLanguageId)), P('category_id', DbInt(Parent))],
    ['slug', 'source_language_id']);
end;

function TLibrary.AddResource(const Slug, Name, Kind, TranslateMode: TDbValue; Status: TJSONData;
  const PubDate: string; const FormatModified, FormatUrl, TwAssignmentsUrl: TDbValue;
  ProjectId: Int64): Int64;
var
  CheckingLevel, Version: TDbValue;
begin
  Need(Slug, 'slug');
  Need(Name, 'name');
  Need(Kind, 'type');
  if not (Status is TJSONObject) then
    raise EInvalidEntry.Create('no status');
  CheckingLevel := JV(Field(Status, 'checking_level'));
  Version := JV(Field(Status, 'version'));
  Need(TranslateMode, 'translate_mode');
  Need(CheckingLevel, 'checking_level');
  Need(Version, 'version');
  Result := InsertOrUpdate('resource', [P('slug', Slug), P('name', Name), P('type', Kind),
    P('translate_mode', TranslateMode), P('checking_level', CheckingLevel),
    P('comments', StrOrEmpty(Field(Status, 'comments'))),
    P('pub_date', OrZero(Field(Status, PubDate))),
    P('license', StrOrEmpty(Field(Status, 'license'))), P('version', Version),
    P('project_id', DbInt(ProjectId))], ['slug', 'project_id']);
  InsertOrUpdate('resource_format', [P('package_version', DbText(PackageVersion)),
    P('mime_type', DbText(MimeBase + Kind.S)), P('modified_at', FormatModified),
    P('url', FormatUrl), P('imported', DbInt(0)), P('resource_id', DbInt(Result))],
    ['mime_type', 'resource_id']);
  if (TwAssignmentsUrl.Kind <> dvNull) and not ((TwAssignmentsUrl.Kind = dvText) and
     (TwAssignmentsUrl.S = '')) then
    InsertOrUpdate('legacy_resource_info', [P('translation_words_assignments_url',
      TwAssignmentsUrl), P('resource_id', DbInt(Result))], ['resource_id']);
end;

function TempLanguagesUrl: string;
begin
  Result := TranslationDatabaseApi + 'templanguages/';
end;

function ApprovedTempLanguagesUrl: string;
begin
  Result := TranslationDatabaseApi + 'templanguages/assignment/changed/';
end;

function QuestionnaireUrl: string;
begin
  Result := TranslationDatabaseApi + 'questionnaire/';
end;

procedure InjectGlobalCatalogs(L: TLibrary; const LanguagesUrl: string);
begin
  L.AddCatalog('langnames', LanguagesUrl);
  L.AddCatalog('new-language-questions', QuestionnaireUrl);
  L.AddCatalog('temp-langnames', TempLanguagesUrl);
  L.AddCatalog('approved-temp-langnames', ApprovedTempLanguagesUrl);
end;

{ ---- target languages (main.js updateCatalogs) ---- }

procedure IndexLanguages(L: TLibrary; Data: TJSONData; const Table: string);
var
  I: Integer;
  E: TJSONData;
  Slug, Name, Direction: TDbValue;
  Region: TDbValue;
begin
  if not (Data is TJSONArray) then
    raise EInvalidEntry.Create('not a list');
  for I := 0 to Data.Count - 1 do
  begin
    E := Data.Items[I];
    Slug := JV(Field(E, 'lc'));
    Name := JV(Field(E, 'ln'));
    Direction := JV(Field(E, 'ld'));
    Need(Slug, 'slug');
    Need(Name, 'name');
    Need(Direction, 'direction');
    Region := StrOrEmpty(Field(E, 'lr'));
    L.InsertOrUpdate(Table, [P('slug', Slug), P('name', Name),
      P('anglicized_name', JV(Field(E, 'ang'))), P('direction', Direction),
      P('region', Region), P('is_gateway_language', DbInt(Ord(Truthy(Field(E, 'gl')))))],
      ['slug']);
  end;
end;

procedure IndexApproved(L: TLibrary; Data: TJSONData);
var
  I: Integer;
  E: TJSONData;
begin
  if not (Data is TJSONArray) then
    raise EInvalidEntry.Create('not a list');
  for I := 0 to Data.Count - 1 do
  begin
    E := Data.Items[I];
    if not (E is TJSONObject) or (E.Count = 0) then
      Continue;
    L.Db.Run('update temp_target_language set approved_target_language_slug=:approved' +
      ' where slug=:slug', [P('approved', JV(E.Items[0])),
      P('slug', DbText(TJSONObject(E).Names[0]))]);
  end;
end;

procedure IndexQuestionnaires(L: TLibrary; Data: TJSONData);
var
  Languages, Q, Questions, Qn, LanguageData: TJSONData;
  I, J: Integer;
  Id: Int64;
  Dir: string;
  DependsOn: TDbValue;
begin
  Languages := Field(Data, 'languages');
  if not (Languages is TJSONArray) then
    raise EInvalidEntry.Create('no languages');
  for I := 0 to Languages.Count - 1 do
  begin
    Q := Languages.Items[I];
    Need(JV(Field(Q, 'slug')), 'language_slug');
    Need(JV(Field(Q, 'name')), 'language_name');
    Need(JV(Field(Q, 'dir')), 'language_direction');
    LanguageData := Field(Q, 'language_data');
    if not (LanguageData is TJSONObject) then
      raise EInvalidEntry.Create('missing language_data');
    Dir := 'ltr';
    if LowerCase(Field(Q, 'dir').AsString) = 'rtl' then
      Dir := 'rtl';
    Id := L.InsertOrUpdate('questionnaire', [P('language_slug', JV(Field(Q, 'slug'))),
      P('language_name', JV(Field(Q, 'name'))), P('language_direction', DbText(Dir)),
      P('td_id', JV(Field(Q, 'questionnaire_id')))], ['td_id', 'language_slug']);
    for J := 0 to LanguageData.Count - 1 do
      L.InsertOrUpdate('questionnaire_data_field', [P('questionnaire_id', DbInt(Id)),
        P('field', DbText(TJSONObject(LanguageData).Names[J])),
        P('question_td_id', JV(LanguageData.Items[J]))], ['field', 'questionnaire_id']);
    if Id <= 0 then
      Continue;
    Questions := Field(Q, 'questions');
    if not (Questions is TJSONArray) then
      Continue;
    for J := 0 to Questions.Count - 1 do
    begin
      Qn := Questions.Items[J];
      Need(JV(Field(Qn, 'text')), 'text');
      Need(JV(Field(Qn, 'input_type')), 'input_type');
      DependsOn := JV(Field(Qn, 'depends_on'));
      if (DependsOn.Kind = dvNull) or ((DependsOn.Kind = dvText) and (DependsOn.S = '')) then
        DependsOn := DbInt(-1);
      L.InsertOrUpdate('question', [P('text', JV(Field(Qn, 'text'))),
        P('help', JV(Field(Qn, 'help'))),
        P('is_required', DbInt(Ord(Truthy(Field(Qn, 'required'))))),
        P('input_type', JV(Field(Qn, 'input_type'))), P('sort', JV(Field(Qn, 'sort'))),
        P('depends_on', DependsOn), P('td_id', JV(Field(Qn, 'id'))),
        P('questionnaire_id', DbInt(Id))], ['td_id', 'questionnaire_id']);
    end;
  end;
end;

function Count(Db: TSqliteDb; const Table: string): Int64;
begin
  Result := Db.QueryInt('select count(*) from ' + Table, []);
end;

function UpdateTargetLanguages(Db: TSqliteDb; const LanguagesUrl: string;
  Connections: Integer; Reporter: TWBReporter): Boolean;
const
  Names: array[0..3] of string = ('langnames', 'temp-langnames', 'approved-temp-langnames',
    'new-language-questions');
var
  Got: TFetchedList;
  L: TLibrary;
  Step: Integer;
begin
  Result := False;
  Got := FetchAll([LanguagesUrl, TempLanguagesUrl, ApprovedTempLanguagesUrl, QuestionnaireUrl],
    Connections, Reporter, 'language catalogs');
  L := TLibrary.Create(Db);
  try
    for Step := 0 to 3 do
      if Got[Step].Data = nil then
      begin
        Reporter.Error(Format(rsCatalogFailed, [Got[Step].Url, Got[Step].Error]));
        Exit;
      end;
    Step := 0;
    try
      Db.BeginTransaction;
      InjectGlobalCatalogs(L, LanguagesUrl);
      { BTT-Writer clears the target languages (and vacuums) and indexes
        langnames, then the temporary languages (kept: users add to them),
        clears and sets the approved codes, then replaces the
        questionnaires. }
      Reporter.Info(Format(rsIndexing, [Names[0]]));
      Db.Run('delete from target_language', []);
      IndexLanguages(L, Got[0].Data, 'target_language');
      Step := 1;
      Reporter.Info(Format(rsIndexing, [Names[1]]));
      IndexLanguages(L, Got[1].Data, 'temp_target_language');
      Step := 2;
      Reporter.Info(Format(rsIndexing, [Names[2]]));
      Db.Run('update temp_target_language set approved_target_language_slug=null', []);
      IndexApproved(L, Got[2].Data);
      Step := 3;
      Reporter.Info(Format(rsIndexing, [Names[3]]));
      Db.Run('delete from questionnaire_data_field', []);
      Db.Run('delete from question', []);
      Db.Run('delete from questionnaire', []);
      IndexQuestionnaires(L, Got[3].Data);
      Db.Commit;
      Db.Exec('vacuum');
      Result := True;
    except
      on E: Exception do
      begin
        try
          Db.Rollback;
        except
        end;
        Reporter.Error(Format(rsInvalidEntry, [Names[Step], E.Message]));
        Reporter.Error(Format(rsLanguagesFailed, [Names[Step]]));
      end;
    end;
  finally
    L.Free;
    FreeFetched(Got);
  end;
end;

{ ---- the source list (main.js updateResources, updateTA) ---- }

type
  TLocalized = record
    Id: Int64;            // project row
    Slug: string;
    SourceLanguageId: Int64;
    ResourceUrl: string;
  end;

{ downloadSourceLanguages: Project is the catalog entry, Data its
  languages.json. Appends to List; False if BTT-Writer would reject the
  file (what it wrote stays, and none of the file's projects count). }
function IndexProjectLanguages(L: TLibrary; Project, Data: TJSONData;
  var List: array of TLocalized; var N: Integer; out Problem: string): Boolean;
var
  I, K, Start: Integer;
  E, Meta, Names: TJSONData;
  LanguageId, ProjectId: Int64;
  CatSlugs, CatNames: array of TDbValue;
  Slug: string;
  ChunksUrl: TDbValue;
begin
  Result := False;
  Problem := '';
  Start := N;
  if not (Data is TJSONArray) then
  begin
    Problem := 'not a list';
    Exit;
  end;
  Slug := '';
  if Field(Project, 'slug') <> nil then
    Slug := Field(Project, 'slug').AsString;
  ChunksUrl := DbNull;   // undefined until the first language sets it
  try
    for I := 0 to Data.Count - 1 do
    begin
      E := Data.Items[I];
      LanguageId := L.AddSourceLanguage(JV(Field(E, 'language.slug')),
        JV(Field(E, 'language.name')), JV(Field(E, 'language.direction')));
      { categories: the catalog's meta slugs, named by this language's meta }
      Meta := Field(Project, 'meta');
      Names := Field(E, 'project.meta');
      CatSlugs := nil;
      CatNames := nil;
      if Meta is TJSONArray then
        for K := 0 to Meta.Count - 1 do
        begin
          CatSlugs := Concat(CatSlugs, [JV(Meta.Items[K])]);
          if (Names is TJSONArray) and (K < Names.Count) then
            CatNames := Concat(CatNames, [JV(Names.Items[K])])
          else
            CatNames := Concat(CatNames, [DbNull]);
        end;
      if LowerCase(Slug) <> 'obs' then
        ChunksUrl := DbText('https://api.unfoldingword.org/bible/txt/1/' + Slug + '/chunks.json');
      if (ChunksUrl.Kind <> dvText) then
        ChunksUrl := DbText('');
      ProjectId := L.AddProject(JV(Field(Project, 'slug')), JV(Field(E, 'project.name')),
        StrOrEmpty(Field(E, 'project.desc')), StrOrEmpty(Field(Project, 'icon')),
        JV(Field(Project, 'sort')), ChunksUrl, CatSlugs, CatNames, LanguageId);
      if N > High(List) then
        raise EInvalidEntry.Create('too many projects');
      List[N].Id := ProjectId;
      List[N].Slug := Slug;
      List[N].SourceLanguageId := LanguageId;
      List[N].ResourceUrl := '';
      if Field(E, 'res_catalog') <> nil then
        List[N].ResourceUrl := Field(E, 'res_catalog').AsString;
      Inc(N);
    end;
    Result := True;
  except
    on Ex: Exception do
    begin
      Problem := Ex.Message;
      N := Start;
    end;
  end;
end;

{ downloadSourceResources for one localized project. }
function IndexResources(L: TLibrary; const Project: TLocalized; Data: TJSONData;
  out Problem: string): Boolean;
var
  I: Integer;
  R, Status: TJSONData;
  Slug, Mode, Modified, Name: TDbValue;
  WordsId: Int64;
  IsObs: Boolean;
  WordsName: string;
begin
  Result := False;
  Problem := '';
  if not (Data is TJSONArray) then
  begin
    Problem := 'not a list';
    Exit;
  end;
  IsObs := Project.Slug = 'obs';
  try
    for I := 0 to Data.Count - 1 do
    begin
      R := Data.Items[I];
      if Field(R, 'slug') = nil then
        raise EInvalidEntry.Create('missing slug');
      Slug := DbText(LowerCase(Field(R, 'slug').AsString));
      if (Slug.S = 'obs') or (Slug.S = 'ulb') then
        Mode := DbText('all')
      else
        Mode := DbText('gl');
      Status := Field(R, 'status');
      Modified := OrZero(Field(R, 'date_modified'));
      Name := JV(Field(R, 'name'));
      L.AddResource(Slug, Name, DbText('book'), Mode, Status, 'publish_date', Modified,
        JV(Field(R, 'source')), JV(Field(R, 'tw_cat')), Project.Id);
      { notes, questions and words share the resource's status, now 'gl' }
      if Truthy(Field(R, 'notes')) then
        L.AddResource(DbText('tn'), DbText('translationNotes'), DbText('help'), DbText('gl'),
          Status, 'publish_date', Modified, JV(Field(R, 'notes')), DbNull, Project.Id);
      if Truthy(Field(R, 'checking_questions')) then
        L.AddResource(DbText('tq'), DbText('translationQuestions'), DbText('help'),
          DbText('gl'), Status, 'publish_date', Modified, JV(Field(R, 'checking_questions')),
          DbNull, Project.Id);
      if IsObs then
        WordsName := 'translationWords OBS'
      else
        WordsName := 'translationWords';
      if IsObs then
        WordsId := L.AddProject(DbText('bible-obs'), DbText(WordsName), DbText(''), DbText(''),
          DbInt(100), DbText(''), [], [], Project.SourceLanguageId)
      else
        WordsId := L.AddProject(DbText('bible'), DbText(WordsName), DbText(''), DbText(''),
          DbInt(100), DbText(''), [], [], Project.SourceLanguageId);
      if Truthy(Field(R, 'terms')) then
        L.AddResource(DbText('tw'), DbText('translationWords'), DbText('dict'), DbText('gl'),
          Status, 'publish_date', Modified, JV(Field(R, 'terms')), DbNull, WordsId);
    end;
    Result := True;
  except
    on Ex: Exception do
      Problem := Ex.Message;
  end;
end;

const
  TAFiles: array[0..7] of string = ('audio_2.json', 'checking_1.json', 'checking_2.json',
    'gateway_3.json', 'intro_1.json', 'process_1.json', 'translate_1.json',
    'translate_2.json');

{ downloadTA }
function IndexTA(L: TLibrary; const Url: string; Data: TJSONData; out Problem: string): Boolean;
var
  LanguageId, ProjectId: Int64;
  Manual, Volume: string;
  Status: TJSONData;
begin
  Result := False;
  Problem := '';
  try
    LanguageId := L.AddSourceLanguage(DbText('en'), DbText('English'), DbText('ltr'));
    if (Field(Data, 'meta.manual') = nil) or (Field(Data, 'meta.volume') = nil) then
      raise EInvalidEntry.Create('missing meta');
    Manual := Field(Data, 'meta.manual').AsString;
    ProjectId := L.AddProject(DbText('ta-' + StringReplace(Manual, '_', '-', [rfReplaceAll])),
      DbText(UpperCase(Copy(Manual, 1, 1)) + Copy(Manual, 2, MaxInt) + ' Manual'),
      DbText(''), DbText(''), DbInt(0), DbText(''), [DbText('ta')], [DbText('translationAcademy')],
      LanguageId);
    Volume := Field(Data, 'meta.volume').AsString;
    Status := Field(Data, 'meta.status');
    L.AddResource(DbText('vol' + Volume), DbText('Volume ' + Volume), DbText('man'),
      DbText('gl'), Status, 'pub_date', OrZero(Field(Data, 'meta.mod')), DbText(Url), DbNull,
      ProjectId);
    Result := True;
  except
    on Ex: Exception do
      Problem := Ex.Message;
  end;
end;

function UpdateSourceList(Db: TSqliteDb; const Server: string;
  Connections: Integer; Reporter: TWBReporter): Boolean;
var
  Catalog: TFetchedList;
  LangFiles, ResFiles, TAFetched: TFetchedList;
  Urls: array of string;
  L: TLibrary;
  Projects: TJSONData;
  Localized: array of TLocalized;
  I, N: Integer;
  Problem, CatalogUrl: string;
begin
  Result := False;
  CatalogUrl := Server;
  while (CatalogUrl <> '') and (CatalogUrl[Length(CatalogUrl)] = '/') do
    SetLength(CatalogUrl, Length(CatalogUrl) - 1);
  CatalogUrl := CatalogUrl + '/v2/ts/catalog.json';
  Catalog := FetchAll([CatalogUrl], 1, Reporter, 'the catalog');
  L := TLibrary.Create(Db);
  LangFiles := nil;
  ResFiles := nil;
  TAFetched := nil;
  try
    if Catalog[0].Data = nil then
    begin
      Reporter.Error(Format(rsCatalogFailed, [CatalogUrl, Catalog[0].Error]));
      Exit;
    end;
    Projects := Catalog[0].Data;
    if not (Projects is TJSONArray) then
    begin
      Reporter.Error(Format(rsBadCatalog, [CatalogUrl, 'not a list']));
      Exit;
    end;

    { every project's languages }
    SetLength(Urls, Projects.Count);
    for I := 0 to Projects.Count - 1 do
    begin
      Urls[I] := '';
      if Field(Projects.Items[I], 'lang_catalog') <> nil then
        Urls[I] := Field(Projects.Items[I], 'lang_catalog').AsString;
    end;
    LangFiles := FetchAll(Urls, Connections, Reporter, 'project languages');

    Db.BeginTransaction;
    try
      InjectGlobalCatalogs(L, DefaultLanguagesUrl);
      Reporter.Info(Format(rsIndexing, ['projects and source languages']));
      SetLength(Localized, 0);
      N := 0;
      for I := 0 to High(LangFiles) do
      begin
        if LangFiles[I].Data = nil then
        begin
          Reporter.Warn(Format(rsFetchFailed, [LangFiles[I].Url, LangFiles[I].Error]));
          Continue;
        end;
        if Length(Localized) < N + LangFiles[I].Data.Count then
          SetLength(Localized, N + LangFiles[I].Data.Count);
        if not IndexProjectLanguages(L, Projects.Items[I], LangFiles[I].Data, Localized, N,
           Problem) then
          Reporter.Warn(Format(rsInvalidEntry, [LangFiles[I].Url, Problem]));
      end;
      SetLength(Localized, N);
      Db.Commit;
    except
      Db.Rollback;
      raise;
    end;

    { every localized project's resources }
    SetLength(Urls, Length(Localized));
    for I := 0 to High(Localized) do
      Urls[I] := Localized[I].ResourceUrl;
    ResFiles := FetchAll(Urls, Connections, Reporter, 'resources');
    Db.BeginTransaction;
    try
      Reporter.Info(Format(rsIndexing, ['resources']));
      for I := 0 to High(ResFiles) do
      begin
        if ResFiles[I].Data = nil then
        begin
          Reporter.Warn(Format(rsFetchFailed, [ResFiles[I].Url, ResFiles[I].Error]));
          Continue;
        end;
        if not IndexResources(L, Localized[I], ResFiles[I].Data, Problem) then
          Reporter.Warn(Format(rsInvalidEntry, [ResFiles[I].Url, Problem]));
      end;
      Db.Commit;
    except
      Db.Rollback;
      raise;
    end;

    { translationAcademy }
    SetLength(Urls, Length(TAFiles));
    for I := 0 to High(TAFiles) do
      Urls[I] := TranslationAcademyBase + TAFiles[I];
    TAFetched := FetchAll(Urls, Connections, Reporter, 'translationAcademy');
    Db.BeginTransaction;
    try
      Reporter.Info(Format(rsIndexing, ['translationAcademy']));
      for I := 0 to High(TAFetched) do
      begin
        if TAFetched[I].Data = nil then
        begin
          Reporter.Warn(Format(rsFetchFailed, [TAFetched[I].Url, TAFetched[I].Error]));
          Continue;
        end;
        if not IndexTA(L, TAFetched[I].Url, TAFetched[I].Data, Problem) then
          Reporter.Warn(Format(rsInvalidEntry, [TAFetched[I].Url, Problem]));
      end;
      Db.Commit;
    except
      Db.Rollback;
      raise;
    end;
    Result := True;
  finally
    L.Free;
    FreeFetched(Catalog);
    FreeFetched(LangFiles);
    FreeFetched(ResFiles);
    FreeFetched(TAFetched);
  end;
end;

end.
