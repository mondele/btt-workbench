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
  WBReporter, WBGit, WBJson, WBDataPaths, WBSources, WBSqlite, WBLanguages, TestUtil;

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
    M.Add('target_language', TJSONObject.Create(['id', Lang, 'name', 'Lang ' + Lang,
      'direction', 'ltr']));
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

{ What HEAD points at, e.g. refs/heads/master. }
function Branch(const Folder: string): string;
begin
  Result := Trim(RunGit(Target + Folder, ['symbolic-ref', '-q', 'HEAD']).Output);
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

{ WBSqlite against tests/fixtures/langs.sqlite, made with the sqlite3 tool:
  1 KiB pages, so 618 languages need interior pages; one name long enough
  for overflow pages; negative integers; a column added after some rows
  were written (shorter records). }
procedure TestSqliteReader(const Fixtures: string);
var
  Db: TSqliteFile;
  Rows: TSqliteRows;
  Cols: TStringArray;
  Langs: TLanguageIndex;
  Info: TLanguageInfo;
  Row: TSqliteRow;
  LongName, Filler: string;
  Raised: Boolean;
begin
  Db := TSqliteFile.Create(Fixtures + 'langs.sqlite');
  try
    Cols := Db.Columns('target_language');
    Check(String.Join(',', Cols) = 'id,slug,name,anglicized_name,direction,region,' +
      'is_gateway_language', 'sqlite: columns from CREATE TABLE, constraints skipped');
    Rows := Db.ReadTable('target_language');
    Check(Length(Rows) = 618, 'sqlite: every row read across interior pages');
    Check((RowValue(Rows[0], 0) = '1') and (RowValue(Rows[617], 0) = '618'),
      'sqlite: INTEGER PRIMARY KEY column holds the rowid');
    LongName := '';
    Filler := '';
    for Row in Rows do
    begin
      if RowValue(Row, 1) = 'zz-long' then
        LongName := RowValue(Row, 2);
      if RowValue(Row, 1) = 'x0599' then
        Filler := RowValue(Row, 2) + '|' + RowValue(Row, 6) + '|' +
          BoolToStr(Row.IsNull[3], 'null', 'value');
    end;
    Check((Length(LongName) = 3003) and (Copy(LongName, 2991, 13) = 'Long name end'),
      'sqlite: long value read through overflow pages');
    Check(Filler = 'Filler ünïcode 599|-599000|null', 'sqlite: UTF-8 text, negative integer, NULL');
    Rows := Db.ReadTable('temp_target_language');
    Check((Length(Rows) = 3) and (RowValue(Rows[0], 8) = '') and (RowValue(Rows[2], 8) = 'noted'),
      'sqlite: rows older than an added column read as empty');
    Raised := False;
    try
      Db.ReadTable('nothing');
    except
      on ESqliteFormat do
        Raised := True;
    end;
    Check(Raised, 'sqlite: missing table raises');
  finally
    Db.Free;
  end;
  Raised := False;
  try
    TSqliteFile.Create(Fixtures + 'fr_tit_f10.tsrc').Free;
  except
    on ESqliteFormat do
      Raised := True;
  end;
  Check(Raised, 'sqlite: a file that is not a database is refused');

  Langs := TLanguageIndex.Create(Fixtures + 'langs.sqlite');
  try
    Check(Langs.Find('PPP', Info) and (Info.Direction = 'rtl') and not Info.IsTemp,
      'language index: found case-insensitively');
    Check(Langs.Find('qaa-x-111111', Info) and Info.IsTemp and (Info.ApprovedAs = 'qqq'),
      'language index: temporary language and its approved code');
    Check(not Langs.Find('rrr', Info), 'language index: unknown code');
  finally
    Langs.Free;
  end;
end;

