unit WBForeignCheck;

{$mode objfpc}{$H+}

(* Text from another language, for cross-check: verses pasted from another
   language's Bible or source text, verses reworded to read like another
   language, and chunks taken from another language's book.

   Other-language texts are projects (in the projects folder or another
   folder, say a neighbouring language's repos downloaded for the purpose)
   and BTT-Writer's source texts. Each is compared verse by verse with the
   same verse of the same book, with WBSimilarity's SequenceRatio (Python
   difflib's ratio):

   - same: a current verse of 40 or more characters is 97% or more alike;
   - reworded: an edit made a verse 80% or more alike, at least 15 points
     more than before, and the verse still is. This is how the Bwile
     1 Peter and 1 John verses reworded towards the Bemba Bible in October
     2026 show; a verse merely close to a related language is not enough
     (412 of 2978 Bwile verses were 80% alike to Bemba from their first
     version, drafted from it);
   - chunk: 70% or more of a chunk's word runs are in one chunk of another
     language's text, of any book.

   Related languages share words: Bwile verses are up to 0.98 alike to
   Bemba by chance (spacing differs), which is why the thresholds are high.

   A same or chunk match between two projects is reported on the one that
   had the text later, by both projects' git history (the first version
   holding it), with the commit that brought it in; the earlier one is not
   reported. Without history on either side, or at the same moment, both
   are, marked unordered. A source text counts as the original.
   Texts in the language's own group (WBCrossScan.LanguageGroup) are never
   compared. *)

interface

uses
  Classes, SysUtils, Generics.Collections, WBCrossCheck, WBCrossScan, WBCrossTitles,
  WBSources, WBSimilarity, WBChunkHistory;

const
  SameRatio = 0.97;
  SameMinChars = 40;
  RewordRatio = 0.80;
  RewordGain = 0.15;
  RewordMinChars = 20;
  ChunkShare = 0.70;
  ChunkMinRuns = 8;
  { a word run in more chunks than this is a common phrase: not counted }
  RunMaxChunks = 12;
  { below this TrigramDice no pair reached a SequenceRatio of 0.78 }
  DiceFloor = 0.40;

type
  { A text in another language to compare with. }
  TForeignText = class
  private
    FIndex: specialize TDictionary<string, Integer>;   // '5:8' -> verse
  public
    Name: string;        // bem_1pe_text_reg, en_1pe_ulb
    Lang, LangName: string;
    Group: string;
    Book: string;
    IsSource: Boolean;
    Dir: string;          // a project's folder (for its history); '' for a source
    HistoryRead, HasHistory: Boolean;
    Versions: TChunkVersions;
    Keys: TStringArray;
    Words: array of UnicodeString;
    Trigrams: array of TTrigrams;
    ChunkNames: TStringArray;     // 05/08
    ChunkRuns: array of THashList;
    constructor Create;
    destructor Destroy; override;
    procedure AddVerse(Chapter, Verse: Integer; const W: UnicodeString);
    { Position in Words of chapter:verse, or -1. }
    function Find(Chapter, Verse: Integer): Integer;
  end;
  TForeignTexts = specialize TObjectList<TForeignText>;

  TForeignKind = (fkSame, fkReworded, fkChunk);

  TForeignFinding = record
    Doc: Integer;        // the current chunk file
    Kind: TForeignKind;
    Verse: Integer;      // fkSame, fkReworded
    Text: Integer;       // position in the TForeignTexts
    Chunk: string;       // fkChunk: the chunk of Text
    Now, Before: Double; // likeness (fkChunk: share of word runs)
    Since: Integer;      // the version that brought it in (-1 unknown)
    Unordered: Boolean;  // fkSame, fkChunk: which had it first is unknown
  end;
  TForeignFindings = array of TForeignFinding;

