# Critic results, Phase 1 (0.1.0)

How these were run: each piece had a builder pass and a separate critic pass
with its own checklist taken from the brief. Both were run by the same
builder agent (Prototyper), as scripted checks and evidence review, not by
independent reviewers. Where a check needs a visible desktop or admin rights
it is marked PENDING, not passed.

## 1. Evt bindings and SiftCore filter compiler: PASS

- Binding search: no Evt* binding exists in the FPC 3.2.2 / Lazarus 4.8
  distribution (searched every .pas/.pp/.inc for EvtQuery), so
  `sift.evtapi` is hand-written and loaded dynamically. 10 binding tests pass
  (including missing and access-denied channels and bookmark seek).
- Golden tests: 19 pass (filter to expected `<QueryList>` text, FilterHashtable
  one-liner, or the full -FilterXml command when FilterHashtable cannot express the filter, Export as PowerShell text).
- Round-trip: 7 JSON tests pass (filter to JSON to filter, and bad-file
  handling).
- Equivalence against Get-WinEvent (Windows PowerShell 5.1) on fixtures:
  include/exclude combos, include and exclude on the same field, more than 20
  terms, multi-channel, empty result (NoMatchingEventsFound), user/computer/
  task/keywords, access denied: all pass. Also on an optional extra .evtx named by `SIFT_PROBE_EVTX`
  (on the dev PC, the 324-event System export kept from the WPF probe);
  the test reports SKIP when the variable is not set.
- Found and fixed during the critic pass: multi-log results are not strictly
  time-ordered from the service (the probe assumed they were), so multi-log
  last-N is per-log then merged; `TryStrToInt64('x1')` accepted hex; lazy
  re-open by EventRecordID XPath was 25 to 33 ms per row (now bookmark seek,
  0.11 ms).

## 2. Fixture generator: PASS with one PENDING item

- `Make-Fixtures.ps1` exports System and Application .evtx fixtures
  unelevated with `wevtutil epl`; the tests regenerate them when missing and
  pass with no admin rights (65/65 as win64 and as win32).
- Reproducible: same script, same record-range rule; the files are not
  committed because they contain real machine events (see .gitignore).
- PENDING (needs the maintainer): the dedicated `SiftTest` source. The one elevated
  step is `Register-SiftTestSource.ps1` (`New-EventLog -LogName Application
  -Source SiftTest`); `Write-SiftTestEvents.ps1` then writes known events
  across levels and IDs spread over 1 min to 4 h. Not run.

## 3. Viewer grid, right-click Include/Exclude, chips, quick buttons: PASS (headless), visible check PENDING

- Every right-click path: all 36 combinations (9 columns x Include/Exclude x
  Add to/Set as) produce the expected AST change (`test.filter`).
- Last-N 5/10/20/40 and windows 1/5/15/30/60/240 min return exactly what
  Get-WinEvent returns for the same window, on fixtures and live
  (`TimeWindowsMatch`, `LiveLastNMatchesGetWinEvent`,
  `LiveWindowsMatchGetWinEvent`).
- All 11 quick buttons clicked in both exes (`--dump-ui`): each set the
  expected filter, returned rows in order and inside the window.
- 100k+ rows: 217,488 rows, paint 13 to 24 ms per frame (docs/benchmarks.md).
- Right-click menu and chips captured in docs/images (private desktop).
- PENDING: a person right-clicking and using Shift+F10/Apps key in a
  visible session.

## 4. Detail pane, query panel, copy/paste/open filter, Export as PowerShell: PASS

- The exported PowerShell, run as-is on Windows PowerShell 5.1, returns the
  same events (`ExportedPowerShellReturnsSameEvents`), including excludes
  (emitted as `-FilterXml` with Suppress) and multi-log last-N.
- The FilterHashtable one-liner, run as-is, returns the same events for
  include-only filters (`HashtableOracleIncludeOnly`); for filters it cannot
  express exactly the slot shows the -FilterXml command instead (screenshot: query-panel.png).
- PENDING: clipboard copy/paste and the Open dialogs by hand.

## 5. Shell and packaging: PASS (headless), visible launch PENDING

- Both exes started (on a private desktop, nothing shown) and every label,
  menu, tray-menu item and status panel was read back (`--dump-ui`): ASCII
  only, no mojibake, no LCL default icon, version `v0.1.0` at the bottom
  right in both, version resource 0.1.0.0, CompanyName kilrkrow,
  LegalCopyright "Copyright (c) 2026 kilrkrow".
- Icon: 9 sizes (16 to 256); the exe, window title bar and about box use it (screenshots).
  Found and fixed: the first .ico used PNG entries at every size and hung
  `Application.Initialize` in LCL; small sizes are now classic DIB entries,
  256 is PNG.
