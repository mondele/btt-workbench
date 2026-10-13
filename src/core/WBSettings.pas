unit WBSettings;

{$mode objfpc}{$H+}

{ BTT Workbench's own saved settings: a small ini file, shared by the CLI,
  GUI and library.
    Linux    $XDG_CONFIG_HOME/btt-workbench/settings.ini (~/.config/...)
    macOS    ~/Library/Application Support/btt-workbench/settings.ini
    Windows  %APPDATA%\btt-workbench\settings.ini
  BTW_SETTINGS names another file (tests, portable setups). }

interface

uses
  SysUtils;

const
  { Keys in [btt-writer] }
  SetBttWriterInstall = 'install';
  SetBttWriterData = 'data';

function SettingsFile: string;
{ '' if unset. }
function GetSetting(const Key: string): string;
{ An empty value removes the key. }
procedure SetSetting(const Key, Value: string);
{ The same in another [Section] (e.g. 'wacs'). The file can hold a WACS
  token, so it is written readable by its owner only (Unix). }
function GetSettingIn(const ASection, Key: string): string;
procedure SetSettingIn(const ASection, Key, Value: string);

var
  { Set by tests so they never read or change the user's settings. }
  SettingsFileOverride: string = '';

implementation

uses
  IniFiles{$IFDEF UNIX}, BaseUnix{$ENDIF};

const
  Section = 'btt-writer';

function SettingsFile: string;
var
  Base: string;
begin
  if SettingsFileOverride <> '' then
    Exit(SettingsFileOverride);
  Result := Trim(GetEnvironmentVariable('BTW_SETTINGS'));
  if Result <> '' then
    Exit;
  {$IFDEF WINDOWS}
  Base := GetEnvironmentVariable('APPDATA');
  {$ELSE}
  {$IFDEF DARWIN}
  Base := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) +
    'Library' + PathDelim + 'Application Support';
  {$ELSE}
  Base := Trim(GetEnvironmentVariable('XDG_CONFIG_HOME'));
  if Base = '' then
    Base := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config';
  {$ENDIF}
  {$ENDIF}
  Result := IncludeTrailingPathDelimiter(Base) + 'btt-workbench' + PathDelim +
    'settings.ini';
end;

function GetSettingIn(const ASection, Key: string): string;
var
  Ini: TMemIniFile;
begin
  Result := '';
  if not FileExists(SettingsFile) then
    Exit;
  Ini := TMemIniFile.Create(SettingsFile);
  try
    Result := Ini.ReadString(ASection, Key, '');
  finally
    Ini.Free;
  end;
end;

procedure SetSettingIn(const ASection, Key, Value: string);
var
  Ini: TMemIniFile;
begin
  ForceDirectories(ExtractFileDir(SettingsFile));
  {$IFDEF UNIX}
  if not FileExists(SettingsFile) then
    FileClose(FileCreate(SettingsFile));
  fpChmod(SettingsFile, &600);
  {$ENDIF}
  Ini := TMemIniFile.Create(SettingsFile);
  try
    if Value = '' then
      Ini.DeleteKey(ASection, Key)
    else
      Ini.WriteString(ASection, Key, Value);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
  {$IFDEF UNIX}
  fpChmod(SettingsFile, &600);
  {$ENDIF}
end;

function GetSetting(const Key: string): string;
begin
  Result := GetSettingIn(Section, Key);
end;

procedure SetSetting(const Key, Value: string);
begin
  SetSettingIn(Section, Key, Value);
end;

end.
