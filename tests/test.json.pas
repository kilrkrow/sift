unit Test.Json;

{ Piece 1 critic: filter -> JSON -> filter round trips, the v1 golden text,
  and readable errors for bad files. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Sift.Filter, Sift.FilterJson;

type
  TFilterJsonTests = class(TTestCase)
  private
    procedure RoundTrip(F: TSiftFilter);
    procedure ExpectBad(const S, Needle: string);
  published
    procedure RoundTripEmpty;
    procedure RoundTripEveryField;
    procedure RoundTripRelativeAndLastN;
    procedure RoundTripWindowWithMaxCount;
    procedure RoundTripAbsoluteOpenEnded;
    procedure GoldenV1;
    procedure RejectsBadInput;
    procedure FileSaveLoad;
    procedure HugeCapsAreClamped;
  end;

implementation

uses
  Test.Util;

procedure TFilterJsonTests.RoundTrip(F: TSiftFilter);
var
  G: TSiftFilter;
  J: string;
begin
  J := FilterToJson(F);
  G := TSiftFilter.Create;
  try
    FilterFromJson(J, G);
    AssertTrue('round trip: ' + J, F.SameAs(G));
    AssertEquals('stable text', J, FilterToJson(G));
  finally
    G.Free;
  end;
end;

procedure TFilterJsonTests.ExpectBad(const S, Needle: string);
var
  G: TSiftFilter;
  Msg: string;
begin
  Msg := '';
  G := TSiftFilter.Create;
  try
    try
      FilterFromJson(S, G);
    except
      on E: ESiftFilterFormat do
        Msg := E.Message;
    end;
  finally
    G.Free;
  end;
  AssertTrue('expected error containing "' + Needle + '", got "' + Msg + '"',
    Pos(Needle, Msg) > 0);
end;

procedure TFilterJsonTests.RoundTripWindowWithMaxCount;
var
  F: TSiftFilter;
begin
  { Piece 10: a toolbar window plus a max count (MaxEvents) }
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.SetRelativeWindow(3600000);
    F.SetMaxCount(15);
    AssertEquals(15, F.LastN);
    AssertTrue(F.TimeMode = tmRelative);
    RoundTrip(F);
  finally
    F.Free;
  end;
  F := TSiftFilter.Create;
  try
    FilterFromJson('{"siftFilterVersion":1,"lastN":5,"time":{"mode":"relative","lastMs":60000}}', F);
    AssertEquals(5, F.LastN);
    AssertEquals(60000, F.RelativeMs);
  finally
    F.Free;
  end;
end;

procedure TFilterJsonTests.RoundTripEmpty;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    RoundTrip(F);
  finally
    F.Free;
  end;
end;

procedure TFilterJsonTests.RoundTripEveryField;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.Channels.Add('Microsoft-Windows-Kernel-PnP/Configuration');
    F.Channels.Add('file://C:\x\a b.evtx');
    F.AddTerm(MakeTerm(sfChannel, saExclude, 'Setup'));
    F.AddTerm(MakeTerm(sfLevel, saInclude, 'Error'));
    F.AddTerm(MakeTerm(sfProvider, saInclude, 'Bob''s & <x>'));
    F.AddTerm(MakeTerm(sfEventId, saExclude, '7036'));
    F.AddTerm(MakeTerm(sfTask, saInclude, '12'));
    F.AddTerm(MakeTerm(sfKeywords, saInclude, '0x80'));
    F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-21-1-2-3-1001'));
    F.AddTerm(MakeTerm(sfComputer, saExclude, 'HOST1'));
    F.AddTerm(MakeTerm(sfTime, saInclude, '2026-10-30T07:15:00.123Z'));
    F.AddTerm(MakeTerm(sfMessage, saInclude, 'USB device'));
    F.TextScanCap := 5000;
    RoundTrip(F);
  finally
    F.Free;
  end;
end;

procedure TFilterJsonTests.RoundTripRelativeAndLastN;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('*');
    F.SetRelativeWindow(14400000);
    RoundTrip(F);
    F.SetLastN(40);
    RoundTrip(F);
  finally
    F.Free;
  end;
end;

procedure TFilterJsonTests.RoundTripAbsoluteOpenEnded;
var
  F: TSiftFilter;
  S: TDateTime;
begin
  F := TSiftFilter.Create;
  try
    IsoToUtc('2026-01-02T03:04:05.006Z', S);
    F.SetAbsoluteWindow(S, 0);
    RoundTrip(F);
    F.SetAbsoluteWindow(0, S);
    RoundTrip(F);
  finally
    F.Free;
  end;
end;

procedure TFilterJsonTests.GoldenV1;
var
  F: TSiftFilter;
  Expected: string;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    F.AddTerm(MakeTerm(sfEventId, saExclude, '7036'));
    F.SetLastN(20);
    Expected :=
      '{' + LineEnding +
      '  "siftFilterVersion" : 1,' + LineEnding +
      '  "channels" : [' + LineEnding +
      '    "System"' + LineEnding +
      '  ],' + LineEnding +
      '  "time" : {' + LineEnding +
      '    "mode" : "all"' + LineEnding +
      '  },' + LineEnding +
      '  "lastN" : 20,' + LineEnding +
      '  "textScanCap" : 20000,' + LineEnding +
      '  "terms" : [' + LineEnding +
      '    {' + LineEnding +
      '      "field" : "level",' + LineEnding +
      '      "action" : "include",' + LineEnding +
      '      "value" : "2"' + LineEnding +
      '    },' + LineEnding +
      '    {' + LineEnding +
      '      "field" : "eventId",' + LineEnding +
      '      "action" : "exclude",' + LineEnding +
      '      "value" : "7036"' + LineEnding +
      '    }' + LineEnding +
      '  ]' + LineEnding +
      '}';
    AssertEquals(Expected, FilterToJson(F));
  finally
    F.Free;
  end;
end;

procedure TFilterJsonTests.RejectsBadInput;
begin
  ExpectBad('not json', 'JSON parse error');
  ExpectBad('[1,2]', 'top level must be an object');
  ExpectBad('{"channels":[]}', 'missing "siftFilterVersion"');
  ExpectBad('{"siftFilterVersion":2}', 'unsupported siftFilterVersion 2');
  ExpectBad('{"siftFilterVersion":1,"terms":[{"field":"color","action":"include","value":"x"}]}', 'unknown field "color"');
  ExpectBad('{"siftFilterVersion":1,"terms":[{"field":"eventId","action":"maybe","value":"1"}]}', 'action must be include or exclude');
  ExpectBad('{"siftFilterVersion":1,"terms":[{"field":"eventId","action":"include","value":"x1"}]}', 'Invalid Event ID value');
  ExpectBad('{"siftFilterVersion":1,"time":{"mode":"sometimes"}}', 'unknown time.mode');
end;

procedure TFilterJsonTests.FileSaveLoad;
var
  F, G: TSiftFilter;
  P: string;
begin
  F := TSiftFilter.Create;
  G := TSiftFilter.Create;
  try
    F.Channels.Add('Application');
    F.AddTerm(MakeTerm(sfProvider, saInclude, 'Application Error'));
    P := ScratchDir + 'roundtrip' + SiftFilterFileExt;
    SaveFilterFile(F, P);
    LoadFilterFile(P, G);
    AssertTrue(F.SameAs(G));
    DeleteFile(P);
  finally
    F.Free;
    G.Free;
  end;
end;


procedure TFilterJsonTests.HugeCapsAreClamped;
var
  F: TSiftFilter;
  J: string;
begin
  F := TSiftFilter.Create;
  try
    J := '{"siftFilterVersion":1,"channels":["System"],"lastN":2147483647,"textScanCap":2147483647}';
    FilterFromJson(J, F);
    AssertEquals(MaxLastN, F.LastN);
    AssertEquals(MaxTextScanCap, F.TextScanCap);
    { A documented small value still loads as-is. }
    J := '{"siftFilterVersion":1,"channels":["System"],"lastN":40,"textScanCap":20000}';
    FilterFromJson(J, F);
    AssertEquals(40, F.LastN);
    AssertEquals(20000, F.TextScanCap);
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TFilterJsonTests);
end.
