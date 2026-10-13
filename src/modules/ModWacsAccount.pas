unit ModWacsAccount;

{$mode objfpc}{$H+}

{ wacs-account: log in to WACS once, so wacs-download and wacs-upload can
  work with the user's repos (and private ones). Like BTT-Writer Desktop
  (user.js): the user name and password make a Gitea token, after deleting
  any earlier token of ours with the same name; only the token is kept
  (WBWacs). The password is never saved.
  - --username (password asked for, or --password): log in.
  - --logout: forget the login. Gitea only lets a token be deleted with
    the password, so with --password it is also deleted on WACS; without,
    the next login on this machine replaces it.
  - no options: show the server and who is logged in, checking the token.
  --server picks another Gitea server (e.g. WACS dev) for the login. }

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TWacsAccountModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  WBHttp, WBGitea, WBWacs;

resourcestring
  rsTitle = 'WACS login';
  rsDescription = 'Logs in to WACS so projects can be downloaded and uploaded. ' +
    'Only a login token is kept on this computer, never the password.';
  rsOptServer = 'Server';
  rsOptServerHelp = 'The WACS (Gitea) server address';
  rsOptUsername = 'User name';
  rsOptUsernameHelp = 'Your WACS user name (log in)';
  rsOptPassword = 'Password';
  rsOptPasswordHelp = 'Your WACS password; it is not saved';
  rsOptLogout = 'Log out';
  rsOptLogoutHelp = 'Forget the saved login (with the password, also delete ' +
    'the token on WACS)';
  rsServer = 'Server: %s';
  rsNoPassword = 'A password is needed to log in.';
  rsLoggedIn = 'Logged in as %s%s. The login is saved as token "%s".';
  rsReplacedToken = 'Replaced the earlier token "%s".';
  rsLoginFailed = 'Login failed: %s';
  rsLoggedOut = 'Logged out.';
  rsTokenDeleted = 'The token was deleted on WACS.';
  rsTokenLeft = 'The token stays on WACS until you log in again from this ' +
    'computer, or remove it there under Settings, Applications.';
  rsTokenDeleteFailed = 'Could not delete the token on WACS (%s); it was ' +
    'forgotten here anyway.';
  rsNotLoggedIn = 'Not logged in.';
  rsStatusOk = 'Logged in as %s%s.';
  rsStatusBad = 'Saved login for %s no longer works (%s). Log in again.';

const
  TokenScopes: array of string = ('write:repository', 'write:user',
    'write:organization');

function NameSuffix(const FullName: string): string;
begin
  if FullName <> '' then
    Result := ' (' + FullName + ')'
  else
    Result := '';
end;

function TWacsAccountModule.Id: string;
begin
  Result := 'wacs-account';
end;

function TWacsAccountModule.Title: string;
begin
  Result := rsTitle;
end;

function TWacsAccountModule.Description: string;
begin
  Result := rsDescription;
end;

function TWacsAccountModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('username', okString, False, False, rsOptUsername, rsOptUsernameHelp),
    PasswordOptionDef('password', 'username', rsOptPassword, rsOptPasswordHelp),
    OptionDef('logout', okFlag, False, False, rsOptLogout, rsOptLogoutHelp),
    OptionDef('server', okString, False, False, rsOptServer, rsOptServerHelp)];
end;

function TWacsAccountModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  A: TWacsAccount;
  Client: TGiteaClient;
  User: TGiteaUser;
  Tokens: TGiteaTokens;
  T: TGiteaToken;
  Name, Password: string;
begin
  Result := 1;
  A := LoadWacsAccount;
  if Trim(Options.Values['server']) <> '' then
    A.Server := Trim(Options.Values['server']);
  Password := Options.Values['password'];
  Reporter.Info(Format(rsServer, [A.Server]));

  if OptionIsSet(Options, 'logout') then
  begin
    if LoggedIn(A) and (Password <> '') and (A.TokenId <> 0) then
    begin
      Client := TGiteaClient.Create(A.Server);
      try
        Client.Auth := BasicAuth(A.User, Password);
        try
          Client.DeleteToken(A.User, A.TokenId);
          Reporter.Info(rsTokenDeleted);
        except
          on E: Exception do
            Reporter.Warn(Format(rsTokenDeleteFailed, [E.Message]));
        end;
      finally
        Client.Free;
      end;
    end
    else if LoggedIn(A) then
      Reporter.Info(rsTokenLeft);
    ClearWacsAccount;
    Reporter.Info(rsLoggedOut);
    Exit(0);
  end;

  if Trim(Options.Values['username']) <> '' then
  begin
    if Password = '' then
    begin
      Reporter.Error(rsNoPassword);
      Exit;
    end;
    Name := WorkbenchTokenName;
    Client := TGiteaClient.Create(A.Server);
    try
      Client.Auth := BasicAuth(Trim(Options.Values['username']), Password);
      try
        User := Client.CurrentUser;
        Tokens := Client.ListTokens(User.Login);
        for T in Tokens do
          if T.Name = Name then
          begin
            Client.DeleteToken(User.Login, T.Id);
            Reporter.Info(Format(rsReplacedToken, [Name]));
          end;
        T := Client.CreateToken(User.Login, Name, TokenScopes);
      except
        on E: Exception do
        begin
          Reporter.Error(Format(rsLoginFailed, [E.Message]));
          Exit;
        end;
      end;
    finally
      Client.Free;
    end;
    A.User := User.Login;
    A.Token := T.Sha1;
    A.TokenId := T.Id;
    SaveWacsAccount(A);
    Reporter.Info(Format(rsLoggedIn, [User.Login, NameSuffix(User.FullName), Name]));
    Exit(0);
  end;

  { Status }
  if not LoggedIn(A) then
  begin
    Reporter.Info(rsNotLoggedIn);
    Exit(0);
  end;
  Client := WacsClient(A);
  try
    try
      User := Client.CurrentUser;
      Reporter.Info(Format(rsStatusOk, [User.Login, NameSuffix(User.FullName)]));
      Result := 0;
    except
      on E: Exception do
        Reporter.Warn(Format(rsStatusBad, [A.User, E.Message]));
    end;
  finally
    Client.Free;
  end;
  if Result <> 0 then
    Result := 1;
end;

initialization
  RegisterModule(TWacsAccountModule.Create);

end.