procedure TestProjectsModule(const TempRoot: string);
var
  Output, B, Blob: string;
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
  TestSqliteReader(IncludeTrailingPathDelimiter(BundledSourcesOverride));
  { BTT-Writer's own copy of the language database, in <data>/library/. }
  WriteFileText(Data + 'library' + PathDelim + 'index.sqlite',
    ReadFileText(IncludeTrailingPathDelimiter(BundledSourcesOverride) + 'langs.sqlite'));

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
  MakeProject('lll_tit_text_reg', 'lll', 'tit', 'text', 'reg', ['en_ulb'], [],
    ['01/01.txt=\v 1 a \v 2 b \v 3 c']);
  { Remove the chunk's blob: HEAD still resolves, only fsck notices. }
  Blob := GitText(Target + 'lll_tit_text_reg', ['rev-parse', 'HEAD:01/01.txt']);
  DeleteFile(Target + 'lll_tit_text_reg' + PathDelim + '.git' + PathDelim + 'objects' +
    PathDelim + Copy(Blob, 1, 2) + PathDelim + Copy(Blob, 3, MaxInt));
  MakeProject('mmm_tit_text_reg', 'mmm', 'tit', 'text', 'reg', [], [], []);
  WriteFileText(Target + 'mmm_tit_text_reg' + PathDelim + 'manifest.json',
    '{"package_version": "8", "target_language": {"id": "mmm", "name": "M"},' +
    ' "project": {"id": "tit", "name": 5}, "type": {"id": "text"},' +
    ' "resource": {"id": "reg"}, "finished_chunks": ["01-01", 3],' +
    ' "source_translations": [{"language_id": "en"}, "x"], "translators": "me"}');
  ForceDirectories(Target + 'nnn_tit_text_reg');
  MakeProject('ooo_tit_text_reg', 'ooo', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  MakeProject('ppp_tit_text_reg', 'ppp', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  MakeProject('qaa-x-111111_tit_text_reg', 'qaa-x-111111', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  MakeProject('qaa-x-222222_tit_text_reg', 'qaa-x-222222', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  MakeProject('rrr_tit_text_reg', 'rrr', 'tit', 'text', 'reg', ['en_ulb'], [], []);
  { Git branches: BTT-Writer only uses master. }
  MakeProject('aaa_tit_tq', 'aaa', 'tit', 'tq', '', [], [], ['01/01.txt=q']);
  Git(Target + 'aaa_tit_tq', ['branch', '-m', 'master', 'main']);
  MakeProject('bbb_tit_tq', 'bbb', 'tit', 'tq', '', [], [], ['01/01.txt=q'], False);
  Git(Target + 'bbb_tit_tq', ['init', '-q', '-b', 'main']);   // no commits yet
  MakeProject('ccc_tit_tq', 'ccc', 'tit', 'tq', '', [], [], ['01/01.txt=q']);
  Git(Target + 'ccc_tit_tq', ['checkout', '-q', '-b', 'main']);
  MakeProject('ddd_tit_tq', 'ddd', 'tit', 'tq', '', [], [], ['01/01.txt=q']);
  Git(Target + 'ddd_tit_tq', ['checkout', '-q', '-b', 'work']);
  MakeProject('eee_tit_tq', 'eee', 'tit', 'tq', '', [], [], ['01/01.txt=q']);
  Git(Target + 'eee_tit_tq', ['checkout', '-q', '--detach']);

  Output := List(['--type', 'tq', '--dry-run']);
  Check((Pos('would be moved to master (dry run)', Block(Output, 'aaa_tit_tq')) > 0) and
    (Pos('would be moved to master (dry run)', Block(Output, 'bbb_tit_tq')) > 0) and
    (Pos('2 project(s) would be moved from git branch main to master.', Output) > 0),
    'dry run: projects on main reported');
  Check((Branch('aaa_tit_tq') = 'refs/heads/main') and (Branch('bbb_tit_tq') = 'refs/heads/main'),
    'dry run: branches left alone');

  ForceDirectories(Target + 'junk');
  WriteFileText(Target + 'stray.zip', 'x');

  Output := List([]);
  Check(Pos('Language database: ' + Data + 'library' + PathDelim + 'index.sqlite (621 languages)',
    Output) > 0, 'language database from the data folder''s library');
  Check(Pos('info: 26 project(s) listed, 20 with problems.', Output) > 0,
    'every folder and file listed, problems counted');

  B := Block(Output, 'aaa_tit_tq');
  Check((Pos('warning: The git branch was main; moved it to master', B) > 0) and
    (Branch('aaa_tit_tq') = 'refs/heads/master') and
    (GitText(Target + 'aaa_tit_tq', ['log', '--format=%s']) = 'start') and
    (RunGit(Target + 'aaa_tit_tq', ['rev-parse', '--verify', '-q', 'refs/heads/main']).ExitCode <> 0),
    'branch main moved to master, history kept');
  Check((Pos('moved it to master', Block(Output, 'bbb_tit_tq')) > 0) and
    (Branch('bbb_tit_tq') = 'refs/heads/master'), 'branch main with no commits moved to master');
  Check((Pos('a master branch exists too; not changed', Block(Output, 'ccc_tit_tq')) > 0) and
    (Branch('ccc_tit_tq') = 'refs/heads/main'), 'main and master both present: refused');
  Check(Pos('The git branch is work, not master', Block(Output, 'ddd_tit_tq')) > 0,
    'other branch reported');
  Check(Pos('detached HEAD', Block(Output, 'eee_tit_tq')) > 0, 'detached HEAD reported');
  Check(Pos('2 project(s) moved from git branch main to master.', Output) > 0, 'moves summed up');


  B := Block(Output, 'aaa_tit_text_reg');
  Check((Pos('1 of 5 chunks finished', B) > 0) and (Pos('warning', B) = 0),
    'clean project: progress against the source, no problems');

  B := Block(Output, 'bbb_tit_text_reg');
  Check(Pos('Compared with en_tit_ulb (always compared): extra chunks (not in it; BTT-Writer ' +
    'does not show them with it): 01-03', B) > 0, 'en_ulb chunking deviation found, naming the chunk');
  Check(Pos('missing front-title, 01-title; missing 01-04, whose verses are in other chunks here',
    B) > 0, '... and the en_ulb chunks it lacks, those covered by other chunks apart');
  Check(Pos('Compared with ru_tit_ulb (listed as a source): no extra chunks; no chunks missing; ' +
    'verse markers all in its chunks.', B) > 0, 'its own source: each part said to be clean');
  Check(Pos('Matches ru_tit_ulb: nothing is lost when the project is opened with it. The ' +
    'differences from en_tit_ulb are only another chunking', B) > 0, '... and the verdict');
  Check(Pos('warning', B) = 0, 'another chunking of en_ulb alone is not a problem');

  B := Block(Output, 'ccc_tit_text_reg');
  Check(Pos('warning: Compared with en_tit_ulb (listed as a source): no extra chunks; ' +
    'missing front-title, 01-title, 01-01, 01-06; verse markers outside its chunks (BTT-Writer ' +
    'drops them when the chunk is opened with it): 01-04 \v 6.', B) > 0,
    'misplaced verse marker found, with chunk and verse');
  Check(Pos('No compared source matches', B) = 0, 'no verdict repeating the only source');
  Check(Pos('given twice in one chunk: 01-04 \v 5', B) > 0, 'repeated verse marker found');

  B := Block(Output, 'ddd_tit_text_reg');
  Check((Pos('not installed', B) = 0) and (Pos('(fr_tit_f10)', B) = 0),
    'bundled source used: verses checked against its larger chunk');
  Check((Pos('Compared with en_tit_ulb (always compared)', B) > 0) and (Pos('01-04 \v 7', B) > 0),
    '... and against en_ulb as well, which ends that chunk at verse 5');
  Check(Pos('Matches fr_tit_f10', B) > 0, '... the source it follows matching');

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

  B := Block(Output, 'mmm_tit_text_reg');
  Check(Pos('missing or of the wrong type: package_version, project.name, ' +
    'translators, finished_chunks[1], source_translations[0].resource_id, ' +
    'source_translations[1]', B) > 0, 'manifest fields of the wrong type reported');
  Check(Pos('Source _tit', B) + Pos('Source en_tit_ is', B) = 0, 'source entries without ids not looked up');

  Check(Pos('Text direction is out of date: the project says (none), the language ' +
    'database says ltr.', B) > 0, 'missing direction reported');

  Check(Pos('Language name is out of date: the project says "Lang ooo", the language ' +
    'database says "Ooo renamed".', Block(Output, 'ooo_tit_text_reg')) > 0, 'renamed language reported');
  B := Block(Output, 'ppp_tit_text_reg');
  Check((Pos('Text direction is out of date: the project says ltr, the language database ' +
    'says rtl.', B) > 0) and (Pos('Language name', B) = 0), 'changed direction reported');
  Check(Pos('Temporary language qaa-x-111111 has been approved as qqq',
    Block(Output, 'qaa-x-111111_tit_text_reg')) > 0, 'approved temporary language reported');
  Check(Pos('warning', Block(Output, 'qaa-x-222222_tit_text_reg')) = 0,
    'unapproved temporary language matching the database is fine');
  Check(Pos('Language rrr is not in the language database.', Block(Output, 'rrr_tit_text_reg')) > 0,
    'unknown language reported');
  Check(Pos('Language', Block(Output, 'aaa_tit_text_reg')) = 0, 'matching language not reported');

  B := Block(Output, 'lll_tit_text_reg');
  Check((B <> '') and (Pos('warning', B) = 0), 'missing object not noticed without --deep-git');
  Output := List(['--deep-git', '--language', 'lll,aaa']);
  Check(Pos('git fsck found problems in the history: ', Block(Output, 'lll_tit_text_reg')) > 0,
    '--deep-git: fsck problem reported');
  Check(Pos('warning', Block(Output, 'aaa_tit_text_reg')) = 0, '--deep-git: sound history passes');

  Check(Pos('branch', List(['--type', 'tq', '--language', 'aaa'])) = 0,
    'moved project is clean on the next scan');

  Output := List(['--language', 'ooo', '--language-db', TempRoot + 'nowhere.sqlite']);
  Check((Pos('Cannot read the language database', Output) > 0) and
    (Pos('out of date', Output) = 0), 'unreadable language database: warned, check skipped');

  { Filters }
  Output := List(['--language', 'bbb,CCC', '--type', 'text']);
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
  Output := List(['--language', 'hhh,nnn']);
  Check((Pos('2 project(s) listed', Output) > 0) and
    (Pos('unresolved merge conflict markers', Output) > 0) and
    (Pos('Listed by its folder name', Output) > 0) and
    (Pos('nnn_tit_text_reg: no manifest.json', Output) > 0),
    'unreadable or missing manifest matched by folder name when filtering');
  Output := List(['--language', 'aaa']);
  Check(Pos('hhh', Output) = 0, '... and left out when the folder name does not match');
  Output := List(['--problems-only']);
  Check((Block(Output, 'aaa_tit_text_reg') = '') and (Block(Output, 'ccc_tit_text_reg') <> '') and
    (Pos('without problems not shown', Output) > 0), '--problems-only hides clean projects');

  BundledSourcesOverride := TempRoot + 'no-bundled-sources';
  Output := List(['--language', 'ddd']);
  Check(Pos('fr_tit_f10 is neither downloaded nor bundled', Output) > 0,
    'missing source reported when not bundled');
  BundledSourcesOverride := '';
end;

end.
