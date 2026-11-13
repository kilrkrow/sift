unit Sift.EvtApi;

{ Hand-written bindings for the Windows Event Log API (wevtapi.dll, Vista+).
  No maintained Free Pascal binding exists (FPC 3.2.2 winunits-jedi and the
  Lazarus 4.8 tree have no EvtQuery declarations), so these are our own.
  wevtapi.dll is loaded dynamically, so the exe has no static import on it
  and can report "Event Log API not available" instead of failing to load. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

type
  EVT_HANDLE = THandle;
  PEVT_HANDLE = ^EVT_HANDLE;

  { EVT_VARIANT: 8-byte union, Count, Type = 16 bytes on win32 and win64 }
  PEVT_VARIANT = ^EVT_VARIANT;
  EVT_VARIANT = record
    case Integer of
      0: (BooleanVal: BOOL);
      1: (SByteVal: ShortInt);
      2: (Int16Val: SmallInt);
      3: (Int32Val: LongInt);
      4: (Int64Val: Int64);
      5: (ByteVal: Byte);
      6: (UInt16Val: Word);
      7: (UInt32Val: DWORD);
      8: (UInt64Val: QWord);
      9: (SingleVal: Single);
      10: (DoubleVal: Double);
      11: (FileTimeVal: QWord);
      12: (SysTimeVal: PSystemTime);
      13: (GuidVal: PGUID);
      14: (StringVal: PWideChar);
      15: (AnsiStringVal: PAnsiChar);
      16: (BinaryVal: PByte);
      17: (SidVal: PSID);
      18: (SizeTVal: PtrUInt);
      19: (EvtHandleVal: EVT_HANDLE);
      20: (XmlVal: PWideChar);
      21: (Pad: array[0..7] of Byte;
          Count: DWORD;
          VarType: DWORD);
  end;

const
  { EVT_VARIANT_TYPE }
  EvtVarTypeNull = 0;
  EvtVarTypeString = 1;
  EvtVarTypeAnsiString = 2;
  EvtVarTypeSByte = 3;
  EvtVarTypeByte = 4;
  EvtVarTypeInt16 = 5;
  EvtVarTypeUInt16 = 6;
  EvtVarTypeInt32 = 7;
  EvtVarTypeUInt32 = 8;
  EvtVarTypeInt64 = 9;
  EvtVarTypeUInt64 = 10;
  EvtVarTypeSingle = 11;
  EvtVarTypeDouble = 12;
  EvtVarTypeBoolean = 13;
  EvtVarTypeBinary = 14;
  EvtVarTypeGuid = 15;
  EvtVarTypeSizeT = 16;
  EvtVarTypeFileTime = 17;
  EvtVarTypeSysTime = 18;
  EvtVarTypeSid = 19;
  EvtVarTypeHexInt32 = 20;
  EvtVarTypeHexInt64 = 21;
  EvtVarTypeEvtHandle = 32;
  EvtVarTypeEvtXml = 35;
  EVT_VARIANT_TYPE_MASK = $7F;
  EVT_VARIANT_TYPE_ARRAY = 128;

  { EVT_QUERY_FLAGS }
  EvtQueryChannelPath = $1;
  EvtQueryFilePath = $2;
  EvtQueryForwardDirection = $100;
  EvtQueryReverseDirection = $200;
  EvtQueryTolerateQueryErrors = $1000;

  { EVT_RENDER_CONTEXT_FLAGS }
  EvtRenderContextValues = 0;
  EvtRenderContextSystem = 1;
  EvtRenderContextUser = 2;

  { EVT_RENDER_FLAGS }
  EvtRenderEventValues = 0;
  EvtRenderEventXml = 1;
  EvtRenderBookmark = 2;

  { EVT_SYSTEM_PROPERTY_ID }
  EvtSystemProviderName = 0;
  EvtSystemProviderGuid = 1;
  EvtSystemEventID = 2;
  EvtSystemQualifiers = 3;
  EvtSystemLevel = 4;
  EvtSystemTask = 5;
  EvtSystemOpcode = 6;
  EvtSystemKeywords = 7;
  EvtSystemTimeCreated = 8;
  EvtSystemEventRecordId = 9;
  EvtSystemActivityID = 10;
  EvtSystemRelatedActivityID = 11;
  EvtSystemProcessID = 12;
  EvtSystemThreadID = 13;
  EvtSystemChannel = 14;
  EvtSystemComputer = 15;
  EvtSystemUserID = 16;
  EvtSystemVersion = 17;
  EvtSystemPropertyIdEND = 18;

  { EVT_FORMAT_MESSAGE_FLAGS }
  EvtFormatMessageEvent = 1;
  EvtFormatMessageLevel = 2;
  EvtFormatMessageTask = 3;
  EvtFormatMessageOpcode = 4;
  EvtFormatMessageKeyword = 5;
  EvtFormatMessageChannel = 6;
  EvtFormatMessageProvider = 7;
  EvtFormatMessageId = 8;
  EvtFormatMessageXml = 9;

  { EVT_PUBLISHER_METADATA_PROPERTY_ID (subset) }
  EvtPublisherMetadataLevels = 12;
  EvtPublisherMetadataLevelName = 13;
  EvtPublisherMetadataLevelValue = 14;
  EvtPublisherMetadataLevelMessageID = 15;
  EvtPublisherMetadataTasks = 16;
  EvtPublisherMetadataTaskName = 17;
  EvtPublisherMetadataTaskEventGuid = 18;
  EvtPublisherMetadataTaskValue = 19;
  EvtPublisherMetadataTaskMessageID = 20;
  EvtPublisherMetadataOpcodes = 21;
  EvtPublisherMetadataOpcodeName = 22;
  EvtPublisherMetadataOpcodeValue = 23;
  EvtPublisherMetadataOpcodeMessageID = 24;
  EvtPublisherMetadataKeywords = 25;
  EvtPublisherMetadataKeywordName = 26;
  EvtPublisherMetadataKeywordValue = 27;
  EvtPublisherMetadataKeywordMessageID = 28;

  { EVT_EVENT_METADATA_PROPERTY_ID }
  EventMetadataEventID = 0;
  EventMetadataEventVersion = 1;
  EventMetadataEventChannel = 2;
  EventMetadataEventLevel = 3;
  EventMetadataEventOpcode = 4;
  EventMetadataEventTask = 5;
  EventMetadataEventKeyword = 6;
  EventMetadataEventMessageID = 7;
  EventMetadataEventTemplate = 8;

  { EVT_QUERY_PROPERTY_ID }
  EvtQueryNames = 0;
  EvtQueryStatuses = 1;

  { EVT_CHANNEL_CONFIG_PROPERTY_ID (subset) }
  EvtChannelConfigEnabled = 0;
  EvtChannelConfigIsolation = 1;
  EvtChannelConfigType = 2;

  { EVT_CHANNEL_TYPE }
  EvtChannelTypeAdmin = 0;
  EvtChannelTypeOperational = 1;
  EvtChannelTypeAnalytic = 2;
  EvtChannelTypeDebug = 3;

  { EVT_SEEK_FLAGS }
  EvtSeekRelativeToFirst = 1;
  EvtSeekRelativeToLast = 2;
  EvtSeekRelativeToCurrent = 3;
  EvtSeekRelativeToBookmark = 4;

  { Win32 errors seen from wevtapi }
  ERROR_NO_MORE_ITEMS_ = 259;
  ERROR_INSUFFICIENT_BUFFER_ = 122;
  ERROR_ACCESS_DENIED_ = 5;
  ERROR_TIMEOUT_ = 1460;
  ERROR_EVT_INVALID_QUERY = 15001;
  ERROR_EVT_PUBLISHER_METADATA_NOT_FOUND = 15002;
  ERROR_EVT_CHANNEL_NOT_FOUND = 15007;
  ERROR_EVT_QUERY_RESULT_STALE = 15011;
  ERROR_EVT_MESSAGE_NOT_FOUND = 15027;
  ERROR_EVT_MESSAGE_ID_NOT_FOUND = 15028;
  ERROR_EVT_UNRESOLVED_VALUE_INSERT = 15029;

  EVT_INFINITE = DWORD($FFFFFFFF);

type
  TEvtQuery = function(Session: EVT_HANDLE; Path: PWideChar; Query: PWideChar;
    Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtNext = function(ResultSet: EVT_HANDLE; EventArraySize: DWORD;
    EventArray: PEVT_HANDLE; Timeout: DWORD; Flags: DWORD;
    out Returned: DWORD): BOOL; stdcall;
  TEvtSeek = function(ResultSet: EVT_HANDLE; Position: Int64;
    Bookmark: EVT_HANDLE; Timeout: DWORD; Flags: DWORD): BOOL; stdcall;
  TEvtCreateRenderContext = function(ValuePathsCount: DWORD;
    ValuePaths: Pointer; Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtRender = function(Context: EVT_HANDLE; Fragment: EVT_HANDLE;
    Flags: DWORD; BufferSize: DWORD; Buffer: Pointer; out BufferUsed: DWORD;
    out PropertyCount: DWORD): BOOL; stdcall;
  TEvtFormatMessage = function(PublisherMetadata: EVT_HANDLE;
    Event: EVT_HANDLE; MessageId: DWORD; ValueCount: DWORD;
    Values: PEVT_VARIANT; Flags: DWORD; BufferSize: DWORD; Buffer: PWideChar;
    out BufferUsed: DWORD): BOOL; stdcall;
  TEvtOpenPublisherMetadata = function(Session: EVT_HANDLE;
    PublisherId: PWideChar; LogFilePath: PWideChar; Locale: LCID;
    Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtClose = function(Obj: EVT_HANDLE): BOOL; stdcall;
  TEvtOpenChannelEnum = function(Session: EVT_HANDLE; Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtNextChannelPath = function(ChannelEnum: EVT_HANDLE;
    ChannelPathBufferSize: DWORD; ChannelPathBuffer: PWideChar;
    out ChannelPathBufferUsed: DWORD): BOOL; stdcall;
  TEvtOpenChannelConfig = function(Session: EVT_HANDLE; ChannelPath: PWideChar;
    Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtGetChannelConfigProperty = function(ChannelConfig: EVT_HANDLE;
    PropertyId: DWORD; Flags: DWORD; PropertyValueBufferSize: DWORD;
    PropertyValueBuffer: PEVT_VARIANT; out PropertyValueBufferUsed: DWORD): BOOL; stdcall;
  TEvtCreateBookmark = function(BookmarkXml: PWideChar): EVT_HANDLE; stdcall;
  TEvtOpenEventMetadataEnum = function(PublisherMetadata: EVT_HANDLE;
    Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtNextEventMetadata = function(EventMetadataEnum: EVT_HANDLE;
    Flags: DWORD): EVT_HANDLE; stdcall;
  TEvtGetEventMetadataProperty = function(EventMetadata: EVT_HANDLE;
    PropertyId: DWORD; Flags: DWORD; BufferSize: DWORD; Buffer: PEVT_VARIANT;
    out BufferUsed: DWORD): BOOL; stdcall;
  TEvtGetPublisherMetadataProperty = function(PublisherMetadata: EVT_HANDLE;
    PropertyId: DWORD; Flags: DWORD; BufferSize: DWORD; Buffer: PEVT_VARIANT;
    out BufferUsed: DWORD): BOOL; stdcall;
  TEvtGetObjectArraySize = function(ObjectArray: EVT_HANDLE;
    out ArraySize: DWORD): BOOL; stdcall;
  TEvtGetObjectArrayProperty = function(ObjectArray: EVT_HANDLE;
    PropertyId: DWORD; ArrayIndex: DWORD; Flags: DWORD; BufferSize: DWORD;
    Buffer: PEVT_VARIANT; out BufferUsed: DWORD): BOOL; stdcall;
  TEvtGetQueryInfo = function(QueryOrSubscription: EVT_HANDLE;
    PropertyId: DWORD; PropertyValueBufferSize: DWORD;
    PropertyValueBuffer: PEVT_VARIANT; out PropertyValueBufferUsed: DWORD): BOOL; stdcall;

var
  EvtQuery: TEvtQuery = nil;
  EvtNext: TEvtNext = nil;
  EvtSeek: TEvtSeek = nil;
  EvtCreateRenderContext: TEvtCreateRenderContext = nil;
  EvtRender: TEvtRender = nil;
  EvtFormatMessage: TEvtFormatMessage = nil;
  EvtOpenPublisherMetadata: TEvtOpenPublisherMetadata = nil;
  EvtClose: TEvtClose = nil;
  EvtOpenChannelEnum: TEvtOpenChannelEnum = nil;
  EvtNextChannelPath: TEvtNextChannelPath = nil;
  EvtOpenChannelConfig: TEvtOpenChannelConfig = nil;
  EvtGetChannelConfigProperty: TEvtGetChannelConfigProperty = nil;
  EvtGetQueryInfo: TEvtGetQueryInfo = nil;
  EvtCreateBookmark: TEvtCreateBookmark = nil;
  { provider metadata (Event ID lookup) }
  EvtOpenEventMetadataEnum: TEvtOpenEventMetadataEnum = nil;
  EvtNextEventMetadata: TEvtNextEventMetadata = nil;
  EvtGetEventMetadataProperty: TEvtGetEventMetadataProperty = nil;
  EvtGetPublisherMetadataProperty: TEvtGetPublisherMetadataProperty = nil;
  EvtGetObjectArraySize: TEvtGetObjectArraySize = nil;
  EvtGetObjectArrayProperty: TEvtGetObjectArrayProperty = nil;

{ Loads wevtapi.dll from System32 once. Returns False (and sets Msg) if the
  DLL or any required entry point is missing (pre-Vista). }
function EvtApiLoad(out Msg: string): Boolean;
function EvtApiLoaded: Boolean;

{ Safe EvtClose that ignores 0 handles. }
procedure EvtCloseSafe(var H: EVT_HANDLE);

{ Win32 error text, ASCII-safe, without trailing CR/LF. }
function Win32ErrorText(Code: DWORD): string;

implementation

var
  GLib: HMODULE = 0;
  GLoaded: Boolean = False;
  GTried: Boolean = False;
  GMsg: string = '';

function SystemDir: UnicodeString;
var
  Buf: array[0..MAX_PATH] of WideChar;
  N: UINT;
begin
  N := GetSystemDirectoryW(@Buf[0], MAX_PATH);
  if N = 0 then
    Result := ''
  else
    SetString(Result, PWideChar(@Buf[0]), N);
end;

function EvtApiLoad(out Msg: string): Boolean;

  function Get(const Name: AnsiString; var Missing: string): Pointer;
  begin
    Result := GetProcAddress(GLib, PAnsiChar(Name));
    if Result = nil then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + string(Name);
    end;
  end;

var
  Missing: string;
  P: UnicodeString;
begin
  if GTried then
  begin
    Msg := GMsg;
    Exit(GLoaded);
  end;
  GTried := True;
  P := SystemDir;
  if P <> '' then
    P := P + '\wevtapi.dll'
  else
    P := 'wevtapi.dll';
  GLib := LoadLibraryW(PWideChar(P));
  if GLib = 0 then
  begin
    GMsg := 'wevtapi.dll could not be loaded (Windows Vista or later is required).';
    Msg := GMsg;
    Exit(False);
  end;
  Missing := '';
  Pointer(EvtQuery) := Get('EvtQuery', Missing);
  Pointer(EvtNext) := Get('EvtNext', Missing);
  Pointer(EvtSeek) := Get('EvtSeek', Missing);
  Pointer(EvtCreateRenderContext) := Get('EvtCreateRenderContext', Missing);
  Pointer(EvtRender) := Get('EvtRender', Missing);
  Pointer(EvtFormatMessage) := Get('EvtFormatMessage', Missing);
  Pointer(EvtOpenPublisherMetadata) := Get('EvtOpenPublisherMetadata', Missing);
  Pointer(EvtClose) := Get('EvtClose', Missing);
  Pointer(EvtOpenChannelEnum) := Get('EvtOpenChannelEnum', Missing);
  Pointer(EvtNextChannelPath) := Get('EvtNextChannelPath', Missing);
  Pointer(EvtOpenChannelConfig) := Get('EvtOpenChannelConfig', Missing);
  Pointer(EvtGetChannelConfigProperty) := Get('EvtGetChannelConfigProperty', Missing);
  Pointer(EvtGetQueryInfo) := Get('EvtGetQueryInfo', Missing);
  Pointer(EvtCreateBookmark) := Get('EvtCreateBookmark', Missing);
  Pointer(EvtOpenEventMetadataEnum) := Get('EvtOpenEventMetadataEnum', Missing);
  Pointer(EvtNextEventMetadata) := Get('EvtNextEventMetadata', Missing);
  Pointer(EvtGetEventMetadataProperty) := Get('EvtGetEventMetadataProperty', Missing);
  Pointer(EvtGetPublisherMetadataProperty) := Get('EvtGetPublisherMetadataProperty', Missing);
  Pointer(EvtGetObjectArraySize) := Get('EvtGetObjectArraySize', Missing);
  Pointer(EvtGetObjectArrayProperty) := Get('EvtGetObjectArrayProperty', Missing);
  if Missing <> '' then
  begin
    GMsg := 'wevtapi.dll is missing: ' + Missing;
    Msg := GMsg;
    Exit(False);
  end;
  GLoaded := True;
  GMsg := '';
  Msg := '';
  Result := True;
end;

function EvtApiLoaded: Boolean;
var
  M: string;
begin
  Result := EvtApiLoad(M);
end;

procedure EvtCloseSafe(var H: EVT_HANDLE);
begin
  if (H <> 0) and Assigned(EvtClose) then
    EvtClose(H);
  H := 0;
end;

function Win32ErrorText(Code: DWORD): string;
var
  I: Integer;
begin
  Result := SysErrorMessage(Code);
  for I := 1 to Length(Result) do
    if Result[I] in [#13, #10] then
      Result[I] := ' ';
  Result := Trim(Result);
  if Result = '' then
    Result := 'Error ' + IntToStr(Code);
end;

end.
