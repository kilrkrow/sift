unit Test.Equivalence;

{ Piece 1/3/4 critic: Sift results must equal what Get-WinEvent returns on
  the same .evtx fixtures (no admin needed). Oracles:
   - "dump": Get-WinEvent -Path <fixture> (every event, no filter), then the
     test's own predicate in Pascal - independent of XPath and EvtQuery;
   - "hashtable": Get-WinEvent -FilterHashtable @{ Path = ... } for
     include-only filters;
   - "export": the PowerShell that Sift exports, run as-is on Windows
     PowerShell 5.1.
  Also checks the live last-N and time windows against Get-WinEvent. }

{$mode objfpc}{$H+}
{$modeswitch nestedprocvars}

interface

uses
  Windows, SysUtils, Classes, Math, fpcunit, testregistry, Sift.Filter,
  Sift.Compiler, Sift.Query, Test.Util;

type
  TEquivalenceTests = class(TTestCase)
  private
    FSys, FApp: string;
    FSysEv, FAppEv: TOracleEvents;
    procedure CheckDump(F: TSiftFilter; const Ev: TOracleEvents;
      Pred: TOraclePred; const What: string; MinRows: Integer = 0);
    function TopIds(const Ev: TOracleEvents; N: Integer): TStringArray;
    function TopProvider(const Ev: TOracleEvents): string;
    function NewestFT(const Ev: TOracleEvents): Int64;
    function NewFilter(const Paths: array of string): TSiftFilter;
    function PsKeys(const Script: string): TStringList;
  protected
    procedure SetUp; override;
  published
    procedure FixturesLoad;
    procedure IncludeLevels;
    procedure IncludeTopIds;
    procedure ExcludeTopId;
    procedure IncludeProviderExcludeId;
    procedure IncludeAndExcludeSameField;
    procedure MultiChannelInterleaved;
    procedure MoreThanTwentyTerms;
    procedure EmptyResult;
    procedure UserComputerTaskKeywords;
    procedure LastNMatchesNewestFirst;
    procedure TimeWindowsMatch;
    procedure TextIncludeExclude;
    procedure HashtableOracleIncludeOnly;
    procedure ExportedPowerShellReturnsSameEvents;
    procedure SecurityDeniedMatchesGetWinEvent;
    procedure LiveLastNMatchesGetWinEvent;
    procedure LiveWindowsMatchGetWinEvent;
    procedure ProbeSeedFixture;
  end;

implementation

const
  FT_PER_MIN = Int64(600000000);

var
  OkK: Boolean;

function FileUrl(const P: string): string;
begin
  Result := 'file://' + P;
end;

procedure TEquivalenceTests.SetUp;
begin
  EnsureFixtures;
  FSys := FixturePath('system.evtx');
  FApp := FixturePath('application.evtx');
  FSysEv := LoadOracle(FSys);
  FAppEv := LoadOracle(FApp);
end;

function TEquivalenceTests.NewFilter(const Paths: array of string): TSiftFilter;
var
  P: string;
begin
  Result := TSiftFilter.Create;
  for P in Paths do
    Result.Channels.Add(FileUrl(P));
end;

procedure TEquivalenceTests.CheckDump(F: TSiftFilter; const Ev: TOracleEvents;
  Pred: TOraclePred; const What: string; MinRows: Integer);
var
  R: TSiftResult;
  A, B: TStringList;
  D: string;
  Ok: Boolean;
begin
  R := RunSift(F);
  A := ResultKeys(R);
  B := OracleKeys(Ev, Pred);
  try
    AssertEquals(What + ': no query error', 0, Int64(R.Stats.QueryError));
    Ok := SameKeySets(A, B, D);
    AssertTrue(What + ': ' + D, Ok);
    AssertTrue(What + Format(': expected >= %d rows, got %d', [MinRows, A.Count]), A.Count >= MinRows);
  finally
    A.Free;
    B.Free;
    R.Free;
  end;
end;

function TEquivalenceTests.TopIds(const Ev: TOracleEvents; N: Integer): TStringArray;
var
  Counts: TStringList;
  E: TOracleEvent;
  I, J, K: Integer;
