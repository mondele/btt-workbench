unit ModTextCheck;

{$mode objfpc}{$H+}

(* text-check: usfm-tools' translation text checks (verifyUSFM.py, Larry
   Versaw, Wycliffe Associates) on the text projects in targetTranslations,
   read straight from the chunk files (WBUsfmChecks). Each finding names
   verifyUSFM's check number, so results can be compared with its
   issues.txt. Filters as in projects; --skip turns off groups of checks
   (as verifyUSFM's suppress settings do). Changes nothing. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TTextCheckModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
  end;

implementation

uses
  fpjson, WBJson, WBDataPaths, WBProject, WBUsfmChecks, WBVersification, WBSources;

resourcestring
  rsTitle = 'Translation text checks';
  rsDescription = 'Checks the text of translation projects for verse, marker, ' +
    'punctuation, quote and number problems, using the checks of usfm-tools'' ' +
    'verifyUSFM. Changes nothing.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Only these target language codes, comma-separated';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only these book codes, comma-separated';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these resources, comma-separated (reg, ulb, ...)';
  rsOptSkip = 'Skip checks';
  rsOptSkipHelp = 'Groups of checks to leave out, comma-separated: structure, ' +
    'markers, punctuation, quotes, numbers, ascii, caps, source, words, headings';
  rsOptProblemsOnly = 'Problems only';
  rsOptProblemsOnlyHelp = 'List only projects with findings';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';

  rsNoTargetDir = 'Projects folder not found: %s';
  rsBadSkip = 'Unknown check group "%s". Use: %s';
  rsFolder = 'Projects folder: %s';
  rsHeader = '%s: %s (%s), %s - %d finding(s)';
  rsUnknownBook = '%s: book "%s" is not one of the 66 books; not checked.';
  rsSummary = '%d project(s) checked, %d with findings.';
  rsMore = '%s and %d more';

  { One per check; %s is the list of places. }
  rsMissingVerses = 'Verses missing from chapter %s: %s';
  rsVerseBeyond = 'Verse numbers past the end of the chapter: %s';
  rsVerseTwice = 'Verses given more than once: %s';
  rsVerseOrder = 'Verses out of order: %s';
  rsTextBeforeVerse = 'Text before the first verse marker of a chunk: %s';
  rsUnknownMarker = 'Unknown markers: %s';
  rsFootnoteMismatch = 'Footnote start and end markers do not pair up (started/ended): %s';
  rsNoSpaceBeforeNumber = 'No space between \v and the verse number: %s';
  rsNoSpaceAfterNumber = 'No space after the verse number: %s';
  rsNothingBeforeVerse = 'No space before a verse marker: %s';
  rsVerseNoNumber = 'Verse marker without a number: %s';
  rsSlashVerse = '"/v" typed instead of "\v": %s';
  rsConflictParsingError = 'BTT-Writer "Conflict Parsing Error" text: %s';
  rsAngleBracket = 'Angle bracket not closed: %s';
  rsPunctuation = 'Check the punctuation: %s';
  rsSpaceBeforePunct = 'Space before phrase-ending punctuation: %s';
  rsFreeFloating = 'Free-floating quote or bracket: %s';
  rsPunctAfterQuote = 'Punctuation after the closing quote: %s';
  rsRepeatedQuotes = 'Repeated quote marks: %s';
  rsWordMedialPunct = 'Punctuation inside a word: %s';
  rsSlash = 'Forward slash in the text: %s';
  rsBackslash = 'Backslash in the text: %s';
  rsEquals = 'Equals sign in the text: %s';
  rsOrphanPunct = 'Punctuation standing alone: %s';
  rsStartsWithPunct = 'Text begins with phrase-ending punctuation: %s';
  rsVerseNumberInText = 'Verse number in the text (probable): %s';
  rsPossibleVerseNumber = 'Possible verse number in the text: %s';
  rsVerseReference = 'Likely verse reference in the text (belongs in a footnote): %s';
  rsEmbeddedNumber = 'Number inside a word: %s';
  rsNumberPrefix = 'Invalid number prefix: %s';
  rsNumberSuffix = 'Invalid number suffix: %s';
  rsUnsegmented = 'Long number without separators: %s';
  rsSpaceInNumber = 'Space between digits: %s';
  rsLeadingZero = 'Number with a leading zero: %s';
  rsEmptyVerse = 'Empty verses: %s';
  rsAsciiVerse = 'Verses entirely in ASCII (untranslated?): %s';
  rsStraightQuotes = 'Straight quotes: %s double, %s single (not counting %s inside words)';
  rsBackslashEol = 'Backslash at the end of a line: %s';
  rsNullBytes = 'Null bytes: %s';
  rsCapsParagraph = 'First word of a paragraph not capitalised: %s';
  rsCapsSentence = 'First word of a sentence not capitalised: %s';
  rsParagraphPunct = 'No sentence-ending punctuation before a paragraph break: %s';
  rsShortVerse = 'Verses very short compared with the source: %s';
  rsUntranslated = 'Verses that may be untranslated (many words shared with the source): %s';
  rsMixedCase = 'Words in mixed case: %s';
  rsSectionTitle = 'Possible section titles in the text (should they be \s headings?): %s';
  rsComparedWith = 'Compared with source %s.';
  rsNoSource = 'No source text found to compare with; short verses are judged by length.';

const
  ListLimit = 20;

function TemplateOf(Id: TCheckId): string;
begin
  case Id of
    ciMissingVerses: Result := rsMissingVerses;
    ciVerseBeyond: Result := rsVerseBeyond;
    ciVerseTwice: Result := rsVerseTwice;
    ciVerseOrder: Result := rsVerseOrder;
    ciTextBeforeVerse: Result := rsTextBeforeVerse;
    ciUnknownMarker: Result := rsUnknownMarker;
    ciFootnoteMismatch: Result := rsFootnoteMismatch;
    ciNoSpaceBeforeNumber: Result := rsNoSpaceBeforeNumber;
    ciNoSpaceAfterNumber: Result := rsNoSpaceAfterNumber;
    ciNothingBeforeVerse: Result := rsNothingBeforeVerse;
    ciVerseNoNumber: Result := rsVerseNoNumber;
    ciSlashVerse: Result := rsSlashVerse;
    ciConflictParsingError: Result := rsConflictParsingError;
    ciAngleBracket: Result := rsAngleBracket;
    ciPunctuation: Result := rsPunctuation;
    ciSpaceBeforePunct: Result := rsSpaceBeforePunct;
    ciFreeFloating: Result := rsFreeFloating;
    ciPunctAfterQuote: Result := rsPunctAfterQuote;
    ciRepeatedQuotes: Result := rsRepeatedQuotes;
    ciWordMedialPunct: Result := rsWordMedialPunct;
    ciSlash: Result := rsSlash;
    ciBackslash: Result := rsBackslash;
    ciEquals: Result := rsEquals;
    ciOrphanPunct: Result := rsOrphanPunct;
    ciStartsWithPunct: Result := rsStartsWithPunct;
    ciVerseNumberInText: Result := rsVerseNumberInText;
    ciPossibleVerseNumber: Result := rsPossibleVerseNumber;
    ciVerseReference: Result := rsVerseReference;
    ciEmbeddedNumber: Result := rsEmbeddedNumber;
    ciNumberPrefix: Result := rsNumberPrefix;
    ciNumberSuffix: Result := rsNumberSuffix;
    ciUnsegmented: Result := rsUnsegmented;
    ciSpaceInNumber: Result := rsSpaceInNumber;
    ciLeadingZero: Result := rsLeadingZero;
    ciEmptyVerse: Result := rsEmptyVerse;
    ciAsciiVerse: Result := rsAsciiVerse;
    ciStraightQuotes: Result := rsStraightQuotes;
    ciBackslashEol: Result := rsBackslashEol;
    ciNullBytes: Result := rsNullBytes;
    ciCapsParagraph: Result := rsCapsParagraph;
    ciCapsSentence: Result := rsCapsSentence;
    ciParagraphPunct: Result := rsParagraphPunct;
    ciShortVerse: Result := rsShortVerse;
    ciUntranslated: Result := rsUntranslated;
    ciMixedCase: Result := rsMixedCase;
    ciSectionTitle: Result := rsSectionTitle;
  end;
end;

function ShortList(const Items: TStringArray): string;
var
  Shown: TStringArray;
  I: Integer;
begin
  if Length(Items) <= ListLimit then
    Exit(String.Join(', ', Items));
  SetLength(Shown, ListLimit);
  for I := 0 to ListLimit - 1 do
    Shown[I] := Items[I];
  Result := Format(rsMore, [String.Join(', ', Shown), Length(Items) - ListLimit]);
end;

function ReadText(const FileName: string): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

{ Messages for the hits, one line per check (missing verses: per chapter). }
procedure ReportHits(const Hits: TCheckHits; R: TWBReporter);
var
  Id: TCheckId;
  H: TCheckHit;
  Items, Parts: TStringArray;
  Item: string;
begin
  for Id in TCheckId do
  begin
    Items := nil;
    for H in Hits do
      if H.Id = Id then
      begin
        if Id = ciMissingVerses then
        begin
          R.Warn(Format(TemplateOf(Id), [H.Ref, H.Detail]) + ' [' + CheckNumber(Id) + ']');
          Continue;
        end;
        if Id = ciStraightQuotes then
        begin
          Parts := H.Detail.Split(['/']);
          R.Warn(Format(TemplateOf(Id), [Parts[0], Parts[1], Parts[2]]) + ' [' + CheckNumber(Id) + ']');
          Continue;
        end;
        Item := H.Ref;
        if H.Detail <> '' then
          Item := Item + ' "' + H.Detail + '"';
        Items := Concat(Items, [Item]);
      end;
    if Length(Items) > 0 then
      R.Warn(Format(TemplateOf(Id), [ShortList(Items)]) + ' [' + CheckNumber(Id) + ']');
  end;
end;

function TTextCheckModule.Id: string;
begin
  Result := 'text-check';
end;

function TTextCheckModule.Title: string;
begin
  Result := rsTitle;
end;

function TTextCheckModule.Description: string;
begin
  Result := rsDescription;
end;

function TTextCheckModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    OptionDef('language', okString, False, False, rsOptLanguage, rsOptLanguageHelp),
    OptionDef('book', okString, False, False, rsOptBook, rsOptBookHelp),
    OptionDef('type', okString, False, False, rsOptType, rsOptTypeHelp),
    OptionDef('skip', okString, False, False, rsOptSkip, rsOptSkipHelp),
    OptionDef('problems-only', okFlag, False, False, rsOptProblemsOnly, rsOptProblemsOnlyHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp)];
