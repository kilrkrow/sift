unit Test.Util;

{ Helpers shared by the SiftCore tests: running Windows PowerShell 5.1 as an
  independent oracle, fixture discovery, and key-set comparison. }

{$mode objfpc}{$H+}
{$modeswitch nestedprocvars}

interface

uses
  Windows, SysUtils, Classes, Process, Sift.Filter, Sift.Query;

type
  TOracleEvent = record
    LogName: string;
    RecordId: Int64;
    TimeFT: Int64;
    Level: Integer;
    Id: Integer;
    Provider: string;
    Task: Integer;
    Keywords: QWord;
    UserId: string;
    Machine: string;
    Message: string;
  end;
  TOracleEvents = array of TOracleEvent;
  TOraclePred = function(const E: TOracleEvent): Boolean is nested;

function RepoDir: string;
function FixtureDir: string;
function ScratchDir: string;
function FixturePath(const Name: string): string;
procedure EnsureFixtures;
{ Runs a PowerShell script (text) with powershell.exe 5.1; returns stdout
  lines written to the $SiftOut file the script receives as $args[0]. }
function RunPs(const Script: string; Lines: TStrings): Integer;
function LoadOracle(const EvtxFile: string): TOracleEvents;
function OracleKeys(const Ev: TOracleEvents; Pred: TOraclePred): TStringList;
function ResultKeys(R: TSiftResult): TStringList;
function SameKeySets(A, B: TStrings; out Diff: string): Boolean;
function RunSift(F: TSiftFilter): TSiftResult;
function Elevated: Boolean;
function PsPath(const S: string): string;

implementation

uses
  Sift.Channels, Sift.EvtApi;

var
  GExec: TSiftExecutor = nil;
  GOracleCache: TStringList = nil;

function Elevated: Boolean;
begin
  Result := IsProcessElevated;
end;

function RepoDir: string;
var
  D: string;
begin
  D := ExtractFileDir(ParamStr(0));
  { exe lives in <repo>\tests\bin\<target> or similar; walk up to README.md }
  while (D <> '') and not FileExists(IncludeTrailingPathDelimiter(D) + 'README.md') do
  begin
    if ExtractFileDir(D) = D then
    begin
      D := '';
      Break;
    end;
    D := ExtractFileDir(D);
  end;
  if D = '' then
    D := GetCurrentDir;
  Result := IncludeTrailingPathDelimiter(D);
end;

function FixtureDir: string;
begin
  Result := RepoDir + 'tests\fixtures\';
end;

