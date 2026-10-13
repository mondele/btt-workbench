unit WBDataPaths;

{$mode objfpc}{$H+}

{ Where BTT-Writer keeps its data (same rules as btt-writer-two's
  DataPaths.pas and BTT-Writer Desktop):
    Linux    ~/.config/BTT-Writer/
    macOS    ~/Library/Application Support/BTT-Writer/
    Windows  %LOCALAPPDATA%\BTT-Writer\
  BTT_WRITER_DATA overrides all of them (tests, portable setups).

  Source texts ("resource containers", <lang>_<book>_<resource>) are in
  <data>/library/resource_containers/ once BTT-Writer has used them.
  BTT-Writer also ships thousands as compressed .tsrc files inside its
  install folder; BundledSourcesPath finds that folder (BTW_BUNDLED_SOURCES
  overrides it). Only the Linux location has been checked against a real
  install; the Windows and macOS ones follow the Electron app layout. }

interface

uses
  SysUtils;

function BttWriterDataPath: string;
function TargetTranslationsPath: string;
{ <data>/library/resource_containers/ for the data folder holding
  TargetDir (so a --target-dir elsewhere brings its own library). }
function LibrarySourcesPath(const TargetDir: string): string;
{ BTT-Writer's bundled .tsrc folder, or '' if none is found. }
function BundledSourcesPath: string;

var
  { Set by tests so results do not depend on an installed BTT-Writer. }
  BundledSourcesOverride: string = '';

implementation

function BttWriterDataPath: string;
var
  Base: string;
begin
  Result := Trim(GetEnvironmentVariable('BTT_WRITER_DATA'));
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(Result));
  {$IFDEF WINDOWS}
  Base := Trim(GetEnvironmentVariable('LOCALAPPDATA'));
  if Base = '' then
    Base := Trim(GetEnvironmentVariable('APPDATA'));
  Result := IncludeTrailingPathDelimiter(Base) + 'BTT-Writer' + PathDelim;
  {$ELSE}
  Base := Trim(GetEnvironmentVariable('HOME'));
  {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(Base) + 'Library' + PathDelim +
    'Application Support' + PathDelim + 'BTT-Writer' + PathDelim;
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(Base) + '.config' + PathDelim +
    'BTT-Writer' + PathDelim;
  {$ENDIF}
  {$ENDIF}
end;

function TargetTranslationsPath: string;
begin
  Result := BttWriterDataPath + 'targetTranslations' + PathDelim;
end;

function LibrarySourcesPath(const TargetDir: string): string;
begin
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(TargetDir)) + 'library' +
    PathDelim + 'resource_containers' + PathDelim;
end;

function BundledSourcesPath: string;
const
  Inside = 'resources' + PathDelim + 'app' + PathDelim + 'src' + PathDelim +
    'index' + PathDelim + 'resource_containers' + PathDelim;
var
  Candidates: array of string;
  C: string;
begin
  if BundledSourcesOverride <> '' then
    Exit(IncludeTrailingPathDelimiter(BundledSourcesOverride));
  Result := Trim(GetEnvironmentVariable('BTW_BUNDLED_SOURCES'));
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(Result));
  {$IFDEF WINDOWS}
  Candidates := [
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) +
      'Programs' + PathDelim + 'BTT-Writer' + PathDelim + Inside,
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('ProgramFiles')) +
      'BTT-Writer' + PathDelim + Inside];
  {$ELSE}
  {$IFDEF DARWIN}
  Candidates := ['/Applications/BTT-Writer.app/Contents/' + Inside];
  {$ELSE}
  Candidates := ['/usr/lib/btt-writer/' + Inside, '/opt/BTT-Writer/' + Inside,
    '/opt/btt-writer/' + Inside];
  {$ENDIF}
  {$ENDIF}
  for C in Candidates do
    if DirectoryExists(C) then
      Exit(C);
  Result := '';
end;

end.
