unit WBCommandLine;

{$mode objfpc}{$H+}

{ Turns a module's command-line arguments into the name=value list that
  TWBModule.Execute takes. Accepted forms:
    --name value   --name=value   --flag   positional
  Positional arguments fill the module's Positional options in order. A
  Multiple option may be given repeatedly; if it is positional, it takes
  every remaining positional argument. For a module with a checklist
  option, --all checks every item (unless the module has its own 'all'). }

interface

uses
  Classes, SysUtils, WBModule;

{ Args are the arguments after the module id. Returns False and sets
  ErrorMsg (translated) on an unknown option, a missing value or a
  surplus positional argument. }
function ParseModuleArgs(Module: TWBModule; Args: TStrings; Options: TStrings;
  out ErrorMsg: string): Boolean;

implementation

resourcestring
  rsUnknownOption = 'Unknown option: %s';
  rsMissingValue = 'Option --%s needs a value';
  rsFlagNoValue = 'Option --%s does not take a value';
  rsExtraArgument = 'Unexpected argument: %s';

function FindDef(const Defs: TWBOptionDefs; const AName: string; out Def: TWBOptionDef): Boolean;
var
  D: TWBOptionDef;
begin
  for D in Defs do
    if D.Name = AName then
    begin
      Def := D;
      Exit(True);
    end;
  Result := False;
end;

function ParseModuleArgs(Module: TWBModule; Args: TStrings; Options: TStrings;
  out ErrorMsg: string): Boolean;
var
  Defs: TWBOptionDefs;
  Def: TWBOptionDef;
  I, P, NextPositional: Integer;
  Arg, OptName, OptValue: string;
  HasInlineValue: Boolean;
begin
  Result := False;
  ErrorMsg := '';
  Defs := Module.OptionDefs;
  NextPositional := 0;
  I := 0;
  while I < Args.Count do
  begin
    Arg := Args[I];
    if (Arg = '--all') and not FindDef(Defs, 'all', Def) and (ChecklistOption(Module) <> '') then
      AddOptionValue(Options, ChecklistOption(Module), AllChoices)
    else if (Length(Arg) > 2) and (Copy(Arg, 1, 2) = '--') then
    begin
      OptName := Copy(Arg, 3, MaxInt);
      P := Pos('=', OptName);
      HasInlineValue := P > 0;
      if HasInlineValue then
      begin
        OptValue := Copy(OptName, P + 1, MaxInt);
        SetLength(OptName, P - 1);
      end;
      if not FindDef(Defs, OptName, Def) then
      begin
        ErrorMsg := Format(rsUnknownOption, ['--' + OptName]);
        Exit;
      end;
      if Def.Kind = okFlag then
      begin
        if HasInlineValue then
        begin
          ErrorMsg := Format(rsFlagNoValue, [OptName]);
          Exit;
        end;
        Options.Values[OptName] := 'true';
      end
      else
      begin
        if not HasInlineValue then
        begin
          Inc(I);
          if I >= Args.Count then
          begin
            ErrorMsg := Format(rsMissingValue, [OptName]);
            Exit;
          end;
          OptValue := Args[I];
        end;
        if Def.Multiple then
          AddOptionValue(Options, OptName, OptValue)
        else
          Options.Values[OptName] := OptValue;
      end;
    end
    else
    begin
      { Next positional option that has not been given by name. A Multiple
        one stays current and collects the rest. }
      while (NextPositional <= High(Defs)) and
            (not Defs[NextPositional].Positional or
             (not Defs[NextPositional].Multiple and
              (Options.IndexOfName(Defs[NextPositional].Name) >= 0))) do
        Inc(NextPositional);
      if NextPositional > High(Defs) then
      begin
        ErrorMsg := Format(rsExtraArgument, [Arg]);
        Exit;
      end;
      if Defs[NextPositional].Multiple then
        AddOptionValue(Options, Defs[NextPositional].Name, Arg)
      else
      begin
        Options.Values[Defs[NextPositional].Name] := Arg;
        Inc(NextPositional);
      end;
    end;
    Inc(I);
  end;
  Result := True;
end;

end.