{ Adds the text projects in Dir (current text). }
procedure AddProjectTexts(const Dir: string; Texts: TForeignTexts);
{ Adds BTT-Writer's Bible source texts of Book (installed or bundled). }
procedure AddSourceTexts(Sources: TSourceLibrary; const LibraryDir, BundledDir,
  Book: string; Texts: TForeignTexts);
{ Findings for the projects Scan reports on, against the texts of other
  language groups. Without history only fkSame and fkChunk. }
function FindForeignText(Scan: TCrossScan; Texts: TForeignTexts;
  NoHistory: Boolean): TForeignFindings;

implementation

uses
  fpjson, WBJson, WBProject;

constructor TForeignText.Create;
begin
  FIndex := specialize TDictionary<string, Integer>.Create;
end;

destructor TForeignText.Destroy;
begin
  FIndex.Free;
  inherited Destroy;
end;

procedure TForeignText.AddVerse(Chapter, Verse: Integer; const W: UnicodeString);
var
  Key: string;
  I: Integer;
begin
  if W = '' then
    Exit;
  Key := IntToStr(Chapter) + ':' + IntToStr(Verse);
  if FIndex.TryGetValue(Key, I) then
  begin
    Words[I] := Words[I] + ' ' + W;
    Trigrams[I] := TrigramsOf(Words[I]);
    Exit;
  end;
  I := Length(Words);
  FIndex.Add(Key, I);
  Keys := Concat(Keys, [Key]);
  SetLength(Words, I + 1);
  SetLength(Trigrams, I + 1);
  Words[I] := W;
  Trigrams[I] := TrigramsOf(W);
end;

function TForeignText.Find(Chapter, Verse: Integer): Integer;
begin
  if not FIndex.TryGetValue(IntToStr(Chapter) + ':' + IntToStr(Verse), Result) then
    Result := -1;
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

function RunsOf(const Text: string): THashList;
var
  W: THashList;
  V: TVerseList;
begin
  TokenizeWords(Text, W, V);
  Result := Shingles(W, ShingleWords);
end;

procedure AddProjectTexts(const Dir: string; Texts: TForeignTexts);
var
  SR: TSearchRec;
  List: TStringList;
  PDir, Lang: string;
  Manifest: TJSONObject;
  T: TForeignText;
  Chunks: TProjectChunks;
  VT: TVerseTexts;
  I, J, K, Ch: Integer;
  Text: string;
begin
  List := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + AllFilesMask, faDirectory, SR) = 0 then
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
      PDir := IncludeTrailingPathDelimiter(Dir) + List[I] + PathDelim;
      if not FileExists(PDir + 'manifest.json') then
        Continue;
      try
        Manifest := ReadJSONObjectFile(PDir + 'manifest.json');
      except
        Continue;
      end;
      try
        Lang := StrField(Manifest, 'target_language.id');
        if (StrField(Manifest, 'type.id') <> 'text') or (Lang = '') or
           (StrField(Manifest, 'project.id') = '') then
          Continue;
        T := TForeignText.Create;
        T.Name := List[I];
        T.Dir := PDir;
        T.Lang := Lang;
        T.LangName := StrField(Manifest, 'target_language.name');
        T.Group := LanguageGroup(Lang);
        T.Book := StrField(Manifest, 'project.id');
      finally
        Manifest.Free;
      end;
      Texts.Add(T);
      Chunks := ProjectChunks(PDir);
      for J := 0 to High(Chunks) do
      begin
        Ch := StrToIntDef(Chunks[J].Chapter, -1);
        if (Ch < 0) or (Chunks[J].Chunk = 'title') then
          Continue;
        Text := ReadText(Chunks[J].Path);
        VT := VerseWordTexts(Text);
        for K := 0 to High(VT) do
          T.AddVerse(Ch, VT[K].Verse, VT[K].Text);
        T.ChunkNames := Concat(T.ChunkNames, [Chunks[J].Chapter + '/' + Chunks[J].Chunk]);
        T.ChunkRuns := Concat(T.ChunkRuns, [RunsOf(Text)]);
      end;
    end;
  finally
    List.Free;
  end;
end;

{ Container names of Book's Bible texts in Dir: <lang>_<book>_<resource>,
  with Ext (a folder when '', else a file). }
procedure ListContainers(const Dir, Book, Ext: string; Names: TStringList);
const
  NotBible: array[0..4] of string = ('tn', 'tq', 'tw', 'ta', 'obs');
var
  SR: TSearchRec;
  Parts: TStringArray;
  N: string;
  Skip: Boolean;
  X: string;
begin
  if (Dir = '') or (FindFirst(IncludeTrailingPathDelimiter(Dir) + '*_' + Book + '_*' + Ext,
    faAnyFile, SR) <> 0) then
    Exit;
  try
    repeat
      N := SR.Name;
      if Ext <> '' then
        N := Copy(N, 1, Length(N) - Length(Ext));
      Parts := N.Split(['_']);
      if (Length(Parts) <> 3) or (Parts[1] <> Book) then
        Continue;
      Skip := False;
      for X in NotBible do
        if Copy(Parts[2], 1, Length(X)) = X then
          Skip := True;
      if not Skip and (Names.IndexOf(N) < 0) then
        Names.Add(N);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure AddSourceTexts(Sources: TSourceLibrary; const LibraryDir, BundledDir,
  Book: string; Texts: TForeignTexts);
