unit WBSources;

{$mode objfpc}{$H+}

{ Chunking of BTT-Writer source texts (resource containers such as
  en_tit_ulb): which chunks each chapter has, and which verses each chunk
  holds. That is what a project's chunk files are compared against.

  Read the way BTT-Writer Desktop 1.6.0 reads them (js/database.js
  getContainerData, ts-translate.html):
  - chunks are the content/<chapter>/<chunk>.usx files, in toc.yml order
    when there is a toc.yml (toc entries without a file are dropped);
  - a chunk's verses are the numbers in its <verse number="..."> tags, a
    range "4-5" counting as 4 and 5 (render.js convertVerseMarkers).

  A container is taken from the installed library folder if it is there,
  else from BTT-Writer's bundled .tsrc (a bzip2-compressed tar). }

interface

uses
  Classes, SysUtils, Generics.Collections;

type
  TVerseList = array of Integer;

  TSourceChunk = record
    Chapter: string;   // as named in the container: '01', 'front'
    Chunk: string;     // '04', 'title'
    Verses: TVerseList;
  end;

  TSourceChunking = class
  private
    FIndex: TStringList;   // ChunkKey -> position in Chunks
  public
    Container: string;     // en_tit_ulb
    Location: string;      // folder or .tsrc it was read from
    Bundled: Boolean;
    Chunks: array of TSourceChunk;
    constructor Create;
    destructor Destroy; override;
    { Position of a chunk in Chunks, or -1. }
    function IndexOf(const Chapter, Chunk: string): Integer;
  end;

  { Finds and caches containers for one run. Owns what it returns. }
  TSourceLibrary = class
  private
    FLibraryDir, FBundledDir: string;
    FCache: specialize TObjectDictionary<string, TSourceChunking>;
  public
    constructor Create(const LibraryDir, BundledDir: string);
    destructor Destroy; override;
    { nil if the container is neither installed nor bundled, or unreadable. }
    function Find(const Container: string): TSourceChunking;
  end;

{ Chapter/chunk identity independent of zero padding: ('01','04') and
  ('1','004') give the same key. }
function ChunkKey(const Chapter, Chunk: string): string;
{ Verse numbers of the <verse number="..."> tags in USX text. }
function UsxVerses(const Text: string): TVerseList;
{ First verse numbers of the \v markers in USFM text, as BTT-Writer reads
  them (render.js validateVerseMarkers: "\v 4-5" counts as 4). }
function UsfmVerseMarkers(const Text: string): TVerseList;

implementation

uses
  bzip2stream, libtar;

function NormalPart(const S: string): string;
var
  N: Integer;
begin
  if (S <> '') and TryStrToInt(S, N) and (N >= 0) then
    Result := IntToStr(N)
  else
    Result := LowerCase(S);
end;

function ChunkKey(const Chapter, Chunk: string): string;
begin
  Result := NormalPart(Chapter) + '-' + NormalPart(Chunk);
end;

function ReadNumber(const Text: string; var P: Integer): Integer;
var
  Start: Integer;
begin
  Start := P;
  while (P <= Length(Text)) and (Text[P] in ['0'..'9']) do
    Inc(P);
  Result := StrToIntDef(Copy(Text, Start, P - Start), -1);
end;

function UsxVerses(const Text: string): TVerseList;
var
  P, Q, A, B, V: Integer;
begin
  Result := nil;
  P := Pos('<verse', Text);
  while P > 0 do
  begin
    { First quoted value after the tag name, as Desktop's regex takes it. }
    Q := P + 6;
    while (Q <= Length(Text)) and not (Text[Q] in ['"', '<', '>']) do
      Inc(Q);
    if (Q <= Length(Text)) and (Text[Q] = '"') then
    begin
      Inc(Q);
      A := ReadNumber(Text, Q);
      B := A;
      if (A >= 0) and (Q <= Length(Text)) and (Text[Q] = '-') then
      begin
        Inc(Q);
        B := ReadNumber(Text, Q);
        if B < A then
          B := A;
      end;
      if A >= 0 then
        for V := A to B do
          Result := Concat(Result, [V]);
    end;
    P := Pos('<verse', Text, P + 6);
  end;
end;

function UsfmVerseMarkers(const Text: string): TVerseList;
var
  P, Q, V: Integer;
begin
  Result := nil;
  P := Pos('\v', Text);
  while P > 0 do
  begin
    Q := P + 2;
    { \v must be followed by optional space and a number (not \va, \vp). }
    while (Q <= Length(Text)) and (Text[Q] in [' ', #9, #10, #13]) do
      Inc(Q);
    if (Q <= Length(Text)) and (Text[Q] in ['0'..'9']) then
    begin
      V := ReadNumber(Text, Q);
      if V >= 0 then
        Result := Concat(Result, [V]);
    end;
    P := Pos('\v', Text, P + 2);
  end;
end;

{ toc.yml: a list of chapters, each "chapter: '01'" with "chunks:" items
  "- '04'". Only that shape is read; quotes are optional. }
procedure ParseToc(const Text: string; Toc: TStrings);
var
  Line, S, Chapter: string;
  InChunks: Boolean;

  function Unquote(const V: string): string;
  begin
    Result := Trim(V);
    if (Length(Result) >= 2) and (Result[1] in ['''', '"']) and
       (Result[Length(Result)] = Result[1]) then
      Result := Copy(Result, 2, Length(Result) - 2);
  end;

begin
  Chapter := '';
  InChunks := False;
  for Line in Text.Split([#10]) do
  begin
    S := Trim(Line);
    if (S = '-') or (S = '') then
      Continue;
    if Copy(S, 1, 2) = '- ' then
      S := Trim(Copy(S, 3, MaxInt));
    if Copy(S, 1, 8) = 'chapter:' then
    begin
      Chapter := Unquote(Copy(S, 9, MaxInt));
      InChunks := False;
    end
    else if Copy(S, 1, 7) = 'chunks:' then
      InChunks := True
    else if InChunks and (Chapter <> '') and (Pos(':', S) = 0) then
      Toc.Add(Chapter + #9 + Unquote(S))
    else if Pos(':', S) > 0 then
      InChunks := False;
  end;
end;

{ --- TSourceChunking --- }

constructor TSourceChunking.Create;
begin
  inherited Create;
  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupIgnore;
end;

destructor TSourceChunking.Destroy;
begin
  FIndex.Free;
  inherited Destroy;
end;

function TSourceChunking.IndexOf(const Chapter, Chunk: string): Integer;
var
  I: Integer;
begin
  I := FIndex.IndexOf(ChunkKey(Chapter, Chunk));
  if I < 0 then
    Result := -1
  else
    Result := PtrInt(FIndex.Objects[I]);
end;

{ Files: chapter#9chunk -> usx text. Builds Chunks in toc order (or file
  order without a toc), like getContainerData. }
procedure BuildChunks(C: TSourceChunking; Files: TStringList; const TocText: string);
var
  Toc: TStringList;
  I, J: Integer;

  procedure AddChunk(const Key: string; const Text: string);
  var
    Parts: TStringArray;
    N: Integer;
  begin
    Parts := Key.Split([#9]);
    if C.FIndex.IndexOf(ChunkKey(Parts[0], Parts[1])) >= 0 then
      Exit;
    N := Length(C.Chunks);
    SetLength(C.Chunks, N + 1);
    C.Chunks[N].Chapter := Parts[0];
    C.Chunks[N].Chunk := Parts[1];
    C.Chunks[N].Verses := UsxVerses(Text);
    C.FIndex.AddObject(ChunkKey(Parts[0], Parts[1]), TObject(PtrInt(N)));
  end;

begin
  Toc := TStringList.Create;
  try
    if TocText <> '' then
      ParseToc(TocText, Toc);
    if Toc.Count > 0 then
    begin
      for I := 0 to Toc.Count - 1 do
      begin
        J := Files.IndexOfName(Toc[I]);
        if J >= 0 then
          AddChunk(Toc[I], Files.ValueFromIndex[J]);
      end;
    end
    else
    begin
      Files.Sort;
      for I := 0 to Files.Count - 1 do
        AddChunk(Files.Names[I], Files.ValueFromIndex[I]);
    end;
  finally
    Toc.Free;
  end;
end;

{ content/<chapter>/<chunk>.usx -> 'chapter#9chunk'; '' otherwise. }
function UsxEntryKey(const RelPath: string): string;
var
  Parts: TStringArray;
  P: string;
begin
  Result := '';
  P := StringReplace(RelPath, '\', '/', [rfReplaceAll]);
  if Copy(P, 1, 2) = './' then
    Delete(P, 1, 2);
  Parts := P.Split(['/']);
  if (Length(Parts) = 3) and (Parts[0] = 'content') and
     (LowerCase(ExtractFileExt(Parts[2])) = '.usx') then
    Result := Parts[1] + #9 + ChangeFileExt(Parts[2], '');
end;

function NameValue(const Key, Text: string): string;
begin
  { Values may hold line breaks; Files only ever uses IndexOfName and
    ValueFromIndex on whole items, which is fine with those. }
  Result := Key + '=' + Text;
end;

function ReadFileText(const FileName: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

function LoadFromFolder(const Dir: string; C: TSourceChunking): Boolean;
var
  Files: TStringList;
  Content, TocText: string;
  Ch, F: TSearchRec;
begin
  Content := IncludeTrailingPathDelimiter(Dir) + 'content' + PathDelim;
  Result := DirectoryExists(Content);
  if not Result then
    Exit;
  Files := TStringList.Create;
  try
    Files.NameValueSeparator := '=';
    if FindFirst(Content + AllFilesMask, faDirectory, Ch) = 0 then
    try
      repeat
        if (Ch.Name = '.') or (Ch.Name = '..') or ((Ch.Attr and faDirectory) = 0) then
          Continue;
        if FindFirst(Content + Ch.Name + PathDelim + '*.usx', faAnyFile, F) = 0 then
        try
          repeat
            Files.Add(NameValue(Ch.Name + #9 + ChangeFileExt(F.Name, ''),
              ReadFileText(Content + Ch.Name + PathDelim + F.Name)));
          until FindNext(F) <> 0;
        finally
          FindClose(F);
        end;
      until FindNext(Ch) <> 0;
    finally
      FindClose(Ch);
    end;
    TocText := '';
    if FileExists(Content + 'toc.yml') then
      TocText := ReadFileText(Content + 'toc.yml');
    BuildChunks(C, Files, TocText);
  finally
    Files.Free;
  end;
end;

function LoadFromTsrc(const FileName: string; C: TSourceChunking): Boolean;
var
  Src: TFileStream;
  Bz: TDecompressBzip2Stream;
  Tar: TMemoryStream;
  Archive: TTarArchive;
  Rec: TTarDirRec;
  Files: TStringList;
  Buf: array[0..65535] of Byte;
  N: LongInt;
  Key, TocText, Name: string;
begin
  Result := False;
  Files := TStringList.Create;
  Tar := TMemoryStream.Create;
  try
    try
      Src := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
      try
        Bz := TDecompressBzip2Stream.Create(Src);
        try
          repeat
            N := Bz.Read(Buf, SizeOf(Buf));
            if N > 0 then
              Tar.WriteBuffer(Buf, N);
          until N <= 0;
        finally
          Bz.Free;
        end;
      finally
        Src.Free;
      end;
      Tar.Position := 0;
      TocText := '';
      Archive := TTarArchive.Create(Tar);
      try
        Archive.Reset;
        while Archive.FindNext(Rec) do
        begin
          if Rec.FileType <> ftNormal then
            Continue;
          Name := StringReplace(Rec.Name, '\', '/', [rfReplaceAll]);
          if Copy(Name, 1, 2) = './' then
            Delete(Name, 1, 2);
          if Name = 'content/toc.yml' then
            TocText := Archive.ReadFile
          else
          begin
            Key := UsxEntryKey(Name);
            if Key <> '' then
              Files.Add(NameValue(Key, Archive.ReadFile));
          end;
        end;
      finally
        Archive.Free;
      end;
    except
      Exit(False);   // corrupt or not a tsrc: treated as unavailable
    end;
    BuildChunks(C, Files, TocText);
    Result := Length(C.Chunks) > 0;
  finally
    Tar.Free;
    Files.Free;
  end;
end;

{ --- TSourceLibrary --- }

constructor TSourceLibrary.Create(const LibraryDir, BundledDir: string);
begin
  inherited Create;
  FLibraryDir := LibraryDir;
  FBundledDir := BundledDir;
  FCache := specialize TObjectDictionary<string, TSourceChunking>.Create([doOwnsValues]);
end;

destructor TSourceLibrary.Destroy;
begin
  FCache.Free;
  inherited Destroy;
end;

function TSourceLibrary.Find(const Container: string): TSourceChunking;
var
  C: TSourceChunking;
  Dir, Tsrc: string;
begin
  if FCache.TryGetValue(Container, Result) then
    Exit;
  Result := nil;
  if (Container = '') or (Pos('/', Container) > 0) or (Pos('\', Container) > 0) or
     (Pos('..', Container) > 0) then
    Exit;
  C := TSourceChunking.Create;
  C.Container := Container;
  Dir := '';
  if FLibraryDir <> '' then
    Dir := IncludeTrailingPathDelimiter(FLibraryDir) + Container;
  Tsrc := '';
  if FBundledDir <> '' then
    Tsrc := IncludeTrailingPathDelimiter(FBundledDir) + Container + '.tsrc';
  if (Dir <> '') and LoadFromFolder(Dir, C) and (Length(C.Chunks) > 0) then
    C.Location := Dir
  else if (Tsrc <> '') and FileExists(Tsrc) and LoadFromTsrc(Tsrc, C) then
  begin
    C.Location := Tsrc;
    C.Bundled := True;
  end
  else
    FreeAndNil(C);
  FCache.Add(Container, C);   // nil too: don't look twice
  Result := C;
end;

end.
