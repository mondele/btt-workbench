unit WBDataPaths;

{$mode objfpc}{$H+}

{ Where BTT-Writer keeps its data (same rules as btt-writer-two's
  DataPaths.pas and BTT-Writer Desktop):
    Linux    ~/.config/BTT-Writer/
    macOS    ~/Library/Application Support/BTT-Writer/
    Windows  %LOCALAPPDATA%\BTT-Writer\
  BTT_WRITER_DATA overrides all of them (tests, portable setups), then the
  saved setting (WBSettings, "btw settings --data-dir").

  Source texts ("resource containers", <lang>_<book>_<resource>) are in
  <data>/library/resource_containers/ once BTT-Writer has used them.
  BTT-Writer also ships thousands as compressed .tsrc files inside its
  install folder. BundledSourcesPath finds that folder: BTW_BUNDLED_SOURCES,
  else the saved install setting ("btw settings --btt-writer"), else an
  install found on this computer (FindBttWriterInstalls). Only the Linux
  locations have been checked against a real install; the Windows and
  macOS ones follow the Electron app layout. }

interface

uses
  SysUtils;

function BttWriterDataPath: string;
{ The data folder BTT-Writer itself would use, ignoring the setting. }
function DefaultBttWriterDataPath: string;
function TargetTranslationsPath: string;
{ <data>/library/resource_containers/ for the data folder holding
  TargetDir (so a --target-dir elsewhere brings its own library). }
function LibrarySourcesPath(const TargetDir: string): string;
{ BTT-Writer's language database for the data folder holding TargetDir:
  <data>/library/index.sqlite, which BTT-Writer keeps up to date, else the
  copy bundled with BTT-Writer; '' if neither exists. }
function LanguageIndexPath(const TargetDir: string): string;
{ BTT-Writer's bundled .tsrc folder, or '' if none is found. }
function BundledSourcesPath: string;
{ The bundled .tsrc folder of the BTT-Writer at Path, which may be the
  program file, its folder, a macOS .app, or the .tsrc folder itself;
  '' if there are no .tsrc files there. }
function BundledSourcesIn(const Path: string): string;
{ .tsrc folders of BTT-Writer installs found on this computer: the usual
  install folders, the btt-writer command on PATH, and (Linux) the program
  that BTT-Writer's desktop entries start. }
function FindBttWriterInstalls: TStringArray;

var
  { Set by tests so results do not depend on an installed BTT-Writer. }
  BundledSourcesOverride: string = '';

implementation

uses
  Classes, {$IFDEF UNIX}BaseUnix,{$ENDIF} WBSettings;

const
  Inside = 'resources' + PathDelim + 'app' + PathDelim + 'src' + PathDelim +
    'index' + PathDelim + 'resource_containers';

function BttWriterDataPath: string;
begin
  Result := Trim(GetEnvironmentVariable('BTT_WRITER_DATA'));
  if Result = '' then
    Result := GetSetting(SetBttWriterData);
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(Result));
  Result := DefaultBttWriterDataPath;
end;

function DefaultBttWriterDataPath: string;
var
  Base: string;
begin
  {$IFDEF WINDOWS}
  Base := Trim(GetEnvironmentVariable('LOCALAPPDATA'));
  if Base = '' then
    Base := Trim(GetEnvironmentVariable('APPDATA'));
  Result := IncludeTrailingPathDelimiter(Base) + 'BTT-Writer' + PathDelim;
  {$ELSE}
  Base := Trim(GetEnvironmentVariable('HOME'));
  {$IFDEF DARWIN}
  Result := IncludeTrailingPathDelimiter(Base) + 'Library' + PathDelim +
    'Application Support' + PathDelim + 'BTT-Writer' + PathDelim;
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(Base) + '.config' + PathDelim +
    'BTT-Writer' + PathDelim;
  {$ENDIF}
  {$ENDIF}
end;

function TargetTranslationsPath: string;
begin
  Result := BttWriterDataPath + 'targetTranslations' + PathDelim;
end;

function LibrarySourcesPath(const TargetDir: string): string;
begin
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(TargetDir)) + 'library' +
    PathDelim + 'resource_containers' + PathDelim;