begin
  Counts := TStringList.Create;
  try
    for E in Ev do
    begin
      I := Counts.IndexOf(IntToStr(E.Id));
      if I < 0 then
        Counts.AddObject(IntToStr(E.Id), TObject(PtrInt(1)))
      else
        Counts.Objects[I] := TObject(PtrInt(Counts.Objects[I]) + 1);
    end;
    { simple selection of the N most frequent }
    SetLength(Result, Min(N, Counts.Count));
    for K := 0 to High(Result) do
    begin
      J := 0;
      for I := 1 to Counts.Count - 1 do
        if PtrInt(Counts.Objects[I]) > PtrInt(Counts.Objects[J]) then
          J := I;
      Result[K] := Counts[J];
      Counts.Objects[J] := TObject(PtrInt(-1));
    end;
  finally
    Counts.Free;
  end;
end;

function TEquivalenceTests.TopProvider(const Ev: TOracleEvents): string;
var
  Counts: TStringList;
  E: TOracleEvent;
  I, J: Integer;
begin
  Counts := TStringList.Create;
  try
    for E in Ev do
    begin
      I := Counts.IndexOf(E.Provider);
      if I < 0 then
        Counts.AddObject(E.Provider, TObject(PtrInt(1)))
      else
        Counts.Objects[I] := TObject(PtrInt(Counts.Objects[I]) + 1);
    end;
    J := 0;
    for I := 1 to Counts.Count - 1 do
      if PtrInt(Counts.Objects[I]) > PtrInt(Counts.Objects[J]) then
        J := I;
    Result := Counts[J];
  finally
    Counts.Free;
  end;
end;

function TEquivalenceTests.NewestFT(const Ev: TOracleEvents): Int64;
var
  E: TOracleEvent;
begin
  Result := 0;
  for E in Ev do
    if E.TimeFT > Result then
      Result := E.TimeFT;
end;

function TEquivalenceTests.PsKeys(const Script: string): TStringList;
begin
  Result := TStringList.Create;
  RunPs(Script, Result);
end;

procedure TEquivalenceTests.FixturesLoad;
begin
  AssertTrue('system fixture has events', Length(FSysEv) > 100);
  AssertTrue('application fixture has events', Length(FAppEv) > 100);
end;

procedure TEquivalenceTests.IncludeLevels;
var
  F: TSiftFilter;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := E.Level in [2, 3];
  end;

  function PInfo(const E: TOracleEvent): Boolean;
  begin
    Result := E.Level in [0, 4];
  end;

begin
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfLevel, saInclude, 'Error'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, 'Warning'));
    CheckDump(F, FSysEv, @P, 'levels 2,3');
    F.ClearTerms;
    F.AddTerm(MakeTerm(sfLevel, saInclude, 'Information'));
    CheckDump(F, FSysEv, @PInfo, 'Information = 4 or 0', 1);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.IncludeTopIds;
var
  F: TSiftFilter;
  Ids: TStringArray;
  S: string;

  function P(const E: TOracleEvent): Boolean;
  var
    X: string;
  begin
    Result := False;
    for X in Ids do
      if IntToStr(E.Id) = X then
        Exit(True);
  end;

begin
  Ids := TopIds(FSysEv, 3);
  F := NewFilter([FSys]);
  try
    for S in Ids do
      F.AddTerm(MakeTerm(sfEventId, saInclude, S));
    CheckDump(F, FSysEv, @P, 'top 3 ids', 3);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.ExcludeTopId;
var
  F: TSiftFilter;
  Id: string;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := IntToStr(E.Id) <> Id;
  end;

begin
  Id := TopIds(FSysEv, 1)[0];
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfEventId, saExclude, Id));
    CheckDump(F, FSysEv, @P, 'exclude top id ' + Id, 1);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.IncludeProviderExcludeId;
var
  F: TSiftFilter;
  Prov, Id: string;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := SameText(E.Provider, Prov) and (IntToStr(E.Id) <> Id);
  end;

  function First(const E: TOracleEvent): Boolean;
  begin
    Result := SameText(E.Provider, Prov);
  end;

var
  I: Integer;
begin
  Prov := TopProvider(FSysEv);
  Id := '';
  for I := 0 to High(FSysEv) do
    if SameText(FSysEv[I].Provider, Prov) then
    begin
      Id := IntToStr(FSysEv[I].Id);
      Break;
    end;
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfProvider, saInclude, Prov));
    CheckDump(F, FSysEv, @First, 'provider ' + Prov, 1);
    F.AddTerm(MakeTerm(sfEventId, saExclude, Id));
    CheckDump(F, FSysEv, @P, 'provider minus id ' + Id);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.IncludeAndExcludeSameField;
