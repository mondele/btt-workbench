unit WBCrossCheck;

{$mode objfpc}{$H+}
{$Q-}{$R-}

(* Finds text copied from one book's chunks into another's, in the projects
   of one language: whole chunks pasted over, blocks of verses, and the end
   of another book's chunk stuck onto the end of a chunk.

   Texts are compared as runs of ShingleWords words (markers left out, case
   folded). Every version of every chunk is indexed with the time it was
   committed, so for each run in a current chunk the book that had it first
   is known: text another book had before this book did came from there.
   That also traces text whose source chunk has since been edited.

   Shared phrases are common in a language, so only these are reported:
   - a block of at least 25 words, or of at least 8 words covering half the
     chunk or more;
   - at least 6 words ending the chunk that also end a chunk of the other
     book (the tail of a selection pasted onto the end);
   - text run onto the last word without a space ("word.foreign words") that
     appears in the other book.
   Real parallels (Kings and Chronicles, the gospels, greetings and
   blessings) are left out by comparing the two places in the English ULB:
   when the English is alike there too, it is a parallel. That is not done
   when this chunk's verse numbers do not belong in its chapter, which a
   pasted block can show. *)

interface

uses
  Classes, SysUtils, WBSources;

const
  ShingleWords = 4;
  { A time later than any commit: files on disk not yet committed. }
  NotCommitted = High(Int64);

type
  TCrossDoc = record
    Book: string;       // project.id
    Project: string;    // folder name
    Chapter, Chunk: string;
    Commit, Author: string;
    Date: string;       // commit time as the author's clock showed it
    Time: Int64;        // NotCommitted for the file on disk
    Current: Boolean;   // the file on disk now
    Text: string;       // UTF-8
  end;
  TCrossDocs = array of TCrossDoc;

  TCrossKind = (ckWhole, ckPart, ckTail, ckGlued);

  TCrossFinding = record
    Doc: Integer;          // the current file that holds the copy
    Kind: TCrossKind;
    Verses: string;        // where in this chunk: '1-3', '' unknown
    Words: Integer;
    Origin: Integer;       // first version of the other book that had it
    OriginCurrent: Boolean;  // that chunk still holds it
    Since: Integer;        // first version of this book that had all of it
    Unordered: Boolean;    // same time: which came first is unknown
    Fragment: string;      // ckGlued: the text run on (UTF-8)
    Hash: QWord;           // the first word run matched (0 for ckGlued)
  end;
  TCrossFindings = array of TCrossFinding;

{ Findings for the current docs whose Report entry is set (Report may be
  shorter than Docs: missing entries count as set). English may be nil:
  then nothing is ruled out as a parallel. }
function FindCopiedText(const Docs: TCrossDocs; const Report: array of Boolean;
  English: TSourceLibrary): TCrossFindings;

{ Word hashes of USFM text, markers left out; Verses gets the verse each
  word is in (0 before the first \v). Exposed for tests. }
type
  THashList = array of QWord;
procedure TokenizeWords(const Text: string; out Hashes: THashList; out Verses: TVerseList);
{ Word runs of ShingleWords words. }
function Shingles(const W: THashList; Size: Integer): THashList;
{ Text with markers left out and white space made single. }
function NormalText(const S: string): string;
{ Whether a version of a chunk holds the copied text of finding F. }
function HasCopiedText(const Doc: TCrossDoc; const F: TCrossFinding): Boolean;

type
  TVerseText = record
    Verse: Integer;
    Text: UnicodeString;   // its words in lower case, single spaces
  end;
  TVerseTexts = array of TVerseText;
{ The words of each verse of USFM chunk text, as TokenizeWords finds them,
  in order (a \v 4-5 range counts as 4; a verse marked twice is joined).
  Words before the first \v are left out. }
function VerseWordTexts(const Text: string): TVerseTexts;
{ The words of plain text (no markers), lower case, single spaces. }
function WordText(const S: string): UnicodeString;

implementation

uses
  Character, Generics.Collections, Generics.Defaults, WBVersification;

type
  THashIndex = specialize TDictionary<QWord, Integer>;

const
  FnvBasis = QWord(14695981039346656037);
  FnvPrime = QWord(1099511628211);
  Glue: set of Char = ['.', '!', '?', ';', ':', ','];
  ParallelRatio = 0.12;
  AppendGap = 6 * 60 * 60;   // seconds

