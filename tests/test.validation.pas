unit Test.Validation;

{ Spike: central input validation. Every untrusted entry point (JSON load,
  LoadFilterFile used by --filter and paste, ini Channel list, right-click
  AddTerm / ApplyCell) rejects control characters, a line equal to the
  PowerShell here-string closer, both quote types, non-SID users, and
  remote / UNC file:// paths. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Sift.Filter, Sift.FilterJson, Sift.Compiler;

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
    procedure IniPersistStripsRemote;
    procedure OpenDialogPathLocalAndRemote;
    procedure EffectiveChannelsAndExportDropRemote;
    procedure RejectedValueHasVisibleReason;
  end;

implementation

uses
  Test.Util, Sift.Elevate;

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

procedure TValidationTests.IniPersistStripsRemote;
var
  Src, Dest: TStringList;
begin
  { FormCloseQuery writes LoadValidatedChannels(...).CommaText to ini. }
  Src := TStringList.Create;
  Dest := TStringList.Create;
  try
    Src.Add('System');
    Src.Add('file://\\host\share\x.evtx');
    Src.Add('Application');
    Src.Add('\\host\share\y.evtx');
    Src.Add('file://C:\logs\local.evtx');
    LoadValidatedChannels(Src.CommaText, Dest, nil);
    AssertEquals(3, Dest.Count);
    AssertEquals('System', Dest[0]);
    AssertEquals('Application', Dest[1]);
    AssertEquals('file://C:\logs\local.evtx', Dest[2]);
    AssertTrue('no UNC host in persist text', Pos('\\host', Dest.CommaText) = 0);
  finally
    Src.Free;
    Dest.Free;
  end;
end;

procedure TValidationTests.OpenDialogPathLocalAndRemote;
var
  Ch, Err: string;
begin
  AssertTrue('local evtx', TryFileChannelFromPath('C:\logs\x.evtx', Ch, Err));
  AssertEquals('file://C:\logs\x.evtx', Ch);
  AssertFalse('UNC evtx', TryFileChannelFromPath('\\host\share\x.evtx', Ch, Err));
  AssertTrue('remote reason', Pos('remote', LowerCase(Err)) > 0);
  AssertFalse('extended UNC', TryFileChannelFromPath('\\?\UNC\host\share\x.evtx', Ch, Err));
end;

procedure TValidationTests.EffectiveChannelsAndExportDropRemote;
var
  F: TSiftFilter;
  Ch: TStringArray;
  C: TSiftCompiled;
  S: string;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.Channels.Add('file://\\host\share\x.evtx');
    F.Channels.Add('\\host\share\y.evtx');
    F.Channels.Add('file:////host/share/z.evtx');
    F.Channels.Add('file://\\?\UNC\host\share\w.evtx');
    Ch := F.EffectiveChannels(nil);
    AssertEquals(1, Length(Ch));
    AssertEquals('System', Ch[0]);
    C := CompileFilter(F, nil);
    AssertEquals(1, Length(C.Channels));
    AssertEquals('System', C.Channels[0]);
    AssertTrue('no host in QueryXml', Pos('host', C.QueryXml) = 0);
    S := CompilePowerShell(F, nil);
    AssertTrue('no UNC in export', Pos('host\share', S) = 0);
    AssertTrue('no slash-UNC in export', Pos('host/share', S) = 0);
  finally
    F.Free;
  end;
end;
procedure TValidationTests.RejectedValueHasVisibleReason;
var
  F: TSiftFilter;
  Msg: string;
begin
  { ApplyCell / AddTerm raise a message the UI shows in MessageDlg. }
  F := TSiftFilter.Create;
  try
    Msg := '';
    try
      F.ApplyCell(sfProvider, 'x''" or 1=1 or @Name="', saInclude, amAdd);
    except
      on E: EConvertError do
        Msg := E.Message;
    end;
    AssertTrue('prefix', Pos('Invalid Provider value: ', Msg) = 1);
    AssertTrue('reason is visible', Pos('contains both single and double quotes', Msg) > 0);
    AssertTrue('payload is not echoed', Pos('or 1=1', Msg) = 0);
    Msg := '';
    try
      F.AddTerm(MakeTerm(sfUser, saInclude, 'S-x'));
    except
      on E: EConvertError do
        Msg := E.Message;
    end;
    AssertTrue('SID reason', Pos('not a valid SID', Msg) > 0);
  finally
    F.Free;
  end;
end;

{ ---- Issue #8: Unicode quotation marks and line breaks ------------------
  PowerShell reads U+2018-U+201B as single quotes and U+201C-U+201E as
  double quotes. Provider, computer and channel values that contain any of
  them are rejected with a visible reason; message terms may contain one
  quote style (the compiler emits them as Base64). Here-string markers and
  "both quote styles" count the Unicode forms too, and U+0085, U+2028,
  U+2029 are rejected like control characters. All entry paths (filter
  JSON paste, filter file, elevation hand-off) reach the same validator. }

type
  TUnicodeValidationTests = class(TTestCase)
  private
    procedure ExpectAddRejectedWith(Fld: TSiftField; const V, Needle: string);
    procedure ExpectChannelRejectedWith(const Ch, Needle: string);
    procedure ExpectEntryRejected(const Json, Needle, What: string);
    function EntryLoads(const Json: string; F: TSiftFilter; Path: Integer;
      out Err: string): Boolean;
  published
    procedure UnicodeQuotesRejectedInNames;
    procedure UnicodeBothQuoteTypesRejected;
    procedure UnicodeHereStringMarkersRejected;
    procedure UnicodeLineBreaksRejected;
    procedure UnicodeQuoteMessageTermAccepted;
    procedure Variant7_EntryPathsShareValidator;
  end;

const
  UQ2018 = #$E2#$80#$98;
  UQ2019 = #$E2#$80#$99;
  UQ201A = #$E2#$80#$9A;
  UQ201B = #$E2#$80#$9B;
  UD201C = #$E2#$80#$9C;
  UD201D = #$E2#$80#$9D;
  UD201E = #$E2#$80#$9E;
  USingles: array[0..4] of string = ('''', UQ2018, UQ2019, UQ201A, UQ201B);
  UUniSingles: array[0..3] of string = (UQ2018, UQ2019, UQ201A, UQ201B);
  UDoubles: array[0..3] of string = ('"', UD201C, UD201D, UD201E);
  UUniQuotes: array[0..6] of string = (UQ2018, UQ2019, UQ201A, UQ201B,
    UD201C, UD201D, UD201E);
  EntryNames: array[0..2] of string = ('paste', 'filter file', 'elevation file');
  { U+0085, U+2028, U+2029 and two other C1 controls }
  ULineBreaks: array[0..4] of string = (#$C2#$85, #$E2#$80#$A8, #$E2#$80#$A9,
    #$C2#$80, #$C2#$9F);

procedure TUnicodeValidationTests.ExpectAddRejectedWith(Fld: TSiftField;
  const V, Needle: string);
var
  F: TSiftFilter;
  Msg: string;
begin
  Msg := '';
  F := TSiftFilter.Create;
  try
    try
      F.AddTerm(MakeTerm(Fld, saInclude, V));
    except
      on E: EConvertError do
        Msg := E.Message;
    end;
    AssertTrue('expected reject (' + Needle + ') for ' + SiftFieldCaptions[Fld] +
      ', got "' + Msg + '"', Pos(Needle, Msg) > 0);
    AssertEquals(0, F.TermCount);
  finally
    F.Free;
  end;
end;

procedure TUnicodeValidationTests.ExpectChannelRejectedWith(const Ch, Needle: string);
var
  Norm, Err: string;
begin
  AssertFalse('channel should be rejected', ValidateChannel(Ch, Norm, Err));
  AssertTrue('needle "' + Needle + '" in "' + Err + '"', Pos(Needle, Err) > 0);
end;

{ Path 0: Paste filter (FilterFromJson on the clipboard text); 1: a
  .siftfilter.json file (LoadFilterFile); 2: the elevation-restart hand-off
  (LoadElevationFilterBytes, hash checked). }
function TUnicodeValidationTests.EntryLoads(const Json: string; F: TSiftFilter;
  Path: Integer; out Err: string): Boolean;
var
  P: string;
  Fs: TFileStream;
begin
  Err := '';
  Result := False;
  case Path of
    0:
      try
        FilterFromJson(Json, F);
        Result := True;
      except
        on E: Exception do
          Err := E.Message;
      end;
    1:
      begin
        P := ScratchDir + 'unicode-' + IntToStr(GetProcessID) + SiftFilterFileExt;
        Fs := TFileStream.Create(P, fmCreate);
        try
          Fs.WriteBuffer(Json[1], Length(Json));
        finally
          Fs.Free;
        end;
        try
          LoadFilterFile(P, F);
          Result := True;
        except
          on E: Exception do
            Err := E.Message;
        end;
        DeleteFile(P);
      end;
    2:
      Result := LoadElevationFilterBytes(Json, BytesSha256Hex(Json), F, Err);
  end;
end;

procedure TUnicodeValidationTests.ExpectEntryRejected(const Json, Needle, What: string);
var
  I: Integer;
  F: TSiftFilter;
  Err: string;
begin
  for I := 0 to High(EntryNames) do
  begin
    F := TSiftFilter.Create;
    try
      AssertFalse(What + ' accepted via ' + EntryNames[I], EntryLoads(Json, F, I, Err));
      AssertTrue(What + ' via ' + EntryNames[I] + ': reason "' + Needle + '" in "' + Err + '"',
        Pos(Needle, Err) > 0);
      AssertEquals(0, F.TermCount);
    finally
      F.Free;
    end;
  end;
end;

procedure TUnicodeValidationTests.UnicodeQuotesRejectedInNames;
var
  Q: string;
begin
  for Q in UUniQuotes do
  begin
    ExpectAddRejectedWith(sfProvider, 'Prov' + Q + 'ider', 'quotation mark');
    ExpectAddRejectedWith(sfProvider, Q, 'quotation mark');
    ExpectAddRejectedWith(sfComputer, 'HOST' + Q, 'quotation mark');
    ExpectAddRejectedWith(sfChannel, 'Sys' + Q + 'tem', 'quotation mark');
    ExpectChannelRejectedWith('Sys' + Q + 'tem', 'quotation mark');
    ExpectChannelRejectedWith('file://C:\fx\a' + Q + '.evtx', 'quotation mark');
  end;
end;

procedure TUnicodeValidationTests.UnicodeBothQuoteTypesRejected;
var
  S, D: string;
begin
  for S in USingles do
    for D in UDoubles do
    begin
      ExpectAddRejectedWith(sfMessage, 'a' + S + 'b' + D + 'c', 'both single and double quotes');
      ExpectAddRejectedWith(sfMessage, D + 'x' + S, 'both single and double quotes');
    end;
end;

procedure TUnicodeValidationTests.UnicodeHereStringMarkersRejected;
var
  Q: string;
  Fld: TSiftField;
begin
  for Fld in [sfProvider, sfComputer, sfMessage, sfChannel] do
  begin
    for Q in USingles do
    begin
      ExpectAddRejectedWith(Fld, Q + '@', 'here-string');
      ExpectAddRejectedWith(Fld, '@' + Q, 'here-string');
    end;
    for Q in UDoubles do
    begin
      ExpectAddRejectedWith(Fld, Q + '@', 'here-string');
      ExpectAddRejectedWith(Fld, '@' + Q, 'here-string');
    end;
  end;
  for Q in UUniSingles do
    ExpectChannelRejectedWith(Q + '@', 'here-string');
end;

procedure TUnicodeValidationTests.UnicodeLineBreaksRejected;
var
  B: string;
  Fld: TSiftField;
begin
  for B in ULineBreaks do
  begin
    for Fld in [sfProvider, sfComputer, sfMessage, sfChannel] do
      ExpectAddRejectedWith(Fld, 'a' + B + 'b', 'control characters');
    ExpectChannelRejectedWith('Sys' + B + 'tem', 'control characters');
  end;
end;

procedure TUnicodeValidationTests.UnicodeQuoteMessageTermAccepted;
var
  F: TSiftFilter;
  Q: string;
begin
  { message terms keep one quote style: the compiler emits them as Base64 }
  F := TSiftFilter.Create;
  try
    for Q in UUniQuotes do
    begin
      F.ClearTerms;
      F.AddTerm(MakeTerm(sfMessage, saInclude, 'can' + Q + 't connect'));
      AssertEquals(1, F.TermCount);
      AssertEquals('can' + Q + 't connect', F.Terms[0].Value);
    end;
  finally
    F.Free;
  end;
end;

procedure TUnicodeValidationTests.Variant7_EntryPathsShareValidator;
const
  Head = '{"siftFilterVersion":1,"channels":["System"],"terms":[{"field":"';
var
  I: Integer;
  F: TSiftFilter;
  Err: string;
begin
  { raw UTF-8 and \u escapes, provider / computer / channel }
  ExpectEntryRejected(Head + 'provider","action":"include","value":"a' + UQ2019 + 'b"}]}',
    'quotation mark', 'raw U+2019 provider');
  ExpectEntryRejected(Head + 'provider","action":"include","value":"a\u2018b"}]}',
    'quotation mark', '\u2018 provider');
  ExpectEntryRejected(Head + 'computer","action":"include","value":"H\u201Ab"}]}',
    'quotation mark', '\u201A computer');
  ExpectEntryRejected('{"siftFilterVersion":1,"channels":["Sys\u201Btem"]}',
    'quotation mark', '\u201B channel');
  ExpectEntryRejected('{"siftFilterVersion":1,"channels":["Sys' + UD201C + 'tem"]}',
    'quotation mark', 'raw U+201C channel');
  ExpectEntryRejected(Head + 'message","action":"include","value":"\u2019@"}]}',
    'here-string', '\u2019@ message');
  ExpectEntryRejected(Head + 'message","action":"include","value":"a\u2028b"}]}',
    'control characters', '\u2028 message');
  ExpectEntryRejected(Head + 'message","action":"include","value":"a\u2019b\u201Dc"}]}',
    'both single and double quotes', 'mixed quotes message');
  { a message term with one Unicode quote loads unchanged on every path }
  Err := '';
  for I := 0 to High(EntryNames) do
  begin
    F := TSiftFilter.Create;
    try
      AssertTrue('message via ' + EntryNames[I] + ': ' + Err,
        EntryLoads(Head + 'message","action":"include","value":"can\u2019t"}]}', F, I, Err));
      AssertEquals(1, F.TermCount);
      AssertEquals('can' + UQ2019 + 't', F.Terms[0].Value);
    finally
      F.Free;
    end;
  end;
end;

initialization
  RegisterTest(TValidationTests);
  RegisterTest(TUnicodeValidationTests);
end.
