library btw;

{$mode objfpc}{$H+}

(* libbtw: the workbench core behind a flat C ABI, for the Kotlin Android UI
  (and anything else that can call C). Strings in and out are UTF-8,
  NUL-terminated. Structured data is JSON. Every returned string must be
  released with btw_free_string.

    int   btw_api_version(void);
    char* btw_version(void);
    char* btw_set_language(const char* lang, const char* locale_dir);
          -> {"language": "fr", "loaded": "/path/btt-workbench.po", "rtl": false}
    char* btw_list_modules(void);
          -> [{"id", "title", "description",
               "options": [{"name", "kind", "required", "positional",
                            "caption", "help", "default", "choices",
                            "multiple"}]}]
    char* btw_run_module(const char* id, const char* options_json);
          options_json: {"project": "/path", "dry-run": true}
          (a "multiple" option takes an array: {"file": ["/a", "/b"]})
          -> {"exit_code": 0, "messages": [{"level": "info", "text": "..."}]}
    void  btw_free_string(char* s);

  Calls are not reentrant: the Kotlin side should run modules on one
  background thread. No exception crosses the boundary; failures come back
  as exit_code 2 with an error message. *)

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, fpjson, jsonparser,
  WBReporter, WBModule, WBI18n, WBVersion, WBAllModules;

function ToCString(const S: string): PChar;
begin
  Result := StrAlloc(Length(S) + 1);
  StrPCopy(Result, S);
end;

function btw_api_version: LongInt; cdecl;
begin
  Result := WorkbenchApiVersion;
end;

function btw_version: PChar; cdecl;
begin
  Result := ToCString(WorkbenchVersion);
end;

procedure btw_free_string(S: PChar); cdecl;
begin
  if S <> nil then
    StrDispose(S);
end;

function btw_set_language(Lang, LocaleDir: PChar): PChar; cdecl;
var
  Obj: TJSONObject;
  Loaded: string;
begin
  Obj := TJSONObject.Create;
  try
    try
      Loaded := LoadLanguage(StrPas(Lang), StrPas(LocaleDir));
      Obj.Add('language', CurrentLanguage);
      Obj.Add('loaded', Loaded);
      Obj.Add('rtl', IsRightToLeftLanguage(CurrentLanguage));
    except
      on E: Exception do
        Obj.Add('error', E.Message);
    end;
    Result := ToCString(Obj.AsJSON);
  finally
    Obj.Free;
  end;
end;

function btw_list_modules: PChar; cdecl;
var
  Arr, Opts, Choices: TJSONArray;
  Choice: string;
  ModObj, OptObj: TJSONObject;
  M: TWBModule;
  Def: TWBOptionDef;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  try
    for I := 0 to ModuleCount - 1 do
    begin
      M := ModuleAt(I);
      ModObj := TJSONObject.Create;
      ModObj.Add('id', M.Id);
      ModObj.Add('title', M.Title);
      ModObj.Add('description', M.Description);
      Opts := TJSONArray.Create;
      for Def in M.OptionDefs do
      begin
        OptObj := TJSONObject.Create;
        OptObj.Add('name', Def.Name);
        OptObj.Add('kind', OptionKindName(Def.Kind));
        OptObj.Add('required', Def.Required);
        OptObj.Add('positional', Def.Positional);
        OptObj.Add('caption', Def.Caption);
        OptObj.Add('help', Def.Help);
        OptObj.Add('default', Def.Default);
        OptObj.Add('multiple', Def.Multiple);
        Choices := TJSONArray.Create;
        for Choice in Def.Choices do
          Choices.Add(Choice);
        OptObj.Add('choices', Choices);
        Opts.Add(OptObj);
      end;
      ModObj.Add('options', Opts);
      Arr.Add(ModObj);
    end;
    Result := ToCString(Arr.AsJSON);
  finally
    Arr.Free;
  end;
end;

function btw_run_module(Id, OptionsJson: PChar): PChar; cdecl;
var
  ResultObj, MsgObj: TJSONObject;
  Messages: TJSONArray;
  Reporter: TWBListReporter;
  Options: TStringList;
  Parsed: TJSONData;
  M: TWBModule;
  Code, I, J: Integer;
  Value: TJSONData;
begin
  Reporter := TWBListReporter.Create;
  Options := TStringList.Create;
  Parsed := nil;
  Code := 2;
  try
    try
      M := FindModule(StrPas(Id));
      if M = nil then
        Reporter.Error('Unknown module: ' + StrPas(Id))
      else
      begin
        if (OptionsJson <> nil) and (OptionsJson^ <> #0) then
          Parsed := GetJSON(StrPas(OptionsJson), True);
        if (Parsed <> nil) and not (Parsed is TJSONObject) then
          Reporter.Error('options_json must be a JSON object')
        else
        begin
          if Parsed <> nil then
            for I := 0 to Parsed.Count - 1 do
            begin
              Value := Parsed.Items[I];
              if Value.JSONType = jtArray then
              begin
                for J := 0 to Value.Count - 1 do
                  AddOptionValue(Options, TJSONObject(Parsed).Names[I], Value.Items[J].AsString);
              end
              else if Value.JSONType = jtBoolean then
                Options.Values[TJSONObject(Parsed).Names[I]] := BoolToStr(Value.AsBoolean, 'true', '')
              else
                Options.Values[TJSONObject(Parsed).Names[I]] := Value.AsString;
            end;
          if M.ValidateOptions(Options, Reporter) then
            Code := M.Execute(Options, Reporter);
        end;
      end;
    except
      on E: Exception do
      begin
        Reporter.Error(E.ClassName + ': ' + E.Message);
        Code := 2;
      end;
    end;

    ResultObj := TJSONObject.Create;
    try
      ResultObj.Add('exit_code', Code);
      Messages := TJSONArray.Create;
      for I := 0 to Reporter.Count - 1 do
      begin
        MsgObj := TJSONObject.Create;
        MsgObj.Add('level', LevelName(Reporter.Levels[I]));
        MsgObj.Add('text', Reporter.Texts[I]);
        Messages.Add(MsgObj);
      end;
      ResultObj.Add('messages', Messages);
      Result := ToCString(ResultObj.AsJSON);
    finally
      ResultObj.Free;
    end;
  finally
    Parsed.Free;
    Options.Free;
    Reporter.Free;
  end;
end;

exports
  btw_api_version,
  btw_version,
  btw_free_string,
  btw_set_language,
  btw_list_modules,
  btw_run_module;

end.
