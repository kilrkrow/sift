unit Test.Compiler;

{ Piece 1 critic: golden tests. Filter -> expected structured query text,
  -> expected Get-WinEvent -FilterHashtable one-liner, and -> PowerShell
  export. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, base64, Sift.Filter, Sift.Compiler, Test.Util;

type
  TCompilerGoldenTests = class(TTestCase)
  private
    F: TSiftFilter;
    function Q: string;
    function FH: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure EmptySystemIsStar;
    procedure SpikeFilterSystemApplication;
    procedure ProviderQuotingAndEscaping;
    procedure KeywordsUserComputerTask;
    procedure AbsoluteWindow;
    procedure TimeTermIncludeExclude;
    procedure InformationCoversLevelZero;
    procedure MoreThanTwentyTermsSplitsSelects;
    procedure ManyExcludesSplitSuppress;
    procedure ChannelTermsAndAll;
    procedure FileChannels;
    procedure FilterHashtableIncludeOnly;
    procedure FilterHashtableRelativeUnits;
    procedure FilterHashtableRefusesExclude;
    procedure FilterHashtableRefusesComputer;
    procedure FilterHashtableTextTerm;
    procedure PowerShellExportShape;
    procedure PowerShellExportTextAndLastN;
    procedure PowerShellQueryIsBase64NotHereString;
    procedure PowerShellValidAtQuoteRunsAsSingleAssignment;
    procedure PowerShellPerChannelQueriesAreBase64;
    procedure RecordQuery;
  end;

implementation

uses
  Process, Sift.FilterJson;

const
  NL = #13#10;

procedure TCompilerGoldenTests.SetUp;
begin
  F := TSiftFilter.Create;
end;

procedure TCompilerGoldenTests.TearDown;
begin
  F.Free;
end;

function TCompilerGoldenTests.Q: string;
begin
  Result := CompileFilter(F, nil).QueryXml;
end;

function TCompilerGoldenTests.FH: string;
begin
  Result := CompileFilter(F, nil).FilterHashtable;
end;

function QueryAssignPrefix: string;
begin
  Result := '$siftQuery = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(''';
end;

function DecodeAssign(const Assign: string): string;
var
  Pfx: string;
begin
  Pfx := QueryAssignPrefix;
  if Copy(Assign, 1, Length(Pfx)) <> Pfx then
    raise EAssertionFailed.Create('assignment is not a Base64 decode');
  if Copy(Assign, Length(Assign) - 2, 3) <> '''))' then
    raise EAssertionFailed.Create('assignment does not close FromBase64String');
  Result := DecodeStringBase64(Copy(Assign, Length(Pfx) + 1, Length(Assign) - Length(Pfx) - 3));
end;

procedure TCompilerGoldenTests.EmptySystemIsStar;
begin
  F.Channels.Add('System');
  AssertEquals('<QueryList>' + NL +
    '  <Query Id="0" Path="System">' + NL +
    '    <Select Path="System">*</Select>' + NL +
    '  </Query>' + NL +
    '</QueryList>', Q);
end;

procedure TCompilerGoldenTests.SpikeFilterSystemApplication;
begin
  F.Channels.Add('System');
  F.Channels.Add('Application');
  F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
  F.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
  F.AddTerm(MakeTerm(sfEventId, saInclude, '7036'));
  F.AddTerm(MakeTerm(sfEventId, saInclude, '1014'));
  F.AddTerm(MakeTerm(sfEventId, saExclude, '10016'));
  F.SetRelativeWindow(3600000);
  AssertEquals('<QueryList>' + NL +
    '  <Query Id="0" Path="System">' + NL +
    '    <Select Path="System">*[System[(EventID=7036 or EventID=1014) and (Level=2 or Level=3) and TimeCreated[timediff(@SystemTime) &lt;= 3600000]]]</Select>' + NL +
    '    <Select Path="Application">*[System[(EventID=7036 or EventID=1014) and (Level=2 or Level=3) and TimeCreated[timediff(@SystemTime) &lt;= 3600000]]]</Select>' + NL +
    '    <Suppress Path="System">*[System[(EventID=10016)]]</Suppress>' + NL +
    '    <Suppress Path="Application">*[System[(EventID=10016)]]</Suppress>' + NL +
    '  </Query>' + NL +
    '</QueryList>', Q);
end;

procedure TCompilerGoldenTests.ProviderQuotingAndEscaping;
var
  Raised: Boolean;
begin
  F.Channels.Add('Application');
  F.AddTerm(MakeTerm(sfProvider, saInclude, 'Bob''s & <Co>'));
  AssertEquals('    <Select Path="Application">*[System[(Provider[@Name=&quot;Bob''s &amp; &lt;Co&gt;&quot;])]]</Select>',
    CompileFilter(F, nil).QueryXml.Split([#13#10])[2]);
  F.ClearTerms;
  F.AddTerm(MakeTerm(sfProvider, saInclude, 'Service Control Manager'));
  AssertEquals('    <Select Path="Application">*[System[(Provider[@Name=''Service Control Manager''])]]</Select>',
    CompileFilter(F, nil).QueryXml.Split([#13#10])[2]);
  Raised := False;
  try
    F.AddTerm(MakeTerm(sfProvider, saInclude, 'x''" or 1=1 or @Name="'));
  except
    on EConvertError do
      Raised := True;
  end;
  AssertTrue('both-quote provider is rejected', Raised);
end;

procedure TCompilerGoldenTests.KeywordsUserComputerTask;
begin
  F.Channels.Add('Security');
  F.AddTerm(MakeTerm(sfKeywords, saInclude, '0x8020000000000000'));
  F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-18'));
  F.AddTerm(MakeTerm(sfComputer, saInclude, 'HOST1'));
  F.AddTerm(MakeTerm(sfTask, saInclude, '12544'));
  AssertEquals('    <Select Path="Security">*[System[(Task=12544) and (band(Keywords,9232379236109516800)) and (Security[@UserID=''S-1-5-18'']) and (Computer=''HOST1'')]]</Select>',
    Q.Split([#13#10])[2]);
end;

procedure TCompilerGoldenTests.AbsoluteWindow;
var
  S, E: TDateTime;
begin
  F.Channels.Add('System');
  IsoToUtc('2026-10-30T07:00:00.000Z', S);
  IsoToUtc('2026-10-30T08:30:00.500Z', E);
  F.SetAbsoluteWindow(S, E);
  AssertEquals('    <Select Path="System">*[System[TimeCreated[@SystemTime&gt;=''2026-10-30T07:00:00.000Z'' and @SystemTime&lt;=''2026-10-30T08:30:00.500Z'']]]</Select>',
    Q.Split([#13#10])[2]);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; StartTime=[datetime]''2026-10-30T07:00:00.000Z''; EndTime=[datetime]''2026-10-30T08:30:00.500Z'' }', FH);
end;

procedure TCompilerGoldenTests.TimeTermIncludeExclude;
var
  L: TStringArray;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfTime, saInclude, '2026-10-30T07:00:00.000Z'));
  F.AddTerm(MakeTerm(sfTime, saExclude, '2026-10-30T08:00:00.000Z'));
  L := Q.Split([#13#10]);
  AssertEquals('    <Select Path="System">*[System[(TimeCreated[@SystemTime&gt;=''2026-10-30T07:00:00.000Z''])]]</Select>', L[2]);
  AssertEquals('    <Suppress Path="System">*[System[(TimeCreated[@SystemTime&gt;=''2026-10-30T08:00:00.000Z''])]]</Suppress>', L[3]);
end;

procedure TCompilerGoldenTests.InformationCoversLevelZero;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfLevel, saInclude, 'Information'));
  AssertEquals('    <Select Path="System">*[System[(Level=4 or Level=0)]]</Select>',
    Q.Split([#13#10])[2]);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; Level=4,0 }', FH);
end;

procedure TCompilerGoldenTests.MoreThanTwentyTermsSplitsSelects;
var
  I: Integer;
  C: TSiftCompiled;
  L: TStringArray;
  Line: string;
  Cnt: Integer;
begin
  F.Channels.Add('System');
  for I := 1 to 30 do
    F.AddTerm(MakeTerm(sfEventId, saInclude, IntToStr(I)));
  F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
  C := CompileFilter(F, nil);
  AssertEquals('selects', 2, C.SelectCount);
  L := C.QueryXml.Split([#13#10]);
  for Line in L do
    if Pos('<Select', Line) > 0 then
    begin
      Cnt := 0;
      for I := 1 to Length(Line) - 1 do
        if Line[I] = '=' then
          Inc(Cnt);
      Dec(Cnt); { Path= attribute }
      AssertTrue('<= 20 sub-expressions: ' + Line, Cnt <= MaxSubExpressions);
      AssertTrue('keeps the level group', Pos('(Level=2)', Line) > 0);
    end;
  AssertEquals('    <Select Path="System">*[System[(EventID=1 or EventID=2 or EventID=3 or EventID=4 or EventID=5 or EventID=6 or EventID=7 or EventID=8 or EventID=9 or EventID=10 or EventID=11 or EventID=12 or EventID=13 or EventID=14 or EventID=15) and (Level=2)]]</Select>', L[2]);
  AssertEquals('', C.FilterHashtable);
  AssertTrue(Pos('20 sub-expressions', C.FilterHashtableNote) > 0);
end;

procedure TCompilerGoldenTests.ManyExcludesSplitSuppress;
var
  I: Integer;
  C: TSiftCompiled;
begin
  F.Channels.Add('System');
  for I := 1 to 25 do
    F.AddTerm(MakeTerm(sfEventId, saExclude, IntToStr(I)));
  C := CompileFilter(F, nil);
  AssertEquals(1, C.SelectCount);
  AssertEquals(2, C.SuppressCount);
end;

procedure TCompilerGoldenTests.ChannelTermsAndAll;
var
  All: TStringList;
  C: TSiftCompiled;
begin
  All := TStringList.Create;
  try
    All.Add('Application');
    All.Add('System');
    All.Add('Microsoft-Windows-Kernel-PnP/Configuration');
    F.Channels.Add('*');
    F.AddTerm(MakeTerm(sfChannel, saExclude, 'System'));
    C := CompileFilter(F, All);
    AssertEquals(2, Length(C.Channels));
    AssertEquals('Application', C.Channels[0]);
    AssertEquals('Microsoft-Windows-Kernel-PnP/Configuration', C.Channels[1]);
    F.AddTerm(MakeTerm(sfChannel, saInclude, 'Setup'));
    C := CompileFilter(F, All);
    AssertEquals(1, Length(C.Channels));
    AssertEquals('Setup', C.Channels[0]);
  finally
    All.Free;
  end;
end;

procedure TCompilerGoldenTests.FileChannels;
begin
  F.Channels.Add('file://C:\fx\system.evtx');
  F.AddTerm(MakeTerm(sfEventId, saInclude, '7036'));
  AssertEquals('    <Select Path="file://C:\fx\system.evtx">*[System[(EventID=7036)]]</Select>',
    Q.Split([#13#10])[2]);
  AssertEquals('Get-WinEvent -FilterHashtable @{ Path=''C:\fx\system.evtx''; Id=7036 }', FH);
end;

procedure TCompilerGoldenTests.FilterHashtableIncludeOnly;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfProvider, saInclude, 'Service Control Manager'));
  F.AddTerm(MakeTerm(sfEventId, saInclude, '7036'));
  F.AddTerm(MakeTerm(sfEventId, saInclude, '7040'));
  F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
  F.AddTerm(MakeTerm(sfLevel, saInclude, '4'));
  F.AddTerm(MakeTerm(sfUser, saInclude, 'S-1-5-18'));
  F.SetLastN(20);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; ProviderName=''Service Control Manager''; Id=7036,7040; Level=2,4,0; UserID=''S-1-5-18'' } -MaxEvents 20', FH);
  F.SetLastN(0);
  F.Channels.Add('Application');
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System'',''Application''; ProviderName=''Service Control Manager''; Id=7036,7040; Level=2,4,0; UserID=''S-1-5-18'' }', FH);
  F.SetLastN(20);
  AssertEquals('multi-log last-N has no faithful one-liner', '', FH);
end;

procedure TCompilerGoldenTests.FilterHashtableRelativeUnits;
begin
  F.Channels.Add('System');
  F.SetRelativeWindow(4 * 3600000);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; StartTime=(Get-Date).AddHours(-4) }', FH);
  F.SetRelativeWindow(15 * 60000);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; StartTime=(Get-Date).AddMinutes(-15) }', FH);
  F.SetRelativeWindow(1 * 60000);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System''; StartTime=(Get-Date).AddMinutes(-1) }', FH);
end;

procedure TCompilerGoldenTests.FilterHashtableRefusesExclude;
var
  C: TSiftCompiled;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfEventId, saExclude, '7036'));
  C := CompileFilter(F, nil);
  AssertEquals('', C.FilterHashtable);
  AssertTrue(Pos('SuppressHashFilter', C.FilterHashtableNote) > 0);
end;

procedure TCompilerGoldenTests.FilterHashtableRefusesComputer;
var
  C: TSiftCompiled;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfComputer, saInclude, 'HOST1'));
  C := CompileFilter(F, nil);
  AssertEquals('', C.FilterHashtable);
  AssertTrue(Pos('Computer', C.FilterHashtableNote) > 0);
end;

procedure TCompilerGoldenTests.FilterHashtableTextTerm;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfMessage, saInclude, 'usb'));
  F.SetLastN(10);
  AssertEquals('Get-WinEvent -FilterHashtable @{ LogName=''System'' } | Where-Object { $_.Message -ne $null -and $_.Message.IndexOf(''usb'', [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 10', FH);
  AssertTrue(CompileFilter(F, nil).ClientText);
end;

procedure TCompilerGoldenTests.PowerShellExportShape;
var
  S: string;
  L: TStringArray;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
  F.AddTerm(MakeTerm(sfEventId, saExclude, '7036'));
  F.SetLastN(40);
  S := CompilePowerShell(F, nil);
  L := S.Split([#13#10]);
  AssertEquals('$siftErrors = @()', L[2]);
  AssertTrue('base64 assign', Pos('$siftQuery = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(''', L[3]) = 1);
  AssertTrue('closes the call', Copy(L[3], Length(L[3]) - 2, 3) = '''))');
  AssertEquals('$siftEvents = @(Get-WinEvent -FilterXml $siftQuery -MaxEvents 40 -ErrorAction SilentlyContinue -ErrorVariable +siftErrors -WarningAction SilentlyContinue)', L[4]);
  AssertTrue('no raw QueryList', Pos('<QueryList>', S) = 0);
  AssertTrue('no here-string opener', Pos('@''', S) = 0);
  AssertTrue('no &&', Pos('&&', S) = 0);
  AssertTrue('no SuppressHashFilter', Pos('SuppressHashFilter', S) = 0);
  AssertEquals(CompileFilter(F, nil).QueryXml, DecodeAssign(L[3]));
