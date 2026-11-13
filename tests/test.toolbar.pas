unit Test.Toolbar;

{ Piece 10: the easy-button toolbar. Two-way sync between the toolbar and
  the filter that the right-click menu and quick buttons edit, the
  no-level-ticked case, and the use cases checked live against the exported
  Get-WinEvent (both the FilterHashtable one-liner and Export as PowerShell). }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Math, fpcunit, testregistry, Sift.Filter,
  Sift.Compiler, Sift.Query, Sift.Channels, Sift.Toolbar, Sift.EvtApi, Sift.TzTime;

type
  TToolbarTests = class(TTestCase)
  private
    FAll: TStringList;
    function SiftRows(F: TSiftFilter; out NowFT: Int64): TStringList;
    function PsRows(const Cmd: string): TStringList;
    function ExportInfo(F: TSiftFilter): TStringList;
    procedure CompareWindowed(F: TSiftFilter; const What: string);
    procedure CompareOrdered(F: TSiftFilter; const What: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure RightClickIncludeTicksLevel;
    procedure ToolbarLevelShowsAsChipTerm;
    procedure ExcludedLevelShowsExcluded;
    procedure NoLevelTickedMeansAllLevels;
    procedure OneSharedTimeWindow;
    procedure CustomWindowValidated;
    procedure MaxCountKeepsWindow;
    procedure LogChoiceSync;
    procedure ExportMapsToolbar;
    procedure UseCaseAllErrorsLastHour;
    procedure UseCaseLast15SystemErrors;
    procedure UseCaseToolbarPlusRightClickExclude;
    procedure ExportSkipsDeniedFirstSelect;
    procedure ExportSkipsMissingLog;
    procedure ExportAllDeniedWarnsAndStops;
    procedure ExportAllLogsProbeTime;
    procedure CustomRangeShownInLocalAscii;
  end;

implementation

uses
  Test.Util;

const
  FT_PER_SEC = Int64(10000000);
  EDGE = 30 * FT_PER_SEC;

procedure TToolbarTests.SetUp;
var
  Infos: TSiftChannelInfos;
begin
  FAll := TStringList.Create;
  EnumChannels(Infos);
  QueryableChannels(Infos, FAll);
end;

procedure TToolbarTests.TearDown;
begin
  FAll.Free;
end;

procedure TToolbarTests.RightClickIncludeTicksLevel;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    AssertTrue(LevelState(F, 2) = lsOff);
    F.ApplyCell(sfLevel, '2', saInclude, amAdd); { right-click Include Level=2 }
    AssertTrue('Error ticked', LevelState(F, 2) = lsOn);
    AssertEquals('2', LevelsOn(F));
    F.ApplyCell(sfLevel, '0', saInclude, amAdd); { level 0 is Information }
    AssertTrue('Info ticked by a level-0 row', LevelState(F, 4) = lsOn);
    F.ApplyCell(sfLevel, '3', saInclude, amSet); { Set as: only Warning }
    AssertEquals('3', LevelsOn(F));
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.ToolbarLevelShowsAsChipTerm;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    AssertTrue(ToggleLevel(F, 2) = lsOn);
    AssertEquals('one term, the same one a right-click adds', 1, F.TermCount);
    AssertEquals('Level = Error', TermCaption(F.Terms[0]));
    AssertTrue(ToggleLevel(F, 2) = lsOff);
    AssertEquals(0, F.TermCount);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.ExcludedLevelShowsExcluded;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.ApplyCell(sfLevel, '4', saExclude, amAdd); { right-click Exclude Info }
    AssertTrue(LevelState(F, 4) = lsExcluded);
    AssertTrue('clicking an excluded level clears it', ToggleLevel(F, 4) = lsOff);
    AssertEquals(0, F.TermCount);
    ToggleLevel(F, 4);
    F.ApplyCell(sfLevel, '4', saExclude, amAdd); { exclude replaces include }
    AssertTrue(LevelState(F, 4) = lsExcluded);
    AssertEquals(1, F.TermCount);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.NoLevelTickedMeansAllLevels;
var
  F: TSiftFilter;
  C: TSiftCompiled;
  L: Integer;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    for L in ToolbarLevelValues do
      ToggleLevel(F, L);
    for L in ToolbarLevelValues do
      ToggleLevel(F, L); { all off again }
    AssertEquals('', LevelsOn(F));
    C := CompileFilter(F, nil);
    AssertTrue('a Select is still emitted', C.SelectCount > 0);
    AssertEquals('no level predicate', 0, Pos('Level', C.QueryXml));
    AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System'' }', C.FilterHashtable);
    { all five ticked is also every level, including 0 (LogAlways) }
    for L in ToolbarLevelValues do
      ToggleLevel(F, L);
    C := CompileFilter(F, nil);
    AssertTrue(C.QueryXml, Pos('Level=0', C.QueryXml) > 0);
    AssertTrue(C.FilterHashtable, Pos('Level=1,2,3,4,0,5', C.FilterHashtable) > 0);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.OneSharedTimeWindow;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    AssertTrue(WindowPreset(F) = wpAny);
    F.SetRelativeWindow(15 * 60000); { quick button "15 min" }
    AssertTrue('toolbar shows the quick button''s window', WindowPreset(F) = wp15m);
    F.SetRelativeWindow(5 * 60000); { quick button "5 min" }
    AssertTrue(WindowPreset(F) = wpOther);
    AssertEquals('Last 5 min', WindowCaption(F));
    AssertTrue(SetWindowPreset(F, wp24h)); { toolbar }
    AssertEquals('the same field the quick buttons read', 86400000, F.RelativeMs);
    AssertTrue(F.TimeMode = tmRelative);
    F.SetLastN(10); { quick "Last 10" means any time }
    AssertTrue(WindowPreset(F) = wpAny);
    AssertTrue(SetWindowPreset(F, wp7d));
    AssertEquals(604800000, F.RelativeMs);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.CustomWindowValidated;
