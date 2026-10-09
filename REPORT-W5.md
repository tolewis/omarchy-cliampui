# REPORT-W5 — stations: first-class browse

- `Stations.qml` (whole file): filter `TextField` + 260 ms debounce Timer below the
  section title (Library search idiom, client-side via `Model.filterStations`,
  `Keys.onEscapePressed` clears); now-playing line `title — station` from
  `service.title` + active station, hidden when no match; row emphasis keeps the
  tick and adds `font.bold` on the active title (active match now id-based so it
  survives the filter); empty-state dim centered line `Play something once and
  stations appear here.` gated on `stationsAnswered` (`service.stationsLoaded` if
  present, else `service.running`); header count `STATIONS (n)` uses the filtered
  count; `import "Model.js" as Model` added.
- `Model.js`: new `filterStations(stations, query)` after `stationActiveIndex` —
  case-insensitive substring on name+artist, empty query returns the list.
- `tests/model.test.js`: `filterStations` added to the return-object list and 8
  checks (empty/blank query, case, artist match, no match, cross-field no-match,
  null list).
- Verified: `deno run --allow-read tests/model.test.js` passes; `qmllint
  Stations.qml` clean.

W5 DONE