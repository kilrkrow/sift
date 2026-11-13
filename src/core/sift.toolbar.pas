unit Sift.Toolbar;

{ Piece 10: the easy-button toolbar's view of a TSiftFilter. The toolbar has
  no state of its own: every control reads from and writes into the same
  filter the right-click menu, the chips and the quick buttons use, and the
  same compiler turns it into a query. So the two stay in sync both ways
  and there is one time-window state. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Sift.Filter, Sift.TzTime;

type
  TSiftLevelState = (lsOff, lsOn, lsExcluded);
  TSiftWindowPreset = (wpAny, wp15m, wp1h, wp24h, wp7d, wpCustom, wpOther);

const
  ToolbarLevelValues: array[0..4] of Integer = (1, 2, 3, 4, 5);
  ToolbarLevelCaptions: array[0..4] of string = ('Critical', 'Error', 'Warning',
    'Info', 'Verbose');
  WindowPresetMs: array[wp15m..wp7d] of Int64 = (900000, 3600000, 86400000,
    604800000);
  WindowPresetCaptions: array[TSiftWindowPreset] of string = ('Any time',
    '15 min', '1 h', '24 h', '7 d', 'Custom...', '');
  { toolbar log choice for "every readable log" }
  ToolbarAllLogs = '*';

{ Level checkbox state: On = an Include term, Excluded = an Exclude term
  (from the right-click menu), Off = neither. No level On means all levels. }
function LevelState(F: TSiftFilter; Level: Integer): TSiftLevelState;
{ Off -> On (adds Include), On -> Off (removes it), Excluded -> Off
  (removes the Exclude). Returns the new state. }
function ToggleLevel(F: TSiftFilter; Level: Integer): TSiftLevelState;
{ The levels that are On, e.g. '2,3'; '' = all levels }
function LevelsOn(F: TSiftFilter): string;

function WindowPreset(F: TSiftFilter): TSiftWindowPreset;
{ Text for wpOther (a quick-button window the toolbar has no preset for). }
function WindowCaption(F: TSiftFilter): string;
{ A Custom (absolute) window in local time, ASCII only:
  'yyyy-mm-dd hh:nn to yyyy-mm-dd hh:nn', or 'from yyyy-mm-dd hh:nn' when
  open-ended; '' when the window is not Custom. Tz as in Sift.TzTime. }
function CustomRangeText(F: TSiftFilter; Tz: PTimeZoneInformation = nil): string;
{ Sets the shared window and keeps the max count. wpCustom needs
  StartUtc < EndUtc (EndUtc = 0 means open-ended); returns False otherwise
  and leaves F unchanged. }
function SetWindowPreset(F: TSiftFilter; P: TSiftWindowPreset;
  StartUtc: TDateTime = 0; EndUtc: TDateTime = 0): Boolean;

{ Max count from the edit box text: '' or 0 = no cap; anything that is not
  a whole number from 0 to 1000000 is rejected (False, F unchanged). }
function SetMaxCountText(F: TSiftFilter; const S: string): Boolean;

{ '*' for every readable log, a channel name when exactly one log is
  queried, '' when several are (the Logs... picker shows those). }
function LogChoice(F: TSiftFilter): string;
{ Queries one log, or every readable log for '*'. Removes Include-channel
  terms (they would override the choice); Exclude-channel terms stay. }
procedure SetLogChoice(F: TSiftFilter; const Name: string);

implementation

function LevelState(F: TSiftFilter; Level: Integer): TSiftLevelState;
var
  V: string;
begin
  V := IntToStr(Level);
  if F.IndexOfTerm(MakeTerm(sfLevel, saInclude, V)) >= 0 then
    Result := lsOn
  else if F.IndexOfTerm(MakeTerm(sfLevel, saExclude, V)) >= 0 then
    Result := lsExcluded
  else
    Result := lsOff;
end;

function ToggleLevel(F: TSiftFilter; Level: Integer): TSiftLevelState;
var
  V: string;
begin
  V := IntToStr(Level);
  case LevelState(F, Level) of
    lsOff: F.ApplyCell(sfLevel, V, saInclude, amAdd);
    lsOn: F.DeleteTerm(F.IndexOfTerm(MakeTerm(sfLevel, saInclude, V)));
    lsExcluded: F.DeleteTerm(F.IndexOfTerm(MakeTerm(sfLevel, saExclude, V)));
  end;
  Result := LevelState(F, Level);
end;

function LevelsOn(F: TSiftFilter): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ToolbarLevelValues) do
    if LevelState(F, ToolbarLevelValues[I]) = lsOn then
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + IntToStr(ToolbarLevelValues[I]);
    end;
