import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Stream.js" as Stream

// oma-stream control panel: per-platform ingest config, capture settings,
// and one button that starts or stops every enabled stream at once.
//
// Config lives in ~/.config/omastream/config.json — URLs and toggles only.
// Stream keys NEVER touch disk: they are stored in the Secret Service
// keyring (secret-tool) under service=omastream username=<platform>, and
// read back over stdin-safe IPC at go-live.
//
// Streaming is delegated to gpu-screen-recorder — one process per platform.
Panel {
  id: root
  moduleName: "user.omastream"
  ipcTarget: "user.omastream"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Configuration ------------------------------------------------------
  // Deliberately secret-free: only toggles, URLs, and capture settings.
  property var cfg: ({
    fps: 60,
    quality: "medium",
    audio: "default_output",
    capture: "screen",
    scene: "screen",
    cameraDevice: "/dev/video0",
    pipXPct: 72,
    pipYPct: 62,
    pipSizePct: 22,
    twitch:  { enabled: true,  url: "rtmps://ingest.global-contribute.live-video.net/app" },
    youtube: { enabled: true,  url: "rtmps://a.rtmps.youtube.com:443/live2" },
    x:       { enabled: false, url: "" }
  })

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omastream/config.json"

  // Detected cameras (friendly names); ids are /dev paths usable by gsr+mpv.
  MediaDevices { id: mediaDevs }
  readonly property var cameras: mediaDevs.videoInputs || []
  readonly property string cameraName: {
    var want = String(cfg.cameraDevice || "")
    for (var i = 0; i < cameras.length; i++)
      if (String(cameras[i].id) === want) return String(cameras[i].description)
    return ""
  }
  function selectCamera(description) {
    for (var i = 0; i < cameras.length; i++)
      if (String(cameras[i].description) === description) {
        updateGlobal({ cameraDevice: String(cameras[i].id) })
        return
      }
  }

  function entryFor(id) {
    var meta = Stream.platform(id)
    return cfg[id] || { enabled: false, url: meta ? meta.defaultUrl : "" }
  }

  function updateEntry(id, patch) {
    var entry = Object.assign({}, entryFor(id), patch)
    var next = Object.assign({}, cfg)
    next[id] = entry
    cfg = next
    saveCfg()
  }

  function updateGlobal(patch) {
    cfg = Object.assign({}, cfg, patch)
    saveCfg()
  }

  function applyConfig(raw) {
    var loaded
    try { loaded = JSON.parse(raw) } catch (e) { return }
    if (!loaded || typeof loaded !== "object") return
    var next = Object.assign({}, cfg)
    ;["fps", "quality", "audio", "capture", "scene", "cameraDevice",
      "pipXPct", "pipYPct", "pipSizePct"].forEach(function(k) {
      if (loaded[k] !== undefined) next[k] = loaded[k]
    })
    Stream.platforms().forEach(function(p) {
      if (loaded[p.id] && typeof loaded[p.id] === "object") {
        // Any legacy plaintext "key" found here is ignored and dropped on
        // the next save — keys belong in the keyring, not this file.
        var url = String(loaded[p.id].url || "")
        // Migrate superseded defaults (e.g. YouTube legacy RTMP) up to the
        // current OBS-style default so old configs get encrypted ingests.
        var meta = Stream.platform(p.id)
        if (meta && url !== "" && meta.legacyUrls.indexOf(url) !== -1) url = meta.defaultUrl
        next[p.id] = {
          enabled: loaded[p.id].enabled === true,
          url: url
        }
      }
    })
    cfg = next
  }

  function saveCfg() {
    // Written through a child process instead of FileView.writeAdapter():
    // the config is plain text (no structured adapter), the content travels
    // via env — never argv — and permissions are kept exact.
    saveProc.payload = JSON.stringify(cfg, null, 2)
    saveProc.running = true
  }

  Process {
    id: saveProc
    property string payload: ""
    environment: ({
      OMASTREAM_CFG: payload,
      OMASTREAM_CFG_PATH: root.configPath
    })
    command: ["bash", "-c",
      'printf "%s" "$OMASTREAM_CFG" > "$OMASTREAM_CFG_PATH" && chmod 600 "$OMASTREAM_CFG_PATH"']
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    printErrors: false
    onLoaded: root.applyConfig(text())
    // Missing file on first run: defaults stay, first save creates it.
    onLoadFailed: { /* keep defaults */ }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    refreshKeyPresence()
  }

  // ---- Scenes / webcam overlay --------------------------------------------
  // "screen": capture desktop · "camera": capture webcam only ·
  // "pip": draggable always-on-top mpv window showing the webcam, captured
  // as part of the screen — OBS-style overlay arrangement by dragging.
  property var goLiveIds: []
  readonly property string scene: String(cfg.scene || "screen")
  readonly property string effectiveCapture: scene === "camera"
    ? String(cfg.cameraDevice || "/dev/video0")
    : "screen"

  function buildCamOverlayArgs() {
    // Percent offsets mirror the monitor's tile position: mpv measures them
    // against screen size minus window size, same as our canvas math.
    var xp = Math.round(Number(cfg.pipXPct) || 72)
    var yp = Math.round(Number(cfg.pipYPct) || 62)
    var size = Math.round(Number(cfg.pipSizePct) || 22)
    return [
      "mpv",
      "--ontop", "--border=no", "--mute=yes",
      "--autofit=" + size + "%",
      "--geometry=" + xp + "%+" + yp + "%",
      "--title=omastream-camera",
      // av://v4l2: prefix — mpv won't autodetect a raw v4l2 device node.
      "av://v4l2:" + String(cfg.cameraDevice || "/dev/video0")
    ]
  }

  function toggleCamPreview() {
    lastError = ""
    if (camOverlay.running) {
      camOverlay.running = false
      camPreviewOn = false
    } else {
      camOverlay.command = buildCamOverlayArgs()
      camOverlay.running = true
    }
  }

  property bool camPreviewOn: false

  Process {
    id: camOverlay
    onExited: root.camPreviewOn = false
  }

  Timer {
    id: pipDelay
    interval: 2000
    repeat: false
    onTriggered: {
      if (root.goLiveIds.length > 0) root.startLookupPhase()
      else root.lastError = "Stream cancelled."
    }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.config/omastream"]
  }

  // ---- Keyring storage ----------------------------------------------------
  // Attributes: service=omastream username=<platform>. Secrets cross the
  // boundary via stdin, never argv.
  property var keyPresent: ({ twitch: false, youtube: false, x: false })

  function refreshKeyPresence() {
    twitchLookup.startLookup("check")
    youtubeLookup.startLookup("check")
    xLookup.startLookup("check")
  }

  function storeKey(id, secret) {
    if (secret === "") {
      // Empty field committed means "forget this key".
      keyClear.command = ["secret-tool", "clear", "service", "omastream", "username", id]
      keyClear.running = true
      var p1 = Object.assign({}, keyPresent); p1[id] = false; keyPresent = p1
      return
    }
    keyStore.targetId = id
    keyStore.secret = secret
    keyStore.command = [
      "secret-tool", "store", "--label=oma-stream " + id,
      "service", "omastream", "username", id
    ]
    keyStore.running = true
    var p2 = Object.assign({}, keyPresent); p2[id] = true; keyPresent = p2
  }

  Process {
    id: keyStore
    property string targetId: ""
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  Process {
    id: keyClear
    command: ["true"]
  }

  // ---- Twitch ingest picker ----------------------------------------------
  // Queries the same public feed OBS uses and pins the lowest-latency
  // online ingest into the Twitch URL field.
  property string ingestStatus: ""

  function pickTwitchIngest() {
    root.lastError = ""
    root.ingestStatus = "Measuring Twitch ingests…"
    twitchIngestProc.running = true
  }

  function applyTwitchIngests(raw) {
    var best = Stream.bestTwitchIngest(raw)
    if (best === null) {
      root.ingestStatus = ""
      root.lastError = "Could not reach the Twitch ingest feed; keeping the auto-router URL."
      return
    }
    root.updateEntry("twitch", { url: best.url })
    root.ingestStatus = "Pinned: " + best.name
  }

  Process {
    id: twitchIngestProc
    command: ["curl", "-s", "--max-time", "8", "https://ingest.twitch.tv/ingests"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyTwitchIngests(String(text || ""))
    }
  }

  // Generic per-platform lookup process: doubles as a presence check
  // (mode "check") and as the fetch phase of go-live (mode "launch").
  component KeyLookup: Process {
    id: lookup
    required property string platformId
    property string mode: ""

    function startLookup(m) {
      mode = m
      command = ["secret-tool", "lookup", "service", "omastream", "username", platformId]
      running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lookupText(lookup.platformId, lookup.mode, String(text || "").trim())
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") root.lookupError(lookup.platformId, t)
      }
    }
    onExited: function(code) { root.lookupDone(lookup.platformId, lookup.mode, code) }
  }

  KeyLookup { id: twitchLookup;  platformId: "twitch" }
  KeyLookup { id: youtubeLookup; platformId: "youtube" }
  KeyLookup { id: xLookup;       platformId: "x" }

  // Results land here during both modes; see lookupText/lookupDone.
  property var fetchedKeys: ({})
  // Launch-phase bookkeeping: which platforms we're waiting on, how many
  // lookups haven't finished yet, whether any lookup failed.
  property var launchState: null

  function lookupText(platformId, mode, value) {
    fetchedKeys[platformId] = value
    if (mode === "check") {
      var p = Object.assign({}, keyPresent); p[platformId] = value !== ""; keyPresent = p
    }
    tryLaunch()
  }

  function lookupError(platformId, message) {
    if (launchState !== null) {
      var s = Object.assign({}, launchState)
      s.failed = true
      s.err = (s.err !== "" ? s.err + "\n" : "") + message.split("\n")[0]
      launchState = s
    }
  }

  function lookupDone(platformId, mode, code) {
    if (mode !== "launch" || launchState === null) return
    var s = Object.assign({}, launchState)
    // exit 1 from `secret-tool lookup` means "not found" — an empty result
    // (platform gets skipped later), not a failure. Anything else is.
    if (code > 1) {
      s.failed = true
      s.err = (s.err !== "" ? s.err + "\n" : "") +
              "Could not read keyring for " + platformId + " (exit " + code + "). Is secret-tool available?"
    }
    s.pending = s.pending - 1
    launchState = s
    tryLaunch()
  }

  function tryLaunch() {
    var s = launchState
    if (s === null) return
    if (s.failed) {
      if (s.err !== "") root.lastError = s.err
      launchState = null
      return
    }
    if (s.pending > 0) return // lookups still in flight
    launchState = null

    // Platforms without a keyring entry are skipped, not fatal — one
    // unconfigured platform must not block the others.
    var launching = []
    var skipped = []
    s.ids.forEach(function(id) {
      if (String(fetchedKeys[id] || "") !== "") launching.push(id)
      else skipped.push(Stream.platform(id).label)
    })

    if (launching.length === 0) {
      root.lastError = "No stream keys found in the keyring for: " + s.ids.map(function(id) { return Stream.platform(id).label }).join(", ") + "."
      return
    }

    root.stopping = false
    root.startedAt = new Date()
    launching.forEach(function(id) {
      var proc = procFor(id)
      proc.command = Stream.buildArgs(cfg, Stream.targetUrl(entryFor(id)), fetchedKeys[id], id, root.effectiveCapture)
      proc.running = true
    })
    if (skipped.length > 0)
      root.lastError = "Skipped (no key in keyring): " + skipped.join(", ")
  }

  // ---- Live state ---------------------------------------------------------
  readonly property bool live: twitchProc.running || youtubeProc.running || xProc.running
  readonly property int activeCount: (twitchProc.running ? 1 : 0) + (youtubeProc.running ? 1 : 0) + (xProc.running ? 1 : 0)
  readonly property int readyCount: Stream.platforms().filter(function(p) { return Stream.isReady(entryFor(p.id)) }).length

  property date startedAt: new Date()
  property string elapsedText: "00:00"
  property string lastError: ""
  // Set while an intentional stop is in flight so exits don't read as errors.
  property bool stopping: false

  Timer {
    id: elapsedTimer
    interval: 1000
    repeat: true
    running: root.live
    triggeredOnStart: true
    onTriggered: root.elapsedText = Stream.formatElapsed(Date.now() - root.startedAt.getTime())
  }

  function toggleStream() {
    if (root.live) stopAll()
    else goLive()
  }

  function goLive() {
    root.lastError = ""
    var missing = []
    var ids = []

    Stream.platforms().forEach(function(p) {
      var entry = entryFor(p.id)
      if (!entry.enabled) return
      if (!Stream.isReady(entry)) { missing.push(p.label); return }
      ids.push(p.id)
    })

    console.log("[omastream] goLive: ids=" + JSON.stringify(ids) + " missing=" + JSON.stringify(missing))
    if (missing.length > 0) {
      root.lastError = "Missing ingest URL for: " + missing.join(", ")
      return
    }
    if (ids.length === 0) {
      root.lastError = "No platforms enabled."
      return
    }

    root.goLiveIds = ids

    // PiP: raise the overlay window first and give it a moment to appear,
    // so the capture opens with the camera already in frame.
    if (root.scene === "pip" && !camOverlay.running) {
      camOverlay.command = buildCamOverlayArgs()
      camOverlay.running = true
      pipDelay.restart()
      return
    }
    startLookupPhase()
  }

  function startLookupPhase() {
    // Fetch keys out of the keyring first; streams start once every lookup
    // has come back (see tryLaunch).
    fetchedKeys = {}
    launchState = { ids: goLiveIds, pending: goLiveIds.length, failed: false, err: "" }
    goLiveIds.forEach(function(id) { procForLookup(id).startLookup("launch") })
  }

  function stopAll() {
    if (!root.live) return
    root.stopping = true
    twitchProc.running = false
    youtubeProc.running = false
    xProc.running = false
  }

  function procFor(id) {
    if (id === "twitch") return twitchProc
    if (id === "youtube") return youtubeProc
    return xProc
  }

  function procForLookup(id) {
    if (id === "twitch") return twitchLookup
    if (id === "youtube") return youtubeLookup
    return xLookup
  }

  function handleExit(exitCode) {
    if (root.stopping) {
      if (!root.live) root.stopping = false
      return
    }
    if (exitCode === 0) return
    // Give the stderr collector's onStreamFinished a beat to land first so
    // the panel shows gsr's actual complaint, not just an exit code.
    Qt.callLater(function() {
      if (!root.live) {
        root.lastError = root.lastStreamStderr !== ""
          ? root.lastStreamStderr
          : "A stream ended unexpectedly (exit " + exitCode + ")."
      }
    })
  }

  // Last stderr line from any stream process; read by handleExit after the
  // collector has flushed (exit and stream-finished have no guaranteed order,
  // so the generic exit path defers to whatever stderr landed).
  property string lastStreamStderr: ""

  component StreamProcess: Process {
    id: streamProc
    required property string platformId
    stdout: StdioCollector {}
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") {
          console.log("[omastream] " + streamProc.platformId + " stderr:\n" + t)
          root.lastStreamStderr = Stream.pickErrorLine(t)
        }
      }
    }
    onExited: function(code) {
      console.log("[omastream] " + platformId + " exited code=" + code)
      root.handleExit(code)
    }
  }

  StreamProcess { id: twitchProc;  platformId: "twitch" }
  StreamProcess { id: youtubeProc; platformId: "youtube" }
  StreamProcess { id: xProc;       platformId: "x" }

  // ---- Chrome -------------------------------------------------------------
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(contentForeground, 1.55)
  readonly property color liveColor: urgent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function open() {
    refreshKeyPresence()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    root.setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // ---- Content ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(1000))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: contentColumn.implicitHeight
      interactive: contentHeight > height

      Column {
        id: contentColumn
        width: scroll.width
        spacing: Style.space(12)

        property int tabPage: 0

        // All pages share the tallest page's height so the panel never
        // resizes itself when you switch tabs.
        readonly property real tabPageHeight: Math.max(
          streamPage.implicitHeight,
          platformsPage.implicitHeight,
          previewPage.implicitHeight)

        // Header: name on the left, status on the right.
        Item {
          width: parent.width
          implicitHeight: headerText.implicitHeight

          Text {
            id: headerText
            anchors.left: parent.left
            text: "OMASTREAM"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1.5
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: headerText.verticalCenter
            text: root.live
              ? "● LIVE " + root.elapsedText + " · " + root.activeCount + " UP"
              : (root.readyCount > 0 ? "READY · " + root.readyCount + " CONFIGURED" : "OFFLINE")
            color: root.live ? root.liveColor : root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }
        }

        // Tabs: STREAM = scene + capture · PLATFORMS = per-service setup
        Row {
          spacing: Style.space(6)

          Button {
            text: "STREAM"
            selected: contentColumn.tabPage === 0
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: contentColumn.tabPage = 0
          }

          Button {
            text: "PLATFORMS"
            selected: contentColumn.tabPage === 1
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: contentColumn.tabPage = 1
          }

          Button {
            text: "PREVIEW"
            selected: contentColumn.tabPage === 2
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: contentColumn.tabPage = 2
          }
        }

        // ---- Page 0: stream settings ------------------------------------
        Column {
          id: streamPage
          visible: contentColumn.tabPage === 0
          height: contentColumn.tabPageHeight
          width: parent.width
          spacing: Style.space(12)

        // Scene selection: what the stream shows.
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "SCENE"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Row {
            spacing: Style.space(6)

            Repeater {
              model: [
                { id: "screen", label: "🖥 SCREEN" },
                { id: "pip",    label: "🖥+🎥 PIP" },
                { id: "camera", label: "🎥 WEBCAM" }
              ]

              Button {
                required property var modelData
                text: modelData.label
                selected: root.scene === modelData.id
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.updateGlobal({ scene: modelData.id })
              }
            }
          }

          Column {
            visible: root.scene !== "screen"
            width: parent.width
            spacing: Style.space(8)

            Dropdown {
              width: parent.width
              label: visible && root.cameras.length > 0 ? "" : ""
              showLabel: false
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              options: root.cameras.length > 0
                ? root.cameras.map(function(d) { return String(d.description) })
                : ["No cameras detected"]
              value: root.cameraName !== "" ? root.cameraName : (root.cameras.length > 0 ? "Select camera" : "No cameras detected")
              enabled: root.cameras.length > 0
              onChanged: function(desc) { root.selectCamera(desc) }
            }

            Text {
              width: parent.width
              text: root.cameras.length > 0
                ? "Streams via " + String(cfg.cameraDevice)
                : "No webcam detected — plug one in and reopen the panel."
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              visible: root.scene === "pip"
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(64)
                text: "CAM SIZE"
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: [
                  { v: 15, label: "S" }, { v: 22, label: "M" }, { v: 30, label: "L" }
                ]

                Button {
                  required property var modelData
                  text: modelData.label
                  selected: Number(cfg.pipSizePct) === modelData.v
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.updateGlobal({ pipSizePct: modelData.v })
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Drag the camera on the monitor to place it."
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              visible: root.scene === "pip"
              spacing: Style.space(10)

              Button {
                text: root.camPreviewOn ? "■ CLOSE CAMERA PREVIEW" : "◎ PREVIEW & ARRANGE CAMERA"
                selected: root.camPreviewOn
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.toggleCamPreview()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(300)
                text: root.camPreviewOn
                  ? "Drag the camera window anywhere — it streams as-is."
                  : "Opens a draggable always-on-top camera window."
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // Capture settings.
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "CAPTURE"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Row {
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(64)
              text: "FPS"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              text: "30"
              selected: Number(root.cfg.fps) === 30
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.updateGlobal({ fps: 30 })
            }

            Button {
              text: "60"
              selected: Number(root.cfg.fps) === 60
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.updateGlobal({ fps: 60 })
            }
          }

          Row {
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(64)
              text: "QUALITY"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: ["low", "medium", "high"]

              Button {
                required property string modelData
                text: modelData
                selected: String(root.cfg.quality) === modelData
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.updateGlobal({ quality: modelData })
              }
            }
          }

          TextField {
            width: parent.width
            foreground: root.contentForeground
            text: String(cfg.audio)
            placeholderText: 'Audio source (gpu-screen-recorder, e.g. "default_output")'
            onEditingFinished: root.updateGlobal({ audio: text.trim() })
          }

          TextField {
            width: parent.width
            foreground: root.contentForeground
            text: String(cfg.capture)
            placeholderText: 'Capture target ("screen", monitor name, "portal", …)'
            onEditingFinished: root.updateGlobal({ capture: text.trim() })
          }
        }
        }

        // ---- Page 1: platforms ------------------------------------------
        Column {
          id: platformsPage
          visible: contentColumn.tabPage === 1
          height: contentColumn.tabPageHeight
          width: parent.width
          spacing: Style.space(12)

        // One block per platform.
        Repeater {
          model: Stream.platforms()

          Column {
            id: platformBlock
            required property var modelData
            width: parent.width
            spacing: Style.space(8)

            readonly property var entry: root.entryFor(modelData.id)
            // Only commit the key field when the user actually typed.
            property bool keyDirty: false
            readonly property bool hasKey: root.keyPresent[modelData.id] === true
            readonly property bool streaming: root.live && entry.enabled === true &&
                                              (modelData.id === "twitch" ? twitchProc.running :
                                               modelData.id === "youtube" ? youtubeProc.running : xProc.running)

            Item {
              width: parent.width
              implicitHeight: Math.max(platformLabel.implicitHeight, platformSwitch.implicitHeight)

              Rectangle {
                id: statusDot
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(7)
                height: width
                radius: width / 2
                color: streaming ? root.liveColor : (parent.parent.enabled ? root.dim : "transparent")
                border.width: 1
                border.color: root.dim
              }

              Text {
                id: platformLabel
                anchors.left: statusDot.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label.toUpperCase()
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1.2
              }

              ToggleSwitch {
                id: platformSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: platformBlock.entry.enabled
                foreground: root.contentForeground
                onToggled: root.updateEntry(platformBlock.modelData.id, { enabled: !root.entryFor(platformBlock.modelData.id).enabled })
              }
            }

            TextField {
              width: parent.width
              foreground: root.contentForeground
              text: platformBlock.entry.url
              placeholderText: platformBlock.modelData.id === "x"
                ? "rtmp://<region>.pscp.tv:80/x — from X Producer"
                : "RTMP(S) ingest URL"
              onEditingFinished: {
                if (platformBlock.modelData.id === "twitch") root.ingestStatus = ""
                root.updateEntry(platformBlock.modelData.id, { url: text.trim() })
              }
            }

            // Twitch-only: one-click lowest-latency ingest selection, same
            // feed OBS queries.
            Row {
              visible: platformBlock.modelData.id === "twitch"
              spacing: Style.space(8)

              Button {
                text: "◎ PICK FASTEST INGEST"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.pickTwitchIngest()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.ingestStatus
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            TextField {
              id: keyField
              width: parent.width
              foreground: root.contentForeground
              password: true
              // Programmatic clears (after commit) must not count as edits.
              property bool clearing: false
              // Auto-store shortly after typing stops — no Enter required.
              Timer {
                id: storeDebounce
                interval: 700
                onTriggered: root.storeKey(platformBlock.modelData.id, keyField.text.trim())
              }
              placeholderText: platformBlock.hasKey
                ? "●●●●●● stored in system keyring — type to replace, clear to delete"
                : "Paste stream key → stored in system keyring (not on disk)"
              onTextChanged: {
                if (!clearing) {
                  platformBlock.keyDirty = true
                  storeDebounce.restart()
                }
              }
              onEditingFinished: {
                if (!platformBlock.keyDirty) return
                storeDebounce.stop()
                var secret = text.trim()
                platformBlock.keyDirty = false
                clearing = true
                text = ""
                clearing = false
                root.storeKey(platformBlock.modelData.id, secret)
              }
            }
          }
        }
        }



          // ---- Page 2: program monitor -------------------------------------
          Column {
            id: previewPage
            visible: contentColumn.tabPage === 2
            height: contentColumn.tabPageHeight
            width: parent.width
            spacing: Style.space(8)

            Monitor {
              width: parent.width
              scene: root.scene
              streaming: root.live
              elapsedText: root.elapsedText
              pipXPct: Number(cfg.pipXPct) || 72
              pipYPct: Number(cfg.pipYPct) || 62
              pipSizePct: Number(cfg.pipSizePct) || 22
              cameraDeviceId: String(cfg.cameraDevice || "")
              fg: root.contentForeground
              fontFamily: root.contentFontFamily
              onPlacementChanged: function(xp, yp) { root.updateGlobal({ pipXPct: xp, pipYPct: yp }) }
            }

            Text {
              width: parent.width
              text: root.scene === "pip"
                ? "Drag the camera tile to place it · size presets in the STREAM tab"
                : "Switch to 🖥+🎥 PIP to arrange your camera here."
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

        // Error / status line.
        Text {
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // The single action: starts or stops every enabled platform.
        Button {
          width: parent.width
          leftAlign: true
          text: root.live ? "■ STOP STREAMING" : "● GO LIVE — ALL PLATFORMS"
          selected: root.live
          foreground: root.contentForeground
          accent: root.liveColor
          fontFamily: root.contentFontFamily
          onClicked: root.toggleStream()
        }

        Text {
          width: parent.width
          text: "Keys: Secret Service keyring (service=omastream) · Streams: gpu-screen-recorder"
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
