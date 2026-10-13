unit WBUsfmChecks;

{$mode objfpc}{$H+}
{$codepage utf8}  // the regular expressions hold curly quotes

(* Translation text checks, ported from usfm-tools' verifyUSFM.py (Larry
   Versaw, Wycliffe Associates; also txt2USFM.py's marker repairs) to work
   on a BTT-Writer project's chunk files directly, without converting to
   USFM first. Each check keeps verifyUSFM's number, so findings can be
   compared with its issues.txt. Regular expressions are verifyUSFM's,
   run on UnicodeString (uregexpr) so classes such as [’”»›] match whole
   characters.

   Ported so far (tranche 1):
   - structure: verses missing from a chapter (41), beyond the chapter's
     count (8), given twice (40), out of order (39); text before the first
     verse marker of a chunk (54); unknown markers (67); footnote markers
     that do not pair up (9)
   - marker format: no space before (73) or after (74) a verse number,
     nothing before a verse marker (72), \v without a number (66), "/v"
     typed for "\v" (txt2USFM)
   - BTT-Writer leftovers: "Conflict Parsing Error" (57), an unclosed
     angle bracket (56)
   - punctuation: 45, 48, 49, 50, 51, 52, 52.1-52.3, 58, 58.1
   - numbers: 59, 59.1, 59.2, 60, 60.1, 60.2, 61, 61.1, 61.2
   - verses: empty (1), entirely ASCII (3)
   - straight quotes in the project (75), backslash at end of line (78),
     null bytes (79)
   Differences from verifyUSFM: chunks with unresolved conflicts are left
   out (the projects module reports them); all-ASCII verses (3) are only
   reported when most verses are not ASCII, since in a Latin-script
   language every verse is.

   Tranche 2:
   - capitalisation: first word of a sentence (44.1) or paragraph (44)
     not capitalised, with sentences followed across verses and chunks
     as verifyUSFM does (sentences.py); no end punctuation before a
     paragraph marker (26)
   - against the source text (the one the project's chunking follows):
     verses very short for their source (2; without a source, under 12
     characters) and verses probably untranslated (3.5: more than 40%
     of the words shared with the source, Jaccard)
   - mixed-case words used fewer than 5 times (0.4, 0.5)

   Tranche 3: possible section titles typed into the text (76), from
   section_titles.py (WBSectionTitles), line by line as verifyUSFM's
   reportSectionHeadings does.

   Not yet: footnote heuristics (43), the once-only word statistic (0.2)
   and wordlist.tsv. *)

interface

uses
  Classes, SysUtils, WBSources;

type
  TCheckGroup = (cgStructure, cgMarkers, cgPunctuation, cgQuotes, cgNumbers, cgAscii,
    cgCaps, cgSource, cgWords, cgHeadings);
  TCheckGroups = set of TCheckGroup;

  TCheckId = (
    ciMissingVerses, ciVerseBeyond, ciVerseTwice, ciVerseOrder, ciTextBeforeVerse,
    ciUnknownMarker, ciFootnoteMismatch,
    ciNoSpaceBeforeNumber, ciNoSpaceAfterNumber, ciNothingBeforeVerse, ciVerseNoNumber,
    ciSlashVerse,
    ciConflictParsingError, ciAngleBracket,
    ciPunctuation, ciSpaceBeforePunct, ciFreeFloating, ciPunctAfterQuote,
    ciRepeatedQuotes, ciWordMedialPunct, ciSlash, ciBackslash, ciEquals,
    ciOrphanPunct, ciStartsWithPunct,
    ciVerseNumberInText, ciPossibleVerseNumber, ciVerseReference, ciEmbeddedNumber,
    ciNumberPrefix, ciNumberSuffix, ciUnsegmented, ciSpaceInNumber, ciLeadingZero,
    ciEmptyVerse, ciAsciiVerse,
    ciStraightQuotes, ciBackslashEol, ciNullBytes,
    ciCapsParagraph, ciCapsSentence, ciParagraphPunct,
    ciShortVerse, ciUntranslated, ciMixedCase, ciSectionTitle);

  TCheckHit = record
    Id: TCheckId;
    Ref: string;      // "3:16", or a chunk "03-16", or '' for the project
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
  Title chunks ("title", "front") are not checked. Source, if given, is the
  source text compared with (checks 2 and 3.5). }
function CheckChunks(const Book: string; const Chunks: TChunkTexts;
  Groups: TCheckGroups; Source: TSourceChunking = nil): TCheckHits;

implementation

uses
  uregexpr, Character, Generics.Collections, WBVersification, WBPyText, WBSectionTitles;

type
  TStrMap = specialize TDictionary<string, string>;
  TCountMap = specialize TDictionary<string, Integer>;

