unit WBSentences;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Sentences and capitalised words, ported from usfm-tools' sentences.py
   (Larry Versaw, Wycliffe Associates; version of 2026-10). Sentences end
   with . ? ! the Devanagari danda and double danda, the Ethiopic wordspace
   and full stop, and the Arabic question mark and full stop. An opening
   quote or dash after ? ! leaves the end uncertain (badquoted_re).
   UnicodeString in, positions 1-based. *)

interface

type
  TPositions = array of Integer;
  TUnicodeWordList = array of UnicodeString;

{ endsSentence: the mark that ends the text's last sentence, or ''. With
  CheckQuotes, '' when an opening quote or dash follows it. }
function EndsSentence(const S: UnicodeString; CheckQuotes: Boolean = False): UnicodeString;
function FirstWord(const S: UnicodeString): UnicodeString;
function LastWord(const S: UnicodeString): UnicodeString;
{ nextfirstwords: the first word of each sentence after the first. }
function NextFirstWords(const S: UnicodeString): TUnicodeWordList;
{ nextstartpos: where each sentence (or part of one) starts. }
function StartPositions(const S: UnicodeString): TPositions;
function SentenceCount(const S: UnicodeString): Integer;
{ isCapitalized: a Title case word, apostrophes and hyphens allowed. }
function IsCapitalized(const Word: UnicodeString): Boolean;

implementation

uses
  SysUtils, Character, WBRegExpr, WBPyText;

const
  Enders = '.?!\x{0964}\x{0965}\x{1361}\x{1362}\x{061F}\x{06D4}';

type
  TRe = (reEndSentence, reBadQuoted, reWordFirst, reWordLast, reWordStart,
    reEndSentNext, reEndSentStart, reStartWord);

const
  Patterns: array[TRe] of UnicodeString = (
    '([' + Enders + '])[^\w]*$',
    '^[?!\x{1361}\x{1362}\x{061F}\x{06D4}]+[«“‘\-\x{2014}\x{2013}]',
    '(\w+-\w+|\w+)',
    '(\w+-\w+|\w+)',
    '(\w+-\w+|\w+)',
    '[' + Enders + '].*?(\w+-\w+|\w+)',
    '[' + Enders + '].*?(\w+-\w+|\w+)',
    '^[\w "‘“''\(\)]');

var
  Res: array[TRe] of TRegExpr;

function Re(R: TRe): TRegExpr;
begin
  if Res[R] = nil then
  begin
    Res[R] := TRegExpr.Create(Patterns[R]);
    Res[R].UseUnicodeWordDetection := True;
    Res[R].ModifierS := R in [reEndSentNext, reEndSentStart];   // re.DOTALL
  end;
  Result := Res[R];
end;

function BadQuoted(const S: UnicodeString): Boolean;
begin
  Result := (S <> '') and Re(reBadQuoted).Exec(S);
end;

function IsPyWordChar(C: WideChar): Boolean;
begin
  if Ord(C) < 128 then
    Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
      ((C >= '0') and (C <= '9')) or (C = '_')
  else
    Result := TCharacter.IsLetterOrDigit(C) or TCharacter.IsNumber(C);
end;

{ endsentence_re.search: the leftmost sentence-ending mark followed only
  by non-word characters to the end. A direct scan, same result. }
function EndsSentence(const S: UnicodeString; CheckQuotes: Boolean): UnicodeString;
const
  EnderChars: UnicodeString = '.?!'#$0964#$0965#$1361#$1362#$061F#$06D4;
var
  K, I: Integer;
begin
  Result := '';
  K := Length(S);
  while (K >= 1) and not IsPyWordChar(S[K]) do
    Dec(K);
  for I := K + 1 to Length(S) do
    if Pos(S[I], EnderChars) > 0 then
    begin
      Result := S[I];
      if CheckQuotes and BadQuoted(Copy(S, I, 3)) then
        Result := '';
      Exit;
    end;
end;

{ word_re (\w+-\w+|\w+) at a word start P: the word, hyphen rule
  included. }
function WordAt(const S: UnicodeString; P: Integer): UnicodeString;
var
  E: Integer;
begin
  E := P;
  while (E <= Length(S)) and IsPyWordChar(S[E]) do
    Inc(E);
  { \w+-\w+ first: a hyphen and more word characters }
  if (E < Length(S)) and (S[E] = '-') and IsPyWordChar(S[E + 1]) then
  begin
    Inc(E);
    while (E <= Length(S)) and IsPyWordChar(S[E]) do
      Inc(E);
  end;
  Result := Copy(S, P, E - P);
end;

{ word_re.search: a direct scan, same result. }
function FirstWord(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if IsPyWordChar(S[I]) then
      Exit(WordAt(S, I));
  Result := '';
end;

function LastWord(const S: UnicodeString): UnicodeString;
var
  Items: TUnicodeWords;
  I: Integer;
  M: TRegExpr;
begin
  Result := '';
  Items := SplitWords(S);
  M := Re(reWordLast);
  for I := High(Items) downto 0 do
    if M.Exec(Items[I]) then
    begin
      repeat
        Result := M.Match[1];   // the last of findall
      until not M.ExecNext;
      Exit;
    end;
end;

{ endsent_re over S: after each sentence-ending mark, the next word
  (DOTALL, lazy), unless the mark is badly quoted. A direct scan, same
  result. }
function NextFirstWords(const S: UnicodeString): TUnicodeWordList;
const
  EnderChars: UnicodeString = '.?!'#$0964#$0965#$1361#$1362#$061F#$06D4;
var
  I, Q: Integer;
  W: UnicodeString;
begin
  Result := nil;
  I := 1;
  while I <= Length(S) do
  begin
    if Pos(S[I], EnderChars) > 0 then
    begin
      Q := I + 1;
      while (Q <= Length(S)) and not IsPyWordChar(S[Q]) do
        Inc(Q);
      if Q > Length(S) then
        Exit;     // no word after it: no more matches
      W := WordAt(S, Q);
      if not BadQuoted(Copy(S, I, 2)) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := W;
      end;
      I := Q + Length(W);
      Continue;
    end;
    Inc(I);
  end;
end;

function StartPositions(const S: UnicodeString): TPositions;
var
  W, E: TRegExpr;
  From: Integer;
  Found: Boolean;
begin
  Result := nil;
  W := Re(reWordStart);
  E := Re(reEndSentStart);
  if (S = '') or not W.Exec(S) then
    Exit;
  E.InputString := S;     // ExecPos searches the last InputString
  repeat
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := W.MatchPos[0];
    From := W.MatchPos[0] + W.MatchLen[0];
    Found := (From <= Length(S)) and E.ExecPos(From);
    while Found and BadQuoted(E.Match[0]) do
    begin
      From := E.MatchPos[0] + E.MatchLen[0];
      Found := (From <= Length(S)) and E.ExecPos(From);
    end;
    if not Found then
      Break;
    From := E.MatchPos[0] + 1;
    if (From > Length(S)) or not W.ExecPos(From) then
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
  if IsTitle(Word) then
    Exit(True);
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
