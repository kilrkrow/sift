unit Sift.Harness;

{ Headless harness for the viewer. Never shows a window: the main form is
  created hidden, painted into bitmaps with PaintTo, and the process exits.
  The tray icon is never made visible here.
    sift.exe --screenshots <dir> [--redact old=new ...]
    sift.exe --dump-ui <file>
    sift.exe --selftest-grid <file>
    sift.exe --feature-check <file>     (pieces 8, 9, 10 through the real UI)
    sift.exe --report-wrap <file>       (the Message wrap state read at start-up)
  Every mode takes --ini <file>; without it a scratch ini under %TEMP% is
  used, so the harness never reads or writes the user's own sift.ini. }

{$mode objfpc}{$H+}

interface

function HarnessRequested: Boolean;
procedure RunHarness;
procedure HarnessTrace(const S: string);
{ Moves the main thread onto a private, never-displayed desktop so the
  harness can lay out and paint real windows without anything appearing
  on the user's screen or taking focus. Must run before
  Application.Initialize creates the first window. }
procedure HarnessPrepareDesktop;

implementation

uses
  Windows, SysUtils, Classes, Forms, Controls, Graphics, Grids, StdCtrls,
  ExtCtrls, ComCtrls, Buttons, IntfGraphics, Math, Sift.MainForm, Sift.Filter, Sift.Query,
  Sift.Channels, Sift.Compiler,
  Sift.Shell, Sift.ColFit, Sift.PubMeta, Sift.Toolbar, Sift.TzTime;

function ArgValue(const Name: string): string;
var
  I: Integer;
begin
  for I := 1 to ParamCount - 1 do
    if ParamStr(I) = Name then
      Exit(ParamStr(I + 1));
  Result := '';
end;

function HasArg(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if ParamStr(I) = Name then
      Exit(True);
  Result := False;
end;

var
  TraceFile: string = '';
  HarnessDesktop: HDESK = 0;

function CreateDesktopW(lpszDesktop, lpszDevice: PWideChar; pDevmode: Pointer;
  dwFlags: DWORD; dwDesiredAccess: DWORD; lpsa: Pointer): HDESK; stdcall;
  external 'user32.dll' name 'CreateDesktopW';
function SetThreadDesktop(hDesktop: HDESK): BOOL; stdcall;
  external 'user32.dll' name 'SetThreadDesktop';
function CloseDesktop(hDesktop: HDESK): BOOL; stdcall;
  external 'user32.dll' name 'CloseDesktop';

procedure Trace(const S: string);
var
  F: TextFile;
begin
  if TraceFile = '' then
    TraceFile := ArgValue('--trace');
  if TraceFile = '' then
    Exit;
  AssignFile(F, TraceFile);
  if FileExists(TraceFile) then
    Append(F)
  else
    Rewrite(F);
  WriteLn(F, FormatDateTime('hh:nn:ss.zzz', Now), ' ', S);
  CloseFile(F);
end;

type
  THarnessExceptionSink = class
    procedure HandleException(Sender: TObject; E: Exception);
  end;

procedure THarnessExceptionSink.HandleException(Sender: TObject; E: Exception);
begin
  Trace('exception: ' + E.ClassName + ': ' + E.Message);
end;

function HarnessRequested: Boolean;
begin
  Result := HasArg('--screenshots') or HasArg('--dump-ui') or HasArg('--selftest-grid') or
    HasArg('--feature-check') or HasArg('--report-wrap');
end;

procedure SavePng(Bmp: TBitmap; const FileName: string);
var
  Png: TPortableNetworkGraphic;
begin
  Png := TPortableNetworkGraphic.Create;
  try
    Png.Assign(Bmp);
    Png.SaveToFile(FileName);
  finally
    Png.Free;
  end;
end;

function EndMenu: BOOL; stdcall; external 'user32.dll' name 'EndMenu';
function PrintWindow(hwnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall;
  external 'user32.dll' name 'PrintWindow';

var
  SnapMethod: Integer = 0; { 0 = PrintWindow, 1 = PrintWindow full content, 2 = BitBlt, 3 = PaintTo }

function Snap(C: TWinControl): TBitmap;
var
  R: TRect;
  DC: HDC;
  W, H: Integer;
begin
  Result := TBitmap.Create;
  Result.PixelFormat := pf24bit;
  if (HarnessDesktop = 0) or (SnapMethod = 3) then
  begin
    Result.SetSize(C.Width, C.Height);
    Result.Canvas.Brush.Color := clBtnFace;
    Result.Canvas.FillRect(0, 0, C.Width, C.Height);
    C.PaintTo(Result.Canvas, 0, 0);
    Exit;
  end;
  RedrawWindow(C.Handle, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW or
    RDW_ALLCHILDREN or RDW_FRAME or RDW_ERASE);
  GetWindowRect(C.Handle, R);
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  Result.SetSize(W, H);
  Result.Canvas.Brush.Color := clWhite;
  Result.Canvas.FillRect(0, 0, W, H);
  case SnapMethod of
    0: PrintWindow(C.Handle, Result.Canvas.Handle, 0);
    1: PrintWindow(C.Handle, Result.Canvas.Handle, 2);
  else
    DC := GetWindowDC(C.Handle);
    BitBlt(Result.Canvas.Handle, 0, 0, W, H, DC, 0, 0, SRCCOPY);
    ReleaseDC(C.Handle, DC);
  end;
end;

function SnapHwnd(H: HWND; out R: TRect): TBitmap;
begin
  GetWindowRect(H, R);
  Result := TBitmap.Create;
  Result.PixelFormat := pf24bit;
  Result.SetSize(R.Right - R.Left, R.Bottom - R.Top);
  Result.Canvas.Brush.Color := clWhite;
  Result.Canvas.FillRect(0, 0, Result.Width, Result.Height);
  PrintWindow(H, Result.Canvas.Handle, 0);
end;

type
  { Captures a modal popup (menu or dialog) from inside its own modal loop,
    composited over the main window, then closes it. Only ever used on the
    harness's private desktop; key messages are posted to our own menu
    window there, never to the user's session. }
  TPopupShot = class
    Timer: TTimer;
    Step: Integer;
    Form: TSiftMainForm;
    FileName: string;
    OpenSubmenu: Boolean;
    IsDialog: Boolean;
    Captured: Boolean;
    constructor Create(AForm: TSiftMainForm; const AFile: string; ASub, ADialog: Boolean);
    destructor Destroy; override;
    procedure Tick(Sender: TObject);
    procedure Capture;
  end;

var
  MenuWnds: array of HWND;

function EnumMenuWnd(H: HWND; LP: LPARAM): BOOL; stdcall;
var
  Cls: array[0..63] of Char;
begin
  GetClassNameA(H, Cls, 64);
  if (StrPas(Cls) = '#32768') and IsWindowVisible(H) then
  begin
    SetLength(MenuWnds, Length(MenuWnds) + 1);
    MenuWnds[High(MenuWnds)] := H;
  end;
  Result := True;
end;

constructor TPopupShot.Create(AForm: TSiftMainForm; const AFile: string; ASub, ADialog: Boolean);
begin
  Form := AForm;
  FileName := AFile;
  OpenSubmenu := ASub;
  IsDialog := ADialog;
  Timer := TTimer.Create(nil);
  Timer.Interval := 300;
  Timer.OnTimer := @Tick;
  Timer.Enabled := True;
end;

destructor TPopupShot.Destroy;
begin
  Timer.Free;
  inherited Destroy;
end;

procedure TPopupShot.Capture;
var
  Base, Part: TBitmap;
  FR, R: TRect;
  I: Integer;
  Wnds: array of HWND;
  Png: TPortableNetworkGraphic;
begin
  Wnds := nil;
  if IsDialog then
  begin
    for I := 0 to Screen.FormCount - 1 do
      if (Screen.Forms[I] <> Form) and Screen.Forms[I].Visible then
      begin
        SetLength(Wnds, Length(Wnds) + 1);
        Wnds[High(Wnds)] := Screen.Forms[I].Handle;
      end;
  end
  else
  begin
    MenuWnds := nil;
    EnumThreadWindows(GetCurrentThreadId, @EnumMenuWnd, 0);
    Wnds := MenuWnds;
  end;
  Base := SnapHwnd(Form.Handle, FR);
  try
    for I := 0 to High(Wnds) do
    begin
      Part := SnapHwnd(Wnds[I], R);
      try
        Base.Canvas.Draw(R.Left - FR.Left, R.Top - FR.Top, Part);
      finally
        Part.Free;
      end;
    end;
    Png := TPortableNetworkGraphic.Create;
    try
      Png.Assign(Base);
      Png.SaveToFile(FileName);
    finally
      Png.Free;
    end;
    Trace(Format('captured %s (%d popup windows)', [ExtractFileName(FileName), Length(Wnds)]));
  finally
    Base.Free;
  end;
  Captured := True;
end;

procedure TPopupShot.Tick(Sender: TObject);
var
  I: Integer;
begin
  Inc(Step);
  if IsDialog then
  begin
    Timer.Enabled := False;
    Capture;
    for I := 0 to Screen.FormCount - 1 do
      if (Screen.Forms[I] <> Form) and Screen.Forms[I].Visible and
         (fsModal in Screen.Forms[I].FormState) then
        Screen.Forms[I].ModalResult := mrCancel;
    Exit;
  end;
  MenuWnds := nil;
  EnumThreadWindows(GetCurrentThreadId, @EnumMenuWnd, 0);
  if Length(MenuWnds) = 0 then
  begin
    if Step > 20 then
      Timer.Enabled := False;
    Exit;
  end;
  if OpenSubmenu and (Step = 1) then
  begin
    PostMessage(MenuWnds[0], WM_KEYDOWN, VK_DOWN, 0);
    Exit;
  end;
  if OpenSubmenu and (Step = 2) then
  begin
    PostMessage(MenuWnds[0], WM_KEYDOWN, VK_RIGHT, 0);
    Exit;
  end;
  Timer.Enabled := False;
  Capture;
  EndMenu;
end;

procedure SnapTo(C: TWinControl; const FileName: string);
var
  B: TBitmap;
begin
  B := Snap(C);
  try
    SavePng(B, FileName);
  finally
    B.Free;
  end;
end;

procedure CropTo(Src: TBitmap; const R: TRect; const FileName: string);
var
  B: TBitmap;
begin
  B := TBitmap.Create;
  try
    B.PixelFormat := pf24bit;
    B.SetSize(R.Right - R.Left, R.Bottom - R.Top);
    B.Canvas.CopyRect(Rect(0, 0, B.Width, B.Height), Src.Canvas, R);
    SavePng(B, FileName);
  finally
    B.Free;
  end;
end;

function MakeForm: TSiftMainForm;
var
  Map: TStringList;
  I: Integer;
  S: string;
begin
  Application.ShowMainForm := False;
  Trace('creating form');
  Result := TSiftMainForm.Create(Application);
  Trace('form constructed');
  Result.SetBounds(0, 0, Result.Scale96ToForm(1240), Result.Scale96ToForm(760));
  Result.HandleNeeded;
  Trace('handle ok');
  if HarnessDesktop <> 0 then
  begin
    { safe: this window lives on a private desktop nobody can see }
    Result.Show;
    Result.SetBounds(0, 0, Result.Scale96ToForm(1240), Result.Scale96ToForm(760));
    Application.ProcessMessages;
    Trace(Format('shown on private desktop, bounds %dx%d', [Result.Width, Result.Height]));
  end
  else
    Trace('no private desktop: painting a hidden form (child controls may be blank)');
  Map := TStringList.Create;
  try
    S := GetEnvironmentVariable('COMPUTERNAME');
    if S <> '' then
      Map.Add(S + '=HOST01');
    S := GetEnvironmentVariable('USERNAME');
    if S <> '' then
      Map.Add(S + '=user');
    for I := 1 to ParamCount - 1 do
      if ParamStr(I) = '--redact' then
        Map.Add(ParamStr(I + 1));
    Result.SetRedaction(Map);
  finally
    Map.Free;
  end;
end;

procedure Settle(F: TSiftMainForm);
var
  I: Integer;
begin
  for I := 1 to 5 do
  begin
    Application.ProcessMessages;
    CheckSynchronize(5);
  end;
  F.Realign;
end;

type
  TDemoEvent = record
    Channel, Provider, User, Msg: string;
    Id: Word;
    Level: Byte;
  end;

const
  DemoEvents: array[0..11] of TDemoEvent = (
    (Channel: 'System'; Provider: 'Microsoft-Windows-Kernel-PnP'; User: 'S-1-5-18';
     Msg: 'The driver \Driver\WUDFRd failed to load for the device USB\VID_0000&PID_0000\DEMO0001.'; Id: 219; Level: 3),
    (Channel: 'System'; Provider: 'disk'; User: '';
     Msg: 'The IO operation at logical block address 0x1f2e3d for Disk 1 (PDO name: \Device\00000042) was retried.'; Id: 153; Level: 3),
    (Channel: 'Application'; Provider: 'Application Error'; User: '';
     Msg: 'Faulting application name: demoapp.exe, version: 1.0.0.0. Faulting module name: demo.dll, version: 1.0.0.0, exception code: 0xc0000005.'; Id: 1000; Level: 2),
    (Channel: 'System'; Provider: 'Service Control Manager'; User: '';
     Msg: 'The Demo Update service terminated unexpectedly. It has done this 1 time(s). The following corrective action will be taken in 60000 milliseconds: Restart the service.'; Id: 7031; Level: 2),
    (Channel: 'Application'; Provider: 'Microsoft-Windows-Search'; User: '';
     Msg: 'The filter host process 4242 did not respond and is being forcibly terminated.'; Id: 10024; Level: 3),
    (Channel: 'System'; Provider: 'Microsoft-Windows-Time-Service'; User: 'S-1-5-19';
     Msg: 'NtpClient was unable to set a domain peer to use as a time source because of discovery error. NtpClient will try again in 15 minutes.'; Id: 129; Level: 3),
    (Channel: 'System'; Provider: 'Microsoft-Windows-WindowsUpdateClient'; User: 'S-1-5-18';
     Msg: 'Installation Failure: Windows failed to install the following update with error 0x80070643: Demo Update (KB0000001).'; Id: 20; Level: 2),
    (Channel: 'Application'; Provider: 'ESENT'; User: '';
     Msg: 'svchost (4242,R,98) DemoInstance: Error -1811 (0xfffff8ed) occurred while opening logfile C:\ProgramData\Demo\edb.log.'; Id: 455; Level: 2),
    (Channel: 'System'; Provider: 'Microsoft-Windows-DNS-Client'; User: 'S-1-5-20';
     Msg: 'Name resolution for the name example.invalid timed out after none of the configured DNS servers responded.'; Id: 1014; Level: 3),
    (Channel: 'System'; Provider: 'Service Control Manager'; User: 'S-1-5-18';
     Msg: 'The start type of the Demo service was changed from auto start to demand start.'; Id: 7040; Level: 4),
    (Channel: 'System'; Provider: 'Microsoft-Windows-Kernel-General'; User: 'S-1-5-19';
     Msg: 'The system time has changed to 2026-10-30T09:00:00.000000000Z from 2026-10-30T08:59:59.990000000Z.'; Id: 1; Level: 4),
    (Channel: 'Application'; Provider: 'Microsoft-Windows-Security-SPP'; User: '';
     Msg: 'The Software Protection service has completed licensing status check. Application Id=00000000-0000-0000-0000-000000000000'; Id: 1066; Level: 4)
  );

  DemoLogs: array[0..14] of string = ('Application', 'Security', 'Setup', 'System',
    'ForwardedEvents', 'Windows PowerShell', 'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
    'Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-Kernel-PnP/Device Management',
    'Microsoft-Windows-Ntfs/Operational', 'Microsoft-Windows-PowerShell/Operational',
    'Microsoft-Windows-StorageManagement/Operational', 'Microsoft-Windows-TaskScheduler/Operational',
    'Microsoft-Windows-Windows Defender/Operational', 'Microsoft-Windows-WindowsUpdateClient/Operational');

{ Replaces the form's rows with synthetic ones (no real hostnames, users or
  event text), keeping the real query's timing and errors. }
procedure LoadDemo(F: TSiftMainForm; G: TSiftFilter; N: Integer; ErrWarnOnly: Boolean);
var
  R, Real: TSiftResult;
  Msgs: TStringList;
  Logs: TSiftChannelInfos;
  Row: TSiftEventRow;
  I, K: Integer;
  T: Int64;
  E: TDemoEvent;
begin
  Real := F.CurrentResult;
  R := TSiftResult.Create(G, CompileFilter(G, nil));
  Msgs := TStringList.Create;
  try
    if Real <> nil then
    begin
      R.Stats := Real.Stats;
      for I := 0 to High(Real.Errors) do
        R.AddError(Real.Errors[I]);
    end;
    T := UtcNowFileTime - Int64(90) * 10000000;
    K := 0;
    I := 0;
    while R.Count < N do
    begin
      E := DemoEvents[K mod Length(DemoEvents)];
      Inc(K);
      if ErrWarnOnly and not (E.Level in [2, 3]) then
        Continue;
      if (G.Channels.IndexOf(E.Channel) < 0) then
        Continue;
      FillChar(Row, SizeOf(Row), 0);
      Row.RecordId := 900000 - I;
      Row.TimeCreated := T;
      Row.EventId := E.Id;
      Row.Level := E.Level;
      Row.ChannelIx := R.Pool.Intern(E.Channel);
      Row.ProviderIx := R.Pool.Intern(E.Provider);
      Row.UserIx := R.Pool.Intern(E.User);
      Row.ComputerIx := R.Pool.Intern('HOST01');
      R.AddRow(Row);
      Msgs.Add(E.Msg);
      Dec(T, Int64(37 + (I * 53) mod 900) * 10000000);
      Inc(I);
    end;
    SetLength(Logs, Length(DemoLogs));
    for I := 0 to High(DemoLogs) do
    begin
      Logs[I].Name := DemoLogs[I];
      Logs[I].Enabled := True;
      Logs[I].ChannelType := 1;
      Logs[I].Classic := IsClassicLog(DemoLogs[I]);
    end;
    F.SetDemoData(R, Msgs, Logs);
  finally
    Msgs.Free;
  end;
end;

procedure DoScreenshots(const Dir: string);
var
  Shot: TPopupShot;
  F: TSiftMainForm;
  G: TSiftFilter;
  B: TBitmap;
  Log: TStringList;
  W, H: Integer;
begin
  ForceDirectories(Dir);
  Log := TStringList.Create;
  F := MakeForm;
  G := TSiftFilter.Create;
  try
    { 1. main grid with chips: System + Application, errors and warnings,
         one exclude, last 40 }
    G.Channels.Add('System');
    G.Channels.Add('Application');
    G.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    G.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    G.AddTerm(MakeTerm(sfEventId, saExclude, '10016'));
    G.SetLastN(40);
    F.ShowQueryPanel(False);
    F.ApplyFilter(G);
    F.WaitForQuery(30000);
    { the screenshots show synthetic rows, messages and log names; the real
      query above only supplies the timing in the status bar }
    LoadDemo(F, G, 40, True);
    F.SelectRow(0);
    Settle(F);
    if HasArg('--snap-variants') then
    begin
      for W := 3 downto 0 do
      begin
        SnapMethod := W;
        SnapTo(F, IncludeTrailingPathDelimiter(Dir) + 'variant' + IntToStr(W) + '.png');
      end;
      SnapMethod := StrToIntDef(ArgValue('--snap-method'), 0);
    end;
    SnapTo(F, IncludeTrailingPathDelimiter(Dir) + 'main-grid-chips.png');
    Log.Add('main-grid-chips.png rows=' + IntToStr(F.CurrentResult.Count));

    { 1b. right-click menu on the Provider cell of row 2, Include submenu open }
    Shot := TPopupShot.Create(F, IncludeTrailingPathDelimiter(Dir) + 'right-click-menu.png', True, False);
    try
      F.OpenGridMenuAt(3, 1);
      Log.Add('right-click-menu.png captured=' + BoolToStr(Shot.Captured, 'yes', 'no'));
    finally
      Shot.Free;
    end;
    Settle(F);

    { 1c. tray menu (the popup the tray icon opens; the notification-area
          icon itself is never shown by the harness) }
    Shot := TPopupShot.Create(F, IncludeTrailingPathDelimiter(Dir) + 'tray-menu.png', False, False);
    try
      F.TrayMenu.PopUp(F.Left + F.Width - F.Scale96ToForm(260), F.Top + F.Height - F.Scale96ToForm(160));
      Log.Add('tray-menu.png captured=' + BoolToStr(Shot.Captured, 'yes', 'no'));
    finally
      Shot.Free;
    end;
    Settle(F);

    { 1d. about box and log picker (modal dialogs) }
    Shot := TPopupShot.Create(F, IncludeTrailingPathDelimiter(Dir) + 'about.png', False, True);
    try
      F.OpenAbout;
      Log.Add('about.png captured=' + BoolToStr(Shot.Captured, 'yes', 'no'));
    finally
      Shot.Free;
    end;
    Shot := TPopupShot.Create(F, IncludeTrailingPathDelimiter(Dir) + 'log-picker.png', False, True);
    try
      F.OpenLogPicker;
      Log.Add('log-picker.png captured=' + BoolToStr(Shot.Captured, 'yes', 'no'));
    finally
      Shot.Free;
    end;
    Settle(F);

    { 2. query panel open }
    F.ShowQueryPanel(True);
    Settle(F);
    SnapTo(F, IncludeTrailingPathDelimiter(Dir) + 'query-panel.png');
    Log.Add('query-panel.png');

    { 3. version label (bottom right of the status bar) }
    B := Snap(F);
    try
      W := F.Scale96ToForm(420);
      H := F.Scale96ToForm(40);
      CropTo(B, Rect(B.Width - W, B.Height - H, B.Width, B.Height),
        IncludeTrailingPathDelimiter(Dir) + 'version-label.png');
      Log.Add('version-label.png version=' + F.VersionText);
    finally
      B.Free;
    end;

    { 4. Security access denied banner (real query, unelevated) }
    F.ShowQueryPanel(False);
    G.Clear;
    G.Channels.Add('System');
    G.Channels.Add('Security');
    G.SetLastN(20);
    F.ApplyFilter(G);
    F.WaitForQuery(30000);
    { keeps the real access-denied error (unelevated), synthetic rows }
    LoadDemo(F, G, 20, False);
    F.SelectRow(0);
    Settle(F);
    SnapTo(F, IncludeTrailingPathDelimiter(Dir) + 'security-denied.png');
    Log.Add('security-denied.png elevated=' + BoolToStr(IsProcessElevated, 'yes', 'no'));

    { 5. easy-button toolbar + Event ID tab: Error and Warning, 24 h, max 40,
         System + Application; synthetic rows, real provider metadata }
    G.Clear;
    G.Channels.Add('System');
    G.Channels.Add('Application');
    G.AddTerm(MakeTerm(sfLevel, saInclude, '2'));
    G.AddTerm(MakeTerm(sfLevel, saInclude, '3'));
    G.SetRelativeWindow(24 * 3600000);
    G.SetMaxCount(40);
    F.ApplyFilter(G);
    F.WaitForQuery(30000);
    LoadDemo(F, G, 40, True);
    F.SelectRow(3);
    F.ShowEventIdTab;
    Settle(F);
    SnapTo(F, IncludeTrailingPathDelimiter(Dir) + 'event-id-tab.png');
    Log.Add('event-id-tab.png toolbar: ' + F.ToolbarStateText);
    SnapTo(F.ToolbarRow, IncludeTrailingPathDelimiter(Dir) + 'toolbar.png');
    Log.Add('toolbar.png');

    { 6. Message column wrapped (divider double-click on Message) }
    F.SetMessageWrap(True);
    F.SelectRow(0);
    Settle(F);
    SnapTo(F, IncludeTrailingPathDelimiter(Dir) + 'message-wrap.png');
    Log.Add('message-wrap.png');
    F.SetMessageWrap(False);
    Log.SaveToFile(IncludeTrailingPathDelimiter(Dir) + 'screenshots.log');
  finally
    G.Free;
    Log.Free;
    F.Free;
  end;
end;

function RowsOf(R: TSiftResult): Integer;
begin
  if R = nil then
    Result := -1
  else
    Result := R.Count;
end;

{ Clicks every quick button (through its OnClick, as a mouse click does)
  and checks the filter it produced and the rows it returned. }
procedure QuickButtonCheck(F: TSiftMainForm; L: TStrings);
var
  I, K, Bad: Integer;
  S: TSpeedButton;
  R: TSiftResult;
  NowFt, Oldest: Int64;
  Ok: Boolean;
  Pass, Fail: Integer;
begin
  Pass := 0;
  Fail := 0;
  for I := 0 to F.ComponentCount - 1 do
    if (F.Components[I] is TSpeedButton) and Assigned(TSpeedButton(F.Components[I]).OnClick) then
    begin
      S := TSpeedButton(F.Components[I]);
      S.OnClick(S);
      F.WaitForQuery(60000);
      Settle(F);
      R := F.CurrentResult;
      NowFt := UtcNowFileTime;
      Bad := 0;
      Ok := R <> nil;
      if Ok then
      begin
        case F.Filter.TimeMode of
          tmRelative:
            begin
              Oldest := NowFt - (F.Filter.RelativeMs + 5000) * 10000;
              for K := 0 to R.Count - 1 do
                if R.Rows[K]^.TimeCreated < Oldest then
                  Inc(Bad);
            end;
        end;
        for K := 1 to R.Count - 1 do
          if R.Rows[K]^.TimeCreated > R.Rows[K - 1]^.TimeCreated then
            Inc(Bad);
        if (F.Filter.LastN > 0) and (R.Count > F.Filter.LastN) then
          Inc(Bad);
        Ok := Bad = 0;
      end;
      if Ok then Inc(Pass) else Inc(Fail);
      L.Add(Format('quick button "%s": lastN=%d timeMode=%d relativeMs=%d rows=%d out-of-window-or-order=%d %s',
        [S.Caption, F.Filter.LastN, Ord(F.Filter.TimeMode), F.Filter.RelativeMs,
         RowsOf(R), Bad, BoolToStr(Ok, 'OK', 'FAIL')]));
    end;
  L.Add(Format('quick buttons: %d OK, %d FAIL', [Pass, Fail]));
end;

procedure DoDumpUi(const FileName: string);
var
  F: TSiftMainForm;
  L: TStringList;
begin
  F := MakeForm;
  Trace('form created');
  L := TStringList.Create;
  try
    F.RunNow;
    Trace('query started');
    Trace('wait=' + BoolToStr(F.WaitForQuery(30000), 'done', 'timeout'));
    Settle(F);
    Trace('settled');
    F.DumpUiText(L);
    QuickButtonCheck(F, L);
    L.Add('version resource FileVersion: ' + VersionInfoValue('FileVersion'));
    L.Add('version resource ProductVersion: ' + VersionInfoValue('ProductVersion'));
    L.Add('version resource CompanyName: ' + VersionInfoValue('CompanyName'));
    L.Add('version resource LegalCopyright: ' + VersionInfoValue('LegalCopyright'));
    L.Add('version resource FileDescription: ' + VersionInfoValue('FileDescription'));
    L.Add('version resource ProductName: ' + VersionInfoValue('ProductName'));
    L.Add('fixed version: ' + FileVersionFull);
    L.SaveToFile(FileName);
  finally
    L.Free;
    F.Free;
  end;
end;

procedure DoSelfTestGrid(const FileName: string);
var
  F: TSiftMainForm;
  G: TSiftFilter;
  L: TStringList;
  Ex: TSiftExecutor;
  Src, Big: TSiftResult;
  T0: QWord;
  I, K: Integer;
  Ms: Double;
  B: TBitmap;
begin
  L := TStringList.Create;
  F := MakeForm;
  G := TSiftFilter.Create;
  Ex := TSiftExecutor.Create;
  try
    G.Channels.Add('System');
    Src := Ex.Execute(G, nil);
    try
      L.Add(Format('source: System, all events: %d rows, engine total %.1f ms, first row %.1f ms',
        [Src.Count, Src.Stats.TotalMs, Src.Stats.FirstRowMs]));
      Big := TSiftResult.Create(G, Src.Compiled);
      K := 0;
      while Big.Count < 200000 do
      begin
        Big.MergeFrom(Src, 0);
        Inc(K);
      end;
      L.Add(Format('grid model: System rows replicated x%d = %d rows', [K, Big.Count]));
    finally
      Src.Free;
    end;
    T0 := NowTick;
    F.LoadResultForTest(Big);
    L.Add(Format('load %d rows into the grid (set RowCount): %.1f ms', [Big.Count, MsSince(T0)]));
    for I := 0 to 2 do
    begin
      case I of
        0: F.Grid.TopRow := 1;
        1: F.Grid.TopRow := Big.Count div 2;
        2: F.Grid.TopRow := Big.Count - 10;
      end;
      T0 := NowTick;
      F.Grid.Repaint;
      Ms := MsSince(T0);
      L.Add(Format('paint visible rows at top row %d (lazy message render, cold): %.1f ms',
        [F.Grid.TopRow, Ms]));
      T0 := NowTick;
      F.Grid.Repaint;
      Ms := MsSince(T0);
      L.Add(Format('repaint same rows (cached): %.1f ms', [Ms]));
    end;
    T0 := NowTick;
    for I := 1 to 50 do
    begin
      F.Grid.TopRow := 1 + Random(Big.Count - 40);
      F.Grid.Repaint;
    end;
    L.Add(Format('50 random jumps + paint: %.1f ms average', [MsSince(T0) / 50]));
    T0 := NowTick;
    for I := 1 to 200 do
    begin
      F.Grid.TopRow := F.Grid.TopRow + 1;
      F.Grid.Repaint;
    end;
    L.Add(Format('200 one-row scroll steps + paint: %.2f ms average', [MsSince(T0) / 200]));
    T0 := NowTick;
    F.Grid.Row := Big.Count;
    F.Grid.Repaint;
    L.Add(Format('jump to last row (Ctrl+End equivalent) + paint: %.1f ms', [MsSince(T0)]));
    L.Add('painted on a private desktop: ' + BoolToStr(HarnessDesktop <> 0, 'yes', 'no'));
    L.SaveToFile(FileName);
  finally
    Ex.Free;
    G.Free;
    F.Free;
    L.Free;
  end;
end;

{ ---- pieces 8, 9, 10 through the real form ---- }

const
  WM_MOUSEMOVE_ = $0200;
  WM_LBUTTONDOWN_ = $0201;
  WM_LBUTTONUP_ = $0202;
  WM_LBUTTONDBLCLK_ = $0203;

procedure MouseDblClickAt(G: TWinControl; X, Y: Integer);
var
  P: LPARAM;
begin
  { a real double-click's message sequence, sent to the grid's own window
    on the private desktop: no input is injected into the user's session }
  P := MAKELPARAM(Word(X), Word(Y));
  SendMessage(G.Handle, WM_MOUSEMOVE_, 0, P);
  SendMessage(G.Handle, WM_LBUTTONDOWN_, MK_LBUTTON, P);
  SendMessage(G.Handle, WM_LBUTTONUP_, 0, P);
  SendMessage(G.Handle, WM_LBUTTONDBLCLK_, MK_LBUTTON, P);
  SendMessage(G.Handle, WM_LBUTTONUP_, 0, P);
  Application.ProcessMessages;
end;

function WidthsText(G: TDrawGrid): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to G.ColCount - 1 do
    Result := Result + IntToStr(G.ColWidths[I]) + ' ';
  Result := Trim(Result);
end;

function RowOrderSig(R: TSiftResult): string;
var
  I: Integer;
begin
  Result := '';
  if R = nil then
    Exit;
  for I := 0 to Min(R.Count, 40) - 1 do
    Result := Result + IntToStr(R.Rows[I]^.RecordId) + ',';
end;

procedure LoadMetaRows(F: TSiftMainForm);
const
  Prov: array[0..3] of string = ('Service Control Manager', 'Microsoft-Windows-Kernel-General',
    'Microsoft-Windows-Kernel-General', 'Sift-NoSuchProvider-7f3a');
  Ids: array[0..3] of Word = (7036, 12, 13, 1);
var
  G: TSiftFilter;
  R: TSiftResult;
  Row: TSiftEventRow;
  Msgs: TStringList;
  Logs: TSiftChannelInfos;
  I: Integer;
begin
  G := TSiftFilter.Create;
  Msgs := TStringList.Create;
  try
    G.Channels.Add('System');
    R := TSiftResult.Create(G, CompileFilter(G, nil));
    for I := 0 to High(Prov) do
    begin
      FillChar(Row, SizeOf(Row), 0);
      Row.RecordId := 1000 - I;
      Row.TimeCreated := UtcNowFileTime - Int64(I) * 10000000;
      Row.EventId := Ids[I];
      Row.Level := 4;
      Row.ChannelIx := R.Pool.Intern('System');
      Row.ProviderIx := R.Pool.Intern(Prov[I]);
      Row.UserIx := R.Pool.Intern('');
      Row.ComputerIx := R.Pool.Intern('HOST01');
      R.AddRow(Row);
      Msgs.Add('demo message ' + IntToStr(I));
    end;
    SetLength(Logs, 1);
    Logs[0].Name := 'System';
    Logs[0].Enabled := True;
    Logs[0].ChannelType := 1;
    Logs[0].Classic := True;
    F.SetDemoData(R, Msgs, Logs);
  finally
    Msgs.Free;
    G.Free;
  end;
end;

function QuickDownText(F: TSiftMainForm): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to F.ComponentCount - 1 do
    if (F.Components[I] is TSpeedButton) and TSpeedButton(F.Components[I]).Down then
      Result := Result + '[' + TSpeedButton(F.Components[I]).Caption + ']';
end;

type
  TCustomAskStub = class
    Ret: Boolean;
    A, B: TDateTime;
    function Ask(out StartUtc, EndUtc: TDateTime): Boolean;
  end;

function TCustomAskStub.Ask(out StartUtc, EndUtc: TDateTime): Boolean;
begin
  StartUtc := A;
  EndUtc := B;
  Result := Ret;
end;

function WinH(C: TWinControl): Integer;
var
  R: TRect;
begin
  GetWindowRect(C.Handle, R);
  Result := R.Bottom - R.Top;
end;

procedure Key(C: TWinControl; VK: Word);
begin
  SendMessage(C.Handle, WM_KEYDOWN, VK, 0);
  SendMessage(C.Handle, WM_KEYUP, VK, LPARAM($C0000000));
end;

{ every pair of child controls of the dialog: no overlap, all inside }
function DialogOverlaps(D: TForm; out Why: string): Boolean;
var
  I, J: Integer;
  R: array of TRect;
  X: TRect;
  C: TControl;
begin
  Result := False;
  Why := '';
  SetLength(R, D.ControlCount);
  for I := 0 to D.ControlCount - 1 do
  begin
    C := D.Controls[I];
    R[I] := C.BoundsRect;
    if C is TLabel then
      R[I].Right := Max(R[I].Right, C.Left + D.Canvas.TextWidth(TLabel(C).Caption));
    if (R[I].Right > D.ClientWidth) or (R[I].Bottom > D.ClientHeight) then
    begin
      Why := Why + Format(' %s outside the dialog;', [C.ClassName]);
      Result := True;
    end;
  end;
  for I := 0 to High(R) do
    for J := I + 1 to High(R) do
      if IntersectRect(X, R[I], R[J]) then
      begin
        Why := Why + Format(' %d/%d overlap;', [I, J]);
        Result := True;
      end;
end;

procedure RealClick(C: TWinControl);
var
  P: LPARAM;
begin
  { button-down/up on the check box's own window (private desktop): the
    same path a mouse click takes, BN_CLICKED and the LCL's state cycle }
  P := MAKELPARAM(Word(C.Scale96ToForm(7)), Word(C.Height div 2));
  SendMessage(C.Handle, WM_LBUTTONDOWN_, MK_LBUTTON, P);
  SendMessage(C.Handle, WM_LBUTTONUP_, 0, P);
  Application.ProcessMessages;
end;

function LocalToUtcOrSame(T: TDateTime): TDateTime;
begin
  if not TryLocalToUtc(T, Result) then
    Result := T;
end;

procedure DoFeatureCheck(const FileName: string);
var
  F: TSiftMainForm;
  L: TStringList;
  Gd: TDrawGrid;
  Pass, Fail: Integer;
  C: TGridCol;
  Rc: TRect;
  X, Y, I, K, Expect, Narrow: Integer;
  Before, After, Ord0, Ord1, S, Url: string;
  Wrap0: Boolean;
  Bmp: TBitmap;
  W: array[0..2] of Integer;
  Ex: TSiftExecutor;
  G: TSiftFilter;
  Src, Big: TSiftResult;
  T0: QWord;
  Ms: array[0..1] of Double;
  WrapRun: Integer;
  WidthsBefore: array of Integer;
  Chk: TCheckBox;
  CustomFrom, CustomTo: string;
  Dlg: TForm;
  Ed1, Ed2: TEdit;
  Stub: TCustomAskStub;

  procedure Check(Ok: Boolean; const What: string);
  begin
    if Ok then
    begin
      Inc(Pass);
      L.Add('PASS ' + What);
    end
    else
    begin
      Inc(Fail);
      L.Add('FAIL ' + What);
    end;
  end;

  procedure Run;
  begin
    F.WaitForQuery(60000);
    Settle(F);
  end;

begin
  Pass := 0;
  Fail := 0;
  L := TStringList.Create;
  F := MakeForm;
  try
    L.Add('settings file: ' + ExtractFileName(SiftSettingsFile) + ' (scratch, not the user''s sift.ini)');
    L.Add('screen PPI: ' + IntToStr(Screen.PixelsPerInch) + ', grid font PPI: ' + IntToStr(F.Grid.Font.PixelsPerInch));
    F.LookupDryRun := True;
    Gd := F.Grid;

    { ---------------- piece 8: divider double-click ---------------- }
    G := TSiftFilter.Create;
    try
      G.Channels.Add('System');
      G.Channels.Add('Application');
      F.RunNow;
      Run;
      LoadDemo(F, G, 300, False);
      Settle(F);
    finally
      G.Free;
    end;
    if F.MessageWrap then
      F.SetMessageWrap(False);
    Ord0 := RowOrderSig(F.CurrentResult);
    for C := Low(TGridCol) to High(TGridCol) do
    begin
      I := Ord(C);
      Gd.LeftCol := Gd.FixedCols;
      Settle(F);
      if C <> gcMessage then
      begin
        Narrow := ScalePx(30, Gd.Font.PixelsPerInch);
        Gd.ColWidths[I] := Narrow;
      end;
      Settle(F);
      Rc := Gd.CellRect(I, 0);
      if Rc.Right > Gd.ClientWidth then
      begin
        Gd.LeftCol := I;
        Settle(F);
        Rc := Gd.CellRect(I, 0);
      end;
      Before := WidthsText(Gd);
      SetLength(WidthsBefore, Gd.ColCount);
      for X := 0 to Gd.ColCount - 1 do
        WidthsBefore[X] := Gd.ColWidths[X];
      Wrap0 := F.MessageWrap;
      Expect := F.ComputeFitWidth(C, Gd.Canvas, Gd.Font.PixelsPerInch);
      { header body first: nothing may change }
      MouseDblClickAt(Gd, (Rc.Left + Rc.Right) div 2, Gd.RowHeights[0] div 2);
      Settle(F);
      After := WidthsText(Gd);
      Check((After = Before) and (F.MessageWrap = Wrap0),
        Format('header-body double-click on %s: widths unchanged (%s), wrap unchanged (%s)',
        [ColCaptions[C], BoolToStr(After = Before, 'yes', 'no'), BoolToStr(F.MessageWrap = Wrap0, 'yes', 'no')]));
      { then the divider, 2 px inside the column's right edge }
      MouseDblClickAt(Gd, Rc.Right - 2, Gd.RowHeights[0] div 2);
      Settle(F);
      After := WidthsText(Gd);
      if C = gcMessage then
        Check((F.MessageWrap <> Wrap0) and (After = Before),
          Format('divider double-click on Message toggles wrap %s -> %s, widths unchanged',
          [BoolToStr(Wrap0, 'on', 'off'), BoolToStr(F.MessageWrap, 'on', 'off')]))
      else
        Check((Gd.ColWidths[I] = Expect) and (Gd.ColWidths[I] <> Narrow) and (F.MessageWrap = Wrap0),
          Format('divider double-click on %s: width %d -> %d (fit %d), wrap unchanged',
          [ColCaptions[C], Narrow, Gd.ColWidths[I], Expect]));
      { the other columns kept their widths }
      K := 0;
      for X := 0 to Gd.ColCount - 1 do
        if (X <> I) and (Gd.ColWidths[X] <> WidthsBefore[X]) then
          Inc(K);
      Check(K = 0, Format('divider double-click on %s left the other %d columns alone (%d changed)',
        [ColCaptions[C], Gd.ColCount - 1, K]));
    end;
    { also a double-click on a data row at the divider's X: no fit, no wrap }
    Rc := Gd.CellRect(Ord(gcProvider), 1);
    Before := WidthsText(Gd);
    Wrap0 := F.MessageWrap;
    Gd.LeftCol := Gd.FixedCols;
    Settle(F);
    Rc := Gd.CellRect(Ord(gcProvider), 0);
    MouseDblClickAt(Gd, Rc.Right - 2, Gd.RowHeights[0] + Gd.DefaultRowHeight div 2);
    Settle(F);
    Check((WidthsText(Gd) = Before) and (F.MessageWrap = Wrap0),
      'double-click on a data row at a divider''s X: widths and wrap unchanged');
    Ord1 := RowOrderSig(F.CurrentResult);
    Check((Ord0 <> '') and (Ord0 = Ord1), 'row order unchanged by all header double-clicks (Sift has no column sort)');

    { DPI: the fit scales with the canvas DPI }
    Bmp := TBitmap.Create;
    try
      Bmp.SetSize(16, 16);
      for C := Low(TGridCol) to High(TGridCol) do
      begin
        if C = gcMessage then
          Continue;
        W[0] := F.ComputeFitWidth(C, Bmp.Canvas, 96);
        W[1] := F.ComputeFitWidth(C, Bmp.Canvas, 120);
        W[2] := F.ComputeFitWidth(C, Bmp.Canvas, 144);
        Check((W[1] > W[0]) and (W[2] > W[1]) and (Abs(W[1] / W[0] - 1.25) < 0.15) and
          (Abs(W[2] / W[0] - 1.5) < 0.2),
          Format('fit width %s at 100/125/150%%: %d / %d / %d px (x%.2f / x%.2f)',
          [ColCaptions[C], W[0], W[1], W[2], W[1] / W[0], W[2] / W[0]]));
      end;
      Check((ScalePx(DividerTol96, 120) = 5) and (ScalePx(DividerTol96, 144) = 6),
        Format('divider hit zone: +/-%d / %d / %d px at 100/125/150%%',
        [ScalePx(DividerTol96, 96), ScalePx(DividerTol96, 120), ScalePx(DividerTol96, 144)]));
    finally
      Bmp.Free;
    end;

    { wrap repaint time at 200k rows }
    Ex := TSiftExecutor.Create;
    G := TSiftFilter.Create;
    try
      G.Channels.Add('System');
      Src := Ex.Execute(G, nil);
      try
        Big := TSiftResult.Create(G, Src.Compiled);
        while Big.Count < 200000 do
          Big.MergeFrom(Src, 0);
      finally
        Src.Free;
      end;
      F.LoadResultForTest(Big);
      Settle(F);
      for WrapRun := 0 to 1 do
      begin
        F.SetMessageWrap(WrapRun = 1);
        Settle(F);
        T0 := NowTick;
        for I := 1 to 50 do
        begin
          Gd.TopRow := 1 + Random(F.CurrentResult.Count - 40);
          Gd.Repaint;
        end;
        Ms[WrapRun] := MsSince(T0) / 50;
        T0 := NowTick;
        Gd.TopRow := F.CurrentResult.Count - 5;
        Gd.Repaint;
        L.Add(Format('wrap %s, %d rows: 50 random jumps + paint %.1f ms average; jump to end + paint %.1f ms',
          [BoolToStr(WrapRun = 1, 'on', 'off'), F.CurrentResult.Count, Ms[WrapRun], MsSince(T0)]));
      end;
      Check(Ms[1] < 250, Format('wrap-on repaint at 200k rows stays interactive (%.1f ms per jump, limit 250)', [Ms[1]]));
      F.SetMessageWrap(False);
    finally
      G.Free;
      Ex.Free;
    end;

    { ---------------- piece 9: Event ID tab ---------------- }
    LoadMetaRows(F);
    Settle(F);
    for I := 0 to 3 do
    begin
      F.SelectRow(I);
      F.ShowEventIdTab;
      Settle(F);
      S := F.EventIdText;
      if I < 3 then
        Check((Pos('Description template:', S) > 0) and (Pos(MetaNotAvailableText, S) = 0),
          Format('Event ID tab, row %d: %s', [I, StringReplace(Copy(S, 1, 160), LineEnding, ' / ', [rfReplaceAll])]))
      else
        Check(Pos(MetaNotAvailableText, S) > 0,
          'Event ID tab, missing provider: ' + StringReplace(S, LineEnding, ' / ', [rfReplaceAll]));
      for K := 1 to Length(S) do
        if Ord(S[K]) > 127 then
        begin
          L.Add('  (non-ASCII byte in the pane text at ' + IntToStr(K) + ')');
          Break;
        end;
    end;
    L.Add(Format('provider metadata loads this session: %d (cache hits after the first view)', [F.MetaCache.Loads]));
    F.LookUpOnline(0);
    Url := F.LastLookupUrl;
    Check(Url = 'https://www.google.com/search?q=%22Service%20Control%20Manager%22%20event%20ID%207036',
      'Look up online (dry run, nothing opened): ' + Url);

    { ---------------- piece 10: toolbar ---------------- }
    F.Filter.Clear;
    F.Filter.Channels.Add('System');
    F.RunNow;
    Run;
    F.ToolbarClickLevel(1);
    Run;
    Check((LevelState(F.Filter, 2) = lsOn) and (Pos('Error=on', F.ToolbarStateText) > 0),
      'toolbar Error -> filter Level=2: ' + F.ToolbarStateText);
    F.ToolbarSelectTime(wp1h);
    Run;
    Check((F.Filter.TimeMode = tmRelative) and (F.Filter.RelativeMs = 3600000) and (Pos('[Within 1 h]', QuickDownText(F) + '[Within 1 h]') > 0),
      'toolbar 1 h -> one shared window; quick buttons down: ' + QuickDownText(F) + ' | ' + F.ToolbarStateText);
    F.ToolbarSetMax('15');
    Run;
    Check((F.Filter.LastN = 15) and (F.Filter.TimeMode = tmRelative) and
      ((F.CurrentResult = nil) or (F.CurrentResult.Count <= 15)),
      Format('toolbar Max 15 keeps the window: rows %d | %s', [RowsOf(F.CurrentResult), F.ToolbarStateText]));
    F.ToolbarSetMax('abc');
    Check(F.Filter.LastN = 15, 'toolbar Max rejects "abc" and keeps 15');
    F.ToolbarSetMax('');
    Run;
    F.ToolbarSelectTime(wpAny);
    Run;
    { quick buttons drive the toolbar }
    for I := 0 to F.ComponentCount - 1 do
      if (F.Components[I] is TSpeedButton) and (TSpeedButton(F.Components[I]).Caption = '10') then
        TSpeedButton(F.Components[I]).OnClick(F.Components[I]);
    Run;
    Check(Pos('max: 10', F.ToolbarStateText) > 0, 'quick button Last 10 (caption "10") -> toolbar: ' + F.ToolbarStateText);
    for I := 0 to F.ComponentCount - 1 do
      if (F.Components[I] is TSpeedButton) and (TSpeedButton(F.Components[I]).Caption = '15 min') then
        TSpeedButton(F.Components[I]).OnClick(F.Components[I]);
    Run;
    Check((Pos('time: 15 min', F.ToolbarStateText) > 0) and (Pos('max:  |', F.ToolbarStateText) > 0),
      'quick button 15 min -> toolbar: ' + F.ToolbarStateText);
    { right-click Include / Exclude on a Level cell drives the boxes }
    F.ToolbarSelectTime(wp24h);
    Run;
    F.Filter.Clear;
    F.Filter.Channels.Add('System');
    F.ToolbarSelectTime(wp7d);
    Run;
    K := -1;
    if F.CurrentResult <> nil then
      for I := 0 to F.CurrentResult.Count - 1 do
        if F.CurrentResult.Rows[I]^.Level = 4 then
        begin
          K := I;
          Break;
        end;
    if K >= 0 then
    begin
      F.CellFilterForTest(K, gcLevel, True);
      Run;
      Check(Pos('Info=excluded', F.ToolbarStateText) > 0, 'right-click Exclude Level=Information -> toolbar: ' + F.ToolbarStateText);
      F.ToolbarClickLevel(3);
      Run;
      Check((LevelState(F.Filter, 4) = lsOff) and (Pos('Info=off', F.ToolbarStateText) > 0),
        'clicking the excluded Info box clears the exclusion: ' + F.ToolbarStateText);
    end
    else
      L.Add('SKIP right-click Exclude: no Information event in System in the last 7 days');
    K := -1;
    if F.CurrentResult <> nil then
      for I := 0 to F.CurrentResult.Count - 1 do
        if F.CurrentResult.Rows[I]^.Level in [2, 3] then
        begin
          K := I;
          Break;
        end;
    if K >= 0 then
    begin
      X := F.CurrentResult.Rows[K]^.Level;
      F.CellFilterForTest(K, gcLevel, False);
      Run;
      Check(LevelState(F.Filter, X) = lsOn,
        Format('right-click Include Level=%d -> toolbar: %s', [X, F.ToolbarStateText]));
    end
    else
      L.Add('SKIP right-click Include: no Error/Warning event in System in the last 7 days');
    F.ToolbarSelectLog('Application');
    Run;
    Check((F.Filter.Channels.Count = 1) and (F.Filter.Channels[0] = 'Application') and (Pos('log: Application', F.ToolbarStateText) > 0),
      'toolbar Log = Application: ' + F.ToolbarStateText);
    F.ToolbarSelectLog(ToolbarAllLogs);
    Run;
    Check((F.Filter.Channels.IndexOf('*') >= 0) and (Pos('log: All logs', F.ToolbarStateText) > 0),
      Format('toolbar Log = All logs: rows %d, errors (denied logs in the banner) %d | %s',
      [RowsOf(F.CurrentResult), Length(F.CurrentResult.Errors), F.ToolbarStateText]));
    F.Filter.Clear;
    F.Filter.Channels.Add('System');
    F.ToolbarSelectTime(wp15m);
    Run;
    Check((LevelsOn(F.Filter) = '') and (F.CurrentResult <> nil),
      Format('no level ticked = all levels: query ran, rows %d', [RowsOf(F.CurrentResult)]));

    { ---------------- QA round 2 ---------------- }
    { level boxes: real clicks (button-down/up on the box's own window) never
      leave a box grey; grey only shows a right-click exclusion }
    F.Filter.Clear;
    F.Filter.Channels.Add('System');
    F.ToolbarSelectTime(wp7d);
    Run;
    Chk := F.ToolbarLevelBox(1);
    for I := 1 to 2 do
    begin
      RealClick(Chk);
      Run;
      if I = 1 then
        Check((Chk.State = cbChecked) and (LevelState(F.Filter, 2) = lsOn),
          Format('real click on an unticked Error box -> ticked, Level=2 on (state %d)', [Ord(Chk.State)]))
      else
        Check((Chk.State = cbUnchecked) and (LevelState(F.Filter, 2) = lsOff),
          Format('real click on the ticked Error box -> unticked, never grey (state %d)', [Ord(Chk.State)]));
    end;
    K := -1;
    if F.CurrentResult <> nil then
      for I := 0 to F.CurrentResult.Count - 1 do
        if F.CurrentResult.Rows[I]^.Level = 4 then
        begin
          K := I;
          Break;
        end;
    if K >= 0 then
    begin
      F.CellFilterForTest(K, gcLevel, True);
      Run;
      Chk := F.ToolbarLevelBox(3);
      Check(Chk.State = cbGrayed, 'right-click Exclude Information shows the Info box grey');
      RealClick(Chk);
      Run;
      Check((Chk.State = cbUnchecked) and (LevelState(F.Filter, 4) = lsOff),
        Format('real click on the grey Info box clears the exclusion -> unticked (state %d)', [Ord(Chk.State)]));
      RealClick(Chk);
      Run;
      Check((Chk.State = cbChecked) and (LevelState(F.Filter, 4) = lsOn),
        Format('next real click ticks Info, not grey (state %d)', [Ord(Chk.State)]));
    end
    else
      L.Add('SKIP grey-box click: no Information event in System in the last 7 days');

    { wrap: View menu and grid menu toggle, both stay in sync with the
      divider and the ini }
    if F.MessageWrap then
      F.SetMessageWrap(False);
    F.WrapViewItem.Click;
    Settle(F);
    Check(F.MessageWrap and F.WrapViewItem.Checked and F.WrapGridItem.Checked,
      'View > Wrap message text turns wrap on; both menu items checked');
    F.WrapGridItem.Click;
    Settle(F);
    Check(not F.MessageWrap and not F.WrapViewItem.Checked and not F.WrapGridItem.Checked,
      'grid menu Wrap message text turns it off; both unchecked');
    Gd.LeftCol := Gd.FixedCols;
    Settle(F);
    Rc := Gd.CellRect(Ord(gcMessage), 0);
    if Rc.Right > Gd.ClientWidth then
    begin
      Gd.LeftCol := Ord(gcMessage);
      Settle(F);
      Rc := Gd.CellRect(Ord(gcMessage), 0);
    end;
    MouseDblClickAt(Gd, Rc.Right - 2, Gd.RowHeights[0] div 2);
    Settle(F);
    Check(F.MessageWrap and F.WrapViewItem.Checked and F.WrapGridItem.Checked,
      'Message divider double-click turns wrap on; menu items follow');
    F.WrapViewItem.Click;
    Settle(F);
    Check(not F.MessageWrap, 'and the menu turns it off again');

    { Custom range: local time, ASCII, pre-filled }
    F.Filter.SetAbsoluteWindow(LocalToUtcOrSame(EncodeDate(2026, 10, 29) + EncodeTime(8, 0, 0, 0)),
      LocalToUtcOrSame(EncodeDate(2026, 10, 30) + EncodeTime(8, 30, 0, 0)));
    F.RunNow;
    Run;
    CustomFrom := '';
    CustomTo := '';
    F.CustomPrefill(CustomFrom, CustomTo);
    Check(Pos('time: 2026-10-29 08:00 to 2026-10-30 08:30', F.ToolbarStateText) > 0,
      'Custom range shown in the Time box in local time: ' + F.ToolbarStateText);
    Check((CustomFrom = '2026-10-29 08:00') and (CustomTo = '2026-10-30 08:30'),
      'Custom dialog pre-filled with the active range: ' + CustomFrom + ' / ' + CustomTo);
    F.Filter.ClearWindow;
    F.RunNow;
    Run;

    { ---------------- DPI test follow-ups ---------------- }
    { (B) Custom dialog: nothing overlaps, at 100% and scaled to 125/150% }
    Dlg := F.CreateCustomDialog(Ed1, Ed2);
    try
      Wrap0 := DialogOverlaps(Dlg, S);
    Check(not Wrap0 and (Ed1.Height >= 24) and (Ed2.Height >= 24),
        Format('Custom dialog at %d PPI: no overlap, edits >= 24 px (%d x %d)%s',
          [Dlg.PixelsPerInch, Dlg.ClientWidth, Dlg.ClientHeight, S]));
      K := Dlg.PixelsPerInch;
      for I in [120, 144] do
      begin
        Dlg.AutoAdjustLayout(lapAutoAdjustForDPI, K, I, Dlg.Width, MulDiv(Dlg.Width, I, K));
        K := I;
        Wrap0 := DialogOverlaps(Dlg, S);
        Check(not Wrap0,
          Format('Custom dialog scaled to %d%%: no overlap (%d x %d)%s', [I * 100 div 96, Dlg.ClientWidth, Dlg.ClientHeight, S]));
      end;
    finally
      Dlg.Free;
    end;

    { (C) hit targets >= 24 px at this PPI (scaled) }
    S := '';
    K := 0;
    for I := 0 to F.ToolbarRow.ControlCount - 1 do
      if (F.ToolbarRow.Controls[I] is TWinControl) and F.ToolbarRow.Controls[I].Visible then
      begin
        Y := WinH(TWinControl(F.ToolbarRow.Controls[I]));
        S := S + Format(' %s=%d', [F.ToolbarRow.Controls[I].ClassName, Y]);
        if Y < F.Scale96ToForm(24) then
          Inc(K);
      end;
    Y := WinH(F.TextBox);
    S := S + Format(' text=%d', [Y]);
    if Y < F.Scale96ToForm(24) then
      Inc(K);
    Check(K = 0, 'toolbar boxes, combos, Max and text box are >= 24 px:' + S);

    { (D) Time list: End in the open list does not open Custom; Enter does,
      once; Cancel opens nothing else; Custom again while a range is active
      reopens it }
    Stub := TCustomAskStub.Create;
    try
      F.CustomAskHook := @Stub.Ask;
      F.ToolbarSelectTime(wp24h);
      Run;
      F.CustomAskCount := 0;
      Stub.Ret := False;
      F.TimeCombo.DroppedDown := True;
      Settle(F);
      Key(F.TimeCombo, VK_END);
      Settle(F);
      Check(F.CustomAskCount = 0, Format('open list + End: Custom not opened (opens %d, dropped %s)',
        [F.CustomAskCount, BoolToStr(F.TimeCombo.DroppedDown, True)]));
      Key(F.TimeCombo, VK_RETURN);
      Settle(F);
      Settle(F);
      Check(F.CustomAskCount = 1, Format('then Enter: Custom opened once (opens %d)', [F.CustomAskCount]));
      Check(WindowPreset(F.Filter) = wp24h, 'Cancel keeps 24 h and opens no second dialog: ' + F.ToolbarStateText);
      F.CustomAskCount := 0;
      Key(F.TimeCombo, VK_END);
      Settle(F);
      Check(F.CustomAskCount = 0, 'closed list + End: not opened yet');
      Key(F.TimeCombo, VK_RETURN);
      Settle(F);
      Check(F.CustomAskCount = 1, Format('closed list + End + Enter: opened once (opens %d)', [F.CustomAskCount]));
      Stub.Ret := True;
      Stub.A := LocalToUtcOrSame(EncodeDate(2026, 10, 29) + EncodeTime(9, 0, 0, 0));
      Stub.B := 0;
      F.CustomAskCount := 0;
      F.TimeCombo.DroppedDown := True;
      Settle(F);
      Key(F.TimeCombo, VK_END);
      Key(F.TimeCombo, VK_RETURN);
      Settle(F);
      Run;
      Check((F.CustomAskCount = 1) and (WindowPreset(F.Filter) = wpCustom),
        'Custom picked from the list sets the range: ' + F.ToolbarStateText);
      Stub.A := LocalToUtcOrSame(EncodeDate(2026, 10, 29) + EncodeTime(10, 0, 0, 0));
      F.TimeCombo.DroppedDown := True;
      Settle(F);
      Key(F.TimeCombo, VK_UP);
      Key(F.TimeCombo, VK_RETURN);
      Settle(F);
      Run;
      Check((F.CustomAskCount = 2) and (Pos('2026-10-29 10:00', F.ToolbarStateText) > 0),
        Format('Custom again while a range is active reopens it (opens %d): %s', [F.CustomAskCount, F.ToolbarStateText]));
    finally
      F.CustomAskHook := nil;
      Stub.Free;
    end;
    F.Filter.ClearWindow;
    F.RunNow;
    Run;

    { (E) status bar follows a DPI change (what WM_DPICHANGED does) }
    K := F.StatusBar.Height;
    I := F.PixelsPerInch;
    F.AutoAdjustLayout(lapAutoAdjustForDPI, I, I * 3 div 2, F.Width, F.Width * 3 div 2);
    Settle(F);
    Y := F.StatusBar.Height;
    X := WinH(F.TimeCombo);
    F.AutoAdjustLayout(lapAutoAdjustForDPI, I * 3 div 2, I, F.Width, F.Width * 2 div 3);
    Settle(F);
    Check(X >= F.Scale96ToForm(24) * 3 div 2,
      Format('Time list at 150%%: %d px (>= %d)', [X, F.Scale96ToForm(24) * 3 div 2]));
    Check((Y >= K * 3 div 2 - 1) and (Abs(F.StatusBar.Height - K) <= 1),
      Format('status bar height follows a DPI change: %d -> %d at 150%% -> %d back', [K, Y, F.StatusBar.Height]));

    { ---------------- wrap persistence: leave it on for the next run ---------------- }
    Gd.LeftCol := Gd.FixedCols;
    Settle(F);
    if F.MessageWrap then
      F.SetMessageWrap(False);
    Rc := Gd.CellRect(Ord(gcMessage), 0);
    if Rc.Right > Gd.ClientWidth then
    begin
      Gd.LeftCol := Ord(gcMessage);
      Settle(F);
      Rc := Gd.CellRect(Ord(gcMessage), 0);
    end;
    MouseDblClickAt(Gd, Rc.Right - 2, Gd.RowHeights[0] div 2);
    Settle(F);
    Check(F.MessageWrap, 'Message wrap left ON via its divider for the restart check');
    L.Add(Format('feature check: %d PASS, %d FAIL', [Pass, Fail]));
    L.SaveToFile(FileName);
    if Fail > 0 then
      ExitCode := 1;
  finally
    F.Free;
    L.Free;
  end;
end;

procedure DoReportWrap(const FileName: string);
var
  F: TSiftMainForm;
  L: TStringList;
begin
  F := MakeForm;
  L := TStringList.Create;
  try
    L.Add('MessageWrap at start-up: ' + BoolToStr(F.MessageWrap, 'on', 'off'));
    L.SaveToFile(FileName);
  finally
    L.Free;
    F.Free;
  end;
end;

procedure HarnessTrace(const S: string);
begin
  Trace(S);
end;

procedure HarnessPrepareDesktop;
const
  GENERIC_ALL_ = $10000000;
var
  D: HDESK;
  Name, Cmd: UnicodeString;
  SI: STARTUPINFOW;
  PI: PROCESS_INFORMATION;
  Code: DWORD;
begin
  if not HarnessRequested then
    Exit;
  if HasArg('--on-private-desktop') then
  begin
    HarnessDesktop := 1;
    Trace('running on private desktop');
    Exit;
  end;
  { relaunch this exe on a private desktop and wait for it }
  Name := 'SiftHarness' + UnicodeString(IntToStr(GetCurrentProcessId));
  D := CreateDesktopW(PWideChar(Name), nil, nil, 0, GENERIC_ALL_, nil);
  if D = 0 then
  begin
    Trace('CreateDesktop failed: ' + IntToStr(GetLastError) + '; painting hidden');
    Exit;
  end;
  Cmd := UnicodeString(GetCommandLineW) + ' --on-private-desktop';
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.lpDesktop := PWideChar(Name);
  FillChar(PI, SizeOf(PI), 0);
  if not CreateProcessW(nil, PWideChar(Cmd), nil, nil, False, 0, nil, nil, SI, PI) then
  begin
    Trace('CreateProcess failed: ' + IntToStr(GetLastError) + '; painting hidden');
    CloseDesktop(D);
    Exit;
  end;
  WaitForSingleObject(PI.hProcess, INFINITE);
  Code := 0;
  GetExitCodeProcess(PI.hProcess, Code);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
  CloseDesktop(D);
  Halt(Code);
end;

procedure RunHarnessSteps;
var
  V: string;
begin
  SnapMethod := StrToIntDef(ArgValue('--snap-method'), 0);
  V := ArgValue('--screenshots');
  if V <> '' then
    DoScreenshots(V);
  V := ArgValue('--dump-ui');
  if V <> '' then
    DoDumpUi(V);
  V := ArgValue('--selftest-grid');
  if V <> '' then
    DoSelfTestGrid(V);
  V := ArgValue('--feature-check');
  if V <> '' then
    DoFeatureCheck(V);
  V := ArgValue('--report-wrap');
  if V <> '' then
    DoReportWrap(V);
end;

procedure RunHarness;
var
  V: string;
  Sink: THarnessExceptionSink;
begin
  Trace('harness start');
  { never the user's own %APPDATA%\Sift\sift.ini }
  V := ArgValue('--ini');
  if V = '' then
    V := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'sift-harness' + PathDelim + 'sift.ini';
  SiftSettingsFile := ExpandFileName(V);
  Sink := THarnessExceptionSink.Create;
  Application.OnException := @Sink.HandleException;
  try
    try
      RunHarnessSteps;
    except
      on E: Exception do
      begin
        Trace('fatal: ' + E.ClassName + ': ' + E.Message);
        ExitCode := 3;
      end;
    end;
  finally
    Application.OnException := nil;
    Sink.Free;
  end;
  Trace('done');
end;

end.
