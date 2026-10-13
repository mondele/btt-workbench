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
  Classes, SysUtils, WBReporter, WBUsfmChecks, WBVersification, TestUtil;

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

procedure TestAgainstVerifyUsfm;
var
  L, Ids: TStringList;
  Parts: TStringArray;
  I, Bad, Total: Integer;
  H: TCheckHit;
  C: TChunkTexts;
  Id, Got, Want: string;
begin
  L := TStringList.Create;
  Ids := TStringList.Create;
  try
    L.LoadFromFile(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + 'tests' + PathDelim +
      'fixtures' + PathDelim + 'verifyusfm-samples.tsv');
    Bad := 0;
    Total := 0;
    for I := 0 to L.Count - 1 do
    begin
      if (L[I] = '') or (L[I][1] = '#') then
        Continue;
      Parts := L[I].Split([#9]);
      C := nil;
      SetLength(C, 1);
      C[0] := Chunk(Parts[0], Parts[1], '\v ' + Parts[1] + ' ' + Parts[2]);
      Ids.Clear;
      for H in CheckChunks('GEN', C, [cgPunctuation, cgNumbers, cgQuotes]) do
      begin
        Id := CheckNumber(H.Id);
        if (Id <> '75') and (Id <> '56') and (Id <> '57') then
          Ids.Add(Id);
      end;
      Ids.Sort;
      Got := Ids.CommaText;
      Want := '';
      if Length(Parts) > 3 then
        Want := Parts[3];
      Inc(Total);
      if Got <> Want then
      begin
        Inc(Bad);
        WriteLn('    sample ', Parts[2], ': got [', Got, '] verifyUSFM [', Want, ']');
      end;
    end;
    Check((Total >= 60) and (Bad = 0), Format('punctuation and number checks match verifyUSFM on %d texts', [Total]));
  finally
    Ids.Free;
    L.Free;
  end;
end;

procedure TestStructure;
var
  Hits: string;
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
  Check(Has(Hits, '67 01-06 \zz') and Has(Hits, '9 01-06 1/0'), 'unknown marker, unpaired footnote');
  Check(Has(Hits, '73 01-07 \v7') and Has(Hits, '74 01-07 \v 8e') and
    Has(Hits, '72 01-07 t\v 9') and Has(Hits, 'txt2USFM 01-07 /v 10'),
    'malformed verse markers (\v7, \v 8e, text\v, /v)');
  Check(Has(Hits, '66 01-11 ') and Has(Hits, '1 1:11 '), 'verse marker without number; empty verse');
  Check(Pos('1:13', Hits) = 0, 'chunk with an unresolved conflict left out');
  Check(Has(Hits, '41 1 7,10,13,14,15,16'), 'missing verses listed per chapter');
  Check(Pos('Chapter 1', Hits) + Pos('Titus', Hits) = 0, 'titles not checked');

  Hits := HitList('MRK', [Chunk('07', '14', '\v 14 a \v 15 b \v 17 c')], [cgStructure]);
  Check(Has(Hits, '41 7 1,2,3,4,5,6,7,8,9,10,11,12,13,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37'),
    'optional verse (Mark 7:16) not reported missing');

  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 Иуда, раб. \v 2 Мир вам. \v 3 plain ascii \v 4 Ещё')], AllCheckGroups);
  Check(Has(Hits, '3 1:3 '), 'all-ASCII verse in a non-Latin text reported');
  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 Jude, a servant. \v 2 Peace. \v 3 Ñandú')], AllCheckGroups);
  Check(Pos('3 1:', Hits) = 0, 'all-ASCII verses not reported for a Latin-script text');
  Hits := HitList('JUD', [Chunk('01', '01', '\v 1 He said "go" and it''s "fine"')], [cgQuotes]);
  Check(Has(Hits, '75  4/0/1'), 'straight quotes counted, word-medial apostrophes apart');
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
      '\v ' + IntToStr(I) + ' Text ' + 'é.');

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

procedure TestTextChecks(const TempRoot: string);
begin
  Section('text checks (usfm-tools port)');
  TestAgainstVerifyUsfm;
  TestStructure;
  TestModule(TempRoot);
end;

end.
