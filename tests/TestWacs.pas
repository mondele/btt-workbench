unit TestWacs;

{$mode objfpc}{$H+}

(* Tests for the WACS modules against FakeWacs (no network). *)

interface

procedure TestWacsModules(const TempRoot: string);

implementation

uses
  Classes, SysUtils, {$IFDEF UNIX}BaseUnix,{$ENDIF} WBCommandLine,
  WBReporter, WBModule, WBSettings, WBWacs, WBGitea, WBBielCatalog, WBGit, FakeWacs, TestUtil;

var
  Root, Target: string;

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

{ A BTT-Writer project as a git repo at Dir (path=text files). }
procedure MakeProjectRepo(const Dir, Lang, Book, Kind, Res: string;
  const Files: array of string);
var
  F, Manifest: string;
  P: Integer;
begin
  ForceDirectories(Dir);
  Manifest := '{"package_version": 8, "target_language": {"id": "' + Lang +
    '", "name": "L", "direction": "ltr"}, "project": {"id": "' + Book +
    '", "name": "B"}, "type": {"id": "' + Kind + '", "name": "T"}';
  if Res <> '' then
    Manifest := Manifest + ', "resource": {"id": "' + Res + '", "name": "R"}';
  Manifest := Manifest + ', "source_translations": [], "finished_chunks": ["01-01"]}';
  WriteFileText(Dir + PathDelim + 'manifest.json', Manifest);
  for F in Files do
  begin
    P := Pos('=', F);
    ForceDirectories(ExtractFileDir(Dir + PathDelim + Copy(F, 1, P - 1)));
    WriteFileText(Dir + PathDelim + Copy(F, 1, P - 1), Copy(F, P + 1, MaxInt));
  end;
  Git(Dir, ['init', '-q']);
  Git(Dir, ['add', '--all']);
  Git(Dir, ['commit', '-q', '-m', 'start']);
end;

function Head(const Dir: string): string;
begin
  Result := Trim(RunGit(Dir, ['rev-parse', 'HEAD']).Output);
end;

function Run(const Module: string; const Args: array of string; out Output: string): Integer;
var
  R: TWBListReporter;
  I: Integer;
begin
  Result := RunModule(Module, Args, R);
  Output := '';
  for I := 0 to R.Count - 1 do
    Output := Output + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
  R.Free;
end;

procedure TestAccount;
var
  Output, Settings: string;
  A: TWacsAccount;
  {$IFDEF UNIX}
  St: Stat;
  {$ENDIF}
begin
  Section('wacs-account');
  Check((Run('wacs-account', [], Output) = 0) and (Pos('Not logged in.', Output) > 0),
    'status when not logged in');

  Check(Run('wacs-account', ['--username', 'alice', '--password', 'wrong'], Output) = 1,
    'wrong password refused');
  Check((Pos('Login failed: The server did not accept', Output) > 0) and
    not LoggedIn(LoadWacsAccount), '... with a readable error, nothing saved');
  Check(Run('wacs-account', ['--username', 'alice'], Output) = 1, 'no password refused');

  Check(Run('wacs-account', ['--username', 'alice', '--password', 'secret'], Output) = 0,
    'login');
  A := LoadWacsAccount;
  Check(Pos('Logged in as alice (Alice Tester). The login is saved as token "' +
    WorkbenchTokenName + '"', Output) > 0, '... reported with the token name');
  Check((A.User = 'alice') and (A.Token <> '') and (A.TokenId <> 0), '... token saved');
  Settings := ReadFileText(SettingsFile);
  Check(Pos('secret', Settings) = 0, '... password not saved');
  {$IFDEF UNIX}
  Check((FpStat(SettingsFile, St) = 0) and ((St.st_mode and &777) = &600),
    '... settings file readable by its owner only');
  {$ENDIF}

  Check((Run('wacs-account', ['--username', 'alice', '--password', 'secret'], Output) = 0) and
    (Pos('Replaced the earlier token', Output) > 0) and (FakeTokenCount('alice') = 1),
    'second login replaces our token');

  ClearFakeRequests;
  Check((Run('wacs-account', [], Output) = 0) and (Pos('Logged in as alice', Output) > 0),
    'status checks the saved token');
  Check(Pos('GET /api/v1/user token', FakeRequests.Text) > 0, '... using token auth');

  Check((Run('wacs-account', ['--logout'], Output) = 0) and
    (Pos('stays on WACS', Output) > 0) and not LoggedIn(LoadWacsAccount) and
    (FakeTokenCount('alice') = 1), 'logout without password forgets it here only');

  Run('wacs-account', ['--username', 'alice', '--password', 'secret'], Output);
  Check((Run('wacs-account', ['--logout', '--password', 'secret'], Output) = 0) and
    (Pos('deleted on WACS', Output) > 0) and (FakeTokenCount('alice') = 0),
    'logout with password deletes the token on WACS');

  Run('wacs-account', ['--username', 'bob', '--password', 'pw'], Output);
  SetSettingIn('wacs', 'token', 'revoked');
  Check((Run('wacs-account', [], Output) = 1) and (Pos('no longer works', Output) > 0),
    'a token that stopped working is reported');
  ClearWacsAccount;