var
  F: TSiftFilter;
  Ids: TStringArray;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := (E.Level in [2, 3, 4, 0]) and (IntToStr(E.Id) <> Ids[0]) and
      (IntToStr(E.Id) <> Ids[1]) and (E.Level <> 3);
  end;

begin
  Ids := TopIds(FSysEv, 2);
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '4'));
    F.AddTerm(MakeTerm(sfLevel, saExclude, '3'));
    F.AddTerm(MakeTerm(sfEventId, saExclude, Ids[0]));
    F.AddTerm(MakeTerm(sfEventId, saExclude, Ids[1]));
    CheckDump(F, FSysEv, @P, 'include+exclude combo');
  finally
    F.Free;
  end;
end;

function TopByRecord(const Ev: TOracleEvents; N: Integer): TOracleEvents;
var
  S: TOracleEvents;
  I, J: Integer;
  T: TOracleEvent;
begin
  S := Copy(Ev);
  for I := 1 to High(S) do
  begin
    T := S[I];
    J := I - 1;
    while (J >= 0) and (S[J].RecordId < T.RecordId) do
    begin
      S[J + 1] := S[J];
      Dec(J);
    end;
    S[J + 1] := T;
  end;
  if Length(S) > N then
    SetLength(S, N);
  Result := S;
end;

function MergedLastN(const A, B: TOracleEvents; N: Integer): TStringArray;
var
  M: TOracleEvents;
  I, J: Integer;
  T: TOracleEvent;
begin
  M := Concat(TopByRecord(A, N), TopByRecord(B, N));
  for I := 1 to High(M) do
  begin
    T := M[I];
    J := I - 1;
    while (J >= 0) and ((M[J].TimeFT < T.TimeFT) or
      ((M[J].TimeFT = T.TimeFT) and (M[J].RecordId < T.RecordId))) do
    begin
      M[J + 1] := M[J];
      Dec(J);
    end;
    M[J + 1] := T;
  end;
  if Length(M) > N then
    SetLength(M, N);
  SetLength(Result, Length(M));
  for I := 0 to High(M) do
    Result[I] := M[I].LogName + '|' + IntToStr(M[I].RecordId);
end;

procedure TEquivalenceTests.MultiChannelInterleaved;
var
  F: TSiftFilter;
  Both: TOracleEvents;
  R: TSiftResult;
  I, N: Integer;
  Want: TStringArray;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := E.Level in [1, 2, 3];
  end;

begin
  Both := Concat(FSysEv, FAppEv);
  F := NewFilter([FSys, FApp]);
  try
    F.AddTerm(MakeTerm(sfLevel, saInclude, '1'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    CheckDump(F, Both, @P, 'two fixtures, levels 1-3', 1);
    { several sources are merged newest-first by time }
    F.ClearTerms;
    R := RunSift(F);
    try
      AssertEquals(Length(Both), R.Count);
      for I := 1 to R.Count - 1 do
        AssertTrue('merged newest-first at ' + IntToStr(I),
          R.Rows[I]^.TimeCreated <= R.Rows[I - 1]^.TimeCreated);
    finally
      R.Free;
    end;
    { last-N across sources: each source's last N (record order), merged by
      time, newest N kept. Oracle built the same way from the dumps. }
    for N in [5, 40, 200] do
    begin
      F.SetLastN(N);
      Want := MergedLastN(FSysEv, FAppEv, N);
      R := RunSift(F);
      try
        AssertEquals('multi last ' + IntToStr(N), Length(Want), R.Count);
        for I := 0 to R.Count - 1 do
          AssertEquals(Format('multi last %d row %d', [N, I]), Want[I], R.Key(I));
      finally
        R.Free;
      end;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.MoreThanTwentyTerms;
var
  F: TSiftFilter;
  Ids: TStringArray;
  I: Integer;
  C: TSiftCompiled;

  function P(const E: TOracleEvent): Boolean;
  var
    X: string;
  begin
    Result := False;
    if not (E.Level in [2, 3, 4, 0]) then
      Exit;
    for X in Ids do
      if IntToStr(E.Id) = X then
        Exit(True);
  end;

begin
  Ids := TopIds(FSysEv, 25);
  { pad to 30 IDs with ones that do not occur }
  I := Length(Ids);
  SetLength(Ids, 30);
  while I < 30 do
  begin
    Ids[I] := IntToStr(64000 + I);
    Inc(I);
  end;
  F := NewFilter([FSys]);
  try
    for I := 0 to High(Ids) do
      F.AddTerm(MakeTerm(sfEventId, saInclude, Ids[I]));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '4'));
    C := CompileFilter(F, nil);
    AssertTrue('split into several Selects', C.SelectCount > 1);
    CheckDump(F, FSysEv, @P, '30 ids + 3 levels (34 sub-expressions)', 1);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.EmptyResult;
