unit Test.ColFit;

{ Piece 8: column auto-fit arithmetic (which rows are measured, the fitted
  width, and DPI scaling of the padding). }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Types, fpcunit, testregistry, Sift.ColFit;

type
  TColFitTests = class(TTestCase)
  published
    procedure WidthIsWidestPlusPadding;
    procedure HeaderWinsWhenRowsAreNarrow;
    procedure WidthClamped;
    procedure SampleIncludesVisibleRowsFirst;
    procedure SampleBoundedAt250kRows;
    procedure SampleSmallResult;
    procedure SampleEmpty;
    procedure PaddingScalesWithDpi;
    procedure FitScalesWithDpi;
    procedure DividerZoneHits;
    procedure HeaderBodyIsNotDivider;
    procedure DividerZoneScalesWithDpi;
  end;

implementation

procedure TColFitTests.WidthIsWidestPlusPadding;
begin
  AssertEquals(214, FitColumnWidth(40, [100, 200, 150], 14, 36, 1600));
end;

procedure TColFitTests.HeaderWinsWhenRowsAreNarrow;
begin
  AssertEquals(74, FitColumnWidth(60, [10, 20], 14, 36, 1600));
  AssertEquals(74, FitColumnWidth(60, [], 14, 36, 1600));
end;

procedure TColFitTests.WidthClamped;
begin
  AssertEquals(36, FitColumnWidth(5, [3], 14, 36, 1600));
  AssertEquals(1600, FitColumnWidth(5, [99999], 14, 36, 1600));
end;

procedure TColFitTests.SampleIncludesVisibleRowsFirst;
var
  R: TIntegerDynArray;
  I: Integer;
begin
  R := FitSampleRows(500, 30, 10000, 200);
  for I := 0 to 29 do
    AssertEquals('visible row ' + IntToStr(I), 500 + I, R[I]);
  for I := 30 to High(R) do
    AssertTrue('sample outside visible block', (R[I] < 500) or (R[I] > 529));
end;

procedure TColFitTests.SampleBoundedAt250kRows;
var
  R: TIntegerDynArray;
  I, J: Integer;
  Seen: TStringList;
begin
  R := FitSampleRows(120000, 35, 250000, FitSampleMax);
  AssertTrue('bounded: ' + IntToStr(Length(R)), Length(R) <= 35 + FitSampleMax);
  AssertTrue('samples beyond the view', Length(R) > 35);
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupError;
    for I := 0 to High(R) do
    begin
      AssertTrue((R[I] >= 0) and (R[I] < 250000));
      Seen.Add(IntToStr(R[I])); { raises on a duplicate }
    end;
    { spread over the whole result, not just the top }
    J := 0;
    for I := 0 to High(R) do
      if R[I] > 200000 then
        Inc(J);
    AssertTrue('reaches the end of the result', J > 0);
  finally
    Seen.Free;
  end;
end;

procedure TColFitTests.SampleSmallResult;
var
  R: TIntegerDynArray;
begin
  R := FitSampleRows(0, 30, 12, 200);
  AssertEquals(12, Length(R));
  R := FitSampleRows(5, 30, 12, 200); { view clipped to the result }
  AssertEquals(12, Length(R));
  AssertEquals(5, R[0]);
end;

procedure TColFitTests.SampleEmpty;
begin
  AssertEquals(0, Length(FitSampleRows(0, 30, 0, 200)));
end;

procedure TColFitTests.PaddingScalesWithDpi;
begin
  AssertEquals(14, ScalePx(FitPad96, 96));
  AssertEquals(18, ScalePx(FitPad96, 120)); { 17.5 rounds up }
  AssertEquals(21, ScalePx(FitPad96, 144));
  AssertEquals(45, ScalePx(FitMin96, 120));
  AssertEquals(54, ScalePx(FitMin96, 144));
end;

procedure TColFitTests.FitScalesWithDpi;
var
  Ppi, W96: Integer;
begin
  { text measured by a DPI-scaled font grows by the same factor, so the
    fitted width tracks the DPI within rounding }
  W96 := FitColumnWidth(50, [180], ScalePx(FitPad96, 96), ScalePx(FitMin96, 96), ScalePx(FitMax96, 96));
  for Ppi in [120, 144] do
    AssertTrue(IntToStr(Ppi), Abs(FitColumnWidth(MulDiv(50, Ppi, 96),
      [MulDiv(180, Ppi, 96)], ScalePx(FitPad96, Ppi), ScalePx(FitMin96, Ppi),
      ScalePx(FitMax96, Ppi)) - MulDiv(W96, Ppi, 96)) <= 1);
end;

const
  { right edges of 9 columns at 96 DPI (the default widths) }
  Rights96: array[0..8] of Integer = (140, 224, 374, 564, 632, 742, 892, 1002, 1642);

procedure TColFitTests.DividerZoneHits;
var
  I, Tol: Integer;
begin
  Tol := ScalePx(DividerTol96, 96);
  for I := 0 to High(Rights96) do
  begin
    AssertEquals('on edge ' + IntToStr(I), I, DividerHit(Rights96[I], 10, 24, Rights96, Tol));
    AssertEquals('left of edge ' + IntToStr(I), I, DividerHit(Rights96[I] - Tol, 10, 24, Rights96, Tol));
    AssertEquals('right of edge ' + IntToStr(I), I, DividerHit(Rights96[I] + Tol, 10, 24, Rights96, Tol));
  end;
  AssertEquals('Message divider', 8, DividerHit(1642, 3, 24, Rights96, Tol));
end;

procedure TColFitTests.HeaderBodyIsNotDivider;
var
  I, Tol, L: Integer;
begin
  Tol := ScalePx(DividerTol96, 96);
  L := 0;
  for I := 0 to High(Rights96) do
  begin
    AssertEquals('body of column ' + IntToStr(I), -1,
      DividerHit((L + Rights96[I]) div 2, 10, 24, Rights96, Tol));
    AssertEquals('just outside the zone ' + IntToStr(I), -1,
      DividerHit(Rights96[I] - Tol - 1, 10, 24, Rights96, Tol));
    L := Rights96[I];
  end;
  AssertEquals('data row, on an edge', -1, DividerHit(140, 24, 24, Rights96, Tol));
  AssertEquals('above the grid', -1, DividerHit(140, -1, 24, Rights96, Tol));
end;

procedure TColFitTests.DividerZoneScalesWithDpi;
var
  R: array[0..8] of Integer;
  I, Ppi, Tol: Integer;
begin
  AssertEquals(4, ScalePx(DividerTol96, 96));
  AssertEquals(5, ScalePx(DividerTol96, 120));
  AssertEquals(6, ScalePx(DividerTol96, 144));
  for Ppi in [120, 144] do
  begin
    for I := 0 to 8 do
      R[I] := MulDiv(Rights96[I], Ppi, 96);
    Tol := ScalePx(DividerTol96, Ppi);
    AssertEquals(IntToStr(Ppi) + ' edge', 3, DividerHit(R[3] + Tol, MulDiv(10, Ppi, 96), MulDiv(24, Ppi, 96), R, Tol));
    AssertEquals(IntToStr(Ppi) + ' body', -1, DividerHit(R[3] - Tol - 1, MulDiv(10, Ppi, 96), MulDiv(24, Ppi, 96), R, Tol));
  end;
end;

initialization
  RegisterTest(TColFitTests);
end.
