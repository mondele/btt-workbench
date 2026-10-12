unit WBFiles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ Deletes Dir and everything in it. Clears read-only attributes first
  (git object files are read-only, which blocks deletion on Windows). }
procedure DeleteTree(const Dir: string);

{ A path element that is safe as a single folder name: not empty, no
  separators, not . or .. }
function IsSafeName(const Name: string): Boolean;

{ A relative archive path with no .. segments and no absolute prefix. }
function IsSafeRelativePath(const Path: string): Boolean;

implementation

procedure DeleteTree(const Dir: string);
var
  SR: TSearchRec;
  Base, Full: string;
begin
  Base := IncludeTrailingPathDelimiter(Dir);
  if FindFirst(Base + AllFilesMask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      Full := Base + SR.Name;
      if ((SR.Attr and faDirectory) <> 0) and ((SR.Attr and faSymLink) = 0) then
        DeleteTree(Full)
      else
      begin
        {$IFDEF WINDOWS}
        FileSetAttr(Full, 0);
        {$ENDIF}
        DeleteFile(Full);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

function IsSafeName(const Name: string): Boolean;
begin
  Result := (Name <> '') and (Name <> '.') and (Name <> '..') and
    (Pos('/', Name) = 0) and (Pos('\', Name) = 0) and (Pos(':', Name) = 0);
end;

function IsSafeRelativePath(const Path: string): Boolean;
var
  Parts: TStringArray;
  P, Norm: string;
begin
  Norm := StringReplace(Path, '\', '/', [rfReplaceAll]);
  Result := (Norm <> '') and (Norm[1] <> '/') and (Pos(':', Norm) = 0);
  if not Result then
    Exit;
  Parts := Norm.Split(['/']);
  for P in Parts do
    if P = '..' then
      Exit(False);
end;

end.
