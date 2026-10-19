unit TestCrossCheck;

{$mode objfpc}{$H+}

(* Tests for cross-check (WBCrossCheck, WBChunkHistory, ModCrossCheck).
   Builds three projects of a made-up language, xx: Titus, Philemon and
   Jude, each with its own made-up words, committed on 2026-01-01. A second
   commit on 2026-03-01 by "Paster" damages Titus the ways seen in the
   field: a chunk replaced by a Philemon chunk, the end of a Jude chunk added
   to a chunk, the end of a Philemon chunk run onto a chunk's last word. It
   also adds what must not be reported: a new chunk whose ending phrase is
   shared with Jude (typed while drafting), and a Titus closing blessing
   shared with Philemon's, which the English ULB shows is a real parallel. *)

interface

procedure TestCrossChecks(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fpjson,
  WBReporter, WBModule, WBCommandLine, WBGit, WBJson, WBDataPaths, WBSources, WBProject,
  WBChunkHistory, WBCrossCheck, WBCrossScan, WBCrossRepair, WBWacs, WBSimilarity, TestUtil;

var
  Target: string;

{ Made-up words of one chunk: tit0105a1 tit0105a2 ... }
function Words(const Key: string; First, Last: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := First to Last do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Key + 'w' + IntToStr(I);
  end;
end;

procedure Put(const Path, Text: string);
begin
  ForceDirectories(ExtractFileDir(Path));
  WriteFileText(Path, Text);
end;

procedure Git(const Dir, Date, Author: string; const Args: array of string);
var
  All: array of string;
  I: Integer;
begin
  All := ['-c', 'user.name=' + Author, '-c', 'user.email=t@example.com',
    '-c', 'init.defaultBranch=master', '-c', 'commit.gpgsign=false'];
  SetLength(All, 8 + Length(Args));
  for I := 0 to High(Args) do
    All[8 + I] := Args[I];
  RunGitEnv(Dir, All, ['GIT_AUTHOR_DATE=' + Date, 'GIT_COMMITTER_DATE=' + Date]);
end;

function MakeProject(const Book: string; const Files: array of string;
  const Lang: string = 'xx'): string;
var
  M: TJSONObject;
  S: string;
  P: Integer;
begin
  Result := Target + Lang + '_' + Book + '_text_reg' + PathDelim;
  ForceDirectories(Result);
  M := TJSONObject.Create(['package_version', 8,
    'target_language', TJSONObject.Create(['id', Lang, 'name', 'Lang xx', 'direction', 'ltr']),
    'project', TJSONObject.Create(['id', Book, 'name', Book]),
    'type', TJSONObject.Create(['id', 'text', 'name', 'Text']),
    'resource', TJSONObject.Create(['id', 'reg', 'name', 'Regular'])]);
  try
    WriteBttJSONFile(Result + 'manifest.json', M);
  finally
    M.Free;
  end;
  for S in Files do
  begin
    P := Pos('=', S);
    Put(Result + Copy(S, 1, P - 1), Copy(S, P + 1, MaxInt));
  end;
  Git(Result, '2026-01-01T09:00:00+0300', 'Translator', ['init', '-q']);
  Git(Result, '2026-01-01T09:00:00+0300', 'Translator', ['add', '--all']);
  Git(Result, '2026-01-01T09:00:00+0300', 'Translator', ['commit', '-q', '-m', 'start']);
end;

function Lines(R: TWBListReporter): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to R.Count - 1 do
    Result := Result + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
end;

function LineWith(const Output, A: string; const B: string = ''): string;
var
  L: TStringList;
  S: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Output;
    for S in L do
      if (Pos(A, S) > 0) and ((B = '') or (Pos(B, S) > 0)) then
        Exit(S);
  finally
    L.Free;
  end;
end;

procedure TestParseLog;
var
  V: TChunkVersions;
  C: TCommitFilesList;
  Log: string;
begin
  Section('cross-check: reading chunk history from git log');
  Log := #1'aaaa'#9'100'#9'2026-01-01 09:00:00 +0300'#9'Ann'#10 + #10 +
    'diff --git a/01/01.txt b/01/01.txt'#10'new file mode 100644'#10 +
    '--- /dev/null'#10'+++ b/01/01.txt'#10'@@ -0,0 +1,2 @@'#10'+\v 1 one'#10'+two'#10 +
    'diff --git a/01/02.txt b/01/02.txt'#10'deleted file mode 100644'#10 +
    '--- a/01/02.txt'#10'+++ /dev/null'#10'@@ -1 +0,0 @@'#10'-gone'#10 +
    #1'bbbb'#9'200'#9'2026-01-02 10:30:00 -0500'#9'Bo Bo'#10 + #10 +
    'diff --git a/01/01.txt b/01/01.txt'#10'--- a/01/01.txt'#10'+++ b/01/01.txt'#10 +
    '@@ -1,2 +1,2 @@'#10' \v 1 one'#10'-two'#10'+three'#10'\ No newline at end of file'#10;
  ParseChunkLog(Log, V, C);
  Check(Length(V) = 2, 'two versions (the deleted file has none)');
  Check((V[0].Path = '01/01.txt') and (V[0].Text = '\v 1 one'#10'two'#10) and
    (V[0].Commit = 'aaaa') and (V[0].Time = 100), 'a new file is its added lines');
  Check((V[1].Text = '\v 1 one'#10'three'#10) and (V[1].Author = 'Bo Bo') and
    (V[1].Date = '2026-01-02 10:30'), 'a change is context and added lines, author and date kept');
  Check((Length(C) = 2) and (C[0].Files = 2) and (C[1].Files = 1), 'files changed per commit');
end;

procedure TestTokenize;
var
  A, B: THashList;
  VA, VB: TVerseList;
begin
  Section('cross-check: words');
  TokenizeWords('\c 3 \v 4 Ndima ye-Mwari, \v 5-6 \f + \ft note\f* zwose.', A, VA);
  TokenizeWords('ndima YE mwari NOTE zwose', B, VB);
  Check((Length(A) = 5) and (A[0] = B[0]) and (A[2] = B[2]) and (A[4] = B[4]),
    'markers left out, case folded, punctuation splits words');
  Check((VA[0] = 4) and (VA[3] = 5), 'each word knows its verse');
end;

procedure TestModule(const TempRoot: string);
var
  Data, Tit, Phm, Jud, Lib, Output, S: string;
  R: TWBListReporter;
  Code: Integer;
  OldBundled: string;
begin
  Section('cross-check module');
  Data := TempRoot + 'crosscheck' + PathDelim;
  Target := Data + 'targetTranslations' + PathDelim;
  Lib := Data + 'library' + PathDelim + 'resource_containers' + PathDelim;
  OldBundled := BundledSourcesOverride;
  BundledSourcesOverride := TempRoot + 'no-bundled-sources';
  try
    { English: Titus 3:15 and Philemon 25 are alike; the rest is not. }
    Put(Lib + 'en_tit_ulb/content/03/15.usx',
      '<verse number="15" style="v" />All who are with me greet you. ' +
      'May the grace of the Lord Jesus Christ be with you all.');
    Put(Lib + 'en_tit_ulb/content/01/05.usx',
      '<verse number="5" style="v" />For this purpose I left you in Crete.');
    Put(Lib + 'en_tit_ulb/content/01/01.usx',
      '<verse number="1" style="v" />Paul, a servant of God.');
    Put(Lib + 'en_phm_ulb/content/01/25.usx',
      '<verse number="25" style="v" />May the grace of the Lord Jesus Christ be with your spirit.');
    Put(Lib + 'en_phm_ulb/content/01/04.usx',
      '<verse number="4" style="v" />I always thank my God.');

    Phm := MakeProject('phm', [
      '01/04.txt=\v 4 ' + Words('phm0104', 1, 12) + ' \v 5 ' + Words('phm0104', 13, 24) + '.',
      '01/08.txt=\v 8 ' + Words('phm0108', 1, 20) + '.',
      '01/25.txt=\v 25 ' + Words('phm0125', 1, 3) + ' ' + Words('bless', 1, 9) + '.']);
    Jud := MakeProject('jud', [
      '01/01.txt=\v 1 ' + Words('jud0101', 1, 30) + '.',
      '01/03.txt=\v 3 ' + Words('jud0103', 1, 20) + ' ' + Words('formula', 1, 7) + '.']);
    Tit := MakeProject('tit', [
      '01/01.txt=\v 1 ' + Words('tit0101', 1, 25) + '.',
      '01/05.txt=\v 5 ' + Words('tit0105', 1, 30) + '.',
      '02/01.txt=\v 1 ' + Words('tit0201', 1, 25) + '.',
      '03/15.txt=\v 15 ' + Words('tit0315', 1, 2) + '.']);

    { The damage, two months later. }
    Put(Tit + '01/05.txt', '\v 4 ' + Words('phm0104', 1, 12) + ' \v 5 ' + Words('phm0104', 13, 24) + '.');
    Put(Tit + '01/01.txt', '\v 1 ' + Words('tit0101', 1, 25) + '. ' + Words('jud0101', 21, 30) + '.');
    { the selection started inside a word, as in the field: "w15" }
    Put(Tit + '02/01.txt', '\v 1 ' + Words('tit0201', 1, 25) + '.w15 ' + Words('phm0108', 16, 20) + '.');
    { Not damage: a new chunk drafted with a shared phrase at its end, and
      the closing blessing (a real parallel). }
    Put(Tit + '02/05.txt', '\v 5 ' + Words('tit0205', 1, 20) + ' ' + Words('formula', 1, 7) + '.');
    Put(Tit + '03/15.txt', '\v 15 ' + Words('tit0315', 1, 2) + ' ' + Words('bless', 1, 9) + '.');
    Git(Tit, '2026-03-01T10:00:00+0200', 'Paster', ['add', '--all']);
    Git(Tit, '2026-03-01T10:00:00+0200', 'Paster', ['commit', '-q', '-m', 'session']);

    Code := RunModule('cross-check', ['--target-dir', Target], R);
    try
      Output := Lines(R);
    finally
      R.Free;
    end;
    if GetEnvironmentVariable('BTW_SHOW') <> '' then
      WriteLn(Output);
    Check(Code = 0, 'runs');
    Check(Pos('xx: compared 3 project(s), 10 chunk file(s) and ', Output) > 0,
      'compares the projects of the language with their history');
    S := LineWith(Output, '01/05: replaced by text from Philemon 01/04');
    Check(S <> '', 'a chunk pasted over is found, with where it came from');
    Check(Pos('since ', S) > 0, 'with the commit that brought it in');
    Check(Pos('(2026-03-01 10:00, Paster)', S) > 0, 'its date as the author saw it, and author');
    Check(Pos('also changed 4 other chunk file(s)', S) > 0, 'and what else that commit changed');
    Check(LineWith(Output, '01/01: ends with text from Jude 01/01') <> '',
      'the end of another book''s chunk added to a chunk');
    S := LineWith(Output, '02/01: ends with text from Philemon 01/08, run onto the last word');
    Check((S <> '') and (Pos('"w15 phm0108w16', S) > 0), 'text run onto the last word, quoted');
    Check(LineWith(Output, '02/05:') = '', 'a phrase typed while drafting is not reported');
    Check(LineWith(Output, '03/15:') = '', 'a real parallel (alike in the English) is not reported');
    Check(LineWith(Output, 'xx_tit_text_reg', '3 file(s) to check') <> '',
      'the project header counts chunks');
    Check(LineWith(Output, 'The text of 01/04 appears later in: tit 01/05') <> '',
      'the other book is told where its text went');
    Check(LineWith(Output, '1 with files to check') <> '', 'summary');

    Code := RunModule('cross-check', ['--target-dir', Target, '--book', 'phm,jud'], R);
    try
      Output := Lines(R);
    finally
      R.Free;
    end;
    Check((Code = 0) and (LineWith(Output, '01/05: replaced') = '') and
      (LineWith(Output, 'xx: compared 3 project(s)') <> ''),
      '--book reports on those books but compares all of the language');

    Code := RunModule('cross-check', ['--target-dir', Target, '--no-history'], R);
    try
      Output := Lines(R);
    finally
      R.Free;
    end;
    S := LineWith(Output, '01/05: replaced by text from Philemon 01/04');
    Check((Code = 0) and (Pos('which came first is unknown', S) > 0) and
      (LineWith(Output, 'and 0 earlier version(s)') <> ''),
      '--no-history compares current text only and cannot tell which came first');

    { The same language under another code (Chimanika's Luke was
      mxc-MZ-chimanika, its other books mxc-MZ-x-manika): Luke's chunk
      pasted over by a Jude chunk must still be found. }
    Phm := MakeProject('luk', ['01/01.txt=\v 1 ' + Words('luk0101', 1, 30) + '.'], 'xx-YY-alt');
    Put(Phm + '01/01.txt', '\v 3 ' + Words('jud0103', 1, 20) + '.');
    Git(Phm, '2026-03-02T10:00:00+0200', 'Paster', ['commit', '-q', '-a', '-m', 'session']);
    Code := RunModule('cross-check', ['--target-dir', Target], R);
    try
      Output := Lines(R);
    finally
      R.Free;
    end;
    Check((Code = 0) and (LineWith(Output, 'xx, xx-YY-alt: compared 4 project(s)') <> ''),
      'codes sharing their first part are compared as one language');
    Check(LineWith(Output, 'under 2 codes (xx, xx-YY-alt)') <> '', 'with a warning naming them');
    Check(LineWith(Output, '01/01: replaced by text from Jude 01/03') <> '',
      'text copied from a book under another code is found');
    Code := RunModule('cross-check', ['--target-dir', Target, '--language', 'xx-yy-alt'], R);
    try
      Output := Lines(R);
    finally
      R.Free;
    end;
    Check((Code = 0) and (LineWith(Output, 'compared 4 project(s)') <> '') and
      (LineWith(Output, '01/01: replaced by text from Jude 01/03') <> '') and
      (LineWith(Output, '01/05: replaced') = ''),
      '--language reports on that code but compares the whole language');
  finally
    BundledSourcesOverride := OldBundled;
  end;
end;

function Run(const ModuleId: string; const Args: array of string; out Code: Integer): string;
var
  R: TWBListReporter;
begin
  Code := RunModule(ModuleId, Args, R);
  try
    Result := Lines(R);
  finally
    R.Free;
  end;
  if GetEnvironmentVariable('BTW_SHOW') <> '' then
    WriteLn(Result);
end;

{ The module's checklist, one line per item: value and columns. }
function ListOf(const ModuleId: string; const Args: array of string; out Code: Integer): string;
var
  R: TWBListReporter;
  Options, ArgList: TStringList;
  M: TWBModule;
  List: TWBChoiceList;
  C: TWBChoice;
  Err, A: string;
begin
  Result := '';
  M := FindModule(ModuleId);
  R := TWBListReporter.Create;
  Options := TStringList.Create;
  ArgList := TStringList.Create;
  try
    for A in Args do
      ArgList.Add(A);
    Code := 2;
    if not ParseModuleArgs(M, ArgList, Options, Err) then
      Exit;
    Code := 1;
    if not M.Choices(ChecklistOption(M), Options, R, List) then
      Exit;
    Code := 0;
    for C in List.Items do
      Result := Result + C.Value + ' | ' + String.Join(' | ', C.Columns) + #10;
  finally
    ArgList.Free;
    Options.Free;
    R.Free;
  end;
  if GetEnvironmentVariable('BTW_SHOW') <> '' then
    WriteLn(Result);
end;

function Finished(const Dir: string): TStringArray;
var
  M: TJSONObject;
begin
  M := ReadJSONObjectFile(Dir + 'manifest.json');
  try
    Result := StringsOf(M.Find('finished_chunks'));
  finally
    M.Free;
  end;
end;

procedure SetFinished(const Dir: string; const Ids: array of string);
var
  M: TJSONObject;
  A: TJSONArray;
  S: string;
begin
  M := ReadJSONObjectFile(Dir + 'manifest.json');
  try
    A := TJSONArray.Create;
    for S in Ids do
      A.Add(S);
    if M.Find('finished_chunks') <> nil then
      M.Delete('finished_chunks');
    M.Add('finished_chunks', A);
    WriteBttJSONFile(Dir + 'manifest.json', M);
  finally
    M.Free;
  end;
end;

function CommitCount(const Dir: string): Integer;
begin
  Result := StrToIntDef(Trim(RunGit(Dir, ['rev-list', '--count', 'HEAD']).Output), -1);
end;

(* cross-repair. Titus is damaged by two "Paster" commits and then edited
   for real by "Editor":
   01/05  pasted over (Philemon 01/04), more pasted on by the 2nd commit
          -> restore from before the 1st
   01/09  added, holding Jude 01/01, and marked finished -> remove
   02/01  Philemon 01/08's end added, but its own words changed too
          -> mixed: only with --include-mixed
   02/03  added with Philemon 01/12, edited since by Editor -> left alone
   02/05  pasted over (Jude 01/01), has uncommitted changes -> left alone
   03/01  pasted over by the 2nd commit (Philemon 01/12) -> restore
   The 1st commit also renamed the chapter title: that must stay. *)
procedure TestRepair(const TempRoot: string);
var
  Data, Tit, Output, S, OldBundled: string;
  Code, Before: Integer;
  Ids: TStringArray;
  Account: TWacsAccount;
  Name, Email: string;
begin
  Section('cross-repair module');
  Data := TempRoot + 'crossrepair' + PathDelim;
  Target := Data + 'targetTranslations' + PathDelim;
  OldBundled := BundledSourcesOverride;
  BundledSourcesOverride := TempRoot + 'no-bundled-sources';
  try
    MakeProject('phm', [
      '01/04.txt=\v 4 ' + Words('phm0104', 1, 24) + '.',
      '01/08.txt=\v 8 ' + Words('phm0108', 1, 20) + '.',
      '01/12.txt=\v 12 ' + Words('phm0112', 1, 30) + '.']);
    MakeProject('jud', ['01/01.txt=\v 1 ' + Words('jud0101', 1, 30) + '.']);
    Tit := MakeProject('tit', [
      '01/title.txt=Chapter one',
      '01/01.txt=\v 1 ' + Words('tit0101', 1, 25) + '.',
      '01/05.txt=\v 5 ' + Words('tit0105', 1, 30) + '.',
      '02/01.txt=\v 1 ' + Words('tit0201', 1, 25) + '.',
      '02/05.txt=\v 5 ' + Words('tit0205', 1, 20) + '.',
      '03/01.txt=\v 1 ' + Words('tit0301', 1, 20) + '.']);

    { as BTT-Writer does: the field user's name in the project's settings }
    RunGit(Tit, ['config', 'user.name', 'Field User']);
    RunGit(Tit, ['config', 'user.email', 'field@example.org']);
    { the first damaging session }
    Put(Tit + '01/title.txt', 'Sura 1');
    Put(Tit + '01/05.txt', '\v 5 ' + Words('phm0104', 1, 24) + '.');
    Put(Tit + '01/09.txt', '\v 9 ' + Words('jud0101', 1, 30) + '.');
    Put(Tit + '02/01.txt', '\v 1 ' + Words('titedit', 1, 10) + ' ' + Words('tit0201', 11, 25) +
      '. ' + Words('phm0108', 13, 20) + '.');
    Put(Tit + '02/03.txt', '\v 3 ' + Words('phm0112', 1, 30) + '.');
    Put(Tit + '02/05.txt', '\v 5 ' + Words('jud0101', 1, 30) + '.');
    SetFinished(Tit, ['01-01', '01-05', '01-09']);
    Git(Tit, '2026-03-01T10:00:00+0200', 'Paster', ['add', '--all']);
    Git(Tit, '2026-03-01T10:00:00+0200', 'Paster', ['commit', '-q', '-m', 'session 1']);
    { the second }
    Put(Tit + '01/05.txt', '\v 5 ' + Words('phm0104', 1, 24) + '. ' + Words('phm0108', 1, 10) + '.');
    Put(Tit + '03/01.txt', '\v 1 ' + Words('phm0112', 1, 30) + '.');
    Git(Tit, '2026-03-02T10:00:00+0200', 'Paster', ['add', '--all']);
    Git(Tit, '2026-03-02T10:00:00+0200', 'Paster', ['commit', '-q', '-m', 'session 2']);
    { real work on a damaged chunk, then uncommitted typing }
    Put(Tit + '02/03.txt', '\v 3 ' + Words('phm0112', 1, 30) + ' ' + Words('fix', 1, 3) + '.');
    Git(Tit, '2026-03-05T10:00:00+0200', 'Editor', ['add', '--all']);
    Git(Tit, '2026-03-05T10:00:00+0200', 'Editor', ['commit', '-q', '-m', 'edit']);
    Put(Tit + '02/05.txt', '\v 5 ' + Words('jud0101', 1, 30) + ' typing.');

    Output := ListOf('cross-repair', ['--target-dir', Target], Code);
    Check((Code = 0) and (LineWith(Output, 'xx_tit_text_reg/01/05', 'restore') <> ''),
      'list: a chunk pasted over is restored');
    Check(LineWith(Output, 'xx_tit_text_reg/01/09', 'remove') <> '',
      'list: a chunk the damage added is removed');
    Check(LineWith(Output, 'xx_tit_text_reg/02/01', 'mixed') <> '',
      'list: a chunk whose own words changed too is mixed');
    Check(LineWith(Output, 'xx_tit_text_reg/02/03', 'edited since') <> '',
      'list: a chunk edited since is left alone');
    Check(LineWith(Output, 'xx_tit_text_reg/02/05', 'uncommitted') <> '',
      'list: a chunk with uncommitted changes is left alone');
    Check(LineWith(Output, 'xx_tit_text_reg/03/01', 'restore') <> '',
      'list: a chunk damaged by the second session is restored');
    Check(LineWith(Output, 'xx_tit_text_reg/01/05', 'Philemon 01/04') <> '',
      'list: says where the text came from');

    Before := CommitCount(Tit);
    Output := Run('cross-repair', ['--target-dir', Target, '--all', '--dry-run'], Code);
    Check((Code = 0) and (CommitCount(Tit) = Before) and
      (Pos('phm0104', ReadFileText(Tit + '01/05.txt')) > 0) and FileExists(Tit + '01/09.txt'),
      'the check changes nothing');
    Check((LineWith(Output, '01/05: would be restored', 'from before ') <> '') and
      (LineWith(Output, '01/09: would be removed') <> '') and
      (LineWith(Output, 'Uncommitted work would be committed first') <> ''),
      'the check says what would happen');
    Check(LineWith(Output, 'devices that sent the damage') = '',
      'the check does not tell you to upload');

    Output := Run('cross-repair', ['--target-dir', Target, '--all'], Code);
    Check(Code = 0, 'repairs');
    Check(ReadFileText(Tit + '01/05.txt') = '\v 5 ' + Words('tit0105', 1, 30) + '.',
      'pasted over twice: back to the version from before the first session');
    Check(ReadFileText(Tit + '03/01.txt') = '\v 1 ' + Words('tit0301', 1, 20) + '.',
      'pasted over by the second session: restored');
    Ids := Finished(Tit);
    Check(not FileExists(Tit + '01/09.txt') and not Contains(Ids, '01-09') and
      Contains(Ids, '01-05'), 'an added chunk is removed and no longer finished');
    Check(Pos('titedit', ReadFileText(Tit + '02/01.txt')) > 0,
      'a mixed chunk is left alone without --include-mixed');
    Check(Pos('fix', ReadFileText(Tit + '02/03.txt')) > 0, 'a chunk edited since is left alone');
    Check(Pos('typing', ReadFileText(Tit + '02/05.txt')) > 0,
      'a chunk with uncommitted changes is left alone');
    Check(ReadFileText(Tit + '01/title.txt') = 'Sura 1',
      'the rest of what the damaging commits did stays');
    Check(CommitCount(Tit) = Before + 2, 'loose work committed first, then one repair commit');
    Check(Trim(RunGit(Tit, ['log', '-1', '--format=%an']).Output) = 'BTT Workbench',
      'the repair commit is by BTT Workbench (not logged in), not the project''s user');
    Check(Trim(RunGit(Tit, ['log', '-2', '--format=%an']).Output.Split([#10])[1]) = 'Field User',
      'loose work is committed as the project''s own user');
    S := RunGit(Tit, ['log', '-1', '--format=%B']).Output;
    Check((Pos('01/05: restored from before ', S) > 0) and (Pos('01/09: removed (added by ', S) > 0),
      'the commit lists what was done');
    Check(Trim(RunGit(Tit, ['status', '--porcelain']).Output) = '', 'nothing left uncommitted');
    Check(LineWith(Output, 'Checked again: no text from other books is left') <> '',
      'checked again afterwards');
    Check(LineWith(Output, 'devices that sent the damage') <> '',
      'reminds that the field devices must re-import');

    Account := Default(TWacsAccount);
    Account.Server := 'https://wacs.example.org:8443/';
    Account.User := 'tech';
    Account.Token := 'not-a-real-token';
    SaveWacsAccount(Account);
    try
      RepairIdentity(Name, Email);
      Check((Name = 'tech') and (Email = 'tech@wacs.example.org'),
        'logged in to WACS: repairs are by that user');
    finally
      ClearWacsAccount;
    end;
    RepairIdentity(Name, Email);
    Check(Name = 'BTT Workbench', 'logged out: by BTT Workbench again');

    Output := Run('cross-repair', ['--target-dir', Target, '--chunk',
      'xx_tit_text_reg/02/01', '--include-mixed'], Code);
    Check((Code = 0) and (ReadFileText(Tit + '02/01.txt') = '\v 1 ' + Words('tit0201', 1, 25) + '.'),
      '--include-mixed repairs a mixed chunk');
    Output := Run('cross-repair', ['--target-dir', Target, '--chunk', 'xx_tit_text_reg/01/05'], Code);
    Check((Code = 0) and (LineWith(Output, 'not damaged now') <> ''),
      'an already repaired chunk is reported, not touched');
  finally
    BundledSourcesOverride := OldBundled;
  end;
end;

{ Made-up words that look like a language: syllables picked by a seeded
  generator, so two seeds give texts about as alike as two languages. }
function Gib(const Seed: string; Count: Integer): string;
const
  Syl: array[0..15] of string = ('ka', 'li', 'mu', 'to', 'sha', 'ne', 'bwa', 'ro',
    'fi', 'nyo', 'pe', 'za', 'ku', 'ye', 'di', 'mba');
var
  X: QWord;
  C: Char;
  I, J, N: Integer;
  W: string;
begin
  X := 1469598103;
  for C in Seed do
    X := (X xor Ord(C)) * 1099511628211;
  Result := '';
  for I := 1 to Count do
  begin
    X := X * 6364136223846793005 + 1442695040888963407;
    N := 2 + (X shr 60) mod 3;
    W := '';
    for J := 1 to N do
    begin
      X := X * 6364136223846793005 + 1442695040888963407;
      W := W + Syl[(X shr 59) and 15];
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + W;
  end;
end;

procedure TestSimilarity;
type
  TCase = record
    A, B: UnicodeString;
    Ratio, Dice: Double;
  end;
const
  { from Python: difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()
    and the trigram Dice of collections.Counter }
  Cases: array[0..8] of TCase = (
    (A: 'yesu alililile'; B: 'yesu alililile'; Ratio: 1.0; Dice: 1.0),
    (A: 'ilyo alaile libela muli bakasesema wakwe mumalembo ya mushilo';
     B: 'iyo alaile libela muli bakasesema wakwe mu malembo ya mushilo';
     Ratio: 0.983606557377; Dice: 0.932203389831),
    (A: 'abcd'; B: ''; Ratio: 0.0; Dice: 0.0),
    (A: ''; B: ''; Ratio: 1.0; Dice: 0.0),
    (A: 'the quick brown fox'; B: 'a quick brown dog jumps';
     Ratio: 0.666666666667; Dice: 0.578947368421),
    (A: 'muleba abatekanya kabili abashibuka umulwani wenu ciwa';
     B: 'muletekanya kabili mulelola umulwani wenu ciwa aleendauka';
     Ratio: 0.720720720721; Dice: 0.654205607477),
    (A: #$03B7#$03B3#$03AC#$03C0#$03B7#$03C3#$03B5#$03BD' '#$1F41' '#$03B8#$03B5#$1F78#$03C2;
     B: #$03B7#$03B3#$03AC#$03C0#$03B7#$03C3#$03B5' '#$03B8#$03B5#$03CC#$03C2' '#$1F41;
     Ratio: 0.758620689655; Dice: 0.48),
    (A: 'aaaaabbbbb'; B: 'bbbbbaaaaa'; Ratio: 0.5; Dice: 0.75),
    (A: 'abxcdxefg'; B: 'abcdefgx'; Ratio: 0.823529411765; Dice: 0.153846153846));
var
  C: TCase;
  OK: Boolean;
  VT: TVerseTexts;
begin
  Section('cross-check: likeness of texts');
  OK := True;
  for C in Cases do
    if Abs(SequenceRatio(C.A, C.B) - C.Ratio) > 1e-9 then
      OK := False;
  Check(OK, 'SequenceRatio gives difflib''s ratio');
  OK := True;
  for C in Cases do
    if Abs(TrigramDice(C.A, C.B) - C.Dice) > 1e-9 then
      OK := False;
  Check(OK, 'TrigramDice as computed in Python');
  VT := VerseWordTexts('\c 1 \v 1 Mwe, Bantu! \v 2-3 Ni\f + \ft note\f* ba \v 1 again');
  Check((Length(VT) = 2) and (VT[0].Verse = 1) and (VT[0].Text = 'mwe bantu again') and
    (VT[1].Verse = 2) and (VT[1].Text = 'ni note ba'),
    'verse words: lower case, markers out, a range counts as its first verse');
end;

procedure TestLanguageGroup;
begin
  Section('cross-check language groups');
  Check(LanguageGroup('mxc-MZ-x-manika') = 'mxc', 'a code''s group is its first part');
  Check(LanguageGroup('mxc-MZ-chimanika') = 'mxc', 'so variants of a language meet');
  Check(LanguageGroup('EN') = 'en', 'a bare code is its own group, lower case');
  Check(LanguageGroup('qaa-x-abc') = 'qaa-x-abc', 'private-use codes are not grouped');
  Check(LanguageGroup('qtz-x-abc') = 'qtz-x-abc', 'up to qtz');
  Check(LanguageGroup('x-abc') = 'x-abc', 'nor are x- codes');
end;

procedure TestTitlesAndOtherLanguages(const TempRoot: string);
var
  Data, Other, Lib, Tit, Phm, Ref1, Output, S, OldBundled: string;
  Code: Integer;
begin
  Section('cross-check: titles and other languages');
  Data := TempRoot + 'crosswide' + PathDelim;
  Lib := Data + 'library' + PathDelim + 'resource_containers' + PathDelim;
  OldBundled := BundledSourcesOverride;
  BundledSourcesOverride := TempRoot + 'no-bundled-sources';
  try
    { another language, yy, in a folder of its own, and the language itself
      under another code there (never compared) }
    Other := Data + 'other' + PathDelim;
    Target := Other;
    Ref1 := Gib('yy-tit-1-1', 14);
    MakeProject('tit', [
      '01/01.txt=\v 1 ' + Ref1 + '.',
      '01/05.txt=\v 5 ' + Gib('yy-tit-1-5', 16) + ' \v 6 ' + Gib('yy-tit-1-6', 14) + '.'], 'yy');
    MakeProject('tit', ['02/01.txt=\v 1 ' + Gib('xx-tit-2-1', 14) + '.'], 'xx-x-old');
    { a source text in a third language, zz }
    Put(Lib + 'zz_tit_ulb/content/02/03.usx',
      '<verse number="3" style="v" />' + Gib('zz-tit-2-3', 14) + '.');

    Target := Data + 'targetTranslations' + PathDelim;
    Tit := MakeProject('tit', [
      'front/title.txt=Kalito',
      '01/title.txt=Sura 1',
      '01/01.txt=\v 1 ' + Gib('xx-tit-1-1', 14) + '.',
      '02/title.txt=Sura 2',
      '02/01.txt=\v 1 ' + Gib('xx-tit-2-1', 14) + '.',
      '02/03.txt=\v 3 ' + Gib('xx-tit-2-3', 14) + '.']);
    Phm := MakeProject('phm', [
      'front/title.txt=Pilimona',
      '01/01.txt=\v 1 ' + Gib('xx-phm-1-1', 30) + '.']);

    { one session: Philemon's title and a Philemon chunk pasted into Titus,
      a chapter title with the wrong number, a verse reworded to read like
      yy, a verse of the zz source pasted in, and yy's 01/05 as a new chunk }
    Put(Tit + 'front/title.txt', 'Pilimona');
    Put(Tit + '02/title.txt', 'Sura 5');
    Put(Tit + '01/05.txt', '\v 1 ' + Gib('xx-phm-1-1', 30) + '.');
    Put(Tit + '01/01.txt', '\v 1 ' + Copy(Ref1, 1, LastDelimiter(' ', Ref1)) + 'mbaka.');
    Put(Tit + '02/03.txt', '\v 3 ' + Gib('zz-tit-2-3', 14) + '.');
    Put(Tit + '03/01.txt', '\v 1 ' + Gib('yy-tit-1-5', 16) + ' ' + Gib('yy-tit-1-6', 14) + '.');
    Git(Tit, '2026-03-01T10:00:00+0200', 'Paster', ['add', '--all']);
    Git(Tit, '2026-03-01T10:00:00+0200', 'Paster', ['commit', '-q', '-m', 'session']);

    Output := Run('cross-check', ['--target-dir', Target], Code);
    Check((Code = 0) and (LineWith(Output, 'front/title: the book title "Pilimona" is also ' +
      'the title of Philemon', 'Paster') <> ''),
      'a book title another book has is reported, with the commit');
    Check(LineWith(Output, 'front/title: the book title "Pilimona" is also the title of Titus') <> '',
      'on both books: neither is assumed to be the original');
    Check(LineWith(Output, '02/title: the chapter title "Sura 5" has another chapter''s number') <> '',
      'a chapter title with another chapter''s number');
    Check(LineWith(Output, '01/title:') = '', 'a right chapter title is not reported');
    Check((LineWith(Output, 'reworded') = '') and (LineWith(Output, 'Also compared') = ''),
      'other languages only on request');

    Output := Run('cross-check', ['--target-dir', Target, '--compare-dir', Other, '--sources'], Code);
    Check((Code = 0) and (LineWith(Output, 'Also compared with 2 text(s) in other languages') <> ''),
      'compares with the other folder and the source texts, not the language''s own code');
    S := LineWith(Output, '01/01: verse 1 was reworded to read like Lang xx (yy), yy_tit_text_reg');
    Check((S <> '') and (Pos('Paster', S) > 0), 'a verse reworded to read like another language');
    Check(LineWith(Output, '02/03: verse 3 is the same as in the source text zz_tit_ulb') <> '',
      'a verse pasted from a source text');
    Check(LineWith(Output, '03/01: 100% of its text is in Lang xx (yy), yy_tit_text_reg 01/05') <> '',
      'a chunk taken from another language');
    Check(LineWith(Output, '02/01: verse') = '', 'the language under another code is not foreign');
    Check(LineWith(Output, '01/05: verse') = '', 'nor is another book of the language');

    Output := Run('cross-check', ['--target-dir', Target, '--compare-dir', Other, '--no-history'], Code);
    Check((Code = 0) and (LineWith(Output, 'reworded') = '') and
      (LineWith(Output, '03/01: 100% of its text') <> ''),
      'without history: no rewording, the rest still');

    Output := Run('cross-check', ['--target-dir', Target, '--compare-dir', Data + 'nowhere'], Code);
    Check(Code = 1, 'a missing folder to compare with is an error');

    Output := Run('cross-repair', ['--target-dir', Target, '--all'], Code);
    Check((Code = 0) and (Trim(ReadFileText(Tit + 'front' + PathDelim + 'title.txt')) = 'Kalito'),
      'cross-repair gives a book title brought in with copied text its own back');
    Check(Trim(ReadFileText(Phm + 'front' + PathDelim + 'title.txt')) = 'Pilimona',
      'and leaves the other book''s alone');
    Check(Trim(ReadFileText(Tit + '02' + PathDelim + 'title.txt')) = 'Sura 5',
      'a wrong chapter number is only reported');
  finally
    BundledSourcesOverride := OldBundled;
  end;
end;

procedure TestCrossChecks(const TempRoot: string);
begin
  TestLanguageGroup;
  TestParseLog;
  TestTokenize;
  TestSimilarity;
  TestModule(TempRoot);
  TestRepair(TempRoot);
  TestTitlesAndOtherLanguages(TempRoot);
end;

end.
