unit Sift.Sids;

{ SID display without any network lookup: SID string plus a well-known
  local name where one exists. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

function SidToString(Sid: PSID): string;
function WellKnownSidName(const Sid: string): string;
function SidDisplay(const Sid: string): string;

implementation

function ConvertSidToStringSidW(Sid: PSID; out StringSid: PWideChar): BOOL;
  stdcall; external 'advapi32.dll' name 'ConvertSidToStringSidW';

function SidToString(Sid: PSID): string;
var
  P: PWideChar;
begin
  Result := '';
  if Sid = nil then
    Exit;
  P := nil;
  if ConvertSidToStringSidW(Sid, P) then
  begin
    Result := UTF8Encode(UnicodeString(P));
    LocalFree(HLOCAL(P));
  end;
end;

function WellKnownSidName(const Sid: string): string;
begin
  case UpperCase(Sid) of
    'S-1-0-0': Result := 'NULL SID';
    'S-1-1-0': Result := 'Everyone';
    'S-1-2-0': Result := 'LOCAL';
    'S-1-3-0': Result := 'CREATOR OWNER';
    'S-1-5-2': Result := 'NETWORK';
    'S-1-5-4': Result := 'INTERACTIVE';
    'S-1-5-6': Result := 'SERVICE';
    'S-1-5-7': Result := 'ANONYMOUS LOGON';
    'S-1-5-11': Result := 'Authenticated Users';
    'S-1-5-18': Result := 'SYSTEM';
    'S-1-5-19': Result := 'LOCAL SERVICE';
    'S-1-5-20': Result := 'NETWORK SERVICE';
    'S-1-5-32-544': Result := 'Administrators';
    'S-1-5-32-545': Result := 'Users';
    'S-1-5-32-546': Result := 'Guests';
    'S-1-5-32-573': Result := 'Event Log Readers';
  else
    if Copy(UpperCase(Sid), 1, 8) = 'S-1-5-90' then
      Result := 'Window Manager'
    else if Copy(UpperCase(Sid), 1, 8) = 'S-1-5-96' then
      Result := 'Font Driver Host'
    else if Copy(UpperCase(Sid), 1, 9) = 'S-1-5-80-' then
      Result := 'NT SERVICE'
    else
      Result := '';
  end;
end;

function SidDisplay(const Sid: string): string;
var
  N: string;
begin
  N := WellKnownSidName(Sid);
  if N <> '' then
    Result := N + ' (' + Sid + ')'
  else
    Result := Sid;
end;

end.
