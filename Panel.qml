import QtQuick
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
    twitch:  { enabled: true,  url: "rtmp://live.twitch.tv/app/" },
    youtube: { enabled: true,  url: "rtmp://a.rtmp.youtube.com/live2/" },
    x:       { enabled: false, url: "" }
  })

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omastream/config.json"

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
    ;["fps", "quality", "audio", "capture"].forEach(function(k) {
      if (loaded[k] !== undefined) next[k] = loaded[k]
    })
    Stream.platforms().forEach(function(p) {
      if (loaded[p.id] && typeof loaded[p.id] === "object") {
        // Any legacy plaintext "key" found here is ignored and dropped on
        // the next save — keys belong in the keyring, not this file.
        next[p.id] = {
          enabled: loaded[p.id].enabled === true,
          url: String(loaded[p.id].url || "")
        }
      }
    })
    cfg = next
  }

  function saveCfg() {
    configFile.setText(JSON.stringify(cfg, null, 2))
    configFile.writeAdapter()
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
      proc.command = Stream.buildArgs(cfg, Stream.targetUrl(entryFor(id)), fetchedKeys[id])
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

    if (missing.length > 0) {
      root.lastError = "Missing ingest URL for: " + missing.join(", ")
      return
    }
    if (ids.length === 0) {
      root.lastError = "No platforms enabled."
      return
    }

    // Fetch keys out of the keyring first; streams start once every lookup
    // has come back (see tryLaunch).
    fetchedKeys = {}
    launchState = { ids: ids, pending: ids.length, failed: false, err: "" }
    ids.forEach(function(id) { procForLookup(id).startLookup("launch") })
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
    if (exitCode !== 0) {
      root.lastError = "A stream ended unexpectedly (exit " + exitCode + ")."
    }
  }

  Process {
    id: twitchProc
    stdout: StdioCollector {}
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "" && !root.stopping) root.lastError = t.split("\n")[0]
      }
    }
    onExited: function(code) { root.handleExit(code) }
  }

  Process {
    id: youtubeProc
    stdout: StdioCollector {}
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "" && !root.stopping) root.lastError = t.split("\n")[0]
      }
    }
    onExited: function(code) { root.handleExit(code) }
  }

  Process {
    id: xProc
    stdout: StdioCollector {}
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "" && !root.stopping) root.lastError = t.split("\n")[0]
      }
    }
    onExited: function(code) { root.handleExit(code) }
  }

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
    contentWidth: panel.fittedContentWidth(Style.space(520))
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

        PanelSeparator { foreground: root.contentForeground }

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
                ? "X RTMP ingest URL (from X Studio)"
                : "RTMP URL"
              onEditingFinished: root.updateEntry(platformBlock.modelData.id, { url: text.trim() })
            }

            TextField {
              id: keyField
              width: parent.width
              foreground: root.contentForeground
              password: true
              // Programmatic clears (after commit) must not count as edits.
              property bool clearing: false
              placeholderText: platformBlock.hasKey
                ? "●●●●●● stored in system keyring — type to replace, clear to delete"
                : "Paste stream key → stored in system keyring (not on disk)"
              onTextChanged: {
                if (!clearing) platformBlock.keyDirty = true
              }
              onEditingFinished: {
                if (!platformBlock.keyDirty) return
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
