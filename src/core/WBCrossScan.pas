unit WBCrossScan;

{$mode objfpc}{$H+}

(* Gathers what WBCrossCheck compares, for cross-check and cross-repair:
   the text projects of a projects folder, and for one language every
   current chunk file plus every committed version (WBChunkHistory). *)

interface

uses
  Classes, SysUtils, Generics.Collections, WBCrossCheck, WBSources;

type
  TCrossProject = record
    Folder, Lang, LangName, Book, Resource: string;
    Report: Boolean;   // passes the book and type filters
  end;
  TCrossProjects = array of TCrossProject;

  { One language's chunk files and their history, and what was found. }
  TCrossScan = class
  public
    Lang: string;
    Docs: TCrossDocs;
    Report: array of Boolean;
    Findings: TCrossFindings;
    { project#9commit -> chunk files that commit changed }
    CommitFiles: specialize TDictionary<string, Integer>;
    NProjects, NCurrent, NEarlier: Integer;
    NoGit: TStringArray;   // project folders without readable history
    constructor Create;
    destructor Destroy; override;
    { Chunk files the commit changed in that project, 0 if unknown. }
    function FilesChanged(const Project, Commit: string): Integer;
  end;

{ Text projects of the languages in Langs (all when empty); Report is set
  on those that also match Books and Types. }
function ListTextProjects(const TargetDir: string;
  const Langs, Books, Types: TStringArray): TCrossProjects;
{ The languages that have a project to report on, sorted. }
function ReportLanguages(const Projects: TCrossProjects): TStringArray;
{ Loads Lang's projects (with history unless NoHistory) and finds the copied
  text in the projects to report on. The caller frees the result. }
function ScanLanguage(const TargetDir, Lang: string; const Projects: TCrossProjects;
  NoHistory: Boolean; Sources: TSourceLibrary): TCrossScan;
{ 01/04 }
function ChunkName(const D: TCrossDoc): string;

implementation

uses
  fpjson, WBJson, WBProject, WBChunkHistory;

constructor TCrossScan.Create;
begin
  CommitFiles := specialize TDictionary<string, Integer>.Create;
end;

destructor TCrossScan.Destroy;
begin
  CommitFiles.Free;
  inherited Destroy;
end;

function TCrossScan.FilesChanged(const Project, Commit: string): Integer;
begin
  if not CommitFiles.TryGetValue(Project + #9 + Commit, Result) then
    Result := 0;
end;

function ChunkName(const D: TCrossDoc): string;
begin
  Result := D.Chapter + '/' + D.Chunk;
end;

function ReadText(const FileName: string): string;
var
  S: TStringStream;
begin
  S := TStringStream.Create('');
  try
    S.LoadFromFile(FileName);
    Result := S.DataString;
  finally
    S.Free;
  end;
end;

function ListTextProjects(const TargetDir: string;
  const Langs, Books, Types: TStringArray): TCrossProjects;
var
  SR: TSearchRec;
  List: TStringList;
  Dir, S: string;
  Manifest: TJSONObject;
  P: TCrossProject;
  I: Integer;
begin
  Result := nil;
  List := TStringList.Create;
  try
    if FindFirst(TargetDir + AllFilesMask, faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Name[1] <> '.') and
           ((SR.Attr and faDirectory) <> 0) then
          List.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    List.Sort;
    for I := 0 to List.Count - 1 do
    begin
      Dir := TargetDir + List[I] + PathDelim;
      if not FileExists(Dir + 'manifest.json') then
        Continue;
      try
        Manifest := ReadJSONObjectFile(Dir + 'manifest.json');
      except
        Continue;   // the projects module reports unreadable manifests
      end;
      try
        if StrField(Manifest, 'type.id') <> 'text' then
          Continue;
        P.Folder := List[I];
        P.Lang := StrField(Manifest, 'target_language.id');
        P.LangName := StrField(Manifest, 'target_language.name');
        if P.LangName = '' then
          P.LangName := P.Lang;
        P.Book := StrField(Manifest, 'project.id');
        S := StrField(Manifest, 'resource.id');
        P.Resource := S;
        if (P.Lang = '') or (P.Book = '') or not Matches(Langs, [P.Lang]) then
          Continue;
        P.Report := Matches(Books, [P.Book]) and Matches(Types, ['text', S, 'text_' + S]);
        Result := Concat(Result, [P]);
      finally
        Manifest.Free;
      end;
    end;
  finally
    List.Free;
  end;
end;

function ReportLanguages(const Projects: TCrossProjects): TStringArray;
var
  L: TStringList;
  P: TCrossProject;
  S: string;
begin
  L := TStringList.Create;
  try
    L.Sorted := True;
    L.Duplicates := dupIgnore;
    for P in Projects do
      if P.Report then
        L.Add(P.Lang);
    Result := nil;
    for S in L do
      Result := Concat(Result, [S]);
  finally
    L.Free;
  end;
end;

function ScanLanguage(const TargetDir, Lang: string; const Projects: TCrossProjects;
  NoHistory: Boolean; Sources: TSourceLibrary): TCrossScan;
var
  P: TCrossProject;
  Dir: string;
  Chunks: TProjectChunks;
  Versions: TChunkVersions;
  Commits: TCommitFilesList;
  Parts: TStringArray;
  J, K, N: Integer;
begin
  Result := TCrossScan.Create;
  Result.Lang := Lang;
  N := 0;
  for P in Projects do
  begin
    if P.Lang <> Lang then
      Continue;
    Inc(Result.NProjects);
    Dir := TargetDir + P.Folder + PathDelim;
    Chunks := ProjectChunks(Dir);
    SetLength(Result.Docs, N + Length(Chunks));
    SetLength(Result.Report, Length(Result.Docs));
    for J := 0 to High(Chunks) do
    begin
      Result.Docs[N] := Default(TCrossDoc);
      Result.Docs[N].Book := P.Book;
      Result.Docs[N].Project := P.Folder;
      Result.Docs[N].Chapter := Chunks[J].Chapter;
      Result.Docs[N].Chunk := Chunks[J].Chunk;
      Result.Docs[N].Time := NotCommitted;
      Result.Docs[N].Current := True;
      Result.Docs[N].Text := ReadText(Chunks[J].Path);
      Result.Report[N] := P.Report;
      Inc(N);
      Inc(Result.NCurrent);
    end;
    if NoHistory then
      Continue;
    if not ReadChunkHistory(Dir, Versions, Commits) then
    begin
      Result.NoGit := Concat(Result.NoGit, [P.Folder]);
      Continue;
    end;
    for K := 0 to High(Commits) do
      Result.CommitFiles.AddOrSetValue(P.Folder + #9 + Commits[K].Commit, Commits[K].Files);
    SetLength(Result.Docs, N + Length(Versions));
    SetLength(Result.Report, Length(Result.Docs));
    for K := 0 to High(Versions) do
    begin
      Parts := Versions[K].Path.Split(['/']);
      if Length(Parts) <> 2 then
        Continue;
      Result.Docs[N] := Default(TCrossDoc);
      Result.Docs[N].Book := P.Book;
      Result.Docs[N].Project := P.Folder;
      Result.Docs[N].Chapter := Parts[0];
      Result.Docs[N].Chunk := ChangeFileExt(Parts[1], '');
      Result.Docs[N].Commit := Versions[K].Commit;
      Result.Docs[N].Author := Versions[K].Author;
      Result.Docs[N].Date := Versions[K].Date;
      Result.Docs[N].Time := Versions[K].Time;
      Result.Docs[N].Current := False;
      Result.Docs[N].Text := Versions[K].Text;
      Result.Report[N] := False;
      Inc(N);
      Inc(Result.NEarlier);
    end;
    SetLength(Result.Docs, N);
    SetLength(Result.Report, N);
  end;
  Result.Findings := FindCopiedText(Result.Docs, Result.Report, Sources);
end;

end.
