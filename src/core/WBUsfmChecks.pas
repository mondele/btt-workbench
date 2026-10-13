unit WBUsfmChecks;

{$mode objfpc}{$H+}
{$codepage utf8}  // the regular expressions hold curly quotes

(* Translation text checks, ported from usfm-tools' verifyUSFM.py (Larry
   Versaw, Wycliffe Associates; Bible-Translation-Tools/usfm-tools of
   2026-10) to work on a BTT-Writer project's chunk files, in chapter and
   chunk order, as if they were one USFM book. Check numbers, regular
   expressions and the order of decisions are verifyUSFM's; strings are
   UnicodeString (WBRegExpr) so classes such as [’”»›] match whole
   characters, and Unicode spaces are made plain spaces first because
   WBRegExpr's \s does not match them.

   Like verifyUSFM, three passes:
   - whole book: \c1 (70), \v1 (73), \v 5x (74), straight quotes (75),
     curly braces (75.1), null bytes (79);
   - block by block (lines): possible section titles (76, 76.1), empty
     \s (76.2), a space before a footnote (78), and the 2% rule that turns
     the all-ASCII check off for a book in a Latin-script language;
   - token by token, with usfmReader's tokenising: unsupported markers
     (53), unmarked text (54.1), unmatched brackets (56-56.3), BTT-Writer
     leftovers (57), punctuation (45, 48-52.3, 58, 58.1), footnote-like
     text (43-43.4), numbers (59-61.2), capitals (44, 44.1, 26, 26.1),
     footnote markers (9, 18, 21), verse numbers (34, 35), and for each
     verse: empty (1), short for its source (2), all ASCII (3), probably
     untranslated (3.5); then mixed-case words (0.4-0.6) and a lone section
     heading (73.6).

   For BTT-Writer projects, besides: verses missing from a chapter (41),
   past its end (8), repeated (40) or out of order (39), text before the
   first verse marker of a chunk (54), "/v" for "\v" (txt2USFM). Chunks
   with unresolved conflicts are left out (the projects module reports
   them).

   The source text is the one the project is compared with (WBSources):
   verse texts and footnotes for 2 and 3.5, its footnoted verses for
   43.1 (else Larry's en_ulb list for 43.3). BTT-Writer sources have no
   section headings, so the section-title tests that need them (76.1
   inside verses) never fire, as with verifyUSFM given such a source.
   Not ported: paragraph and poetry structure, book and chapter titles,
   chapter counts, \toc3, the said-word list and the output files. *)

interface

uses
  Classes, SysUtils, WBSources, WBPyText;

type
  TCheckGroup = (cgStructure, cgMarkers, cgPunctuation, cgQuotes, cgNumbers, cgAscii,
    cgCaps, cgSource, cgWords, cgHeadings, cgFootnotes, cgBrackets);
  TCheckGroups = set of TCheckGroup;

  TCheckId = (
    { BTT-Writer chunk structure }
    ciMissingVerses, ciVerseBeyond, ciVerseTwice, ciVerseOrder, ciTextBeforeVerse,
    ciSlashVerse,
    { markers }
    ciUnsupportedMarker, ciUnmarkedText, ciVerseRange, ciVerseNoNumber,
    ciFootnoteMismatch, ciFootnoteNested, ciFootnoteOutside,
    ciNoSpaceChapter, ciNoSpaceBeforeNumber, ciNoSpaceAfterNumber,
    ciConflictParsingError, ciNullBytes, ciFootnoteSpacing,
    { brackets }
    ciUnmatchedParen, ciUnmatchedAngle, ciUnmatchedSquare, ciUnmatchedBrace,
    { punctuation }
    ciPunctuation, ciSpaceBeforePunct, ciFreeFloating, ciPunctAfterQuote,
    ciWordMedialPunct, ciBackslash, ciUnusualChar, ciOrphanPunct, ciStartsWithPunct,
    ciCurlyBraces,
    { quotes }
    ciRepeatedQuotes, ciStraightQuotes,
    { numbers }
    ciVerseNumberInText, ciPossibleVerseNumber, ciVerseReference, ciEmbeddedNumber,
    ciFraction, ciNumberSuffix, ciNumberPrefix, ciUnsegmented, ciSpaceInNumber,
    ciLeadingZero,
    { verses }
    ciEmptyVerse, ciShortVerse, ciAsciiVerse, ciUntranslated,
    { capitals }
    ciCapsParagraph, ciCapsSentence, ciParagraphPunct, ciChapterEndPunct,
    { words }
    ciMixedCase, ciMixedCaseRepeated, ciMixedCaseTooMany,
    { headings }
    ciSectionTitle, ciSectionTitleAtEnd, ciEmptySectionTitle, ciLoneSection,
    { footnotes }
    ciFootnoteReference, ciFootnoteWhereSource, ciOptionalText,
    ciFootnoteCommonHere, ciUntaggedFootnote);

  TCheckHit = record
    Id: TCheckId;
    Ref: string;      // "3:16", a chunk "03-16", a chapter "3", or ''
    Detail: string;   // the text at fault, a number, ...
  end;
  TCheckHits = array of TCheckHit;

  TChunkText = record
    Chapter, Chunk: string;   // folder and file names, e.g. 03 and 16
    Text: string;             // UTF-8
  end;
  TChunkTexts = array of TChunkText;

const
  AllCheckGroups = [Low(TCheckGroup)..High(TCheckGroup)];

