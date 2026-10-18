// Pure helpers for the Cliamp panel. No QML imports, so this file is testable with Deno.

var MAX_ERROR_CHARS = 140
var SECONDS_PER_MINUTE = 60
var MINUTES_PER_HOUR = 60
// Rates within this many Hz are the same rate, covering integer rounding in the graph.
var RATE_MATCH_TOLERANCE_HZ = 1

function defaultStatus() {
  return {
    ok: false,
    state: "stopped",
    title: "",
    path: "",
    isStream: false,
    seekable: false,
    durationSec: 0,
    positionSec: 0,
    artist: "",
    album: "",
    artUrl: "",
    volumeDb: 0,
    total: 0,
    index: -1,
    shuffle: false,
    repeat: "Off",
    visualizer: "",
    eqFlat: true,
    playlist: "",
    streamError: "",
    revision: 0,
    lastError: ""
  }
}

// ---- version 2 IPC ----

// cliamp 2 speaks only version 2 on its socket. A v1 {"cmd":...} packet is refused with
// invalid_version, which is what left the panel showing nothing.
var IPC_VERSION = 2

// Every v2 line is one JSON object. Anything else, including the plain sentence cliamp
// prints when it is not running, parses to null.
function parseObject(raw) {
  var text = String(raw || "").trim()
  if (text.length === 0) return null
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return null
  }
  return data && typeof data === "object" ? data : null
}

// Sample input: {"code":"internal_error","message":"operation failed","detail":"no lyrics found"}
// The detail is the provider's own diagnostic, so it is the useful half when present.
// A v1 refusal carried the sentence in "error" directly, so both shapes are read.
function errorText(error) {
  if (error === undefined || error === null) return ""
  if (typeof error === "string") return error
  if (typeof error !== "object") return String(error)
  var detail = String(error.detail || "")
  if (detail.length > 0) return detail
  return String(error.message || error.code || "")
}

// A line on the command socket answers a request and carries its id. A line on the
// event socket carries "event". Nothing else is routed.
function messageKind(raw) {
  var data = parseObject(raw)
  if (data === null) return String(raw || "").trim().length === 0 ? "none" : "garbage"
  if (typeof data.event === "string") return "event"
  if (data.id !== undefined) return "response"
  return "garbage"
}

var TERMINAL_JOB_STATES = ["succeeded", "failed", "canceled"]

function jobTerminal(job) {
  var state = String(job && job.state || "")
  return TERMINAL_JOB_STATES.indexOf(state) >= 0
}

// The sentence a person reads when an action fails. Measured on 2.3.0: Spotify answers a
// playlist the account follows but does not own with 403, and a shared client id with 429.
function friendlyError(text) {
  var t = String(text || "")
  if (t.length === 0) return ""
  if (t.indexOf("403") >= 0 && t.toLowerCase().indexOf("spotify") >= 0)
    return "Spotify does not let cliamp read this playlist. It plays only playlists you own or collaborate on."
  if (t.indexOf("429") >= 0 || t.toLowerCase().indexOf("rate-limit") >= 0 || t.toLowerCase().indexOf("rate limit") >= 0)
    return "The provider is rate-limiting requests. Try again in a minute."
  if (t.indexOf("not authenticated") >= 0 || t.indexOf("sign in") >= 0)
    return "Sign in to this provider in the cliamp TUI first."
  return elideError(t.replace(/^operation failed \((.*)\)$/, "$1"))
}

// The reason a job failed, for the panel. Empty for a job that succeeded.
function jobError(job) {
  if (!job || typeof job !== "object") return "no answer from cliamp"
  if (job.state === "succeeded") return ""
  if (job.state === "canceled") return "canceled"
  return friendlyError(errorText(job.error) || "operation failed")
}

