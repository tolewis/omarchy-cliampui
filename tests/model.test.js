// Run with: deno run --allow-read tests/model.test.js
// Model.js has no exports, so it is evaluated here rather than imported.

const source = Deno.readTextFileSync(new URL("../Model.js", import.meta.url))
const Model = new Function(
  source + "; return { defaultStatus, parseStatus, parseSnapshot, parseObject, errorText, messageKind, jobTerminal, jobError, friendlyError, loadedNothing, rateFromNodeProps, sinkRateFromPactl, parseSinkAvailability, parsePlaylists, parseResults, matchPlaylists, asBool, parseLyrics, activeLyricIndex, latencyMs, isSupportedOutputRate, parseBands, coverArtUrlFromStreamPath, transcodedFromPath, bluetoothCodecLabel, verdict, formatTime, elideError, MAX_ERROR_CHARS, RECENTLY_PLAYED, parseProviders, providerByKey, playlistRef, rowKey, parseSourceRows, parseSearchRows, playRequest, rowIsActive, activeRowIndex, adjacentRowIndex, filterRows, rowDetail, hiddenNote }"
)()

let failures = 0

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.log("FAIL " + name + "\n  expected " + JSON.stringify(expected) + "\n  got      " + JSON.stringify(actual))
  }
}

// Byte for byte from cliamp 2.3.0 on the box: state.get while a cliamp radio channel plays.
const ncs = '{"version":2,"id":"cliampui-3","ok":true,"snapshot":{"revision":4,"playlist_revision":3,"state":"playing","track":{"title":"BE THERE WITH U","artist":"2frers","album":"BE THERE WITH U","path":"https://radio.cliamp.stream/ncs/tracks/b9092417fc7622db","stream":true},"logical_track":{"title":"BE THERE WITH U","artist":"2frers","album":"BE THERE WITH U","path":"https://radio.cliamp.stream/ncs/tracks/b9092417fc7622db","stream":true},"position":1.999818594,"duration":169.692471655,"seekable":true,"playlist":"cliamp:ncs","total":48,"shuffle":false,"repeat":"Off","mono":false,"speed":1,"eq_preset":"Custom","eq_bands":[0,0,0,0,0,0,0,0,0,0],"visualizer":"Bars"}}'

const r = Model.parseStatus(ncs)
check("v2 status parses", r.ok, true)
check("v2 title", r.title, "BE THERE WITH U")
check("v2 artist", r.artist, "2frers")
check("a channel track is a stream", r.isStream, true)
check("and it can still seek, which cliamp says itself", r.seekable, true)
check("v2 names the loaded playlist", r.playlist, "cliamp:ncs")
check("v2 queue depth", r.total, 48)
check("an omitted index with a track is the first track", r.index, 0)
check("an omitted volume is 0 dB", r.volumeDb, 0)
check("v2 revision", r.revision, 4)
check("v2 duration", r.durationSec, 169.692471655)

// The same snapshot arrives bare in a runtime.state event and inside a finished job.
check("a bare snapshot parses the same", Model.parseSnapshot(JSON.parse(ncs).snapshot), r)

// A Navidrome track, tokens replaced. Note stream:true is set for library tracks as well
// as radio, so it cannot be the seekability test.
const nav = Model.parseSnapshot({state: "playing", track: {title: "Billie (Loving Arms)", artist: "Gerry Mulligan", album: "Night Lights", path: "https://music.example.com/rest/stream?c=cliamp&f=json&format=raw&id=rrH30XR3&s=SALT&t=TOKEN&u=USER&v=1.0.0", stream: true}, position: 37.49, duration: 412, seekable: false, index: 3, total: 44, volume: -6.5})
check("navidrome index", nav.index, 3)
check("navidrome volume", nav.volumeDb, -6.5)
check("navidrome cannot seek", nav.seekable, false)

check("cover art is derived from the stream url",
  Model.coverArtUrlFromStreamPath(nav.path, 300),
  "https://music.example.com/rest/getCoverArt?c=cliamp&id=rrH30XR3&s=SALT&t=TOKEN&u=USER&v=1.0.0&size=300")
