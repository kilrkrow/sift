unit Test.EvtApi;

{ Piece 1 critic: the hand-written wevtapi bindings. Struct layout, entry
  points, channel enumeration, query/next/render/format on live channels,
  and the error paths (invalid query, missing channel, access denied). }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, fpcunit, testregistry, Sift.EvtApi, Sift.Filter,
  Sift.Compiler, Sift.Query, Sift.Channels;

type
  TEvtApiTests = class(TTestCase)
  published
    procedure VariantLayout;
    procedure LoadsAllEntryPoints;
    procedure EnumeratesChannels;
    procedure LastFiveSystemNewestFirst;
    procedure RendersXmlAndMessage;
    procedure InvalidQueryReportsError;
    procedure MissingChannelReportsError;
    procedure SecurityAccessDeniedUnelevated;
    procedure AllChannelsToleratesDenied;
    procedure BookmarkSeekMatchesRecord;
  end;

implementation

uses
  Test.Util;

procedure TEvtApiTests.VariantLayout;
var
  V: EVT_VARIANT;
begin
  AssertEquals('EVT_VARIANT is 16 bytes', 16, SizeOf(EVT_VARIANT));
  AssertEquals('Count at offset 8', 8, PtrUInt(@V.Count) - PtrUInt(@V));
  AssertEquals('Type at offset 12', 12, PtrUInt(@V.VarType) - PtrUInt(@V));
end;

procedure TEvtApiTests.LoadsAllEntryPoints;
var
  M: string;
begin
  AssertTrue(M, EvtApiLoad(M));
  AssertTrue(Assigned(EvtQuery) and Assigned(EvtNext) and Assigned(EvtRender) and
    Assigned(EvtFormatMessage) and Assigned(EvtOpenPublisherMetadata) and
    Assigned(EvtClose) and Assigned(EvtOpenChannelEnum) and
    Assigned(EvtNextChannelPath) and Assigned(EvtSeek) and
    Assigned(EvtCreateBookmark) and Assigned(EvtGetQueryInfo));
end;

procedure TEvtApiTests.EnumeratesChannels;
var
  Infos: TSiftChannelInfos;
  L: TStringList;
begin
  AssertTrue(EnumChannels(Infos));
  AssertTrue('many channels', Length(Infos) > 50);
  L := TStringList.Create;
  try
    QueryableChannels(Infos, L);
    AssertTrue(L.IndexOf('System') >= 0);
    AssertTrue(L.IndexOf('Application') >= 0);
    AssertEquals('classic logs first', 'Application', L[0]);
  finally
    L.Free;
  end;
end;

procedure TEvtApiTests.LastFiveSystemNewestFirst;
var
  F: TSiftFilter;
  R: TSiftResult;
  I: Integer;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.SetLastN(5);
    R := RunSift(F);
    try
      AssertEquals(5, R.Count);
      for I := 1 to R.Count - 1 do
        AssertTrue('newest first', R.Rows[I]^.TimeCreated <= R.Rows[I - 1]^.TimeCreated);
      AssertEquals('System', R.Str(R.Rows[0]^.ChannelIx));
      AssertTrue(R.Stats.FirstRowMs >= 0);
      AssertTrue(R.Stats.Path = rpService);
      AssertTrue('filter carried', R.Filter.SameAs(F));
    finally
      R.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEvtApiTests.RendersXmlAndMessage;
var
  F: TSiftFilter;
  R: TSiftResult;
  Rd: TSiftRenderer;
  Ev: EVT_HANDLE;
  I, WithMsg: Integer;
  X: string;
