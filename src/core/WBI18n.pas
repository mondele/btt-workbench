unit WBI18n;

{$mode objfpc}{$H+}

{ Runtime translation loader, LCL-free so the CLI and libbtw can use it.

  Translations are gettext .po files at locale/<lang>/btt-workbench.po,
  produced from locale/btt-workbench.pot (see tools/extract-pot.sh).
  LoadLanguage swaps every resourcestring in the process to the
  translated text. English is the source language and needs no file.

  Language codes are lowercase with '-' (pt-br, es-419). A missing regional
  file falls back to the base language (pt-br -> pt).

  The language to start in (StartupLanguage): the one the user chose last
  (SaveLanguage, in WBSettings' [interface] language), else the one chosen
  in the Windows installer (defaults.ini beside the program, same key),
  else the system language.

  Locale directory search order:
    1. ExtraDir, if given (Android passes its unpacked assets dir)
    2. <exe-dir>/locale
    3. <exe-dir>/../locale                     (dev: binaries in bin/)
    4. <exe-dir>/../share/btt-workbench/locale (installed layout) }

interface

uses
  Classes, SysUtils;

const
  LocaleDomain = 'btt-workbench';

{ Resets all resourcestrings to English, then loads Lang if it is not
  English. Returns the .po path that was loaded, or '' for English or when
  no file was found (strings then stay English). }
function LoadLanguage(const Lang: string; const ExtraDir: string = ''): string;
function CurrentLanguage: string;
function NormalizeLanguage(const Lang: string): string;
{ From LANG/LC_* on Unix, the user locale on Windows. }
function SystemLanguage: string;
function IsRightToLeftLanguage(const Lang: string): Boolean;
{ 'en' plus every language with a .po in the first locale dir found. }
function AvailableLanguages(const ExtraDir: string = ''): TStringArray;
function StartupLanguage: string;
{ Remembers Lang for StartupLanguage; '' forgets it. }
procedure SaveLanguage(const Lang: string);

var
  { Set by tests in place of <exe-dir>/defaults.ini. }
  InstallDefaultsOverride: string = '';

implementation

uses
  Translations, IniFiles, WBSettings;

const
  SetSection = 'interface';
  SetLanguage = 'language';

var
  FCurrent: string = 'en';

function NormalizeLanguage(const Lang: string): string;
var
  P: Integer;
begin
  Result := LowerCase(Trim(Lang));
  P := Pos('.', Result);           // en_US.UTF-8 -> en_us
  if P > 0 then
    SetLength(Result, P - 1);
  P := Pos('@', Result);           // sr_RS@latin -> sr_rs
  if P > 0 then
    SetLength(Result, P - 1);
  Result := StringReplace(Result, '_', '-', [rfReplaceAll]);
  if (Result = '') or (Result = 'c') or (Result = 'posix') then
    Result := 'en';
end;

function BaseLanguage(const Lang: string): string;
var
  P: Integer;
begin
  Result := Lang;
  P := Pos('-', Result);
  if P > 0 then
    SetLength(Result, P - 1);
end;

function LocaleDirs(const ExtraDir: string): TStringArray;
var
  ExeDir: string;
begin
  ExeDir := ExtractFilePath(ParamStr(0));
  if ExeDir = '' then
    ExeDir := IncludeTrailingPathDelimiter(GetCurrentDir);
  Result := nil;
  if ExtraDir <> '' then
    Result := Concat(Result, [IncludeTrailingPathDelimiter(ExtraDir)]);
  Result := Concat(Result, [
    ExeDir + 'locale' + PathDelim,
    ExeDir + '..' + PathDelim + 'locale' + PathDelim,
    ExeDir + '..' + PathDelim + 'share' + PathDelim + LocaleDomain + PathDelim +
      'locale' + PathDelim]);
end;

function LocateLanguageFile(const Lang, ExtraDir: string): string;
var
  Dir, Code: string;
  Codes: array[0..1] of string;
begin
  Codes[0] := Lang;
  Codes[1] := BaseLanguage(Lang);
  for Code in Codes do
    for Dir in LocaleDirs(ExtraDir) do
    begin
      Result := Dir + Code + PathDelim + LocaleDomain + '.po';
      if FileExists(Result) then
        Exit;
    end;
  Result := '';
end;

function LoadLanguage(const Lang: string; const ExtraDir: string): string;
var
  Code: string;
begin
  Result := '';
  Code := NormalizeLanguage(Lang);
  ResetResourceTables;
  FCurrent := 'en';
  if BaseLanguage(Code) = 'en' then
    Exit;
  Result := LocateLanguageFile(Code, ExtraDir);
  if Result = '' then
    Exit;
  TranslateResourceStrings(Result);
  FCurrent := Code;
end;

function CurrentLanguage: string;
begin
  Result := FCurrent;
end;

function SystemLanguage: string;
begin
  Result := NormalizeLanguage(GetLanguageID.LanguageID);
end;

function IsRightToLeftLanguage(const Lang: string): Boolean;
var
  Base: string;
begin
  Base := BaseLanguage(NormalizeLanguage(Lang));
  Result := (Base = 'ar') or (Base = 'fa') or (Base = 'he') or (Base = 'ur') or
            (Base = 'ps') or (Base = 'sd') or (Base = 'ug') or (Base = 'yi') or
            (Base = 'dv') or (Base = 'ckb') or (Base = 'syr');
end;

function InstallDefaultLanguage: string;
var
  F: string;
  Ini: TIniFile;
begin
  Result := '';
  F := InstallDefaultsOverride;
  if F = '' then
    F := ExtractFilePath(ParamStr(0)) + 'defaults.ini';
  if not FileExists(F) then
    Exit;
  Ini := TIniFile.Create(F);
  try
    Result := Trim(Ini.ReadString(SetSection, SetLanguage, ''));
  finally
    Ini.Free;
  end;
end;

function StartupLanguage: string;
begin
  Result := GetSettingIn(SetSection, SetLanguage);
  if Result = '' then
    Result := InstallDefaultLanguage;
  if Result = '' then
    Result := SystemLanguage;
  Result := NormalizeLanguage(Result);
end;

procedure SaveLanguage(const Lang: string);
begin
  SetSettingIn(SetSection, SetLanguage, Lang);
end;

function AvailableLanguages(const ExtraDir: string): TStringArray;
var
  Found: TStringList;
  Dir: string;
  SR: TSearchRec;
begin
  Found := TStringList.Create;
  try
    Found.Sorted := True;
    Found.Duplicates := dupIgnore;
    Found.Add('en');
    for Dir in LocaleDirs(ExtraDir) do
      if DirectoryExists(Dir) then
      begin
        if FindFirst(Dir + '*', faDirectory, SR) = 0 then
        try
          repeat
            if ((SR.Attr and faDirectory) <> 0) and (SR.Name <> '.') and (SR.Name <> '..') and
               FileExists(Dir + SR.Name + PathDelim + LocaleDomain + '.po') then
              Found.Add(SR.Name);
          until FindNext(SR) <> 0;
        finally
          FindClose(SR);
        end;
        Break;
      end;
    Result := Found.ToStringArray;
  finally
    Found.Free;
  end;
end;

end.
