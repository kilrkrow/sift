unit Sift.ColFit;

{ Column auto-fit arithmetic, kept free of LCL so it can be unit-tested.
  The viewer measures the header and a bounded sample of rows with its own
  canvas (whose font already carries the monitor DPI) and asks this unit
  which rows to measure and what width that gives. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Types;

const
  { Rows measured outside the visible block, spread evenly over the loaded
    result. Keeps a fit O(visible + FitSampleMax) at any row count. }
  FitSampleMax = 200;
  { Horizontal padding at 96 DPI: 4 px each side for the cell text plus a
    little air, the same value for header and cells. }
  FitPad96 = 14;
  FitMin96 = 36;
  FitMax96 = 1600;
  { Half-width of the column divider (resizer) hit zone at 96 DPI: a
    double-click within this many pixels of a header's right edge is a
    divider double-click. }
  DividerTol96 = 4;

{ Px96 scaled to Ppi with rounding (same as LCL's MulDiv-based Scale96ToForm). }
function ScalePx(Px96, Ppi: Integer): Integer;

{ 0-based data-row indexes to measure: every visible row (TopIndex ..
  TopIndex + VisibleCount - 1, clipped to RowCount) followed by up to MaxSample
  evenly spaced rows from the whole loaded result, no duplicates. }
function FitSampleRows(TopIndex, VisibleCount, RowCount, MaxSample: Integer): TIntegerDynArray;

{ Which column's divider (right edge in the header row) is at X, Y: the
  column index, or -1 for the header body, a data row or no column.
  Rights[i] is column i's right edge in client pixels; HeaderH is the header
  row height; Tol the half-width of the zone in device pixels. When two
  edges are in range the nearer one wins (ties go to the left column, the
  one being resized, as in Excel). }
function DividerHit(X, Y, HeaderH: Integer; const Rights: array of Integer;
  Tol: Integer): Integer;

{ The fitted width: widest of the header and the cell text widths, plus
  padding, clamped to [MinPx, MaxPx]. All values are device pixels. }
function FitColumnWidth(HeaderW: Integer; const CellWs: array of Integer;
  PadPx, MinPx, MaxPx: Integer): Integer;

implementation

function ScalePx(Px96, Ppi: Integer): Integer;
begin
  if Ppi <= 0 then
    Ppi := 96;
  Result := (Px96 * Ppi + 48) div 96;
end;

function FitSampleRows(TopIndex, VisibleCount, RowCount, MaxSample: Integer): TIntegerDynArray;
var
  N, I, K, Last, Step: Integer;

  procedure Add(R: Integer);
  begin
    if (R < 0) or (R >= RowCount) then
      Exit;
    if (R >= TopIndex) and (R <= Last) then
      Exit; { already in the visible block }
    Result[N] := R;
    Inc(N);
  end;

begin
  Result := nil;
  if RowCount <= 0 then
    Exit;
  if TopIndex < 0 then
    TopIndex := 0;
  if TopIndex >= RowCount then
    TopIndex := RowCount - 1;
  if VisibleCount < 1 then
    VisibleCount := 1;
  Last := TopIndex + VisibleCount - 1;
  if Last >= RowCount then
    Last := RowCount - 1;
  if MaxSample < 0 then
    MaxSample := 0;
  SetLength(Result, (Last - TopIndex + 1) + MaxSample);
  N := 0;
  for I := TopIndex to Last do
  begin
    Result[N] := I;
    Inc(N);
  end;
  if MaxSample > 0 then
  begin
    if RowCount <= MaxSample then
      for I := 0 to RowCount - 1 do
        Add(I)
    else
    begin
      { evenly spaced; Step >= 1, so no index repeats }
      Step := RowCount div MaxSample;
      K := 0;
      for I := 0 to MaxSample - 1 do
      begin
        Add(K);
        Inc(K, Step);
      end;
    end;
  end;
  SetLength(Result, N);
end;

function DividerHit(X, Y, HeaderH: Integer; const Rights: array of Integer;
  Tol: Integer): Integer;
var
  I, D, Best: Integer;
begin
  Result := -1;
  if (Y < 0) or (Y >= HeaderH) then
    Exit;
  Best := MaxInt;
  for I := 0 to High(Rights) do
  begin
    D := Abs(X - Rights[I]);
    if (D <= Tol) and (D < Best) then
    begin
      Best := D;
      Result := I;
    end;
  end;
end;

function FitColumnWidth(HeaderW: Integer; const CellWs: array of Integer;
  PadPx, MinPx, MaxPx: Integer): Integer;
var
  W: Integer;
begin
  Result := HeaderW;
  for W in CellWs do
    if W > Result then
      Result := W;
  Result := Result + PadPx;
  if Result < MinPx then
    Result := MinPx;
  if (MaxPx > 0) and (Result > MaxPx) then
    Result := MaxPx;
end;

end.