end;

procedure TCompilerGoldenTests.PowerShellExportTextAndLastN;
var
  S: string;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfMessage, saInclude, 'disk'));
  F.AddTerm(MakeTerm(sfMessage, saExclude, 'O''Brien'));
  F.SetLastN(5);
  S := CompilePowerShell(F, nil);
  AssertTrue(Pos('-FilterXml $siftQuery -ErrorAction', S) > 0);
  AssertTrue(Pos('-MaxEvents', S) = 0);
  AssertTrue(Pos('$siftEvents = @($siftEvents | Where-Object { $_.Message -ne $null -and $_.Message.IndexOf(''disk''', S) > 0);
  AssertTrue(Pos('Where-Object { -not ($_.Message -ne $null -and $_.Message.IndexOf(''O''''Brien''', S) > 0);
  AssertTrue(Pos('$siftEvents = @($siftEvents | Select-Object -First 5)', S) > 0);
end;

procedure TCompilerGoldenTests.RecordQuery;
begin
  AssertEquals('<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[EventRecordID=42]]</Select></Query></QueryList>',
    RecordQueryXml('System', 42));
end;

procedure TCompilerGoldenTests.PowerShellQueryIsBase64NotHereString;
var
  S: string;
  L: TStringArray;
begin
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfComputer, saInclude, 'O''Brien@host'));
  S := CompilePowerShell(F, nil);
  L := S.Split([#13#10]);
  AssertTrue('no here-string opener', Pos('@''', S) = 0);
  AssertTrue('no raw QueryList', Pos('<QueryList>', S) = 0);
  AssertTrue('uses FromBase64String', Pos('[System.Convert]::FromBase64String(', S) > 0);
  AssertEquals(CompileFilter(F, nil).QueryXml, DecodeAssign(L[3]));
  AssertTrue('value is in the decoded XML', Pos('O''Brien@host', DecodeAssign(L[3])) > 0);
end;

procedure TCompilerGoldenTests.PowerShellValidAtQuoteRunsAsSingleAssignment;
var
  S, Script, OutLine: string;
  Lines: TStringList;
  Code: Integer;
  L: TStringArray;
begin
  { BAR 3: a valid value with both ' and @ is encoded, not a here-string.
    The generated script, run with powershell -NoProfile -File against a
    Get-WinEvent stub, never emits PWNED and $siftQuery is one QueryList. }
  F.Channels.Add('System');
  F.AddTerm(MakeTerm(sfComputer, saInclude, 'O''Brien@host'));
  F.SetLastN(10);
  S := CompilePowerShell(F, nil);
  AssertTrue('no here-string opener', Pos('@''', S) = 0);
  L := S.Split([#13#10]);
  AssertEquals(CompileFilter(F, nil).QueryXml, DecodeAssign(L[3]));
  Lines := TStringList.Create;
  try
    Script :=
      'function Get-WinEvent { [CmdletBinding()] param($FilterXml, $MaxEvents) @() }' + NL +
      S + NL +
      '$status = ''FAIL''' + NL +
      'if (($siftQuery -is [string]) -and (([regex]::Matches($siftQuery, ''<QueryList>'')).Count -eq 1)) { $status = ''QUERY-OK'' }' + NL +
      '@($status, $siftQuery) | Set-Content -Path $SiftOut';
    Code := RunPs(Script, Lines);
    if Lines.Count > 0 then
      OutLine := Lines[0]
    else
      OutLine := '';
    AssertEquals('powershell exit 0 (exit ' + IntToStr(Code) + ' out=' + OutLine + ')', 0, Code);
    AssertEquals('QUERY-OK', OutLine);
    AssertTrue('decoded query in output', Pos('O''Brien@host', Lines.Text) > 0);
    AssertTrue('no PWNED in output', Pos('PWNED', Lines.Text) = 0);
  finally
    Lines.Free;
  end;
end;

procedure TCompilerGoldenTests.PowerShellPerChannelQueriesAreBase64;
var
  S, B64, Decoded: string;
  L: TStringArray;
  I, N, P: Integer;
begin
  F.Channels.Add('System');
  F.Channels.Add('Application');
  F.SetLastN(5);
  S := CompilePowerShell(F, nil);
  AssertTrue('no here-string opener', Pos('@''', S) = 0);
  AssertTrue('no raw QueryList', Pos('<QueryList>', S) = 0);
  L := S.Split([#13#10]);
  N := 0;
  for I := 0 to High(L) do
  begin
    P := Pos('FromBase64String(''', L[I]);
    if P > 0 then
    begin
      Inc(N);
      B64 := Copy(L[I], P + Length('FromBase64String('''), Length(L[I]) - (P + Length('FromBase64String(''')) + 1 - 3);
      Decoded := DecodeStringBase64(B64);
      AssertTrue('decoded query ' + IntToStr(N), Pos('<QueryList>', Decoded) > 0);
    end;
  end;
  AssertTrue('both per-channel queries encoded', N >= 2);
end;

{ ---- Issue #8: PowerShell quoting of Unicode quote characters ----------

  Every user value that reaches generated PowerShell (provider, live
  channel, .evtx path, SID, message Include/Exclude, single-log and
  per-path export) is generated for each variant value, once through the
  validated entry point (AddTerm / ValidateChannel) and once with the
  compiler called directly on an unvalidated filter. A rejected value must
  carry a visible reason. Every accepted value is written to a case
  folder with the same filter built on a plain value, and
  tests\ps\Test-GeneratedPs.ps1 checks it in powershell.exe 5.1 and
  pwsh.exe 7: AST shape vs the plain value, the value reaching PowerShell
  unchanged, and no PWNED when run against a stub Get-WinEvent. }

type
  { Same field order as TSiftFilter (FChannels, FTerms first). Test-only:
    lets a test put a term in a filter without AddTerm's validation, the
    way a caller that skipped validation would reach the compiler. }
  TSiftFilterFields = class
  private
    FChannels: TStringList;
    FTerms: TSiftTermArray;
  end;

const
  Q27 = '''';
  Q2018 = #$E2#$80#$98;
  Q2019 = #$E2#$80#$99;
  Q201A = #$E2#$80#$9A;
  Q201B = #$E2#$80#$9B;
  D22 = '"';
  D201C = #$E2#$80#$9C;
  D201D = #$E2#$80#$9D;
  D201E = #$E2#$80#$9E;
  H2D = '-';
  H2013 = #$E2#$80#$93;
  H2014 = #$E2#$80#$94;
  H2015 = #$E2#$80#$95;
  LNEL = #$C2#$85;
  LSEP = #$E2#$80#$A8;
  PSEP = #$E2#$80#$A9;
  SingleQuotes: array[0..4] of string = (Q27, Q2018, Q2019, Q201A, Q201B);
  SingleNames: array[0..4] of string = ('0027', '2018', '2019', '201A', '201B');
  DoubleQuotes: array[0..3] of string = (D22, D201C, D201D, D201E);
  DoubleNames: array[0..3] of string = ('0022', '201C', '201D', '201E');
  Dashes: array[0..3] of string = (H2D, H2013, H2014, H2015);
  DashNames: array[0..3] of string = ('002D', '2013', '2014', '2015');
  AllSinks: array[0..6] of string = ('provider', 'logname', 'path', 'user',
    'msginc', 'msgexc', 'perpath');
  ShellNames: array[0..1] of string = ('powershell', 'pwsh');
  Seps: array[0..2] of string = (#13, #10, #13#10);
  SepNames: array[0..2] of string = ('cr', 'lf', 'crlf');
  OtherBreaks: array[0..2] of string = (LNEL, LSEP, PSEP);
  OtherBreakNames: array[0..2] of string = ('0085', '2028', '2029');
  PlainValue = 'SiftPlainValue';
  PlainSid = 'S-1-5-21-1-2-3-1001';

{ Breakouts, Q = the quote under test. Each one prints PWNED when its
  quote ends the literal in that sink:
  BreakFH    hashtable value (ProviderName= / LogName= / Path= / UserID=)
  BreakText1 one-liner message Include (Where-Object after the pipe)
  BreakText2 export message Include (inside $x = @($x | Where-Object ...))
  BreakText3 export message Exclude (Where-Object with -not (...)) }
function BreakFH(const Q: string): string;
begin
  Result := 'x' + Q + ' }; Write-Output PWNED; @{ a=' + Q;
end;

function BreakText1(const Q: string): string;
begin
  Result := 'x' + Q + ', 0) -ge 0 }; Write-Output PWNED; & { @(' + Q;
end;

function BreakText2(const Q: string): string;
begin
  Result := 'x' + Q + ', 0) -ge 0 }); Write-Output PWNED; $null = @(& { @(' + Q;
end;

function BreakText3(const Q: string): string;
begin
  Result := 'x' + Q + ', 0) -ge 0) }); Write-Output PWNED; $null = @(& { (@(' + Q;
end;

procedure ForceTerm(F: TSiftFilter; Fld: TSiftField; Act: TSiftAction;
  const V: string);
var
  N: Integer;
  R: TSiftFilterFields;
begin
  R := TSiftFilterFields(TObject(F));
  N := Length(R.FTerms);
  SetLength(R.FTerms, N + 1);
  R.FTerms[N] := MakeTerm(Fld, Act, V);
  if (F.TermCount <> N + 1) or (F.Terms[N].Value <> V) or (F.Terms[N].Field <> Fld) then
    raise Exception.Create('ForceTerm: TSiftFilter field layout changed');
end;

function B64Line(const S: string): string;
begin
  Result := EncodeStringBase64(S);
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
end;

procedure WriteBytes(const FileName, Data: string);
var
  Fs: TFileStream;
begin
  Fs := TFileStream.Create(FileName, fmCreate);
  try
    if Data <> '' then
      Fs.WriteBuffer(Data[1], Length(Data));
  finally
    Fs.Free;
  end;
end;

function PwshPath: string;
var
  Pf: string;
begin
  Result := GetEnvironmentVariable('SIFT_PWSH');
  if (Result <> '') and FileExists(Result) then
    Exit;
  Pf := GetEnvironmentVariable('ProgramW6432');
  if Pf = '' then
    Pf := GetEnvironmentVariable('ProgramFiles');
  Result := IncludeTrailingPathDelimiter(Pf) + 'PowerShell\7\pwsh.exe';
  if not FileExists(Result) then
    Result := '';
end;

function ShellPath(const Name: string): string;
begin
  if Name = 'pwsh' then
    Result := PwshPath
  else
    Result := 'powershell.exe';
end;

type
  TPsInjectionTests = class(TTestCase)
  private
    FDir: string;
    FCases: TStringList;
    FRejectNoReason: TStringList;
    FSeq: Integer;
    procedure StartSet(const Name: string);
    function BuildFilter(F: TSiftFilter; const Sink, V: string;
      Validate: Boolean; out Expected, Why: string): Boolean;
    procedure AddCase(const Id, Sink, V: string; Validate, Exec: Boolean);
    procedure AddAllSinks(const Id, V: string; Exec: Boolean);
    procedure RunChecker;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Repro_UnicodeSingleQuoteBreakout;
    procedure PsQuoteDoublesEveryPowerShellSingleQuote;
    procedure Variant1_SingleQuoteForms;
    procedure Variant2_DoubleQuoteForms;
    procedure Variant3_DashLookalikesWithBreakout;
    procedure Variant4_HereStringForms;
    procedure Variant5_OtherLineBreaks;
    procedure Variant6_EverySink;
    procedure Variant8_ShellsAndDeliveryForms;
    procedure Regression_ApostropheValuesStillWork;
    procedure ExportFileIsUtf8WithBom;
  end;

procedure TPsInjectionTests.SetUp;
begin
  FCases := TStringList.Create;
  FRejectNoReason := TStringList.Create;
  FSeq := 0;
end;

procedure TPsInjectionTests.TearDown;
begin
  FCases.Free;
  FRejectNoReason.Free;
end;

procedure TPsInjectionTests.StartSet(const Name: string);
var
  Sr: TSearchRec;
begin
  FDir := ScratchDir + 'psinj-' + Name + '-' + IntToStr(GetProcessID) + '\';
  ForceDirectories(FDir);
  if FindFirst(FDir + '*', faAnyFile, Sr) = 0 then
  try
    repeat
      if (Sr.Attr and faDirectory) = 0 then
        DeleteFile(FDir + Sr.Name);
    until FindNext(Sr) <> 0;
  finally
    FindClose(Sr);
  end;
  FCases.Clear;
  FRejectNoReason.Clear;
end;

function TPsInjectionTests.BuildFilter(F: TSiftFilter; const Sink, V: string;
  Validate: Boolean; out Expected, Why: string): Boolean;
var
  Norm, Ch: string;

  function AddT(Fld: TSiftField; Act: TSiftAction; const Val: string): Boolean;
  begin
    Result := True;
    if Validate then
    begin
      try
        F.AddTerm(MakeTerm(Fld, Act, Val));
      except
        on E: EConvertError do
        begin
          Why := E.Message;
          Exit(False);
        end;
      end;
    end
    else
      ForceTerm(F, Fld, Act, Val);
    Expected := F.Terms[F.TermCount - 1].Value;
  end;

  function AddCh(const Val: string; IsValue: Boolean): Boolean;
  var
    E: string;
  begin
    Result := True;
    if Validate then
    begin
      if not ValidateChannel(Val, Norm, E) then
      begin
        Why := E;
        Exit(False);
      end;
      F.Channels.Add(Norm);
    end
    else
    begin
      Norm := Val;
      F.Channels.Add(Val);
    end;
    if IsValue then
      Expected := Norm;
  end;

begin
  Why := '';
  Expected := '';
  if Sink = 'provider' then
    Result := AddCh('System', False) and AddT(sfProvider, saInclude, V)
  else if Sink = 'logname' then
    Result := AddCh(V, True)
  else if Sink = 'path' then
  begin
    Result := AddCh('file://C:\fx\' + V + '.evtx', True);
    if Result then
      Expected := Copy(Expected, Length('file://') + 1, MaxInt);
  end
  else if Sink = 'user' then
    Result := AddCh('System', False) and AddT(sfUser, saInclude, V)
  else if Sink = 'msginc' then
    Result := AddCh('System', False) and AddT(sfMessage, saInclude, V)
  else if Sink = 'msgexc' then
    Result := AddCh('System', False) and AddT(sfMessage, saExclude, V)
  else if Sink = 'perpath' then
  begin
    Result := AddCh('System', False) and AddCh('Application', False) and
      AddT(sfMessage, saInclude, V);
    F.SetLastN(5);
  end
  else if Sink = 'repro' then
  begin
    { one filter: channel, provider and message Include all carry V }
    Result := AddCh(V, True) and AddT(sfProvider, saInclude, V) and
      AddT(sfMessage, saInclude, V);
  end
  else
    raise Exception.Create('unknown sink ' + Sink);
  if (not Result) and (Why = '') then
    Why := '(no reason)';
end;

procedure TPsInjectionTests.AddCase(const Id, Sink, V: string; Validate, Exec: Boolean);
var
  Fv, Fp: TSiftFilter;
  Ev, Ep, Why, WhyP, Plain, Name: string;
  Cv, Cp: TSiftCompiled;
  Ok: Boolean;
begin
  Inc(FSeq);
  if Validate then
    Name := Format('%.4d-%s-%s-val', [FSeq, Id, Sink])
  else
    Name := Format('%.4d-%s-%s-raw', [FSeq, Id, Sink]);
  if Sink = 'user' then
    Plain := PlainSid
  else
    Plain := PlainValue;
  Fv := TSiftFilter.Create;
  Fp := TSiftFilter.Create;
  try
    Ok := BuildFilter(Fv, Sink, V, Validate, Ev, Why);
    if not Ok then
    begin
      { rejected at load: fine, if the reason is visible }
      if (Trim(Why) = '') or (Why = '(no reason)') then
        FRejectNoReason.Add(Name);
      Exit;
    end;
    if not BuildFilter(Fp, Sink, Plain, Validate, Ep, WhyP) then
      raise Exception.Create('plain value rejected for ' + Name + ': ' + WhyP);
    Cv := CompileFilter(Fv, nil);
    Cp := CompileFilter(Fp, nil);
    if Cv.FilterHashtable <> '' then
      WriteBytes(FDir + Name + '.v.oneliner.txt', Cv.FilterHashtable);
    if Cp.FilterHashtable <> '' then
      WriteBytes(FDir + Name + '.p.oneliner.txt', Cp.FilterHashtable);
    { the export file as the app should write it: UTF-8 with BOM }
    WriteBytes(FDir + Name + '.v.export.ps1', #$EF#$BB#$BF + CompilePowerShell(Fv, nil) + #13#10);
    WriteBytes(FDir + Name + '.p.export.ps1', #$EF#$BB#$BF + CompilePowerShell(Fp, nil) + #13#10);
    FCases.Add(Name + #9 + Sink + #9 + B64Line(Ev) + #9 + B64Line(Ep) + #9 +
      IntToStr(Ord(Exec)));
  finally
    Fv.Free;
    Fp.Free;
  end;
end;

procedure TPsInjectionTests.AddAllSinks(const Id, V: string; Exec: Boolean);
var
  S: string;
begin
  for S in AllSinks do
    AddCase(Id, S, V, False, Exec);
  { the validated entry points users reach: provider, channel, message }
  AddCase(Id, 'provider', V, True, Exec);
  AddCase(Id, 'logname', V, True, Exec);
  AddCase(Id, 'msginc', V, True, Exec);
  AddCase(Id, 'msgexc', V, True, Exec);
end;

procedure TPsInjectionTests.RunChecker;
var
  Shell, Exe, OutFile, L, Msg: string;
  P: TProcess;
  R: TStringList;
  Fails, Shown: Integer;
begin
  FCases.LineBreak := #13#10;
  WriteBytes(FDir + 'cases.tsv', FCases.Text);
  AssertEquals('rejected without a visible reason: ' + FRejectNoReason.CommaText,
    0, FRejectNoReason.Count);
  Msg := '';
  Fails := 0;
  for Shell in ShellNames do
  begin
    Exe := ShellPath(Shell);
    if Exe = '' then
    begin
      Inc(Fails);
      Msg := Msg + ' [' + Shell + ' not installed: PowerShell 7 is required]';
      Continue;
    end;
    OutFile := FDir + 'result-' + Shell + '.txt';
    DeleteFile(OutFile);
    P := TProcess.Create(nil);
    try
      P.Executable := Exe;
      P.Parameters.Add('-NoProfile');
      P.Parameters.Add('-NonInteractive');
      P.Parameters.Add('-ExecutionPolicy');
      P.Parameters.Add('Bypass');
      P.Parameters.Add('-File');
      P.Parameters.Add(RepoDir + 'tests\ps\Test-GeneratedPs.ps1');
      P.Parameters.Add('-CaseDir');
      P.Parameters.Add(ExcludeTrailingPathDelimiter(FDir));
      P.Parameters.Add('-Out');
      P.Parameters.Add(OutFile);
      P.ShowWindow := swoHide;
      P.Options := [poWaitOnExit];
      P.Execute;
    finally
      P.Free;
    end;
    if not FileExists(OutFile) then
    begin
      Inc(Fails);
      Msg := Msg + ' [' + Shell + ': checker wrote no result]';
      Continue;
    end;
    R := TStringList.Create;
    try
      R.LoadFromFile(OutFile);
      Shown := 0;
      for L in R do
      begin
        if Copy(L, 1, 6) = 'PWNED ' then
          WriteLn('    ', Shell, ': ', L);
        if Copy(L, 1, 8) = 'SUMMARY ' then
          WriteLn('    ', Shell, ': ', L);
        if Copy(L, 1, 5) = 'FAIL ' then
        begin
          Inc(Fails);
          if Shown < 6 then
          begin
            Msg := Msg + ' [' + Shell + ': ' + L + ']';
            Inc(Shown);
          end;
        end;
      end;
      if (R.Count = 0) or (Copy(R[R.Count - 1], 1, 8) <> 'SUMMARY ') then
      begin
        Inc(Fails);
        Msg := Msg + ' [' + Shell + ': no SUMMARY line]';
      end;
    finally
      R.Free;
    end;
  end;
  AssertTrue(IntToStr(Fails) + ' failing check(s) over ' + IntToStr(FCases.Count) +
    ' case(s), folder ' + FDir + ':' + Msg, Fails = 0);
end;

procedure TPsInjectionTests.Repro_UnicodeSingleQuoteBreakout;
begin
  StartSet('repro');
  { the filter from the report: channel, provider and message Include each
    carry a Unicode single quote breakout }
  AddCase('repro-fh-2019', 'repro', BreakFH(Q2019), True, True);
  AddCase('repro-fh-2019', 'repro', BreakFH(Q2019), False, True);
  AddCase('repro-fh-2019', 'provider', BreakFH(Q2019), True, True);
  AddCase('repro-fh-2019', 'logname', BreakFH(Q2019), True, True);
  AddCase('repro-text-2019', 'msginc', BreakText1(Q2019), True, True);
  AddCase('repro-text-2018', 'msginc', BreakText2(Q2018), True, True);
  RunChecker;
end;

procedure TPsInjectionTests.PsQuoteDoublesEveryPowerShellSingleQuote;
var
  I: Integer;
begin
  for I := 0 to High(SingleQuotes) do
  begin
    AssertEquals('U+' + SingleNames[I] + ' doubled', '''a' + SingleQuotes[I] +
      SingleQuotes[I] + 'b''', PsQuote('a' + SingleQuotes[I] + 'b'));
    AssertEquals('U+' + SingleNames[I] + ' whole value', '''' + SingleQuotes[I] +
      SingleQuotes[I] + '''', PsQuote(SingleQuotes[I]));
  end;
  AssertEquals('mixed', '''' + Q2018 + Q2018 + Q27 + Q27 + Q201B + Q201B + '''',
    PsQuote(Q2018 + Q27 + Q201B));
  { double quotes and dashes are not special inside a single-quoted literal }
  AssertEquals('''' + D201C + H2014 + '''', PsQuote(D201C + H2014));
end;

procedure TPsInjectionTests.Variant1_SingleQuoteForms;
var
  I: Integer;
  Q, N, Mixed: string;
begin
  StartSet('v1');
  Mixed := '';
  for I := 0 to High(SingleQuotes) do
  begin
    Q := SingleQuotes[I];
    N := 'v1-' + SingleNames[I];
    Mixed := Mixed + Q;
    AddAllSinks(N + '-alone', Q, False);
    AddAllSinks(N + '-doubled', Q + Q, False);
    AddAllSinks(N + '-start', Q + 'abc', False);
    AddAllSinks(N + '-end', 'abc' + Q, False);
    AddAllSinks(N + '-middle', 'ab' + Q + 'cd', False);
    AddAllSinks(N + '-breakfh', BreakFH(Q), False);
    AddAllSinks(N + '-breaktext1', BreakText1(Q), False);
    AddAllSinks(N + '-breaktext2', BreakText2(Q), False);
    AddAllSinks(N + '-breaktext3', BreakText3(Q), False);
  end;
  AddAllSinks('v1-mixed', Mixed, False);
  AddAllSinks('v1-mixed-break', 'x' + Q2018 + Q201B + ' }; Write-Output PWNED; @{ a=' + Q201A + Q2019, False);
  RunChecker;
end;

procedure TPsInjectionTests.Variant2_DoubleQuoteForms;
var
  I, J: Integer;
begin
  StartSet('v2');
  for I := 0 to High(DoubleQuotes) do
  begin
    AddAllSinks('v2-' + DoubleNames[I] + '-alone', 'a' + DoubleQuotes[I] + 'b', False);
    for J := 0 to High(SingleQuotes) do
      AddAllSinks('v2-' + DoubleNames[I] + '-' + SingleNames[J],
        'x' + DoubleQuotes[I] + SingleQuotes[J] + ' }; Write-Output PWNED; @{ a=' +
        SingleQuotes[J] + DoubleQuotes[I], False);
  end;
  RunChecker;
end;

procedure TPsInjectionTests.Variant3_DashLookalikesWithBreakout;
var
  I: Integer;
  Dh: string;
begin
  StartSet('v3');
  for I := 0 to High(Dashes) do
  begin
    Dh := Dashes[I];
    AddAllSinks('v3-' + DashNames[I] + '-param',
      'x' + Q2019 + ' }; Write-Output ' + Dh + 'InputObject PWNED; @{ a=' + Q2019, False);
    AddAllSinks('v3-' + DashNames[I] + '-operator',
      'x' + Q2019 + ' }; if (1 ' + Dh + 'eq 1) { Write-Output PWNED }; @{ a=' + Q2019, False);
    AddAllSinks('v3-' + DashNames[I] + '-text',
      'x' + Q201B + ', 0) ' + Dh + 'ge 0 }; Write-Output ' + Dh + 'InputObject PWNED; & { @(' + Q201B, False);
  end;
  RunChecker;
end;

procedure TPsInjectionTests.Variant4_HereStringForms;
var
  Forms: TStringList;
  Q: string;
  I, J: Integer;
begin
  StartSet('v4');
  Forms := TStringList.Create;
  try
    for Q in SingleQuotes do
    begin
      Forms.Add(Q + '@');
      Forms.Add('@' + Q);
    end;
    for Q in DoubleQuotes do
    begin
      Forms.Add(Q + '@');
      Forms.Add('@' + Q);
    end;
    for I := 0 to Forms.Count - 1 do
    begin
      { whole value: validation on must reject it with a reason, validation
        off must still compile to one literal }
      AddAllSinks('v4-form' + IntToStr(I) + '-whole', Forms[I], False);
      for J := 0 to High(Seps) do
        AddAllSinks('v4-form' + IntToStr(I) + '-' + SepNames[J],
          'a' + Seps[J] + Forms[I] + Seps[J] + 'Write-Output PWNED' + Seps[J] +
          Forms[I] + Seps[J] + 'b', False);
    end;
  finally
    Forms.Free;
  end;
  RunChecker;
end;

procedure TPsInjectionTests.Variant5_OtherLineBreaks;
var
  I: Integer;
begin
  StartSet('v5');
  for I := 0 to High(OtherBreaks) do
  begin
    AddAllSinks('v5-' + OtherBreakNames[I] + '-inside', 'a' + OtherBreaks[I] + 'b', False);
    AddAllSinks('v5-' + OtherBreakNames[I] + '-payload',
      'a' + OtherBreaks[I] + 'Write-Output PWNED' + OtherBreaks[I] + 'b', False);
    AddAllSinks('v5-' + OtherBreakNames[I] + '-break',
      'x' + Q2019 + OtherBreaks[I] + 'Write-Output PWNED' + OtherBreaks[I] + '@{ a=' + Q2019, False);
  end;
  RunChecker;
end;

procedure TPsInjectionTests.Variant6_EverySink;
var
  Q: string;
  I: Integer;
begin
  StartSet('v6');
  { every sink with every breakout shape, Unicode and ASCII quotes, both
    validation modes (user / perpath / path only reach the compiler
    unvalidated through a caller that skips validation) }
  for I := 0 to High(SingleQuotes) do
  begin
    Q := SingleQuotes[I];
    AddAllSinks('v6-' + SingleNames[I] + '-fh', BreakFH(Q), False);
    AddAllSinks('v6-' + SingleNames[I] + '-t1', BreakText1(Q), False);
    AddAllSinks('v6-' + SingleNames[I] + '-t2', BreakText2(Q), False);
    AddAllSinks('v6-' + SingleNames[I] + '-t3', BreakText3(Q), False);
    AddCase('v6-' + SingleNames[I] + '-sid', 'user', 'S-1-5-18' + Q + ' }; Write-Output PWNED; @{ a=' + Q, True, False);
    AddCase('v6-' + SingleNames[I] + '-path', 'path', BreakFH(Q), True, False);
    AddCase('v6-' + SingleNames[I] + '-perpath', 'perpath', BreakText2(Q), True, False);
  end;
  RunChecker;
end;

procedure TPsInjectionTests.Variant8_ShellsAndDeliveryForms;
var
  S: string;
begin
  StartSet('v8');
  { new processes: one-liner via -Command and export via -File, in
    powershell.exe 5.1 and pwsh.exe 7, for each sink }
  for S in AllSinks do
  begin
    AddCase('v8-fh-2019', S, BreakFH(Q2019), False, True);
    AddCase('v8-t1-2018', S, BreakText1(Q2018), False, True);
    AddCase('v8-t2-201A', S, BreakText2(Q201A), False, True);
    AddCase('v8-t3-201B', S, BreakText3(Q201B), False, True);
  end;
  AddCase('v8-fh-2019', 'provider', BreakFH(Q2019), True, True);
  AddCase('v8-t1-2019', 'msginc', BreakText1(Q2019), True, True);
  AddCase('v8-t3-2019', 'msgexc', BreakText3(Q2019), True, True);
  RunChecker;
end;

procedure TPsInjectionTests.Regression_ApostropheValuesStillWork;
begin
  StartSet('regress');
  AddCase('reg-obrien', 'provider', 'O''Brien-Svc', True, True);
  AddCase('reg-cant', 'msginc', 'can''t connect', True, True);
  AddCase('reg-cant', 'msgexc', 'can''t connect', True, True);
  AddCase('reg-cant', 'perpath', 'can''t connect', True, True);
  AddCase('reg-dq', 'msginc', 'say "hi"', True, True);
  AddCase('reg-plain', 'provider', 'Service Control Manager', True, True);
  AddCase('reg-plain', 'logname', 'Microsoft-Windows-Kernel-Power/Thermal-Operational', True, True);
  RunChecker;
end;

procedure TPsInjectionTests.ExportFileIsUtf8WithBom;
var
  P, Script, Data, Src: string;
  Fs: TFileStream;
  F: TSiftFilter;
begin
  F := TSiftFilter.Create;
  try
    F.Channels.Add('System');
    F.AddTerm(MakeTerm(sfMessage, saInclude, 'can' + Q2019 + 't'));
    Script := CompilePowerShell(F, nil);
  finally
    F.Free;
  end;
  P := ScratchDir + 'bom-' + IntToStr(GetProcessID) + '.ps1';
  SavePowerShellExport(P, Script);
  Fs := TFileStream.Create(P, fmOpenRead);
  try
    SetLength(Data, Fs.Size);
    if Fs.Size > 0 then
      Fs.ReadBuffer(Data[1], Fs.Size);
  finally
    Fs.Free;
  end;
  DeleteFile(P);
  AssertTrue('starts with EF BB BF', Copy(Data, 1, 3) = #$EF#$BB#$BF);
  AssertEquals('then the script bytes and CRLF', Script + #13#10, Copy(Data, 4, MaxInt));
  { Export as PowerShell in the viewer goes through the same function }
  with TStringList.Create do
  try
    LoadFromFile(RepoDir + 'src\app\sift.mainform.pas');
    Src := Text;
  finally
    Free;
  end;
  AssertTrue('mainform saves the export with SavePowerShellExport',
    Pos('SavePowerShellExport(D.FileName, CompilePowerShell(', Src) > 0);
end;

initialization
  RegisterTest(TCompilerGoldenTests);
  RegisterTest(TPsInjectionTests);
end.