type
  TCheckInfo = record
    Number: string;
    Group: TCheckGroup;
  end;

const
  Infos: array[TCheckId] of TCheckInfo = (
    (Number: '41'; Group: cgStructure), (Number: '8'; Group: cgStructure),
    (Number: '40'; Group: cgStructure), (Number: '39'; Group: cgStructure),
    (Number: '54'; Group: cgStructure), (Number: '67'; Group: cgMarkers),
    (Number: '9'; Group: cgMarkers),
    (Number: '73'; Group: cgMarkers), (Number: '74'; Group: cgMarkers),
    (Number: '72'; Group: cgMarkers), (Number: '66'; Group: cgMarkers),
    (Number: 'txt2USFM'; Group: cgMarkers),
    (Number: '57'; Group: cgMarkers), (Number: '56'; Group: cgPunctuation),
    (Number: '45'; Group: cgPunctuation), (Number: '48'; Group: cgPunctuation),
    (Number: '49'; Group: cgPunctuation), (Number: '50'; Group: cgPunctuation),
    (Number: '51'; Group: cgQuotes), (Number: '52'; Group: cgPunctuation),
    (Number: '52.1'; Group: cgPunctuation), (Number: '52.2'; Group: cgPunctuation),
    (Number: '52.3'; Group: cgPunctuation),
    (Number: '58'; Group: cgPunctuation), (Number: '58.1'; Group: cgPunctuation),
    (Number: '59'; Group: cgNumbers), (Number: '59.1'; Group: cgNumbers),
    (Number: '59.2'; Group: cgNumbers), (Number: '60'; Group: cgNumbers),
    (Number: '60.1'; Group: cgNumbers), (Number: '60.2'; Group: cgNumbers),
    (Number: '61'; Group: cgNumbers), (Number: '61.1'; Group: cgNumbers),
    (Number: '61.2'; Group: cgNumbers),
    (Number: '1'; Group: cgStructure), (Number: '3'; Group: cgAscii),
    (Number: '75'; Group: cgQuotes), (Number: '78'; Group: cgMarkers),
    (Number: '79'; Group: cgMarkers),
    (Number: '44'; Group: cgCaps), (Number: '44.1'; Group: cgCaps),
    (Number: '26'; Group: cgCaps),
    (Number: '2'; Group: cgSource), (Number: '3.5'; Group: cgSource),
    (Number: '0.4'; Group: cgWords), (Number: '76'; Group: cgHeadings));

  GroupNames: array[TCheckGroup] of string = ('structure', 'markers',
    'punctuation', 'quotes', 'numbers', 'ascii', 'caps', 'source', 'words', 'headings');

  { USFM 3 markers a chunk may hold (digits after a name are allowed). }
  KnownMarkers =
    '|id|ide|h|toc|mt|ms|mr|s|sr|r|d|sp|c|cl|cp|ca|v|va|vp|p|m|pi|mi|nb|pc|pr|' +
    'pmo|pm|pmc|pmr|ph|q|qr|qc|qs|qa|qac|qm|qd|b|li|lh|lf|lim|f|fe|fr|fk|fq|fqa|' +
    'fl|fw|fp|ft|fdc|fv|fm|x|xo|xk|xq|xt|xta|xop|xot|xnt|xdc|add|bk|dc|k|nd|ord|' +
    'pn|png|qt|sig|sls|tl|wj|em|bd|it|bdit|no|sc|sup|w|rq|rb|fig|ndx|pro|ie|im|' +
    'imi|ip|ipi|iq|is|io|iot|ior|imt|ili|ib|iex|cls|rem|usfm|sts|tr|th|thr|tc|tcr|' +
    'periph|ref|jmp|lit|mte|ms|esb|esbe|cat|';

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

{ --- regular expressions (verifyUSFM.py) --- }

type
  TRe = (
    rePunctuation, reSpacey, reSpacey2, reSpacey3, reSpacey4, reWordMedial,
    reOutsideQuote, rePeriod,
    reNumberEmbed, reNumberPrefix, reNumberSuffix, reUnsegmented, reNumberFormat,
    reLeadingZero, reNumber, reChapVerse, reEmbeddedQuote,
    reBadVerse1, reBadVerse2, reBadVerse3, reSlashVerse, reBackslashEol,
    reEndSentence, reBadQuoted, reFirstWord, reEndSent);

