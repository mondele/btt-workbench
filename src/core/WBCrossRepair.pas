unit WBCrossRepair;

{$mode objfpc}{$H+}

(* Repairs chunks holding text copied from another book (found by
   WBCrossCheck), one chunk file at a time, leaving everything else the
   damaging commits did alone.

   For each damaged chunk the commit that brought the copied text into that
   file is found from its history. Then:
   - restore: the file existed before that commit; it gets that version
     back;
   - remove: the file did not exist before; it is deleted and taken out of
     finished_chunks.
   Nothing is changed (review) when the file was changed since by a commit
   that brought no copied text into this project, or has uncommitted
   changes. A chunk is mixed when that commit also changed the chunk's own
   words (words added that none of the source chunks ever had): repairing
   it would undo those too, so it needs a separate yes. *)

interface

uses
  Classes, SysUtils, WBCrossCheck, WBCrossScan;

type
  TRepairAction = (raRestore, raRemove);
  TRepairHold = (rhNone, rhEditedSince, rhUncommitted, rhNoHistory);

  TRepairItem = record
    Project, Book, Chapter, Chunk: string;
    Action: TRepairAction;
    Hold: TRepairHold;      // why it is left alone (rhNone: it can be repaired)
    Mixed: Boolean;          // repairing also undoes own words of that commit
    Commit, Date, Author: string;       // the commit that brought the text in
    LaterCommit, LaterDate, LaterAuthor: string;   // rhEditedSince: by whom
    Origins: string;         // where the text came from: 'Revelation 01/04'
    Restored: string;        // raRestore: the file as it was before Commit
  end;
  TRepairItems = array of TRepairItem;

{ project/chapter/chunk: the checklist value of an item. }
function RepairValue(const Item: TRepairItem): string;
{ Plans a repair for every damaged chunk of the projects reported on. }
function PlanRepairs(Scan: TCrossScan; const TargetDir: string): TRepairItems;
{ Who repair commits are by: the WACS user logged in here, else BTT
  Workbench. A project's own git settings hold the field user's name, which
  would make the repair look like theirs. }
procedure RepairIdentity(out Name, Email: string);
{ Applies Items (all of one project, and repairable) and commits them with
  Message as Name <Email>. False with Failure set if anything went wrong. }
function ApplyRepairs(const ProjectDir: string; const Items: TRepairItems;
  const Message, Name, Email: string; out Failure: string): Boolean;

implementation

uses
  fpjson, Generics.Collections, WBGit, WBJson, WBProject, WBImport, WBVersification,
  WBSources, WBWacs, WBCrossTitles;

function RepairValue(const Item: TRepairItem): string;
begin
  Result := Item.Project + '/' + Item.Chapter + '/' + Item.Chunk;
end;

function BookName(const Code: string): string;
begin
  Result := EnglishBookName(Code);
  if Result = '' then
    Result := Code;
end;

function SameChunk(const A, B: TCrossDoc): Boolean;
begin
  Result := (A.Project = B.Project) and (A.Chapter = B.Chapter) and (A.Chunk = B.Chunk);
end;

function ChunkPath(const Item: TRepairItem): string;
begin
  Result := Item.Chapter + '/' + Item.Chunk + '.txt';
end;

{ Words of New that a longest common subsequence with Old leaves over:
  what was added. }
function AddedWords(const Old, New: THashList): THashList;
var
  L: array of array of Integer;
  I, J, N, M: Integer;
begin
  N := Length(Old);
  M := Length(New);
  SetLength(L, N + 1, M + 1);
  for I := N - 1 downto 0 do
    for J := M - 1 downto 0 do
      if Old[I] = New[J] then
        L[I][J] := L[I + 1][J + 1] + 1
      else if L[I + 1][J] >= L[I][J + 1] then
        L[I][J] := L[I + 1][J]
      else
        L[I][J] := L[I][J + 1];
  Result := nil;
  I := 0;
  J := 0;
  while J < M do
    if (I < N) and (Old[I] = New[J]) then
    begin
      Inc(I);
      Inc(J);
    end
    else if (I < N) and (L[I + 1][J] >= L[I][J + 1]) then
      Inc(I)
    else
    begin
      Result := Concat(Result, [New[J]]);
      Inc(J);
    end;
end;

