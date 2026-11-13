# Compatibility

Target: one native exe, no runtime, Windows 7 / Server 2008 R2 through
Windows 11 / Server 2025, Server Core included; x64 (win64) and x86 (win32).

## Where it was actually run (0.1.0)

| Windows version | win64 exe | win32 exe | How |
|---|---|---|---|
| Windows 11 Pro 64-bit (dev PC) | run | run | headless only, using the separate harness build (`--dump-ui`, `--screenshots`, `--selftest-grid` on a private desktop); SiftCore tests as win64 and as win32: 97 passed, 1 skipped (optional SIFT_PROBE_EVTX fixture), 0 failed, and 98/98 passed with SIFT_PROBE_EVTX set; all 11 quick buttons and the 57-check `--feature-check` (pieces 8 to 10) pass in both harness exes |
| Windows 11, visible interactive session | not run | not run | pending batched UI check with the maintainer |
| Windows 10 | not run | not run | no machine or VM available |
| Windows 7 SP1 | not run | not run | no machine or VM available |
| Windows Server 2008 R2 | not run | not run | no machine or VM available |
| Windows Server 2016 / 2019 / 2022 / 2025 | not run | not run | no machine or VM available |
| Windows Server Core (any) | not run | not run | no machine or VM available |

"Run" means the exe started, built its full window, ran real queries and
rendered; it does not mean every feature was clicked by a person.

## Static import check

`tools/Check-Imports.ps1` parses the PE import table of each exe and fails on
any DLL+function pair that is not on the reviewed allowlist
(`tools/imports-allowlist.txt`, 489 pairs, all present on Windows XP or
later), on any DLL that does not ship with Windows 7 (or that must be loaded
dynamically, like wevtapi.dll) and on a list of functions introduced after
Windows 7 (DPI-per-monitor APIs, GetSystemTimePreciseAsFileTime, CreateFile2,
...). It also fails when the exe has no icon group (or an icon group whose
images are missing) or no version resource, and every build mode runs it
after linking, so such a build fails. Full lists: [imports-win64.txt](imports-win64.txt),
[imports-win32.txt](imports-win32.txt).

Result at 0.1.0: PASS for both release exes (the harness exes fail it on
purpose: CreateDesktopW, CloseDesktop, PrintWindow and EndMenu are not on the
release allowlist). 10 DLLs (kernel32, user32, gdi32,
advapi32, shell32, ole32, oleaut32, comctl32, comdlg32, version); every
imported function is available on Windows XP or later. wevtapi.dll (Vista+)
is loaded at runtime with LoadLibrary/GetProcAddress, and LCL loads its
newer DPI functions the same way.

## Design choices for old and minimal Windows

- Evt* API only (Vista+), loaded dynamically; if wevtapi.dll is missing the
  status bar says so instead of crashing.
- Tray: `FindWindow('Shell_TrayWnd')` decides whether a notification area
  exists. Without one (Server Core) the tray icon is never created,
  close-to-tray is disabled and `--tray` opens a normal window.
- Start menu shortcut is a per-user .lnk via IShellLinkW; it is an optional
  toggle, not needed for any core feature.
- DPI: manifest declares `True/PM_V2` (per-monitor v2 on Windows 10 1703+,
  system DPI aware on Windows 7/8). Layout uses Scale96ToForm everywhere.