// Sample input, the snapshot from state.get, a runtime.state event, or a finished job:
// {"revision":4,"playlist_revision":3,"state":"playing","track":{"title":"BE THERE WITH U",
//  "artist":"2frers","path":"https://radio.cliamp.stream/ncs/tracks/b90…","stream":true},
//  "position":1.99,"duration":169.69,"seekable":true,"playlist":"cliamp:ncs","total":48,
//  "shuffle":false,"repeat":"Off","eq_bands":[0,0,0,0,0,0,0,0,0,0],"visualizer":"Bars"}
// cliamp omits zero values, so a missing index with a track present is index 0 and a
// missing volume is 0 dB.
function parseSnapshot(snapshot) {
  var out = defaultStatus()
  if (!snapshot || typeof snapshot !== "object") {
    out.lastError = "cliamp sent no state"
    return out
  }
  out.ok = true
  out.state = String(snapshot.state || "stopped")
  out.revision = numberOr(snapshot.revision, 0)
  out.volumeDb = numberOr(snapshot.volume, 0)
  out.total = numberOr(snapshot.total, 0)
  out.shuffle = snapshot.shuffle === true
  out.repeat = String(snapshot.repeat || "Off")
  out.visualizer = String(snapshot.visualizer || "")
  out.eqFlat = bandsAreFlat(snapshot.eq_bands)
  out.seekable = snapshot.seekable === true
  out.playlist = String(snapshot.playlist || "")
  out.streamError = String(snapshot.stream_error || "")
  out.durationSec = numberOr(snapshot.duration, 0)
  out.positionSec = numberOr(snapshot.position, 0)

  var track = snapshot.track
  if (track && typeof track === "object") {
    out.index = numberOr(snapshot.index, numberOr(track.index, 0))
    // Measured on a Radio Browser station: cliamp splits the ICY title, so artist holds
    // the song, title holds the station, and stream_title holds both. The song is the
    // title here and the station is the line under it.
    var streamTitle = String(track.stream_title || "")
    if (streamTitle.length > 0) {
      out.title = String(track.artist || "") || streamTitle
      out.artist = String(track.station || track.title || "")
    } else {
      out.title = String(track.title || "")
      out.artist = String(track.artist || "")
    }
    out.album = String(track.album || "")
    out.path = String(track.path || "")
    out.isStream = track.stream === true
    out.artUrl = String(track.album_art_url || "")
    if (out.durationSec <= 0) out.durationSec = numberOr(track.duration_secs, 0)
  }
  return out
}

// Sample input, the reply to method "state.get":
// {"version":2,"id":"cliampui-1","ok":true,"snapshot":{…}}
// A refusal carries {"ok":false,"error":{…}} instead, and a daemon that is down answers
// nothing at all.
function parseStatus(raw) {
  var data = parseObject(raw)
  var text = String(raw || "").trim()
  if (data === null) {
    var none = defaultStatus()
    none.lastError = text.length === 0 ? "cliamp returned nothing" : elideError(text)
    return none
  }
  if (data.ok !== true || !data.snapshot || typeof data.snapshot !== "object") {
    var refused = defaultStatus()
    refused.lastError = elideError(errorText(data.error) || text)
    return refused
  }
  return parseSnapshot(data.snapshot)
}

// Sample input, the "result" of a succeeded lyrics job, measured on the box:
// {"ok":true,"lyrics":[{"start":30.23,"text":"One more time"}]}
// A track with no lyrics fails the job instead, so there is no result to parse.
function parseLyrics(result) {
  var out = []
  var data = typeof result === "string" ? parseObject(result) : result
  if (!data || typeof data !== "object" || !data.lyrics || data.lyrics.length === undefined) return out
  for (var i = 0; i < data.lyrics.length; i++) {
    var line = data.lyrics[i]
    if (!line) continue
    var body = String(line.text || "")
    if (body.length === 0) continue
    out.push({ start: numberOr(line.start, 0), text: body })
  }
  return out
}

// A ten band EQ with anything but zeros is DSP, so the samples are no longer the
// ones the file holds. The preset name is not consulted: cliamp reports "Custom"
// for an untouched EQ, so only the numbers are trustworthy.
function bandsAreFlat(bands) {
  if (!bands || bands.length === undefined) return true
  for (var i = 0; i < bands.length; i++) {
    if (numberOr(bands[i], 0) !== 0) return false
  }
  return true
}

