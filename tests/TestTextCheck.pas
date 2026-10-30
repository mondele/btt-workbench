unit TestTextCheck;

{$mode objfpc}{$H+}
{$codepage utf8}

(* Tests for WBUsfmChecks and the text-check module. The punctuation and
   number checks are compared with what usfm-tools' verifyUSFM.py itself
   reports for the texts in tests/fixtures/verifyusfm-samples.tsv. *)

interface

procedure TestTextChecks(const TempRoot: string);

implementation

uses
  Classes, SysUtils, fpjson, jsonparser, WBReporter, WBUsfmChecks, WBVersification, WBSources,
  WBSectionTitles, WBSentences, WBPyText, WBRegExpr, WBQuoteMarks, TestUtil;

function Chunk(const Ch, Ck, Text: string): TChunkText;
begin
  Result.Chapter := Ch;
  Result.Chunk := Ck;
  Result.Text := Text;
end;

{ "number ref detail" lines of the hits, sorted. }
function HitList(const Book: string; const Chunks: array of TChunkText;
  Groups: TCheckGroups): string;
var
  C: TChunkTexts;
  H: TCheckHit;
  L: TStringList;
  I: Integer;
begin
  C := nil;
  SetLength(C, Length(Chunks));
  for I := 0 to High(Chunks) do
    C[I] := Chunks[I];
  L := TStringList.Create;
  try
    for H in CheckChunks(Book, C, Groups) do
      L.Add(CheckNumber(H.Id) + ' ' + H.Ref + ' ' + H.Detail);
    L.Sort;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function Has(const Hits, Line: string): Boolean;