check("cover art needs a stream url", Model.coverArtUrlFromStreamPath("http://radio.example/stream", 300), "")
check("cover art refuses plaintext", Model.coverArtUrlFromStreamPath("http://music.example.com/rest/stream?id=1&u=a&t=b&s=c", 300), "")
check("cover art of a local file", Model.coverArtUrlFromStreamPath("/tmp/x.flac", 300), "")
check("cover art of nothing", Model.coverArtUrlFromStreamPath("", 300), "")

check("format=raw is not transcoded", Model.transcodedFromPath(nav.path), false)
check("a missing format=raw is transcoded",
  Model.transcodedFromPath("https://music.example.com/rest/stream?id=1&format=mp3"), true)
check("a local file is not transcoded", Model.transcodedFromPath("/tmp/x.flac"), false)

// A Spotify track carries its own cover, which the panel prefers.
const sp = Model.parseSnapshot({state: "playing", track: {title: "Dance Monkey", path: "spotify:track:2XU0", album_art_url: "https://i.scdn.co/image/ab67", duration_secs: 209}})
check("provider art is read", sp.artUrl, "https://i.scdn.co/image/ab67")
check("the track duration fills a missing snapshot duration", sp.durationSec, 209)

// A live station names the song in stream_title.
const live = Model.parseSnapshot({state: "playing", track: {title: "Lofi", path: "https://radio.cliamp.stream/lofi/stream", stream: true, stream_title: "Artist - Song"}})
check("a live station shows the song", live.title, "Artist - Song")
check("and names itself as the artist", live.artist, "Lofi")

// Measured: a daemon with nothing loaded omits track, index and total.
const empty = Model.parseStatus('{"version":2,"id":"c","ok":true,"snapshot":{"revision":1,"playlist_revision":0,"state":"stopped","seekable":false,"index":-1,"shuffle":false,"repeat":"Off","mono":false,"speed":1,"eq_preset":"Custom","eq_bands":[0,0,0,0,0,0,0,0,0,0],"visualizer":"Bars"}}')
check("empty parses", empty.ok, true)
check("empty title", empty.title, "")
check("empty index", empty.index, -1)
check("empty total defaults to zero", empty.total, 0)

// Measured on the old panel: a v1 request is refused, and that refusal is not a status.
const refused = Model.parseStatus('{"version":2,"ok":false,"error":{"code":"invalid_version","message":"unsupported protocol version"}}')
check("a refusal is not ok", refused.ok, false)
check("a refusal says why in words, not [object Object]", refused.lastError, "unsupported protocol version")

// cliamp exits 1 and prints this when no socket exists.
const down = Model.parseStatus("cliamp is not running (no socket at /home/user/.config/cliamp/cliamp.sock)")
check("down is not ok", down.ok, false)
check("down still returns the full shape", Object.keys(down).sort(), Object.keys(Model.defaultStatus()).sort())
check("down records why", down.lastError.length > 0, true)

check("empty input is not ok", Model.parseStatus("").ok, false)
check("null input does not throw", Model.parseStatus(null).ok, false)
check("a missing snapshot does not throw", Model.parseSnapshot(null).ok, false)

// PipeWire publishes the stream rate as a period, so 1/44100 means 44100 Hz.
check("node.rate parses", Model.rateFromNodeProps({ "node.rate": "1/44100" }), 44100)
check("node.rate 96k", Model.rateFromNodeProps({ "node.rate": "1/96000" }), 96000)
check("missing node.rate is zero", Model.rateFromNodeProps({}), 0)
check("malformed node.rate is zero", Model.rateFromNodeProps({ "node.rate": "44100" }), 0)
check("null props is zero", Model.rateFromNodeProps(null), 0)

// pactl list short sinks, tab separated: id, name, driver, format, state
check("pactl rate parses", Model.sinkRateFromPactl("55\talsa_output.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts32le 2ch 44100Hz\tRUNNING"), 44100)
check("pactl rate 48k", Model.sinkRateFromPactl("55\tx\tPipeWire\ts32le 2ch 48000Hz\tIDLE"), 48000)
check("pactl garbage is zero", Model.sinkRateFromPactl("nonsense"), 0)
check("pactl empty is zero", Model.sinkRateFromPactl(""), 0)