function numberOr(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

// Sample input: PipeWire node properties carrying node.rate as a period, "1/44100".
function rateFromNodeProps(props) {
  if (!props) return 0
  var raw = String(props["node.rate"] || "")
  var parts = raw.split("/")
  if (parts.length !== 2) return 0
  var rate = parseInt(parts[1], 10)
  return isFinite(rate) && rate > 0 ? rate : 0
}

// Sample input, one line of `pactl list short sinks`, tab separated:
// 55\talsa_output.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts32le 2ch 44100Hz\tRUNNING
function sinkRateFromPactl(raw) {
  var line = String(raw || "")
  var fields = line.split("\t")
  if (fields.length < 4) return 0
  var pieces = fields[3].split(" ")
  for (var i = 0; i < pieces.length; i++) {
    var piece = pieces[i]
    if (piece.slice(-2) !== "Hz") continue
    var rate = parseInt(piece.slice(0, -2), 10)
    if (isFinite(rate) && rate > 0) return rate
  }
  return 0
}

// Sample input, one line per sink from `omarchy-audio-sink-availability`:
// alsa_output.pci-0000_00_1f.3.analog-stereo\t1
// Same contract the stock audio panel parses, so an unplugged output is filtered
// out of the device list here exactly as it is there.
function parseSinkAvailability(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
  }
  return next
}

// Sample input, the path cliamp reports for a Navidrome track:
// https://host/rest/stream?c=cliamp&f=json&format=raw&id=XXX&s=SALT&t=TOKEN&u=USER&v=1.0.0
// The same salted token already authorises cover art, so the panel can show artwork
// without ever being told a password. cliamp publishes no art of its own.
function coverArtUrlFromStreamPath(path, size) {
  var text = String(path || "")
  var cut = text.indexOf("?")
  if (cut < 0) return ""
  var base = text.slice(0, cut)
  if (base.indexOf("https://") !== 0) return ""
  var marker = "/rest/stream"
  if (base.slice(-marker.length) !== marker) return ""

  var keep = ["id", "u", "t", "s", "c", "v"]
  var parts = text.slice(cut + 1).split("&")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq < 0) continue
    var key = parts[i].slice(0, eq)
    for (var j = 0; j < keep.length; j++) {
      if (key === keep[j]) { out.push(parts[i]); break }
    }
  }
  if (out.length === 0) return ""
  out.push("size=" + (size > 0 ? size : 300))
  return base.slice(0, base.length - marker.length) + "/rest/getCoverArt?" + out.join("&")
}

// cliamp asks Navidrome for format=raw, so its absence on a Subsonic stream means
// the server re-encoded the file before sending it.
function transcodedFromPath(path) {
  var text = String(path || "")
  if (text.indexOf("/rest/stream") < 0) return false
  return text.indexOf("format=raw") < 0
}

// Sample input, PipeWire props on a bluez sink:
// api.bluez5.codec = "sbc_xq", api.bluez5.profile = "a2dp-sink"
// Returns a display name only for a lossy A2DP link, and "" for anything wired.
function bluetoothCodecLabel(props) {
  if (!props) return ""
  var codec = String(props["api.bluez5.codec"] || "")
  if (codec.length === 0) return ""
  var names = {
    sbc: "SBC",
    sbc_xq: "SBC-XQ",
    aac: "AAC",
    aptx: "aptX",
    aptx_hd: "aptX HD",
    ldac: "LDAC",
    opus_05: "Opus"
  }
  return names[codec] || codec.toUpperCase()
}

// Sample input from `cliamp playlist list`, two leading spaces and a right hand count:
//     Recently Played  8 tracks
// A playlist saved from the Navidrome browser keeps the resolved stream URLs, which is
// what lets a headless daemon play a library it cannot otherwise browse.
function parsePlaylists(raw) {
  var out = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = trim(lines[i])
    if (line.length === 0) continue

    var suffix = ""
    if (endsWith(line, " tracks")) suffix = " tracks"
    else if (endsWith(line, " track")) suffix = " track"
    else continue

    var head = line.slice(0, line.length - suffix.length)
    var cut = head.length
    while (cut > 0 && head.charAt(cut - 1) >= "0" && head.charAt(cut - 1) <= "9") cut--
    var count = parseInt(head.slice(cut), 10)
    var name = trim(head.slice(0, cut))
    if (name.length === 0 || !isFinite(count)) continue
    out.push({ name: name, count: count })
  }
  return out
}