end;

procedure TestBiel;
var
  States: TBielStates;
  Err: string;
begin
  Section('BIEL states');
  AddFakeRepo('alice', 'aaa_tit_text_reg', 'Primary', False, '', []);
  AddFakeRepo('bob', 'aaa_tit_text_reg', 'Inactive', False, '', []);
  AddFakeRepo('bob', 'aaaxtitxtextxreg', 'Active', False, '', []);
  Check(BielStates(['aaa_tit_'], States, Err), 'query runs: ' + Err);
  Check((Length(States) = 2) and (BielStateOf(States, 'Alice/aaa_tit_text_reg') = 'Primary') and
    (BielStateOf(States, 'bob/aaa_tit_text_reg') = 'Inactive'),
    'states by owner/repo; "_" matched literally, not as a wildcard');
end;

function ChoiceLines(const Args: array of string; out Ok: Boolean): string;
var
  R: TWBListReporter;
  Options, ArgList: TStringList;
  Err, A: string;
  List: TWBChoiceList;
  I: Integer;
begin
  Result := '';
  R := TWBListReporter.Create;
  Options := TStringList.Create;
  ArgList := TStringList.Create;
  try
    for A in Args do
      ArgList.Add(A);
    ParseModuleArgs(FindModule('wacs-download'), ArgList, Options, Err);
    Ok := FindModule('wacs-download').Choices('repo', Options, R, List);
    for I := 0 to High(List.Items) do
      Result := Result + List.Items[I].Value + ' | ' + String.Join(' | ', List.Items[I].Columns) + #10;
    for I := 0 to R.Count - 1 do
      Result := Result + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
  finally
    ArgList.Free;
    Options.Free;
    R.Free;
  end;
end;

procedure TestDownload;
var
  Src, Output, Proj, Before, List: string;
  Ok: Boolean;