var
  F: TSiftFilter;
  L: TStringList;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := E.Id = 65001;
  end;

begin
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfEventId, saInclude, '65001'));
    CheckDump(F, FSysEv, @P, 'empty');
    { Get-WinEvent says "No events were found" for the same filter }
    L := PsKeys('try { Get-WinEvent -FilterHashtable @{ Path = ' + PsPath(FSys) +
      '; Id = 65001 } -ErrorAction Stop | Out-Null; ''found'' | Set-Content $SiftOut } catch { $_.FullyQualifiedErrorId | Set-Content $SiftOut }');
    try
      AssertTrue('Get-WinEvent NoMatchingEventsFound: ' + L.Text,
        Pos('NoMatchingEventsFound', L.Text) > 0);
    finally
      L.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.UserComputerTaskKeywords;
var
  F: TSiftFilter;
  Machine, Kw: string;
  Task: Integer;
  KwV: QWord;
  I: Integer;

  function PUser(const E: TOracleEvent): Boolean;
  begin
    Result := SameText(E.UserId, 'S-1-5-18');
  end;

  function PComp(const E: TOracleEvent): Boolean;
  begin
    Result := not SameText(E.Machine, Machine);
  end;

  function PComp2(const E: TOracleEvent): Boolean;
  begin
    Result := SameText(E.Machine, Machine);
  end;

  function PTask(const E: TOracleEvent): Boolean;
  begin
    Result := E.Task = Task;
  end;

  function PKw(const E: TOracleEvent): Boolean;
  begin
    Result := (E.Keywords and KwV) <> 0;
  end;

begin
  Machine := FSysEv[0].Machine;
  Task := -1;
  for I := 0 to High(FSysEv) do
    if FSysEv[I].Task <> 0 then
    begin
      Task := FSysEv[I].Task;
      Break;
    end;
  KwV := QWord($0000000000000080); { classic "Classic" bit used by many providers }
  for I := 0 to High(FSysEv) do
    if (FSysEv[I].Keywords and $0000FFFFFFFFFFFF) <> 0 then
    begin
      KwV := FSysEv[I].Keywords and $0000FFFFFFFFFFFF;
      KwV := KwV and (not (KwV - 1)); { lowest set bit }
      Break;
    end;
  Kw := '0x' + IntToHex(KwV, 16);
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-18'));
    CheckDump(F, FSysEv, @PUser, 'user SYSTEM');
    F.ClearTerms;
    F.AddTerm(MakeTerm(sfComputer, saInclude, Machine));
    CheckDump(F, FSysEv, @PComp2, 'computer include', 1);
    F.ClearTerms;
    F.AddTerm(MakeTerm(sfComputer, saExclude, Machine));
    CheckDump(F, FSysEv, @PComp, 'computer exclude');
    if Task >= 0 then
    begin
      F.ClearTerms;
      F.AddTerm(MakeTerm(sfTask, saInclude, IntToStr(Task)));
      CheckDump(F, FSysEv, @PTask, 'task ' + IntToStr(Task), 1);
    end;
    F.ClearTerms;
    F.AddTerm(MakeTerm(sfKeywords, saInclude, Kw));
    CheckDump(F, FSysEv, @PKw, 'keywords ' + Kw);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.LastNMatchesNewestFirst;
var
  F: TSiftFilter;
  R: TSiftResult;
  N, I, J: Integer;
  Sorted: TOracleEvents;
  Tmp: TOracleEvent;
