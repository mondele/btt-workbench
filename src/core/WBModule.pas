unit WBModule;

{$mode objfpc}{$H+}

{ The module contract shared by the CLI, the LCL desktop GUI and the
  Android library.

  A module never touches the console or a widget. It declares its options
  (TWBOptionDef), reads their values from a name=value list, and reports
  through a TWBReporter. That is what lets the same module run from the
  terminal, from the GUI, and through the C ABI in libbtw.

  Rules:
  - Units under src/core and src/modules must not use LCL.
  - Id and option Name values are stable and untranslated: they are CLI
    verbs, --option names and JSON keys.
  - Everything a person reads (Title, Description, Caption, Help, every
    reported message) comes from a resourcestring, so it can be translated. }

interface

uses
  Classes, SysUtils, Generics.Collections, WBReporter;

type
  TWBOptionKind = (okString, okDirectory, okFile, okFlag);

  TWBOptionDef = record
    Name: string;        // stable: --name on the CLI, key in JSON
    Kind: TWBOptionKind;
    Required: Boolean;
    Positional: Boolean; // CLI may take it without --name, in declared order
    Caption: string;     // translated label
    Help: string;        // translated one-line help
  end;
  TWBOptionDefs = array of TWBOptionDef;

  TWBModule = class
  public
    function Id: string; virtual; abstract;
    function Title: string; virtual; abstract;
    function Description: string; virtual; abstract;
    function OptionDefs: TWBOptionDefs; virtual; abstract;
    { Options holds name=value pairs; flags are 'true' when set.
      Returns 0 on success, non-zero on failure (the CLI exit code). }
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; virtual; abstract;
    { Reports every missing required option. True if none are missing. }
    function ValidateOptions(Options: TStrings; Reporter: TWBReporter): Boolean;
  end;

function OptionDef(const AName: string; AKind: TWBOptionKind;
  ARequired, APositional: Boolean; const ACaption, AHelp: string): TWBOptionDef;
function OptionIsSet(Options: TStrings; const AName: string): Boolean;
function OptionKindName(Kind: TWBOptionKind): string;

{ Registry. Module units register themselves in their initialization
  section; src/modules/WBAllModules.pas pulls them all in. The registry
  owns the instances. }
procedure RegisterModule(AModule: TWBModule);
function ModuleCount: Integer;
function ModuleAt(Index: Integer): TWBModule;
function FindModule(const AId: string): TWBModule;

implementation

resourcestring
  rsMissingOption = 'Missing required option: %s (%s)';

var
  Registry: specialize TObjectList<TWBModule>;

function OptionDef(const AName: string; AKind: TWBOptionKind;
  ARequired, APositional: Boolean; const ACaption, AHelp: string): TWBOptionDef;
begin
  Result.Name := AName;
  Result.Kind := AKind;
  Result.Required := ARequired;
  Result.Positional := APositional;
  Result.Caption := ACaption;
  Result.Help := AHelp;
end;

function OptionIsSet(Options: TStrings; const AName: string): Boolean;
var
  V: string;
begin
  V := LowerCase(Options.Values[AName]);
  Result := (V = 'true') or (V = '1') or (V = 'yes');
end;

function OptionKindName(Kind: TWBOptionKind): string;
begin
  case Kind of
    okString:    Result := 'string';
    okDirectory: Result := 'directory';
    okFile:      Result := 'file';
    okFlag:      Result := 'flag';
  end;
end;

function TWBModule.ValidateOptions(Options: TStrings; Reporter: TWBReporter): Boolean;
var
  Def: TWBOptionDef;
begin
  Result := True;
  for Def in OptionDefs do
    if Def.Required and (Def.Kind <> okFlag) and (Options.Values[Def.Name] = '') then
    begin
      Reporter.Error(Format(rsMissingOption, [Def.Name, Def.Caption]));
      Result := False;
    end;
end;

procedure RegisterModule(AModule: TWBModule);
begin
  if FindModule(AModule.Id) <> nil then
    raise Exception.CreateFmt('Duplicate module id: %s', [AModule.Id]);
  Registry.Add(AModule);
end;

function ModuleCount: Integer;
begin
  Result := Registry.Count;
end;

function ModuleAt(Index: Integer): TWBModule;
begin
  Result := Registry[Index];
end;

function FindModule(const AId: string): TWBModule;
var
  M: TWBModule;
begin
  for M in Registry do
    if M.Id = AId then
      Exit(M);
  Result := nil;
end;

initialization
  Registry := specialize TObjectList<TWBModule>.Create(True);

finalization
  FreeAndNil(Registry);

end.
