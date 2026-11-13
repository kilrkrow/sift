unit Sift.Query;

{ Runs a compiled Sift filter through EvtQuery/EvtNext and collects compact
  rows. Messages are NOT rendered here unless the filter has message-text
  terms (the one client-side fallback, capped). Every result carries a copy
  of the filter that produced it, so it can be reopened or handed off. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Generics.Collections,
  Sift.EvtApi, Sift.Filter, Sift.Compiler;

type
  TSiftEventRow = record
    RecordId: Int64;
    TimeCreated: Int64;   { FILETIME, UTC }
    Keywords: QWord;
    EventId: Word;
    Task: Word;
    Level: Byte;
    ChannelIx: Integer;
    ProviderIx: Integer;
    UserIx: Integer;
    ComputerIx: Integer;
  end;
  PSiftEventRow = ^TSiftEventRow;

  { Interned strings (channels, providers, SIDs, computers). }
  TSiftStringPool = class
  private
    FMap: specialize TDictionary<string, Integer>;
    FList: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function Intern(const S: string): Integer;
    function Get(Ix: Integer): string;
    function Count: Integer;
  end;

  TSiftRenderer = class;

  TSiftChannelError = record
    Channel: string;
    Code: DWORD;
    Text: string;
    NeedsElevation: Boolean;
  end;
  TSiftChannelErrors = array of TSiftChannelError;

  TSiftRunPath = (rpService, rpServiceAndClientText);

  TSiftStats = record
    FirstRowMs: Double;
    TotalMs: Double;
    Path: TSiftRunPath;
    Scanned: Int64;     { events returned by the service }
    TextScanned: Int64; { events whose message was rendered for text terms }
    CapHit: Boolean;
    Cancelled: Boolean;
    QueryError: DWORD;
    QueryErrorText: string;
  end;

  TSiftResult = class
  private
    FRows: array of TSiftEventRow;
    FCount: Integer;
    FPool: TSiftStringPool;
    FFilter: TSiftFilter;
    FCompiled: TSiftCompiled;
    FErrors: TSiftChannelErrors;
    function GetRow(I: Integer): PSiftEventRow;
  public
    Stats: TSiftStats;
    constructor Create(F: TSiftFilter; const C: TSiftCompiled);
    destructor Destroy; override;
    procedure AddRow(const R: TSiftEventRow);
    { Newest first by TimeCreated, ties by RecordId (both descending). }
    procedure SortNewestFirst;
    procedure Truncate(N: Integer);
    { Appends Src's rows from FromIndex (re-interning strings); errors are
      copied when FromIndex = 0. }
    procedure MergeFrom(Src: TSiftResult; FromIndex: Integer = 0);
    procedure AddError(const E: TSiftChannelError);
    function Str(Ix: Integer): string;
    function Key(I: Integer): string; { 'Channel|RecordId' }
    { Re-opens row I for message/XML rendering (caller closes). Live
      channels seek by bookmark; .evtx sources are tried in query order. }
    function OpenRow(Renderer: TSiftRenderer; I: Integer): EVT_HANDLE;
    property Rows[I: Integer]: PSiftEventRow read GetRow;
    property Count: Integer read FCount;
    property Pool: TSiftStringPool read FPool;
    property Filter: TSiftFilter read FFilter;
    property Compiled: TSiftCompiled read FCompiled;
    property Errors: TSiftChannelErrors read FErrors;
  end;

  TSiftProgressEvent = procedure(R: TSiftResult; var Cancel: Boolean) of object;

  { Message / XML rendering with a publisher-metadata cache. Not thread-safe:
    use one per thread. }
  TSiftRenderer = class
  private
    FPublishers: specialize TDictionary<string, EVT_HANDLE>;
    FHandles: array of EVT_HANDLE;
    FSeekPaths: TStringList;
    FSeekQueries: array of EVT_HANDLE;
    FCtx: EVT_HANDLE;
    FPool: TSiftStringPool;
    FBuf: TBytes;
    function SeekQuery(const Path: string): EVT_HANDLE;
  public
    constructor Create;
    destructor Destroy; override;
    function Publisher(const Provider: string): EVT_HANDLE;
    function FormatMessage(Ev: EVT_HANDLE; const Provider: string;
      Flags: DWORD = EvtFormatMessageEvent): string;
    function RenderXml(Ev: EVT_HANDLE): string;
    { Re-opens an event by record id; caller closes the handle. Seeks with a
      bookmark on a cached per-channel query (fast), falling back to an
      EventRecordID XPath query (scans). Channel is the event's channel;
      Path is the queried channel or file:// path. }
    function OpenEvent(const Path: string; RecordId: Int64;
      const Channel: string = ''): EVT_HANDLE;
    function OpenEventByQuery(const Path: string; RecordId: Int64): EVT_HANDLE;
    { Drops cached seek queries (call when a new result arrives). }
    procedure ResetSeekCache;
  end;

  TSiftExecutor = class
  private
    FRenderer: TSiftRenderer;
    FSysCtx: EVT_HANDLE;
    FBatchSize: Integer;
    FProgressEvery: Integer;
    FBuf: TBytes;
    FCancelFlag: PBoolean;
    FFirstProgress: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Runs the filter. Single source: service order (reverse record order,
      what Get-WinEvent -MaxEvents returns). Several sources: rows are
      merged newest-first by time; last-N takes each source's last N and
      keeps the newest N of the merge (the service interleaves multi-path
      results only approximately by time). }
    function Execute(F: TSiftFilter; AllChannels: TStrings;
      OnProgress: TSiftProgressEvent = nil): TSiftResult;
    function ExecuteOne(F: TSiftFilter; const C: TSiftCompiled;
      OnProgress: TSiftProgressEvent): TSiftResult;
    property BatchSize: Integer read FBatchSize write FBatchSize;
    property ProgressEvery: Integer read FProgressEvery write FProgressEvery;
    property FirstProgress: Integer read FFirstProgress write FFirstProgress;
    property Renderer: TSiftRenderer read FRenderer;
    { Optional flag polled after every EvtNext batch. }
    property CancelFlag: PBoolean read FCancelFlag write FCancelFlag;
  end;

function FileTimeToUtc(FT: Int64): TDateTime;
function FileTimeToLocal(FT: Int64): TDateTime;
function UtcNowFileTime: Int64;
function TextContains(const Haystack, Needle: string): Boolean;
function RenderSystemRow(Ctx, Ev: EVT_HANDLE; Pool: TSiftStringPool;
  var Buf: TBytes; out Row: TSiftEventRow; out Provider: string): Boolean;
function IsAccessDenied(Code: DWORD): Boolean;
function MsSince(StartTick: QWord): Double;
function NowTick: QWord;

implementation

uses
  Sift.Sids, Sift.TzTime;

var
  QPCFreq: Int64 = 0;

function NowTick: QWord;
var
  C: Int64;
begin
  if QPCFreq = 0 then
    QueryPerformanceFrequency(QPCFreq);
  QueryPerformanceCounter(C);
  Result := QWord(C);
end;

function MsSince(StartTick: QWord): Double;
begin
  Result := (Int64(NowTick) - Int64(StartTick)) * 1000.0 / QPCFreq;
end;

function FileTimeToUtc(FT: Int64): TDateTime;
begin
  { 100-ns ticks since 1601-01-01 }
  Result := EncodeDate(1601, 1, 1) + FT / (864000000000.0);
end;

function FileTimeToLocal(FT: Int64): TDateTime;
var
  U: TFileTime;
  ST, LT: TSystemTime;
begin
  { the DST rules of the event's own date (FileTimeToLocalFileTime would use
    today's offset and show events across a DST change an hour off) }
  U.dwLowDateTime := DWORD(FT and $FFFFFFFF);
  U.dwHighDateTime := DWORD(FT shr 32);
  if FileTimeToSystemTime(U, ST) and SystemTimeToTzSpecificLocalTime(nil, ST, LT) then
    Result := SystemTimeToDateTime(LT)
  else
    Result := FileTimeToUtc(FT);
end;

function UtcNowFileTime: Int64;
var
  F: TFileTime;
begin
  GetSystemTimeAsFileTime(F);
  Result := (Int64(F.dwHighDateTime) shl 32) or F.dwLowDateTime;
end;

function TextContains(const Haystack, Needle: string): Boolean;
begin
  Result := (Needle = '') or
    (Pos(UTF8Encode(WideLowerCase(UTF8Decode(Needle))),
         UTF8Encode(WideLowerCase(UTF8Decode(Haystack)))) > 0);
end;

function IsAccessDenied(Code: DWORD): Boolean;
begin
  Result := Code = ERROR_ACCESS_DENIED_;
end;

{ TSiftStringPool }

constructor TSiftStringPool.Create;
begin
  FMap := specialize TDictionary<string, Integer>.Create;
  FList := TStringList.Create;
end;

destructor TSiftStringPool.Destroy;
begin
  FMap.Free;
  FList.Free;
  inherited Destroy;
end;

function TSiftStringPool.Intern(const S: string): Integer;
begin
  if not FMap.TryGetValue(S, Result) then
  begin
    Result := FList.Add(S);
    FMap.Add(S, Result);
  end;
end;

function TSiftStringPool.Get(Ix: Integer): string;
begin
  if (Ix >= 0) and (Ix < FList.Count) then
    Result := FList[Ix]
  else
    Result := '';
end;

function TSiftStringPool.Count: Integer;
begin
  Result := FList.Count;
end;

{ TSiftResult }

constructor TSiftResult.Create(F: TSiftFilter; const C: TSiftCompiled);
begin
  FPool := TSiftStringPool.Create;
  FFilter := F.Clone;
  FCompiled := C;
  SetLength(FRows, 1024);
  FCount := 0;
  FillChar(Stats, SizeOf(Stats), 0);
  Stats.FirstRowMs := -1;
end;

destructor TSiftResult.Destroy;
begin
  FPool.Free;
  FFilter.Free;
  inherited Destroy;
end;

function TSiftResult.GetRow(I: Integer): PSiftEventRow;
begin
  Result := @FRows[I];
end;

procedure TSiftResult.AddRow(const R: TSiftEventRow);
begin
  if FCount >= Length(FRows) then
    SetLength(FRows, Length(FRows) * 2);
  FRows[FCount] := R;
  Inc(FCount);
end;

procedure TSiftResult.AddError(const E: TSiftChannelError);
begin
  SetLength(FErrors, Length(FErrors) + 1);
  FErrors[High(FErrors)] := E;
end;

function RowNewer(const A, B: TSiftEventRow): Boolean; inline;
begin
  Result := (A.TimeCreated > B.TimeCreated) or
    ((A.TimeCreated = B.TimeCreated) and (A.RecordId > B.RecordId));
end;

procedure TSiftResult.SortNewestFirst;
var
  Tmp: array of TSiftEventRow;

  procedure MSort(Lo, Hi: Integer);
  var
    Mid, I, J, K: Integer;
  begin
    if Hi - Lo < 1 then
      Exit;
    Mid := (Lo + Hi) div 2;
    MSort(Lo, Mid);
    MSort(Mid + 1, Hi);
    I := Lo;
    J := Mid + 1;
    K := Lo;
    while (I <= Mid) and (J <= Hi) do
    begin
      if RowNewer(FRows[J], FRows[I]) then
      begin
        Tmp[K] := FRows[J];
        Inc(J);
      end
      else
      begin
        Tmp[K] := FRows[I];
        Inc(I);
      end;
      Inc(K);
    end;
    while I <= Mid do
    begin
      Tmp[K] := FRows[I];
      Inc(I);
      Inc(K);
    end;
    while J <= Hi do
    begin
      Tmp[K] := FRows[J];
      Inc(J);
      Inc(K);
    end;
    for K := Lo to Hi do
      FRows[K] := Tmp[K];
  end;

begin
  if FCount < 2 then
    Exit;
  SetLength(Tmp, FCount);
  MSort(0, FCount - 1);
end;

procedure TSiftResult.Truncate(N: Integer);
begin
  if (N >= 0) and (N < FCount) then
    FCount := N;
end;

procedure TSiftResult.MergeFrom(Src: TSiftResult; FromIndex: Integer);
var
  I: Integer;
  R: TSiftEventRow;
begin
  for I := FromIndex to Src.Count - 1 do
  begin
    R := Src.FRows[I];
    R.ChannelIx := FPool.Intern(Src.Str(R.ChannelIx));
    R.ProviderIx := FPool.Intern(Src.Str(R.ProviderIx));
    R.UserIx := FPool.Intern(Src.Str(R.UserIx));
    R.ComputerIx := FPool.Intern(Src.Str(R.ComputerIx));
    AddRow(R);
  end;
  if FromIndex = 0 then
    for I := 0 to High(Src.FErrors) do
      AddError(Src.FErrors[I]);
end;

function TSiftResult.Str(Ix: Integer): string;
begin
  Result := FPool.Get(Ix);
end;

function TSiftResult.Key(I: Integer): string;
begin
  Result := FPool.Get(FRows[I].ChannelIx) + '|' + IntToStr(FRows[I].RecordId);
end;

function TSiftResult.OpenRow(Renderer: TSiftRenderer; I: Integer): EVT_HANDLE;
var
  Ch, P: string;
  R: PSiftEventRow;
begin
  Result := 0;
  if (I < 0) or (I >= FCount) then
    Exit;
  R := @FRows[I];
  Ch := FPool.Get(R^.ChannelIx);
  for P in FCompiled.Channels do
    if SameText(P, Ch) then
      Exit(Renderer.OpenEvent(P, R^.RecordId, Ch));
  for P in FCompiled.Channels do
    if SameText(Copy(P, 1, 7), 'file://') then
    begin
      Result := Renderer.OpenEvent(P, R^.RecordId, Ch);
      if Result <> 0 then
        Exit;
    end;
end;

{ Rendering helpers }

function VarStr(const V: EVT_VARIANT): string;
begin
  if ((V.VarType and EVT_VARIANT_TYPE_MASK) = EvtVarTypeString) and
     (V.StringVal <> nil) then
    Result := UTF8Encode(UnicodeString(V.StringVal))
  else
    Result := '';
end;

function VarUInt(const V: EVT_VARIANT): QWord;
begin
  case V.VarType and EVT_VARIANT_TYPE_MASK of
    EvtVarTypeByte: Result := V.ByteVal;
    EvtVarTypeSByte: Result := QWord(V.SByteVal);
    EvtVarTypeUInt16: Result := V.UInt16Val;
    EvtVarTypeInt16: Result := QWord(V.Int16Val);
    EvtVarTypeUInt32, EvtVarTypeHexInt32: Result := V.UInt32Val;
    EvtVarTypeInt32: Result := QWord(V.Int32Val);
    EvtVarTypeUInt64, EvtVarTypeHexInt64, EvtVarTypeInt64,
    EvtVarTypeFileTime: Result := V.UInt64Val;
  else
    Result := 0;
  end;
end;

function RenderSystemRow(Ctx, Ev: EVT_HANDLE; Pool: TSiftStringPool;
  var Buf: TBytes; out Row: TSiftEventRow; out Provider: string): Boolean;
var
  Used, Props: DWORD;
  V: PEVT_VARIANT;
  Sid: string;
begin
  Result := False;
  FillChar(Row, SizeOf(Row), 0);
  Provider := '';
  if Length(Buf) < 4096 then
    SetLength(Buf, 4096);
  Used := 0;
  Props := 0;
  if not EvtRender(Ctx, Ev, EvtRenderEventValues, Length(Buf),
    @Buf[0], Used, Props) then
  begin
    if GetLastError <> ERROR_INSUFFICIENT_BUFFER_ then
      Exit;
    SetLength(Buf, Used + 256);
    if not EvtRender(Ctx, Ev, EvtRenderEventValues, Length(Buf),
      @Buf[0], Used, Props) then
      Exit;
  end;
  V := PEVT_VARIANT(@Buf[0]);
  Provider := VarStr(V[EvtSystemProviderName]);
  Row.ProviderIx := Pool.Intern(Provider);
  Row.EventId := Word(VarUInt(V[EvtSystemEventID]));
  Row.Level := Byte(VarUInt(V[EvtSystemLevel]));
  Row.Task := Word(VarUInt(V[EvtSystemTask]));
  Row.Keywords := VarUInt(V[EvtSystemKeywords]);
  Row.TimeCreated := Int64(VarUInt(V[EvtSystemTimeCreated]));
  Row.RecordId := Int64(VarUInt(V[EvtSystemEventRecordId]));
  Row.ChannelIx := Pool.Intern(VarStr(V[EvtSystemChannel]));
  Row.ComputerIx := Pool.Intern(VarStr(V[EvtSystemComputer]));
  if (V[EvtSystemUserID].VarType and EVT_VARIANT_TYPE_MASK) = EvtVarTypeSid then
    Sid := SidToString(V[EvtSystemUserID].SidVal)
  else
    Sid := '';
  Row.UserIx := Pool.Intern(Sid);
  Result := True;
end;

{ TSiftRenderer }

constructor TSiftRenderer.Create;
begin
  FPublishers := specialize TDictionary<string, EVT_HANDLE>.Create;
  FSeekPaths := TStringList.Create;
  FPool := TSiftStringPool.Create;
end;

destructor TSiftRenderer.Destroy;
var
  H: EVT_HANDLE;
begin
  for H in FHandles do
    if H <> 0 then
      EvtClose(H);
  for H in FSeekQueries do
    if H <> 0 then
      EvtClose(H);
  FSeekPaths.Free;
  EvtCloseSafe(FCtx);
  FPool.Free;
  FPublishers.Free;
  inherited Destroy;
end;

function TSiftRenderer.Publisher(const Provider: string): EVT_HANDLE;
var
  W: UnicodeString;
begin
  if FPublishers.TryGetValue(LowerCase(Provider), Result) then
    Exit;
  W := UTF8Decode(Provider);
  Result := EvtOpenPublisherMetadata(0, PWideChar(W), nil, 0, 0);
  FPublishers.Add(LowerCase(Provider), Result);
  if Result <> 0 then
  begin
    SetLength(FHandles, Length(FHandles) + 1);
    FHandles[High(FHandles)] := Result;
  end;
end;

function TSiftRenderer.FormatMessage(Ev: EVT_HANDLE; const Provider: string;
  Flags: DWORD): string;
var
  Pub: EVT_HANDLE;
  Used, Err: DWORD;
  Buf: UnicodeString;
  Ok: Boolean;
begin
  Result := '';
  Pub := Publisher(Provider);
  if Pub = 0 then
    Exit;
  Used := 0;
  SetLength(Buf, 512);
  Ok := EvtFormatMessage(Pub, Ev, 0, 0, nil, Flags, Length(Buf),
    PWideChar(Buf), Used);
  if not Ok then
  begin
    Err := GetLastError;
    if Err = ERROR_INSUFFICIENT_BUFFER_ then
    begin
      SetLength(Buf, Used + 1);
      Ok := EvtFormatMessage(Pub, Ev, 0, 0, nil, Flags, Length(Buf),
        PWideChar(Buf), Used);
      if not Ok then
        Err := GetLastError;
    end;
    { Like .NET's EventRecord.FormatDescription: unresolved inserts still
      return the partially formatted text. }
    if not Ok and not ((Err = ERROR_EVT_UNRESOLVED_VALUE_INSERT) or
      (Err = 15030) or (Err = 15031)) then
      Exit;
  end;
  if Used > 0 then
    Result := UTF8Encode(UnicodeString(PWideChar(Buf)))
  else
    Result := '';
end;

function TSiftRenderer.RenderXml(Ev: EVT_HANDLE): string;
var
  Used, Props: DWORD;
  Buf: UnicodeString;
begin
  Result := '';
  SetLength(Buf, 2048);
  if not EvtRender(0, Ev, EvtRenderEventXml, Length(Buf) * 2, PWideChar(Buf),
    Used, Props) then
  begin
    if GetLastError <> ERROR_INSUFFICIENT_BUFFER_ then
      Exit;
    SetLength(Buf, Used div 2 + 1);
    if not EvtRender(0, Ev, EvtRenderEventXml, Length(Buf) * 2, PWideChar(Buf),
      Used, Props) then
      Exit;
  end;
  Result := UTF8Encode(UnicodeString(PWideChar(Buf)));
end;

function TSiftRenderer.OpenEventByQuery(const Path: string; RecordId: Int64): EVT_HANDLE;
var
  Q: UnicodeString;
  H: EVT_HANDLE;
  Ret: DWORD;
  Ev: EVT_HANDLE;
begin
  Result := 0;
  Q := UTF8Decode(RecordQueryXml(Path, RecordId));
  H := EvtQuery(0, nil, PWideChar(Q), EvtQueryChannelPath or EvtQueryTolerateQueryErrors);
  if H = 0 then
    Exit;
  try
    Ev := 0;
    Ret := 0;
    if EvtNext(H, 1, @Ev, EVT_INFINITE, 0, Ret) and (Ret = 1) then
      Result := Ev;
  finally
    EvtClose(H);
  end;
end;

procedure TSiftRenderer.ResetSeekCache;
var
  H: EVT_HANDLE;
begin
  for H in FSeekQueries do
    if H <> 0 then
      EvtClose(H);
  SetLength(FSeekQueries, 0);
  FSeekPaths.Clear;
end;

function TSiftRenderer.SeekQuery(const Path: string): EVT_HANDLE;
var
  I: Integer;
  W: UnicodeString;
begin
  I := FSeekPaths.IndexOf(Path);
  if I >= 0 then
    Exit(FSeekQueries[I]);
  if SameText(Copy(Path, 1, 7), 'file://') then
  begin
    W := UTF8Decode(Copy(Path, 8, MaxInt));
    Result := EvtQuery(0, PWideChar(W), '*', EvtQueryFilePath or EvtQueryForwardDirection);
  end
  else
  begin
    W := UTF8Decode(Path);
    Result := EvtQuery(0, PWideChar(W), '*', EvtQueryChannelPath or EvtQueryForwardDirection);
  end;
  FSeekPaths.Add(Path);
  SetLength(FSeekQueries, Length(FSeekQueries) + 1);
  FSeekQueries[High(FSeekQueries)] := Result;
end;

function XmlAttr(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
end;

function TSiftRenderer.OpenEvent(const Path: string; RecordId: Int64;
  const Channel: string): EVT_HANDLE;
var
  BmX: UnicodeString;
  Bm: EVT_HANDLE;
  Ret: DWORD;
  Ev: EVT_HANDLE;
  Ch: string;
  Rv: TSiftEventRow;
  Prov: string;
begin
  Result := 0;
  Ch := Channel;
  if Ch = '' then
    Ch := Path;
  BmX := UTF8Decode('<BookmarkList><Bookmark Channel=''' + XmlAttr(Ch) +
    ''' RecordId=''' + IntToStr(RecordId) + ''' IsCurrent=''true''/></BookmarkList>');
  Bm := EvtCreateBookmark(PWideChar(BmX));
  if Bm <> 0 then
  try
    if (SeekQuery(Path) <> 0) and
       EvtSeek(SeekQuery(Path), 0, Bm, 0, EvtSeekRelativeToBookmark) then
    begin
      Ev := 0;
      Ret := 0;
      if EvtNext(SeekQuery(Path), 1, @Ev, EVT_INFINITE, 0, Ret) and (Ret = 1) then
      begin
        { verify we landed on the right record }
        if FCtx = 0 then
          FCtx := EvtCreateRenderContext(0, nil, EvtRenderContextSystem);
        if RenderSystemRow(FCtx, Ev, FPool, FBuf, Rv, Prov) and
           (Rv.RecordId = RecordId) and
           ((Channel = '') or SameText(FPool.Get(Rv.ChannelIx), Channel)) then
          Result := Ev
        else
          EvtClose(Ev);
      end;
    end;
  finally
    EvtClose(Bm);
  end;
  if Result = 0 then
    Result := OpenEventByQuery(Path, RecordId);
end;

{ TSiftExecutor }

constructor TSiftExecutor.Create;
var
  M: string;
begin
  if not EvtApiLoad(M) then
    raise Exception.Create(M);
  FRenderer := TSiftRenderer.Create;
  FSysCtx := EvtCreateRenderContext(0, nil, EvtRenderContextSystem);
  FBatchSize := 256;
  FProgressEvery := 2000;
  FFirstProgress := 2000;
end;

destructor TSiftExecutor.Destroy;
begin
  EvtCloseSafe(FSysCtx);
  FRenderer.Free;
  inherited Destroy;
end;

procedure CollectQueryStatuses(H: EVT_HANDLE; R: TSiftResult);
var
  Used: DWORD;
  NamesBuf, StatBuf: array of Byte;
  NV, SV: PEVT_VARIANT;
  I, N: Integer;
  E: TSiftChannelError;
  Names: PPWideChar;
  Stats: PDWORD;
begin
  Used := 0;
  EvtGetQueryInfo(H, EvtQueryNames, 0, nil, Used);
  if Used = 0 then
    Exit;
  SetLength(NamesBuf, Used);
  if not EvtGetQueryInfo(H, EvtQueryNames, Used, PEVT_VARIANT(@NamesBuf[0]), Used) then
    Exit;
  Used := 0;
  EvtGetQueryInfo(H, EvtQueryStatuses, 0, nil, Used);
  if Used = 0 then
    Exit;
  SetLength(StatBuf, Used);
  if not EvtGetQueryInfo(H, EvtQueryStatuses, Used, PEVT_VARIANT(@StatBuf[0]), Used) then
    Exit;
  NV := PEVT_VARIANT(@NamesBuf[0]);
  SV := PEVT_VARIANT(@StatBuf[0]);
  N := NV^.Count;
  if Integer(SV^.Count) < N then
    N := SV^.Count;
  Names := PPWideChar(NV^.StringVal);
  Stats := PDWORD(SV^.BinaryVal);
  for I := 0 to N - 1 do
    if Stats[I] <> 0 then
    begin
      E.Channel := UTF8Encode(UnicodeString(Names[I]));
      E.Code := Stats[I];
      E.Text := Win32ErrorText(E.Code);
      E.NeedsElevation := IsAccessDenied(E.Code);
      R.AddError(E);
    end;
end;

function TSiftExecutor.Execute(F: TSiftFilter; AllChannels: TStrings;
  OnProgress: TSiftProgressEvent): TSiftResult;
var
  C, SubC: TSiftCompiled;
  Sub: TSiftFilter;
  SubR: TSiftResult;
  Ch: string;
  I: Integer;
  T0: QWord;
  TextScanned: Int64;
begin
  C := CompileFilter(F, AllChannels);
  if (F.LastN > 0) and (Length(C.Channels) > 1) then
  begin
    T0 := NowTick;
    Result := TSiftResult.Create(F, C);
    if C.ClientText then
      Result.Stats.Path := rpServiceAndClientText
    else
      Result.Stats.Path := rpService;
    TextScanned := 0;
    for Ch in C.Channels do
    begin
      Sub := F.Clone;
      try
        for I := Sub.TermCount - 1 downto 0 do
          if Sub.Terms[I].Field = sfChannel then
            Sub.DeleteTerm(I);
        Sub.Channels.Clear;
        Sub.Channels.Add(Ch);
        Sub.TextScanCap := F.TextScanCap - TextScanned;
        if Sub.TextScanCap < 0 then
          Sub.TextScanCap := 0;
        SubC := CompileFilter(Sub, nil);
        SubR := ExecuteOne(Sub, SubC, nil);
        try
          Result.MergeFrom(SubR);
          if (Result.Stats.FirstRowMs < 0) and (SubR.Stats.FirstRowMs >= 0) then
            Result.Stats.FirstRowMs := MsSince(T0);
          Inc(Result.Stats.Scanned, SubR.Stats.Scanned);
          Inc(TextScanned, SubR.Stats.TextScanned);
          Result.Stats.CapHit := Result.Stats.CapHit or SubR.Stats.CapHit;
          Result.Stats.Cancelled := Result.Stats.Cancelled or SubR.Stats.Cancelled;
        finally
          SubR.Free;
        end;
      finally
        Sub.Free;
      end;
      if Result.Stats.Cancelled then
        Break;
    end;
    Result.Stats.TextScanned := TextScanned;
    Result.SortNewestFirst;
    Result.Truncate(F.LastN);
    Result.Stats.TotalMs := MsSince(T0);
    Exit;
  end;
  Result := ExecuteOne(F, C, OnProgress);
  if Length(C.Channels) > 1 then
    Result.SortNewestFirst;
end;

function TSiftExecutor.ExecuteOne(F: TSiftFilter; const C: TSiftCompiled;
  OnProgress: TSiftProgressEvent): TSiftResult;
var
  Q: UnicodeString;
  H: EVT_HANDLE;
  Evs: array of EVT_HANDLE;
  Ret, I, Err: DWORD;
  T0: QWord;
  Row: TSiftEventRow;
  Prov, Msg: string;
  IncT, ExcT: TStringArray;
  Keep, Stop, Cancel: Boolean;
  S: string;
  E: TSiftChannelError;
  NextProgress: Int64;
  Flags: DWORD;
begin
  Result := TSiftResult.Create(F, C);
  if C.ClientText then
    Result.Stats.Path := rpServiceAndClientText
  else
    Result.Stats.Path := rpService;
  if Length(C.Channels) = 0 then
    Exit;
  IncT := F.TermsFor(sfMessage, saInclude);
  ExcT := F.TermsFor(sfMessage, saExclude);
  SetLength(Evs, FBatchSize);
  Q := UTF8Decode(C.QueryXml);
  Flags := EvtQueryChannelPath or EvtQueryReverseDirection;
  if Length(C.Channels) > 1 then
    Flags := Flags or EvtQueryTolerateQueryErrors;
  T0 := NowTick;
  H := EvtQuery(0, nil, PWideChar(Q), Flags);
  if H = 0 then
  begin
    Err := GetLastError;
    Result.Stats.QueryError := Err;
    Result.Stats.QueryErrorText := Win32ErrorText(Err);
    if Length(C.Channels) = 1 then
    begin
      E.Channel := C.Channels[0];
      E.Code := Err;
      E.Text := Result.Stats.QueryErrorText;
      E.NeedsElevation := IsAccessDenied(Err);
      Result.AddError(E);
    end;
    Result.Stats.TotalMs := MsSince(T0);
    Exit;
  end;
  try
    if Length(C.Channels) > 1 then
      CollectQueryStatuses(H, Result);
    Stop := False;
    Cancel := False;
    NextProgress := FFirstProgress;
    while not Stop do
    begin
      Ret := 0;
      if not EvtNext(H, FBatchSize, @Evs[0], EVT_INFINITE, 0, Ret) then
      begin
        Err := GetLastError;
        if (Err <> ERROR_NO_MORE_ITEMS_) and (Result.Stats.QueryError = 0) then
        begin
          Result.Stats.QueryError := Err;
          Result.Stats.QueryErrorText := Win32ErrorText(Err);
          if (Length(C.Channels) = 1) then
          begin
            E.Channel := C.Channels[0];
            E.Code := Err;
            E.Text := Result.Stats.QueryErrorText;
            E.NeedsElevation := IsAccessDenied(Err);
            Result.AddError(E);
          end;
        end;
        Break;
      end;
      for I := 0 to Ret - 1 do
      begin
        if not Stop then
        begin
          Inc(Result.Stats.Scanned);
          if RenderSystemRow(FSysCtx, Evs[I], Result.Pool, FBuf, Row, Prov) then
          begin
            Keep := True;
            if C.ClientText then
            begin
              if Result.Stats.TextScanned >= F.TextScanCap then
              begin
                Result.Stats.CapHit := True;
                Stop := True;
                Keep := False;
              end
              else
              begin
                Inc(Result.Stats.TextScanned);
                Msg := FRenderer.FormatMessage(Evs[I], Prov);
                for S in IncT do
                  if not TextContains(Msg, S) then
                  begin
                    Keep := False;
                    Break;
                  end;
                if Keep then
                  for S in ExcT do
                    if TextContains(Msg, S) then
                    begin
                      Keep := False;
                      Break;
                    end;
              end;
            end;
            if Keep then
            begin
              Result.AddRow(Row);
              if Result.Count = 1 then
                Result.Stats.FirstRowMs := MsSince(T0);
              if (F.LastN > 0) and (Result.Count >= F.LastN) then
                Stop := True;
            end;
          end;
        end;
        EvtClose(Evs[I]);
      end;
      if (FCancelFlag <> nil) and FCancelFlag^ then
      begin
        Result.Stats.Cancelled := True;
        Stop := True;
      end;
      if Assigned(OnProgress) and (Result.Count >= NextProgress) then
      begin
        NextProgress := Result.Count + FProgressEvery;
        Result.Stats.TotalMs := MsSince(T0);
        OnProgress(Result, Cancel);
        if Cancel then
        begin
          Result.Stats.Cancelled := True;
          Stop := True;
        end;
      end;
    end;
  finally
    EvtClose(H);
  end;
  Result.Stats.TotalMs := MsSince(T0);
end;

end.
