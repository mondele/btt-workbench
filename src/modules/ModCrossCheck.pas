unit ModCrossCheck;

{$mode objfpc}{$H+}

(* cross-check: text copied from one book into another. Compares the text
   projects of each language with each other, including every earlier
   version of their chunk files in git, and reports chunks holding text
   another book had first (WBCrossCheck), with the commit that brought it
   in. Changes nothing. *)

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
  end;

implementation

uses
  fpjson, Generics.Collections, WBJson, WBDataPaths, WBProject,
  WBSources, WBVersification, WBChunkHistory, WBCrossCheck;

resourcestring
  rsTitle = 'Text copied between books';
  rsDescription = 'Finds chunks holding text from another book of the same ' +
    'language: chunks pasted over, blocks of verses, and the end of another ' +
    'book''s chunk stuck onto a chunk. Earlier versions in each project''s ' +
    'history show which book had the text first and the commit that brought ' +
    'it in (the version before that commit has the chunk''s own text). Real ' +
    'parallels are left out by comparing the English ULB. Changes nothing.';
  rsOptLanguage = 'Languages';
  rsOptLanguageHelp = 'Only these target language codes, comma-separated';
  rsOptBook = 'Books';
  rsOptBookHelp = 'Only report on these book codes, comma-separated (all books ' +
    'of the language are still compared)';
  rsOptType = 'Project types';
  rsOptTypeHelp = 'Only these resources, comma-separated (reg, ulb, ...)';
  rsOptNoHistory = 'Current text only';
  rsOptNoHistoryHelp = 'Leave out earlier versions (faster, but which book had ' +
    'the text first is then unknown)';
  rsOptTargetDir = 'Projects folder';
  rsOptTargetDirHelp = 'Where projects live (default: BTT-Writer''s ' +
    'targetTranslations folder)';

  rsNoTargetDir = 'Projects folder not found: %s';
  rsFolder = 'Projects folder: %s';
  rsCompared = '%s: compared %d project(s), %d chunk file(s) and %d earlier version(s).';
  rsNoGit = '%s: no git history; only its current text is compared.';
  rsHeader = '%s: %s (%s), %s - %d chunk(s) with text from other books';
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
  rsSummary = '%d project(s) checked, %d with text from other books.';

type
  TProjectInfo = record
    Folder, Lang, LangName, Book: string;
    Report: Boolean;
  end;

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
    OptionDef('language', okString, False, False, rsOptLanguage, rsOptLanguageHelp),
    OptionDef('book', okString, False, False, rsOptBook, rsOptBookHelp),
    OptionDef('type', okString, False, False, rsOptType, rsOptTypeHelp),
    OptionDef('no-history', okFlag, False, False, rsOptNoHistory, rsOptNoHistoryHelp),
    OptionDef('target-dir', okDirectory, False, False, rsOptTargetDir, rsOptTargetDirHelp)];
end;

function ReadText(const FileName: string): string;
var
  S: TStringStream;
begin
  S := TStringStream.Create('');
  try
    S.LoadFromFile(FileName);
    Result := S.DataString;
  finally
    S.Free;
  end;
end;

function BookName(const Code: string): string;
begin
  Result := EnglishBookName(Code);
  if Result = '' then
    Result := Code;
end;

function ChunkName(const D: TCrossDoc): string;
begin
  Result := D.Chapter + '/' + D.Chunk;
end;

