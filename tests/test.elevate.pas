unit Test.Elevate;

{ Piece D: the elevation-restart temp file is a random exclusive name,
  a SHA-256 is passed with the path, and ConsumeElevationFilter verifies
  then deletes. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Sift.Filter, Sift.Elevate;

type
  TElevateTests = class(TTestCase)
  published
    procedure Sha256KnownVectors;
    procedure WriteCreatesRandomExclusiveFile;
    procedure ConsumeLoadsAndDeletes;
    procedure ConsumeRejectsBadHashAndDeletes;
    procedure CancelledRestartWouldLeaveNoFile;
  end;

implementation

uses
  Windows;


procedure TElevateTests.Sha256KnownVectors;
begin
  AssertEquals('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    BytesSha256Hex(''));
  AssertEquals('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    BytesSha256Hex('abc'));
  AssertEquals('248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    BytesSha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'));
end;

procedure TElevateTests.WriteCreatesRandomExclusiveFile;
var
  F: TSiftFilter;
  P1, P2, H1, H2, Err: string;
  Excl: THandle;
  W: UnicodeString;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    AssertTrue('write 1', WriteElevationFilter(F, P1, H1, Err));
    AssertTrue('path 1', FileExists(P1));
    AssertTrue('hash 1', Length(H1) = 64);
    AssertEquals(H1, FileSha256Hex(P1));
    AssertTrue('name prefix', Pos('sift-', ExtractFileName(P1)) = 1);
    AssertTrue('name ext', LowerCase(ExtractFileExt(P1)) = '.json');
    { Exclusive: CREATE_NEW on the same path must fail. }
    W := UnicodeString(P1);
    Excl := CreateFileW(PWideChar(W), GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL, 0);
    AssertTrue('exclusive', Excl = THandle(-1));
    AssertTrue('write 2', WriteElevationFilter(F, P2, H2, Err));
    AssertTrue('different names', not SameText(P1, P2));
    AssertEquals(H1, H2);
    SysUtils.DeleteFile(P1);
    SysUtils.DeleteFile(P2);
  finally
    F.Free;
  end;
end;

procedure TElevateTests.ConsumeLoadsAndDeletes;
var
  Src, Dest: TSiftFilter;
  P, H, Err: string;
begin
  Src := TSiftFilter.Create;
  Dest := TSiftFilter.Create;
  try
    Src.Channels.Add('Application');
    Src.AddTerm(MakeTerm(sfEventId, saInclude, '7036'));
    Src.SetLastN(15);
    AssertTrue(WriteElevationFilter(Src, P, H, Err));
    AssertTrue('exists before', FileExists(P));
    AssertTrue('consume', ConsumeElevationFilter(P, H, Dest, Err));
    AssertTrue('gone after load', not FileExists(P));
    AssertTrue('same filter', Dest.SameAs(Src));
  finally
    Src.Free;
    Dest.Free;
  end;
end;

procedure TElevateTests.ConsumeRejectsBadHashAndDeletes;
var
  Dest: TSiftFilter;
  P, H, Err: string;
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  Dest := TSiftFilter.Create;
  try
    F.Channels.Add('Security');
    AssertTrue(WriteElevationFilter(F, P, H, Err));
    H[1] := '0';
    if H[1] = FileSha256Hex(P)[1] then
      H[1] := '1';
    AssertFalse('bad hash', ConsumeElevationFilter(P, H, Dest, Err));
    AssertTrue('gone after reject', not FileExists(P));
    AssertEquals(0, Dest.Channels.Count);
    AssertTrue('reason', Pos('hash', LowerCase(Err)) > 0);
  finally
    F.Free;
    Dest.Free;
  end;
end;

procedure TElevateTests.CancelledRestartWouldLeaveNoFile;
var
  F: TSiftFilter;
  P, H, Err: string;
begin
  { If UAC is cancelled the caller must delete the temp file itself
    (ElevateClick does). This test is that DeleteFile works on the path. }
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    AssertTrue(WriteElevationFilter(F, P, H, Err));
    AssertTrue(SysUtils.DeleteFile(P));
    AssertTrue(not FileExists(P));
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TElevateTests);
end.