function ScratchDir: string;
begin
  Result := GetEnvironmentVariable('SIFT_TEST_TEMP');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'sift-tests';
  ForceDirectories(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

function FixturePath(const Name: string): string;
begin
  Result := FixtureDir + Name;
end;

function PsPath(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function RunPs(const Script: string; Lines: TStrings): Integer;
var
  P: TProcess;
  ScriptFile, OutFile: string;
  L: TStringList;
  N: Integer;
begin
  N := Random(MaxInt);
  ScriptFile := ScratchDir + 'ps-' + IntToStr(GetCurrentProcessId) + '-' + IntToStr(N) + '.ps1';
  OutFile := ChangeFileExt(ScriptFile, '.out');
  L := TStringList.Create;
  try
    L.Text := '$SiftOut = $args[0]' + LineEnding +
      '$ErrorActionPreference = ''Continue''' + LineEnding + Script;
    L.SaveToFile(ScriptFile);
  finally
    L.Free;
  end;
  P := TProcess.Create(nil);
  try
    P.Executable := 'powershell.exe';
    P.Parameters.Add('-NoProfile');
    P.Parameters.Add('-NonInteractive');
    P.Parameters.Add('-ExecutionPolicy');
    P.Parameters.Add('Bypass');
    P.Parameters.Add('-File');
    P.Parameters.Add(ScriptFile);
    P.Parameters.Add(OutFile);
    P.ShowWindow := swoHide;
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
  Lines.Clear;
  if FileExists(OutFile) then
  begin
    Lines.LoadFromFile(OutFile);
    DeleteFile(OutFile);
  end;
  if GetEnvironmentVariable('SIFT_KEEP_PS') = '' then
    DeleteFile(ScriptFile);
end;

procedure EnsureFixtures;
var
  L: TStringList;
  Code: Integer;
begin
  if FileExists(FixturePath('system.evtx')) and FileExists(FixturePath('application.evtx')) then
    Exit;
  L := TStringList.Create;
  try
    Code := RunPs('& ' + PsPath(FixtureDir + 'Make-Fixtures.ps1') + ' | Out-Null' + LineEnding +
      '''done'' | Set-Content -Path $SiftOut', L);
    if not FileExists(FixturePath('system.evtx')) then
      raise Exception.CreateFmt('Make-Fixtures.ps1 failed (exit %d)', [Code]);
  finally
    L.Free;
  end;
end;

type
  TOracleHolder = class
    Events: TOracleEvents;
  end;

function SplitTabs(const S: string): TStringArray;
var
  I, Start, N: Integer;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = #9) then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

function LoadOracle(const EvtxFile: string): TOracleEvents;
var
  L: TStringList;
  Parts: TStringArray;
  I, Ix: Integer;
  S: string;
  E: TOracleEvent;
  Script: string;
  H: TOracleHolder;
begin
  if GOracleCache = nil then
  begin
    GOracleCache := TStringList.Create;
    GOracleCache.OwnsObjects := True;
  end;
  I := GOracleCache.IndexOf(EvtxFile);
  if I >= 0 then
    Exit(TOracleHolder(GOracleCache.Objects[I]).Events);
  Result := nil;
  L := TStringList.Create;
  try
    Script :=
      '$ev = @(Get-WinEvent -Path ' + PsPath(EvtxFile) + ' -ErrorAction SilentlyContinue)' + LineEnding +
      '$sb = New-Object System.Text.StringBuilder' + LineEnding +
      'foreach ($e in $ev) { $m = $e.Message; if ($m -eq $null) { $m = '''' }; $m = $m -replace "[\r\n\t]", '' ''; $u = ''''; if ($e.UserId) { $u = $e.UserId.Value }; $k = ''{0:X16}'' -f $e.Keywords; [void]$sb.AppendLine(($e.LogName, $e.RecordId, $e.TimeCreated.ToFileTimeUtc(), $e.Level, $e.Id, $e.ProviderName, $e.Task, $k, $u, $e.MachineName, $m) -join "`t") }' + LineEnding +
      '[System.IO.File]::WriteAllText($SiftOut, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))';
    RunPs(Script, L);
    SetLength(Result, L.Count);
    Ix := 0;
    for I := 0 to L.Count - 1 do
    begin
      S := L[I];
      if S = '' then
        Continue;
      Parts := SplitTabs(S);
      if Length(Parts) < 11 then
        Continue;
      E.LogName := Parts[0];
      E.RecordId := StrToInt64(Parts[1]);
      E.TimeFT := StrToInt64(Parts[2]);
      E.Level := StrToIntDef(Parts[3], 0);
      E.Id := StrToIntDef(Parts[4], 0);
      E.Provider := Parts[5];
      E.Task := StrToIntDef(Parts[6], 0);
      E.Keywords := StrToQWord('$' + Parts[7]);
      E.UserId := Parts[8];
      E.Machine := Parts[9];
      E.Message := Parts[10];
      Result[Ix] := E;
      Inc(Ix);
    end;
    SetLength(Result, Ix);
    H := TOracleHolder.Create;
    H.Events := Result;
    GOracleCache.AddObject(EvtxFile, H);
  finally
    L.Free;
  end;
end;

function OracleKeys(const Ev: TOracleEvents; Pred: TOraclePred): TStringList;
var
  E: TOracleEvent;
begin
  Result := TStringList.Create;
  for E in Ev do
    if Pred(E) then
      Result.Add(E.LogName + '|' + IntToStr(E.RecordId));
end;

function ResultKeys(R: TSiftResult): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 0 to R.Count - 1 do
    Result.Add(R.Key(I));
end;

function SameKeySets(A, B: TStrings; out Diff: string): Boolean;
var
  SA, SB: TStringList;
  I, N: Integer;
begin
  SA := TStringList.Create;
  SB := TStringList.Create;
  try
    SA.Assign(A);
    SB.Assign(B);
    SA.Sorted := True;
    SB.Sorted := True;
    Diff := '';
    N := 0;
    for I := 0 to SA.Count - 1 do
      if SB.IndexOf(SA[I]) < 0 then
      begin
        Inc(N);
        if N <= 5 then
          Diff := Diff + ' sift-only:' + SA[I];
      end;
    for I := 0 to SB.Count - 1 do
      if SA.IndexOf(SB[I]) < 0 then
      begin
        Inc(N);
        if N <= 10 then
          Diff := Diff + ' oracle-only:' + SB[I];
      end;
    Result := (N = 0) and (SA.Count = SB.Count);
    Diff := Format('sift=%d oracle=%d diffs=%d%s', [SA.Count, SB.Count, N, Diff]);
  finally
    SA.Free;
    SB.Free;
  end;
end;

function RunSift(F: TSiftFilter): TSiftResult;
begin
  if GExec = nil then
    GExec := TSiftExecutor.Create;
  Result := GExec.Execute(F, nil);
end;

finalization
  GExec.Free;
  GOracleCache.Free;
end.