function TCrossCheckModule.Execute(Options: TStrings; Reporter: TWBReporter): Integer;
var
  TargetDir, Dir, S, Lang, Origin, Line, Seen: string;
  Langs, Books, Types, Kinds: TStringArray;
  Projects: array of TProjectInfo;
  P: TProjectInfo;
  SR: TSearchRec;
  List, LangList: TStringList;
  Manifest: TJSONObject;
  Docs: TCrossDocs;
  Report: array of Boolean;
  Chunks: TProjectChunks;
  Versions: TChunkVersions;
  Commits: TCommitFilesList;
  CommitFiles: specialize TDictionary<string, Integer>;
  Findings: TCrossFindings;
  F: TCrossFinding;
  Copied: TStringList;   // origin project#9chunk -> where it went
  Lines: TStringList;
  Sources: TSourceLibrary;
  NoHistory: Boolean;
  I, J, K, N, NCurrent, NEarlier, NProj, Checked, WithFindings, Count: Integer;
  Parts: TStringArray;
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
  NoHistory := OptionIsSet(Options, 'no-history');
  Reporter.Info(Format(rsFolder, [ExcludeTrailingPathDelimiter(TargetDir)]));

  { Text projects, and which are reported on. }
  Projects := nil;
  List := TStringList.Create;
  LangList := TStringList.Create;
  LangList.Sorted := True;
  LangList.Duplicates := dupIgnore;
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
        if StrField(Manifest, 'type.id') <> 'text' then
          Continue;
        P.Folder := List[I];
        P.Lang := StrField(Manifest, 'target_language.id');
        P.LangName := StrField(Manifest, 'target_language.name');
        if P.LangName = '' then
          P.LangName := P.Lang;
        P.Book := StrField(Manifest, 'project.id');
        S := StrField(Manifest, 'resource.id');
        if (P.Lang = '') or (P.Book = '') or not Matches(Langs, [P.Lang]) then
          Continue;
        P.Report := Matches(Books, [P.Book]) and Matches(Types, ['text', S, 'text_' + S]);
        Projects := Concat(Projects, [P]);
        if P.Report then
          LangList.Add(P.Lang);
      finally
        Manifest.Free;
      end;
    end;
  finally
    List.Free;
  end;

  Checked := 0;
  WithFindings := 0;
  Sources := TSourceLibrary.Create(LibrarySourcesPath(TargetDir), BundledSourcesPath);
  CommitFiles := specialize TDictionary<string, Integer>.Create;
  Copied := TStringList.Create;
  Lines := TStringList.Create;
  try
    for Lang in LangList do
    begin
      Docs := nil;
      Report := nil;
      CommitFiles.Clear;
      Copied.Clear;
      N := 0;
      NCurrent := 0;
      NEarlier := 0;
      NProj := 0;
      for P in Projects do
      begin
        if P.Lang <> Lang then
          Continue;
        Inc(NProj);
        Dir := TargetDir + P.Folder + PathDelim;
        Chunks := ProjectChunks(Dir);
        SetLength(Docs, N + Length(Chunks));
        SetLength(Report, Length(Docs));
        for J := 0 to High(Chunks) do
        begin
          Docs[N].Book := P.Book;
          Docs[N].Project := P.Folder;
          Docs[N].Chapter := Chunks[J].Chapter;
          Docs[N].Chunk := Chunks[J].Chunk;
          Docs[N].Time := NotCommitted;
          Docs[N].Current := True;
          Docs[N].Text := ReadText(Chunks[J].Path);
          Report[N] := P.Report;
          Inc(N);
          Inc(NCurrent);
        end;
        if NoHistory then
          Continue;
        if not ReadChunkHistory(Dir, Versions, Commits) then
        begin
          Reporter.Info(Format(rsNoGit, [P.Folder]));
          Continue;
        end;
        for K := 0 to High(Commits) do
          CommitFiles.AddOrSetValue(P.Folder + #9 + Commits[K].Commit, Commits[K].Files);
        SetLength(Docs, N + Length(Versions));
        SetLength(Report, Length(Docs));
        for K := 0 to High(Versions) do
        begin
          Parts := Versions[K].Path.Split(['/']);
          if Length(Parts) <> 2 then
            Continue;
          Docs[N].Book := P.Book;
          Docs[N].Project := P.Folder;
          Docs[N].Chapter := Parts[0];
          Docs[N].Chunk := ChangeFileExt(Parts[1], '');
          Docs[N].Commit := Versions[K].Commit;
          Docs[N].Author := Versions[K].Author;
          Docs[N].Date := Versions[K].Date;
          Docs[N].Time := Versions[K].Time;
          Docs[N].Current := False;
          Docs[N].Text := Versions[K].Text;
          Report[N] := False;
          Inc(N);
          Inc(NEarlier);
        end;
        SetLength(Docs, N);
        SetLength(Report, N);
      end;
      Reporter.Info(Format(rsCompared, [Lang, NProj, NCurrent, NEarlier]));
      Findings := FindCopiedText(Docs, Report, Sources);

      { where each chunk's text went }
      for F in Findings do
      begin
        S := Docs[F.Origin].Project + #9 + ChunkName(Docs[F.Origin]);
        K := Copied.IndexOfName(S);
        Line := Docs[F.Doc].Book + ' ' + ChunkName(Docs[F.Doc]);
        if K < 0 then
          Copied.Add(S + '=' + Line)
        else if Pos(Line, Copied.ValueFromIndex[K]) = 0 then
          Copied.ValueFromIndex[K] := Copied.ValueFromIndex[K] + ', ' + Line;
      end;

      for P in Projects do
      begin
        if (P.Lang <> Lang) or not P.Report then
          Continue;
        Inc(Checked);
        Lines.Clear;
        Count := 0;
        Seen := #10;
        for F in Findings do
        begin
          if Docs[F.Doc].Project <> P.Folder then
            Continue;
          if (Count = 0) or (Pos(#10 + ChunkName(Docs[F.Doc]) + #10, Seen) = 0) then
          begin
            Inc(Count);
            Seen := Seen + ChunkName(Docs[F.Doc]) + #10;
          end;
          Origin := BookName(Docs[F.Origin].Book) + ' ' + ChunkName(Docs[F.Origin]);
          if not F.OriginCurrent then
            Origin := Format(rsEarlier, [Origin]);
          S := ChunkName(Docs[F.Doc]);
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
          else if Docs[F.Since].Current then
            Line := Line + rsUncommitted
          else
          begin
            Line := Line + Format(rsSince, [Copy(Docs[F.Since].Commit, 1, 7),
              Docs[F.Since].Date, Docs[F.Since].Author]);
            if CommitFiles.TryGetValue(P.Folder + #9 + Docs[F.Since].Commit, K) and (K > 1) then
              Line := Line + Format(rsAlsoChanged, [K - 1]);
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
    end;
  finally
    Lines.Free;
    Copied.Free;
    CommitFiles.Free;
    Sources.Free;
    LangList.Free;
  end;
  Reporter.Info('');
  Reporter.Info(Format(rsSummary, [Checked, WithFindings]));
  Result := 0;
end;

initialization
  RegisterModule(TCrossCheckModule.Create);

end.
