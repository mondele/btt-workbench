unit WBWinHttp;

{$mode objfpc}{$H+}

(* HTTP(S) requests through Windows' own client, WinHTTP (winhttp.dll, part
   of every Windows). TLS, certificates (the Windows store) and proxies are
   Windows' business, kept current by Windows Update, so the program needs
   no OpenSSL DLLs. Used by WBHttp on Windows only.

   The few functions needed are declared here: FPC 3.2.2's winhttp unit
   declares WinHttpSetTimeouts under the wrong name. *)

interface

{$IFDEF WINDOWS}

{ Method on URL. Headers are "Name: value" lines separated by CR LF; Body
  is sent as is. Status is the HTTP status, or 0 with ErrorCode set (a
  Windows or WinHTTP error number) when no answer came. }
function WinHttpRequest(const Method, URL, UserAgent, Headers, Body: string;
  ConnectMs, TimeoutMs: Integer; out Status: Integer; out ErrorCode: Cardinal): string;

const
  { WinHTTP errors worth their own message. }
  WinHttpErrTimeout = 12002;
  WinHttpErrNameNotResolved = 12007;
  WinHttpErrCannotConnect = 12029;
  WinHttpErrConnectionError = 12030;
  WinHttpErrSecureFailure = 12175;
  WinHttpErrBadUrl = 12005;

{$ENDIF}

implementation

{$IFDEF WINDOWS}

uses
  SysUtils, Windows;

type
  HINTERNET = Pointer;

const
  WinHttpDll = 'winhttp.dll';
  ACCESS_TYPE_DEFAULT_PROXY = 0;
  ACCESS_TYPE_AUTOMATIC_PROXY = 4;    // Windows 8.1 and later
  FLAG_SECURE = $00800000;
  OPTION_SECURE_PROTOCOLS = 84;
  PROTOCOL_TLS1_2 = $00000800;
  PROTOCOL_TLS1_3 = $00002000;        // Windows 11 and Server 2022
  QUERY_STATUS_CODE = 19;
  QUERY_FLAG_NUMBER = $20000000;
  NO_LENGTH = $FFFFFFFF;               // headers are zero-terminated

function WinHttpOpen(Agent: PWideChar; AccessType: DWORD; Proxy, Bypass: PWideChar;
  Flags: DWORD): HINTERNET; stdcall; external WinHttpDll;
function WinHttpConnect(Session: HINTERNET; Server: PWideChar; Port: Word;
  Reserved: DWORD): HINTERNET; stdcall; external WinHttpDll;
function WinHttpOpenRequest(Connect: HINTERNET; Verb, ObjectName, Version, Referrer: PWideChar;
  AcceptTypes: Pointer; Flags: DWORD): HINTERNET; stdcall; external WinHttpDll;
function WinHttpSetTimeouts(H: HINTERNET; Resolve, Connect, Send, Receive: Integer): BOOL;
  stdcall; external WinHttpDll;
function WinHttpSetOption(H: HINTERNET; Option: DWORD; Buffer: Pointer; Len: DWORD): BOOL;
  stdcall; external WinHttpDll;
function WinHttpSendRequest(H: HINTERNET; Headers: PWideChar; HeadersLen: DWORD;
  Optional: Pointer; OptionalLen, TotalLen: DWORD; Context: PtrUInt): BOOL;
  stdcall; external WinHttpDll;
function WinHttpReceiveResponse(H: HINTERNET; Reserved: Pointer): BOOL;
  stdcall; external WinHttpDll;
function WinHttpQueryHeaders(H: HINTERNET; InfoLevel: DWORD; Name: PWideChar;
  Buffer: Pointer; var Len: DWORD; Index: Pointer): BOOL; stdcall; external WinHttpDll;
function WinHttpQueryDataAvailable(H: HINTERNET; var Available: DWORD): BOOL;
  stdcall; external WinHttpDll;
function WinHttpReadData(H: HINTERNET; Buffer: Pointer; ToRead: DWORD; var Read: DWORD): BOOL;
  stdcall; external WinHttpDll;
function WinHttpCloseHandle(H: HINTERNET): BOOL; stdcall; external WinHttpDll;

