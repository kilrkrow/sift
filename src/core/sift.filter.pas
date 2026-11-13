unit Sift.Filter;

{ The Sift filter AST. One object describes everything the viewer (and later
  the MCP server) can ask for. No LCL references. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TSiftField = (sfChannel, sfLevel, sfProvider, sfEventId, sfTask,
    sfKeywords, sfUser, sfComputer, sfTime, sfMessage);

  TSiftAction = (saInclude, saExclude);

  { How a right-click term is applied: add to the current filter, or replace
    all include/exclude terms with this one term (channel scope and time
    window are kept). }
  TSiftApplyMode = (amAdd, amSet);

  TSiftTimeMode = (tmAll, tmRelative, tmAbsolute);

  TSiftTerm = record
    Field: TSiftField;
    Action: TSiftAction;
    { Value encoding per field:
      sfChannel   channel name or file://path
      sfLevel     '0'..'5'; '4' (Information) also matches level 0
      sfProvider  provider name
      sfEventId   decimal event ID
      sfTask      decimal task number
      sfKeywords  decimal or 0x-hex 64-bit mask
      sfUser      SID string (S-1-...)
      sfComputer  computer name
      sfTime      UTC ISO 8601 'yyyy-mm-ddThh:nn:ss.zzzZ'; Include = at or
                  after this time, Exclude = drop at or after this time
      sfMessage   case-insensitive substring (client-side) }
    Value: string;
  end;

  TSiftTermArray = array of TSiftTerm;

  { TSiftFilter }
  TSiftFilter = class
  private
    FChannels: TStringList;
    FTerms: TSiftTermArray;
    FTimeMode: TSiftTimeMode;
    FRelativeMs: Int64;
    FStartUtc: TDateTime;
    FEndUtc: TDateTime;
    FLastN: Integer;
    FTextScanCap: Integer;
    function GetTerm(I: Integer): TSiftTerm;
    function GetTermCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Src: TSiftFilter);
    function Clone: TSiftFilter;
    function SameAs(Other: TSiftFilter): Boolean;
    procedure Clear;
    procedure ClearTerms;

    function IndexOfTerm(const T: TSiftTerm): Integer;
    function AddTerm(const T: TSiftTerm): Integer;
    procedure DeleteTerm(Index: Integer);

    { The right-click entry point: Include/Exclude the cell value with
      Add-to or Set-as semantics. Returns True if the filter changed. }
    function ApplyCell(Field: TSiftField; const Value: string;
      Action: TSiftAction; Mode: TSiftApplyMode): Boolean;

    { Quick "Last N" buttons: newest N events, any time (clears the window). }
    procedure SetLastN(N: Integer);
    procedure SetTextScanCapValue(N: Integer);
    { Hard ceiling: LastN is raised from 0 or reduced if it exceeds RowCap. }
    procedure ApplyRowCap(RowCap: Integer);
    { Toolbar max count: caps the result at N (MaxEvents) and keeps the
      current time window. 0 = no cap. }
    procedure SetMaxCount(N: Integer);
    procedure SetRelativeWindow(Ms: Int64);
    procedure SetAbsoluteWindow(StartUtc, EndUtc: TDateTime);
    procedure ClearWindow;

    function HasTextTerms: Boolean;
    function HasExcludes: Boolean;
    function TermsFor(Field: TSiftField; Action: TSiftAction): TStringArray;

    { The channels this filter queries: Include-channel terms if present,
      otherwise Channels; minus Exclude-channel terms. '*' in Channels means
      every enabled Admin/Operational channel (resolved by the caller). }
    function EffectiveChannels(const AllChannels: TStrings): TStringArray;

    property Channels: TStringList read FChannels;
    property Terms[I: Integer]: TSiftTerm read GetTerm;
    property TermCount: Integer read GetTermCount;
    property TimeMode: TSiftTimeMode read FTimeMode;
    property RelativeMs: Int64 read FRelativeMs;
    property StartUtc: TDateTime read FStartUtc;
    property EndUtc: TDateTime read FEndUtc;
    property LastN: Integer read FLastN;
    property TextScanCap: Integer read FTextScanCap write SetTextScanCapValue;
  end;