var
  Names: TStringList;
  C: TSourceChunking;
  T: TForeignText;
  N, Joined: string;
  I, J, Ch, Count: Integer;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    ListContainers(LibraryDir, Book, '', Names);
    ListContainers(BundledDir, Book, '.tsrc', Names);
    for N in Names do
    begin
      C := Sources.Find(N);
      if C = nil then
        Continue;
      T := TForeignText.Create;
      T.Name := N;
      T.Lang := Copy(N, 1, Pos('_', N) - 1);
      T.Group := LanguageGroup(T.Lang);
      T.Book := Book;
      T.IsSource := True;
      Count := 0;
      for I := 0 to High(C.Chunks) do
      begin
        Ch := StrToIntDef(C.Chunks[I].Chapter, -1);
        if Ch < 0 then
          Continue;
        Joined := '';
        for J := 0 to High(C.Chunks[I].Verses) do
          if J <= High(C.Chunks[I].Texts) then
          begin
            T.AddVerse(Ch, C.Chunks[I].Verses[J], WordText(C.Chunks[I].Texts[J]));
            Joined := Joined + ' ' + C.Chunks[I].Texts[J];
            Inc(Count);
          end;
        T.ChunkNames := Concat(T.ChunkNames, [C.Chunks[I].Chapter + '/' + C.Chunks[I].Chunk]);
        T.ChunkRuns := Concat(T.ChunkRuns, [RunsOf(Joined)]);
      end;
      if Count = 0 then
        T.Free     // not a Bible text after all (no verses)
      else
        Texts.Add(T);
    end;
  finally
    Names.Free;
  end;
end;

{ The ratio of A to B when the cheap filter lets it through, else 0. }
function Alike(const A: UnicodeString; const TA: TTrigrams; const B: UnicodeString;
  const TB: TTrigrams): Double;
begin
  if DiceOf(TA, TB) < DiceFloor then
    Exit(0);
  Result := SequenceRatio(A, B);
end;

{ The chunk (05/08) of a project text that holds Chapter:Verse, '' if
  none or a source text. }
function ChunkOfVerse(T: TForeignText; Chapter, Verse: Integer): string;
var
  J: Integer;
  Best, Ch, Start: Integer;
  Parts: TStringArray;
begin
  Result := '';
  Best := -1;
  for J := 0 to High(T.ChunkNames) do
  begin
    Parts := T.ChunkNames[J].Split(['/']);
    if Length(Parts) <> 2 then
      Continue;
    Ch := StrToIntDef(Parts[0], -1);
    Start := StrToIntDef(Parts[1], -1);
    if (Ch = Chapter) and (Start <= Verse) and (Start > Best) then
    begin
      Best := Start;
      Result := T.ChunkNames[J];
    end;
  end;
end;

