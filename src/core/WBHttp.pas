unit WBHttp;

{$mode objfpc}{$H+}

{ Small HTTP(S) helper over fphttpclient for the WACS (Gitea) API and the
  BIEL Public Data API: JSON in and out, timeouts, our own User-Agent
  (Cloudflare in front of both servers blocks some default ones), Basic or
  token auth, readable errors, one retry of a GET on a 5xx or a dropped
  connection.

  On Windows requests go through WinHTTP (WBWinHttp), Windows' own client:
  TLS, certificates and proxies come from Windows, and no OpenSSL DLLs are
  needed. Elsewhere fphttpclient is used, and HTTPS needs OpenSSL at run
  time (opensslsockets), which Linux has. FPC 3.2.2 only looks for OpenSSL
  up to 1.1 on Unix; current Linux has only 3, so the initialization adds
  '.3' to the library versions it tries. }

interface

uses
  Classes, SysUtils, fpjson;

type
  EWBHttp = class(Exception)
  public
    Status: Integer;  // 0 when the server could not be reached
  end;

  TWBHttpAuthKind = (haNone, haBasic, haToken);
  TWBHttpAuth = record
    Kind: TWBHttpAuthKind;
    User, Secret: string;   // Basic: user and password; token: Secret
  end;

function NoAuth: TWBHttpAuth;
function BasicAuth(const User, Password: string): TWBHttpAuth;
function TokenAuth(const Token: string): TWBHttpAuth;

{ Method on URL with an optional JSON body. Returns the parsed JSON reply
  (nil for an empty one; the caller frees it). Raises EWBHttp for a
  network failure or a status of 400 and up. }
function HttpJson(const Method, URL: string; const Auth: TWBHttpAuth;
  Body: TJSONData = nil; TimeoutMs: Integer = 15000): TJSONData;
{ Like HttpJson, but returns the status instead of raising for 4xx/5xx
  (Reply holds whatever came back). Still raises when unreachable. }
function HttpJsonStatus(const Method, URL: string; const Auth: TWBHttpAuth;
  Body: TJSONData; TimeoutMs: Integer; out Reply: TJSONData): Integer;
{ Percent-encodes a query-string value. }
function UrlEncode(const S: string): string;

var
  HttpUserAgent: string = '';   // set from WBVersion at start-up

implementation

uses
  {$IFDEF WINDOWS}WBWinHttp,{$ELSE}fphttpclient, opensslsockets, openssl,{$ENDIF}
  jsonparser, base64, WBVersion;

resourcestring
  rsUnreachable = 'Could not reach %s (%s).';
  rsBadLogin = 'The server did not accept the user name and password (or the ' +
    'saved login has expired).';
  rsForbidden = 'Not allowed: %s';
  rsNotFound = 'Not found: %s';
  rsServerSaid = 'The server answered %d: %s';
  { Windows only (WinHTTP); declared everywhere so the .pot has them. }
  rsTimedOut = 'no answer in time';
  rsNameNotResolved = 'server name not found; check the internet connection';
  rsCannotConnect = 'could not connect';
  rsConnectionError = 'the connection was broken off';
  rsSecureFailure = 'the secure connection failed (certificate or TLS problem)';
  rsBadUrl = 'not a valid address';
  rsWindowsError = 'Windows error %d';

function NoAuth: TWBHttpAuth;
begin
  Result.Kind := haNone;
  Result.User := '';
  Result.Secret := '';
end;

function BasicAuth(const User, Password: string): TWBHttpAuth;
begin
  Result.Kind := haBasic;
  Result.User := User;
  Result.Secret := Password;
end;

function TokenAuth(const Token: string): TWBHttpAuth;
begin
  Result.Kind := haToken;
  Result.User := '';
  Result.Secret := Token;
end;

function UrlEncode(const S: string): string;
const
  Safe = ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'];
var
  C: Char;
begin
  Result := '';
  for C in S do
    if C in Safe then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Ord(C), 2);
end;

function HostOf(const URL: string): string;
var
  P: Integer;
begin
  Result := URL;
  P := Pos('://', Result);
  if P > 0 then
    Delete(Result, 1, P + 2);
  P := Pos('/', Result);
  if P > 0 then
    SetLength(Result, P - 1);
end;

function RaiseHttp(const Msg: string; Status: Integer): EWBHttp;
begin
  Result := EWBHttp.Create(Msg);
  Result.Status := Status;
end;

function AgentName: string;
begin
  if HttpUserAgent <> '' then
    Result := HttpUserAgent
  else
    Result := 'btt-workbench/' + WorkbenchVersion;
end;

function AuthHeader(const Auth: TWBHttpAuth): string;
begin
  case Auth.Kind of
    haBasic: Result := 'Basic ' + EncodeStringBase64(Auth.User + ':' + Auth.Secret);
    haToken: Result := 'token ' + Auth.Secret;
  else
    Result := '';
  end;
end;

{$IFDEF WINDOWS}
function FailureText(Code: Cardinal): string;
begin
  case Code of
    WinHttpErrTimeout: Result := rsTimedOut;
    WinHttpErrNameNotResolved: Result := rsNameNotResolved;
    WinHttpErrCannotConnect: Result := rsCannotConnect;
    WinHttpErrConnectionError: Result := rsConnectionError;
    WinHttpErrSecureFailure: Result := rsSecureFailure;
    WinHttpErrBadUrl: Result := rsBadUrl;
  else
    Result := Format(rsWindowsError, [Code]);
  end;