begin
  Section('wacs-download');
  Src := Root + 'src' + PathDelim;
  MakeProjectRepo(Src + 'a1', 'ddd', 'tit', 'text', 'reg', ['01/01.txt=\v 1 alice', '01/02.txt=\v 2 two']);
  { bob's copy starts from alice's, then changes 01/01 differently. }
  Git(Src, ['clone', '-q', Src + 'a1', Src + 'b1']);
  WriteFileText(Src + 'b1' + PathDelim + '01' + PathDelim + '01.txt', '\v 1 bob');
  Git(Src + 'b1', ['commit', '-q', '-am', 'bob']);
  WriteFileText(Src + 'a1' + PathDelim + '01' + PathDelim + '01.txt', '\v 1 alice again');
  Git(Src + 'a1', ['commit', '-q', '-am', 'alice']);
  MakeProjectRepo(Src + 'm1', 'ddd', 'mat', 'text', 'reg', ['01/01.txt=\v 1 m']);
  MakeProjectRepo(Src + 'n1', 'ddd', 'tit', 'tn', '', ['01/01.txt=note']);
  MakeProjectRepo(Src + 'x1', 'xddd', 'tit', 'text', 'reg', ['01/01.txt=\v 1 x']);
  AddFakeRepo('alice', 'ddd_tit_text_reg', 'Primary', False, Src + 'a1', []);
  AddFakeRepo('bob', 'ddd_tit_text_reg', 'Inactive', False, Src + 'b1', []);
  AddFakeRepo('team', 'ddd_mat_text_reg', 'Active', True, Src + 'm1', ['consolidated']);
  AddFakeRepo('alice', 'ddd_tit_tn', '', False, Src + 'n1', []);
  AddFakeRepo('bob', 'xddd_tit_text_reg', '', False, Src + 'x1', []);
  AddFakeRepo('bob', 'ddd_jon_text_reg', '', False, '', []);   // empty

  { Finding }
  List := ChoiceLines(['--language', 'ddd', '--target-dir', Target], Ok);
  Check(Ok and (Pos('alice/ddd_tit_text_reg | Primary | 2026-01-02 | new |', List) > 0) and
    (Pos('bob/ddd_tit_text_reg | Inactive', List) > 0) and (Pos('alice/ddd_tit_tn |  |', List) > 0) and
    (Pos('xddd', List) = 0) and (Pos('team/', List) = 0),
    'list by language: exact language, states, private repos hidden when not logged in');
  Check(Pos('bob/ddd_jon_text_reg |  | 2026-01-02 | new | empty', List) > 0, 'empty repos marked');
  List := ChoiceLines(['--language', 'ddd', '--type', 'text', '--book', 'tit'], Ok);
  Check(Ok and (Pos('ddd_tit_tn', List) = 0) and (Pos('alice/ddd_tit_text_reg', List) > 0),
    'type and book filters');
  List := ChoiceLines(['--owner', 'bob', '--language', 'ddd'], Ok);
  Check(Ok and (Pos('bob/ddd_tit_text_reg', List) > 0) and (Pos('alice/', List) = 0), 'owner filter');
  List := ChoiceLines(['--owner', 'nobody'], Ok);
  Check(not Ok and (Pos('no WACS user or organisation called nobody', List) > 0), 'unknown owner');
  List := ChoiceLines([], Ok);
  Check(not Ok and (Pos('at least one language', List) > 0), 'a filter is required');

  Run('wacs-account', ['--username', 'alice', '--password', 'secret'], Output);
  List := ChoiceLines(['--language', 'ddd', '--book', 'mat', '--no-state'], Ok);
  Check(Ok and (Pos('team/ddd_mat_text_reg |  | 2026-01-02 | new | consolidated, private', List) > 0),
    'logged in: private organisation repo listed, topics and privacy noted; --no-state');
  Run('wacs-account', ['--logout'], Output);

  { Downloading }
  Proj := Target + 'ddd_tit_text_reg';
  Check((Run('wacs-download', ['--repo', 'alice/ddd_tit_text_reg', '--target-dir', Target,
    '--dry-run'], Output) = 0) and not DirectoryExists(Proj), 'check changes nothing');
  Check(Run('wacs-download', ['--repo', 'alice/ddd_tit_text_reg', '--repo', 'ALICE/ddd_tit_text_reg',
    '--target-dir', Target], Output) = 0, 'download a new project');
  Check((Pos('listed more than once', Output) > 0) and
    (ReadFileText(Proj + PathDelim + '01' + PathDelim + '01.txt') = '\v 1 alice again'),
    '... once, with its files');
  Check((Trim(RunGit(Proj, ['remote']).Output) = '') and
    (Pos('Authorization', ReadFileText(Proj + PathDelim + '.git' + PathDelim + 'config')) = 0),
    '... no remote and no credentials left in .git/config');

  Before := Head(Proj);
  Check((Run('wacs-download', ['--repo', 'bob/ddd_tit_text_reg', '--target-dir', Target], Output) = 1) and
    (Pos('Choose merge or overwrite', Output) > 0) and (Head(Proj) = Before),
    'existing project: stop by default');
  Check((Run('wacs-download', ['--repo', 'bob/ddd_tit_text_reg', '--target-dir', Target,
    '--on-existing', 'merge'], Output) = 0) and (Pos('was not merged, because it would leave conflicts', Output) > 0) and
    (Pos('1 chunk(s) in conflict', Output) > 0) and (Head(Proj) = Before),
    'merge that would conflict is skipped by default, project unchanged');
  Check((Run('wacs-download', ['--repo', 'bob/ddd_tit_text_reg', '--target-dir', Target,
    '--on-existing', 'merge', '--on-conflict', 'commit', '--dry-run'], Output) = 0) and
    (Head(Proj) = Before), 'check of a committing merge changes nothing');
  Check((Run('wacs-download', ['--repo', 'bob/ddd_tit_text_reg', '--target-dir', Target,
    '--on-existing', 'merge', '--on-conflict', 'commit'], Output) = 0) and
    (Pos('<<<<<<< HEAD', ReadFileText(Proj + PathDelim + '01' + PathDelim + '01.txt')) > 0) and
    (Pos('"01-01"', ReadFileText(Proj + PathDelim + 'manifest.json')) = 0),
    'on-conflict commit merges with markers and un-finishes the chunk');

  Check((Run('wacs-download', ['--repo', 'team/ddd_mat_text_reg', '--target-dir', Target], Output) = 1) and
    (Pos('was not found on WACS (or it is private', Output) > 0), 'private repo needs a login');
  Run('wacs-account', ['--username', 'alice', '--password', 'secret'], Output);
  Check((Run('wacs-download', ['--repo', 'team/ddd_mat_text_reg', '--target-dir', Target], Output) = 0) and
    DirectoryExists(Target + 'ddd_mat_text_reg'), '... and downloads when logged in');
  Run('wacs-account', ['--logout'], Output);

  Check((Run('wacs-download', ['--repo', 'bob/ddd_jon_text_reg', '--target-dir', Target], Output) = 0) and
    (Pos('is empty. Skipped.', Output) > 0), 'empty repo skipped');
  Check((Run('wacs-download', ['--language', 'ddd', '--book', 'tit', '--type', 'tn', '--all',
    '--target-dir', Target], Output) = 0) and DirectoryExists(Target + 'ddd_tit_tn'),
    '--all downloads everything the filters find');
  Check((Run('wacs-download', ['--repo', 'not-a-repo', '--target-dir', Target], Output) = 1) and
    (Pos('is not an owner/name repo', Output) > 0), 'bad repo name refused');
end;

procedure TestWacsModules(const TempRoot: string);
begin
  Root := TempRoot + 'wacs' + PathDelim;
  Target := Root + 'data' + PathDelim + 'targetTranslations' + PathDelim;
  ForceDirectories(Target);
  StartFakeWacs(Root);
  try
    TestAccount;
    TestBiel;
    TestDownload;
  finally
    StopFakeWacs;
  end;
end;

end.
