unit Sift.Shell;

{ Windows integration for the viewer: settings, Start-with-Windows (HKCU Run),
  Start menu shortcut, notification-area detection, elevation restart and
  version info. Everything degrades quietly on Server Core (no Explorer). }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, IniFiles;

const
  AppName = 'Sift';
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  RunValue = 'Sift';

type
  TSiftSettings = class
  private
    FIni: TIniFile;
  public
    constructor Create;
    destructor Destroy; override;
    function ReadBool(const Key: string; Def: Boolean): Boolean;
    procedure WriteBool(const Key: string; V: Boolean);
    function ReadStr(const Key, Def: string): string;
    procedure WriteStr(const Key, V: string);
    function ReadInt(const Key: string; Def: Integer): Integer;
    procedure WriteInt(const Key: string; V: Integer);
  end;

function SettingsDir: string;
function ExePath: string;

var
  { Full path of the ini file to use instead of %APPDATA%\Sift\sift.ini
    (set by the harness so it never touches the user's settings). }
  SiftSettingsFile: string = '';

{ HKCU Run value, no admin needed. }
function IsStartWithWindows: Boolean;
function SetStartWithWindows(Enable: Boolean; out Err: string): Boolean;

{ %APPDATA%\Microsoft\Windows\Start Menu\Programs\Sift.lnk }
function StartMenuShortcutPath: string;
function HasStartMenuShortcut: Boolean;
function SetStartMenuShortcut(Enable: Boolean; out Err: string): Boolean;

{ True when Explorer's notification area exists (not on Server Core). }
function NotificationAreaAvailable: Boolean;

{ Re-launches this exe through the "runas" verb (the user sees UAC). }
function RestartElevated(const Params: string; out Err: string): Boolean;

function FileVersionString: string;  { e.g. '0.1.0' (from VERSIONINFO) }
function FileVersionFull: string;    { e.g. '0.1.0.0' }
function VersionInfoValue(const Key: string): string;

implementation

uses
  Registry, ShellApi, ActiveX, ShlObj, ComObj;

function ExePath: string;
begin
  Result := ParamStr(0);
end;

function SettingsDir: string;
begin
  Result := GetEnvironmentVariable('APPDATA');
  if Result = '' then
    Result := ExtractFileDir(ExePath);
  Result := IncludeTrailingPathDelimiter(Result) + AppName;
  ForceDirectories(Result);
  Result := IncludeTrailingPathDelimiter(Result);
end;

{ TSiftSettings }

constructor TSiftSettings.Create;
begin
  if SiftSettingsFile <> '' then
  begin
    ForceDirectories(ExtractFileDir(SiftSettingsFile));
    FIni := TIniFile.Create(SiftSettingsFile);
  end
  else
    FIni := TIniFile.Create(SettingsDir + 'sift.ini');
end;

destructor TSiftSettings.Destroy;
begin
  FIni.Free;
  inherited Destroy;
end;

function TSiftSettings.ReadBool(const Key: string; Def: Boolean): Boolean;
begin
  Result := FIni.ReadBool('Sift', Key, Def);
end;

procedure TSiftSettings.WriteBool(const Key: string; V: Boolean);
begin
  try
    FIni.WriteBool('Sift', Key, V);
  except
    { read-only profile: keep running }
  end;
end;

function TSiftSettings.ReadStr(const Key, Def: string): string;
begin
  Result := FIni.ReadString('Sift', Key, Def);
end;

procedure TSiftSettings.WriteStr(const Key, V: string);
begin
  try
    FIni.WriteString('Sift', Key, V);
  except
  end;
end;

function TSiftSettings.ReadInt(const Key: string; Def: Integer): Integer;
begin
  Result := FIni.ReadInteger('Sift', Key, Def);
end;

procedure TSiftSettings.WriteInt(const Key: string; V: Integer);
begin
  try
    FIni.WriteInteger('Sift', Key, V);
  except
  end;
end;

function RunCommand: string;
begin
  Result := '"' + ExePath + '" --tray';
end;

function IsStartWithWindows: Boolean;
var
  R: TRegistry;
begin
  Result := False;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly(RunKey) then
      Result := R.ValueExists(RunValue) and
        SameText(R.ReadString(RunValue), RunCommand);
  finally
    R.Free;
  end;
end;

function SetStartWithWindows(Enable: Boolean; out Err: string): Boolean;
var
  R: TRegistry;
begin
  Err := '';
  Result := False;
  R := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    R.RootKey := HKEY_CURRENT_USER;
    try
      if R.OpenKey(RunKey, True) then
      begin
        if Enable then
          R.WriteString(RunValue, RunCommand)
        else if R.ValueExists(RunValue) then
          R.DeleteValue(RunValue);
        Result := True;
      end
      else
        Err := 'Could not open HKCU\' + RunKey;
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    R.Free;
  end;
end;

function StartMenuShortcutPath: string;
var
  A: string;
begin
  A := GetEnvironmentVariable('APPDATA');
  if A = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(A) +
    'Microsoft\Windows\Start Menu\Programs\' + AppName + '.lnk';
end;

function HasStartMenuShortcut: Boolean;
var
  P: string;
begin
  P := StartMenuShortcutPath;
  Result := (P <> '') and FileExists(P);
end;

function SetStartMenuShortcut(Enable: Boolean; out Err: string): Boolean;
var
  P: string;
  Obj: IUnknown;
  Link: IShellLinkW;
  PF: IPersistFile;
  W: UnicodeString;
  Hr: HRESULT;
  Inited: Boolean;
begin
  Err := '';
  Result := False;
  P := StartMenuShortcutPath;
  if P = '' then
  begin
    Err := 'APPDATA is not set.';
    Exit;
  end;
  if not Enable then
  begin
    if FileExists(P) and not DeleteFile(P) then
      Err := 'Could not delete ' + P
    else
      Result := True;
    Exit;
  end;
  Inited := Succeeded(CoInitialize(nil));
  try
    try
      ForceDirectories(ExtractFileDir(P));
      Hr := CoCreateInstance(CLSID_ShellLink, nil, CLSCTX_INPROC_SERVER,
        IUnknown, Obj);
      if Failed(Hr) then
      begin
        Err := 'Shell link object is not available (no Explorer shell?).';
        Exit;
      end;
      Link := Obj as IShellLinkW;
      W := UnicodeString(ExePath);
      Link.SetPath(PWideChar(W));
      W := UnicodeString(ExtractFileDir(ExePath));
      Link.SetWorkingDirectory(PWideChar(W));
      W := 'Sift - fast Windows event log viewer';
      Link.SetDescription(PWideChar(W));
      W := UnicodeString(ExePath);
      Link.SetIconLocation(PWideChar(W), 0);
      PF := Link as IPersistFile;
      W := UnicodeString(P);
      Hr := PF.Save(PWideChar(W), True);
      Result := Succeeded(Hr);
      if not Result then
        Err := 'Saving the shortcut failed: ' + SysErrorMessage(Hr);
    except
      on E: Exception do
        Err := E.Message;
    end;
  finally
    Link := nil;
    PF := nil;
    Obj := nil;
    if Inited then
      CoUninitialize;
  end;
end;

function NotificationAreaAvailable: Boolean;
begin
  Result := FindWindow('Shell_TrayWnd', nil) <> 0;
end;

function RestartElevated(const Params: string; out Err: string): Boolean;
var
  Exe, Par: UnicodeString;
  R: HINST;
begin
  Err := '';
  Exe := UnicodeString(ExePath);
  Par := UnicodeString(Params);
  R := ShellExecuteW(0, 'runas', PWideChar(Exe), PWideChar(Par), nil, SW_SHOWNORMAL);
  Result := PtrUInt(R) > 32;
  if not Result then
    Err := 'Elevation was cancelled or is not available (' + IntToStr(PtrUInt(R)) + ').';
end;

type
  TLangCp = packed record
    Lang, Cp: Word;
  end;
  PLangCp = ^TLangCp;

  TGetFileVersionInfoSizeW = function(lptstrFilename: PWideChar;
    var lpdwHandle: DWORD): DWORD; stdcall;
  TGetFileVersionInfoW = function(lptstrFilename: PWideChar;
    dwHandle, dwLen: DWORD; lpData: Pointer): WINBOOL; stdcall;
  TVerQueryValueW = function(pBlock: Pointer; lpSubBlock: PWideChar;
    var lplpBuffer: Pointer; var puLen: UINT): WINBOOL; stdcall;

var
  VersionLib: HMODULE = 0;
  pGetFileVersionInfoSizeW: TGetFileVersionInfoSizeW = nil;
  pGetFileVersionInfoW: TGetFileVersionInfoW = nil;
  pVerQueryValueW: TVerQueryValueW = nil;

function System32Dll(const Dll: UnicodeString): UnicodeString;
var
  Dir: array[0..MAX_PATH] of WideChar;
  N: UINT;
begin
  Result := '';
  N := GetSystemDirectoryW(@Dir[0], MAX_PATH);
  if (N = 0) or (N >= MAX_PATH) then
    Exit;
  Result := UnicodeString(PWideChar(@Dir[0]));
  if (Length(Result) > 0) and (Result[Length(Result)] <> '\') then
    Result := Result + '\';
  Result := Result + Dll;
end;

function LoadVersionApis: Boolean;
var
  Path: UnicodeString;
begin
  if Assigned(pGetFileVersionInfoSizeW) and Assigned(pGetFileVersionInfoW)
    and Assigned(pVerQueryValueW) then
  begin
    Result := True;
    Exit;
  end;
  Result := False;
  Path := System32Dll('version.dll');
  if Path = '' then
    Exit;
  VersionLib := LoadLibraryW(PWideChar(Path));
  if VersionLib = 0 then
    Exit;
  pGetFileVersionInfoSizeW := TGetFileVersionInfoSizeW(
    GetProcAddress(VersionLib, 'GetFileVersionInfoSizeW'));
  pGetFileVersionInfoW := TGetFileVersionInfoW(
    GetProcAddress(VersionLib, 'GetFileVersionInfoW'));
  pVerQueryValueW := TVerQueryValueW(
    GetProcAddress(VersionLib, 'VerQueryValueW'));
  Result := Assigned(pGetFileVersionInfoSizeW) and Assigned(pGetFileVersionInfoW)
    and Assigned(pVerQueryValueW);
end;

function ReadVersionBlock(out Buf: TBytes): Boolean;
var
  Dummy, Size: DWORD;
  W: UnicodeString;
begin
  Result := False;
  if not LoadVersionApis then
    Exit;
  W := UnicodeString(ExePath);
  Size := pGetFileVersionInfoSizeW(PWideChar(W), Dummy);
  if Size = 0 then
    Exit;
  SetLength(Buf, Size);
  Result := pGetFileVersionInfoW(PWideChar(W), 0, Size, @Buf[0]);
end;

function VersionInfoValue(const Key: string): string;
var
  Buf: TBytes;
  P: Pointer;
  Len: UINT;
  LC: PLangCp;
  Sub: UnicodeString;
begin
  Result := '';
  if not ReadVersionBlock(Buf) then
    Exit;
  if not pVerQueryValueW(@Buf[0], '\VarFileInfo\Translation', P, Len) or (Len < 4) then
    Exit;
  LC := PLangCp(P);
  Sub := UnicodeString(Format('\StringFileInfo\%.4x%.4x\%s', [LC^.Lang, LC^.Cp, Key]));
  if pVerQueryValueW(@Buf[0], PWideChar(Sub), P, Len) and (Len > 0) then
    Result := UTF8Encode(UnicodeString(PWideChar(P)));
end;

function FixedVersion(out A, B, C, D: Word): Boolean;
var
  Buf: TBytes;
  P: Pointer;
  Len: UINT;
  FI: PVSFixedFileInfo;
begin
  Result := False;
  A := 0; B := 0; C := 0; D := 0;
  if not ReadVersionBlock(Buf) then
    Exit;
  if pVerQueryValueW(@Buf[0], '\', P, Len) and (Len >= SizeOf(TVSFixedFileInfo)) then
  begin
    FI := PVSFixedFileInfo(P);
    A := HiWord(FI^.dwFileVersionMS);
    B := LoWord(FI^.dwFileVersionMS);
    C := HiWord(FI^.dwFileVersionLS);
    D := LoWord(FI^.dwFileVersionLS);
    Result := True;
  end;
end;


function FileVersionString: string;
var
  A, B, C, D: Word;
begin
  if FixedVersion(A, B, C, D) then
    Result := Format('%d.%d.%d', [A, B, C])
  else
    Result := '?';
end;

function FileVersionFull: string;
var
  A, B, C, D: Word;
begin
  if FixedVersion(A, B, C, D) then
    Result := Format('%d.%d.%d.%d', [A, B, C, D])
  else
    Result := '?';
end;

end.
