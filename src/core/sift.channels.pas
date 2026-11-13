unit Sift.Channels;

{ Channel enumeration (EvtOpenChannelEnum / EvtNextChannelPath) with the
  enabled flag and channel type, so "All logs" can be resolved to the
  queryable Admin and Operational channels. Read-only: nothing is changed. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Sift.EvtApi;

type
  TSiftChannelInfo = record
    Name: string;
    Enabled: Boolean;
    ChannelType: Integer; { EvtChannelType*; -1 unknown }
    Classic: Boolean;     { Application, Security, Setup, System, ForwardedEvents }
  end;
  TSiftChannelInfos = array of TSiftChannelInfo;

function EnumChannelNames(Names: TStrings): Boolean;
function EnumChannels(out Infos: TSiftChannelInfos): Boolean;
{ Enabled Admin + Operational channels, classic logs first. }
procedure QueryableChannels(const Infos: TSiftChannelInfos; Dest: TStrings);
function IsClassicLog(const Name: string): Boolean;
function IsProcessElevated: Boolean;

const
  ClassicLogs: array[0..4] of string = ('Application', 'Security', 'Setup',
    'System', 'ForwardedEvents');

implementation

function IsClassicLog(const Name: string): Boolean;
var
  S: string;
begin
  for S in ClassicLogs do
    if SameText(S, Name) then
      Exit(True);
  Result := False;
end;

function EnumChannelNames(Names: TStrings): Boolean;
var
  H: EVT_HANDLE;
  Buf: UnicodeString;
  Used, Err: DWORD;
begin
  Result := False;
  if not EvtApiLoaded then
    Exit;
  H := EvtOpenChannelEnum(0, 0);
  if H = 0 then
    Exit;
  try
    SetLength(Buf, 512);
    while True do
    begin
      Used := 0;
      if not EvtNextChannelPath(H, Length(Buf), PWideChar(Buf), Used) then
      begin
        Err := GetLastError;
        if Err = ERROR_INSUFFICIENT_BUFFER_ then
        begin
          SetLength(Buf, Used + 1);
          Continue;
        end;
        Break;
      end;
      Names.Add(UTF8Encode(UnicodeString(PWideChar(Buf))));
    end;
    Result := True;
  finally
    EvtClose(H);
  end;
end;

function ChannelProp(Cfg: EVT_HANDLE; Prop: DWORD; out V: EVT_VARIANT): Boolean;
var
  Used: DWORD;
  Buf: array[0..63] of Byte;
begin
  Used := 0;
  Result := EvtGetChannelConfigProperty(Cfg, Prop, 0, SizeOf(Buf),
    PEVT_VARIANT(@Buf[0]), Used);
  if Result then
    V := PEVT_VARIANT(@Buf[0])^;
end;

function EnumChannels(out Infos: TSiftChannelInfos): Boolean;
var
  Names: TStringList;
  I, N: Integer;
  Cfg: EVT_HANDLE;
  W: UnicodeString;
  V: EVT_VARIANT;
begin
  Infos := nil;
  Names := TStringList.Create;
  try
    Result := EnumChannelNames(Names);
    if not Result then
      Exit;
    SetLength(Infos, Names.Count);
    N := 0;
    for I := 0 to Names.Count - 1 do
    begin
      Infos[N].Name := Names[I];
      Infos[N].Enabled := False;
      Infos[N].ChannelType := -1;
      Infos[N].Classic := IsClassicLog(Names[I]);
      W := UTF8Decode(Names[I]);
      Cfg := EvtOpenChannelConfig(0, PWideChar(W), 0);
      if Cfg <> 0 then
      begin
        if ChannelProp(Cfg, EvtChannelConfigEnabled, V) then
          Infos[N].Enabled := V.BooleanVal;
        if ChannelProp(Cfg, EvtChannelConfigType, V) then
          Infos[N].ChannelType := V.UInt32Val;
        EvtClose(Cfg);
      end
      else if Infos[N].Classic then
      begin
        { e.g. Security config is unreadable unelevated; still list it }
        Infos[N].Enabled := True;
        Infos[N].ChannelType := EvtChannelTypeAdmin;
      end;
      Inc(N);
    end;
    SetLength(Infos, N);
  finally
    Names.Free;
  end;
end;

procedure QueryableChannels(const Infos: TSiftChannelInfos; Dest: TStrings);
var
  I: Integer;
  S: string;
begin
  for S in ClassicLogs do
    for I := 0 to High(Infos) do
      if SameText(Infos[I].Name, S) and Infos[I].Enabled then
        Dest.Add(Infos[I].Name);
  for I := 0 to High(Infos) do
    if (not Infos[I].Classic) and Infos[I].Enabled and
       (Infos[I].ChannelType in [EvtChannelTypeAdmin, EvtChannelTypeOperational]) then
      Dest.Add(Infos[I].Name);
end;

function IsProcessElevated: Boolean;
const
  TokenElevation = 20;
var
  Tok: THandle;
  Elev: DWORD;
  Len: DWORD;
begin
  Result := False;
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, Tok) then
  try
    Elev := 0;
    Len := 0;
    if GetTokenInformation(Tok, TTokenInformationClass(TokenElevation), @Elev,
      SizeOf(Elev), Len) then
      Result := Elev <> 0;
  finally
    CloseHandle(Tok);
  end;
end;

end.
