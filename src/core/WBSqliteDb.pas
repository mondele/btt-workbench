unit WBSqliteDb;

{$mode objfpc}{$H+}

(* Writing SQLite databases, through the SQLite library the system has,
   loaded when first needed: libsqlite3.so.0 on Linux, winsqlite3.dll on
   Windows 10 and later (sqlite3.dll if one is put beside the program).
   Reading BTT-Writer's index.sqlite needs no library (WBSqlite); only the
   library updates write one.

   Statements are prepared once per SQL text and reused; parameters are
   bound by name (:slug) as BTT-Writer's door43 client binds them, so the
   updates can run its SQL unchanged. *)

interface

uses
  Classes, SysUtils, Generics.Collections;

type
  ESqliteDb = class(Exception);

  TDbValueKind = (dvNull, dvInt, dvFloat, dvText);
  TDbValue = record
    Kind: TDbValueKind;
    I: Int64;
    F: Double;
    S: string;   // UTF-8
  end;

  TDbParam = record
    Name: string;      // without the ':'
    Value: TDbValue;
  end;
  TDbParams = array of TDbParam;

  TSqliteDb = class
  private
    FDb: Pointer;
    FStatements: specialize TDictionary<string, Pointer>;
    function Prepared(const SQL: string): Pointer;
    procedure Bind(Stmt: Pointer; const Params: TDbParams);
    procedure Check(Code: Integer; const What: string);
  public
    { Opens (or creates) FileName. Raises ESqliteDb if the library or the
      file cannot be used. }
    constructor Create(const FileName: string);
    destructor Destroy; override;
    { Runs SQL with no parameters and no result (several statements are
      fine). }
    procedure Exec(const SQL: string);
    { Runs one statement with named parameters, ignoring any rows. }
    procedure Run(const SQL: string; const Params: TDbParams);
    { The first column of the first row as an integer, or Default. }
    function QueryInt(const SQL: string; const Params: TDbParams; Default: Int64 = -1): Int64;
    { The first column of every row, as text. }
    function QueryTexts(const SQL: string; const Params: TDbParams): TStringArray;
    { Rows the last Run changed. }
    function Changes: Integer;
    procedure BeginTransaction;
    procedure Commit;
    procedure Rollback;
  end;