// Sample input, what `omarchy bar set` stores without --json: the string "true", not a boolean.
function asBool(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true") return true
  if (value === "false") return false
  return fallback
}

// Sample input, one integer of milliseconds from cliamp-output-latency: 167, or 0.
function latencyMs(raw) {
  var value = parseInt(String(raw || "").trim(), 10)
  return isFinite(value) && value > 0 ? value : 0
}

// The last line whose start has passed, scanned in order because the list is short.
function activeLyricIndex(lines, positionSec) {
  if (!lines || lines.length === undefined) return -1
  var at = numberOr(positionSec, 0)
  var found = -1
  for (var i = 0; i < lines.length; i++) {
    if (numberOr(lines[i].start, 0) > at) break
    found = i
  }
  return found
}

// cliamp only accepts these output rates, so a native rate outside the set cannot be
// played natively at all and must not be chased. 88.2 and 176.4 kHz are not in it.
var SUPPORTED_OUTPUT_RATES = [22050, 44100, 48000, 96000, 192000]

function isSupportedOutputRate(rate) {
  var value = numberOr(rate, 0)
  for (var i = 0; i < SUPPORTED_OUTPUT_RATES.length; i++) {
    if (SUPPORTED_OUTPUT_RATES[i] === value) return true
  }
  return false
}

// Sample input, one NDJSON frame from the bands command:
// {"ok":true,"visualizer":"Bars","bands":[0.93,0.81,...]}
function parseBands(raw) {
  var out = []
  var text = String(raw || "").trim()
  if (text.length === 0) return out
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!data || data.ok !== true || !data.bands || data.bands.length === undefined) return out
  for (var i = 0; i < data.bands.length; i++) {
    var v = numberOr(data.bands[i], 0)
    out.push(v < 0 ? 0 : (v > 1 ? 1 : v))
  }
  return out
}

// Sample input, one JSON array from `cliamp-library albums` or `search`, mixing kinds:
// [{"kind":"album","id":"7tO..","name":"Discovery","artist":"Daft Punk","songCount":14},
//  {"kind":"song","id":"a9F..","name":"One More Time","artist":"Daft Punk","album":"Discovery","duration":320}]
function parseResults(raw) {
  var out = []
  var text = String(raw || "").trim()
  if (text.length === 0) return out
  var data = null
  try {
    data = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!data || data.length === undefined) return out
  for (var i = 0; i < data.length; i++) {
    var a = data[i]
    if (!a || !a.id) continue
    out.push({
      kind: a.kind === "song" ? "song" : "album",
      id: String(a.id),
      name: String(a.name || ""),
      artist: String(a.artist || ""),
      album: String(a.album || ""),
      songCount: numberOr(a.songCount, 0),
      duration: numberOr(a.duration, 0)
    })
  }
  return out
}

// Overwritten on every play, so it is plumbing rather than a playlist the user saved.
var SCRATCH_PLAYLIST = "cliampui"

// Saved playlists matched by name, as rows the same list can show.
function matchPlaylists(playlists, query) {
  var out = []
  var list = playlists && playlists.length !== undefined ? playlists : []
  var needle = trim(query).toLowerCase()
  for (var j = 0; j < list.length; j++) {
    var name = String(list[j] && list[j].name || "")
    if (name.length === 0) continue
    if (name === SCRATCH_PLAYLIST) continue
    if (needle.length > 0 && name.toLowerCase().indexOf(needle) === -1) continue
    out.push({
      kind: "playlist",
      id: name,
      name: name,
      artist: "",
      album: "",
      songCount: numberOr(list[j].count, 0),
      duration: 0
    })
  }
  return out
}

// ---- sources: providers, their playlists and stations, and search ----

// A playlist cliamp rebuilds itself, not one the user saved. Loading it starts its first
// entry, which is the most recently played track.
var RECENTLY_PLAYED = "Recently Played"

// Measured on 2.3.0 with a Spotify developer client: every playlist in this section
// answers 403, because Spotify lets an app read only playlists the account owns or
// collaborates on. Listing them gave the panel rows that could never play.
var BLOCKED_SECTIONS = { spotify: ["Followed playlists"] }

// Rows the TUI drives interactively and a panel cannot: "Use my location" asks a
// question first.
var INTERACTIVE_IDS = { radio: ["loc:ask"] }