var
  F: TSiftFilter;
  A, B: TDateTime;
begin
  F := TSiftFilter.Create;
  try
    A := EncodeDate(2026, 10, 1);
    B := EncodeDate(2026, 10, 2);
    AssertFalse('end before start', SetWindowPreset(F, wpCustom, B, A));
    AssertFalse('no start', SetWindowPreset(F, wpCustom, 0, B));
    AssertTrue(F.TimeMode = tmAll);
    AssertTrue(SetWindowPreset(F, wpCustom, A, B));
    AssertTrue(WindowPreset(F) = wpCustom);
    AssertTrue(SetWindowPreset(F, wpCustom, A, 0)); { open-ended }
    AssertTrue(F.StartUtc = A);
    AssertTrue(F.EndUtc = 0);
    F.Channels.Add('System');
    AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; StartTime=[datetime]''2026-10-01T00:00:00.000Z'' }',
      CompileFilter(F, nil).FilterHashtable);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.MaxCountKeepsWindow;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    SetWindowPreset(F, wp1h);
    AssertTrue(SetMaxCountText(F, '15'));
    AssertEquals(15, F.LastN);
    AssertTrue(WindowPreset(F) = wp1h);
    AssertTrue(SetWindowPreset(F, wp24h));
    AssertEquals('window change keeps the cap', 15, F.LastN);
    AssertFalse(SetMaxCountText(F, '-3'));
    AssertFalse(SetMaxCountText(F, '1e3'));
    AssertFalse(SetMaxCountText(F, '99999999'));
    AssertEquals(15, F.LastN);
    AssertTrue(SetMaxCountText(F, ''));
    AssertEquals(0, F.LastN);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.LogChoiceSync;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.Channels.Add('Application');
    AssertEquals('several logs', '', LogChoice(F));
    SetLogChoice(F, 'Security');
    AssertEquals('Security', LogChoice(F));
    F.ApplyCell(sfChannel, 'System', saInclude, amAdd); { right-click Include Channel }
    AssertEquals('toolbar shows the right-click channel', 'System', LogChoice(F));
    F.ApplyCell(sfChannel, 'Setup', saExclude, amAdd);
    SetLogChoice(F, ToolbarAllLogs);
    AssertEquals('*', LogChoice(F));
    AssertEquals('Include channel replaced, Exclude kept', 1, F.TermCount);
    AssertTrue(F.Terms[0].Action = saExclude);
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.ExportMapsToolbar;
var
  F: TSiftFilter;
  C: TSiftCompiled;
