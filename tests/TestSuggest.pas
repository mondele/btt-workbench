unit TestSuggest;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Tests for WBSuggest and the modules' Suggestions: what the pickers of
   the GUI offer for the language, book and type filters. *)

interface

procedure TestSuggestions(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fpjson, WBModule, WBJson, WBSuggest, TestUtil;

function Values(const S: TWBSuggestions): string;
var
  X: TWBSuggestion;
begin
  Result := '';
  for X in S do
    Result := Result + X.Value + ';';
end;

function CaptionOf(const S: TWBSuggestions; const Value: string): string;
var
  X: TWBSuggestion;
begin
  Result := '';
  for X in S do
    if X.Value = Value then
      Exit(X.Caption);
end;

procedure MakeManifest(const Dir, Lang, LangName, Book, Kind, Res: string);
var
  M: TJSONObject;
begin
  ForceDirectories(Dir);
  M := TJSONObject.Create(['package_version', 8,
    'target_language', TJSONObject.Create(['id', Lang, 'name', LangName, 'direction', 'ltr']),
    'project', TJSONObject.Create(['id', Book, 'name', Book]),
    'type', TJSONObject.Create(['id', Kind, 'name', Kind])]);
  if Res <> '' then
    M.Add('resource', TJSONObject.Create(['id', Res, 'name', Res]));
  try
    WriteBttJSONFile(Dir + PathDelim + 'manifest.json', M);
  finally
    M.Free;
  end;
end;

procedure TestSuggestions(const TempRoot: string);
var
  Head, Part, Target: string;
  All, S: TWBSuggestions;
  M: TBoundArray;
  Options: TStringList;
begin
  Section('suggestions (pickers)');
  SplitLast('sah, ud', Head, Part);
  Check((Head = 'sah, ') and (Part = 'ud'), 'the part after the last comma is typed');
  SplitLast('udm', Head, Part);
  Check((Head = '') and (Part = 'udm'), 'no comma: all of it');

  SetLength(All, 4);
  All[0].Value := 'udm';
  All[0].Caption := 'udm  удмурт кыл';
  All[1].Value := 'udm-x-norudmurt';
  All[1].Caption := 'udm-x-norudmurt  Северной удмурт кыл';
  All[2].Value := 'sah';
  All[2].Caption := 'sah  саха тыла';
  All[3].Value := 'en';
  All[3].Caption := 'en  English';
  Check(CompletionOf(All, 'ud') = 0, 'completes from the first value it starts');
  Check(CompletionOf(All, 'UDM-') = 1, 'in any case');
  Check((CompletionOf(All, 'udm-x-norudmurt') = -1) and (CompletionOf(All, '') = -1) and
    (CompletionOf(All, 'zz') = -1), 'not a whole value, nothing, or a non-match');
  Check(CompletionOf(All, 'UDM') = -1, 'nor a value typed in full (udm, not udm-x-norudmurt)');
  M := Matching(All, 'УДМУРТ', 10);
  Check((Length(M) = 2) and (M[0] = 0) and (M[1] = 1),
    'the list: captions holding the text, in any case');
  M := Matching(All, 's', 10);
  Check((Length(M) = 2) and (M[0] = 2) and (M[1] = 3),
    'values starting with it first (sah), then captions holding it (English)');
  Check(Length(Matching(All, '', 3)) = 3, 'everything, up to the limit');

  Target := TempRoot + 'suggest' + PathDelim;
  MakeManifest(Target + 'udm_luk_text_reg', 'udm', 'удмурт кыл', 'luk', 'text', 'reg');
  MakeManifest(Target + 'udm_gen_text_reg', 'udm', 'Удмуртский', 'gen', 'text', 'reg');
  MakeManifest(Target + 'sah_mrk_tn', 'sah', 'саха тыла', 'mrk', 'tn', '');
  S := FolderSuggestions('language', Target);
  Check(Values(S) = 'sah;udm;', 'languages in the projects folder, sorted');
  Check(CaptionOf(S, 'udm') = 'udm  Удмуртский / удмурт кыл (2)',
    'with their names and how many projects');
  Check(Values(FolderSuggestions('book', Target)) = 'gen;mrk;luk;', 'books in canonical order');
  Check(Values(FolderSuggestions('type', Target)) = 'text_reg;tn;', 'types as the filter takes them');
  Check(FolderSuggestions('owner', Target) = nil, 'nothing for other options');

  S := NameSuggestions('book', ['a/udm_luk_text_reg', 'b/udm_luk_text_reg', 'a/udm_jhn_tn']);
  Check((Values(S) = 'luk;jhn;') and (CaptionOf(S, 'luk') = 'luk  Luke (2)'),
    'from repo names: books, with how many repos');
  Check(Values(NameSuggestions('owner', ['a/udm_luk_text_reg', 'b/udm_luk_text_reg'])) = 'a;b;',
    'owners');
  Check(Values(NameSuggestions('type', ['a/udm_luk_text_reg', 'a/udm_jhn_tn'])) = 'text_reg;tn;',
    'types');
  Check(Values(MergeSuggestions(NameSuggestions('book', ['a/udm_luk_text_reg']),
    FolderSuggestions('book', Target))) = 'luk;gen;mrk;', 'merged: the first list''s first');
  Check(Length(AllBooks) = 66, 'all 66 books');

  Options := TStringList.Create;
  try
    Options.Values['target-dir'] := Target;
    Check(Values(FindModule('projects').Suggestions('language', Options)) = 'sah;udm;',
      'projects suggests the folder''s languages');
    Check(Values(FindModule('cross-check').Suggestions('book', Options)) = 'gen;mrk;luk;',
      'and so do the other modules working on the folder');
    Check(Length(FindModule('wacs-download').Suggestions('book', Options)) = 66,
      'wacs-download: every book before a Find');
    Check(FindModule('ulb2reg').Suggestions('project', Options) = nil,
      'a module with nothing to suggest: a plain field');
  finally
    Options.Free;
  end;
end;

end.
