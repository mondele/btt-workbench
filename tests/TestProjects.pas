unit TestProjects;

{$mode objfpc}{$H+}

(* Tests for the projects module and WBSources. Builds a temp BTT-Writer
   data folder: a library with en_tit_ulb (with toc.yml) and ru_tit_ulb
   (without), the bundled fr_tit_f10.tsrc from tests/fixtures, and a set of
   projects with one kind of problem each. *)

interface

procedure TestProjectsModule(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fpjson,
  WBReporter, WBGit, WBJson, WBDataPaths, WBSources, TestUtil;

var
  Data, Target, Lib: string;

procedure Git(const Dir: string; const Args: array of string);
var
  All: array of string;
  I: Integer;
begin
  All := ['-c', 'user.name=Test', '-c', 'user.email=test@example.com',
    '-c', 'init.defaultBranch=master', '-c', 'commit.gpgsign=false'];
  SetLength(All, 8 + Length(Args));
  for I := 0 to High(Args) do
    All[8 + I] := Args[I];
  RunGit(Dir, All);
end;

procedure Put(const Path, Text: string);
begin
  ForceDirectories(ExtractFileDir(Path));
  WriteFileText(Path, Text);
end;

function Usx(const Verses: array of string): string;
var
  V: string;
begin
  Result := '';
  for V in Verses do
    Result := Result + '<verse number="' + V + '" style="v" />text ' + V + #10;
end;

procedure MakeLibrary;
var
  En, Ru: string;
begin
  En := Lib + 'en_tit_ulb' + PathDelim + 'content' + PathDelim;
  Put(En + 'front/title.usx', 'Titus');
  Put(En + '01/title.usx', 'Chapter 1');
  Put(En + '01/01.usx', Usx(['1', '2', '3']));
  Put(En + '01/04.usx', Usx(['4', '5']));
  Put(En + '01/06.usx', Usx(['6-7', '8', '9']));
  { toc order differs from file order on purpose; 01-99 has no file. }
  Put(En + 'toc.yml', '-' + #10 + '  chapter: front' + #10 + '  chunks:' + #10 +
    '    - title' + #10 + '-' + #10 + '  chapter: ''01''' + #10 + '  chunks:' + #10 +
    '    - title' + #10 + '    - ''01''' + #10 + '    - ''04''' + #10 +
    '    - ''06''' + #10 + '    - ''99''' + #10);
  Ru := Lib + 'ru_tit_ulb' + PathDelim + 'content' + PathDelim;
  Put(Ru + '01/01.usx', Usx(['1', '2']));
  Put(Ru + '01/03.usx', Usx(['3', '4', '5']));
  Put(Ru + '01/06.usx', Usx(['6', '7', '8', '9']));
end;

{ A project folder with a manifest and chunk files (path=text pairs). }
procedure MakeProject(const Folder, Lang, Book, Kind, Res: string;
  const Sources: array of string; const Finished: array of string;
  const Files: array of string; WithGit: Boolean = True);
var
  Dir, S: string;
  M, Src: TJSONObject;
  A: TJSONArray;
  P: Integer;
begin
  Dir := Target + Folder + PathDelim;
  ForceDirectories(Dir);
  M := TJSONObject.Create;
  try
    M.Add('package_version', 8);
    M.Add('target_language', TJSONObject.Create(['id', Lang, 'name', 'Lang ' + Lang]));
    M.Add('project', TJSONObject.Create(['id', Book, 'name', 'Book ' + Book]));
    M.Add('type', TJSONObject.Create(['id', Kind, 'name', Kind]));
    if Res <> '' then
      M.Add('resource', TJSONObject.Create(['id', Res, 'name', Res]));
    A := TJSONArray.Create;
    for S in Sources do
    begin
      P := Pos('_', S);
      Src := TJSONObject.Create(['language_id', Copy(S, 1, P - 1),
        'resource_id', Copy(S, P + 1, MaxInt)]);
      A.Add(Src);
    end;
    M.Add('source_translations', A);
    A := TJSONArray.Create;
    for S in Finished do
      A.Add(S);
    M.Add('finished_chunks', A);
    WriteBttJSONFile(Dir + 'manifest.json', M);
  finally
    M.Free;
  end;
  for S in Files do
  begin
    P := Pos('=', S);
    Put(Dir + StringReplace(Copy(S, 1, P - 1), '/', PathDelim, [rfReplaceAll]),
      Copy(S, P + 1, MaxInt));
  end;
  if WithGit then
  begin
    Git(Dir, ['init', '-q']);
    Git(Dir, ['add', '--all']);
    Git(Dir, ['commit', '-q', '-m', 'start']);
  end;
end;

function List(const Extra: array of string): string;
var
  Args: array of string;
  I: Integer;
  R: TWBListReporter;
begin
  Args := ['--target-dir', Target];
  SetLength(Args, 2 + Length(Extra));
  for I := 0 to High(Extra) do
    Args[2 + I] := Extra[I];
  RunModule('projects', Args, R);
  Result := '';
  for I := 0 to R.Count - 1 do
    Result := Result + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
  R.Free;
end;

{ The block of output for one project: its header line up to the next
  blank line. }
function Block(const Output, Folder: string): string;
var
  P, E: Integer;
begin
  P := Pos('info: ' + Folder + ':', Output);
  if P = 0 then
    P := Pos(Folder + ':', Output);
  if P = 0 then
    Exit('');
  E := Pos('info: ' + #10, Output, P);
  if E = 0 then
    E := Length(Output) + 1;
  Result := Copy(Output, P, E - P);
end;

procedure TestSources;
var
  Sources: TSourceLibrary;
  C: TSourceChunking;
  I: Integer;
  Order: string;
begin
  Sources := TSourceLibrary.Create(Lib, BundledSourcesPath);
  try
    C := Sources.Find('en_tit_ulb');
    Check((C <> nil) and not C.Bundled, 'installed container found');
    Order := '';
    if C <> nil then
      for I := 0 to High(C.Chunks) do
        Order := Order + C.Chunks[I].Chapter + '-' + C.Chunks[I].Chunk + ' ';
    Check(Trim(Order) = 'front-title 01-title 01-01 01-04 01-06',
      'chunks in toc.yml order, toc entries without a file dropped');
    I := C.IndexOf('1', '006');
    Check((I >= 0) and (Length(C.Chunks[I].Verses) = 4) and (C.Chunks[I].Verses[0] = 6) and
      (C.Chunks[I].Verses[1] = 7), 'verse range 6-7 counts as 6 and 7; padding ignored');
    C := Sources.Find('fr_tit_f10');
    Check((C <> nil) and C.Bundled and (C.IndexOf('01', '04') >= 0),
      'bundled .tsrc container read');
    Check(Sources.Find('xx_tit_ulb') = nil, 'missing container is nil');
    Check(Sources.Find('../en_tit_ulb') = nil, 'path in a container name refused');
  finally
    Sources.Free;
  end;
end;

procedure TestProjectsModule(const TempRoot: string);
var
  Output, B: string;
begin
  Section('projects');
  Data := TempRoot + 'projects' + PathDelim + 'data' + PathDelim;
  Target := Data + 'targetTranslations' + PathDelim;
  Lib := Data + 'library' + PathDelim + 'resource_containers' + PathDelim;
  ForceDirectories(Target);
  MakeLibrary;
  BundledSourcesOverride := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' +
    PathDelim + 'tests' + PathDelim + 'fixtures');

  TestSources;

  MakeProject('aaa_tit_text_reg', 'aaa', 'tit', 'text', 'reg', ['en_ulb'], ['01-01'],
    ['01/01.txt=\v 1 a \v 2 b \v 3 c', '01/04.txt=\v 4 d \v 5 e']);
  MakeProject('bbb_tit_text_reg', 'bbb', 'tit', 'text', 'reg', ['ru_ulb'], [],
    ['01/01.txt=\v 1 a \v 2 b', '01/03.txt=\v 3 c \v 4 d \v 5 e', '01/06.txt=\v 6 f']);
  MakeProject('ccc_tit_text_reg', 'ccc', 'tit', 'text', 'reg', ['en_ulb'], [],
    ['01/04.txt=\v 4 d \v 6 x \v 5 e \v 5 again']);
  MakeProject('ddd_tit_text_reg', 'ddd', 'tit', 'text', 'reg', ['fr_f10'], [],
    ['01/01.txt=\v 1 a', '01/04.txt=\v 4 b \v 7 c']);
  MakeProject('wrongname', 'eee', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  MakeProject('fff_tit_text_reg', 'fff', 'tit', 'text', 'reg', ['en_ulb'], [], [], False);
  MakeProject('ggg_tit_text_reg', 'ggg', 'tit', 'text', 'reg', ['en_ulb'], [],
    ['01/01.txt=<<<<<<< HEAD'#10'\v 1 a'#10'======='#10'\v 1 b'#10 +
       '>>>>>>> 0123456789abcdef0123456789abcdef01234567'#10,
     '01/04.txt=<<<<<<< HEAD'#10'\v 4 a'#10'======='#10'\v 4 b'#10'>>>>>>> import/master'#10]);
  MakeProject('hhh_tit_text_reg', 'hhh', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  WriteFileText(Target + 'hhh_tit_text_reg' + PathDelim + 'manifest.json',
    '<<<<<<< HEAD'#10'{"a": 1}'#10'======='#10'{"a": 2}'#10'>>>>>>> x'#10);
  MakeProject('iii_tit_text_reg', 'iii', 'tit', 'text', 'reg', ['en_ulb'], ['01-06'],
    ['01/01.txt=\v 1 a']);
  MakeProject('jjj_xyz_text_reg', 'jjj', 'xyz', 'text', 'reg', [], [], ['01/01.txt=\v 1 a']);
  MakeProject('kkk_tit_tn', 'kkk', 'tit', 'tn', '', ['en_tn'], [], ['01/01.txt=note']);
  ForceDirectories(Target + 'junk');
  WriteFileText(Target + 'stray.zip', 'x');

  Output := List([]);
  Check(Pos('info: 13 project(s) listed, 10 with problems.', Output) > 0,
    'every folder and file listed, problems counted');

  B := Block(Output, 'aaa_tit_text_reg');
  Check((Pos('1 of 5 chunks finished', B) > 0) and (Pos('warning', B) = 0),
    'clean project: progress against the source, no problems');

  B := Block(Output, 'bbb_tit_text_reg');
  Check(Pos('1 chunk(s) do not match en_tit_ulb chunking', B) > 0, 'en_ulb chunking deviation found');
  Check(Pos(': 01-03', B) > 0, '... naming the chunk');
  Check(Pos('en_tit_ulb chunks with no file here: front-title, 01-title, 01-04', B) > 0,
    '... and the en_ulb chunks it lacks');
  Check(Pos('Follows ru_tit_ulb chunking', B) > 0, '... and which chunking it follows');
  Check(Pos('ru_tit_ulb (listed', B) = 0, 'no deviation from its own source');

  B := Block(Output, 'ccc_tit_text_reg');
  Check(Pos('not in that chunk of the source (en_tit_ulb)', B) > 0, 'misplaced verse marker found');
  Check(Pos('01-04 \v 6', B) > 0, '... with chunk and verse');
  Check(Pos('given twice in one chunk: 01-04 \v 5', B) > 0, 'repeated verse marker found');

  B := Block(Output, 'ddd_tit_text_reg');
  Check((Pos('not installed', B) = 0) and (Pos('warning', B) = 0),
    'bundled source used: verses checked against its larger chunk');
  Check(Pos('Follows fr_tit_f10 chunking', B) = 0, 'no "follows" note when en_ulb matches too');

  Check(Pos('should be named eee_tit_text_reg', Block(Output, 'wrongname')) > 0,
    'misnamed folder reported');
  Check(Pos('No git history', Block(Output, 'fff_tit_text_reg')) > 0, 'missing git reported');

  B := Block(Output, 'ggg_tit_text_reg');
  Check(Pos('1 chunk(s) have unresolved conflicts: 01-01', B) > 0, 'conflict reported');
  Check(Pos('1 chunk(s) have conflict markers BTT-Writer cannot read: 01-04', B) > 0,
    'unreadable (btt-writer-two style) conflict reported');
  Check(Pos('given twice', B) = 0, 'conflicted chunks skipped by the verse check');

  Check(Pos('unresolved merge conflict markers', Output) > 0, 'conflicted manifest reported');
  Check(Pos('Marked finished but have no file: 01-06', Block(Output, 'iii_tit_text_reg')) > 0,
    'finished chunk without a file reported');
  Check(Pos('No en_ulb text for book "xyz"', Block(Output, 'jjj_xyz_text_reg')) > 0,
    'unknown book reported');
  Check(Pos('only checked for text projects', Block(Output, 'kkk_tit_tn')) > 0,
    'non-text project not chunk-checked');
  Check(Pos('junk: no manifest.json', Output) > 0, 'folder without manifest reported');
  Check(Pos('stray.zip: a file', Output) > 0, 'stray file reported');

  { Filters }
  Output := List(['--language', 'bbb,CCC']);
  Check((Pos('2 project(s) listed', Output) > 0) and (Block(Output, 'bbb_tit_text_reg') <> '') and
    (Block(Output, 'ccc_tit_text_reg') <> '') and (Pos('junk', Output) = 0),
    'language filter, comma list, any case; non-projects hidden');
  Output := List(['--book', 'xyz']);
  Check((Pos('1 project(s) listed', Output) > 0) and (Block(Output, 'jjj_xyz_text_reg') <> ''),
    'book filter');
  Output := List(['--type', 'tn']);
  Check((Pos('1 project(s) listed', Output) > 0) and (Block(Output, 'kkk_tit_tn') <> ''),
    'type filter by type');
  Output := List(['--type', 'text_reg', '--language', 'kkk,aaa']);
  Check((Pos('1 project(s) listed', Output) > 0) and (Block(Output, 'aaa_tit_text_reg') <> ''),
    'type filter as type_resource, combined with language');
  Output := List(['--problems-only']);
  Check((Block(Output, 'aaa_tit_text_reg') = '') and (Block(Output, 'bbb_tit_text_reg') <> '') and
    (Pos('without problems not shown', Output) > 0), '--problems-only hides clean projects');

  BundledSourcesOverride := TempRoot + 'no-bundled-sources';
  Output := List(['--language', 'ddd']);
  Check(Pos('fr_tit_f10 is not installed or bundled', Output) > 0,
    'missing source reported when not bundled');
  BundledSourcesOverride := '';
end;

end.
