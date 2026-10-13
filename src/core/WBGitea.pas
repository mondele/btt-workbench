unit WBGitea;

{$mode objfpc}{$H+}

{ Client for the Gitea REST API (v1) that WACS runs. Ported from
  btt-writer-two's GiteaClient.pas, with: URL-encoded queries, repo search
  paged to the end (WACS returns at most 50 per page), the {ok, data}
  wrapper of /repos/search read, organisation owners, and tokens that are
  never written anywhere by this unit.

  Calls BTT-Writer Desktop 1.6.0 makes (gogs-client): GET user, tokens
  (create/list/delete with Basic auth), GET repos/search, POST user/repos
  with description "btt-writer-desktop: <name>". }

interface

uses
  Classes, SysUtils, fpjson, WBHttp;

const
  DefaultWacsServer = 'https://content.bibletranslationtools.org';
  GiteaPageSize = 50;

type
  TGiteaUser = record
    Id: Int64;
    Login, FullName, Email: string;
    IsOrg: Boolean;
  end;

  TGiteaToken = record
    Id: Int64;
    Name, Sha1: string;   // Sha1 (the token) only when just created
  end;
  TGiteaTokens = array of TGiteaToken;

  TGiteaRepo = record
    Id: Int64;
    Owner, Name, FullName, Description: string;
    CloneUrl, HtmlUrl, DefaultBranch, Updated: string;
    Empty, IsPrivate, CanPush: Boolean;
    Topics: TStringArray;
  end;
  TGiteaRepos = array of TGiteaRepo;

  TGiteaClient = class
  private
    FServer: string;
    FAuth: TWBHttpAuth;
    function Api(const Path: string): string;
  public
    constructor Create(const Server: string);
    property Server: string read FServer;
    property Auth: TWBHttpAuth read FAuth write FAuth;
    { The logged-in user (needs Auth). }
    function CurrentUser: TGiteaUser;
    { A user or organisation by name; False if there is none. }
    function FindOwner(const Name: string; out Owner: TGiteaUser): Boolean;
    { Token calls need Basic auth (Gitea's rule). }
    function ListTokens(const User: string): TGiteaTokens;
    function CreateToken(const User, Name: string; const Scopes: array of string): TGiteaToken;
    procedure DeleteToken(const User: string; TokenId: Int64);
    { Every repo matching Query (substring of the name), all pages. With
      OwnerId <> 0 only that user's or organisation's own repos. }
    function SearchRepos(const Query: string; OwnerId: Int64): TGiteaRepos;
    function GetRepo(const Owner, Name: string; out Repo: TGiteaRepo): Boolean;
    { In the logged-in user's account when Owner is them, else in the
      organisation Owner. Public, not initialised, like BTT-Writer. }
    function CreateRepo(const Owner, Name: string; OwnerIsOrg: Boolean): TGiteaRepo;
  end;

{ Our token's name on WACS: btt-workbench_<machine>_<os>. }
function WorkbenchTokenName: string;
function ParseRepo(Obj: TJSONObject): TGiteaRepo;

implementation

uses
  {$IFDEF UNIX}Unix,{$ENDIF} WBJson;

function MachineName: string;
begin
  {$IFDEF UNIX}
  Result := GetHostName;
  {$ELSE}
  Result := GetEnvironmentVariable('COMPUTERNAME');
  {$ENDIF}
  if Result = '' then
    Result := 'unknown';
end;

function WorkbenchTokenName: string;
const
  {$IF DEFINED(ANDROID)}OS = 'android';
  {$ELSEIF DEFINED(WINDOWS)}OS = 'windows';
  {$ELSEIF DEFINED(DARWIN)}OS = 'macos';
  {$ELSE}OS = 'linux';
  {$ENDIF}
begin
  Result := 'btt-workbench_' + MachineName + '_' + OS;
end;

function Str(Obj: TJSONObject; const Name: string): string;
var
  D: TJSONData;
begin
  D := Obj.Find(Name);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ''
  else
    Result := D.AsString;
end;

function Bool(Obj: TJSONObject; const Name: string): Boolean;
var
  D: TJSONData;
begin
  D := Obj.Find(Name);
  Result := (D <> nil) and (D.JSONType = jtBoolean) and D.AsBoolean;
end;

function Int(Obj: TJSONObject; const Name: string): Int64;
var
  D: TJSONData;
begin
  D := Obj.Find(Name);
  if (D <> nil) and (D.JSONType = jtNumber) then
    Result := D.AsInt64
  else
    Result := 0;
end;

function ParseUser(Obj: TJSONObject): TGiteaUser;
begin
  Result.Id := Int(Obj, 'id');
  Result.Login := Str(Obj, 'login');
  if Result.Login = '' then
    Result.Login := Str(Obj, 'username');
  Result.FullName := Str(Obj, 'full_name');
  Result.Email := Str(Obj, 'email');
  Result.IsOrg := False;
end;

function ParseRepo(Obj: TJSONObject): TGiteaRepo;
var
  D: TJSONData;
  I: Integer;
begin
  Result.Id := Int(Obj, 'id');
  Result.Name := Str(Obj, 'name');
  Result.FullName := Str(Obj, 'full_name');
  Result.Owner := '';
  D := Obj.Find('owner');
  if D is TJSONObject then
    Result.Owner := ParseUser(TJSONObject(D)).Login;
  if (Result.Owner = '') and (Pos('/', Result.FullName) > 0) then
    Result.Owner := Copy(Result.FullName, 1, Pos('/', Result.FullName) - 1);
  Result.Description := Str(Obj, 'description');
  Result.CloneUrl := Str(Obj, 'clone_url');
  Result.HtmlUrl := Str(Obj, 'html_url');
  Result.DefaultBranch := Str(Obj, 'default_branch');
  Result.Updated := Str(Obj, 'updated_at');
  Result.Empty := Bool(Obj, 'empty');
  Result.IsPrivate := Bool(Obj, 'private');
  Result.CanPush := False;
  D := Obj.Find('permissions');
  if D is TJSONObject then
    Result.CanPush := Bool(TJSONObject(D), 'push');
  Result.Topics := nil;
  D := Obj.Find('topics');
  if (D <> nil) and (D.JSONType = jtArray) then
    for I := 0 to D.Count - 1 do
      Result.Topics := Concat(Result.Topics, [D.Items[I].AsString]);
end;

constructor TGiteaClient.Create(const Server: string);
begin
  inherited Create;
  FServer := Trim(Server);
  while (FServer <> '') and (FServer[Length(FServer)] = '/') do
    SetLength(FServer, Length(FServer) - 1);
  FAuth := NoAuth;
end;

function TGiteaClient.Api(const Path: string): string;
begin
  Result := FServer + '/api/v1/' + Path;
end;

function TGiteaClient.CurrentUser: TGiteaUser;
var
  Reply: TJSONData;
begin
  Reply := HttpJson('GET', Api('user'), FAuth);
  try
    if not (Reply is TJSONObject) then
      raise EWBHttp.Create('GET user: unexpected reply');
    Result := ParseUser(TJSONObject(Reply));
  finally
    Reply.Free;
  end;
end;

function TGiteaClient.FindOwner(const Name: string; out Owner: TGiteaUser): Boolean;
var
  Reply: TJSONData;
begin
  Result := False;
  Owner.Id := 0;
  if HttpJsonStatus('GET', Api('users/' + UrlEncode(Name)), FAuth, nil, 15000, Reply) = 200 then
  try
    if Reply is TJSONObject then
    begin
      Owner := ParseUser(TJSONObject(Reply));
      Result := Owner.Id <> 0;
    end;
  finally
    Reply.Free;
  end
  else
    Reply.Free;
  if not Result then
    Exit;
  { Organisations answer users/<name> too; orgs/<name> tells them apart. }
  if HttpJsonStatus('GET', Api('orgs/' + UrlEncode(Name)), FAuth, nil, 15000, Reply) = 200 then
    Owner.IsOrg := True;
  Reply.Free;
end;

function TGiteaClient.ListTokens(const User: string): TGiteaTokens;
var
  Reply: TJSONData;
  I: Integer;
  T: TGiteaToken;
begin
  Result := nil;
  Reply := HttpJson('GET', Api('users/' + UrlEncode(User) + '/tokens'), FAuth);
  try
    if (Reply <> nil) and (Reply.JSONType = jtArray) then
      for I := 0 to Reply.Count - 1 do
        if Reply.Items[I] is TJSONObject then
        begin
          T.Id := Int(TJSONObject(Reply.Items[I]), 'id');
          T.Name := Str(TJSONObject(Reply.Items[I]), 'name');
          T.Sha1 := '';
          Result := Concat(Result, [T]);
        end;
  finally
    Reply.Free;
  end;
end;

function TGiteaClient.CreateToken(const User, Name: string;
  const Scopes: array of string): TGiteaToken;
var
  Body: TJSONObject;
  Arr: TJSONArray;
  Reply: TJSONData;
  S: string;
begin
  Body := TJSONObject.Create;
  try
    Body.Add('name', Name);
    Arr := TJSONArray.Create;
    for S in Scopes do
      Arr.Add(S);
    Body.Add('scopes', Arr);
    Reply := HttpJson('POST', Api('users/' + UrlEncode(User) + '/tokens'), FAuth, Body);
  finally
    Body.Free;
  end;
  try
    if not (Reply is TJSONObject) then
      raise EWBHttp.Create('POST tokens: unexpected reply');
    Result.Id := Int(TJSONObject(Reply), 'id');
    Result.Name := Str(TJSONObject(Reply), 'name');
    Result.Sha1 := Str(TJSONObject(Reply), 'sha1');
  finally
    Reply.Free;
  end;
end;

procedure TGiteaClient.DeleteToken(const User: string; TokenId: Int64);
begin
  HttpJson('DELETE', Api('users/' + UrlEncode(User) + '/tokens/' + IntToStr(TokenId)), FAuth).Free;
end;

function TGiteaClient.SearchRepos(const Query: string; OwnerId: Int64): TGiteaRepos;
var
  Reply, Data: TJSONData;
  Page, I, Got: Integer;
  URL: string;
begin
  Result := nil;
  Page := 1;
  repeat
    URL := Api('repos/search?q=' + UrlEncode(Query) + '&limit=' + IntToStr(GiteaPageSize) +
      '&page=' + IntToStr(Page));
    if OwnerId <> 0 then
      URL := URL + '&uid=' + IntToStr(OwnerId) + '&exclusive=true';
    Reply := HttpJson('GET', URL, FAuth);
    try
      Data := nil;
      if Reply is TJSONObject then
        Data := TJSONObject(Reply).Find('data')
      else if (Reply <> nil) and (Reply.JSONType = jtArray) then
        Data := Reply;
      Got := 0;
      if (Data <> nil) and (Data.JSONType = jtArray) then
      begin
        Got := Data.Count;
        for I := 0 to Data.Count - 1 do
          if Data.Items[I] is TJSONObject then
            Result := Concat(Result, [ParseRepo(TJSONObject(Data.Items[I]))]);
      end;
    finally
      Reply.Free;
    end;
    Inc(Page);
  until (Got < GiteaPageSize) or (Page > 1000);
end;

function TGiteaClient.GetRepo(const Owner, Name: string; out Repo: TGiteaRepo): Boolean;
var
  Reply: TJSONData;
  Status: Integer;
begin
  Status := HttpJsonStatus('GET', Api('repos/' + UrlEncode(Owner) + '/' + UrlEncode(Name)),
    FAuth, nil, 15000, Reply);
  try
    Result := (Status = 200) and (Reply is TJSONObject);
    if Result then
      Repo := ParseRepo(TJSONObject(Reply))
    else if Status <> 404 then
    begin
      FreeAndNil(Reply);
      { Anything but "not there": let HttpJson raise the readable error. }
      HttpJson('GET', Api('repos/' + UrlEncode(Owner) + '/' + UrlEncode(Name)), FAuth).Free;
    end;
  finally
    Reply.Free;
  end;
end;

function TGiteaClient.CreateRepo(const Owner, Name: string; OwnerIsOrg: Boolean): TGiteaRepo;
var
  Body: TJSONObject;
  Reply: TJSONData;
  Path: string;
begin
  if OwnerIsOrg then
    Path := 'orgs/' + UrlEncode(Owner) + '/repos'
  else
    Path := 'user/repos';
  Body := TJSONObject.Create;
  try
    Body.Add('name', Name);
    Body.Add('description', 'btt-writer-desktop: ' + Name);
    Body.Add('private', False);
    Body.Add('auto_init', False);
    Reply := HttpJson('POST', Api(Path), FAuth, Body);
  finally
    Body.Free;
  end;
  try
    if not (Reply is TJSONObject) then
      raise EWBHttp.Create('POST repos: unexpected reply');
    Result := ParseRepo(TJSONObject(Reply));
  finally
    Reply.Free;
  end;
end;

end.
