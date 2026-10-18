# Changelog

## 0.4.0 — 2026-10-18

- The panel speaks cliamp's version 2 IPC protocol, which cliamp 2.3 requires.
  It sends one command connection and keeps a second connection subscribed to
  state and job events, so the panel updates without a poll.
- A SOURCES section replaces STATIONS. It lists every provider cliamp reports
  as a chip, and it shows the channels, stations or playlists of the chosen
  provider. The field filters the list and searches the provider. A click
  plays the row, and the playing row is marked and scrolled into view.
- `[` and `]` change to the previous or next row of the Sources list. The
  shell IPC functions `nextsource` and `prevsource` do the same from a
  keybinding.
- Spotify followed playlists are hidden, because Spotify answers 403 for them.
  Spotify search plays albums by their full path.
- A play that does not start in 3.5 seconds is retried once. If it still does
  not start, the panel shows a notice.
- Daemon errors show as a notice under the transport, and an empty playlist
  says that it has no tracks.
- The search fields keep the keyboard, so typing in them no longer triggers
  the panel hotkeys.
- The provider chips moved from the OUTPUT sheet to the Sources section. The
  right-click player menu and the fork binary path were removed.

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