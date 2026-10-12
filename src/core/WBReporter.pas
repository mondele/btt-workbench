unit WBReporter;

{$mode objfpc}{$H+}

{ How a module talks back to whoever is running it. The CLI prints to
  stdout/stderr, the GUI appends to a log memo, the shared library collects
  messages into JSON. Modules only ever see TWBReporter. }

interface

uses
  Classes, SysUtils;

type
  TWBMessageLevel = (mlInfo, mlWarning, mlError);

  TWBReporter = class
  public
    procedure Message(Level: TWBMessageLevel; const Text: string); virtual; abstract;
    { Optional progress for long-running modules. Default: ignored. }
    procedure Progress(Current, Total: Integer); virtual;
    procedure Info(const Text: string);
    procedure Warn(const Text: string);
    procedure Error(const Text: string);
  end;

  { Keeps every message in order. Used by tests and the shared library. }
  TWBListReporter = class(TWBReporter)
  private
    FTexts: TStringList;
    FLevels: array of TWBMessageLevel;
    function GetCount: Integer;
    function GetLevel(Index: Integer): TWBMessageLevel;
    function GetText(Index: Integer): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Message(Level: TWBMessageLevel; const Text: string); override;
    function HasErrors: Boolean;
    property Count: Integer read GetCount;
    property Levels[Index: Integer]: TWBMessageLevel read GetLevel;
    property Texts[Index: Integer]: string read GetText;
  end;

function LevelName(Level: TWBMessageLevel): string;

implementation

function LevelName(Level: TWBMessageLevel): string;
begin
  case Level of
    mlInfo:    Result := 'info';
    mlWarning: Result := 'warning';
    mlError:   Result := 'error';
  end;
end;

{ TWBReporter }

procedure TWBReporter.Progress(Current, Total: Integer);
begin
end;

procedure TWBReporter.Info(const Text: string);
begin
  Message(mlInfo, Text);
end;

procedure TWBReporter.Warn(const Text: string);
begin
  Message(mlWarning, Text);
end;

procedure TWBReporter.Error(const Text: string);
begin
  Message(mlError, Text);
end;

{ TWBListReporter }

constructor TWBListReporter.Create;
begin
  inherited Create;
  FTexts := TStringList.Create;
end;

destructor TWBListReporter.Destroy;
begin
  FreeAndNil(FTexts);
  inherited Destroy;
end;

procedure TWBListReporter.Message(Level: TWBMessageLevel; const Text: string);
begin
  FTexts.Add(Text);
  SetLength(FLevels, Length(FLevels) + 1);
  FLevels[High(FLevels)] := Level;
end;

function TWBListReporter.HasErrors: Boolean;
var
  L: TWBMessageLevel;
begin
  Result := False;
  for L in FLevels do
    if L = mlError then
      Exit(True);
end;

function TWBListReporter.GetCount: Integer;
begin
  Result := FTexts.Count;
end;

function TWBListReporter.GetLevel(Index: Integer): TWBMessageLevel;
begin
  Result := FLevels[Index];
end;

function TWBListReporter.GetText(Index: Integer): string;
begin
  Result := FTexts[Index];
end;

end.
