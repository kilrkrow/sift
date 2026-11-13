program sift;

{ Sift - a light, fast Windows event log viewer. Copyright (c) 2026 kilrkrow }

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, SysUtils, Classes, Sift.MainForm,
  {$IFDEF SIFT_HARNESS}
  { headless screenshot / self-test harness: only in the Harness-* build
    modes, never in the Release exes }
  Sift.Harness,
  {$ENDIF}
  Sift.Filter, Sift.FilterJson, Sift.Elevate;

{$R *.res}

var
  I: Integer;
  FilterFile, FilterHash, ConsumeErr: string;
  G: TSiftFilter;
  StartTray, Loaded: Boolean;
begin
  {$IFDEF SIFT_HARNESS}
  HarnessTrace('main');
  HarnessPrepareDesktop;
  {$ENDIF}
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Title := 'Sift';
  Application.Initialize;
  {$IFDEF SIFT_HARNESS}
  if HarnessRequested then
  begin
    RunHarness;
    Exit;
  end;
  {$ENDIF}
  FilterFile := '';
  FilterHash := '';
  StartTray := False;
  for I := 1 to ParamCount do
  begin
    if (ParamStr(I) = '--filter') and (I < ParamCount) then
      FilterFile := ParamStr(I + 1);
    if (ParamStr(I) = '--filter-sha256') and (I < ParamCount) then
      FilterHash := ParamStr(I + 1);
    if ParamStr(I) = '--tray' then
      StartTray := True;
  end;
  Application.CreateForm(TSiftMainForm, SiftMainForm);
  SiftMainForm.EnableTray;
  if StartTray and SiftMainForm.TrayAvailable then
    Application.ShowMainForm := False;
  if FilterFile <> '' then
  begin
    G := TSiftFilter.Create;
    try
      Loaded := False;
      if FilterHash <> '' then
        Loaded := ConsumeElevationFilter(FilterFile, FilterHash, G, ConsumeErr)
      else if FileExists(FilterFile) then
      try
        LoadFilterFile(FilterFile, G);
        Loaded := True;
      except
        Loaded := False;
      end;
      if Loaded then
        SiftMainForm.ApplyFilter(G)
      else
        SiftMainForm.RunNow;
    finally
      G.Free;
    end;
  end
  else
    SiftMainForm.RunNow;
  Application.Run;
end.
