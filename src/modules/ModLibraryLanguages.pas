unit ModLibraryLanguages;

{$mode objfpc}{$H+}

(* library-languages: BTT-Writer's "Update languages" (target languages,
   temporary languages and their approved codes, the new-language
   questionnaire), with the downloads made at once and a report of what
   changed (WBLibraryUpdate.RunLibraryUpdate): BTT-Writer's index.sqlite is
   replaced while BTT-Writer is not running, keeping the old one, or the
   result written elsewhere (--output), or only reported (--dry-run). *)

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
  WBLibraryUpdate;

resourcestring
  rsTitle = 'Update target languages';
  rsDescription = 'Does what BTT-Writer''s Update Languages does to its ' +
    'index.sqlite (the target languages, temporary languages and their ' +
    'approved codes, and the new-language questions), downloading the ' +
    'catalogs at once, and reports what changed. BTT-Writer must be closed; ' +
    'its old index.sqlite is kept beside the new one. Check first to see what ' +
    'would change, or write elsewhere with Write to.';
  rsOptLibraryDb = 'Language database';
  rsOptLibraryDbHelp = 'The index.sqlite to update (default: BTT-Writer''s)';
  rsOptOutput = 'Write to';
  rsOptOutputHelp = 'Write the updated index.sqlite here instead (BTT-Writer''s is then ' +
    'not changed)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Download and report what would change, writing nothing';
  rsOptLanguagesUrl = 'Languages catalog';
  rsOptLanguagesUrlHelp = 'Where the target languages come from (default: ' +
    'BTT-Writer''s, langnames.json)';
  rsOptConnections = 'Downloads at once';
  rsOptConnectionsHelp = 'How many catalogs to download at the same time (default 8)';

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
    OptionDef('library-db', okFile, False, False, rsOptLibraryDb, rsOptLibraryDbHelp),
    OptionDef('output', okFile, False, False, rsOptOutput, rsOptOutputHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp),
    OptionDef('languages-url', okString, False, False, rsOptLanguagesUrl, rsOptLanguagesUrlHelp),
    OptionDef('connections', okString, False, False, rsOptConnections, rsOptConnectionsHelp)];
end;

function TLibraryLanguagesModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Run: TLibraryRun;
begin
  Run.Kind := luLanguages;
  Run.Input := Options.Values['library-db'];
  if Run.Input = '' then
    Run.Input := LibraryIndexFile;
  Run.Input := ExpandFileName(Run.Input);
  Run.Output := Options.Values['output'];
  Run.DryRun := OptionIsSet(Options, 'dry-run');
  Run.Url := Trim(Options.Values['languages-url']);
  if Run.Url = '' then
    Run.Url := DefaultLanguagesUrl;
  Run.Connections := StrToIntDef(Options.Values['connections'], DefaultConnections);
  Result := RunLibraryUpdate(Run, Reporter);
end;

initialization
  RegisterModule(TLibraryLanguagesModule.Create);

end.
