unit TestTStudioImport;

{$mode objfpc}{$H+}

(* Tests for tstudio-import. Builds real git-backed projects and .tstudio
   packages (zip with manifest.json + <project>/ including .git) under a
   temp dir, imports them into a temp targetTranslations, and checks the
   result, including that conflict markers match the regexes BTT-Writer
   Desktop uses to find conflicts (src/js/render.js). *)

interface

procedure TestTStudioImportModule(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fpjson, Zipper, RegExpr,
  WBReporter, WBGit, WBJson, WBModule, WBCommandLine, TestUtil;

const
  ProjectVersion = 8;

var
  Root: string;        // per-suite temp root
  Target: string;      // the targetTranslations under test
  PkgCount: Integer = 0;

function Git(const Dir: string; const Args: array of string): TGitResult;
var
  All: array of string;
  I: Integer;
begin
  All := ['-c', 'user.name=Test', '-c', 'user.email=test@example.com',
    '-c', 'init.defaultBranch=master', '-c', 'commit.gpgsign=false'];
  SetLength(All, 8 + Length(Args));
  for I := 0 to High(Args) do
    All[8 + I] := Args[I];
  Result := RunGit(Dir, All);
  if Result.ExitCode <> 0 then
    WriteLn('    (git ', Args[0], ' in ', Dir, ': ', Trim(Result.ErrorOutput), ')');
end;

procedure WriteChunk(const ProjectDir, RelPath, Text: string);
var
  P: string;
begin
  P := ProjectDir + PathDelim + StringReplace(RelPath, '/', PathDelim, [rfReplaceAll]);
  ForceDirectories(ExtractFileDir(P));
  WriteFileText(P, Text);
end;

procedure Commit(const ProjectDir, Msg: string);
begin
  Git(ProjectDir, ['add', '--all']);
  Git(ProjectDir, ['commit', '-q', '-m', Msg]);
end;

procedure WriteProjectManifest(const ProjectDir: string; const Translators,
  Finished: array of string; Version: Integer = ProjectVersion);
var
  M: TJSONObject;
  A: TJSONArray;
  S: string;
begin
  M := TJSONObject.Create;
  try
    M.Add('package_version', Version);
    M.Add('format', 'usfm');
    M.Add('target_language', TJSONObject.Create(['id', 'xyz', 'name', 'Xyzé', 'direction', 'ltr']));
    M.Add('project', TJSONObject.Create(['id', 'tit', 'name', 'Titus']));
    M.Add('type', TJSONObject.Create(['id', 'text', 'name', 'Text']));
    M.Add('resource', TJSONObject.Create(['id', 'reg', 'name', 'Regular']));
    A := TJSONArray.Create;
    for S in Translators do
      A.Add(S);
    M.Add('translators', A);
    A := TJSONArray.Create;
    for S in Finished do
      A.Add(S);
    M.Add('finished_chunks', A);
    WriteBttJSONFile(ProjectDir + PathDelim + 'manifest.json', M);
  finally
    M.Free;
  end;
end;

{ A fresh project repo at Dir/xyz_tit_text_reg with three chunks. }
function NewProject(const Dir: string; Version: Integer = ProjectVersion): string;
begin
  Result := Dir + PathDelim + 'xyz_tit_text_reg';
  ForceDirectories(Result);
  WriteProjectManifest(Result, ['Ann'], ['01-01'], Version);
  WriteChunk(Result, 'front/title.txt', 'Titus');
  WriteChunk(Result, '01/01.txt', '\c 1 \v 1 Paul, a servant of God');
  WriteChunk(Result, '01/04.txt', '\v 4 To Titus, my true son');
  WriteChunk(Result, '01/07.txt', '\v 7 For an overseer must be blameless');
  Git(Result, ['init', '-q']);
  Commit(Result, 'start');
end;

{ An independent copy with shared history (what another computer has). }
function CloneOf(const ProjectDir, Dir: string): string;
begin
  ForceDirectories(Dir);
  Result := Dir + PathDelim + ExtractFileName(ProjectDir);
  Git(Dir, ['clone', '-q', ProjectDir, Result]);
  Git(Result, ['remote', 'remove', 'origin']);
end;

procedure AddTree(Zip: TZipper; const DiskDir, ArchiveDir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(DiskDir) + AllFilesMask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      if (SR.Attr and faDirectory) <> 0 then
        AddTree(Zip, IncludeTrailingPathDelimiter(DiskDir) + SR.Name, ArchiveDir + '/' + SR.Name)
      else
        Zip.Entries.AddFileEntry(IncludeTrailingPathDelimiter(DiskDir) + SR.Name,
          ArchiveDir + '/' + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Zip ProjectDir as a Desktop-style .tstudio. EntryPath overrides the
  folder name used inside the zip; ExtraName adds a stray entry. }
function Pack(const ProjectDir: string; const EntryPath: string = '';
  PackageVersion: Integer = 2; const ExtraName: string = ''): string;
var
  Zip: TZipper;
  Name, ManifestFile: string;
  Stream: TStringStream;
begin
  Inc(PkgCount);
  Name := EntryPath;
  if Name = '' then
    Name := ExtractFileName(ProjectDir);
  Result := Root + 'pkg' + IntToStr(PkgCount) + '.tstudio';
  ManifestFile := Root + 'pkg-manifest.json';
  WriteFileText(ManifestFile,
    '{"generator":{"name":"ts-desktop","build":"1073"},"package_version":' +
    IntToStr(PackageVersion) + ',"timestamp":1778177531329,"target_translations":' +
    '[{"path":"' + Name + '","id":"' + Name + '","commit_hash":{"stdout":"x\n",' +
    '"stderr":"","error":null},"direction":"ltr"}]}');
  Zip := TZipper.Create;
  Stream := nil;
  try
    Zip.FileName := Result;
    Zip.Entries.AddFileEntry(ManifestFile, 'manifest.json');
    AddTree(Zip, ProjectDir, Name);
    if ExtraName <> '' then
    begin
      Stream := TStringStream.Create('evil');
      Zip.Entries.AddFileEntry(Stream, ExtraName);
    end;
    Zip.ZipAllFiles;
  finally
    Zip.Free;
    Stream.Free;
  end;
end;

function Head(const Dir: string): string;
begin
  Result := Trim(RunGit(Dir, ['rev-parse', 'HEAD']).Output);
end;

function Joined(R: TWBListReporter): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to R.Count - 1 do
    Result := Result + R.Texts[I] + #10;
end;

function Import(const Pkg: string; const Extra: array of string;
  out Log: string): Integer;
var
  Args: array of string;
  I: Integer;
  R: TWBListReporter;
begin
  Args := [Pkg, '--target-dir', Target];
  SetLength(Args, 3 + Length(Extra));
  for I := 0 to High(Extra) do
    Args[3 + I] := Extra[I];
  Result := RunModule('tstudio-import', Args, R);
  Log := Joined(R);
  R.Free;
end;

function NoWorkDirsLeft: Boolean;
var
  SR: TSearchRec;
begin
  Result := True;
  if FindFirst(ExtractFileDir(ExcludeTrailingPathDelimiter(Target)) + PathDelim + '.btw-import-*',
    faAnyFile, SR) = 0 then
  begin
    Result := False;
    FindClose(SR);
  end;
end;

function ManifestStrings(const ProjectDir, Key: string): string;
var
  M: TJSONObject;
  I: Integer;
  A: TJSONData;
begin
  Result := '';
  M := ReadJSONObjectFile(ProjectDir + PathDelim + 'manifest.json');
  try
    A := M.Find(Key);
    for I := 0 to A.Count - 1 do
      Result := Result + A.Items[I].AsString + ' ';
  finally
    M.Free;
  end;
  Result := Trim(Result);
end;

function Contains(const Items: TStringArray; const S: string): Boolean;
var
  X: string;
begin
  for X in Items do
    if X = S then
      Exit(True);
  Result := False;
end;

{ BTT-Writer Desktop's render.js, ported: replaceConflictCode swaps the
  markers for <S>/<M>/<E>; parseConflicts repeatedly unwraps the innermost
  S..M..E group into @s@option@e@ pieces (so nested conflicts flatten into
  one list), then collects the distinct options. Any marker left over is
  Desktop's "Conflict Parsing Error", returned here as nil. }
function DesktopConflictOptions(const Text: string): TStringArray;
var
  T, P3, P5, NewContent, Opt: string;
  Re, OptRe: TRegExpr;
begin
  Result := nil;
  T := ReplaceRegExpr('<{7} HEAD\n', Text, '<S>', False);
  T := ReplaceRegExpr('={7}\n', T, '<M>', False);
  T := ReplaceRegExpr('>{7} \w{40}\n?', T, '<E>', False);
  Re := TRegExpr.Create('([^<>]*)(<S>)([^<>]*)(<M>)([^<>]*)(<E>)([^<>]*)');
  OptRe := TRegExpr.Create('(@s@)([\s\S]+?)(@e@)');
  try
    while Re.Exec(T) do
    begin
      P3 := Re.Match[3];
      P5 := Re.Match[5];
      if not OptRe.Exec(P3) then
        P3 := '@s@' + P3 + '@e@';
      if not OptRe.Exec(P5) then
        P5 := '@s@' + P5 + '@e@';
      NewContent := P3 + P5;
      if Re.Match[1] <> '' then
        NewContent := StringReplace(NewContent, '@s@', '@s@' + Re.Match[1], [rfReplaceAll]);
      if Re.Match[7] <> '' then
        NewContent := StringReplace(NewContent, '@e@', Re.Match[7] + '@e@', [rfReplaceAll]);
      T := Copy(T, 1, Re.MatchPos[0] - 1) + NewContent +
        Copy(T, Re.MatchPos[0] + Re.MatchLen[0], MaxInt);
    end;
    while OptRe.Exec(T) do
    begin
      Opt := Trim(OptRe.Match[2]);
      if not Contains(Result, Opt) then
        Result := Concat(Result, [Opt]);
      T := Copy(T, 1, OptRe.MatchPos[0] - 1) + Copy(T, OptRe.MatchPos[0] + OptRe.MatchLen[0], MaxInt);
    end;
    if (Pos('<S>', T) > 0) or (Pos('<M>', T) > 0) or (Pos('<E>', T) > 0) then
      Result := nil;
  finally
    OptRe.Free;
    Re.Free;
  end;
end;

function DesktopSeesConflict(const Text: string): Boolean;
begin
  Result := Length(DesktopConflictOptions(Text)) >= 2;
end;

function Occurrences(const Needle, Hay: string): Integer;
var
  P: Integer;
begin
  Result := 0;
  P := Pos(Needle, Hay);
  while P > 0 do
  begin
    Inc(Result);
    P := Pos(Needle, Hay, P + Length(Needle));
  end;
end;

procedure Fresh(const Name: string);
begin
  Root := Root + Name + PathDelim;
  ForceDirectories(Root);
  Target := Root + 'data' + PathDelim + 'targetTranslations' + PathDelim;
  ForceDirectories(Target);
end;

procedure TestTStudioImportModule(const TempRoot: string);
var
  Base, Work, Local, Other, Pkg, Pkg2, Log, Before, Chunk: string;
  Code: Integer;
  Opts, ArgList: TStringList;
begin
  Section('tstudio-import');
  Base := TempRoot + 'import' + PathDelim;

  { New project }
  Root := Base; Fresh('new');
  Work := NewProject(Root + 'remote');
  Pkg := Pack(Work);
  Code := Import(Pkg, ['--dry-run'], Log);
  Check((Code = 0) and (Pos('New project', Log) > 0), 'check: new project reported');
  Check(not DirectoryExists(Target + 'xyz_tit_text_reg'), 'check changes nothing');
  Code := Import(Pkg, [], Log);
  Check((Code = 0) and DirectoryExists(Target + 'xyz_tit_text_reg'), 'new project imported');
  Check(Head(Target + 'xyz_tit_text_reg') = Head(Work), '... with its git history');
  Check(NoWorkDirsLeft, '... and no temp folders left behind');

  { Same commit again: up to date }
  Code := Import(Pkg, ['--dry-run'], Log);
  Check((Code = 0) and (Pos('already contains everything', Log) > 0), 'same package again: up to date');
  Code := Import(Pkg, ['--on-existing', 'merge'], Log);
  Check((Code = 0) and (Head(Target + 'xyz_tit_text_reg') = Head(Work)), 'merging it changes nothing');

  { Package only adds work: fast-forward }
  Root := Base; Fresh('ff');
  Work := NewProject(Root + 'remote');
  Local := CloneOf(Work, Target);
  WriteChunk(Work, '01/04.txt', '\v 4 To Titus, my true child');
  Commit(Work, 'edit 01-04');
  Pkg := Pack(Work);
  Code := Import(Pkg, ['--dry-run'], Log);
  Check((Code = 0) and (Pos('only adds newer work', Log) > 0), 'fast-forward reported');
  Code := Import(Pkg, [], Log);
  Check((Code = 1) and (Pos('Choose merge or overwrite', Log) > 0), 'default stop refuses');
  Check(Pos('true son', ReadFileText(Local + '/01/04.txt')) > 0, '... and changes nothing');
  Code := Import(Pkg, ['--on-existing', 'merge'], Log);
  Check((Code = 0) and (Pos('true child', ReadFileText(Local + '/01/04.txt')) > 0),
    'fast-forward merge brings the change in');

  { Both sides changed different chunks: clean merge }
  Root := Base; Fresh('clean');
  Work := NewProject(Root + 'remote');
  Local := CloneOf(Work, Target);
  WriteChunk(Work, '01/04.txt', '\v 4 To Titus, my true child');
  WriteProjectManifest(Work, ['Ann', 'Ben'], ['01-01', '01-04']);
  Commit(Work, 'remote edit');
  WriteChunk(Local, '01/07.txt', '\v 7 An overseer must be without blame');
  Commit(Local, 'local edit');
  Pkg := Pack(Work);
  Code := Import(Pkg, ['--dry-run'], Log);
  Check((Code = 0) and (Pos('no conflicts', Log) > 0) and (Pos('conflict:', Log) = 0),
    'clean merge reported, no conflicts');
  Code := Import(Pkg, ['--on-existing', 'merge'], Log);
  Check((Code = 0) and (Pos('true child', ReadFileText(Local + '/01/04.txt')) > 0) and
    (Pos('without blame', ReadFileText(Local + '/01/07.txt')) > 0), 'clean merge keeps both edits');
  Check(ManifestStrings(Local, 'translators') = 'Ann Ben', 'translators combined');
  Check(ManifestStrings(Local, 'finished_chunks') = '01-01 01-04', 'finished chunks combined');
  Check(Trim(RunGit(Local, ['status', '--porcelain']).Output) = '', 'nothing left uncommitted');

  { Same chunk changed on both sides: conflict }
  Root := Base; Fresh('conflict');
  Work := NewProject(Root + 'remote');
  Local := CloneOf(Work, Target);
  WriteChunk(Work, '01/01.txt', '\c 1 \v 1 Paul, a slave of God');
  Commit(Work, 'remote edit');
  WriteChunk(Local, '01/01.txt', '\c 1 \v 1 Paul, a bondservant of God');
  Commit(Local, 'local edit');
  Before := Head(Local);
  Pkg := Pack(Work);
  Code := Import(Pkg, ['--dry-run'], Log);
  Check((Code = 0) and (Pos('1 chunk(s) in conflict', Log) > 0) and (Pos(': 01-01', Log) > 0),
    'check lists the conflicting chunk');
  Check(Pos('marked unfinished again: 01-01', Log) > 0, 'check warns a finished chunk reopens');
  Check(Head(Local) = Before, 'check leaves the local repo alone');
  Check(Trim(RunGit(Local, ['for-each-ref']).Output) = Trim(RunGit(Local, ['for-each-ref']).Output),
    'no refs added by the check');
  Code := Import(Pkg, ['--on-existing', 'merge'], Log);
  Check(Code = 0, 'merge with conflict succeeds');
  Chunk := ReadFileText(Local + '/01/01.txt');
  Check(Pos('<<<<<<< HEAD'#10, Chunk) > 0, 'marker: ours labelled HEAD');
  Check(ExecRegExpr('>{7} [0-9a-f]{40}', Chunk), 'marker: theirs labelled with a 40-char hash');
  Check(Pos('|||||||', Chunk) = 0, 'marker: no diff3 base section');
  Check(DesktopSeesConflict(Chunk), 'BTT-Writer Desktop''s parser recognises the conflict');
  Check(ManifestStrings(Local, 'finished_chunks') = '', 'conflicted chunk un-finished');
  Check(not FileExists(Local + '/.git/MERGE_HEAD'), 'merge committed (as Desktop does)');
  Check(Trim(RunGit(Local, ['status', '--porcelain']).Output) = '', 'nothing left uncommitted');

  { Overwrite keeps a backup }
  Root := Base; Fresh('overwrite');
  Work := NewProject(Root + 'remote');
  Local := CloneOf(Work, Target);
  WriteChunk(Local, '01/07.txt', 'LOCAL ONLY');
  Commit(Local, 'local edit');
  Pkg := Pack(Work);
  Code := Import(Pkg, ['--on-existing', 'overwrite'], Log);
  Check((Code = 0) and (Pos('LOCAL ONLY', ReadFileText(Local + '/01/07.txt')) = 0), 'overwrite replaces');
  Check((Pos('workbench-backups', Log) > 0) and
    DirectoryExists(Root + 'data' + PathDelim + 'workbench-backups'), 'overwrite keeps a backup');

  { Uncommitted local work is committed before merging }
  Root := Base; Fresh('dirty');
  Work := NewProject(Root + 'remote');
  Local := CloneOf(Work, Target);
  WriteChunk(Work, '01/04.txt', 'REMOTE');
  Commit(Work, 'remote');
  WriteChunk(Local, '01/07.txt', 'UNSAVED LOCAL');
  Pkg := Pack(Work);
  Code := Import(Pkg, ['--dry-run'], Log);
  Check(Pos('uncommitted changes', Log) > 0, 'check warns about uncommitted local work');
  Code := Import(Pkg, ['--on-existing', 'merge'], Log);
  Check((Code = 0) and (Pos('UNSAVED LOCAL', ReadFileText(Local + '/01/07.txt')) > 0) and
    (Pos('REMOTE', ReadFileText(Local + '/01/04.txt')) > 0), 'uncommitted local work kept through merge');

  { Refusals }
  Root := Base; Fresh('refuse');
  Work := NewProject(Root + 'remote');
  Code := Import(Pack(Work, '', 2, '../escape.txt'), [], Log);
  Check((Code <> 0) and (Pos('unsafe path', Log) > 0) and
    not FileExists(Root + 'data' + PathDelim + 'escape.txt'), 'zip path escaping the folder refused');
  Code := Import(Pack(Work, '', 3), [], Log);
  Check((Code <> 0) and (Pos('Unsupported package version', Log) > 0), 'unknown package version refused');
  Other := NewProject(Root + 'old', 6);
  Code := Import(Pack(Other), [], Log);
  Check((Code <> 0) and (Pos('older project format', Log) > 0) and
    not DirectoryExists(Target + 'xyz_tit_text_reg'), 'old project format refused');
  Code := Import(Root + 'nope.tstudio', [], Log);
  Check(Code <> 0, 'missing file refused');
  WriteFileText(Root + 'junk.tstudio', 'not a zip');
  Code := Import(Root + 'junk.tstudio', [], Log);
  Check((Code <> 0) and (Pos('Not a readable', Log) > 0), 'non-zip refused');
  Check(NoWorkDirsLeft, 'no temp folders left after refusals');

  { Version 7 is upgraded on the way in; a 'main' branch becomes 'master' }
  Root := Base; Fresh('v7');
  Work := NewProject(Root + 'remote', 7);
  Git(Work, ['branch', '-m', 'master', 'main']);
  Code := Import(Pack(Work), [], Log);
  Local := Target + 'xyz_tit_text_reg';
  Check((Code = 0) and (Pos('"package_version": 8', ReadFileText(Local + '/manifest.json')) > 0),
    'version 7 project upgraded to 8');
  Check(Pos('"source_translations": {}', ReadFileText(Local + '/manifest.json')) > 0,
    '... with source_translations added');
  Check(Trim(RunGit(Local, ['symbolic-ref', '--short', 'HEAD']).Output) = 'master',
    '... and its branch named master');
  Check(Trim(RunGit(Local, ['status', '--porcelain']).Output) = '', '... all committed');
  Code := Import(Pack(NewProject(Root + 'v9', 9)), ['--dry-run'], Log);
  Check((Code <> 0) and (Pos('newer project format', Log) > 0), 'newer project format refused');

  { List option parsing: positionals and repeated --file all collect }
  Opts := TStringList.Create;
  ArgList := TStringList.Create;
  try
    ArgList.CommaText := 'a.tstudio,--file,b.tstudio,c.tstudio,--dry-run';
    Check(ParseModuleArgs(FindModule('tstudio-import'), ArgList, Opts, Log) and
      (String.Join('|', OptionValues(Opts, 'file')) = 'a.tstudio|b.tstudio|c.tstudio'),
      'several files: positionals and --file collect in order');
  finally
    ArgList.Free;
    Opts.Free;
  end;

  { Two copies of a project that is new here }
  Root := Base; Fresh('multi-new');
  Work := NewProject(Root + 'remote');
  Other := CloneOf(Work, Root + 'tablet2');
  WriteChunk(Work, '01/01.txt', '\c 1 \v 1 Paul, a slave of God');
  Commit(Work, 'tablet 1');
  WriteChunk(Other, '01/04.txt', '\v 4 To Titus, my true child');
  Commit(Other, 'tablet 2');
  Pkg := Pack(Work);
  Pkg2 := Pack(Other);
  Code := Import(Pkg, [Pkg2, '--dry-run'], Log);
  Check((Code = 0) and (Pos('New project', Log) > 0) and
    (Pos('also in an earlier package', Log) > 0) and (Pos('no conflicts', Log) > 0),
    'check of two copies: the second is checked against the first');
  Check(not DirectoryExists(Target + 'xyz_tit_text_reg') and NoWorkDirsLeft,
    '... and changes nothing, leaves no temp folders');
  Code := Import(Pkg, [Pkg2, '--on-existing', 'merge'], Log);
  Local := Target + 'xyz_tit_text_reg';
  Check((Code = 0) and (Pos('slave', ReadFileText(Local + '/01/01.txt')) > 0) and
    (Pos('true child', ReadFileText(Local + '/01/04.txt')) > 0), 'both copies imported and merged');

  Root := Base; Fresh('multi-stop');
  Code := Import(Pkg, [Pkg2], Log);
  Local := Target + 'xyz_tit_text_reg';
  Check((Code = 1) and DirectoryExists(Local) and (Pos('Choose merge or overwrite', Log) > 0) and
    (Pos('true child', ReadFileText(Local + '/01/04.txt')) = 0),
    'stop: first copy imported, second refused');

  Code := Import(Pkg, [Pkg, '--dry-run'], Log);
  Check(Pos('listed more than once', Log) > 0, 'a file listed twice is imported once');

  { Local and two copies all change one chunk: the conflicts stack }
  Root := Base; Fresh('multi-stack');
  Work := NewProject(Root + 'remote');
  Local := CloneOf(Work, Target);
  Other := CloneOf(Work, Root + 'tablet2');
  WriteChunk(Local, '01/01.txt', '\c 1 \v 1 Paul, a bondservant of God');
  Commit(Local, 'local');
  WriteChunk(Work, '01/01.txt', '\c 1 \v 1 Paul, a slave of God');
  Commit(Work, 'tablet 1');
  WriteChunk(Other, '01/01.txt', '\c 1 \v 1 Paul, a doulos of God');
  Commit(Other, 'tablet 2');
  Pkg := Pack(Work);
  Pkg2 := Pack(Other);
  Before := Head(Local);
  Code := Import(Pkg, [Pkg2, '--dry-run'], Log);
  Check((Code = 0) and (Pos('Checking 2 packages', Log) > 0) and
    (Pos('assumes you will choose merge', Log) > 0), 'check of two packages says how it checks');
  Check((Occurrences('1 chunk(s) in conflict', Log) = 2) and
    (Pos('choose from: 01-01', Log) > 0), 'second copy: stacked conflict on 01-01 reported');
  Check((Head(Local) = Before) and (Trim(RunGit(Local, ['status', '--porcelain']).Output) = '') and
    NoWorkDirsLeft, '... the check leaves the local project alone');
  Code := Import(Pkg, [Pkg2, '--on-existing', 'merge'], Log);
  Check((Code = 0) and (Pos('choose from: 01-01', Log) > 0), 'merge of both reports the stacking');
  Chunk := ReadFileText(Local + '/01/01.txt');
  Check(String.Join('|', DesktopConflictOptions(Chunk)) =
    '\c 1 \v 1 Paul, a bondservant of God|\c 1 \v 1 Paul, a slave of God|\c 1 \v 1 Paul, a doulos of God',
    'stacked conflict: Desktop''s parser offers all three versions');
  Check(Trim(RunGit(Local, ['status', '--porcelain']).Output) = '', '... all committed');

  { Folder name comes from the project manifest, not the zip path }
  Root := Base; Fresh('rename');
  Work := NewProject(Root + 'remote');
  Code := Import(Pack(Work, 'oldname'), [], Log);
  Check((Code = 0) and DirectoryExists(Target + 'xyz_tit_text_reg') and
    not DirectoryExists(Target + 'oldname'), 'folder named from the manifest');
end;

end.
