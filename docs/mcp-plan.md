# SiftMcp plan (not built)

Note (Addendum 2): the Phase 2 SiftMcp MVP is local stdio only. No
network transport, no listening socket, no HTTP: it is started by the MCP
client as a child process and talks over stdin/stdout.

A small separate console exe, `SiftMcp.exe`, that speaks JSON-RPC 2.0 over
stdio (hand-written on fpjson, no framework) on top of SiftCore. Read-only.

- Tools:
  - `list_logs` (channel name, enabled, record count, needs-elevation flag)
  - `query_events(filter, limit<=500)`: the filter is the same v1 JSON the
    viewer copies/pastes (`"siftFilterVersion": 1`), so a filter built by
    right-clicking is exactly the filter an agent sends, and back.
  - `summarize(filter, group_by = provider | event_id | level)` bounded counts.
  - `get_event(log, record_id)` full message and XML.
- Every result carries its compiled filter and query so it can be reopened in
  the viewer (`sift.exe --filter file.siftfilter.json`).
- Bounded: hard caps on rows and on message-text scanning, same as the viewer.
- SiftCore pieces it reuses unchanged: TSiftFilter, CompileFilter,
  TSiftExecutor (with CancelFlag), TSiftRenderer, FilterToJson/FilterFromJson.
- Phase 1 kept the AST / compiler / executor split clean and left the summary
  shapes for Phase 3 (the "safe fallback" in the brief).
