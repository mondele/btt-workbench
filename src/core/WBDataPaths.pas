unit WBDataPaths;

{$mode objfpc}{$H+}

{ Where BTT-Writer keeps its data (same rules as btt-writer-two's
  DataPaths.pas and BTT-Writer Desktop):
    Linux    ~/.config/BTT-Writer/
    macOS    ~/Library/Application Support/BTT-Writer/
    Windows  %LOCALAPPDATA%\BTT-Writer\
  BTT_WRITER_DATA overrides all of them (tests, portable setups). }

interface

uses
  SysUtils;

function BttWriterDataPath: string;
function TargetTranslationsPath: string;

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

end.