begin
  Result := Pos(#10 + Line + #10, #10 + Hits) > 0;
end;

function FixturePath(const Name: string): string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'tests' + PathDelim +
    'fixtures' + PathDelim + Name;
end;

{ Check numbers, sorted, from one verse of text through the engine. }
function IdsFor(const Book, Chapter, Verse, Text: string; Groups: TCheckGroups;
  Source: TSourceChunking; const Skip: array of string): string;
var
  C: TChunkTexts;
  H: TCheckHit;
  Ids: TStringList;
  Id, X: string;
  Skipped: Boolean;
begin
  C := nil;
  SetLength(C, 1);
  C[0] := Chunk(Chapter, Verse, '\v ' + Verse + ' ' + Text);
  Ids := TStringList.Create;
  try
    for H in CheckChunks(Book, C, Groups, Source) do
    begin
      Id := CheckNumber(H.Id);
      Skipped := False;
      for X in Skip do
        if X = Id then
          Skipped := True;
      if not Skipped then
        Ids.Add(Id);
    end;
    Ids.Sort;
    Result := Ids.CommaText;
  finally
    Ids.Free;
  end;
end;

function SourceWith(const Chapter: string; Verse: Integer; const Text: string;
  Footnoted: Boolean): TSourceChunking;
begin
  Result := TSourceChunking.Create;
  SetLength(Result.Chunks, 1);
  Result.Chunks[0].Chapter := Chapter;
  Result.Chunks[0].Chunk := '01';
  Result.Chunks[0].Verses := [Verse];
  Result.Chunks[0].Texts := [Text];
  Result.Chunks[0].Notes := [Footnoted];
  Result.Chunks[0].NoteTexts := [''];
end;

{ Rows of a fixture: tab-separated fields, comments and blanks left out. }
procedure EachRow(const Name: string; out Rows: TStringList);
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  Rows := TStringList.Create;
  try
    L.LoadFromFile(FixturePath(Name));
    for I := 0 to L.Count - 1 do
      if (L[I] <> '') and (L[I][1] <> '#') then
        Rows.Add(L[I]);
  finally
    L.Free;
  end;
end;

procedure Compare(const What: string; Total, Bad, Least: Integer);
begin
  Check((Total >= Least) and (Bad = 0),
    Format('%s match verifyUSFM on %d cases (%d differ)', [What, Total, Bad]));
end;

{ reportUnmatched, reportPunctuation, period_re and reportNumbers on
  tests/fixtures/verifyusfm-samples.tsv. }
procedure TestAgainstVerifyUsfm;
var
  Rows: TStringList;
  P: TStringArray;
  I, Bad: Integer;
  Got, Want: string;
begin
  EachRow('verifyusfm-samples.tsv', Rows);
  try
    Bad := 0;
    for I := 0 to Rows.Count - 1 do
    begin
      P := Rows[I].Split([#9]);
      Want := '';
      if Length(P) > 3 then
        Want := P[3];
      Got := IdsFor('GEN', P[0], P[1], P[2], [cgPunctuation, cgNumbers, cgQuotes, cgBrackets],
        nil, ['75', '75.1']);
      if Got <> Want then
      begin
        Inc(Bad);
        WriteLn('    ', P[2], ' at ', P[0], ':', P[1], ': got [', Got, '] verifyUSFM [', Want, ']');
      end;
    end;
    Compare('punctuation, bracket and number checks', Rows.Count, Bad, 80);
  finally
    Rows.Free;
  end;
end;

{ reportFootnotes on tests/fixtures/verifyusfm-footnotes.tsv. }
procedure TestFootnotesAgainstVerifyUsfm;
var
  Rows: TStringList;
  P: TStringArray;
  I, Bad: Integer;
  Got, Want: string;
  Src: TSourceChunking;
begin
  EachRow('verifyusfm-footnotes.tsv', Rows);
  try
    Bad := 0;
    for I := 0 to Rows.Count - 1 do
    begin
      P := Rows[I].Split([#9]);
      Want := '';
      if Length(P) > 4 then
        Want := P[4];
      Src := SourceWith('01', 1, 'x', P[3] = 'source');
      try
        Got := IdsFor('MAT', P[0], P[1], P[2], [cgFootnotes], Src, []);
      finally
        Src.Free;
      end;
      if Got <> Want then
      begin
        Inc(Bad);
        WriteLn('    ', P[2], ' at ', P[0], ':', P[1], ' (', P[3], '): got [', Got,
          '] verifyUSFM [', Want, ']');
      end;
    end;
    Compare('footnote checks', Rows.Count, Bad, 180);
  finally
    Rows.Free;
  end;
end;

{ reportCaps and takeP, isMixed over listwords, and similarity on
  tests/fixtures/verifyusfm-sentences.tsv. }
procedure TestSentencesAgainstVerifyUsfm;
var
  Rows: TStringList;
  P: TStringArray;
  I, Bad: Integer;
  Got, Want: string;
  Src: TSourceChunking;
begin
  EachRow('verifyusfm-sentences.tsv', Rows);
  try
    Bad := 0;
    for I := 0 to Rows.Count - 1 do
    begin
      P := Rows[I].Split([#9]);
      Want := P[High(P)];
      if (P[0] = 'caps') and (Length(P) = 2) then
        Want := '';
      if P[0] = 'caps' then
        Got := IdsFor('GEN', '01', '1', P[1] + ' \p ', [cgCaps], nil, [])
      else if P[0] = 'mixed' then
        Got := BoolToStr(IdsFor('GEN', '01', '1', P[1], [cgWords], nil, []) <> '', 'True', 'False')
      else
      begin
        Src := SourceWith('01', 1, P[2], False);
        try
          Got := BoolToStr(Pos('3.5', IdsFor('GEN', '01', '1', P[1], [cgSource], Src, [])) > 0,
            'True', 'False');
        finally
          Src.Free;
        end;
      end;
      if Got <> Want then
      begin
        Inc(Bad);
        WriteLn('    ', P[0], ' ', P[1], ': got [', Got, '] verifyUSFM [', Want, ']');
      end;
    end;
    Compare('capitalisation, mixed case and similarity', Rows.Count, Bad, 29);
  finally
    Rows.Free;
  end;
end;

{ section_titles.py, sentences.py and usfm_utils.py functions on every
  string input of usfm-tools' tests (tests/fixtures/section-titles.jsonl). }
procedure TestSectionTitlesAgainstPython;
var
  L: TStringList;
  Row: TJSONData;
  I, J, Bad, Total: Integer;
  Fn, Got, Want: string;
  Input: UnicodeString;
  Words: TUnicodeWordList;
  Starts: TPositions;

  function B(V: Boolean): string;
  begin
    Result := BoolToStr(V, 'true', 'false');
  end;

  function F6(V: Double): string;
  begin
    Result := FormatFloat('0.000000', V);
  end;

begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FixturePath('section-titles.jsonl'));
    Bad := 0;
    Total := 0;
    for I := 1 to L.Count - 1 do
    begin
      if Trim(L[I]) = '' then
        Continue;
      Row := GetJSON(L[I]);
      try
        Fn := Row.Items[0].AsString;
        Input := UTF8Decode(Row.Items[1].AsString);
        case Row.Items[2].JSONType of
          jtBoolean: Want := B(Row.Items[2].AsBoolean);
          jtNumber:
            if (Fn = 'sentence_count') then
              Want := IntToStr(Row.Items[2].AsInteger)
            else
              Want := F6(Row.Items[2].AsFloat);
        else
          Want := Row.Items[2].AsString;
        end;
      finally
        Row.Free;
      end;
      if Fn = 'prob_heading' then
        Got := F6(ProbHeading(Input))
      else if Fn = 'find_eol_heading' then
        Got := UTF8Encode(FindEolHeading(Input, 0.100))
      else if Fn = 'find_parenthesized_heading' then
        Got := UTF8Encode(FindParenthesizedHeading(Input, 0.249))
      else if Fn = 'percent_title_or_caps' then
        Got := F6(PercentTitleOrCaps(Input))
      else if Fn = 'disqualified' then
        Continue    // internal; covered through prob_heading
      else if Fn = 'ends_sentence' then
        Got := UTF8Encode(EndsSentence(Input))
      else if Fn = 'ends_sentence_quotes' then
        Got := UTF8Encode(EndsSentence(Input, True))
      else if Fn = 'first_word' then
        Got := UTF8Encode(FirstWord(Input))
      else if Fn = 'last_word' then
        Got := UTF8Encode(LastWord(Input))
      else if Fn = 'sentence_count' then
        Got := IntToStr(SentenceCount(Input))
      else if Fn = 'next_first_words' then
      begin
        Words := NextFirstWords(Input);
        Got := '';
        for J := 0 to High(Words) do
        begin
          if J > 0 then
            Got := Got + '|';
          Got := Got + UTF8Encode(Words[J]);
        end;
      end
      else if Fn = 'start_positions' then
      begin
        Starts := StartPositions(Input);
        Got := '';
        for J := 0 to High(Starts) do
        begin
          if J > 0 then
            Got := Got + ',';
          Got := Got + IntToStr(Starts[J]);
        end;
      end
      else if Fn = 'is_capitalized' then
        Got := B(IsCapitalized(Input))
      else if Fn = 'is_caseless' then
        Got := B(IsCaseless(Input))
      else if Fn = 'unicode_block' then
        Got := UnicodeBlockOf(Input)
      else
        Continue;
      Inc(Total);
      if Got <> Want then
      begin
        Inc(Bad);
        if Bad <= 40 then
          WriteLn('    ', Fn, '(', StringReplace(UTF8Encode(Input), #10, '\n', [rfReplaceAll]),
            '): got [', Got, '] Python [', Want, ']');
      end;
    end;
    Check((Total >= 2500) and (Bad = 0),
      Format('sentences, section titles and isCaseless match usfm-tools on %d cases (%d differ)', [Total, Bad]));
  finally
    L.Free;
  end;
end;

{ usfmReader, Token, parseLine and verifyUSFM helpers on every input of
  usfm-tools' own tests (tests/fixtures/usfm-tools-units.jsonl). }
procedure TestUnitsAgainstUsfmTools;
var
  L: TStringList;
  Row, R: TJSONData;
  I, J, N, Bad, Total: Integer;
  Fn, Got, Want: string;
  Input: UnicodeString;
  Marks: TMarkerPositions;
  Toks: TTokens;
  Words: TUnicodeWords;
  M, V, Rest: UnicodeString;
  Flag: Char;
  Sim: Double;

  { Lists as "a|b|c", pairs as "a=b". }
  function JoinJson(D: TJSONData): string;
  var
    K: Integer;
  begin
    case D.JSONType of
      jtNull: Result := '<none>';
      jtBoolean: Result := BoolToStr(D.AsBoolean, 'true', 'false');
      jtArray:
        begin
          Result := '';
          for K := 0 to D.Count - 1 do
          begin
            if K > 0 then
              Result := Result + '|';
            Result := Result + JoinJson(D.Items[K]);
          end;
          Result := '[' + Result + ']';
        end;
    else
      Result := D.AsString;
    end;
  end;

  function B(X: Boolean): string;
  begin
    Result := BoolToStr(X, 'true', 'false');
  end;

begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FixturePath('usfm-tools-units.jsonl'));
    Bad := 0;
    Total := 0;
    for I := 1 to L.Count - 1 do
    begin
      if Trim(L[I]) = '' then
        Continue;
      Row := GetJSON(L[I]);
      try
        Fn := Row.Items[0].AsString;
        Input := UTF8Decode(Row.Items[1].AsString);
        R := Row.Items[Row.Count - 1];
        Want := JoinJson(R);
        Got := '';
        if Fn = 'list_usfm' then
        begin
          Marks := ListUsfm(Input);
          for J := 0 to High(Marks) do
          begin
            if J > 0 then
              Got := Got + '|';
            Got := Got + '[' + UTF8Encode(Marks[J].Name) + '|' + IntToStr(Marks[J].Start - 1) + ']';
          end;
          Got := '[' + Got + ']';
        end
        else if (Fn = 'nextpair') or (Fn = 'parseString') then
        begin
          if Fn = 'nextpair' then
            Toks := NextPairs(Input)
          else
            Toks := Tokenize(Input);
          for J := 0 to High(Toks) do
          begin
            if J > 0 then
              Got := Got + '|';
            Got := Got + '[' + UTF8Encode(Toks[J].Kind) + '|' + UTF8Encode(Toks[J].Value) + ']';
          end;
          Got := '[' + Got + ']';
        end
        else if Fn = 'token_kinds' then
          Got := '[' + B(IsFootnoteMarker(Input)) + '|' + B(IsFootnoteInteriorMarker(Input)) + '|' +
            B(IsPoetryMarker(Input)) + ']'
        else if Fn = 'parseLine' then
        begin
          ParseLine(Input, M, V, Rest);
          Got := '[' + UTF8Encode(M) + '|' + UTF8Encode(V) + '|' + UTF8Encode(Rest) + ']';
        end
        else if Fn = 'findFootnote' then
        begin
          Flag := FindFootnote(Input);
          if Flag = #0 then
            Got := '<none>'
          else
            Got := Flag;
        end
        else if Fn = 'validBracketedFootnote' then
          Got := B(ValidBracketedFootnote(Input))
        else if Fn = 'isMixed' then
          Got := B(IsMixed(Input))
        else if Fn = 'listwords' then
        begin
          Words := ListWords(Input);
          for J := 0 to High(Words) do
          begin
            if J > 0 then
              Got := Got + '|';
            Got := Got + UTF8Encode(Words[J]);
          end;
          Got := '[' + Got + ']';
        end
        else if Fn = 'context' then
          Got := UTF8Encode(Context(Input, Row.Items[2].AsInteger, Row.Items[3].AsInteger))
        else if Fn = 'similarity' then
        begin
          Sim := Similarity(Input, UTF8Decode(Row.Items[2].AsString), N);
          Got := FormatFloat('0.######', Sim) + ' ' + IntToStr(N);
          Want := FormatFloat('0.######', R.Items[0].AsFloat) + ' ' + IntToStr(R.Items[1].AsInteger);
        end
        else
          Continue;
      finally
        Row.Free;
      end;
      Inc(Total);
      if Got <> Want then
      begin
        Inc(Bad);
        WriteLn('    ', Fn, '(', StringReplace(UTF8Encode(Input), #10, '\n', [rfReplaceAll]),
          '): got ', Got, ' usfm-tools ', Want);
      end;
    end;
    Check((Total >= 340) and (Bad = 0),
      Format('tokenizer, parseLine and verifyUSFM helpers match usfm-tools on %d cases (%d differ)',
      [Total, Bad]));
  finally
    L.Free;
  end;
end;

{ test_State_versebridges: references name the whole bridge. }
procedure TestVerseBridges;
var
  Hits: string;
begin
  Hits := HitList('MAT', [Chunk('01', '01', '\c 1 \v 1-3 Text,with a comma.'),
    Chunk('02', '20', '\c 2 \v 20-25 More,text.')], [cgPunctuation]);
  Check(Has(Hits, '45 1:1-3 ,w') and Has(Hits, '45 2:20-25 ,t'),
    'verse bridges: references name the whole bridge (test_State_versebridges)');
end;

procedure TestStructure;
var
  Hits, Hits3jn, HitsBridge: string;
begin
  Check((ChapterCount('mat') = 28) and (VerseCount('MAT', 1) = 25) and (VerseCount('MAT', 29) = 0) and
    IsOptionalVerse('mrk', 7, 16) and IsShortVerse('JHN', 11, 35) and (EnglishBookName('3jn') = '3 John'),
    'versification table');

  Hits := HitList('TIT', [
    Chunk('01', '01', '\c 1 \v 1 Paul, a servant. \v 2 In hope.'),
    Chunk('01', '03', '\v 4 Four. \v 3 Three. \v 3 again'),
    Chunk('01', '05', 'Loose text \v 5 Five \v 99 too far'),
    Chunk('01', '06', '\v 6 Six \zz odd \f + \ft note'),
    Chunk('01', '07', '\v7 seven \v 8eight text\v 9 nine /v 10 ten'),
    Chunk('01', '11', '\v 11 \v 12 twelve \v'),
    Chunk('01', '13', '<<<<<<< HEAD'#10'\v 13 a'#10'======='#10'\v 13 b'#10'>>>>>>> abc'#10),
    Chunk('01', 'title', 'Chapter 1'), Chunk('front', 'title', 'Titus')], AllCheckGroups);
  Check(Has(Hits, '39 1:3 ') and Has(Hits, '40 1:3 '), 'verse out of order and given twice');
  Check(Has(Hits, '54 01-05 Loose text'), 'text before the first verse marker');
  Check(Has(Hits, '8 1:99 16'), 'verse past the end of the chapter');
  Check((MaxVerseCount('3jn', 1) = 15) and (MaxVerseCount('REV', 12) = 18) and (MaxVerseCount('TIT', 1) = 16),
    'chapter ends numbered differently');
  Hits3jn := HitList('3JN', [
    Chunk('01', '01', '\c 1 \v 1 One. \v 2 Two. \v 3 Three. \v 4 Four.'),
    Chunk('01', '05', '\v 5 Five. \v 6 Six. \v 7 Seven. \v 8 Eight.'),
    Chunk('01', '09', '\v 9 Nine. \v 10 Ten.'), Chunk('01', '11', '\v 11 Eleven. \v 12 Twelve.'),
    Chunk('01', '13', '\v 13 Thirteen. \v 14 Fourteen. \v 15 Fifteen. \v 16 Sixteen.')], AllCheckGroups);
  Check(not Has(Hits3jn, '8 1:15 ') and Has(Hits3jn, '8 1:16 14') and not Has(Hits3jn, '41 '),
    '3 John 1:15 is not past the end of the chapter; 1:16 is');
  HitsBridge := HitList('3JN', [
    Chunk('01', '01', '\c 1 \v 1 One. \v 2-4 Two to four.'),
    Chunk('01', '05', '\v 5-8 Five to eight. \v 7 Seven again.')], AllCheckGroups);
  Check(not Has(HitsBridge, '39 1:2-4 ') and Has(HitsBridge, '39 1:5-8 '),
    'a bridge of three or more verses is in order; a verse going back after one is not');
  Check(Has(Hits, '53 1:6 \zz') and Has(Hits, '9  1/0') and Has(Hits, '78 1:6 \f'),
    'unsupported marker, unpaired footnote, space before a footnote');
  Check(Has(Hits, '73 01-07 \v7') and Has(Hits, '74 01-07 \v 8e') and
    Has(Hits, 'txt2USFM 01-07 /v 10') and Has(Hits, '35 1:6 '),
    'malformed verse markers (\v7, \v 8e, /v); \v without a number');
  Check(Has(Hits, '35 1:12 ') and Has(Hits, '1 1:11 '), 'verse marker without number; empty verse');
  { The unclosed \f in 01-06 keeps the rest of the book in a footnote, so
    later verses count as empty or short, as in verifyUSFM. }
  Check(Has(Hits, '1 1:9 '), 'text after an unclosed footnote is footnote text');
  Check(Pos('1:13', Hits) = 0, 'chunk with an unresolved conflict left out');
  Check(Has(Hits, '41 1 7,8,10,13,14,15,16'), 'missing verses listed per chapter (\v 8eight is no verse 8)');
  Check(Pos('Chapter 1', Hits) + Pos('Titus', Hits) = 0, 'titles not checked');

  Hits := HitList('MRK', [Chunk('07', '14', '\v 14 a \v 15 b \v 17 c')], [cgStructure]);
  Check(Has(Hits, '41 7 1,2,3,4,5,6,7,8,9,10,11,12,13,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37'),
    'optional verse (Mark 7:16) not reported missing');

  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 Иуда, раб. \v 2 Мир вам. \v 3 plain ascii \v 4 Ещё')], AllCheckGroups);
  Check(Has(Hits, '3 1:3 '), 'all-ASCII verse in a non-Latin text reported');
  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 Jude, a servant.'), Chunk('01', '02', '\v 2 Peace to you all.'),
    Chunk('01', '03', '\v 3 Ñandú is here.')], AllCheckGroups);
  Check(Pos(#10'3 1:', #10 + Hits) = 0,
    'all-ASCII verses not reported when over 2% of the lines are ASCII (Latin script)');
  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 He said "go" and it''s "fine"')], [cgQuotes]);
  Check(Has(Hits, '75  4/0/1'), 'straight quotes counted, word-medial apostrophes apart');
  Hits := HitList('JHN', [
    Chunk('10', '01', '\v 1 Truly, I tell you, the sheep follow him.'#10'The Good Shepherd'#10'\v 2 He calls them by name.'),
    Chunk('10', '03', '\v 3 They know his voice. Jesus Heals A Blind Man'),
    Chunk('10', '04', '\v 4 He goes ahead of them, and they follow.')], [cgHeadings]);
  Check(Has(Hits, '76 10:1 The Good Shepherd') and (Pos('10:3', Hits) = 0) and (Pos('10:4', Hits) = 0),
    'possible section title on a line of its own; none at the end of a verse without source sections');
  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 Text, 12345 here')], AllCheckGroups - [cgNumbers]);
  Check(Pos('61 ', Hits) = 0, 'a skipped group is not checked');
end;

procedure TestModule(const TempRoot: string);
var
  Target, Output: string;
  R: TWBListReporter;
  I: Integer;

  procedure Put(const Path, Text: string);
  begin
    ForceDirectories(ExtractFileDir(Path));
    WriteFileText(Path, Text);
  end;

  function Run(const Args: array of string): Integer;
  var
    All: array of string;
    J: Integer;
  begin
    All := ['--target-dir', Target];
    SetLength(All, 2 + Length(Args));
    for J := 0 to High(Args) do
      All[2 + J] := Args[J];
    Result := RunModule('text-check', All, R);
    Output := '';
    for J := 0 to R.Count - 1 do
      Output := Output + LevelName(R.Levels[J]) + ': ' + R.Texts[J] + #10;
    R.Free;
  end;

begin
  Target := TempRoot + 'textcheck' + PathDelim + 'targetTranslations' + PathDelim;
  Put(Target + 'aaa_jud_text_reg' + PathDelim + 'manifest.json',
    '{"target_language": {"id": "aaa", "name": "Aaa"}, "project": {"id": "jud"}, "type": {"id": "text"}, "resource": {"id": "reg"}}');
  Put(Target + 'aaa_jud_text_reg' + PathDelim + '01' + PathDelim + '01.txt', '\c 1 \v 1 Jude,a servant 12345.');
  Put(Target + 'bbb_jud_tn' + PathDelim + 'manifest.json',
    '{"target_language": {"id": "bbb"}, "project": {"id": "jud"}, "type": {"id": "tn"}}');
  Put(Target + 'ccc_xyz_text_reg' + PathDelim + 'manifest.json',
    '{"target_language": {"id": "ccc"}, "project": {"id": "xyz"}, "type": {"id": "text"}}');
  Put(Target + 'ddd_jud_text_reg' + PathDelim + 'manifest.json',
    '{"target_language": {"id": "ddd"}, "project": {"id": "jud"}, "type": {"id": "text"}}');
  for I := 1 to 25 do
    Put(Target + 'ddd_jud_text_reg' + PathDelim + '01' + PathDelim + Format('%.2d.txt', [I]),
      '\v ' + IntToStr(I) + ' Text of this verse é.');

  Check(Run([]) = 0, 'text-check runs');
  Check(Pos('info: aaa_jud_text_reg: Aaa (aaa), Jude - ', Output) > 0, 'project header with the English book name');
  Check(Pos('warning: Check the punctuation: 1:1 ",a" [45]', Output) > 0, 'finding with reference, text and check number');
  Check(Pos('Long number without separators: 1:1 "12345" [61]', Output) > 0, 'number finding');
  Check(Pos('Verses missing from chapter 1: 2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25 [41]', Output) > 0,
    'missing verses');
  Check(Pos('bbb_jud_tn', Output) = 0, 'non-text projects left out');
  Check(Pos('ccc_xyz_text_reg: book "xyz" is not one of the 66 books', Output) > 0, 'unknown book reported');
  Check(Pos('info: ddd_jud_text_reg: ddd (ddd), Jude - 0 finding(s)', Output) > 0,
    'clean project listed (language code when the manifest has no name)');
  Check(Pos('2 project(s) checked, 1 with findings.', Output) > 0, 'summary');

  Run(['--problems-only', '--skip', 'numbers']);
  Check((Pos('ddd_jud', Output) = 0) and (Pos('[61]', Output) = 0) and (Pos('[45]', Output) > 0),
    '--problems-only and --skip');
  Check((Run(['--skip', 'spelling']) = 1) and (Pos('Unknown check group "spelling"', Output) > 0),
    'unknown --skip group refused');
end;

{ A source for chapter 1 of a book: one chunk per verse, Texts[I] being
  verse I + 1. }
function SourceOf(const Container: string; const Texts: array of string): TSourceChunking;
var
  I: Integer;
begin
  Result := TSourceChunking.Create;
  Result.Container := Container;
  SetLength(Result.Chunks, Length(Texts));
  for I := 0 to High(Texts) do
  begin
    Result.Chunks[I].Chapter := '01';
    Result.Chunks[I].Chunk := Format('%.2d', [I + 1]);
    Result.Chunks[I].Verses := [I + 1];
    Result.Chunks[I].Texts := [Texts[I]];
    Result.Chunks[I].Notes := [False];
    Result.Chunks[I].NoteTexts := [''];
  end;
end;

{ "number ref detail" lines of the hits, sorted, with a source. }
function HitListWith(const Book: string; const Chunks: array of TChunkText;
  Groups: TCheckGroups; Source: TSourceChunking): string;
var
  C: TChunkTexts;
  H: TCheckHit;
  L: TStringList;
  I: Integer;
begin
  C := nil;
  SetLength(C, Length(Chunks));
  for I := 0 to High(Chunks) do
    C[I] := Chunks[I];
  L := TStringList.Create;
  try
    for H in CheckChunks(Book, C, Groups, Source) do
      L.Add(CheckNumber(H.Id) + ' ' + H.Ref + ' ' + H.Detail);
    L.Sort;
    Result := L.Text;
  finally
    L.Free;
  end;
end;

{ Workbench's own quote checks (WBQuoteMarks), and check 50 against the
  source verse. }
procedure TestQuoteMarks;
var
  P: TQuoteProfile;
  Q: UnicodeString;
  Hits: string;
  Src: TSourceChunking;
  Here: array of TChunkText;
  SrcTexts: array of string;
  I: Integer;
begin
  P := Default(TQuoteProfile);
  AddQuoteProfile(P, UTF8Decode('He said, “Go.” She said «Come» and „Ja“ and ''''Yes'''' and "No".'));
  Check((P.Marks[qsCurly] = 2) and (P.Marks[qsLow] = 2) and (P.Marks[qsGuillemet] = 2) and
    (P.Marks[qsDoubledApostrophe] = 2) and (P.Marks[qsStraight] = 2) and (P.Marks[qsCorner] = 0),
    'quote profile: marks of each style („…“ closers are not curly quotes)');
  Check((P.PunctBefore = 1) and (P.PunctAfter = 1) and (P.Tight = 2) and (P.Spaced = 0),
    'quote profile: punctuation before/after the closing quote, guillemet spacing');
  P := Default(TQuoteProfile);
  AddQuoteProfile(P, UTF8Decode('« a » « b » «c» “d” "e" "f"'));
  Check((P.Spaced = 4) and (P.Tight = 2) and (MainQuoteStyle(P) = qsGuillemet) and
    (DescribeQuoteStyles(P) = '«…» 50%, "…" 33%, “…” 17%') and (Percent(1, 3) = 33) and (Percent(2, 3) = 67),
    'quote profile: main style and shares');
  Check((UnpairedQuotes(UTF8Decode('“a” “b'), False) = '“×2 ”×1') and
    (UnpairedQuotes(UTF8Decode('„a“ „b”'), True) = '') and
    (UnpairedQuotes(UTF8Decode('"a" "b ''''c'''' ''''d'), False) = '"×3 ''''×3') and
    (UnpairedQuotes(UTF8Decode('«a» 「b」'), False) = ''),
    'quote marks that do not pair up');
  Check(FloatingQuote(UTF8Decode('He said „ go'), Q) and (UTF8Encode(Q) = 'id „ go') and
    FloatingQuote(UTF8Decode('「 x'), Q) and not FloatingQuote(UTF8Decode('„go“'), Q) and
    not FloatingQuote(UTF8Decode('„'), Q),
    'free-floating quote marks verifyUSFM leaves out');
  Check(WithoutFootnotes('a \f + \ft "x" \f* b \fe + \ft y\fe* c') = 'a  b  c', 'footnotes left out of the profile');

  { 50: verses whose source verse has the same are counted, not listed }
  Src := SourceOf('pt-br_jud_ulb', ['Ele disse: "Vai".', 'Ele disse: Venha.']);
  try
    Hits := HitListWith('JUD', [Chunk('01', '01', '\c 1 \v 1 He said: "Go". \v 2 He said: "Come".')],
      [cgPunctuation], Src);
  finally
    Src.Free;
  end;
  Check(Has(Hits, '50 1:2 ".') and not Has(Hits, '50 1:1 ".') and Has(Hits, '50  1'#9'pt-br_jud_ulb'),
    'punctuation after the closing quote: left out where the source verse has it too');
  Hits := HitList('JUD', [Chunk('01', '01', '\c 1 \v 1 He said: "Go".')], [cgPunctuation]);
  Check(Has(Hits, '50 1:1 ".'), 'punctuation after the closing quote: every one without a source');

  { quote style, punctuation and pairs against the source }
  Here := nil;
  SrcTexts := nil;
  for I := 1 to 12 do
  begin
    Here := Concat(Here, [Chunk('01', Format('%.2d', [I]),
      '\v ' + IntToStr(I) + ' He said, ''''Go''''.')]);
    SrcTexts := Concat(SrcTexts, ['Ele disse, “Vai.”']);
  end;
  Src := SourceOf('pt-br_jud_ulb', SrcTexts);
  try
    Hits := HitListWith('JUD', Here, [cgQuoteMarks], Src);
  finally
    Src.Free;
  end;
  Check(Has(Hits, 'quote-style  ''''…'''' 100%'#9'“…” 100%'#9'pt-br_jud_ulb'),
    'quote style unlike the source''s');
  Check(Has(Hits, 'quote-punctuation  12/12'#9'0/12'#9'pt-br_jud_ulb'),
    'punctuation after the closing quote where the source has it before');
  Check(Pos('quote-pairs', Hits) = 0, 'balanced chapter: no quote-pairs');

  Here := Concat(Here, [Chunk('01', '13', '\v 13 And “more.')]);
  Hits := HitList('JUD', Here, [cgQuoteMarks]);
  Check(Has(Hits, 'quote-pairs 1 “×1 ”×0') and (Pos('quote-style', Hits) = 0),
    'quote marks that do not pair up in a chapter; 96% one style is not mixed');
  SrcTexts := nil;
  for I := 1 to 13 do
    SrcTexts := Concat(SrcTexts, ['“Fala']);
  Src := SourceOf('pt-br_jud_ulb', SrcTexts);
  try
    Hits := HitListWith('JUD', Here, [cgQuoteMarks], Src);
  finally
    Src.Free;
  end;
  Check(Pos('quote-pairs', Hits) = 0, 'no quote-pairs where the source''s marks do not pair up either');

  Hits := HitList('JUD', [Chunk('01', '01', '\c 1 \v 1 He said „ go')], AllCheckGroups - [cgQuoteMarks]);
  Check(Pos('floating-quote', Hits) = 0, '--skip quote-marks turns them off');
end;

{ {m,n} after a single character or class: FPC 3.2.2's regexpr read the
  counts from the wrong place on aarch64, so a{3} matched like a{0,...}. }
procedure TestRegExprBraces;
begin
  Check(not ExecRegExpr('a{3}', 'xab') and not ExecRegExpr('[a]{3}', 'xab') and
    not ExecRegExpr('\d{3}', '12x'), 'regex: x{3} needs three');
  Check(ReplaceRegExpr('={7}\n', 'a'#10'======='#10'b', '<M>', False) = 'a'#10'<M>b',
    'regex: ={7}\n replaces only the marker line');
  Check(ExecRegExpr('^a{2,3}$', 'aaa') and not ExecRegExpr('^a{2,3}$', 'aaaa'),
    'regex: x{2,3} keeps its bounds');
end;

procedure TestTextChecks(const TempRoot: string);
begin
  Section('text checks (usfm-tools port)');
  TestRegExprBraces;
  TestAgainstVerifyUsfm;
  TestSentencesAgainstVerifyUsfm;
  TestSectionTitlesAgainstPython;
  TestFootnotesAgainstVerifyUsfm;
  TestUnitsAgainstUsfmTools;
  TestVerseBridges;
  TestStructure;
  TestQuoteMarks;
  TestModule(TempRoot);
end;

end.