function IsWordChar(C: WideChar): Boolean;
begin
  if Ord(C) < 128 then
    Exit(C in ['a'..'z', 'A'..'Z', '0'..'9', '_']);
  if (Ord(C) >= $D800) and (Ord(C) <= $DFFF) then
    Exit(True);   // a character outside the BMP: treat as a letter
  case TCharacter.GetUnicodeCategory(C) of
    TUnicodeCategory.ucUppercaseLetter, TUnicodeCategory.ucLowercaseLetter,
    TUnicodeCategory.ucTitlecaseLetter, TUnicodeCategory.ucModifierLetter,
    TUnicodeCategory.ucOtherLetter, TUnicodeCategory.ucNonSpacingMark,
    TUnicodeCategory.ucCombiningMark, TUnicodeCategory.ucEnclosingMark,
    TUnicodeCategory.ucDecimalNumber, TUnicodeCategory.ucLetterNumber,
    TUnicodeCategory.ucOtherNumber, TUnicodeCategory.ucConnectPunctuation:
      Result := True;
  else
    Result := False;
  end;
end;

procedure TokenizeWords(const Text: string; out Hashes: THashList; out Verses: TVerseList);
var
  U, Marker: UnicodeString;
  I, J, N, Verse, V: Integer;
  H: QWord;
  C: WideChar;
begin
  U := UTF8Decode(Text);
  Hashes := nil;
  Verses := nil;
  SetLength(Hashes, Length(U) div 2 + 1);
  SetLength(Verses, Length(Hashes));
  N := 0;
  Verse := 0;
  I := 1;
  while I <= Length(U) do
  begin
    C := U[I];
    if C = '\' then
    begin
      J := I + 1;
      while (J <= Length(U)) and (U[J] in ['a'..'z', 'A'..'Z', '0'..'9', '*', '+']) do
        Inc(J);
      Marker := Copy(U, I + 1, J - I - 1);
      I := J;
      if (Marker = 'v') or (Marker = 'c') then
      begin
        while (I <= Length(U)) and (U[I] = ' ') do
          Inc(I);
        V := 0;
        while (I <= Length(U)) and (U[I] in ['0'..'9']) do
        begin
          V := V * 10 + Ord(U[I]) - Ord('0');
          Inc(I);
        end;
        { a range: \v 4-5 }
        if (I < Length(U)) and (U[I] = '-') and (U[I + 1] in ['0'..'9']) then
        begin
          Inc(I);
          while (I <= Length(U)) and (U[I] in ['0'..'9']) do
            Inc(I);
        end;
        if Marker = 'v' then
          Verse := V;
      end;
      Continue;
    end;
    if IsWordChar(C) then
    begin
      J := I;
      while (J <= Length(U)) and IsWordChar(U[J]) do
        Inc(J);
      H := FnvBasis;
      for C in TCharacter.ToLower(Copy(U, I, J - I)) do
        H := (H xor Ord(C)) * FnvPrime;
      Hashes[N] := H;
      Verses[N] := Verse;
      Inc(N);
      I := J;
      Continue;
    end;
    Inc(I);
  end;
  SetLength(Hashes, N);
  SetLength(Verses, N);
end;

function VerseWordTexts(const Text: string): TVerseTexts;
var
  U, Marker, W: UnicodeString;
  I, J, K, Verse, V, N: Integer;