end;

function WindowPreset(F: TSiftFilter): TSiftWindowPreset;
var
  P: TSiftWindowPreset;
begin
  case F.TimeMode of
    tmAll: Result := wpAny;
    tmAbsolute: Result := wpCustom;
  else
    begin
      for P := wp15m to wp7d do
        if F.RelativeMs = WindowPresetMs[P] then
          Exit(P);
      Result := wpOther;
    end;
  end;
end;

function WindowCaption(F: TSiftFilter): string;
var
  Ms: Int64;
begin
  case WindowPreset(F) of
    wpOther:
      begin
        Ms := F.RelativeMs;
        if (Ms mod 3600000) = 0 then
          Result := 'Last ' + IntToStr(Ms div 3600000) + ' h'
        else if (Ms mod 60000) = 0 then
          Result := 'Last ' + IntToStr(Ms div 60000) + ' min'
        else
          Result := 'Last ' + IntToStr(Ms div 1000) + ' s';
      end;
  else
    Result := WindowPresetCaptions[WindowPreset(F)];
  end;
end;

function CustomRangeText(F: TSiftFilter; Tz: PTimeZoneInformation): string;
begin
  Result := '';
  if F.TimeMode <> tmAbsolute then
    Exit;
  if F.EndUtc = 0 then
    Result := 'from ' + LocalStamp(UtcToLocal(F.StartUtc, Tz))
  else
    Result := LocalStamp(UtcToLocal(F.StartUtc, Tz)) + ' to ' +
      LocalStamp(UtcToLocal(F.EndUtc, Tz));
end;

function SetWindowPreset(F: TSiftFilter; P: TSiftWindowPreset;
  StartUtc: TDateTime; EndUtc: TDateTime): Boolean;
var
  N: Integer;
begin
  Result := True;
  N := F.LastN;
  case P of
    wpAny: F.ClearWindow;
    wp15m..wp7d: F.SetRelativeWindow(WindowPresetMs[P]);
    wpCustom:
      begin
        if (StartUtc <= 0) or ((EndUtc <> 0) and (EndUtc <= StartUtc)) then
          Exit(False);
        F.SetAbsoluteWindow(StartUtc, EndUtc);
      end;
  else
    Exit(False);
  end;
  F.SetMaxCount(N);
end;

function SetMaxCountText(F: TSiftFilter; const S: string): Boolean;
var
  N: Integer;
  T: string;
  C: Char;
begin
  T := Trim(S);
  if T = '' then
    N := 0
  else
  begin
    for C in T do
      if not (C in ['0'..'9']) then
        Exit(False);
    if (Length(T) > 7) or not TryStrToInt(T, N) or (N > 1000000) then
      Exit(False);
  end;
  F.SetMaxCount(N);
  Result := True;
end;

function LogChoice(F: TSiftFilter): string;
var
  Inc_: TStringArray;
begin
  Inc_ := F.TermsFor(sfChannel, saInclude);
  if Length(Inc_) = 1 then
    Exit(Inc_[0]);
  if Length(Inc_) > 1 then
    Exit('');
  if F.Channels.Count = 1 then
    Result := F.Channels[0]
  else
    Result := '';
end;

procedure SetLogChoice(F: TSiftFilter; const Name: string);
var
  I: Integer;
begin
  for I := F.TermCount - 1 downto 0 do
    if (F.Terms[I].Field = sfChannel) and (F.Terms[I].Action = saInclude) then
      F.DeleteTerm(I);
  F.Channels.Clear;
  F.Channels.Add(Name);
end;

end.
