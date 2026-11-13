# Benchmarks

Script: [tools/bench/Run-Benchmarks.ps1](../tools/bench/Run-Benchmarks.ps1).
It runs `siftbench.exe` (the SiftCore engine the viewer uses, headless) and
plain `Get-WinEvent` on the same machine with the same filters, 3 runs per
case, median reported.

What is measured:

- Sift first row: time from EvtQuery to the first row handed to the caller.
  Sift full: all rows with their system fields (time, level, channel,
  provider, ID, task, keywords, user, computer). Messages are rendered lazily
  only for rows on screen (cost below), exactly as the viewer does.
- Get-WinEvent first row: `-MaxEvents 1`. Get-WinEvent full: every event as an
  `EventLogRecord`, which includes formatting each message. That is real work
  Sift defers, so the "full" column compares "ready to show" against "fully
  materialised"; it is the honest comparison for a viewer, not for a
  message-dumping script.

## Results, 0.1.0, 2026-10-30

Machine: Windows 11 Pro 10.0.26200 (dev PC), Windows PowerShell 5.1.26100,
unelevated, win64 build.

| Case | Sift rows | Sift first row (ms) | Sift full (ms) | Get-WinEvent rows | Get-WinEvent first row (ms) | Get-WinEvent full (ms) |
|---|---:|---:|---:|---:|---:|---:|
| System, full log (20 MB) | 36,248 | 1.6 | 222 | 36,248 | 4.8 | 10,928 |
| System, last 40 | 40 | 1.5 | 1.7 | 40 | 5.0 | 32 |
| System+Application, Err/Warn/Info, last 24 h, exclude ID 7036 | 960 | 1.9 | 86 | 960 | 9.7 | 475 |
| Application, full log (20 MB) | 50,726 | 1.3 | 255 | 50,726 | 12.6 | 8,797 |
| Exported .evtx, 194 MB, full file | 264,478 | 4.1 | 1,668 | 264,478 | 4.4 | 67,732 |
| Exported .evtx, 194 MB, Error+Warning (filtered in the service) | 48,660 | 4.0 | 510 | 48,660 | 5.0 | 11,868 |
| Security, full log | access denied (code 5, flagged "needs elevation") | | | access denied | | |

Caption: the two "full" columns are not like-for-like. Sift's "full" is
every row ready to display (system fields only; messages are formatted
later, only for rows on screen). Get-WinEvent's "full" is every event with
its message fully formatted. Compare the first-row columns, and the row
counts, for an equal-work comparison.

Row counts match Get-WinEvent in every case.

The "~100 MB log" case: this PC's largest single log is 33 MB, so the script
(`-BuildBigLog`) exports the 8 largest non-Security logs into one .evtx with
`wevtutil epl` (unelevated). That produced 194 MB, about twice the target size.

Security log: **not measured yet.** It needs an elevated run of
the same script by the maintainer (see "Pending" below). Unelevated, both tools are denied, and
Sift reports the channel as needing elevation.

## Lazy message rendering (viewer cost per visible row)

From `siftbench --messages N` on System: re-open an event through a cached
bookmark seek about 0.11 ms per row, then EvtFormatMessage 0.17 to 0.5 ms per
row (depends on the publisher). A full screen of about 30 rows costs well
under 20 ms the first time and nothing after that (cached).

## Grid at 100k+ rows

`sift.exe --selftest-grid <file>` loads System (36,248 rows), replicates the
rows to 217,488, loads them into the virtual grid and times real WM_PAINT
repaints of the visible rows (private desktop, nothing on screen):

| Step | win64 | win32 |
|---|---:|---:|
| Load 217,488 rows into the grid | 33 ms | 26 ms |
| Paint visible rows, top / middle / end (cold, messages rendered) | 17 / 17 / 24 ms | 21 / 19 / 26 ms |
| Repaint same rows (cached) | 7 to 8 ms | 10 to 13 ms |
| 50 random jumps + paint, average | 17.8 ms | 20.8 ms |
| 200 one-row scroll steps + paint, average | 13.8 ms | 12.3 ms |
| Jump to last row + paint | 13.8 ms | 15.2 ms |

Queries run on a worker thread; rows stream into the grid in batches, so the
UI keeps painting and responding while a large log loads.

## Pending (needs the maintainer)

From an elevated Windows PowerShell, in the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\Run-Benchmarks.ps1 -OutFile docs\benchmarks-elevated.md
```