begin
  { single source: last N = the N highest record ids, newest record first
    (what Get-WinEvent -MaxEvents and Event Viewer show) }
  Sorted := Copy(FSysEv);
  for I := 1 to High(Sorted) do
  begin
    Tmp := Sorted[I];
    J := I - 1;
    while (J >= 0) and (Sorted[J].RecordId < Tmp.RecordId) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := Tmp;
  end;
  F := NewFilter([FSys]);
  try
    for N in [5, 10, 20, 40] do
    begin
      F.SetLastN(N);
      R := RunSift(F);
      try
        AssertEquals('last ' + IntToStr(N), N, R.Count);
        for I := 0 to N - 1 do
          AssertEquals(Format('last %d row %d', [N, I]),
            Sorted[I].RecordId, R.Rows[I]^.RecordId);
      finally
        R.Free;
      end;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.TimeWindowsMatch;
var
  F: TSiftFilter;
  Anchor, StartFT: Int64;
  M: Integer;
  L: TStringList;
  R: TSiftResult;
  A: TStringList;
  D: string;

  function P(const E: TOracleEvent): Boolean;
  begin
    Result := E.TimeFT >= StartFT;
  end;

begin
  { Windows anchored to the newest fixture event (the fixture is static, so
    "last N minutes" is expressed as an absolute UTC window). }
  Anchor := NewestFT(FSysEv);
  F := NewFilter([FSys]);
  try
    for M in [1, 5, 15, 30, 60, 240] do
    begin
      StartFT := Anchor - Int64(M) * FT_PER_MIN;
      { ms-aligned start so the XPath literal is exact }
      StartFT := (StartFT div 10000) * 10000;
      F.SetAbsoluteWindow(FileTimeToUtc(StartFT), 0);
      CheckDump(F, FSysEv, @P, 'window ' + IntToStr(M) + ' min', 1);
      { and Get-WinEvent -FilterHashtable StartTime on the same file }
      L := PsKeys('$s = [DateTime]::FromFileTime(' + IntToStr(StartFT) + ')' + LineEnding +
        '@(Get-WinEvent -FilterHashtable @{ Path = ' + PsPath(FSys) + '; StartTime = $s } -ErrorAction SilentlyContinue) | ForEach-Object { $_.LogName + ''|'' + $_.RecordId } | Set-Content $SiftOut');
      R := RunSift(F);
      A := ResultKeys(R);
      try
        OkK := SameKeySets(A, L, D);
        AssertTrue('window ' + IntToStr(M) + ' vs FilterHashtable StartTime: ' + D, OkK);
      finally
        A.Free;
        R.Free;
        L.Free;
      end;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.TextIncludeExclude;
var
  F: TSiftFilter;
  R: TSiftResult;
  Word1: string;

  function PInc(const E: TOracleEvent): Boolean;
  begin
    Result := Pos(LowerCase(Word1), LowerCase(E.Message)) > 0;
  end;

  function PExc(const E: TOracleEvent): Boolean;
  begin
    Result := Pos(LowerCase(Word1), LowerCase(E.Message)) = 0;
  end;

begin
  Word1 := 'service';
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfMessage, saInclude, 'SERVICE'));
    CheckDump(F, FSysEv, @PInc, 'text include', 1);
    F.ClearTerms;
    F.AddTerm(MakeTerm(sfMessage, saExclude, Word1));
    CheckDump(F, FSysEv, @PExc, 'text exclude', 1);
    { the cap is honoured and reported }
    F.TextScanCap := 50;
    R := RunSift(F);
    try
      AssertTrue('cap hit flagged', R.Stats.CapHit);
      AssertEquals(Int64(50), R.Stats.TextScanned);
      AssertTrue(R.Stats.Path = rpServiceAndClientText);
    finally
      R.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.HashtableOracleIncludeOnly;
var
  F: TSiftFilter;
  Ids: TStringArray;
  L, A: TStringList;
  R: TSiftResult;
  C: TSiftCompiled;
  D: string;