// omarchy-audio-sink-availability, one sink per line, name then a 0 or 1.
check("availability marks a live sink", Model.parseSinkAvailability("alsa_output.x\t1"), { "alsa_output.x": true })
check("availability marks a dead sink", Model.parseSinkAvailability("hdmi.y\t0"), { "hdmi.y": false })
check("availability handles both", Model.parseSinkAvailability("a\t1\nb\t0"), { a: true, b: false })
check("availability ignores junk", Model.parseSinkAvailability("nonsense\n\n"), {})
check("availability of nothing", Model.parseSinkAvailability(""), {})

// cliamp playlist list, byte for byte from the box.
check("playlists parse", Model.parsePlaylists("  Recently Played  8 tracks"), [{ name: "Recently Played", count: 8 }])
check("a singular track parses", Model.parsePlaylists("  Solo  1 track"), [{ name: "Solo", count: 1 }])
check("several playlists", Model.parsePlaylists("  A  2 tracks\n  B B  10 tracks"), [{ name: "A", count: 2 }, { name: "B B", count: 10 }])
check("a header line is ignored", Model.parsePlaylists("No playlists found."), [])
check("empty playlist output", Model.parsePlaylists(""), [])

// cliamp outputs a fixed rate, so a known source rate is required before the full
// claim is made. Measured: a 48 kHz file leaves cliamp at 44100 with default config.
// cliamp accepts only these output rates, so 88.2 can never be played natively.
check("44.1 is a supported output rate", Model.isSupportedOutputRate(44100), true)
check("96 is supported", Model.isSupportedOutputRate(96000), true)
check("88.2 is not", Model.isSupportedOutputRate(88200), false)
check("zero is not", Model.isSupportedOutputRate(0), false)

// One NDJSON frame from {"cmd":"bands"}, byte for byte from the docs.
check("bands parse", Model.parseBands('{"ok":true,"visualizer":"Bars","bands":[0.93,0.81,0.62]}'), [0.93, 0.81, 0.62])
check("bands clamp above one", Model.parseBands('{"ok":true,"bands":[1.4,-0.2]}'), [1, 0])
check("a failed frame yields nothing", Model.parseBands('{"ok":false,"error":"x"}'), [])
check("garbage yields nothing", Model.parseBands("not json"), [])
check("empty yields nothing", Model.parseBands(""), [])

// One mixed array from `cliamp-library search`, the shape the helper prints.
const mixed = '[{"kind":"album","id":"a1","name":"Discovery","artist":"Daft Punk","songCount":14},' +
  '{"kind":"song","id":"s1","name":"One More Time","artist":"Daft Punk","album":"Discovery","duration":320}]'

check("an album row parses", Model.parseResults(mixed)[0],
  { kind: "album", id: "a1", name: "Discovery", artist: "Daft Punk", album: "", songCount: 14, duration: 0 })
check("a song row parses", Model.parseResults(mixed)[1],
  { kind: "song", id: "s1", name: "One More Time", artist: "Daft Punk", album: "Discovery", songCount: 0, duration: 320 })
check("an untagged row is an album",
  Model.parseResults('[{"id":"a1","name":"x"}]').map(function (r) { return r.kind }), ["album"])
check("an unknown kind falls back to album",
  Model.parseResults('[{"kind":"artist","id":"a1","name":"x"}]').map(function (r) { return r.kind }), ["album"])
check("a row without an id is skipped", Model.parseResults('[{"name":"x"}]'), [])
check("garbage results yield nothing", Model.parseResults("nope"), [])
check("empty results", Model.parseResults("[]"), [])

// Built by the real producer, so a field rename in parsePlaylists breaks this too.
const saved = Model.parsePlaylists("  Recently Played  55 tracks\n  cliampui  12 tracks\n")

check("the scratch playlist is never a row",
  Model.matchPlaylists(saved, "").map(function (r) { return r.name }),
  ["Recently Played"])
check("a playlist row is typed and carries its count",
  Model.matchPlaylists(saved, "")[0],
  { kind: "playlist", id: "Recently Played", name: "Recently Played", artist: "", album: "", songCount: 55, duration: 0 })
