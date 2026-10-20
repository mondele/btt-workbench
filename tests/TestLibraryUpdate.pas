unit TestLibraryUpdate;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Tests for the library updates (WBLibraryUpdate, library-languages,
   library-sources) and WBHttp.DecodeJsonEscapes. A local server serves
   small catalogs written here, BTT-Writer's schema (tests/fixtures/
   door43-schema.sql) makes the database, and the rows are checked against
   what BTT-Writer's door43-client writes for the same catalogs (worked out
   from its library.js and main.js; the full catalogs were compared with
   BTT-Writer's own output in October 2026, row for row). Skipped without a
   SQLite library. *)

interface

procedure TestLibraryUpdates(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fphttpserver, httpdefs, WBReporter, WBHttp, WBSqliteDb, WBLibraryUpdate,
  TestUtil;

type
  TLocalServer = class(TFPHttpServer)
  public
    property Address;
  end;

  TFileServer = class(TThread)
  private
    FServer: TLocalServer;
    procedure Idle(Sender: TObject);
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  protected
    procedure Execute; override;
  public
    Root: string;
    Port: Integer;
    Failed: string;
  end;

procedure TFileServer.Idle(Sender: TObject);
begin
  if Terminated then
    FServer.Active := False;
end;

{ /a/b.json -> Root/a/b.json; /a/b/ -> Root/a/b/index.json }
procedure TFileServer.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Path: string;
begin
  Path := ARequest.URI;
  if Pos('?', Path) > 0 then
    SetLength(Path, Pos('?', Path) - 1);
  if (Path <> '') and (Path[Length(Path)] = '/') then
    Path := Path + 'index.json';
  Path := Root + StringReplace(Copy(Path, 2, MaxInt), '/', PathDelim, [rfReplaceAll]);
  if FileExists(Path) then
  begin
    AResponse.Code := 200;
    AResponse.ContentType := 'application/json';
    AResponse.Content := ReadFileText(Path);
  end
  else
  begin
    AResponse.Code := 404;
    AResponse.Content := '{"message": "not here"}';
  end;
end;

procedure TFileServer.Execute;
begin
  FServer := TLocalServer.Create(nil);
  try
    FServer.Address := '127.0.0.1';
    FServer.Port := Port;
    FServer.AcceptIdleTimeout := 50;
    FServer.OnAcceptIdle := @Idle;
    FServer.OnRequest := @HandleRequest;
    try
      FServer.Active := True;
    except
      on E: Exception do
        Failed := E.Message;
    end;
  finally
    FreeAndNil(FServer);
  end;
end;

var
  Server: TFileServer;
  Base, Root: string;

procedure Put(const Path, Text: string);
begin
  ForceDirectories(ExtractFileDir(Root + Path));
  WriteFileText(Root + Path, Text);
end;

function StartServer: Boolean;
var
  Attempt: Integer;
begin
  for Attempt := 1 to 10 do
  begin
    Server := TFileServer.Create(True);
    Server.Root := Root;
    Server.Port := 20000 + Random(30000);
    Server.FreeOnTerminate := False;
    Server.Start;
    Sleep(150);
    if Server.Failed = '' then
      Break;
    Server.WaitFor;
    FreeAndNil(Server);
  end;
  Result := Server <> nil;
  if Result then
    Base := 'http://127.0.0.1:' + IntToStr(Server.Port);
end;

procedure StopServer;
begin
  if Server = nil then
    Exit;
  Server.Terminate;
  Server.WaitFor;
  FreeAndNil(Server);
end;

function Run(const ModuleId: string; const Args: array of string; out Code: Integer): string;
var
  R: TWBListReporter;
  I: Integer;
begin
  Code := RunModule(ModuleId, Args, R);
  try
    Result := '';
    for I := 0 to R.Count - 1 do
      Result := Result + LevelName(R.Levels[I]) + ': ' + R.Texts[I] + #10;
  finally
    R.Free;
  end;
  if GetEnvironmentVariable('BTW_SHOW') <> '' then
    WriteLn(Result);
end;

{ A fresh index.sqlite from BTT-Writer's schema, with Extra SQL run on it. }
procedure MakeIndex(const FileName, Extra: string);
var
  Db: TSqliteDb;
begin
  DeleteFile(FileName);
  Db := TSqliteDb.Create(FileName);
  try
    Db.Exec(ReadFileText(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'tests' + PathDelim +
      'fixtures' + PathDelim + 'door43-schema.sql'));
    if Extra <> '' then
      Db.Exec(Extra);
  finally
    Db.Free;
  end;
end;

function Q(const FileName, SQL: string): string;
var
  Db: TSqliteDb;
  Rows: TStringArray;
begin
  Db := TSqliteDb.Create(FileName);
  try
    Rows := Db.QueryTexts(SQL, []);
    Result := String.Join('|', Rows);
  finally
    Db.Free;
  end;
end;

procedure TestEscapes;
begin
  Section('JSON \u escapes');
  Check(DecodeJsonEscapes('"ไทย é"') = '"ไทย é"', 'decoded to UTF-8');
  Check(DecodeJsonEscapes('"😀"') = '"😀"', 'a surrogate pair');
  Check(DecodeJsonEscapes('"a"b\c\u000ad\\u0041"') = '"a"b\c\u000ad\\u0041"',
    'quotes, backslashes, control characters and an escaped backslash stay as they are');
  Check(DecodeJsonEscapes('"\ud83d x"') = '"\ud83d x"', 'an unpaired surrogate stays');
  Check(DecodeJsonEscapes('plain') = 'plain', 'nothing to do');
end;

procedure TestLanguages(const Data: string);
var
  Index, Out1, Output: string;
  Code: Integer;
begin
  Section('library-languages');
  Put('langnames.json', '[{"lc": "aa", "ln": "Qafaraf", "ang": "Afar", "ld": "ltr", ' +
    '"lr": "Africa", "gl": false}, {"lc": "th", "ln": "ไทย", "ang": "Thai", ' +
    '"ld": "ltr", "lr": "Asia", "gl": true}, {"lc": "ar", "ln": "العربية", "ang": "Arabic", ' +
    '"ld": "rtl", "lr": {"x": 1}}]');
  Put('td/templanguages/index.json', '[{"lc": "qaa-x-000001", "ln": "Temp One", "ang": "", ' +
    '"ld": "ltr", "lr": "Africa", "gw": false}]');
  Put('td/templanguages/assignment/changed/index.json', '[{"qaa-x-000001": "aa"}]');
  Put('td/questionnaire/index.json', '{"languages": [{"slug": "en", "name": "English", ' +
    '"dir": "LTR", "questionnaire_id": 2, "language_data": {"ln": 0, "cc": 2}, "questions": [' +
    '{"id": 0, "text": "Name?", "help": "h", "required": true, "input_type": "string", ' +
    '"sort": 1, "depends_on": null}, {"id": 1, "text": "Where?", "input_type": "string", ' +
    '"sort": 2, "depends_on": 0}]}]}');
  Index := Data + 'index.sqlite';
  MakeIndex(Index, 'insert into target_language (slug, name, direction, region) values ' +
    '(''zz'', ''Gone'', ''ltr'', '''');' +
    'insert into temp_target_language (slug, name, direction, region, approved_target_language_slug)' +
    ' values (''qaa-x-000001'', ''Old'', ''ltr'', '''', ''old'');');
  Output := Data + 'out' + PathDelim + 'index.sqlite';
  Out1 := Run('library-languages', ['--library-db', Index, '--output', Output,
    '--languages-url', Base + '/langnames.json'], Code);
  Check(Code = 0, 'runs');
  Check(Q(Output, 'select slug from target_language order by id') = 'aa|th|ar',
    'target languages replaced in catalog order (the stale one gone)');
  Check(Q(Output, 'select name || '','' || is_gateway_language from target_language ' +
    'where slug=''th''') = 'ไทย,1', 'names decoded from \u escapes; gateway as 1');
  Check(Q(Output, 'select ''['' || region || '']'' from target_language where slug=''ar''') = '[]',
    'a region that is not a string becomes ''''');
  Check(Q(Output, 'select name || '','' || approved_target_language_slug from ' +
    'temp_target_language') = 'Temp One,aa',
    'temporary languages updated, approved code set again');
  Check(Q(Output, 'select language_direction || '','' || td_id from questionnaire') = 'ltr,2',
    'the questionnaire');
  Check(Q(Output, 'select field || ''='' || question_td_id from questionnaire_data_field ' +
    'order by id') = 'ln=0|cc=2', 'its data fields');
  Check(Q(Output, 'select text || '','' || is_required || '','' || depends_on || '','' || ' +
    'coalesce(help, ''-'') from question order by id') = 'Name?,1,-1,h',
    'its questions: required as 1/0, no dependency as -1; one without help is left out, ' +
    'as BTT-Writer leaves it out (help is NOT NULL, and insert or ignore drops it)');
  Check(Q(Output, 'select slug || ''='' || url from catalog where slug=''langnames''') =
    'langnames=' + Base + '/langnames.json', 'the catalogs BTT-Writer keeps');
  Check(Q(Index, 'select count(*) from target_language') = '1', 'the source database is not changed');
  Check(Pos('Target languages: 1 before, 3 now', Out1) > 0, 'reported');

  { an entry BTT-Writer would refuse: it stops, and nothing changes }
  Put('bad.json', '[{"lc": "bb", "ln": "B", "ld": "ltr"}, {"lc": "cc", "ln": "", "ld": "ltr"}]');
  Out1 := Run('library-languages', ['--library-db', Index, '--output', Output,
    '--languages-url', Base + '/bad.json'], Code);
  Check((Code = 1) and (Q(Output, 'select group_concat(slug) from target_language') = 'zz'),
    'an invalid entry: stopped, rolled back');
  Out1 := Run('library-languages', ['--library-db', Index, '--output', Index], Code);
  Check(Code = 1, 'the output must be another file');
end;

procedure TestSources(const Data: string);
var
  Index, Output, Out1: string;
  Code: Integer;
begin
  Section('library-sources');
  Put('v2/ts/catalog.json', '[{"slug": "tit", "sort": "56", "meta": ["bible-nt"], ' +
    '"lang_catalog": "' + Base + '/cdn/tit/languages.json"}, {"slug": "obs", "sort": "1", ' +
    '"meta": [], "lang_catalog": "' + Base + '/cdn/obs/languages.json"}, {"slug": "jud", ' +
    '"sort": "65", "meta": ["bible-nt"], "lang_catalog": "' + Base + '/cdn/gone.json"}]');
  Put('cdn/tit/languages.json', '[{"language": {"slug": "en", "name": "English", ' +
    '"direction": "ltr"}, "project": {"name": "Titus", "desc": "", "meta": ["New Testament"]}, ' +
    '"res_catalog": "' + Base + '/cdn/tit/en/resources.json"}, {"language": {"slug": "th", ' +
    '"name": "ไทย", "direction": "ltr"}, "project": {"name": "ทิตัส", ' +
    '"meta": ["Nuevo"]}, "res_catalog": "' + Base + '/cdn/tit/th/resources.json"}]');
  Put('cdn/tit/en/resources.json', '[{"slug": "ULB", "name": "Unlocked Literal Bible", ' +
    '"status": {"checking_level": "3", "version": "10", "publish_date": "2024-01-01", ' +
    '"license": "CC BY-SA 4.0", "comments": ""}, "date_modified": "20240101", "source": "S", ' +
    '"notes": "N", "checking_questions": "Q", "terms": "T", "tw_cat": "W"}]');
  { the first entry is invalid (no checking level): BTT-Writer stops there }
  Put('cdn/tit/th/resources.json', '[{"slug": "reg", "name": "R", "status": ' +
    '{"checking_level": "", "version": "1"}, "source": "S2"}, {"slug": "udb", "name": "U", ' +
    '"status": {"checking_level": "3", "version": "1"}, "source": "S3"}]');
  Put('cdn/obs/languages.json', '[{"language": {"slug": "en", "name": "English", ' +
    '"direction": "ltr"}, "project": {"name": "Open Bible Stories", "meta": []}, ' +
    '"res_catalog": "' + Base + '/cdn/obs/en/resources.json"}]');
  Put('cdn/obs/en/resources.json', '[{"slug": "obs", "name": "OBS", "status": ' +
    '{"checking_level": "3", "version": "4"}, "date_modified": "", "source": "O", "terms": "OT"}]');
  Put('ta/intro_1.json', '{"meta": {"manual": "intro", "volume": 1, "mod": "20240101", ' +
    '"status": {"checking_level": "3", "version": "4"}}}');
  Index := Data + 'index.sqlite';
  MakeIndex(Index, '');
  Output := Data + 'sources.sqlite';
  Out1 := Run('library-sources', ['--library-db', Index, '--output', Output, '--server', Base,
    '--connections', '3'], Code);
  Check(Code = 0, 'runs');
  Check(Q(Output, 'select p.slug || ''/'' || l.slug || '':'' || p.name || '':'' || p.sort || '':'' || ' +
    'p.chunks_url from project p join source_language l on l.id = p.source_language_id ' +
    'order by p.id') = 'tit/en:Titus:56:https://api.unfoldingword.org/bible/txt/1/tit/chunks.json|' +
    'tit/th:ทิตัส:56:https://api.unfoldingword.org/bible/txt/1/tit/chunks.json|' +
    'obs/en:Open Bible Stories:1:|bible/en:translationWords:100:|' +
    'bible-obs/en:translationWords OBS:100:|ta-intro/en:Intro Manual:0:',
    'projects in BTT-Writer''s order (every catalog project, then the words projects as ' +
    'resources are written, then tA)');
  Check(Q(Output, 'select c.slug || ''='' || n.name from category_name n join category c ' +
    'on c.id = n.category_id order by n.id') = 'bible-nt=New Testament|bible-nt=Nuevo|' +
    'ta=translationAcademy', 'categories named per source language');
  Check(Q(Output, 'select r.slug || '','' || r.type || '','' || r.translate_mode || '','' || ' +
    'r.pub_date || '','' || r.license || '','' || f.mime_type || '','' || f.url from resource r ' +
    'join resource_format f on f.resource_id = r.id order by r.id') =
    'ulb,book,all,2024-01-01,CC BY-SA 4.0,application/tsrc+book,S|' +
    'tn,help,gl,2024-01-01,CC BY-SA 4.0,application/tsrc+help,N|' +
    'tq,help,gl,2024-01-01,CC BY-SA 4.0,application/tsrc+help,Q|' +
    'tw,dict,gl,2024-01-01,CC BY-SA 4.0,application/tsrc+dict,T|' +
    'obs,book,all,0,,application/tsrc+book,O|tw,dict,gl,0,,application/tsrc+dict,OT|' +
    'vol1,man,gl,0,,application/tsrc+man,' + Base + '/ta/intro_1.json',
    'resources: slugs in lower case, notes/questions/words from the same status, ' +
    'nothing from a file stopped at its first entry');
  Check(Q(Output, 'select count(*) from legacy_resource_info') = '1', 'tw_cat kept for the ULB only');
  Check(Q(Output, 'select name from source_language where slug = ''th''') = 'ไทย',
    'source language names decoded');
  Check((Pos('cdn/gone.json', Out1) > 0) and (Pos('checking_level', Out1) > 0) and
    (Pos('ta/audio_2.json', Out1) > 0), 'what could not be read or was refused is reported');
end;

procedure TestLibraryUpdates(const TempRoot: string);
var
  Data, OldTd, OldTa: string;
begin
  TestEscapes;
  if SqliteLibraryVersion = '' then
  begin
    Section('library updates: skipped, no SQLite library');
    Exit;
  end;
  Data := TempRoot + 'library' + PathDelim;
  Root := Data + 'www' + PathDelim;
  ForceDirectories(Root);
  if not StartServer then
  begin
    Check(False, 'local server starts');
    Exit;
  end;
  OldTd := TranslationDatabaseApi;
  OldTa := TranslationAcademyBase;
  TranslationDatabaseApi := Base + '/td/';
  TranslationAcademyBase := Base + '/ta/';
  try
    TestLanguages(Data);
    TestSources(Data);
  finally
    TranslationDatabaseApi := OldTd;
    TranslationAcademyBase := OldTa;
    StopServer;
  end;
end;

end.
