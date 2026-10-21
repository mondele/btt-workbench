unit WBLangTag;

{$mode objfpc}{$H+}

(* Whether a language code is a well-formed BCP 47 tag (RFC 5646, section
   2.1). Scripture Burrito and other newer tools expect BCP 47 tags, and
   some codes in use by BTT-Writer projects are not: mxc-MZ-chimanika has
   a variant of nine letters, where eight is the most (mxc-MZ-x-manika,
   with a private-use part, is well formed). Only the form is checked, not
   whether the subtags are registered; grandfathered tags such as
   i-klingon are not accepted. *)

interface

function IsWellFormedTag(const Tag: string): Boolean;

implementation

uses
  SysUtils;

function IsAlpha(const S: string): Boolean;
var
  C: Char;
begin
  Result := S <> '';
  for C in S do
    if not (C in ['a'..'z', 'A'..'Z']) then
      Exit(False);
end;

function IsDigits(const S: string): Boolean;
var
  C: Char;
begin
  Result := S <> '';
  for C in S do
    if not (C in ['0'..'9']) then
      Exit(False);
end;

function IsAlnum(const S: string): Boolean;
var
  C: Char;
begin
  Result := S <> '';
  for C in S do
    if not (C in ['a'..'z', 'A'..'Z', '0'..'9']) then
      Exit(False);
end;

function IsWellFormedTag(const Tag: string): Boolean;
var
  Parts: TStringArray;
  I, N, Ext: Integer;
  S: string;
  Singletons: string;
begin
  Result := False;
  if (Tag = '') or (Tag[1] = '-') or (Tag[Length(Tag)] = '-') or (Pos('--', Tag) > 0) then
    Exit;
  Parts := Tag.Split(['-']);
  N := Length(Parts);
  I := 0;

  { privateuse alone: x-abc }
  if LowerCase(Parts[0]) = 'x' then
  begin
    if N < 2 then
      Exit;
    for I := 1 to N - 1 do
      if not IsAlnum(Parts[I]) or (Length(Parts[I]) > 8) then
        Exit;
    Exit(True);
  end;

  { language: 2-3 letters with up to three extlangs, or 4-8 letters }
  S := Parts[0];
  if not IsAlpha(S) or (Length(S) < 2) or (Length(S) > 8) then
    Exit;
  I := 1;
  if Length(S) <= 3 then
  begin
    Ext := 0;
    while (I < N) and (Ext < 3) and IsAlpha(Parts[I]) and (Length(Parts[I]) = 3) do
    begin
      Inc(I);
      Inc(Ext);
    end;
  end;
  { script }
  if (I < N) and IsAlpha(Parts[I]) and (Length(Parts[I]) = 4) then
    Inc(I);
  { region }
  if (I < N) and ((IsAlpha(Parts[I]) and (Length(Parts[I]) = 2)) or
     (IsDigits(Parts[I]) and (Length(Parts[I]) = 3))) then
    Inc(I);
  { variants: 5-8 alphanumerics, or a digit and 3 alphanumerics }
  while (I < N) and IsAlnum(Parts[I]) and
    (((Length(Parts[I]) >= 5) and (Length(Parts[I]) <= 8)) or
     ((Length(Parts[I]) = 4) and (Parts[I][1] in ['0'..'9']))) do
    Inc(I);
  { extensions: a singleton (not x), then subtags of 2-8 }
  Singletons := '';
  while (I < N) and (Length(Parts[I]) = 1) and IsAlnum(Parts[I]) and
    (LowerCase(Parts[I]) <> 'x') do
  begin
    if Pos(LowerCase(Parts[I]), Singletons) > 0 then
      Exit;   // the same extension twice
    Singletons := Singletons + LowerCase(Parts[I]);
    Inc(I);
    Ext := 0;
    while (I < N) and IsAlnum(Parts[I]) and (Length(Parts[I]) >= 2) and
      (Length(Parts[I]) <= 8) do
    begin
      Inc(I);
      Inc(Ext);
    end;
    if Ext = 0 then
      Exit;
  end;
  { privateuse }
  if (I < N) and (LowerCase(Parts[I]) = 'x') then
  begin
    Inc(I);
    if I >= N then
      Exit;
    while I < N do
    begin
      if not IsAlnum(Parts[I]) or (Length(Parts[I]) > 8) then
        Exit;
      Inc(I);
    end;
  end;
  Result := I = N;
end;

end.
