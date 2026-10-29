unit WBMacHttp;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

(* HTTP(S) requests through macOS's own client, NSURLSession (Foundation).
   TLS, certificates (the system keychain) and proxies are macOS's business,
   so nothing extra ships: macOS has no usable OpenSSL (its libssl.dylib is
   LibreSSL, and loading it can abort the program). Used by WBHttp on macOS
   only.

   FPC 3.2.2 has no closures to pass as completion blocks, so a delegate
   collects the reply and a dispatch semaphore makes the call synchronous.
   The delegate runs on NSURLSession's own threads, which FPC did not start:
   its methods use only Objective-C objects, no Pascal strings or heap. *)

interface

{$IFDEF DARWIN}

{ Method on URL. Headers are "Name: value" lines separated by CR LF; Body
  is sent as is. Status is the HTTP status, or 0 with ErrorCode (an
  NSURLErrorDomain code, e.g. -1001) and ErrorText (macOS's description)
  when no answer came. }
function MacHttpRequest(const Method, URL, UserAgent, Headers, Body: string;
  ConnectMs, TimeoutMs: Integer; out Status: Integer; out ErrorCode: Integer;
  out ErrorText: string): string;

{ Keep this thread's session (and so its connections) between requests;
  release it before the thread ends. }
procedure MacHttpKeepSession;
procedure MacHttpReleaseSession;

const
  { NSURLErrorDomain codes worth their own message. }
  MacHttpErrBadUrl = -1000;
  MacHttpErrUnsupportedUrl = -1002;
  MacHttpErrTimedOut = -1001;
  MacHttpErrCannotFindHost = -1003;
  MacHttpErrCannotConnect = -1004;
  MacHttpErrConnectionLost = -1005;
  MacHttpErrDnsFailed = -1006;
  MacHttpErrNotConnected = -1009;
  { -1200 secure connection failed, -1201 to -1206 certificate problems }
  MacHttpErrSecureFirst = -1206;
  MacHttpErrSecureLast = -1200;

{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  SysUtils, CocoaAll;

type
  dispatch_semaphore_t = Pointer;

const
  DISPATCH_TIME_FOREVER = not QWord(0);
  NSURLRequestReloadIgnoringLocalCacheData = 1;

function dispatch_semaphore_create(Value: PtrInt): dispatch_semaphore_t; cdecl;
  external 'c' name 'dispatch_semaphore_create';
function dispatch_semaphore_wait(Sema: dispatch_semaphore_t; Timeout: QWord): PtrInt; cdecl;
  external 'c' name 'dispatch_semaphore_wait';
function dispatch_semaphore_signal(Sema: dispatch_semaphore_t): PtrInt; cdecl;
  external 'c' name 'dispatch_semaphore_signal';
procedure dispatch_release(Obj: Pointer); cdecl; external 'c' name 'dispatch_release';

type
  { One request at a time: Start before each, then wait on Done. }
  TMacHttpDelegate = objcclass(NSObject, NSURLSessionDataDelegateProtocol)
  public
    Received: NSMutableData;
    Failure: NSError;
    Done: dispatch_semaphore_t;
    procedure Start; message 'wbStart';
    procedure dealloc; override;
    procedure URLSession_dataTask_didReceiveData(session: NSURLSession;
      dataTask: NSURLSessionDataTask; data: NSData);
      message 'URLSession:dataTask:didReceiveData:';
    procedure URLSession_task_didCompleteWithError(session: NSURLSession;
      task: NSURLSessionTask; error: NSError);
      message 'URLSession:task:didCompleteWithError:';
    { Started on an NSThread once, so Cocoa knows the program has threads. }
    procedure Nothing(Arg: id); message 'wbNothing:';
  end;

procedure TMacHttpDelegate.Start;
begin
  if Received <> nil then
    Received.release;
  Received := NSMutableData.alloc.init;
  if Failure <> nil then
    Failure.release;
  Failure := nil;
  if Done = nil then
    Done := dispatch_semaphore_create(0);
end;

procedure TMacHttpDelegate.dealloc;
begin
  if Received <> nil then
    Received.release;
  if Failure <> nil then
    Failure.release;
  if Done <> nil then
    dispatch_release(Done);
  inherited dealloc;
end;

procedure TMacHttpDelegate.URLSession_dataTask_didReceiveData(session: NSURLSession;
  dataTask: NSURLSessionDataTask; data: NSData);
begin
  Received.appendData(data);
end;

procedure TMacHttpDelegate.URLSession_task_didCompleteWithError(session: NSURLSession;
  task: NSURLSessionTask; error: NSError);
begin
  if error <> nil then
    Failure := error.retain;
  dispatch_semaphore_signal(Done);
end;

procedure TMacHttpDelegate.Nothing(Arg: id);
begin
end;

threadvar
  Keeping: Boolean;
  KeptSession: NSURLSession;
  KeptDelegate: TMacHttpDelegate;

procedure MacHttpKeepSession;
begin
  Keeping := True;
end;

procedure MacHttpReleaseSession;
begin
  if KeptSession <> nil then
    KeptSession.finishTasksAndInvalidate;   // the session then lets go of the delegate
  KeptSession := nil;
  if KeptDelegate <> nil then
    KeptDelegate.release;
  KeptDelegate := nil;
  Keeping := False;
end;

function NewSession(Delegate: TMacHttpDelegate; ConnectMs, TimeoutMs: Integer): NSURLSession;
var
  Config: NSURLSessionConfiguration;
begin
  { No cookies, cache or credentials kept on disk }
  Config := NSURLSessionConfiguration.ephemeralSessionConfiguration;
  if ConnectMs > TimeoutMs then
    TimeoutMs := ConnectMs;
  Config.setTimeoutIntervalForRequest(TimeoutMs / 1000);   // without any data
  Result := NSURLSession.sessionWithConfiguration_delegate_delegateQueue(Config,
    NSURLSessionDelegateProtocol(id(Delegate)), nil);
end;

function NS(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function FromNS(S: NSString): string;
begin
  Result := '';
  if S <> nil then
    Result := S.UTF8String;
end;

function MacHttpRequest(const Method, URL, UserAgent, Headers, Body: string;
  ConnectMs, TimeoutMs: Integer; out Status: Integer; out ErrorCode: Integer;
  out ErrorText: string): string;
var
  Pool: NSAutoreleasePool;
  Delegate: TMacHttpDelegate;
  Session: NSURLSession;
  Address: NSURL;
  Req: NSMutableURLRequest;
  Task: NSURLSessionDataTask;
  Response: NSURLResponse;
  Lines: TStringArray;
  Line: string;
  P: Integer;
begin
  Result := '';
  Status := 0;
  ErrorCode := 0;
  ErrorText := '';
  Pool := NSAutoreleasePool.alloc.init;
  try
    Address := NSURL.URLWithString(NS(URL));
    if Address = nil then
    begin
      ErrorCode := MacHttpErrBadUrl;
      Exit;
    end;
    if Keeping and (KeptSession <> nil) then
    begin
      Delegate := KeptDelegate;
      Session := KeptSession;
    end
    else
    begin
      Delegate := TMacHttpDelegate.alloc.init;
      Session := NewSession(Delegate, ConnectMs, TimeoutMs);
      if Keeping then
      begin
        KeptDelegate := Delegate;
        KeptSession := Session;
      end;
    end;
    Req := NSMutableURLRequest.requestWithURL_cachePolicy_timeoutInterval(Address,
      NSURLRequestReloadIgnoringLocalCacheData, TimeoutMs / 1000);
    Req.setHTTPMethod(NS(Method));
    Req.setValue_forHTTPHeaderField(NS(UserAgent), NS('User-Agent'));
    Lines := Headers.Split([#13#10]);
    for Line in Lines do
    begin
      P := Pos(':', Line);
      if P > 1 then
        Req.setValue_forHTTPHeaderField(NS(Trim(Copy(Line, P + 1, MaxInt))),
          NS(Trim(Copy(Line, 1, P - 1))));
    end;
    if Body <> '' then
      Req.setHTTPBody(NSData.dataWithBytes_length(PChar(Body), Length(Body)));

    Delegate.Start;
    Task := Session.dataTaskWithRequest(Req);
    Task.resume;
    { The request timeout always ends the task, with an error if need be. }
    dispatch_semaphore_wait(Delegate.Done, DISPATCH_TIME_FOREVER);

    if Delegate.Failure <> nil then
    begin
      ErrorCode := Delegate.Failure.code;
      ErrorText := FromNS(Delegate.Failure.localizedDescription);
    end
    else
    begin
      Response := Task.response;
      if (Response <> nil) and Response.isKindOfClass(NSHTTPURLResponse.classClass) then
        Status := NSHTTPURLResponse(Response).statusCode;
      if Delegate.Received.length > 0 then
        SetString(Result, PAnsiChar(Delegate.Received.bytes), Delegate.Received.length);
    end;

    if Session <> KeptSession then
    begin
      Session.finishTasksAndInvalidate;
      Delegate.release;
    end;
  finally
    Pool.release;
  end;
end;

var
  Starter: TMacHttpDelegate;

initialization
  if not NSThread.isMultiThreaded then
  begin
    Starter := TMacHttpDelegate.alloc.init;
    NSThread.detachNewThreadSelector_toTarget_withObject(objcselector('wbNothing:'),
      Starter, nil);
  end;

{$ENDIF}

end.
