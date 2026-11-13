unit Test.Validation;

{ Spike: central input validation. Every untrusted entry point (JSON load,
  LoadFilterFile used by --filter and paste, ini Channel list, right-click
  AddTerm / ApplyCell) rejects control characters, a line equal to the
  PowerShell here-string closer, both quote types, non-SID users, and
  remote / UNC file:// paths. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Sift.Filter, Sift.FilterJson;

type
  TValidationTests = class(TTestCase)
  private
    procedure ExpectAddRejected(Fld: TSiftField; const V: string);
    procedure ExpectJsonRejected(const S, Needle: string);
    procedure ExpectChannelRejected(const Ch, Needle: string);
    procedure ExpectChannelAccepted(const Ch: string);
  published
    procedure InjectionPayloadRejectedAtAddTerm;
    procedure InjectionPayloadRejectedAtJsonLoad;
    procedure InjectionPayloadRejectedAtFilterFile;
    procedure HereStringCloserLineRejected;
    procedure ControlCharsRejected;
    procedure BothQuotesRejected;
    procedure SingleQuoteTypeStillAccepted;
    procedure ApostropheAndAtAcceptedWhenSafe;
    procedure SidAcceptedAndRejected;
    procedure RemoteChannelsRejectedOnJson;
    procedure LocalFileChannelAccepted;
    procedure ExtendedLocalDriveAccepted;
    procedure RemoteDroppedOnIniReload;
    procedure RightClickIncludeRejectsInjection;
    procedure SfChannelTermRejectsRemote;
    procedure StarAndNamedChannelsAccepted;
  end;

implementation

uses
  Test.Util;

const
  Payload = #13#10'''@'#13#10'Write-Output PWNED'#13#10;

procedure TValidationTests.ExpectAddRejected(Fld: TSiftField; const V: string);
var
  F: TSiftFilter;
  Raised: Boolean;
begin
  F := TSiftFilter.Create;
  try
    Raised := False;
    try
      F.AddTerm(MakeTerm(Fld, saInclude, V));
    except
      on EConvertError do
        Raised := True;
    end;
    AssertTrue('expected reject for ' + SiftFieldCaptions[Fld] + '=' + V, Raised);
    AssertEquals(0, F.TermCount);
  finally
    F.Free;
  end;
end;

procedure TValidationTests.ExpectJsonRejected(const S, Needle: string);
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
  AssertTrue('expected "' + Needle + '" in "' + Msg + '"', Pos(Needle, Msg) > 0);
end;

procedure TValidationTests.ExpectChannelRejected(const Ch, Needle: string);
var
  Norm, Err: string;
begin
  AssertFalse('should reject ' + Ch, ValidateChannel(Ch, Norm, Err));
  AssertTrue('needle "' + Needle + '" in "' + Err + '"', Pos(Needle, Err) > 0);
end;

procedure TValidationTests.ExpectChannelAccepted(const Ch: string);
var
  Norm, Err: string;
  Ok: Boolean;
begin
  Ok := ValidateChannel(Ch, Norm, Err);
  AssertTrue('should accept ' + Ch + ' (' + Err + ')', Ok);
  AssertEquals('', Err);
end;

procedure TValidationTests.InjectionPayloadRejectedAtAddTerm;
begin
  ExpectAddRejected(sfProvider, Payload);
  ExpectAddRejected(sfComputer, Payload);
  ExpectAddRejected(sfChannel, Payload);
  ExpectAddRejected(sfMessage, Payload);
  ExpectAddRejected(sfUser, Payload);
end;

procedure TValidationTests.InjectionPayloadRejectedAtJsonLoad;
var
  J: string;
begin
  J := '{"siftFilterVersion":1,"terms":[{"field":"provider","action":"include","value":"';
  J := J + '\r\n''@\r\nWrite-Output PWNED\r\n"}]}';
  ExpectJsonRejected(J, 'Invalid Provider value');
  J := '{"siftFilterVersion":1,"channels":["';
  J := J + '\r\n''@\r\nWrite-Output PWNED\r\n"]}';
  ExpectJsonRejected(J, 'control characters');
end;

procedure TValidationTests.InjectionPayloadRejectedAtFilterFile;
var
  F: TSiftFilter;
  P, J: string;
  Raised: Boolean;
begin
  J := '{"siftFilterVersion":1,"channels":["System"],"terms":[{"field":"computer","action":"include","value":"';
  J := J + '\r\n''@\r\nWrite-Output PWNED\r\n"}]}';
  P := ScratchDir + 'inject' + SiftFilterFileExt;
  with TStringList.Create do
  try
    Text := J;
    SaveToFile(P);
  finally
    Free;
  end;
  F := TSiftFilter.Create;
  try
    Raised := False;
    try
      LoadFilterFile(P, F);
    except
      on E: ESiftFilterFormat do
        Raised := True;
    end;
    AssertTrue('LoadFilterFile rejected injection', Raised);
    AssertEquals(0, F.TermCount);
  finally
    F.Free;
    DeleteFile(P);
  end;
end;

procedure TValidationTests.HereStringCloserLineRejected;
begin
  ExpectAddRejected(sfProvider, '''@');
  ExpectChannelRejected('''@', '''@');
end;

procedure TValidationTests.ControlCharsRejected;
begin
  ExpectAddRejected(sfProvider, 'foo' + #10 + 'bar');
  ExpectAddRejected(sfProvider, 'foo' + #13 + 'bar');
  ExpectAddRejected(sfProvider, 'foo' + #9 + 'bar');
  ExpectAddRejected(sfComputer, 'HO' + #7 + 'ST');
  ExpectChannelRejected('System' + #10 + 'x', 'control characters');
end;

procedure TValidationTests.BothQuotesRejected;
const
  Both = 'x''" or 1=1 or @Name="';
var
  J: string;
begin
  ExpectAddRejected(sfProvider, Both);
  ExpectAddRejected(sfComputer, Both);
  ExpectAddRejected(sfMessage, Both);
  J := '{"siftFilterVersion":1,"terms":[{"field":"provider","action":"include","value":"x''\" or 1=1 or @Name=\""}]}';
  ExpectJsonRejected(J, 'Invalid Provider value');
end;

procedure TValidationTests.SingleQuoteTypeStillAccepted;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.AddTerm(MakeTerm(sfProvider, saInclude, 'Bob''s & <Co>'));
    F.AddTerm(MakeTerm(sfComputer, saInclude, 'foo "bar"'));
    AssertEquals(2, F.TermCount);
  finally
    F.Free;
  end;
end;

procedure TValidationTests.ApostropheAndAtAcceptedWhenSafe;
var
  F: TSiftFilter;
begin
  { Passes validation (one quote type, no control chars, not a closer line)
    but contains an apostrophe and @ -- PowerShell export must stay safe. }
  F := TSiftFilter.Create;
  try
    F.AddTerm(MakeTerm(sfComputer, saInclude, 'O''Brien@host'));
    AssertEquals(1, F.TermCount);
    AssertEquals('O''Brien@host', F.Terms[0].Value);
  finally
    F.Free;
  end;
end;

procedure TValidationTests.SidAcceptedAndRejected;
var
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-18'));
    F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-21-1-2-3-1001'));
    AssertEquals(2, F.TermCount);
  finally
    F.Free;
  end;
  ExpectAddRejected(sfUser, 'S-x');
  ExpectAddRejected(sfUser, 'S-1-5-18''');
  ExpectAddRejected(sfUser, 'S-' + 'junk');
  ExpectAddRejected(sfUser, 'SYSTEM');
  ExpectAddRejected(sfUser, 's-1-5-18');
  ExpectAddRejected(sfUser, 'S-1-5');
end;

procedure TValidationTests.RemoteChannelsRejectedOnJson;
  procedure CaseCh(const Ch: string);
  var
    J: string;
    I: Integer;
    Esc: string;
  begin
    ExpectChannelRejected(Ch, 'remote or UNC');
    Esc := '';
    for I := 1 to Length(Ch) do
    begin
      if Ch[I] = '\' then
        Esc := Esc + '\\'
      else if Ch[I] = '"' then
        Esc := Esc + '\"'
      else
        Esc := Esc + Ch[I];
    end;
    J := '{"siftFilterVersion":1,"channels":["' + Esc + '"]}';
    ExpectJsonRejected(J, 'remote or UNC');
  end;
begin
  CaseCh('file://\\host\share\x.evtx');
  CaseCh('file:////host/share/x.evtx');
  CaseCh('\\host\share\x.evtx');
  CaseCh('file://\\?\UNC\host\share\x.evtx');
  CaseCh('file://attacker/share/x.evtx');
end;

procedure TValidationTests.LocalFileChannelAccepted;
var
  F: TSiftFilter;
  J: string;
begin
  ExpectChannelAccepted('file://C:\fx\system.evtx');
  ExpectChannelAccepted('file:///C:/fx/system.evtx');
  ExpectChannelAccepted('file://C:\x\a b.evtx');
  F := TSiftFilter.Create;
  try
    J := '{"siftFilterVersion":1,"channels":["file://C:\\fx\\system.evtx"]}';
    FilterFromJson(J, F);
    AssertEquals(1, F.Channels.Count);
    AssertEquals('file://C:\fx\system.evtx', F.Channels[0]);
  finally
    F.Free;
  end;
end;

procedure TValidationTests.ExtendedLocalDriveAccepted;
begin
  ExpectChannelAccepted('file://\\?\C:\logs\x.evtx');
end;

procedure TValidationTests.RemoteDroppedOnIniReload;
var
  Dest, Rej: TStringList;
begin
  Dest := TStringList.Create;
  Rej := TStringList.Create;
  try
    Dest.CaseSensitive := False;
    LoadValidatedChannels(
      'System,"file://\\host\share\x.evtx",Application,"\\host\share\y.evtx"',
      Dest, Rej);
    AssertEquals(2, Dest.Count);
    AssertEquals('System', Dest[0]);
    AssertEquals('Application', Dest[1]);
    AssertEquals(2, Rej.Count);
  finally
    Dest.Free;
    Rej.Free;
  end;
end;

procedure TValidationTests.RightClickIncludeRejectsInjection;
var
  F: TSiftFilter;
  Raised: Boolean;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    Raised := False;
    try
      F.ApplyCell(sfProvider, Payload, saInclude, amAdd);
    except
      on EConvertError do
        Raised := True;
    end;
    AssertTrue('ApplyCell rejected injection', Raised);
    AssertEquals(0, F.TermCount);
    Raised := False;
    try
      F.ApplyCell(sfProvider, 'x''" or 1=1 or @Name="', saInclude, amSet);
    except
      on EConvertError do
        Raised := True;
    end;
    AssertTrue('ApplyCell rejected both-quotes', Raised);
  finally
    F.Free;
  end;
end;

procedure TValidationTests.SfChannelTermRejectsRemote;
begin
  ExpectAddRejected(sfChannel, 'file://\\host\share\x.evtx');
  ExpectAddRejected(sfChannel, '\\host\share\x.evtx');
end;

procedure TValidationTests.StarAndNamedChannelsAccepted;
begin
  ExpectChannelAccepted('*');
  ExpectChannelAccepted('System');
  ExpectChannelAccepted('Microsoft-Windows-Kernel-PnP/Configuration');
end;

initialization
  RegisterTest(TValidationTests);
end.
