unit WBJson;

{$mode objfpc}{$H+}

{ JSON read/write in the layout BTT-Writer uses for manifest.json (the
  same as JavaScript's JSON.stringify(value, null, '\t')): tab indent,
  "key": value, empty objects and arrays on one line, non-ASCII left as
  UTF-8.
  fpjson's FormatJSON writes "key" : value and splits empty arrays, which
  would show up as noise in the project's git history. }

interface

uses
  Classes, SysUtils, fpjson;

function FormatBttJSON(Data: TJSONData): string;
{ Caller frees. Raises if the file is not a JSON object. }
function ReadJSONObjectFile(const Path: string): TJSONObject;
{ Writes via a .tmp file then replaces Path. }
procedure WriteBttJSONFile(const Path: string; Data: TJSONData);

implementation

uses
  jsonparser;

function QuoteJSON(const S: string): string;
var
  C: Char;
begin
  Result := '"';
  for C in S do
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
      #0..#7, #11, #14..#31:
            Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4));
    else
      Result := Result + C;
    end;
  Result := Result + '"';
end;

procedure WriteValue(Data: TJSONData; const Indent: string; Lines: TStrings; var Line: string);
var
  I: Integer;
  Inner: string;
begin
  case Data.JSONType of
    jtObject:
      if Data.Count = 0 then
        Line := Line + '{}'
      else
      begin
        Lines.Add(Line + '{');
        Inner := Indent + #9;
        for I := 0 to Data.Count - 1 do
        begin
          Line := Inner + QuoteJSON(TJSONObject(Data).Names[I]) + ': ';
          WriteValue(Data.Items[I], Inner, Lines, Line);
          if I < Data.Count - 1 then
            Line := Line + ',';
          Lines.Add(Line);
        end;
        Line := Indent + '}';
      end;
    jtArray:
      if Data.Count = 0 then
        Line := Line + '[]'
      else
      begin
        Lines.Add(Line + '[');
        Inner := Indent + #9;
        for I := 0 to Data.Count - 1 do
        begin
          Line := Inner;
          WriteValue(Data.Items[I], Inner, Lines, Line);
          if I < Data.Count - 1 then
            Line := Line + ',';
          Lines.Add(Line);
        end;
        Line := Indent + ']';
      end;
    jtString:
      Line := Line + QuoteJSON(Data.AsString);
  else
    Line := Line + Data.AsJSON;   // numbers, booleans, null
  end;
end;

function FormatBttJSON(Data: TJSONData): string;
var
  Lines: TStringList;
  Line: string;
begin
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.TrailingLineBreak := False;
    Line := '';
    WriteValue(Data, '', Lines, Line);
    Lines.Add(Line);
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function ReadJSONObjectFile(const Path: string): TJSONObject;
var
  Stream: TFileStream;
  Data: TJSONData;
begin
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    Data := GetJSON(Stream, True);
  finally
    Stream.Free;
  end;
  if not (Data is TJSONObject) then
  begin
    Data.Free;
    raise EJSON.Create('top level is not an object');
  end;
  Result := TJSONObject(Data);
end;

procedure WriteBttJSONFile(const Path: string; Data: TJSONData);
var
  Text, TmpPath: string;
  Stream: TFileStream;
begin
  Text := FormatBttJSON(Data);
  TmpPath := Path + '.tmp';
  Stream := TFileStream.Create(TmpPath, fmCreate);
  try
    if Text <> '' then
      Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
  if FileExists(Path) and not DeleteFile(Path) then
    raise EInOutError.CreateFmt('cannot replace %s', [Path]);
  if not RenameFile(TmpPath, Path) then
    raise EInOutError.CreateFmt('cannot rename %s', [TmpPath]);
end;

end.
