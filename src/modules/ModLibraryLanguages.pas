unit ModLibraryLanguages;

{$mode objfpc}{$H+}

(* library-languages: BTT-Writer's "Update languages" (target languages,
   temporary languages and their approved codes, the new-language
   questionnaire), with the downloads made at once (WBLibraryUpdate). For
   now it writes an updated copy of index.sqlite, not BTT-Writer's own. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TLibraryLanguagesModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  WBSqliteDb, WBLibraryUpdate;

resourcestring
  rsTitle = 'Update target languages';
  rsDescription = 'Does what BTT-Writer''s Update Languages does (the target ' +
    'languages, temporary languages and their approved codes, and the ' +
    'new-language questions), downloading the catalogs at once. The result ' +
    'is written to a copy of BTT-Writer''s index.sqlite; BTT-Writer''s own is ' +
    'not changed.';
  rsOptLibraryDb = 'Language database';
  rsOptLibraryDbHelp = 'The index.sqlite to start from (default: BTT-Writer''s)';
  rsOptOutput = 'Write to';
  rsOptOutputHelp = 'The updated copy of index.sqlite to write';
  rsOptLanguagesUrl = 'Languages catalog';
  rsOptLanguagesUrlHelp = 'Where the target languages come from (default: ' +
    'BTT-Writer''s, langnames.json)';
  rsOptConnections = 'Downloads at once';
  rsOptConnectionsHelp = 'How many catalogs to download at the same time (default 8)';
  rsNoSqlite = 'No SQLite library was found on this computer, so index.sqlite cannot be written.';
  rsNoInput = 'The language database was not found: %s';
  rsCannotCopy = 'Cannot write %s: %s';
  rsUsing = 'From %s, written to %s (SQLite %s).';
  rsDone = 'Target languages: %d before, %d now. Temporary languages: %d before, %d now, %d ' +
    'with an approved code. New-language questions: %d. (%.1f s)';

function TLibraryLanguagesModule.Id: string;
begin
  Result := 'library-languages';
end;

function TLibraryLanguagesModule.Title: string;
begin
  Result := rsTitle;
end;

function TLibraryLanguagesModule.Description: string;
begin
  Result := rsDescription;
end;

function TLibraryLanguagesModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('output', okFile, True, False, rsOptOutput, rsOptOutputHelp),
    OptionDef('library-db', okFile, False, False, rsOptLibraryDb, rsOptLibraryDbHelp),
    OptionDef('languages-url', okString, False, False, rsOptLanguagesUrl, rsOptLanguagesUrlHelp),
    OptionDef('connections', okString, False, False, rsOptConnections, rsOptConnectionsHelp)];
end;

function TLibraryLanguagesModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Input, Output, Url, Problem, Version: string;
  Db: TSqliteDb;
  Before, BeforeTemp: Int64;
  Started: QWord;
begin
  Result := 1;
  Version := SqliteLibraryVersion;
  if Version = '' then
  begin
    Reporter.Error(rsNoSqlite);
    Exit;
  end;
  Input := Options.Values['library-db'];
  if Input = '' then
    Input := LibraryIndexFile;
  if not FileExists(Input) then
  begin
    Reporter.Error(Format(rsNoInput, [Input]));
    Exit;
  end;
  Output := ExpandFileName(Options.Values['output']);
  Url := Trim(Options.Values['languages-url']);
  if Url = '' then
    Url := DefaultLanguagesUrl;
  Db := OpenCopy(Input, Output, Problem);
  if Db = nil then
  begin
    Reporter.Error(Format(rsCannotCopy, [Output, Problem]));
    Exit;
  end;
  try
    Reporter.Info(Format(rsUsing, [Input, Output, Version]));
    Started := GetTickCount64;
    Before := Db.QueryInt('select count(*) from target_language', []);
    BeforeTemp := Db.QueryInt('select count(*) from temp_target_language', []);
    if not UpdateTargetLanguages(Db, Url,
       StrToIntDef(Options.Values['connections'], DefaultConnections), Reporter) then
      Exit;
    Reporter.Info(Format(rsDone, [Before, Db.QueryInt('select count(*) from target_language', []),
      BeforeTemp, Db.QueryInt('select count(*) from temp_target_language', []),
      Db.QueryInt('select count(*) from temp_target_language where ' +
        'approved_target_language_slug is not null', []),
      Db.QueryInt('select count(*) from question', []),
      (GetTickCount64 - Started) / 1000]));
    Result := 0;
  finally
    Db.Free;
  end;
end;

initialization
  RegisterModule(TLibraryLanguagesModule.Create);

end.