begin
  U := UTF8Decode(Text);
  Result := nil;
  N := 0;
  Verse := 0;
  I := 1;
  while I <= Length(U) do
  begin
    if U[I] = '\' then
    begin
      J := I + 1;
      while (J <= Length(U)) and (U[J] in ['a'..'z', 'A'..'Z', '0'..'9', '*', '+']) do
        Inc(J);
      Marker := Copy(U, I + 1, J - I - 1);
      I := J;
      if (Marker = 'v') or (Marker = 'c') then
      begin
        while (I <= Length(U)) and (U[I] = ' ') do
          Inc(I);
        V := 0;
        while (I <= Length(U)) and (U[I] in ['0'..'9']) do
        begin
          V := V * 10 + Ord(U[I]) - Ord('0');
          Inc(I);
        end;
        if (I < Length(U)) and (U[I] = '-') and (U[I + 1] in ['0'..'9']) then
        begin
          Inc(I);
          while (I <= Length(U)) and (U[I] in ['0'..'9']) do
            Inc(I);
        end;
        if Marker = 'v' then
          Verse := V;
      end;
      Continue;
    end;
    if IsWordChar(U[I]) then
    begin
      J := I;
      while (J <= Length(U)) and IsWordChar(U[J]) do
        Inc(J);
      if Verse > 0 then
      begin
        W := TCharacter.ToLower(Copy(U, I, J - I));
        if (N > 0) and (Result[N - 1].Verse = Verse) then
          Result[N - 1].Text := Result[N - 1].Text + ' ' + W
        else
        begin
          K := -1;
          for V := 0 to N - 1 do
            if Result[V].Verse = Verse then
              K := V;
          if K >= 0 then
            Result[K].Text := Result[K].Text + ' ' + W
          else
          begin
            SetLength(Result, N + 1);
            Result[N].Verse := Verse;
            Result[N].Text := W;
            Inc(N);
          end;
        end;
      end;
      I := J;
      Continue;
    end;
    Inc(I);
  end;
end;

function WordText(const S: string): UnicodeString;
var
  U: UnicodeString;
  I, J: Integer;
begin
  U := UTF8Decode(S);
  Result := '';
  I := 1;
  while I <= Length(U) do
    if IsWordChar(U[I]) then
    begin
      J := I;
      while (J <= Length(U)) and IsWordChar(U[J]) do
        Inc(J);
      if Result <> '' then
        Result := Result + ' ';
      Result := Result + TCharacter.ToLower(Copy(U, I, J - I));
      I := J;
    end
    else
      Inc(I);
end;

function Shingles(const W: THashList; Size: Integer): THashList;
var
  I, J: Integer;
  H: QWord;
begin
  Result := nil;
  if Length(W) < Size then
    Exit;
  SetLength(Result, Length(W) - Size + 1);
  for I := 0 to High(Result) do
  begin
    H := FnvBasis;
    for J := I to I + Size - 1 do
      H := ((H xor W[J]) * FnvPrime) xor (H shr 29);
    Result[I] := H;
  end;
end;

{ Shared distinct values over the smaller count (0 if either is empty). }
function Overlap(A, B: THashList): Double;
var
  I, J, NA, NB, Same: Integer;

  function Dedup(var X: THashList): Integer;
  var
    K, M: Integer;
  begin
    if Length(X) = 0 then
      Exit(0);
    specialize TArrayHelper<QWord>.Sort(X);
    M := 0;
    for K := 1 to High(X) do
      if X[K] <> X[M] then
      begin
        Inc(M);
        X[M] := X[K];
      end;
    Result := M + 1;
  end;

begin
  A := Copy(A);
  B := Copy(B);
  NA := Dedup(A);
  NB := Dedup(B);
  if (NA = 0) or (NB = 0) then
    Exit(0);
  I := 0;
  J := 0;
  Same := 0;
  while (I < NA) and (J < NB) do
    if A[I] = B[J] then
    begin
      Inc(Same);
      Inc(I);
      Inc(J);
    end
    else if A[I] < B[J] then
      Inc(I)
    else
      Inc(J);
  if NA < NB then
    Result := Same / NA
  else
    Result := Same / NB;
end;

{ The English ULB text of a book, by verse and by chunk. }
type
  TEnglishBook = class
    Found: Boolean;
    Verses: specialize TDictionary<Integer, string>;   // chapter*1000+verse
    Chunks: specialize TDictionary<string, string>;    // ChunkKey -> text
    constructor Create(Lib: TSourceLibrary; const Book: string);
    destructor Destroy; override;
    function VerseText(Chapter: Integer; const VS: array of Integer): string;
  end;

constructor TEnglishBook.Create(Lib: TSourceLibrary; const Book: string);
var
  Src: TSourceChunking;
  I, J, Ch: Integer;
  All: string;
