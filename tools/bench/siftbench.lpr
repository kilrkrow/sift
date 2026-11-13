program siftbench;

{ Headless SiftCore driver: runs a filter and prints timing. Used by the
  spike and by tools\bench\Run-Benchmarks.ps1. Read-only. }

{$mode objfpc}{$H+}

uses
  Windows, SysUtils, Classes, Sift.EvtApi, Sift.Filter, Sift.Compiler,
  Sift.FilterJson, Sift.Query, Sift.Channels;

procedure Usage;
begin
  WriteLn('siftbench --channel <name|file://path> [--channel ...] [--all]');
  WriteLn('          [--last-n N] [--minutes M] [--level L] [--id N] [--exclude-id N]');
  WriteLn('          [--text S] [--filter file.json] [--show-query] [--ids] [--messages N]');
  WriteLn('          [--list-channels] [--repeat K]');
end;

var
  F: TSiftFilter;
  Ex: TSiftExecutor;
  R: TSiftResult;
  All: TStringList;
  Infos: TSiftChannelInfos;
  I, K, Rep, Msgs: Integer;
  A, Msg: string;
  ShowQuery, Ids, ListCh, NeedAll: Boolean;
  C: TSiftCompiled;
  T0: QWord;
  Ev: EVT_HANDLE;
  OpenMs, FmtMs: Double;
begin
  if not EvtApiLoad(Msg) then
  begin
    WriteLn('ERROR ', Msg);
    Halt(2);
  end;
  F := TSiftFilter.Create;
  All := TStringList.Create;
  ShowQuery := False;
  Ids := False;
  ListCh := False;
  NeedAll := False;
  Rep := 1;
  Msgs := 0;
  I := 1;
  try
    while I <= ParamCount do
    begin
      A := ParamStr(I);
      if A = '--channel' then begin Inc(I); F.Channels.Add(ParamStr(I)); end
      else if A = '--all' then begin F.Channels.Add('*'); NeedAll := True; end
      else if A = '--last-n' then begin Inc(I); F.SetLastN(StrToInt(ParamStr(I))); end
      else if A = '--minutes' then begin Inc(I); F.SetRelativeWindow(Int64(StrToInt(ParamStr(I))) * 60000); end
      else if A = '--level' then begin Inc(I); F.AddTerm(MakeTerm(sfLevel, saInclude, ParamStr(I))); end
      else if A = '--id' then begin Inc(I); F.AddTerm(MakeTerm(sfEventId, saInclude, ParamStr(I))); end
      else if A = '--exclude-id' then begin Inc(I); F.AddTerm(MakeTerm(sfEventId, saExclude, ParamStr(I))); end
      else if A = '--text' then begin Inc(I); F.AddTerm(MakeTerm(sfMessage, saInclude, ParamStr(I))); end
      else if A = '--filter' then begin Inc(I); LoadFilterFile(ParamStr(I), F); NeedAll := F.Channels.IndexOf('*') >= 0; end
      else if A = '--show-query' then ShowQuery := True
      else if A = '--ids' then Ids := True
      else if A = '--messages' then begin Inc(I); Msgs := StrToInt(ParamStr(I)); end
      else if A = '--list-channels' then ListCh := True
      else if A = '--repeat' then begin Inc(I); Rep := StrToInt(ParamStr(I)); end
      else begin Usage; Halt(1); end;
      Inc(I);
    end;
    if ListCh or NeedAll then
    begin
      T0 := NowTick;
      EnumChannels(Infos);
      QueryableChannels(Infos, All);
      if ListCh then
      begin
        WriteLn('channels_total=', Length(Infos), ' queryable=', All.Count,
          ' enum_ms=', MsSince(T0):0:1);
        for A in All do
          WriteLn(A);
        Exit;
      end;
    end;
    C := CompileFilter(F, All);
    if ShowQuery then
    begin
      WriteLn(C.QueryXml);
      WriteLn('FH: ', C.FilterHashtable, C.FilterHashtableNote);
    end;
    Ex := TSiftExecutor.Create;
    try
      for K := 1 to Rep do
      begin
        R := Ex.Execute(F, All);
        try
          WriteLn(Format('run=%d rows=%d scanned=%d first_row_ms=%.1f total_ms=%.1f path=%s cap_hit=%s text_scanned=%d err=%d %s',
            [K, R.Count, R.Stats.Scanned, R.Stats.FirstRowMs, R.Stats.TotalMs,
             BoolToStr(R.Stats.Path = rpService, 'service', 'service+client-text'),
             BoolToStr(R.Stats.CapHit, 'yes', 'no'), R.Stats.TextScanned,
             R.Stats.QueryError, R.Stats.QueryErrorText]));
          for I := 0 to High(R.Errors) do
            WriteLn(Format('channel_error channel=%s code=%d elevation=%s text=%s',
              [R.Errors[I].Channel, R.Errors[I].Code,
               BoolToStr(R.Errors[I].NeedsElevation, 'yes', 'no'), R.Errors[I].Text]));
          if Ids and (K = Rep) then
            for I := 0 to R.Count - 1 do
              WriteLn(R.Key(I));
          if (Msgs > 0) and (K = Rep) then
          begin
            OpenMs := 0;
            FmtMs := 0;
            for I := 0 to Msgs - 1 do
              if I < R.Count then
              begin
                T0 := NowTick;
                Ev := Ex.Renderer.OpenEvent(R.Str(R.Rows[I]^.ChannelIx), R.Rows[I]^.RecordId, R.Str(R.Rows[I]^.ChannelIx));
                OpenMs := OpenMs + MsSince(T0);
                if Ev <> 0 then
                begin
                  T0 := NowTick;
                  A := Ex.Renderer.FormatMessage(Ev, R.Str(R.Rows[I]^.ProviderIx));
                  FmtMs := FmtMs + MsSince(T0);
                  EvtClose(Ev);
                end;
              end;
            WriteLn(Format('lazy_render rows=%d open_ms_per_row=%.2f format_ms_per_row=%.2f',
              [Msgs, OpenMs / Msgs, FmtMs / Msgs]));
          end;
        finally
          R.Free;
        end;
      end;
    finally
      Ex.Free;
    end;
  finally
    All.Free;
    F.Free;
  end;
end.