- Pen-name check (grep for the owner's real surname and user-profile name, case-insensitive): 0 hits in the tracked tree, the working tree and all four exes (release and harness, ASCII and UTF-16).
- PENDING: real notification-area icon and its menu, Start-with-Windows and
  Add-to-Start-menu toggles exercised by hand, close-to-tray, and the
  "Restart elevated" button (it raises a UAC prompt by design, so it was not
  clicked).

## 6. Compatibility pass: PASS for the import check; other Windows versions NOT RUN

- Static import check (both release exes): PASS against the reviewed
  DLL+function allowlist (tools/imports-allowlist.txt). 10 DLLs, all functions XP-era
  (docs/imports-win64.txt, docs/imports-win32.txt), wevtapi.dll dynamic.
- Run only on Windows 11 (headless). Windows 7/10 and Server versions: not
  run, no machine or VM available (docs/compat.md).

## 7. Perf benchmark script: PASS with one PENDING item

- `tools/bench/Run-Benchmarks.ps1` vs plain Get-WinEvent, row counts match in
  every case; first row 1.3 to 4.1 ms, full System log 222 ms vs 10.9 s.
- The "~100 MB log" is a 194 MB export of the 8 largest local logs (no single
  log here is near 100 MB).
- PENDING (needs the maintainer): the Security log needs an elevated run.

## QA round 1 (gauntlet-bot review of PR #1)

- License: LICENSE is MIT with the Commons Clause, Copyright (c) 2026
  kilrkrow; README and About box say so.
- Query panel: when an Exclude is present, the FilterHashtable slot now shows
  the full `Get-WinEvent -FilterXml` command with a Copy command button
  (screenshot: query-panel.png) instead of a refusal note.
- No personal paths: the optional extra fixture comes only from
  `SIFT_PROBE_EVTX` (skipped if unset); README builds with a standard
  Lazarus install (`C:\lazarus\lazbuild.exe`).
- Test runner reports PASS / SKIP / FAIL per test and a count of each.
  Result, win64 and win32: 64 passed, 1 skipped (ProbeSeedFixture,
  SIFT_PROBE_EVTX unset), 0 failed; with it set, 65 passed. The Security
  tests check the access-denied path, so they run (pass) unelevated and skip
  only in an elevated session.
- Benchmarks: caption says the "full" column is not like-for-like.
- All time: capped at the newest 200,000 events per query by default
  (`AllTimeRowCap` in sift.ini, 0 = no cap); the status bar says when the cap
  was hit.
- Harness separated: private-desktop screenshots, `--screenshots`,
  `--dump-ui`, `--selftest-grid` are only in the Harness-win64/Harness-win32
  build modes (`-dSIFT_HARNESS`). Release exes checked: none of
  CreateDesktopW, PrintWindow, EndMenu, CloseDesktop in the imports and none
  of the harness switches in the strings (ASCII and UTF-16). Harness build
  still runs: 11/11 quick buttons OK in both.
- Screenshots: the previous set showed real event message text and real
  local log names (no host or user names). All images regenerated from the
  harness build with synthetic demo events (computer HOST01) and a standard
  log list; each image was inspected: no real host names, user names or
  event text.

## Addendum 2 and Piece 10: critic table

| Piece | Verdict |
|---|---|
| 8. Column divider auto-fit, Message wrap toggle | PASS (headless, win64 + win32). Visible check at 125/150% DPI is a hand check. |
| 9. Offline Event ID lookup, Look up online | PASS (win64 + win32). Opening the real browser is a hand check (the harness only builds the URL). |
| 10. Easy-button toolbar | PASS (win64 + win32). Presets (stretch) deferred. |

Tests: SiftCore 98 tests per arch: 97 passed, 1 skipped (optional
SIFT_PROBE_EVTX), 0 failed as win64 and as win32; 98/98 with it set. Harness
`--feature-check`: 57 PASS, 0 FAIL in both harness exes; `--dump-ui` quick
buttons 11/11 OK in both.

## 8. Column divider auto-fit: PASS

Trigger, as specified: the double-click must be on the column divider
(the resize zone at a header's right edge), not the header body.

- Divider zone: `DividerHit` in `sift.colfit` takes the header row only,
  +/-4 px at 96 DPI, scaled (5 px at 125%, 6 px at 150%), nearest edge wins.
  Unit tests: DividerZoneHits, HeaderBodyIsNotDivider (header body, data
  rows, above/below the header: no hit), DividerZoneScalesWithDpi.
- Harness, through the real grid (WM_MOUSEMOVE / LBUTTONDOWN / UP / DBLCLK / UP
  sent to the grid's window on the private desktop), for each of the 9
  columns: a header-body double-click changes no width and not the wrap
  state; a divider double-click fits the column (Time 30 -> 117, Level 77,
  Channel 75, Provider 242, Event ID 57, Task 43, User 172, Computer 68 px at
  100%, each equal to the computed fit) and leaves the other 8 columns
  alone; on Message it toggles wrap and changes no width. A double-click on a
  data row at a divider's X does nothing. Row order is unchanged after all of
  them.
- Critic "no sort on double-click": Sift has no column sort at all (the
  steering's "a single click still sorts" does not apply); the harness
  checks the row order is unchanged.
- DPI: fit widths at 100/125/150% (bitmap canvas at 96/120/144 DPI) scale
  x1.24-1.30 and x1.48-1.61 for all 8 fit columns, e.g. Provider 242 / 302 /
  361 px.
- Bounded: header + visible rows + at most 200 sampled rows
  (`FitSampleRows`, tested at 250k rows); Task text outside the view is only
  used when already rendered.
- Critic "repaint with wrap on at 200k rows": 217,710 rows, 50 random jumps
  + paint: 21.7 ms (win64) / 23.9 ms (win32) per jump with wrap on vs 18.6 ms
  off; jump to end 26.6 / 16.2 ms. Only visible rows are measured.
- Critic "survives a restart": harness run 1 leaves wrap on via the Message
  divider; run 2 with the same ini reports `MessageWrap at start-up: on`
  (ini has `MessageWrap=1`); a fresh ini reports off. Both arches.
- Hand check (maintainer): auto-fit by mouse at 125% and 150% DPI; the wrap toggle.
- QA round 2: the toggle is also View > Wrap message text (Ctrl+W) and the
  grid right-click menu; harness checks menu, divider and both checkmarks stay
  in sync and the ini keeps it.

## 9. Offline Event ID lookup: PASS

- `sift.pubmeta`: EvtOpenPublisherMetadata, EvtOpenEventMetadataEnum /
  EvtNextEventMetadata, EvtGetEventMetadataProperty,
  EvtGetPublisherMetadataProperty and EvtFormatMessage, all loaded
  dynamically from wevtapi.dll with the rest. Cached per provider (including
  failures) for the session; the harness saw 3 loads for 4 rows.
- Equivalence with `Get-WinEvent -ListProvider` (.NET ProviderMetadata),
  description, level, task, opcode and keywords by name: Service Control
  Manager 7036 and 7040, Microsoft-Windows-Kernel-General 12 and 13,
  Microsoft-Windows-RestartManager 10000 and 10001 (Application). Note:
  .NET's `EventMetadata.Id` keeps the qualifiers (SCM 7036 is 1073748860),
  so `? Id -eq 7036` finds nothing; the oracle matches `Id -band 0xFFFF`.
- Missing provider: "Provider metadata not available on this machine", no
  exception (unit test and harness).
- Critic "non-ASCII templates": Microsoft-Windows-Bits-Client 16401 (U+2019)
  and Microsoft-Windows-DirectShow-Core 1 (U+00AE) match .NET byte for byte
  as UTF-8. Pane labels are plain ASCII (test DetailTextAsciiLabels).
- Critic "no network": no ws2_32 / wsock32 / wininet / winhttp / urlmon /
  dnsapi in either release exe's imports, and no code path loads one; the
  harness runs (win64 and win32) were watched with Get-NetTCPConnection /
  Get-NetUDPEndpoint every 150 ms: 0 connections or endpoints. Look up
  online is ShellExecuteW on an https URL (the browser searches), URL-encoded
  (`%22Service%20Control%20Manager%22%20event%20ID%207036`).
- Hand check (maintainer): right-click Look up online opens the default browser.

## 10. Easy-button toolbar: PASS, presets deferred

- No second query path: `sift.toolbar` only reads and writes TSiftFilter;
  the compiler, chips, query panel and export do the rest.
- Equivalence with Get-WinEvent, live:
  - "all errors last hour" (Error, 1 h, All logs): same events as the
    exported PowerShell run as-is (edges of the window excluded). Found a
    real gap: Get-WinEvent -FilterXml fails the whole query when one log is
    access denied (Security, unelevated), while Sift skips it. The export now
    retries without the unreadable logs and warns, like Sift's banner.
  - "last 15 System errors" (Error, Max 15, System): the one-liner is
    `Get-WinEvent -FilterHashtable @{ LogName='System'; Level=2 } -MaxEvents 15`
    and matches Sift row for row.
  - toolbar + right-click Exclude (Error+Warning, 24 h, System, Exclude the
    newest event's ID; then Max 25): export uses -FilterXml and matches.
- Two-way sync (unit tests and harness): right-click Include Level=3 ticks
  Warning; right-click Exclude Level=Information shades Info and a click
  clears it; Last 10 shows Max 10; the 15 min quick button shows Time 15
  min; toolbar 1 h lights the "1 h" quick button; Log = Application / All.
- No levels ticked = all levels, never an empty query (test and harness).
- Max accepts digits 0..1,000,000 only; "abc" is rejected and the old value
  kept. Max keeps the time window (`SetMaxCount`); filter file v1 now allows
  `lastN` together with a window and reads it as "cap at N" (newest N inside
  the window; earlier builds rejected it, so no old file changes meaning).
- ASCII captions; sizes via Scale96ToForm; import check PASS.

### QA round 2 (gauntlet bot, on 73bfcb8)

- DST: local time now goes through TzSpecificLocalTimeToSystemTime /
  SystemTimeToTzSpecificLocalTime (kernel32, Windows XP+, on the allowlist;
  GetTimeZoneInformation is gone). Unit tests pin a Pacific
  TIME_ZONE_INFORMATION and cross 2026-11-01 and 2027-03-14 both ways;
  repeated hour = first (daylight) instance (01:30 -> 08:30 UTC), skipped hour
  read with daylight time (02:30 -> 09:30 UTC).
- Export: denied/missing logs detected by exception type (inner exceptions
  too); missing logs skipped; all-denied warns and stops; the query stays
  valid when the first Select is the one removed (Security first); probe of
  All logs (419) takes 211 ms win64 / 177 ms win32, 44 denied.
- Event ID tab: enum failure shows exactly "Provider metadata not available
  on this machine". LookupUrl templates with spaces, quotes or other unsafe
  characters are rejected (test with 15 bad, 4 good).
- Custom range shown in local time, ASCII, pre-filled on reopen (harness and
  unit test).
- Level boxes: AllowGrayed off, so a real click (button down/up on the box
  in the harness) goes unticked -> ticked -> unticked and a shaded
  (excluded) box -> unticked; never grey.
- Deferred (stretch): saved one-click presets as filter-file v1 buttons.
- Hand check (maintainer): the toolbar by mouse and keyboard, including Custom.

### Follow-ups from the 125%/150% test (the maintainer's machine)

- (A) The win64 exe built at 73bfcb8 into the out folder had no icon: the
  build script built from a copy of the .lpi named `sift-out.lpi`, and
  Lazarus takes the project icon from `<project>.ico`, which did not exist.
  The script now copies the icon too, and `tools/Check-Imports.ps1` checks the
  icon (group + all 9 images) and version resources; every build mode runs it
  after linking, so a build without the icon fails (seen failing on the
  broken build, passing after the fix: 1 group, 16/20/24/32/40/48/64/128/256).
- (B) Custom time window: the labels are stacked (format line, From row, To
  row) and the edits start after the wider label, measured with the dialog
  font. Harness: no two controls overlap and all are inside the dialog at
  100% (301 x 147) and scaled to 125% and 150%.
- (C) Hit targets: level boxes, Max box and the text box get a scaled 24 px
  minimum height; the Time and Log lists are fixed owner-drawn lists (a plain
  drop-down list is sized by Windows from the font, 23 px, and ignores
  CB_SETITEMHEIGHT), item height = 24 px - 6 px frame, kept on DPI change.
  Harness: all 24 px at 100%, Time list 36 px at 150%.
- (D) Time list: arrows/Home/End only move the selection; an open list
  commits on close-up (queued once, because Windows may send the selection
  change before or after the close-up), Custom... on a closed list commits on
  Enter. Harness: End in the open list opens nothing, Enter opens it once,
  Cancel keeps 24 h with no second dialog; picking Custom... again while a
  range is active reopens it pre-filled.
- (E) Status bar: the LCL reads the native status bar height once per
  process; it now has a fixed scaled height that is scaled on a DPI change
  (harness: 24 -> 36 at 150% -> 24).
- Item i (DPI 125/150%): PASS apart from (B) and (C), now fixed; j
  (multi-monitor) still skipped.

## Visible + elevated batch (the maintainer's machine, fcca17b exes)

| Items | Result |
|---|---|
| a-h | PASS on fcca17b |
| i | PASS at 125% and 150% (73bfcb8), except the Custom window overlap and the 23 px hit targets, fixed afterwards |
| j | SKIPPED: single monitor |
| k-o | Deferred to the maintainer |

## Hand-check list (needs the maintainer)

- Items k-o of the visible batch; item j needs a second monitor.
- Auto-fit by divider double-click at 125% and 150% DPI.
- The Message wrap toggle (divider double-click, View menu, Ctrl+W, grid
  menu) and that it survives a restart.
- Right-click Look up online opens the browser on the search.
- The toolbar: Level boxes, Time incl. Custom, Max, Log.
