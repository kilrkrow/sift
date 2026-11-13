unit Test.PubMeta;

{ Piece 9: offline Event ID lookup. Sift's provider-metadata reader against
  `(Get-WinEvent -ListProvider <p>).Events` (Windows PowerShell 5.1, .NET's
  ProviderMetadata) for several providers, the missing-provider path, the
  per-session cache and the "Look up online" URL. .NET keeps the qualifiers
  in EventMetadata.Id (Service Control Manager 7036 is 1073748860), so the
  oracle matches on the low 16 bits, as Sift does. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, fpcunit, testregistry, Sift.EvtApi, Sift.PubMeta;

type
  TPubMetaTests = class(TTestCase)
  private
    function SiftLines(const Provider: string; Id: Word): TStringList;
    procedure Compare(const Pairs: array of string);
  published
    procedure SystemProvidersMatchGetWinEvent;
    procedure ApplicationProviderMatchesGetWinEvent;
    procedure NonAsciiTemplatesMatchGetWinEvent;
    procedure MissingProvider;
    procedure CachedPerSession;
    procedure FindPrefersQualifiersAndVersion;
    procedure LookupUrlEncoding;
    procedure LookupUrlTemplateRejectsUnsafe;
    procedure UnavailableMetaIsExactText;
    procedure DetailTextAsciiLabels;
  end;

implementation

uses
  Test.Util;

function Esc(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, #13, '\r', [rfReplaceAll]), #10, '\n', [rfReplaceAll]);
end;

function MetaLine(const P: string; const M: TSiftEventMeta): string;
var
  K: string;
  I: Integer;
begin
  K := '';
  for I := 0 to High(M.KeywordList) do
  begin
    if I > 0 then
      K := K + ';';
    K := K + IntToHex(M.KeywordList[I].Value, 1) + '=' + M.KeywordList[I].Name + '/' +
      M.KeywordList[I].Display;
  end;
  Result := Esc(P) + '|' + IntToStr(M.Id) + '|' + IntToStr(M.Version) + '|' +
    IntToStr(M.Level) + '|' + Esc(M.LevelName) + '|' + Esc(M.LevelDisplay) + '|' +
    IntToStr(M.Task) + '|' + Esc(M.TaskName) + '|' + Esc(M.TaskDisplay) + '|' +
    IntToStr(M.Opcode) + '|' + Esc(M.OpcodeName) + '|' + Esc(M.OpcodeDisplay) + '|' +
    Esc(K) + '|' + Esc(M.Description) + '|' + Esc(M.Template);
end;

function TPubMetaTests.SiftLines(const Provider: string; Id: Word): TStringList;
var
  C: TSiftMetaCache;
  P: TSiftProviderMeta;
  Ms: TSiftEventMetas;
  I: Integer;
begin
  Result := TStringList.Create;
  C := TSiftMetaCache.Create;
  try
    P := C.Get(Provider);
    AssertTrue(Provider + ' metadata available', P.Available);
    Ms := P.Matches(Id);
    for I := 0 to High(Ms) do
      Result.Add(MetaLine(Provider, Ms[I]));
  finally
    C.Free;
  end;
end;

procedure TPubMetaTests.Compare(const Pairs: array of string);
var
  Script, Plist: string;
  I, K: Integer;
  Ps, A, One: TStringList;
begin
  Plist := '';
  I := 0;
  while I < High(Pairs) do
  begin
    if Plist <> '' then
      Plist := Plist + ',';
    Plist := Plist + '@(' + PsPath(Pairs[I]) + ',' + Pairs[I + 1] + ')';
    Inc(I, 2);
  end;
  Script :=
    'function E($s) { if ($null -eq $s) { '''' } else { ([string]$s).Replace("`r", ''\r'').Replace("`n", ''\n'') } }' + LineEnding +
    '$lines = New-Object System.Collections.Generic.List[string]' + LineEnding +
    'foreach ($pair in @(' + Plist + ')) {' + LineEnding +
    '  $p = $pair[0]; $id = [int]$pair[1]' + LineEnding +
    '  $evs = @((Get-WinEvent -ListProvider $p -ErrorAction Stop).Events | Where-Object { ($_.Id -band 0xFFFF) -eq $id })' + LineEnding +
    '  foreach ($e in $evs) {' + LineEnding +
    '    $kw = @($e.Keywords | ForEach-Object { (''{0:X}'' -f $_.Value) + ''='' + $_.Name + ''/'' + $_.DisplayName }) -join '';''' + LineEnding +
    '    $f = @((E $p), $e.Id, $e.Version, $e.Level.Value, (E $e.Level.Name), (E $e.Level.DisplayName), $e.Task.Value, (E $e.Task.Name), (E $e.Task.DisplayName), $e.Opcode.Value, (E $e.Opcode.Name), (E $e.Opcode.DisplayName), (E $kw), (E $e.Description), (E $e.Template))' + LineEnding +
    '    $lines.Add(($f -join ''|''))' + LineEnding +
    '  }' + LineEnding +
    '}' + LineEnding +
    '[IO.File]::WriteAllLines($SiftOut, $lines, (New-Object System.Text.UTF8Encoding($false)))';
  Ps := TStringList.Create;
  A := TStringList.Create;
  try
    RunPs(Script, Ps);
    I := 0;
    while I < High(Pairs) do
    begin
      One := SiftLines(Pairs[I], StrToInt(Pairs[I + 1]));
      try
        AssertTrue(Pairs[I] + ' ' + Pairs[I + 1] + ': Sift found the event', One.Count > 0);
        A.AddStrings(One);
      finally
        One.Free;
      end;
      Inc(I, 2);
    end;
    AssertEquals('entries (Get-WinEvent: ' + Ps.Text + ')', Ps.Count, A.Count);
    for K := 0 to A.Count - 1 do
      AssertEquals('entry ' + IntToStr(K), Ps[K], A[K]);
  finally
    Ps.Free;
    A.Free;
  end;
end;

procedure TPubMetaTests.SystemProvidersMatchGetWinEvent;
begin
  Compare(['Service Control Manager', '7036', 'Service Control Manager', '7040',
    'Microsoft-Windows-Kernel-General', '12', 'Microsoft-Windows-Kernel-General', '13']);
end;

procedure TPubMetaTests.ApplicationProviderMatchesGetWinEvent;
begin
  Compare(['Microsoft-Windows-RestartManager', '10000',
    'Microsoft-Windows-RestartManager', '10001']);
end;

procedure TPubMetaTests.NonAsciiTemplatesMatchGetWinEvent;
var
  L: TStringList;
begin
  { U+2019 and U+00AE in the description templates }
  Compare(['Microsoft-Windows-Bits-Client', '16401', 'Microsoft-Windows-DirectShow-Core', '1']);
  L := SiftLines('Microsoft-Windows-DirectShow-Core', 1);
  try
    AssertTrue('registered sign kept as UTF-8: ' + L.Text, Pos(#$C2#$AE, L.Text) > 0);
  finally
    L.Free;
  end;
end;

procedure TPubMetaTests.MissingProvider;
var
  C: TSiftMetaCache;
  P: TSiftProviderMeta;
  Ps: TStringList;
begin
  Ps := TStringList.Create;
  C := TSiftMetaCache.Create;
  try
    RunPs('try { Get-WinEvent -ListProvider ''Sift-NoSuchProvider-7f3a'' -ErrorAction Stop | Out-Null; ''found'' | Set-Content $SiftOut } catch { ''missing'' | Set-Content $SiftOut }', Ps);
    AssertEquals('Get-WinEvent also has no such provider', 'missing', Trim(Ps.Text));
    P := C.Get('Sift-NoSuchProvider-7f3a');
    AssertFalse(P.Available);
    AssertEquals(0, Length(P.Matches(1)));
    AssertTrue(P.Find(1, -1, -1) = nil);
    AssertEquals(MetaNotAvailableText, FormatEventMeta('Sift-NoSuchProvider-7f3a',
      P.Find(1, -1, -1), P, 1));
    AssertEquals(MetaNotAvailableText, FormatEventMeta('x', nil, nil, 1));
  finally
    C.Free;
    Ps.Free;
  end;
end;

procedure TPubMetaTests.CachedPerSession;
var
  C: TSiftMetaCache;
  A, B: TSiftProviderMeta;
begin
  C := TSiftMetaCache.Create;
  try
    A := C.Get('Service Control Manager');
    B := C.Get('service control manager');
    AssertTrue('same object', A = B);
    C.Get('Sift-NoSuchProvider-7f3a');
    C.Get('Sift-NoSuchProvider-7f3a');
    AssertEquals('each provider read once (failures cached too)', 2, C.Loads);
  finally
    C.Free;
  end;
end;

procedure TPubMetaTests.FindPrefersQualifiersAndVersion;
var
  P: TSiftProviderMeta;
  M: PSiftEventMeta;
begin
  P := TSiftProviderMeta.Create;
  try
    P.Available := True;
    SetLength(P.Events, 3);
    P.Events[0].Id := $C0001B7C; P.Events[0].Version := 0;
    P.Events[1].Id := $40001B7C; P.Events[1].Version := 0;
    P.Events[2].Id := $40001B7C; P.Events[2].Version := 1;
    AssertEquals(3, Length(P.Matches(7036)));
    M := P.Find(7036, $4000, 1);
    AssertTrue(M = @P.Events[2]);
    M := P.Find(7036, $4000, -1);
    AssertTrue(M = @P.Events[1]);
    M := P.Find(7036, -1, -1);
    AssertTrue(M = @P.Events[0]);
    AssertTrue(P.Find(7037, -1, -1) = nil);
  finally
    P.Free;
  end;
end;

procedure TPubMetaTests.LookupUrlEncoding;
begin
  AssertEquals('https://www.google.com/search?q=%22Service%20Control%20Manager%22%20event%20ID%207036',
    LookupUrl('Service Control Manager', 7036));
  AssertEquals('%22Pr%C3%BCf%26x%22%20event%20ID%201', UrlEncodeUtf8(LookupQuery('Pr'#$C3#$BC'f&x', 1)));
  AssertEquals('https://duckduckgo.com/?q=%22a%22%20event%20ID%202',
    LookupUrl('a', 2, 'https://duckduckgo.com/?q=%s'));
  { only https search URLs are accepted from settings }
  AssertEquals(LookupUrl('a', 2), LookupUrl('a', 2, 'file:///c:/x?%s'));
  AssertEquals(LookupUrl('a', 2), LookupUrl('a', 2, 'https://example.com/'));
end;

procedure TPubMetaTests.DetailTextAsciiLabels;
var
  C: TSiftMetaCache;
  P: TSiftProviderMeta;
  S: string;
  I: Integer;
begin
  C := TSiftMetaCache.Create;
  try
    P := C.Get('Microsoft-Windows-Kernel-General');
    S := FormatEventMeta(P.Provider, P.Find(12, -1, -1), P, 12);
    AssertTrue(S, Pos('Level: Information (4)', S) > 0);
    AssertTrue(S, Pos('Task: SystemStart (1)', S) > 0);
    AssertTrue(S, Pos('Opcode: Info (0)', S) > 0);
    AssertTrue(S, Pos('BootPerformance', S) > 0);
    AssertTrue(S, Pos('The operating system started at system time %7.', S) > 0);
    for I := 1 to Length(S) do
      AssertTrue('ASCII at ' + IntToStr(I), Ord(S[I]) < 128);
  finally
    C.Free;
  end;
end;

procedure TPubMetaTests.LookupUrlTemplateRejectsUnsafe;
const
  Good: array[0..3] of string = ('https://www.google.com/search?q=%s',
    'https://duckduckgo.com/?q=%s&ia=web', 'https://www.bing.com/search?q=%s&setlang=en-US',
    'https://example.org/find?q=%s&x=%20');
  Bad: array[0..14] of string = ('https://www.google.com/search?q=%s extra',
    'https://www.google.com/search?q="%s"', 'https://www.google.com/search?q=''%s''',
    'https://www.google.com/search?q=<%s>', 'https://www.google.com\search?q=%s',
    'https://www.google.com/search?q=%s|calc', 'https://www.google.com/search?q=%s^',
    'https://www.google.com/search?q=%s`x`', 'https://www.goo' + #$C3#$A9 + 'gle.com/?q=%s',
    'http://www.google.com/search?q=%s', 'https://www.google.com/search?q=',
    'https://www.google.com/?a=%s&b=%s', 'https://www.google.com/?a=%zz&q=%s',
    'https:///search?q=%s', 'https://www.google.com/search?q=%s' + #9);
var
  I: Integer;
begin
  for I := 0 to High(Good) do
    AssertTrue('accepted: ' + Good[I], LookupUrlTemplateOk(Good[I]));
  for I := 0 to High(Bad) do
  begin
    AssertFalse('rejected: ' + Bad[I], LookupUrlTemplateOk(Bad[I]));
    { a rejected template falls back to the default search }
    AssertEquals(LookupUrl('Service Control Manager', 7036),
      LookupUrl('Service Control Manager', 7036, Bad[I]));
  end;
end;

procedure TPubMetaTests.UnavailableMetaIsExactText;
var
  M: TSiftProviderMeta;
begin
  { what the pane shows when EvtOpenPublisherMetadata or
    EvtOpenEventMetadataEnum fails (Available = False) }
  M := TSiftProviderMeta.Create;
  try
    M.Provider := 'Some-Classic-Provider';
    M.Available := False;
    M.ErrorCode := 15002;
    AssertEquals('Provider metadata not available on this machine',
      FormatEventMeta('Some-Classic-Provider', nil, M, 1));
  finally
    M.Free;
  end;
end;

initialization
  RegisterTest(TPubMetaTests);
end.