// Sample input, the result of provider.list on 2.3.0:
// {"ok":true,"providers":[{"key":"cliamp","name":"cliamp radio","searchable":false},
//  {"key":"radio","name":"Radio","searchable":true,"catalog":true}, …]}
// The daemon has no active provider. The panel picks one for browsing only.
function parseProviders(result) {
  var out = []
  var data = typeof result === "string" ? parseObject(result) : result
  var list = data && data.providers
  if (!list || list.length === undefined) return out
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || typeof p !== "object") continue
    var key = String(p.key || "")
    if (key.length === 0) continue
    out.push({
      key: key,
      name: String(p.name || key),
      searchable: p.searchable === true,
      catalog: p.catalog === true
    })
  }
  return out
}

function providerByKey(providers, key) {
  var list = providers && providers.length !== undefined ? providers : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].key === key) return list[i]
  }
  return null
}

// The provider half of the snapshot's "playlist" field: "cliamp:ncs" is the cliamp radio
// channel ncs, and "spotify:spotify:album:4eL…" is a Spotify album. Split at the first colon.
function playlistRef(value) {
  var text = String(value || "")
  var cut = text.indexOf(":")
  if (cut <= 0) return { provider: "", id: "" }
  return { provider: text.slice(0, cut), id: text.slice(cut + 1) }
}

function rowKey(row) {
  if (!row) return ""
  return String(row.provider || "") + "|" + String(row.kind || "") + "|" + String(row.id || "")
}

function listOf(container, field) {
  var data = typeof container === "string" ? parseObject(container) : container
  var list = data && data[field]
  return list && list.length !== undefined ? list : []
}

// Sample input, the result of provider.playlists or provider.catalog:
// {"ok":true,"total":15,"playlists":[{"id":"ncs","name":"NCS","provider":"cliamp","track_count":48},
//  {"id":"23hD5…","name":"ROCK/GYM PUMP","provider":"spotify","section":"Followed playlists"}]}
// Returns { rows, hidden }: hidden counts the rows dropped because they cannot play.
function parseSourceRows(result, providerKey) {
  var rows = []
  var hidden = 0
  var list = listOf(result, "playlists")
  var key = String(providerKey || "")
  var blocked = BLOCKED_SECTIONS[key] || []
  var interactive = INTERACTIVE_IDS[key] || []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || typeof p !== "object") continue
    var id = String(p.id || "")
    if (id.length === 0 || interactive.indexOf(id) >= 0) continue
    var section = String(p.section || "")
    if (blocked.indexOf(section) >= 0) { hidden++; continue }
    var provider = String(p.provider || key)
    var row = {
      kind: "playlist",
      provider: provider,
      id: id,
      name: String(p.name || id),
      section: section,
      count: numberOr(p.track_count, 0)
    }
    // Two rows with one id would play the same thing and both light up as active.
    var k = rowKey(row)
    if (seen[k]) continue
    seen[k] = true
    rows.push(row)
  }
  return { rows: rows, hidden: hidden }
}

// Sample input, the result of provider.search on 2.3.0. Spotify answers albums, Radio
// answers stations, Podcasts answers feeds:
// {"ok":true,"tracks":[{"title":"DAMN.","artist":"Kendrick Lamar","path":"spotify:album:4eL…",
//   "provider_meta":{"albumID":"4eL…","kind":"album"}},
//  {"title":"Adroit Jazz Underground","path":"https://icecast…/jazz","stream":true,"realtime":true}]}
// An album or a feed loads as a playlist under its full path, which is the id that
// provider.load accepts. Stripping "spotify:album:" made the daemon answer 404.
function parseSearchRows(result, providerKey) {
  var rows = []
  var list = listOf(result, "tracks")
  var key = String(providerKey || "")
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (!t || typeof t !== "object") continue
    var path = String(t.path || "")
    if (path.length === 0) continue
    var meta = t.provider_meta && typeof t.provider_meta === "object" ? t.provider_meta : {}
    var kind = "track"
    if (String(meta.kind || "") === "album") kind = t.feed === true ? "podcast" : "album"
    else if (t.stream === true && t.realtime === true) kind = "station"
    var sub = String(t.artist || "")
    if (sub.length === 0 && kind === "station") sub = String(meta["radio.country"] || "")
    rows.push({
      kind: kind,
      provider: key,
      id: path,
      name: String(t.title || path),
      section: sub,
      count: 0,
      track: t
    })
  }
  return rows
}

