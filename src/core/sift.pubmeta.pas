unit Sift.PubMeta;

{ Offline Event ID lookup: what a provider's own metadata says about an
  event ID (description template, level, task, opcode, keywords), read with
  the Evt* publisher-metadata calls - the same data
  `(Get-WinEvent -ListProvider <p>).Events` shows. Nothing here touches the
  network; the "Look up online" URL is only built here and opened by the
  viewer through ShellExecute. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Generics.Collections, Sift.EvtApi;

type
  { One named value from a provider's level / task / opcode / keyword table. }
  TSiftMetaName = record
    Value: QWord;
    Name: string;     { e.g. win:Informational, SystemStart }
    Display: string;  { localized display name; '' when the provider has none }
  end;
  TSiftMetaNames = array of TSiftMetaName;

  TSiftMetaKeyword = record
    Value: QWord;     { one bit }
    Name: string;
    Display: string;
  end;

  TSiftEventMeta = record
    Id: DWORD;        { as stored: qualifiers in the high word for classic IDs }
    Version: Integer;
    Level: Integer;
    LevelName, LevelDisplay: string;
    Task: Integer;
    TaskName, TaskDisplay: string;
    Opcode: Integer;
    OpcodeName, OpcodeDisplay: string;
    Keywords: QWord;
    KeywordList: array of TSiftMetaKeyword; { set bits, highest first }
    Description: string; { the message template, with %1-style inserts }
    Template: string;    { the event data template (XML) }
  end;
  PSiftEventMeta = ^TSiftEventMeta;
  TSiftEventMetas = array of TSiftEventMeta;

  { Metadata for one provider, read once. }
  TSiftProviderMeta = class
  public
    Provider: string;
    Available: Boolean;
    ErrorCode: DWORD;
    Events: TSiftEventMetas;
    Levels, Tasks, Opcodes, Keywords: TSiftMetaNames;
    { all entries whose low 16 bits are EventId (several versions or
      qualifiers can share one ID) }
    function Matches(EventId: Word): TSiftEventMetas;
    { the best entry for an event: same qualifiers and version when known
      (pass -1 for unknown), else the first match; nil when none }
    function Find(EventId: Word; Qualifiers, Version: Integer): PSiftEventMeta;
  end;

  { Per-session cache: one provider is read at most once while the app runs. }
  TSiftMetaCache = class
  private
    FMap: specialize TObjectDictionary<string, TSiftProviderMeta>;
    FStd: TSiftProviderMeta; { the default (winmeta) publisher }
    FStdTried: Boolean;
    FLoads: Integer;
    function Standard: TSiftProviderMeta;
  public
    constructor Create;
    destructor Destroy; override;
    function Get(const Provider: string): TSiftProviderMeta;
    function Cached(const Provider: string): Boolean;
    property Loads: Integer read FLoads; { providers actually read }
  end;

const
  MetaNotAvailableText = 'Provider metadata not available on this machine';
  DefaultLookupUrl = 'https://www.google.com/search?q=%s';

{ Reads a provider's metadata (no cache). Std may be nil; when given, names
  that the provider takes from the standard winmeta set get their standard
  display names, as .NET's ProviderMetadata does. }
function LoadProviderMeta(const Provider: string; Std: TSiftProviderMeta): TSiftProviderMeta;

{ Text for the details pane. ASCII labels; values are UTF-8 as read. }
function FormatEventMeta(const Provider: string; M: PSiftEventMeta;
  Meta: TSiftProviderMeta; EventId: Word): string;

{ Percent-encoded (UTF-8) query: "<provider>" event ID <id> }
function LookupQuery(const Provider: string; EventId: Integer): string;
function UrlEncodeUtf8(const S: string): string;
{ True when T is usable as a LookupUrl: https://host..., exactly one %s,
  only URL-safe ASCII (no spaces, quotes, <>, backslash, non-ASCII), other
  '%' only as %XX. A rejected template falls back to DefaultLookupUrl. }
function LookupUrlTemplateOk(const T: string): Boolean;
{ UrlTemplate holds one %s for the encoded query; must start with https:// }
function LookupUrl(const Provider: string; EventId: Integer;
  const UrlTemplate: string = DefaultLookupUrl): string;

implementation

function UrlEncodeUtf8(const S: string): string;
const
  Hex: array[0..15] of Char = '0123456789ABCDEF';
var
  B: Byte;
  I: Integer;
begin
  { S is UTF-8 already (the app's string type); encode byte by byte }
  Result := '';
  for I := 1 to Length(S) do
  begin
    B := Ord(S[I]);
    if Chr(B) in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then
      Result := Result + Chr(B)
    else
      Result := Result + '%' + Hex[B shr 4] + Hex[B and 15];
  end;
end;

function LookupQuery(const Provider: string; EventId: Integer): string;
begin
  Result := '"' + Provider + '" event ID ' + IntToStr(EventId);
end;

function LookupUrlTemplateOk(const T: string): Boolean;
const
  { RFC 3986 unreserved + reserved characters and '%'; no spaces, quotes,
    angle brackets, backslash, braces, '|', '^', '`' or non-ASCII }
  UrlSafe = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', ':', '/', '?',
    '#', '[', ']', '@', '!', '$', '&', '(', ')', '*', '+', ',', ';', '=', '%'];
var
  I, P: Integer;
begin
  Result := False;
  if (Length(T) < 12) or (Length(T) > 512) or (LowerCase(Copy(T, 1, 8)) <> 'https://') then
    Exit;
  for I := 1 to Length(T) do
    if not (T[I] in UrlSafe) then
      Exit;
  { exactly one %s, and every other % must start a %XX escape }
  P := Pos('%s', T);
  if (P = 0) or (Pos('%s', Copy(T, P + 2, MaxInt)) > 0) then
    Exit;
  I := 1;
  while I <= Length(T) do
  begin
    if T[I] = '%' then
    begin
      if I = P then
        Inc(I, 2)
      else if (I + 2 <= Length(T)) and (T[I + 1] in ['0'..'9', 'A'..'F', 'a'..'f']) and
        (T[I + 2] in ['0'..'9', 'A'..'F', 'a'..'f']) then
        Inc(I, 3)
      else
        Exit;
    end
    else
      Inc(I);
  end;
  { the host must be non-empty }
  Result := (Length(T) > 8) and not (T[9] in ['/', '?', '#', '%']);
end;

function LookupUrl(const Provider: string; EventId: Integer;
  const UrlTemplate: string): string;
var
  T: string;
begin
  T := UrlTemplate;
  if not LookupUrlTemplateOk(T) then
    T := DefaultLookupUrl;
  Result := StringReplace(T, '%s', UrlEncodeUtf8(LookupQuery(Provider, EventId)), []);
end;

{ --- variant helpers --- }

type
  TVarBuf = array of Byte;

function GetEventProp(H: EVT_HANDLE; Id: DWORD; var Buf: TVarBuf): PEVT_VARIANT;
var
  Used: DWORD;
begin
  Result := nil;
  if Length(Buf) < 256 then
    SetLength(Buf, 256);
  Used := 0;
  if not EvtGetEventMetadataProperty(H, Id, 0, Length(Buf), PEVT_VARIANT(@Buf[0]), Used) then
  begin
    if GetLastError <> ERROR_INSUFFICIENT_BUFFER_ then
      Exit;
    SetLength(Buf, Used + 16);
    if not EvtGetEventMetadataProperty(H, Id, 0, Length(Buf), PEVT_VARIANT(@Buf[0]), Used) then
      Exit;
  end;
  Result := PEVT_VARIANT(@Buf[0]);
end;

function GetPubProp(H: EVT_HANDLE; Id: DWORD; var Buf: TVarBuf): PEVT_VARIANT;
var
  Used: DWORD;
begin
  Result := nil;
  if Length(Buf) < 256 then
    SetLength(Buf, 256);
  Used := 0;
  if not EvtGetPublisherMetadataProperty(H, Id, 0, Length(Buf), PEVT_VARIANT(@Buf[0]), Used) then
  begin
    if GetLastError <> ERROR_INSUFFICIENT_BUFFER_ then
      Exit;
    SetLength(Buf, Used + 16);
    if not EvtGetPublisherMetadataProperty(H, Id, 0, Length(Buf), PEVT_VARIANT(@Buf[0]), Used) then
      Exit;
  end;
  Result := PEVT_VARIANT(@Buf[0]);
end;

function GetArrProp(A: EVT_HANDLE; Id, Index: DWORD; var Buf: TVarBuf): PEVT_VARIANT;
var
  Used: DWORD;
begin
  Result := nil;
  if Length(Buf) < 256 then
    SetLength(Buf, 256);
  Used := 0;
  if not EvtGetObjectArrayProperty(A, Id, Index, 0, Length(Buf), PEVT_VARIANT(@Buf[0]), Used) then
  begin
    if GetLastError <> ERROR_INSUFFICIENT_BUFFER_ then
      Exit;
    SetLength(Buf, Used + 16);
    if not EvtGetObjectArrayProperty(A, Id, Index, 0, Length(Buf), PEVT_VARIANT(@Buf[0]), Used) then
      Exit;
  end;
  Result := PEVT_VARIANT(@Buf[0]);
end;

function VStr(V: PEVT_VARIANT): string;
begin
  Result := '';
  if (V <> nil) and ((V^.VarType and EVT_VARIANT_TYPE_MASK) = EvtVarTypeString) and
     (V^.StringVal <> nil) then
    Result := UTF8Encode(UnicodeString(V^.StringVal));
end;

function VUInt(V: PEVT_VARIANT; Def: QWord = 0): QWord;
begin
  Result := Def;
  if V = nil then
    Exit;
  case V^.VarType and EVT_VARIANT_TYPE_MASK of
    EvtVarTypeByte: Result := V^.ByteVal;
    EvtVarTypeUInt16: Result := V^.UInt16Val;
    EvtVarTypeUInt32, EvtVarTypeHexInt32, EvtVarTypeInt32: Result := V^.UInt32Val;
    EvtVarTypeUInt64, EvtVarTypeHexInt64, EvtVarTypeInt64: Result := V^.UInt64Val;
  end;
end;

{ Message text by ID from the provider's message table; '' if none. }
function MessageById(Pub: EVT_HANDLE; MsgId: DWORD): string;
var
  Buf: UnicodeString;
  Used, Err: DWORD;
  Ok: Boolean;
begin
  Result := '';
  if MsgId = $FFFFFFFF then
    Exit;
  SetLength(Buf, 512);
  Used := 0;
  Ok := EvtFormatMessage(Pub, 0, MsgId, 0, nil, EvtFormatMessageId, Length(Buf),
    PWideChar(Buf), Used);
  if not Ok then
  begin
    Err := GetLastError;
    if Err = ERROR_INSUFFICIENT_BUFFER_ then
    begin
      SetLength(Buf, Used + 1);
      Ok := EvtFormatMessage(Pub, 0, MsgId, 0, nil, EvtFormatMessageId, Length(Buf),
        PWideChar(Buf), Used);
      if not Ok then
        Err := GetLastError;
    end;
    { a template with inserts and no values reports unresolved inserts but
      still returns the template text, as .NET's EvtFormatMessage does }
    if not Ok and not ((Err = ERROR_EVT_UNRESOLVED_VALUE_INSERT) or
      (Err = 15030) or (Err = 15031)) then
      Exit;
  end;
  if Used > 0 then
    Result := UTF8Encode(UnicodeString(PWideChar(Buf)));
end;

function ReadNames(Pub: EVT_HANDLE; ListId, NameId, ValueId, MsgIdId: DWORD;
  OpcodeShift: Boolean; Std: TSiftProviderMeta; StdList: Integer): TSiftMetaNames;
var
  Buf, B2: TVarBuf;
  V: PEVT_VARIANT;
  Arr: EVT_HANDLE;
  N, K: DWORD;
  I: Integer;
  MsgId: DWORD;
  L: TSiftMetaNames;
  J: Integer;
begin
  Result := nil;
  Buf := nil;
  B2 := nil;
  V := GetPubProp(Pub, ListId, Buf);
  if (V = nil) or ((V^.VarType and EVT_VARIANT_TYPE_MASK) <> EvtVarTypeEvtHandle) then
    Exit;
  Arr := V^.EvtHandleVal;
  try
    N := 0;
    if not EvtGetObjectArraySize(Arr, N) or (N = 0) then
      Exit;
    SetLength(Result, N);
    K := 0;
    for I := 0 to Integer(N) - 1 do
    begin
      Result[K].Name := VStr(GetArrProp(Arr, NameId, I, B2));
      Result[K].Value := VUInt(GetArrProp(Arr, ValueId, I, B2));
      if OpcodeShift then
        Result[K].Value := Result[K].Value shr 16;
      MsgId := DWORD(VUInt(GetArrProp(Arr, MsgIdId, I, B2), $FFFFFFFF));
      if MsgId <> $FFFFFFFF then
        Result[K].Display := MessageById(Pub, MsgId)
      else if Std <> nil then
      begin
        { standard (winmeta) entries carry no message of their own }
        case StdList of
          0: L := Std.Levels;
          1: L := Std.Tasks;
          2: L := Std.Opcodes;
        else
          L := Std.Keywords;
        end;
        for J := 0 to High(L) do
          if (L[J].Name = Result[K].Name) and (L[J].Value = Result[K].Value) then
          begin
            Result[K].Display := L[J].Display;
            Break;
          end;
      end;
      Inc(K);
    end;
    SetLength(Result, K);
  finally
    EvtClose(Arr);
  end;
end;

function FindName(const L: TSiftMetaNames; Value: QWord; out Name, Display: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(L) do
    if L[I].Value = Value then
    begin
      Name := L[I].Name;
      Display := L[I].Display;
      Exit(True);
    end;
  Name := '';
  Display := '';
  Result := False;
end;

function LoadProviderMeta(const Provider: string; Std: TSiftProviderMeta): TSiftProviderMeta;
var
  Pub, En, Ev: EVT_HANDLE;
  W: UnicodeString;
  Buf: TVarBuf;
  M: TSiftEventMeta;
  N, B: Integer;
  Bit: QWord;
begin
  Result := TSiftProviderMeta.Create;
  Result.Provider := Provider;
  if not EvtApiLoaded or not Assigned(EvtOpenEventMetadataEnum) then
  begin
    Result.ErrorCode := ERROR_PROC_NOT_FOUND;
    Exit;
  end;
  if Provider = '' then
    Pub := EvtOpenPublisherMetadata(0, nil, nil, 0, 0) { default: winmeta }
  else
  begin
    W := UTF8Decode(Provider);
    Pub := EvtOpenPublisherMetadata(0, PWideChar(W), nil, 0, 0);
  end;
  if Pub = 0 then
  begin
    Result.ErrorCode := GetLastError;
    Exit;
  end;
  try
    Result.Levels := ReadNames(Pub, EvtPublisherMetadataLevels, EvtPublisherMetadataLevelName,
      EvtPublisherMetadataLevelValue, EvtPublisherMetadataLevelMessageID, False, Std, 0);
    Result.Tasks := ReadNames(Pub, EvtPublisherMetadataTasks, EvtPublisherMetadataTaskName,
      EvtPublisherMetadataTaskValue, EvtPublisherMetadataTaskMessageID, False, Std, 1);
    Result.Opcodes := ReadNames(Pub, EvtPublisherMetadataOpcodes, EvtPublisherMetadataOpcodeName,
      EvtPublisherMetadataOpcodeValue, EvtPublisherMetadataOpcodeMessageID, True, Std, 2);
    Result.Keywords := ReadNames(Pub, EvtPublisherMetadataKeywords, EvtPublisherMetadataKeywordName,
      EvtPublisherMetadataKeywordValue, EvtPublisherMetadataKeywordMessageID, False, Std, 3);
    Result.Available := True;
    if Provider = '' then
      Exit;
    En := EvtOpenEventMetadataEnum(Pub, 0);
    if En = 0 then
    begin
      { a classic provider can have a message file but no event table: the
        pane then says exactly MetaNotAvailableText, nothing more }
      Result.ErrorCode := GetLastError;
      Result.Available := False;
      Exit;
    end;
    Buf := nil;
    N := 0;
    try
      repeat
        Ev := EvtNextEventMetadata(En, 0);
        if Ev = 0 then
          Break;
        try
          M := Default(TSiftEventMeta);
          M.Id := DWORD(VUInt(GetEventProp(Ev, EventMetadataEventID, Buf)));
          M.Version := Byte(VUInt(GetEventProp(Ev, EventMetadataEventVersion, Buf)));
          M.Level := Byte(VUInt(GetEventProp(Ev, EventMetadataEventLevel, Buf)));
          M.Opcode := Byte(VUInt(GetEventProp(Ev, EventMetadataEventOpcode, Buf)));
          M.Task := Word(VUInt(GetEventProp(Ev, EventMetadataEventTask, Buf)));
          M.Keywords := VUInt(GetEventProp(Ev, EventMetadataEventKeyword, Buf));
          M.Description := MessageById(Pub,
            DWORD(VUInt(GetEventProp(Ev, EventMetadataEventMessageID, Buf), $FFFFFFFF)));
          M.Template := VStr(GetEventProp(Ev, EventMetadataEventTemplate, Buf));
          FindName(Result.Levels, M.Level, M.LevelName, M.LevelDisplay);
          FindName(Result.Tasks, M.Task, M.TaskName, M.TaskDisplay);
          FindName(Result.Opcodes, M.Opcode, M.OpcodeName, M.OpcodeDisplay);
          for B := 63 downto 0 do
          begin
            Bit := QWord(1) shl B;
            if (M.Keywords and Bit) <> 0 then
            begin
              SetLength(M.KeywordList, Length(M.KeywordList) + 1);
              with M.KeywordList[High(M.KeywordList)] do
              begin
                Value := Bit;
                FindName(Result.Keywords, Bit, Name, Display);
              end;
            end;
          end;
          if N >= Length(Result.Events) then
            SetLength(Result.Events, N * 2 + 16);
          Result.Events[N] := M;
          Inc(N);
        finally
          EvtClose(Ev);
        end;
      until False;
    finally
      SetLength(Result.Events, N);
      EvtClose(En);
    end;
  finally
    EvtClose(Pub);
  end;
end;

{ TSiftProviderMeta }

function TSiftProviderMeta.Matches(EventId: Word): TSiftEventMetas;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(Events) do
    if Word(Events[I].Id and $FFFF) = EventId then
    begin
      SetLength(Result, N + 1);
      Result[N] := Events[I];
      Inc(N);
    end;
end;

function TSiftProviderMeta.Find(EventId: Word; Qualifiers, Version: Integer): PSiftEventMeta;
var
  I: Integer;
  First, SameQ: PSiftEventMeta;
begin
  First := nil;
  SameQ := nil;
  for I := 0 to High(Events) do
    if Word(Events[I].Id and $FFFF) = EventId then
    begin
      if First = nil then
        First := @Events[I];
      if (Qualifiers < 0) or (Integer(Events[I].Id shr 16) = Qualifiers) then
      begin
        if (Version >= 0) and (Events[I].Version = Version) then
          Exit(@Events[I]);
        if SameQ = nil then
          SameQ := @Events[I];
      end;
    end;
  if SameQ <> nil then
    Result := SameQ
  else
    Result := First;
end;

{ TSiftMetaCache }

constructor TSiftMetaCache.Create;
begin
  FMap := specialize TObjectDictionary<string, TSiftProviderMeta>.Create([doOwnsValues]);
end;

destructor TSiftMetaCache.Destroy;
begin
  FMap.Free;
  FStd.Free;
  inherited Destroy;
end;

function TSiftMetaCache.Standard: TSiftProviderMeta;
begin
  if not FStdTried then
  begin
    FStdTried := True;
    FStd := LoadProviderMeta('', nil);
  end;
  Result := FStd;
end;

function TSiftMetaCache.Cached(const Provider: string): Boolean;
begin
  Result := FMap.ContainsKey(LowerCase(Provider));
end;

function TSiftMetaCache.Get(const Provider: string): TSiftProviderMeta;
begin
  if FMap.TryGetValue(LowerCase(Provider), Result) then
    Exit;
  Result := LoadProviderMeta(Provider, Standard);
  Inc(FLoads);
  FMap.Add(LowerCase(Provider), Result);
end;

function NameText(const Name, Display: string; Value: QWord): string;
begin
  if Display <> '' then
    Result := Display
  else if Name <> '' then
    Result := Name
  else
    Result := '';
  if Result = '' then
    Result := IntToStr(Value)
  else
    Result := Result + ' (' + IntToStr(Value) + ')';
end;

function FormatEventMeta(const Provider: string; M: PSiftEventMeta;
  Meta: TSiftProviderMeta; EventId: Word): string;
var
  L: TStringList;
  K: string;
  I: Integer;
begin
  if (Meta = nil) or not Meta.Available then
    Exit(MetaNotAvailableText);
  if M = nil then
    Exit('Event ID ' + IntToStr(EventId) + ' is not described in the metadata of "' +
      Provider + '" on this machine.');
  L := TStringList.Create;
  try
    L.Add('Provider: ' + Provider);
    if (M^.Id shr 16) <> 0 then
      L.Add(Format('Event ID: %d (qualifiers %d)   Version: %d', [M^.Id and $FFFF, M^.Id shr 16, M^.Version]))
    else
      L.Add(Format('Event ID: %d   Version: %d', [M^.Id, M^.Version]));
    L.Add('Level: ' + NameText(M^.LevelName, M^.LevelDisplay, M^.Level));
    L.Add('Task: ' + NameText(M^.TaskName, M^.TaskDisplay, M^.Task));
    L.Add('Opcode: ' + NameText(M^.OpcodeName, M^.OpcodeDisplay, M^.Opcode));
    K := '';
    for I := 0 to High(M^.KeywordList) do
    begin
      if K <> '' then
        K := K + ', ';
      with M^.KeywordList[I] do
        if Display <> '' then
          K := K + Display
        else if Name <> '' then
          K := K + Name
        else
          K := K + '0x' + IntToHex(Value, 16);
    end;
    if K = '' then
      K := '(none)';
    L.Add('Keywords: ' + K + '   (0x' + IntToHex(M^.Keywords, 16) + ')');
    L.Add('');
    L.Add('Description template:');
    if M^.Description <> '' then
      L.Add(TrimRight(M^.Description))
    else
      L.Add('(none)');
    if M^.Template <> '' then
    begin
      L.Add('');
      L.Add('Event data template:');
      L.Add(TrimRight(M^.Template));
    end;
    L.Add('');
    L.Add('From the provider''s metadata on this machine (offline).');
    Result := TrimRight(L.Text);
  finally
    L.Free;
  end;
end;

end.
