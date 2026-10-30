unit WBQuoteMarks;

{$mode objfpc}{$H+}

(* Quote-mark checks of BTT Workbench's own, beside the usfm-tools port in
   WBUsfmChecks. They are not in verifyUSFM, so its fixtures do not cover
   them, and they leave the ported checks as they are:
   - the quote style of a book: which marks open and close quotations
     (curly, low-9 as in „…“, guillemets, CJK corner brackets, straight,
     or two apostrophes), whether sentence-ending punctuation follows the
     closing quote or comes before it, and whether guillemets have spaces
     inside; each counted, so a book can be compared with its source and
     its consistency given as a share;
   - quote marks that do not pair up within a chapter;
   - quote marks verifyUSFM's patterns leave out (single guillemet ‹,
     low-9 „ and ‚, CJK corner brackets) standing free between spaces.
   Only the outer (double) level is profiled: ’ is also the apostrophe, so
   the single marks would mostly count apostrophes. Characters are written
   as code points so the unit needs no codepage. *)

interface

type
  TQuoteStyle = (qsCurly, qsLow, qsGuillemet, qsCorner, qsStraight, qsDoubledApostrophe);
  TQuoteCounts = array[TQuoteStyle] of Integer;

  TQuoteProfile = record
    Marks: TQuoteCounts;                { quote marks of each style }
    PunctAfter, PunctBefore: Integer;   { . ! ? after a closing quote / before it }
    Spaced, Tight: Integer;             { guillemets with / without a space inside }
  end;

{ Adds the quote marks of T to P. }
procedure AddQuoteProfile(var P: TQuoteProfile; const T: UnicodeString);
function QuoteMarkTotal(const P: TQuoteProfile): Integer;
{ The style with the most marks (the first on a tie). }
function MainQuoteStyle(const P: TQuoteProfile): TQuoteStyle;
{ Part of Whole in whole percent, rounded; 0 when Whole is 0. }
function Percent(Part, Whole: Integer): Integer;
{ The styles used, most first, at most three, as UTF-8: '“…” 61%, "…" 30%'. }
function DescribeQuoteStyles(const P: TQuoteProfile): string;
{ Quote marks of T that do not pair up, as UTF-8 ('“×5 ”×4', '"×3'), or ''.
  LowStyle: „ opens and “ or ” closes, as in German and Polish. }
function UnpairedQuotes(const T: UnicodeString; LowStyle: Boolean): string;
{ The first of ‹ „ ‚ 「 」 『 』 standing free (spaces on both sides, or
  a space after at the start of T, before at its end), with a little
  context around it. }
function FloatingQuote(const T: UnicodeString; out Context: UnicodeString): Boolean;
{ T without footnotes (\f ... \f*, \fe ... \fe*). }
function WithoutFootnotes(const T: UnicodeString): UnicodeString;

implementation

uses
  SysUtils;

const
  LeftDouble = WideChar($201C);    // “
  RightDouble = WideChar($201D);   // ”
  LowDouble = WideChar($201E);     // „
  LowSingle = WideChar($201A);     // ‚
  LeftGuillemet = WideChar($00AB);   // «
  RightGuillemet = WideChar($00BB);  // »
  LeftSingleGuillemet = WideChar($2039);  // ‹
  LeftCorner = WideChar($300C);    // 「
  RightCorner = WideChar($300D);   // 」
  LeftWhiteCorner = WideChar($300E);   // 『
  RightWhiteCorner = WideChar($300F);  // 』
  Times = WideChar($00D7);         // ×

function Samples(S: TQuoteStyle): UnicodeString;
begin
  case S of
    qsCurly: Result := UnicodeString(LeftDouble) + #$2026 + RightDouble;
    qsLow: Result := UnicodeString(LowDouble) + #$2026 + LeftDouble;
    qsGuillemet: Result := UnicodeString(LeftGuillemet) + #$2026 + RightGuillemet;
    qsCorner: Result := UnicodeString(LeftCorner) + #$2026 + RightCorner;
    qsStraight: Result := '"' + #$2026 + '"';
    qsDoubledApostrophe: Result := '''''' + #$2026 + '''''';
  end;