const
  SiftFieldNames: array[TSiftField] of string = ('channel', 'level',
    'provider', 'eventId', 'task', 'keywords', 'user', 'computer', 'time',
    'message');
  SiftFieldCaptions: array[TSiftField] of string = ('Channel', 'Level',
    'Provider', 'Event ID', 'Task', 'Keywords', 'User', 'Computer', 'Time',
    'Message');
  SiftActionNames: array[TSiftAction] of string = ('include', 'exclude');
  DefaultTextScanCap = 20000;
  { Documented maxima (v0.1.1). lastN, textScanCap and the AllTimeRowCap
    ini value are clamped to these at parse / set time. A query never
    holds more than MaxRowCap rows. }
  MaxLastN = 200000;
  MaxTextScanCap = 200000;
  MaxRowCap = 200000;
  DefaultAllTimeRowCap = 200000;

  LevelNames: array[0..5] of string = ('Information', 'Critical', 'Error',
    'Warning', 'Information', 'Verbose');

function MakeTerm(Field: TSiftField; Action: TSiftAction;
  const Value: string): TSiftTerm;
function SameTerm(const A, B: TSiftTerm): Boolean;
function TermCaption(const T: TSiftTerm): string;
function FieldFromName(const S: string; out F: TSiftField): Boolean;
function NormalizeTermValue(Field: TSiftField; const Value: string;
  out Normalized: string): Boolean;
{ Shared by JSON load, paste, --filter, ini reload and right-click Include. }
function UnsafeValueReason(const Value: string): string;
function IsValidSidString(const Value: string): Boolean;
function IsFileChannel(const Channel: string): Boolean;
function IsRemoteChannel(const Channel: string): Boolean;
function IsAllowedFileChannel(const Channel: string): Boolean;
function ClampLastN(N: Integer): Integer;
function ClampTextScanCap(N: Integer): Integer;
function ClampRowCap(N: Integer): Integer;

function UtcToIso(const D: TDateTime): string;
function IsoToUtc(const S: string; out D: TDateTime): Boolean;
function LevelCaption(Level: Integer): string;
function LevelFromCaption(const S: string): Integer;

implementation

uses
  DateUtils;

function AllDigits(const S: string): Boolean; forward;

function MakeTerm(Field: TSiftField; Action: TSiftAction;
  const Value: string): TSiftTerm;
begin
  Result.Field := Field;
  Result.Action := Action;
  Result.Value := Value;
end;

function SameTerm(const A, B: TSiftTerm): Boolean;
begin
  Result := (A.Field = B.Field) and (A.Action = B.Action);
  if not Result then
    Exit;
  case A.Field of
    sfProvider, sfComputer, sfChannel, sfMessage, sfUser:
      Result := SameText(A.Value, B.Value);
  else
    Result := A.Value = B.Value;
  end;
end;

function LevelCaption(Level: Integer): string;
begin
  if (Level >= 0) and (Level <= 5) then
    Result := LevelNames[Level]
  else
    Result := 'Level ' + IntToStr(Level);
end;

function LevelFromCaption(const S: string): Integer;
var
  I: Integer;
begin
  for I := 1 to 5 do
    if SameText(S, LevelNames[I]) then
      Exit(I);
  if SameText(S, 'LogAlways') then
    Exit(4);
  if AllDigits(S) and (Length(S) <= 3) and TryStrToInt(S, Result) then
    Exit;
  Result := -1;
end;

function TermCaption(const T: TSiftTerm): string;
var
  V: string;
  L: Integer;
begin
  V := T.Value;
  case T.Field of
    sfLevel:
      begin
        L := StrToIntDef(V, -1);
        V := LevelCaption(L);
      end;
    sfTime: V := '>= ' + V;
    sfMessage: V := '"' + V + '"';
  end;
  if T.Action = saInclude then
    Result := SiftFieldCaptions[T.Field] + ' = ' + V
  else
    Result := 'NOT ' + SiftFieldCaptions[T.Field] + ' = ' + V;
end;

function FieldFromName(const S: string; out F: TSiftField): Boolean;
var
  X: TSiftField;
begin
  for X := Low(TSiftField) to High(TSiftField) do
    if SameText(SiftFieldNames[X], S) then
    begin
      F := X;
      Exit(True);
    end;
  Result := False;
end;