begin
  Ids := TopIds(FSysEv, 2);
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfEventId, saInclude, Ids[0]));
    F.AddTerm(MakeTerm(sfEventId, saInclude, Ids[1]));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '4'));
    C := CompileFilter(F, nil);
    AssertTrue('one-liner exists', C.FilterHashtable <> '');
    { run Sift's own one-liner unchanged }
    L := PsKeys('@(' + C.FilterHashtable + ' -ErrorAction SilentlyContinue) | ForEach-Object { $_.LogName + ''|'' + $_.RecordId } | Set-Content $SiftOut');
    R := RunSift(F);
    A := ResultKeys(R);
    try
      OkK := SameKeySets(A, L, D);
        AssertTrue('FilterHashtable one-liner: ' + D, OkK);
      AssertTrue(A.Count > 0);
    finally
      A.Free;
      R.Free;
      L.Free;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.ExportedPowerShellReturnsSameEvents;

  procedure Check(F: TSiftFilter; const What: string; Ordered: Boolean);
  var
    Script, D: string;
    Lines: TStringList;
    L, A: TStringList;
    R: TSiftResult;
    I: Integer;
  begin
    Lines := TStringList.Create;
    try
      Lines.Text := CompilePowerShell(F, nil);
      { run as exported; only the final display line is swapped for output }
      AssertTrue(Pos('$siftEvents | Format-Table', Lines[Lines.Count - 1]) = 1);
      Lines.Delete(Lines.Count - 1);
      Lines.Add('$siftEvents | ForEach-Object { $_.LogName + ''|'' + $_.RecordId } | Set-Content $SiftOut');
      Script := Lines.Text;
    finally
      Lines.Free;
    end;
    L := PsKeys(Script);
    R := RunSift(F);
    A := ResultKeys(R);
    try
      OkK := SameKeySets(A, L, D);
        AssertTrue(What + ': ' + D, OkK);
      if Ordered then
        for I := 0 to A.Count - 1 do
          AssertEquals(What + ' order ' + IntToStr(I), A[I], L[I]);
    finally
      A.Free;
      L.Free;
      R.Free;
    end;
  end;

var
  F: TSiftFilter;
  Ids: TStringArray;
begin
  Ids := TopIds(FSysEv, 2);
  F := NewFilter([FSys]);
  try
    F.AddTerm(MakeTerm(sfLevel, saInclude, '4'));
    F.AddTerm(MakeTerm(sfEventId, saExclude, Ids[0]));
    Check(F, 'export: include level + exclude id', False);
    F.SetLastN(20);
    Check(F, 'export: last 20 with exclude', True);
  finally
    F.Free;
  end;
  F := NewFilter([FSys, FApp]);
  try
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    F.AddTerm(MakeTerm(sfEventId, saExclude, Ids[1]));
    Check(F, 'export: two files', False);
    F.ClearTerms;
    F.AddTerm(MakeTerm(sfMessage, saInclude, 'service'));
    F.SetLastN(10);
    Check(F, 'export: text + last 10', True);
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.SecurityDeniedMatchesGetWinEvent;
var
  F: TSiftFilter;
  R: TSiftResult;
  L: TStringList;
begin
  if Elevated then
  begin
    Ignore('elevated session');
    Exit;
  end;
  L := PsKeys('try { Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop | Out-Null; ''ok'' | Set-Content $SiftOut } catch { $_.FullyQualifiedErrorId | Set-Content $SiftOut }');
  F := TSiftFilter.Create;
  try
    AssertTrue('Get-WinEvent also denied: ' + L.Text, Pos('UnauthorizedAccess', L.Text) > 0);
    F.Channels.Add('Security');
    R := RunSift(F);
    try
      AssertEquals(0, R.Count);
      AssertTrue(R.Errors[0].NeedsElevation);
    finally
      R.Free;
    end;
  finally
    F.Free;
    L.Free;
  end;
end;

procedure TEquivalenceTests.LiveLastNMatchesGetWinEvent;
var
  F: TSiftFilter;
  R: TSiftResult;
  L, A: TStringList;
  N, I: Integer;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('Application');
    for N in [5, 10, 20, 40] do
    begin
      F.SetLastN(N);
      L := PsKeys('Get-WinEvent -LogName Application -MaxEvents ' + IntToStr(N) +
        ' | ForEach-Object { $_.LogName + ''|'' + $_.RecordId } | Set-Content $SiftOut');
      R := RunSift(F);
      A := ResultKeys(R);
      try
        { a new event can land between the two reads; allow a 1-row shift }
        if (A.Count = L.Count) and (A.Count > 0) and (A[0] <> L[0]) then
        begin
          if A.IndexOf(L[0]) = 1 then A.Delete(0) else L.Delete(0);
        end;
        for I := 0 to Min(A.Count, L.Count) - 1 do
          AssertEquals(Format('live last %d row %d', [N, I]), L[I], A[I]);
        AssertTrue(Abs(A.Count - L.Count) <= 1);
      finally
        A.Free;
        L.Free;
        R.Free;
      end;
    end;
  finally
    F.Free;
  end;
end;

procedure TEquivalenceTests.LiveWindowsMatchGetWinEvent;
var
  F: TSiftFilter;
  R: TSiftResult;
  L, A: TStringList;
  M, I: Integer;
  NowFT: Int64;
  D: string;
  Edge: TStringList;
begin
  { Sift's relative window (timediff) vs Get-WinEvent StartTime on the live
    System log. Events within 3 s of either edge are excluded from the
    comparison because the two reads happen at slightly different times. }
  F := TSiftFilter.Create;
  Edge := TStringList.Create;
  try
    F.Channels.Add('System');
    for M in [1, 5, 15, 30, 60, 240] do
    begin
      F.SetRelativeWindow(Int64(M) * 60000);
      NowFT := UtcNowFileTime;
      R := RunSift(F);
      L := PsKeys('$now = [DateTime]::FromFileTime(' + IntToStr(NowFT) + ')' + LineEnding +
        '@(Get-WinEvent -FilterHashtable @{ LogName = ''System''; StartTime = $now.AddMinutes(-' + IntToStr(M) + ') } -ErrorAction SilentlyContinue) | ForEach-Object { $_.LogName + ''|'' + $_.RecordId + ''|'' + $_.TimeCreated.ToFileTimeUtc() } | Set-Content $SiftOut');
      A := TStringList.Create;
      try
        Edge.Clear;
        for I := 0 to R.Count - 1 do
          if (Abs(R.Rows[I]^.TimeCreated - (NowFT - Int64(M) * FT_PER_MIN)) < 30000000) or
             (R.Rows[I]^.TimeCreated > NowFT - 30000000) then
            Edge.Add(R.Key(I))
          else
            A.Add(R.Key(I));
        for I := L.Count - 1 downto 0 do
        begin
          D := L[I];
          L[I] := Copy(D, 1, LastDelimiter('|', D) - 1);
          if (Edge.IndexOf(L[I]) >= 0) or
             (Abs(StrToInt64(Copy(D, LastDelimiter('|', D) + 1, 30)) - (NowFT - Int64(M) * FT_PER_MIN)) < 30000000) or
             (StrToInt64(Copy(D, LastDelimiter('|', D) + 1, 30)) > NowFT - 30000000) then
            L.Delete(I);
        end;
        OkK := SameKeySets(A, L, D);
        AssertTrue('live ' + IntToStr(M) + ' min: ' + D, OkK);
      finally
        A.Free;
        L.Free;
        R.Free;
      end;
    end;
  finally
    Edge.Free;
    F.Free;
  end;
end;

procedure TEquivalenceTests.ProbeSeedFixture;
{ Optional extra fixture: any System .evtx export named by the
  SIFT_PROBE_EVTX environment variable (the dev machine uses the 324-event
  export kept from the WPF probe). Skipped when the variable is unset. }
var
  Path: string;
  Ev: TOracleEvents;
  F: TSiftFilter;

  function PAll(const E: TOracleEvent): Boolean;
  begin
    Result := True;
  end;

  function PErrWarn(const E: TOracleEvent): Boolean;
  begin
    Result := E.Level in [2, 3];
  end;

begin
  Path := GetEnvironmentVariable('SIFT_PROBE_EVTX');
  if Path = '' then
    Ignore('SIFT_PROBE_EVTX not set (optional extra .evtx fixture)');
  if not FileExists(Path) then
    Ignore('SIFT_PROBE_EVTX file not found: ' + Path);
  Ev := LoadOracle(Path);
  AssertTrue('probe seed has events', Length(Ev) > 0);
  F := NewFilter([Path]);
  try
    CheckDump(F, Ev, @PAll, 'probe seed: all events', 1);
    F.AddTerm(MakeTerm(sfLevel, saInclude, 'Error'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, 'Warning'));
    CheckDump(F, Ev, @PErrWarn, 'probe seed: levels 2,3');
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TEquivalenceTests);
end.
