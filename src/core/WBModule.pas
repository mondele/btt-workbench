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
    verbs, --option names and JSON keys. So are okChoice Choices.
  - A module that can check without changing anything declares a flag
    named 'dry-run'. The GUI shows it as a Check button, and runs the check
    automatically when opened from the command line (e.g. a double-clicked
    file).
  - Everything a person reads (Title, Description, Caption, Help, every
    reported message) comes from a resourcestring, so it can be translated. }

interface

uses
  Classes, SysUtils, Generics.Collections, WBReporter;

type
  TWBOptionKind = (okString, okDirectory, okFile, okFlag, okChoice);

  TWBOptionDef = record
    Name: string;        // stable: --name on the CLI, key in JSON
    Kind: TWBOptionKind;
    Required: Boolean;
    Positional: Boolean; // CLI may take it without --name, in declared order
    Caption: string;     // translated label
    Help: string;        // translated one-line help
    Choices: TStringArray; // okChoice: allowed values (stable, untranslated)
    Default: string;     // used when the option is not given ('' = none)
    Multiple: Boolean;   // takes a list of values (see OptionValues)
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
function ChoiceOptionDef(const AName: string; const AChoices: array of string;
  const ADefault, ACaption, AHelp: string): TWBOptionDef;
{ OptionDef with Multiple set: a list of values. }
function ListOptionDef(const AName: string; AKind: TWBOptionKind;
  ARequired, APositional: Boolean; const ACaption, AHelp: string): TWBOptionDef;
function OptionIsSet(Options: TStrings; const AName: string): Boolean;
{ The non-empty values of a Multiple option, in order. }
function OptionValues(Options: TStrings; const AName: string): TStringArray;
{ Appends one value to a Multiple option. }
procedure AddOptionValue(Options: TStrings; const AName, AValue: string);
{ The given value, or the option's Default when not given. }
function OptionValue(Module: TWBModule; Options: TStrings; const AName: string): string;
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
  rsBadChoice = 'Option --%s must be one of: %s';

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
  Result.Choices := nil;
  Result.Default := '';
  Result.Multiple := False;
end;

function ListOptionDef(const AName: string; AKind: TWBOptionKind;
  ARequired, APositional: Boolean; const ACaption, AHelp: string): TWBOptionDef;
begin
  Result := OptionDef(AName, AKind, ARequired, APositional, ACaption, AHelp);
  Result.Multiple := True;
end;

function OptionValues(Options: TStrings; const AName: string): TStringArray;
var
  V: string;
begin
  Result := nil;
  for V in Options.Values[AName].Split([#10]) do
    if Trim(V) <> '' then
      Result := Concat(Result, [Trim(V)]);
end;

procedure AddOptionValue(Options: TStrings; const AName, AValue: string);
var
  Old: string;
begin
  Old := Options.Values[AName];
  if Old = '' then
    Options.Values[AName] := AValue
  else
    Options.Values[AName] := Old + #10 + AValue;
end;

function ChoiceOptionDef(const AName: string; const AChoices: array of string;
  const ADefault, ACaption, AHelp: string): TWBOptionDef;
var
  I: Integer;
begin
  Result := OptionDef(AName, okChoice, False, False, ACaption, AHelp);
  SetLength(Result.Choices, Length(AChoices));
  for I := 0 to High(AChoices) do
    Result.Choices[I] := AChoices[I];
  Result.Default := ADefault;
end;

function OptionValue(Module: TWBModule; Options: TStrings; const AName: string): string;
var
  Def: TWBOptionDef;
begin
  Result := Options.Values[AName];
  if Result <> '' then
    Exit;
  for Def in Module.OptionDefs do
    if Def.Name = AName then
      Exit(Def.Default);
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
    okChoice:    Result := 'choice';
  end;
end;

function TWBModule.ValidateOptions(Options: TStrings; Reporter: TWBReporter): Boolean;
var
  Def: TWBOptionDef;
  Value, C: string;
  Found: Boolean;
begin
  Result := True;
  for Def in OptionDefs do
  begin
    Value := Options.Values[Def.Name];
    if Def.Required and (Def.Kind <> okFlag) and (Value = '') then
    begin
      Reporter.Error(Format(rsMissingOption, [Def.Name, Def.Caption]));
      Result := False;
    end;
    if (Def.Kind = okChoice) and (Value <> '') then
    begin
      Found := False;
      for C in Def.Choices do
        if C = Value then
          Found := True;
      if not Found then
      begin
        Reporter.Error(Format(rsBadChoice, [Def.Name, String.Join(', ', Def.Choices)]));
        Result := False;
      end;
    end;
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