end;

function LanguageIndexPath(const TargetDir: string): string;
var
  Bundled: string;
begin
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(TargetDir)) + 'library' +
    PathDelim + 'index.sqlite';
  if FileExists(Result) then
    Exit;
  Bundled := BundledSourcesPath;
  Result := '';
  if Bundled <> '' then
  begin
    Result := ExtractFilePath(ExcludeTrailingPathDelimiter(Bundled)) + 'index.sqlite';
    if not FileExists(Result) then
      Result := '';
  end;
end;

function HasTsrc(const Dir: string): Boolean;
var
  SR: TSearchRec;
begin
  Result := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.tsrc', faAnyFile, SR) = 0;
  FindClose(SR);
end;

function BundledSourcesIn(const Path: string): string;
const
  Suffixes: array of string = ('', Inside,
    'Contents' + PathDelim + Inside,
    'app' + PathDelim + 'src' + PathDelim + 'index' + PathDelim + 'resource_containers',
    'src' + PathDelim + 'index' + PathDelim + 'resource_containers',
    'index' + PathDelim + 'resource_containers');
var
  P, S, Dir: string;
begin
  Result := '';
  if Trim(Path) = '' then
    Exit;
  P := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  if FileExists(P) and not DirectoryExists(P) then
    P := ExtractFileDir(P);
  for S in Suffixes do
  begin
    Dir := IncludeTrailingPathDelimiter(P);
    if S <> '' then
      Dir := Dir + S + PathDelim;
    if HasTsrc(Dir) then
      Exit(Dir);
  end;
end;

{ The path with every symbolic link in it followed, so the same install
  reached through /lib and /usr/lib is recognised as one. }
function ResolveLinks(const Path: string): string;
{$IFDEF UNIX}
var
  Parts: TStringArray;
  Done, Target: string;
  I, Hops: Integer;
{$ENDIF}
begin
  Result := ExpandFileName(Path);
  {$IFDEF UNIX}
  Hops := 0;
  repeat
    Result := ExcludeTrailingPathDelimiter(Result);
    Parts := Result.Split([PathDelim]);
    Done := '';
    Target := '';
    for I := 1 to High(Parts) do
    begin
      if Parts[I] = '' then
        Continue;
      Target := fpReadLink(Done + PathDelim + Parts[I]);
      if Target <> '' then
      begin
        if Target[1] <> PathDelim then
          Target := Done + PathDelim + Target;
        { Rest of the path after the link. }
        Result := ExpandFileName(Target + PathDelim +
          String.Join(PathDelim, Copy(Parts, I + 1, MaxInt)));
        Result := ExcludeTrailingPathDelimiter(Result);
        Break;
      end;
      Done := Done + PathDelim + Parts[I];
    end;
    Inc(Hops);
  until (Target = '') or (Hops > 40);
  {$ENDIF}
end;

{ Name looked up on PATH, '' if not there. }
function OnPath(const Name: string): string;
var
  Dir: string;
begin
  for Dir in GetEnvironmentVariable('PATH').Split([PathSeparator]) do
    if (Dir <> '') and FileExists(IncludeTrailingPathDelimiter(Dir) + Name) then
      Exit(ResolveLinks(IncludeTrailingPathDelimiter(Dir) + Name));
  Result := '';
end;