begin
  F := TSiftFilter.Create;
  Rd := TSiftRenderer.Create;
  try
    F.Channels.Add('System');
    F.SetLastN(20);
    R := RunSift(F);
    try
      WithMsg := 0;
      for I := 0 to R.Count - 1 do
      begin
        Ev := R.OpenRow(Rd, I);
        AssertTrue('reopen row ' + IntToStr(I), Ev <> 0);
        X := Rd.RenderXml(Ev);
        AssertTrue(Pos('<Event ', X) = 1);
        AssertTrue(Pos('<EventRecordID>' + IntToStr(R.Rows[I]^.RecordId) + '</EventRecordID>', X) > 0);
        if Rd.FormatMessage(Ev, R.Str(R.Rows[I]^.ProviderIx)) <> '' then
          Inc(WithMsg);
        EvtClose(Ev);
      end;
      AssertTrue('most System events have a message', WithMsg >= R.Count div 2);
    finally
      R.Free;
    end;
  finally
    Rd.Free;
    F.Free;
  end;
end;

procedure TEvtApiTests.InvalidQueryReportsError;
var
  H: EVT_HANDLE;
begin
  H := EvtQuery(0, 'System', '*[System[EventID=]]', EvtQueryChannelPath);
  AssertEquals(0, H);
  AssertEquals(ERROR_EVT_INVALID_QUERY, GetLastError);
end;

procedure TEvtApiTests.MissingChannelReportsError;
var
  F: TSiftFilter;
  R: TSiftResult;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('Sift-No-Such-Channel/Operational');
    R := RunSift(F);
    try
      AssertEquals(0, R.Count);
      AssertEquals(1, Length(R.Errors));
      AssertEquals(ERROR_EVT_CHANNEL_NOT_FOUND, R.Errors[0].Code);
      AssertFalse(R.Errors[0].NeedsElevation);
    finally
      R.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEvtApiTests.SecurityAccessDeniedUnelevated;
var
  F: TSiftFilter;
  R: TSiftResult;
begin
  if Elevated then
  begin
    Ignore('elevated session: access-denied path not testable here');
    Exit;
  end;
  F := TSiftFilter.Create;
  try
    F.Channels.Add('Security');
    F.SetLastN(5);
    R := RunSift(F);
    try
      AssertEquals(0, R.Count);
      AssertEquals(1, Length(R.Errors));
      AssertEquals('Security', R.Errors[0].Channel);
      AssertEquals(ERROR_ACCESS_DENIED_, R.Errors[0].Code);
      AssertTrue('flags elevation', R.Errors[0].NeedsElevation);
    finally
      R.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEvtApiTests.AllChannelsToleratesDenied;
var
  F: TSiftFilter;
  R: TSiftResult;
  I: Integer;
  SawSecurity: Boolean;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.Channels.Add('Security');
    F.Channels.Add('Application');
    F.SetLastN(10);
    R := RunSift(F);
    try
      AssertEquals('denied channel does not sink the query', 10, R.Count);
      SawSecurity := False;
      for I := 0 to High(R.Errors) do
        if R.Errors[I].Channel = 'Security' then
          SawSecurity := R.Errors[I].NeedsElevation;
      if not Elevated then
        AssertTrue('Security reported as needing elevation', SawSecurity);
    finally
      R.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEvtApiTests.BookmarkSeekMatchesRecord;
var
  F: TSiftFilter;
  R: TSiftResult;
  Rd: TSiftRenderer;
  Ev: EVT_HANDLE;
  I: Integer;
begin
  F := TSiftFilter.Create;
  Rd := TSiftRenderer.Create;
  try
    F.Channels.Add('Application');
    F.SetLastN(200);
    R := RunSift(F);
    try
      for I := R.Count - 1 downto 0 do
      begin
        Ev := Rd.OpenEvent('Application', R.Rows[I]^.RecordId, 'Application');
        AssertTrue(Ev <> 0);
        AssertTrue(Pos('<EventRecordID>' + IntToStr(R.Rows[I]^.RecordId) + '<',
          Rd.RenderXml(Ev)) > 0);
        EvtClose(Ev);
      end;
    finally
      R.Free;
    end;
  finally
    Rd.Free;
    F.Free;
  end;
end;

initialization
  RegisterTest(TEvtApiTests);
end.