begin
  F := TSiftFilter.Create;
  try
    SetLogChoice(F, 'System');
    ToggleLevel(F, 2);
    ToggleLevel(F, 3);
    SetWindowPreset(F, wp24h);
    SetMaxCountText(F, '15');
    C := CompileFilter(F, nil);
    AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; Level=2,3; StartTime=(Get-Date).AddHours(-24) } -MaxEvents 15',
      C.FilterHashtable);
    F.ApplyCell(sfEventId, '7036', saExclude, amAdd);
    C := CompileFilter(F, nil);
    AssertEquals('an Exclude still needs -FilterXml', '', C.FilterHashtable);
    AssertTrue(Pos('-FilterXml', CompilePowerShell(F, nil)) > 0);
    AssertTrue(Pos('-MaxEvents 15', CompilePowerShell(F, nil)) > 0);
    AssertTrue(Pos('<Suppress Path="System">', C.QueryXml) > 0);
  finally
    F.Free;
  end;
end;

{ --- live use cases --- }

function TToolbarTests.SiftRows(F: TSiftFilter; out NowFT: Int64): TStringList;
var
  Ex: TSiftExecutor;
  R: TSiftResult;
  I: Integer;
begin
  Ex := TSiftExecutor.Create;
  try
    NowFT := UtcNowFileTime;
    R := Ex.Execute(F, FAll);
    try
      Result := TStringList.Create;
      for I := 0 to R.Count - 1 do
        Result.Add(R.Key(I) + '|' + IntToStr(R.Rows[I]^.TimeCreated));
    finally
      R.Free;
    end;
  finally
    Ex.Free;
  end;
end;

function TToolbarTests.PsRows(const Cmd: string): TStringList;
begin
  Result := TStringList.Create;
  RunPs(Cmd + LineEnding +
    '$siftEvents | ForEach-Object { $_.LogName + ''|'' + $_.RecordId + ''|'' + $_.TimeCreated.ToFileTimeUtc() } | Set-Content $SiftOut', Result);
end;

function ExportScript(F: TSiftFilter; All: TStrings): string;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := CompilePowerShell(F, All);
    { run as exported; only the final display line is dropped }
    if Pos('$siftEvents | Format-Table', L[L.Count - 1]) = 1 then
      L.Delete(L.Count - 1);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function TimeOf(const S: string): Int64;
begin
  Result := StrToInt64Def(Copy(S, LastDelimiter('|', S) + 1, 40), 0);
end;

function KeyOf(const S: string): string;
begin
  Result := Copy(S, 1, LastDelimiter('|', S) - 1);
end;

procedure TToolbarTests.CompareWindowed(F: TSiftFilter; const What: string);
var
  A, P, A2, P2: TStringList;
  NowFT, Start: Int64;
  I: Integer;
  D, Cmd: string;
  C: TSiftCompiled;
  Pass: Integer;

  function Near(T: Int64): Boolean;
  begin
    Result := (T > NowFT - 3 * FT_PER_SEC) or (Abs(T - Start) < EDGE);
  end;

