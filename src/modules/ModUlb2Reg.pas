unit ModUlb2Reg;

{$mode objfpc}{$H+}

{ ulb2reg: convert a BTT-Writer / translationStudio target translation from
  ULB to REG. Sets the manifest.json resource id to "reg" and name to
  "Regular", and renames the project folder from *_ulb to *_reg.

  Ported from BTT-Manager/ulb2reg.py, with these fixes:
  - refuses unless the manifest really says ULB (the script renamed the
    folder on the folder name alone)
  - refuses if the *_reg folder already exists
  - --dry-run reports what would change without touching anything
  - keeps BTT-Writer's tab-indented manifest layout }

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TUlb2RegModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  fpjson, WBJson;

resourcestring
  rsTitle = 'Convert ULB project to REG';
  rsDescription = 'Changes a BTT-Writer target translation from ULB to REG: ' +
    'updates manifest.json and renames the project folder from *_ulb to *_reg.';
  rsOptProject = 'Project folder';
  rsOptProjectHelp = 'The target translation folder, e.g. en_mat_text_ulb';
  rsOptDryRun = 'Dry run';
  rsOptDryRunHelp = 'Show what would change without changing anything';
  rsNotAFolder = 'Not a folder: %s';
  rsNotUlbName = 'Folder name does not end in _ulb: %s';
  rsNoManifest = 'No manifest.json in %s';
  rsBadManifest = 'Could not read manifest.json: %s';
  rsManifestNotUlb = 'manifest.json says the resource is "%s", not "ulb". Nothing changed.';
  rsTargetExists = 'Cannot rename: %s already exists. Nothing changed.';
  rsWillConvert = 'Converting %s -> %s';
  rsDryRun = 'Dry run: no changes made.';
  rsRenameFailed = 'Could not rename %s to %s. Nothing changed.';
  rsWriteFailed = 'Could not write manifest.json (%s). Folder name restored.';
  rsDone = 'Done: %s is now a REG project.';

const
  UlbSuffix = '_ulb';
  RegSuffix = '_reg';

function TUlb2RegModule.Id: string;
begin
  Result := 'ulb2reg';
end;

function TUlb2RegModule.Title: string;
begin
  Result := rsTitle;
end;

function TUlb2RegModule.Description: string;
begin
  Result := rsDescription;
end;

function TUlb2RegModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('project', okDirectory, True, True, rsOptProject, rsOptProjectHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp)];
end;

function TUlb2RegModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  ProjectDir, NewDir, FolderName, ResourceId: string;
  Manifest: TJSONObject;
  Resource: TJSONData;
  DryRun: Boolean;
begin
  Result := 1;
  ProjectDir := ExcludeTrailingPathDelimiter(ExpandFileName(Options.Values['project']));
  DryRun := OptionIsSet(Options, 'dry-run');

  if not DirectoryExists(ProjectDir) then
  begin
    Reporter.Error(Format(rsNotAFolder, [ProjectDir]));
    Exit;
  end;
  FolderName := ExtractFileName(ProjectDir);
  if Copy(FolderName, Length(FolderName) - Length(UlbSuffix) + 1, MaxInt) <> UlbSuffix then
  begin
    Reporter.Error(Format(rsNotUlbName, [FolderName]));
    Exit;
  end;
  if not FileExists(ProjectDir + PathDelim + 'manifest.json') then
  begin
    Reporter.Error(Format(rsNoManifest, [ProjectDir]));
    Exit;
  end;

  try
    Manifest := ReadJSONObjectFile(ProjectDir + PathDelim + 'manifest.json');
  except
    on E: Exception do
    begin
      Reporter.Error(Format(rsBadManifest, [E.Message]));
      Exit;
    end;
  end;

  try
    Resource := Manifest.Find('resource');
    ResourceId := '';
    if Resource is TJSONObject then
      ResourceId := TJSONObject(Resource).Get('id', '');
    if ResourceId <> 'ulb' then
    begin
      Reporter.Error(Format(rsManifestNotUlb, [ResourceId]));
      Exit;
    end;

    NewDir := Copy(ProjectDir, 1, Length(ProjectDir) - Length(UlbSuffix)) + RegSuffix;
    if DirectoryExists(NewDir) or FileExists(NewDir) then
    begin
      Reporter.Error(Format(rsTargetExists, [NewDir]));
      Exit;
    end;

    Reporter.Info(Format(rsWillConvert, [FolderName, ExtractFileName(NewDir)]));
    if DryRun then
    begin
      Reporter.Info(rsDryRun);
      Exit(0);
    end;

    TJSONObject(Resource).Strings['id'] := 'reg';
    TJSONObject(Resource).Strings['name'] := 'Regular';

    { Rename first: if that fails nothing has changed. If the manifest
      write then fails, put the folder name back. }
    if not RenameFile(ProjectDir, NewDir) then
    begin
      Reporter.Error(Format(rsRenameFailed, [ProjectDir, NewDir]));
      Exit;
    end;
    try
      WriteBttJSONFile(NewDir + PathDelim + 'manifest.json', Manifest);
    except
      on E: Exception do
      begin
        RenameFile(NewDir, ProjectDir);
        Reporter.Error(Format(rsWriteFailed, [E.Message]));
        Exit;
      end;
    end;

    Reporter.Info(Format(rsDone, [ExtractFileName(NewDir)]));
    Result := 0;
  finally
    Manifest.Free;
  end;
end;

initialization
  RegisterModule(TUlb2RegModule.Create);

end.