// How a row is played. Playlists, albums and feeds replace the queue through
// provider.load. A single track or station is played as supplied, which keeps its
// provider identity.
function playRequest(row) {
  if (!row) return null
  if (row.kind === "track" || row.kind === "station") {
    return { operation: "track.play", params: { track: row.track || { path: String(row.id || ""), title: String(row.name || "") } } }
  }
  return { operation: "provider.load", params: { provider: String(row.provider || ""), playlist: String(row.id || "") } }
}

// The row the daemon is playing. The snapshot names the loaded playlist; a track played
// on its own is matched on its path.
// A load that succeeded into an empty queue. Measured: loading the empty saved playlist
// "Favorites" succeeds, and nothing plays, so the panel says why.
function loadedNothing(job) {
  if (!job || job.state !== "succeeded" || !job.snapshot) return false
  return numberOr(job.snapshot.total, 0) === 0
}

// soloPath is the track last played on its own with track.play. cliamp inserts it into
// the queue and keeps the playlist name, so while it plays no playlist row is active.
function rowIsActive(row, status, soloPath) {
  if (!row || !status) return false
  var path = String(status.path || "")
  if (row.kind === "track" || row.kind === "station") {
    return path.length > 0 && path === String(row.id || "")
  }
  if (path.length > 0 && path === String(soloPath || "")) return false
  // An empty playlist loads, and the previous track plays on, so it is not "playing".
  if (numberOr(status.total, 0) === 0) return false
  var ref = playlistRef(status.playlist)
  return ref.provider === String(row.provider || "") && ref.id === String(row.id || "")
}

function activeRowIndex(rows, status, soloPath) {
  var list = rows && rows.length !== undefined ? rows : []
  for (var i = 0; i < list.length; i++) {
    if (rowIsActive(list[i], status, soloPath)) return i
  }
  return -1
}

// Channel up and down: the row next to the one playing, wrapping at the ends. With
// nothing of this list playing, the first step lands on the first or the last row.
function adjacentRowIndex(count, activeIndex, delta) {
  var n = numberOr(count, 0)
  if (n <= 0) return -1
  var step = delta < 0 ? -1 : 1
  if (activeIndex < 0 || activeIndex >= n) return step > 0 ? 0 : n - 1
  return (activeIndex + step + n) % n
}

// The filter runs in the panel on name and section, so a provider that cannot search
// still answers it. An empty query keeps every row.
function filterRows(rows, query) {
  var list = rows && rows.length !== undefined ? rows : []
  var wanted = String(query || "").trim().toLowerCase()
  if (wanted.length === 0) return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    if (!s || typeof s !== "object") continue
    var hay = (String(s.name || "") + " " + String(s.section || "")).toLowerCase()
    if (hay.indexOf(wanted) !== -1) out.push(s)
  }
  return out
}

// The right-hand label on a row: its section, else its size, else what it is.
function rowDetail(row) {
  if (!row) return ""
  if (row.kind === "playlist") {
    if (String(row.section || "").length > 0) return String(row.section)
    if (row.count > 0) return row.count + (row.count === 1 ? " track" : " tracks")
    return ""
  }
  return String(row.kind || "").toUpperCase()
}

function hiddenNote(providerKey, hidden) {
  if (!(hidden > 0)) return ""
  if (providerKey === "spotify")
    return hidden + (hidden === 1 ? " followed playlist is" : " followed playlists are")
      + " hidden. Spotify does not let cliamp read playlists you do not own."
  return hidden + " rows hidden."
}

function trim(text) {
  return String(text || "").replace(/^\s+/, "").replace(/\s+$/, "")
}

function endsWith(text, suffix) {
  return text.length >= suffix.length && text.slice(text.length - suffix.length) === suffix
}

function formatRate(hz) {
  var rounded = Math.round(hz / 1000 * 10) / 10
  return String(rounded) + " kHz"
}

