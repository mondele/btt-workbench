unit ModSettings;

{$mode objfpc}{$H+}

{ settings: show and save where BTT-Writer is, for the computers where it
  is not found by itself.
  --btt-writer: the BTT-Writer program (or its folder, or a macOS .app);
    its bundled source texts are used to check chunking (ModProjects).
  --data-dir: BTT-Writer's data folder (the one holding targetTranslations
    and library), used by every module that defaults to BTT-Writer's data.
  --clear forgets both before applying any new value. With no options it
  only shows the current settings and where each comes from. Saved in
  WBSettings' ini file. }

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TSettingsModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  WBSettings, WBDataPaths;

resourcestring
  rsTitle = 'Settings';
  rsDescription = 'Shows where BTT Workbench finds BTT-Writer and its data, ' +
    'and saves those locations when they are not found by themselves.';
  rsOptBttWriter = 'BTT-Writer program';
  rsOptBttWriterHelp = 'Where BTT-Writer is installed (its folder or program ' +
    'file); its bundled source texts are used to check chunking';
  rsOptDataDir = 'BTT-Writer data folder';
  rsOptDataDirHelp = 'The folder holding BTT-Writer''s targetTranslations and ' +
    'library folders';
  rsOptClear = 'Forget saved settings';
  rsOptClearHelp = 'Go back to finding BTT-Writer and its data by themselves';
  rsCleared = 'Saved settings forgotten.';
  rsNoSources = 'No BTT-Writer source texts (.tsrc files) found in %s. Choose ' +
    'the folder BTT-Writer is installed in. Nothing saved.';
  rsNoDataDir = 'Not a folder: %s. Nothing saved.';
  rsNoTargetTranslations = '%s has no targetTranslations folder; is it ' +
    'BTT-Writer''s data folder?';
  rsSaved = 'Saved.';
  rsSettingsFile = 'Settings file: %s';
  rsData = 'BTT-Writer data folder: %s (%s)';
  rsFromEnv = 'from %s';
  rsFromSetting = 'saved setting';
  rsFromDefault = 'BTT-Writer''s usual place';
  rsSources = 'BTT-Writer source texts: %s (%s, %d source texts)';
  rsFound = 'found on this computer';
  rsNoneFound = 'BTT-Writer source texts: not found. Chunking can only be ' +
    'checked against sources BTT-Writer has downloaded. Use --btt-writer to ' +
    'say where BTT-Writer is installed.';
  rsBadSetting = 'The saved BTT-Writer location %s has no source texts any ' +
    'more.';
  rsOtherInstalls = 'Other BTT-Writer installs found: %s';

function CountTsrc(const Dir: string): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FindFirst(Dir + '*.tsrc', faAnyFile, SR) = 0 then
  try
    repeat
      Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function TSettingsModule.Id: string;
begin
  Result := 'settings';
end;

function TSettingsModule.Title: string;
begin
  Result := rsTitle;
end;

function TSettingsModule.Description: string;
begin
  Result := rsDescription;
end;

function TSettingsModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('btt-writer', okDirectory, False, False, rsOptBttWriter, rsOptBttWriterHelp),
    OptionDef('data-dir', okDirectory, False, False, rsOptDataDir, rsOptDataDirHelp),
    OptionDef('clear', okFlag, False, False, rsOptClear, rsOptClearHelp)];
end;

function TSettingsModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Install, DataDir, Sources, Saved, Origin, Env: string;
  Found, Others: TStringArray;
  F: string;
begin
  Result := 1;
  Install := Trim(Options.Values['btt-writer']);
  DataDir := Trim(Options.Values['data-dir']);

  { Check new values before changing anything. }
  if (Install <> '') and (BundledSourcesIn(Install) = '') then
  begin
    Reporter.Error(Format(rsNoSources, [Install]));
    Exit;
  end;
  if (DataDir <> '') and not DirectoryExists(DataDir) then
  begin
    Reporter.Error(Format(rsNoDataDir, [DataDir]));
    Exit;
  end;

  if OptionIsSet(Options, 'clear') then
  begin
    SetSetting(SetBttWriterInstall, '');
    SetSetting(SetBttWriterData, '');
    Reporter.Info(rsCleared);
  end;
  if Install <> '' then
    SetSetting(SetBttWriterInstall, ExcludeTrailingPathDelimiter(ExpandFileName(Install)));
  if DataDir <> '' then
  begin
    DataDir := ExcludeTrailingPathDelimiter(ExpandFileName(DataDir));
    if not DirectoryExists(DataDir + PathDelim + 'targetTranslations') then
      Reporter.Warn(Format(rsNoTargetTranslations, [DataDir]));
    SetSetting(SetBttWriterData, DataDir);
  end;
  if (Install <> '') or (DataDir <> '') then
    Reporter.Info(rsSaved);

  Reporter.Info(Format(rsSettingsFile, [SettingsFile]));

  { Data folder and where it comes from. }
  Env := Trim(GetEnvironmentVariable('BTT_WRITER_DATA'));
  if Env <> '' then
    Origin := Format(rsFromEnv, ['BTT_WRITER_DATA'])
  else if GetSetting(SetBttWriterData) <> '' then
    Origin := rsFromSetting
  else
    Origin := rsFromDefault;
  Reporter.Info(Format(rsData, [ExcludeTrailingPathDelimiter(BttWriterDataPath), Origin]));

  { Bundled sources and where they come from. }
  Saved := GetSetting(SetBttWriterInstall);
  if (Saved <> '') and (BundledSourcesIn(Saved) = '') then
    Reporter.Warn(Format(rsBadSetting, [Saved]));
  Sources := BundledSourcesPath;
  if BundledSourcesOverride <> '' then
    Origin := Format(rsFromEnv, ['BundledSourcesOverride'])
  else if Trim(GetEnvironmentVariable('BTW_BUNDLED_SOURCES')) <> '' then
    Origin := Format(rsFromEnv, ['BTW_BUNDLED_SOURCES'])
  else if (Saved <> '') and (BundledSourcesIn(Saved) <> '') then
    Origin := rsFromSetting
  else
    Origin := rsFound;
  if Sources = '' then
    Reporter.Warn(rsNoneFound)
  else
    Reporter.Info(Format(rsSources, [ExcludeTrailingPathDelimiter(Sources), Origin,
      CountTsrc(Sources)]));

  Found := FindBttWriterInstalls;
  Others := nil;
  for F in Found do
    if F <> Sources then
      Others := Concat(Others, [ExcludeTrailingPathDelimiter(F)]);
  if Length(Others) > 0 then
    Reporter.Info(Format(rsOtherInstalls, [String.Join(', ', Others)]));
  Result := 0;
end;

initialization
  RegisterModule(TSettingsModule.Create);

end.
