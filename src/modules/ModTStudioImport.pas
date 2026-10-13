unit ModTStudioImport;

{$mode objfpc}{$H+}

(* tstudio-import: import a BTT-Writer .tstudio package into
   targetTranslations, with a preflight (--dry-run) that says whether each
   project is new, already present, or needs merging, and which chunks a
   merge would leave in conflict.

   Follows BTT-Writer Desktop 1.6.0 (/usr/lib/btt-writer: src/js/
   importer.js, migrator.js, gitnative.js, render.js), so the result opens
   cleanly there:
   - Package: zip with manifest.json (package_version 1 or 2, list in
     target_translations, or projects in v1) and one folder per project,
     .git included.
   - Same project = same folder name, built from the project's manifest as
     <language>_<book>_<type>[_<resource>].
   - Project manifests must end up at package_version 8. Version 7 gets
     Desktop's small v7->v8 step (resource.name filled in,
     source_translations defaulted). Older ones need BTT-Writer's full
     migration, so they are refused rather than guessed at; newer ones too.
   - The project must have a 'master' branch: Desktop merges later
     imports with "git pull <path> master".
   - Merge: local is "ours", imported is "theirs". translators and
     finished_chunks become the union of both; conflicted chunks are
     un-finished. Conflicts are committed with standard markers
       <<<<<<< HEAD / ======= / >>>>>>> <40-char commit hash>
     which is exactly what Desktop's conflict parser looks for (render.js).
     We merge by commit hash, not branch, so 'master' vs 'main' does not
     matter, and force merge.conflictStyle=merge (diff3 would break
     Desktop's parser).
   - Overwrite moves the existing project to <data>/workbench-backups/
     instead of deleting it (Desktop deletes it).

   The preflight never touches the existing project: it fetches into a
   throwaway shared bare clone and asks git merge-tree (git 2.38+).

   Several packages (copies of one project from different devices, say)
   are imported in the order given. The check runs them in that order too:
   each package is imported into a scratch copy of the project, so the next
   one is checked against the result. Under 'stop' the check assumes merge,
   since that is what the user will be choosing. A chunk that conflicts
   again on top of an unresolved conflict gets nested markers; Desktop's
   parser (render.js parseConflicts) unwraps those into one list of all the
   versions, so that is reported, not refused. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TTStudioImportModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  fpjson, Zipper, DateUtils,
  WBJson, WBGit, WBFiles, WBDataPaths, WBProject, WBImport;

resourcestring
  rsTitle = 'Import .tstudio package';
  rsDescription = 'Imports a BTT-Writer project package (.tstudio) into the ' +
    'BTT-Writer projects folder. Check first: it tells you whether the ' +
    'project is new or already here, and which chunks a merge would leave ' +
    'in conflict.';
  rsOptFile = 'Package files';
  rsOptFileHelp = 'The .tstudio file(s) to import, in order';
  rsOptOnExisting = 'If the project exists';
  rsOptOnExistingHelp = 'stop: change nothing; merge: combine with the ' +
    'existing project (as BTT-Writer does); overwrite: replace it (the old ' +
    'copy is kept in workbench-backups)';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';
  rsOptDryRun = 'Check only';
  rsOptDryRunHelp = 'Report what the import would do without changing anything';

  rsNoGit = 'git was not found. BTT-Writer projects are git repositories; ' +
    'install git first.';
  rsNoFile = 'File not found: %s';
  rsNotZip = 'Not a readable .tstudio package (%s)';
  rsUnsafeEntry = 'The package contains an unsafe path (%s). Nothing was imported.';
  rsNoPackageManifest = 'The package has no manifest.json.';
  rsBadPackageVersion = 'Unsupported package version %s.';
  rsEmptyPackage = 'The package contains no projects.';
  rsPackageInfo = 'Package: %s, made by %s on %s, %d project(s).';
  rsTargetDir = 'Projects folder: %s';
  rsTargetDirMissing = 'The projects folder does not exist yet; it will be created.';

  rsBadEntryPath = 'Project entry has an unsafe or missing path: "%s". Skipped.';
  rsEntryMissing = 'Project folder %s is listed but not in the package. Skipped.';
  rsMoveFailed = 'Could not move %s to %s. Nothing changed.';
  rsCheckInOrder = 'Checking %d packages in the order given, each as if the ' +
    'ones before it had been imported.';
  rsCheckAssumesMerge = 'Where a project already exists, the check assumes ' +
    'you will choose merge.';
  rsDuplicateFile = '%s is listed more than once; importing it once.';

{ One project entry of a package: check its path, then import it. }
function ImportEntry(const Ctx: TImportContext; Entry: TJSONObject): Integer;
var
  EntryPath, Src: string;
begin
  Result := 1;
  EntryPath := StrField(Entry, 'path');
  if not IsSafeName(EntryPath) then
  begin
    Ctx.Reporter.Error(Format(rsBadEntryPath, [EntryPath]));
    Exit;
  end;
  Src := Ctx.WorkRoot + PathDelim + EntryPath;
  if not DirectoryExists(Src) then
  begin
    Ctx.Reporter.Error(Format(rsEntryMissing, [EntryPath]));
    Exit;
  end;
  Result := ImportProject(Ctx, Src, EntryPath);
end;

{ --- module --- }

function TTStudioImportModule.Id: string;
begin
  Result := 'tstudio-import';
end;

function TTStudioImportModule.Title: string;
begin
  Result := rsTitle;
end;

function TTStudioImportModule.Description: string;
begin
  Result := rsDescription;
end;

function TTStudioImportModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    ListOptionDef('file', okFile, True, True, rsOptFile, rsOptFileHelp),
    ChoiceOptionDef('on-existing', ['stop', 'merge', 'overwrite'], 'stop',
      rsOptOnExisting, rsOptOnExistingHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp),
    OptionDef('dry-run', okFlag, False, False, rsOptDryRun, rsOptDryRunHelp)];