// The three conditions from the spec. "bit-perfect" is only ever said when all hold.
function verdict(v) {
  var input = v || {}
  var codec = String(input.codec || "")
  var streamRate = numberOr(input.streamRate, 0)
  var sinkRate = numberOr(input.sinkRate, 0)

  if (input.transcoded === true) {
    return { ok: false, text: (codec ? codec + " · " : "") + "transcoded by server" }
  }

  // A2DP re-encodes with SBC or AAC, both lossy, so a Bluetooth sink can never be
  // bit-perfect at any sample rate. Saying only "resampled" here would let someone
  // match rates and believe they had got there.
  var link = String(input.lossyLink || "")
  if (link.length > 0) {
    var lead = streamRate > 0 ? formatRate(streamRate) + " · " : ""
    return { ok: false, text: lead + link + " · lossy" }
  }
  if (streamRate <= 0 || sinkRate <= 0) {
    return { ok: false, text: "" }
  }

  // cliamp always outputs one fixed rate and resamples anything else internally,
  // before PipeWire can see it, so the file's own rate is the only thing that proves
  // the decode stage was clean. Unknown means the claim cannot be made.
  var sourceRate = numberOr(input.sourceRate, 0)
  if (sourceRate > 0 && Math.abs(sourceRate - streamRate) > RATE_MATCH_TOLERANCE_HZ) {
    return {
      ok: false,
      text: formatRate(sourceRate).replace(" kHz", "") + " → " + formatRate(streamRate)
        + " · cliamp resampled"
    }
  }

  var prefix = (codec ? codec + " " : "") + formatRate(streamRate)
  if (Math.abs(streamRate - sinkRate) > RATE_MATCH_TOLERANCE_HZ) {
    // Written as an arrow so the whole verdict stays on one line in the panel.
    var text = formatRate(streamRate).replace(" kHz", "") + " → " + formatRate(sinkRate) + " · resampled"
    // A rate was forced and the sink took a different one: the 88.2 to 96 case on the
    // internal DAC, or AirPods on SBC-XQ which hold the link at 48 kHz. Only then is
    // the output the thing to blame, which the requested rate is what distinguishes
    // from an ordinary unforced mismatch.
    var requested = numberOr(input.requestedRate, 0)
    if (requested > 0 && Math.abs(requested - sinkRate) > RATE_MATCH_TOLERANCE_HZ) {
      text = formatRate(streamRate).replace(" kHz", "") + " → " + formatRate(sinkRate)
        + " · output has no " + formatRate(requested).replace(" kHz", "")
    }
    return { ok: false, text: text }
  }
  if (input.eqFlat === false) {
    return { ok: false, text: prefix + " · EQ applied" }
  }
  if (input.unityGain === false || input.playerUnity === false) {
    // Named only when it is known which gain moved, because the panel can correct one.
    var stage = input.playerUnity === false ? "cliamp volume"
      : input.playerUnity === true ? "output volume" : "volume"
    return { ok: false, text: prefix + " · " + stage + " applied" }
  }
  // The claim needs the source rate, the gain, the EQ and the transcode flag all read.
  if (sourceRate <= 0 || input.unityGain !== true || input.eqFlat !== true || input.transcoded !== false) {
    return { ok: false, text: prefix + " · no resampling after cliamp" }
  }
  return { ok: true, text: prefix + " · bit-perfect" }
}

// Quickshell reports MPRIS position and length as doubles in seconds, not microseconds.
function formatTime(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value < 0) value = 0
  var total = Math.floor(value)
  var secs = total % SECONDS_PER_MINUTE
  var minutes = Math.floor(total / SECONDS_PER_MINUTE) % MINUTES_PER_HOUR
  var hours = Math.floor(total / (SECONDS_PER_MINUTE * MINUTES_PER_HOUR))
  var ss = secs < 10 ? "0" + secs : String(secs)
  if (hours > 0) {
    var mm = minutes < 10 ? "0" + minutes : String(minutes)
    return hours + ":" + mm + ":" + ss
  }
  return minutes + ":" + ss
}

function elideError(raw) {
  var text = String(raw || "").replace(/\s+/g, " ").trim()
  if (text.length <= MAX_ERROR_CHARS) return text
  return text.slice(0, MAX_ERROR_CHARS)
}