end;

function IsSpace(C: WideChar): Boolean;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13) or (C = #$00A0) or
    (C = #$2009) or (C = #$202F);
end;

function IsEndPunct(C: WideChar): Boolean;
begin
  Result := (C = '.') or (C = '!') or (C = '?');
end;

{ A closing quote mark at I: its length (two for ''), else 0. }
function ClosingAt(const T: UnicodeString; I: Integer): Integer;
begin
  Result := 0;
  if (I < 1) or (I > Length(T)) then
    Exit;
  case T[I] of
    RightDouble, RightGuillemet, RightCorner, RightWhiteCorner, '"': Result := 1;
    '''':
      if (I < Length(T)) and (T[I + 1] = '''') then
        Result := 2;
  end;
end;

procedure AddQuoteProfile(var P: TQuoteProfile; const T: UnicodeString);
var
  I, L, N, Curly, Low: Integer;
begin
  N := Length(T);
  Curly := 0;
  Low := 0;
  I := 1;
  while I <= N do
  begin
    case T[I] of
      LeftDouble, RightDouble: Inc(Curly);
      LowDouble: Inc(Low);
      LeftGuillemet:
        begin
          Inc(P.Marks[qsGuillemet]);
          if I < N then
            if IsSpace(T[I + 1]) then
              Inc(P.Spaced)
            else
              Inc(P.Tight);
        end;
      RightGuillemet:
        begin
          Inc(P.Marks[qsGuillemet]);
          if I > 1 then
            if IsSpace(T[I - 1]) then
              Inc(P.Spaced)
            else
              Inc(P.Tight);
        end;
      LeftCorner, RightCorner, LeftWhiteCorner, RightWhiteCorner: Inc(P.Marks[qsCorner]);
      '"': Inc(P.Marks[qsStraight]);
    end;
    L := ClosingAt(T, I);
    if (L > 0) and (I + L <= N) and IsEndPunct(T[I + L]) then
      Inc(P.PunctAfter);
    if IsEndPunct(T[I]) and (ClosingAt(T, I + 1) > 0) then
      Inc(P.PunctBefore);
    if (T[I] = '''') and (I < N) and (T[I + 1] = '''') then
    begin
      Inc(P.Marks[qsDoubledApostrophe]);
      Inc(I);
    end;
    Inc(I);
  end;
  { „ is closed by “ (German) or ” (Polish): those closers are not curly
    quotes. }
  if Low > 0 then
  begin
    Inc(P.Marks[qsLow], 2 * Low);
    Dec(Curly, Low);
    if Curly < 0 then
      Curly := 0;
  end;
  Inc(P.Marks[qsCurly], Curly);
end;

function QuoteMarkTotal(const P: TQuoteProfile): Integer;
var
  S: TQuoteStyle;
begin
  Result := 0;
  for S in TQuoteStyle do
    Inc(Result, P.Marks[S]);
end;

function MainQuoteStyle(const P: TQuoteProfile): TQuoteStyle;
var
  S: TQuoteStyle;
begin
  Result := Low(TQuoteStyle);
  for S in TQuoteStyle do
    if P.Marks[S] > P.Marks[Result] then
      Result := S;
end;

function Percent(Part, Whole: Integer): Integer;
begin
  if Whole <= 0 then
    Exit(0);
  Result := (200 * Part + Whole) div (2 * Whole);
end;

function DescribeQuoteStyles(const P: TQuoteProfile): string;
var
  Done: set of TQuoteStyle;
  S, Best: TQuoteStyle;
  Total, Shown: Integer;
  Found: Boolean;
begin
  Result := '';
  Total := QuoteMarkTotal(P);
  Done := [];
  for Shown := 1 to 3 do
  begin
    Found := False;
    Best := Low(TQuoteStyle);
    for S in TQuoteStyle do
      if not (S in Done) and (P.Marks[S] > 0) and (not Found or (P.Marks[S] > P.Marks[Best])) then
      begin
        Best := S;
        Found := True;
      end;
    if not Found then
      Break;
    Include(Done, Best);
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + UTF8Encode(Samples(Best)) + ' ' + IntToStr(Percent(P.Marks[Best], Total)) + '%';
  end;
end;

function CountOf(const T: UnicodeString; C: WideChar): Integer;
var
  X: WideChar;
begin
  Result := 0;
  for X in T do
    if X = C then
      Inc(Result);
end;

function DoubledApostrophes(const T: UnicodeString): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := 1;
  while I < Length(T) do
    if (T[I] = '''') and (T[I + 1] = '''') then
    begin
      Inc(Result);
      Inc(I, 2);
    end
    else
      Inc(I);
end;

function UnpairedQuotes(const T: UnicodeString; LowStyle: Boolean): string;
var
  Parts: UnicodeString;

  procedure Pair(Opening, Closing: UnicodeString; NOpen, NClose: Integer);
  begin
    if NOpen <> NClose then
      Parts := Parts + ' ' + Opening + Times + UnicodeString(IntToStr(NOpen)) + ' ' +
        Closing + Times + UnicodeString(IntToStr(NClose));
  end;

  procedure OddCount(Mark: UnicodeString; N: Integer);
  begin
    if N mod 2 = 1 then
      Parts := Parts + ' ' + Mark + Times + UnicodeString(IntToStr(N));
  end;

begin
  Parts := '';
  if LowStyle then
    Pair(LowDouble, UnicodeString(LeftDouble) + RightDouble, CountOf(T, LowDouble),
      CountOf(T, LeftDouble) + CountOf(T, RightDouble))
  else
    Pair(LeftDouble, RightDouble, CountOf(T, LeftDouble), CountOf(T, RightDouble));
  Pair(LeftGuillemet, RightGuillemet, CountOf(T, LeftGuillemet), CountOf(T, RightGuillemet));
  Pair(LeftCorner, RightCorner, CountOf(T, LeftCorner), CountOf(T, RightCorner));
  Pair(LeftWhiteCorner, RightWhiteCorner, CountOf(T, LeftWhiteCorner), CountOf(T, RightWhiteCorner));
  OddCount('"', CountOf(T, '"'));
  OddCount('''''', DoubledApostrophes(T));
  Result := UTF8Encode(Trim(Parts));
end;

function FloatingQuote(const T: UnicodeString; out Context: UnicodeString): Boolean;
var
  I, N, Start: Integer;
begin
  Context := '';
  N := Length(T);
  for I := 1 to N do
    case T[I] of
      LeftSingleGuillemet, LowDouble, LowSingle, LeftCorner, RightCorner,
      LeftWhiteCorner, RightWhiteCorner:
        if (N > 1) and ((I = 1) or IsSpace(T[I - 1])) and ((I = N) or IsSpace(T[I + 1])) then
        begin
          Start := I - 3;
          if Start < 1 then
            Start := 1;
          Context := Trim(Copy(T, Start, I + 4 - Start));
          Exit(True);
        end;
    end;
  Result := False;
end;

function WithoutFootnotes(const T: UnicodeString): UnicodeString;
var
  I, J: Integer;
  Closing: UnicodeString;
begin
  Result := T;
  I := 1;
  while I < Length(Result) do
  begin
    Closing := '';
    if Copy(Result, I, 3) = '\f ' then
      Closing := '\f*'
    else if Copy(Result, I, 4) = '\fe ' then
      Closing := '\fe*';
    if Closing = '' then
    begin
      Inc(I);
      Continue;
    end;
    J := Pos(Closing, Copy(Result, I, MaxInt));
    if J = 0 then
      Delete(Result, I, MaxInt)
    else
      Delete(Result, I, J - 1 + Length(Closing));
  end;
end;

end.
