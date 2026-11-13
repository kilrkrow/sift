unit Test.Compiler;

{ Piece 1 critic: golden tests. Filter -> expected structured query text,
  -> expected Get-WinEvent -FilterHashtable one-liner, and -> PowerShell
  export. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Sift.Filter, Sift.Compiler;

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
    procedure RecordQuery;
  end;

implementation

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
begin
  F.Channels.Add('Application');
  F.AddTerm(MakeTerm(sfProvider, saInclude, 'Bob''s & <Co>'));
  AssertEquals('    <Select Path="Application">*[System[(Provider[@Name=&quot;Bob''s &amp; &lt;Co&gt;&quot;])]]</Select>',
    CompileFilter(F, nil).QueryXml.Split([#13#10])[2]);
  F.ClearTerms;
  F.AddTerm(MakeTerm(sfProvider, saInclude, 'Service Control Manager'));
  AssertEquals('    <Select Path="Application">*[System[(Provider[@Name=''Service Control Manager''])]]</Select>',
    CompileFilter(F, nil).QueryXml.Split([#13#10])[2]);
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
  AssertEquals('$siftQuery = @''', L[3]);
  AssertEquals('<QueryList>', L[4]);
  AssertEquals('''@', L[10]);
  AssertEquals('$siftEvents = @(Get-WinEvent -FilterXml $siftQuery -MaxEvents 40 -ErrorAction SilentlyContinue -ErrorVariable +siftErrors -WarningAction SilentlyContinue)', L[11]);
  AssertTrue('no &&', Pos('&&', S) = 0);
  AssertTrue('no SuppressHashFilter', Pos('SuppressHashFilter', S) = 0);
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

initialization
  RegisterTest(TCompilerGoldenTests);
end.
