unit FakeWacs;

{$mode objfpc}{$H+}

{ A fake WACS (Gitea API) and BIEL Public Data API on 127.0.0.1, for
  offline tests. Users: alice (password "secret", member of org "team")
  and bob (password "pw"). Repos are added with AddFakeRepo, as bare git
  repos under Root whose clone URLs are file:// paths. Only what the
  workbench calls is served. Every request is logged (method, path, auth
  kind) for assertions. }

interface

uses
  Classes, SysUtils;

type
  TFakeRequest = record
    Method, Path, Query, AuthKind, Body: string;
  end;

{ Starts the server; sets WBWacs.WacsServerOverride and
  WBBielCatalog.BielEndpoint to it. }
procedure StartFakeWacs(const Root: string);
procedure StopFakeWacs;
{ A repo Owner/Name with the given BIEL status (or ''), as a bare clone of
  SourceDir (a git repo) or empty if SourceDir is ''. Returns its path. }
function AddFakeRepo(const Owner, Name, Status: string; IsPrivate: Boolean;
  const SourceDir: string; const Topics: array of string): string;
function FakeRepoPath(const Owner, Name: string): string;
function FakeRequests: TStringList;   // "METHOD path?query auth" lines
function FakeTokenCount(const User: string): Integer;
procedure ClearFakeRequests;

implementation

uses
  fpjson, jsonparser, base64, fphttpserver, httpdefs, syncobjs,
  WBGit, WBWacs, WBBielCatalog;

type
  TFakeToken = record
    Id: Int64;
    User, Name, Sha1: string;
  end;

  TFakeRepo = record
    Id: Int64;
    Owner, Name, Status: string;
    IsPrivate: Boolean;
    Topics: TStringArray;
  end;

  { Address is protected in TFPHttpServer: listen on localhost only. }
  TLocalServer = class(TFPHttpServer)
  public
    property Address;
  end;

  TServerThread = class(TThread)
  private
    FServer: TLocalServer;
    procedure Idle(Sender: TObject);
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  protected
    procedure Execute; override;
  public
    Port: Integer;
    Started: Boolean;
    Failed: string;
  end;

var
  Lock: TCriticalSection;
  Thread: TServerThread;
  RootDir: string;
  Tokens: array of TFakeToken;
  Repos: array of TFakeRepo;
  NextId: Int64 = 100;
  Log: TStringList;

const
  Users: array[0..2] of string = ('alice', 'bob', 'team');
  UserIds: array[0..2] of Integer = (1, 2, 3);
  Passwords: array[0..2] of string = ('secret', 'pw', '');

function UserIndex(const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Users) do
    if SameText(Users[I], Name) then
      Exit(I);
  Result := -1;
end;

function FakeRepoPath(const Owner, Name: string): string;
begin
  Result := RootDir + 'git' + PathDelim + Owner + PathDelim + Name + '.git';
end;

function RepoJson(const R: TFakeRepo; const Viewer: string): TJSONObject;
var
  Topics: TJSONArray;
  T: string;
  Empty: Boolean;
begin
  Empty := RunGit(FakeRepoPath(R.Owner, R.Name), ['rev-parse', '--verify', '-q', 'HEAD']).ExitCode <> 0;
  Topics := TJSONArray.Create;
  for T in R.Topics do
    Topics.Add(T);
  Result := TJSONObject.Create([
    'id', R.Id, 'name', R.Name, 'full_name', R.Owner + '/' + R.Name,
    'owner', TJSONObject.Create(['id', UserIds[UserIndex(R.Owner)], 'login', R.Owner]),
    'description', 'btt-writer-desktop: ' + R.Name,
    'clone_url', 'file://' + FakeRepoPath(R.Owner, R.Name),
    'html_url', 'http://fake/' + R.Owner + '/' + R.Name,
    'default_branch', 'master', 'updated_at', '2026-01-02T03:04:05Z',
    'empty', Empty, 'private', R.IsPrivate,
    'permissions', TJSONObject.Create(['push', SameText(Viewer, R.Owner) or
      ((R.Owner = 'team') and SameText(Viewer, 'alice'))]),
    'topics', Topics]);
end;

function CanSee(const R: TFakeRepo; const Viewer: string): Boolean;
begin
  Result := not R.IsPrivate or SameText(Viewer, R.Owner) or
    ((R.Owner = 'team') and SameText(Viewer, 'alice'));
end;

{ Who the request is from: '' (anonymous), or a user; Kind basic/token/none;
  Bad when credentials were given but wrong. }
procedure Identify(const Header: string; out User, Kind: string; out Bad: Boolean);
var
  Decoded: string;
  I: Integer;
  T: TFakeToken;
