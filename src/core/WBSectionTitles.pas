unit WBSectionTitles;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Possible untagged section titles in translation text, ported from
   usfm-tools' section_titles.py (Larry Versaw, Wycliffe Associates), which
   verifyUSFM.py uses for its check 76. A short phrase in Title Case or
   ALL CAPS, alone on a line or ending one, without quotes, markers or a
   second sentence, is probably a heading the translator typed into the
   text. The thresholds are section_titles.py's; the sentence helpers are
   sentences.py's (firstword, nextstartpos). Strings are UnicodeString;
   positions are 1-based. *)

interface

{ isCapitalized: Title case word, apostrophes and hyphens allowed. }
function IsCapitalized(const Word: UnicodeString): Boolean;
{ percentTitlecase: share of the words that are capitalised. }
function PercentTitlecase(const S: UnicodeString): Double;
function IsHeading(const S: UnicodeString): Boolean;
function IsPossibleHeading(const S: UnicodeString): Boolean;
{ find_eol_heading: the heading ending Line, or '' (Found False). }
function FindEolHeading(const Line: UnicodeString; out Heading: UnicodeString): Boolean;
{ verifyUSFM's reportSectionHeadings for one line: True if the line holds
  a possible section title; Title is it (or the line). }
function LineHasHeading(const Line: UnicodeString; out Title: UnicodeString): Boolean;

implementation

uses
  SysUtils, uregexpr, WBPyText;

type
  TPositions = array of Integer;
  TRe = (reStartWord, reAnyMarker, reAmen, reForbidden, reSingleWordInParens,
    reGoodStart, reFirstWord, reEndSent, reBadQuoted, reConflict);

const
  Patterns: array[TRe] of UnicodeString = (
    '^[\w "‘“''\(\)]',
    '\\[a-z]+[a-z1-5]* ?[0-9]*',
    'Am[ei]+n',
    '["“‘‹«”›»]',
    '^\(\s*\w+\s*\)',
    '^[\w\(]',
    '(\w+-\w+|\w+)',
    '[.?!\x{0964}\x{0965}\x{1361}\x{1362}].*?(\w+-\w+|\w+)',
    '^[?!\x{1361}\x{1362}]+[«“‘\-\x{2014}\x{2013}]',
    '^<+ HEAD');

var
  Res: array[TRe] of TRegExpr;

function Re(R: TRe): TRegExpr;
begin
  if Res[R] = nil then
  begin
    Res[R] := TRegExpr.Create(Patterns[R]);
    Res[R].UseUnicodeWordDetection := True;
    Res[R].ModifierS := R = reEndSent;    // re.DOTALL
  end;
  Result := Res[R];
end;

