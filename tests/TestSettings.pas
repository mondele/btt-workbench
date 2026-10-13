unit TestSettings;

{$mode objfpc}{$H+}

(* Tests for the settings module and finding BTT-Writer's bundled sources.
   TestCore points WBSettings at a temp file, so the user's settings are
   never read or changed. *)

interface

procedure TestSettingsModule(const TempRoot: string);

implementation

uses
  Classes, SysUtils, WBReporter, WBSettings, WBDataPaths, TestUtil;

function Run(const Args: array of string; out Output: string): Integer;
var
  R: TWBListReporter;
  I: Integer;
begin
  Result := RunModule('settings', Args, R);
  Output := '';
  for I := 0 to R.Count - 1 do
    Output := Output + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
  R.Free;
end;

procedure TestSettingsModule(const TempRoot: string);
var
  Root, Linux, Mac, Sources, MacSources, Empty, Data, Output: string;
  EnvFree: Boolean;
begin
  Section('settings');
  Root := TempRoot + 'settings' + PathDelim;
  Linux := Root + 'btt-writer' + PathDelim;
  Sources := Linux + 'resources' + PathDelim + 'app' + PathDelim + 'src' + PathDelim +
    'index' + PathDelim + 'resource_containers' + PathDelim;
  ForceDirectories(Sources);
  WriteFileText(Sources + 'fr_tit_f10.tsrc', 'x');
  WriteFileText(Linux + 'BTT-Writer', 'program');
  Mac := Root + 'BTT-Writer.app' + PathDelim;
  MacSources := Mac + 'Contents' + PathDelim + 'resources' + PathDelim + 'app' + PathDelim +
    'src' + PathDelim + 'index' + PathDelim + 'resource_containers' + PathDelim;
  ForceDirectories(MacSources);
  WriteFileText(MacSources + 'en_tit_ulb.tsrc', 'x');
  Empty := Root + 'empty' + PathDelim;
  ForceDirectories(Empty);
  Data := Root + 'data' + PathDelim;
  ForceDirectories(Data);

  Check(BundledSourcesIn(Linux) = Sources, 'sources found from the install folder');
  Check(BundledSourcesIn(Linux + 'BTT-Writer') = Sources, '... from the program file');
  Check(BundledSourcesIn(Sources) = Sources, '... from the sources folder itself');
  Check(BundledSourcesIn(Linux + 'resources') = Sources, '... from resources/');
  Check(BundledSourcesIn(Mac) = MacSources, '... from a macOS .app');
  Check((BundledSourcesIn(Empty) = '') and (BundledSourcesIn(Root + 'nowhere') = ''),
    'nothing found where there are no .tsrc files');

  Check(Run(['--btt-writer', Empty], Output) = 1, 'a folder without sources is refused');
  Check((Pos('error: No BTT-Writer source texts', Output) > 0) and
    (GetSetting(SetBttWriterInstall) = ''), '... and nothing saved');
  Check(Run(['--data-dir', Root + 'nowhere'], Output) = 1, 'a missing data folder is refused');

  Check(Run(['--btt-writer', Linux + 'BTT-Writer', '--data-dir', Data], Output) = 0,
    'install and data folder saved');
  Check(GetSetting(SetBttWriterInstall) = Linux + 'BTT-Writer', '... install as given');
  Check(GetSetting(SetBttWriterData) = ExcludeTrailingPathDelimiter(Data), '... data folder');
  Check(Pos('warning: ' + ExcludeTrailingPathDelimiter(Data) + ' has no targetTranslations',
    Output) > 0, 'warns when the data folder has no targetTranslations');

  EnvFree := (GetEnvironmentVariable('BTW_BUNDLED_SOURCES') = '') and
    (GetEnvironmentVariable('BTT_WRITER_DATA') = '');
  if EnvFree then
  begin
    BundledSourcesOverride := '';
    Check(BundledSourcesPath = Sources, 'saved install used for bundled sources');
    Check(BttWriterDataPath = Data, 'saved data folder used');
    Check(TargetTranslationsPath = Data + 'targetTranslations' + PathDelim,
      '... and for targetTranslations');
    Run([], Output);
    Check((Pos('BTT-Writer data folder: ' + ExcludeTrailingPathDelimiter(Data) +
      ' (saved setting)', Output) > 0) and
      (Pos('source texts: ' + ExcludeTrailingPathDelimiter(Sources) +
      ' (saved setting, 1 source texts)', Output) > 0), 'settings shown with their origin');

    RenameFile(Sources + 'fr_tit_f10.tsrc', Sources + 'fr_tit_f10.gone');
    Run([], Output);
    Check(Pos('warning: The saved BTT-Writer location', Output) > 0,
      'a saved install that lost its sources is reported');
    RenameFile(Sources + 'fr_tit_f10.gone', Sources + 'fr_tit_f10.tsrc');
  end
  else
    WriteLn('  (skipped lookup checks: BTW_BUNDLED_SOURCES or BTT_WRITER_DATA is set)');

  Check(Run(['--clear'], Output) = 0, '--clear runs');
  Check((GetSetting(SetBttWriterInstall) = '') and (GetSetting(SetBttWriterData) = ''),
    '--clear forgets both settings');
  if EnvFree then
    Check(BttWriterDataPath = DefaultBttWriterDataPath, 'data folder back to the default');
end;

end.
