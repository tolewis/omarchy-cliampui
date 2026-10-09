# Changelog

## 0.2.0 — 2026-07-18

- A STATIONS section above the library lists the radio stations the daemon
  reports. Clicking a row plays it. The station the daemon is playing is
  marked. The section is hidden while the daemon reports no stations, so the
  panel is unchanged on an unpatched cliamp.
- Next and previous now move between stations while a stream plays.
- The Recently Played row in the library replays the most recently played
  track instead of loading the list as a playlist.
- The OUTPUT sheet footer shows the provider the daemon resolves library
  tracks through, and its authorisation state. Clicking the line switches the
  provider. The line is hidden while the daemon reports no providers.

## 0.1.11 — 2026-08-26

- Hardened the cliamp daemon systemd unit (merged upstream pull request #1).