{ str.strip(' \n') }
function StripSpaceNewline(const S: UnicodeString): UnicodeString;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and ((S[A] = ' ') or (S[A] = #10)) do
    Inc(A);
  while (B >= A) and ((S[B] = ' ') or (S[B] = #10)) do
    Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

{ sentences.firstword }
function FirstWord(const S: UnicodeString): UnicodeString;
begin
  if Re(reFirstWord).Exec(S) then
    Result := Re(reFirstWord).Match[1]
  else
    Result := '';
end;

{ sentences.nextstartpos: where each sentence (or part) starts. }
function StartPositions(const S: UnicodeString): TPositions;
var
  W, E: TRegExpr;
  NextWordEnd, SearchFrom: Integer;
  Found: Boolean;
begin
  Result := nil;
  if S = '' then
    Exit;
  W := Re(reFirstWord);
  E := Re(reEndSent);
  if not W.Exec(S) then
    Exit;
  E.InputString := S;     // ExecPos searches the last InputString
  repeat
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := W.MatchPos[0];
    NextWordEnd := W.MatchPos[0] + W.MatchLen[0];
    { endsent = endsent_re.search(str, nextword.end()), skipping matches
      that badquoted_re matches }
    Found := (NextWordEnd <= Length(S)) and E.ExecPos(NextWordEnd);
    while Found and Re(reBadQuoted).Exec(E.Match[0]) do
    begin
      SearchFrom := E.MatchPos[0] + E.MatchLen[0];
      Found := (SearchFrom <= Length(S)) and E.ExecPos(SearchFrom);
    end;
    if not Found then
      Break;
    { nextword = firstword_re.search(str, endsent.start() + 1) }
    SearchFrom := E.MatchPos[0] + 1;
    if (SearchFrom > Length(S)) or not W.ExecPos(SearchFrom) then
      Break;
  until False;
end;

function SentenceCount(const S: UnicodeString): Integer;
begin
  Result := Length(StartPositions(S));
end;

function IsCapitalized(const Word: UnicodeString): Boolean;
var
  Parts: array of UnicodeString;
  Part: UnicodeString;
  C: WideChar;
  I: Integer;
begin
  if (Word = '') or not Re(reStartWord).Exec(Word) then
    Exit(False);
  { re.split("['’-]", word) }
  Parts := nil;
  Part := '';
  for C in Word do
    if (C = '''') or (C = '’') or (C = '-') then
    begin
      SetLength(Parts, Length(Parts) + 1);
      Parts[High(Parts)] := Part;
      Part := '';
    end
    else
      Part := Part + C;
  SetLength(Parts, Length(Parts) + 1);
  Parts[High(Parts)] := Part;
  Result := IsTitle(Parts[0]);
  if Result then
    for I := 1 to High(Parts) do
      if not (AllLower(Parts[I]) or IsTitle(Parts[I])) then
        Result := False;
end;

function PercentTitlecase(const S: UnicodeString): Double;
var
  Words: TUnicodeWords;
  W: UnicodeString;
  N, Total: Integer;
begin
  Words := SplitWords(S);
  N := 0;
  for W in Words do
    if IsCapitalized(W) then
      Inc(N);
  Total := Length(Words);
  if Total = 0 then
    Total := 1;
  Result := N / Total;
end;

function LastWord(const S: UnicodeString): UnicodeString;
var
  Words: TUnicodeWords;
begin
  Words := SplitWords(S);
  if Length(Words) > 0 then
    Result := Words[High(Words)]
  else
    Result := '';
end;

{ _titlecase_threshold; S already stripped. }
function TitlecaseThreshold(const S: UnicodeString): Double;
var
  I: Integer;
  L: UnicodeString;
begin
  if Length(S) < 5 then
    Exit(2);
  Result := 0.51;
  if (S[Length(S)] = '''') or (S[Length(S)] = '’') then
    Result := 1.2;
  if Pos(',', S) > 0 then
    Result := Result + 0.16;
  if Length(S) > 40 then
    Result := Result + 0.01 * (Length(S) - 40);
  if (S[1] = '(') and (S[Length(S)] = ')') then
    Result := Result - 0.03;
  if not Re(reGoodStart).Exec(S) then
    Result := Result + 0.18;
  for I := Length(S) - 2 to Length(S) do
    if Pos(S[I], UnicodeString('.'#$0964#$0965#$1361#$1362)) > 0 then
    begin
      Result := Result + 0.16;
      if Length(SplitWords(S)) = 1 then
        Result := 1.01;
    end
    else if Pos(S[I], UnicodeString('!?,;')) > 0 then
      Result := 0.99;
  L := LastWord(S);
  if not IsCapitalized(L) and not AllUpper(L) then
    Result := Result + 0.24;
end;

function Qualifies(const S: UnicodeString; Threshold: Double): Boolean;
var
  First: UnicodeString;
  Possible: Boolean;
begin
  First := FirstWord(S);
  Possible := (Threshold <= 1) and (Pos(#10, S) = 0) and
    not Re(reAnyMarker).Exec(S) and not Re(reAmen).Exec(S) and
    (AllUpper(First) or IsCapitalized(First)) and
    not Re(reForbidden).Exec(S) and not Re(reSingleWordInParens).Exec(S) and
    (SentenceCount(S) = 1);
  if not Possible then
    Exit(False);
  Result := AllUpper(S) or (PercentTitlecase(S) >= Threshold);
  if not Result then
    Result := (S[1] = '(') and (S[Length(S)] = ')') and
      (AllUpper(S) or (PercentTitlecase(Copy(S, 2, Length(S) - 2)) >= Threshold));
end;

function IsHeading(const S: UnicodeString): Boolean;
var
  T: UnicodeString;
begin
  T := StripSpaceNewline(S);
  if T = '' then
    Exit(False);
  Result := Qualifies(T, TitlecaseThreshold(T));
end;

function IsPossibleHeading(const S: UnicodeString): Boolean;
var
  T: UnicodeString;
  Threshold: Double;
begin
  T := StripSpaceNewline(S);
  if T = '' then
    Exit(False);
  Threshold := TitlecaseThreshold(T) - 0.21;
  if Threshold < 0.45 then
    Threshold := 0.45;
  Result := Qualifies(T, Threshold);
end;

function FindEolHeading(const Line: UnicodeString; out Heading: UnicodeString): Boolean;
var
  Starts: TPositions;
  P: Integer;
begin
  Heading := '';
  Result := False;
  Starts := StartPositions(Line);
  if Length(Starts) = 0 then
    Exit;
  P := Starts[High(Starts)];
  if (P > 1) and (Line[P - 1] = '(') then
    Dec(P);
  if IsHeading(Copy(Line, P, MaxInt)) then
  begin
    Heading := Copy(Line, P, MaxInt);
    Result := Heading <> '';
  end;
end;

function LineHasHeading(const Line: UnicodeString; out Title: UnicodeString): Boolean;
begin
  Title := '';
  Result := False;
  if (Line = '') or Re(reConflict).Exec(Line) then
    Exit;
  if (Line[1] <> '\') and IsPossibleHeading(Line) then
  begin
    Title := StripSpaceNewline(Line);
    Exit(True);
  end;
  Result := FindEolHeading(Line, Title);
  Title := StripSpaceNewline(Title);
end;

procedure FreeRes;
var
  R: TRe;
begin
  for R in TRe do
    FreeAndNil(Res[R]);
end;

finalization
  FreeRes;

end.
