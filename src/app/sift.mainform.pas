unit Sift.MainForm;

{ The Sift viewer: filter bar (quick buttons, channel picker, chips), a
  virtual owner-drawn grid, a detail pane (message + XML) and a collapsible
  query panel. All filtering goes through SiftCore. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Types, Math, Forms, Controls, Graphics, Dialogs,
  StdCtrls, ExtCtrls, ComCtrls, Grids, Menus, Buttons, Clipbrd, LCLType,
  LCLIntf, CheckLst, Generics.Collections,
  Sift.EvtApi, Sift.Filter, Sift.Compiler, Sift.FilterJson, Sift.Query,
  Sift.Channels, Sift.Sids, Sift.Shell, Sift.ColFit, Sift.PubMeta, Sift.Toolbar;

type
  TSiftMainForm = class;
  TSiftCustomAsk = function(out StartUtc, EndUtc: TDateTime): Boolean of object;

  { Runs one query off the UI thread and streams rows back. }
  TQueryThread = class(TThread)
  private
    FOwner: TSiftMainForm;
    FFilter: TSiftFilter;
    FAll: TStringList;
    FGen: Integer;
    FCancel: Boolean;
    FResult: TSiftResult;
    FProgressResult: TSiftResult;
    FError: string;
    FCapApplied: Integer;
    FRowCapHit: Boolean;
    procedure OnProgress(R: TSiftResult; var Cancel: Boolean);
    procedure SyncProgress;
    procedure SyncDone;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TSiftMainForm; F: TSiftFilter; All: TStrings;
      Gen: Integer; RowCap: Integer = 0);
    destructor Destroy; override;
    procedure Cancel;
  end;

  TDividerEvent = procedure(Sender: TObject; ACol: Integer) of object;

  { The event grid. A double-click on a column divider (the resizer zone at
    a header's right edge) raises OnDividerDblClick; a double-click anywhere
    else, including the header body, does nothing special. }
  TSiftGrid = class(TDrawGrid)
  private
    FDownX, FDownY: Integer;
    FOnDividerDblClick: TDividerEvent;
  protected
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
  public
    { column whose divider is at client X, Y, or -1 }
    function DividerAt(X, Y: Integer): Integer;
    property OnDividerDblClick: TDividerEvent read FOnDividerDblClick write FOnDividerDblClick;
  end;

  TGridCol = (gcTime, gcLevel, gcChannel, gcProvider, gcEventId, gcTask,
    gcUser, gcComputer, gcMessage);

  { TSiftMainForm }

  TSiftMainForm = class(TForm)
  private
    { filter bar }
    FTop: TPanel;
    FRow1, FRow2: TPanel;
    FBtnLogs: TButton;
    FLblLast, FLblWin: TLabel;
    FLastBtns: array[0..3] of TSpeedButton;
    FWinBtns: array[0..5] of TSpeedButton;
    FBtnAll: TSpeedButton;
    FBtnRefresh: TButton;
    FBtnQuery: TButton;
    FLblText: TLabel;
    FEdText: TEdit;
    FBtnTextInc, FBtnTextExc: TButton;
    FLblTextNote: TLabel;
    FChips: TFlowPanel;
    { easy-button toolbar (Piece 10): a view of FFilter, no state of its own }
    FRowTb: TPanel;
    FTimeCustomPending, FInCustomDialog, FTimeCommitQueued: Boolean;
    FStatusH, FComboH: Double;
    {$IFDEF SIFT_HARNESS}
    FCustomAskHook: TSiftCustomAsk;
    FCustomAskCount: Integer;
    {$ENDIF}
    FLblLevel, FLblTime, FLblMax, FLblLog: TLabel;
    FChkLevel: array[0..4] of TCheckBox;
    FCbTime, FCbLog: TComboBox;
    FEdMax: TEdit;
    FSyncing: Boolean;
    FBanner: TPanel;
    FBannerLbl: TLabel;
    FBtnElevate: TButton;
    { query panel }
    FQueryPanel: TPanel;
    FMemoQuery, FMemoFH: TMemo;
    FBtnCopyQuery, FBtnCopyFH, FBtnExportPs: TButton;
    FLblQuery, FLblFH: TLabel;
    { grid + detail }
    FGrid: TSiftGrid;
    FSplit: TSplitter;
    FQueryHead: TPanel;
    FPages: TPageControl;
    FMemoMsg, FMemoXml, FMemoMeta: TMemo;
    FStatus: TStatusBar;
    { menus }
    FMainMenu: TMainMenu;
    FGridMenu: TPopupMenu;
    FMiInclude, FMiExclude, FMiIncAdd, FMiIncSet, FMiExcAdd, FMiExcSet,
      FMiCopyCell, FMiCopyRow, FMiLookup, FMiWrapView, FMiWrapGrid: TMenuItem;
    FMiShowQuery, FMiStartWin, FMiStartMenu, FMiCloseTray: TMenuItem;
    { tray }
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FTrayOk: Boolean;
    { state }
    FFilter: TSiftFilter;
    FAllChannels: TStringList;
    FChannelInfos: TSiftChannelInfos;
    FResult: TSiftResult;
    FThread: TQueryThread;
    FOldThreads: TList;
    FGen: Integer;
    FRenderer: TSiftRenderer;
    FMsgCache: specialize TDictionary<Integer, string>;
    FTaskCache: specialize TDictionary<string, string>;
    FMenuCol: TGridCol;
    FMenuRow: Integer;
    FDetailTimer: TTimer;
    FReapTimer: TTimer;
    FSettings: TSiftSettings;
    FReallyClose: Boolean;
    FVersion: string;
    FRunning: Boolean;
    FRedact: Boolean;
    FRedactMap: TStringList;
    FResultGen: Integer;
    FRowCap: Integer;
    FRowCapHit: Boolean;
    FDemoMessages: TStringList;
    { column auto-fit and Message wrap }
    FWrap: Boolean;
    FWrapRows: specialize TDictionary<Integer, Boolean>;
    FInWrap: Boolean;
    FLastFitCol: Integer;
    FLastFitWidth: Integer;
    { Event ID lookup }
    FMetaCache: TSiftMetaCache;
    FDetailProvider: string;
    FDetailId, FDetailQual, FDetailVer: Integer;
    FMetaShownFor: string;
    FLookupDryRun: Boolean;
    FLastLookupUrl: string;
    procedure ShowMeta;
    procedure PagesChange(Sender: TObject);
    procedure MiLookupClick(Sender: TObject);
    procedure GridDividerDblClick(Sender: TObject; ACol: Integer);
    procedure GridTopLeftChanged(Sender: TObject);
    procedure GridHeaderSized(Sender: TObject; IsColumn: Boolean; Index: Integer);
    procedure UpdateWrapCaption;
    procedure MiWrapClick(Sender: TObject);
    procedure ResetWrapHeights;
    function WrapHeightFor(I: Integer; Cv: TCanvas; TextW: Integer): Integer;
    function TaskTextReady(I: Integer): Boolean;
    procedure BuildToolbar;
    procedure SyncToolbar;
    procedure LevelChkClick(Sender: TObject);
    procedure TimeComboSelect(Sender: TObject);
    procedure TimeComboCloseUp(Sender: TObject);
    procedure TimeComboKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TimeComboExit(Sender: TObject);
    procedure TimeComboCommit;
    procedure TimeComboCommitAsync(Data: PtrInt);
    function TimeComboPreset: TSiftWindowPreset;
    procedure MaxEditDone(Sender: TObject);
    procedure MaxKeyPress(Sender: TObject; var Key: Char);
    procedure LogComboSelect(Sender: TObject);
    function AskCustomWindow(out StartUtc, EndUtc: TDateTime): Boolean;
    procedure BuildUi;
    procedure BuildMenus;
    procedure BuildTray;
    function MakeButton(AParent: TWinControl; const ACaption: string;
      AWidth: Integer; AOnClick: TNotifyEvent): TButton;
    function MakeSpeed(AParent: TWinControl; const ACaption: string;
      AWidth, ATag: Integer; AOnClick: TNotifyEvent): TSpeedButton;
    function MakeLabel(AParent: TWinControl; const ACaption: string): TLabel;
    procedure LayoutRow(Row: TPanel);
    function ComboItemHeight: Integer;
    procedure LoadChannels;
    procedure UpdateLogsCaption;
    procedure UpdateChips;
    procedure UpdateQuickButtons;
    procedure UpdateQueryPanel;
    procedure UpdateStatus;
    procedure UpdateBanner;
    procedure ClearDetail;
    procedure ShowDetail;
    function RowMessage(I: Integer): string;
    function RowTaskText(I: Integer): string;
    function CellText(I: Integer; C: TGridCol): string;
    function CellFilterValue(I: Integer; C: TGridCol; out F: TSiftField;
      out V: string): Boolean;
    function Redacted(const S: string): string;
    procedure StartQuery;
    procedure CancelQuery;
    procedure ReceiveProgress(T: TQueryThread; R: TSiftResult);
    procedure ReceiveDone(T: TQueryThread);
    procedure FormResizeHandler(Sender: TObject);
    procedure ApplyMenu(AAction: TSiftAction; Mode: TSiftApplyMode);
    { events }
    procedure GridDrawCell(Sender: TObject; aCol, aRow: Integer; aRect: TRect;
      aState: TGridDrawState);
    procedure GridSelection(Sender: TObject; aCol, aRow: Integer);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure GridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DetailTimerTick(Sender: TObject);
    procedure ReapTimerTick(Sender: TObject);
    procedure LastClick(Sender: TObject);
    procedure WinClick(Sender: TObject);
    procedure AllClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure LogsClick(Sender: TObject);
    procedure QueryToggleClick(Sender: TObject);
    procedure TextIncClick(Sender: TObject);
    procedure TextExcClick(Sender: TObject);
    procedure ChipClick(Sender: TObject);
    procedure ClearFilterClick(Sender: TObject);
    procedure ElevateClick(Sender: TObject);
    procedure CopyQueryClick(Sender: TObject);
    procedure CopyFHClick(Sender: TObject);
    procedure ExportPsClick(Sender: TObject);
    procedure MiIncAddClick(Sender: TObject);
    procedure MiIncSetClick(Sender: TObject);
    procedure MiExcAddClick(Sender: TObject);
    procedure MiExcSetClick(Sender: TObject);
    procedure MiCopyCellClick(Sender: TObject);
    procedure MiCopyRowClick(Sender: TObject);
    procedure MiOpenFilterClick(Sender: TObject);
    procedure MiOpenEvtxClick(Sender: TObject);
    procedure MiCopyFilterClick(Sender: TObject);
    procedure MiPasteFilterClick(Sender: TObject);
    procedure MiExitClick(Sender: TObject);
    procedure MiStartWinClick(Sender: TObject);
    procedure MiStartMenuClick(Sender: TObject);
    procedure MiCloseTrayClick(Sender: TObject);
    procedure MiAboutClick(Sender: TObject);
    procedure TrayShowClick(Sender: TObject);
    procedure TrayLast1Click(Sender: TObject);
    procedure TrayLast5Click(Sender: TObject);
    procedure TrayLast20Click(Sender: TObject);
    procedure TrayDblClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroyHandler(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  protected
    procedure DoAutoAdjustLayout(const AMode: TLayoutAdjustmentPolicy;
      const AXProportion, AYProportion: Double); override;
  public
    procedure ApplyFilter(F: TSiftFilter);
    procedure RunNow;
    { headless helpers for the screenshot / self-test harness }
    function WaitForQuery(TimeoutMs: Integer): Boolean;
    procedure SetRedaction(const Map: TStrings);
    procedure DumpUiText(L: TStrings);
    procedure ShowQueryPanel(AShow: Boolean);
    procedure ShowElevationBannerForTest;
    procedure SelectRow(I: Integer);
    { takes ownership of R }
    procedure LoadResultForTest(R: TSiftResult);
    { opens the grid context menu at a cell, as the Apps key does }
    procedure OpenGridMenuAt(ACol, ARow: Integer);
    procedure OpenAbout;
    { harness only: synthetic rows/messages/log list for screenshots }
    procedure SetDemoData(R: TSiftResult; Messages: TStrings;
      const Channels: TSiftChannelInfos);
    property RowCap: Integer read FRowCap write FRowCap;
    property RowCapHit: Boolean read FRowCapHit;
    procedure OpenLogPicker;
    { shows the notification-area icon when one exists }
    procedure EnableTray;
    property Filter: TSiftFilter read FFilter;
    property Grid: TSiftGrid read FGrid;
    property CurrentResult: TSiftResult read FResult;
    property TrayAvailable: Boolean read FTrayOk;
    property GridMenu: TPopupMenu read FGridMenu;
    property TrayMenu: TPopupMenu read FTrayMenu;
    property MainMenuBar: TMainMenu read FMainMenu;
    property VersionText: string read FVersion;
    { column auto-fit: what a double-click on a column's divider does
      (Message: toggles wrap instead) }
    procedure DividerDblClick(C: TGridCol);
    { width the column would get, measured with Cv at Ppi (the harness passes
      a bitmap canvas at 120/144 DPI to check scaling) }
    function ComputeFitWidth(C: TGridCol; Cv: TCanvas; Ppi: Integer): Integer;
    procedure FitColumn(C: TGridCol);
    procedure SetMessageWrap(V: Boolean);
    { re-measures the visible rows when Message wrap is on }
    procedure UpdateWrapHeights;
    property MessageWrap: Boolean read FWrap;
    { toolbar access for the harness (the same handlers a click runs) }
    procedure ToolbarClickLevel(Index: Integer);
    procedure ToolbarSelectTime(P: TSiftWindowPreset);
    procedure ToolbarSetMax(const S: string);
    procedure ToolbarSelectLog(const LogName: string);
    function ToolbarStateText: string;
    { right-click Include/Exclude "add" on a cell, as the menu item does }
    procedure CellFilterForTest(Row: Integer; Col: TGridCol; Exclude: Boolean);
    property ToolbarRow: TPanel read FRowTb;
    function ToolbarLevelBox(I: Integer): TCheckBox;
    { what the Custom dialog opens with }
    procedure CustomPrefill(out FromText, ToText: string);
    { the Custom dialog, built but not shown (the harness checks its layout) }
    function CreateCustomDialog(out EdFrom, EdTo: TEdit): TForm;
    property TimeCombo: TComboBox read FCbTime;
    property TextBox: TEdit read FEdText;
    property StatusBar: TStatusBar read FStatus;
    {$IFDEF SIFT_HARNESS}
    { replaces the modal Custom dialog in harness runs and counts the opens }
    property CustomAskHook: TSiftCustomAsk read FCustomAskHook write FCustomAskHook;
    property CustomAskCount: Integer read FCustomAskCount write FCustomAskCount;
    {$ENDIF}
    property WrapViewItem: TMenuItem read FMiWrapView;
    property WrapGridItem: TMenuItem read FMiWrapGrid;
    property LastFitCol: Integer read FLastFitCol;
    property LastFitWidth: Integer read FLastFitWidth;
    { Event ID tab and Look up online }
    procedure ShowEventIdTab;
    function EventIdText: string;
    procedure LookUpOnline(Row: Integer);
    property MetaCache: TSiftMetaCache read FMetaCache;
    { harness: build the URL but never open the browser }
    property LookupDryRun: Boolean read FLookupDryRun write FLookupDryRun;
    property LastLookupUrl: string read FLastLookupUrl;
  end;

var
  SiftMainForm: TSiftMainForm;

function ShowChannelPicker(Owner: TForm; const Infos: TSiftChannelInfos;
  Current: TStrings): Boolean;
procedure ShowAboutBox(Owner: TForm; const Version: string);

const
  ColCaptions: array[TGridCol] of string = ('Time', 'Level', 'Channel',
    'Provider', 'Event ID', 'Task', 'User', 'Computer', 'Message');
  ColWidths96: array[TGridCol] of Integer = (140, 84, 150, 190, 68, 110,
    150, 110, 640);
  ColFields: array[TGridCol] of TSiftField = (sfTime, sfLevel, sfChannel,
    sfProvider, sfEventId, sfTask, sfUser, sfComputer, sfMessage);
  LastNs: array[0..3] of Integer = (5, 10, 20, 40);
  { most lines a wrapped Message cell grows to }
  WrapMaxLines = 8;
  WinMins: array[0..5] of Integer = (1, 5, 15, 30, 60, 240);
  WinCaptions: array[0..5] of string = ('1 min', '5 min', '15 min', '30 min',
    '1 h', '4 h');

implementation

uses
  Sift.TzTime;

function WindowSpanText(Ms: Int64): string; forward;

const
  LevelBg: array[0..5] of TColor = (clNone, $00DCDCFF, $00E8E8FF, $00D8F4FF,
    clNone, clNone);

function FirstLine(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if Result[I] in [#13, #10] then
    begin
      SetLength(Result, I - 1);
      Break;
    end;
  Result := Trim(Result);
end;

function PrettyXml(const X: string): string;
var
  I, Depth: Integer;
  Sb: TStringBuilder;
  C: Char;
  Closing, SelfClose: Boolean;
  J: Integer;
begin
  Sb := TStringBuilder.Create;
  try
    Depth := 0;
    I := 1;
    while I <= Length(X) do
    begin
      C := X[I];
      if C = '<' then
      begin
        Closing := (I < Length(X)) and (X[I + 1] = '/');
        J := I;
        while (J <= Length(X)) and (X[J] <> '>') do
          Inc(J);
        SelfClose := (J > 1) and (J <= Length(X)) and (X[J - 1] = '/');
        if Closing then
          Dec(Depth);
        if (Sb.Length > 0) and ((I = 1) or (X[I - 1] = '>')) then
          Sb.Append(#13#10 + StringOfChar(' ', Max(0, Depth) * 2));
        Sb.Append(Copy(X, I, J - I + 1));
        if not Closing and not SelfClose and (Copy(X, I, 2) <> '<?') then
          Inc(Depth);
        I := J + 1;
      end
      else
      begin
        Sb.Append(C);
        Inc(I);
      end;
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

{ TQueryThread }

constructor TQueryThread.Create(AOwner: TSiftMainForm; F: TSiftFilter;
  All: TStrings; Gen: Integer; RowCap: Integer);
begin
  FOwner := AOwner;
  FFilter := F.Clone;
  { "All time" with no last-N on a big log (Security, or all logs) can mean
    millions of rows: cap it to the newest RowCap rows. }
  if (RowCap > 0) and (FFilter.LastN = 0) and (FFilter.TimeMode = tmAll) then
  begin
    FFilter.SetLastN(RowCap);
    FCapApplied := RowCap;
  end;
  FAll := TStringList.Create;
  FAll.Assign(All);
  FGen := Gen;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TQueryThread.Destroy;
begin
  FFilter.Free;
  FAll.Free;
  FResult.Free;
  inherited Destroy;
end;

procedure TQueryThread.Cancel;
begin
  FCancel := True;
end;

procedure TQueryThread.OnProgress(R: TSiftResult; var Cancel: Boolean);
begin
  if FCancel then
  begin
    Cancel := True;
    Exit;
  end;
  FProgressResult := R;
  Synchronize(@SyncProgress);
  Cancel := FCancel;
end;

procedure TQueryThread.SyncProgress;
begin
  if not FCancel then
    FOwner.ReceiveProgress(Self, FProgressResult);
end;

procedure TQueryThread.SyncDone;
begin
  FOwner.ReceiveDone(Self);
end;

procedure TQueryThread.Execute;
var
  Ex: TSiftExecutor;
begin
  try
    Ex := TSiftExecutor.Create;
    try
      Ex.CancelFlag := @FCancel;
      Ex.FirstProgress := 300;
      Ex.ProgressEvery := 20000;
      FResult := Ex.Execute(FFilter, FAll, @OnProgress);
      FRowCapHit := (FCapApplied > 0) and (FResult <> nil) and (FResult.Count >= FCapApplied);
    finally
      Ex.Free;
    end;
  except
    on E: Exception do
      FError := E.Message;
  end;
  if not FCancel then
    Synchronize(@SyncDone);
end;

{ TSiftMainForm }

constructor TSiftMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 1);
  Caption := 'Sift - Windows event log viewer';
  Position := poScreenCenter;
  Width := Scale96ToForm(1240);
  Height := Scale96ToForm(780);
  Constraints.MinWidth := Scale96ToForm(720);
  Constraints.MinHeight := Scale96ToForm(420);
  KeyPreview := True;
  ShowHint := True;
  FFilter := TSiftFilter.Create;
  FAllChannels := TStringList.Create;
  FOldThreads := TList.Create;
  FMsgCache := specialize TDictionary<Integer, string>.Create;
  FTaskCache := specialize TDictionary<string, string>.Create;
  FRedactMap := TStringList.Create;
  FSettings := TSiftSettings.Create;
  FRowCap := FSettings.ReadInt('AllTimeRowCap', 200000);
  FWrap := FSettings.ReadBool('MessageWrap', False);
  FWrapRows := specialize TDictionary<Integer, Boolean>.Create;
  FLastFitCol := -1;
  FDetailId := -1;
  if EvtApiLoaded then
    FMetaCache := TSiftMetaCache.Create;
  FVersion := FileVersionString;
  if EvtApiLoaded then
    FRenderer := TSiftRenderer.Create;
  BuildUi;
  BuildMenus;
  BuildTray;
  OnCloseQuery := @FormCloseQuery;
  OnDestroy := @FormDestroyHandler;
  OnResize := @FormResizeHandler;
  LoadChannels;
  FFilter.Channels.CommaText := FSettings.ReadStr('Channels', 'System,Application');
  if FFilter.Channels.Count = 0 then
  begin
    FFilter.Channels.Add('System');
    FFilter.Channels.Add('Application');
  end;
  FFilter.SetLastN(40);
  ShowQueryPanel(FSettings.ReadBool('QueryPanel', False));
  UpdateLogsCaption;
  UpdateChips;
  UpdateQuickButtons;
  UpdateQueryPanel;
  UpdateStatus;
end;

procedure TSiftMainForm.DoAutoAdjustLayout(const AMode: TLayoutAdjustmentPolicy;
  const AXProportion, AYProportion: Double);
begin
  inherited DoAutoAdjustLayout(AMode, AXProportion, AYProportion);
  { the status bar's height is fixed (see BuildUi): scale it with the rest }
  if (AMode = lapAutoAdjustForDPI) and (FStatus <> nil) then
  begin
    FStatusH := FStatusH * AYProportion;
    FStatus.Height := Round(FStatusH);
  end;
  { the list's frame does not scale, only its item height: keep 24 px total }
  if (AMode = lapAutoAdjustForDPI) and (FCbTime <> nil) then
  begin
    FComboH := FComboH * AYProportion;
    FCbTime.ItemHeight := ComboItemHeight;
    FCbLog.ItemHeight := ComboItemHeight;
  end;
end;

function TSiftMainForm.ComboItemHeight: Integer;
begin
  { an owner-drawn list's field is item height + 6 px of frame }
  Result := Round(FComboH) - 6;
end;

destructor TSiftMainForm.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;

procedure TSiftMainForm.FormDestroyHandler(Sender: TObject);
var
  I: Integer;
  T: TQueryThread;
begin
  CancelQuery;
  for I := 0 to FOldThreads.Count - 1 do
  begin
    T := TQueryThread(FOldThreads[I]);
    T.Cancel;
    while not T.Finished do
      CheckSynchronize(10);
    T.Free;
  end;
  FOldThreads.Free;
  FResult.Free;
  FRenderer.Free;
  FMsgCache.Free;
  FTaskCache.Free;
  FRedactMap.Free;
  FSettings.Free;
  FAllChannels.Free;
  FFilter.Free;
  FDemoMessages.Free;
  FWrapRows.Free;
  FMetaCache.Free;
end;

function TSiftMainForm.MakeButton(AParent: TWinControl; const ACaption: string;
  AWidth: Integer; AOnClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Height := Scale96ToForm(26);
  Result.Width := Scale96ToForm(AWidth);
  Result.OnClick := AOnClick;
end;

function TSiftMainForm.MakeSpeed(AParent: TWinControl; const ACaption: string;
  AWidth, ATag: Integer; AOnClick: TNotifyEvent): TSpeedButton;
begin
  Result := TSpeedButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Height := Scale96ToForm(26);
  Result.Width := Scale96ToForm(AWidth);
  Result.GroupIndex := 1;
  Result.AllowAllUp := True;
  Result.Tag := ATag;
  Result.OnClick := AOnClick;
end;

function TSiftMainForm.MakeLabel(AParent: TWinControl; const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Layout := tlCenter;
  Result.AutoSize := True;
end;

procedure TSiftMainForm.LayoutRow(Row: TPanel);
{ Simple left-to-right layout: 8 px edge, 6 px gaps (scaled), vertically
  centred. Controls with Tag = -99 start a 14 px group gap. }
var
  I, X, Gap, Edge: Integer;
  C: TControl;
begin
  Gap := Scale96ToForm(6);
  Edge := Scale96ToForm(8);
  X := Edge;
  for I := 0 to Row.ControlCount - 1 do
  begin
    C := Row.Controls[I];
    if not C.Visible then
      Continue;
    if (C is TLabel) and (I > 0) then
      Inc(X, Scale96ToForm(8));
    C.Left := X;
    C.Top := (Row.ClientHeight - C.Height) div 2;
    Inc(X, C.Width + Gap);
  end;
end;

procedure TSiftMainForm.BuildUi;
var
  I: Integer;
  P: TPanel;
  Col: TGridColumn;
  G: TGridCol;
  Mono: string;
begin
  Mono := 'Consolas';

  FTop := TPanel.Create(Self);
  FTop.Parent := Self;
  FTop.Align := alTop;
  FTop.BevelOuter := bvNone;
  FTop.AutoSize := True;

  { row 1: logs, quick buttons, refresh, query toggle }
  FRow1 := TPanel.Create(Self);
  FRow1.Parent := FTop;
  FRow1.Align := alTop;
  FRow1.BevelOuter := bvNone;
  FRow1.Height := Scale96ToForm(40);
  FBtnLogs := MakeButton(FRow1, 'Logs: System, Application', 260, @LogsClick);
  FBtnLogs.Hint := 'Choose which logs to read (any or all, including Applications and Services logs)';
  FLblLast := MakeLabel(FRow1, 'Last:');
  for I := 0 to High(LastNs) do
  begin
    FLastBtns[I] := MakeSpeed(FRow1, IntToStr(LastNs[I]), 36, I, @LastClick);
    FLastBtns[I].Hint := Format('Show the last %d events', [LastNs[I]]);
  end;
  FLblWin := MakeLabel(FRow1, 'Within:');
  for I := 0 to High(WinMins) do
  begin
    FWinBtns[I] := MakeSpeed(FRow1, WinCaptions[I], 50, I, @WinClick);
    FWinBtns[I].Hint := 'Show events from the last ' + WinCaptions[I];
  end;
  FBtnAll := MakeSpeed(FRow1, 'All time', 66, 0, @AllClick);
  FBtnAll.Hint := 'No time limit';
  FBtnRefresh := MakeButton(FRow1, 'Refresh', 76, @RefreshClick);
  FBtnRefresh.Hint := 'Run the current filter again (F5)';
  FBtnQuery := MakeButton(FRow1, 'Query...', 76, @QueryToggleClick);
  FBtnQuery.Hint := 'Show or hide the compiled query';

  BuildToolbar;

  { row 2: message text (client-side) }
  FRow2 := TPanel.Create(Self);
  FRow2.Parent := FTop;
  FRow2.Align := alTop;
  FRow2.Top := FRowTb.Top + FRowTb.Height;
  FRow2.BevelOuter := bvNone;
  FRow2.Height := Scale96ToForm(38);
  FLblText := MakeLabel(FRow2, 'Message text:');
  FEdText := TEdit.Create(Self);
  FEdText.Parent := FRow2;
  FEdText.Width := Scale96ToForm(260);
  FEdText.Constraints.MinHeight := Scale96ToForm(24);
  FEdText.Height := Scale96ToForm(26);
  FEdText.TextHint := 'contains...';
  FBtnTextInc := MakeButton(FRow2, 'Include', 70, @TextIncClick);
  FBtnTextExc := MakeButton(FRow2, 'Exclude', 70, @TextExcClick);
  FLblTextNote := MakeLabel(FRow2, '(client-side text match: slower, capped at ' +
    IntToStr(DefaultTextScanCap) + ' events)');
  FLblTextNote.Font.Color := clGrayText;

  { chips }
  FChips := TFlowPanel.Create(Self);
  FChips.Parent := FTop;
  FChips.Align := alTop;
  FChips.Top := FRow2.Top + FRow2.Height;
  FChips.BevelOuter := bvNone;
  FChips.AutoSize := True;
  FChips.BorderSpacing.Left := Scale96ToForm(8);
  FChips.BorderSpacing.Right := Scale96ToForm(8);
  FChips.BorderSpacing.Bottom := Scale96ToForm(4);

  { elevation banner }
  FBanner := TPanel.Create(Self);
  FBanner.Parent := FTop;
  FBanner.Align := alTop;
  FBanner.Top := 2000;
  FBanner.BevelOuter := bvNone;
  FBanner.Height := Scale96ToForm(40);
  FBanner.Color := clInfoBk;
  FBanner.ParentBackground := False;
  FBanner.Visible := False;
  FBannerLbl := MakeLabel(FBanner, '');
  FBannerLbl.Font.Color := clInfoText;
  FBtnElevate := MakeButton(FBanner, 'Restart elevated', 130, @ElevateClick);
  FBtnElevate.Hint := 'Restart Sift as administrator (Windows will ask for consent)';

  { query panel }
  FQueryPanel := TPanel.Create(Self);
  FQueryPanel.Parent := Self;
  FQueryPanel.Align := alTop;
  FQueryPanel.Top := 3000;
  FQueryPanel.BevelOuter := bvNone;
  FQueryPanel.Height := Scale96ToForm(340);
  FQueryPanel.BorderSpacing.Around := Scale96ToForm(8);
  P := TPanel.Create(Self);
  P.Parent := FQueryPanel;
  P.Align := alTop;
  P.BevelOuter := bvNone;
  P.Height := Scale96ToForm(32);
  FQueryHead := P;
  FLblQuery := MakeLabel(P, 'Structured query (runs in the event log service):');
  FBtnCopyQuery := MakeButton(P, 'Copy query', 96, @CopyQueryClick);
  FBtnExportPs := MakeButton(P, 'Export as PowerShell...', 170, @ExportPsClick);
  LayoutRow(P);
  FMemoQuery := TMemo.Create(Self);
  FMemoQuery.Parent := FQueryPanel;
  FMemoQuery.Align := alClient;
  FMemoQuery.ReadOnly := True;
  FMemoQuery.ScrollBars := ssAutoBoth;
  FMemoQuery.WordWrap := False;
  FMemoQuery.Font.Name := Mono;
  P := TPanel.Create(Self);
  P.Parent := FQueryPanel;
  P.Align := alBottom;
  P.BevelOuter := bvNone;
  P.Height := Scale96ToForm(150);
  FLblFH := MakeLabel(P, 'Get-WinEvent -FilterHashtable:');
  FLblFH.Top := Scale96ToForm(6);
  FLblFH.Left := 0;
  FBtnCopyFH := MakeButton(P, 'Copy one-liner', 110, @CopyFHClick);
  FBtnCopyFH.Anchors := [akTop, akRight];
  FBtnCopyFH.Top := Scale96ToForm(32);
  FBtnCopyFH.Left := P.ClientWidth - FBtnCopyFH.Width;
  FMemoFH := TMemo.Create(Self);
  FMemoFH.Parent := P;
  FMemoFH.ReadOnly := True;
  FMemoFH.WordWrap := False;
  FMemoFH.Font.Name := Mono;
  FMemoFH.Left := 0;
  FMemoFH.Top := Scale96ToForm(32);
  FMemoFH.Height := Scale96ToForm(112);
  FMemoFH.ScrollBars := ssAutoBoth;
  FMemoFH.Width := P.ClientWidth - FBtnCopyFH.Width - Scale96ToForm(6);
  FMemoFH.Anchors := [akLeft, akTop, akRight, akBottom];

  { status bar }
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  FStatus.SizeGrip := False;
  { the LCL takes the native status bar height once per process, at the
    start-up DPI; a fixed, scaled height follows a DPI change instead }
  FStatus.AutoSize := False;
  FStatusH := Scale96ToForm(24);
  FStatus.Height := Round(FStatusH);
  with FStatus.Panels.Add do Width := Scale96ToForm(130);
  with FStatus.Panels.Add do Width := Scale96ToForm(230);
  with FStatus.Panels.Add do Width := Scale96ToForm(520);
  with FStatus.Panels.Add do Width := Scale96ToForm(240);
  with FStatus.Panels.Add do
  begin
    Width := Scale96ToForm(100);
    Alignment := taRightJustify;
  end;

  { detail pane }
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alBottom;
  FPages.Height := Scale96ToForm(230);
  with FPages.AddTabSheet do
  begin
    Caption := 'Message';
    FMemoMsg := TMemo.Create(Self);
    FMemoMsg.Parent := FPages.Pages[0];
    FMemoMsg.Align := alClient;
    FMemoMsg.ReadOnly := True;
    FMemoMsg.ScrollBars := ssAutoVertical;
    FMemoMsg.BorderStyle := bsNone;
  end;
  with FPages.AddTabSheet do
  begin
    Caption := 'XML';
    FMemoXml := TMemo.Create(Self);
    FMemoXml.Parent := FPages.Pages[1];
    FMemoXml.Align := alClient;
    FMemoXml.ReadOnly := True;
    FMemoXml.ScrollBars := ssAutoBoth;
    FMemoXml.WordWrap := False;
    FMemoXml.Font.Name := Mono;
    FMemoXml.BorderStyle := bsNone;
  end;
  with FPages.AddTabSheet do
  begin
    Caption := 'Event ID';
    FMemoMeta := TMemo.Create(Self);
    FMemoMeta.Parent := FPages.Pages[2];
    FMemoMeta.Align := alClient;
    FMemoMeta.ReadOnly := True;
    FMemoMeta.ScrollBars := ssAutoBoth;
    FMemoMeta.WordWrap := True;
    FMemoMeta.BorderStyle := bsNone;
  end;
  FPages.OnChange := @PagesChange;
  FSplit := TSplitter.Create(Self);
  FSplit.Parent := Self;
  FSplit.Align := alBottom;
  FSplit.Height := Scale96ToForm(6);
  FSplit.Top := FPages.Top - 1;

  { the status bar stays the bottom-most bar, below the detail pane }
  FStatus.Top := FPages.Top + FPages.Height + 100;

  { grid }
  FGrid := TSiftGrid.Create(Self);
  FGrid.Parent := Self;
  FGrid.Align := alClient;
  FGrid.FixedCols := 0;
  FGrid.FixedRows := 1;
  FGrid.RowCount := 1;
  FGrid.DefaultRowHeight := Scale96ToForm(24);
  FGrid.Options := [goFixedVertLine, goFixedHorzLine, goVertLine, goRowSelect,
    goColSizing, goThumbTracking, goDrawFocusSelected, goSmoothScroll];
  FGrid.FocusRectVisible := False;
  FGrid.TitleStyle := tsNative;
  for G := Low(TGridCol) to High(TGridCol) do
  begin
    Col := FGrid.Columns.Add;
    Col.Title.Caption := ColCaptions[G];
    Col.Width := Scale96ToForm(ColWidths96[G]);
  end;
  FGrid.OnDrawCell := @GridDrawCell;
  FGrid.OnSelection := @GridSelection;
  FGrid.OnContextPopup := @GridContextPopup;
  FGrid.OnKeyDown := @GridKeyDown;
  FGrid.OnDividerDblClick := @GridDividerDblClick;
  FGrid.OnTopLeftChanged := @GridTopLeftChanged;
  FGrid.OnHeaderSized := @GridHeaderSized;
  UpdateWrapCaption;

  FDetailTimer := TTimer.Create(Self);
  FDetailTimer.Enabled := False;
  FDetailTimer.Interval := 60;
  FDetailTimer.OnTimer := @DetailTimerTick;
  FReapTimer := TTimer.Create(Self);
  FReapTimer.Interval := 1000;
  FReapTimer.OnTimer := @ReapTimerTick;

  Icon.Assign(Application.Icon);
  LayoutRow(FRow1);
  LayoutRow(FRowTb);
  LayoutRow(FRow2);
  LayoutRow(FBanner);
end;

procedure TSiftMainForm.BuildMenus;

  function Item(AParent: TMenuItem; const ACaption: string; AOnClick: TNotifyEvent;
    AShortCut: TShortCut = 0): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
    Result.ShortCut := AShortCut;
    AParent.Add(Result);
  end;

var
  M: TMenuItem;
begin
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;
  M := TMenuItem.Create(Self);
  M.Caption := '&File';
  FMainMenu.Items.Add(M);
  Item(M, '&Open filter file...', @MiOpenFilterClick, ShortCut(VK_O, [ssCtrl]));
  Item(M, 'Open &log file (.evtx)...', @MiOpenEvtxClick);
  Item(M, '-', nil);
  Item(M, '&Copy filter', @MiCopyFilterClick, ShortCut(VK_C, [ssCtrl, ssShift]));
  Item(M, '&Paste filter', @MiPasteFilterClick, ShortCut(VK_V, [ssCtrl, ssShift]));
  Item(M, '&Export as PowerShell...', @ExportPsClick);
  Item(M, '-', nil);
  Item(M, 'E&xit', @MiExitClick);

  M := TMenuItem.Create(Self);
  M.Caption := '&View';
  FMainMenu.Items.Add(M);
  FMiShowQuery := Item(M, 'Show &query panel', @QueryToggleClick, ShortCut(VK_Q, [ssCtrl]));
  Item(M, '&Refresh', @RefreshClick, ShortCut(VK_F5, []));
  Item(M, '-', nil);
  { the same toggle as a double-click on the Message column's divider, which
    is often scrolled off-screen }
  FMiWrapView := Item(M, '&Wrap message text', @MiWrapClick, ShortCut(VK_W, [ssCtrl]));

  M := TMenuItem.Create(Self);
  M.Caption := '&Options';
  FMainMenu.Items.Add(M);
  FMiStartWin := Item(M, 'Start with &Windows', @MiStartWinClick);
  FMiStartMenu := Item(M, 'Add to &Start menu', @MiStartMenuClick);
  FMiCloseTray := Item(M, '&Close to tray', @MiCloseTrayClick);
  FMiStartWin.Checked := IsStartWithWindows;
  FMiStartMenu.Checked := HasStartMenuShortcut;

  M := TMenuItem.Create(Self);
  M.Caption := '&Help';
  FMainMenu.Items.Add(M);
  Item(M, '&About Sift...', @MiAboutClick);

  { grid right-click: Include / Exclude, then Add to / Set as }
  FGridMenu := TPopupMenu.Create(Self);
  FMiInclude := Item(FGridMenu.Items, 'Include', nil);
  FMiIncAdd := Item(FMiInclude, '&Add to current filter', @MiIncAddClick);
  FMiIncSet := Item(FMiInclude, '&Set as current filter', @MiIncSetClick);
  FMiExclude := Item(FGridMenu.Items, 'Exclude', nil);
  FMiExcAdd := Item(FMiExclude, 'A&dd to current filter', @MiExcAddClick);
  FMiExcSet := Item(FMiExclude, 'S&et as current filter', @MiExcSetClick);
  Item(FGridMenu.Items, '-', nil);
  FMiCopyCell := Item(FGridMenu.Items, '&Copy cell', @MiCopyCellClick);
  FMiCopyRow := Item(FGridMenu.Items, 'Copy &row', @MiCopyRowClick);
  Item(FGridMenu.Items, '-', nil);
  FMiLookup := Item(FGridMenu.Items, '&Look up online', @MiLookupClick);
  Item(FGridMenu.Items, '-', nil);
  FMiWrapGrid := Item(FGridMenu.Items, '&Wrap message text', @MiWrapClick);
  UpdateWrapCaption;
end;

procedure TSiftMainForm.BuildTray;

  function Item(const ACaption: string; AOnClick: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
    FTrayMenu.Items.Add(Result);
  end;

begin
  FTrayMenu := TPopupMenu.Create(Self);
  Item('&Show Sift', @TrayShowClick);
  Item('-', nil);
  Item('Last &1 min', @TrayLast1Click);
  Item('Last &5 min', @TrayLast5Click);
  Item('Last &20 events', @TrayLast20Click);
  Item('-', nil);
  Item('E&xit', @MiExitClick);
  FTrayOk := NotificationAreaAvailable;
  FTray := TTrayIcon.Create(Self);
  FTray.Hint := 'Sift ' + FVersion;
  FTray.PopUpMenu := FTrayMenu;
  FTray.OnDblClick := @TrayDblClick;
  FTray.Icon.Assign(Application.Icon);
  FMiCloseTray.Checked := FTrayOk and FSettings.ReadBool('CloseToTray', True);
  FMiCloseTray.Enabled := FTrayOk;
  if not FTrayOk then
    FMiCloseTray.Caption := 'Close to tray (no notification area)';
  { the icon itself is shown by the lpr after the window decides to show }
end;

procedure TSiftMainForm.LoadChannels;
begin
  FAllChannels.Clear;
  if not EvtApiLoaded then
    Exit;
  EnumChannels(FChannelInfos);
  QueryableChannels(FChannelInfos, FAllChannels);
end;

procedure TSiftMainForm.UpdateLogsCaption;
var
  S: string;
  I: Integer;
begin
  if FFilter.Channels.IndexOf('*') >= 0 then
    S := 'Logs: All (' + IntToStr(FAllChannels.Count) + ')'
  else
  begin
    S := '';
    for I := 0 to FFilter.Channels.Count - 1 do
    begin
      if I = 3 then
      begin
        S := S + Format(' +%d more', [FFilter.Channels.Count - 3]);
        Break;
      end;
      if I > 0 then
        S := S + ', ';
      if SameText(Copy(FFilter.Channels[I], 1, 7), 'file://') then
        S := S + ExtractFileName(Copy(FFilter.Channels[I], 8, MaxInt))
      else
        S := S + FFilter.Channels[I];
    end;
    if S = '' then
      S := '(none)';
    S := 'Logs: ' + S;
  end;
  FBtnLogs.Caption := S + ' ...';
end;

procedure TSiftMainForm.UpdateChips;
var
  I: Integer;
  B: TButton;
  W: Integer;

  function AddChip(const ACaption, AHint: string; ATag: Integer): TButton;
  begin
    Result := TButton.Create(FChips);
    Result.Parent := FChips;
    Result.Caption := ACaption;
    Result.Hint := AHint;
    Result.Tag := ATag;
    Result.Height := Scale96ToForm(26);
    Canvas.Font := Result.Font;
    W := Canvas.TextWidth(ACaption) + Scale96ToForm(24);
    Result.Width := Max(Scale96ToForm(48), W);
    Result.BorderSpacing.Right := Scale96ToForm(6);
    Result.BorderSpacing.Bottom := Scale96ToForm(6);
    Result.OnClick := @ChipClick;
  end;

begin
  FChips.DisableAlign;
  try
    while FChips.ControlCount > 0 do
      FChips.Controls[0].Free;
    case FFilter.TimeMode of
      tmRelative:
        AddChip('Within ' + Copy(WindowSpanText(FFilter.RelativeMs), 1, 40) + '  x',
          'Click to remove the time window', -1);
      tmAbsolute:
        AddChip(CustomRangeText(FFilter) + '  x', 'Click to remove the time window (local time)', -1);
    end;
    if FFilter.LastN > 0 then
    begin
      if FFilter.TimeMode = tmAll then
        AddChip('Last ' + IntToStr(FFilter.LastN) + ' events  x', 'Click to remove', -4)
      else
        AddChip('Max ' + IntToStr(FFilter.LastN) + ' events  x', 'Click to remove the cap', -4);
    end;
    for I := 0 to FFilter.TermCount - 1 do
    begin
      B := AddChip(TermCaption(FFilter.Terms[I]) + '  x', 'Click to remove this term', I);
      if FFilter.Terms[I].Action = saExclude then
        B.Font.Color := $000000A0;
    end;
    if FFilter.TermCount > 0 then
      AddChip('Clear filter', 'Remove every include/exclude term', -2).OnClick := @ClearFilterClick;
    if FChips.ControlCount = 0 then
      AddChip('No filter: right-click any cell to Include or Exclude', '', -3).Enabled := False;
  finally
    FChips.EnableAlign;
  end;
end;

procedure TSiftMainForm.UpdateQuickButtons;
var
  I: Integer;
begin
  for I := 0 to High(FLastBtns) do
    FLastBtns[I].Down := FFilter.LastN = LastNs[I];
  for I := 0 to High(FWinBtns) do
    FWinBtns[I].Down := (FFilter.LastN = 0) and (FFilter.TimeMode = tmRelative) and
      (FFilter.RelativeMs = Int64(WinMins[I]) * 60000);
  FBtnAll.Down := (FFilter.LastN = 0) and (FFilter.TimeMode = tmAll);
  SyncToolbar;
end;

function WindowSpanText(Ms: Int64): string;
begin
  if (Ms mod 86400000) = 0 then
    Result := IntToStr(Ms div 86400000) + ' d'
  else if (Ms mod 3600000) = 0 then
    Result := IntToStr(Ms div 3600000) + ' h'
  else if (Ms mod 60000) = 0 then
    Result := IntToStr(Ms div 60000) + ' min'
  else
    Result := IntToStr(Ms div 1000) + ' s';
end;

procedure TSiftMainForm.BuildToolbar;
var
  I: Integer;
begin
  FRowTb := TPanel.Create(Self);
  FRowTb.Parent := FTop;
  FRowTb.Align := alTop;
  FRowTb.Top := FRow1.Top + FRow1.Height;
  FRowTb.BevelOuter := bvNone;
  FRowTb.Height := Scale96ToForm(36);
  FLblLevel := MakeLabel(FRowTb, 'Level:');
  for I := 0 to High(FChkLevel) do
  begin
    FChkLevel[I] := TCheckBox.Create(Self);
    FChkLevel[I].Parent := FRowTb;
    FChkLevel[I].Caption := ToolbarLevelCaptions[I];
    FChkLevel[I].Tag := I;
    { a click must never cycle a box into the grey state: with AllowGrayed
      off the LCL goes unchecked <-> checked (grey -> checked); grey is only
      ever set by SyncToolbar, for a level excluded by right-click }
    FChkLevel[I].AllowGrayed := False;
    FChkLevel[I].AutoSize := True;
    { the whole box is the click target: at least 24 px tall at 100% }
    FChkLevel[I].Constraints.MinHeight := Scale96ToForm(24);
    FChkLevel[I].Hint := 'Show ' + ToolbarLevelCaptions[I] + ' events. None ticked = all levels. ' +
      'A shaded box is excluded by a right-click filter; click to clear it.';
    FChkLevel[I].OnClick := @LevelChkClick;
  end;
  FLblTime := MakeLabel(FRowTb, 'Time:');
  FCbTime := TComboBox.Create(Self);
  FCbTime.Parent := FRowTb;
  { a drop-down list is as tall as Windows makes it for the font (23 px at
    100%, and it ignores CB_SETITEMHEIGHT); a fixed owner-drawn list takes
    the item height we give it, so the click target is 24 px }
  FCbTime.Style := csOwnerDrawFixed;
  FComboH := Scale96ToForm(24);
  FCbTime.ItemHeight := ComboItemHeight;
  FCbTime.Width := Scale96ToForm(110);
  FCbTime.Hint := 'Time window (the same one the Within buttons set)';
  FCbTime.OnSelect := @TimeComboSelect;
  FCbTime.OnCloseUp := @TimeComboCloseUp;
  FCbTime.OnKeyDown := @TimeComboKeyDown;
  FCbTime.OnExit := @TimeComboExit;
  FLblMax := MakeLabel(FRowTb, 'Max:');
  FEdMax := TEdit.Create(Self);
  FEdMax.Parent := FRowTb;
  FEdMax.Width := Scale96ToForm(70);
  FEdMax.Constraints.MinHeight := Scale96ToForm(24);
  FEdMax.Height := Scale96ToForm(26);
  FEdMax.TextHint := 'all';
  FEdMax.MaxLength := 7;
  FEdMax.Hint := 'Newest N events (Get-WinEvent -MaxEvents). Empty = no limit. Press Enter to apply.';
  FEdMax.OnEditingDone := @MaxEditDone;
  FEdMax.OnKeyPress := @MaxKeyPress;
  FLblLog := MakeLabel(FRowTb, 'Log:');
  FCbLog := TComboBox.Create(Self);
  FCbLog.Parent := FRowTb;
  FCbLog.Style := csOwnerDrawFixed;
  FCbLog.ItemHeight := ComboItemHeight;
  FCbLog.Width := Scale96ToForm(230);
  FCbLog.DropDownCount := 20;
  FCbLog.Hint := 'One log, or All logs (every log you can read; denied ones show in the banner)';
  FCbLog.OnSelect := @LogComboSelect;
end;

procedure TSiftMainForm.SyncToolbar;
const
  ClassicThree: array[0..2] of string = ('System', 'Application', 'Security');
var
  I, K: Integer;
  P: TSiftWindowPreset;
  Choice, S: string;
  Fixed: TStringList;
begin
  if FRowTb = nil then
    Exit;
  FSyncing := True;
  try
    for I := 0 to High(FChkLevel) do
      case LevelState(FFilter, ToolbarLevelValues[I]) of
        lsOn: FChkLevel[I].State := cbChecked;
        lsExcluded: FChkLevel[I].State := cbGrayed;
      else
        FChkLevel[I].State := cbUnchecked;
      end;
    { time: the presets, plus the current window when a quick button set one
      the toolbar has no preset for }
    FCbTime.Items.BeginUpdate;
    try
      FCbTime.Items.Clear;
      for P := wpAny to wpCustom do
        FCbTime.Items.AddObject(WindowPresetCaptions[P], TObject(PtrInt(Ord(P))));
      P := WindowPreset(FFilter);
      if P = wpOther then
      begin
        FCbTime.Items.AddObject(WindowCaption(FFilter), TObject(PtrInt(Ord(wpOther))));
        FCbTime.ItemIndex := FCbTime.Items.Count - 1;
      end
      else if P = wpCustom then
      begin
        { the active range in local time; "Custom..." stays in the list to
          change it (the dialog opens pre-filled with this range) }
        FCbTime.Items.AddObject(CustomRangeText(FFilter), TObject(PtrInt(Ord(wpOther))));
        FCbTime.ItemIndex := FCbTime.Items.Count - 1;
      end
      else
        FCbTime.ItemIndex := Ord(P);
    finally
      FCbTime.Items.EndUpdate;
    end;
    if P = wpCustom then
      K := Scale96ToForm(260)
    else
      K := Scale96ToForm(110);
    if FCbTime.Width <> K then
    begin
      FCbTime.Width := K;
      LayoutRow(FRowTb);
    end;
    if FFilter.LastN > 0 then
      FEdMax.Text := IntToStr(FFilter.LastN)
    else
      FEdMax.Text := '';
    { logs: All, the classic three, then every other log that exists }
    Choice := LogChoice(FFilter);
    Fixed := TStringList.Create;
    FCbLog.Items.BeginUpdate;
    try
      FCbLog.Items.Clear;
      FCbLog.Items.Add('All logs');
      Fixed.Add(ToolbarAllLogs);
      for S in ClassicThree do
      begin
        FCbLog.Items.Add(S);
        Fixed.Add(S);
      end;
      for I := 0 to FAllChannels.Count - 1 do
        if not SameText(FAllChannels[I], 'System') and
           not SameText(FAllChannels[I], 'Application') and
           not SameText(FAllChannels[I], 'Security') then
        begin
          FCbLog.Items.Add(FAllChannels[I]);
          Fixed.Add(FAllChannels[I]);
        end;
      K := -1;
      for I := 0 to Fixed.Count - 1 do
        if (Choice <> '') and SameText(Fixed[I], Choice) then
        begin
          K := I;
          Break;
        end;
      if K < 0 then
      begin
        if Choice = '' then
          FCbLog.Items.Add('Several (see Logs...)')
        else
          FCbLog.Items.Add(Choice);
        K := FCbLog.Items.Count - 1;
      end;
      FCbLog.ItemIndex := K;
    finally
      FCbLog.Items.EndUpdate;
      Fixed.Free;
    end;
  finally
    FSyncing := False;
  end;
end;

function TSiftMainForm.ToolbarLevelBox(I: Integer): TCheckBox;
begin
  Result := FChkLevel[I];
end;

procedure TSiftMainForm.ToolbarClickLevel(Index: Integer);
begin
  ToggleLevel(FFilter, ToolbarLevelValues[Index]);
  RunNow;
end;

procedure TSiftMainForm.LevelChkClick(Sender: TObject);
begin
  if FSyncing then
    Exit;
  { the box's own grayed/checked cycling is ignored: the filter decides and
    SyncToolbar redraws every box from it }
  ToolbarClickLevel(TCheckBox(Sender).Tag);
end;

procedure TSiftMainForm.ToolbarSelectTime(P: TSiftWindowPreset);
var
  A, B: TDateTime;
begin
  if P = wpOther then
    Exit;
  if P = wpCustom then
  begin
    if not AskCustomWindow(A, B) then
    begin
      SyncToolbar;
      Exit;
    end;
    if not SetWindowPreset(FFilter, wpCustom, A, B) then
    begin
      SyncToolbar;
      Exit;
    end;
  end
  else
    SetWindowPreset(FFilter, P);
  RunNow;
end;

function TSiftMainForm.TimeComboPreset: TSiftWindowPreset;
begin
  if FCbTime.ItemIndex < 0 then
    Result := wpOther
  else
    Result := TSiftWindowPreset(PtrInt(FCbTime.Items.Objects[FCbTime.ItemIndex]));
end;

procedure TSiftMainForm.TimeComboSelect(Sender: TObject);
begin
  { arrows, Home/End and the mouse wheel move the selection without
    committing: an open list commits on close-up, Custom... commits on
    close-up or Enter (so End does not pop the dialog) }
  if FSyncing or (FCbTime.ItemIndex < 0) then
    Exit;
  if FCbTime.DroppedDown or FTimeCommitQueued then
    Exit;
  if TimeComboPreset = wpCustom then
  begin
    FTimeCustomPending := True;
    Exit;
  end;
  FTimeCustomPending := False;
  ToolbarSelectTime(TimeComboPreset);
end;

procedure TSiftMainForm.TimeComboCommit;
var
  P: TSiftWindowPreset;
begin
  if FSyncing or FInCustomDialog then
    Exit;
  FTimeCustomPending := False;
  P := TimeComboPreset;
  if P = wpOther then
    Exit;
  if P = wpCustom then
  begin
    { once per commit; picking Custom... again while a custom range is
      active reopens the dialog with that range }
    FInCustomDialog := True;
    try
      ToolbarSelectTime(wpCustom);
    finally
      FInCustomDialog := False;
    end;
  end
  else if P <> WindowPreset(FFilter) then
    ToolbarSelectTime(P);
end;

procedure TSiftMainForm.TimeComboCloseUp(Sender: TObject);
begin
  { Windows may send the selection change before or after the close-up:
    commit once, after both }
  if FSyncing or FTimeCommitQueued then
    Exit;
  FTimeCommitQueued := True;
  Application.QueueAsyncCall(@TimeComboCommitAsync, 0);
end;

procedure TSiftMainForm.TimeComboCommitAsync(Data: PtrInt);
begin
  FTimeCommitQueued := False;
  TimeComboCommit;
end;

procedure TSiftMainForm.TimeComboKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and not FCbTime.DroppedDown and FTimeCustomPending then
  begin
    Key := 0;
    TimeComboCommit;
  end;
end;

procedure TSiftMainForm.TimeComboExit(Sender: TObject);
begin
  if FTimeCustomPending then
  begin
    FTimeCustomPending := False;
    SyncToolbar;
  end;
end;

procedure TSiftMainForm.ToolbarSetMax(const S: string);
begin
  if SetMaxCountText(FFilter, S) then
    RunNow
  else
  begin
    FStatus.Panels[3].Text := 'Max: enter a whole number from 0 to 1000000 (empty = no limit)';
    SyncToolbar;
  end;
end;

procedure TSiftMainForm.MaxEditDone(Sender: TObject);
var
  Cur: string;
begin
  if FSyncing then
    Exit;
  if FFilter.LastN > 0 then
    Cur := IntToStr(FFilter.LastN)
  else
    Cur := '';
  if Trim(FEdMax.Text) <> Cur then
    ToolbarSetMax(FEdMax.Text);
end;

procedure TSiftMainForm.MaxKeyPress(Sender: TObject; var Key: Char);
begin
  if not (Key in ['0'..'9', #8, #13, #27]) then
    Key := #0;
end;

procedure TSiftMainForm.ToolbarSelectLog(const LogName: string);
begin
  SetLogChoice(FFilter, LogName);
  UpdateLogsCaption;
  RunNow;
end;

procedure TSiftMainForm.LogComboSelect(Sender: TObject);
var
  I: Integer;
begin
  if FSyncing then
    Exit;
  I := FCbLog.ItemIndex;
  if I < 0 then
    Exit;
  if I = 0 then
    ToolbarSelectLog(ToolbarAllLogs)
  else if FCbLog.Items[I] = 'Several (see Logs...)' then
    Exit
  else
    ToolbarSelectLog(FCbLog.Items[I]);
end;

function TSiftMainForm.ToolbarStateText: string;
var
  I: Integer;
const
  St: array[TCheckBoxState] of string = ('off', 'on', 'excluded');
begin
  Result := 'levels:';
  for I := 0 to High(FChkLevel) do
    Result := Result + ' ' + FChkLevel[I].Caption + '=' + St[FChkLevel[I].State];
  Result := Result + ' | time: ' + FCbTime.Text + ' | max: ' + FEdMax.Text +
    ' | log: ' + FCbLog.Text;
end;

procedure TSiftMainForm.CustomPrefill(out FromText, ToText: string);
begin
  { reopening Custom shows the active range (local time); otherwise the
    last 24 hours, open-ended }
  ToText := '';
  if FFilter.TimeMode = tmAbsolute then
  begin
    FromText := LocalStamp(UtcToLocal(FFilter.StartUtc));
    if FFilter.EndUtc <> 0 then
      ToText := LocalStamp(UtcToLocal(FFilter.EndUtc));
  end
  else
    FromText := LocalStamp(Now - 1);
end;

function TSiftMainForm.CreateCustomDialog(out EdFrom, EdTo: TEdit): TForm;
{ stacked: a format line, then From and To rows with the edits after the
  wider label, measured with the dialog's own font, so nothing overlaps at
  any scale }
var
  D: TForm;
  LHint, LFrom, LTo: TLabel;
  Ok, Cancel: TButton;
  M, Gap, RowH, X, Y, W, EdW, BtnW, BtnH: Integer;
  S1, S2: string;

  function MkLabel(const C: string): TLabel;
  begin
    Result := TLabel.Create(D);
    Result.Parent := D;
    Result.AutoSize := True;
    Result.Caption := C;
  end;

begin
  D := TForm.CreateNew(Self);
  D.Caption := 'Custom time window';
  D.BorderStyle := bsDialog;
  D.Position := poOwnerFormCenter;
  D.HandleNeeded;
  M := Scale96ToForm(12);
  Gap := Scale96ToForm(8);
  RowH := Scale96ToForm(28);
  EdW := Scale96ToForm(170);
  BtnW := Scale96ToForm(84);
  BtnH := Scale96ToForm(28);
  LHint := MkLabel('Local time, as yyyy-mm-dd hh:nn');
  LFrom := MkLabel('From:');
  LTo := MkLabel('To (empty = now):');
  X := M + Max(D.Canvas.TextWidth(LFrom.Caption), D.Canvas.TextWidth(LTo.Caption)) + Gap;
  W := Max(X + EdW, M + D.Canvas.TextWidth(LHint.Caption)) + M;
  W := Max(W, M + 2 * BtnW + Gap + M);
  Y := M;
  LHint.Left := M;
  LHint.Top := Y;
  Y := Y + D.Canvas.TextHeight('Ag') + Gap;
  EdFrom := TEdit.Create(D);
  EdFrom.Parent := D;
  EdFrom.Constraints.MinHeight := Scale96ToForm(24);
  EdFrom.SetBounds(X, Y, EdW, Scale96ToForm(24));
  LFrom.Left := M;
  LFrom.Top := Y + (EdFrom.Height - D.Canvas.TextHeight('Ag')) div 2;
  Y := Y + Max(RowH, EdFrom.Height + Gap);
  EdTo := TEdit.Create(D);
  EdTo.Parent := D;
  EdTo.Constraints.MinHeight := Scale96ToForm(24);
  EdTo.SetBounds(X, Y, EdW, Scale96ToForm(24));
  LTo.Left := M;
  LTo.Top := Y + (EdTo.Height - D.Canvas.TextHeight('Ag')) div 2;
  Y := Y + Max(RowH, EdTo.Height + Gap) + Gap;
  CustomPrefill(S1, S2);
  EdFrom.Text := S1;
  EdTo.Text := S2;
  Ok := TButton.Create(D);
  Ok.Parent := D;
  Ok.Caption := 'OK';
  Ok.ModalResult := mrOK;
  Ok.Default := True;
  Ok.SetBounds(W - M - 2 * BtnW - Gap, Y, BtnW, BtnH);
  Cancel := TButton.Create(D);
  Cancel.Parent := D;
  Cancel.Caption := 'Cancel';
  Cancel.ModalResult := mrCancel;
  Cancel.Cancel := True;
  Cancel.SetBounds(W - M - BtnW, Y, BtnW, BtnH);
  D.ClientWidth := W;
  D.ClientHeight := Y + BtnH + M;
  Result := D;
end;

function TSiftMainForm.AskCustomWindow(out StartUtc, EndUtc: TDateTime): Boolean;
var
  D: TForm;
  EdFrom, EdTo: TEdit;
  A, B: TDateTime;
  Fs: TFormatSettings;

  function ParseLocal(const S: string; out V: TDateTime): Boolean;
  begin
    Result := TryStrToDateTime(Trim(S), V, Fs);
  end;

begin
  Result := False;
  StartUtc := 0;
  EndUtc := 0;
  Fs := DefaultFormatSettings;
  Fs.DateSeparator := '-';
  Fs.ShortDateFormat := 'yyyy-mm-dd';
  Fs.TimeSeparator := ':';
  Fs.ShortTimeFormat := 'hh:nn';
  Fs.LongTimeFormat := 'hh:nn:ss';
  {$IFDEF SIFT_HARNESS}
  if Assigned(FCustomAskHook) then
  begin
    Inc(FCustomAskCount);
    Exit(FCustomAskHook(StartUtc, EndUtc));
  end;
  {$ENDIF}
  D := CreateCustomDialog(EdFrom, EdTo);
  try
    while D.ShowModal = mrOK do
    begin
      if not ParseLocal(EdFrom.Text, A) then
      begin
        MessageDlg('Sift', 'From: use yyyy-mm-dd hh:nn', mtWarning, [mbOK], 0);
        Continue;
      end;
      B := 0;
      if (Trim(EdTo.Text) <> '') and not ParseLocal(EdTo.Text, B) then
      begin
        MessageDlg('Sift', 'To: use yyyy-mm-dd hh:nn, or leave it empty', mtWarning, [mbOK], 0);
        Continue;
      end;
      { the DST rules of the dates entered, not today's offset }
      if not TryLocalToUtc(A, StartUtc) or ((B <> 0) and not TryLocalToUtc(B, EndUtc)) then
      begin
        MessageDlg('Sift', 'That local time could not be converted to UTC.', mtWarning, [mbOK], 0);
        Continue;
      end;
      if (EndUtc <> 0) and (EndUtc <= StartUtc) then
      begin
        MessageDlg('Sift', 'To must be later than From.', mtWarning, [mbOK], 0);
        Continue;
      end;
      Exit(True);
    end;
  finally
    D.Free;
  end;
end;

procedure TSiftMainForm.UpdateQueryPanel;
var
  C: TSiftCompiled;
begin
  if not FQueryPanel.Visible then
    Exit;
  C := CompileFilter(FFilter, FAllChannels);
  FMemoQuery.Text := C.QueryXml;
  if C.ClientText then
    FMemoQuery.Lines.Add('<!-- plus client-side message-text matching (slower) -->');
  if C.FilterHashtable <> '' then
  begin
    FLblFH.Caption := 'Get-WinEvent -FilterHashtable:';
    FMemoFH.Text := C.FilterHashtable;
    FBtnCopyFH.Caption := 'Copy one-liner';
  end
  else
  begin
    { Excludes (or anything -FilterHashtable can't express exactly):
      Windows PowerShell 5.1 ignores SuppressHashFilter, so show the full
      Get-WinEvent -FilterXml command instead. }
    FLblFH.Caption := 'Get-WinEvent -FilterXml (-FilterHashtable cannot express this filter exactly):';
    FLblFH.Hint := C.FilterHashtableNote;
    FLblFH.ShowHint := True;
    FMemoFH.Text := CompilePowerShell(FFilter, FAllChannels);
    FBtnCopyFH.Caption := 'Copy command';
  end;
  FBtnCopyFH.Enabled := FMemoFH.Text <> '';
  LayoutRow(FQueryHead);
end;

procedure TSiftMainForm.ShowQueryPanel(AShow: Boolean);
begin
  FQueryPanel.Visible := AShow;
  FMiShowQuery.Checked := AShow;
  if AShow then
    LayoutRow(FQueryHead);
  if AShow then
    FBtnQuery.Caption := 'Hide query'
  else
    FBtnQuery.Caption := 'Query...';
  UpdateQueryPanel;
end;

procedure TSiftMainForm.UpdateStatus;
var
  S: string;
  Need: Integer;
  I: Integer;
begin
  if FResult = nil then
  begin
    FStatus.Panels[0].Text := ' No results';
    FStatus.Panels[1].Text := '';
    FStatus.Panels[2].Text := '';
    FStatus.Panels[3].Text := '';
  end
  else
  begin
    S := Format(' %s events', [FormatFloat('#,##0', FResult.Count)]);
    if FRowCapHit and not FRunning then
      S := Format(' Newest %s events (cap)', [FormatFloat('#,##0', FResult.Count)]);
    if FRunning then
      S := S + '...';
    FStatus.Panels[0].Text := S;
    if FRunning then
      FStatus.Panels[1].Text := 'Running...'
    else
      FStatus.Panels[1].Text := Format('Query %s ms (first row %s ms)',
        [FormatFloat('0', FResult.Stats.TotalMs), FormatFloat('0.0', Max(0, FResult.Stats.FirstRowMs))]);
    if FRowCapHit and not FRunning then
      FStatus.Panels[2].Text := Format('Filtered in the event log service - All time capped at the newest %s rows: pick a window or narrow the filter',
        [FormatFloat('#,##0', FRowCap)])
    else if FResult.Stats.Path = rpService then
      FStatus.Panels[2].Text := 'Filtered in the event log service'
    else
    begin
      S := Format('Service query + client-side text scan (%s scanned, slower)',
        [FormatFloat('#,##0', FResult.Stats.TextScanned)]);
      if FResult.Stats.CapHit then
        S := S + ' - CAP HIT, results incomplete';
      FStatus.Panels[2].Text := S;
    end;
    Need := 0;
    for I := 0 to High(FResult.Errors) do
      if FResult.Errors[I].NeedsElevation then
        Inc(Need);
    if Need > 0 then
      FStatus.Panels[3].Text := Format('%d log(s) need elevation', [Need])
    else if Length(FResult.Errors) > 0 then
      FStatus.Panels[3].Text := Format('%d log(s) failed: %s', [Length(FResult.Errors), FResult.Errors[0].Text])
    else if FResult.Stats.QueryError <> 0 then
      FStatus.Panels[3].Text := 'Query error: ' + FResult.Stats.QueryErrorText
    else
      FStatus.Panels[3].Text := '';
  end;
  FStatus.Panels[4].Text := 'v' + FVersion + ' ';
end;

procedure TSiftMainForm.UpdateBanner;
var
  Names: string;
  I, N: Integer;
begin
  Names := '';
  N := 0;
  if FResult <> nil then
    for I := 0 to High(FResult.Errors) do
      if FResult.Errors[I].NeedsElevation then
      begin
        Inc(N);
        if N <= 3 then
        begin
          if Names <> '' then
            Names := Names + ', ';
          Names := Names + FResult.Errors[I].Channel;
        end;
      end;
  if N = 0 then
  begin
    FBanner.Visible := False;
    Exit;
  end;
  if N > 3 then
    Names := Names + Format(' and %d more', [N - 3]);
  FBannerLbl.Caption := 'Access denied: ' + Names +
    '. Reading these logs needs administrator rights or the Event Log Readers group.';
  FBtnElevate.Visible := not IsProcessElevated;
  FBanner.Visible := True;
  LayoutRow(FBanner);
end;

procedure TSiftMainForm.ShowElevationBannerForTest;
begin
  FBannerLbl.Caption := 'Access denied: Security. Reading these logs needs administrator rights or the Event Log Readers group.';
  FBtnElevate.Visible := True;
  FBanner.Visible := True;
  LayoutRow(FBanner);
end;

function TSiftMainForm.Redacted(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  if not FRedact then
    Exit;
  for I := 0 to FRedactMap.Count - 1 do
    if FRedactMap.Names[I] <> '' then
      Result := StringReplace(Result, FRedactMap.Names[I], FRedactMap.ValueFromIndex[I],
        [rfReplaceAll, rfIgnoreCase]);
end;

procedure TSiftMainForm.SetRedaction(const Map: TStrings);
begin
  FRedactMap.Assign(Map);
  FRedact := FRedactMap.Count > 0;
end;

function TSiftMainForm.RowMessage(I: Integer): string;
var
  Ev: EVT_HANDLE;
begin
  if FMsgCache.TryGetValue(I, Result) then
    Exit;
  if (FDemoMessages <> nil) and (FDemoMessages.Count > 0) then
    Exit(FDemoMessages[I mod FDemoMessages.Count]);
  Result := '';
  if (FRenderer = nil) or (FResult = nil) then
    Exit;
  Ev := FResult.OpenRow(FRenderer, I);
  if Ev <> 0 then
  begin
    Result := FRenderer.FormatMessage(Ev, FResult.Str(FResult.Rows[I]^.ProviderIx));
    EvtClose(Ev);
  end;
  FMsgCache.AddOrSetValue(I, Result);
end;

function TSiftMainForm.RowTaskText(I: Integer): string;
var
  R: PSiftEventRow;
  Key: string;
  Ev: EVT_HANDLE;
begin
  R := FResult.Rows[I];
  if R^.Task = 0 then
    Exit('None');
  Key := FResult.Str(R^.ProviderIx) + '|' + IntToStr(R^.Task);
  if FTaskCache.TryGetValue(Key, Result) then
    Exit;
  Result := '';
  if FRenderer <> nil then
  begin
    Ev := FResult.OpenRow(FRenderer, I);
    if Ev <> 0 then
    begin
      Result := Trim(FRenderer.FormatMessage(Ev, FResult.Str(R^.ProviderIx), EvtFormatMessageTask));
      EvtClose(Ev);
    end;
  end;
  if Result = '' then
    Result := IntToStr(R^.Task)
  else
    Result := Result + ' (' + IntToStr(R^.Task) + ')';
  FTaskCache.AddOrSetValue(Key, Result);
end;

function TSiftMainForm.CellText(I: Integer; C: TGridCol): string;
var
  R: PSiftEventRow;
  Sid: string;
begin
  R := FResult.Rows[I];
  case C of
    gcTime: Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', FileTimeToLocal(R^.TimeCreated));
    gcLevel: Result := LevelCaption(R^.Level);
    gcChannel: Result := FResult.Str(R^.ChannelIx);
    gcProvider: Result := FResult.Str(R^.ProviderIx);
    gcEventId: Result := IntToStr(R^.EventId);
    gcTask: Result := RowTaskText(I);
    gcUser:
      begin
        Sid := FResult.Str(R^.UserIx);
        if Sid = '' then
          Result := 'N/A'
        else
          Result := SidDisplay(Sid);
      end;
    gcComputer: Result := FResult.Str(R^.ComputerIx);
    gcMessage: Result := FirstLine(RowMessage(I));
  end;
  Result := Redacted(Result);
end;

function TSiftMainForm.CellFilterValue(I: Integer; C: TGridCol;
  out F: TSiftField; out V: string): Boolean;
var
  R: PSiftEventRow;
begin
  F := ColFields[C];
  V := '';
  Result := (FResult <> nil) and (I >= 0) and (I < FResult.Count);
  if not Result then
    Exit;
  R := FResult.Rows[I];
  case C of
    gcTime: V := UtcToIso(FileTimeToUtc((R^.TimeCreated div 10000) * 10000));
    gcLevel: V := IntToStr(R^.Level);
    gcChannel: V := FResult.Str(R^.ChannelIx);
    gcProvider: V := FResult.Str(R^.ProviderIx);
    gcEventId: V := IntToStr(R^.EventId);
    gcTask: V := IntToStr(R^.Task);
    gcUser: V := FResult.Str(R^.UserIx);
    gcComputer: V := FResult.Str(R^.ComputerIx);
    gcMessage:
      begin
        V := FirstLine(RowMessage(I));
        if Length(V) > 100 then
          V := Copy(V, 1, 100);
      end;
  end;
  Result := Trim(V) <> '';
end;

procedure TSiftMainForm.GridDrawCell(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
var
  I: Integer;
  C: TGridCol;
  S: string;
  Cv: TCanvas;
  Bg: TColor;
  TS: TTextStyle;
  Pad: Integer;
begin
  if aRow = 0 then
    Exit; { titles drawn by the grid }
  Cv := FGrid.Canvas;
  I := aRow - 1;
  if (FResult = nil) or (I >= FResult.Count) then
    Exit;
  C := TGridCol(aCol);
  if gdSelected in aState then
  begin
    Cv.Brush.Color := clHighlight;
    Cv.Font.Color := clHighlightText;
  end
  else
  begin
    Bg := clNone;
    if FResult.Rows[I]^.Level <= 5 then
      Bg := LevelBg[FResult.Rows[I]^.Level];
    if Bg = clNone then
      Bg := FGrid.Color;
    Cv.Brush.Color := Bg;
    Cv.Font.Color := clWindowText;
  end;
  Cv.FillRect(aRect);
  TS := Cv.TextStyle;
  TS.Clipping := True;
  if C = gcEventId then
    TS.Alignment := taRightJustify
  else
    TS.Alignment := taLeftJustify;
  if FWrap then
  begin
    { wrapped rows can be taller: every column is top-aligned at the offset a
      single centred line would have, so a row still reads as one line }
    Pad := Max(0, (FGrid.DefaultRowHeight - Cv.TextHeight('Ag')) div 2);
    TS.Layout := tlTop;
    if C = gcMessage then
    begin
      S := Redacted(RowMessage(I));
      TS.SingleLine := False;
      TS.WordBreak := True;
      TS.EndEllipsis := False;
    end
    else
    begin
      S := CellText(I, C);
      TS.SingleLine := True;
      TS.WordBreak := False;
      TS.EndEllipsis := True;
    end;
    Cv.TextStyle := TS;
    Cv.TextRect(Rect(aRect.Left + Scale96ToForm(4), aRect.Top + Pad,
      aRect.Right - Scale96ToForm(4), aRect.Bottom), aRect.Left + Scale96ToForm(4),
      aRect.Top + Pad, S);
    Exit;
  end;
  S := CellText(I, C);
  TS.Layout := tlCenter;
  TS.SingleLine := True;
  TS.WordBreak := False;
  TS.EndEllipsis := True;
  Cv.TextStyle := TS;
  Cv.TextRect(Rect(aRect.Left + Scale96ToForm(4), aRect.Top,
    aRect.Right - Scale96ToForm(4), aRect.Bottom), aRect.Left + Scale96ToForm(4),
    aRect.Top, S);
end;

{ Re-sizes Fnt for Ppi when it differs from the font's own DPI (harness DPI
  check); a no-op in normal use. }
procedure ScaleFontTo(Fnt: TFont; Ppi: Integer);
var
  H: Integer;
begin
  if (Ppi <= 0) or (Ppi = Fnt.PixelsPerInch) then
    Exit;
  if Fnt.Size <> 0 then
    H := -MulDiv(Abs(Fnt.Size), Ppi, 72)
  else if Fnt.Height <> 0 then
    H := MulDiv(Fnt.Height, Ppi, Fnt.PixelsPerInch)
  else
    H := -MulDiv(9, Ppi, 72); { LCL default font: 9 pt Segoe UI }
  Fnt.Height := H;
end;

{ TSiftGrid }

procedure TSiftGrid.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
  begin
    FDownX := X;
    FDownY := Y;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

function TSiftGrid.DividerAt(X, Y: Integer): Integer;
var
  Rights: array of Integer;
  I: Integer;
begin
  SetLength(Rights, ColCount);
  for I := 0 to ColCount - 1 do
    Rights[I] := CellRect(I, 0).Right;
  Result := DividerHit(X, Y, RowHeights[0], Rights,
    ScalePx(DividerTol96, Font.PixelsPerInch));
end;

procedure TSiftGrid.DblClick;
var
  C: Integer;
begin
  { the grid's own handling first: it ends any resize drag the first click
    started, and never auto-sizes (goDblClickAutoSize is off) }
  inherited DblClick;
  C := DividerAt(FDownX, FDownY);
  if (C >= 0) and Assigned(FOnDividerDblClick) then
    FOnDividerDblClick(Self, C);
end;

procedure TSiftMainForm.GridDividerDblClick(Sender: TObject; ACol: Integer);
begin
  if (ACol >= 0) and (ACol <= Ord(High(TGridCol))) then
    DividerDblClick(TGridCol(ACol));
end;

procedure TSiftMainForm.DividerDblClick(C: TGridCol);
begin
  if C = gcMessage then
    SetMessageWrap(not FWrap)
  else
    FitColumn(C);
end;

function TSiftMainForm.TaskTextReady(I: Integer): Boolean;
var
  R: PSiftEventRow;
begin
  R := FResult.Rows[I];
  Result := (R^.Task = 0) or (FRenderer = nil) or
    FTaskCache.ContainsKey(FResult.Str(R^.ProviderIx) + '|' + IntToStr(R^.Task));
end;

function TSiftMainForm.ComputeFitWidth(C: TGridCol; Cv: TCanvas; Ppi: Integer): Integer;
var
  Rows: TIntegerDynArray;
  Ws: array of Integer;
  I, N, TopIx, VisN: Integer;
  HeaderW: Integer;
begin
  Cv.Font := FGrid.TitleFont;
  ScaleFontTo(Cv.Font, Ppi);
  HeaderW := Cv.TextWidth(FGrid.Columns[Ord(C)].Title.Caption);
  Cv.Font := FGrid.Font;
  ScaleFontTo(Cv.Font, Ppi);
  Ws := nil;
  if (FResult <> nil) and (FResult.Count > 0) then
  begin
    TopIx := Max(0, FGrid.TopRow - 1);
    VisN := Max(1, FGrid.VisibleRowCount + 1);
    Rows := FitSampleRows(TopIx, VisN, FResult.Count, FitSampleMax);
    SetLength(Ws, Length(Rows));
    N := 0;
    for I := 0 to High(Rows) do
    begin
      { Task names cost a metadata lookup: rows outside the view are only
        measured when their name is already cached }
      if (C = gcTask) and ((Rows[I] < TopIx) or (Rows[I] >= TopIx + VisN)) and
         not TaskTextReady(Rows[I]) then
        Continue;
      Ws[N] := Cv.TextWidth(CellText(Rows[I], C));
      Inc(N);
    end;
    SetLength(Ws, N);
  end;
  Result := FitColumnWidth(HeaderW, Ws, ScalePx(FitPad96, Ppi),
    ScalePx(FitMin96, Ppi), ScalePx(FitMax96, Ppi));
end;

procedure TSiftMainForm.FitColumn(C: TGridCol);
var
  W: Integer;
begin
  W := ComputeFitWidth(C, FGrid.Canvas, PixelsPerInch);
  FLastFitCol := Ord(C);
  FLastFitWidth := W;
  FGrid.Columns[Ord(C)].Width := W;
end;

procedure TSiftMainForm.MiWrapClick(Sender: TObject);
begin
  SetMessageWrap(not FWrap);
end;

procedure TSiftMainForm.UpdateWrapCaption;
begin
  if FMiWrapView <> nil then
    FMiWrapView.Checked := FWrap;
  if FMiWrapGrid <> nil then
    FMiWrapGrid.Checked := FWrap;
  if (FGrid = nil) or (FGrid.Columns.Count <= Ord(gcMessage)) then
    Exit;
  if FWrap then
    FGrid.Columns[Ord(gcMessage)].Title.Caption := ColCaptions[gcMessage] + ' (wrapped)'
  else
    FGrid.Columns[Ord(gcMessage)].Title.Caption := ColCaptions[gcMessage];
end;

procedure TSiftMainForm.SetMessageWrap(V: Boolean);
begin
  if FWrap = V then
    Exit;
  FWrap := V;
  FSettings.WriteBool('MessageWrap', V);
  UpdateWrapCaption;
  ResetWrapHeights;
  UpdateWrapHeights;
  FGrid.Invalidate;
end;

procedure TSiftMainForm.ResetWrapHeights;
var
  R: Integer;
begin
  if FWrapRows.Count = 0 then
    Exit;
  FGrid.BeginUpdate;
  try
    for R in FWrapRows.Keys do
      if (R > 0) and (R < FGrid.RowCount) then
        FGrid.RowHeights[R] := -1;
  finally
    FWrapRows.Clear;
    FGrid.EndUpdate;
  end;
end;

function TSiftMainForm.WrapHeightFor(I: Integer; Cv: TCanvas; TextW: Integer): Integer;
var
  S: string;
  R: TRect;
  LineH, MaxH, Pad: Integer;
begin
  Result := FGrid.DefaultRowHeight;
  S := Trim(Redacted(RowMessage(I)));
  if S = '' then
    Exit;
  LineH := Max(1, Cv.TextHeight('Ag'));
  Pad := Max(0, (FGrid.DefaultRowHeight - LineH) div 2);
  R := Rect(0, 0, Max(10, TextW), 0);
  LCLIntf.DrawText(Cv.Handle, PChar(S), Length(S), R,
    DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX or DT_EDITCONTROL);
  MaxH := LineH * WrapMaxLines + 2 * Pad;
  Result := Min(MaxH, Max(FGrid.DefaultRowHeight, (R.Bottom - R.Top) + 2 * Pad));
end;

procedure TSiftMainForm.UpdateWrapHeights;
var
  Cv: TCanvas;
  R, H, Acc, Avail, TextW: Integer;
begin
  if not FWrap or FInWrap or (FResult = nil) or (FResult.Count = 0) or
     not FGrid.HandleAllocated then
    Exit;
  FInWrap := True;
  try
    Cv := FGrid.Canvas;
    Cv.Font := FGrid.Font;
    TextW := FGrid.ColWidths[Ord(gcMessage)] - Scale96ToForm(8);
    Avail := FGrid.ClientHeight;
    Acc := FGrid.RowHeights[0];
    R := Max(1, FGrid.TopRow);
    FGrid.BeginUpdate;
    try
      while (R < FGrid.RowCount) and (Acc < Avail) and (R - 1 < FResult.Count) do
      begin
        H := WrapHeightFor(R - 1, Cv, TextW);
        if FGrid.RowHeights[R] <> H then
          FGrid.RowHeights[R] := H;
        FWrapRows.AddOrSetValue(R, True);
        Inc(Acc, H);
        Inc(R);
      end;
    finally
      FGrid.EndUpdate;
    end;
  finally
    FInWrap := False;
  end;
end;

procedure TSiftMainForm.GridTopLeftChanged(Sender: TObject);
begin
  if FWrap then
    UpdateWrapHeights;
end;

procedure TSiftMainForm.GridHeaderSized(Sender: TObject; IsColumn: Boolean;
  Index: Integer);
begin
  if FWrap and IsColumn and (Index = Ord(gcMessage)) then
  begin
    ResetWrapHeights;
    UpdateWrapHeights;
  end;
end;

procedure TSiftMainForm.GridSelection(Sender: TObject; aCol, aRow: Integer);
begin
  FDetailTimer.Enabled := False;
  FDetailTimer.Enabled := True;
end;

procedure TSiftMainForm.DetailTimerTick(Sender: TObject);
begin
  FDetailTimer.Enabled := False;
  ShowDetail;
end;

procedure TSiftMainForm.ClearDetail;
begin
  FMemoMsg.Clear;
  FMemoXml.Clear;
  FMemoMeta.Clear;
  FDetailProvider := '';
  FDetailId := -1;
  FDetailQual := -1;
  FDetailVer := -1;
  FMetaShownFor := '';
end;

{ Integer between the first '>' after Tag and the next '<'; -1 if absent }
function XmlIntAfter(const X, Tag: string): Integer;
var
  P, Q: Integer;
begin
  Result := -1;
  P := Pos(Tag, X);
  if P = 0 then
    Exit;
  P := P + Length(Tag);
  while (P <= Length(X)) and (X[P] <> '>') do
    Inc(P);
  Inc(P);
  Q := P;
  while (Q <= Length(X)) and (X[Q] <> '<') do
    Inc(Q);
  Result := StrToIntDef(Trim(Copy(X, P, Q - P)), -1);
end;

function XmlQualifiers(const X: string): Integer;
var
  P, Q: Integer;
begin
  Result := -1;
  P := Pos('Qualifiers=''', X);
  if P = 0 then
    P := Pos('Qualifiers="', X);
  if P = 0 then
    Exit;
  P := P + Length('Qualifiers=''');
  Q := P;
  while (Q <= Length(X)) and (X[Q] in ['0'..'9']) do
    Inc(Q);
  Result := StrToIntDef(Copy(X, P, Q - P), -1);
end;

function TSiftMainForm.EventIdText: string;
var
  Meta: TSiftProviderMeta;
begin
  if FDetailId < 0 then
    Exit('');
  if FMetaCache = nil then
    Exit(MetaNotAvailableText);
  try
    Meta := FMetaCache.Get(FDetailProvider);
    Result := FormatEventMeta(FDetailProvider,
      Meta.Find(Word(FDetailId), FDetailQual, FDetailVer), Meta, Word(FDetailId));
  except
    on E: Exception do
      Result := MetaNotAvailableText;
  end;
end;

procedure TSiftMainForm.ShowMeta;
var
  Key: string;
begin
  if FDetailId < 0 then
    Exit;
  Key := FDetailProvider + '|' + IntToStr(FDetailId) + '|' + IntToStr(FDetailQual) +
    '|' + IntToStr(FDetailVer);
  if Key = FMetaShownFor then
    Exit;
  FMetaShownFor := Key;
  FMemoMeta.Text := EventIdText;
end;

procedure TSiftMainForm.ShowEventIdTab;
begin
  FPages.ActivePageIndex := 2;
  ShowMeta;
end;

procedure TSiftMainForm.PagesChange(Sender: TObject);
begin
  if FPages.ActivePageIndex = 2 then
    ShowMeta;
end;

procedure TSiftMainForm.LookUpOnline(Row: Integer);
var
  R: PSiftEventRow;
  W: UnicodeString;
begin
  if (FResult = nil) or (Row < 0) or (Row >= FResult.Count) then
    Exit;
  R := FResult.Rows[Row];
  FLastLookupUrl := LookupUrl(FResult.Str(R^.ProviderIx), R^.EventId,
    FSettings.ReadStr('LookupUrl', DefaultLookupUrl));
  if FLookupDryRun then
    Exit;
  { the browser does the search; Sift itself makes no network calls }
  W := UTF8Decode(FLastLookupUrl);
  ShellExecuteW(Handle, 'open', PWideChar(W), nil, nil, SW_SHOWNORMAL);
end;

procedure TSiftMainForm.MiLookupClick(Sender: TObject);
begin
  LookUpOnline(FMenuRow);
end;

procedure TSiftMainForm.ShowDetail;
var
  I: Integer;
  Ev: EVT_HANDLE;
  M, X: string;
begin
  ClearDetail;
  I := FGrid.Row - 1;
  if (FResult = nil) or (I < 0) or (I >= FResult.Count) then
    Exit;
  FDetailProvider := FResult.Str(FResult.Rows[I]^.ProviderIx);
  FDetailId := FResult.Rows[I]^.EventId;
  if FDemoMessages <> nil then
  begin
    FMemoMsg.Text := RowMessage(I);
    FMemoXml.Text := '(demo data)';
    if FPages.ActivePageIndex = 2 then
      ShowMeta;
    Exit;
  end;
  if FRenderer = nil then
    Exit;
  Ev := FResult.OpenRow(FRenderer, I);
  if Ev = 0 then
  begin
    FMemoMsg.Text := 'This event could not be re-read (the log may have wrapped).';
    Exit;
  end;
  try
    M := FRenderer.FormatMessage(Ev, FResult.Str(FResult.Rows[I]^.ProviderIx));
    X := FRenderer.RenderXml(Ev);
  finally
    EvtClose(Ev);
  end;
  if M = '' then
    M := '(No message text: the provider''s message resources are not available on this computer. See the XML tab for the event data.)';
  FMemoMsg.Text := Redacted(M);
  FMemoXml.Text := Redacted(PrettyXml(X));
  FDetailVer := XmlIntAfter(X, '<Version');
  FDetailQual := XmlQualifiers(X);
  if FPages.ActivePageIndex = 2 then
    ShowMeta;
end;

procedure TSiftMainForm.SelectRow(I: Integer);
begin
  if (FResult <> nil) and (I >= 0) and (I < FResult.Count) then
  begin
    FGrid.Row := I + 1;
    ShowDetail;
  end;
end;

procedure TSiftMainForm.GridContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  C, R: Integer;
  F: TSiftField;
  V, Shown: string;
  Ok: Boolean;
  Pt: TPoint;
begin
  if (MousePos.X >= 0) and (MousePos.Y >= 0) then
  begin
    FGrid.MouseToCell(MousePos.X, MousePos.Y, C, R);
    if R >= 1 then
      FGrid.Row := R;
  end
  else
  begin
    C := FGrid.Col;
    R := FGrid.Row;
  end;
  Handled := True;
  if (R < 1) or (C < 0) or (FResult = nil) or (R - 1 >= FResult.Count) then
    Exit;
  FMenuCol := TGridCol(C);
  FMenuRow := R - 1;
  Ok := CellFilterValue(FMenuRow, FMenuCol, F, V);
  case FMenuCol of
    gcLevel: Shown := LevelCaption(StrToIntDef(V, 0));
    gcTime: Shown := '>= ' + CellText(FMenuRow, gcTime);
    gcUser: Shown := Redacted(SidDisplay(V));
  else
    Shown := Redacted(V);
  end;
  if Length(Shown) > 60 then
    Shown := Copy(Shown, 1, 57) + '...';
  if FMenuCol = gcMessage then
    Shown := 'text "' + Shown + '" (client-side)';
  FMiInclude.Caption := 'Include ' + ColCaptions[FMenuCol] + ' = ' + Shown;
  FMiExclude.Caption := 'Exclude ' + ColCaptions[FMenuCol] + ' = ' + Shown;
  FMiInclude.Enabled := Ok;
  FMiExclude.Enabled := Ok;
  FMiLookup.Hint := LookupQuery(FResult.Str(FResult.Rows[FMenuRow]^.ProviderIx),
    FResult.Rows[FMenuRow]^.EventId);
  if (MousePos.X >= 0) and (MousePos.Y >= 0) then
    FGridMenu.PopUp
  else
  begin
    { keyboard (Apps key / Shift+F10): open at the focused cell }
    Pt := FGrid.CellRect(C, R).TopLeft;
    Pt := FGrid.ClientToScreen(Point(Pt.X + Scale96ToForm(16), Pt.Y + FGrid.DefaultRowHeight));
    FGridMenu.PopUp(Pt.X, Pt.Y);
  end;
end;

procedure TSiftMainForm.SetDemoData(R: TSiftResult; Messages: TStrings;
  const Channels: TSiftChannelInfos);
begin
  if FDemoMessages = nil then
    FDemoMessages := TStringList.Create;
  FDemoMessages.Assign(Messages);
  FChannelInfos := Copy(Channels);
  if R <> nil then
  begin
    R.Stats.TotalMs := Max(R.Stats.TotalMs, 0);
    LoadResultForTest(R);
    UpdateBanner;
  end;
end;

procedure TSiftMainForm.OpenAbout;
begin
  ShowAboutBox(Self, FVersion);
end;

procedure TSiftMainForm.OpenLogPicker;
begin
  LogsClick(nil);
end;

procedure TSiftMainForm.OpenGridMenuAt(ACol, ARow: Integer);
var
  H: Boolean;
begin
  FGrid.Col := ACol;
  FGrid.Row := ARow + 1;
  H := False;
  GridContextPopup(FGrid, Point(-1, -1), H);
end;

procedure TSiftMainForm.GridKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  H: Boolean;
begin
  if (Key = VK_APPS) or ((Key = VK_F10) and (ssShift in Shift)) then
  begin
    H := False;
    GridContextPopup(Sender, Point(-1, -1), H);
    Key := 0;
  end;
end;

procedure TSiftMainForm.ApplyMenu(AAction: TSiftAction; Mode: TSiftApplyMode);
var
  F: TSiftField;
  V: string;
begin
  if not CellFilterValue(FMenuRow, FMenuCol, F, V) then
    Exit;
  try
    if FFilter.ApplyCell(F, V, AAction, Mode) then
    begin
      UpdateChips;
      RunNow;
    end;
  except
    on E: Exception do
      MessageDlg('Sift', E.Message, mtWarning, [mbOK], 0);
  end;
end;

procedure TSiftMainForm.CellFilterForTest(Row: Integer; Col: TGridCol; Exclude: Boolean);
begin
  FMenuRow := Row;
  FMenuCol := Col;
  if Exclude then
    MiExcAddClick(nil)
  else
    MiIncAddClick(nil);
end;

procedure TSiftMainForm.MiIncAddClick(Sender: TObject);
begin
  ApplyMenu(saInclude, amAdd);
end;

procedure TSiftMainForm.MiIncSetClick(Sender: TObject);
begin
  ApplyMenu(saInclude, amSet);
end;

procedure TSiftMainForm.MiExcAddClick(Sender: TObject);
begin
  ApplyMenu(saExclude, amAdd);
end;

procedure TSiftMainForm.MiExcSetClick(Sender: TObject);
begin
  ApplyMenu(saExclude, amSet);
end;

procedure TSiftMainForm.MiCopyCellClick(Sender: TObject);
begin
  if (FResult <> nil) and (FMenuRow < FResult.Count) then
    Clipboard.AsText := CellText(FMenuRow, FMenuCol);
end;

procedure TSiftMainForm.MiCopyRowClick(Sender: TObject);
var
  C: TGridCol;
  S: string;
begin
  if (FResult = nil) or (FMenuRow >= FResult.Count) then
    Exit;
  S := '';
  for C := Low(TGridCol) to High(TGridCol) do
  begin
    if S <> '' then
      S := S + #9;
    S := S + CellText(FMenuRow, C);
  end;
  Clipboard.AsText := S;
end;

procedure TSiftMainForm.LastClick(Sender: TObject);
begin
  FFilter.SetLastN(LastNs[TSpeedButton(Sender).Tag]);
  RunNow;
end;

procedure TSiftMainForm.WinClick(Sender: TObject);
begin
  FFilter.SetRelativeWindow(Int64(WinMins[TSpeedButton(Sender).Tag]) * 60000);
  RunNow;
end;

procedure TSiftMainForm.AllClick(Sender: TObject);
begin
  FFilter.SetLastN(0);
  FFilter.ClearWindow;
  RunNow;
end;

procedure TSiftMainForm.RefreshClick(Sender: TObject);
begin
  RunNow;
end;

procedure TSiftMainForm.QueryToggleClick(Sender: TObject);
begin
  ShowQueryPanel(not FQueryPanel.Visible);
  FSettings.WriteBool('QueryPanel', FQueryPanel.Visible);
end;

procedure TSiftMainForm.TextIncClick(Sender: TObject);
begin
  if Trim(FEdText.Text) = '' then
    Exit;
  FFilter.AddTerm(MakeTerm(sfMessage, saInclude, FEdText.Text));
  FEdText.Clear;
  RunNow;
end;

procedure TSiftMainForm.TextExcClick(Sender: TObject);
begin
  if Trim(FEdText.Text) = '' then
    Exit;
  FFilter.AddTerm(MakeTerm(sfMessage, saExclude, FEdText.Text));
  FEdText.Clear;
  RunNow;
end;

procedure TSiftMainForm.ChipClick(Sender: TObject);
var
  T: Integer;
begin
  T := TButton(Sender).Tag;
  if T = -1 then
    FFilter.ClearWindow
  else if T = -4 then
    FFilter.SetMaxCount(0)
  else if T >= 0 then
    FFilter.DeleteTerm(T)
  else
    Exit;
  RunNow;
end;

procedure TSiftMainForm.ClearFilterClick(Sender: TObject);
begin
  FFilter.ClearTerms;
  RunNow;
end;

procedure TSiftMainForm.ElevateClick(Sender: TObject);
var
  P, Err: string;
begin
  P := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'sift-restart' + SiftFilterFileExt;
  try
    SaveFilterFile(FFilter, P);
  except
    P := '';
  end;
  if P <> '' then
    P := '--filter "' + P + '"';
  if RestartElevated(P, Err) then
  begin
    FReallyClose := True;
    Close;
  end
  else
    MessageDlg('Sift', Err, mtInformation, [mbOK], 0);
end;

procedure TSiftMainForm.CopyQueryClick(Sender: TObject);
begin
  Clipboard.AsText := CompileFilter(FFilter, FAllChannels).QueryXml;
end;

procedure TSiftMainForm.CopyFHClick(Sender: TObject);
var
  C: TSiftCompiled;
begin
  C := CompileFilter(FFilter, FAllChannels);
  if C.FilterHashtable <> '' then
    Clipboard.AsText := C.FilterHashtable;
end;

procedure TSiftMainForm.ExportPsClick(Sender: TObject);
var
  D: TSaveDialog;
  L: TStringList;
begin
  D := TSaveDialog.Create(Self);
  try
    D.Title := 'Export filter as PowerShell';
    D.Filter := 'PowerShell script (*.ps1)|*.ps1';
    D.DefaultExt := 'ps1';
    D.FileName := 'sift-filter.ps1';
    D.Options := D.Options + [ofOverwritePrompt];
    if D.Execute then
    begin
      L := TStringList.Create;
      try
        L.Text := CompilePowerShell(FFilter, FAllChannels);
        L.SaveToFile(D.FileName);
      finally
        L.Free;
      end;
    end;
  finally
    D.Free;
  end;
end;

procedure TSiftMainForm.MiOpenFilterClick(Sender: TObject);
var
  D: TOpenDialog;
  G: TSiftFilter;
begin
  D := TOpenDialog.Create(Self);
  G := TSiftFilter.Create;
  try
    D.Title := 'Open Sift filter';
    D.Filter := 'Sift filter (*.siftfilter.json;*.json)|*.siftfilter.json;*.json|All files (*.*)|*.*';
    if D.Execute then
    try
      LoadFilterFile(D.FileName, G);
      ApplyFilter(G);
    except
      on E: Exception do
        MessageDlg('Sift', E.Message, mtWarning, [mbOK], 0);
    end;
  finally
    G.Free;
    D.Free;
  end;
end;

procedure TSiftMainForm.MiOpenEvtxClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Open event log file';
    D.Filter := 'Event log files (*.evtx)|*.evtx';
    if D.Execute then
    begin
      FFilter.Channels.Clear;
      FFilter.Channels.Add('file://' + D.FileName);
      UpdateLogsCaption;
      RunNow;
    end;
  finally
    D.Free;
  end;
end;

procedure TSiftMainForm.MiCopyFilterClick(Sender: TObject);
begin
  Clipboard.AsText := FilterToJson(FFilter);
end;

procedure TSiftMainForm.MiPasteFilterClick(Sender: TObject);
var
  G: TSiftFilter;
begin
  G := TSiftFilter.Create;
  try
    try
      FilterFromJson(Clipboard.AsText, G);
      ApplyFilter(G);
    except
      on E: Exception do
        MessageDlg('Sift', E.Message, mtWarning, [mbOK], 0);
    end;
  finally
    G.Free;
  end;
end;

procedure TSiftMainForm.MiExitClick(Sender: TObject);
begin
  FReallyClose := True;
  Close;
end;

procedure TSiftMainForm.MiStartWinClick(Sender: TObject);
var
  Err: string;
begin
  if SetStartWithWindows(not FMiStartWin.Checked, Err) then
    FMiStartWin.Checked := IsStartWithWindows
  else
    MessageDlg('Sift', Err, mtWarning, [mbOK], 0);
end;

procedure TSiftMainForm.MiStartMenuClick(Sender: TObject);
var
  Err: string;
begin
  if SetStartMenuShortcut(not FMiStartMenu.Checked, Err) then
    FMiStartMenu.Checked := HasStartMenuShortcut
  else
    MessageDlg('Sift', Err, mtWarning, [mbOK], 0);
end;

procedure TSiftMainForm.MiCloseTrayClick(Sender: TObject);
begin
  FMiCloseTray.Checked := not FMiCloseTray.Checked;
  FSettings.WriteBool('CloseToTray', FMiCloseTray.Checked);
end;

procedure TSiftMainForm.MiAboutClick(Sender: TObject);
begin
  ShowAboutBox(Self, FVersion);
end;

procedure TSiftMainForm.TrayShowClick(Sender: TObject);
begin
  Show;
  WindowState := wsNormal;
  Application.BringToFront;
end;

procedure TSiftMainForm.TrayLast1Click(Sender: TObject);
begin
  FFilter.SetRelativeWindow(60000);
  TrayShowClick(nil);
  RunNow;
end;

procedure TSiftMainForm.TrayLast5Click(Sender: TObject);
begin
  FFilter.SetRelativeWindow(5 * 60000);
  TrayShowClick(nil);
  RunNow;
end;

procedure TSiftMainForm.TrayLast20Click(Sender: TObject);
begin
  FFilter.SetLastN(20);
  TrayShowClick(nil);
  RunNow;
end;

procedure TSiftMainForm.TrayDblClick(Sender: TObject);
begin
  TrayShowClick(nil);
end;

procedure TSiftMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FSettings.WriteStr('Channels', FFilter.Channels.CommaText);
  if (not FReallyClose) and FTrayOk and FMiCloseTray.Checked then
  begin
    CanClose := False;
    FTray.Visible := True;
    Hide;
    Exit;
  end;
  CanClose := True;
end;

procedure TSiftMainForm.LogsClick(Sender: TObject);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Assign(FFilter.Channels);
    if ShowChannelPicker(Self, FChannelInfos, L) then
    begin
      FFilter.Channels.Assign(L);
      UpdateLogsCaption;
      RunNow;
    end;
  finally
    L.Free;
  end;
end;

procedure TSiftMainForm.ApplyFilter(F: TSiftFilter);
begin
  FFilter.Assign(F);
  if FFilter.Channels.Count = 0 then
  begin
    FFilter.Channels.Add('System');
    FFilter.Channels.Add('Application');
  end;
  UpdateLogsCaption;
  RunNow;
end;

procedure TSiftMainForm.RunNow;
begin
  UpdateChips;
  UpdateQuickButtons;
  UpdateQueryPanel;
  StartQuery;
end;

procedure TSiftMainForm.CancelQuery;
begin
  if FThread <> nil then
  begin
    FThread.Cancel;
    FOldThreads.Add(FThread);
    FThread := nil;
  end;
  FRunning := False;
end;

procedure TSiftMainForm.StartQuery;
begin
  CancelQuery;
  if not EvtApiLoaded then
  begin
    FStatus.Panels[3].Text := 'Event Log API (wevtapi.dll) not available';
    Exit;
  end;
  Inc(FGen);
  FRunning := True;
  FThread := TQueryThread.Create(Self, FFilter, FAllChannels, FGen, FRowCap);
  UpdateStatus;
end;

procedure TSiftMainForm.ReceiveProgress(T: TQueryThread; R: TSiftResult);
var
  Before: Integer;
begin
  if T <> FThread then
    Exit;
  if (FResult = nil) or (FResultGen <> FGen) then
  begin
    FResult.Free;
    FResult := TSiftResult.Create(R.Filter, R.Compiled);
    FResultGen := FGen;
    FMsgCache.Clear;
    if FRenderer <> nil then
      FRenderer.ResetSeekCache;
  end;
  Before := FResult.Count;
  FResult.MergeFrom(R, Before);
  FResult.Stats := R.Stats;
  if Before = 0 then
    ResetWrapHeights;
  FGrid.RowCount := 1 + FResult.Count;
  if Before = 0 then
    FGrid.Row := Min(1, FResult.Count);
  if FWrap then
    UpdateWrapHeights;
  UpdateStatus;
end;

procedure TSiftMainForm.ReceiveDone(T: TQueryThread);
var
  SelKey: string;
begin
  if T <> FThread then
    Exit;
  FThread := nil;
  FOldThreads.Add(T);
  FRunning := False;
  SelKey := '';
  FResult.Free;
  FResult := T.FResult;
  T.FResult := nil;
  FResultGen := FGen;
  FRowCapHit := T.FRowCapHit;
  FMsgCache.Clear;
  if FRenderer <> nil then
    FRenderer.ResetSeekCache;
  ResetWrapHeights;
  if FResult = nil then
  begin
    FGrid.RowCount := 1;
    FStatus.Panels[3].Text := 'Query failed: ' + T.FError;
    Exit;
  end;
  FGrid.RowCount := 1 + FResult.Count;
  if FResult.Count > 0 then
  begin
    FGrid.Row := 1;
    FGrid.TopRow := 1;
  end;
  UpdateWrapHeights;
  FGrid.Invalidate;
  UpdateStatus;
  UpdateBanner;
  ShowDetail;
end;

procedure TSiftMainForm.ReapTimerTick(Sender: TObject);
var
  I: Integer;
  T: TQueryThread;
begin
  for I := FOldThreads.Count - 1 downto 0 do
  begin
    T := TQueryThread(FOldThreads[I]);
    if T.Finished then
    begin
      T.Free;
      FOldThreads.Delete(I);
    end;
  end;
end;

procedure TSiftMainForm.FormResizeHandler(Sender: TObject);
var
  I, Used: Integer;
begin
  if (FStatus = nil) or (FStatus.Panels.Count < 5) then
    Exit;
  { labels autosize only once handles exist, so re-run the row layout }
  LayoutRow(FRow1);
  LayoutRow(FRowTb);
  LayoutRow(FRow2);
  LayoutRow(FBanner);
  LayoutRow(FQueryHead);
  { the path/notes panel absorbs the slack so the version label stays
    visible at the bottom right at any width }
  Used := 0;
  for I := 0 to FStatus.Panels.Count - 1 do
    if I <> 2 then
      Inc(Used, FStatus.Panels[I].Width);
  FStatus.Panels[2].Width := Max(Scale96ToForm(80), FStatus.ClientWidth - Used - Scale96ToForm(20));
  if FWrap then
    UpdateWrapHeights;
end;

procedure TSiftMainForm.LoadResultForTest(R: TSiftResult);
begin
  CancelQuery;
  FResult.Free;
  FResult := R;
  FResultGen := FGen;
  FMsgCache.Clear;
  ResetWrapHeights;
  FGrid.RowCount := 1 + R.Count;
  UpdateWrapHeights;
  UpdateStatus;
end;

procedure TSiftMainForm.EnableTray;
begin
  if FTrayOk then
    FTray.Visible := True;
end;

function TSiftMainForm.WaitForQuery(TimeoutMs: Integer): Boolean;
var
  T0: QWord;
begin
  T0 := GetTickCount64;
  while FRunning and (GetTickCount64 - T0 < QWord(TimeoutMs)) do
  begin
    CheckSynchronize(20);
    Application.ProcessMessages;
  end;
  Result := not FRunning;
end;

procedure TSiftMainForm.DumpUiText(L: TStrings);

  procedure DumpMenu(const Prefix: string; M: TMenuItem);
  var
    I: Integer;
  begin
    for I := 0 to M.Count - 1 do
      if M.Items[I].Caption <> '-' then
      begin
        L.Add(Prefix + StringReplace(M.Items[I].Caption, '&', '', [rfReplaceAll]));
        DumpMenu(Prefix + '  ', M.Items[I]);
      end;
  end;

  procedure DumpCtl(C: TControl);
  var
    I: Integer;
  begin
    if C is TButton then
      L.Add('control TButton: ' + TButton(C).Caption)
    else if C is TSpeedButton then
      L.Add('control TSpeedButton: ' + TSpeedButton(C).Caption)
    else if C is TLabel then
      L.Add('control TLabel: ' + TLabel(C).Caption)
    else if C is TTabSheet then
      L.Add('control TTabSheet: ' + TTabSheet(C).Caption);
    if C is TEdit then
      L.Add('control TEdit hint: ' + TEdit(C).TextHint);
    if C is TWinControl then
      for I := 0 to TWinControl(C).ControlCount - 1 do
        DumpCtl(TWinControl(C).Controls[I]);
  end;

var
  I: Integer;
  G: TGridCol;
begin
  L.Add('window: ' + Caption);
  DumpCtl(Self);
  for G := Low(TGridCol) to High(TGridCol) do
    L.Add('column: ' + ColCaptions[G]);
  for I := 0 to FStatus.Panels.Count - 1 do
    L.Add('status ' + IntToStr(I) + ': ' + FStatus.Panels[I].Text);
  DumpMenu('menu: ', FMainMenu.Items);
  DumpMenu('grid menu: ', FGridMenu.Items);
  DumpMenu('tray menu: ', FTrayMenu.Items);
  L.Add('tray hint: ' + FTray.Hint);
  L.Add('tray available: ' + BoolToStr(FTrayOk, 'yes', 'no'));
end;

{ Channel picker }

type
  TPicker = class(TForm)
  public
    Search: TEdit;
    List: TCheckListBox;
    ChkAll: TCheckBox;
    Infos: TSiftChannelInfos;
    Names: TStringList;
    Checked: TStringList;
    procedure Refill;
    procedure SearchChange(Sender: TObject);
    procedure ListClickCheck(Sender: TObject);
    procedure AllChange(Sender: TObject);
    destructor Destroy; override;
  end;

destructor TPicker.Destroy;
begin
  Names.Free;
  Checked.Free;
  inherited Destroy;
end;

procedure TPicker.Refill;
var
  I: Integer;
  Q: string;
begin
  Q := LowerCase(Trim(Search.Text));
  List.Items.BeginUpdate;
  try
    List.Items.Clear;
    for I := 0 to Names.Count - 1 do
      if (Q = '') or (Pos(Q, LowerCase(Names[I])) > 0) then
        List.Checked[List.Items.Add(Names[I])] := Checked.IndexOf(Names[I]) >= 0;
  finally
    List.Items.EndUpdate;
  end;
end;

procedure TPicker.SearchChange(Sender: TObject);
begin
  Refill;
end;

procedure TPicker.ListClickCheck(Sender: TObject);
var
  I, J: Integer;
begin
  for I := 0 to List.Items.Count - 1 do
  begin
    J := Checked.IndexOf(List.Items[I]);
    if List.Checked[I] and (J < 0) then
      Checked.Add(List.Items[I])
    else if not List.Checked[I] and (J >= 0) then
      Checked.Delete(J);
  end;
end;

procedure TPicker.AllChange(Sender: TObject);
begin
  List.Enabled := not ChkAll.Checked;
  Search.Enabled := not ChkAll.Checked;
end;

function ShowChannelPicker(Owner: TForm; const Infos: TSiftChannelInfos;
  Current: TStrings): Boolean;
var
  P: TPicker;
  Q: TStringList;
  BOk, BCancel: TButton;
  Bottom: TPanel;
  I: Integer;
  S: string;
begin
  P := TPicker.CreateNew(Owner);
  try
    P.Caption := 'Choose logs';
    P.Position := poOwnerFormCenter;
    P.Width := P.Scale96ToForm(560);
    P.Height := P.Scale96ToForm(560);
    P.BorderIcons := [biSystemMenu];
    P.Names := TStringList.Create;
    P.Checked := TStringList.Create;
    P.Checked.CaseSensitive := False;
    Q := TStringList.Create;
    try
      QueryableChannels(Infos, Q);
      P.Names.Assign(Q);
    finally
      Q.Free;
    end;
    for S in Current do
      if (S <> '*') then
      begin
        P.Checked.Add(S);
        if P.Names.IndexOf(S) < 0 then
          P.Names.Insert(0, S);
      end;
    P.ChkAll := TCheckBox.Create(P);
    P.ChkAll.Parent := P;
    P.ChkAll.Align := alTop;
    P.ChkAll.BorderSpacing.Around := P.Scale96ToForm(8);
    P.ChkAll.Caption := Format('All logs (%d enabled Admin and Operational logs)', [P.Names.Count]);
    P.ChkAll.Checked := Current.IndexOf('*') >= 0;
    P.ChkAll.OnChange := @P.AllChange;
    P.Search := TEdit.Create(P);
    P.Search.Parent := P;
    P.Search.Align := alTop;
    P.Search.Top := 100;
    P.Search.BorderSpacing.Left := P.Scale96ToForm(8);
    P.Search.BorderSpacing.Right := P.Scale96ToForm(8);
    P.Search.TextHint := 'Search logs...';
    P.Search.OnChange := @P.SearchChange;
    Bottom := TPanel.Create(P);
    Bottom.Parent := P;
    Bottom.Align := alBottom;
    Bottom.BevelOuter := bvNone;
    Bottom.Height := P.Scale96ToForm(44);
    BCancel := TButton.Create(P);
    BCancel.Parent := Bottom;
    BCancel.Caption := 'Cancel';
    BCancel.ModalResult := mrCancel;
    BCancel.Cancel := True;
    BCancel.Width := P.Scale96ToForm(88);
    BCancel.Height := P.Scale96ToForm(28);
    BCancel.Anchors := [akRight, akTop];
    BCancel.Left := Bottom.ClientWidth - BCancel.Width - P.Scale96ToForm(8);
    BCancel.Top := P.Scale96ToForm(8);
    BOk := TButton.Create(P);
    BOk.Parent := Bottom;
    BOk.Caption := 'OK';
    BOk.ModalResult := mrOk;
    BOk.Default := True;
    BOk.Width := P.Scale96ToForm(88);
    BOk.Height := P.Scale96ToForm(28);
    BOk.Anchors := [akRight, akTop];
    BOk.Left := BCancel.Left - BOk.Width - P.Scale96ToForm(6);
    BOk.Top := P.Scale96ToForm(8);
    P.List := TCheckListBox.Create(P);
    P.List.Parent := P;
    P.List.Align := alClient;
    P.List.BorderSpacing.Around := P.Scale96ToForm(8);
    P.List.ItemHeight := P.Scale96ToForm(24);
    P.List.OnClickCheck := @P.ListClickCheck;
    P.Refill;
    P.AllChange(nil);
    Result := P.ShowModal = mrOk;
    if Result then
    begin
      Current.Clear;
      if P.ChkAll.Checked then
        Current.Add('*')
      else
        for I := 0 to P.Names.Count - 1 do
          if P.Checked.IndexOf(P.Names[I]) >= 0 then
            Current.Add(P.Names[I]);
      if Current.Count = 0 then
        Result := False;
    end;
  finally
    P.Free;
  end;
end;

procedure ShowAboutBox(Owner: TForm; const Version: string);
var
  F: TForm;
  L: TLabel;
  B: TButton;
  Img: TImage;
  Y: Integer;

  procedure Line(const S: string; Bold: Boolean = False);
  begin
    L := TLabel.Create(F);
    L.Parent := F;
    L.Caption := S;
    L.Left := F.Scale96ToForm(88);
    L.Top := Y;
    if Bold then
      L.Font.Style := [fsBold];
    Inc(Y, L.Height + F.Scale96ToForm(6));
  end;

begin
  F := TForm.CreateNew(Owner);
  try
    F.Caption := 'About Sift';
    F.BorderStyle := bsDialog;
    F.Position := poOwnerFormCenter;
    F.Width := F.Scale96ToForm(460);
    F.Height := F.Scale96ToForm(250);
    Img := TImage.Create(F);
    Img.Parent := F;
    Img.Left := F.Scale96ToForm(16);
    Img.Top := F.Scale96ToForm(16);
    Img.Width := F.Scale96ToForm(64);
    Img.Height := F.Scale96ToForm(64);
    Img.Stretch := True;
    Img.Picture.Icon.Assign(Application.Icon);
    Y := F.Scale96ToForm(16);
    Line('Sift ' + Version, True);
    Line('A light, fast Windows event log viewer.');
    Line('Filters run inside the event log service.');
    Line('Free to use: MIT license with Commons Clause. No telemetry.');
    Line('Copyright (c) 2026 kilrkrow');
    Line('Built with Free Pascal and Lazarus (LCL).');
    B := TButton.Create(F);
    B.Parent := F;
    B.Caption := 'OK';
    B.ModalResult := mrOk;
    B.Default := True;
    B.Cancel := True;
    B.Width := F.Scale96ToForm(88);
    B.Height := F.Scale96ToForm(28);
    B.Left := F.ClientWidth - B.Width - F.Scale96ToForm(12);
    B.Top := F.ClientHeight - B.Height - F.Scale96ToForm(12);
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.
