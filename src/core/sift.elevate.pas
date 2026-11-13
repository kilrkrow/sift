unit Sift.Elevate;

{ UAC restart: write the current filter to a new exclusive temp file with a
  random name, pass the path and a SHA-256 of the bytes on the command line,
  and have the elevated process verify the hash and delete the file. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Sift.Filter;

function BytesSha256Hex(const Data: RawByteString): string;
function FileSha256Hex(const FileName: string): string;
{ New file in the temp directory. Path is random, created with CREATE_NEW.
  Sha256Hex is lowercase hex of the file bytes. }
function WriteElevationFilter(F: TSiftFilter; out Path, Sha256Hex: string;
  out Err: string): Boolean;
{ Verify ExpectedSha256, load into F, always delete Path. Returns True only
  when the hash matched and the file loaded. }
function ConsumeElevationFilter(const Path, ExpectedSha256: string;
  F: TSiftFilter; out Err: string): Boolean;

implementation

uses
  Windows, Classes, Sift.FilterJson;

function Rotr32(X: LongWord; N: Integer): LongWord; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

function BytesSha256Hex(const Data: RawByteString): string;
const
  KK: array[0..63] of LongWord = (
    $428A2F98, $71374491, $B5C0FBCF, $E9B5DBA5,
    $3956C25B, $59F111F1, $923F82A4, $AB1C5ED5,
    $D807AA98, $12835B01, $243185BE, $550C7DC3,
    $72BE5D74, $80DEB1FE, $9BDC06A7, $C19BF174,
    $E49B69C1, $EFBE4786, $0FC19DC6, $240CA1CC,
    $2DE92C6F, $4A7484AA, $5CB0A9DC, $76F988DA,
    $983E5152, $A831C66D, $B00327C8, $BF597FC7,
    $C6E00BF3, $D5A79147, $06CA6351, $14292967,
    $27B70A85, $2E1B2138, $4D2C6DFC, $53380D13,
    $650A7354, $766A0ABB, $81C2C92E, $92722C85,
    $A2BFE8A1, $A81A664B, $C24B8B70, $C76C51A3,
    $D192E819, $D6990624, $F40E3585, $106AA070,
    $19A4C116, $1E376C08, $2748774C, $34B0BCB5,
    $391C0CB3, $4ED8AA4A, $5B9CCA4F, $682E6FF3,
    $748F82EE, $78A5636F, $84C87814, $8CC70208,
    $90BEFFFA, $A4506CEB, $BEF9A3F7, $C67178F2);
var
  St: array[0..7] of LongWord;
  W: array[0..63] of LongWord;
  Msg: RawByteString;
  I, J, Blocks, Off: Integer;
  A, B, C, D, E, Fv, G, Hv, T1, T2, S0, S1, Ch, Maj: LongWord;
  BitLen64: QWord;
  function BE(O: Integer): LongWord;
  begin
    Result := (LongWord(Ord(Msg[O])) shl 24) or
      (LongWord(Ord(Msg[O + 1])) shl 16) or
      (LongWord(Ord(Msg[O + 2])) shl 8) or
      LongWord(Ord(Msg[O + 3]));
  end;
begin
  BitLen64 := QWord(Length(Data)) * 8;
  Msg := Data + RawByteString(#128);
  while (Length(Msg) mod 64) <> 56 do
    Msg := Msg + RawByteString(#0);
  SetLength(Msg, Length(Msg) + 8);
  for I := 0 to 7 do
    Msg[Length(Msg) - 7 + I] := AnsiChar(Byte(BitLen64 shr (56 - 8 * I)));
  St[0] := $6A09E667; St[1] := $BB67AE85; St[2] := $3C6EF372; St[3] := $A54FF53A;
  St[4] := $510E527F; St[5] := $9B05688C; St[6] := $1F83D9AB; St[7] := $5BE0CD19;
  Blocks := Length(Msg) div 64;
  for I := 0 to Blocks - 1 do
  begin
    Off := I * 64 + 1;
    for J := 0 to 15 do
      W[J] := BE(Off + J * 4);
    for J := 16 to 63 do
    begin
      S0 := Rotr32(W[J - 15], 7) xor Rotr32(W[J - 15], 18) xor (W[J - 15] shr 3);
      S1 := Rotr32(W[J - 2], 17) xor Rotr32(W[J - 2], 19) xor (W[J - 2] shr 10);
      W[J] := W[J - 16] + S0 + W[J - 7] + S1;
    end;
    A := St[0]; B := St[1]; C := St[2]; D := St[3];
    E := St[4]; Fv := St[5]; G := St[6]; Hv := St[7];
    for J := 0 to 63 do
    begin
      S1 := Rotr32(E, 6) xor Rotr32(E, 11) xor Rotr32(E, 25);
      Ch := (E and Fv) xor ((not E) and G);
      T1 := Hv + S1 + Ch + KK[J] + W[J];
      S0 := Rotr32(A, 2) xor Rotr32(A, 13) xor Rotr32(A, 22);
      Maj := (A and B) xor (A and C) xor (B and C);
      T2 := S0 + Maj;
      Hv := G;
      G := Fv;
      Fv := E;
      E := D + T1;
      D := C;
      C := B;
      B := A;
      A := T1 + T2;
    end;
    St[0] := St[0] + A; St[1] := St[1] + B; St[2] := St[2] + C; St[3] := St[3] + D;
    St[4] := St[4] + E; St[5] := St[5] + Fv; St[6] := St[6] + G; St[7] := St[7] + Hv;
  end;
  Result := '';
  for I := 0 to 7 do
    Result := Result + LowerCase(IntToHex(St[I], 8));
end;

function FileSha256Hex(const FileName: string): string;
var
  Fs: TFileStream;
  Data: RawByteString;
begin
  Fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Data, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Data[1], Fs.Size);
  finally
    Fs.Free;
  end;
  Result := BytesSha256Hex(Data);
end;

var
  GNameCounter: QWord = 0;

function RandomFilterName: string;
var
  Seed: RawByteString;
  C: Int64;
  procedure AppendU64(V: QWord);
  var
    I: Integer;
  begin
    for I := 0 to 7 do
      Seed := Seed + AnsiChar(Byte(V shr (8 * I)));
  end;
begin
  { Only APIs already on the Win7 import allowlist. QPC + a counter +
    pid/tid/heap make the name unique; CREATE_NEW retries if it is not. }
  Inc(GNameCounter);
  C := 0;
  QueryPerformanceCounter(C);
  Seed := '';
  AppendU64(QWord(C));
  AppendU64(GNameCounter);
  AppendU64(GetTickCount);
  AppendU64(GetCurrentProcessId);
  AppendU64(GetCurrentThreadId);
  AppendU64(QWord(GetHeapStatus.TotalAllocated));
  AppendU64(QWord(PtrUInt(@Seed)));
  AppendU64(QWord(PtrUInt(@GNameCounter)));
  Result := 'sift-' + Copy(BytesSha256Hex(Seed), 1, 32) + SiftFilterFileExt;
end;

function WriteElevationFilter(F: TSiftFilter; out Path, Sha256Hex: string;
  out Err: string): Boolean;
var
  Dir, Body: string;
  W: UnicodeString;
  H: HANDLE;
  Written: DWORD;
  Tries: Integer;
  Bytes: RawByteString;
begin
  Result := False;
  Path := '';
  Sha256Hex := '';
  Err := '';
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False));
  Body := FilterToJson(F);
  Bytes := Body;
  H := INVALID_HANDLE_VALUE;
  for Tries := 1 to 16 do
  begin
    Path := Dir + RandomFilterName;
    W := UnicodeString(Path);
    H := CreateFileW(PWideChar(W), GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL, 0);
    if H <> INVALID_HANDLE_VALUE then
      Break;
    Path := '';
  end;
  if H = INVALID_HANDLE_VALUE then
  begin
    Err := 'Could not create a temporary filter file.';
    Exit;
  end;
  try
    Written := 0;
    if Length(Bytes) > 0 then
    begin
      if (not WriteFile(H, Bytes[1], Length(Bytes), Written, nil)) or
        (Written <> DWORD(Length(Bytes))) then
        Err := 'Could not write the temporary filter file.';
    end;
  finally
    CloseHandle(H);
  end;
  if Err <> '' then
  begin
    if Path <> '' then
      SysUtils.DeleteFile(Path);
    Path := '';
    Exit;
  end;
  try
    Sha256Hex := FileSha256Hex(Path);
  except
    on E: Exception do
    begin
      Err := E.Message;
      SysUtils.DeleteFile(Path);
      Path := '';
      Exit;
    end;
  end;
  Result := True;
end;

function ConsumeElevationFilter(const Path, ExpectedSha256: string;
  F: TSiftFilter; out Err: string): Boolean;
var
  Actual: string;
begin
  Result := False;
  Err := '';
  try
    if (Path = '') or not FileExists(Path) then
    begin
      Err := 'Temporary filter file is missing.';
      Exit;
    end;
    try
      Actual := FileSha256Hex(Path);
    except
      on E: Exception do
      begin
        Err := E.Message;
        Exit;
      end;
    end;
    if not SameText(Actual, ExpectedSha256) then
    begin
      Err := 'Temporary filter file hash did not match.';
      Exit;
    end;
    try
      LoadFilterFile(Path, F);
      Result := True;
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    if (Path <> '') and FileExists(Path) then
      SysUtils.DeleteFile(Path);
  end;
end;

end.
