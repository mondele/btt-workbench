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
    reported message) comes from a resourcestring, so it can be translated.
  - okPassword values are never shown, logged or passed to another process.
    The CLI asks for one (without echo) when the option named in
    PromptWith is given and the password is not.
  - okChecklist is a Multiple option whose values are picked from a list
    the module finds itself (Choices), using the other options as filters:
    the GUI shows it as a list with check boxes and a Find button, the CLI
    prints it with --list and takes --all, libbtw has btw_choices. The
    value AllChoices ('*') stands for every item; ChecklistValues expands
    it. }

interface

uses
  Classes, SysUtils, Generics.Collections, WBReporter;

type
  TWBOptionKind = (okString, okDirectory, okFile, okFlag, okChoice, okPassword,
    okChecklist);

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
    PromptWith: string;  // okPassword: CLI asks for it when this option is given
    Suggests: Boolean;   // okString: the module's Suggestions has values (a picker)
  end;
  TWBOptionDefs = array of TWBOptionDef;

  { One item of an okChecklist option: the value it adds when checked, and
    what to show for it, one entry per column. }
  TWBChoice = record
    Value: string;
    Columns: TStringArray;
  end;
  TWBChoiceList = record
    Headers: TStringArray;  // translated column titles
    Items: array of TWBChoice;
  end;

  { A value an option is likely to take, for a picker: Value is what goes
    in the field, Caption what the list shows ('udm  удмурт кыл'). }
  TWBSuggestion = record
    Value, Caption: string;
  end;
  TWBSuggestions = array of TWBSuggestion;

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
    { The items an okChecklist option can take, found with the other
      Options as filters. False (with the reason reported) if they cannot
      be found. Modules with a checklist override this. }
    function Choices(const OptionName: string; Options: TStrings;
      Reporter: TWBReporter; out List: TWBChoiceList): Boolean; virtual;
    { Values a string option is likely to take (language codes in the
      projects folder, say), with the other Options as context; quick and
      local, as the GUI asks when a field is entered. A module may add what
      its last Choices found. None by default: a plain field. }
    function Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions; virtual;
  end;

const
  AllChoices = '*';


function OptionDef(const AName: string; AKind: TWBOptionKind;
  ARequired, APositional: Boolean; const ACaption, AHelp: string): TWBOptionDef;
function ChoiceOptionDef(const AName: string; const AChoices: array of string;
  const ADefault, ACaption, AHelp: string): TWBOptionDef;
{ OptionDef with Multiple set: a list of values. }
function ListOptionDef(const AName: string; AKind: TWBOptionKind;
  ARequired, APositional: Boolean; const ACaption, AHelp: string): TWBOptionDef;
{ A checklist: a Multiple option picked from Module.Choices. }
function ChecklistOptionDef(const AName: string; ARequired: Boolean;
  const ACaption, AHelp: string): TWBOptionDef;
function PasswordOptionDef(const AName, APromptWith, ACaption, AHelp: string): TWBOptionDef;
{ A string option the module suggests values for (Suggestions). }
function SuggestingOptionDef(const AName, ACaption, AHelp: string): TWBOptionDef;
{ The checked values of a checklist option, AllChoices expanded through
  Module.Choices. False if that fails. }
function ChecklistValues(Module: TWBModule; const AName: string; Options: TStrings;
  Reporter: TWBReporter; out Values: TStringArray): Boolean;
{ The module's first checklist option, or '' if it has none. }
function ChecklistOption(Module: TWBModule): string;
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
  rsNoChoices = 'This module has no list to choose from for %s.';

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
  Result.PromptWith := '';
end;

function ChecklistOptionDef(const AName: string; ARequired: Boolean;
  const ACaption, AHelp: string): TWBOptionDef;
begin
  Result := OptionDef(AName, okChecklist, ARequired, False, ACaption, AHelp);
  Result.Multiple := True;
end;

function PasswordOptionDef(const AName, APromptWith, ACaption, AHelp: string): TWBOptionDef;
begin
  Result := OptionDef(AName, okPassword, False, False, ACaption, AHelp);
  Result.PromptWith := APromptWith;
end;

function ChecklistOption(Module: TWBModule): string;
var
  Def: TWBOptionDef;
begin
  for Def in Module.OptionDefs do
    if Def.Kind = okChecklist then
      Exit(Def.Name);
  Result := '';
end;

function ChecklistValues(Module: TWBModule; const AName: string; Options: TStrings;
  Reporter: TWBReporter; out Values: TStringArray): Boolean;
var
  V: string;
  List: TWBChoiceList;
  Item: TWBChoice;
  All: Boolean;
begin
  Values := nil;
  All := False;
  for V in OptionValues(Options, AName) do
    if V = AllChoices then
      All := True
    else
      Values := Concat(Values, [V]);
  if not All then
    Exit(True);
  if not Module.Choices(AName, Options, Reporter, List) then
    Exit(False);
  Values := nil;
  for Item in List.Items do
    Values := Concat(Values, [Item.Value]);
  Result := True;
end;

function TWBModule.Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions;
begin
  Result := nil;
end;

function TWBModule.Choices(const OptionName: string; Options: TStrings;
  Reporter: TWBReporter; out List: TWBChoiceList): Boolean;
begin
  List.Headers := nil;
  List.Items := nil;
  Reporter.Error(Format(rsNoChoices, [OptionName]));
  Result := False;
end;

function SuggestingOptionDef(const AName, ACaption, AHelp: string): TWBOptionDef;
begin
  Result := OptionDef(AName, okString, False, False, ACaption, AHelp);
  Result.Suggests := True;
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
    okPassword:  Result := 'password';
    okChecklist: Result := 'checklist';
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
