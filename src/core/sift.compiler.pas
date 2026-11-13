unit Sift.Compiler;

{ Compiles a TSiftFilter to what the event log service runs:
  - a structured XML query (<QueryList>), Include -> Select, Exclude -> Suppress
  - the equivalent Get-WinEvent -FilterHashtable one-liner when one exists
  - a PowerShell 5.1 export (Get-WinEvent -FilterXml); the query XML is a Base64 blob, not a here-string
  Event Log XPath is a subset of XPath 1.0: no contains()/starts-with(), and
  at most 20 sub-expressions per expression, so large OR groups are split
  across several Select elements (Selects in one Query are a union). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Sift.Filter;

const
  MaxSubExpressions = 20;

type
  TSiftCompiled = record
    Channels: TStringArray;     { resolved channel / file:// paths }
    QueryXml: string;           { structured query }
    SelectCount: Integer;
    SuppressCount: Integer;
    FilterHashtable: string;    { '' when not expressible }
    FilterHashtableNote: string;{ why not, when FilterHashtable = '' }
    ClientText: Boolean;        { message-text terms are matched client-side }
    LastN: Integer;
  end;

function CompileFilter(F: TSiftFilter; AllChannels: TStrings): TSiftCompiled;
function CompilePowerShell(F: TSiftFilter; AllChannels: TStrings): string;
{ One assignment: $Name = UTF8.GetString(FromBase64String(...)). No here-string. }
function PsAssignQuery(const VarName, QueryXml: string): string;

{ Helpers, exposed for tests }
function XmlEscape(const S: string): string;
function XPathLiteral(const S: string): string;
function SystemXPath(F: TSiftFilter): string;
function PsQuote(const S: string): string;
function KeywordDecimal(const Hex: string): string;

{ Builds the record-id lookup query for the detail pane. }
function RecordQueryXml(const Channel: string; RecordId: Int64): string;

implementation

uses
  base64;

type
  TGroup = record
    Field: TSiftField;
    Values: TStringArray;
  end;
  TGroupArray = array of TGroup;
  TGroupSets = array of TGroupArray;

function XmlEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else
      Result := Result + S[I];
    end;
end;

function XPathLiteral(const S: string): string;
begin
  if Pos('''', S) = 0 then
    Result := '''' + S + ''''
  else
    Result := '"' + S + '"';
end;

function PsQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function KeywordDecimal(const Hex: string): string;
var
  Q: QWord;
begin
  if (Length(Hex) > 2) and (Hex[1] = '0') and (Hex[2] in ['x', 'X']) then
    Q := StrToQWord('$' + Copy(Hex, 3, MaxInt))
  else
    Q := StrToQWord(Hex);
  Result := IntToStr(Q);
end;

function ValueCost(Field: TSiftField; const V: string): Integer;
begin
  if (Field = sfLevel) and (V = '4') then
    Result := 2
  else
    Result := 1;
end;

function TermXPath(Field: TSiftField; const V: string): string;
begin
  case Field of
    sfLevel:
      if V = '4' then
        Result := 'Level=4 or Level=0'
      else
        Result := 'Level=' + V;
    sfProvider: Result := 'Provider[@Name=' + XPathLiteral(V) + ']';
    sfEventId: Result := 'EventID=' + V;
    sfTask: Result := 'Task=' + V;
    sfKeywords: Result := 'band(Keywords,' + KeywordDecimal(V) + ')';
    sfUser: Result := 'Security[@UserID=' + XPathLiteral(V) + ']';
    sfComputer: Result := 'Computer=' + XPathLiteral(V);
    sfTime: Result := 'TimeCreated[@SystemTime>=' + XPathLiteral(V) + ']';
  else
    Result := '';
  end;
end;

function GroupXPath(const G: TGroup): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(G.Values) do
  begin
    if I > 0 then
      Result := Result + ' or ';
    Result := Result + TermXPath(G.Field, G.Values[I]);
  end;
  Result := '(' + Result + ')';
end;

function GroupCost(const G: TGroup): Integer;
var
  V: string;
begin
  Result := 0;
  for V in G.Values do
    Inc(Result, ValueCost(G.Field, V));
end;

function TimeXPath(F: TSiftFilter; out Cost: Integer): string;
begin
  Result := '';
  Cost := 0;
  case F.TimeMode of
    tmRelative:
      begin
        Result := 'TimeCreated[timediff(@SystemTime) <= ' + IntToStr(F.RelativeMs) + ']';
        Cost := 1;
      end;
    tmAbsolute:
      begin
        if F.StartUtc <> 0 then
        begin
          Result := '@SystemTime>=' + XPathLiteral(UtcToIso(F.StartUtc));
          Cost := 1;
        end;
        if F.EndUtc <> 0 then
        begin
          if Result <> '' then
            Result := Result + ' and ';
          Result := Result + '@SystemTime<=' + XPathLiteral(UtcToIso(F.EndUtc));
          Inc(Cost);
        end;
        if Result <> '' then
          Result := 'TimeCreated[' + Result + ']';
      end;
  end;
end;

const
  XPathFields: array[0..7] of TSiftField = (sfProvider, sfEventId, sfLevel,
    sfTask, sfKeywords, sfUser, sfComputer, sfTime);

function IncludeGroups(F: TSiftFilter): TGroupArray;
var
  I, N: Integer;
  V: TStringArray;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(XPathFields) do
  begin
    V := F.TermsFor(XPathFields[I], saInclude);
    if Length(V) = 0 then
      Continue;
    SetLength(Result, N + 1);
    Result[N].Field := XPathFields[I];
    Result[N].Values := V;
    Inc(N);
  end;
end;

function SetCost(const Gs: TGroupArray): Integer;
var
  G: TGroup;
begin
  Result := 0;
  for G in Gs do
    Inc(Result, GroupCost(G));
end;

function ExpandGroups(const Gs: TGroupArray; Budget: Integer): TGroupSets;
var
  Big, I, Half, K: Integer;
  A, B: TGroupArray;
  RA, RB: TGroupSets;
begin
  if (SetCost(Gs) <= Budget) then
  begin
    SetLength(Result, 1);
    Result[0] := Gs;
    Exit;
  end;
  Big := -1;
  for I := 0 to High(Gs) do
    if (Length(Gs[I].Values) > 1) and
       ((Big < 0) or (GroupCost(Gs[I]) > GroupCost(Gs[Big]))) then
      Big := I;
  if Big < 0 then
  begin
    { cannot split further; emit as is }
    SetLength(Result, 1);
    Result[0] := Gs;
    Exit;
  end;
  Half := Length(Gs[Big].Values) div 2;
  A := Copy(Gs);
  B := Copy(Gs);
  A[Big].Values := Copy(Gs[Big].Values, 0, Half);
  B[Big].Values := Copy(Gs[Big].Values, Half, MaxInt);
  RA := ExpandGroups(A, Budget);
  RB := ExpandGroups(B, Budget);
  SetLength(Result, Length(RA) + Length(RB));
  for K := 0 to High(RA) do
    Result[K] := RA[K];
  for K := 0 to High(RB) do
    Result[Length(RA) + K] := RB[K];
end;

function BuildSystemPredicate(const Gs: TGroupArray; const TimeExpr: string): string;
var
  G: TGroup;
begin
  Result := '';
  for G in Gs do
  begin
    if Result <> '' then
      Result := Result + ' and ';
    Result := Result + GroupXPath(G);
  end;
  if TimeExpr <> '' then
  begin
    if Result <> '' then
      Result := Result + ' and ';
    Result := Result + TimeExpr;
  end;
  if Result = '' then
    Result := '*'
  else
    Result := '*[System[' + Result + ']]';
end;

function SystemXPath(F: TSiftFilter): string;
var
  TC: Integer;
begin
  Result := BuildSystemPredicate(IncludeGroups(F), TimeXPath(F, TC));
end;

function RecordQueryXml(const Channel: string; RecordId: Int64): string;
var
  P: string;
begin
  P := XmlEscape(Channel);
  Result := '<QueryList><Query Id="0" Path="' + P + '"><Select Path="' + P +
    '">*[System[EventRecordID=' + IntToStr(RecordId) + ']]</Select></Query></QueryList>';
end;

function IsFilePath(const C: string): Boolean;
begin
  Result := SameText(Copy(C, 1, 7), 'file://');
end;

function FilePathOf(const C: string): string;
begin
  Result := Copy(C, 8, MaxInt);
end;

function RelativeStartPs(Ms: Int64): string;
begin
  if (Ms mod 3600000) = 0 then
    Result := '(Get-Date).AddHours(-' + IntToStr(Ms div 3600000) + ')'
  else if (Ms mod 60000) = 0 then
    Result := '(Get-Date).AddMinutes(-' + IntToStr(Ms div 60000) + ')'
  else if (Ms mod 1000) = 0 then
    Result := '(Get-Date).AddSeconds(-' + IntToStr(Ms div 1000) + ')'
  else
    Result := '(Get-Date).AddMilliseconds(-' + IntToStr(Ms) + ')';
end;

function PsList(const V: TStringArray; Quote: Boolean): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(V) do
  begin
    if I > 0 then
      Result := Result + ',';
    if Quote then
      Result := Result + PsQuote(V[I])
    else
      Result := Result + V[I];
  end;
end;

function LevelPsList(const V: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(V) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + V[I];
    if V[I] = '4' then
      Result := Result + ',0';
  end;
end;

function TextWhere(const Term: string; Include: Boolean): string;
var
  Cond: string;
begin
  Cond := '$_.Message -ne $null -and $_.Message.IndexOf(' + PsQuote(Term) +
    ', [StringComparison]::OrdinalIgnoreCase) -ge 0';
  if Include then
    Result := 'Where-Object { ' + Cond + ' }'
  else
    Result := 'Where-Object { -not (' + Cond + ') }';
end;

procedure BuildFilterHashtable(F: TSiftFilter; var C: TSiftCompiled);
var
  Parts: string;
  Ch, Files, Logs: TStringArray;
  S: string;
  NL, NF, TC: Integer;
  V: TStringArray;
  T: string;

  procedure Add(const P: string);
  begin
    if Parts <> '' then
      Parts := Parts + '; ';
    Parts := Parts + P;
  end;

  function Fail(const Why: string): Boolean;
  begin
    C.FilterHashtable := '';
    C.FilterHashtableNote := Why;
    Result := True;
  end;

begin
  C.FilterHashtable := '';
  C.FilterHashtableNote := '';
  if F.HasExcludes then
  begin
    Fail('Not expressible: Windows PowerShell 5.1 ignores SuppressHashFilter, so Exclude terms need -FilterXml (use Export as PowerShell).');
    Exit;
  end;
  if (Length(F.TermsFor(sfComputer, saInclude)) > 0) or
     (Length(F.TermsFor(sfTask, saInclude)) > 0) then
  begin
    Fail('Not expressible: FilterHashtable has no Computer or Task key (use -FilterXml).');
    Exit;
  end;
  if (Length(F.TermsFor(sfUser, saInclude)) > 1) or
     (Length(F.TermsFor(sfKeywords, saInclude)) > 1) or
     (Length(F.TermsFor(sfTime, saInclude)) > 0) then
  begin
    Fail('Not expressible as FilterHashtable (several users/keywords or a time term); use -FilterXml.');
    Exit;
  end;
  TimeXPath(F, TC);
  if SetCost(IncludeGroups(F)) + TC > MaxSubExpressions then
  begin
    Fail('Not expressible: more than 20 sub-expressions; use -FilterXml.');
    Exit;
  end;
  Ch := C.Channels;
  if Length(Ch) = 0 then
  begin
    Fail('No channels selected.');
    Exit;
  end;
  if (F.LastN > 0) and (Length(Ch) > 1) then
  begin
    Fail('Not expressible: last-N across several logs is each log''s last N merged by time; -MaxEvents would cut the interleaved stream instead (use Export as PowerShell).');
    Exit;
  end;
  Files := nil;
  Logs := nil;
  NL := 0;
  NF := 0;
  for S in Ch do
    if IsFilePath(S) then
    begin
      SetLength(Files, NF + 1);
      Files[NF] := FilePathOf(S);
      Inc(NF);
    end
    else
    begin
      SetLength(Logs, NL + 1);
      Logs[NL] := S;
      Inc(NL);
    end;
  if (NL > 0) and (NF > 0) then
  begin
    Fail('Not expressible: mixes live channels and .evtx files; use -FilterXml.');
    Exit;
  end;
  Parts := '';
  if NL > 0 then
    Add('LogName=' + PsList(Logs, True))
  else
    Add('Path=' + PsList(Files, True));
  V := F.TermsFor(sfProvider, saInclude);
  if Length(V) > 0 then Add('ProviderName=' + PsList(V, True));
  V := F.TermsFor(sfEventId, saInclude);
  if Length(V) > 0 then Add('Id=' + PsList(V, False));
  V := F.TermsFor(sfLevel, saInclude);
  if Length(V) > 0 then Add('Level=' + LevelPsList(V));
  V := F.TermsFor(sfKeywords, saInclude);
  if Length(V) > 0 then Add('Keywords=' + KeywordDecimal(V[0]));
  V := F.TermsFor(sfUser, saInclude);
  if Length(V) > 0 then Add('UserID=' + PsQuote(V[0]));
  case F.TimeMode of
    tmRelative: Add('StartTime=' + RelativeStartPs(F.RelativeMs));
    tmAbsolute:
      begin
        if F.StartUtc <> 0 then
          Add('StartTime=[datetime]' + PsQuote(UtcToIso(F.StartUtc)));
        if F.EndUtc <> 0 then
          Add('EndTime=[datetime]' + PsQuote(UtcToIso(F.EndUtc)));
      end;
  end;
  S := 'Get-WinEvent -FilterHashtable @{ ' + Parts + ' }';
  if (F.LastN > 0) and not F.HasTextTerms then
    S := S + ' -MaxEvents ' + IntToStr(F.LastN);
  for T in F.TermsFor(sfMessage, saInclude) do
    S := S + ' | ' + TextWhere(T, True);
  for T in F.TermsFor(sfMessage, saExclude) do
    S := S + ' | ' + TextWhere(T, False);
  if (F.LastN > 0) and F.HasTextTerms then
    S := S + ' | Select-Object -First ' + IntToStr(F.LastN);
  C.FilterHashtable := S;
end;

function CompileFilter(F: TSiftFilter; AllChannels: TStrings): TSiftCompiled;
var
  Sb: TStringList;
  Sets: TGroupSets;
  Gs: TGroupArray;
  TimeExpr, Ch, Pred, EscCh: string;
  TC, I: Integer;
  Fld: TSiftField;
  Ex: TStringArray;
  G: TGroup;
  ExSets: TGroupSets;
  One: TGroupArray;
begin
  Result.Channels := F.EffectiveChannels(AllChannels);
  Result.ClientText := F.HasTextTerms;
  Result.LastN := F.LastN;
  Result.SelectCount := 0;
  Result.SuppressCount := 0;
  TimeExpr := TimeXPath(F, TC);
  Gs := IncludeGroups(F);
  Sets := ExpandGroups(Gs, MaxSubExpressions - TC);
  Sb := TStringList.Create;
  try
    Sb.Add('<QueryList>');
    if Length(Result.Channels) > 0 then
      Sb.Add('  <Query Id="0" Path="' + XmlEscape(Result.Channels[0]) + '">')
    else
      Sb.Add('  <Query Id="0">');
    for Ch in Result.Channels do
    begin
      EscCh := XmlEscape(Ch);
      for I := 0 to High(Sets) do
      begin
        Pred := BuildSystemPredicate(Sets[I], TimeExpr);
        Sb.Add('    <Select Path="' + EscCh + '">' + XmlEscape(Pred) + '</Select>');
        Inc(Result.SelectCount);
      end;
    end;
    { Excludes: one Suppress per field group (values OR'd), split at 20. }
    for Fld in XPathFields do
    begin
      Ex := F.TermsFor(Fld, saExclude);
      if Length(Ex) = 0 then
        Continue;
      G.Field := Fld;
      G.Values := Ex;
      SetLength(One, 1);
      One[0] := G;
      ExSets := ExpandGroups(One, MaxSubExpressions);
      for Ch in Result.Channels do
      begin
        EscCh := XmlEscape(Ch);
        for I := 0 to High(ExSets) do
        begin
          Pred := BuildSystemPredicate(ExSets[I], '');
          Sb.Add('    <Suppress Path="' + EscCh + '">' + XmlEscape(Pred) + '</Suppress>');
          Inc(Result.SuppressCount);
        end;
      end;
    end;
    Sb.Add('  </Query>');
    Sb.Add('</QueryList>');
    Sb.LineBreak := #13#10;
    Result.QueryXml := TrimRight(Sb.Text);
  finally
    Sb.Free;
  end;
  BuildFilterHashtable(F, Result);
end;

function PsAssignQuery(const VarName, QueryXml: string): string;
var
  B64: string;
begin
  B64 := EncodeStringBase64(QueryXml);
  B64 := StringReplace(B64, #13, '', [rfReplaceAll]);
  B64 := StringReplace(B64, #10, '', [rfReplaceAll]);
  Result := VarName + ' = [System.Text.Encoding]::UTF8.GetString(' +
    '[System.Convert]::FromBase64String(''' + B64 + '''))';
end;

function CompilePowerShell(F: TSiftFilter; AllChannels: TStrings): string;
var
  C, SubC: TSiftCompiled;
  L: TStringList;
  Ch: string;
  Sub: TSiftFilter;
  I, K: Integer;
  PerPath: Boolean;
  Cmd: string;

  function GetCmd(const VarName: string; WithMax: Boolean): string;
  begin
    Result := '@(Get-WinEvent -FilterXml ' + VarName;
    if WithMax then
      Result := Result + ' -MaxEvents ' + IntToStr(C.LastN);
    Result := Result + ' -ErrorAction SilentlyContinue -ErrorVariable +siftErrors -WarningAction SilentlyContinue)';
  end;

  procedure AddTextFilters(const Target: string);
  var
    T: string;
  begin
    for T in F.TermsFor(sfMessage, saInclude) do
      L.Add(Target + ' = @(' + Target + ' | ' + TextWhere(T, True) + ')');
    for T in F.TermsFor(sfMessage, saExclude) do
      L.Add(Target + ' = @(' + Target + ' | ' + TextWhere(T, False) + ')');
  end;

begin
  C := CompileFilter(F, AllChannels);
  PerPath := (C.LastN > 0) and (Length(C.Channels) > 1);
  L := TStringList.Create;
  try
    L.LineBreak := #13#10;
    L.Add('# Sift filter export. Runs on Windows PowerShell 5.1 and PowerShell 7.');
    L.Add('# The structured query is passed to Get-WinEvent -FilterXml so Exclude (Suppress) is honored.');
    if C.ClientText then
      L.Add('# Message-text terms are matched client-side, after the service query.');
    if PerPath then
      L.Add('# Last ' + IntToStr(C.LastN) + ' across several logs: each log''s last ' + IntToStr(C.LastN) + ', merged newest first.');
    L.Add('$siftErrors = @()');
    if not PerPath then
    begin
      L.Add(PsAssignQuery('$siftQuery', C.QueryXml));
      Cmd := GetCmd('$siftQuery', (C.LastN > 0) and not C.ClientText);
      if Length(C.Channels) > 1 then
      begin
        { One log that is access denied (Security when not elevated) or not
          present on the machine running the script makes Get-WinEvent fail
          the whole -FilterXml query, while Sift skips it and names it in the
          banner. The script does the same: errors are classified by
          exception type (inner exceptions included), each log is opened once
          to find the bad ones, they are removed and the query runs again;
          when none is left it warns and stops. }
        L.Add('try { $siftEvents = ' + Cmd + ' } catch { $siftEvents = @(); $siftErrors += $_ }');
        L.Add('# Get-WinEvent fails the whole query when one log is unreadable or missing; Sift skips such logs.');
        L.Add('function SiftErrorKind($e) {');
        L.Add('  $x = $e');
        L.Add('  if ($x -is [System.Management.Automation.ErrorRecord]) { $x = $x.Exception }');
        L.Add('  while ($null -ne $x) {');
        L.Add('    if ($x -is [System.UnauthorizedAccessException]) { return ''denied'' }');
        L.Add('    if ($x -is [System.Diagnostics.Eventing.Reader.EventLogNotFoundException]) { return ''missing'' }');
        L.Add('    $x = $x.InnerException');
        L.Add('  }');
        L.Add('  return ''''');
        L.Add('}');
        L.Add('$siftDenied = @(); $siftMissing = @(); $siftProbeMs = 0');
        L.Add('$siftKinds = @($siftErrors | ForEach-Object { SiftErrorKind $_ })');
        L.Add('if (($siftKinds -contains ''denied'') -or ($siftKinds -contains ''missing'')) {');
        L.Add('  # Open each log once (no events are read) and drop the ones you cannot read or that do not exist here.');
        L.Add('  $siftClock = [System.Diagnostics.Stopwatch]::StartNew()');
        L.Add('  foreach ($siftPath in @(([xml]$siftQuery).SelectNodes(''//Select'') | ForEach-Object { $_.GetAttribute(''Path'') } | Sort-Object -Unique)) {');
        L.Add('    try {');
        L.Add('      $siftReader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader((New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($siftPath, [System.Diagnostics.Eventing.Reader.PathType]::LogName)))');
        L.Add('      $siftReader.Dispose()');
        L.Add('    } catch {');
        L.Add('      switch (SiftErrorKind $_) { ''denied'' { $siftDenied += $siftPath } ''missing'' { $siftMissing += $siftPath } }');
        L.Add('    }');
        L.Add('  }');
        L.Add('  $siftProbeMs = $siftClock.ElapsedMilliseconds');
        L.Add('  $siftDoc = [xml]$siftQuery');
        L.Add('  $siftSkip = @($siftDenied) + @($siftMissing)');
        L.Add('  foreach ($siftNode in @($siftDoc.SelectNodes(''//Select|//Suppress''))) { if ($siftSkip -contains $siftNode.GetAttribute(''Path'')) { [void]$siftNode.ParentNode.RemoveChild($siftNode) } }');
        L.Add('  $siftErrors = @()');
        L.Add('  if ($siftDenied.Count -gt 0) { Write-Warning (''Access denied, skipped: '' + ($siftDenied -join '', '')) }');
        L.Add('  if ($siftMissing.Count -gt 0) { Write-Warning (''No such log on this computer, skipped: '' + ($siftMissing -join '', '')) }');
        L.Add('  if (@($siftDoc.SelectNodes(''//Select'')).Count -eq 0) {');
        L.Add('    Write-Warning ''None of the logs in this filter can be read on this computer: nothing to query.''');
        L.Add('    $siftEvents = @()');
        L.Add('  } else {');
        L.Add('    # a Query left without a Select is removed; a Query''s Path follows its first remaining Select');
        L.Add('    foreach ($siftQ in @($siftDoc.SelectNodes(''//Query''))) {');
        L.Add('      $siftFirst = $siftQ.SelectSingleNode(''Select'')');
        L.Add('      if ($null -eq $siftFirst) { [void]$siftQ.ParentNode.RemoveChild($siftQ) } else { $siftQ.SetAttribute(''Path'', $siftFirst.GetAttribute(''Path'')) }');
        L.Add('    }');
        L.Add('    $siftQuery = $siftDoc.OuterXml');
        L.Add('    $siftEvents = ' + Cmd + '');
        L.Add('  }');
        L.Add('}');
      end
      else
        L.Add('$siftEvents = ' + GetCmd('$siftQuery', (C.LastN > 0) and not C.ClientText));
      AddTextFilters('$siftEvents');
      if (C.LastN > 0) and C.ClientText then
        L.Add('$siftEvents = @($siftEvents | Select-Object -First ' + IntToStr(C.LastN) + ')');
    end
    else
    begin
      L.Add('$siftEvents = @()');
      K := 0;
      for Ch in C.Channels do
      begin
        Inc(K);
        Sub := F.Clone;
        try
          for I := Sub.TermCount - 1 downto 0 do
            if Sub.Terms[I].Field = sfChannel then
              Sub.DeleteTerm(I);
          Sub.Channels.Clear;
          Sub.Channels.Add(Ch);
          SubC := CompileFilter(Sub, nil);
        finally
          Sub.Free;
        end;
        L.Add(PsAssignQuery('$siftQuery' + IntToStr(K), SubC.QueryXml));
        L.Add('$siftPart = ' + GetCmd('$siftQuery' + IntToStr(K), not C.ClientText));
        if C.ClientText then
        begin
          AddTextFilters('$siftPart');
          L.Add('$siftPart = @($siftPart | Select-Object -First ' + IntToStr(C.LastN) + ')');
        end;
        L.Add('$siftEvents += $siftPart');
      end;
      L.Add('$siftEvents = @($siftEvents | Sort-Object -Property @{ Expression = { $_.TimeCreated }; Descending = $true }, @{ Expression = { $_.RecordId }; Descending = $true } | Select-Object -First ' + IntToStr(C.LastN) + ')');
    end;
    L.Add('$siftErrors | Where-Object { $_.FullyQualifiedErrorId -notlike ''NoMatchingEventsFound*'' } | ForEach-Object { Write-Warning ('''' + $_) }');
    L.Add('$siftEvents | Format-Table TimeCreated, LevelDisplayName, LogName, ProviderName, Id -AutoSize');
    Result := TrimRight(L.Text);
  finally
    L.Free;
  end;
end;

end.
