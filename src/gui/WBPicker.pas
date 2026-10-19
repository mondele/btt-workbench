unit WBPicker;

{$mode objfpc}{$H+}

{ A picker: an editable drop-down for a string option the module can
  suggest values for (TWBModule.Suggestions), like the font box of a word
  processor. Typing completes the value being typed from the suggestions,
  the rest selected, so typing on replaces it; Backspace or Delete do not
  complete. Anything can still be typed. The list shows the suggestions
  matching what is being typed (by value, else anywhere in the caption),
  and choosing one puts its value in.

  Filters take several values, comma-separated ("sah,udm"), so all of this
  works on the part after the last comma: choosing from the list replaces
  that part, and a comma starts the next one.

  Suggestions are asked for (OnNeedSuggestions) when the field is entered
  and when the list opens, so they follow the other fields (the projects
  folder) and what a Find has found. The text and caret are set after the
  widget has finished with the key or the click (QueueAsyncCall): set
  during its own change handling, GTK puts them back. }

interface

uses
  Classes, SysUtils, Forms, StdCtrls, LCLType, WBModule, WBSuggest;

type
  TNeedSuggestions = function(Sender: TObject): TWBSuggestions of object;

  TPickerBox = class(TComboBox)
  private
    FAll: TWBSuggestions;
    FShown: array of Integer;    // Items[I] is FAll[FShown[I]]
    FUpdating: Boolean;          // the text is being set by us
    FNoComplete: Boolean;        // the last key deleted
    FBeforeDrop: string;         // the text when the list opened
    FWant: string;               // async: the text to set
    FWantStart, FWantLength: Integer;
    FWantFrom: string;           // async: only if the text is still this
    FFromList: Boolean;          // async: a list choice, set it regardless
    FOnNeed: TNeedSuggestions;
    procedure Refresh;
    procedure FillList(const Part: string);
    procedure Apply(Data: PtrInt);
  protected
    procedure Change; override;
    procedure Select; override;
    procedure DropDown; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property OnNeedSuggestions: TNeedSuggestions read FOnNeed write FOnNeed;
  end;

implementation

uses
  LazUTF8;

const
  ListLimit = 400;   // a GTK list of 10,000 languages opens slowly

constructor TPickerBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Style := csDropDown;
  AutoComplete := False;     // our own, per comma-separated part
  DropDownCount := 16;
end;

destructor TPickerBox.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

procedure TPickerBox.Refresh;
var
  New: TWBSuggestions;
begin
  if not Assigned(FOnNeed) then
    Exit;
  New := FOnNeed(Self);
  if Length(New) > 0 then
    FAll := New;
end;

procedure TPickerBox.FillList(const Part: string);
var
  M: TBoundArray;
  I: Integer;
begin
  M := Matching(FAll, Part, ListLimit);
  if Length(M) = 0 then
    M := Matching(FAll, '', ListLimit);   // nothing matches: show them all
  FUpdating := True;
  try
    Items.BeginUpdate;
    try
      Items.Clear;
      SetLength(FShown, Length(M));
      for I := 0 to High(M) do
      begin
        FShown[I] := M[I];
        Items.Add(FAll[M[I]].Caption);
      end;
    finally
      Items.EndUpdate;
    end;
  finally
    FUpdating := False;
  end;
end;

procedure TPickerBox.Apply(Data: PtrInt);
begin
  if not FFromList and (Text <> FWantFrom) then
    Exit;     // typed on meanwhile
  FFromList := False;
  FUpdating := True;
  try
    Text := FWant;
    SelStart := FWantStart;
    SelLength := FWantLength;
  finally
    FUpdating := False;
  end;
end;

procedure TPickerBox.Change;
var
  Head, Part: string;
  I: Integer;
begin
  inherited Change;
  if FUpdating or FFromList then
    Exit;
  if FNoComplete then
  begin
    FNoComplete := False;
    Exit;
  end;
  SplitLast(Text, Head, Part);
  I := CompletionOf(FAll, Part);
  if I < 0 then
    Exit;
  FWantFrom := Text;
  FWant := Head + Part + Copy(FAll[I].Value, Length(Part) + 1, MaxInt);
  FWantStart := UTF8Length(Head + Part);
  FWantLength := UTF8Length(FWant) - FWantStart;
  Application.QueueAsyncCall(@Apply, 0);
end;

procedure TPickerBox.Select;
var
  Head, Part: string;
begin
  inherited Select;
  if FUpdating or (ItemIndex < 0) or (ItemIndex > High(FShown)) then
    Exit;
  SplitLast(FBeforeDrop, Head, Part);
  FWant := Head + FAll[FShown[ItemIndex]].Value;
  FWantStart := UTF8Length(FWant);
  FWantLength := 0;
  { the widget may be about to show the caption: replace it once done }
  FFromList := True;
  Application.QueueAsyncCall(@Apply, 0);
end;

procedure TPickerBox.DropDown;
var
  Head, Part: string;
begin
  Refresh;
  FBeforeDrop := Text;
  SplitLast(Text, Head, Part);
  FillList(Part);
  inherited DropDown;
end;

procedure TPickerBox.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key in [VK_BACK, VK_DELETE] then
    FNoComplete := True;
  inherited KeyDown(Key, Shift);
end;

procedure TPickerBox.DoEnter;
begin
  Refresh;
  inherited DoEnter;
end;

end.
