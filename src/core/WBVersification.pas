unit WBVersification;

{$mode objfpc}{$H+}

{ Chapter and verse counts of the 66 books, and the verses that are
  optional (absent from some manuscripts) or legitimately very short.
  Generated from usfm-tools' usfm_verses.py (Larry Versaw, Wycliffe
  Associates), which verifyUSFM.py checks against; regenerate rather than
  edit by hand. }

interface

type
  TBookInfo = record
    Code, Name: string;   // USFM code (upper case), English name
    Chapters: Integer;
    Verses: string;       // verses per chapter, comma-separated
  end;

{ -1 if the code (any case) is not one of the 66 books. }
function BookIndex(const Code: string): Integer;
function ChapterCount(const Code: string): Integer;
{ 0 for an unknown book or chapter. }
function VerseCount(const Code: string; Chapter: Integer): Integer;
function EnglishBookName(const Code: string): string;
{ Reference as "MAT 17:21". }
function IsOptionalVerse(const Code: string; Chapter, Verse: Integer): Boolean;
function IsShortVerse(const Code: string; Chapter, Verse: Integer): Boolean;

implementation

uses
  SysUtils;

const
  BookCount = 66;
  Books: array[0..BookCount - 1] of TBookInfo = (
    (Code: 'GEN'; Name: 'Genesis'; Chapters: 50; Verses: '31,25,24,26,32,22,24,22,29,32,32,20,18,24,21,16,27,33,38,18,34,24,20,67,34,35,46,22,35,43,55,32,20,31,29,43,36,30,23,23,57,38,34,34,28,34,31,22,33,26'),
    (Code: 'EXO'; Name: 'Exodus'; Chapters: 40; Verses: '22,25,22,31,23,30,25,32,35,29,10,51,22,31,27,36,16,27,25,26,36,31,33,18,40,37,21,43,46,38,18,35,23,35,35,38,29,31,43,38'),
    (Code: 'LEV'; Name: 'Leviticus'; Chapters: 27; Verses: '17,16,17,35,19,30,38,36,24,20,47,8,59,57,33,34,16,30,37,27,24,33,44,23,55,46,34'),
    (Code: 'NUM'; Name: 'Numbers'; Chapters: 36; Verses: '54,34,51,49,31,27,89,26,23,36,35,16,33,45,41,50,13,32,22,29,35,41,30,25,18,65,23,31,40,16,54,42,56,29,34,13'),
    (Code: 'DEU'; Name: 'Deuteronomy'; Chapters: 34; Verses: '46,37,29,49,33,25,26,20,29,22,32,32,18,29,23,22,20,22,21,20,23,30,25,22,19,19,26,68,29,20,30,52,29,12'),
    (Code: 'JOS'; Name: 'Joshua'; Chapters: 24; Verses: '18,24,17,24,15,27,26,35,27,43,23,24,33,15,63,10,18,28,51,9,45,34,16,33'),
    (Code: 'JDG'; Name: 'Judges'; Chapters: 21; Verses: '36,23,31,24,31,40,25,35,57,18,40,15,25,20,20,31,13,31,30,48,25'),
    (Code: 'RUT'; Name: 'Ruth'; Chapters: 4; Verses: '22,23,18,22'),
    (Code: '1SA'; Name: '1 Samuel'; Chapters: 31; Verses: '28,36,21,22,12,21,17,22,27,27,15,25,23,52,35,23,58,30,24,42,15,23,29,22,44,25,12,25,11,31,13'),
    (Code: '2SA'; Name: '2 Samuel'; Chapters: 24; Verses: '27,32,39,12,25,23,29,18,13,19,27,31,39,33,37,23,29,33,43,26,22,51,39,25'),
    (Code: '1KI'; Name: '1 Kings'; Chapters: 22; Verses: '53,46,28,34,18,38,51,66,28,29,43,33,34,31,34,34,24,46,21,43,29,53'),
    (Code: '2KI'; Name: '2 Kings'; Chapters: 25; Verses: '18,25,27,44,27,33,20,29,37,36,21,21,25,29,38,20,41,37,37,21,26,20,37,20,30'),
    (Code: '1CH'; Name: '1 Chronicles'; Chapters: 29; Verses: '54,55,24,43,26,81,40,40,44,14,47,40,14,17,29,43,27,17,19,8,30,19,32,31,31,32,34,21,30'),
    (Code: '2CH'; Name: '2 Chronicles'; Chapters: 36; Verses: '17,18,17,22,14,42,22,18,31,19,23,16,22,15,19,14,19,34,11,37,20,12,21,27,28,23,9,27,36,27,21,33,25,33,27,23'),
    (Code: 'EZR'; Name: 'Ezra'; Chapters: 10; Verses: '11,70,13,24,17,22,28,36,15,44'),
    (Code: 'NEH'; Name: 'Nehemiah'; Chapters: 13; Verses: '11,20,32,23,19,19,73,18,38,39,36,47,31'),
    (Code: 'EST'; Name: 'Esther'; Chapters: 10; Verses: '22,23,15,17,14,14,10,17,32,3'),
    (Code: 'JOB'; Name: 'Job'; Chapters: 42; Verses: '22,13,26,21,27,30,21,22,35,22,20,25,28,22,35,22,16,21,29,29,34,30,17,25,6,14,23,28,25,31,40,22,33,37,16,33,24,41,30,24,34,17'),
    (Code: 'PSA'; Name: 'Psalms'; Chapters: 150; Verses: '6,12,8,8,12,10,17,9,20,18,7,8,6,7,5,11,15,50,14,9,13,31,6,10,22,12,14,9,11,12,24,11,22,22,28,12,40,22,13,17,13,11,5,26,17,11,9,14,20,23,19,9,6,7,23,13,11,11,17,12,8,12,11,10,13,20,7,35,36,5,24,20,28,23,10,12,20,72,13,19,16,8,18,12,13,17,7,18,52,17,16,15,5,23,11,13,12,9,9,5,8,28,22,35,45,48,43,13,31,7,10,10,9,8,18,19,2,29,176,7,8,9,4,8,5,6,5,6,8,8,3,18,3,3,21,26,9,8,24,13,10,7,12,15,21,10,20,14,9,6'),
    (Code: 'PRO'; Name: 'Proverbs'; Chapters: 31; Verses: '33,22,35,27,23,35,27,36,18,32,31,28,25,35,33,33,28,24,29,30,31,29,35,34,28,28,27,28,27,33,31'),
    (Code: 'ECC'; Name: 'Ecclesiastes'; Chapters: 12; Verses: '18,26,22,16,20,12,29,17,18,20,10,14'),
    (Code: 'SNG'; Name: 'Song of Songs'; Chapters: 8; Verses: '17,17,11,16,16,13,13,14'),
    (Code: 'ISA'; Name: 'Isaiah'; Chapters: 66; Verses: '31,22,26,6,30,13,25,22,21,34,16,6,22,32,9,14,14,7,25,6,17,25,18,23,12,21,13,29,24,33,9,20,24,17,10,22,38,22,8,31,29,25,28,28,25,13,15,22,26,11,23,15,12,17,13,12,21,14,21,22,11,12,19,12,25,24'),
    (Code: 'JER'; Name: 'Jeremiah'; Chapters: 52; Verses: '19,37,25,31,31,30,34,22,26,25,23,17,27,22,21,21,27,23,15,18,14,30,40,10,38,24,22,17,32,24,40,44,26,22,19,32,21,28,18,16,18,22,13,30,5,28,7,47,39,46,64,34'),
    (Code: 'LAM'; Name: 'Lamentations'; Chapters: 5; Verses: '22,22,66,22,22'),
    (Code: 'EZK'; Name: 'Ezekiel'; Chapters: 48; Verses: '28,10,27,17,17,14,27,18,11,22,25,28,23,23,8,63,24,32,14,49,32,31,49,27,17,21,36,26,21,26,18,32,33,31,15,38,28,23,29,49,26,20,27,31,25,24,23,35'),
    (Code: 'DAN'; Name: 'Daniel'; Chapters: 12; Verses: '21,49,30,37,31,28,28,27,27,21,45,13'),
    (Code: 'HOS'; Name: 'Hosea'; Chapters: 14; Verses: '11,23,5,19,15,11,16,14,17,15,12,14,16,9'),
    (Code: 'JOL'; Name: 'Joel'; Chapters: 3; Verses: '20,32,21'),
    (Code: 'AMO'; Name: 'Amos'; Chapters: 9; Verses: '15,16,15,13,27,14,17,14,15'),
    (Code: 'OBA'; Name: 'Obadiah'; Chapters: 1; Verses: '21'),
    (Code: 'JON'; Name: 'Jonah'; Chapters: 4; Verses: '17,10,10,11'),
    (Code: 'MIC'; Name: 'Micah'; Chapters: 7; Verses: '16,13,12,13,15,16,20'),
    (Code: 'NAM'; Name: 'Nahum'; Chapters: 3; Verses: '15,13,19'),
    (Code: 'HAB'; Name: 'Habakkuk'; Chapters: 3; Verses: '17,20,19'),
    (Code: 'ZEP'; Name: 'Zephaniah'; Chapters: 3; Verses: '18,15,20'),
    (Code: 'HAG'; Name: 'Haggai'; Chapters: 2; Verses: '15,23'),
    (Code: 'ZEC'; Name: 'Zechariah'; Chapters: 14; Verses: '21,13,10,14,11,15,14,23,17,12,17,14,9,21'),
    (Code: 'MAL'; Name: 'Malachi'; Chapters: 4; Verses: '14,17,18,6'),
    (Code: 'MAT'; Name: 'Matthew'; Chapters: 28; Verses: '25,23,17,25,48,34,29,34,38,42,30,50,58,36,39,28,27,35,30,34,46,46,39,51,46,75,66,20'),
    (Code: 'MRK'; Name: 'Mark'; Chapters: 16; Verses: '45,28,35,41,43,56,37,38,50,52,33,44,37,72,47,20'),
    (Code: 'LUK'; Name: 'Luke'; Chapters: 24; Verses: '80,52,38,44,39,49,50,56,62,42,54,59,35,35,32,31,37,43,48,47,38,71,56,53'),
    (Code: 'JHN'; Name: 'John'; Chapters: 21; Verses: '51,25,36,54,47,71,53,59,41,42,57,50,38,31,27,33,26,40,42,31,25'),
    (Code: 'ACT'; Name: 'Acts'; Chapters: 28; Verses: '26,47,26,37,42,15,60,40,43,48,30,25,52,28,41,40,34,28,41,38,40,30,35,27,27,32,44,31'),
    (Code: 'ROM'; Name: 'Romans'; Chapters: 16; Verses: '32,29,31,25,21,23,25,39,33,21,36,21,14,23,33,27'),
    (Code: '1CO'; Name: '1 Corinthians'; Chapters: 16; Verses: '31,16,23,21,13,20,40,13,27,33,34,31,13,40,58,24'),
    (Code: '2CO'; Name: '2 Corinthians'; Chapters: 13; Verses: '24,17,18,18,21,18,16,24,15,18,33,21,14'),
    (Code: 'GAL'; Name: 'Galatians'; Chapters: 6; Verses: '24,21,29,31,26,18'),
    (Code: 'EPH'; Name: 'Ephesians'; Chapters: 6; Verses: '23,22,21,32,33,24'),
    (Code: 'PHP'; Name: 'Philippians'; Chapters: 4; Verses: '30,30,21,23'),
    (Code: 'COL'; Name: 'Colossians'; Chapters: 4; Verses: '29,23,25,18'),
    (Code: '1TH'; Name: '1 Thessalonians'; Chapters: 5; Verses: '10,20,13,18,28'),
    (Code: '2TH'; Name: '2 Thessalonians'; Chapters: 3; Verses: '12,17,18'),
    (Code: '1TI'; Name: '1 Timothy'; Chapters: 6; Verses: '20,15,16,16,25,21'),
    (Code: '2TI'; Name: '2 Timothy'; Chapters: 4; Verses: '18,26,17,22'),
    (Code: 'TIT'; Name: 'Titus'; Chapters: 3; Verses: '16,15,15'),
    (Code: 'PHM'; Name: 'Philemon'; Chapters: 1; Verses: '25'),
    (Code: 'HEB'; Name: 'Hebrews'; Chapters: 13; Verses: '14,18,19,16,14,20,28,13,28,39,40,29,25'),
    (Code: 'JAS'; Name: 'James'; Chapters: 5; Verses: '27,26,18,17,20'),
    (Code: '1PE'; Name: '1 Peter'; Chapters: 5; Verses: '25,25,22,19,14'),
    (Code: '2PE'; Name: '2 Peter'; Chapters: 3; Verses: '21,22,18'),
    (Code: '1JN'; Name: '1 John'; Chapters: 5; Verses: '10,29,24,21,21'),
    (Code: '2JN'; Name: '2 John'; Chapters: 1; Verses: '13'),
    (Code: '3JN'; Name: '3 John'; Chapters: 1; Verses: '14'),
    (Code: 'JUD'; Name: 'Jude'; Chapters: 1; Verses: '25'),
    (Code: 'REV'; Name: 'Revelation'; Chapters: 22; Verses: '20,29,22,11,14,17,17,13,21,11,19,17,18,20,8,21,18,24,21,15,27,21'));
  OptionalVerses = '|MAT 17:21|MAT 18:11|MAT 23:14|MRK 7:16|MRK 9:44|MRK 9:46|MRK 16:9|MRK 16:10|MRK 16:11|MRK 16:12|MRK 16:13|MRK 16:14|MRK 16:15|MRK 16:16|MRK 16:17|MRK 16:18|MRK 16:19|MRK 16:20|MRK 11:26|MRK 15:28|LUK 17:36|LUK 23:17|JHN 5:4|JHN 7:53|JHN 8:1|ACT 8:37|ACT 15:34|ACT 24:7|ACT 28:29|ROM 16:24|REV 12:18|';
  ShortVerses = '|LEV 11:15|EXO 20:13|EXO 20:14|EXO 20:15|DEU 5:17|DEU 5:18|DEU 5:19|JOB 3:2|JOB 9:1|JOB 12:1|JOB 16:1|JOB 19:1|JOB 21:1|JOB 27:1|JOB 29:1|LUK 20:30|JHN 11:35|';


