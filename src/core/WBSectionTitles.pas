unit WBSectionTitles;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Possible untagged section titles, ported from usfm-tools'
   section_titles.py (Larry Versaw, Wycliffe Associates; version of
   2026-10). prob_heading gives a string a probability of being a heading
   from its content only: Title Case or ALL CAPS, length, punctuation,
   parentheses, one sentence, no quotes or markers; caseless scripts get a
   low fixed value. verifyUSFM combines it with where the text is
   (WBUsfmChecks). UnicodeString in, positions 1-based. *)

interface

{ percentTitleOrCaps }
function PercentTitleOrCaps(const S: UnicodeString): Double;
{ prob_heading: 0.0 .. 1.0 }
function ProbHeading(const S: UnicodeString): Double;
{ find_parenthesized_heading: '' if none reaches RequiredProb. }
function FindParenthesizedHeading(const Line: UnicodeString; RequiredProb: Double): UnicodeString;
{ find_eol_heading: the line's last sentence if it reaches RequiredProb. }
function FindEolHeading(const Line: UnicodeString; RequiredProb: Double): UnicodeString;
{ References whose verse-ending phrases are not checked (exclude_eol_checks). }
function EolCheckExcluded(const Reference: string): Boolean;

implementation

uses
  SysUtils, WBRegExpr, WBPyText, WBSentences;

const
  ExcludeEol = '|LEV 18:5|LEV 19:4|MAT 15:31|LUK 2:11|LUK 17:32|JHN 19:19|' +
    'ACT 16:20|COL 3:22|2TI 4:18|REV 22:9|REV 22:20|';

type
  TRe = (rePunct, rePPhrase, reDigit, reAnyMarker, reAmen, reSelah, reQuotes,
    reGoodStart);

const
  Patterns: array[TRe] of UnicodeString = (
    '[()*+,./:;<=>!?@[\]^{|}~\x{0964}\x{0965}\x{1361}\x{1362}\x{061F}\x{06D4}]',
    '\([^()\n\t]+\)\s*$',
    '\d',
    '\\[a-z]+[a-z1-5]* ?[0-9]*',
    '[AE]m[ei]+n',
    'Sela',
    '["“‘‹«”›»]',
    '^[\w\(]');

var
  Res: array[TRe] of TRegExpr;

function Re(R: TRe): TRegExpr;
begin
  if Res[R] = nil then
  begin
    Res[R] := TRegExpr.Create(Patterns[R]);
    Res[R].UseUnicodeWordDetection := True;
    Res[R].ModifierI := R in [reAmen, reSelah];   // re.IGNORECASE
    Res[R].ModifierM := R = rePPhrase;           // re.MULTILINE
  end;
  Result := Res[R];
end;

function Found(R: TRe; const S: UnicodeString): Boolean;
begin
  Result := (S <> '') and Re(R).Exec(S);
end;

function CountOf(R: TRe; const S: UnicodeString): Integer;
begin
  Result := 0;
  if (S <> '') and Re(R).Exec(S) then
    repeat
      Inc(Result);
    until not Re(R).ExecNext;
end;

function CountChar(const S: UnicodeString; C: WideChar): Integer;
var
  X: WideChar;
begin
  Result := 0;
  for X in S do
    if X = C then
      Inc(Result);
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

function WordCount(const S: UnicodeString): Integer;
begin
  Result := Length(SplitWords(S));
end;

function PercentTitleOrCaps(const S: UnicodeString): Double;
var
  Words: TUnicodeWords;
  W: UnicodeString;
  N, Total: Integer;
begin
  if IsTitle(S) or AllUpper(S) then
    Exit(1.0);
  Words := SplitWords(S);
  N := 0;
  for W in Words do
    if IsCapitalized(W) or AllUpper(W) then
      Inc(N);
  Total := Length(Words);
  if Total = 0 then
    Total := 1;
  Result := N / Total;
end;

{ A real constant as a Double. FPC evaluates untyped real constants in
  extended precision on x86-64; Python adds doubles, and
  _titlecase_threshold compares a sum with 0.67 for equality. }
function D(X: Double): Double; inline;
begin
  Result := X;
end;

{ disqualified }
function Disqualified(const S: UnicodeString): Boolean;
begin
  Result := (S = '') or Found(reAnyMarker, S) or (S[1] = '\') or
    ((Found(reAmen, S) or Found(reSelah, S)) and (WordCount(S) = 1));
end;

{ _titlecase_threshold }
function TitlecaseThreshold(const S: UnicodeString): Double;
var
  Ends, First, Last: UnicodeString;
begin
  if Length(S) < 2 then
    Exit(D(0.99));
  Result := D(0.51);
  if Pos(S[Length(S)], UnicodeString('''’,')) > 0 then
    Result := D(0.99);
  if Pos(',', S) > 0 then
    Result := Result + D(0.16);
  if Length(S) > 80 then
    Result := Result + D(0.01) * (Length(S) - 80);
  if WordCount(S) > 10 then
    Result := Result + D(0.03) * (WordCount(S) - 10);
  if (S[1] = '(') and (S[Length(S)] = ')') and (CountChar(S, '(') = 1) and
     (CountChar(S, ')') = 1) then
    Result := Result - D(0.03);
  if not Found(reGoodStart, S) then
    Result := Result + D(0.18);
  Ends := EndsSentence(S);
  if Ends <> '' then
  begin
    Result := Result + D(0.16);
    if Pos(Ends, UnicodeString('!?;')) > 0 then
      Result := D(0.99);
  end
  else
  begin
    First := FirstWord(S);
    if IsCapitalized(First) or AllUpper(First) then
      Result := Result - D(0.24);
  end;
  Last := LastWord(S);
  if IsCapitalized(Last) or AllUpper(Last) then
    Result := Result - D(0.08);
  { Python compares the float with == D(0.67) }
  if Result = D(0.67) then
    Result := D(0.66);
end;

function ProbHeading(const S: UnicodeString): Double;
var
  T: UnicodeString;
  Percent, Diff: Double;
  NPunct: Integer;
begin
  T := StripSpaceNewline(S);
  if Disqualified(T) then
    Exit(0);
  if (Length(T) < 2) or Found(reQuotes, T) or
     ((SentenceCount(T) > 1) and not Found(reDigit, T)) then
    Exit(D(0.01));
  if IsCaseless(FirstWord(T)) then
    Result := D(0.1)
  else if AllUpper(T) then
    Result := D(0.8)
  else
  begin
    Percent := PercentTitleOrCaps(T);
    Diff := Percent - TitlecaseThreshold(T);
    if Diff >= D(0.0) then
    begin
      Result := D(0.5);
      if Percent >= D(0.8) then
        Result := D(0.75);
    end
    else
      Result := D(0.04);
  end;
  if (T[1] = '(') and (T[Length(T)] = ')') then
    Result := Result + D(0.15);
  if Found(reDigit, T) and (Pos(':', T) > 0) then
    Result := Result - D(0.1);
  if Length(T) > 80 then
    Result := Result - D(0.002) * (Length(T) - 80);
  if WordCount(T) > 10 then
    Result := Result - D(0.005) * (WordCount(T) - 10);
  Result := Result - D(0.15) * CountChar(T, #10);
  NPunct := CountOf(rePunct, T);
  Result := Result - D(0.03) * NPunct;
  if (Result > D(0.05)) and (T[Length(T)] = ',') then
    Result := D(0.05);
  if (Result > D(0.1)) and (T[Length(T)] = ':') then
    Result := D(0.1);
  if EndsSentence(T) <> '' then
  begin
    Result := Result - D(0.1);
    Result := Result - D(0.3) * (NPunct - 1);
  end;
  if Result <= D(0.01) then
    Result := D(0.01);
end;

function FindParenthesizedHeading(const Line: UnicodeString; RequiredProb: Double): UnicodeString;
var
  M: TRegExpr;
  Possible, Next: UnicodeString;
begin
  Result := '';
  M := Re(rePPhrase);
  if (Line = '') or not M.Exec(Line) then
    Exit;
  repeat
    Possible := Trim(M.Match[0]);
    if ProbHeading(Possible) >= RequiredProb then
    begin
      Next := FirstWord(Copy(Line, M.MatchPos[0] + M.MatchLen[0], MaxInt));
      if (Next = '') or not AllLower(Next) then
        Exit(Possible);
    end;
  until not M.ExecNext;
end;

function FindEolHeading(const Line: UnicodeString; RequiredProb: Double): UnicodeString;
var
  Starts: TPositions;
  P: Integer;
begin
  Result := '';
  Starts := StartPositions(Line);
  if Length(Starts) = 0 then
    Exit;
  P := Starts[High(Starts)];
  if (P > 1) and (Line[P - 1] = '(') then
    Dec(P);
  Result := Copy(Line, P, MaxInt);
  if ProbHeading(Result) < RequiredProb then
    Result := '';
end;

function EolCheckExcluded(const Reference: string): Boolean;
begin
  Result := Pos('|' + Reference + '|', ExcludeEol) > 0;
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