begin
  User := '';
  Kind := 'none';
  Bad := False;
  if Copy(Header, 1, 6) = 'Basic ' then
  begin
    Kind := 'basic';
    Decoded := DecodeStringBase64(Copy(Header, 7, MaxInt));
    I := UserIndex(Copy(Decoded, 1, Pos(':', Decoded) - 1));
    if (I >= 0) and (Passwords[I] <> '') and
       (Copy(Decoded, Pos(':', Decoded) + 1, MaxInt) = Passwords[I]) then
      User := Users[I]
    else
      Bad := True;
  end
  else if Copy(Header, 1, 6) = 'token ' then
  begin
    Kind := 'token';
    Bad := True;
    for T in Tokens do
      if T.Sha1 = Copy(Header, 7, MaxInt) then
      begin
        User := T.User;
        Bad := False;
      end;
  end;
end;

procedure Reply(var AResponse: TFPHTTPConnectionResponse; Code: Integer; Data: TJSONData);
begin
  AResponse.Code := Code;
  AResponse.ContentType := 'application/json';
  if Data <> nil then
  begin
    AResponse.Content := Data.AsJSON;
    Data.Free;
  end
  else
    AResponse.Content := '';
end;

function Msg(const Text: string): TJSONObject;
begin
  Result := TJSONObject.Create(['message', Text]);
end;

function QueryValue(const Query, Name: string): string;
var
  Part: string;
begin
  Result := '';
  for Part in Query.Split(['&']) do
    if Copy(Part, 1, Length(Name) + 1) = Name + '=' then
      Exit(HTTPDecode(Copy(Part, Length(Name) + 2, MaxInt)));
end;

function IfThen(B: Boolean; const A, C: string): string;
begin
  if B then Result := A else Result := C;
end;

procedure Graphql(const Body: string; var AResponse: TFPHTTPConnectionResponse);
var
  Req, Ors, Pattern: TJSONData;
  Rows: TJSONArray;
  R: TFakeRepo;
  I: Integer;
  Frag: string;
  Hit: Boolean;