function BookIndex(const Code: string): Integer;
var
  I: Integer;
begin
  for I := 0 to BookCount - 1 do
    if Books[I].Code = UpperCase(Code) then
      Exit(I);
  Result := -1;
end;

function ChapterCount(const Code: string): Integer;
begin
  if BookIndex(Code) < 0 then
    Exit(0);
  Result := Books[BookIndex(Code)].Chapters;
end;

function VerseCount(const Code: string; Chapter: Integer): Integer;
var
  Counts: TStringArray;
begin
  Result := 0;
  if (BookIndex(Code) < 0) or (Chapter < 1) then
    Exit;
  Counts := Books[BookIndex(Code)].Verses.Split([',']);
  if Chapter <= Length(Counts) then
    Result := StrToIntDef(Counts[Chapter - 1], 0);
end;

function EnglishBookName(const Code: string): string;
begin
  if BookIndex(Code) < 0 then
    Exit('');
  Result := Books[BookIndex(Code)].Name;
end;

function Ref(const Code: string; Chapter, Verse: Integer): string;
begin
  Result := '|' + UpperCase(Code) + ' ' + IntToStr(Chapter) + ':' + IntToStr(Verse) + '|';
end;

function IsOptionalVerse(const Code: string; Chapter, Verse: Integer): Boolean;
begin
  Result := Pos(Ref(Code, Chapter, Verse), OptionalVerses) > 0;
end;

function IsShortVerse(const Code: string; Chapter, Verse: Integer): Boolean;
begin
  Result := Pos(Ref(Code, Chapter, Verse), ShortVerses) > 0;
end;

end.
