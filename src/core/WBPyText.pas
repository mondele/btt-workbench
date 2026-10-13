unit WBPyText;

{$mode objfpc}{$H+}

{ Python string semantics the usfm-tools ports rely on: str.islower,
  isupper, istitle (cased characters by Unicode category) and split()
  on whitespace, for UnicodeString. }

interface

type
  TUnicodeWords = array of UnicodeString;

function IsLowerChar(C: WideChar): Boolean;
function IsUpperChar(C: WideChar): Boolean;
{ str.islower / str.isupper: at least one cased character, all that case. }
function AllLower(const W: UnicodeString): Boolean;
function AllUpper(const W: UnicodeString): Boolean;
{ str.istitle }
function IsTitle(const W: UnicodeString): Boolean;
{ str.split(): runs of whitespace separate, none empty. }
function SplitWords(const T: UnicodeString): TUnicodeWords;
{ Python's str.isspace for one character. }
function IsSpaceChar(C: WideChar): Boolean;
{ usfm_utils.unicodeBlock: the commonest first word of the characters'
  Unicode names ('LATIN' for ASCII text, 'Unknown' if none count). }
function UnicodeBlockOf(const T: UnicodeString): string;
{ usfm_utils.isCaseless: the text is in a script without capitals. }
function IsCaseless(const T: UnicodeString): Boolean;
{ str.isascii }
function IsAsciiText(const T: UnicodeString): Boolean;

implementation

uses
  Character, WBUnicodeNames;

function IsAsciiText(const T: UnicodeString): Boolean;
var
  C: WideChar;
begin
  for C in T do
    if Ord(C) > 127 then
      Exit(False);
  Result := True;
end;

{ Most frequent name word; ties go to the one seen first, as Python's
  max() over an insertion-ordered dict does. }
function BestName(const T: UnicodeString; out Caseless: Boolean): string;
var
  Ids: array of Integer;
  Counts: array of Integer;
  I, J, Best, Id: Integer;
  CP: Cardinal;
  Found: Boolean;
begin
  Caseless := False;
  if IsAsciiText(T) then
    Exit('LATIN');
  Ids := nil;
  Counts := nil;
  I := 1;
  while I <= Length(T) do
  begin
    CP := Ord(T[I]);
    if (CP >= $D800) and (CP <= $DBFF) and (I < Length(T)) and
       (Ord(T[I + 1]) >= $DC00) and (Ord(T[I + 1]) <= $DFFF) then
    begin
      CP := $10000 + ((CP - $D800) shl 10) + (Ord(T[I + 1]) - $DC00);
      Inc(I);
    end;
    Inc(I);
    if (CP < 128) and (Pos(Chr(CP), ' '#10'\vcpq*-0123456789') > 0) then
      Continue;
    Id := NameWordOf(CP);
    if NameWord(Id) = 'ZERO' then
      Continue;
    Found := False;
    for J := 0 to High(Ids) do
      if Ids[J] = Id then
      begin
        Inc(Counts[J]);
        Found := True;
        Break;
      end;
    if not Found then
    begin
      SetLength(Ids, Length(Ids) + 1);
      SetLength(Counts, Length(Counts) + 1);
      Ids[High(Ids)] := Id;
      Counts[High(Counts)] := 1;
    end;
  end;
  if Length(Ids) = 0 then
    Exit('Unknown');
  Best := 0;
  for J := 1 to High(Ids) do
    if Counts[J] > Counts[Best] then
      Best := J;
  Caseless := IsCaselessName(Ids[Best]);
  Result := NameWord(Ids[Best]);
end;

function UnicodeBlockOf(const T: UnicodeString): string;
var
  Caseless: Boolean;
begin
  Result := BestName(T, Caseless);
end;

function IsCaseless(const T: UnicodeString): Boolean;
begin
  BestName(T, Result);
end;

function IsSpaceChar(C: WideChar): Boolean;
begin
  case Ord(C) of
    9..13, $1C..$20, $85, $A0, $1680, $2000..$200A, $2028, $2029, $202F, $205F, $3000:
      Result := True;
  else
    Result := False;
  end;
end;

function IsLowerChar(C: WideChar): Boolean;
begin
  Result := TCharacter.IsLower(C);
end;

function IsUpperChar(C: WideChar): Boolean;
begin
  Result := TCharacter.IsUpper(C);
end;

function AllLower(const W: UnicodeString): Boolean;
var
  C: WideChar;
  Cased: Boolean;
begin
  Cased := False;
  for C in W do
    if IsUpperChar(C) then
      Exit(False)
    else if IsLowerChar(C) then
      Cased := True;
  Result := Cased;
end;

function AllUpper(const W: UnicodeString): Boolean;
var
  C: WideChar;
  Cased: Boolean;
begin
  Cased := False;
  for C in W do
    if IsLowerChar(C) then
      Exit(False)
    else if IsUpperChar(C) then
      Cased := True;
  Result := Cased;
end;

function IsTitle(const W: UnicodeString): Boolean;
var
  C: WideChar;
  PrevCased, Cased: Boolean;
begin
  PrevCased := False;
  Cased := False;
  for C in W do
    if IsUpperChar(C) then
    begin
      if PrevCased then
        Exit(False);
      PrevCased := True;
      Cased := True;
    end
    else if IsLowerChar(C) then
    begin
      if not PrevCased then
        Exit(False);
      PrevCased := True;
      Cased := True;
    end
    else
      PrevCased := False;
  Result := Cased;
end;

{ Python's str.split(): runs of whitespace separate. }
function SplitWords(const T: UnicodeString): TUnicodeWords;
var
  I, Start: Integer;
begin
  Result := nil;
  I := 1;
  while I <= Length(T) do
  begin
    while (I <= Length(T)) and IsSpaceChar(T[I]) do
      Inc(I);
    Start := I;
    while (I <= Length(T)) and not IsSpaceChar(T[I]) do
      Inc(I);
    if I > Start then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(T, Start, I - Start);
    end;
  end;
end;

end.