begin
  Verses := specialize TDictionary<Integer, string>.Create;
  Chunks := specialize TDictionary<string, string>.Create;
  Src := nil;
  if Lib <> nil then
    Src := Lib.Find('en_' + Book + '_ulb');
  Found := Src <> nil;
  if not Found then
    Exit;
  for I := 0 to High(Src.Chunks) do
  begin
    Ch := StrToIntDef(Src.Chunks[I].Chapter, -1);
    All := '';
    for J := 0 to High(Src.Chunks[I].Verses) do
      if J <= High(Src.Chunks[I].Texts) then
      begin
        if Ch >= 0 then
          Verses.AddOrSetValue(Ch * 1000 + Src.Chunks[I].Verses[J], Src.Chunks[I].Texts[J]);
        All := All + ' ' + Src.Chunks[I].Texts[J];
      end;
    Chunks.AddOrSetValue(ChunkKey(Src.Chunks[I].Chapter, Src.Chunks[I].Chunk), All);
  end;
end;

destructor TEnglishBook.Destroy;
begin
  Verses.Free;
  Chunks.Free;
  inherited Destroy;
end;

function TEnglishBook.VerseText(Chapter: Integer; const VS: array of Integer): string;
var
  V: Integer;
  S: string;
begin
  Result := '';
  for V in VS do
    if Verses.TryGetValue(Chapter * 1000 + V, S) then
      Result := Result + ' ' + S;
end;

type
  TEntry = record
    Book: Integer;
    Doc: Integer;
    Next: Integer;
  end;

  TChecker = class
    Docs: TCrossDocs;
    English: TSourceLibrary;
    BookIds: TStringList;
    DocBook: array of Integer;
    Entries: array of TEntry;
    NEntries: Integer;
    First: THashIndex;      // shingle -> first entry
    Ends: THashIndex;       // last shingle of a version -> first entry
    CurrentSh: array of THashList;   // shingles of current docs
    WordVerses: array of TVerseList; // verses of current docs' words
    DocVerses: array of TVerseList;  // verse numbers of every doc
    EnglishBooks: specialize TObjectDictionary<string, TEnglishBook>;
    Norms: TStringList;     // normalised texts, made when needed
    Findings: TCrossFindings;
    constructor Create(const ADocs: TCrossDocs; AEnglish: TSourceLibrary);
    destructor Destroy; override;
    procedure BuildIndex;
    function EntryOf(Head, Book: Integer): Integer;
    procedure Add(var AIndex: THashIndex; H: QWord; Book, Doc: Integer; Earliest: Boolean);
    function EnglishOf(const Book: string): TEnglishBook;
    function Parallel(D, O: Integer; const VS: TVerseList): Boolean;
    function OriginStillHas(O: Integer; H: QWord): Boolean;
    function EndedBefore(D: Integer; const Sh: THashList; St: Integer;
      const Own: array of Integer): Boolean;
    function MostMatched(const Orig: array of Integer; St, K: Integer): Integer;
    procedure CheckDoc(D: Integer);
    procedure CheckGlued(D: Integer);
    function Norm(D: Integer): string;
  end;

constructor TChecker.Create(const ADocs: TCrossDocs; AEnglish: TSourceLibrary);
begin
  Docs := ADocs;
  English := AEnglish;
  BookIds := TStringList.Create;
  BookIds.Sorted := True;
  First := THashIndex.Create;
  Ends := THashIndex.Create;
  EnglishBooks := specialize TObjectDictionary<string, TEnglishBook>.Create([doOwnsValues]);
  Norms := nil;
end;

destructor TChecker.Destroy;
begin
  BookIds.Free;
  First.Free;
  Ends.Free;
  EnglishBooks.Free;
  Norms.Free;
  inherited Destroy;
end;

function TChecker.EntryOf(Head, Book: Integer): Integer;
begin
  Result := Head;
  while (Result >= 0) and (Entries[Result].Book <> Book) do
    Result := Entries[Result].Next;
end;

{ Records Doc under H for its book: the earliest doc (Earliest) or every
  doc (not Earliest; used for the ends of versions). }
procedure TChecker.Add(var AIndex: THashIndex; H: QWord; Book, Doc: Integer; Earliest: Boolean);
var
  Head, E: Integer;
begin
  if not AIndex.TryGetValue(H, Head) then
    Head := -1;
  if Earliest then
  begin
    E := EntryOf(Head, Book);
    if E >= 0 then
    begin
      if Docs[Doc].Time < Docs[Entries[E].Doc].Time then
        Entries[E].Doc := Doc;
      Exit;
    end;
  end;
  if NEntries > High(Entries) then
    SetLength(Entries, NEntries * 2 + 1024);
  Entries[NEntries].Book := Book;
  Entries[NEntries].Doc := Doc;
  Entries[NEntries].Next := Head;
  AIndex.AddOrSetValue(H, NEntries);
  Inc(NEntries);
