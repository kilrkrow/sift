unit Sift.FilterJson;

{ Filter file v1: human-readable, versioned JSON ("siftFilterVersion": 1).
  Round-trips through the TSiftFilter AST. Uses fpjson. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser, Sift.Filter;

const
  SiftFilterVersion = 1;
  SiftFilterFileExt = '.siftfilter.json';

function FilterToJson(F: TSiftFilter): string;
{ Raises ESiftFilterFormat with a readable message on bad input. }
procedure FilterFromJson(const S: string; F: TSiftFilter);
procedure SaveFilterFile(F: TSiftFilter; const FileName: string);
procedure LoadFilterFile(const FileName: string; F: TSiftFilter);
{ Rejects control characters, a line equal to the PowerShell here-string
  closer, both quote types, and remote / UNC file:// paths. }
function ValidateChannel(const Channel: string; out Normalized: string;
  out ErrorMsg: string): Boolean;
{ Clears Dest, then adds every valid channel from a comma-separated list
  (ini Channels=). Invalid entries are skipped and, if Rejected is not
  nil, appended there. }
procedure LoadValidatedChannels(const CommaText: string; Dest: TStrings;
  Rejected: TStrings);
{ Open-dialog .evtx path: only a local drive (or \\?\X:) becomes a
  file:// channel. Remote / UNC paths are rejected with ErrorMsg. }
function TryFileChannelFromPath(const FileName: string; out Channel: string;
  out ErrorMsg: string): Boolean;

type
  ESiftFilterFormat = class(Exception);

implementation

function FilterToJson(F: TSiftFilter): string;
var
  O, W: TJSONObject;
  A, Terms: TJSONArray;
  I: Integer;
  T: TSiftTerm;
  TO_: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('siftFilterVersion', SiftFilterVersion);
    A := TJSONArray.Create;
    for I := 0 to F.Channels.Count - 1 do
      A.Add(F.Channels[I]);
    O.Add('channels', A);
    W := TJSONObject.Create;
    case F.TimeMode of
      tmAll: W.Add('mode', 'all');
      tmRelative:
        begin
          W.Add('mode', 'relative');
          W.Add('lastMs', F.RelativeMs);
        end;
      tmAbsolute:
        begin
          W.Add('mode', 'absolute');
          if F.StartUtc <> 0 then
            W.Add('startUtc', UtcToIso(F.StartUtc))
          else
            W.Add('startUtc', TJSONNull.Create);
          if F.EndUtc <> 0 then
            W.Add('endUtc', UtcToIso(F.EndUtc))
          else
            W.Add('endUtc', TJSONNull.Create);
        end;
    end;
    O.Add('time', W);
    O.Add('lastN', F.LastN);
    O.Add('textScanCap', F.TextScanCap);
    Terms := TJSONArray.Create;
    for I := 0 to F.TermCount - 1 do
    begin
      T := F.Terms[I];
      TO_ := TJSONObject.Create;
      TO_.Add('field', SiftFieldNames[T.Field]);
      TO_.Add('action', SiftActionNames[T.Action]);
      TO_.Add('value', T.Value);
      Terms.Add(TO_);
    end;
    O.Add('terms', Terms);
    Result := O.FormatJSON([foUseTabchar], 1);
    Result := StringReplace(Result, #9, '  ', [rfReplaceAll]);
  finally
    O.Free;
  end;
end;

function ValidateChannel(const Channel: string; out Normalized: string;
  out ErrorMsg: string): Boolean;
var
  V, Why: string;
begin
  V := Trim(Channel);
  Normalized := V;
  ErrorMsg := '';
  if V = '' then
  begin
    ErrorMsg := 'channel is empty';
    Exit(False);
  end;
  Why := UnsafeValueReason(V);
  if Why <> '' then
  begin
    ErrorMsg := Why;
    Exit(False);
  end;
  if IsRemoteChannel(V) then
  begin
    ErrorMsg := 'remote or UNC file paths are not allowed';
    Exit(False);
  end;
  if IsFileChannel(V) and not IsAllowedFileChannel(V) then
  begin
    ErrorMsg := 'file:// path is not a local drive path';
    Exit(False);
  end;
  Result := True;
end;

procedure LoadValidatedChannels(const CommaText: string; Dest: TStrings;
  Rejected: TStrings);
var
  Tmp: TStringList;
  I: Integer;
  Norm, Err: string;
begin
  Dest.Clear;
  Tmp := TStringList.Create;
  try
    Tmp.CommaText := CommaText;
    for I := 0 to Tmp.Count - 1 do
    begin
      if ValidateChannel(Tmp[I], Norm, Err) then
      begin
        if Dest.IndexOf(Norm) < 0 then
          Dest.Add(Norm);
      end
      else if Rejected <> nil then
        Rejected.Add(Tmp[I]);
    end;
  finally
    Tmp.Free;
  end;
end;

function TryFileChannelFromPath(const FileName: string; out Channel: string;
  out ErrorMsg: string): Boolean;
var
  Norm: string;
begin
  Channel := 'file://' + FileName;
  Result := ValidateChannel(Channel, Norm, ErrorMsg);
  if Result then
    Channel := Norm;
end;

procedure Bad(const Msg: string);
begin
  raise ESiftFilterFormat.Create('Not a valid Sift filter: ' + Msg);
end;

procedure FilterFromJson(const S: string; F: TSiftFilter);
var
  D: TJSONData;
  O, W, TO_: TJSONObject;
  A: TJSONArray;
  I: Integer;
  V: Int64;
  Mode, Fs, As_, Val: string;
  Fld: TSiftField;
  Act: TSiftAction;
  St, En: TDateTime;
  Tmp: TSiftFilter;
  Norm, Err: string;
begin
  try
    D := GetJSON(S);
  except
    on E: Exception do
    begin
      Bad('JSON parse error (' + E.Message + ')');
      Exit;
    end;
  end;
  Tmp := TSiftFilter.Create;
  try
    if not (D is TJSONObject) then
      Bad('top level must be an object');
    O := TJSONObject(D);
    if O.Find('siftFilterVersion') = nil then
      Bad('missing "siftFilterVersion"');
    V := O.Get('siftFilterVersion', Int64(0));
    if V <> SiftFilterVersion then
      Bad('unsupported siftFilterVersion ' + IntToStr(V) + ' (this build reads 1)');
    A := O.Get('channels', TJSONArray(nil));
    if A <> nil then
      for I := 0 to A.Count - 1 do
      begin
        if not ValidateChannel(A.Strings[I], Norm, Err) then
          Bad('channels[' + IntToStr(I) + '] ' + Err);
        Tmp.Channels.Add(Norm);
      end;
    W := O.Get('time', TJSONObject(nil));
    if W <> nil then
    begin
      Mode := W.Get('mode', 'all');
      if Mode = 'relative' then
        Tmp.SetRelativeWindow(W.Get('lastMs', Int64(0)))
      else if Mode = 'absolute' then
      begin
        St := 0;
        En := 0;
        if (W.Find('startUtc') <> nil) and (W.Find('startUtc').JSONType = jtString) then
          if not IsoToUtc(W.Strings['startUtc'], St) then
            Bad('bad time.startUtc');
        if (W.Find('endUtc') <> nil) and (W.Find('endUtc').JSONType = jtString) then
          if not IsoToUtc(W.Strings['endUtc'], En) then
            Bad('bad time.endUtc');
        Tmp.SetAbsoluteWindow(St, En);
      end
      else if Mode <> 'all' then
        Bad('unknown time.mode "' + Mode + '"');
    end;
    Tmp.TextScanCap := O.Get('textScanCap', DefaultTextScanCap);
    A := O.Get('terms', TJSONArray(nil));
    if A <> nil then
      for I := 0 to A.Count - 1 do
      begin
        if not (A.Items[I] is TJSONObject) then
          Bad('terms[' + IntToStr(I) + '] must be an object');
        TO_ := TJSONObject(A.Items[I]);
        Fs := TO_.Get('field', '');
        As_ := TO_.Get('action', '');
        Val := TO_.Get('value', '');
        if not FieldFromName(Fs, Fld) then
          Bad('terms[' + IntToStr(I) + '] unknown field "' + Fs + '"');
        if As_ = 'include' then
          Act := saInclude
        else if As_ = 'exclude' then
          Act := saExclude
        else
          Bad('terms[' + IntToStr(I) + '] action must be include or exclude');
        try
          Tmp.AddTerm(MakeTerm(Fld, Act, Val));
        except
          on E: EConvertError do
            Bad('terms[' + IntToStr(I) + '] ' + E.Message);
        end;
      end;
    { lastN after the window: with a window it is a cap (MaxEvents) }
    V := O.Get('lastN', Int64(0));
    if V > 0 then
    begin
      if V > MaxInt then
        Bad('lastN is too large');
      Tmp.SetMaxCount(V);
    end;
    F.Assign(Tmp);
  finally
    Tmp.Free;
    D.Free;
  end;
end;

procedure SaveFilterFile(F: TSiftFilter; const FileName: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := FilterToJson(F);
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
end;

procedure LoadFilterFile(const FileName: string; F: TSiftFilter);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    FilterFromJson(L.Text, F);
  finally
    L.Free;
  end;
end;

end.