function UtcToIso(const D: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', D);
end;

function IsoToUtc(const S: string; out D: TDateTime): Boolean;
var
  Y, Mo, Dd, H, Mi, Se, Ms: Integer;
  T: string;
begin
  Result := False;
  T := Trim(S);
  if (Length(T) < 20) or (T[5] <> '-') or (T[8] <> '-') or
     not (T[11] in ['T', 't', ' ']) or (T[14] <> ':') or (T[17] <> ':') then
    Exit;
  if not TryStrToInt(Copy(T, 1, 4), Y) then Exit;
  if not TryStrToInt(Copy(T, 6, 2), Mo) then Exit;
  if not TryStrToInt(Copy(T, 9, 2), Dd) then Exit;
  if not TryStrToInt(Copy(T, 12, 2), H) then Exit;
  if not TryStrToInt(Copy(T, 15, 2), Mi) then Exit;
  if not TryStrToInt(Copy(T, 18, 2), Se) then Exit;
  Ms := 0;
  if (Length(T) >= 21) and (T[20] = '.') then
  begin
    if not TryStrToInt(Copy(T, 21, 3), Ms) then Exit;
    if not (T[Length(T)] in ['Z', 'z']) then Exit;
  end
  else if not (T[20] in ['Z', 'z']) then
    Exit;
  Result := TryEncodeDateTime(Y, Mo, Dd, H, Mi, Se, Ms, D);
end;

function AllDigits(const S: string): Boolean;
var
  C: Char;
begin
  Result := S <> '';
  for C in S do
    if not (C in ['0'..'9']) then
      Exit(False);
end;

function HasControlChars(const S: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if (Ord(S[I]) < 32) or (Ord(S[I]) = 127) then
      Exit(True);
  Result := False;
end;

function HasHereStringCloserLine(const S: string): Boolean;
var
  L: TStringList;
  I: Integer;
begin
  if S = '''@' then
    Exit(True);
  L := TStringList.Create;
  try
    L.Text := S;
    for I := 0 to L.Count - 1 do
      if L[I] = '''@' then
        Exit(True);
  finally
    L.Free;
  end;
  Result := False;
end;

function HasBothQuoteTypes(const S: string): Boolean;
begin
  Result := (Pos('''', S) > 0) and (Pos('"', S) > 0);
end;

function UnsafeValueReason(const Value: string): string;
begin
  if HasControlChars(Value) then
    Exit('contains control characters');
  if HasHereStringCloserLine(Value) then
    Exit('contains a line equal to ''@');
  if HasBothQuoteTypes(Value) then
    Exit('contains both single and double quotes');
  Result := '';
end;

function IsValidSidString(const Value: string): Boolean;
var
  I, Digits, Groups: Integer;
begin
  Result := False;
  if Length(Value) < 7 then
    Exit;
  if (Value[1] <> 'S') or (Value[2] <> '-') or (Value[3] <> '1') or
     (Value[4] <> '-') then
    Exit;
  I := 5;
  Digits := 0;
  Groups := 0;
  while I <= Length(Value) do
  begin
    if Value[I] = '-' then
    begin
      if Digits = 0 then
        Exit;
      Inc(Groups);
      Digits := 0;
    end
    else if Value[I] in ['0'..'9'] then
      Inc(Digits)
    else
      Exit;
    Inc(I);
  end;
  Result := (Digits > 0) and (Groups >= 1);
end;

function IsFileChannel(const Channel: string): Boolean;
var
  S: string;
begin
  S := Trim(Channel);
  Result := SameText(Copy(S, 1, 7), 'file://') or
    SameText(Copy(S, 1, 5), 'file:');
end;

function StripFileScheme(const Channel: string): string;
var
  S: string;
begin
  S := Trim(Channel);
  if SameText(Copy(S, 1, 7), 'file://') then
    Result := Copy(S, 8, MaxInt)
  else if SameText(Copy(S, 1, 5), 'file:') then
    Result := Copy(S, 6, MaxInt)
  else
    Result := S;
end;

function BackslashPath(const S: string): string;
begin
  Result := StringReplace(S, '/', '\', [rfReplaceAll]);
end;

function IsExtendedLocalDrive(const Q: string): Boolean;
begin
  { Q uses backslashes. \\?\X: with X a drive letter, not \\?\UNC. }
  Result := (Length(Q) >= 6) and (Q[1] = '\') and (Q[2] = '\') and
    (Q[3] = '?') and (Q[4] = '\') and (Q[5] in ['A'..'Z', 'a'..'z']) and
    (Q[6] = ':');
end;

function IsRemoteChannel(const Channel: string): Boolean;
var
  Raw, Q: string;
  I: Integer;
begin
  Raw := Trim(Channel);
  Q := BackslashPath(StripFileScheme(Raw));
  if IsExtendedLocalDrive(Q) then
    Exit(False);
  if (Length(Q) >= 2) and (Q[1] = '\') and (Q[2] = '\') then
    Exit(True);
  if IsFileChannel(Raw) then
  begin
    I := 1;
    while (I <= Length(Q)) and (Q[I] = '\') do
      Inc(I);
    if (I < Length(Q)) and (Q[I] in ['A'..'Z', 'a'..'z']) and (Q[I + 1] = ':') then
      Exit(False);
    Exit(True);
  end;
  Result := False;
end;

function IsAllowedFileChannel(const Channel: string): Boolean;
var
  Q: string;
  I: Integer;
begin
  Result := False;
  if not IsFileChannel(Channel) or IsRemoteChannel(Channel) then
    Exit;
  Q := BackslashPath(StripFileScheme(Channel));
  if IsExtendedLocalDrive(Q) then
    Exit(True);
  I := 1;
  while (I <= Length(Q)) and (Q[I] = '\') do
    Inc(I);
  Result := (I + 2 <= Length(Q)) and (Q[I] in ['A'..'Z', 'a'..'z']) and
    (Q[I + 1] = ':') and (Q[I + 2] = '\');
end;

function NormalizeTermValue(Field: TSiftField; const Value: string;
  out Normalized: string): Boolean;
var
  N: Int64;
  Q: QWord;
  D: TDateTime;
  L: Integer;
  V: string;
begin
  V := Trim(Value);
  Normalized := V;
  Result := V <> '';
  if not Result then
    Exit;
  if UnsafeValueReason(V) <> '' then
  begin
    Result := False;
    Exit;
  end;
  case Field of
    sfLevel:
      begin
        L := LevelFromCaption(V);
        Result := (L >= 0) and (L <= 255);
        if L = 0 then
          L := 4; { Event Viewer's Information covers 0 and 4 }
        Normalized := IntToStr(L);
      end;
    sfEventId, sfTask:
      begin
        Result := AllDigits(V) and (Length(V) <= 6) and TryStrToInt64(V, N) and
          (N >= 0) and (N <= 65535);
        if Result then
          Normalized := IntToStr(N);
      end;
    sfKeywords:
      begin
        if (Length(V) > 2) and (V[1] = '0') and (V[2] in ['x', 'X']) then
          Result := TryStrToQWord('$' + Copy(V, 3, MaxInt), Q)
        else
          Result := TryStrToQWord(V, Q);
        if Result then
          Normalized := '0x' + IntToHex(Q, 16);
      end;
    sfTime:
      begin
        Result := IsoToUtc(V, D);
        if Result then
          Normalized := UtcToIso(D);
      end;
    sfUser:
      Result := IsValidSidString(V);
    sfChannel:
      Result := (not IsRemoteChannel(V)) and
        ((not IsFileChannel(V)) or IsAllowedFileChannel(V));
    sfProvider, sfComputer, sfMessage:
      Result := True;
  end;
end;

{ TSiftFilter }

function ClampLastN(N: Integer): Integer;
begin
  if N < 0 then
    Result := 0
  else if N > MaxLastN then
    Result := MaxLastN
  else
    Result := N;
end;

function ClampTextScanCap(N: Integer): Integer;
begin
  if N < 0 then
    Result := 0
  else if N > MaxTextScanCap then
    Result := MaxTextScanCap
  else
    Result := N;
end;

function ClampRowCap(N: Integer): Integer;
begin
  if (N <= 0) or (N > MaxRowCap) then
    Result := MaxRowCap
  else
    Result := N;
end;

constructor TSiftFilter.Create;
begin
  inherited Create;
  FChannels := TStringList.Create;
  FChannels.CaseSensitive := False;
  FTextScanCap := DefaultTextScanCap;
end;

destructor TSiftFilter.Destroy;
begin
  FChannels.Free;
  inherited Destroy;
end;

function TSiftFilter.GetTerm(I: Integer): TSiftTerm;
begin
  Result := FTerms[I];
end;

function TSiftFilter.GetTermCount: Integer;
begin
  Result := Length(FTerms);
end;

procedure TSiftFilter.Assign(Src: TSiftFilter);
begin
  FChannels.Assign(Src.FChannels);
  FTerms := Copy(Src.FTerms);
  FTimeMode := Src.FTimeMode;
  FRelativeMs := Src.FRelativeMs;
  FStartUtc := Src.FStartUtc;
  FEndUtc := Src.FEndUtc;
  FLastN := Src.FLastN;
  FTextScanCap := Src.FTextScanCap;
end;

function TSiftFilter.Clone: TSiftFilter;
begin
  Result := TSiftFilter.Create;
  Result.Assign(Self);
end;

function TSiftFilter.SameAs(Other: TSiftFilter): Boolean;
var
  I: Integer;
begin
  Result := (Other <> nil) and (FChannels.Text = Other.FChannels.Text) and
    (Length(FTerms) = Length(Other.FTerms)) and
    (FTimeMode = Other.FTimeMode) and (FLastN = Other.FLastN) and
    (FTextScanCap = Other.FTextScanCap);
  if not Result then
    Exit;
  case FTimeMode of
    tmRelative: Result := FRelativeMs = Other.FRelativeMs;
    tmAbsolute: Result := (UtcToIso(FStartUtc) = UtcToIso(Other.FStartUtc)) and
      (UtcToIso(FEndUtc) = UtcToIso(Other.FEndUtc)) and
      ((FStartUtc = 0) = (Other.FStartUtc = 0)) and
      ((FEndUtc = 0) = (Other.FEndUtc = 0));
  end;
  if not Result then
    Exit;
  for I := 0 to High(FTerms) do
    if not SameTerm(FTerms[I], Other.FTerms[I]) then
      Exit(False);
end;

procedure TSiftFilter.Clear;
begin
  FChannels.Clear;
  ClearTerms;
  ClearWindow;
  FLastN := 0;
  FTextScanCap := DefaultTextScanCap;
end;

procedure TSiftFilter.ClearTerms;
begin
  SetLength(FTerms, 0);
end;

function TSiftFilter.IndexOfTerm(const T: TSiftTerm): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FTerms) do
    if SameTerm(FTerms[I], T) then
      Exit(I);
  Result := -1;
end;

function TSiftFilter.AddTerm(const T: TSiftTerm): Integer;
var
  N, Why: string;
  X: TSiftTerm;
begin
  if not NormalizeTermValue(T.Field, T.Value, N) then
  begin
    Why := UnsafeValueReason(T.Value);
    if Why = '' then
    begin
      if T.Field = sfUser then
        Why := 'not a valid SID (S-1- followed by at least one RID group)'
      else if T.Field = sfChannel then
        Why := 'remote or UNC file paths are not allowed'
      else
        Why := T.Value;
    end;
    raise EConvertError.CreateFmt('Invalid %s value: %s',
      [SiftFieldCaptions[T.Field], Why]);
  end;
  X := T;
  X.Value := N;
  Result := IndexOfTerm(X);
  if Result >= 0 then
    Exit;
  Result := Length(FTerms);
  SetLength(FTerms, Result + 1);
  FTerms[Result] := X;
end;

procedure TSiftFilter.DeleteTerm(Index: Integer);
var
  I: Integer;
begin
  if (Index < 0) or (Index > High(FTerms)) then
    Exit;
  for I := Index to High(FTerms) - 1 do
    FTerms[I] := FTerms[I + 1];
  SetLength(FTerms, Length(FTerms) - 1);
end;

function TSiftFilter.ApplyCell(Field: TSiftField; const Value: string;
  Action: TSiftAction; Mode: TSiftApplyMode): Boolean;
var
  T, Opp: TSiftTerm;
  Before: TSiftFilter;
  I: Integer;
begin
  Before := Clone;
  try
    T := MakeTerm(Field, Action, Value);
    if Mode = amSet then
      ClearTerms
    else
    begin
      { Adding the opposite of an existing term replaces it: Include X then
        Exclude X leaves only Exclude X. }
      Opp := T;
      if Action = saInclude then Opp.Action := saExclude else Opp.Action := saInclude;
      NormalizeTermValue(Field, Value, Opp.Value);
      I := IndexOfTerm(Opp);
      if I >= 0 then
        DeleteTerm(I);
    end;
    AddTerm(T);
    Result := not SameAs(Before);
  finally
    Before.Free;
  end;
end;

procedure TSiftFilter.SetLastN(N: Integer);
begin
  N := ClampLastN(N);
  FLastN := N;
  if N > 0 then
    ClearWindow;
end;

procedure TSiftFilter.SetMaxCount(N: Integer);
begin
  FLastN := ClampLastN(N);
end;

procedure TSiftFilter.SetTextScanCapValue(N: Integer);
begin
  FTextScanCap := ClampTextScanCap(N);
end;

procedure TSiftFilter.ApplyRowCap(RowCap: Integer);
begin
  RowCap := ClampRowCap(RowCap);
  if (FLastN = 0) or (FLastN > RowCap) then
    SetMaxCount(RowCap);
end;

procedure TSiftFilter.SetRelativeWindow(Ms: Int64);
begin
  FTimeMode := tmRelative;
  FRelativeMs := Ms;
  FStartUtc := 0;
  FEndUtc := 0;
  FLastN := 0;
end;

procedure TSiftFilter.SetAbsoluteWindow(StartUtc, EndUtc: TDateTime);
begin
  FTimeMode := tmAbsolute;
  FRelativeMs := 0;
  FStartUtc := StartUtc;
  FEndUtc := EndUtc;
  FLastN := 0;
end;

procedure TSiftFilter.ClearWindow;
begin
  FTimeMode := tmAll;
  FRelativeMs := 0;
  FStartUtc := 0;
  FEndUtc := 0;
end;

function TSiftFilter.HasTextTerms: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FTerms) do
    if FTerms[I].Field = sfMessage then
      Exit(True);
  Result := False;
end;

function TSiftFilter.HasExcludes: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FTerms) do
    if (FTerms[I].Action = saExclude) and (FTerms[I].Field <> sfMessage) and
       (FTerms[I].Field <> sfChannel) then
      Exit(True);
  Result := False;
end;

function TSiftFilter.TermsFor(Field: TSiftField; Action: TSiftAction): TStringArray;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(FTerms) do
    if (FTerms[I].Field = Field) and (FTerms[I].Action = Action) then
    begin
      SetLength(Result, N + 1);
      Result[N] := FTerms[I].Value;
      Inc(N);
    end;
end;

function TSiftFilter.EffectiveChannels(const AllChannels: TStrings): TStringArray;
var
  InclCh, Exc: TStringArray;
  L: TStringList;
  I: Integer;
  S: string;
begin
  L := TStringList.Create;
  try
    L.CaseSensitive := False;
    L.Duplicates := dupIgnore;
    InclCh := TermsFor(sfChannel, saInclude);
    Exc := TermsFor(sfChannel, saExclude);
    if Length(InclCh) > 0 then
    begin
      for S in InclCh do
        if L.IndexOf(S) < 0 then
          L.Add(S);
    end
    else
      for I := 0 to FChannels.Count - 1 do
        if FChannels[I] = '*' then
        begin
          if AllChannels <> nil then
            for S in AllChannels do
              if L.IndexOf(S) < 0 then
                L.Add(S);
        end
        else if L.IndexOf(FChannels[I]) < 0 then
          L.Add(FChannels[I]);
    for S in Exc do
    begin
      I := L.IndexOf(S);
      if I >= 0 then
        L.Delete(I);
    end;
    { A bypass of the load-time checks must still not reach EvtQuery
      or the PowerShell export. }
    for I := L.Count - 1 downto 0 do
      if IsRemoteChannel(L[I]) or
        (IsFileChannel(L[I]) and not IsAllowedFileChannel(L[I])) then
        L.Delete(I);
    SetLength(Result, L.Count);
    for I := 0 to L.Count - 1 do
      Result[I] := L[I];
  finally
    L.Free;
  end;
end;

end.
