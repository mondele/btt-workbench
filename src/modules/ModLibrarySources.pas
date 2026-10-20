unit ModLibrarySources;

{$mode objfpc}{$H+}

(* library-sources: BTT-Writer's "Update sources" (the projects, source
   languages and resources of the source server's catalog, and
   translationAcademy), with the downloads made several at once and a
   report of what changed (WBLibraryUpdate.RunLibraryUpdate): BTT-Writer's
   index.sqlite is replaced while BTT-Writer is not running, keeping the old
   one, or the result written elsewhere (--output), or only reported
   (--dry-run). *)

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
  WBLibraryUpdate;

resourcestring
  rsTitle = 'Update source list';
  rsDescription = 'Does what BTT-Writer''s Update Sources does to its ' +
    'index.sqlite (the list of source texts, their languages and projects, ' +
    'and translationAcademy), downloading many catalogs at once: about half a ' +
    'minute instead of five. The source texts themselves are not downloaded. ' +
    'Reports what changed. BTT-Writer must be closed; its old index.sqlite is ' +
    'kept beside the new one. Check first to see what would change, or write ' +
    'elsewhere with Write to.';
  rsOptLibraryDb = 'Language database';
  rsOptLibraryDbHelp = 'The index.sqlite to update (default: BTT-Writer''s)';
  rsOptOutput = 'Write to';
  rsOptOutputHelp = 'Write the updated index.sqlite here instead (BTT-Writer''s is then ' +
    'not changed)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Download and report what would change, writing nothing';
  rsOptServer = 'Source server';
  rsOptServerHelp = 'Where the source catalog comes from (default: BTT-Writer''s, ' +
    'https://api.bibletranslationtools.org)';
  rsOptConnections = 'Downloads at once';
  rsOptConnectionsHelp = 'How many catalogs to download at the same time (default 8)';

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
    OptionDef('library-db', okFile, False, False, rsOptLibraryDb, rsOptLibraryDbHelp),
    OptionDef('output', okFile, False, False, rsOptOutput, rsOptOutputHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp),
    OptionDef('server', okString, False, False, rsOptServer, rsOptServerHelp),
    OptionDef('connections', okString, False, False, rsOptConnections, rsOptConnectionsHelp)];
end;

function TLibrarySourcesModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Run: TLibraryRun;
begin
  Run.Kind := luSources;
  Run.Input := Options.Values['library-db'];
  if Run.Input = '' then
    Run.Input := LibraryIndexFile;
  Run.Input := ExpandFileName(Run.Input);
  Run.Output := Options.Values['output'];
  Run.DryRun := OptionIsSet(Options, 'dry-run');
  Run.Url := Trim(Options.Values['server']);
  if Run.Url = '' then
    Run.Url := DefaultSourceServer;
  Run.Connections := StrToIntDef(Options.Values['connections'], DefaultConnections);
  Result := RunLibraryUpdate(Run, Reporter);
end;

initialization
  RegisterModule(TLibrarySourcesModule.Create);

end.