{$IFDEF LINUX}
{ Programs started by desktop entries that look like BTT-Writer's. }
function DesktopEntryPrograms: TStringArray;
var
  Dirs: TStringArray;
  Dir, Line, Exec, Low: string;
  SR: TSearchRec;
  L: TStringList;
  IsBttWriter: Boolean;
begin
  Result := nil;
  Dir := Trim(GetEnvironmentVariable('XDG_DATA_HOME'));
  if Dir = '' then
    Dir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) +
      '.local' + PathDelim + 'share';
  Dirs := [Dir];
  Dir := Trim(GetEnvironmentVariable('XDG_DATA_DIRS'));
  if Dir = '' then
    Dir := '/usr/local/share:/usr/share';
  Dirs := Concat(Dirs, Dir.Split([':']));
  L := TStringList.Create;
  try
    for Dir in Dirs do
    begin
      if (Dir = '') or (FindFirst(IncludeTrailingPathDelimiter(Dir) + 'applications' +
        PathDelim + '*.desktop', faAnyFile, SR) <> 0) then
        Continue;
      try
        repeat
          L.LoadFromFile(IncludeTrailingPathDelimiter(Dir) + 'applications' +
            PathDelim + SR.Name);
          IsBttWriter := False;
          Exec := '';
          for Line in L do
          begin
            Low := LowerCase(Line);
            if ((Copy(Low, 1, 5) = 'name=') or (Copy(Low, 1, 5) = 'exec=')) and
               ((Pos('btt-writer', Low) > 0) or (Pos('btt writer', Low) > 0) or
                (Pos('bttwriter', Low) > 0)) and (Pos('workbench', Low) = 0) then
              IsBttWriter := True;
            if (Exec = '') and (Copy(Low, 1, 5) = 'exec=') then
              Exec := Trim(Copy(Line, 6, MaxInt));
          end;
          if not IsBttWriter or (Exec = '') then
            Continue;
          { First word of Exec, unquoted. }
          if Exec[1] = '"' then
            Exec := Copy(Exec, 2, Pos('"', Copy(Exec, 2, MaxInt)) - 1)
          else if Pos(' ', Exec) > 0 then
            Exec := Copy(Exec, 1, Pos(' ', Exec) - 1);
          if Pos(PathDelim, Exec) = 0 then
            Exec := OnPath(Exec)
          else
            Exec := ResolveLinks(Exec);
          if Exec <> '' then
            Result := Concat(Result, [Exec]);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
  finally
    L.Free;
  end;
end;
{$ENDIF}

function FindBttWriterInstalls: TStringArray;
var
  Candidates: TStringArray;
  C, Dir, Home: string;
  I: Integer;
  Known: Boolean;
begin
  Home := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'));
  {$IFDEF WINDOWS}
  Candidates := [
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) +
      'Programs' + PathDelim + 'BTT-Writer',
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('ProgramFiles')) + 'BTT-Writer',
    IncludeTrailingPathDelimiter(GetEnvironmentVariable('ProgramFiles(x86)')) + 'BTT-Writer',
    OnPath('BTT-Writer.exe')];
  {$ELSE}
  {$IFDEF DARWIN}
  Candidates := ['/Applications/BTT-Writer.app', Home + 'Applications/BTT-Writer.app',
    OnPath('btt-writer')];
  {$ELSE}
  Candidates := [OnPath('btt-writer'), OnPath('BTT-Writer'), '/usr/lib/btt-writer',
    '/opt/BTT-Writer', '/opt/btt-writer', Home + 'Applications/BTT-Writer'];
  Candidates := Concat(Candidates, DesktopEntryPrograms);
  {$ENDIF}
  {$ENDIF}
  Result := nil;
  for C in Candidates do
  begin
    if C = '' then
      Continue;
    Dir := BundledSourcesIn(C);
    if Dir = '' then
      Continue;
    Dir := IncludeTrailingPathDelimiter(ResolveLinks(Dir));
    Known := False;
    for I := 0 to High(Result) do
      if Result[I] = Dir then
        Known := True;
    if not Known then
      Result := Concat(Result, [Dir]);
  end;
end;

function BundledSourcesPath: string;
var
  Found: TStringArray;
begin
  if BundledSourcesOverride <> '' then
    Exit(IncludeTrailingPathDelimiter(BundledSourcesOverride));
  Result := Trim(GetEnvironmentVariable('BTW_BUNDLED_SOURCES'));
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(Result));
  Result := BundledSourcesIn(GetSetting(SetBttWriterInstall));
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(ResolveLinks(Result)));
  Found := FindBttWriterInstalls;
  if Length(Found) > 0 then
    Result := Found[0];
end;

end.