end;

{ One request; Status 0 means it never got an answer. }
function Request(const Method, URL: string; const Auth: TWBHttpAuth;
  const Body: string; TimeoutMs: Integer; out Status: Integer;
  out Failure: string): string;
var
  Headers: string;
  Code: Cardinal;
begin
  Failure := '';
  Headers := 'Accept: application/json'#13#10;
  if Auth.Kind <> haNone then
    Headers := Headers + 'Authorization: ' + AuthHeader(Auth) + #13#10;
  if Body <> '' then
    Headers := Headers + 'Content-Type: application/json'#13#10;
  Result := WinHttpRequest(Method, URL, AgentName, Headers, Body, 15000, TimeoutMs,
    Status, Code);
  if Status = 0 then
    Failure := FailureText(Code);
end;
{$ELSE}
{ One request; Status 0 means it never got an answer. }
function Request(const Method, URL: string; const Auth: TWBHttpAuth;
  const Body: string; TimeoutMs: Integer; out Status: Integer;
  out Failure: string): string;
var
  Http: TFPHTTPClient;
  Sent: TStringStream;
  Got: TStringStream;
begin
  Result := '';
  Status := 0;
  Failure := '';
  Http := TFPHTTPClient.Create(nil);
  Got := TStringStream.Create('');
  Sent := nil;
  try
    Http.AllowRedirect := True;
    Http.ConnectTimeout := 15000;
    Http.IOTimeout := TimeoutMs;
    Http.AddHeader('User-Agent', AgentName);
    Http.AddHeader('Accept', 'application/json');
    if Auth.Kind <> haNone then
      Http.AddHeader('Authorization', AuthHeader(Auth));
    if Body <> '' then
    begin
      Sent := TStringStream.Create(Body);
      Http.RequestBody := Sent;
      Http.AddHeader('Content-Type', 'application/json');
    end;
    try
      Http.HTTPMethod(Method, URL, Got, []);
      Status := Http.ResponseStatusCode;
      Result := Got.DataString;
    except
      on E: Exception do
      begin
        Status := 0;
        Failure := E.Message;
      end;
    end;
  finally
    Sent.Free;
    Got.Free;
    Http.Free;
  end;
end;
{$ENDIF}

function ServerMessage(Reply: TJSONData; const Raw: string): string;
begin
  Result := '';
  if (Reply is TJSONObject) and (TJSONObject(Reply).Find('message') <> nil) then
    Result := TJSONObject(Reply).Get('message', '')
  else if (Reply is TJSONObject) and (TJSONObject(Reply).Find('errors') <> nil) then
    Result := TJSONObject(Reply).Find('errors').AsJSON;
  if (Result = '') and (Reply is TJSONString) then
    Result := Copy(Trim(Reply.AsString), 1, 200);
  if Result = '' then
    Result := Copy(Trim(Raw), 1, 200);
end;

function HttpJsonStatus(const Method, URL: string; const Auth: TWBHttpAuth;
  Body: TJSONData; TimeoutMs: Integer; out Reply: TJSONData): Integer;
var
  Raw, BodyText, Failure: string;
  Attempt: Integer;
begin
  Reply := nil;
  BodyText := '';
  if Body <> nil then
    BodyText := Body.AsJSON;
  Result := 0;
  Raw := '';
  for Attempt := 1 to 2 do
  begin
    Raw := Request(Method, URL, Auth, BodyText, TimeoutMs, Result, Failure);
    { Retry a read once if it failed for reasons that may pass. }
    if (Method <> 'GET') or ((Result <> 0) and (Result < 500)) then
      Break;
  end;
  if Result = 0 then
    raise RaiseHttp(Format(rsUnreachable, [HostOf(URL), Failure]), 0);
  if Trim(Raw) <> '' then
    try
      Reply := GetJSON(Raw, True);
    except
      Reply := TJSONString.Create(Raw);   // not JSON (an error page, say)
    end;
end;

function HttpJson(const Method, URL: string; const Auth: TWBHttpAuth;
  Body: TJSONData; TimeoutMs: Integer): TJSONData;
var
  Status: Integer;
  Msg: string;
begin
  Status := HttpJsonStatus(Method, URL, Auth, Body, TimeoutMs, Result);
  if Status < 400 then
    Exit;
  try
    case Status of
      401: Msg := rsBadLogin;
      403: Msg := Format(rsForbidden, [ServerMessage(Result, '')]);
      404: Msg := Format(rsNotFound, [URL]);
    else
      Msg := Format(rsServerSaid, [Status, ServerMessage(Result, '')]);
    end;
  finally
    FreeAndNil(Result);
  end;
  raise RaiseHttp(Msg, Status);
end;

initialization
  {$IF DEFINED(UNIX) and not DEFINED(DARWIN)}
  { Replace the oldest version FPC 3.2.2 tries (0.9.1) with 3. }
  if DLLVersions[High(DLLVersions)] = '.0.9.1' then
    DLLVersions[High(DLLVersions)] := '.3';
  {$ENDIF}

end.