begin
  Req := GetJSON(Body);
  Rows := TJSONArray.Create;
  try
    Ors := TJSONObject(Req).FindPath('variables.w._or');
    for R in Repos do
    begin
      Hit := False;
      if Ors <> nil then
        for I := 0 to Ors.Count - 1 do
        begin
          Pattern := TJSONObject(Ors.Items[I]).FindPath('name._ilike');
          Frag := StringReplace(Pattern.AsString, '%', '', [rfReplaceAll]);
          Frag := StringReplace(Frag, '\', '', [rfReplaceAll]);
          if Pos(LowerCase(Frag), LowerCase(R.Owner + '/' + R.Name)) > 0 then
            Hit := True;
        end;
      if Hit and not R.IsPrivate then
        Rows.Add(TJSONObject.Create(['name', R.Owner + '/' + R.Name,
          'modified_on', '2026-01-02T03:04:05',
          'wa_content_metadata', TJSONObject.Create(['status', R.Status]),
          'git_repo', TJSONObject.Create(['username', R.Owner, 'repo_name', R.Name])]));
    end;
  finally
    Req.Free;
  end;
  Reply(AResponse, 200, TJSONObject.Create(['data', TJSONObject.Create(['content', Rows])]));
end;

procedure TServerThread.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Path, Query, User, Kind, Viewer, Q: string;
  Bad: Boolean;
  Parts: TStringArray;
  I, Uid, Limit, Page, Skip: Integer;
  Arr: TJSONArray;
  T: TFakeToken;
  R: TFakeRepo;
  Body: TJSONData;
begin
  Lock.Enter;
  try
    Path := ARequest.URI;
    Query := '';
    if Pos('?', Path) > 0 then
    begin
      Query := Copy(Path, Pos('?', Path) + 1, MaxInt);
      SetLength(Path, Pos('?', Path) - 1);
    end;
    Identify(ARequest.Authorization, User, Kind, Bad);
    Log.Add(ARequest.Method + ' ' + Path + IfThen(Query <> '', '?' + Query, '') + ' ' + Kind);
    if Bad then
    begin
      Reply(AResponse, 401, Msg('unauthorized'));
      Exit;
    end;
    Viewer := User;

    if Path = '/graphql' then
    begin
      Graphql(ARequest.Content, AResponse);
      Exit;
    end;
    if Copy(Path, 1, 8) <> '/api/v1/' then
    begin
      Reply(AResponse, 404, Msg('not found'));
      Exit;
    end;
    Parts := Copy(Path, 9, MaxInt).Split(['/']);

    if (ARequest.Method = 'GET') and (Path = '/api/v1/version') then
      Reply(AResponse, 200, TJSONObject.Create(['version', '1.23.8']))
    else if (ARequest.Method = 'GET') and (Path = '/api/v1/user') then
    begin
      if User = '' then
        Reply(AResponse, 401, Msg('token is required'))
      else
        Reply(AResponse, 200, TJSONObject.Create(['id', UserIds[UserIndex(User)],
          'login', User, 'full_name', UpperCase(User[1]) + Copy(User, 2, MaxInt) + ' Tester']));
    end
    else if (ARequest.Method = 'GET') and (Length(Parts) = 2) and (Parts[0] = 'users') then
    begin
      I := UserIndex(Parts[1]);
      if I < 0 then
        Reply(AResponse, 404, Msg('user does not exist'))
      else
        Reply(AResponse, 200, TJSONObject.Create(['id', UserIds[I], 'login', Users[I]]));
    end
    else if (ARequest.Method = 'GET') and (Length(Parts) = 2) and (Parts[0] = 'orgs') then
    begin
      if Parts[1] = 'team' then
        Reply(AResponse, 200, TJSONObject.Create(['id', 3, 'username', 'team']))
      else
        Reply(AResponse, 404, Msg('org does not exist'));
    end
    else if (Length(Parts) >= 3) and (Parts[0] = 'users') and (Parts[2] = 'tokens') then
    begin
      { Gitea: token calls need Basic auth as that user. }
      if (Kind <> 'basic') or not SameText(User, Parts[1]) then
      begin
        Reply(AResponse, 401, Msg('basic auth required'));
        Exit;
      end;
      if ARequest.Method = 'GET' then
      begin
        Arr := TJSONArray.Create;
        for T in Tokens do
          if SameText(T.User, User) then
            Arr.Add(TJSONObject.Create(['id', T.Id, 'name', T.Name]));
        Reply(AResponse, 200, Arr);
      end
      else if ARequest.Method = 'POST' then
      begin
        Body := GetJSON(ARequest.Content);
        try
          Inc(NextId);
          T.Id := NextId;
          T.User := User;
          T.Name := TJSONObject(Body).Get('name', '');
          T.Sha1 := 'tok' + IntToStr(NextId) + 'abcdef';
        finally
          Body.Free;
        end;
        for I := 0 to High(Tokens) do
          if SameText(Tokens[I].User, User) and (Tokens[I].Name = T.Name) then
          begin
            Reply(AResponse, 422, Msg('access token name has been used already'));
            Exit;
          end;
        Tokens := Concat(Tokens, [T]);
        Reply(AResponse, 201, TJSONObject.Create(['id', T.Id, 'name', T.Name, 'sha1', T.Sha1]));
      end
      else if (ARequest.Method = 'DELETE') and (Length(Parts) = 4) then
      begin
        for I := High(Tokens) downto 0 do
          if (IntToStr(Tokens[I].Id) = Parts[3]) and SameText(Tokens[I].User, User) then
            Delete(Tokens, I, 1);
        Reply(AResponse, 204, nil);
      end;
    end
    else if (ARequest.Method = 'GET') and (Path = '/api/v1/repos/search') then
    begin
      Q := LowerCase(QueryValue(Query, 'q'));
      Uid := StrToIntDef(QueryValue(Query, 'uid'), 0);
      Limit := StrToIntDef(QueryValue(Query, 'limit'), 10);
      if Limit > 50 then
        Limit := 50;
      Page := StrToIntDef(QueryValue(Query, 'page'), 1);
      Skip := (Page - 1) * Limit;
      Arr := TJSONArray.Create;
      for R in Repos do
        if (Pos(Q, LowerCase(R.Name)) > 0) and CanSee(R, Viewer) and
           ((Uid = 0) or (UserIds[UserIndex(R.Owner)] = Uid)) then
        begin
          if Skip > 0 then
            Dec(Skip)
          else if Arr.Count < Limit then
            Arr.Add(RepoJson(R, Viewer));
        end;
      Reply(AResponse, 200, TJSONObject.Create(['ok', True, 'data', Arr]));
    end
    else if (ARequest.Method = 'GET') and (Length(Parts) = 3) and (Parts[0] = 'repos') then
    begin
      for R in Repos do
        if SameText(R.Owner, Parts[1]) and SameText(R.Name, Parts[2]) and CanSee(R, Viewer) then
        begin
          Reply(AResponse, 200, RepoJson(R, Viewer));
          Exit;
        end;
      Reply(AResponse, 404, Msg('repo not found'));
    end
    else if (ARequest.Method = 'POST') and
            ((Path = '/api/v1/user/repos') or
             ((Length(Parts) = 3) and (Parts[0] = 'orgs') and (Parts[2] = 'repos'))) then
    begin
      if (Kind <> 'token') or (User = '') then
      begin
        Reply(AResponse, 401, Msg('token is required'));
        Exit;
      end;
      Body := GetJSON(ARequest.Content);
      try
        R.Name := TJSONObject(Body).Get('name', '');
      finally
        Body.Free;
      end;
      if Parts[0] = 'orgs' then
      begin
        if (Parts[1] <> 'team') or (User <> 'alice') then
        begin
          Reply(AResponse, 403, Msg('not a member of the organisation'));
          Exit;
        end;
        R.Owner := 'team';
      end
      else
        R.Owner := User;
      for I := 0 to High(Repos) do
        if SameText(Repos[I].Owner, R.Owner) and SameText(Repos[I].Name, R.Name) then
        begin
          Reply(AResponse, 409, Msg('The repository with the same name already exists.'));
          Exit;
        end;
      Inc(NextId);
      R.Id := NextId;
      R.Status := '';
      R.IsPrivate := False;
      R.Topics := nil;
      ForceDirectories(FakeRepoPath(R.Owner, R.Name));
      RunGit(FakeRepoPath(R.Owner, R.Name), ['init', '-q', '--bare', '-b', 'master']);
      Repos := Concat(Repos, [R]);
      Reply(AResponse, 201, RepoJson(R, Viewer));
    end
    else
      Reply(AResponse, 404, Msg('no such endpoint in the fake'));
  finally
    Lock.Leave;
  end;
end;

procedure TServerThread.Idle(Sender: TObject);
begin
  if Terminated then
    FServer.Active := False;
end;

procedure TServerThread.Execute;
begin
  FServer := TLocalServer.Create(nil);
  try
    FServer.Address := '127.0.0.1';
    FServer.Port := Port;
    FServer.AcceptIdleTimeout := 50;
    FServer.OnAcceptIdle := @Idle;
    FServer.OnRequest := @HandleRequest;
    try
      Started := True;
      FServer.Active := True;   // blocks until Idle stops it
    except
      on E: Exception do
      begin
        Failed := E.Message;
        Started := False;
      end;
    end;
  finally
    FreeAndNil(FServer);
  end;
end;

procedure StartFakeWacs(const Root: string);
var
  Attempt: Integer;
begin
  RootDir := IncludeTrailingPathDelimiter(Root);
  ForceDirectories(RootDir + 'git');
  Tokens := nil;
  Repos := nil;
  Log.Clear;
  for Attempt := 1 to 10 do
  begin
    Thread := TServerThread.Create(True);
    Thread.Port := 20000 + Random(30000);
    Thread.FreeOnTerminate := False;
    Thread.Start;
    Sleep(150);
    if Thread.Failed = '' then
      Break;
    Thread.WaitFor;
    FreeAndNil(Thread);
  end;
  if Thread = nil then
    raise Exception.Create('fake WACS server could not start');
  WacsServerOverride := 'http://127.0.0.1:' + IntToStr(Thread.Port);
  BielEndpoint := WacsServerOverride + '/graphql';
end;

procedure StopFakeWacs;
begin
  if Thread = nil then
    Exit;
  Thread.Terminate;
  Thread.WaitFor;
  FreeAndNil(Thread);
  WacsServerOverride := '';
end;

function AddFakeRepo(const Owner, Name, Status: string; IsPrivate: Boolean;
  const SourceDir: string; const Topics: array of string): string;
var
  R: TFakeRepo;
  T: string;
begin
  Lock.Enter;
  try
    Result := FakeRepoPath(Owner, Name);
    ForceDirectories(ExtractFileDir(Result));
    if SourceDir <> '' then
      RunGit(ExtractFileDir(Result), ['clone', '-q', '--bare', SourceDir, Result])
    else
    begin
      ForceDirectories(Result);
      RunGit(Result, ['init', '-q', '--bare', '-b', 'master']);
    end;
    Inc(NextId);
    R.Id := NextId;
    R.Owner := Owner;
    R.Name := Name;
    R.Status := Status;
    R.IsPrivate := IsPrivate;
    R.Topics := nil;
    for T in Topics do
      R.Topics := Concat(R.Topics, [T]);
    Repos := Concat(Repos, [R]);
  finally
    Lock.Leave;
  end;
end;

function FakeRequests: TStringList;
begin
  Result := Log;
end;

function FakeTokenCount(const User: string): Integer;
var
  T: TFakeToken;
begin
  Result := 0;
  for T in Tokens do
    if SameText(T.User, User) then
      Inc(Result);
end;

procedure ClearFakeRequests;
begin
  Lock.Enter;
  try
    Log.Clear;
  finally
    Lock.Leave;
  end;
end;

initialization
  Lock := TCriticalSection.Create;
  Log := TStringList.Create;
  Randomize;

finalization
  StopFakeWacs;
  Log.Free;
  Lock.Free;

end.
