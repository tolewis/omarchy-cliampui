# Report — W2: CLI integration for the stream-era ops

Date: 2026-07-18. Branch: `fix/panel-streams`. Plugin version 0.1.11 → 0.2.0.

## Scope

Wire the plugin to the four new daemon ops: stations list/play, history play,
provider list/switch. Plus the stream-era transport change and the Recently
Played row. No new settings, no new IPC surface, no new CLI subcommands on the
plugin side.

## Decisions

- **CLI argument forms** (verified against the fork checkout and the stock
  v2.0.1 binary during exploration):
  - stations: subcommand form `cliamp station list`,
    `cliamp station play <id>`, the way `history` and `load` are wired in
    `commands.go`.
  - history play and providers: the daemon's remote passthrough,
    `cliamp remote call history.play --params '{"index":0}'`,
    `cliamp remote call provider.list`, `cliamp remote call provider.switch`.
    These verbs are parameterised or v2-only, so they travel through the
    passthrough to the running daemon's own socket.
- **All parsing and normalisation sits in `Model.js`** (`parseStations`,
  `stationActiveIndex`, `parseProviders`, `providerSummary`, `RECENTLY_PLAYED`,
  and the five `*Args()` builders). `Service.qml` only runs the processes and
  stores the results; the QML files only render and call.
- **Backward compatibility is structural, not branchy.** On a daemon without an
  op, the process exits non-zero with no stdout (unknown verb) or the op
  answers `{"ok":false,...}`, and `parseStations`/`parseProviders` return `[]`.
  An empty list is the condition that hides the STATIONS section and the
  provider footer line. Nothing renders differently on stock v2.0.1.
- **Stream next/prev** goes to the CLI verb (`cliamp next` / `cliamp prev`)
  when `status.track.stream` is true; the socket verb and the MPRIS fallback
  are untouched for files. On the patched daemon the verb cycles stations; on
  anything else it stays a no-op, so the buttons are never suppressed.
- **Recently Played** is special-cased in `Service.playResult` by the exact
  name `Model.RECENTLY_PLAYED` (the built-in list the daemon rebuilds, already
  parsed by `parsePlaylists`). Clicking it issues `history.play` with
  `{"index":0}`, not `load`.
- **Provider envelope.** `provider.list` answers through the v2 response
  path, so `parseProviders` looks for `providers` at the top level, a bare
  array, and one level down under `result`/`data`/`value`. Row flags accept
  `authed|authenticated` and `active|current|is_active`. The footer renders
  `key: authed · active` per the brief.
- **Read rhythm.** Stations and providers are read on panel open, the same
  rhythm as the playlist list. Providers are re-read after a switch, because
  the authorisation state is the visible content of the line. The stations
  list is not re-read on play; the daemon's queue order is stable for the
  session.

## Files

- `Model.js` — new section: station/provider parsing, active-station match,
  summary line, CLI argument builders, `RECENTLY_PLAYED`.
- `Service.qml` — `stations`, `providers`, `activeStationIndex`,
  `providerSummary`; `readStations`, `playStation`, `historyPlay`,
  `readProviders`, `cycleProvider`; stream branch in `next`/`previous`;
  Recently Played branch in `playResult`; two reads on panel open.
- `Stations.qml` — new section between transport and library, styled from
  `qs.Commons`/`qs.Ui` tokens the way the library is. Pointer-driven; the
  keyboard cursor stays on library and output sheet.
- `Panel.qml` — instantiates the section; no keyboard-cursor change.
- `OutputSheet.qml` — provider footer line with a Switch affordance.
- `tests/model.test.js` — covers the new functions: station rows (valid,
  dropped, garbage, empty, null), active-station match, provider rows
  (top-level, bare array, enveloped, flag variants, dropped, garbage),
  summary line, and the five argument builders.
- `manifest.json` — 0.2.0.
- `CHANGELOG.md` — new file, dated entry (the README has no changelog section).
- `REPORT-W2.md` — this file.

## Verification

- `deno run --allow-read tests/model.test.js` is the check for `Model.js`;
  the new checks follow the existing byte-for-byte fixture style. Not run in
  this environment (deno is unavailable here).
- QML not linted in this environment; the new files follow the structure and
  ids of the existing sections (CursorSurface delegates, StdioCollector
  processes, `Style.space`/`Color` tokens).
- The CLI argument forms are the ones the architect's contract names
  (`cliamp station list`) and the passthrough usage the fork's `commands.go`
  documents (`cliamp remote call <operation> [--params '{}']`).

## Residual risk

- The station `play` subcommand and the `remote call` envelope shape are
  trusted to the fork contract; a rename in the fork CLI changes the argv the
  panel builds, which the new `*Args()` tests will catch at build time.
- If the fork's `provider.list` envelope nests the list under a key other than
  `result`/`data`/`value`, the footer hides itself rather than misrendering.
  One added key to `providerList` in `Model.js` fixes it.