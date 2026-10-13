unit TestWacs;

{$mode objfpc}{$H+}

(* Tests for the WACS modules against FakeWacs (no network). *)

interface

procedure TestWacsModules(const TempRoot: string);

implementation

uses
  Classes, SysUtils, {$IFDEF UNIX}BaseUnix,{$ENDIF}
  WBReporter, WBSettings, WBWacs, WBGitea, WBBielCatalog, FakeWacs, TestUtil;

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

procedure TestWacsModules(const TempRoot: string);
begin
  StartFakeWacs(TempRoot + 'wacs');
  try
    TestAccount;
    TestBiel;
  finally
    StopFakeWacs;
  end;
end;

end.
