unit WBProject;

{$mode objfpc}{$H+}

{ Helpers for BTT-Writer target translations (projects): manifest fields,
  folder naming and chunk ids, shared by the modules that read or change
  projects. Behaviour follows BTT-Writer Desktop 1.6.0. }

interface

uses
  Classes, SysUtils, fpjson;

type
  TProjectChunk = record
    Chapter, Chunk, Path: string;
  end;
  TProjectChunks = array of TProjectChunk;

{ String (or number) at a dotted path in a manifest; '' if absent. }
function StrField(Obj: TJSONObject; const Path: string): string;
{ The string items of a JSON array (nil for anything else). }
function StringsOf(Arr: TJSONData): TStringArray;
function Contains(const Items: TStringArray; const S: string): Boolean;
{ Desktop's unique_id: <lang>_<book>_<type>[_<resource>] (migrator.js).
  Fallback when the manifest lacks a language, book or type. }
function ProjectFolderName(Manifest: TJSONObject; const Fallback: string): string;
{ 03/01.txt -> 03-01, front/title.txt -> front-title (gitnative.js).
  '' for anything that is not a .txt chunk file. }
function ChunkIdFromPath(const Path: string): string;
{ True if the file holds a line starting a git conflict marker. }
function HasConflictMarkers(const FileName: string): Boolean;
{ <chapter>/<chunk>.txt files of a project folder (with trailing
  separator), in name order. }
function ProjectChunks(const Dir: string): TProjectChunks;
{ Filters as typed: comma, space or semicolon separated, lower case. }
function SplitList(const S: string): TStringArray;
{ True if Filter is empty or holds one of Values (case-insensitive). }
function Matches(const Filter: TStringArray; const Values: array of string): Boolean;
{ Whether a project folder or WACS repo name, <lang>_<book>_<type>
  [_<resource>], passes the language, book and type filters (a type filter
  matches the type, the resource or type_resource). A name not of that form
  passes when AnyName is set. }
function FolderMatches(const Name: string; const Langs, Books, Types: TStringArray;
  AnyName: Boolean): Boolean;

implementation

function StrField(Obj: TJSONObject; const Path: string): string;
var
  D: TJSONData;
begin
  Result := '';
  D := Obj.FindPath(Path);
  if (D <> nil) and (D.JSONType in [jtString, jtNumber]) then
    Result := D.AsString;
end;

function StringsOf(Arr: TJSONData): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  if (Arr = nil) or (Arr.JSONType <> jtArray) then
    Exit;
  for I := 0 to Arr.Count - 1 do
    if Arr.Items[I].JSONType = jtString then
      Result := Concat(Result, [Arr.Items[I].AsString]);
end;

function Contains(const Items: TStringArray; const S: string): Boolean;
var
  X: string;
begin
  for X in Items do
    if X = S then
      Exit(True);
  Result := False;
end;

function ProjectFolderName(Manifest: TJSONObject; const Fallback: string): string;
var
  Lang, Book, Kind, Res: string;
begin
  Lang := StrField(Manifest, 'target_language.id');
  Book := StrField(Manifest, 'project.id');
  Kind := StrField(Manifest, 'type.id');
  Res := StrField(Manifest, 'resource.id');
  if (Lang = '') or (Book = '') or (Kind = '') then
    Exit(Fallback);
  Result := Lang + '_' + Book + '_' + Kind;
  if Res <> '' then
    Result := Result + '_' + Res;
end;

function ChunkIdFromPath(const Path: string): string;
begin
  Result := '';
  if LowerCase(ExtractFileExt(Path)) <> '.txt' then
    Exit;
  Result := StringReplace(ChangeFileExt(Path, ''), '/', '-', [rfReplaceAll]);
end;

function HasConflictMarkers(const FileName: string): Boolean;
var
  L: TStringList;
  Line: string;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    for Line in L do
      if Copy(Line, 1, 8) = '<<<<<<< ' then
        Exit(True);
  finally
    L.Free;
  end;
end;

function SplitList(const S: string): TStringArray;
var
  Part: string;
begin
  Result := nil;
  for Part in LowerCase(S).Split([',', ' ', ';']) do
    if Trim(Part) <> '' then
      Result := Concat(Result, [Trim(Part)]);
end;

function Matches(const Filter: TStringArray; const Values: array of string): Boolean;
var
  V: string;
begin
  if Length(Filter) = 0 then
    Exit(True);
  for V in Values do
    if (V <> '') and Contains(Filter, LowerCase(V)) then
      Exit(True);
  Result := False;
end;

function FolderMatches(const Name: string; const Langs, Books, Types: TStringArray;
  AnyName: Boolean): Boolean;
var
  Parts: TStringArray;
  Res: string;
begin
  Parts := Name.Split(['_']);
  if Length(Parts) < 3 then
    Exit(AnyName);
  Res := '';
  if Length(Parts) > 3 then
    Res := Parts[3];
  Result := Matches(Langs, [Parts[0]]) and Matches(Books, [Parts[1]]) and
    Matches(Types, [Parts[2], Res, Parts[2] + '_' + Res]);
end;

{ <chapter>/<chunk>.txt files, in name order. }
function ProjectChunks(const Dir: string): TProjectChunks;
var
  Ch, F: TSearchRec;
  Names: TStringList;
  I: Integer;
  Parts: TStringArray;
begin
  Result := nil;
  Names := TStringList.Create;
  try
    if FindFirst(Dir + AllFilesMask, faDirectory, Ch) = 0 then
    try
      repeat
        if (Ch.Name = '.') or (Ch.Name = '..') or (Ch.Name[1] = '.') or
           ((Ch.Attr and faDirectory) = 0) then
          Continue;
        if FindFirst(Dir + Ch.Name + PathDelim + '*.txt', faAnyFile, F) = 0 then
        try
          repeat
            Names.Add(Ch.Name + #9 + ChangeFileExt(F.Name, ''));
          until FindNext(F) <> 0;
        finally
          FindClose(F);
        end;
      until FindNext(Ch) <> 0;
    finally
      FindClose(Ch);
    end;
    Names.Sort;
    SetLength(Result, Names.Count);
    for I := 0 to Names.Count - 1 do
    begin
      Parts := Names[I].Split([#9]);
      Result[I].Chapter := Parts[0];
      Result[I].Chunk := Parts[1];
      Result[I].Path := Dir + Parts[0] + PathDelim + Parts[1] + '.txt';
    end;
  finally
    Names.Free;
  end;
end;

end.