end;

procedure TChecker.BuildIndex;
var
  D, I, B: Integer;
  W, Sh: THashList;
  VS: TVerseList;
  Seen: specialize THashSet<Integer>;
  V: Integer;
begin
  SetLength(DocBook, Length(Docs));
  SetLength(CurrentSh, Length(Docs));
  SetLength(WordVerses, Length(Docs));
  SetLength(DocVerses, Length(Docs));
  NEntries := 0;
  for D := 0 to High(Docs) do
  begin
    if not BookIds.Find(Docs[D].Book, B) then
      B := BookIds.Add(Docs[D].Book);
  end;
  Seen := specialize THashSet<Integer>.Create;
  try
    for D := 0 to High(Docs) do
    begin
      DocBook[D] := BookIds.IndexOf(Docs[D].Book);
      TokenizeWords(Docs[D].Text, W, VS);
      Sh := Shingles(W, ShingleWords);
      for I := 0 to High(Sh) do
        Add(First, Sh[I], DocBook[D], D, True);
      if Length(Sh) > 0 then
        Add(Ends, Sh[High(Sh)], DocBook[D], D, False);
      if Docs[D].Current then
      begin
        CurrentSh[D] := Sh;
        WordVerses[D] := VS;
      end;
      Seen.Clear;
      for V in VS do
        if (V > 0) and Seen.Add(V) then
          DocVerses[D] := Concat(DocVerses[D], [V]);
    end;
  finally
    Seen.Free;
  end;
end;

function TChecker.EnglishOf(const Book: string): TEnglishBook;
begin
  if not EnglishBooks.TryGetValue(Book, Result) then
  begin
    Result := TEnglishBook.Create(English, Book);
    EnglishBooks.Add(Book, Result);
  end;
end;

var
  ArticleHashes: THashList;