const
  { Words a paste may add that no source chunk had: the pieces of a word
    cut at the start of a selection, a typo fixed on the way. }
  MixedSlack = 2;

function PlanRepairs(Scan: TCrossScan; const TargetDir: string): TRepairItems;
var
  Docs: TCrossDocs;
  Chunks: specialize TDictionary<Integer, Integer>;   // current doc -> item
  Intro: array of Integer;     // per item: version that brought the text in
  ProjectCommits: specialize THashSet<string>;   // project#9commit
  Item: TRepairItem;
  F: TCrossFinding;
  I, D: Integer;
  Dir, Path, S: string;
  R: TGitResult;
  Fields: TStringArray;
  Allowed: specialize THashSet<QWord>;
  Old, New, Added: THashList;
  VS: TVerseList;
  H: QWord;
  Unmatched: Integer;
  ItemDoc: array of Integer;
  Mine: specialize THashSet<QWord>;
  Shared: Integer;
  Cache, ShCache: array of THashList;
  Cached, ShCached: array of Boolean;
  T: TTitleFinding;
  Versions: TDocList;
  Q, X: Integer;

  function ShinglesOf(Doc: Integer): THashList;
  var
    V: TVerseList;
    W: THashList;
  begin
    if not ShCached[Doc] then
    begin
      if Cached[Doc] then
        W := Cache[Doc]
      else
        TokenizeWords(Docs[Doc].Text, W, V);
      ShCache[Doc] := Shingles(W, ShingleWords);
      ShCached[Doc] := True;
    end;
    Result := ShCache[Doc];
  end;

  function WordsOf(Doc: Integer): THashList;
  var
    V: TVerseList;
  begin
    if not Cached[Doc] then
    begin
      TokenizeWords(Docs[Doc].Text, Cache[Doc], V);
      Cached[Doc] := True;
    end;
    Result := Cache[Doc];
  end;

