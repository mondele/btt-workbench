unit WBSqlite;

{$mode objfpc}{$H+}

{ A small read-only reader for SQLite 3 database files, enough to read every
  row of a table (BTT-Writer's index.sqlite). Pure Pascal, so it needs no
  sqlite3 library: Windows has none, and neither does Android for the .so.

  Follows https://www.sqlite.org/fileformat.html: the file is read into
  memory, sqlite_master gives the table's root page and CREATE TABLE
  statement, and the table b-tree is walked in rowid order, following
  overflow pages. Values are returned as strings (numbers formatted, blobs
  raw); NULL is reported separately. Only UTF-8 databases are read. A
  -wal file next to the database is ignored (BTT-Writer does not use WAL). }

interface

uses
  Classes, SysUtils;

type
  ESqliteFormat = class(Exception);

  TSqliteRow = record
    RowId: Int64;
    Values: TStringArray;
    IsNull: array of Boolean;
  end;
  TSqliteRows = array of TSqliteRow;

  TSqliteFile = class
  private
    FData: TBytes;
    FPageSize, FUsable: Integer;
    function PageOffset(Page: Int64): Int64;
    function Byte1(Pos: Int64): Byte;
    function Int16At(Pos: Int64): Integer;
    function Int32At(Pos: Int64): Int64;
    function VarInt(var Pos: Int64): Int64;
    function Payload(Pos: Int64; Size: Int64): TBytes;
    procedure Walk(Page: Int64; var Rows: TSqliteRows; Depth: Integer);
    function DecodeRecord(const Rec: TBytes): TSqliteRow;
    function TableInfo(const Table: string; out RootPage: Int64; out Sql: string): Boolean;
  public
    constructor Create(const FileName: string);
    { Every row of a table, in rowid order. Raises ESqliteFormat if the
      table is missing or the file is damaged. }
    function ReadTable(const Table: string): TSqliteRows;
    { Column names of a table, in order, from its CREATE TABLE. }
    function Columns(const Table: string): TStringArray;
  end;

{ Index of Name in Columns (case-insensitive), -1 if absent. }
function ColumnIndex(const Columns: TStringArray; const Name: string): Integer;
{ A row's value for column Index ('' for NULL or a short row). }
function RowValue(const Row: TSqliteRow; Index: Integer): string;

implementation

const
  Magic = 'SQLite format 3'#0;
  MaxDepth = 64;

function ColumnIndex(const Columns: TStringArray; const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Columns) do
    if SameText(Columns[I], Name) then
      Exit(I);
  Result := -1;
end;

function RowValue(const Row: TSqliteRow; Index: Integer): string;
begin
  if (Index < 0) or (Index > High(Row.Values)) or Row.IsNull[Index] then
    Exit('');
  Result := Row.Values[Index];
end;

constructor TSqliteFile.Create(const FileName: string);
var
  F: TFileStream;
  Header: string;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(FData, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(FData[0], F.Size);
  finally
    F.Free;
  end;
  if Length(FData) < 100 then
    raise ESqliteFormat.Create('not an SQLite database');
  SetString(Header, PChar(@FData[0]), 16);
  if Header <> Magic then
    raise ESqliteFormat.Create('not an SQLite database');
  FPageSize := Int16At(16);
  if FPageSize = 1 then
    FPageSize := 65536;
  if (FPageSize < 512) or (FPageSize and (FPageSize - 1) <> 0) then
    raise ESqliteFormat.Create('bad page size');
  FUsable := FPageSize - FData[20];
  if Int32At(56) > 1 then
    raise ESqliteFormat.Create('only UTF-8 databases can be read');
end;

function TSqliteFile.PageOffset(Page: Int64): Int64;
begin
  if (Page < 1) or (Page * FPageSize > Length(FData)) then
    raise ESqliteFormat.CreateFmt('page %d is outside the file', [Page]);
  Result := (Page - 1) * FPageSize;
end;

function TSqliteFile.Byte1(Pos: Int64): Byte;
begin
  if (Pos < 0) or (Pos >= Length(FData)) then
    raise ESqliteFormat.Create('read past the end of the file');
  Result := FData[Pos];
end;

function TSqliteFile.Int16At(Pos: Int64): Integer;
begin
  Result := (Byte1(Pos) shl 8) or Byte1(Pos + 1);
end;

function TSqliteFile.Int32At(Pos: Int64): Int64;
begin
  Result := (Int64(Byte1(Pos)) shl 24) or (Byte1(Pos + 1) shl 16) or
    (Byte1(Pos + 2) shl 8) or Byte1(Pos + 3);
end;

function TSqliteFile.VarInt(var Pos: Int64): Int64;
var
  I: Integer;
  B: Byte;
begin
  Result := 0;
  for I := 1 to 8 do
  begin
    B := Byte1(Pos);
    Inc(Pos);
    Result := (Result shl 7) or (B and $7F);
    if B < $80 then
      Exit;
  end;
  B := Byte1(Pos);
  Inc(Pos);
  Result := (Result shl 8) or B;
end;

{ A table-leaf cell's payload of Size bytes starting at Pos, with any
  overflow pages joined on. }
function TSqliteFile.Payload(Pos: Int64; Size: Int64): TBytes;
var
  MaxLocal, MinLocal, Local, Got, Chunk: Int64;
  Next: Int64;
  Pages: Integer;
begin
  Result := nil;
  if Size < 0 then
    raise ESqliteFormat.Create('bad payload size');
  SetLength(Result, Size);
  MaxLocal := FUsable - 35;
  if Size <= MaxLocal then
    Local := Size
  else
  begin
    MinLocal := ((FUsable - 12) * 32 div 255) - 23;
    Local := MinLocal + ((Size - MinLocal) mod (FUsable - 4));
    if Local > MaxLocal then
      Local := MinLocal;
  end;
  if Pos + Local > Length(FData) then
    raise ESqliteFormat.Create('cell runs past the end of the file');
  if Local > 0 then
    Move(FData[Pos], Result[0], Local);
  Got := Local;
  if Got >= Size then
    Exit;
  Next := Int32At(Pos + Local);
  Pages := 0;
  while Got < Size do
  begin
    Inc(Pages);
    if (Next = 0) or (Pages > Length(FData) div FPageSize) then
      raise ESqliteFormat.Create('broken overflow chain');
    Chunk := Size - Got;
    if Chunk > FUsable - 4 then
      Chunk := FUsable - 4;
    Move(FData[PageOffset(Next) + 4], Result[Got], Chunk);
    Inc(Got, Chunk);
    Next := Int32At(PageOffset(Next));
  end;
end;

procedure TSqliteFile.Walk(Page: Int64; var Rows: TSqliteRows; Depth: Integer);
var
  Base, Hdr, Cell, Size, RowId: Int64;
  Kind: Byte;
  Count, I: Integer;
  Row: TSqliteRow;
begin
  if Depth > MaxDepth then
    raise ESqliteFormat.Create('b-tree too deep (damaged file?)');
  Base := PageOffset(Page);
  Hdr := Base;
  if Page = 1 then
    Hdr := 100;   // page 1 starts with the file header
  Kind := Byte1(Hdr);
  Count := Int16At(Hdr + 3);
  case Kind of
    $05:   // interior table page: children left of each key, then the right-most
      begin
        for I := 0 to Count - 1 do
        begin
          Cell := Base + Int16At(Hdr + 12 + 2 * I);
          Walk(Int32At(Cell), Rows, Depth + 1);
        end;
        Walk(Int32At(Hdr + 8), Rows, Depth + 1);
      end;
    $0D:   // leaf table page
      for I := 0 to Count - 1 do
      begin
        Cell := Base + Int16At(Hdr + 8 + 2 * I);
        Size := VarInt(Cell);
        RowId := VarInt(Cell);
        Row := DecodeRecord(Payload(Cell, Size));
        Row.RowId := RowId;
        SetLength(Rows, Length(Rows) + 1);
        Rows[High(Rows)] := Row;
      end;
  else
    raise ESqliteFormat.CreateFmt('page %d is not a table page', [Page]);
  end;
end;

function TSqliteFile.DecodeRecord(const Rec: TBytes): TSqliteRow;
var
  HeaderEnd, Pos, Body: Int64;
  Types: array of Int64;
  T, Len, V: Int64;
  I, J, N: Integer;
  D: Double;
  Q: QWord;
  S: string;

  function RecVarInt(var P: Int64): Int64;
  var
    K: Integer;
    B: Byte;
  begin
    Result := 0;
    for K := 1 to 9 do
    begin
      if P >= Length(Rec) then
        raise ESqliteFormat.Create('record header runs past its end');
      B := Rec[P];
      Inc(P);
      if K = 9 then
        Exit((Result shl 8) or B);
      Result := (Result shl 7) or (B and $7F);
      if B < $80 then
        Exit;
    end;
  end;

begin
  Result.RowId := 0;
  Result.Values := nil;
  Result.IsNull := nil;
  Pos := 0;
  HeaderEnd := RecVarInt(Pos);
  Types := nil;
  while Pos < HeaderEnd do
  begin
    SetLength(Types, Length(Types) + 1);
    Types[High(Types)] := RecVarInt(Pos);
  end;
  N := Length(Types);
  SetLength(Result.Values, N);
  SetLength(Result.IsNull, N);
  Body := HeaderEnd;
  for I := 0 to N - 1 do
  begin
    T := Types[I];
    Result.IsNull[I] := False;
    Result.Values[I] := '';
    case T of
      0: Result.IsNull[I] := True;
      1..6:
        begin
          case T of
            5: Len := 6;
            6: Len := 8;
          else
            Len := T;
          end;
          if Body + Len > Length(Rec) then
            raise ESqliteFormat.Create('record runs past its end');
          V := 0;
          for J := 0 to Len - 1 do
            V := (V shl 8) or Rec[Body + J];
          { Sign-extend }
          if (Len < 8) and (Rec[Body] and $80 <> 0) then
            V := V - (Int64(1) shl (8 * Len));
          Result.Values[I] := IntToStr(V);
          Inc(Body, Len);
        end;
      7:
        begin
          if Body + 8 > Length(Rec) then
            raise ESqliteFormat.Create('record runs past its end');
          Q := 0;
          for J := 0 to 7 do
            Q := (Q shl 8) or Rec[Body + J];
          Move(Q, D, 8);
          Result.Values[I] := FloatToStr(D);
          Inc(Body, 8);
        end;
      8: Result.Values[I] := '0';
      9: Result.Values[I] := '1';
      10, 11: raise ESqliteFormat.Create('reserved serial type');
    else
      begin
        if T and 1 = 0 then
          Len := (T - 12) div 2
        else
          Len := (T - 13) div 2;
        if Body + Len > Length(Rec) then
          raise ESqliteFormat.Create('record runs past its end');
        SetString(S, PChar(@Rec[Body]), Len);
        Result.Values[I] := S;
        Inc(Body, Len);
      end;
    end;
  end;
end;

function TSqliteFile.TableInfo(const Table: string; out RootPage: Int64;
  out Sql: string): Boolean;
var
  Master: TSqliteRows;
  Row: TSqliteRow;
begin
  Master := nil;
  Walk(1, Master, 0);
  { sqlite_master: type, name, tbl_name, rootpage, sql }
  for Row in Master do
    if (RowValue(Row, 0) = 'table') and SameText(RowValue(Row, 1), Table) then
    begin
      RootPage := StrToInt64Def(RowValue(Row, 3), 0);
      Sql := RowValue(Row, 4);
      Exit(True);
    end;
  RootPage := 0;
  Sql := '';
  Result := False;
end;

function ParseColumns(const Sql: string): TStringArray; forward;

function TSqliteFile.ReadTable(const Table: string): TSqliteRows;
var
  Root, Alias: Int64;
  Sql: string;
  Cols: TStringArray;
  I, J: Integer;
begin
  if not TableInfo(Table, Root, Sql) then
    raise ESqliteFormat.CreateFmt('no table %s', [Table]);
  Result := nil;
  Walk(Root, Result, 0);
  { An INTEGER PRIMARY KEY column is stored as NULL and holds the rowid. }
  Cols := ParseColumns(Sql);
  Alias := -1;
  for I := 0 to High(Cols) do
    if Pos('|ROWID', Cols[I]) > 0 then
    begin
      Alias := I;
      Cols[I] := Copy(Cols[I], 1, Pos('|', Cols[I]) - 1);
    end;
  if Alias >= 0 then
    for J := 0 to High(Result) do
      if (Alias <= High(Result[J].Values)) and Result[J].IsNull[Alias] then
      begin
        Result[J].Values[Alias] := IntToStr(Result[J].RowId);
        Result[J].IsNull[Alias] := False;
      end;
end;

{ Column names from CREATE TABLE. Internally a rowid alias is returned as
  "name|ROWID"; Columns strips that for callers. }
function ParseColumns(const Sql: string): TStringArray;
var
  Body, Part, Word, Up: string;
  Depth, I, Start, P: Integer;
  Parts: TStringArray;
begin
  Result := nil;
  P := Pos('(', Sql);
  if P = 0 then
    Exit;
  Body := Copy(Sql, P + 1, MaxInt);
  P := LastDelimiter(')', Body);
  if P > 0 then
    Body := Copy(Body, 1, P - 1);
  { Split on commas outside parentheses and quotes. }
  Parts := nil;
  Depth := 0;
  Start := 1;
  I := 1;
  while I <= Length(Body) do
  begin
    case Body[I] of
      '(': Inc(Depth);
      ')': Dec(Depth);
      '''', '"', '`':
        begin
          P := I;
          Inc(I);
          while (I <= Length(Body)) and (Body[I] <> Body[P]) do
            Inc(I);
        end;
      '[':
        while (I <= Length(Body)) and (Body[I] <> ']') do
          Inc(I);
      ',':
        if Depth = 0 then
        begin
          Parts := Concat(Parts, [Copy(Body, Start, I - Start)]);
          Start := I + 1;
        end;
    end;
    Inc(I);
  end;
  Parts := Concat(Parts, [Copy(Body, Start, MaxInt)]);
  for Part in Parts do
  begin
    Word := Trim(Part);
    if Word = '' then
      Continue;
    if Word[1] in ['`', '"', '['] then
    begin
      if Word[1] = '[' then
        P := Pos(']', Copy(Word, 2, MaxInt))
      else
        P := Pos(Word[1], Copy(Word, 2, MaxInt));
      Up := UpperCase(Copy(Word, P + 2, MaxInt));
      Word := Copy(Word, 2, P - 1);
    end
    else
    begin
      P := 1;
      while (P <= Length(Word)) and not (Word[P] in [' ', #9, #10, #13, '(']) do
        Inc(P);
      Up := UpperCase(Copy(Word, P, MaxInt));
      Word := Copy(Word, 1, P - 1);
      case UpperCase(Word) of
        'CONSTRAINT', 'PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN':
          Continue;
      end;
    end;
    Up := StringReplace(Up, #9, ' ', [rfReplaceAll]);
    while Pos('  ', Up) > 0 do
      Up := StringReplace(Up, '  ', ' ', [rfReplaceAll]);
    { A rowid alias: declared type exactly INTEGER, and PRIMARY KEY. }
    Up := Trim(StringReplace(StringReplace(Up, #10, ' ', [rfReplaceAll]), #13, ' ',
      [rfReplaceAll]));
    if ((Up = 'INTEGER') or (Copy(Up, 1, 8) = 'INTEGER ')) and
       (Pos('PRIMARY KEY', Up) > 0) and (Pos('DESC', Up) = 0) then
      Word := Word + '|ROWID';
    Result := Concat(Result, [Word]);
  end;
end;

function TSqliteFile.Columns(const Table: string): TStringArray;
var
  I: Integer;
  Root: Int64;
  Sql: string;
begin
  if not TableInfo(Table, Root, Sql) then
    raise ESqliteFormat.CreateFmt('no table %s', [Table]);
  Result := ParseColumns(Sql);
  for I := 0 to High(Result) do
    if Pos('|', Result[I]) > 0 then
      Result[I] := Copy(Result[I], 1, Pos('|', Result[I]) - 1);
end;

end.