begin
  { events within 30 s of the window start or 3 s of "now" are left out:
    the two reads run a few seconds apart }
  C := CompileFilter(F, FAll);
  for Pass := 0 to 1 do
  begin
    if Pass = 0 then
      Cmd := ExportScript(F, FAll)
    else
    begin
      if C.FilterHashtable = '' then
        Break;
      Cmd := '$siftEvents = @(' + C.FilterHashtable + ' -ErrorAction SilentlyContinue)';
    end;
    A := SiftRows(F, NowFT);
    Start := NowFT - F.RelativeMs * 10000;
    P := PsRows(Cmd);
    A2 := TStringList.Create;
    P2 := TStringList.Create;
    try
      for I := 0 to A.Count - 1 do
        if not Near(TimeOf(A[I])) then
          A2.Add(KeyOf(A[I]));
      for I := 0 to P.Count - 1 do
        if not Near(TimeOf(P[I])) then
          P2.Add(KeyOf(P[I]));
      AssertTrue(What + ' ' + BoolToStr(Pass = 0, 'export', 'hashtable') + ': ' +
        IntToStr(A2.Count) + ' vs ' + IntToStr(P2.Count) + ' ' + D, SameKeySets(A2, P2, D));
    finally
      A.Free;
      P.Free;
      A2.Free;
      P2.Free;
    end;
  end;
end;

procedure TToolbarTests.CompareOrdered(F: TSiftFilter; const What: string);
var
  A, P: TStringList;
  NowFT: Int64;
  I: Integer;
  C: TSiftCompiled;
  Pass: Integer;
  Cmd: string;
begin
  C := CompileFilter(F, FAll);
  for Pass := 0 to 1 do
  begin
    if Pass = 0 then
      Cmd := ExportScript(F, FAll)
    else
    begin
      if C.FilterHashtable = '' then
        Break;
      Cmd := '$siftEvents = @(' + C.FilterHashtable + ' -ErrorAction SilentlyContinue)';
    end;
    A := SiftRows(F, NowFT);
    P := PsRows(Cmd);
    try
      for I := 0 to A.Count - 1 do
        A[I] := KeyOf(A[I]);
      for I := 0 to P.Count - 1 do
        P[I] := KeyOf(P[I]);
      { a new matching event can land between the two reads: 1-row shift }
      if (A.Count > 0) and (P.Count > 0) and (A[0] <> P[0]) then
      begin
        if A.IndexOf(P[0]) = 1 then A.Delete(0) else P.Delete(0);
      end;
      AssertTrue(What + ' count ' + IntToStr(A.Count) + ' vs ' + IntToStr(P.Count),
        Abs(A.Count - P.Count) <= 1);
      for I := 0 to Min(A.Count, P.Count) - 1 do
        AssertEquals(What + ' row ' + IntToStr(I), P[I], A[I]);
    finally
      A.Free;
      P.Free;
    end;
  end;
end;

procedure TToolbarTests.UseCaseAllErrorsLastHour;
var
  F: TSiftFilter;
begin
  { "All errors in the last hour": Level=Error, 1 h, All logs }
  F := TSiftFilter.Create;
  try
    SetLogChoice(F, ToolbarAllLogs);
    ToggleLevel(F, 2);
    SetWindowPreset(F, wp1h);
    AssertTrue(Length(CompileFilter(F, FAll).Channels) > 5);
    CompareWindowed(F, 'all errors last hour');
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.UseCaseLast15SystemErrors;
var
  F: TSiftFilter;
begin
  { "Last 15 System errors": Level=Error, Max 15, System }
  F := TSiftFilter.Create;
  try
    SetLogChoice(F, 'System');
    ToggleLevel(F, 2);
    SetMaxCountText(F, '15');
    AssertTrue(WindowPreset(F) = wpAny);
    AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; Level=2 } -MaxEvents 15',
      CompileFilter(F, FAll).FilterHashtable);
    CompareOrdered(F, 'last 15 System errors');
  finally
    F.Free;
  end;
end;

procedure TToolbarTests.UseCaseToolbarPlusRightClickExclude;
var
  F: TSiftFilter;
  Ex: TSiftExecutor;
  R: TSiftResult;
  Top: string;
