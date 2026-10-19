unit WBCrossTitles;

{$mode objfpc}{$H+}

(* Titles that came from somewhere else, for cross-check and cross-repair.
   A title is a word or three, far below the word runs WBCrossCheck counts,
   so pasted titles need their own check:

   - a book title (front/title) that another book of the language has, or
     had before this book first did (or within a day after: one editing
     session), is reported on the book that has it now. Spaces are ignored
     ("yaJohani" = "ya Johani"). Titles belong to one book, so neither is assumed to be the
     original: in the Chimanika damage of October 2026, Luke and Mark both
     became "JudaBERU", a title no book had before. A title another book
     had only later, and has since lost, was that book's mistake (Bwile
     2 John once had 1 John's title).
   - a chapter title (01/title) whose number is not its chapter's.

   TitleRepair picks what a title should go back to: for a book title, the
   last earlier title that is not, and never was, another book's title and
   was not set in the same session (Chimanika John went "Evangeri ya
   Johani" -> "Marakori ya Johani" -> "Marako" in one night); for a chapter
   title, the last earlier version with the right number, else the title
   with its number corrected. *)

interface

uses
  Classes, SysUtils, WBCrossCheck;

type
  TDocList = array of Integer;   // positions in TCrossDocs
  TTitleKind = (tkShared, tkChapterNumber);

  TTitleFinding = record
    Doc: Integer;             // the current title file
    Kind: TTitleKind;
    { tkShared: per other book, a version of its book title that reads the
      same (its current file when it still does, else the first) }
    Others: TDocList;
    { the version of this file that brought the title in: Doc itself when
      not yet committed, -1 when there is no history }
    Since: Integer;
  end;
  TTitleFindings = array of TTitleFinding;

const
  { versions this close together are one editing session (seconds) }
  SessionGap = 24 * 60 * 60;

{ Title findings for the current docs whose Report entry is set (missing
  entries count as set). }
function FindTitleProblems(const Docs: TCrossDocs;
  const Report: array of Boolean): TTitleFindings;
{ A title's words in lower case, single spaces. }
function TitleKey(const Text: string): UnicodeString;
{ A book title as compared: TitleKey without the spaces. }
function CompactKey(const Text: string): UnicodeString;
{ Whether a chapter title has numbers and none is its chapter's. }
function WrongChapterTitle(const Text, Chapter: string): Boolean;
{ Text with its only number set to Chapter's; '' if it has no number or
  several. }
function RenumberedTitle(const Text, Chapter: string): string;
{ What the title of finding T should become (False: nothing found, to be
  fixed by hand). }
function TitleRepair(const Docs: TCrossDocs; const T: TTitleFinding;
  out NewText: string): Boolean;
{ The committed versions of Doc's file, newest first. }
function VersionsOf(const Docs: TCrossDocs; Doc: Integer): TDocList;

implementation

function TitleKey(const Text: string): UnicodeString;
begin
  Result := WordText(NormalText(Text));
end;

function CompactKey(const Text: string): UnicodeString;
begin
  Result := UnicodeString(StringReplace(UTF8Encode(TitleKey(Text)), ' ', '', [rfReplaceAll]));
end;

function SameFile(const A, B: TCrossDoc): Boolean;
begin
  Result := (A.Project = B.Project) and (A.Chapter = B.Chapter) and (A.Chunk = B.Chunk);
end;

function VersionsOf(const Docs: TCrossDocs; Doc: Integer): TDocList;
var
  I, J, T: Integer;
begin
  Result := nil;
  for I := 0 to High(Docs) do
    if not Docs[I].Current and SameFile(Docs[I], Docs[Doc]) then
      Result := Concat(Result, [I]);
  { newest first; few versions, so an insertion sort }
  for I := 1 to High(Result) do
  begin
    T := Result[I];
    J := I - 1;
    while (J >= 0) and (Docs[Result[J]].Time < Docs[T].Time) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := T;
  end;
end;

function SinceOf(const Docs: TCrossDocs; Doc: Integer): Integer;
var
  V: TDocList;
  Key: UnicodeString;
  I: Integer;
begin
  V := VersionsOf(Docs, Doc);
  if Length(V) = 0 then
    Exit(-1);
  Key := CompactKey(Docs[Doc].Text);
  if CompactKey(Docs[V[0]].Text) <> Key then
    Exit(Doc);
  Result := V[0];
  for I := 1 to High(V) do
    if CompactKey(Docs[V[I]].Text) = Key then
      Result := V[I]
    else
      Break;
end;

function IsDigits(const S: UnicodeString): Boolean;
var
  C: WideChar;
begin
  Result := S <> '';
  for C in S do
    if not (C in ['0'..'9']) then
      Exit(False);
end;

{ How many numbers (whole words) a chapter title has, and whether one is
  its chapter's. }
procedure ChapterNumbers(const Text, Chapter: string; out Count: Integer;
  out Right: Boolean);
var
  W, T: string;
  N: Integer;
begin
  Count := 0;
  Right := False;
  N := StrToIntDef(Chapter, -1);
  T := UTF8Encode(TitleKey(Text));
  for W in T.Split([' ']) do
    if IsDigits(UnicodeString(W)) then
    begin
      Inc(Count);
      if StrToIntDef(W, -2) = N then
        Right := True;
    end;
end;

function WrongChapterTitle(const Text, Chapter: string): Boolean;
var
  Count: Integer;
  Right: Boolean;
begin
  if StrToIntDef(Chapter, -1) < 0 then
    Exit(False);
  ChapterNumbers(Text, Chapter, Count, Right);
  Result := (Count > 0) and not Right;
end;

function RenumberedTitle(const Text, Chapter: string): string;
var
  I, J, Start, Stop, Found: Integer;
begin
  Result := '';
  Found := 0;
  Start := 0;
  Stop := 0;
  I := 1;
  while I <= Length(Text) do
    if Text[I] in ['0'..'9'] then
    begin
      J := I;
      while (J <= Length(Text)) and (Text[J] in ['0'..'9']) do
        Inc(J);
      { a whole word: no letter (or any non-ASCII byte) on either side }
      if ((I = 1) or not (Text[I - 1] in ['a'..'z', 'A'..'Z', #128..#255])) and
         ((J > Length(Text)) or not (Text[J] in ['a'..'z', 'A'..'Z', #128..#255])) then
      begin
        Inc(Found);
        Start := I;
        Stop := J;
      end;
      I := J;
    end
    else
      Inc(I);
  if (Found <> 1) or (StrToIntDef(Chapter, -1) < 0) then
    Exit;
  Result := Copy(Text, 1, Start - 1) + IntToStr(StrToInt(Chapter)) +
    Copy(Text, Stop, MaxInt);
end;

function TitleRepair(const Docs: TCrossDocs; const T: TTitleFinding;
  out NewText: string): Boolean;
var
  V: TDocList;
  Q, X, Count: Integer;
  Right: Boolean;
  Key: UnicodeString;
  Others: TStringList;
begin
  NewText := '';
  Result := False;
  V := VersionsOf(Docs, T.Doc);
  Q := 0;
  if T.Since >= 0 then
    while (Q <= High(V)) and (V[Q] <> T.Since) do
      Inc(Q);
  Inc(Q);   // the versions before the one that brought the title in
  if T.Kind = tkChapterNumber then
  begin
    for Q := Q to High(V) do
    begin
      ChapterNumbers(Docs[V[Q]].Text, Docs[T.Doc].Chapter, Count, Right);
      if Right then
      begin
        NewText := Docs[V[Q]].Text;
        Exit(True);
      end;
    end;
    NewText := RenumberedTitle(Docs[T.Doc].Text, Docs[T.Doc].Chapter);
    Exit(NewText <> '');
  end;
  if T.Since < 0 then
    Exit;
  Key := CompactKey(Docs[T.Doc].Text);
  Others := TStringList.Create;
  try
    Others.Sorted := True;
    Others.Duplicates := dupIgnore;
    for X := 0 to High(Docs) do
      if (Docs[X].Book <> Docs[T.Doc].Book) and (Docs[X].Chapter = 'front') and
         (Docs[X].Chunk = 'title') then
        Others.Add(UTF8Encode(CompactKey(Docs[X].Text)));
    for Q := Q to High(V) do
    begin
      X := V[Q];
      if (Docs[X].Time > Docs[T.Since].Time - SessionGap) or
         (CompactKey(Docs[X].Text) = '') or (CompactKey(Docs[X].Text) = Key) or
         (Others.IndexOf(UTF8Encode(CompactKey(Docs[X].Text))) >= 0) then
        Continue;
      NewText := Docs[X].Text;
      Exit(True);
    end;
  finally
    Others.Free;
  end;
end;

function FindTitleProblems(const Docs: TCrossDocs;
  const Report: array of Boolean): TTitleFindings;
var
  F: TTitleFinding;
  Keys: array of UnicodeString;
  Books: TStringList;
  D, X, K: Integer;
  First: Int64;
  V: TDocList;
  Compact: array of UnicodeString;
begin
  Result := nil;
  SetLength(Keys, Length(Docs));
  SetLength(Compact, Length(Docs));
  for D := 0 to High(Docs) do
    if Docs[D].Chunk = 'title' then
    begin
      Keys[D] := TitleKey(Docs[D].Text);
      Compact[D] := CompactKey(Docs[D].Text);
    end;
  Books := TStringList.Create;
  try
    for D := 0 to High(Docs) do
    begin
      if not Docs[D].Current or (Docs[D].Chunk <> 'title') or (Keys[D] = '') or
         ((D <= High(Report)) and not Report[D]) then
        Continue;
      F := Default(TTitleFinding);
      F.Doc := D;
      if Docs[D].Chapter = 'front' then
      begin
        F.Kind := tkShared;
        { when this book first had the title }
        First := Docs[D].Time;
        V := VersionsOf(Docs, D);
        for X in V do
          if (Compact[X] = Compact[D]) and (Docs[X].Time < First) then
            First := Docs[X].Time;
        { per other book: its current title if it reads the same, else the
          first version that did (before this book had it, or in the same
          session) }
        Books.Clear;
        for X := 0 to High(Docs) do
          if (Docs[X].Book <> Docs[D].Book) and (Docs[X].Chapter = 'front') and
             (Docs[X].Chunk = 'title') and (Compact[X] = Compact[D]) and
             (Docs[X].Current or (Docs[X].Time < First + SessionGap)) then
          begin
            K := Books.IndexOf(Docs[X].Book);
            if K < 0 then
              Books.AddObject(Docs[X].Book, TObject(PtrInt(X)))
            else if Docs[X].Current or
              (not Docs[PtrInt(Books.Objects[K])].Current and
               (Docs[X].Time < Docs[PtrInt(Books.Objects[K])].Time)) then
              Books.Objects[K] := TObject(PtrInt(X));
          end;
        if Books.Count = 0 then
          Continue;
        for K := 0 to Books.Count - 1 do
          F.Others := Concat(F.Others, [Integer(PtrInt(Books.Objects[K]))]);
      end
      else if WrongChapterTitle(Docs[D].Text, Docs[D].Chapter) then
        F.Kind := tkChapterNumber
      else
        Continue;
      F.Since := SinceOf(Docs, D);
      Result := Concat(Result, [F]);
    end;
  finally
    Books.Free;
  end;
end;

end.
