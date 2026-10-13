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

implementation

uses
  Character;

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
