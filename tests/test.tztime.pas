unit Test.TzTime;

{ DST-correct local <-> UTC (Sift.TzTime) with a pinned time zone: US
  Pacific (UTC-8, daylight UTC-7 from the 2nd Sunday of March 02:00 to the
  1st Sunday of November 02:00), independent of this machine's zone. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, fpcunit, testregistry, Sift.TzTime;

type
  TTzTimeTests = class(TTestCase)
  private
    FTz: TTimeZoneInformation;
    function ToUtc(Y, Mo, D, H, Mi: Word): string;
    function ToLocal(Y, Mo, D, H, Mi: Word): string;
  protected
    procedure SetUp; override;
  published
    procedure FallBackLocalToUtc;
    procedure FallBackUtcToLocal;
    procedure FallBackRepeatedHourIsFirstInstance;
    procedure SpringForwardLocalToUtc;
    procedure SpringForwardUtcToLocal;
    procedure SpringForwardGapHour;
  end;

implementation

function Stamp(T: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn', T);
end;

procedure TTzTimeTests.SetUp;
begin
  FillChar(FTz, SizeOf(FTz), 0);
  FTz.Bias := 480;
  FTz.StandardBias := 0;
  FTz.DaylightBias := -60;
  FTz.StandardDate.wMonth := 11;   { 1st Sunday of November, 02:00 }
  FTz.StandardDate.wDayOfWeek := 0;
  FTz.StandardDate.wDay := 1;
  FTz.StandardDate.wHour := 2;
  FTz.DaylightDate.wMonth := 3;    { 2nd Sunday of March, 02:00 }
  FTz.DaylightDate.wDayOfWeek := 0;
  FTz.DaylightDate.wDay := 2;
  FTz.DaylightDate.wHour := 2;
end;

function TTzTimeTests.ToUtc(Y, Mo, D, H, Mi: Word): string;
var
  U: TDateTime;
begin
  AssertTrue('TzSpecificLocalTimeToSystemTime', TryLocalToUtc(EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, 0, 0), U, @FTz));
  Result := Stamp(U);
end;

function TTzTimeTests.ToLocal(Y, Mo, D, H, Mi: Word): string;
var
  L: TDateTime;
begin
  AssertTrue('SystemTimeToTzSpecificLocalTime', TryUtcToLocal(EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, 0, 0), L, @FTz));
  Result := Stamp(L);
end;

procedure TTzTimeTests.FallBackLocalToUtc;
begin
  { Sat 2026-10-31 is PDT (UTC-7), Mon 2026-11-02 is PST (UTC-8): the
    offset of each date, not of today }
  AssertEquals('2026-10-31 19:00', ToUtc(2026, 10, 31, 12, 0));
  AssertEquals('2026-11-01 07:30', ToUtc(2026, 11, 1, 0, 30));
  AssertEquals('2026-11-01 11:00', ToUtc(2026, 11, 1, 3, 0));
  AssertEquals('2026-11-02 20:00', ToUtc(2026, 11, 2, 12, 0));
end;

procedure TTzTimeTests.FallBackUtcToLocal;
begin
  AssertEquals('2026-10-31 12:00', ToLocal(2026, 10, 31, 19, 0));
  AssertEquals('2026-11-02 12:00', ToLocal(2026, 11, 2, 20, 0));
  { both instances of the repeated hour read 01:30 local }
  AssertEquals('2026-11-01 01:30', ToLocal(2026, 11, 1, 8, 30));
  AssertEquals('2026-11-01 01:30', ToLocal(2026, 11, 1, 9, 30));
end;

procedure TTzTimeTests.FallBackRepeatedHourIsFirstInstance;
begin
  { 01:30 on 2026-11-01 happens twice (08:30 and 09:30 UTC); Windows takes
    the first one, still daylight time (UTC-7) }
  AssertEquals('2026-11-01 08:30', ToUtc(2026, 11, 1, 1, 30));
end;

procedure TTzTimeTests.SpringForwardLocalToUtc;
begin
  AssertEquals('2027-03-14 09:30', ToUtc(2027, 3, 14, 1, 30));
  AssertEquals('2027-03-14 10:30', ToUtc(2027, 3, 14, 3, 30));
  AssertEquals('2027-03-13 20:00', ToUtc(2027, 3, 13, 12, 0));
  AssertEquals('2027-03-15 19:00', ToUtc(2027, 3, 15, 12, 0));
end;

procedure TTzTimeTests.SpringForwardUtcToLocal;
begin
  AssertEquals('2027-03-14 01:59', ToLocal(2027, 3, 14, 9, 59));
  AssertEquals('2027-03-14 03:00', ToLocal(2027, 3, 14, 10, 0));
  AssertEquals('2027-03-15 12:00', ToLocal(2027, 3, 15, 19, 0));
end;

procedure TTzTimeTests.SpringForwardGapHour;
begin
  { 02:30 on 2027-03-14 does not exist locally; Windows converts it with the
    daylight bias (UTC-7): 09:30 UTC, the instant shown as 01:30 PST }
  AssertEquals('2027-03-14 09:30', ToUtc(2027, 3, 14, 2, 30));
end;

initialization
  RegisterTest(TTzTimeTests);
end.
