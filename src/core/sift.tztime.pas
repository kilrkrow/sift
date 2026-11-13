unit Sift.TzTime;

{ Local time <-> UTC with the rules of the date being converted, not today's
  offset. FPC's LocalTimeToUniversal / UniversalTimeToLocal and
  FileTimeToLocalFileTime all apply the bias in effect *now*, so a time on
  the other side of a daylight-saving change comes out an hour off.

  TzSpecificLocalTimeToSystemTime (Windows XP+) and
  SystemTimeToTzSpecificLocalTime (Windows 2000+) look up the DST rules for
  the given date. Tz = nil means the computer's current time zone; tests pass
  a pinned TIME_ZONE_INFORMATION.

  Repeated hour (the hour after DST ends, 01:00-01:59 on the first Sunday
  of November in the US): a local time in it happens twice. Windows (and so
  Sift's Custom From/To) takes the FIRST instance, still daylight time:
  01:30 -> 08:30 UTC for US Pacific, not 09:30. The second 01:30 cannot be
  typed as local time; to cover it, end the window at 02:00 or later (a
  window ending at 01:59 stops at the first 01:59). UTC -> local is never
  ambiguous; both instances
  display as 01:xx (test FallBackRepeatedHourIsFirstInstance).
  Skipped hour (the hour DST starts, 02:00-02:59 in the US): no such local
  time exists. Windows applies the daylight bias, so 02:30 becomes 09:30 UTC
  (the instant shown as 01:30 standard time), one hour earlier than the
  wall-clock reading suggests; a From time there includes that extra hour
  (test SpringForwardGapHour). }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

function TzSpecificLocalTimeToSystemTime(lpTimeZoneInformation: PTimeZoneInformation;
  const lpLocalTime: TSystemTime; out lpUniversalTime: TSystemTime): BOOL; stdcall;
  external 'kernel32.dll' name 'TzSpecificLocalTimeToSystemTime';
function SystemTimeToTzSpecificLocalTime(lpTimeZoneInformation: PTimeZoneInformation;
  const lpUniversalTime: TSystemTime; out lpLocalTime: TSystemTime): BOOL; stdcall;
  external 'kernel32.dll' name 'SystemTimeToTzSpecificLocalTime';

function TryLocalToUtc(Local: TDateTime; out Utc: TDateTime;
  Tz: PTimeZoneInformation = nil): Boolean;
function TryUtcToLocal(Utc: TDateTime; out Local: TDateTime;
  Tz: PTimeZoneInformation = nil): Boolean;
{ falls back to the input unchanged if Windows cannot convert it }
function UtcToLocal(Utc: TDateTime; Tz: PTimeZoneInformation = nil): TDateTime;
{ 'yyyy-mm-dd hh:nn' with ASCII separators whatever the locale }
function LocalStamp(Local: TDateTime): string;

implementation

function TryLocalToUtc(Local: TDateTime; out Utc: TDateTime;
  Tz: PTimeZoneInformation): Boolean;
var
  L, U: TSystemTime;
begin
  Utc := 0;
  DateTimeToSystemTime(Local, L);
  Result := TzSpecificLocalTimeToSystemTime(Tz, L, U);
  if Result then
    Utc := SystemTimeToDateTime(U);
end;

function TryUtcToLocal(Utc: TDateTime; out Local: TDateTime;
  Tz: PTimeZoneInformation): Boolean;
var
  L, U: TSystemTime;
begin
  Local := 0;
  DateTimeToSystemTime(Utc, U);
  Result := SystemTimeToTzSpecificLocalTime(Tz, U, L);
  if Result then
    Local := SystemTimeToDateTime(L);
end;

function UtcToLocal(Utc: TDateTime; Tz: PTimeZoneInformation): TDateTime;
begin
  if not TryUtcToLocal(Utc, Result, Tz) then
    Result := Utc;
end;

function LocalStamp(Local: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd hh":"nn', Local);
end;

end.
