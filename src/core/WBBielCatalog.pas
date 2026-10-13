unit WBBielCatalog;

{$mode objfpc}{$H+}

{ The BIEL Public Data API (Hasura GraphQL, no login) for the state WA
  gives each WACS repo: Primary, Active, Inactive or none
  (content.wa_content_metadata.status). Matched on content.name, which is
  "<owner>/<repo>"; filtering by language id is unreliable there, so we
  filter by name with ILIKE patterns (as Sefer and the wacs-chunk-audit
  notes do). Patterns go in as GraphQL variables, so '_' and '%' in them
  are escaped once, here. The API can take a minute to answer, so answers
  are kept for ten minutes (per set of name fragments) for the rest of the
  run: a second Find in the GUI is quick. }

interface

uses
  Classes, SysUtils;

type
  TBielState = record
    FullName: string;   // owner/repo, lower case
    Status: string;     // Primary, Active, Inactive or ''
    Modified: string;
  end;
  TBielStates = array of TBielState;

{ States of every repo whose name contains one of Fragments (plain text,
  e.g. 'udm_hag_'). False with ErrorMsg if the API cannot be asked. }
function BielStates(const Fragments: TStringArray; out States: TBielStates;
  out ErrorMsg: string): Boolean;
{ The state of FullName in States, '' if not listed. }
function BielStateOf(const States: TBielStates; const FullName: string): string;

var
  { BTW_BIEL_URL overrides it (tests). }
  BielEndpoint: string = 'https://api.bibleineverylanguage.org/v1/graphql';

implementation

uses
  fpjson, syncobjs, DateUtils, Generics.Collections, WBHttp;

type
  TCached = record
    When: TDateTime;
    States: TBielStates;
  end;

const
  CacheMinutes = 10;

var
  CacheLock: TCriticalSection;
  Cache: specialize TDictionary<string, TCached>;

function Endpoint: string; forward;

function CacheKey(const Fragments: TStringArray): string;
var
  L: TStringList;
  F: string;
begin
  L := TStringList.Create;
  try
    for F in Fragments do
      L.Add(LowerCase(F));
    L.Sort;
    Result := Endpoint + '|' + L.CommaText;
  finally
    L.Free;
  end;
end;

const
  Query =
    'query ($w: content_bool_exp!) { content(where: $w) { name modified_on ' +
    'wa_content_metadata { status } git_repo { username repo_name } } }';

function EscapeLike(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in S do
  begin
    if C in ['\', '%', '_'] then
      Result := Result + '\';
    Result := Result + C;
  end;
end;

function Endpoint: string;
begin
  Result := Trim(GetEnvironmentVariable('BTW_BIEL_URL'));
  if Result = '' then
    Result := BielEndpoint;
end;

function StrAt(Obj: TJSONData; const Path: string): string;
var
  D: TJSONData;
begin
  Result := '';
  if not (Obj is TJSONObject) then
    Exit;
  D := TJSONObject(Obj).FindPath(Path);
  if (D <> nil) and (D.JSONType = jtString) then
    Result := D.AsString;
end;

function BielStates(const Fragments: TStringArray; out States: TBielStates;
  out ErrorMsg: string): Boolean;
var
  Body, Vars, Where, Clause: TJSONObject;
  Ors: TJSONArray;
  Reply, Rows, Row: TJSONData;
  F, Owner, Repo: string;
  I: Integer;
  S: TBielState;
  Key: string;
  Hit: TCached;
begin
  States := nil;
  ErrorMsg := '';
  Result := False;
  Key := CacheKey(Fragments);
  CacheLock.Enter;
  try
    if Cache.TryGetValue(Key, Hit) and (MinutesBetween(Now, Hit.When) < CacheMinutes) then
    begin
      States := Hit.States;
      Exit(True);
    end;
  finally
    CacheLock.Leave;
  end;
  Body := TJSONObject.Create;
  try
    Ors := TJSONArray.Create;
    for F in Fragments do
    begin
      Clause := TJSONObject.Create;
      Clause.Add('name', TJSONObject.Create(['_ilike', '%' + EscapeLike(F) + '%']));
      Ors.Add(Clause);
    end;
    Where := TJSONObject.Create;
    Where.Add('_or', Ors);
    Vars := TJSONObject.Create;
    Vars.Add('w', Where);
    Body.Add('query', Query);
    Body.Add('variables', Vars);
    try
      Reply := HttpJson('POST', Endpoint, NoAuth, Body, 180000);
    except
      on E: Exception do
      begin
        ErrorMsg := E.Message;
        Exit;
      end;
    end;
  finally
    Body.Free;
  end;
  try
    if (Reply is TJSONObject) and (TJSONObject(Reply).Find('errors') <> nil) then
    begin
      ErrorMsg := TJSONObject(Reply).Find('errors').AsJSON;
      Exit;
    end;
    Rows := nil;
    if Reply is TJSONObject then
      Rows := TJSONObject(Reply).FindPath('data.content');
    if (Rows = nil) or (Rows.JSONType <> jtArray) then
    begin
      ErrorMsg := 'unexpected reply';
      Exit;
    end;
    for I := 0 to Rows.Count - 1 do
    begin
      Row := Rows.Items[I];
      Owner := StrAt(Row, 'git_repo.username');
      Repo := StrAt(Row, 'git_repo.repo_name');
      if (Owner <> '') and (Repo <> '') then
        S.FullName := LowerCase(Owner + '/' + Repo)
      else
        S.FullName := LowerCase(StrAt(Row, 'name'));
      S.Status := StrAt(Row, 'wa_content_metadata.status');
      S.Modified := StrAt(Row, 'modified_on');
      States := Concat(States, [S]);
    end;
    Result := True;
    Hit.When := Now;
    Hit.States := States;
    CacheLock.Enter;
    try
      Cache.AddOrSetValue(Key, Hit);
    finally
      CacheLock.Leave;
    end;
  finally
    Reply.Free;
  end;
end;

function BielStateOf(const States: TBielStates; const FullName: string): string;
var
  S: TBielState;
begin
  for S in States do
    if S.FullName = LowerCase(FullName) then
      Exit(S.Status);
  Result := '';
end;

initialization
  CacheLock := TCriticalSection.Create;
  Cache := specialize TDictionary<string, TCached>.Create;

finalization
  Cache.Free;
  CacheLock.Free;

end.
