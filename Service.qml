import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  // The panel writes this so nothing polls while the popup is shut.
  property bool panelOpen: false

  // Rate following has to notice a track change with nothing on screen, so it is the
  // second consumer of cliamp's status and keeps the poll alive on its own.
  readonly property bool wantsStatus: panelOpen || followNativeRate

  property var status: Model.defaultStatus()
  property string lastError: ""

  readonly property string cliampPath: String(setting("cliampPath", "") || "cliamp")
  readonly property int statusIntervalMs: intSetting("statusIntervalSec", 2, 1, 10) * 1000

  // Bound by cliamp's own bus name, never to whichever player happens to be active,
  // because Chromium and others register MPRIS too and would otherwise drive this panel.
  // Re-resolved on every player list change. A function call binding does not reliably
  // re-evaluate when the daemon restarts, which strands the panel on a dead object.
  property var player: null

  function refreshPlayer() { player = findCliampPlayer() }

  Connections {
    target: Mpris.players
    ignoreUnknownSignals: true
    function onValuesChanged() { root.refreshPlayer() }
  }

  Component.onCompleted: {
    refreshPlayer()
    rebuildNodes()
  }

  // cliamp's own status is the truth. MPRIS only fills gaps, so a stale or missing
  // player object can no longer freeze the panel.
  readonly property bool running: status.ok === true || player !== null
  readonly property bool hasTrack: running && (title.length > 0 || artist.length > 0)
  readonly property bool isPlaying: status.ok === true
    ? status.state === "playing"
    : (player !== null && player.isPlaying === true)
  readonly property string title: String(status.title || (player ? player.trackTitle : "") || "")
  readonly property string artist: String(status.artist || (player ? player.trackArtist : "") || "")
  readonly property string album: String(status.album || (player ? player.trackAlbum : "") || "")

  // Held rather than recomputed to empty. Any moment without a status, between tracks or
  // while the socket changes owner, would otherwise blank the artwork and flash the
  // placeholder. cliamp 2 sends album_art_url for provider tracks, which comes first; a
  // Navidrome cover is still derived from the Subsonic stream URL.
  property string artUrl: ""
  property int artSizePx: 300

  readonly property string resolvedArtUrl: {
    if (!running) return ""
    var fromCliamp = safeArtUrl(status.artUrl)
    if (fromCliamp.length > 0) return fromCliamp
    var fromMpris = player ? safeArtUrl(player.trackArtUrl) : ""
    if (fromMpris.length > 0) return fromMpris
    return safeArtUrl(Model.coverArtUrlFromStreamPath(status.path, artSizePx))
  }

  // Held only across the gap where cliamp is unreachable, which is the socket dropping
  // on a daemon restart. While it is running an empty value is the honest answer, so
  // radio and local files clear the cover instead of showing the last album played.
  onResolvedArtUrlChanged: if (running) artUrl = resolvedArtUrl

  readonly property real lengthSec: {
    if (status.durationSec > 0) return status.durationSec
    if (player && player.lengthSupported) return Number(player.length || 0)
    return 0
  }

  readonly property bool hasProgress: running && lengthSec > 0
  // cliamp 2 says per track whether it can seek. A live station and some HTTP streams
  // cannot, and a cliamp radio channel track can.
  readonly property bool canSeek: hasProgress && status.seekable === true

  readonly property bool shuffle: status.shuffle === true
  readonly property string repeat: String(status.repeat || "Off")
  readonly property int total: Number(status.total || 0)
  readonly property int queueIndex: Number(status.index)
  readonly property real volumeDb: Number(status.volumeDb || 0)
  readonly property bool isStream: status.isStream === true

  // Ticked locally between status reads, because polling Position four times a second
  // is traffic for something the panel can count on its own.
  property real positionSec: 0
  property bool _askedAtEnd: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // `omarchy bar set` stores a bare value as a string unless it is given --json, so the
  // documented way to flip one of these settings would otherwise be silently ignored.
  function boolSetting(name, fallback) {
    return Model.asBool(setting(name, fallback), fallback)
  }

  // Re-clamped on read so a hand-edited shell.json cannot poison the timer.
  function intSetting(name, fallback, min, max) {
    var value = parseInt(setting(name, fallback), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(min, Math.min(max, value))
  }

  function findCliampPlayer() {
    var list = Mpris.players ? Mpris.players.values : []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p) continue
      if (String(p.dbusName || "").indexOf("org.mpris.MediaPlayer2.cliamp") === 0) return p
    }
    return null
  }

  // Album art can be any string a tag supplies, so only these two schemes reach an Image.
  function safeArtUrl(raw) {
    var url = String(raw || "")
    if (url.indexOf("file://") === 0) return url
    if (url.indexOf("https://") === 0) return url
    return ""
  }

  // ---- notices ----

  // The one line that tells the operator why a click did nothing. Every failed
  // operation lands here, and it clears itself so an old failure does not linger.
  property string notice: ""

  function showNotice(text) {
    notice = String(text || "")
    if (notice.length > 0) noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 8000
    repeat: false
    onTriggered: root.notice = ""
  }

  // ---- version 2 IPC ----

  // cliamp 2 speaks only version 2 on ~/.config/cliamp/cliamp.sock. Two connections are
  // kept: one carries requests and their replies, and one is subscribed to runtime
  // events. Measured on 2.3.0: a connection that has subscribed is reset by the daemon
  // if it then sends a request, so the two cannot share one socket.
  readonly property string socketPath: (Quickshell.env("HOME") || "") + "/.config/cliamp/cliamp.sock"

  // The socket changes owner whenever the daemon relaunches. Measured on Quickshell
  // 0.3.0: one connect against a missing path bricks a Socket for good, so every retry
  // has to be a brand new Socket.
  readonly property bool ipcConnected: !!(ipcLoader.item && ipcLoader.item.connected)
  readonly property bool eventsConnected: !!(eventLoader.item && eventLoader.item.connected)

  property int _requestSeq: 0
  // Request id -> handler for the reply. Job id -> pending job record.
  property var _replies: ({})
  property var _jobs: ({})
  property int pendingJobCount: 0

  function _write(request) {
    if (!ipcConnected) return false
    request.version = Model.IPC_VERSION
    request.id = "cliampui-" + (++_requestSeq)
    ipcLoader.item.write(JSON.stringify(request) + "\n")
    ipcLoader.item.flush()
    return request.id
  }

  // A read answered in place, such as state.get.
  function request(method, extra, onReply) {
    var body = { method: method }
    if (extra) { for (var key in extra) body[key] = extra[key] }
    var id = _write(body)
    if (id === false) return false
    if (onReply) _replies[id] = onReply
    return true
  }

  // An operation is answered with a job at once, and finishes later. The handler gets
  // the terminal job: from the reply when it is already done, else from the runtime.job
  // event, else from a job.get poll if the event never comes. Nothing is dropped while
  // an earlier operation runs, so a fast second click is never lost.
  function submit(operation, params, onDone) {
    if (!ipcConnected) {
      _finishJob({ state: "failed", operation: operation, error: { message: "cliamp is not running" } }, onDone)
      return false
    }
    var sent = request("operation.submit", { operation: operation, params: params || {} }, function (reply) {
      if (!reply || reply.ok !== true || !reply.job) {
        var refused = { state: "failed", operation: operation, error: reply ? reply.error : null }
        root._finishJob(refused, onDone)
        return
      }
      var job = reply.job
      if (Model.jobTerminal(job)) { root._finishJob(job, onDone); return }
      var jobs = root._jobs
      jobs[String(job.id)] = { done: onDone, since: Date.now(), polled: 0, operation: operation }
      root.pendingJobCount = Object.keys(jobs).length
    })
    return sent
  }

  function _finishJob(job, onDone) {
    if (job && job.snapshot) applySnapshot(job.snapshot)
    var err = Model.jobError(job)
    if (err.length > 0 && !onDone) showNotice(String(job.operation || "command") + ": " + err)
    if (onDone) onDone(job, err)
  }

  function _resolveJob(job) {
    if (!job || !job.id) return
    var key = String(job.id)
    var entry = _jobs[key]
    if (!entry || !Model.jobTerminal(job)) return
    delete _jobs[key]
    pendingJobCount = Object.keys(_jobs).length
    _finishJob(job, entry.done)
  }

  function _failAllJobs(reason) {
    var jobs = _jobs
    _jobs = ({})
    _replies = ({})
    pendingJobCount = 0
    for (var key in jobs) {
      var entry = jobs[key]
      if (entry) _finishJob({ state: "failed", operation: entry.operation, error: { message: reason } }, entry.done)
    }
  }

  // The fallback for a lost runtime.job event: ask after a second, then every second,
  // and give up after a minute so a job the daemon forgot cannot hold a row busy.
  Timer {
    id: jobPollTimer
    interval: 1000
    repeat: true
    running: root.pendingJobCount > 0 && root.ipcConnected
    onTriggered: {
      var now = Date.now()
      var jobs = root._jobs
      for (var key in jobs) {
        var entry = jobs[key]
        if (now - entry.since > 60000) {
          delete jobs[key]
          root._finishJob({ state: "failed", operation: entry.operation, error: { message: "cliamp did not finish " + entry.operation } }, entry.done)
          continue
        }
        if (now - entry.since < 1000) continue
        root.request("job.get", { job_id: key }, function (reply) {
          if (reply && reply.job) root._resolveJob(reply.job)
        })
      }
      root.pendingJobCount = Object.keys(jobs).length
    }
  }

  // Revisions only move forward while one daemon runs. A late job snapshot must not undo
  // a newer event, but a restarted daemon counts from 1 again, which a reconnect resets.
  function applySnapshot(snapshot) {
    var parsed = Model.parseSnapshot(snapshot)
    if (status.ok === true && parsed.revision > 0 && parsed.revision < status.revision) return
    status = parsed
    lastError = ""
    positionSec = Number(parsed.positionSec || 0)
  }

  function refreshStatus() {
    request("state.get", null, function (reply) {
      if (reply && reply.ok === true && reply.snapshot) { root.applySnapshot(reply.snapshot); return }
      root.lastError = Model.errorText(reply ? reply.error : null)
    })
  }

  function _routeReply(raw) {
    var data = Model.parseObject(raw)
    if (data === null || data.id === undefined) return
    var id = String(data.id)
    var handler = _replies[id]
    if (!handler) return
    delete _replies[id]
    handler(data)
  }

  function _routeEvent(raw) {
    var data = Model.parseObject(raw)
    if (data === null) return
    var name = String(data.event || "")
    if (name === "runtime.state") { applySnapshot(data.data); return }
    if (name === "runtime.job") { if (data.data && data.data.job) _resolveJob(data.data.job); return }
    // The daemon closes a stream it could not keep up with. The snapshot is re-read.
    if (name === "system.overflow") { eventLoader.active = false; eventLoader.active = true; refreshStatus() }
  }

  Loader {
    id: ipcLoader
    active: true
    sourceComponent: Socket {
      path: root.socketPath
      connected: true

      // Handled on the root's ipcConnected, which is only true once this Socket is the
      // Loader's item. Writing from here ran before that and was silently lost.

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) { root._routeReply(String(line || "")) }
      }
    }
  }

  Loader {
    id: eventLoader
    active: true
    sourceComponent: Socket {
      path: root.socketPath
      connected: true

      onConnectionStateChanged: {
        if (!connected) return
        write(JSON.stringify({ version: Model.IPC_VERSION, id: "cliampui-events", method: "subscribe",
          topics: ["runtime.state", "runtime.job"] }) + "\n")
        flush()
      }

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) { root._routeEvent(String(line || "")) }
      }
    }
  }

  Timer {
    id: reconnectTimer
    interval: 700
    repeat: true
    // No assignment to running anywhere: the binding is the only thing that can stop
    // this, so a later disconnect can always start it again.
    running: !root.ipcConnected || !root.eventsConnected
    onTriggered: {
      if (!root.ipcConnected) { ipcLoader.active = false; ipcLoader.active = true }
      if (!root.eventsConnected) { eventLoader.active = false; eventLoader.active = true }
    }
  }

  onIpcConnectedChanged: {
    if (ipcConnected) {
      goneTimer.stop()
      // A new connection may be a new daemon whose revisions start again at 1.
      status = Object.assign({}, status, { revision: 0 })
      refreshStatus()
      readProviders()
      return
    }
    goneTimer.restart()
    _failAllJobs("cliamp disconnected")
    dropLyricsRequest()
  }

  // The socket drops briefly whenever the daemon restarts. Blanking the artwork and
  // title for that window is worse than briefly showing the last known track, so the
  // state is only cleared once cliamp has genuinely stayed away.
  Timer {
    id: goneTimer
    interval: 6000
    repeat: false
    onTriggered: {
      if (root.ipcConnected) return
      root.status = Model.defaultStatus()
      root.artUrl = ""
    }
  }

  // ---- transport ----

  // Held optimistically so the button flips on press instead of waiting for the event,
  // then released as soon as cliamp reports the same thing or the operation fails.
  property int pendingPlaying: -1
  readonly property bool showPlaying: pendingPlaying === -1 ? isPlaying : pendingPlaying === 1

  // Never let an optimistic flip stick if cliamp disagrees.
  Timer {
    id: playHold
    interval: 2500
    repeat: false
    onTriggered: root.pendingPlaying = -1
  }

  // A transport operation reports its own failure, and the notice says what it was.
  function transport(operation, params) {
    if (submit(operation, params, function (job, err) {
      if (err.length > 0) { root.pendingPlaying = -1; root.showNotice(err) }
    })) return true
    return false
  }

  // Measured on 2.3.0: after the daemon sits idle its Spotify connection goes stale,
  // and the first play fails with "broken pipe" in cliamp.log while the job itself
  // succeeds. The second attempt plays. So a start is watched: one quiet retry, and
  // then a sentence instead of silence.
  property string _startLabel: ""
  property int _startTries: 0

  function watchStart(label) {
    _startLabel = String(label || "")
    _startTries = 0
    startWatch.restart()
  }

  Timer {
    id: startWatch
    interval: 3500
    repeat: false
    onTriggered: {
      if (root.status.state === "playing" || root.status.state === "paused") return
      if (root._startTries === 0) {
        root._startTries = 1
        root.submit("play", {}, null)
        restart()
        return
      }
      var what = root._startLabel.length > 0 ? root._startLabel : "the track"
      root.showNotice("cliamp could not start " + what + ". Press play to try again.")
    }
  }

  function playPause() {
    if (!ipcConnected) {
      if (player) player.togglePlaying()
      else showNotice("cliamp is not running")
      return
    }
    // An empty queue has nothing to play, and saying so beats a button that does nothing.
    if (!isPlaying && status.ok === true && status.state === "stopped" && total === 0) {
      showNotice("Nothing is queued. Pick a station or playlist below.")
      return
    }
    pendingPlaying = isPlaying ? 0 : 1
    playHold.restart()
    if (!isPlaying) watchStart(title)
    transport(isPlaying ? "pause" : "play")
  }

  function next() {
    if (!transport("next") && player) player.next()
  }

  function previous() {
    if (!transport("prev") && player) player.previous()
  }

  function stop() { startWatch.stop(); transport("stop") }

  function toggleShuffle() { transport("shuffle") }

  function cycleRepeat() { transport("repeat") }

  function setDevice(name) {
    if (!name) return
    transport("device", { name: String(name) })
  }

  // seek.absolute takes a position, so nothing depends on how stale the last read is.
  function seekTo(targetSec) {
    if (!canSeek) return
    var target = Math.max(0, Math.min(lengthSec, Number(targetSec) || 0))
    positionSec = target
    transport("seek.absolute", { value: target })
  }

  function seekBy(deltaSec) { seekTo(positionSec + Number(deltaSec || 0)) }

  // ---- lyrics ----

  // cliamp resolves lyrics itself, from embedded tags then LRCLIB then NetEase. The
  // lyrics operation finishes with {"ok":true,"lyrics":[{"start":30.23,"text":"..."}]},
  // and a track with no lyrics fails the job with "no lyrics found".
  property var lyrics: []
  property string lyricsTrackPath: ""
  property string lyricsPendingPath: ""

  readonly property bool hasLyrics: lyrics.length > 0
  // cliamp reports the position it has decoded to. Over A2DP the ears are about a
  // sixth of a second behind that, which is plainly visible against lyrics, so the
  // line is chosen from the position that has actually reached the sink.
  property int outputLatencyMs: 0
  readonly property int lyricTrimMs: intSetting("lyricTrimMs", 0, -1000, 1000)
  readonly property string latencyHelper: String(Qt.resolvedUrl("cliamp-output-latency")).replace("file://", "")

  function readOutputLatency() {
    if (latencyProcess.running) return
    latencyProcess.command = [latencyHelper]
    latencyProcess.running = true
  }

  Process {
    id: latencyProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.outputLatencyMs = Model.latencyMs(text)
    }
  }

  readonly property int activeLyricIndex: Model.activeLyricIndex(lyrics, positionSec - (outputLatencyMs + lyricTrimMs) / 1000)
  readonly property string activeLyric: activeLyricIndex >= 0
    ? String(lyrics[activeLyricIndex].text || "")
    : ""

  function refreshLyrics() {
    var path = String(status.path || "")
    if (path.length === 0) { lyrics = []; lyricsTrackPath = ""; return }
    if (path === lyricsTrackPath) return
    lyrics = []
    // One request outstanding at a time. The job carries no track, so the path the
    // single outstanding request was sent for is the only thing that can attribute it.
    if (lyricsPendingPath.length > 0) return
    var sent = submit("lyrics", {}, function (job, err) {
      var wanted = root.lyricsPendingPath
      root.lyricsPendingPath = ""
      if (wanted !== String(root.status.path || "")) {
        // The track changed while this was in flight. Ask again for what is playing.
        root.lyricsTrackPath = ""
        root.refreshLyrics()
        return
      }
      // A failed job is cliamp saying it has no lyrics. The track keeps its fetched
      // mark, so it is not asked again for the rest of the track.
      root.lyrics = err.length === 0 ? Model.parseLyrics(job.result) : []
    })
    if (sent) { lyricsPendingPath = path; lyricsTrackPath = path }
  }

  // A reply lost with the connection is worth asking for again, and only that case is.
  function dropLyricsRequest() {
    if (lyricsPendingPath.length === 0) return
    lyricsPendingPath = ""
    lyricsTrackPath = ""
  }

  function syncPosition() {
    if (status.ok === true) positionSec = Number(status.positionSec || 0)
    else if (player && player.positionSupported) positionSec = Number(player.position || 0)
    if (panelOpen) refreshStatus()
  }

  // cliamp's own 10 band spectrum, the same feed its first-party widget draws. visstream
  // holds one IPC connection open and emits a frame per tick. It runs only while the
  // popup is open and playing, so a shut panel costs nothing.
  property var bands: []

  Process {
    id: visProcess
    command: [root.cliampPath, "visstream", "--fps", "20"]
    running: root.panelOpen && root.isPlaying
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        var frame = Model.parseBands(line)
        if (frame.length > 0) root.bands = frame
      }
    }
    onRunningChanged: if (!running) root.bands = []
  }

  // Events carry every state change, but not the position, so the poll stays for that.
  Timer {
    id: statusTimer
    interval: root.statusIntervalMs
    repeat: true
    running: root.wantsStatus && root.ipcConnected
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: positionTimer
    interval: 250
    repeat: true
    running: root.panelOpen && root.isPlaying
    onTriggered: {
      var next = root.positionSec + interval / 1000
      // A repeat restarts the track without a track change, so the position is asked
      // for at the end rather than clamped and left stale. Asked once, because a
      // duration shorter than the audio would poll four times a second.
      if (root.lengthSec > 0 && next >= root.lengthSec) {
        if (!root._askedAtEnd) { root._askedAtEnd = true; root.refreshStatus() }
        return
      }
      root._askedAtEnd = false
      root.positionSec = next
    }
  }

  Connections {
    target: root.player
    ignoreUnknownSignals: true
    function onTrackChanged() { root.syncPosition() }
    function onPlaybackStateChanged() { root.syncPosition() }
    function onSeek() { root.syncPosition() }
  }

  onPanelOpenChanged: {
    if (!panelOpen) return
    syncPosition()
    readSinkRate()
    readOutputLatency()
    readSinkAvailability()
    readPlaylists()
    readLibrary()
    readProviders()
  }

  // ---- PipeWire routing and the signal verdict ----

  // Rebuilt from an explicit signal rather than left as a binding on values: a list
  // mutating in place does not re-evaluate the binding, so a device connected after
  // the panel loaded never appeared. Same hazard as the MPRIS player lookup.
  property var nodes: []

  function rebuildNodes() {
    nodes = Pipewire.nodes ? (Pipewire.nodes.values || []) : []
    readSinkAvailability()
  }

  Connections {
    target: Pipewire.nodes
    ignoreUnknownSignals: true
    function onValuesChanged() { root.rebuildNodes() }
  }

  property var sinkAvailability: ({})

  // Filtered through the stock helper the first-party audio panel uses, so an output
  // with nothing plugged into it is never offered as somewhere to send music.
  readonly property var sinks: {
    // Depends on nodes, which is now replaced wholesale on every change.
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream) continue
      var known = sinkAvailability[String(n.name || "")]
      if (known === false) continue
      list.push(n)
    }
    return list
  }

  function readSinkAvailability() {
    if (availabilityProcess.running) return
    availabilityProcess.running = true
  }

  Process {
    id: availabilityProcess
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sinkAvailability = Model.parseSinkAvailability(text)
    }
  }

  // cliamp reaches PipeWire through the ALSA compatibility layer, so its stream
  // announces itself as "PipeWire ALSA [cliamp]" rather than as a native client.
  readonly property var streamNode: {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !n.properties) continue
      if (String(n.properties["application.name"] || "").indexOf("cliamp") >= 0) return n
    }
    return null
  }

  readonly property var peakNode: streamNode

  // Read from the global link list rather than a PwNodeLinkTracker, which reports no
  // groups at all for this stream. Taken live rather than cached, so a sink that
  // disappears cannot leave a dead device name sitting in the panel.
  readonly property var currentSink: {
    if (!streamNode) return null
    var groups = Pipewire.linkGroups ? (Pipewire.linkGroups.values || []) : []
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      if (!g || !g.source || !g.target) continue
      if (g.source.id !== streamNode.id) continue
      // cliamp is also linked to quickshell itself for the peak meter, and that
      // tap is not a sink, so the isSink test is what keeps the route honest.
      if (g.target.isSink) return g.target
    }
    return null
  }


  readonly property string currentSinkLabel: currentSink
    ? String(currentSink.description || currentSink.nickname || currentSink.name || "")
    : ""

  readonly property int streamRate: streamNode ? Model.rateFromNodeProps(streamNode.properties) : 0
  property int sinkRate: 0

  readonly property string codec: codecFromPath(status.path)
  // A Subsonic URL is judged by whether cliamp asked for format=raw. A local file is
  // judged by its container, since nothing re-encoded it on the way in.
  readonly property bool transcoded: status.path.indexOf("/rest/stream") >= 0
    ? Model.transcodedFromPath(status.path)
    : (codec === "MP3" || codec === "OGG" || codec === "OPUS")
  // Any attenuation alters samples, so only an exact 0 dB counts. Setting volume over
  // MPRIS lands on -0.02 dB, which really is not unity and must not pass.
  readonly property bool playerUnity: Math.abs(volumeDb) < 0.001
  readonly property bool unityGain: playerUnity
    && (!hasStreamVolume || (!streamMuted && Math.abs(streamVolume - 1) < 0.001))
  readonly property bool eqFlat: status.eqFlat !== false

  // Empty for anything wired, so the lossy-link branch only fires on real Bluetooth.
  readonly property string lossyLink: currentSink
    ? Model.bluetoothCodecLabel(currentSink.properties)
    : ""

  readonly property var signalVerdict: Model.verdict({
    streamRate: streamRate,
    sinkRate: sinkRate,
    unityGain: unityGain,
    playerUnity: playerUnity,
    eqFlat: eqFlat,
    transcoded: transcoded,
    codec: codec,
    requestedRate: forcedRate,
    sourceRate: sourceRate,
    lossyLink: lossyLink
  })

  function codecFromPath(path) {
    var text = String(path || "")
    var cut = text.indexOf("?")
    if (cut >= 0) text = text.slice(0, cut)
    var dot = text.lastIndexOf(".")
    if (dot < 0) return ""
    var ext = text.slice(dot + 1).toUpperCase()
    if (ext === "MP3" || ext === "FLAC" || ext === "WAV" || ext === "ALAC"
      || ext === "OGG" || ext === "OPUS") return ext
    return ""
  }

  PwObjectTracker { objects: root.sinks }
  PwObjectTracker { objects: root.streamNode ? [root.streamNode] : [] }

  // The verdict is only ever derived from what the sink actually adopted, never from
  // the rate that was requested, because an unsupported rate silently lands on the
  // nearest one the DAC does support. No PipeWire property reports this.
  function readSinkRate() {
    if (sinkRateProcess.running) return
    sinkRateProcess.command = ["pactl", "list", "short", "sinks"]
    sinkRateProcess.running = true
  }

  Process {
    id: sinkRateProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var wanted = root.currentSink ? String(root.currentSink.name || "") : ""
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          if (wanted.length > 0 && lines[i].indexOf(wanted) < 0) continue
          var rate = Model.sinkRateFromPactl(lines[i])
          if (rate > 0) { root.sinkRate = rate; return }
        }
        root.sinkRate = 0
      }
    }
  }

  // The graph takes a moment to settle after a forced rate, so the readback waits.
  Timer {
    id: rateSettleTimer
    interval: 2000
    repeat: false
    onTriggered: { root.readSinkRate(); root.readOutputLatency() }
  }

  // ---- rate following ----

  readonly property bool followSourceRate: boolSetting("followSourceRate", true)
  property int forcedRate: 0

  function matchRate() {
    if (streamRate <= 0 || rateProcess.running) return
    if (forcedRate === streamRate) return
    rateProcess.command = ["pw-metadata", "-n", "settings", "0", "clock.force-rate", String(streamRate)]
    rateProcess.running = true
    forcedRate = streamRate
    rateSettleTimer.restart()
  }

  function releaseRate() {
    if (forcedRate === 0 || rateProcess.running) return
    rateProcess.command = ["pw-metadata", "-n", "settings", "0", "clock.force-rate", "0"]
    rateProcess.running = true
    forcedRate = 0
    rateSettleTimer.restart()
  }

  Process { id: rateProcess; command: [] }

  // Following is deliberately scoped to actual playback: a forced rate reaches every
  // application on the box, so it is released the moment the music stops.
  // One handler only: QML rejects a second onIsPlayingChanged and the whole component
  // then fails to load, which takes the widget out of the bar entirely.
  onIsPlayingChanged: {
    if (pendingPlaying !== -1 && isPlaying === (pendingPlaying === 1)) pendingPlaying = -1
    if (!followSourceRate) return
    if (isPlaying) matchRate()
    else releaseRate()
  }

  // A sink change means the old rate reading describes a device no longer in the path,
  // and the switch can happen outside this panel, so the readback is not tied to a click.
  onCurrentSinkChanged: {
    if (followSourceRate && isPlaying) matchRate()
    rateSettleTimer.restart()
  }

  onStreamRateChanged: {
    if (followSourceRate && isPlaying) matchRate()
    else rateSettleTimer.restart()
    // The node is destroyed and remade by a daemon relaunch, so this always fires
    // after one. That re-check is what settles a track change that happened while
    // the relaunch helper was still running and its change event was swallowed.
    considerNativeRate()
  }

  Component.onDestruction: releaseRate()


  // ---- actions ----

  // ---- sources: providers, their playlists and stations ----

  // The providers cliamp has configured, from provider.list. cliamp 2 has no active
  // provider, so the one being browsed is the panel's own choice and never changes
  // what plays until a row is clicked.
  property var providers: []
  property string selectedProviderKey: ""

  // Browsing starts where the music is: the provider of the loaded playlist, else
  // cliamp radio, else whatever is configured first.
  readonly property string browseProviderKey: {
    if (selectedProviderKey.length > 0 && Model.providerByKey(providers, selectedProviderKey)) return selectedProviderKey
    var playing = Model.playlistRef(status.playlist).provider
    if (playing.length > 0 && Model.providerByKey(providers, playing)) return playing
    if (Model.providerByKey(providers, "cliamp")) return "cliamp"
    return providers.length > 0 ? String(providers[0].key) : ""
  }
  readonly property var browseProvider: Model.providerByKey(providers, browseProviderKey)
  readonly property bool browseSearchable: !!(browseProvider && browseProvider.searchable)

  // Rows per provider, kept so switching tabs back and forth costs no round trip.
  property var _sourceCache: ({})
  property var sourceRows: []
  property int sourceHidden: 0
  property bool sourceBusy: false
  property string sourceError: ""

  // The filter text and the provider's own answer to it. The filter narrows the
  // listed rows at once, and a searchable provider is also asked, so a query reaches
  // albums and stations that are not in the list.
  property string sourceQuery: ""
  property var searchRows: []
  property bool searchBusy: false
  property int _searchSeq: 0

  readonly property var visibleSourceRows: searchRows.concat(Model.filterRows(sourceRows, sourceQuery))
  readonly property int activeSourceIndex: Model.activeRowIndex(visibleSourceRows, status, soloPath)
  property string soloPath: ""

  // The row a click is loading. The latest click owns it, so a stale answer to an
  // earlier click can neither clear it nor report an error over it.
  property string loadingKey: ""

  onBrowseProviderKeyChanged: showProvider(browseProviderKey)

  function readProviders() {
    submit("provider.list", {}, function (job, err) {
      if (err.length > 0) return
      root.providers = Model.parseProviders(job.result)
    })
  }

  function selectProvider(key) {
    var k = String(key || "")
    if (k.length === 0) return
    selectedProviderKey = k
    if (k === browseProviderKey) showProvider(k)
  }

  function showProvider(key) {
    searchRows = []
    sourceError = ""
    var cached = _sourceCache[key]
    if (cached) {
      sourceRows = cached.rows
      sourceHidden = cached.hidden
    } else {
      sourceRows = []
      sourceHidden = 0
    }
    if (!cached) refreshSource(key)
    if (sourceQuery.length > 0) searchSources(sourceQuery)
  }

  // A catalog provider such as Radio pages its directory under provider.catalog, which
  // also carries its playlists. The others list playlists only.
  function refreshSource(key) {
    var k = String(key || browseProviderKey)
    if (k.length === 0) return
    var provider = Model.providerByKey(providers, k)
    var op = provider && provider.catalog ? "provider.catalog" : "provider.playlists"
    if (k === browseProviderKey) { sourceBusy = true; sourceError = "" }
    submit(op, { provider: k, limit: 200 }, function (job, err) {
      if (k === root.browseProviderKey) root.sourceBusy = false
      if (err.length > 0) {
        if (k === root.browseProviderKey) root.sourceError = err
        return
      }
      var parsed = Model.parseSourceRows(job.result, k)
      var cache = root._sourceCache
      cache[k] = parsed
      if (k !== root.browseProviderKey) return
      root.sourceRows = parsed.rows
      root.sourceHidden = parsed.hidden
    })
  }

  // Every keystroke gets its own search, and only the newest answer is shown. A search
  // in flight never blocks the next one, so the list always ends on what was typed.
  function searchSources(query) {
    sourceQuery = String(query || "")
    var q = sourceQuery.trim()
    var seq = ++_searchSeq
    if (q.length < 2 || !browseSearchable) { searchRows = []; searchBusy = false; return }
    var key = browseProviderKey
    searchBusy = true
    submit("provider.search", { provider: key, query: q, limit: 30 }, function (job, err) {
      if (seq !== root._searchSeq) return
      root.searchBusy = false
      if (err.length > 0) { root.searchRows = []; root.sourceError = err; return }
      root.searchRows = Model.parseSearchRows(job.result, key)
    })
  }

  function playSource(row) {
    var req = Model.playRequest(row)
    if (!req) return
    var key = Model.rowKey(row)
    var name = String(row.name || "")
    loadingKey = key
    sourceError = ""
    submit(req.operation, req.params, function (job, err) {
      if (root.loadingKey !== key) return
      root.loadingKey = ""
      if (err.length > 0) { root.sourceError = "Could not play " + name + ". " + err; return }
      root.soloPath = req.operation === "track.play" ? String(row.id || "") : ""
      if (Model.loadedNothing(job)) { root.sourceError = name + " has no tracks to play."; return }
      root.watchStart(name)
    })
  }

  // Channel up and down. While a click is still loading, the step counts from that row,
  // so pressing twice quickly moves two rows instead of repeating the first.
  function stepSource(delta) {
    var rows = visibleSourceRows
    var from = activeSourceIndex
    if (loadingKey.length > 0) {
      for (var i = 0; i < rows.length; i++) {
        if (Model.rowKey(rows[i]) === loadingKey) { from = i; break }
      }
    }
    var to = Model.adjacentRowIndex(rows.length, from, delta)
    if (to < 0) return
    playSource(rows[to])
  }

  // ---- library: Navidrome and saved playlists ----

  property var playlists: []
  property var results: []
  property string libraryQuery: ""
  property bool libraryBusy: false

  // Server rows on their own. Saved playlists are matched locally and merged in front,
  // so a playlist list arriving late does not need a second server round trip.
  property var _libraryRows: []

  readonly property string libraryHelper: String(Qt.resolvedUrl("cliamp-library")).replace("file://", "")

  function _recomputeResults() {
    results = Model.matchPlaylists(playlists, libraryQuery).concat(_libraryRows)
  }

  // The query this helper run was dispatched for, so a keystroke that arrives while
  // one is in flight is not silently dropped and does not leave stale rows on screen.
  property string _dispatchedQuery: ""

  // The library is browsed straight off the Subsonic server using the token cliamp
  // already published, so picking something never has to stop the daemon.
  function readLibrary() { _dispatchLibrary() }

  function search(query) {
    libraryQuery = String(query || "")
    _recomputeResults()
    _dispatchLibrary()
  }

  // One dispatcher, so a refresh cannot quietly replace an active search with the
  // full album list while the playlist rows are still filtered by the query.
  function _dispatchLibrary() {
    if (albumProcess.running) return
    _dispatchedQuery = libraryQuery
    libraryBusy = true
    albumProcess.command = libraryQuery.length > 0
      ? [libraryHelper, "search", libraryQuery]
      : [libraryHelper, "albums", "200"]
    albumProcess.running = true
  }

  function playResult(item) {
    if (!item) return
    if (item.kind === "playlist") { loadPlaylist(String(item.name)); return }
    if (albumPlayProcess.running || !item.id) return
    albumPlayProcess.command = [libraryHelper,
      item.kind === "song" ? "play-song" : "play", String(item.id)]
    albumPlayProcess.running = true
  }

  Process {
    id: albumProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root._libraryRows = Model.parseResults(text)
        root._recomputeResults()
      }
    }
    onExited: {
      root.libraryBusy = false
      if (root._dispatchedQuery !== root.libraryQuery) root._dispatchLibrary()
    }
  }

  Process {
    id: albumPlayProcess
    command: []
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim().length > 0) root.showNotice(Model.elideError(text))
    }
    onExited: settleTimer.restart()
  }

  function readPlaylists() {
    if (playlistProcess.running) return
    playlistProcess.command = [cliampPath, "playlist", "list"]
    playlistProcess.running = true
  }

  Process {
    id: playlistProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.playlists = Model.parsePlaylists(text)
        root._recomputeResults()
      }
    }
  }

  // Loading a saved playlist is the only way a headless daemon can reach a Navidrome
  // library: the playlist keeps resolved stream URLs, and the browser is TUI only.
  // Measured: load starts playing on its own, so nothing follows it here. "Recently
  // Played" loads the same way, and its first entry is the most recent track.
  function loadPlaylist(name) {
    if (!name) return
    var label = String(name)
    submit("load", { playlist: label }, function (job, err) {
      if (err.length > 0) { root.showNotice("Could not load " + label + ". " + err); return }
      if (Model.loadedNothing(job)) { root.showNotice(label + " has no tracks to play."); return }
      root.watchStart(label)
    })
  }

  // Volume is cliamp's PipeWire stream volume, moved exactly the way the stock audio
  // panel moves a sink: a property on a tracked node, pushed both ways, so a drag has
  // no subprocess and no poll behind it to fight. cliamp's own gain stays at unity.
  readonly property real streamVolume: streamNode && streamNode.audio ? streamNode.audio.volume : 0
  readonly property bool streamMuted: !!(streamNode && streamNode.audio && streamNode.audio.muted)
  readonly property bool hasStreamVolume: !!(streamNode && streamNode.audio)

  // A level the operator sets is one they expect to hear, so setting one clears mute.
  function setStreamVolume(value) {
    if (!streamNode || !streamNode.audio) return
    streamNode.audio.muted = false
    streamNode.audio.volume = Math.max(0, Math.min(1, Number(value) || 0))
  }

  // cliamp cannot attach to a running instance, so the helper stops the daemon for
  // the life of the terminal session and starts it again afterwards. Without that,
  // opening the player spawns a second copy that the panel cannot see.
  property int sourceRate: 0

  readonly property bool followNativeRate: boolSetting("followNativeRate", false)
  readonly property string nativeRateHelper: String(Qt.resolvedUrl("cliamp-daemon-rate-apply")).replace("file://", "")
  // The rate already asked for, so an output the hardware or cliamp refuses is not
  // requested again in a loop on every status poll.
  property int attemptedNativeRate: 0
  readonly property string sourceRateHelper: String(Qt.resolvedUrl("cliamp-source-rate")).replace("file://", "")

  // Resolved per track, because cliamp exposes no source rate of its own.
  property string sourceRateTrackPath: ""

  function readSourceRate() {
    if (sourceRateProcess.running) return
    var path = String(status.path || "")
    if (path.length === 0) { sourceRate = 0; sourceRateTrackPath = ""; return }
    // Status is reassigned on every poll, so without this the helper queried the
    // server every couple of seconds for a rate that only changes with the track.
    if (path === sourceRateTrackPath) return
    sourceRateTrackPath = path
    sourceRateProcess.command = [sourceRateHelper, path]
    sourceRateProcess.running = true
  }

  Process {
    id: sourceRateProcess
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = parseInt(String(text || "").trim(), 10)
        root.sourceRate = isFinite(value) && value > 0 ? value : 0
      }
    }
  }

  // One handler only. A second onStatusChanged in this object is "Property value set
  // multiple times", which fails the whole Service and removes the widget from the bar.
  onStatusChanged: {
    if (!wantsStatus) return
    readSourceRate()
    // Nobody reads lyrics behind a shut panel, so that half stays panel only.
    if (panelOpen) refreshLyrics()
  }

  // Relaunching cliamp is the only way to change its output rate, so this is gated
  // hard: only while the daemon itself is what is running, only when the file really
  // differs, and never twice for the same rate.
  onSourceRateChanged: considerNativeRate()

  function considerNativeRate() {
    if (!followNativeRate) return
    if (nativeRateProcess.running) return
    if (sourceRate <= 0 || streamRate <= 0) return
    if (Math.abs(sourceRate - streamRate) <= 1) { attemptedNativeRate = 0; return }
    // 88.2 and 176.4 kHz are not accepted output rates, so relaunching would land on
    // the default and gap the audio for nothing.
    if (!Model.isSupportedOutputRate(sourceRate)) return
    if (attemptedNativeRate === sourceRate) return
    attemptedNativeRate = sourceRate
    nativeRateProcess.command = [nativeRateHelper, String(sourceRate)]
    nativeRateProcess.running = true
  }

  Process {
    id: nativeRateProcess
    command: []
    // Re-check on exit as well: a track change during the relaunch is swallowed by
    // the running guard, and the stream node can settle before or after this exit,
    // so both this and onStreamRateChanged re-evaluate and the guards dedupe them.
    onExited: { settleTimer.restart(); root.considerNativeRate() }
  }

  // No socket handover any more. cliamp allows one instance per user, so this is only
  // ever offered when nothing owns the socket, and the in panel library removes the
  // reason to open a terminal player at all.
  function openPlayer() {
    if (running) return
    Quickshell.execDetached(["uwsm-app", "--", "foot", "--title=cliamp", cliampPath])
  }

  // The menu's Open TUI entry, offered only while the daemon is stopped, because the
  // TUI is what starts it.
  function openTui() {
    if (tuiProcess.running) return
    tuiProcess.command = ["foot", "-e", cliampPath]
    tuiProcess.running = true
  }

  // The menu is the only way to stop or restart the headless daemon from the bar, so
  // the unit goes through its own one-shot process and the poll re-reads on exit.
  readonly property string systemctlPath: "/usr/bin/systemctl"

  function quitDaemon() {
    if (sysProcess.running) return
    sysProcess.command = [systemctlPath, "--user", "stop", "cliamp-daemon"]
    sysProcess.running = true
  }

  function restartDaemon() {
    if (sysProcess.running) return
    sysProcess.command = [systemctlPath, "--user", "restart", "cliamp-daemon"]
    sysProcess.running = true
  }

  Process {
    id: sysProcess
    command: []
    onExited: settleTimer.restart()
  }

  Process {
    id: tuiProcess
    command: []
    onExited: settleTimer.restart()
  }

  // A helper or a unit change takes a moment to land, so the panel re-reads rather
  // than guessing. Operations need none of this: their job carries the new snapshot.
  Timer {
    id: settleTimer
    interval: 400
    repeat: false
    onTriggered: {
      root.refreshStatus()
      root.readSinkRate()
    }
  }
}