check("playlists filter on the query, case insensitively",
  Model.matchPlaylists(saved, "RECENT").map(function (r) { return r.name }),
  ["Recently Played"])
check("searching for the scratch name still finds nothing",
  Model.matchPlaylists(saved, "cliampui"), [])
check("no playlists is not an error", Model.matchPlaylists(null, "x"), [])

// The result of a succeeded lyrics job, measured on the box.
const lyricsReply = '{"ok":true,"lyrics":[{"start":30.23,"text":"One more time"},{"start":33.5,"text":"Celebrate"},{"start":37,"text":"and dance so free"}]}'
check("lyrics parse from the result object too", Model.parseLyrics(JSON.parse(lyricsReply)).length, 3)

// The two sockets: replies carry the request id, events carry the topic.
check("a reply is routed by id", Model.messageKind('{"version":2,"id":"cliampui-1","ok":true,"job":{"id":"ab","state":"queued"}}'), "response")
check("a refusal is still a reply", Model.messageKind('{"version":2,"id":"cliampui-2","ok":false,"error":{"code":"invalid_params"}}'), "response")
check("an event is an event", Model.messageKind('{"event":"runtime.state","seq":1,"data":{"state":"stopped"}}'), "event")
check("garbage is garbage", Model.messageKind("not json"), "garbage")
check("an empty frame is nothing at all", Model.messageKind(""), "none")
check("a whitespace frame is nothing at all", Model.messageKind("   \n"), "none")

check("queued is not terminal", Model.jobTerminal({state: "queued"}), false)
check("running is not terminal", Model.jobTerminal({state: "running"}), false)
check("succeeded is terminal", Model.jobTerminal({state: "succeeded"}), true)
check("failed is terminal", Model.jobTerminal({state: "failed"}), true)
check("canceled is terminal", Model.jobTerminal({state: "canceled"}), true)

// Byte for byte from 2.3.0: a followed Spotify playlist, and a track with no lyrics.
const forbidden = {state: "failed", error: {code: "internal_error", message: "operation failed", detail: "spotify: list tracks: http status 403 Forbidden: {\"error\": {\"status\": 403, \"message\": \"Forbidden\" } }"}}
check("a 403 from Spotify is explained",
  Model.jobError(forbidden), "Spotify does not let cliamp read this playlist. It plays only playlists you own or collaborate on.")
check("the detail is the useful half", Model.errorText({code: "internal_error", message: "operation failed", detail: "no lyrics found"}), "no lyrics found")
check("a message without detail is used", Model.errorText({code: "invalid_params", message: "invalid parameters"}), "invalid parameters")
check("a v1 string error is read", Model.errorText("playlist not found"), "playlist not found")
check("no error is empty", Model.errorText(null), "")
check("a succeeded job has no error", Model.jobError({state: "succeeded"}), "")
check("a canceled job says so", Model.jobError({state: "canceled"}), "canceled")
check("a missing job says so", Model.jobError(null), "no answer from cliamp")
check("a 404 keeps its own words", Model.jobError({state: "failed", error: {detail: "spotify: list tracks: http status 404"}}), "spotify: list tracks: http status 404")
check("a rate limit is explained", Model.friendlyError("http status 429"), "The provider is rate-limiting requests. Try again in a minute.")

// Measured: loading the empty saved playlist "Favorites" succeeds and plays nothing.
check("an empty load is noticed", Model.loadedNothing({state: "succeeded", snapshot: {state: "stopped"}}), true)
check("a load with tracks is not", Model.loadedNothing({state: "succeeded", snapshot: {total: 14}}), false)
check("a failed load is reported elsewhere", Model.loadedNothing({state: "failed"}), false)

// `omarchy bar set <id> <key> true` stores the string, not the boolean, without --json.
check("the string the bar CLI writes counts as true", Model.asBool("true", false), true)
check("and its opposite counts as false", Model.asBool("false", true), false)
check("a real boolean is passed through", Model.asBool(true, false), true)
check("an unset setting takes the fallback", Model.asBool(undefined, true), true)
check("anything else takes the fallback", Model.asBool("yes", false), false)