end;

function ExtractPackage(const PackageFile, WorkRoot: string; Reporter: TWBReporter): Boolean;
var
  Unzip: TUnZipper;
  I: Integer;
  Entry: string;
begin
  Result := False;
  Unzip := TUnZipper.Create;
  try
    Unzip.FileName := PackageFile;
    Unzip.OutputPath := WorkRoot;
    try
      Unzip.Examine;
      for I := 0 to Unzip.Entries.Count - 1 do
      begin
        Entry := Unzip.Entries[I].ArchiveFileName;
        if not IsSafeRelativePath(Entry) then
        begin
          Reporter.Error(Format(rsUnsafeEntry, [Entry]));
          Exit;
        end;
      end;
      Unzip.UnZipAllFiles;
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsNotZip, [E.Message]));
        Exit;
      end;
    end;
    Result := True;
  finally
    Unzip.Free;
  end;
end;

{ One package. Ctx.WorkRoot is this package's scratch folder. }
function ImportPackage(const Ctx: TImportContext; const PackageFile: string): Integer;
var
  Reporter: TWBReporter;
  Pkg: TJSONObject;
  Entries: TJSONData;
  Version: Integer;
  I, Code: Integer;
  Stamp: Int64;
  When, Generator: string;
begin
  Result := 1;
  Reporter := Ctx.Reporter;
  if not FileExists(PackageFile) then
  begin
    Reporter.Error(Format(rsNoFile, [PackageFile]));
    Exit;
  end;
  if not ForceDirectories(Ctx.WorkRoot) then
  begin
    Reporter.Error(Format(rsMoveFailed, [PackageFile, Ctx.WorkRoot]));
    Exit;
  end;
  Pkg := nil;
  try
    if not ExtractPackage(PackageFile, Ctx.WorkRoot, Reporter) then
      Exit;
    if not FileExists(Ctx.WorkRoot + PathDelim + 'manifest.json') then
    begin
      Reporter.Error(rsNoPackageManifest);
      Exit;
    end;
    try
      Pkg := ReadJSONObjectFile(Ctx.WorkRoot + PathDelim + 'manifest.json');
    except
      on E: Exception do
      begin
        Reporter.Error(Format(rsNotZip, [E.Message]));
        Exit;
      end;
    end;

    Version := StrToIntDef(StrField(Pkg, 'package_version'), 0);
    if Version = 1 then
      Entries := Pkg.Find('projects')
    else if Version = 2 then
      Entries := Pkg.Find('target_translations')
    else
    begin
      Reporter.Error(Format(rsBadPackageVersion, [StrField(Pkg, 'package_version')]));
      Exit;
    end;
    if (Entries = nil) or (Entries.JSONType <> jtArray) or (Entries.Count = 0) then
    begin
      Reporter.Error(rsEmptyPackage);
      Exit;
    end;

    Stamp := StrToInt64Def(StrField(Pkg, 'timestamp'), 0);
    if Stamp > 0 then
      When := FormatDateTime('yyyy-mm-dd hh:nn', UnixToDateTime(Stamp div 1000, False))
    else
      When := '?';
    Generator := StrField(Pkg, 'generator.name');
    if Generator = '' then
      Generator := '?';
    Reporter.Info(Format(rsPackageInfo, [ExtractFileName(PackageFile),
      Generator, When, Entries.Count]));

    Result := 0;
    for I := 0 to Entries.Count - 1 do
    begin
      if Entries.Items[I].JSONType <> jtObject then
      begin
        Reporter.Error(Format(rsBadEntryPath, ['?']));
        Result := 1;
        Continue;
      end;
      Code := ImportEntry(Ctx, TJSONObject(Entries.Items[I]));
      if Code > Result then
        Result := Code;
    end;
  finally
    Pkg.Free;
    DeleteTree(Ctx.WorkRoot);
  end;
end;

function TTStudioImportModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  Ctx: TImportContext;
  Files, Seen: TStringArray;
  F, SessionRoot: string;
  I, Code: Integer;
begin
  Result := 1;
  Ctx.Reporter := Reporter;
  Ctx.OnExisting := OptionValue(Self, Options, 'on-existing');
  Ctx.DryRun := OptionIsSet(Options, 'dry-run');
  if Options.Values['target-dir'] <> '' then
    Ctx.TargetDir := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    Ctx.TargetDir := TargetTranslationsPath;
  { Scratch and backup dirs sit next to the projects folder, on the same
    disk, so moving a project into place is a rename. }
  SessionRoot := ImportSessionRoot(Ctx.TargetDir);
  Ctx.SimRoot := SessionRoot + PathDelim + 'projects';
  Ctx.BackupRoot := ImportBackupRoot(Ctx.TargetDir);

  if not GitAvailable then
  begin
    Reporter.Error(rsNoGit);
    Exit;
  end;

  Files := nil;
  Seen := nil;
  for F in OptionValues(Options, 'file') do
    if Contains(Seen, ExpandFileName(F)) then
      Reporter.Warn(Format(rsDuplicateFile, [ExtractFileName(F)]))
    else
    begin
      Seen := Concat(Seen, [ExpandFileName(F)]);
      Files := Concat(Files, [ExpandFileName(F)]);
    end;
  Ctx.Simulate := Ctx.DryRun and (Length(Files) > 1);

  Reporter.Info(Format(rsTargetDir, [ExcludeTrailingPathDelimiter(Ctx.TargetDir)]));
  if not DirectoryExists(Ctx.TargetDir) and Ctx.DryRun then
    Reporter.Info(rsTargetDirMissing);
  if Ctx.Simulate then
  begin
    Reporter.Info(Format(rsCheckInOrder, [Length(Files)]));
    if Ctx.OnExisting = 'stop' then
      Reporter.Info(rsCheckAssumesMerge);
  end;

  Result := 0;
  try
    for I := 0 to High(Files) do
    begin
      if Length(Files) > 1 then
        Reporter.Info('');
      Ctx.SourceLabel := ExtractFileName(Files[I]);
      Ctx.WorkRoot := SessionRoot + PathDelim + 'package-' + IntToStr(I + 1);
      Code := ImportPackage(Ctx, Files[I]);
      if Code > Result then
        Result := Code;
    end;
  finally
    DeleteTree(SessionRoot);
  end;
end;

initialization
  RegisterModule(TTStudioImportModule.Create);

end.