function VerseIn(const VT: TVerseTexts; Verse: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(VT) do
    if VT[I].Verse = Verse then
      Exit(I);
  Result := -1;
end;

function FindForeignText(Scan: TCrossScan; Texts: TForeignTexts;
  NoHistory: Boolean): TForeignFindings;
var
  Docs: TCrossDocs;
  Refs: array of Integer;     // texts of this book in other groups
  D, I, J, K, R, X, Ch, Best, Hits: Integer;
  Cur, New: TVerseTexts;
  Last: array of UnicodeString;   // per verse of Cur: its last wording seen
  HasLast: array of Boolean;
  CurTri, NewTri: TTrigrams;
  Versions: array of Integer;
  F: TForeignFinding;
  Found: array of Boolean;    // per verse of Cur: already reported
  Sn, So, Sc, BestSn: Double;
  BestF: TForeignFinding;
  Runs: THashList;
  RunSet: specialize THashSet<QWord>;
  Index: specialize TDictionary<QWord, TDocList>;  // run -> chunk numbers
  List: TDocList;
  ChunkOf: array of array[0..1] of Integer;          // chunk number -> text, chunk
  Counts: specialize TDictionary<Integer, Integer>;
  Pair: specialize TPair<Integer, Integer>;
  H: QWord;
  Reported: specialize THashSet<Integer>;            // texts with verse findings
  Shared: specialize THashSet<QWord>;
  BestW: UnicodeString;
  BestChunk: string;
  Theirs: Int64;
  Unknown: Boolean;

  function SameFile(A, B: Integer): Boolean;
  begin
    Result := (Docs[A].Project = Docs[B].Project) and (Docs[A].Chapter = Docs[B].Chapter) and
      (Docs[A].Chunk = Docs[B].Chunk);
  end;


  { Runs of Text, as a set }
  procedure RunsInto(const Text: string; Into: specialize THashSet<QWord>);
  var
    Hh: QWord;
  begin
    Into.Clear;
    for Hh in RunsOf(Text) do
      Into.Add(Hh);
  end;

  { Whether Text holds ChunkShare of Want }
  function Holds(const Text: string; Want: specialize THashSet<QWord>): Boolean;
  var
    Got: specialize THashSet<QWord>;
    Hh: QWord;
    N: Integer;
  begin
    if Want.Count = 0 then
      Exit(False);
    Got := specialize THashSet<QWord>.Create;
    try
      RunsInto(Text, Got);
      N := 0;
      for Hh in Want do
        if Got.Contains(Hh) then
          Inc(N);
      Result := N >= ChunkShare * Want.Count;
    finally
      Got.Free;
    end;
  end;

  { Whether verse Verse of Text is Ratio alike to W }
  function HoldsVerse(const Text: string; Verse: Integer; const W: UnicodeString;
    Ratio: Double): Boolean;
  var
    VT: TVerseTexts;
    J: Integer;
  begin
    VT := VerseWordTexts(Text);
    J := VerseIn(VT, Verse);
    Result := (J >= 0) and (SequenceRatio(VT[J].Text, W) >= Ratio);
  end;

  { This file's first version (current included) that Test accepts: its
    position in Docs, or -1 }
  function OurFirst(D0: Integer; Want: specialize THashSet<QWord>; Verse: Integer;
    const W: UnicodeString): Integer;
  var
    X: Integer;
    Ok: Boolean;
  begin
    Result := -1;
    for X := 0 to High(Docs) do
      if (Docs[X].Project = Docs[D0].Project) and (Docs[X].Chapter = Docs[D0].Chapter) and
         (Docs[X].Chunk = Docs[D0].Chunk) then
      begin
        if Verse > 0 then
          Ok := HoldsVerse(Docs[X].Text, Verse, W, SameRatio)
        else
          Ok := Holds(Docs[X].Text, Want);
        if Ok and ((Result < 0) or (Docs[X].Time < Docs[Result].Time)) then
          Result := X;
      end;
  end;

  { When the other project first had it: the runs Want in Chunk, or verse
    Verse of chapter Chapter Ratio alike to W in any chunk of it. Its time,
    NotCommitted if only on disk, -1 if it has no history }
  function TheirFirst(T: TForeignText; const Chunk: string; Chapter: Integer;
    Want: specialize THashSet<QWord>; Verse: Integer; const W: UnicodeString;
    Ratio: Double): Int64;
  var
    Commits: TCommitFilesList;
    J: Integer;
    Ok: Boolean;
  begin
    if not T.HistoryRead then
    begin
      T.HistoryRead := True;
      T.HasHistory := (T.Dir <> '') and ReadChunkHistory(T.Dir, T.Versions, Commits);
    end;
    if not T.HasHistory then
      Exit(-1);
    Result := NotCommitted;
    for J := 0 to High(T.Versions) do
    begin
      if Verse > 0 then
        Ok := (StrToIntDef(Copy(T.Versions[J].Path, 1, Pos('/', T.Versions[J].Path) - 1),
          -1) = Chapter) and HoldsVerse(T.Versions[J].Text, Verse, W, Ratio)
      else
        Ok := (T.Versions[J].Path = Chunk + '.txt') and Holds(T.Versions[J].Text, Want);
      if Ok and (T.Versions[J].Time < Result) then
        Result := T.Versions[J].Time;
    end;
  end;

  { Sets F.Since and F.Unordered; False if the other project had it later
    (it copied from here: not reported here) }
  function Ordered(var F: TForeignFinding; Want: specialize THashSet<QWord>;
    const W: UnicodeString; const Chunk: string): Boolean;
  var
    Ours: Integer;
    Theirs: Int64;
  begin
    Result := True;
    if NoHistory then
    begin
      F.Unordered := not Texts[F.Text].IsSource;
      Exit;
    end;
    Ours := OurFirst(F.Doc, Want, F.Verse, W);
    F.Since := Ours;
    if Texts[F.Text].IsSource or (Ours < 0) then
      Exit;
    Theirs := TheirFirst(Texts[F.Text], Chunk, StrToIntDef(Docs[F.Doc].Chapter, -1), Want, F.Verse, W,
      SameRatio);
    if (Theirs < 0) or (Theirs = Docs[Ours].Time) then
      F.Unordered := True
    else if Theirs > Docs[Ours].Time then
      Result := False;
  end;

begin
  Result := nil;
  Docs := Scan.Docs;

  { word runs of every chunk of every other-group text, for fkChunk }
  Index := specialize TDictionary<QWord, TDocList>.Create;
  Counts := specialize TDictionary<Integer, Integer>.Create;
  RunSet := specialize THashSet<QWord>.Create;
  Reported := specialize THashSet<Integer>.Create;
  Shared := specialize THashSet<QWord>.Create;
  try
    ChunkOf := nil;
    for X := 0 to Texts.Count - 1 do
      if Texts[X].Group <> Scan.Group then
        for J := 0 to High(Texts[X].ChunkRuns) do
        begin
          SetLength(ChunkOf, Length(ChunkOf) + 1);
          ChunkOf[High(ChunkOf)][0] := X;
          ChunkOf[High(ChunkOf)][1] := J;
          for H in Texts[X].ChunkRuns[J] do
          begin
            if not Index.TryGetValue(H, List) then
              List := nil;
            if (Length(List) <= RunMaxChunks) and
               ((Length(List) = 0) or (List[High(List)] <> High(ChunkOf))) then
              Index.AddOrSetValue(H, Concat(List, [High(ChunkOf)]));
          end;
        end;

    for D := 0 to High(Docs) do
    begin
      if not Docs[D].Current or ((D <= High(Scan.Report)) and not Scan.Report[D]) then
        Continue;
      Ch := StrToIntDef(Docs[D].Chapter, -1);
      if (Ch < 0) or (Docs[D].Chunk = 'title') then
        Continue;
      Refs := nil;
      for X := 0 to Texts.Count - 1 do
        if (Texts[X].Group <> Scan.Group) and (Texts[X].Book = Docs[D].Book) then
          Refs := Concat(Refs, [X]);
      Reported.Clear;
      Cur := VerseWordTexts(Docs[D].Text);
      SetLength(Found, Length(Cur));
      for I := 0 to High(Found) do
        Found[I] := False;

      if Length(Refs) > 0 then
      begin
        { fkSame }
        for I := 0 to High(Cur) do
        begin
          if Length(Cur[I].Text) < SameMinChars then
            Continue;
          CurTri := TrigramsOf(Cur[I].Text);
          BestSn := 0;
          for X in Refs do
          begin
            K := Texts[X].Find(Ch, Cur[I].Verse);
            if K < 0 then
              Continue;
            Sn := Alike(Cur[I].Text, CurTri, Texts[X].Words[K], Texts[X].Trigrams[K]);
            if (Sn >= SameRatio) and (Sn > BestSn) then
            begin
              BestSn := Sn;
              BestF := Default(TForeignFinding);
              BestF.Doc := D;
              BestF.Kind := fkSame;
              BestF.Verse := Cur[I].Verse;
              BestF.Text := X;
              BestF.Now := Sn;
              BestF.Since := -1;
              BestW := Texts[X].Words[K];
              BestChunk := ChunkOfVerse(Texts[X], Ch, Cur[I].Verse);
            end;
          end;
          if BestSn > 0 then
          begin
            Found[I] := True;   // either way, not one to look at again
            if Ordered(BestF, RunSet, BestW, BestChunk) then
            begin
              Result := Concat(Result, [BestF]);
              Reported.Add(BestF.Text);
            end;
          end;
        end;

        { fkReworded: walk this file's versions oldest first }
        if not NoHistory then
        begin
          Versions := nil;
          for X := 0 to High(Docs) do
            if not Docs[X].Current and SameFile(X, D) then
              Versions := Concat(Versions, [X]);
          Versions := Concat(Versions, [D]);
          for I := 1 to High(Versions) - 1 do
          begin
            X := Versions[I];
            J := I - 1;
            while (J >= 0) and (Docs[Versions[J]].Time > Docs[X].Time) do
            begin
              Versions[J + 1] := Versions[J];
              Dec(J);
            end;
            Versions[J + 1] := X;
          end;
          { each verse against its last wording seen: an edit session may
            leave a version without the verse in between }
          SetLength(Last, Length(Cur));
          SetLength(HasLast, Length(Cur));
          for I := 0 to High(Cur) do
            HasLast[I] := False;
          for J := 0 to High(Versions) do
          begin
            if (J > 0) and (Docs[Versions[J]].Text = Docs[Versions[J - 1]].Text) then
              Continue;
            New := VerseWordTexts(Docs[Versions[J]].Text);
            for I := 0 to High(Cur) do
            begin
              K := VerseIn(New, Cur[I].Verse);
              if K < 0 then
                Continue;
              if not HasLast[I] or Found[I] or (New[K].Text = Last[I]) or
                 (Length(New[K].Text) < RewordMinChars) then
              begin
                Last[I] := New[K].Text;
                HasLast[I] := True;
                Continue;
              end;
              NewTri := TrigramsOf(New[K].Text);
              CurTri := TrigramsOf(Cur[I].Text);
              BestSn := 0;
              for X in Refs do
              begin
                Best := Texts[X].Find(Ch, Cur[I].Verse);
                if Best < 0 then
                  Continue;
                Sn := Alike(New[K].Text, NewTri, Texts[X].Words[Best], Texts[X].Trigrams[Best]);
                if (Sn < RewordRatio) or (Sn <= BestSn) then
                  Continue;
                So := SequenceRatio(Last[I], Texts[X].Words[Best]);
                if Sn - So < RewordGain then
                  Continue;
                if Cur[I].Text = New[K].Text then
                  Sc := Sn
                else
                  Sc := Alike(Cur[I].Text, CurTri, Texts[X].Words[Best], Texts[X].Trigrams[Best]);
                if Sc < RewordRatio then
                  Continue;   // since changed again
                { the other text must have read like this before the edit }
                Unknown := False;
                if not Texts[X].IsSource then
                begin
                  Theirs := TheirFirst(Texts[X], '', Ch, nil, Cur[I].Verse, New[K].Text,
                    RewordRatio);
                  if Theirs < 0 then
                    Unknown := True
                  else if Theirs > Docs[Versions[J]].Time then
                    Continue;
                end;
                BestSn := Sn;
                BestF := Default(TForeignFinding);
                BestF.Doc := D;
                BestF.Kind := fkReworded;
                BestF.Verse := Cur[I].Verse;
                BestF.Text := X;
                BestF.Now := Sc;
                BestF.Before := So;
                BestF.Since := Versions[J];
                BestF.Unordered := Unknown;
              end;
              if BestSn > 0 then
              begin
                Result := Concat(Result, [BestF]);
                Reported.Add(BestF.Text);
                Found[I] := True;
              end;
              Last[I] := New[K].Text;
            end;
          end;
        end;
      end;

      { fkChunk: one chunk of another language holds most of this one }
      Runs := RunsOf(Docs[D].Text);
      RunSet.Clear;
      for H in Runs do
        RunSet.Add(H);
      if RunSet.Count < ChunkMinRuns then
        Continue;
      Counts.Clear;
      for H in RunSet do
        if Index.TryGetValue(H, List) and (Length(List) <= RunMaxChunks) then
          for K in List do
            if Counts.ContainsKey(K) then
              Counts[K] := Counts[K] + 1
            else
              Counts.Add(K, 1);
      Best := -1;
      Hits := 0;
      for Pair in Counts do
        if (Pair.Value > Hits) or ((Pair.Value = Hits) and (Pair.Key < Best)) then
        begin
          Best := Pair.Key;
          Hits := Pair.Value;
        end;
      if (Best >= 0) and (Hits >= ChunkShare * RunSet.Count) and
         not Reported.Contains(ChunkOf[Best][0]) then
      begin
        F := Default(TForeignFinding);
        F.Doc := D;
        F.Kind := fkChunk;
        F.Text := ChunkOf[Best][0];
        F.Chunk := Texts[F.Text].ChunkNames[ChunkOf[Best][1]];
        F.Now := Hits / RunSet.Count;
        F.Since := -1;
        { the runs both share decide who had the text first }
        Shared.Clear;
        for H in Texts[F.Text].ChunkRuns[ChunkOf[Best][1]] do
          if RunSet.Contains(H) then
            Shared.Add(H);
        if Ordered(F, Shared, '', F.Chunk) then
          Result := Concat(Result, [F]);
      end;
    end;
  finally
    Shared.Free;
    Reported.Free;
    RunSet.Free;
    Counts.Free;
    Index.Free;
  end;
end;

end.