check("a command error yields no lyrics", Model.parseLyrics('{"ok":false,"error":"no lyrics found"}'), [])

check("the latency helper output parses", Model.latencyMs("167\n"), 167)
check("an unknown latency is zero, which compensates nothing", Model.latencyMs("0"), 0)
check("garbage latency is zero", Model.latencyMs("what"), 0)
check("a negative latency is refused", Model.latencyMs("-40"), 0)

check("lyrics parse", Model.parseLyrics(lyricsReply).length, 3)
check("a lyric keeps its timestamp", Model.parseLyrics(lyricsReply)[0], { start: 30.23, text: "One more time" })
check("a track with no lyrics is empty, not an error", Model.parseLyrics('{"ok":true,"lyrics":[]}'), [])
check("an empty line is dropped", Model.parseLyrics('{"ok":true,"lyrics":[{"start":1,"text":""}]}'), [])
check("garbage lyrics yield nothing", Model.parseLyrics("nope"), [])

const lines = Model.parseLyrics(lyricsReply)
check("before the first line nothing is active", Model.activeLyricIndex(lines, 10), -1)
check("the first line activates on its timestamp", Model.activeLyricIndex(lines, 30.23), 0)
check("the line being sung is the last one started", Model.activeLyricIndex(lines, 35), 1)
check("the final line stays active to the end", Model.activeLyricIndex(lines, 900), 2)
check("no lyrics means no active line", Model.activeLyricIndex([], 5), -1)
check("a missing list is not an error", Model.activeLyricIndex(null, 5), -1)

check("bit-perfect needs the source rate to agree",
  Model.verdict({ sourceRate: 44100, streamRate: 44100, sinkRate: 44100, unityGain: true, eqFlat: true, transcoded: false, codec: "FLAC" }),
  { ok: true, text: "FLAC 44.1 kHz · bit-perfect" })

