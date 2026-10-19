unit ModCrossCheck;

{$mode objfpc}{$H+}

(* cross-check: text copied from one book into another. Compares the text
   projects of each language with each other, including every earlier
   version of their chunk files in git, and reports chunks holding text
   another book had first (WBCrossCheck), with the commit that brought it
   in; also book titles another book has and chapter titles with the wrong
   number (WBCrossTitles). On request it also compares with other
   languages: projects in the projects folder or other folders, and
   BTT-Writer's source texts (WBForeignCheck). Changes nothing. *)

interface

uses
  Classes, SysUtils, WBModule, WBReporter;

type
  TCrossCheckModule = class(TWBModule)
  public
    function Id: string; override;
    function Title: string; override;
    function Description: string; override;
    function OptionDefs: TWBOptionDefs; override;
    function Execute(Options: TStrings; Reporter: TWBReporter): Integer; override;
    function Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions; override;
  end;

implementation

uses
  WBSuggest,  WBDataPaths, WBProject, WBSources, WBVersification, WBCrossCheck, WBCrossScan,
  WBCrossTitles, WBForeignCheck;

resourcestring
  rsTitle = 'Text copied between books';
  rsDescription = 'Finds chunks holding text from another book of the same ' +
    'language: chunks pasted over, blocks of verses, and the end of another ' +
    'book''s chunk stuck onto a chunk. Earlier versions in each project''s ' +
    'history show which book had the text first and the commit that brought ' +
    'it in (the version before that commit has the chunk''s own text). Real ' +
    'parallels are left out by comparing the English ULB. Also reports book ' +
    'titles another book has and chapter titles with the wrong number. With ' +
    'the options below it also compares with other languages: verses pasted ' +
    'or reworded from another language''s text, and chunks taken from it. ' +
    'Changes nothing.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Only report on these language codes, comma-separated ' +
    '(a first part such as mxc takes every code that starts with it; the ' +
    'language''s projects under other codes are still compared)';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only report on these book codes, comma-separated (all books ' +
    'of the language are still compared)';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these resources, comma-separated (reg, ulb, ...)';
  rsOptNoHistory = 'Current text only';
  rsOptNoHistoryHelp = 'Leave out earlier versions (faster, but which book had ' +
    'the text first is then unknown)';
  rsOptOtherLanguages = 'Compare with other languages here';
  rsOptOtherLanguagesHelp = 'Also compare with the projects of other languages ' +
    'in the projects folder';
  rsOptSources = 'Compare with source texts';
  rsOptSourcesHelp = 'Also compare with BTT-Writer''s source texts of the same ' +
    'books, in every language (untranslated text pasted in)';
  rsOptCompareDir = 'Compare with folders';
  rsOptCompareDirHelp = 'Also compare with the projects in these folders, for ' +
    'example a neighbouring language''s repos downloaded with wacs-download ' +
    '--target-dir';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';

  rsNoTargetDir = 'Projects folder not found: %s';
  rsNoCompareDir = 'Folder to compare with not found: %s';
  rsComparedOther = 'Also compared with %d text(s) in other languages.';
  rsTitleShared = '%s: the book title "%s" is also %s';
  rsTitleOf = 'the title of %s';
  rsEarlierTitleOf = 'an earlier title of %s';
  rsAnd = ' and ';
  rsChapterNumber = '%s: the chapter title "%s" has another chapter''s number';
  rsForeignSame = '%s: verse %d is the same as in %s (%d%% alike)';
  rsForeignReworded = '%s: verse %d was reworded to read like %s (%d%% alike, ' +
    'was %d%%)';
  rsForeignChunk = '%s: %d%% of its text is in %s %s';
  rsSourceText = 'the source text %s';
  rsProjectText = '%s (%s), %s';
  rsNoHistoryKnown = '; no history';
  rsFolder = 'Projects folder: %s';
  rsCompared = '%s: compared %d project(s), %d chunk file(s) and %d earlier version(s).';
  rsNoGit = '%s: no git history; only its current text is compared.';
  rsSeveralCodes = 'This language has projects under %d codes (%s); they are ' +
    'compared as one language.';
  rsHeader = '%s: %s (%s), %s - %d file(s) to check';
  rsHeaderNotes = '%s: %s (%s), %s';
  rsWhole = '%s: replaced by text from %s';
  rsPart = '%s: verses %s hold text from %s';
  rsPartNoVerse = '%s: part holds text from %s';
  rsTail = '%s: ends with text from %s';
  rsGlued = '%s: ends with text from %s, run onto the last word: "%s"';
  rsEarlier = '%s (an earlier version of it)';
  rsUnordered = '; both have it and which came first is unknown';
  rsUncommitted = '; not yet committed';
  rsSince = '; since %s (%s, %s)';
  rsAlsoChanged = '; that commit also changed %d other chunk file(s)';
  rsCopiedOut = 'The text of %s appears later in: %s';
  rsSummary = '%d project(s) checked, %d with files to check.';

function TCrossCheckModule.Id: string;
begin
  Result := 'cross-check';
end;

function TCrossCheckModule.Title: string;
begin
  Result := rsTitle;
end;

function TCrossCheckModule.Description: string;
begin
  Result := rsDescription;
end;

function TCrossCheckModule.OptionDefs: TWBOptionDefs;
begin
  Result := [
    SuggestingOptionDef('language', rsOptLanguage, rsOptLanguageHelp),
    SuggestingOptionDef('book', rsOptBook, rsOptBookHelp),
    SuggestingOptionDef('type', rsOptType, rsOptTypeHelp),
    OptionDef('no-history', okFlag, False, False, rsOptNoHistory, rsOptNoHistoryHelp),
    OptionDef('other-languages', okFlag, False, False, rsOptOtherLanguages,
      rsOptOtherLanguagesHelp),
    OptionDef('sources', okFlag, False, False, rsOptSources, rsOptSourcesHelp),
    ListOptionDef('compare-dir', okDirectory, False, False, rsOptCompareDir,
      rsOptCompareDirHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp)];
end;

function BookName(const Code: string): string;
begin
  Result := EnglishBookName(Code);
  if Result = '' then
    Result := Code;
end;

function TextName(T: TForeignText): string;
begin
  if T.IsSource then
    Result := Format(rsSourceText, [T.Name])
  else if T.LangName <> '' then
    Result := Format(rsProjectText, [T.LangName, T.Lang, T.Name])
  else
    Result := T.Name;
end;

function Percent(X: Double): Integer;
begin
  Result := Trunc(X * 100);
end;

function TCrossCheckModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  TargetDir, S, Lang, Origin, Line, Seen: string;
  Texts: TForeignTexts;
  Foreign: TForeignFindings;
  FF: TForeignFinding;
  T: TTitleFinding;
  SourceBooks: TStringList;
  NoHistory, Wide: Boolean;
  X: Integer;
  Projects: TCrossProjects;
  P: TCrossProject;
  Scan: TCrossScan;
  F: TCrossFinding;
  Copied: TStringList;   // origin project#9chunk -> where it went
  Lines: TStringList;
  Sources: TSourceLibrary;
  Kinds: TStringArray;
  K, Checked, WithFindings, Count: Integer;

  procedure Mark(Doc: Integer);
  begin
    if Pos(#10 + ChunkName(Scan.Docs[Doc]) + #10, Seen) = 0 then
    begin
      Inc(Count);
      Seen := Seen + ChunkName(Scan.Docs[Doc]) + #10;
    end;
  end;

  function SinceText(Doc: Integer): string;
  var
    N: Integer;
  begin
    if Doc < 0 then
      Exit(rsNoHistoryKnown);
    if Scan.Docs[Doc].Current then
      Exit(rsUncommitted);
    Result := Format(rsSince, [Copy(Scan.Docs[Doc].Commit, 1, 7), Scan.Docs[Doc].Date,
      Scan.Docs[Doc].Author]);
    N := Scan.FilesChanged(P.Folder, Scan.Docs[Doc].Commit);
    if N > 1 then
      Result := Result + Format(rsAlsoChanged, [N - 1]);
  end;

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
  Reporter.Info(Format(rsFolder, [ExcludeTrailingPathDelimiter(TargetDir)]));
  for S in OptionValues(Options, 'compare-dir') do
    if not DirectoryExists(S) then
    begin
      Reporter.Error(Format(rsNoCompareDir, [S]));
      Exit;
    end;
  Projects := ListTextProjects(TargetDir, SplitList(Options.Values['language']),
    SplitList(Options.Values['book']), SplitList(Options.Values['type']));
  NoHistory := OptionIsSet(Options, 'no-history');
  Wide := OptionIsSet(Options, 'other-languages') or OptionIsSet(Options, 'sources') or
    (Length(OptionValues(Options, 'compare-dir')) > 0);

  Checked := 0;
  WithFindings := 0;
  Sources := TSourceLibrary.Create(LibrarySourcesPath(TargetDir), BundledSourcesPath);
  Copied := TStringList.Create;
  Lines := TStringList.Create;
  Texts := TForeignTexts.Create(True);
  SourceBooks := TStringList.Create;
  try
    if OptionIsSet(Options, 'other-languages') then
      AddProjectTexts(TargetDir, Texts);
    for S in OptionValues(Options, 'compare-dir') do
      AddProjectTexts(ExpandFileName(S), Texts);
    for Lang in ReportLanguages(Projects) do
    begin
      Scan := ScanLanguage(TargetDir, Lang, Projects, NoHistory, Sources);
      try
        Foreign := nil;
        if Wide then
        begin
          if OptionIsSet(Options, 'sources') then
            for P in Projects do
              if (P.Group = Lang) and P.Report and (SourceBooks.IndexOf(P.Book) < 0) then
              begin
                AddSourceTexts(Sources, LibrarySourcesPath(TargetDir), BundledSourcesPath,
                  P.Book, Texts);
                SourceBooks.Add(P.Book);
              end;
          Foreign := FindForeignText(Scan, Texts, NoHistory);
          K := 0;
          for X := 0 to Texts.Count - 1 do
            if Texts[X].Group <> Lang then
              Inc(K);
          Reporter.Info(Format(rsComparedOther, [K]));
        end;
        for S in Scan.NoGit do
          Reporter.Info(Format(rsNoGit, [S]));
        if Length(Scan.Codes) > 1 then
          Reporter.Warn(Format(rsSeveralCodes, [Length(Scan.Codes),
            String.Join(', ', Scan.Codes)]));
        Reporter.Info(Format(rsCompared, [String.Join(', ', Scan.Codes), Scan.NProjects,
          Scan.NCurrent, Scan.NEarlier]));

        { where each chunk's text went }
        Copied.Clear;
        for F in Scan.Findings do
        begin
          S := Scan.Docs[F.Origin].Project + #9 + ChunkName(Scan.Docs[F.Origin]);
          K := Copied.IndexOfName(S);
          Line := Scan.Docs[F.Doc].Book + ' ' + ChunkName(Scan.Docs[F.Doc]);
          if K < 0 then
            Copied.Add(S + '=' + Line)
          else if Pos(Line, Copied.ValueFromIndex[K]) = 0 then
            Copied.ValueFromIndex[K] := Copied.ValueFromIndex[K] + ', ' + Line;
        end;

        for P in Projects do
        begin
          if (P.Group <> Lang) or not P.Report then
            Continue;
          Inc(Checked);
          Lines.Clear;
          Count := 0;
          Seen := #10;
          for F in Scan.Findings do
          begin
            if Scan.Docs[F.Doc].Project <> P.Folder then
              Continue;
            if Pos(#10 + ChunkName(Scan.Docs[F.Doc]) + #10, Seen) = 0 then
            begin
              Inc(Count);
              Seen := Seen + ChunkName(Scan.Docs[F.Doc]) + #10;
            end;
            Origin := BookName(Scan.Docs[F.Origin].Book) + ' ' + ChunkName(Scan.Docs[F.Origin]);
            if not F.OriginCurrent then
              Origin := Format(rsEarlier, [Origin]);
            S := ChunkName(Scan.Docs[F.Doc]);
            case F.Kind of
              ckWhole: Line := Format(rsWhole, [S, Origin]);
              ckPart:
                if F.Verses <> '' then
                  Line := Format(rsPart, [S, F.Verses, Origin])
                else
                  Line := Format(rsPartNoVerse, [S, Origin]);
              ckTail: Line := Format(rsTail, [S, Origin]);
              ckGlued: Line := Format(rsGlued, [S, Origin, Copy(F.Fragment, 1, 80)]);
            end;
            if F.Unordered then
              Line := Line + rsUnordered
            else if Scan.Docs[F.Since].Current then
              Line := Line + rsUncommitted
            else
            begin
              Line := Line + Format(rsSince, [Copy(Scan.Docs[F.Since].Commit, 1, 7),
                Scan.Docs[F.Since].Date, Scan.Docs[F.Since].Author]);
              K := Scan.FilesChanged(P.Folder, Scan.Docs[F.Since].Commit);
              if K > 1 then
                Line := Line + Format(rsAlsoChanged, [K - 1]);
            end;
            Lines.Add('W' + Line);
          end;
          for T in Scan.Titles do
          begin
            if Scan.Docs[T.Doc].Project <> P.Folder then
              Continue;
            Mark(T.Doc);
            S := ChunkName(Scan.Docs[T.Doc]);
            if T.Kind = tkChapterNumber then
              Line := Format(rsChapterNumber, [S, NormalText(Scan.Docs[T.Doc].Text)])
            else
            begin
              Origin := '';
              for X in T.Others do
              begin
                if Origin <> '' then
                  Origin := Origin + rsAnd;
                if Scan.Docs[X].Current then
                  Origin := Origin + Format(rsTitleOf, [BookName(Scan.Docs[X].Book)])
                else
                  Origin := Origin + Format(rsEarlierTitleOf, [BookName(Scan.Docs[X].Book)]);
              end;
              Line := Format(rsTitleShared, [S, NormalText(Scan.Docs[T.Doc].Text), Origin]);
            end;
            Lines.Add('W' + Line + SinceText(T.Since));
          end;
          for FF in Foreign do
          begin
            if Scan.Docs[FF.Doc].Project <> P.Folder then
              Continue;
            Mark(FF.Doc);
            S := ChunkName(Scan.Docs[FF.Doc]);
            case FF.Kind of
              fkSame: Line := Format(rsForeignSame, [S, FF.Verse, TextName(Texts[FF.Text]),
                Percent(FF.Now)]);
              fkReworded: Line := Format(rsForeignReworded, [S, FF.Verse,
                TextName(Texts[FF.Text]), Percent(FF.Now), Percent(FF.Before)]) +
                SinceText(FF.Since);
              fkChunk: Line := Format(rsForeignChunk, [S, Percent(FF.Now),
                TextName(Texts[FF.Text]), FF.Chunk]);
            end;
            Lines.Add('W' + Line);
          end;
          for K := 0 to Copied.Count - 1 do
          begin
            Kinds := Copied.Names[K].Split([#9]);
            if Kinds[0] = P.Folder then
              Lines.Add('I' + Format(rsCopiedOut, [Kinds[1], Copied.ValueFromIndex[K]]));
          end;
          if Lines.Count = 0 then
            Continue;
          if Count > 0 then
            Inc(WithFindings);
          Reporter.Info('');
          if Count > 0 then
            Reporter.Info(Format(rsHeader, [P.Folder, P.LangName, P.Lang, BookName(P.Book), Count]))
          else
            Reporter.Info(Format(rsHeaderNotes, [P.Folder, P.LangName, P.Lang, BookName(P.Book)]));
          for Line in Lines do
            if Line[1] = 'W' then
              Reporter.Warn(Copy(Line, 2, MaxInt))
            else
              Reporter.Info(Copy(Line, 2, MaxInt));
        end;
      finally
        Scan.Free;
      end;
    end;
  finally
    SourceBooks.Free;
    Texts.Free;
    Lines.Free;
    Copied.Free;
    Sources.Free;
  end;
  Reporter.Info('');
  Reporter.Info(Format(rsSummary, [Checked, WithFindings]));
  Result := 0;
end;

function TCrossCheckModule.Suggestions(const OptionName: string; Options: TStrings): TWBSuggestions;
begin
  Result := FolderSuggestions(OptionName, TargetDirOption(Options));
end;

initialization
  RegisterModule(TCrossCheckModule.Create);

end.