end;

function TTextCheckModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  TargetDir, Dir, Lang, Book, Kind, Res, S: string;
  Langs, Books, Types, Names: TStringArray;
  Groups: TCheckGroups;
  G: TCheckGroup;
  Found: Boolean;
  SR: TSearchRec;
  List: TStringList;
  Manifest: TJSONObject;
  Chunks: TProjectChunks;
  Texts: TChunkTexts;
  Hits: TCheckHits;
  Sources: TSourceLibrary;
  Source: TSourceChunking;
  Entries: TJSONData;
  Container: string;
  I, J, Checked, WithHits: Integer;
begin
  Result := 1;
  if Options.Values['target-dir'] <> '' then
    TargetDir := IncludeTrailingPathDelimiter(ExpandFileName(Options.Values['target-dir']))
  else
    TargetDir := TargetTranslationsPath;
  if not DirectoryExists(TargetDir) then
  begin
    Reporter.Error(Format(rsNoTargetDir, [ExcludeTrailingPathDelimiter(TargetDir)]));
    Exit;
  end;
  Langs := SplitList(Options.Values['language']);
  Books := SplitList(Options.Values['book']);
  Types := SplitList(Options.Values['type']);
  Groups := AllCheckGroups;
  for S in SplitList(Options.Values['skip']) do
  begin
    Found := False;
    for G in TCheckGroup do
      if CheckGroupName(G) = S then
      begin
        Exclude(Groups, G);
        Found := True;
      end;
    if not Found then
    begin
      Names := nil;
      for G in TCheckGroup do
        Names := Concat(Names, [CheckGroupName(G)]);
      Reporter.Error(Format(rsBadSkip, [S, String.Join(', ', Names)]));
      Exit;
    end;
  end;
  Reporter.Info(Format(rsFolder, [ExcludeTrailingPathDelimiter(TargetDir)]));

  List := TStringList.Create;
  Sources := TSourceLibrary.Create(LibrarySourcesPath(TargetDir), BundledSourcesPath);
  try
    if FindFirst(TargetDir + AllFilesMask, faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Name[1] <> '.') and
           ((SR.Attr and faDirectory) <> 0) then
          List.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    List.Sort;
    Checked := 0;
    WithHits := 0;
    for I := 0 to List.Count - 1 do
    begin
      Dir := TargetDir + List[I] + PathDelim;
      if not FileExists(Dir + 'manifest.json') then
        Continue;
      try
        Manifest := ReadJSONObjectFile(Dir + 'manifest.json');
      except
        Continue;   // the projects module reports unreadable manifests
      end;
      try
        Lang := StrField(Manifest, 'target_language.id');
        Book := StrField(Manifest, 'project.id');
        Kind := StrField(Manifest, 'type.id');
        Res := StrField(Manifest, 'resource.id');
        if (Kind <> 'text') or not (Matches(Langs, [Lang]) and Matches(Books, [Book]) and
           Matches(Types, [Kind, Res, Kind + '_' + Res])) then
          Continue;
        if BookIndex(Book) < 0 then
        begin
          Reporter.Info('');
          Reporter.Warn(Format(rsUnknownBook, [List[I], Book]));
          Continue;
        end;
        Chunks := ProjectChunks(Dir);
        Texts := nil;
        SetLength(Texts, Length(Chunks));
        for J := 0 to High(Chunks) do
        begin
          Texts[J].Chapter := Chunks[J].Chapter;
          Texts[J].Chunk := Chunks[J].Chunk;
          Texts[J].Text := ReadText(Chunks[J].Path);
        end;
        { The source the translator worked from: the first one listed that
          is here, else en_ulb. }
        Source := nil;
        Entries := Manifest.Find('source_translations');
        if (Entries <> nil) and (Entries.JSONType = jtArray) then
          for J := 0 to Entries.Count - 1 do
            if (Source = nil) and (Entries.Items[J] is TJSONObject) then
            begin
              Container := StrField(TJSONObject(Entries.Items[J]), 'language_id') + '_' +
                Book + '_' + StrField(TJSONObject(Entries.Items[J]), 'resource_id');
              Source := Sources.Find(Container);
            end;
        if Source = nil then
          Source := Sources.Find('en_' + Book + '_ulb');
        Hits := CheckChunks(Book, Texts, Groups, Source);
        Inc(Checked);
        if Length(Hits) > 0 then
          Inc(WithHits)
        else if OptionIsSet(Options, 'problems-only') then
          Continue;
        Reporter.Info('');
        S := StrField(Manifest, 'target_language.name');
        if S = '' then
          S := Lang;
        Reporter.Info(Format(rsHeader, [List[I], S, Lang, EnglishBookName(Book), Length(Hits)]));
        if Source <> nil then
          Reporter.Info(Format(rsComparedWith, [Source.Container]))
        else if cgSource in Groups then
          Reporter.Info(rsNoSource);
        ReportHits(Hits, Reporter);
      finally
        Manifest.Free;
      end;
    end;
  finally
    Sources.Free;
    List.Free;
  end;
  Reporter.Info('');
  Reporter.Info(Format(rsSummary, [Checked, WithHits]));
  Result := 0;
end;

initialization
  RegisterModule(TTextCheckModule.Create);

end.
