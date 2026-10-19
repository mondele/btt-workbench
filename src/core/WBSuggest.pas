unit WBSuggest;

{$mode objfpc}{$H+}

(* Suggestions for the language, book and type filters (TWBModule.
   Suggestions): what the projects folder holds, every language in
   BTT-Writer's language database, the 66 books, the usual project types,
   and the parts of project or repo names (lang_book_type[_resource]).

   The GUI asks each time a field is entered, so the folder and the
   database are read once and kept for a few seconds. *)

interface

uses
  Classes, SysUtils, WBModule;

{ language, book or type: what the projects in TargetDir have, with how
  many projects (nil for any other option). }
function FolderSuggestions(const OptionName, TargetDir: string): TWBSuggestions;
{ Every language in BTT-Writer's language database for TargetDir. }
function DatabaseLanguages(const TargetDir: string): TWBSuggestions;
{ The 66 books, canonical order. }
function AllBooks: TWBSuggestions;
{ The usual project types: text_reg, text_ulb, ..., tn, tq, tw. }
function KnownTypes: TWBSuggestions;
{ language, book, type or owner from names owner/lang_book_type[_res]
  (owner/ optional), with how many names have each. }
function NameSuggestions(const OptionName: string; const Names: array of string): TWBSuggestions;
{ A's suggestions, then B's whose values A does not have. }
function MergeSuggestions(const A, B: TWBSuggestions): TWBSuggestions;
{ The target-dir option, or BTT-Writer's targetTranslations folder. }
function TargetDirOption(Options: TStrings): string;

{ For a picker of comma-separated values: the text up to and including the
  last comma (and the spaces after it), and the part being typed after it. }
procedure SplitLast(const Text: string; out Head, Part: string);
{ The first suggestion whose value starts with Part (any case) and is
  longer: -1 if none, or if Part is a value itself (udm, not udm-x-...). }
function CompletionOf(const All: TWBSuggestions; const Part: string): Integer;
{ Positions in All of the suggestions to list for Part: values starting
  with it, then captions holding it; everything when Part is empty; at
  most Limit. }
function Matching(const All: TWBSuggestions; const Part: string; Limit: Integer): TBoundArray;

implementation

uses
  Character, fpjson, WBJson, WBProject, WBDataPaths, WBLanguages, WBVersification;

function Lower(const S: string): string;
begin
  Result := UTF8Encode(TCharacter.ToLower(UTF8Decode(S)));
end;

const
  KeepSeconds = 10;

var
  FolderDir: string;
  FolderTime: TDateTime;
  FolderLangs, FolderBooks, FolderTypes: TWBSuggestions;
  DbPath: string;
  DbLangs: TWBSuggestions;

function TargetDirOption(Options: TStrings): string;
begin
  if Options.Values['target-dir'] <> '' then
    Result := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    Result := TargetTranslationsPath;
end;

function Suggestion(const Value, Caption: string): TWBSuggestion;
begin
  Result.Value := Value;
  Result.Caption := Caption;
end;

{ Count[Value] and a caption part per value, kept in first-seen order. }
type
  TTally = class
    Values, Extra: TStringList;   // Extra: what follows the value
    Counts: array of Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Value, More: string);
    function Suggestions: TWBSuggestions;
  end;

constructor TTally.Create;
begin
  Values := TStringList.Create;
  Values.UseLocale := False;
  Values.CaseSensitive := True;
  Extra := TStringList.Create;
end;

destructor TTally.Destroy;
begin
  Values.Free;
  Extra.Free;
  inherited Destroy;
end;

procedure TTally.Add(const Value, More: string);
var
  I: Integer;
begin
  if Value = '' then
    Exit;
  I := Values.IndexOf(Value);
  if I < 0 then
  begin
    I := Values.Add(Value);
    Extra.Add(More);
    SetLength(Counts, I + 1);
    Counts[I] := 0;
  end
  else if (More <> '') and (Pos(More, Extra[I]) = 0) then
  begin
    if Extra[I] <> '' then
      Extra[I] := Extra[I] + ' / ';
    Extra[I] := Extra[I] + More;
  end;
  Inc(Counts[I]);
end;

function TTally.Suggestions: TWBSuggestions;
var
  I: Integer;
  C: string;
begin
  SetLength(Result, Values.Count);
  for I := 0 to Values.Count - 1 do
  begin
    C := Values[I];
    if Extra[I] <> '' then
      C := C + '  ' + Extra[I];
    Result[I] := Suggestion(Values[I], C + Format(' (%d)', [Counts[I]]));
  end;
end;

{ Sorted by value; books in canonical order, unknown ones after. }
procedure SortSuggestions(var S: TWBSuggestions; Books: Boolean);
var
  I, J: Integer;
  T: TWBSuggestion;

  function Before(const A, B: TWBSuggestion): Boolean;
  var
    IA, IB: Integer;
  begin
    if Books then
    begin
      IA := BookIndex(A.Value);
      IB := BookIndex(B.Value);
      if IA < 0 then
        IA := MaxInt;
      if IB < 0 then
        IB := MaxInt;
      if IA <> IB then
        Exit(IA < IB);
    end;
    Result := CompareText(A.Value, B.Value) < 0;
  end;

begin
  for I := 1 to High(S) do
  begin
    T := S[I];
    J := I - 1;
    while (J >= 0) and Before(T, S[J]) do
    begin
      S[J + 1] := S[J];
      Dec(J);
    end;
    S[J + 1] := T;
  end;
end;

procedure ScanFolder(const TargetDir: string);
var
  SR: TSearchRec;
  Manifest: TJSONObject;
  Langs, Books, Types: TTally;
  Kind, Res, Folder: string;
  Folders: TStringList;
begin
  if (TargetDir = FolderDir) and (Now - FolderTime < KeepSeconds / 86400) then
    Exit;
  Langs := TTally.Create;
  Books := TTally.Create;
  Types := TTally.Create;
  Folders := TStringList.Create;
  try
    if FindFirst(TargetDir + AllFilesMask, faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name[1] <> '.') and ((SR.Attr and faDirectory) <> 0) and
           FileExists(TargetDir + SR.Name + PathDelim + 'manifest.json') then
          Folders.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Folders.UseLocale := False;
    Folders.Sort;   // names in a caption in a fixed order
    for Folder in Folders do
    begin
        try
          Manifest := ReadJSONObjectFile(TargetDir + Folder + PathDelim + 'manifest.json');
        except
          Continue;
        end;
        try
          Langs.Add(StrField(Manifest, 'target_language.id'),
            StrField(Manifest, 'target_language.name'));
          Books.Add(LowerCase(StrField(Manifest, 'project.id')),
            EnglishBookName(StrField(Manifest, 'project.id')));
          Kind := StrField(Manifest, 'type.id');
          Res := StrField(Manifest, 'resource.id');
          if Res <> '' then
            Types.Add(Kind + '_' + Res, '')
          else
            Types.Add(Kind, '');
        finally
          Manifest.Free;
        end;
    end;
    FolderLangs := Langs.Suggestions;
    FolderBooks := Books.Suggestions;
    FolderTypes := Types.Suggestions;
  finally
    Folders.Free;
    Langs.Free;
    Books.Free;
    Types.Free;
  end;
  SortSuggestions(FolderLangs, False);
  SortSuggestions(FolderBooks, True);
  SortSuggestions(FolderTypes, False);
  FolderDir := TargetDir;
  FolderTime := Now;
end;

function FolderSuggestions(const OptionName, TargetDir: string): TWBSuggestions;
begin
  Result := nil;
  if (OptionName <> 'language') and (OptionName <> 'book') and (OptionName <> 'type') then
    Exit;
  if not DirectoryExists(TargetDir) then
    Exit;
  ScanFolder(IncludeTrailingPathDelimiter(TargetDir));
  if OptionName = 'language' then
    Result := FolderLangs
  else if OptionName = 'book' then
    Result := FolderBooks
  else
    Result := FolderTypes;
end;

function DatabaseLanguages(const TargetDir: string): TWBSuggestions;
var
  Path: string;
  Index: TLanguageIndex;
  Info: TLanguageInfo;
  I: Integer;
begin
  Result := nil;
  Path := LanguageIndexPath(TargetDir);
  if Path = '' then
    Exit;
  if Path = DbPath then
    Exit(DbLangs);
  try
    Index := TLanguageIndex.Create(Path);
  except
    Exit;
  end;
  try
    SetLength(Result, Index.Count);
    I := 0;
    for Info in Index.All do
    begin
      Result[I] := Suggestion(Info.Code, Info.Code + '  ' + Info.Name);
      Inc(I);
    end;
  finally
    Index.Free;
  end;
  SortSuggestions(Result, False);
  DbPath := Path;
  DbLangs := Result;
end;

function AllBooks: TWBSuggestions;
var
  Code: string;
begin
  Result := nil;
  for Code in BookCodes do
    Result := Concat(Result, [Suggestion(Code, Code + '  ' + EnglishBookName(Code))]);
end;

function KnownTypes: TWBSuggestions;
const
  Known: array[0..6] of string = ('text_reg', 'text_ulb', 'text_udb', 'text', 'tn', 'tq', 'tw');
var
  S: string;
begin
  Result := nil;
  for S in Known do
    Result := Concat(Result, [Suggestion(S, S)]);
end;

function NameSuggestions(const OptionName: string; const Names: array of string): TWBSuggestions;
var
  T: TTally;
  N, Owner, Repo: string;
  Parts: TStringArray;
  P: Integer;
begin
  T := TTally.Create;
  try
    for N in Names do
    begin
      P := Pos('/', N);
      Owner := Copy(N, 1, P - 1);
      Repo := Copy(N, P + 1, MaxInt);
      Parts := Repo.Split(['_']);
      if OptionName = 'owner' then
        T.Add(Owner, '')
      else if Length(Parts) < 3 then
        Continue
      else if OptionName = 'language' then
        T.Add(Parts[0], '')
      else if OptionName = 'book' then
        T.Add(LowerCase(Parts[1]), EnglishBookName(Parts[1]))
      else if OptionName = 'type' then
        T.Add(String.Join('_', Copy(Parts, 2, MaxInt)), '');
    end;
    Result := T.Suggestions;
  finally
    T.Free;
  end;
  SortSuggestions(Result, OptionName = 'book');
end;

function MergeSuggestions(const A, B: TWBSuggestions): TWBSuggestions;
var
  Seen: TStringList;
  S: TWBSuggestion;
begin
  Result := Copy(A);
  Seen := TStringList.Create;
  try
    Seen.UseLocale := False;
    Seen.CaseSensitive := True;
    Seen.Sorted := True;
    for S in A do
      Seen.Add(S.Value);
    for S in B do
      if Seen.IndexOf(S.Value) < 0 then
        Result := Concat(Result, [S]);
  finally
    Seen.Free;
  end;
end;

procedure SplitLast(const Text: string; out Head, Part: string);
var
  P: Integer;
begin
  P := Length(Text);
  while (P > 0) and (Text[P] <> ',') do
    Dec(P);
  Inc(P);
  while (P <= Length(Text)) and (Text[P] = ' ') do
    Inc(P);
  Head := Copy(Text, 1, P - 1);
  Part := Copy(Text, P, MaxInt);
end;

function CompletionOf(const All: TWBSuggestions; const Part: string): Integer;
var
  L: string;
  I: Integer;
begin
  Result := -1;
  if Part = '' then
    Exit;
  L := Lower(Part);
  for I := 0 to High(All) do
    if Lower(All[I].Value) = L then
      Exit;
  for I := 0 to High(All) do
    if (Length(All[I].Value) > Length(Part)) and
       (Lower(Copy(All[I].Value, 1, Length(Part))) = L) then
      Exit(I);
end;

function Matching(const All: TWBSuggestions; const Part: string; Limit: Integer): TBoundArray;
var
  L: string;
  I: Integer;
  Taken: array of Boolean;
begin
  Result := nil;
  L := Lower(Part);
  SetLength(Taken, Length(All));
  for I := 0 to High(All) do
    Taken[I] := False;
  for I := 0 to High(All) do
    if (Length(Result) < Limit) and
       ((L = '') or (Lower(Copy(All[I].Value, 1, Length(Part))) = L)) then
    begin
      Result := Concat(Result, [I]);
      Taken[I] := True;
    end;
  if L = '' then
    Exit;
  for I := 0 to High(All) do
    if (Length(Result) < Limit) and not Taken[I] and
       (Pos(L, Lower(All[I].Caption)) > 0) then
      Result := Concat(Result, [I]);
end;

end.
