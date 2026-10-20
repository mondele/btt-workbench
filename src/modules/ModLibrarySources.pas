unit ModLibrarySources;

{$mode objfpc}{$H+}

(* library-sources: BTT-Writer's "Update sources" (the projects, source
   languages and resources of the source server's catalog, and
   translationAcademy), with the downloads made several at once
   (WBLibraryUpdate). For now it writes an updated copy of index.sqlite, not
   BTT-Writer's own. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TLibrarySourcesModule = class(TWBModule)
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
  rsTitle = 'Update source list';
  rsDescription = 'Does what BTT-Writer''s Update Sources does (the list of ' +
    'source texts, their languages and projects, and translationAcademy), ' +
    'downloading many catalogs at once: about half a minute instead of five. ' +
    'The source texts themselves are not downloaded. The result is written to ' +
    'a copy of BTT-Writer''s index.sqlite; BTT-Writer''s own is not changed.';
  rsOptLibraryDb = 'Language database';
  rsOptLibraryDbHelp = 'The index.sqlite to start from (default: BTT-Writer''s)';
  rsOptOutput = 'Write to';
  rsOptOutputHelp = 'The updated copy of index.sqlite to write';
  rsOptServer = 'Source server';
  rsOptServerHelp = 'Where the source catalog comes from (default: BTT-Writer''s, ' +
    'https://api.bibletranslationtools.org)';
  rsOptConnections = 'Downloads at once';
  rsOptConnectionsHelp = 'How many catalogs to download at the same time (default 8)';
  rsNoSqlite = 'No SQLite library was found on this computer, so index.sqlite cannot be written.';
  rsNoInput = 'The language database was not found: %s';
  rsCannotCopy = 'Cannot write %s: %s';
  rsUsing = 'From %s, written to %s (SQLite %s).';
  rsDone = 'Source languages: %d before, %d now. Projects: %d before, %d now. Resources: %d ' +
    'before, %d now. (%.1f s)';

function TLibrarySourcesModule.Id: string;
begin
  Result := 'library-sources';
end;

function TLibrarySourcesModule.Title: string;
begin
  Result := rsTitle;
end;

function TLibrarySourcesModule.Description: string;
begin
  Result := rsDescription;
end;

function TLibrarySourcesModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('output', okFile, True, False, rsOptOutput, rsOptOutputHelp),
    OptionDef('library-db', okFile, False, False, rsOptLibraryDb, rsOptLibraryDbHelp),
    OptionDef('server', okString, False, False, rsOptServer, rsOptServerHelp),
    OptionDef('connections', okString, False, False, rsOptConnections, rsOptConnectionsHelp)];
end;

function TLibrarySourcesModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Input, Output, Server, Problem, Version: string;
  Db: TSqliteDb;
  Langs, Projects, Resources: Int64;
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
  Server := Trim(Options.Values['server']);
  if Server = '' then
    Server := DefaultSourceServer;
  Db := OpenCopy(Input, Output, Problem);
  if Db = nil then
  begin
    Reporter.Error(Format(rsCannotCopy, [Output, Problem]));
    Exit;
  end;
  try
    Reporter.Info(Format(rsUsing, [Input, Output, Version]));
    Started := GetTickCount64;
    Langs := Db.QueryInt('select count(*) from source_language', []);
    Projects := Db.QueryInt('select count(*) from project', []);
    Resources := Db.QueryInt('select count(*) from resource', []);
    if not UpdateSourceList(Db, Server,
       StrToIntDef(Options.Values['connections'], DefaultConnections), Reporter) then
      Exit;
    Reporter.Info(Format(rsDone, [Langs, Db.QueryInt('select count(*) from source_language', []),
      Projects, Db.QueryInt('select count(*) from project', []),
      Resources, Db.QueryInt('select count(*) from resource', []),
      (GetTickCount64 - Started) / 1000]));
    Result := 0;
  finally
    Db.Free;
  end;
end;

initialization
  RegisterModule(TLibrarySourcesModule.Create);

end.