const
  Patterns: array[TRe] of UnicodeString = (
    '([.?!;:,][^\s\x{200b})\]''"’”»›])',
    '[\s]([.?!;:,)’”»›])',
    '[\s][\[\]\(''"«“‘’”»›][\s]',
    '^[\(''"«“‘’”»›][\s]',
    '[\s][\(''"«“‘’”»›]$',
    '[\w][.?!;:,()\[\]"«“‘”»›][.?!;:,()\[\]''"«“‘’”»›]*[\w]',
    '([''"’”»›][.!])',
    '^[\s]*[.,;:!?]',
    '[^\s,:.\d(\[\-]+[\d]+[^\s,;.\d)\]]+',
    '[^\s,.\d(\[]\d+',
    '[\d]+[^\s,;:.\-?!"\d)\]]',
    '[\d][\d][\d][\d]+',
    '[\d]+[.,]?\s[.,]?[\d]+',
    '[\s]0[0-9,]*',
    '[^\d(](\d+)[^\d,]',
    '(\d+)([:\-])(\d+)',
    '\w''\w',
    '([^\n\r\s]\\v\s*\d+)',
    '(\\v[0-9]+)',
    '(\\v\s*[-0-9]+[^-\d\s])',
    '(^|\s)/v\s*\d+',
    '\\ *\n',
    { sentences.py }
    '[.?!\x{0964}\x{0965}\x{1361}\x{1362}][^\w]*$',
    '^[?!\x{1361}\x{1362}]+[«“‘\-\x{2014}\x{2013}]',
    '(\w+-\w+|\w+)',
    '[.?!\x{0964}\x{0965}\x{1361}\x{1362}].*?(\w+-\w+|\w+)');

var
  Res: array[TRe] of TRegExpr;

function Re(R: TRe): TRegExpr;
begin
  if Res[R] = nil then
  begin
    Res[R] := TRegExpr.Create(Patterns[R]);
    Res[R].UseUnicodeWordDetection := True;
    Res[R].ModifierS := R = reEndSent;     // re.DOTALL
    Res[R].ModifierM := False;
  end;
  Result := Res[R];
end;

{ UTF-8 to UnicodeString, with Unicode spaces made plain spaces: Python's
  \s matches them, uregexpr's does not. One character for one, so
  positions do not move. }
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

