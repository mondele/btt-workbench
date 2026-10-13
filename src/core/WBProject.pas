unit WBProject;

{$mode objfpc}{$H+}

{ Helpers for BTT-Writer target translations (projects): manifest fields,
  folder naming and chunk ids, shared by the modules that read or change
  projects. Behaviour follows BTT-Writer Desktop 1.6.0. }

interface

uses
  Classes, SysUtils, fpjson;

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

end.