begin
  { toolbar: Error + Warning, 24 h, System; right-click Exclude the newest
    row's Event ID }
  F := TSiftFilter.Create;
  Ex := TSiftExecutor.Create;
  try
    SetLogChoice(F, 'System');
    ToggleLevel(F, 2);
    ToggleLevel(F, 3);
    SetWindowPreset(F, wp24h);
    R := Ex.Execute(F, FAll);
    try
      if R.Count = 0 then
        Top := '7036'
      else
        Top := IntToStr(R.Rows[0]^.EventId);
    finally
      R.Free;
    end;
    F.ApplyCell(sfEventId, Top, saExclude, amAdd);
    AssertTrue(F.HasExcludes);
    AssertEquals('-FilterXml rule: no one-liner with an Exclude', '',
      CompileFilter(F, FAll).FilterHashtable);
    CompareWindowed(F, 'toolbar + exclude ' + Top);
    SetMaxCountText(F, '25');
    CompareOrdered(F, 'toolbar + exclude + max 25');
  finally
    Ex.Free;
    F.Free;
  end;
end;

{ ---- export: unreadable and missing logs ---- }

function TToolbarTests.ExportInfo(F: TSiftFilter): TStringList;
begin
  Result := TStringList.Create;
  RunPs('$siftT = [System.Diagnostics.Stopwatch]::StartNew()' + LineEnding +
    ExportScript(F, FAll) + LineEnding +
    '@((''denied='' + (@($siftDenied) -join '','')), (''missing='' + (@($siftMissing) -join '','')), ' +
    '(''probe='' + $siftProbeMs), (''total='' + $siftT.ElapsedMilliseconds), (''events='' + @($siftEvents).Count), ' +
    '(''errors='' + @($siftErrors).Count)) | Set-Content $SiftOut', Result);
end;

function Deniedchannels(All: TStrings; Want: Integer): TStringList;
var
  I: Integer;
  H: EVT_HANDLE;
  W: UnicodeString;
begin
  Result := TStringList.Create;
  for I := 0 to All.Count - 1 do
  begin
    W := UTF8Decode(All[I]);
    H := EvtQuery(0, PWideChar(W), '*', EvtQueryChannelPath or EvtQueryReverseDirection);
    if H <> 0 then
      EvtClose(H)
    else if GetLastError = ERROR_ACCESS_DENIED then
    begin
      Result.Add(All[I]);
      if Result.Count >= Want then
        Exit;
    end;
  end;
end;

procedure TToolbarTests.ExportSkipsDeniedFirstSelect;
var
  F: TSiftFilter;
  C: TSiftCompiled;
  Info: TStringList;
  P: Integer;
begin
  if Elevated then
    Ignore('elevated session: Security is readable');
  F := TSiftFilter.Create;
  Info := nil;
  try
    F.Channels.Add('Security');
    F.Channels.Add('System');
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    F.SetRelativeWindow(Int64(7) * 24 * 3600000);
    C := CompileFilter(F, FAll);
    P := Pos('<Select Path="', C.QueryXml);
    AssertEquals('the denied log is the first Select', 'Security', Copy(C.QueryXml, P + 14, 8));
    CompareWindowed(F, 'Security (denied, first Select) + System');
    Info := ExportInfo(F);
    AssertEquals('denied log reported', 'Security', Info.Values['denied']);
    AssertEquals('errors after the retry', '0', Info.Values['errors']);
  finally
    Info.Free;
    F.Free;
  end;
end;

procedure TToolbarTests.ExportSkipsMissingLog;
var
  F: TSiftFilter;
  Info: TStringList;
begin
  F := TSiftFilter.Create;
  Info := nil;
  try
    F.Channels.Add('System');
    F.Channels.Add('Sift-NoSuchLog-7f3a/Operational');
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    F.SetRelativeWindow(Int64(7) * 24 * 3600000);
    CompareWindowed(F, 'System + a log that does not exist');
    Info := ExportInfo(F);
    AssertEquals('missing log reported', 'Sift-NoSuchLog-7f3a/Operational', Info.Values['missing']);
    AssertEquals('errors after the retry', '0', Info.Values['errors']);
  finally
    Info.Free;
    F.Free;
  end;
end;

procedure TToolbarTests.ExportAllDeniedWarnsAndStops;
var
  F: TSiftFilter;
  D, Info: TStringList;
  I: Integer;
begin
  if Elevated then
    Ignore('elevated session: no log is denied');
  D := Deniedchannels(FAll, 2);
  F := TSiftFilter.Create;
  Info := nil;
  try
    if D.Count < 2 then
      Ignore('fewer than two access-denied logs on this machine');
    for I := 0 to D.Count - 1 do
      F.Channels.Add(D[I]);
    F.SetRelativeWindow(Int64(7) * 24 * 3600000);
    Info := ExportInfo(F);
    AssertEquals('both reported denied', D.Count, Length(Info.Values['denied'].Split([','])));
    AssertEquals('no events', '0', Info.Values['events']);
    { an empty <QueryList> passed to Get-WinEvent would leave an error here }
    AssertEquals('no query run, no error', '0', Info.Values['errors']);
  finally
    Info.Free;
    F.Free;
    D.Free;
  end;
end;

procedure TToolbarTests.ExportAllLogsProbeTime;
var
  F: TSiftFilter;
  Info: TStringList;
begin
  F := TSiftFilter.Create;
  Info := nil;
  try
    F.Channels.Add(ToolbarAllLogs);
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.SetRelativeWindow(3600000);
    Info := ExportInfo(F);
    WriteLn(Format('  info: export of "all errors last hour" over %d logs: probe %s ms, whole script %s ms, ' +
      'denied %d, missing %d, events %s',
      [FAll.Count, Info.Values['probe'], Info.Values['total'],
       Length(Info.Values['denied'].Split([','], TStringSplitOptions.ExcludeEmpty)),
       Length(Info.Values['missing'].Split([','], TStringSplitOptions.ExcludeEmpty)), Info.Values['events']]));
    AssertEquals('errors after the retry', '0', Info.Values['errors']);
    if not Elevated then
      AssertTrue('Security reported denied', Pos('Security', Info.Values['denied']) > 0);
  finally
    Info.Free;
    F.Free;
  end;
end;

procedure TToolbarTests.CustomRangeShownInLocalAscii;
var
  F: TSiftFilter;
  Tz: TTimeZoneInformation;
  S: string;
  I: Integer;
begin
  FillChar(Tz, SizeOf(Tz), 0);
  Tz.Bias := 480;
  Tz.DaylightBias := -60;
  Tz.StandardDate.wMonth := 11;
  Tz.StandardDate.wDay := 1;
  Tz.StandardDate.wHour := 2;
  Tz.DaylightDate.wMonth := 3;
  Tz.DaylightDate.wDay := 2;
  Tz.DaylightDate.wHour := 2;
  F := TSiftFilter.Create;
  try
    AssertEquals('not custom', '', CustomRangeText(F, @Tz));
    { 2026-10-31 15:00 UTC = 08:00 PDT; 2026-11-02 18:00 UTC = 10:00 PST }
    AssertTrue(SetWindowPreset(F, wpCustom, EncodeDate(2026, 10, 31) + EncodeTime(15, 0, 0, 0),
      EncodeDate(2026, 11, 2) + EncodeTime(18, 0, 0, 0)));
    S := CustomRangeText(F, @Tz);
    AssertEquals('2026-10-31 08:00 to 2026-11-02 10:00', S);
    for I := 1 to Length(S) do
      AssertTrue('ASCII', Ord(S[I]) < 128);
    AssertTrue(SetWindowPreset(F, wpCustom, EncodeDate(2026, 11, 2) + EncodeTime(18, 0, 0, 0), 0));
    AssertEquals('from 2026-11-02 10:00', CustomRangeText(F, @Tz));
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TToolbarTests);
end.