{ verifyUSFM's context(): the words around Start..Finish (1-based). }
function Context(const T: UnicodeString; Start, Finish: Integer): UnicodeString;
var
  S, E, I: Integer;
begin
  if Start < 1 then
    S := 1
  else
  begin
    S := 1;
    for I := Start - 1 downto 1 do
      if T[I] = ' ' then
      begin
        S := I + 1;
        Break;
      end;
  end;
  E := 0;
  for I := Finish to Length(T) - 1 do
    if T[I] = ' ' then
    begin
      E := I;
      Break;
    end;
  if E > S then
    Result := Copy(T, S, E - S)
  else
    Result := Copy(T, S, MaxInt);
end;

{ --- checker state --- }

type
  TChecker = class
    Book: string;
    Groups: TCheckGroups;
    Hits: TCheckHits;
    HitCount: Integer;
    Chapter, Verse: Integer;
    SentenceEnd, AfterParagraph: Boolean;
    Words: TCountMap;      // word -> count
    FirstRef: TStrMap;     // word -> reference of its first use
    WordOrder: TStringList;
    procedure Hit(Id: TCheckId; const Ref, Detail: string);
    function VerseRef: string;
    procedure CheckPunctuation(const T: UnicodeString);
    procedure CheckNumbers(const T: UnicodeString; Footnote: Boolean);
    procedure TakeText(const T: UnicodeString; Footnote: Boolean);
    procedure CheckCaps(const T: UnicodeString);
    procedure AddWords(const T: UnicodeString);
  end;

{ verifyUSFM's isMixed. }
function IsMixed(const W: UnicodeString): Boolean;
var
  W2: UnicodeString;
  C: WideChar;
begin
  Result := False;
  if AllLower(W) or IsTitle(W) or AllUpper(W) then
    Exit;
  W2 := '';
  for C in W do
    if Pos(C, UnicodeString('''’"-_()–&')) = 0 then
      W2 := W2 + C;
  Result := (W2 <> '') and not (AllLower(W2) or IsTitle(W2) or AllUpper(W2));
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

function TChecker.VerseRef: string;
begin
  Result := IntToStr(Chapter) + ':' + IntToStr(Verse);
end;

procedure TChecker.CheckPunctuation(const T: UnicodeString);
var
  I: Integer;
  Chars: UnicodeString;
  M: TRegExpr;
  Found: Boolean;
  S: UnicodeString;
begin
  if Re(rePunctuation).Exec(T) then
  begin
    I := Re(rePunctuation).MatchPos[0];
    if (Copy(T, I, 3) <> '...') or (Copy(T, I, 4) = '....') then
    begin
      Chars := Re(rePunctuation).Match[1];
      if not ((Pos(Chars[1], ',.') > 0) and (Pos(Chars[2], '0123456789') > 0)) and
         not ((Chars[1] = ':') and (Pos(Chars[2], '0123456789') > 0)) then
        Hit(ciPunctuation, VerseRef, A(Chars));
    end;
  end;
  if Re(reSpacey).Exec(T) then
    Hit(ciSpaceBeforePunct, VerseRef, A(Re(reSpacey).Match[1]));
  if Re(reOutsideQuote).Exec(T) then
  begin
    I := Re(reOutsideQuote).MatchPos[0];
    if Copy(T, I + 1, 3) <> '...' then
      Hit(ciPunctAfterQuote, VerseRef, A(Re(reOutsideQuote).Match[1]));
  end;
  Found := True;
  M := Re(reSpacey2);
  if M.Exec(T) then
    S := Context(T, M.MatchPos[0] - 2, M.MatchPos[0] + M.MatchLen[0] + 2)
  else if Re(reSpacey3).Exec(T) then
    S := Context(T, 1, Re(reSpacey3).MatchLen[0] + 2)
  else if Re(reSpacey4).Exec(T) then
    S := Context(T, Re(reSpacey4).MatchPos[0] - 2, Length(T))
  else
    Found := False;
  if Found then
    Hit(ciFreeFloating, VerseRef, A(Trim(S)));
  if (Pos('''''', T) > 0) or (Pos('""', T) > 0) then
    Hit(ciRepeatedQuotes, VerseRef, '');
  M := Re(reWordMedial);
  if M.Exec(T) and (Pos(T[M.MatchPos[0] + M.MatchLen[0] - 1], '0123456789') = 0) then
    Hit(ciWordMedialPunct, VerseRef, A(Context(T, M.MatchPos[0], M.MatchPos[0] + M.MatchLen[0])));
  if Pos('/', T) > 0 then
    Hit(ciSlash, VerseRef, '');
  if Pos('\', T) > 0 then
    Hit(ciBackslash, VerseRef, '');
  if Pos('=', T) > 0 then
    Hit(ciEquals, VerseRef, '');
end;

procedure TChecker.CheckNumbers(const T: UnicodeString; Footnote: Boolean);
var
  VerseFlag: Boolean;
  M: TRegExpr;
  G0: UnicodeString;
begin
  VerseFlag := False;
  if (Chapter > 0) and not Footnote then
  begin
    if Copy(T, 1, Length(IntToStr(Verse)) + 1) = UnicodeString(IntToStr(Verse) + ' ') then
    begin
      Hit(ciVerseNumberInText, VerseRef, '');
      VerseFlag := True;
    end
    else
    begin
      M := Re(reNumber);
      if M.Exec(T) then
        repeat
          if (M.Match[1] = UnicodeString(IntToStr(Verse))) or
             (M.Match[1] = UnicodeString(IntToStr(Verse + 1))) then
          begin
            Hit(ciPossibleVerseNumber, VerseRef, A(M.Match[1]));
            VerseFlag := True;
          end;
          { verifyUSFM searches again from the end - 1 }
        until not M.ExecPos(M.MatchPos[0] + M.MatchLen[0] - 1);
    end;
    if not VerseFlag then
    begin
      M := Re(reChapVerse);
      if M.Exec(T) then
        repeat
          if (M.Match[2] = ':') or
             (StrToIntDef(A(M.Match[3]), 0) > StrToIntDef(A(M.Match[1]), 0)) then
          begin
            Hit(ciVerseReference, VerseRef, A(M.Match[0]));
            VerseFlag := True;
          end;
        until not M.ExecNext;
    end;
  end;
  if Re(reNumberEmbed).Exec(T) then
    Hit(ciEmbeddedNumber, VerseRef, A(Re(reNumberEmbed).Match[0]))
  else if not VerseFlag then
  begin
    if Re(reNumberSuffix).Exec(T) and (Chapter > 0) and not Footnote then
      Hit(ciNumberSuffix, VerseRef, A(Re(reNumberSuffix).Match[0]));
    if Re(reNumberPrefix).Exec(T) then
    begin
      G0 := Re(reNumberPrefix).Match[0];
      if ((Chapter > 0) and not Footnote) or not ((G0[1] = ':') or (G0[1] = '-')) then
        Hit(ciNumberPrefix, VerseRef, A(G0));
    end;
  end;
  if Re(reUnsegmented).Exec(T) and (Re(reUnsegmented).MatchLen[0] > 4) then
    Hit(ciUnsegmented, VerseRef, A(Re(reUnsegmented).Match[0]));
  if Re(reNumberFormat).Exec(T) then
    Hit(ciSpaceInNumber, VerseRef, A(Re(reNumberFormat).Match[0]))
  else if Re(reLeadingZero).Exec(T) then
    Hit(ciLeadingZero, VerseRef, A(Trim(Re(reLeadingZero).Match[0])));
end;

{ reportCaps, then the sentence state (sentences.py). }
procedure TChecker.CheckCaps(const T: UnicodeString);
var
  Word: UnicodeString;
  M: TRegExpr;
begin
  if SentenceEnd and Re(reFirstWord).Exec(T) then
  begin
    Word := Re(reFirstWord).Match[1];
    if (Word <> '') and IsLowerChar(Word[1]) then
      if AfterParagraph then
        Hit(ciCapsParagraph, VerseRef, A(Word))
      else
        Hit(ciCapsSentence, VerseRef, A(Word));
  end;
  M := Re(reEndSent);
  if M.Exec(T) then
    repeat
      Word := M.Match[1];
      if (Word <> '') and IsLowerChar(Word[1]) and
         not Re(reBadQuoted).Exec(Copy(T, M.MatchPos[0], 2)) then
        Hit(ciCapsSentence, VerseRef, A(Word));
    until not M.ExecNext;
  SentenceEnd := Re(reEndSentence).Exec(T);
  AfterParagraph := False;
end;

{ verifyUSFM's addWords, for the mixed-case check. }
procedure TChecker.AddWords(const T: UnicodeString);
const
  StripChars: UnicodeString = '.,:;!?+-[]{}()<>"“‘’”*/''';
var
  Item, W: UnicodeString;
  Key: string;
  C: WideChar;
  HasDigit: Boolean;
  I: Integer;
begin
  for Item in SplitWords(T) do
  begin
    W := Item;
    while (W <> '') and (Pos(W[1], StripChars) > 0) do
      Delete(W, 1, 1);
    while (W <> '') and (Pos(W[Length(W)], StripChars) > 0) do
      SetLength(W, Length(W) - 1);
    if W = '' then
      Continue;
    HasDigit := False;
    for C in W do
      if TCharacter.IsNumber(C) then
        HasDigit := True;
    if HasDigit then
      Continue;
    Key := A(W);
    if Words.TryGetValue(Key, I) then
      Words[Key] := I + 1
    else
    begin
      Words.Add(Key, 1);
      FirstRef.Add(Key, VerseRef);
      WordOrder.Add(Key);
    end;
  end;
end;

procedure TChecker.TakeText(const T: UnicodeString; Footnote: Boolean);
begin
  if T = '' then
    Exit;
  if (Pos('<', T) > 0) and (Pos('>', T) = 0) and (Pos('<< HEAD', T) = 0) then
    Hit(ciAngleBracket, VerseRef, '');
  if Pos('Conflict Parsing Error', T) > 0 then
    Hit(ciConflictParsingError, VerseRef, '');
  CheckPunctuation(T);
  if Re(rePeriod).Exec(T) then
  begin
    if Length(T) <= Re(rePeriod).MatchLen[0] + 1 then
      Hit(ciOrphanPunct, VerseRef, '')
    else
      Hit(ciStartsWithPunct, VerseRef, '');
  end;
  CheckNumbers(T, Footnote);
  if not Footnote then
  begin
    CheckCaps(T);
    AddWords(T);
  end;
end;

{ --- tokens --- }

type
  TTokenKind = (tkMarker, tkText);
  TToken = record
    Kind: TTokenKind;
    Name: UnicodeString;    // marker name without '\', '*' kept (e.g. 'f*')
    Number: UnicodeString;  // \v and \c
    Text: UnicodeString;
  end;
  TTokens = array of TToken;

function IsMarkerChar(C: WideChar): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
    ((C >= '0') and (C <= '9')) or (C = '-');
end;

function Tokenize(const S: UnicodeString): TTokens;
var
  I, Start: Integer;
  T: TToken;

  procedure Add(const Tok: TToken);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Tok;
  end;

begin
  Result := nil;
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '\') and (I < Length(S)) and IsMarkerChar(S[I + 1]) then
    begin
      Start := I + 1;
      Inc(I);
      while (I <= Length(S)) and IsMarkerChar(S[I]) do
        Inc(I);
      T.Kind := tkMarker;
      T.Name := LowerCase(Copy(S, Start, I - Start));
      T.Number := '';
      T.Text := '';
      if (I <= Length(S)) and (S[I] = '*') then
      begin
        T.Name := T.Name + '*';
        Inc(I);
      end
      else if (T.Name = 'v') or (T.Name = 'c') then
      begin
        while (I <= Length(S)) and (S[I] = ' ') do
          Inc(I);
        Start := I;
        while (I <= Length(S)) and (((S[I] >= '0') and (S[I] <= '9')) or (S[I] = '-')) do
          Inc(I);
        T.Number := Copy(S, Start, I - Start);
      end;
      Add(T);
    end
    else
    begin
      Start := I;
      Inc(I);
      while (I <= Length(S)) and not ((S[I] = '\') and (I < Length(S)) and IsMarkerChar(S[I + 1])) do
        Inc(I);
      T.Kind := tkText;
      T.Name := '';
      T.Number := '';
      T.Text := Copy(S, Start, I - Start);
      Add(T);
    end;
  end;
end;

type
  TLines = array of UnicodeString;

{ contents.split('\n'), carriage returns dropped. }
function SplitLines(const T: UnicodeString): TLines;
var
  I, Start: Integer;
begin
  Result := nil;
  Start := 1;
  for I := 1 to Length(T) + 1 do
    if (I > Length(T)) or (T[I] = #10) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := StringReplace(Copy(T, Start, I - Start), #13, '', [rfReplaceAll]);
      Start := I + 1;
    end;
end;

function BaseMarker(const Name: UnicodeString): string;
var
  N: string;
begin
  N := A(Name);
  if (N <> '') and (N[Length(N)] = '*') then
    SetLength(N, Length(N) - 1);
  while (N <> '') and (N[Length(N)] in ['0'..'9']) do
    SetLength(N, Length(N) - 1);
  Result := N;
end;

function IsAscii(const S: UnicodeString): Boolean;
var
  C: WideChar;
begin
  for C in S do
    if Ord(C) > 127 then
      Exit(False);
  Result := True;
end;

{ --- the project --- }

function CheckChunks(const Book: string; const Chunks: TChunkTexts;
  Groups: TCheckGroups; Source: TSourceChunking): TCheckHits;
type
  TVerseText = record
    Chapter, Verse: Integer;
    Text: UnicodeString;
  end;
var
  C: TChecker;
  Chunk: TChunkText;
  Toks: TTokens;
  Tok: TToken;
  Text, Whole: UnicodeString;
  Label_: string;
  I, Ch, V, PrevV, Opened, Closed, Embedded, Singles, Doubles: Integer;
  InNote, SeenVerse: Boolean;
  Verses: array of TVerseText;
  Seen: array of array of Boolean;     // [chapter][verse]
  Missing: TStringArray;
  M: TRegExpr;
  SourceText: TStrMap;         // "c:v" -> source verse text
  SrcLen, TgtLen: Int64;
  SrcWords, TgtWords: TStringList;
  Src, W, Info: string;
  Common, Union_, J: Integer;
  Name, Line, Title: UnicodeString;

  procedure AddVerseText(const T: UnicodeString);
  begin
    if (Length(Verses) > 0) and (Verses[High(Verses)].Chapter = Ch) and
       (Verses[High(Verses)].Verse = C.Verse) then
      Verses[High(Verses)].Text := Verses[High(Verses)].Text + T;
  end;

begin
  C := TChecker.Create;
  SourceText := TStrMap.Create;
  SrcWords := TStringList.Create;
  TgtWords := TStringList.Create;
  C.Words := TCountMap.Create;
  C.FirstRef := TStrMap.Create;
  C.WordOrder := TStringList.Create;
  try
    C.Book := UpperCase(Book);
    C.Groups := Groups;
    C.Hits := nil;
    C.SentenceEnd := True;
    C.AfterParagraph := False;
    if Source <> nil then
      for I := 0 to High(Source.Chunks) do
        for J := 0 to High(Source.Chunks[I].Verses) do
          if (StrToIntDef(Source.Chunks[I].Chapter, 0) > 0) and (J <= High(Source.Chunks[I].Texts)) then
            SourceText.AddOrSetValue(IntToStr(StrToInt(Source.Chunks[I].Chapter)) + ':' +
              IntToStr(Source.Chunks[I].Verses[J]), Source.Chunks[I].Texts[J]);
    Verses := nil;
    Seen := nil;
    SetLength(Seen, ChapterCount(Book) + 1);
    for I := 1 to High(Seen) do
      SetLength(Seen[I], VerseCount(Book, I) + 1);
    Whole := '';
    for Chunk in Chunks do
    begin
      Ch := StrToIntDef(Chunk.Chapter, 0);
      if (Ch = 0) or (StrToIntDef(Chunk.Chunk, -1) < 0) then
        Continue;     // front matter and titles
      Label_ := Chunk.Chapter + '-' + Chunk.Chunk;
      Text := U(Chunk.Text);
      if (Copy(Text, 1, 8) = '<<<<<<< ') or (Pos(#10'<<<<<<< ', Text) > 0) then
        Continue;     // unresolved conflict: holds every version
      Whole := Whole + Text + #10;
      C.Chapter := Ch;
      C.Verse := 0;

      { Possible section titles, line by line (reportSectionHeadings) }
      for Line in SplitLines(Text) do
        if LineHasHeading(Line, Title) then
          C.Hit(ciSectionTitle, Label_, A(Title));

      { Marker format, on the raw chunk (verifyChapterAndVerseMarkers). }
      M := Re(reBadVerse1);
      if M.Exec(Text) then
        repeat
          C.Hit(ciNothingBeforeVerse, Label_, A(Trim(M.Match[1])));
        until not M.ExecNext;
      M := Re(reBadVerse2);
      if M.Exec(Text) then
        repeat
          C.Hit(ciNoSpaceBeforeNumber, Label_, A(M.Match[1]));
        until not M.ExecNext;
      M := Re(reBadVerse3);
      if M.Exec(Text) then
        repeat
          C.Hit(ciNoSpaceAfterNumber, Label_, A(M.Match[1]));
        until not M.ExecNext;
      if Re(reSlashVerse).Exec(Text) then
        C.Hit(ciSlashVerse, Label_, A(Trim(Re(reSlashVerse).Match[0])));
      if Re(reBackslashEol).Exec(Text + #10) then
        C.Hit(ciBackslashEol, Label_, '');
      if Pos(#0, Text) > 0 then
        C.Hit(ciNullBytes, Label_, '');

      Toks := Tokenize(Text);
      InNote := False;
      SeenVerse := False;
      Opened := 0;
      Closed := 0;
      PrevV := 0;
      for Tok in Toks do
        if Tok.Kind = tkMarker then
        begin
          if (Tok.Name = 'f') or (Tok.Name = 'fe') or (Tok.Name = 'x') then
          begin
            Inc(Opened);
            InNote := True;
          end
          else if (Tok.Name = 'f*') or (Tok.Name = 'fe*') or (Tok.Name = 'x*') then
          begin
            Inc(Closed);
            InNote := False;
          end
          else if Tok.Name = 'v' then
          begin
            SeenVerse := True;
            V := StrToIntDef(A(Copy(Tok.Number, 1,
              Pos('-', Tok.Number + '-') - 1)), 0);
            if V = 0 then
            begin
              C.Hit(ciVerseNoNumber, Label_, '');
              Continue;
            end;
            C.Verse := V;
            if V < PrevV then
              C.Hit(ciVerseOrder, C.VerseRef, '');
            PrevV := V;
            if (Ch <= High(Seen)) and (V <= High(Seen[Ch])) then
            begin
              if Seen[Ch][V] then
                C.Hit(ciVerseTwice, C.VerseRef, '')
              else
                Seen[Ch][V] := True;
              { A range \v 4-5 covers both. }
              if Pos('-', Tok.Number) > 0 then
                for I := V + 1 to StrToIntDef(A(Copy(Tok.Number, Pos('-', Tok.Number) + 1, MaxInt)), V) do
                  if I <= High(Seen[Ch]) then
                    Seen[Ch][I] := True;
            end
            else if Ch <= High(Seen) then
              C.Hit(ciVerseBeyond, C.VerseRef, IntToStr(VerseCount(Book, Ch)));
            SetLength(Verses, Length(Verses) + 1);
            Verses[High(Verses)].Chapter := Ch;
            Verses[High(Verses)].Verse := V;
            Verses[High(Verses)].Text := '';
          end
          else if (Tok.Name = 'p') or (Tok.Name = 'm') or (Tok.Name = 'mi') or
                  (Tok.Name = 'nb') or (Tok.Name = 'pc') or (BaseMarker(Tok.Name) = 'pi') then
          begin
            { takeP: a paragraph should start after a finished sentence. }
            if not C.SentenceEnd and (Tok.Name <> 'm') and (C.Verse > 0) then
              C.Hit(ciParagraphPunct, C.VerseRef, '');
            if Tok.Name <> 'nb' then
            begin
              C.SentenceEnd := True;
              C.AfterParagraph := True;
            end;
          end
          else if (Tok.Name <> 'c') and
                  (Pos('|' + BaseMarker(Tok.Name) + '|', KnownMarkers) = 0) then
            C.Hit(ciUnknownMarker, Label_, '\' + A(Tok.Name));
        end
        else
        begin
          if Trim(Tok.Text) = '' then
            Continue;
          if not SeenVerse and not InNote then
          begin
            C.Hit(ciTextBeforeVerse, Label_, A(Copy(Trim(Tok.Text), 1, 30)));
            Continue;
          end;
          C.TakeText(Trim(Tok.Text), InNote);
          if not InNote then
            AddVerseText(Trim(Tok.Text));
        end;
      if Opened <> Closed then
        C.Hit(ciFootnoteMismatch, Label_, IntToStr(Opened) + '/' + IntToStr(Closed));
    end;

    { Book lengths for the short-verse ratio: target and source text of the
      verses both have. }
    SrcLen := 0;
    TgtLen := 0;
    for I := 0 to High(Verses) do
    begin
      if not SourceText.TryGetValue(IntToStr(Verses[I].Chapter) + ':' +
        IntToStr(Verses[I].Verse), Src) then
        Src := '';
      if Src <> '' then
      begin
        Inc(SrcLen, Length(U(Src)));
        Inc(TgtLen, Length(Verses[I].Text));
      end;
    end;

    { Empty, very short, untranslated and all-ASCII verses
      (previousVerseCheck) }
    Singles := 0;     // here: verses that are ASCII
    for I := 0 to High(Verses) do
      if (Verses[I].Text <> '') and IsAscii(Verses[I].Text) then
        Inc(Singles);
    for I := 0 to High(Verses) do
    begin
      C.Chapter := Verses[I].Chapter;
      C.Verse := Verses[I].Verse;
      if (Verses[I].Text = '') and not IsOptionalVerse(Book, C.Chapter, C.Verse) then
      begin
        C.Hit(ciEmptyVerse, C.VerseRef, '');
        Continue;
      end;
      { shortened_verse }
      if not SourceText.TryGetValue(C.VerseRef, Src) then
        Src := '';
      if (Src <> '') and not ((C.Book = 'PSA') and (C.Verse = 1)) then
      begin
        if (SrcLen > 0) and (Length(Verses[I].Text) / Length(U(Src)) < 0.4 * TgtLen / SrcLen) then
          C.Hit(ciShortVerse, C.VerseRef, '');
      end
      else if (Length(Verses[I].Text) < 12) and not IsShortVerse(Book, C.Chapter, C.Verse) then
        C.Hit(ciShortVerse, C.VerseRef, '');
      if (Verses[I].Text <> '') and IsAscii(Verses[I].Text) and
         (Singles * 2 < Length(Verses)) then
        C.Hit(ciAsciiVerse, C.VerseRef, '');
      { similarToSource: shared words of 3+ letters in lower case, over all
        distinct words of both (Jaccard) }
      if Src <> '' then
      begin
        SrcWords.Clear;
        TgtWords.Clear;
        SrcWords.Sorted := True;
        SrcWords.Duplicates := dupIgnore;
        SrcWords.CaseSensitive := True;
        TgtWords.Sorted := True;
        TgtWords.Duplicates := dupIgnore;
        TgtWords.CaseSensitive := True;
        for W in Src.Split([' ']) do
          if W <> '' then
            SrcWords.Add(W);
        for W in A(Verses[I].Text).Split([' ']) do
          if W <> '' then
            TgtWords.Add(W);
        Common := 0;
        Union_ := SrcWords.Count;
        for W in TgtWords do
          if SrcWords.IndexOf(W) >= 0 then
          begin
            if (Length(U(W)) > 2) and AllLower(U(W)) then
              Inc(Common);
          end
          else
            Inc(Union_);
        if (Union_ > 0) and (Common / Union_ > 0.4) then
          C.Hit(ciUntranslated, C.VerseRef, '');
      end;
    end;

    { Verses missing from chapters that have chunks }
    for Ch := 1 to High(Seen) do
    begin
      Missing := nil;
      I := 0;
      for V := 1 to High(Seen[Ch]) do
        if Seen[Ch][V] then
          I := 1;
      if I = 0 then
        Continue;     // chapter not started: not reported verse by verse
      for V := 1 to High(Seen[Ch]) do
        if not Seen[Ch][V] and not IsOptionalVerse(Book, Ch, V) then
          Missing := Concat(Missing, [IntToStr(V)]);
      if Length(Missing) > 0 then
        C.Hit(ciMissingVerses, IntToStr(Ch), String.Join(',', Missing));
    end;

    { Straight quotes in the whole project }
    Embedded := 0;
    if Re(reEmbeddedQuote).Exec(Whole) then
      repeat
        Inc(Embedded);
      until not Re(reEmbeddedQuote).ExecNext;
    Singles := 0;
    Doubles := 0;
    for I := 1 to Length(Whole) do
      if Whole[I] = '''' then
        Inc(Singles)
      else if Whole[I] = '"' then
        Inc(Doubles);
    Singles := Singles - Embedded;
    if (Doubles > 0) or (Singles > 0) then
      C.Hit(ciStraightQuotes, '', IntToStr(Doubles) + '/' + IntToStr(Singles) + '/' +
        IntToStr(Embedded));
    { Mixed-case words used fewer than five times (reportMixedCase) }
    for Info in C.WordOrder do
    begin
      Name := U(Info);
      if (C.Words[Info] < 5) and IsMixed(Name) then
        C.Hit(ciMixedCase, C.FirstRef[Info], Info);
    end;
    Result := Copy(C.Hits, 0, C.HitCount);
  finally
    C.Words.Free;
    C.FirstRef.Free;
    C.WordOrder.Free;
    TgtWords.Free;
    SrcWords.Free;
    SourceText.Free;
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