{ The library's version, or '' if no SQLite library can be loaded. }
function SqliteLibraryVersion: string;

function DbNull: TDbValue;
function DbInt(V: Int64): TDbValue;
function DbFloat(V: Double): TDbValue;
function DbText(const V: string): TDbValue;
function P(const Name: string; const Value: TDbValue): TDbParam;

implementation

uses
  dynlibs;

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  SQLITE_OPEN_READWRITE = $02;
  SQLITE_OPEN_CREATE = $04;
  SQLITE_INTEGER = 1;
  SQLITE_TRANSIENT = Pointer(-1);

type
  PPointer = ^Pointer;
  TOpenV2 = function(FileName: PAnsiChar; Db: PPointer; Flags: LongInt; Vfs: PAnsiChar): LongInt; cdecl;
  TClose = function(Db: Pointer): LongInt; cdecl;
  TExec = function(Db: Pointer; SQL: PAnsiChar; Callback, Arg: Pointer; Err: PPointer): LongInt; cdecl;
  TPrepareV2 = function(Db: Pointer; SQL: PAnsiChar; Bytes: LongInt; Stmt: PPointer; Tail: PPointer): LongInt; cdecl;
  TStmtFn = function(Stmt: Pointer): LongInt; cdecl;
  TBindIndex = function(Stmt: Pointer; Name: PAnsiChar): LongInt; cdecl;
  TBindInt64 = function(Stmt: Pointer; Index: LongInt; V: Int64): LongInt; cdecl;
  TBindDouble = function(Stmt: Pointer; Index: LongInt; V: Double): LongInt; cdecl;
  TBindText = function(Stmt: Pointer; Index: LongInt; V: PAnsiChar; Bytes: LongInt; Destructor_: Pointer): LongInt; cdecl;
  TBindNull = function(Stmt: Pointer; Index: LongInt): LongInt; cdecl;
  TColumnInt64 = function(Stmt: Pointer; Col: LongInt): Int64; cdecl;
  TColumnText = function(Stmt: Pointer; Col: LongInt): PAnsiChar; cdecl;
  TColumnType = function(Stmt: Pointer; Col: LongInt): LongInt; cdecl;
  TErrMsg = function(Db: Pointer): PAnsiChar; cdecl;
  TChanges = function(Db: Pointer): LongInt; cdecl;
  TLibVersion = function: PAnsiChar; cdecl;
  TFree = procedure(P: Pointer); cdecl;

var
  Lib: TLibHandle = NilHandle;
  Tried: Boolean = False;
  sqlite3_open_v2: TOpenV2;
  sqlite3_close: TClose;
  sqlite3_exec: TExec;
  sqlite3_prepare_v2: TPrepareV2;
  sqlite3_step, sqlite3_reset, sqlite3_finalize, sqlite3_clear_bindings: TStmtFn;
  sqlite3_bind_parameter_index: TBindIndex;
  sqlite3_bind_int64: TBindInt64;
  sqlite3_bind_double: TBindDouble;
  sqlite3_bind_text: TBindText;
  sqlite3_bind_null: TBindNull;
  sqlite3_column_int64: TColumnInt64;
  sqlite3_column_text: TColumnText;
  sqlite3_column_type: TColumnType;
  sqlite3_errmsg: TErrMsg;
  sqlite3_changes: TChanges;
  sqlite3_libversion: TLibVersion;
  sqlite3_free: TFree;

function LoadLib: Boolean;
const
  Names: array[0..3] of string = (
    {$IFDEF WINDOWS}'sqlite3.dll', 'winsqlite3.dll', '', ''
    {$ELSE}{$IFDEF DARWIN}'libsqlite3.dylib', '/usr/lib/libsqlite3.dylib', '', ''
    {$ELSE}'libsqlite3.so.0', 'libsqlite3.so', '', ''{$ENDIF}{$ENDIF});
var
  N: string;

  function Get(const Name: string): Pointer;
  begin
    Result := GetProcAddress(Lib, Name);
    if Result = nil then
      raise ESqliteDb.CreateFmt('The SQLite library has no %s', [Name]);
  end;

begin
  if not Tried then
  begin
    Tried := True;
    for N in Names do
      if (N <> '') and (Lib = NilHandle) then
        Lib := LoadLibrary(N);
    if Lib <> NilHandle then
    begin
      Pointer(sqlite3_open_v2) := Get('sqlite3_open_v2');
      Pointer(sqlite3_close) := Get('sqlite3_close');
      Pointer(sqlite3_exec) := Get('sqlite3_exec');
      Pointer(sqlite3_prepare_v2) := Get('sqlite3_prepare_v2');
      Pointer(sqlite3_step) := Get('sqlite3_step');
      Pointer(sqlite3_reset) := Get('sqlite3_reset');
      Pointer(sqlite3_finalize) := Get('sqlite3_finalize');
      Pointer(sqlite3_clear_bindings) := Get('sqlite3_clear_bindings');
      Pointer(sqlite3_bind_parameter_index) := Get('sqlite3_bind_parameter_index');
      Pointer(sqlite3_bind_int64) := Get('sqlite3_bind_int64');
      Pointer(sqlite3_bind_double) := Get('sqlite3_bind_double');
      Pointer(sqlite3_bind_text) := Get('sqlite3_bind_text');
      Pointer(sqlite3_bind_null) := Get('sqlite3_bind_null');
      Pointer(sqlite3_column_int64) := Get('sqlite3_column_int64');
      Pointer(sqlite3_column_text) := Get('sqlite3_column_text');
      Pointer(sqlite3_column_type) := Get('sqlite3_column_type');
      Pointer(sqlite3_errmsg) := Get('sqlite3_errmsg');
      Pointer(sqlite3_changes) := Get('sqlite3_changes');
      Pointer(sqlite3_libversion) := Get('sqlite3_libversion');
      Pointer(sqlite3_free) := Get('sqlite3_free');
    end;
  end;
  Result := Lib <> NilHandle;
end;

function SqliteLibraryVersion: string;
begin
  Result := '';
  try
    if LoadLib then
      Result := string(sqlite3_libversion());
  except
    Result := '';
  end;
end;

function DbNull: TDbValue;
begin
  Result := Default(TDbValue);
end;

function DbInt(V: Int64): TDbValue;
begin
  Result := Default(TDbValue);
  Result.Kind := dvInt;
  Result.I := V;
end;

function DbFloat(V: Double): TDbValue;
begin
  Result := Default(TDbValue);
  Result.Kind := dvFloat;
  Result.F := V;
end;

function DbText(const V: string): TDbValue;
begin
  Result := Default(TDbValue);
  Result.Kind := dvText;
  Result.S := V;
end;

function P(const Name: string; const Value: TDbValue): TDbParam;
begin
  Result.Name := Name;
  Result.Value := Value;
end;

constructor TSqliteDb.Create(const FileName: string);
begin
  inherited Create;
  FStatements := specialize TDictionary<string, Pointer>.Create;
  if not LoadLib then
    raise ESqliteDb.Create('No SQLite library was found on this computer');
  if sqlite3_open_v2(PAnsiChar(UTF8Encode(FileName)), @FDb,
     SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil) <> SQLITE_OK then
  begin
    if FDb <> nil then
      sqlite3_close(FDb);
    FDb := nil;
    raise ESqliteDb.CreateFmt('Cannot open %s', [FileName]);
  end;
end;

destructor TSqliteDb.Destroy;
var
  Stmt: Pointer;
begin
  if FStatements <> nil then
    for Stmt in FStatements.Values do
      sqlite3_finalize(Stmt);
  FStatements.Free;
  if FDb <> nil then
    sqlite3_close(FDb);
  inherited Destroy;
end;

procedure TSqliteDb.Check(Code: Integer; const What: string);
begin
  if (Code <> SQLITE_OK) and (Code <> SQLITE_ROW) and (Code <> SQLITE_DONE) then
    raise ESqliteDb.CreateFmt('%s: %s', [What, string(sqlite3_errmsg(FDb))]);
end;

function TSqliteDb.Prepared(const SQL: string): Pointer;
begin
  if FStatements.TryGetValue(SQL, Result) then
    Exit;
  Result := nil;
  Check(sqlite3_prepare_v2(FDb, PAnsiChar(SQL), -1, @Result, nil), SQL);
  FStatements.Add(SQL, Result);
end;

procedure TSqliteDb.Bind(Stmt: Pointer; const Params: TDbParams);
var
  Prm: TDbParam;
  Index: LongInt;
begin
  sqlite3_reset(Stmt);
  sqlite3_clear_bindings(Stmt);
  for Prm in Params do
  begin
    Index := sqlite3_bind_parameter_index(Stmt, PAnsiChar(':' + Prm.Name));
    if Index = 0 then
      Continue;   // not used by this statement
    case Prm.Value.Kind of
      dvNull: sqlite3_bind_null(Stmt, Index);
      dvInt: sqlite3_bind_int64(Stmt, Index, Prm.Value.I);
      dvFloat: sqlite3_bind_double(Stmt, Index, Prm.Value.F);
      dvText: sqlite3_bind_text(Stmt, Index, PAnsiChar(Prm.Value.S), Length(Prm.Value.S),
        SQLITE_TRANSIENT);
    end;
  end;
end;

procedure TSqliteDb.Exec(const SQL: string);
var
  Err: Pointer;
  Msg: string;
begin
  Err := nil;
  if sqlite3_exec(FDb, PAnsiChar(SQL), nil, nil, @Err) <> SQLITE_OK then
  begin
    Msg := string(PAnsiChar(Err));
    sqlite3_free(Err);
    raise ESqliteDb.CreateFmt('%s: %s', [SQL, Msg]);
  end;
end;

procedure TSqliteDb.Run(const SQL: string; const Params: TDbParams);
var
  Stmt: Pointer;
  Code: LongInt;
begin
  Stmt := Prepared(SQL);
  Bind(Stmt, Params);
  repeat
    Code := sqlite3_step(Stmt);
  until Code <> SQLITE_ROW;
  sqlite3_reset(Stmt);
  Check(Code, SQL);
end;

function TSqliteDb.QueryInt(const SQL: string; const Params: TDbParams; Default: Int64): Int64;
var
  Stmt: Pointer;
  Code: LongInt;
begin
  Result := Default;
  Stmt := Prepared(SQL);
  Bind(Stmt, Params);
  Code := sqlite3_step(Stmt);
  if (Code = SQLITE_ROW) and (sqlite3_column_type(Stmt, 0) = SQLITE_INTEGER) then
    Result := sqlite3_column_int64(Stmt, 0);
  sqlite3_reset(Stmt);
  Check(Code, SQL);
end;

function TSqliteDb.QueryTexts(const SQL: string; const Params: TDbParams): TStringArray;
var
  Stmt: Pointer;
  Code: LongInt;
begin
  Result := nil;
  Stmt := Prepared(SQL);
  Bind(Stmt, Params);
  Code := sqlite3_step(Stmt);
  while Code = SQLITE_ROW do
  begin
    Result := Concat(Result, [string(sqlite3_column_text(Stmt, 0))]);
    Code := sqlite3_step(Stmt);
  end;
  sqlite3_reset(Stmt);
  Check(Code, SQL);
end;

function TSqliteDb.Changes: Integer;
begin
  Result := sqlite3_changes(FDb);
end;

procedure TSqliteDb.BeginTransaction;
begin
  Exec('BEGIN');
end;

procedure TSqliteDb.Commit;
begin
  Exec('COMMIT');
end;

procedure TSqliteDb.Rollback;
begin
  Exec('ROLLBACK');
end;

end.
