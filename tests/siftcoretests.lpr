program siftcoretests;

{ SiftCore test runner (FPCUnit, headless). Prints one line per test and a
  summary that keeps skipped tests (Ignore(...), e.g. a missing optional
  fixture or an elevated session) separate from passes.
  Usage: siftcoretests.exe [substring]   (runs tests whose name contains it)
  Exit code: 0 when nothing failed or errored, 1 otherwise. }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, fpcunit, testregistry, Test.Util, Test.Compiler,
  Test.Filter, Test.Json, Test.EvtApi, Test.Equivalence, Test.ColFit, Test.PubMeta, Test.Toolbar, Test.TzTime;

type
  TSummary = class(TInterfacedObject, ITestListener)
  public
    Passed, Skipped, Failed, Errored: Integer;
    CurFailed, CurSkipped: Boolean;
    CurText: string;
    T0: QWord;
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

procedure TSummary.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
  if AFailure.IsIgnoredTest then
  begin
    CurSkipped := True;
    CurText := AFailure.ExceptionMessage;
  end
  else
  begin
    CurFailed := True;
    CurText := AFailure.ExceptionMessage;
    Inc(Failed);
  end;
end;

procedure TSummary.AddError(ATest: TTest; AError: TTestFailure);
begin
  CurFailed := True;
  CurText := AError.ExceptionClassName + ': ' + AError.ExceptionMessage;
  Inc(Errored);
end;

procedure TSummary.StartTest(ATest: TTest);
begin
  CurFailed := False;
  CurSkipped := False;
  CurText := '';
  T0 := GetTickCount64;
end;

procedure TSummary.EndTest(ATest: TTest);
var
  Tag: string;
begin
  if CurFailed then
    Tag := 'FAIL'
  else if CurSkipped then
  begin
    Tag := 'SKIP';
    Inc(Skipped);
  end
  else
  begin
    Tag := 'PASS';
    Inc(Passed);
  end;
  Write(Format('  %s %6.3fs  %s.%s', [Tag, (GetTickCount64 - T0) / 1000,
    ATest.TestSuiteName, ATest.TestName]));
  if CurText <> '' then
    Write('  -- ', CurText);
  WriteLn;
end;

procedure TSummary.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TSummary.EndTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure Collect(T: TTest; const Sub: string; Suite: TTestSuite);
var
  I: Integer;
begin
  if T is TTestSuite then
  begin
    for I := 0 to TTestSuite(T).ChildTestCount - 1 do
      Collect(TTestSuite(T).Test[I], Sub, Suite);
  end
  else if (Sub = '') or (Pos(LowerCase(Sub), LowerCase(T.TestSuiteName + '.' + T.TestName)) > 0) then
    Suite.AddTest(T);
end;

var
  R: TTestResult;
  S: TSummary;
  L: ITestListener;
  Suite: TTestSuite;
  Arch: string;
begin
  { the viewer runs with UTF-8 strings (LCL sets this through LazUTF8); the
    core is tested the same way so non-ASCII text is compared as UTF-8 }
  DefaultSystemCodePage := CP_UTF8;
  {$IFDEF CPUX86_64} Arch := 'win64'; {$ELSE} Arch := 'win32'; {$ENDIF}
  WriteLn('SiftCore tests (', Arch, ', elevated: ', BoolToStr(Elevated, 'yes', 'no'), ')');
  S := TSummary.Create;
  L := S;
  R := TTestResult.Create;
  Suite := TTestSuite.Create('selected');
  try
    Collect(GetTestRegistry, ParamStr(1), Suite);
    R.AddListener(L);
    Suite.Run(R);
    WriteLn;
    WriteLn(Format('Total: %d   passed: %d   skipped: %d   failed: %d   errors: %d',
      [S.Passed + S.Skipped + S.Failed + S.Errored, S.Passed, S.Skipped, S.Failed, S.Errored]));
    if S.Failed + S.Errored > 0 then
      ExitCode := 1;
  finally
    R.Free;
  end;
end.