begin
  Result := nil;
  Docs := Scan.Docs;
  Chunks := specialize TDictionary<Integer, Integer>.Create;
  ProjectCommits := specialize THashSet<string>.Create;
  Allowed := specialize THashSet<QWord>.Create;
  Mine := specialize THashSet<QWord>.Create;
  SetLength(Cache, Length(Docs));
  SetLength(Cached, Length(Docs));
  SetLength(ShCache, Length(Docs));
  SetLength(ShCached, Length(Docs));
  try
    { one item per damaged chunk, with the version that brought each
      finding's text into this file }
    Intro := nil;
    ItemDoc := nil;
    for F in Scan.Findings do
    begin
      if not Chunks.TryGetValue(F.Doc, I) then
      begin
        Item := Default(TRepairItem);
        Item.Project := Docs[F.Doc].Project;
        Item.Book := Docs[F.Doc].Book;
        Item.Chapter := Docs[F.Doc].Chapter;
        Item.Chunk := Docs[F.Doc].Chunk;
        I := Length(Result);
        Result := Concat(Result, [Item]);
        Intro := Concat(Intro, [-1]);
        ItemDoc := Concat(ItemDoc, [F.Doc]);
        Chunks.Add(F.Doc, I);
      end;
      S := BookName(Docs[F.Origin].Book) + ' ' + ChunkName(Docs[F.Origin]);
      if Pos(S, Result[I].Origins) = 0 then
      begin
        if Result[I].Origins <> '' then
          Result[I].Origins := Result[I].Origins + ', ';
        Result[I].Origins := Result[I].Origins + S;
      end;
      for D := 0 to High(Docs) do
        if not Docs[D].Current and SameChunk(Docs[D], Docs[F.Doc]) and
           ((Intro[I] < 0) or (Docs[D].Time < Docs[Intro[I]].Time)) and
           HasCopiedText(Docs[D], F) then
          Intro[I] := D;
    end;
    for I := 0 to High(Result) do
      if Intro[I] >= 0 then
      begin
        Result[I].Commit := Docs[Intro[I]].Commit;
        Result[I].Date := Docs[Intro[I]].Date;
        Result[I].Author := Docs[Intro[I]].Author;
        ProjectCommits.Add(Result[I].Project + #9 + Result[I].Commit);
      end
      else
        Result[I].Hold := rhNoHistory;   // only in uncommitted text, or no git

    for I := 0 to High(Result) do
    begin
      if Result[I].Hold <> rhNone then
        Continue;
      Dir := TargetDir + Result[I].Project + PathDelim;
      Path := ChunkPath(Result[I]);
      if Trim(RunGit(Dir, ['status', '--porcelain', '--', Path]).Output) <> '' then
      begin
        Result[I].Hold := rhUncommitted;
        Continue;
      end;
      { later commits to this file: fine if they too brought copied text in }
      R := RunGit(Dir, ['log', '--format=%H%x09%ai%x09%an',
        Result[I].Commit + '..HEAD', '--', Path]);
      for S in Lines(R.Output) do
      begin
        Fields := S.Split([#9], 3);
        if not ProjectCommits.Contains(Result[I].Project + #9 + Fields[0]) then
        begin
          Result[I].Hold := rhEditedSince;
          Result[I].LaterCommit := Fields[0];
          if Length(Fields) > 1 then
            Result[I].LaterDate := Copy(Fields[1], 1, 16);
          if Length(Fields) > 2 then
            Result[I].LaterAuthor := Fields[2];
          Break;
        end;
      end;
      if Result[I].Hold <> rhNone then
        Continue;
      R := RunGit(Dir, ['cat-file', '-e', Result[I].Commit + '^:' + Path]);
      if R.ExitCode = 0 then
      begin
        Result[I].Action := raRestore;
        R := RunGit(Dir, ['show', Result[I].Commit + '^:' + Path]);
        if R.ExitCode <> 0 then
        begin
          Result[I].Hold := rhNoHistory;
          Continue;
        end;
        Result[I].Restored := R.Output;
      end
      else
        Result[I].Action := raRemove;

      { Mixed: words added since the old version that no other book has
        near: not in any version of a finding's source chunk, nor of any
        chunk of another book sharing at least two word runs with this
        one. }
      Allowed.Clear;
      Mine.Clear;
      for H in ShinglesOf(ItemDoc[I]) do
        Mine.Add(H);
      { every version of each finding's own source chunk (a glued tail is
        too short to share two runs) }
      for F in Scan.Findings do
        if F.Doc = ItemDoc[I] then
          for D := 0 to High(Docs) do
            if SameChunk(Docs[D], Docs[F.Origin]) then
              for H in WordsOf(D) do
                Allowed.Add(H);
      for D := 0 to High(Docs) do
        if Docs[D].Book <> Result[I].Book then
        begin
          Shared := 0;
          for H in ShinglesOf(D) do
            if Mine.Contains(H) then
            begin
              Inc(Shared);
              if Shared >= 2 then
                Break;
            end;
          if Shared >= 2 then
            for H in WordsOf(D) do
              Allowed.Add(H);
        end;
      Old := nil;
      if Result[I].Action = raRestore then
        TokenizeWords(Result[I].Restored, Old, VS);
      TokenizeWords(Docs[ItemDoc[I]].Text, New, VS);
      Added := AddedWords(Old, New);
      Unmatched := 0;
      for H in Added do
        if not Allowed.Contains(H) then
          Inc(Unmatched);
      Result[I].Mixed := Unmatched > MixedSlack;
    end;

    { A book title another book has, brought in by a commit that also
      brought copied text into the project: back to the title before the
      first such commit. A title changed on its own may be a deliberate
      edit, so it is only reported. }
    for T in Scan.Titles do
    begin
      if (T.Kind <> tkShared) or (T.Since < 0) or Docs[T.Since].Current or
         not ProjectCommits.Contains(Docs[T.Doc].Project + #9 + Docs[T.Since].Commit) then
        Continue;
      Item := Default(TRepairItem);
      Item.Project := Docs[T.Doc].Project;
      Item.Book := Docs[T.Doc].Book;
      Item.Chapter := Docs[T.Doc].Chapter;
      Item.Chunk := Docs[T.Doc].Chunk;
      Item.Commit := Docs[T.Since].Commit;
      Item.Date := Docs[T.Since].Date;
      Item.Author := Docs[T.Since].Author;
      for X in T.Others do
      begin
        if Item.Origins <> '' then
          Item.Origins := Item.Origins + ', ';
        Item.Origins := Item.Origins + BookName(Docs[X].Book) + ' ' + ChunkName(Docs[X]);
      end;
      Item.Hold := rhNoHistory;
      Versions := VersionsOf(Docs, T.Doc);
      Q := 0;
      while (Q <= High(Versions)) and (Versions[Q] <> T.Since) do
        Inc(Q);
      for Q := Q + 1 to High(Versions) do
        if not ProjectCommits.Contains(Item.Project + #9 + Docs[Versions[Q]].Commit) then
        begin
          Item.Action := raRestore;
          Item.Restored := Docs[Versions[Q]].Text;
          Item.Hold := rhNone;
          Break;
        end;
      Result := Concat(Result, [Item]);
    end;
  finally
    Mine.Free;
    Allowed.Free;
    ProjectCommits.Free;
    Chunks.Free;
  end;
end;

function WriteText(const FileName, Text: string): Boolean;
var
  S: TStringStream;
begin
  S := TStringStream.Create(Text);
  try
    try
      S.SaveToFile(FileName);
      Result := True;
    except
      Result := False;
    end;
  finally
    S.Free;
  end;
end;

function DirIsEmpty(const Dir: string): Boolean;
var
  SR: TSearchRec;
begin
  Result := True;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + AllFilesMask, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        Exit(False);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure RepairIdentity(out Name, Email: string);
var
  A: TWacsAccount;
  Host: string;
  P: Integer;
begin
  A := LoadWacsAccount;
  if LoggedIn(A) and (A.User <> '') then
  begin
    Host := A.Server;
    P := Pos('://', Host);
    if P > 0 then
      Delete(Host, 1, P + 2);
    P := Pos('/', Host);
    if P > 0 then
      SetLength(Host, P - 1);
    P := Pos(':', Host);
    if P > 0 then
      SetLength(Host, P - 1);
    if Host = '' then
      Host := 'wacs';
    Name := A.User;
    Email := A.User + '@' + Host;
  end
  else
  begin
    Name := 'BTT Workbench';
    Email := 'btt-workbench@localhost';
  end;
end;

function ApplyRepairs(const ProjectDir: string; const Items: TRepairItems;
  const Message, Name, Email: string; out Failure: string): Boolean;
var
  R: TGitResult;
  Dir: string;
  Item: TRepairItem;
  FileName: string;
  Manifest: TJSONObject;
  Finished: TJSONData;
  Removed: TStringArray;
  I: Integer;
  ManifestChanged: Boolean;
begin
  Result := False;
  Failure := '';
  Removed := nil;
  for Item in Items do
  begin
    FileName := ProjectDir + Item.Chapter + PathDelim + Item.Chunk + '.txt';
    case Item.Action of
      raRestore:
        if not WriteText(FileName, Item.Restored) then
        begin
          Failure := FileName;
          Exit;
        end;
      raRemove:
        begin
          if FileExists(FileName) and not DeleteFile(FileName) then
          begin
            Failure := FileName;
            Exit;
          end;
          if DirIsEmpty(ProjectDir + Item.Chapter) then
            RemoveDir(ProjectDir + Item.Chapter);
          Removed := Concat(Removed, [ChunkIdFromPath(Item.Chapter + '/' + Item.Chunk + '.txt')]);
        end;
    end;
  end;
  if Length(Removed) > 0 then
  begin
    Manifest := ReadJSONObjectFile(ProjectDir + 'manifest.json');
    try
      ManifestChanged := False;
      Finished := Manifest.Find('finished_chunks');
      if Finished is TJSONArray then
        for I := TJSONArray(Finished).Count - 1 downto 0 do
          if (TJSONArray(Finished).Items[I].JSONType = jtString) and
             Contains(Removed, TJSONArray(Finished).Items[I].AsString) then
          begin
            TJSONArray(Finished).Delete(I);
            ManifestChanged := True;
          end;
      if ManifestChanged then
        WriteBttJSONFile(ProjectDir + 'manifest.json', Manifest);
    finally
      Manifest.Free;
    end;
  end;
  Dir := ExcludeTrailingPathDelimiter(ProjectDir);
  R := RunGit(Dir, ['add', '--all']);
  if R.ExitCode = 0 then
    R := RunGit(Dir, ['-c', 'user.name=' + Name, '-c', 'user.email=' + Email,
      'commit', '-q', '-m', Message]);
  if R.ExitCode <> 0 then
  begin
    Failure := 'git commit: ' + Trim(R.ErrorOutput);
    Exit;
  end;
  Result := True;
end;

end.
