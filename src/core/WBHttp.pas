unit WBHttp;

{$mode objfpc}{$H+}

{ Small HTTP(S) helper over fphttpclient for the WACS (Gitea) API and the
  BIEL Public Data API: JSON in and out, timeouts, our own User-Agent
  (Cloudflare in front of both servers blocks some default ones), Basic or
  token auth, readable errors, one retry of a GET on a 5xx or a dropped
  connection. HTTPS needs OpenSSL at run time (opensslsockets): present
  on Linux, shipped as DLLs on Windows. }

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
  fphttpclient, opensslsockets, jsonparser, base64, WBVersion;

resourcestring
  rsUnreachable = 'Could not reach %s (%s).';
  rsBadLogin = 'The server did not accept the user name and password (or the ' +
    'saved login has expired).';
  rsForbidden = 'Not allowed: %s';
  rsNotFound = 'Not found: %s';
  rsServerSaid = 'The server answered %d: %s';

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
    if HttpUserAgent <> '' then
      Http.AddHeader('User-Agent', HttpUserAgent)
    else
      Http.AddHeader('User-Agent', 'btt-workbench/' + WorkbenchVersion);
    Http.AddHeader('Accept', 'application/json');
    case Auth.Kind of
      haBasic: Http.AddHeader('Authorization',
        'Basic ' + EncodeStringBase64(Auth.User + ':' + Auth.Secret));
      haToken: Http.AddHeader('Authorization', 'token ' + Auth.Secret);
    end;
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

end.
