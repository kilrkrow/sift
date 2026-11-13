unit Test.Filter;

{ Piece 3 critic (AST part): every right-click path - each grid column x
  Include/Exclude x Add-to/Set-as - produces the expected AST change; chips
  remove terms; quick buttons set last-N / time windows. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Sift.Filter;

type
  TRightClickTests = class(TTestCase)
  private
    F: TSiftFilter;
    procedure Seed;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure EveryColumnEveryActionEveryMode;
    procedure AddIsIdempotent;
    procedure OppositeReplaces;
    procedure SetKeepsScope;
    procedure ChipRemoval;
    procedure QuickButtonsLastN;
    procedure QuickButtonsWindows;
    procedure LevelCaptionsNormalize;
    procedure BadValuesRejected;
    procedure EffectiveChannelsRules;
    procedure CapsClampLastNAndRowCap;
  end;

implementation

const
  { The grid's columns and a sample cell value for each. }
  Cols: array[0..8] of TSiftField = (sfTime, sfLevel, sfChannel, sfProvider,
    sfEventId, sfTask, sfUser, sfComputer, sfMessage);
  Vals: array[0..8] of string = ('2026-10-30T07:15:00.123Z', 'Warning',
    'Application', 'Service Control Manager', '7036', '0', 'S-1-5-18',
    'HOST1', 'disk');
  Norm: array[0..8] of string = ('2026-10-30T07:15:00.123Z', '3',
    'Application', 'Service Control Manager', '7036', '0', 'S-1-5-18',
    'HOST1', 'disk');

procedure TRightClickTests.SetUp;
begin
  F := TSiftFilter.Create;
end;

procedure TRightClickTests.TearDown;
begin
  F.Free;
end;

procedure TRightClickTests.Seed;
begin
  F.Clear;
  F.Channels.Add('System');
  F.Channels.Add('Application');
  F.AddTerm(MakeTerm(sfEventId, saInclude, '1'));
  F.AddTerm(MakeTerm(sfLevel, saExclude, '5'));
  F.SetRelativeWindow(900000);
end;

procedure TRightClickTests.EveryColumnEveryActionEveryMode;
var
  I: Integer;
  A: TSiftAction;
  M: TSiftApplyMode;
  Changed: Boolean;
  T: TSiftTerm;
  Paths: Integer;
begin
  Paths := 0;
  for I := 0 to High(Cols) do
    for A := Low(TSiftAction) to High(TSiftAction) do
      for M := Low(TSiftApplyMode) to High(TSiftApplyMode) do
      begin
        Seed;
        Changed := F.ApplyCell(Cols[I], Vals[I], A, M);
        AssertTrue(Format('changed %s/%d/%d', [SiftFieldNames[Cols[I]], Ord(A), Ord(M)]), Changed);
        T := MakeTerm(Cols[I], A, Norm[I]);
        AssertTrue('term present ' + TermCaption(T), F.IndexOfTerm(T) >= 0);
        if M = amSet then
          AssertEquals('Set leaves exactly one term', 1, F.TermCount)
        else
          AssertEquals('Add keeps the 2 seed terms', 3, F.TermCount);
        { scope is never touched by a cell action }
        AssertEquals(2, F.Channels.Count);
        AssertTrue(F.TimeMode = tmRelative);
        AssertEquals(Int64(900000), F.RelativeMs);
        Inc(Paths);
      end;
  AssertEquals('36 right-click paths', 36, Paths);
end;

procedure TRightClickTests.AddIsIdempotent;
begin
  Seed;
  AssertTrue(F.ApplyCell(sfProvider, 'X', saInclude, amAdd));
  AssertFalse(F.ApplyCell(sfProvider, 'X', saInclude, amAdd));
  AssertFalse(F.ApplyCell(sfProvider, 'x', saInclude, amAdd));
  AssertEquals(3, F.TermCount);
end;

procedure TRightClickTests.OppositeReplaces;
begin
  Seed;
  F.ApplyCell(sfEventId, '1', saExclude, amAdd);
  AssertEquals(2, F.TermCount);
  AssertTrue(F.IndexOfTerm(MakeTerm(sfEventId, saExclude, '1')) >= 0);
  AssertTrue(F.IndexOfTerm(MakeTerm(sfEventId, saInclude, '1')) < 0);
end;

procedure TRightClickTests.SetKeepsScope;
begin
  Seed;
  F.ApplyCell(sfComputer, 'HOST1', saInclude, amSet);
  AssertEquals(1, F.TermCount);
  AssertEquals('System', F.Channels[0]);
  AssertTrue(F.TimeMode = tmRelative);
end;

procedure TRightClickTests.ChipRemoval;
begin
  Seed;
  F.DeleteTerm(0);
  AssertEquals(1, F.TermCount);
  AssertTrue(F.Terms[0].Field = sfLevel);
  F.DeleteTerm(5); { out of range: no-op }
  AssertEquals(1, F.TermCount);
  F.DeleteTerm(0);
  AssertEquals(0, F.TermCount);
end;

procedure TRightClickTests.QuickButtonsLastN;
var
  N: Integer;
begin
  for N in [5, 10, 20, 40] do
  begin
    Seed;
    F.SetLastN(N);
    AssertEquals(N, F.LastN);
    AssertTrue('last-N clears the window', F.TimeMode = tmAll);
    AssertEquals('terms kept', 2, F.TermCount);
  end;
end;

procedure TRightClickTests.QuickButtonsWindows;
var
  M: Integer;
begin
  for M in [1, 5, 15, 30, 60, 240] do
  begin
    Seed;
    F.SetLastN(10);
    F.SetRelativeWindow(Int64(M) * 60000);
    AssertTrue(F.TimeMode = tmRelative);
    AssertEquals(Int64(M) * 60000, F.RelativeMs);
    AssertEquals('window clears last-N', 0, F.LastN);
  end;
end;

procedure TRightClickTests.LevelCaptionsNormalize;
begin
  F.AddTerm(MakeTerm(sfLevel, saInclude, 'Critical'));
  F.AddTerm(MakeTerm(sfLevel, saInclude, 'Error'));
  F.AddTerm(MakeTerm(sfLevel, saInclude, 'Information'));
  F.AddTerm(MakeTerm(sfLevel, saInclude, '0'));  { same as Information }
  F.AddTerm(MakeTerm(sfLevel, saInclude, 'Verbose'));
  AssertEquals(4, F.TermCount);
  AssertEquals('1', F.Terms[0].Value);
  AssertEquals('2', F.Terms[1].Value);
  AssertEquals('4', F.Terms[2].Value);
  AssertEquals('5', F.Terms[3].Value);
end;

procedure TRightClickTests.BadValuesRejected;

  procedure Expect(Fld: TSiftField; const V: string);
  var
    Raised: Boolean;
  begin
    Raised := False;
    try
      F.AddTerm(MakeTerm(Fld, saInclude, V));
    except
      on EConvertError do
        Raised := True;
    end;
    AssertTrue('rejects ' + V, Raised);
  end;

begin
  Expect(sfEventId, 'abc');
  Expect(sfEventId, '70000');
  Expect(sfTime, 'yesterday');
  Expect(sfUser, 'SYSTEM');
  Expect(sfUser, 'S-x');
  Expect(sfUser, 'S-1-5-18''');
  Expect(sfUser, 'S-junk');
  Expect(sfProvider, '  ');
  AssertEquals(0, F.TermCount);
  F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-18'));
  F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-21-1-2-3-1001'));
  AssertEquals(2, F.TermCount);
end;

procedure TRightClickTests.EffectiveChannelsRules;
var
  R: TStringArray;
begin
  F.Channels.Add('System');
  F.Channels.Add('Application');
  R := F.EffectiveChannels(nil);
  AssertEquals(2, Length(R));
  F.ApplyCell(sfChannel, 'Application', saExclude, amAdd);
  R := F.EffectiveChannels(nil);
  AssertEquals(1, Length(R));
  AssertEquals('System', R[0]);
  F.ApplyCell(sfChannel, 'Setup', saInclude, amSet);
  R := F.EffectiveChannels(nil);
  AssertEquals(1, Length(R));
  AssertEquals('Setup', R[0]);
end;


procedure TRightClickTests.CapsClampLastNAndRowCap;
begin
  F.SetLastN(40);
  AssertEquals(40, F.LastN);
  F.SetLastN(0);
  AssertEquals(0, F.LastN);
  F.SetLastN(2147483647);
  AssertEquals(MaxLastN, F.LastN);
  F.SetMaxCount(2147483647);
  AssertEquals(MaxLastN, F.LastN);
  F.SetLastN(40);
  F.ApplyRowCap(MaxRowCap);
  AssertEquals('small lastN is kept', 40, F.LastN);
  F.SetLastN(0);
  F.ApplyRowCap(MaxRowCap);
  AssertEquals('zero lastN becomes the row cap', MaxRowCap, F.LastN);
  F.SetMaxCount(2147483647);
  F.ApplyRowCap(1000);
  AssertEquals('row cap is the hard ceiling', 1000, F.LastN);
  F.TextScanCap := 2147483647;
  AssertEquals(MaxTextScanCap, F.TextScanCap);
  F.TextScanCap := DefaultTextScanCap;
  AssertEquals(DefaultTextScanCap, F.TextScanCap);
  AssertEquals(MaxRowCap, ClampRowCap(2147483647));
  AssertEquals(MaxRowCap, ClampRowCap(0));
  AssertEquals(MaxRowCap, ClampRowCap(-1));
  AssertEquals(5000, ClampRowCap(5000));
end;

initialization
  RegisterTest(TRightClickTests);
end.
