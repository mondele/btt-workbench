unit WBLanguages;

{$mode objfpc}{$H+}

{ BTT-Writer's language list, from the target_language and
  temp_target_language tables of its index.sqlite. BTT-Writer Desktop
  copies that database into <data>/library/ on first start and updates it
  from the catalog. It copies a language's name and direction into a
  project's manifest only when the project is created and never refreshes
  them, so projects can lag later corrections. }

interface

uses
  Classes, SysUtils, Generics.Collections, WBSqlite;

type
  TLanguageInfo = record
    Code, Name, Direction: string;
    { temp_target_language only: a temporary code (qaa-x-...) and the code
      it has been approved as, if any. }
    IsTemp: Boolean;
    ApprovedAs: string;
  end;

  TLanguageIndex = class
  private
    FLanguages: specialize TDictionary<string, TLanguageInfo>;
    FFileName: string;
    FDb: TSqliteFile;
    procedure Load(const Table: string; IsTemp: Boolean);
  public
    { Raises ESqliteFormat or a file error if it cannot be read. }
    constructor Create(const FileName: string);
    destructor Destroy; override;
    { target_language first, then temp_target_language. Codes compare
      case-insensitively, as BTT-Writer's do. }
    function Find(const Code: string; out Info: TLanguageInfo): Boolean;
    function Count: Integer;
    property FileName: string read FFileName;
  end;

implementation

constructor TLanguageIndex.Create(const FileName: string);
begin
  inherited Create;
  FFileName := FileName;
  FLanguages := specialize TDictionary<string, TLanguageInfo>.Create;
  FDb := TSqliteFile.Create(FileName);
  try
    Load('target_language', False);
    try
      Load('temp_target_language', True);
    except
      on ESqliteFormat do ;   // older databases have no temporary languages
    end;
  finally
    FreeAndNil(FDb);
  end;
end;

destructor TLanguageIndex.Destroy;
begin
  FLanguages.Free;
  inherited Destroy;
end;

procedure TLanguageIndex.Load(const Table: string; IsTemp: Boolean);
var
  Cols: TStringArray;
  Rows: TSqliteRows;
  Row: TSqliteRow;
  Slug, Name, Dir, Approved: Integer;
  Info: TLanguageInfo;
  Key: string;
begin
  Cols := FDb.Columns(Table);
  Slug := ColumnIndex(Cols, 'slug');
  Name := ColumnIndex(Cols, 'name');
  Dir := ColumnIndex(Cols, 'direction');
  Approved := ColumnIndex(Cols, 'approved_target_language_slug');
  if (Slug < 0) or (Name < 0) then
    raise ESqliteFormat.CreateFmt('%s has no slug or name column', [Table]);
  Rows := FDb.ReadTable(Table);
  for Row in Rows do
  begin
    Info.Code := RowValue(Row, Slug);
    Info.Name := RowValue(Row, Name);
    Info.Direction := RowValue(Row, Dir);
    Info.IsTemp := IsTemp;
    Info.ApprovedAs := RowValue(Row, Approved);
    Key := LowerCase(Info.Code);
    if (Key <> '') and not FLanguages.ContainsKey(Key) then
      FLanguages.Add(Key, Info);
  end;
end;

function TLanguageIndex.Find(const Code: string; out Info: TLanguageInfo): Boolean;
begin
  Result := FLanguages.TryGetValue(LowerCase(Code), Info);
end;

function TLanguageIndex.Count: Integer;
begin
  Result := FLanguages.Count;
end;

end.