{ scheme://host[:port]/path?query }
function SplitUrl(const URL: string; out Secure: Boolean; out Host: string;
  out Port: Word; out Path: string): Boolean;
var
  Rest, HostPort: string;
  P: Integer;
begin
  Result := False;
  P := Pos('://', URL);
  if P = 0 then
    Exit;
  Secure := LowerCase(Copy(URL, 1, P - 1)) = 'https';
  if not Secure and (LowerCase(Copy(URL, 1, P - 1)) <> 'http') then
    Exit;
  Rest := Copy(URL, P + 3, MaxInt);
  P := Pos('/', Rest);
  if P = 0 then
  begin
    HostPort := Rest;
    Path := '/';
  end
  else
  begin
    HostPort := Copy(Rest, 1, P - 1);
    Path := Copy(Rest, P, MaxInt);
  end;
  if Secure then
    Port := 443
  else
    Port := 80;
  P := Pos(':', HostPort);
  if P > 0 then
  begin
    Port := StrToIntDef(Copy(HostPort, P + 1, MaxInt), 0);
    SetLength(HostPort, P - 1);
    if Port = 0 then
      Exit;
  end;
  Host := HostPort;
  Result := Host <> '';
end;

function WinHttpRequest(const Method, URL, UserAgent, Headers, Body: string;
  ConnectMs, TimeoutMs: Integer; out Status: Integer; out ErrorCode: Cardinal): string;
var
  Session, Connection, Req: HINTERNET;
  Secure: Boolean;
  Host, Path: string;
  WHost, WPath, WMethod, WAgent, WHeaders: UnicodeString;
  Port: Word;
  Protocols, Code, Len, Avail, Got: DWORD;
  Chunk: string;
  BodyPtr: Pointer;

  function Fail: string;
  begin
    ErrorCode := GetLastError;
    Status := 0;
    Result := '';
  end;

begin
  Result := '';
  Status := 0;
  ErrorCode := 0;
  if not SplitUrl(URL, Secure, Host, Port, Path) then
  begin
    ErrorCode := WinHttpErrBadUrl;
    Exit;
  end;
  WAgent := UTF8Decode(UserAgent);
  WHost := UTF8Decode(Host);
  WPath := UTF8Decode(Path);
  WMethod := UTF8Decode(Method);
  WHeaders := UTF8Decode(Headers);
  Connection := nil;
  Req := nil;
  { The proxy settings of Windows; the automatic kind needs 8.1 or later. }
  Session := WinHttpOpen(PWideChar(WAgent), ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, 0);
  if Session = nil then
    Session := WinHttpOpen(PWideChar(WAgent), ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0);
  if Session = nil then
    Exit(Fail);
  try
    { TLS 1.2 is off by default on Windows 7; 1.3 only exists on newer. }
    Protocols := PROTOCOL_TLS1_2 or PROTOCOL_TLS1_3;
    if not WinHttpSetOption(Session, OPTION_SECURE_PROTOCOLS, @Protocols, SizeOf(Protocols)) then
    begin
      Protocols := PROTOCOL_TLS1_2;
      WinHttpSetOption(Session, OPTION_SECURE_PROTOCOLS, @Protocols, SizeOf(Protocols));
    end;
    WinHttpSetTimeouts(Session, ConnectMs, ConnectMs, TimeoutMs, TimeoutMs);
    Connection := WinHttpConnect(Session, PWideChar(WHost), Port, 0);
    if Connection = nil then
      Exit(Fail);
    if Secure then
      Req := WinHttpOpenRequest(Connection, PWideChar(WMethod), PWideChar(WPath), nil, nil,
        nil, FLAG_SECURE)
    else
      Req := WinHttpOpenRequest(Connection, PWideChar(WMethod), PWideChar(WPath), nil, nil,
        nil, 0);
    if Req = nil then
      Exit(Fail);
    BodyPtr := nil;
    if Body <> '' then
      BodyPtr := PChar(Body);
    if WHeaders = '' then
    begin
      if not WinHttpSendRequest(Req, nil, 0, BodyPtr, Length(Body), Length(Body), 0) then
        Exit(Fail);
    end
    else if not WinHttpSendRequest(Req, PWideChar(WHeaders), NO_LENGTH, BodyPtr,
       Length(Body), Length(Body), 0) then
      Exit(Fail);
    if not WinHttpReceiveResponse(Req, nil) then
      Exit(Fail);
    Code := 0;
    Len := SizeOf(Code);
    if not WinHttpQueryHeaders(Req, QUERY_STATUS_CODE or QUERY_FLAG_NUMBER, nil, @Code, Len, nil) then
      Exit(Fail);
    repeat
      Avail := 0;
      if not WinHttpQueryDataAvailable(Req, Avail) then
        Exit(Fail);
      if Avail = 0 then
        Break;
      SetLength(Chunk, Avail);
      Got := 0;
      if not WinHttpReadData(Req, PChar(Chunk), Avail, Got) then
        Exit(Fail);
      SetLength(Chunk, Got);
      Result := Result + Chunk;
    until Got = 0;
    Status := Code;
  finally
    if Req <> nil then
      WinHttpCloseHandle(Req);
    if Connection <> nil then
      WinHttpCloseHandle(Connection);
    WinHttpCloseHandle(Session);
  end;
end;

{$ENDIF}

end.
