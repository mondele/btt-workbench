unit WBCrossTitles;

{$mode objfpc}{$H+}

(* Titles that came from somewhere else, for cross-check and cross-repair.
   A title is a word or three, far below the word runs WBCrossCheck counts,
   so pasted titles need their own check:

   - a book title (front/title) that another book of the language has, or
     had before this book first did, is reported on the book that has it
     now. Titles belong to one book, so neither is assumed to be the
     original: in the Chimanika damage of October 2026, Luke and Mark both
     became "JudaBERU", a title no book had before. A title another book
     had only later, and has since lost, was that book's mistake (Bwile
     2 John once had 1 John's title).
   - a chapter title (01/title) whose number is not its chapter's. *)

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

{ Title findings for the current docs whose Report entry is set (missing
  entries count as set). }
function FindTitleProblems(const Docs: TCrossDocs;
  const Report: array of Boolean): TTitleFindings;
{ A title as compared: its words in lower case. }
function TitleKey(const Text: string): UnicodeString;
{ The committed versions of Doc's file, newest first. }
function VersionsOf(const Docs: TCrossDocs; Doc: Integer): TDocList;

implementation

function TitleKey(const Text: string): UnicodeString;
begin
  Result := WordText(NormalText(Text));
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
  Key := TitleKey(Docs[Doc].Text);
  if TitleKey(Docs[V[0]].Text) <> Key then
    Exit(Doc);
  Result := V[0];
  for I := 1 to High(V) do
    if TitleKey(Docs[V[I]].Text) = Key then
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

{ A chapter title's numbers (whole words) leave out its chapter. }
function WrongChapterNumber(const Title: UnicodeString; const Chapter: string): Boolean;
var
  W, T: string;
  N, Has: Integer;
begin
  N := StrToIntDef(Chapter, -1);
  if N < 0 then
    Exit(False);
  Has := 0;
  T := UTF8Encode(Title);
  for W in T.Split([' ']) do
    if IsDigits(UnicodeString(W)) then
    begin
      if StrToIntDef(W, -2) = N then
        Exit(False);
      Inc(Has);
    end;
  Result := Has > 0;
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
begin
  Result := nil;
  SetLength(Keys, Length(Docs));
  for D := 0 to High(Docs) do
    if Docs[D].Chunk = 'title' then
      Keys[D] := TitleKey(Docs[D].Text);
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
          if (Keys[X] = Keys[D]) and (Docs[X].Time < First) then
            First := Docs[X].Time;
        { per other book: its current title if it reads the same, else the
          first version that did (and came before this book had it) }
        Books.Clear;
        for X := 0 to High(Docs) do
          if (Docs[X].Book <> Docs[D].Book) and (Docs[X].Chapter = 'front') and
             (Docs[X].Chunk = 'title') and (Keys[X] = Keys[D]) and
             (Docs[X].Current or (Docs[X].Time < First)) then
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
      else if WrongChapterNumber(Keys[D], Docs[D].Chapter) then
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