{ verifyUSFM's number for a check, e.g. '45' or '61.2'. }
function CheckNumber(Id: TCheckId): string;
function CheckGroupOf(Id: TCheckId): TCheckGroup;
{ The stable names of the groups, for --skip. }
function CheckGroupName(G: TCheckGroup): string;
{ Checks a text project of Book (USFM code, any case); chunks in order.
  Front matter and title chunks are not checked. Source, if given, is the
  source text compared with. }
function CheckChunks(const Book: string; const Chunks: TChunkTexts;
  Groups: TCheckGroups; Source: TSourceChunking = nil): TCheckHits;

{ The pieces below are exposed for the tests that compare them with
  usfm-tools' own functions. Positions are 1-based. }
type
  TToken = record
    Kind: UnicodeString;    // marker name ('f*', '+add', ...) or 'text'
    Value: UnicodeString;
  end;
  TTokens = array of TToken;

  TMarkerPos = record
    Name: UnicodeString;
    Start: Integer;         // position of the backslash
  end;
  TMarkerPositions = array of TMarkerPos;

{ usfmReader.list_usfm: known markers in a line. }
function ListUsfm(const Line: UnicodeString): TMarkerPositions;
{ usfmReader.nextpair: (marker, raw value) pairs, line by line. }
function NextPairs(const S: UnicodeString): TTokens;
{ usfmReader.parseString: tokens. }
function Tokenize(const S: UnicodeString): TTokens;
{ usfmReader.Token.isFootnote / isFootnoteInterior / isPoetry }
function IsFootnoteMarker(const Name: UnicodeString): Boolean;
function IsFootnoteInteriorMarker(const Name: UnicodeString): Boolean;
function IsPoetryMarker(const Name: UnicodeString): Boolean;
{ usfm_utils.parseLine }
procedure ParseLine(const Line: UnicodeString; out Marker, Value, Remainder: UnicodeString);
{ verifyUSFM.findFootnote: ':' '(' '[' or #0 for none. }
function FindFootnote(const T: UnicodeString): Char;
function ValidBracketedFootnote(const T: UnicodeString): Boolean;
{ verifyUSFM.context, with Python's 0-based Start and Finish. }
function Context(const T: UnicodeString; Start, Finish: Integer): UnicodeString;
{ verifyUSFM.similarity: Jaccard value; Common is the n it returns. }
function Similarity(const SA, SB: UnicodeString; out Common: Integer): Double;
function ListWords(const T: UnicodeString): TUnicodeWords;
function IsMixed(const W: UnicodeString): Boolean;

implementation

uses
  WBRegExpr, Character, Generics.Collections, WBVersification,
  WBSentences, WBSectionTitles;

type
  TStrMap = specialize TDictionary<string, string>;
  TCountMap = specialize TDictionary<UnicodeString, Integer>;
  TRefMap = specialize TDictionary<UnicodeString, string>;

  TCheckInfo = record
    Number: string;
    Group: TCheckGroup;
  end;

const
  Infos: array[TCheckId] of TCheckInfo = (
    (Number: '41'; Group: cgStructure), (Number: '8'; Group: cgStructure),
    (Number: '40'; Group: cgStructure), (Number: '39'; Group: cgStructure),
    (Number: '54'; Group: cgStructure), (Number: 'txt2USFM'; Group: cgMarkers),
    (Number: '53'; Group: cgMarkers), (Number: '54.1'; Group: cgStructure),
    (Number: '34'; Group: cgMarkers), (Number: '35'; Group: cgMarkers),
    (Number: '9'; Group: cgMarkers), (Number: '18'; Group: cgMarkers),
    (Number: '21'; Group: cgMarkers),
    (Number: '70'; Group: cgMarkers), (Number: '73'; Group: cgMarkers),
    (Number: '74'; Group: cgMarkers),
    (Number: '57'; Group: cgMarkers), (Number: '79'; Group: cgMarkers),
    (Number: '78'; Group: cgMarkers),
    (Number: '56'; Group: cgBrackets), (Number: '56.1'; Group: cgBrackets),
    (Number: '56.2'; Group: cgBrackets), (Number: '56.3'; Group: cgBrackets),
    (Number: '45'; Group: cgPunctuation), (Number: '48'; Group: cgPunctuation),
    (Number: '49'; Group: cgPunctuation), (Number: '50'; Group: cgPunctuation),
    (Number: '52'; Group: cgPunctuation), (Number: '52.2'; Group: cgPunctuation),
    (Number: '52.3'; Group: cgPunctuation), (Number: '58'; Group: cgPunctuation),
    (Number: '58.1'; Group: cgPunctuation), (Number: '75.1'; Group: cgPunctuation),
    (Number: '51'; Group: cgQuotes), (Number: '75'; Group: cgQuotes),
    (Number: '59'; Group: cgNumbers), (Number: '59.1'; Group: cgNumbers),
    (Number: '59.2'; Group: cgNumbers), (Number: '60'; Group: cgNumbers),
    (Number: '60.1'; Group: cgNumbers), (Number: '60.2'; Group: cgNumbers),
    (Number: '60.3'; Group: cgNumbers), (Number: '61'; Group: cgNumbers),
    (Number: '61.1'; Group: cgNumbers), (Number: '61.2'; Group: cgNumbers),
    (Number: '1'; Group: cgStructure), (Number: '2'; Group: cgSource),
    (Number: '3'; Group: cgAscii), (Number: '3.5'; Group: cgSource),
    (Number: '44'; Group: cgCaps), (Number: '44.1'; Group: cgCaps),
    (Number: '26'; Group: cgCaps), (Number: '26.1'; Group: cgCaps),
    (Number: '0.4'; Group: cgWords), (Number: '0.5'; Group: cgWords),
    (Number: '0.6'; Group: cgWords),
    (Number: '76'; Group: cgHeadings), (Number: '76.1'; Group: cgHeadings),
    (Number: '76.2'; Group: cgHeadings), (Number: '73.6'; Group: cgHeadings),
    (Number: '43'; Group: cgFootnotes), (Number: '43.1'; Group: cgFootnotes),
    (Number: '43.2'; Group: cgFootnotes), (Number: '43.3'; Group: cgFootnotes),
    (Number: '43.4'; Group: cgFootnotes));

  GroupNames: array[TCheckGroup] of string = ('structure', 'markers',
    'punctuation', 'quotes', 'numbers', 'ascii', 'caps', 'source', 'words',
    'headings', 'footnotes', 'brackets');

  { usfmReader.all_markers }
  AllMarkers =
    '|id|ide|usfm|c|v|p|rem|text|cl|ca|ca*|cp|va|va*|vp|vp*|' +
    'add|+add|add*|+ad*|bd|+bd|bd*|+bd*|bdit|+bdit|bdit*|+bdit*|bk|+bk|bk*|+bk*|' +
    'dc|+dc|dc*|+dc*|em|+em|em*|+em*|it|+it|it*|+it*|k|+k|k*|+k*|nd|+nd|nd*|+nd*|' +
    'no|+no|no*|+no*|ndx|+ndx|ndx*|+ndx*|ord|+ord|ord*|+ord*|pn|+pn|pn*|+pn*|' +
    'pro|+pro|pro*|+pro*|qt|+qt|qt*|+qt*|sc|+sc|sc*|+sc*|sup|+sup|sup*|+sup*|' +
    'sig|+sig|sig*|+sig*|sls|+sls|sls*|+sls*|tl|+tl|tl*|+tl*|w|+w|w*|+w*|' +
    'wg|+wg|wg*|+wg*|wh|+wh|wh*|+wh*|wj|+wj|wj*|+wj*|' +
    'f|f*|fe|fe*|fr|fk|fl|fq|fqa|fp|ft|fv|+fv|fv*|+fv*|fdc|+fdc|fdc*|+fdc*|' +
    'fm|+fm|fm*|+fm*|rq|+rq|rq*|+rq*|x|x*|xo|xt|ef|ef*|ex|ex*|cat|cat*|esb|esbe|' +
    'imt|imt1|imt2|im|imi|imq|ipq|is|is1|is2|is3|ip|ipi|io|io1|io2|io3|iq|iq1|iq2|' +
    'iq3|ib|ili|ili1|ili2|ili3|iot|iex|ior|+ior|ior*|+ior*|iqt|iqt*|ie|' +
    'm|pi|pi1|pi2|pi3|pc|nb|b|q|q1|q2|q3|qa|qr|qc|qac|qac*|qs|qs*|qm|qm1|qm2|' +
    's|s1|s2|s3|s4|s5|sr|r|d|sp|sd|sd1|sd2|sd3|h|toc1|toc2|toc3|' +
    'mt|mt1|mt2|mt3|mte|mte1|mte2|ms|ms1|ms2|mr|lit|pb|fig|fig*|pm|pmo|pmc|pmr|';

  { parseString: markers whose text follows as a separate text token }
  EmptyValueMarkers =
    '|p|pi|pi1|pi2|pi3|pc|nb|m|q|q1|q2|q3|q4|qa|qr|qc|add|bk|dc|k|lit|nd|ord|' +
    'pn|qt|sig|sls|tl|wj|em|bd|it|bdit|no|sc|pb|fig|ndx|pro|w|wg|wh|fl|fp|' +
    'pm|pmo|pmc|pmr|sr|qm|qm1|qm2|';

  FootnoteMarkers = '|f|f*|fe|fe*|ex|ex*|ef|ef*|fr|fk|fl|fq|fqa|fp|ft|fv|+fv|fv*|+fv*|' +
    'fdc|+fdc|fdc*|+fdc*|fm|+fm|fm*|+fm*|rq|+rq|rq*|+rq*|';
  FootnoteInteriorMarkers = '|fr|fk|fl|fq|fqa|fp|ft|fv|+fv|fv*|+fv*|fdc|+fdc|fdc*|' +
    '+fdc*|fm|+fm|fm*|+fm*|rq|+rq|rq*|+rq*|';
  PoetryMarkers = '|q|q1|q2|q3|qa|qr|qc|qm|qm1|qm2|qs|qac|';

{$I wbusfmchecks_enulb.inc}

function CheckNumber(Id: TCheckId): string;
begin
  Result := Infos[Id].Number;
end;

function CheckGroupOf(Id: TCheckId): TCheckGroup;
begin
  Result := Infos[Id].Group;
end;

function CheckGroupName(G: TCheckGroup): string;
begin
  Result := GroupNames[G];
end;

function InList(const Name: UnicodeString; const List: string): Boolean;
begin
  Result := Pos('|' + UTF8Encode(Name) + '|', List) > 0;
end;

{ --- regular expressions (verifyUSFM.py, usfm_utils.py, usfmReader.py) --- }

type
  TRe = (
    rePunctuation, reSpacey, reSpacey2, reSpacey3, reSpacey4, reWordMedial,
    reOutsideQuote, reBacks, reUnusual, rePeriod, reBadMarker,
    reNumberEmbed, reNumberPrefix, reNumberSuffix, reFraction, reUnsegmented,
    reNumberFormat, reLeadingZero, reNumber, reNumCombo,
    reReference, reBracketed, reParenNumber, reParenAmen, reBracket1Word, reParen1Word,
    reConflict, reEmbeddedQuote, reCurly,
    reBadChapter2, reBadVerse2, reBadVerse3, reSlashVerse,
    reCnum, reVnum, rePlus, reUsfmLine, reCvNumber, reFSpace, reSection, reEmptyTitle,
    reSingleWordInQuotes, reQuoteEnd, reQuoteBegin, reMidPunc, rePsalmV1);

const
  Patterns: array[TRe] of UnicodeString = (
    '([.?!;:,][^\s\x{200b})\]''"’”»›])',
    '[\s]([.?!;:,)’”»›])',
    '[\s][\[\]\(''"«“‘’”»›][\s]',
    '^[\(''"«“‘’”»›][\s]',
    '[\s][\(''"«“‘’”»›]$',
    '[\w][.?!;:,()\[\]"«“‘”»›][.?!;:,()\[\]''"«“‘’”»›]*[\w]',
    '([''"’”»›][.!])',
    '\\([^+a-z]|$)',
    '[=+_*&^%$#@~/|¬]+',
    '^[\s]*[.,;:!?]',
    '\\\w+\*?',
    '[^\s,:."''‘\d\(\[\-]+\d+[^\s,;."''’\d\)\]]+',
    '[^\s,."\d\(\[]\d+',
    '\d+[^\s,;:."\-?!"\d\)\]]',
    '\d+\s*[/\\]\s*\d+',
    '\d\d\d\d+',
    '[\d]+[.,]?\s[.,]?[\d]+',
    '\s0[0-9,]*',
    '[^\d(:\-](\d+)[^\d,:\-]',
    '(\d+)([:\-])(\d+)',
    '[\d]+[\s]*:[\s]*[\d]+',
    '\[ *([^\]]+) *\]',
    '\([\d, ]{0,11}\)',
    '\( *[AE]m[ei]+n[aei. ]*\)',
    '\[ ?[^\d ]+ ?\]',
    '\( ?[^\d ]+ ?\)',
    '<<< +HEAD|>>>>>|=====',
    '\w''\w',
    '[{}]',
    '(\\c[0-9]+)',
    '(\\v[0-9]+)',
    '(\\v\s*[-0-9]+[^-\d\s])',
    '(^|\s)/v\s*\d+',
    '^\s+([0-9]+)',
    '^\s+([0-9\-]+)( +|\\|$)',
    '^\s+([\-+])(\s+|$)',
    '^\\([a-z][a-z1-5]*\*?)(\s+.*)?',
    '^[1-9][-0-9]*',
    ' \\(f|fe|x)\s',
    '^\\s[1-4]? +',
    '^\\s *$',
    '^[''’]([\w''’]+)[''’]',
    '[.።,፣:፥;፤!?+-\\\[\]{}()<>''"‹«“‘’”»›`*/][''’]$',
    '^[''’]([.።,፣:፥;፤!?+-\\\[\]{}()<>''"‹«“‘’”»›`*/])',
    '[\d\x{0}.።,፣:፥;፤!?+\\\[\]{}()<>"‹«“‘”»›*]',
    '^PSA \d+:1(-|$)');

var
  Res: array[TRe] of TRegExpr;

function Re(R: TRe): TRegExpr;
begin
  if Res[R] = nil then
  begin
    Res[R] := TRegExpr.Create(Patterns[R]);
    Res[R].UseUnicodeWordDetection := True;
    Res[R].ModifierM := False;
  end;
  Result := Res[R];
end;

function Found(R: TRe; const T: UnicodeString): Boolean;
begin
  Result := (T <> '') and Re(R).Exec(T);
end;

function CountMatches(R: TRe; const T: UnicodeString): Integer;
begin
  Result := 0;
  if Found(R, T) then
    repeat
      Inc(Result);
    until not Re(R).ExecNext;
end;

{ Search from a 1-based position, as Python's search(text, pos). }
function FoundFrom(R: TRe; const T: UnicodeString; From: Integer): Boolean;
begin
  Result := False;
  if (T = '') or (From > Length(T)) then
    Exit;
  if From < 1 then
    From := 1;
  Re(R).InputString := T;
  Result := Re(R).ExecPos(From);
end;

{ UTF-8 to UnicodeString, with Unicode spaces made plain spaces (Python's
  \s matches them, WBRegExpr's does not); one character for one. }
function U(const S: string): UnicodeString;
var
  I: Integer;
begin
  Result := UTF8Decode(S);
  for I := 1 to Length(Result) do
    case Ord(Result[I]) of
      $0B, $85, $A0, $1680, $2000..$200A, $2028, $2029, $202F, $205F, $3000:
        Result[I] := ' ';
    end;
end;

function A(const S: UnicodeString): string;
begin
  Result := UTF8Encode(S);
end;

function CountChar(const T: UnicodeString; C: WideChar): Integer;
var
  X: WideChar;
begin
  Result := 0;
  for X in T do
    if X = C then
      Inc(Result);
end;

{ str.find(' ', start) for 0-based start; -1 if none. }
function FindSpace(const T: UnicodeString; Start0: Integer): Integer;
var
  I: Integer;
begin
  if Start0 < 0 then
    Start0 := 0;
  for I := Start0 + 1 to Length(T) do
    if T[I] = ' ' then
      Exit(I - 1);
  Result := -1;
end;

{ str.rfind(' ', 0, end) for 0-based end; -1 if none. }
function RFindSpace(const T: UnicodeString; End0: Integer): Integer;
var
  I: Integer;
begin
  if End0 > Length(T) then
    End0 := Length(T);
  for I := End0 downto 1 do
    if T[I] = ' ' then
      Exit(I - 1);
  Result := -1;
end;

{ verifyUSFM's context(); Start and Finish 0-based as in Python. }
function Context(const T: UnicodeString; Start, Finish: Integer): UnicodeString;
var
  E: Integer;
begin
  Result := '';
  if (Finish < 0) or (Finish >= Length(T)) then
    Finish := Length(T) - 1;
  if Finish >= Start then
  begin
    E := FindSpace(T, Finish + 1);
    if E < 0 then
      E := Length(T);
    if Start < 1 then
      Start := 0
    else
      Start := RFindSpace(T, Start) + 1;
    if E >= Start then
      Result := Copy(T, Start + 1, E - Start)
    else
      Result := Copy(T, Start + 1, MaxInt);
  end;
  Result := Trim(Result);
end;

{ str.lstrip() }
function LStrip(const S: UnicodeString): UnicodeString;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and IsSpaceChar(S[I]) do
    Inc(I);
  Result := Copy(S, I, MaxInt);
end;

{ str.strip() }
function PyStrip(const S: UnicodeString): UnicodeString;
var
  B: Integer;
begin
  Result := LStrip(S);
  B := Length(Result);
  while (B > 0) and IsSpaceChar(Result[B]) do
    Dec(B);
  SetLength(Result, B);
end;

function IsDigitChar(C: WideChar): Boolean;
begin
  Result := TCharacter.IsDigit(C);
end;

{ Pre-checks: a regular expression that needs one of these characters
  cannot match text without any. They only skip work; results are the
  same. }
function HasAny(const T: UnicodeString; const Chars: UnicodeString): Boolean;
var
  C: WideChar;
begin
  for C in T do
    if Pos(C, Chars) > 0 then
      Exit(True);
  Result := False;
end;

{ Any character Python's \d matches (Unicode decimal digit). }
function HasDigit(const T: UnicodeString): Boolean;
var
  C: WideChar;
begin
  for C in T do
    if ((C >= '0') and (C <= '9')) or ((Ord(C) > 127) and IsDigitChar(C)) then
      Exit(True);
  Result := False;
end;

{ Python's \w for one character: letters, numbers, '_'. }
function IsPyWordChar(C: WideChar): Boolean;
begin
  if Ord(C) < 128 then
    Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
      ((C >= '0') and (C <= '9')) or (C = '_')
  else
    Result := TCharacter.IsLetterOrDigit(C) or TCharacter.IsNumber(C);
end;

{ len(re.findall(r"\w'\w", T)): non-overlapping word-internal apostrophes. }
function CountEmbeddedQuotes(const T: UnicodeString): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := 2;
  while I < Length(T) do
  begin
    if (T[I] = '''') and IsPyWordChar(T[I - 1]) and IsPyWordChar(T[I + 1]) then
    begin
      Inc(Result);
      Inc(I, 3);     // the match ends after T[I + 1]; the next starts after it
    end
    else
      Inc(I);
  end;
end;

{ --- usfmReader: tokens as parseString makes them --- }

{ list_usfm: known markers in a line (unknown ones stay in the text). }
function ListUsfm(const Line: UnicodeString): TMarkerPositions;
var
  I, J, NameEnd: Integer;
  Name: UnicodeString;
  M: TMarkerPos;
begin
  Result := nil;
  I := 1;
  while I <= Length(Line) do
  begin
    if Line[I] = '\' then
    begin
      J := I + 1;
      if (J <= Length(Line)) and (Line[J] = '+') then
        Inc(J);
      NameEnd := J;
      while (NameEnd <= Length(Line)) and (Line[NameEnd] >= 'a') and (Line[NameEnd] <= 'z') do
        Inc(NameEnd);
      if NameEnd > J then
      begin
        if (NameEnd <= Length(Line)) and (Pos(Line[NameEnd], UnicodeString('12345*')) > 0) then
          Inc(NameEnd);
        Name := Copy(Line, I + 1, NameEnd - I - 1);
        if InList(Name, AllMarkers) then
        begin
          M.Name := Name;
          M.Start := I;
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := M;
        end;
        I := NameEnd;
        Continue;
      end;
    end;
    Inc(I);
  end;
end;

{ parseString over one chunk's text. }
function NextPairs(const S: UnicodeString): TTokens;
var
  Lines: array of UnicodeString;
  Line: UnicodeString;
  Marks: TMarkerPositions;
  I, Start, K: Integer;

  procedure Add(const Kind, V: UnicodeString);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Kind := Kind;
    Result[High(Result)].Value := V;
  end;

begin
  Result := nil;
  { text.split('\n') }
  Lines := nil;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = #10) then
    begin
      SetLength(Lines, Length(Lines) + 1);
      Lines[High(Lines)] := Copy(S, Start, I - Start);
      Start := I + 1;
    end;
  for Line in Lines do
  begin
    Marks := ListUsfm(Line);
    if Length(Marks) = 0 then
    begin
      if Line <> '' then
        Add('text', Line);
      Continue;
    end;
    if Marks[0].Start > 1 then
      Add('text', Copy(Line, 1, Marks[0].Start - 1));
    for K := 0 to High(Marks) do
    begin
      Start := Marks[K].Start + Length(Marks[K].Name) + 1;
      if K < High(Marks) then
        Add(Marks[K].Name, Copy(Line, Start, Marks[K + 1].Start - Start))
      else
        Add(Marks[K].Name, Copy(Line, Start, MaxInt));
    end;
  end;
end;

{ parseString: each pair into tokens. }
function Tokenize(const S: UnicodeString): TTokens;
var
  Pair: TToken;
  Leftover: UnicodeString;

  procedure Add(const Kind, V: UnicodeString);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Kind := Kind;
    Result[High(Result)].Value := V;
  end;

  procedure TakePair(const Kind, V: UnicodeString);
  begin
    Leftover := '';
    if Kind = 'text' then
      Add('text', LStrip(V))
    else if Kind = 'c' then
    begin
      if Re(reCnum).Exec(V) then
      begin
        Add('c', Re(reCnum).Match[1]);
        Leftover := Copy(V, Re(reCnum).MatchLen[0] + 1, MaxInt);
      end
      else
      begin
        Add('c', '');
        Leftover := V;
      end;
    end
    else if Kind = 'v' then
    begin
      if Re(reVnum).Exec(V) then
      begin
        Add('v', Re(reVnum).Match[1]);
        Leftover := Copy(V, Re(reVnum).MatchLen[0] + 1, MaxInt);
      end
      else
      begin
        Add('v', '');
        Leftover := V;
      end;
    end
    else if (Kind = 'f') or (Kind = 'fe') or (Kind = 'x') then
    begin
      if Re(rePlus).Exec(V) then
      begin
        Add(Kind, Re(rePlus).Match[1]);
        Leftover := Copy(V, Re(rePlus).MatchLen[0] + 1, MaxInt);
      end;
    end
    else if (Kind[Length(Kind)] = '*') or InList(Kind, EmptyValueMarkers) then
    begin
      Add(Kind, '');
      Leftover := V;
    end
    else
      Add(Kind, LStrip(V));
    if LStrip(Leftover) <> '' then
      Add('text', LStrip(Leftover));
  end;

begin
  Result := nil;
  for Pair in NextPairs(S) do
    TakePair(Pair.Kind, Pair.Value);
end;

function IsFootnoteMarker(const Name: UnicodeString): Boolean;
begin
  Result := InList(Name, FootnoteMarkers);
end;

function IsFootnoteInteriorMarker(const Name: UnicodeString): Boolean;
begin
  Result := InList(Name, FootnoteInteriorMarkers);
end;

function IsPoetryMarker(const Name: UnicodeString): Boolean;
begin
  Result := InList(Name, PoetryMarkers);
end;

{ --- the checker --- }

type
  TCategory = (catOther, catPP, catQQ, catB, catC, catS);
  TBracketState = record
    Ch: WideChar;       // last bracket of its kind seen, #0 for none
    Ref: string;
  end;

  TChecker = class
    Book: string;
    Groups: TCheckGroups;
    Hits: TCheckHits;
    HitCount: Integer;
    SourceId: string;
    SourceText, SourceNotes: TStrMap;     // "c:v" ->
    Footnoted, EnUlbFootnoted: TStrMap;   // "BOOK c:v" of footnoted verses
    SrcBookLen, BookLen: Int64;
    SuppressAscii: Boolean;
    { verifyUSFM's State }
    Chapter, Verse, LastVerse, BridgeStart, BridgeEnd: Integer;
    Reference: string;      // "BOOK c:v"
    InVerse, TextOkay, SentenceEnd, AsciiVerse, NeedVerseText: Boolean;
    VerseText: UnicodeString;
    Curr, Prev: TCategory;
    FootnoteStarts, FootnoteEnds, EndnoteStarts, EndnoteEnds: Integer;
    Paren, Square, Brace, Angle: TBracketState;
    SectionHeadings: Integer;
    Words: TCountMap;
    FirstRef: TRefMap;
    WordOrder: array of UnicodeString;
    WordCount: Integer;
    procedure Hit(Id: TCheckId; const Ref, Detail: string);
    function ShortRef: string;          // "c:v" or "c:v1-v2"
    function InFootnote: Boolean;
    procedure SetCategory(C: TCategory);
    procedure AddChapter(N: Integer);
    procedure AddVerse(N: Integer);
    procedure AddText(const T: UnicodeString);
    procedure PreviousVerseCheck;
    function RelativeLengthCurrent: Double;
    function RelativeLength(Chap, V, TxLen: Integer): Double;
    procedure TakeText(const T: UnicodeString; Footnote: Boolean);
    procedure ReportUnmatched(const T: UnicodeString);
    procedure ReportPunctuation(const T: UnicodeString);
    procedure ReportFootnotes(const T: UnicodeString);
    procedure ReportNumbers(const T: UnicodeString; Footnote: Boolean);
    procedure ReportCaps(const T: UnicodeString);
    procedure AddWords(const T: UnicodeString);
    procedure TakeV(const V: UnicodeString);
    procedure TakeP(const Kind: UnicodeString);
    procedure TakeFootnote(const Tok: TToken);
    procedure ReportMixedCase;
  end;

procedure TChecker.Hit(Id: TCheckId; const Ref, Detail: string);
var
  H: TCheckHit;
begin
  if not (Infos[Id].Group in Groups) then
    Exit;
  H.Id := Id;
  H.Ref := Ref;
  H.Detail := Detail;
  if HitCount = Length(Hits) then
    SetLength(Hits, 2 * HitCount + 16);
  Hits[HitCount] := H;
  Inc(HitCount);
end;

function TChecker.ShortRef: string;
begin
  if (Verse > 0) and (BridgeStart <= Verse) and (Verse <= BridgeEnd) then
    Result := IntToStr(Chapter) + ':' + IntToStr(BridgeStart) + '-' + IntToStr(BridgeEnd)
  else if Verse > 0 then
    Result := IntToStr(Chapter) + ':' + IntToStr(Verse)
  else
    Result := IntToStr(Chapter);
end;

function TChecker.InFootnote: Boolean;
begin
  Result := (FootnoteStarts > FootnoteEnds) or (EndnoteStarts > EndnoteEnds);
end;

procedure TChecker.SetCategory(C: TCategory);
begin
  Prev := Curr;
  Curr := C;
end;

procedure TChecker.AddChapter(N: Integer);
begin
  Chapter := N;
  InVerse := False;
  LastVerse := 0;
  Verse := 0;
  BridgeStart := 0;
  BridgeEnd := 0;
  VerseText := '';
  NeedVerseText := False;
  TextOkay := False;
  Reference := Book + ' ' + IntToStr(N);
  SetCategory(catC);
  Paren := Default(TBracketState);
  Square := Default(TBracketState);
  Brace := Default(TBracketState);
  Angle := Default(TBracketState);
end;

procedure TChecker.AddVerse(N: Integer);
begin
  LastVerse := Verse;
  Verse := N;
  NeedVerseText := True;
  InVerse := True;
  VerseText := '';
  TextOkay := True;
  Reference := Book + ' ' + IntToStr(Chapter) + ':' + IntToStr(N);
  SetCategory(catOther);
  AsciiVerse := True;
end;

procedure TChecker.AddText(const T: UnicodeString);
begin
  SetCategory(catOther);
  NeedVerseText := False;
  if (T <> '') and not InFootnote then
    VerseText := VerseText + T + ' ';
  TextOkay := True;
  if not IsAsciiText(T) then
    AsciiVerse := False;
end;

function TChecker.RelativeLengthCurrent: Double;
var
  SrcLen, TxLen, V: Integer;
  S: string;
begin
  Result := 1.0;
  if Re(rePsalmV1).Exec(UnicodeString(Book + ' ' + ShortRef)) then
    Exit;
  { sourcelength_current }
  SrcLen := 1;
  if SourceText.Count > 0 then
  begin
    if (Verse > 0) and (BridgeStart <= Verse) and (Verse <= BridgeEnd) then
    begin
      SrcLen := 0;
      for V := BridgeStart to BridgeEnd do
        if SourceText.TryGetValue(IntToStr(Chapter) + ':' + IntToStr(V), S) and (S <> '') then
          Inc(SrcLen, Length(U(S)))
        else
          Inc(SrcLen);
    end
    else if SourceText.TryGetValue(IntToStr(Chapter) + ':' + IntToStr(Verse), S) then
      SrcLen := Length(U(S))
    else
      SrcLen := 0;
  end;
  TxLen := Length(VerseText);
  if SrcLen > 1 then
    Result := TxLen / (SrcLen * (BookLen / SrcBookLen))
  else if (TxLen < 12) and not IsShortVerse(Book, Chapter, Verse) then
    Result := TxLen / 100.0;
end;

type
  TWordSet = specialize THashSet<UnicodeString>;

{ similarity(): Jaccard over whitespace-separated words, counting shared
  words longer than 2 characters that are in lower case. }
function Similarity(const SA, SB: UnicodeString; out Common: Integer): Double;
var
  SetA, SetB: TWordSet;
  W: UnicodeString;
  Union_: Integer;
begin
  SetA := TWordSet.Create;
  SetB := TWordSet.Create;
  try
    for W in SplitWords(SA) do
      SetA.Add(W);
    for W in SplitWords(SB) do
      SetB.Add(W);
    Common := 0;
    Union_ := SetA.Count;
    for W in SetB do
      if SetA.Contains(W) then
      begin
        if (Length(W) > 2) and AllLower(W) then
          Inc(Common);
      end
      else
        Inc(Union_);
    if Union_ > 0 then
      Result := Common / Union_
    else
      Result := 0;
  finally
    SetB.Free;
    SetA.Free;
  end;
end;

{ relative_length(ref, chap, verse, txln_len) }
function TChecker.RelativeLength(Chap, V, TxLen: Integer): Double;
var
  S: string;
  SrcLen: Integer;
begin
  Result := 1.0;
  if Re(rePsalmV1).Exec(UnicodeString(Book + ' ' + IntToStr(Chap) + ':' + IntToStr(V))) then
    Exit;
  { source_length: 1 if unknown }
  SrcLen := 1;
  if (SourceText.Count > 0) then
    if SourceText.TryGetValue(IntToStr(Chap) + ':' + IntToStr(V), S) then
      SrcLen := Length(U(S))
    else
      SrcLen := 0;
  if SrcLen > 1 then
    Result := TxLen / (SrcLen * (BookLen / SrcBookLen))
  else if (TxLen < 12) and not IsShortVerse(Book, Chap, V) then
    Result := TxLen / 100.0;
end;

procedure TChecker.PreviousVerseCheck;
var
  Common: Integer;
  Empty: Boolean;
  Rel: Double;
  S, N: string;
begin
  Empty := False;
  if not IsOptionalVerse(Book, Chapter, Verse) and (Verse <> 0) then
  begin
    if Length(VerseText) = 0 then
    begin
      Hit(ciEmptyVerse, ShortRef, '');
      Empty := True;
    end
    else
    begin
      Rel := RelativeLengthCurrent;
      if (Rel < 0.4) or ((BridgeStart < BridgeEnd) and (Rel < 0.5)) then
        Hit(ciShortVerse, ShortRef, '');
    end;
  end;
  if not SuppressAscii and AsciiVerse and not Empty then
    Hit(ciAsciiVerse, ShortRef, '');
  { similarToSource }
  if SourceText.Count > 0 then
  begin
    if not SourceText.TryGetValue(IntToStr(Chapter) + ':' + IntToStr(Verse), S) then
      S := '';
    if not SourceNotes.TryGetValue(IntToStr(Chapter) + ':' + IntToStr(Verse), N) then
      N := '';
    if Similarity(U(S + ' ' + N), VerseText, Common) > 0.4 then
      Hit(ciUntranslated, ShortRef, '');
  end;
end;

procedure TChecker.ReportUnmatched(const T: UnicodeString);
var
  Marks: UnicodeString;
  C: WideChar;
  Ref: string;

  function Differs(L, R: WideChar): Boolean;
  begin
    Result := CountChar(Marks, L) <> CountChar(Marks, R);
  end;

  procedure Track(var St: TBracketState; Ch, L, R: WideChar; Id: TCheckId);
  begin
    if Ch = L then
    begin
      if (St.Ch = L) and Differs(L, R) then
        Hit(Id, St.Ref, A(UnicodeString(L)));
    end
    else if ((St.Ch = #0) or (St.Ch = R)) and Differs(L, R) then
      Hit(Id, Ref, A(UnicodeString(R)));
    St.Ch := Ch;
    St.Ref := Ref;
  end;

begin
  Marks := '';
  for C in T do
    if Pos(C, UnicodeString('()<>[]{}')) > 0 then
      Marks := Marks + C;
  Ref := ShortRef;
  for C in Marks do
    case C of
      '(', ')': Track(Paren, C, '(', ')', ciUnmatchedParen);
      '<', '>':
        if ((C = '<') and (Pos('<<<', T) = 0)) or ((C = '>') and (Pos('>>>', T) = 0)) then
          Track(Angle, C, '<', '>', ciUnmatchedAngle);
      '[', ']': Track(Square, C, '[', ']', ciUnmatchedSquare);
      '{', '}': Track(Brace, C, '{', '}', ciUnmatchedBrace);
    end;
end;

{ punctuation_re.search: the first phrase-ending mark followed by a
  character that is not white space, U+200B, a closing bracket or a quote.
  A direct scan, same result. 0 if none. }
function PunctuationPos(const T: UnicodeString): Integer;
const
  Marks: UnicodeString = '.?!;:,';
  After: UnicodeString = #$200B')]''"’”»›';
var
  I: Integer;
begin
  for I := 1 to Length(T) - 1 do
    if (Pos(T[I], Marks) > 0) and not WBPyText.IsSpaceChar(T[I + 1]) and
       (Pos(T[I + 1], After) = 0) then
      Exit(I);
  Result := 0;
end;

{ Whether some character of Lead is preceded by a word character (cheap
  test before the word-medial pattern). }
function WordThenAny(const T: UnicodeString; const Lead: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := 2 to Length(T) do
    if (Pos(T[I], Lead) > 0) and IsPyWordChar(T[I - 1]) then
      Exit(True);
  Result := False;
end;

{ Whether white space is followed by one of Marks. }
function SpaceThenAny(const T: UnicodeString; const Marks: UnicodeString): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(T) - 1 do
    if WBPyText.IsSpaceChar(T[I]) and (Pos(T[I + 1], Marks) > 0) then
      Exit(True);
  Result := False;
end;

{ wordmedial_punct_re.search(T, From - 1): a word character, one of
  .?!;:,()[]"«“‘”»›, any run of those or ' ’, a word character. A direct
  scan, same result: the run cannot hold word characters, so greedy
  matching never needs to back off. Start and Len 1-based; False if none. }
function WordMedialAt(const T: UnicodeString; From: Integer; out Start, Len: Integer): Boolean;
const
  First: UnicodeString = '.?!;:,()[]"«“‘”»›';
  Rest: UnicodeString = '.?!;:,()[]''"«“‘’”»›';
var
  I, J: Integer;
begin
  if From < 1 then
    From := 1;
  for I := From + 1 to Length(T) - 1 do
    if (Pos(T[I], First) > 0) and IsPyWordChar(T[I - 1]) then
    begin
      J := I + 1;
      while (J <= Length(T)) and (Pos(T[J], Rest) > 0) do
        Inc(J);
      if (J <= Length(T)) and IsPyWordChar(T[J]) then
      begin
        Start := I - 1;
        Len := J - Start + 1;
        Exit(True);
      end;
    end;
  Start := 0;
  Len := 0;
  Result := False;
end;

procedure TChecker.ReportPunctuation(const T: UnicodeString);
var
  MS, ML: Integer;
  I, P: Integer;
  Chars, S: UnicodeString;
  M: TRegExpr;
  Got: Boolean;
  Seen: TStringList;
begin
  I := PunctuationPos(T);
  if I > 0 then
  begin
    if (Copy(T, I, 3) <> '...') or (Copy(T, I, 4) = '....') then
    begin
      Chars := Copy(T, I, 2);
      if not ((Pos(Chars[1], UnicodeString(',.')) > 0) and (Chars[2] >= '0') and (Chars[2] <= '9')) and
         not ((Chars[1] = ':') and (Chars[2] >= '0') and (Chars[2] <= '9')) then
        Hit(ciPunctuation, ShortRef, A(Chars));
    end;
  end;
  if SpaceThenAny(T, '.?!;:,)’”»›') and Found(reSpacey, T) then
    Hit(ciSpaceBeforePunct, ShortRef, A(Re(reSpacey).Match[1]));
  if HasAny(T, '''"’”»›') and Found(reOutsideQuote, T) then
  begin
    I := Re(reOutsideQuote).MatchPos[0];
    if Copy(T, I + 1, 3) <> '...' then
      Hit(ciPunctAfterQuote, ShortRef, A(Re(reOutsideQuote).Match[1]));
  end;
  Got := HasAny(T, '[]()''"«“‘’”»›');
  if not Got then
  else if Found(reSpacey2, T) then
    S := Context(T, Re(reSpacey2).MatchPos[0] - 1 - 2,
      Re(reSpacey2).MatchPos[0] - 1 + Re(reSpacey2).MatchLen[0] + 2)
  else if Found(reSpacey3, T) then
    S := Context(T, 0, Re(reSpacey3).MatchLen[0] + 2)
  else if Found(reSpacey4, T) then
    S := Context(T, Re(reSpacey4).MatchPos[0] - 1 - 2, Length(T))
  else
    Got := False;
  if Got then
    Hit(ciFreeFloating, ShortRef, A(S));
  if (Pos('''''', T) > 0) or (Pos('""', T) > 0) then
    Hit(ciRepeatedQuotes, ShortRef, '');
  { word-medial punctuation, every case after a space }
  Got := WordMedialAt(T, 1, MS, ML);
  while Got and not ((T[MS + ML - 1] >= '0') and (T[MS + ML - 1] <= '9')) do
  begin
    Hit(ciWordMedialPunct, ShortRef, A(Context(T, MS - 1, MS - 1 + ML)));
    P := FindSpace(T, MS - 1 + ML);
    Got := (P > 0) and WordMedialAt(T, P + 1, MS, ML);
  end;
  if (Pos('\', T) > 0) and Found(reBacks, T) then
    Hit(ciBackslash, ShortRef, '');
  if HasAny(T, '=+_*&^%$#@~/|¬') and Found(reUnusual, T) then
  begin
    Seen := TStringList.Create;
    try
      repeat
        S := Re(reUnusual).Match[0];
        if Seen.IndexOf(A(S)) < 0 then
        begin
          Seen.Add(A(S));
          Hit(ciUnusualChar, ShortRef, A(S));
        end;
      until not Re(reUnusual).ExecNext;
    finally
      Seen.Free;
    end;
  end;
end;

{ findFootnote, then reportFootnotes. }
function FindFootnote(const T: UnicodeString): Char;
var
  Flag: Char;
begin
  Flag := #0;
  if not HasAny(T, ':()[') then
    Exit(#0);
  if (Pos(':', T) > 0) and Found(reReference, T) then
    Flag := ':'
  else if (Pos('(', T) > 0) or (Pos(')', T) > 0) then
  begin
    if CountChar(T, '(') > CountMatches(reParenNumber, T) + CountMatches(reParenAmen, T) then
    begin
      Flag := '(';
      if (CountChar(T, '(') = 1) and (CountChar(T, ')') = 1) and Found(reParen1Word, T) then
        Flag := #0;
    end;
  end
  else if Pos('[', T) > 0 then
  begin
    if not Found(reBracketed, T) or (Pos(' ', Re(reBracketed).Match[1]) > 0) then
    begin
      Flag := '[';
      if (CountChar(T, '[') = 1) and (CountChar(T, ']') = 1) and Found(reBracket1Word, T) then
        Flag := #0;
    end;
  end;
  Result := Flag;
end;

{ One bracketed part holding a chapter:verse reference. }
function ValidBracketedFootnote(const T: UnicodeString): Boolean;
begin
  Result := Found(reBracketed, T) and Found(reReference, Re(reBracketed).Match[0]);
end;

procedure TChecker.ReportFootnotes(const T: UnicodeString);
var
  Flag: Char;
  Dummy: string;
begin
  Flag := FindFootnote(T);
  if Flag = #0 then
    Exit;
  { a reference not in brackets (validBracketedFootnote) }
  if (Flag = ':') and not ValidBracketedFootnote(T) then
    Hit(ciFootnoteReference, ShortRef, '')
  else if Footnoted.TryGetValue(Reference, Dummy) then
    Hit(ciFootnoteWhereSource, ShortRef, SourceId)
  else if IsOptionalVerse(Book, Chapter, Verse) then
    Hit(ciOptionalText, ShortRef, '')
  else if EnUlbFootnoted.TryGetValue(Reference, Dummy) then
    Hit(ciFootnoteCommonHere, ShortRef, '')
  else if Flag <> '(' then
    Hit(ciUntaggedFootnote, ShortRef, '');
end;

function InBridge(C: TChecker; N: Integer): Boolean;
begin
  Result := (N > 0) and (C.BridgeStart <= N) and (N <= C.BridgeEnd);
end;

procedure TChecker.ReportNumbers(const T: UnicodeString; Footnote: Boolean);
var
  VerseFlag: Boolean;
  SVerse, G0: UnicodeString;
  M: TRegExpr;
  Got: Boolean;
  N: Integer;
begin
  if not HasDigit(T) then
    Exit;     // every number check needs a digit
  VerseFlag := False;
  if (Chapter > 0) and not Footnote then
  begin
    SVerse := UnicodeString(IntToStr(Verse));
    if (Copy(T, 1, Length(SVerse)) = SVerse) and
       ((T = SVerse) or not IsDigitChar(T[Length(SVerse) + 1])) then
    begin
      Hit(ciVerseNumberInText, ShortRef, '');
      VerseFlag := True;
    end
    else if Found(reNumber, T) then
    begin
      M := Re(reNumber);
      Got := True;
      while Got and not VerseFlag do
      begin
        N := StrToIntDef(A(M.Match[1]), -1);
        if (N = Verse) or (N = Verse + 1) or InBridge(Self, N) then
        begin
          Hit(ciPossibleVerseNumber, ShortRef, A(M.Match[1]));
          VerseFlag := True;
        end;
        Got := FoundFrom(reNumber, T, M.MatchPos[0] + M.MatchLen[0] - 1);
      end;
    end;
    if not VerseFlag and Found(reNumCombo, T) then
    begin
      M := Re(reNumCombo);
      Got := True;
      while Got and not VerseFlag do
      begin
        if M.Match[2] = ':' then
          VerseFlag := True     // reportFootnotes has flagged it
        else if StrToIntDef(A(M.Match[3]), 0) > StrToIntDef(A(M.Match[1]), 0) then
        begin
          Hit(ciVerseReference, ShortRef, A(M.Match[0]));
          VerseFlag := True;
        end;
        Got := M.ExecNext;
      end;
    end;
  end;
  if Found(reNumberEmbed, T) then
    Hit(ciEmbeddedNumber, ShortRef, A(Re(reNumberEmbed).Match[0]))
  else if not VerseFlag then
  begin
    if Found(reFraction, T) then
    begin
      if (Chapter > 0) and not Footnote then
        Hit(ciFraction, ShortRef, A(Re(reFraction).Match[0]));
    end
    else if Found(reNumberSuffix, T) then
    begin
      if (Chapter > 0) and not Footnote then
        Hit(ciNumberSuffix, ShortRef, A(Re(reNumberSuffix).Match[0]));
    end
    else if Found(reNumberPrefix, T) then
    begin
      G0 := Re(reNumberPrefix).Match[0];
      if ((Chapter > 0) and not Footnote) or not ((G0[1] = ':') or (G0[1] = '-')) then
        Hit(ciNumberPrefix, ShortRef, A(G0));
    end;
  end;
  if Found(reUnsegmented, T) and (Re(reUnsegmented).MatchLen[0] > 4) then
    Hit(ciUnsegmented, ShortRef, A(Re(reUnsegmented).Match[0]));
  if Found(reNumberFormat, T) then
    Hit(ciSpaceInNumber, ShortRef, A(Re(reNumberFormat).Match[0]))
  else if Found(reLeadingZero, T) then
    Hit(ciLeadingZero, ShortRef, A(Trim(Re(reLeadingZero).Match[0])));
end;

procedure TChecker.ReportCaps(const T: UnicodeString);
var
  W: UnicodeString;
begin
  if SentenceEnd then
  begin
    W := FirstWord(T);
    if (W <> '') and IsLowerChar(W[1]) then
      if (Curr = catPP) or (Prev = catPP) then
        Hit(ciCapsParagraph, ShortRef, A(W))
      else
        Hit(ciCapsSentence, ShortRef, A(W));
  end;
  for W in NextFirstWords(T) do
    if (W <> '') and IsLowerChar(W[1]) and (Reference <> 'MAT 5:22') then
      Hit(ciCapsSentence, ShortRef, A(W));
end;

{ midpunc_re.search(word): a digit, a null or this punctuation. }
function HasMidPunc(const W: UnicodeString): Boolean;
var
  C: WideChar;
begin
  for C in W do
    case C of
      #0, '0'..'9', '.', ',', ':', ';', '!', '?', '+', '\', '[', ']', '{', '}',
      '(', ')', '<', '>', '"', '*', '።', '፣', '፥', '፤', '‹', '«', '“', '‘', '”', '»', '›':
        Exit(True);
    else
      if (Ord(C) > 127) and IsDigitChar(C) then
        Exit(True);
    end;
  Result := False;
end;

{ listwords }
function ListWords(const T: UnicodeString): TUnicodeWords;
const
  EndPunc: UnicodeString = '.።,፣:፥;፤!?+-\[]{}()<>"‹«“‘”»›`*/';
var
  Items: TUnicodeWords;
  Item, W: UnicodeString;
  I, Start: Integer;
  HasAlpha: Boolean;
  C: WideChar;

  function StripEnds(const S: UnicodeString; Left, Right: Boolean): UnicodeString;
  var
    A_, B_: Integer;
  begin
    A_ := 1;
    B_ := Length(S);
    if Left then
      while (A_ <= B_) and (Pos(S[A_], EndPunc) > 0) do
        Inc(A_);
    if Right then
      while (B_ >= A_) and (Pos(S[B_], EndPunc) > 0) do
        Dec(B_);
    Result := Copy(S, A_, B_ - A_ + 1);
  end;

begin
  Result := nil;
  { re.split(' | |--|—') }
  Items := nil;
  Start := 1;
  I := 1;
  while I <= Length(T) + 1 do
  begin
    if I > Length(T) then
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)] := Copy(T, Start, I - Start);
      Break;
    end;
    if (T[I] = ' ') or (T[I] = #$A0) or (T[I] = '—') or
       ((T[I] = '-') and (I < Length(T)) and (T[I + 1] = '-')) then
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)] := Copy(T, Start, I - Start);
      if T[I] = '-' then
        Inc(I);
      Start := I + 1;
    end;
    Inc(I);
  end;
  for Item in Items do
  begin
    W := StripEnds(Item, True, True);
    { The quote patterns need an apostrophe at the start or end; checking
      that first only saves work. }
    if (W <> '') and ((W[1] = '''') or (W[1] = '’')) and
       Re(reSingleWordInQuotes).Exec(W) and (W[1] = W[Length(W)]) then
      W := Re(reSingleWordInQuotes).Match[1];
    if (Length(W) >= 2) and ((W[Length(W)] = '''') or (W[Length(W)] = '’')) and
       Found(reQuoteEnd, W) then
      W := StripEnds(Copy(W, 1, Length(W) - 2), False, True);
    if (Length(W) >= 2) and ((W[1] = '''') or (W[1] = '’')) and Found(reQuoteBegin, W) then
      W := StripEnds(Copy(W, 3, MaxInt), True, False);
    if W = '' then
      Continue;
    HasAlpha := False;
    for C in W do
      if TCharacter.IsLetter(C) then
        HasAlpha := True;
    if HasAlpha and not HasMidPunc(W) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := W;
    end;
  end;
end;

procedure TChecker.AddWords(const T: UnicodeString);
var
  W: UnicodeString;
  N: Integer;
begin
  for W in ListWords(T) do
    if Words.TryGetValue(W, N) then
      Words[W] := N + 1
    else
    begin
      Words.Add(W, 1);
      FirstRef.Add(W, ShortRef);
      if WordCount = Length(WordOrder) then
        SetLength(WordOrder, 2 * WordCount + 64);
      WordOrder[WordCount] := W;
      Inc(WordCount);
    end;
end;

{ isMixed }
function IsMixed(const W: UnicodeString): Boolean;
var
  W2: UnicodeString;
  C: WideChar;
begin
  Result := False;
  if (Length(W) > 1) and not IsCaseless(W) and
     not (AllLower(W) or IsTitle(W) or AllUpper(W)) then
  begin
    W2 := '';
    for C in W do
      if Pos(C, UnicodeString('''’`"-_()–&')) = 0 then
        W2 := W2 + C;
    Result := (Length(W2) > 1) and not (AllLower(W2) or IsTitle(W2) or AllUpper(W2));
  end;
end;

procedure TChecker.ReportMixedCase;
const
  Limit = 20;
var
  Key: UnicodeString;
  Repeated: array of UnicodeString;
  I: Integer;
begin
  Repeated := nil;
  for I := 0 to WordCount - 1 do
  begin
    Key := WordOrder[I];
    if Length(Repeated) > Limit then
      Break;
    if Words[Key] = 1 then
    begin
      if IsMixed(Key) then
        Hit(ciMixedCase, FirstRef[Key], A(Key));
    end
    else if (Words[Key] < 5) and IsMixed(Key) then
    begin
      SetLength(Repeated, Length(Repeated) + 1);
      Repeated[High(Repeated)] := Key;
    end;
  end;
  if Length(Repeated) > 0 then
  begin
    for I := 0 to High(Repeated) do
      if I < Limit then
        Hit(ciMixedCaseRepeated, FirstRef[Repeated[I]], A(Repeated[I]));
    if Length(Repeated) >= Limit then
      Hit(ciMixedCaseTooMany, '', '');
  end;
end;

procedure TChecker.TakeText(const T: UnicodeString; Footnote: Boolean);
begin
  if Found(reBadMarker, T) then
    Hit(ciUnsupportedMarker, ShortRef, A(Re(reBadMarker).Match[0]));
  if TextOkay and (Verse = 0) and (Chapter > 0) then
    Hit(ciUnmarkedText, IntToStr(Chapter), '');
  ReportUnmatched(T);
  if Pos('Conflict Parsing Error', T) > 0 then
    Hit(ciConflictParsingError, ShortRef, '');
  ReportPunctuation(T);
  if Found(rePeriod, T) then
  begin
    if Length(T) <= Re(rePeriod).MatchLen[0] + 1 then
      Hit(ciOrphanPunct, ShortRef, '')
    else
      Hit(ciStartsWithPunct, ShortRef, '');
  end;
  if InVerse and not InFootnote then
    ReportFootnotes(T);
  ReportNumbers(T, Footnote);
  if not Footnote then
  begin
    ReportCaps(T);
    SentenceEnd := EndsSentence(T) <> '';
  end;
  AddWords(T);
  AddText(T);
end;

procedure TChecker.TakeV(const V: UnicodeString);
var
  A_, B_, N, Dash: Integer;
begin
  if (V <> '1') and (Copy(V, 1, 2) <> '1-') then
    PreviousVerseCheck;
  Dash := Pos('-', V);
  if Dash > 1 then
  begin
    A_ := StrToIntDef(A(Copy(V, 1, Dash - 1)), -1);
    B_ := StrToIntDef(A(Copy(V, Dash + 1, MaxInt)), -1);
    if (A_ >= 0) and (B_ >= 0) then
    begin
      BridgeStart := A_;
      BridgeEnd := B_;
      for N := A_ to B_ do
        AddVerse(N);
    end
    else
      Hit(ciVerseRange, ShortRef, A(V));
  end
  else if V = '' then
    Hit(ciVerseNoNumber, ShortRef, '')
  else if StrToIntDef(A(V), -1) >= 0 then
    AddVerse(StrToInt(A(V)));
end;

procedure TChecker.TakeP(const Kind: UnicodeString);
begin
  if not SentenceEnd and (Kind <> 'm') then
  begin
    if Verse > 0 then
      Hit(ciParagraphPunct, ShortRef, '')
    else if Reference <> 'ACT 22' then
      Hit(ciChapterEndPunct, IntToStr(Chapter), '');
  end;
  TextOkay := True;
  if Kind <> 'nb' then
    SentenceEnd := True;
  SetCategory(catPP);
end;

procedure TChecker.TakeFootnote(const Tok: TToken);
begin
  if (Tok.Kind = 'f') or (Tok.Kind = 'rq') then
  begin
    if FootnoteStarts <> FootnoteEnds then
      Hit(ciFootnoteNested, ShortRef, '');
    Inc(FootnoteStarts);
    SetCategory(catOther);
    NeedVerseText := False;
    TextOkay := True;
  end
  else if Tok.Kind = 'fe' then
  begin
    Inc(EndnoteStarts);
    SetCategory(catOther);
    TextOkay := True;
  end
  else if (Tok.Kind = 'f*') or (Tok.Kind = 'rq*') then
  begin
    Inc(FootnoteEnds);
    TextOkay := True;
  end
  else if Tok.Kind = 'fe*' then
  begin
    Inc(EndnoteEnds);
    TextOkay := True;
  end
  else if not InFootnote then
    Hit(ciFootnoteOutside, ShortRef, '\' + A(Tok.Kind));
  if (Tok.Value <> '') and InList(Tok.Kind, FootnoteInteriorMarkers) then
    TakeText(Tok.Value, True);
end;

{ --- blocks (usfm_utils.nextblock, parseLine) --- }

type
  TBlocks = array of UnicodeString;

{ A chunk's lines as nextblock gives them: one per line, with its line
  end, consecutive lines without a leading marker joined. }
function Blocks(const T: UnicodeString): TBlocks;
var
  Lines: TBlocks;
  I, Start: Integer;
  Block: UnicodeString;

  function Marked(const L: UnicodeString): Boolean;
  begin
    Result := Re(reUsfmLine).Exec(L);
  end;

  function IsSpaceLine(const L: UnicodeString): Boolean;
  begin
    Result := (L <> '') and (PyStrip(L) = '');
  end;

begin
  Lines := nil;
  Start := 1;
  for I := 1 to Length(T) do
    if T[I] = #10 then
    begin
      SetLength(Lines, Length(Lines) + 1);
      Lines[High(Lines)] := Copy(T, Start, I - Start + 1);
      Start := I + 1;
    end;
  { The chunk's last line: in a book it is followed by a line end. }
  if Start <= Length(T) then
  begin
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := Copy(T, Start, MaxInt) + #10;
  end;
  Result := nil;
  I := 0;
  while I <= High(Lines) do
  begin
    if not Marked(Lines[I]) and not IsSpaceLine(Lines[I]) then
    begin
      Block := Lines[I];
      Inc(I);
      while (I <= High(Lines)) and not Marked(Lines[I]) do
      begin
        Block := Block + Lines[I];
        Inc(I);
      end;
    end
    else
    begin
      Block := Lines[I];
      Inc(I);
    end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Block;
  end;
end;

{ parseLine: (marker, value, remainder) }
procedure ParseLine(const Line: UnicodeString; out Marker, Value, Remainder: UnicodeString);
var
  M: TRegExpr;
begin
  Marker := '';
  Value := '';
  Remainder := '';
  M := Re(reUsfmLine);
  if M.Exec(Line) then
  begin
    Marker := M.Match[1];
    Remainder := PyStrip(M.Match[2]);
    if (Marker = 'c') or (Marker = 'v') then
    begin
      if Re(reCvNumber).Exec(Remainder) then
      begin
        Value := Re(reCvNumber).Match[0];
        Remainder := PyStrip(Copy(Remainder, Length(Value) + 1, MaxInt));
      end
      else
        Marker := '';
    end
    else if Marker = 'id' then
    begin
      Value := Copy(Remainder, 1, 3);
      Remainder := PyStrip(Copy(Remainder, 4, MaxInt));
    end;
  end;
  if Marker = '' then
    Remainder := Line;
end;

{ bad_verse_re2 '\\v[0-9]+' (After False) or bad_verse_re3
  '\\v\s*[-0-9]+[^-\d\s]' (After True), every match. }
function BadVerseMarkers(const T: UnicodeString; After: Boolean): TBlocks;
var
  I, J, K: Integer;

  function IsHyphenDigit(C: WideChar): Boolean;
  begin
    Result := (C = '-') or ((C >= '0') and (C <= '9'));
  end;

begin
  Result := nil;
  I := 1;
  while I < Length(T) do
  begin
    if (T[I] = '\') and (T[I + 1] = 'v') then
    begin
      J := I + 2;
      if not After then
      begin
        K := J;
        while (K <= Length(T)) and (T[K] >= '0') and (T[K] <= '9') do
          Inc(K);
        if K > J then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Copy(T, I, K - I);
          I := K;
          Continue;
        end;
      end
      else
      begin
        while (J <= Length(T)) and WBPyText.IsSpaceChar(T[J]) do
          Inc(J);
        K := J;
        while (K <= Length(T)) and IsHyphenDigit(T[K]) do
          Inc(K);
        { [^-\d\s]: \d is any Unicode decimal digit }
        if (K > J) and (K <= Length(T)) and not IsHyphenDigit(T[K]) and
           not IsDigitChar(T[K]) and not WBPyText.IsSpaceChar(T[K]) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Copy(T, I, K - I + 1);
          I := K + 1;
          Continue;
        end;
      end;
    end;
    Inc(I);
  end;
end;

{ --- the project --- }

function CheckChunks(const Book: string; const Chunks: TChunkTexts;
  Groups: TCheckGroups; Source: TSourceChunking): TCheckHits;
var
  C: TChecker;
  Texts: array of UnicodeString;
  Labels: array of string;
  ChapterOf: array of Integer;
  Chunk: TChunkText;
  Text, Whole, Block, Marker, Value, Remainder, Heading, PrevLine: UnicodeString;
  Toks: TTokens;
  Tok: TToken;
  I, J, Ch, V, NBlocks, NAscii, LocalChapter, LocalVerse, Embedded, Singles, Doubles: Integer;
  Seen: array of array of Boolean;
  Missing: TStringArray;
  SeenVerseInChunk, SentenceEnded: Boolean;
  LocalRef, LastHd, Key: string;
  M: TRegExpr;
  Rel: Double;
  SrcLen: Int64;
begin
  C := TChecker.Create;
  C.SourceText := TStrMap.Create;
  C.SourceNotes := TStrMap.Create;
  C.Footnoted := TStrMap.Create;
  C.EnUlbFootnoted := TStrMap.Create;
  C.Words := TCountMap.Create;
  C.FirstRef := TRefMap.Create;
  try
    C.Book := UpperCase(Book);
    C.Groups := Groups;
    C.SentenceEnd := True;
    C.Curr := catOther;
    C.Prev := catOther;
    C.AsciiVerse := True;
    C.SourceId := 'en_ulb';

    { The source text, its footnotes and footnoted verses. }
    SrcLen := 0;
    if Source <> nil then
    begin
      C.SourceId := Source.Container;
      for I := 0 to High(Source.Chunks) do
        for J := 0 to High(Source.Chunks[I].Verses) do
          if (StrToIntDef(Source.Chunks[I].Chapter, 0) > 0) and (J <= High(Source.Chunks[I].Texts)) then
          begin
            Key := IntToStr(StrToInt(Source.Chunks[I].Chapter)) + ':' +
              IntToStr(Source.Chunks[I].Verses[J]);
            C.SourceText.AddOrSetValue(Key, Source.Chunks[I].Texts[J]);
            { about the USFM length without footnotes: \v N text }
            Inc(SrcLen, Length(U(Source.Chunks[I].Texts[J])) +
              Length(IntToStr(Source.Chunks[I].Verses[J])) + 5);
            if J <= High(Source.Chunks[I].NoteTexts) then
              C.SourceNotes.AddOrSetValue(Key, Source.Chunks[I].NoteTexts[J]);
            if (J <= High(Source.Chunks[I].Notes)) and Source.Chunks[I].Notes[J] then
              C.Footnoted.AddOrSetValue(C.Book + ' ' + Key, '');
          end;
      { load_source: the en_ulb list when the source shows no footnotes }
      if C.Footnoted.Count = 0 then
        for Key in string(FootnotedEnUlb).Split(['|']) do
          if Key <> '' then
            C.EnUlbFootnoted.AddOrSetValue(Key, '');
    end;
    if SrcLen < 1 then
      SrcLen := 1;
    C.SrcBookLen := SrcLen;

    { The chunks to check, as one book. }
    Texts := nil;
    Labels := nil;
    ChapterOf := nil;
    Whole := '\id ' + UnicodeString(C.Book) + #10;
    Ch := 0;
    for Chunk in Chunks do
    begin
      I := StrToIntDef(Chunk.Chapter, 0);
      if (I = 0) or (StrToIntDef(Chunk.Chunk, -1) < 0) then
        Continue;     // front matter and titles
      Text := U(Chunk.Text);
      if (Copy(Text, 1, 8) = '<<<<<<< ') or (Pos(#10'<<<<<<< ', Text) > 0) then
        Continue;     // unresolved conflict: holds every version
      SetLength(Texts, Length(Texts) + 1);
      Texts[High(Texts)] := Text;
      SetLength(Labels, Length(Labels) + 1);
      Labels[High(Labels)] := Chunk.Chapter + '-' + Chunk.Chunk;
      SetLength(ChapterOf, Length(ChapterOf) + 1);
      ChapterOf[High(ChapterOf)] := I;
      if I <> Ch then
      begin
        if Pos(UnicodeString('\c '), Text) = 0 then
          Whole := Whole + '\c ' + UnicodeString(IntToStr(I)) + #10;
        Ch := I;
      end;
      Whole := Whole + Text + #10;
    end;
    C.BookLen := Length(Whole);

    { Whole book (verifyWholeFile, verifyChapterAndVerseMarkers): bad_verse_re2
      and bad_verse_re3 as direct scans (same matches, in order). }
    for I := 0 to High(Texts) do
    begin
      M := Re(reBadChapter2);
      if (Pos(UnicodeString('\c'), Texts[I]) > 0) and Found(reBadChapter2, Texts[I]) then
        repeat
          C.Hit(ciNoSpaceChapter, Labels[I], A(M.Match[1]));
        until not M.ExecNext;
      for Text in BadVerseMarkers(Texts[I], False) do
        C.Hit(ciNoSpaceBeforeNumber, Labels[I], A(Text));
      for Text in BadVerseMarkers(Texts[I], True) do
        C.Hit(ciNoSpaceAfterNumber, Labels[I], A(Text));
      if (Pos(UnicodeString('/v'), Texts[I]) > 0) and Found(reSlashVerse, Texts[I]) then
        C.Hit(ciSlashVerse, Labels[I], A(Trim(Re(reSlashVerse).Match[0])));
      if Pos(#0, Texts[I]) > 0 then
        C.Hit(ciNullBytes, Labels[I], '');
    end;
    Embedded := CountEmbeddedQuotes(Whole);
    Singles := CountChar(Whole, '''') - Embedded;
    Doubles := CountChar(Whole, '"');
    if (Doubles > 0) or (Singles > 0) then
      C.Hit(ciStraightQuotes, '', IntToStr(Doubles) + '/' + IntToStr(Singles) + '/' +
        IntToStr(Embedded));
    if HasAny(Whole, '{}') then
      C.Hit(ciCurlyBraces, '', IntToStr(CountMatches(reCurly, Whole)));

    { Block by block (verifyBlockByBlock, reportSectionTitles) }
    NBlocks := 0;
    NAscii := 0;
    LocalChapter := 0;
    LocalVerse := 0;
    LocalRef := '';
    LastHd := '';
    PrevLine := 'xx';
    SentenceEnded := True;
    for I := 0 to High(Texts) do
    begin
      if ChapterOf[I] <> LocalChapter then
      begin
        LocalChapter := ChapterOf[I];
        LocalVerse := 0;
        LocalRef := IntToStr(LocalChapter);
      end;
      for Block in Blocks(Texts[I]) do
      begin
        if PyStrip(Block) = '' then
          Continue;
        ParseLine(Block, Marker, Value, Remainder);
        if Marker = 'c' then
        begin
          LocalChapter := StrToIntDef(A(Value), LocalChapter);
          LocalVerse := 0;
          LocalRef := IntToStr(LocalChapter);
        end
        else if Marker = 'v' then
        begin
          J := Pos('-', Value);
          if J > 0 then
            LocalVerse := StrToIntDef(A(Copy(Value, J + 1, MaxInt)), LocalVerse)
          else
            LocalVerse := StrToIntDef(A(Value), LocalVerse);
          LocalRef := IntToStr(LocalChapter) + ':' + A(Value);
        end;
        if (Marker = 'id') or (Marker = 'ide') or (Marker = 'c') or (Marker = 'cl') then
          Continue;
        if Length(Block) > 10 then
        begin
          Inc(NBlocks);
          if IsAsciiText(Block) then
            Inc(NAscii);
        end;
        if LocalChapter = 0 then
          Continue;
        { reportSectionTitles }
        if Re(reSection).Exec(Block) then
        begin
          LastHd := LocalRef;
          Inc(C.SectionHeadings);
        end;
        if Re(reEmptyTitle).Exec(Block) then
          C.Hit(ciEmptySectionTitle, LocalRef, '');
        if LocalRef <> LastHd then
        begin
          { find_section_heading (a BTT-Writer source has no sections) }
          Heading := '';
          if (LocalVerse = 0) or (PyStrip(PrevLine) = '') or SentenceEnded then
          begin
            Rel := ProbHeading(Block);
            if (Rel >= 0.1) or ((LocalVerse = 0) and (Rel > 0)) then
              Heading := LStrip(Block);
          end;
          if Heading <> '' then
          begin
            if Heading = Block then
              C.Hit(ciSectionTitle, LocalRef, A(PyStrip(Heading)))
            { length_before_heading, then relative_length: report only after
              enough of the verse }
            else if C.RelativeLength(LocalChapter, LocalVerse,
                      Pos(Heading, Block) - 1 - 6) >= 0.6 then
              C.Hit(ciSectionTitleAtEnd, LocalRef, A(PyStrip(Heading)));
            LastHd := LocalRef;
          end;
        end;
        PrevLine := Block;
        SentenceEnded := EndsSentence(Block, True) <> '';
        { reportFootnoteSpacing }
        if (Remainder <> '') and Re(reFSpace).Exec(Block) then
          if not ((Copy(Block, 1, 3) = '\v ') and (Re(reFSpace).MatchPos[0] - 1 < 7)) then
            C.Hit(ciFootnoteSpacing, LocalRef, '\' + A(Re(reFSpace).Match[1]));
      end;
    end;
    C.SuppressAscii := (NBlocks > 0) and (NAscii / NBlocks > 0.02);

    { Token by token (take) }
    Seen := nil;
    SetLength(Seen, ChapterCount(Book) + 1);
    for I := 1 to High(Seen) do
      SetLength(Seen[I], VerseCount(Book, I) + 1);
    for I := 0 to High(Texts) do
    begin
      if ChapterOf[I] <> C.Chapter then
      begin
        if ChapterOf[I] <> 1 then
          C.PreviousVerseCheck;
        C.AddChapter(ChapterOf[I]);
      end;
      Toks := Tokenize(Texts[I]);
      SeenVerseInChunk := False;
      for Tok in Toks do
      begin
        if Tok.Kind = 'text' then
        begin
          if Re(reConflict).Exec(Tok.Value) then
            Continue;
          if not SeenVerseInChunk and not C.InFootnote and (PyStrip(Tok.Value) <> '') then
            C.Hit(ciTextBeforeVerse, Labels[I], A(Copy(PyStrip(Tok.Value), 1, 30)));
          C.TakeText(Tok.Value, C.InFootnote);
        end
        else if Tok.Kind = 'v' then
        begin
          SeenVerseInChunk := True;
          C.TakeV(Tok.Value);
          { BTT-Writer structure }
          V := StrToIntDef(A(Copy(Tok.Value, 1, Pos('-', Tok.Value + '-') - 1)), 0);
          if V = 0 then
            Continue;
          Ch := C.Chapter;
          if V < C.LastVerse then
            C.Hit(ciVerseOrder, C.ShortRef, '');
          if (Ch <= High(Seen)) and (V <= High(Seen[Ch])) then
          begin
            if Seen[Ch][V] then
              C.Hit(ciVerseTwice, IntToStr(Ch) + ':' + IntToStr(V), '')
            else
              Seen[Ch][V] := True;
            for J := V + 1 to C.Verse do
              if J <= High(Seen[Ch]) then
                Seen[Ch][J] := True;
          end
          else if Ch <= High(Seen) then
            C.Hit(ciVerseBeyond, IntToStr(Ch) + ':' + IntToStr(V), IntToStr(VerseCount(Book, Ch)));
        end
        else if Tok.Kind = 'c' then
        begin
          J := StrToIntDef(A(Tok.Value), 0);
          if (J > 0) and (J <> C.Chapter) then
          begin
            C.PreviousVerseCheck;
            C.AddChapter(J);
          end;
        end
        else if InList(Tok.Kind, '|p|pi|pc|nb|m|') then
        begin
          C.TakeP(Tok.Kind);
          if Tok.Value <> '' then
            C.TakeText(Tok.Value, False);
        end
        else if InList(Tok.Kind, FootnoteMarkers) then
          C.TakeFootnote(Tok)
        else if InList(Tok.Kind, '|s|s1|s2|mr|ms|sp|') then
        begin
          C.SetCategory(catS);
          C.InVerse := False;
        end
        else if InList(Tok.Kind, PoetryMarkers) then
        begin
          C.TextOkay := True;
          if Tok.Value <> '' then
            C.SetCategory(catOther)
          else
            C.SetCategory(catQQ);
        end
        else if Tok.Kind = 'b' then
          C.SetCategory(catB);
      end;
    end;
    if C.Chapter > 0 then
      C.PreviousVerseCheck;
    C.ReportUnmatched('([{<');

    if C.FootnoteStarts <> C.FootnoteEnds then
      C.Hit(ciFootnoteMismatch, '', IntToStr(C.FootnoteStarts) + '/' + IntToStr(C.FootnoteEnds));
    if C.SectionHeadings = 1 then
      C.Hit(ciLoneSection, '', '');

    { Verses missing from chapters that have chunks }
    for Ch := 1 to High(Seen) do
    begin
      Missing := nil;
      I := 0;
      for V := 1 to High(Seen[Ch]) do
        if Seen[Ch][V] then
          I := 1;
      if I = 0 then
        Continue;
      for V := 1 to High(Seen[Ch]) do
        if not Seen[Ch][V] and not IsOptionalVerse(Book, Ch, V) then
          Missing := Concat(Missing, [IntToStr(V)]);
      if Length(Missing) > 0 then
        C.Hit(ciMissingVerses, IntToStr(Ch), String.Join(',', Missing));
    end;

    C.ReportMixedCase;
    Result := Copy(C.Hits, 0, C.HitCount);
  finally
    C.FirstRef.Free;
    C.Words.Free;
    C.EnUlbFootnoted.Free;
    C.Footnoted.Free;
    C.SourceNotes.Free;
    C.SourceText.Free;
    C.Free;
  end;
end;

procedure FreeRes;
var
  R: TRe;
begin
  for R in TRe do
    FreeAndNil(Res[R]);
end;

finalization
  FreeRes;

end.
