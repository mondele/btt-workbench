unit WBWacs;

{$mode objfpc}{$H+}

{ The saved WACS login and git access to WACS repos.

  The login is a Gitea token made by the wacs-account module, saved with
  the user name in BTT Workbench's settings file ([wacs] server, username,
  token, token_id; owner-only on Unix). The password is never saved.

  git talks to WACS over HTTPS. When logged in, the token goes to git as
  an http.extraHeader through GIT_CONFIG_COUNT/KEY/VALUE environment
  variables (git 2.31+), so it is not in the process list and never lands
  in a project's .git/config. Older git gets it with -c instead, which
  other users of the machine could see in the process list. }

interface

uses
  Classes, SysUtils, WBGit, WBGitea;

type
  TWacsAccount = record
    Server, User, Token: string;
    TokenId: Int64;
  end;

{ The WACS server: BTW_WACS_SERVER, else the saved one, else WACS. }
function WacsServer: string;
function LoadWacsAccount: TWacsAccount;
function LoggedIn(const A: TWacsAccount): Boolean;
procedure SaveWacsAccount(const A: TWacsAccount);
procedure ClearWacsAccount;
{ A Gitea client for the server, with the saved token if logged in. }
function WacsClient(const A: TWacsAccount): TGiteaClient;
{ git with the account's token for HTTPS (no token: plain RunGit). }
function RunGitAs(const A: TWacsAccount; const WorkDir: string;
  const Args: array of string): TGitResult;

var
  { Set by tests (a fake server on localhost). }
  WacsServerOverride: string = '';

implementation

uses
  base64, WBSettings, WBHttp;

const
  WacsSection = 'wacs';

function WacsServer: string;
begin
  Result := WacsServerOverride;
  if Result = '' then
    Result := Trim(GetEnvironmentVariable('BTW_WACS_SERVER'));
  if Result = '' then
    Result := GetSettingIn(WacsSection, 'server');
  if Result = '' then
    Result := DefaultWacsServer;
end;

function LoadWacsAccount: TWacsAccount;
begin
  Result.Server := WacsServer;
  Result.User := GetSettingIn(WacsSection, 'username');
  Result.Token := GetSettingIn(WacsSection, 'token');
  Result.TokenId := StrToInt64Def(GetSettingIn(WacsSection, 'token_id'), 0);
  { A login belongs to the server it was made on. }
  if (GetSettingIn(WacsSection, 'server') <> '') and
     (GetSettingIn(WacsSection, 'server') <> Result.Server) then
  begin
    Result.User := '';
    Result.Token := '';
    Result.TokenId := 0;
  end;
end;

function LoggedIn(const A: TWacsAccount): Boolean;
begin
  Result := (A.User <> '') and (A.Token <> '');
end;

procedure SaveWacsAccount(const A: TWacsAccount);
begin
  SetSettingIn(WacsSection, 'server', A.Server);
  SetSettingIn(WacsSection, 'username', A.User);
  SetSettingIn(WacsSection, 'token', A.Token);
  SetSettingIn(WacsSection, 'token_id', IntToStr(A.TokenId));
end;

procedure ClearWacsAccount;
begin
  SetSettingIn(WacsSection, 'username', '');
  SetSettingIn(WacsSection, 'token', '');
  SetSettingIn(WacsSection, 'token_id', '');
end;

function WacsClient(const A: TWacsAccount): TGiteaClient;
begin
  Result := TGiteaClient.Create(A.Server);
  if LoggedIn(A) then
    Result.Auth := TokenAuth(A.Token);
end;

function RunGitAs(const A: TWacsAccount; const WorkDir: string;
  const Args: array of string): TGitResult;
var
  Header: string;
  All: array of string;
  I: Integer;
begin
  if not LoggedIn(A) then
    Exit(RunGit(WorkDir, Args));
  { Gitea takes the token as the password of Basic auth over git HTTP. }
  Header := 'Authorization: Basic ' + EncodeStringBase64(A.User + ':' + A.Token);
  if GitAtLeast(2, 31) then
    Exit(RunGitEnv(WorkDir, Args, ['GIT_CONFIG_COUNT=1',
      'GIT_CONFIG_KEY_0=http.extraHeader', 'GIT_CONFIG_VALUE_0=' + Header]));
  All := ['-c', 'http.extraHeader=' + Header];
  SetLength(All, 2 + Length(Args));
  for I := 0 to High(Args) do
    All[2 + I] := Args[I];
  Result := RunGit(WorkDir, All);
end;

end.
