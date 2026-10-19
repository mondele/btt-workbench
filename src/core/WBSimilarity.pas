unit WBSimilarity;

{$mode objfpc}{$H+}

(* How alike two texts are, character by character.

   SequenceRatio is Python's difflib.SequenceMatcher(None, A, B,
   autojunk=False).ratio(): twice the characters in matching blocks over
   the length of both. The cross-language checks were calibrated with it
   (Bwile against Bemba, October 2026), so it follows difflib's own
   algorithm: longest match first (earliest in A, then in B), then the
   same on each side of it.

   TrigramDice is a cheap filter: the share of character triples the two
   have in common. Pairs with a SequenceRatio of 0.78 or more had a
   TrigramDice of at least 0.51 in that calibration. *)

interface

{ difflib.SequenceMatcher(None, A, B, autojunk=False).ratio() }
function SequenceRatio(const A, B: UnicodeString): Double;
{ 2 * shared character triples (counted with repeats) / all triples. }
function TrigramDice(const A, B: UnicodeString): Double;

type
  TTrigrams = array of QWord;
{ A text's character triples, sorted: to compare one text many times. }
function TrigramsOf(const S: UnicodeString): TTrigrams;
{ TrigramDice of two texts' TrigramsOf. }
function DiceOf(const TA, TB: TTrigrams): Double;

implementation

uses
  Generics.Collections, Generics.Defaults;

type
  TIntList = array of Integer;
  TPositions = specialize TDictionary<WideChar, TIntList>;

function SequenceRatio(const A, B: UnicodeString): Double;
var
  B2J: TPositions;
  Prev, Cur: array of Integer;     // j2len, indexed by j + 1
  PrevSet, CurSet: TIntList;       // which entries are set
  NPrev, NCur: Integer;
  Queue: array of array[0..3] of Integer;
  NQueue, ALo, AHi, BLo, BHi, I, J, K, BestI, BestJ, BestSize, Matches: Integer;
  Pos: TIntList;
  L: TIntList;
  T: TIntList;
  TS: Integer;
  C: WideChar;
begin
  if Length(A) + Length(B) = 0 then
    Exit(1.0);
  B2J := TPositions.Create;
  try
    for J := 1 to Length(B) do
    begin
      C := B[J];
      if not B2J.TryGetValue(C, L) then
        L := nil;
      SetLength(L, Length(L) + 1);
      L[High(L)] := J - 1;
      B2J.AddOrSetValue(C, L);
    end;
    SetLength(Prev, Length(B) + 1);
    SetLength(Cur, Length(B) + 1);
    SetLength(PrevSet, Length(B));
    SetLength(CurSet, Length(B));
    NPrev := 0;
    NCur := 0;
    Matches := 0;
    SetLength(Queue, 1);
    Queue[0][0] := 0;
    Queue[0][1] := Length(A);
    Queue[0][2] := 0;
    Queue[0][3] := Length(B);
    NQueue := 1;
    while NQueue > 0 do
    begin
      Dec(NQueue);
      ALo := Queue[NQueue][0];
      AHi := Queue[NQueue][1];
      BLo := Queue[NQueue][2];
      BHi := Queue[NQueue][3];
      { find_longest_match(ALo, AHi, BLo, BHi) }
      BestI := ALo;
      BestJ := BLo;
      BestSize := 0;
      for K := 0 to NPrev - 1 do
        Prev[PrevSet[K] + 1] := 0;
      NPrev := 0;
      for I := ALo to AHi - 1 do
      begin
        NCur := 0;
        C := A[I + 1];
        if B2J.TryGetValue(C, Pos) then
          for J in Pos do
          begin
            if J < BLo then
              Continue;
            if J >= BHi then
              Break;
            K := Prev[J] + 1;    // j2len[j - 1] + 1
            Cur[J + 1] := K;
            CurSet[NCur] := J;
            Inc(NCur);
            if K > BestSize then
            begin
              BestI := I - K + 1;
              BestJ := J - K + 1;
              BestSize := K;
            end;
          end;
        { j2len = newj2len }
        for K := 0 to NPrev - 1 do
          Prev[PrevSet[K] + 1] := 0;
        for K := 0 to NCur - 1 do
        begin
          Prev[CurSet[K] + 1] := Cur[CurSet[K] + 1];
          Cur[CurSet[K] + 1] := 0;
        end;
        T := PrevSet;
        PrevSet := CurSet;
        CurSet := T;
        TS := NPrev;
        NPrev := NCur;
        NCur := TS;
      end;
      if BestSize = 0 then
        Continue;
      Inc(Matches, BestSize);
      if (ALo < BestI) and (BLo < BestJ) then
      begin
        if NQueue >= Length(Queue) then
          SetLength(Queue, NQueue * 2 + 2);
        Queue[NQueue][0] := ALo;
        Queue[NQueue][1] := BestI;
        Queue[NQueue][2] := BLo;
        Queue[NQueue][3] := BestJ;
        Inc(NQueue);
      end;
      if (BestI + BestSize < AHi) and (BestJ + BestSize < BHi) then
      begin
        if NQueue >= Length(Queue) then
          SetLength(Queue, NQueue * 2 + 2);
        Queue[NQueue][0] := BestI + BestSize;
        Queue[NQueue][1] := AHi;
        Queue[NQueue][2] := BestJ + BestSize;
        Queue[NQueue][3] := BHi;
        Inc(NQueue);
      end;
    end;
  finally
    B2J.Free;
  end;
  Result := Double(2 * Matches) / (Length(A) + Length(B));
end;

function TrigramsOf(const S: UnicodeString): TTrigrams;
var
  I: Integer;
begin
  Result := nil;
  if Length(S) < 3 then
    Exit;
  SetLength(Result, Length(S) - 2);
  for I := 1 to Length(S) - 2 do
    Result[I - 1] := (QWord(Ord(S[I])) shl 32) or (QWord(Ord(S[I + 1])) shl 16) or
      QWord(Ord(S[I + 2]));
  specialize TArrayHelper<QWord>.Sort(Result);
end;

function TrigramDice(const A, B: UnicodeString): Double;
begin
  Result := DiceOf(TrigramsOf(A), TrigramsOf(B));
end;

function DiceOf(const TA, TB: TTrigrams): Double;
var
  I, J, Same: Integer;
begin
  if Length(TA) + Length(TB) = 0 then
    Exit(0);
  I := 0;
  J := 0;
  Same := 0;
  while (I < Length(TA)) and (J < Length(TB)) do
    if TA[I] = TB[J] then
    begin
      Inc(Same);
      Inc(I);
      Inc(J);
    end
    else if TA[I] < TB[J] then
      Inc(I)
    else
      Inc(J);
  Result := Double(2 * Same) / (Length(TA) + Length(TB));
end;

end.