check("an unknown source rate stops short of the claim",
  Model.verdict({ streamRate: 44100, sinkRate: 44100, unityGain: true, eqFlat: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · no resampling after cliamp" })

check("cliamp resampling the file is named",
  Model.verdict({ sourceRate: 48000, streamRate: 44100, sinkRate: 44100, unityGain: true, eqFlat: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "48 → 44.1 kHz · cliamp resampled" })

check("resampled names both rates",
  Model.verdict({ streamRate: 44100, sinkRate: 48000, unityGain: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "44.1 → 48 kHz · resampled" })

// The measured trap: a force was requested, this DAC has no 88.2, PipeWire silently
// lands on 96, and only the requested rate reveals that the DAC is what refused.
check("nearest-rate substitution is named",
  Model.verdict({ streamRate: 88200, sinkRate: 96000, unityGain: true, transcoded: false, codec: "FLAC", requestedRate: 88200 }),
  { ok: false, text: "88.2 → 96 kHz · output has no 88.2" })

// Same rates, but nothing was forced, so the DAC is not the thing to blame.
check("an unforced mismatch does not blame the DAC",
  Model.verdict({ streamRate: 88200, sinkRate: 96000, unityGain: true, transcoded: false, codec: "FLAC", requestedRate: 0 }),
  { ok: false, text: "88.2 → 96 kHz · resampled" })

check("bluez codec is named", Model.bluetoothCodecLabel({ "api.bluez5.codec": "sbc_xq" }), "SBC-XQ")
check("aac is named", Model.bluetoothCodecLabel({ "api.bluez5.codec": "aac" }), "AAC")
check("an unknown codec still shows", Model.bluetoothCodecLabel({ "api.bluez5.codec": "wibble" }), "WIBBLE")
check("a wired sink has no codec", Model.bluetoothCodecLabel({ "node.name": "alsa_output.x" }), "")
check("no props, no codec", Model.bluetoothCodecLabel(null), "")

// A2DP re-encodes, so matching the rate would still not make it bit-perfect.
check("a bluetooth link is called lossy, not merely resampled",
  Model.verdict({ streamRate: 44100, sinkRate: 48000, unityGain: true, transcoded: false, codec: "", requestedRate: 44100, lossyLink: "SBC-XQ" }),
  { ok: false, text: "44.1 kHz · SBC-XQ · lossy" })

check("even matched rates over bluetooth are not bit-perfect",
  Model.verdict({ streamRate: 48000, sinkRate: 48000, unityGain: true, transcoded: false, codec: "FLAC", requestedRate: 0, lossyLink: "AAC" }),
  { ok: false, text: "48 kHz · AAC · lossy" })

// AirPods on SBC-XQ hold the link at 48 kHz, so a 44.1 track is refused the same way.
check("a wired output that refuses a rate is still named",
  Model.verdict({ streamRate: 44100, sinkRate: 48000, unityGain: true, transcoded: false, codec: "", requestedRate: 44100 }),
  { ok: false, text: "44.1 → 48 kHz · output has no 44.1" })

// A force that the sink honoured is not a substitution either.
check("an honoured force reports bit-perfect",
  Model.verdict({ sourceRate: 44100, streamRate: 44100, sinkRate: 44100, unityGain: true, playerUnity: true, eqFlat: true, transcoded: false, codec: "FLAC", requestedRate: 44100 }),
  { ok: true, text: "FLAC 44.1 kHz · bit-perfect" })

// cliamp calls an untouched EQ "Custom", so only the band values can be trusted.
check("an untouched EQ is flat", Model.parseStatus(ncs).eqFlat, true)
check("a raised band is not flat",
  Model.parseSnapshot({state: "playing", eq_bands: [0, 0, 3, 0, 0, 0, 0, 0, 0, 0]}).eqFlat, false)
check("a missing eq is treated as flat",
  Model.parseSnapshot({state: "playing"}).eqFlat, true)

check("EQ breaks it even when rates and gain are right",
  Model.verdict({ streamRate: 44100, sinkRate: 44100, unityGain: true, eqFlat: false, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · EQ applied" })

check("an unmeasured stage is not named, it is just volume",
  Model.verdict({ streamRate: 44100, sinkRate: 44100, unityGain: false, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · volume applied" })

check("cliamp's own gain is named, because the panel slider cannot correct it",
  Model.verdict({ streamRate: 44100, sinkRate: 44100, unityGain: false, playerUnity: false, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · cliamp volume applied" })

check("a known player gain at unity blames the output stage",
  Model.verdict({ streamRate: 44100, sinkRate: 44100, unityGain: false, playerUnity: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · output volume applied" })

check("a moved player gain blocks the claim even if the caller says unity",
  Model.verdict({ sourceRate: 44100, streamRate: 44100, sinkRate: 44100, unityGain: true, playerUnity: false, eqFlat: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · cliamp volume applied" })

// The claim is only made when every condition was read, so an unread one stops short.
check("an unread gain stops short of the claim rather than naming a stage",
  Model.verdict({ sourceRate: 44100, streamRate: 44100, sinkRate: 44100, eqFlat: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · no resampling after cliamp" })

check("an unread EQ stops short of the claim",
  Model.verdict({ sourceRate: 44100, streamRate: 44100, sinkRate: 44100, unityGain: true, playerUnity: true, transcoded: false, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · no resampling after cliamp" })

check("an unread transcode flag stops short of the claim",
  Model.verdict({ sourceRate: 44100, streamRate: 44100, sinkRate: 44100, unityGain: true, playerUnity: true, eqFlat: true, codec: "FLAC" }),
  { ok: false, text: "FLAC 44.1 kHz · no resampling after cliamp" })

check("a transcoded stream can never be bit-perfect",
  Model.verdict({ streamRate: 44100, sinkRate: 44100, unityGain: true, transcoded: true, codec: "MP3" }),
  { ok: false, text: "MP3 · transcoded by server" })

check("unknown rates say nothing",
  Model.verdict({ streamRate: 0, sinkRate: 0, unityGain: true, transcoded: false, codec: "" }),
  { ok: false, text: "" })

check("zero time", Model.formatTime(0), "0:00")
check("one minute 47", Model.formatTime(107), "1:47")
check("over an hour", Model.formatTime(3723), "1:02:03")
check("negative is clamped", Model.formatTime(-5), "0:00")
check("fractional seconds floor", Model.formatTime(107.9), "1:47")
check("non-numeric is zero", Model.formatTime("x"), "0:00")

check("error whitespace collapses", Model.elideError("a\n\n  b"), "a b")
check("long error is cut", Model.elideError("x".repeat(300)).length, Model.MAX_ERROR_CHARS)
check("empty error stays empty", Model.elideError(""), "")

// provider.list, byte for byte from 2.3.0.
const providers = Model.parseProviders({ok: true, providers: [{key: "cliamp", name: "cliamp radio", searchable: false}, {key: "radio", name: "Radio", searchable: true, catalog: true}, {key: "local", name: "Local", searchable: true}, {key: "spotify", name: "Spotify", searchable: true}, {name: "no key"}]})
check("providers parse, keyless rows dropped", providers.map(p => p.key), ["cliamp", "radio", "local", "spotify"])
check("searchable is read", providers[1].searchable, true)
check("catalog is read", providers[1].catalog, true)
check("provider lookup", Model.providerByKey(providers, "spotify").name, "Spotify")
check("an unknown provider is null", Model.providerByKey(providers, "tidal"), null)
check("a job result string parses too", Model.parseProviders('{"providers":[{"key":"radio"}]}').length, 1)
check("garbage gives no providers", Model.parseProviders("nope"), [])

// cliamp radio channels have stable ids on 2.3.0. The old station list gave EDM and NCS
// the same id, "cliamp:", so a click on NCS played EDM.
const channels = Model.parseSourceRows({ok: true, total: 3, playlists: [{id: "edm", name: "EDM", provider: "cliamp", track_count: 100}, {id: "ncs", name: "NCS", provider: "cliamp", track_count: 48}, {id: "ncs", name: "NCS again", provider: "cliamp"}]}, "cliamp")
check("channel rows", channels.rows.map(r => r.id), ["edm", "ncs"])
check("a duplicate id is listed once", channels.rows.length, 2)
check("a channel shows its size", Model.rowDetail(channels.rows[1]), "48 tracks")

const status = Model.parseStatus(ncs)
check("the playing channel is found by the snapshot playlist", Model.activeRowIndex(channels.rows, status), 1)
check("EDM is not marked when NCS plays", Model.rowIsActive(channels.rows[0], status), false)
check("playlist ref splits at the first colon", Model.playlistRef("spotify:spotify:album:4eL"), {provider: "spotify", id: "spotify:album:4eL"})
check("an empty ref", Model.playlistRef(""), {provider: "", id: ""})

// Spotify, as 2.3.0 lists it for this account: followed playlists always answer 403.
const spotify = Model.parseSourceRows({ok: true, playlists: [
  {id: "YOUR MUSIC", name: "Your Music", provider: "spotify", section: "Library", track_count: 274},
  {id: "0Gw2", name: "Logan's Dance Mix", provider: "spotify", section: "Your playlists", track_count: 18},
  {id: "23hD", name: "ROCK/GYM PUMP", provider: "spotify", section: "Followed playlists", track_count: 50},
  {id: "spotify:album:7q2B", name: "Dr. Dre - 2001", provider: "spotify", section: "Saved albums", track_count: 23}]}, "spotify")
check("followed playlists are not listed", spotify.rows.map(r => r.id), ["YOUR MUSIC", "0Gw2", "spotify:album:7q2B"])
check("and they are counted", spotify.hidden, 1)
check("the note explains them", Model.hiddenNote("spotify", 34), "34 followed playlists are hidden. Spotify does not let cliamp read playlists you do not own.")
check("no note without hidden rows", Model.hiddenNote("spotify", 0), "")
check("a section is the row detail", Model.rowDetail(spotify.rows[0]), "Library")

// Radio's catalog carries "Use my location", which asks a question the panel cannot.
const radio = Model.parseSourceRows({ok: true, playlists: [{id: "loc:ask", name: "Use my location", provider: "radio"}, {id: "l:0", name: "cliamp radio", provider: "radio"}, {id: "c:0", name: "MANGORADIO [128k] · Germany", provider: "radio", favoritable: true}]}, "radio")
check("the location prompt is skipped", radio.rows.map(r => r.id), ["l:0", "c:0"])

// provider.search on 2.3.0: Spotify answers albums, Radio stations, Podcasts feeds.
const albums = Model.parseSearchRows({ok: true, tracks: [{title: "DAMN.", artist: "Kendrick Lamar", album: "DAMN.", path: "spotify:album:4eLPsYPBmXABThSJ821sqY", year: 2017, provider_meta: {albumID: "4eLPsYPBmXABThSJ821sqY", kind: "album"}}]}, "spotify")
check("a Spotify album row", [albums[0].kind, albums[0].name, albums[0].section], ["album", "DAMN.", "Kendrick Lamar"])
// Measured: provider.load with the bare id answers 404, and with the full path it plays.
check("an album loads by its full path, not the stripped id", Model.playRequest(albums[0]),
  {operation: "provider.load", params: {provider: "spotify", playlist: "spotify:album:4eLPsYPBmXABThSJ821sqY"}})

const stations = Model.parseSearchRows({ok: true, tracks: [{title: "Adroit Jazz Underground", path: "https://icecast.walmradio.com:8443/jazz", stream: true, realtime: true, provider_meta: {"radio.country": "The United States Of America"}}]}, "radio")
check("a radio result is a station", stations[0].kind, "station")
check("a station names its country", stations[0].section, "The United States Of America")
const stationPlay = Model.playRequest(stations[0])
check("a station plays as supplied", stationPlay.operation, "track.play")
check("with its provider identity intact", stationPlay.params.track.provider_meta["radio.country"], "The United States Of America")
check("a station played on its own is marked by path",
  Model.rowIsActive(stations[0], {path: "https://icecast.walmradio.com:8443/jazz"}), true)

const feeds = Model.parseSearchRows({ok: true, tracks: [{title: "The Rest Is History", artist: "Goalhanger", path: "https://feeds.megaphone.fm/GLT4787413333", stream: true, feed: true, provider_meta: {albumID: "https://feeds.megaphone.fm/GLT4787413333", kind: "album"}}]}, "podcast")
check("a podcast result is a feed", feeds[0].kind, "podcast")
check("a feed loads by its url", Model.playRequest(feeds[0]).params.playlist, "https://feeds.megaphone.fm/GLT4787413333")
check("a pathless result is dropped", Model.parseSearchRows({tracks: [{title: "x"}]}, "spotify"), [])
check("no result is no rows", Model.parseSearchRows(null, "spotify"), [])
check("a playlist row loads through the provider", Model.playRequest(channels.rows[0]),
  {operation: "provider.load", params: {provider: "cliamp", playlist: "edm"}})
check("row keys differ by provider and kind", Model.rowKey(channels.rows[0]) !== Model.rowKey(albums[0]), true)

// Channel up and down.
check("next from the middle", Model.adjacentRowIndex(5, 2, 1), 3)
check("previous from the middle", Model.adjacentRowIndex(5, 2, -1), 1)
check("next wraps at the end", Model.adjacentRowIndex(5, 4, 1), 0)
check("previous wraps at the start", Model.adjacentRowIndex(5, 0, -1), 4)
check("nothing playing, next starts at the top", Model.adjacentRowIndex(5, -1, 1), 0)
check("nothing playing, previous starts at the bottom", Model.adjacentRowIndex(5, -1, -1), 4)
check("an empty list has nowhere to go", Model.adjacentRowIndex(0, -1, 1), -1)

// The filter matches the name and the section.
check("filter on name", Model.filterRows(spotify.rows, "dance").map(r => r.id), ["0Gw2"])
check("filter on section", Model.filterRows(spotify.rows, "saved").map(r => r.id), ["spotify:album:7q2B"])
check("filter is case blind", Model.filterRows(channels.rows, "NCS").length, 1)
check("an empty filter keeps every row", Model.filterRows(channels.rows, "  ").length, 2)
check("a missing list filters to nothing", Model.filterRows(null, "x"), [])

check("the scratch playlist is not the recently played list",
  Model.RECENTLY_PLAYED !== "cliampui" && Model.RECENTLY_PLAYED === "Recently Played", true)

console.log(failures === 0 ? "all model tests passed" : failures + " failing")
if (failures > 0) Deno.exit(1)
