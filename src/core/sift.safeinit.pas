unit Sift.SafeInit;

{ Must be the first unit in the program uses clause.

  The initialization section:
    1. Calls SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32)
       through GetProcAddress, so a later LoadLibrary('foo.dll') does
       not pick up a DLL sitting next to the exe. On unpatched Windows 7,
       where the API is missing, the call is skipped and the process
       starts normally.
    2. Binds version.dll IAT slots to System32. The LCL (SysUtils.
       GetFileVersion for comctl32) statically imports version.dll,
       which the OS would otherwise load from the exe directory.
       tools/Unimport-VersionDll.ps1, run after linking, removes that
       import from the PE and fills VersionBindTable; this unit then
       LoadLibraryW's the System32 path and writes the IAT. If the
       table is empty (an unpatched build), this step is a no-op. }

{$mode objfpc}{$H+}

interface

implementation

uses
  Windows;

const
  LOAD_LIBRARY_SEARCH_SYSTEM32 = $00000800;

type
  TSetDefaultDllDirectories = function(DirectoryFlags: DWORD): WINBOOL; stdcall;

  TVersionBindSlot = packed record
    IatRva: LongWord;
    Name: array[0..31] of AnsiChar;
  end;

  TVersionBindTable = packed record
    Magic: array[0..7] of AnsiChar;
    Count: LongWord;
    Slots: array[0..7] of TVersionBindSlot;
  end;

var
  { 'SIFTVBIN' is the post-link tool's search key. Must live in
    initialized data so it is present in the file (not .bss). }
  VersionBindTable: TVersionBindTable = (
    Magic: ('S', 'I', 'F', 'T', 'V', 'B', 'I', 'N');
    Count: 0;
    Slots: (
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0)),
      (IatRva: 0; Name: (#0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0, #0))
    )
  );

procedure ApplySafeDllSearch;
var
  K: HMODULE;
  P: TSetDefaultDllDirectories;
begin
  K := GetModuleHandleA('kernel32.dll');
  if K = 0 then
    Exit;
  P := TSetDefaultDllDirectories(GetProcAddress(K, 'SetDefaultDllDirectories'));
  if Assigned(P) then
    P(LOAD_LIBRARY_SEARCH_SYSTEM32);
end;

function System32VersionDll: UnicodeString;
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
  Result := Result + 'version.dll';
end;

procedure BindVersionIAT;
var
  Base: HMODULE;
  Lib: HMODULE;
  Path: UnicodeString;
  I: Integer;
  P: FARPROC;
  Dest: PPointer;
  Name: PAnsiChar;
begin
  if (VersionBindTable.Magic[0] <> 'S') or (VersionBindTable.Magic[1] <> 'I')
    or (VersionBindTable.Count = 0) then
    Exit;
  Base := GetModuleHandleA(nil);
  if Base = 0 then
    Exit;
  Path := System32VersionDll;
  if Path = '' then
    Exit;
  Lib := LoadLibraryW(PWideChar(Path));
  if Lib = 0 then
    Exit;
  for I := 0 to Integer(VersionBindTable.Count) - 1 do
  begin
    if VersionBindTable.Slots[I].IatRva = 0 then
      Continue;
    Name := @VersionBindTable.Slots[I].Name[0];
    P := GetProcAddress(Lib, Name);
    if not Assigned(P) then
      Continue;
    { .idata is writable in the FPC-produced PE, so no VirtualProtect. }
    Dest := PPointer(PtrUInt(Base) + VersionBindTable.Slots[I].IatRva);
    Dest^ := Pointer(P);
  end;
end;

initialization
  ApplySafeDllSearch;
  BindVersionIAT;

end.