{ English shingles without a, an, the: "an eye for an eye" and "eye for
  eye" are the same parallel. }
function EnglishShingles(const S: string): THashList;
var
  W, Kept: THashList;
  VS: TVerseList;
  H, A: QWord;
  N: Integer;
  Skip: Boolean;
begin
  if ArticleHashes = nil then
    TokenizeWords('a an the', ArticleHashes, VS);
  TokenizeWords(S, W, VS);
  SetLength(Kept, Length(W));
  N := 0;
  for H in W do
  begin
    Skip := False;
    for A in ArticleHashes do
      if H = A then
        Skip := True;
    if not Skip then
    begin
      Kept[N] := H;
      Inc(N);
    end;
  end;
  SetLength(Kept, N);
  Result := Shingles(Kept, ShingleWords);
end;

{ Whether the copy in D (at verses VS) of text from O is a real parallel:
  the English is alike at both places. }
function TChecker.Parallel(D, O: Integer; const VS: TVerseList): Boolean;
var
  EA, EB: TEnglishBook;
  ChA, ChB, V, Last: Integer;
  Window: array of Integer;
  TA, TB, CA, CB: string;
begin
  Result := False;
  ChA := StrToIntDef(Docs[D].Chapter, -1);
  ChB := StrToIntDef(Docs[O].Chapter, -1);
  if (ChA < 1) or (ChB < 1) then
    Exit;
  { Verse numbers that do not belong in this chapter: pasted from elsewhere. }
  Last := VerseCount(Docs[D].Book, ChA);
  for V in VS do
    if (Last > 0) and (V > Last) then
      Exit;
  EA := EnglishOf(Docs[D].Book);
  EB := EnglishOf(Docs[O].Book);
  if not (EA.Found and EB.Found) then
    Exit;
  if not EA.Chunks.TryGetValue(ChunkKey(Docs[D].Chapter, Docs[D].Chunk), CA) then
    CA := '';
  if not EB.Chunks.TryGetValue(ChunkKey(Docs[O].Chapter, Docs[O].Chunk), CB) then
    CB := '';
  { this verse and its neighbours, against the other chunk's verses }
  Window := nil;
  for V in VS do
    Window := Concat(Window, [V - 1, V, V + 1]);
  TA := EA.VerseText(ChA, Window);
  if TA = '' then
    TA := CA;
  Window := nil;
  for V in DocVerses[O] do
    Window := Concat(Window, [V - 1, V, V + 1]);
  TB := EB.VerseText(ChB, Window);
  if TB = '' then
    TB := CB;
  Result := (Overlap(EnglishShingles(TA), EnglishShingles(TB)) >= ParallelRatio) or
    (Overlap(EnglishShingles(CA), EnglishShingles(CB)) >= ParallelRatio);
end;

{ Whether the current file of O's chunk holds shingle H. }
function TChecker.OriginStillHas(O: Integer; H: QWord): Boolean;
var
  D: Integer;
  X: QWord;
begin
  for D := 0 to High(Docs) do
    if Docs[D].Current and (Docs[D].Project = Docs[O].Project) and
       (Docs[D].Chapter = Docs[O].Chapter) and (Docs[D].Chunk = Docs[O].Chunk) then
    begin
      for X in CurrentSh[D] do
        if X = H then
          Exit(True);
      Exit(False);
    end;
  Result := False;
end;

function VerseSpan(const VS: TVerseList; A, B: Integer): TVerseList;
var
  I, V: Integer;
  Seen: Boolean;
begin
  Result := nil;
  for I := A to B do
    if (I >= 0) and (I <= High(VS)) and (VS[I] > 0) then
    begin
      Seen := False;
      for V in Result do
        if V = VS[I] then
          Seen := True;
      if not Seen then
        Result := Concat(Result, [VS[I]]);
    end;
end;

function SpanText(const VS: TVerseList): string;
var
  Lo, Hi, V: Integer;
begin
  if Length(VS) = 0 then
    Exit('');
  Lo := VS[0];
  Hi := VS[0];
  for V in VS do
  begin
    if V < Lo then
      Lo := V;
    if V > Hi then
      Hi := V;
  end;
  if Lo = Hi then
    Result := IntToStr(Lo)
  else
    Result := IntToStr(Lo) + '-' + IntToStr(Hi);
end;

function TChecker.EndedBefore(D: Integer; const Sh: THashList; St: Integer;
  const Own: array of Integer): Boolean;
var
  Head, E, I, J: Integer;
  T: Int64;
begin
  Result := False;
  I := St - ShingleWords;    // the shingle of the words just before
  if I < 0 then
    Exit;
  T := 0;
  for J := St to High(Sh) do
    if (Own[J] >= 0) and (Docs[Own[J]].Time > T) then
      T := Docs[Own[J]].Time;
  if not Ends.TryGetValue(Sh[I], Head) then
    Exit;
  E := Head;
  while E >= 0 do
  begin
    J := Entries[E].Doc;
    if (Docs[J].Project = Docs[D].Project) and (Docs[J].Chapter = Docs[D].Chapter) and
       (Docs[J].Chunk = Docs[D].Chunk) and (Docs[J].Time <= T - AppendGap) then
      Exit(True);
    E := Entries[E].Next;
  end;
end;

{ Position in Orig[St..K-1] whose chunk the most positions match. }
function TChecker.MostMatched(const Orig: array of Integer; St, K: Integer): Integer;
var
  I, J, N, BestN: Integer;
begin
  Result := St;
  BestN := 0;
  for I := St to K - 1 do
  begin
    N := 0;
    for J := St to K - 1 do
      if (Docs[Orig[J]].Project = Docs[Orig[I]].Project) and
         (Docs[Orig[J]].Chapter = Docs[Orig[I]].Chapter) and
         (Docs[Orig[J]].Chunk = Docs[Orig[I]].Chunk) then
        Inc(N);
    if N > BestN then
    begin
      BestN := N;
      Result := I;
    end;
  end;
end;

procedure TChecker.CheckDoc(D: Integer);
var
  Pb: Integer;
  Sh: THashList;
  Orig, Own: array of Integer;
  Unord: array of Boolean;
  I, K, St, Head, E, Best, OwnE, Book, L, NWords: Integer;
  OwnT: Int64;
  Big, Tail: Boolean;
  F: TCrossFinding;
  VS: TVerseList;
begin
  Sh := CurrentSh[D];
  if Length(Sh) = 0 then
    Exit;
  NWords := Length(WordVerses[D]);
  SetLength(Orig, Length(Sh));
  SetLength(Own, Length(Sh));
  SetLength(Unord, Length(Sh));
  for I := 0 to High(Sh) do
  begin
    Orig[I] := -1;
    Own[I] := -1;
    Unord[I] := False;
    if not First.TryGetValue(Sh[I], Head) then
      Continue;
    OwnE := EntryOf(Head, DocBook[D]);
    if OwnE < 0 then
      Continue;
    Own[I] := Entries[OwnE].Doc;
    OwnT := Docs[Own[I]].Time;
    Best := -1;
    E := Head;
    while E >= 0 do
    begin
      if (Entries[E].Book <> DocBook[D]) and (Docs[Entries[E].Doc].Time <= OwnT) and
         ((Best < 0) or (Docs[Entries[E].Doc].Time < Docs[Best].Time)) then
        Best := Entries[E].Doc;
      E := Entries[E].Next;
    end;
    Orig[I] := Best;
    if Best >= 0 then
      Unord[I] := Docs[Best].Time = OwnT;
  end;
  I := 0;
  while I <= High(Sh) do
  begin
    if Orig[I] < 0 then
    begin
      Inc(I);
      Continue;
    end;
    Book := DocBook[Orig[I]];
    St := I;
    while (I <= High(Sh)) and (Orig[I] >= 0) and (DocBook[Orig[I]] = Book) do
      Inc(I);
    K := I;    // run is St..K-1
    L := K - St + ShingleWords - 1;
    Big := (L >= 25) or ((L * 2 >= NWords) and (L >= 8));
    Tail := False;
    if not Big and (K = Length(Sh)) and (L >= 6) and Ends.TryGetValue(Sh[K - 1], Head) then
    begin
      E := Head;
      while (E >= 0) and not Tail do
      begin
        Tail := Entries[E].Book = Book;
        E := Entries[E].Next;
      end;
    end;
    { A tail must have been added to a chunk that already ended there: an
      earlier version (at least AppendGap older) ended with the words just
      before it. Phrases typed while drafting do not pass. Without history
      that cannot be told, and the tail is kept. }
    if Tail and not Unord[St] and not EndedBefore(D, Sh, St, Own) then
      Tail := False;
    if not (Big or Tail) then
      Continue;
    { The run's source: the chunk most of it matches. Its first words may
      be a phrase that chunk shares with others ("Write to the angel of the
      church in ..."), so the first match alone can name the wrong one. }
    Pb := MostMatched(Orig, St, K);
    VS := VerseSpan(WordVerses[D], St, K + ShingleWords - 2);
    if Parallel(D, Orig[Pb], VS) then
      Continue;
    F := Default(TCrossFinding);
    F.Doc := D;
    if not Big then
      F.Kind := ckTail
    else if L * 10 >= NWords * 8 then
      F.Kind := ckWhole
    else
      F.Kind := ckPart;
    F.Verses := SpanText(VS);
    F.Words := L;
    F.Origin := Orig[Pb];
    F.OriginCurrent := OriginStillHas(Orig[Pb], Sh[Pb]);
    F.Since := Own[St];
    F.Unordered := Unord[St];
    F.Hash := Sh[Pb];
    for E := St to K - 1 do
      if (Own[E] >= 0) and (Docs[Own[E]].Time > Docs[F.Since].Time) then
      begin
        F.Since := Own[E];
        F.Unordered := Unord[E];
      end;
    Findings := Concat(Findings, [F]);
  end;
end;

function NormalText(const S: string): string;
var
  I, J: Integer;
  Space: Boolean;
begin
  Result := '';
  Space := False;
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = '\' then
    begin
      J := I + 1;
      while (J <= Length(S)) and (S[J] in ['a'..'z', 'A'..'Z', '0'..'9', '*', '+']) do
        Inc(J);
      if (Copy(S, I, J - I) = '\v') or (Copy(S, I, J - I) = '\c') then
      begin
        while (J <= Length(S)) and (S[J] = ' ') do
          Inc(J);
        while (J <= Length(S)) and (S[J] in ['0'..'9', '-']) do
          Inc(J);
      end;
      I := J;
      Space := True;
      Continue;
    end;
    if S[I] in [#9, #10, #13, ' '] then
      Space := True
    else
    begin
      if Space and (Result <> '') then
        Result := Result + ' ';
      Space := False;
      Result := Result + S[I];
    end;
    Inc(I);
  end;
end;

function TChecker.Norm(D: Integer): string;
var
  I: Integer;
begin
  if Norms = nil then
  begin
    Norms := TStringList.Create;
    for I := 0 to High(Docs) do
      Norms.Add(NormalText(Docs[I].Text));
  end;
  Result := Norms[D];
end;

{ The letter (UTF-8) starting at P, if it is one. }
function LetterAt(const S: string; P: Integer): Boolean;
var
  N: Integer;
  U: UnicodeString;
begin
  if P > Length(S) then
    Exit(False);
  if Ord(S[P]) < $80 then
    Exit(S[P] in ['a'..'z', 'A'..'Z']);
  N := 1;
  while (P + N <= Length(S)) and (Ord(S[P + N]) and $C0 = $80) do
    Inc(N);
  U := UTF8Decode(Copy(S, P, N));
  Result := (U <> '') and TCharacter.IsLetter(U, 1);
end;

procedure TChecker.CheckGlued(D: Integer);
var
  T, Frag: string;
  P, J, Best, Own: Integer;
  OwnT: Int64;
  F: TCrossFinding;
  VS: TVerseList;
  Done: Boolean;
  X: TCrossFinding;
begin
  T := NormalText(Docs[D].Text);
  for P := 1 to Length(T) - 1 do
  begin
    if not ((T[P] in Glue) and LetterAt(T, P + 1)) then
      Continue;
    Frag := Copy(T, P + 1, MaxInt);
    if Length(Frag) < 12 then
      Continue;
    Own := -1;
    for J := 0 to High(Docs) do
      if (DocBook[J] = DocBook[D]) and ((Own < 0) or (Docs[J].Time < Docs[Own].Time)) and
         (Pos(Frag, Norm(J)) > 0) then
        Own := J;
    if Own < 0 then
      Continue;
    OwnT := Docs[Own].Time;
    Best := -1;
    for J := 0 to High(Docs) do
      if (DocBook[J] <> DocBook[D]) and (Docs[J].Time <= OwnT) and
         ((Best < 0) or (Docs[J].Time < Docs[Best].Time)) and (Pos(Frag, Norm(J)) > 0) then
        Best := J;
    if Best < 0 then
      Continue;
    { already reported as a block or tail from that book }
    Done := False;
    for X in Findings do
      if (X.Doc = D) and (DocBook[X.Origin] = DocBook[Best]) then
        Done := True;
    if Done then
      Exit;
    VS := nil;
    if Length(WordVerses[D]) > 0 then
      VS := [WordVerses[D][High(WordVerses[D])]];
    if Parallel(D, Best, VS) then
      Exit;
    F := Default(TCrossFinding);
    F.Doc := D;
    F.Kind := ckGlued;
    F.Verses := SpanText(VS);
    F.Origin := Best;
    F.OriginCurrent := False;
    for J := 0 to High(Docs) do
      if Docs[J].Current and (Docs[J].Project = Docs[Best].Project) and
         (Docs[J].Chapter = Docs[Best].Chapter) and (Docs[J].Chunk = Docs[Best].Chunk) then
        F.OriginCurrent := Pos(Frag, Norm(J)) > 0;
    F.Since := Own;
    F.Unordered := Docs[Best].Time = OwnT;
    F.Fragment := Frag;
    Findings := Concat(Findings, [F]);
    Exit;    // one per chunk: the first glue point covers what follows
  end;
end;

function HasCopiedText(const Doc: TCrossDoc; const F: TCrossFinding): Boolean;
var
  W: THashList;
  VS: TVerseList;
  H: QWord;
begin
  if F.Kind = ckGlued then
    Exit(Pos(F.Fragment, NormalText(Doc.Text)) > 0);
  TokenizeWords(Doc.Text, W, VS);
  for H in Shingles(W, ShingleWords) do
    if H = F.Hash then
      Exit(True);
  Result := False;
end;

function FindCopiedText(const Docs: TCrossDocs; const Report: array of Boolean;
  English: TSourceLibrary): TCrossFindings;
var
  C: TChecker;
  D: Integer;
begin
  C := TChecker.Create(Docs, English);
  try
    C.BuildIndex;
    for D := 0 to High(Docs) do
      if Docs[D].Current and ((D > High(Report)) or Report[D]) then
      begin
        C.CheckDoc(D);
        C.CheckGlued(D);
      end;
    Result := C.Findings;
  finally
    C.Free;
  end;
end;

end.
