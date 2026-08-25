import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Hyprland
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
    resolution: "",
    quality: "medium",
    audio: "default_output",
    capture: "screen",
    scene: "screen",
    cameraDevice: "/dev/video0",
    cameraSource: "device",
    cameraUrl: "",
    chatTwitchChannel: "",
    chatYoutubeId: "",
    startTime: "19:00",
    autoStart: false,
    hiddenWorkspaces: [1, 2],
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
    ;["fps", "resolution", "quality", "audio", "capture", "scene", "cameraDevice",
      "cameraSource", "cameraUrl", "chatTwitchChannel", "chatYoutubeId",
      "startTime", "autoStart",
      "pipXPct", "pipYPct", "pipSizePct", "hiddenWorkspaces"].forEach(function(k) {
      if (loaded[k] !== undefined) next[k] = loaded[k]
    })
    // Migrate the numeric-bitrate experiment back to named presets.
    if (!(next.quality === "low" || next.quality === "medium" || next.quality === "high")
        && loaded.videoBitrateKbps !== undefined) {
      var b = Number(loaded.videoBitrateKbps) || 6000
      next.quality = b < 5000 ? "low" : (b <= 7000 ? "medium" : "high")
    }
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

  property string pendingTwitchKey: ""

  function saveCfg() {
    // Written through a child process instead of FileView.writeAdapter():
    // the config is plain text (no structured adapter), the content travels
    // via env — never argv — and permissions are kept exact.
    saveProc.payload = JSON.stringify(cfg, null, 2)
    saveProc.pendingKey = pendingTwitchKey
    saveProc.running = true
    pendingTwitchKey = ""
  }

  Process {
    id: saveProc
    property string payload: ""
    property string pendingKey: ""
    environment: ({
      OMASTREAM_CFG: payload,
      OMASTREAM_CFG_PATH: root.configPath,
      OMASTREAM_KEY: pendingKey
    })
    command: ["bash", "-c",
      'printf "%s" "$OMASTREAM_CFG" > "$OMASTREAM_CFG_PATH" && chmod 600 "$OMASTREAM_CFG_PATH"; '
      + 'if [ -n "$OMASTREAM_KEY" ]; then '
      + 'umask 077; printf "%s" "$OMASTREAM_KEY" > /tmp/.omastream-key; '
      + 'if [ "$OMASTREAM_KEY" = "-" ]; then '
      + 'secret-tool clear service omastream username twitch; echo "key cleared"; '
      + 'else '
      + 'secret-tool clear service omastream username twitch; '
      + 'secret-tool store --label="oma-stream twitch" service omastream username twitch < /tmp/.omastream-key; echo "key stored rc=$?"; '
      + 'fi; rm -f /tmp/.omastream-key; fi']
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") console.log("[omastream] save:", t)
      }
    }
    onExited: function(code) {
      if (code === 0 && root.pendingTwitchKey !== "" && root.pendingTwitchKey !== "-")
        refreshKeyPresence()
      root.pendingTwitchKey = ""
    }
  }

  // ---- Chat bridges -------------------------------------------------------
  // Anonymous-read bridges: Twitch via IRC-over-WebSocket (justinfan),
  // YouTube via the innertube live-chat endpoint. Each prints
  // "user<TAB>message" lines; X has no public chat API.
  property var twitchChatLines: []
  property var ytChatLines: []

  function appendChat(kind, line) {
    if (!line || line.trim() === "") return
    var parts = line.split("	")
    var entry = { u: parts[0] || "", m: parts.slice(1).join("	") }
    var prop = kind === "twitch" ? "twitchChatLines" : "ytChatLines"
    var arr = root[prop].slice(0)
    arr.push(entry)
    if (arr.length > 60) arr = arr.slice(-60)
    root[prop] = arr
  }

  readonly property string pyTwitch: [
    "import socket,base64,os,sys,time,random",
    "CRLF=chr(13)+chr(10)",
    "def frame(op,p):",
    " d=p.encode()",
    " h=bytearray([0x80|op])",
    " n=len(d)",
    " if n<126: h.append(0x80|n)",
    " else:",
    "  h.append(0x80|126); h+=n.to_bytes(2,'big')",
    " m=os.urandom(4)",
    " h+=m",
    " s.sendall(bytes(h)+bytes(b^m[i%4] for i,b in enumerate(d)))",
    "while True:",
    " try:",
    "  chan=sys.argv[1].lower().lstrip('#')",
    "  import ssl",
    "  raw=socket.create_connection(('irc-ws.chat.twitch.tv',443),15)",
    "  s=ssl.create_default_context().wrap_socket(raw,server_hostname='irc-ws.chat.twitch.tv')",
    "  key=base64.b64encode(os.urandom(16)).decode()",
    "  req='GET / HTTP/1.1'+CRLF+'Host: irc-ws.chat.twitch.tv'+CRLF+'Upgrade: websocket'+CRLF+'Connection: Upgrade'+CRLF+'Sec-WebSocket-Key: '+key+CRLF+'Sec-WebSocket-Version: 13'+CRLF+CRLF",
    "  s.sendall(req.encode())",
    "  buf=b''",
    "  while bytes([13,10,13,10]) not in buf: buf+=s.recv(4096)",
    "  def sendf(op,p): frame(op,p)",
    "  nick='justinfan'+str(random.randint(10000,99999))",
    "  sendf(1,'NICK '+nick)",
    "  sendf(1,'JOIN #'+chan)",
    "  while True:",
    "   while len(buf)<2: buf+=s.recv(4096)",
    "   op=buf[0]&0x0f; ln=buf[1]&0x7f; off=2",
    "   if ln==126:",
    "    while len(buf)<4: buf+=s.recv(4096)",
    "    ln=int.from_bytes(buf[2:4],'big'); off=4",
    "   elif ln==127:",
    "    while len(buf)<10: buf+=s.recv(4096)",
    "    ln=int.from_bytes(buf[2:10],'big'); off=10",
    "   while len(buf)<off+ln: buf+=s.recv(4096)",
    "   payload=buf[off:off+ln]; buf=buf[off+ln:]",
    "   if op==0x9: sendf(0xA,payload.decode()); continue",
    "   if op==0x8: raise RuntimeError('closed')",
    "   for line in payload.decode('utf-8','replace').split(CRLF):",
    "    if line.startswith('PING'): sendf(1,'PONG :tmi.twitch.tv'); continue",
    "    if 'PRIVMSG' in line and ':' in line:",
    "     user=line.split(':')[1].split('!')[0]",
    "     msg=line.split(':',2)[2] if line.count(':')>1 else ''",
    "     print(user+chr(9)+msg, flush=True)",
    " except Exception as e:",
    "  print('bridge: reconnecting ('+str(e)+')', flush=True)",
    "  time.sleep(3)",
  ].join(String.fromCharCode(10))

  readonly property string pyYoutube: [
    "import urllib.request,json,re,sys,time",
    "vid=sys.argv[1]",
    "q=chr(34)",
    "hdr={'User-Agent':'Mozilla/5.0 (X11; Linux x86_64)'}",
    "def http(url,body=None):",
    " data=json.dumps(body).encode() if body else None",
    " req=urllib.request.Request(url,headers=hdr,data=data)",
    " if body: req.add_header('Content-Type','application/json')",
    " return urllib.request.urlopen(req,timeout=15).read().decode('utf-8','replace')",
    "cont=''",
    "html=http('https://www.youtube.com/live_chat?v='+vid+'&hl=en')",
    "m=re.search('continuation'+q+':'+q+'([^'+q+']+)',html)",
    "if m: cont=m.group(1)",
    "if cont=='':",
    " print('bridge: no live chat found for this video', flush=True)",
    " sys.exit(0)",
    "while True:",
    " try:",
    "  body={'context':{'client':{'clientName':'WEB','clientVersion':'2.20240702.01.00'}},'continuation':cont}",
    "  data=json.loads(http('https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?prettyPrint=false',body))",
    "  lr=data.get('contents',{}).get('liveChatRenderer',{})",
    "  for a in lr.get('actions',[]):",
    "   r=a.get('addChatItemAction',{}).get('item',{}).get('liveChatTextMessageRenderer')",
    "   if not r: continue",
    "   author=r.get('authorName',{}).get('simpleText','?')",
    "   msg=''.join(x.get('text','') for x in r.get('message',{}).get('runs',[]))",
    "   print(author+chr(9)+msg, flush=True)",
    "  cs=data.get('continuationContents',{}).get('liveChatContinuation',{}).get('continuations',[])",
    "  if cs: cont=cs[0].get('invalidationContinuationData',{}).get('continuation',cont)",
    "  time.sleep(2)",
    " except Exception as e:",
    "  print('bridge: retrying ('+str(e)+')', flush=True)",
    "  time.sleep(4)",
  ].join(String.fromCharCode(10))
  readonly property var chatColumns: {
    var c = []
    if (entryFor("twitch").enabled)
      c.push({ key: "twitch", title: "TWITCH", lines: twitchChatLines })
    if (entryFor("youtube").enabled)
      c.push({ key: "youtube", title: "YOUTUBE", lines: ytChatLines })
    if (entryFor("x").enabled)
      c.push({ key: "x", title: "X", lines: [{ u: "", m: "X provides no public chat API." }] })
    return c
  }

  property string activeTwitchArg: ""
  property string activeYtArg: ""

  function updateChatBridges() {
    var want = contentColumn.tabPage === 3 && root.opened
    var ch = String(cfg.chatTwitchChannel || "").trim()
    var vid = String(cfg.chatYoutubeId || "").trim()

    if (want && entryFor("twitch").enabled && ch !== "") {
      if (activeTwitchArg !== ch || !twitchChatProc.running) {
        activeTwitchArg = ch
        twitchChatLines = []
        twitchChatProc.command = ["python3", "-c", root.pyTwitch, ch]
        twitchChatProc.running = true
      }
    } else if (twitchChatProc.running) { twitchChatProc.running = false; activeTwitchArg = "" }

    if (want && entryFor("youtube").enabled && vid !== "") {
      if (activeYtArg !== vid || !ytChatProc.running) {
        activeYtArg = vid
        ytChatLines = []
        ytChatProc.command = ["python3", "-c", root.pyYoutube, vid]
        ytChatProc.running = true
      }
    } else if (ytChatProc.running) { ytChatProc.running = false; activeYtArg = "" }
  }

  Process {
    id: twitchChatProc
    stdout: SplitParser { onRead: function(line) { root.appendChat("twitch", line) } }
  }

  Process {
    id: ytChatProc
    stdout: SplitParser { onRead: function(line) { root.appendChat("youtube", line) } }
  }
  // ---- Scheduled start ------------------------------------------------------
  property string lastFiredDate: ""
  property string schedCountdown: ""

  Timer {
    id: schedTimer
    interval: 1000
    repeat: true
    running: String(cfg.autoStart) === "true"
    triggeredOnStart: true
    onTriggered: root.evaluateSchedule()
  }

  function evaluateSchedule() {
    var now = new Date()
    var today = Qt.formatDate(now, "yyyy-MM-dd")

    if (String(cfg.autoStart) !== "true" || root.live || root.lastFiredDate === today) {
      root.schedCountdown = ""
      return
    }

    var parts = String(cfg.startTime).split(":")
    if (parts.length !== 2 || !isFinite(parseInt(parts[0], 10)) || !isFinite(parseInt(parts[1], 10))) {
      root.schedCountdown = "invalid time"
      return
    }
    var target = new Date(now)
    target.setHours(parseInt(parts[0], 10), parseInt(parts[1], 10), 0, 0)

    if (now >= target) {
      root.lastFiredDate = today
      root.schedCountdown = ""
      goLive()
      return
    }

    var s = Math.floor((target - now) / 1000)
    var h = Math.floor(s / 3600); s -= h * 3600
    var m = Math.floor(s / 60);   s -= m * 60
    var pad = function(n) { return (n < 10 ? "0" : "") + n }
    root.schedCountdown = "starts in " + (h > 0 ? pad(h) + ":" : "") + pad(m) + ":" + pad(s)
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
    refreshScreenW()
    audioListProc.running = true
    monitorListProc.running = true
    refreshGsr()
  }

  Process {
    id: audioListProc
    command: ["gpu-screen-recorder", "--list-audio-devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.audioDevices = root.parsePipeList(text)
    }
  }

  Process {
    id: monitorListProc
    command: ["gpu-screen-recorder", "--list-monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.monitorList = root.parsePipeList(text, function(id, res) { return id + " · " + res })
    }
  }

  // Device lists queried from gpu-screen-recorder itself, so the dropdowns
  // always match what gsr will actually accept.
  property var audioDevices: []   // [{ id, label }]
  property var monitorList: []    // [{ id, label }]

  function parsePipeList(t, labelFromParts) {
    var out = []
    String(t || "").split("\n").forEach(function(line) {
      line = line.trim()
      if (line === "") return
      var i = line.indexOf("|")
      if (i > 0) {
        var id = line.slice(0, i)
        out.push({ id: id, label: labelFromParts ? labelFromParts(id, line.slice(i + 1)) : line.slice(i + 1) })
      }
    })
    return out
  }

  // Panel width scales with the screen: 48% of it, clamped to sane bounds,
  // so the same UI fits small laptop panels and a 4K display alike.
  property real screenW: 1280

  function refreshScreenW() {
    var s = root.Screen ? root.Screen.screen : null
    if (!s || !(s.width > 0)) {
      var list = Quickshell.screens
      if (list && list.length > 0) s = list[0]
    }
    if (s && s.width > 0) screenW = s.width
  }
  onVisibleChanged: if (visible) { refreshScreenW(); updateCamGrab() }

  readonly property real targetPanelWidth: Math.max(480, Math.min(screenW * 0.48, 1100))

  readonly property real displayHz: {
    var s = Quickshell.screens
    if (s && s.length > 0 && s[0].refreshRate > 0)
      return Math.round(s[0].refreshRate)
    return 0
  }

  // ---- Workspace privacy ---------------------------------------------------
  // Hidden workspaces freeze every stream encoder (SIGSTOP) while you are on
  // one, and unfreeze when you leave — viewers see a frozen frame instead of
  // whatever should stay private.
  // Chips for workspaces 1..10 plus any named/dynamic ones Hyprland reports,
  // so the list is never empty even before other workspaces are visited.
  readonly property var hyprWorkspaces: {
    var out = {}
    var dyn = Hyprland.workspaces || []
    for (var i = 0; i < dyn.length; i++)
      if (dyn[i].id > 0) out[dyn[i].id] = dyn[i].name !== "" ? dyn[i].name : String(dyn[i].id)
    for (var n = 1; n <= 10; n++)
      if (!(n in out)) out[n] = String(n)
    var keys = Object.keys(out).map(Number).sort(function(a, b) { return a - b })
    return keys.map(function(k) { return { id: k, name: out[k] } })
  }
  readonly property int focusedWsId: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  property bool wsPaused: false

  // ---- Camera preview grabber ---------------------------------------------
  // Idle previews use ffmpeg frame-grabs (2fps JPEG) instead of a second
  // Qt camera session: v4l2 devices allow one consumer, and this keeps the
  // device free for gpu-screen-recorder / the overlay when live.
  property int camShotSeq: 0
  readonly property bool sceneWantsCam: scene !== "screen"
  readonly property string camSourceArg: String(cfg.cameraSource) === "url"
    ? String(cfg.cameraUrl || "")
    : String(cfg.cameraDevice || "/dev/video0")

  // Cheap 1s convergence loop: catches every missed visibility/signal edge.
  Timer {
    id: camEval
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: updateCamGrab()
  }

  function updateCamGrab() {
    var want = root.opened && contentColumn.tabPage === 4
                && root.sceneWantsCam && !root.live
                && root.camSourceArg !== ""
    if (want && !camGrabProc.running) {
      // Atomic writes: grab to temp file, rename — readers never see
      // half-written JPEGs (this was the preview flicker).
      var cmd = ["bash", "-c",
        'SRC="' + root.camSourceArg.replace(/"/g, '') + '"; '
        + (String(cfg.cameraSource) === "url"
          ? 'FLAGS=""'
          : 'FLAGS="-f v4l2 -video_size 480x360"') + '; '
        + 'while true; do '
        + 'ffmpeg -hide_banner -loglevel error -y $FLAGS -i "$SRC" '
        + '-vf fps=10 -frames:v 1 -q:v 4 /tmp/.omastream-cam-new.jpg '
        + '&& mv /tmp/.omastream-cam-new.jpg /tmp/omastream-cam.jpg; '
        + 'sleep 0.09; done']
      camGrabProc.command = cmd
      camGrabProc.running = true
    } else if (!want && camGrabProc.running) {
      camGrabProc.running = false
      camKillProc.running = true
    }
    camShotTick.restart()
  }

  Timer {
    id: camShotTick
    interval: 150
    repeat: true
    running: camGrabProc.running
    onTriggered: root.camShotSeq++
  }

  Process {
    id: camGrabProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") console.log("[omastream] grab:", t.split("\n").pop())
      }
    }
  }


  function isHiddenWs(id) {
    var list = cfg.hiddenWorkspaces || []
    for (var i = 0; i < list.length; i++)
      if (Number(list[i]) === Number(id)) return true
    return false
  }

  function toggleHiddenWs(id) {
    var arr = (cfg.hiddenWorkspaces || []).slice().map(Number)
    var k = arr.indexOf(Number(id))
    if (k >= 0) arr.splice(k, 1); else arr.push(Number(id))
    updateGlobal({ hiddenWorkspaces: arr })
    evaluatePrivacy()
  }

  function setStreamsFrozen(freeze) {
    sigProc.command = freeze
      ? ["pkill", "-STOP", "-f", "gpu-screen-recorder"]
      : ["pkill", "-CONT", "-f", "gpu-screen-recorder"]
    sigProc.running = true
  }

  function evaluatePrivacy() {
    if (!root.live) {
      if (root.wsPaused) { root.wsPaused = false; root.lastError = ""; setStreamsFrozen(false) }
      return
    }
    var hiddenNow = root.isHiddenWs(root.focusedWsId)
    if (hiddenNow && !root.wsPaused) {
      root.wsPaused = true
      root.lastError = "PAUSED — hidden workspace"
      setStreamsFrozen(true)
    } else if (!hiddenNow && root.wsPaused) {
      root.wsPaused = false
      root.lastError = ""
      setStreamsFrozen(false)
    }
  }
  onFocusedWsIdChanged: evaluatePrivacy()

  Process {
    id: sigProc
    command: ["true"]
  }

  // ---- Dependency check -----------------------------------------------------
  property bool gsrMissing: false

  function refreshGsr() {
    gsrProc.running = true
  }

  Process {
    id: gsrProc
    command: ["bash", "-c", "command -v gpu-screen-recorder >/dev/null && echo ok"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.gsrMissing = String(text || "").trim() !== "ok"
    }
  }

  // Guided install via polkit (password prompt handled by the system agent).
  Process {
    id: gsrInstallProc
    command: ["pkexec", "pacman", "-S", "--noconfirm", "--needed", "gpu-screen-recorder"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") console.log("[omastream] install stderr:", t.split("\n").pop())
      }
    }
    onExited: function(code) {
      if (code === 0) {
        root.gsrMissing = false
        root.refreshGsr()
      } else {
        root.lastError = code === 126 ? "Install cancelled." : "Install failed (code " + code + ")."
      }
    }
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

  readonly property bool camOverlayActive: scene === "pip" && (camPreviewOn || live)

  function toggleCamPreview() {
    lastError = ""
    camPreviewOn = !camPreviewOn
  }

  property bool camPreviewOn: false

  Loader {
    id: camOverlayLoader
    active: camOverlayActive
    sourceComponent: CameraOverlay {
      panelRoot: root
    }
  }


  property int pipStage: 0

  Timer {
    id: pipDelay
    interval: 2000
    repeat: false
    onTriggered: startLookupPhase()
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
    console.log("[omastream] storeKey", id, "len=" + secret.length)
    if (id !== "twitch") return
    if (secret === "") {
      pendingTwitchKey = "-"
      saveCfg()   // "-" instructs the save script to delete the stored key
      var p1 = Object.assign({}, keyPresent); p1[id] = false; keyPresent = p1
      return
    }
    pendingTwitchKey = secret
    var p2 = Object.assign({}, keyPresent); p2[id] = true; keyPresent = p2
    saveCfg()   // carries the key through saveProc into the keyring
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

  KeyLookup { id: twitchLookup;  platformId: "twitch";  ctrl: root }
  KeyLookup { id: youtubeLookup; platformId: "youtube"; ctrl: root }
  KeyLookup { id: xLookup;       platformId: "x";       ctrl: root }

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
    evaluatePrivacy()
  }

  // ---- Live state ---------------------------------------------------------
  readonly property bool live: twitchProc.running || youtubeProc.running || xProc.running
  // Whatever way a stream ends (STOP, crash, remote close), give the camera
  // back to the preview immediately.
  onLiveChanged: updateCamGrab()
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
    camGrabProc.running = false   // free the webcam before encoders claim it
    if (root.gsrMissing) {
      root.lastError = "gpu-screen-recorder is required."
      return
    }
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

    // gpu-screen-recorder can only capture local devices; a network camera
    // source needs the PiP path (mpv window composited by screen capture).
    if (root.scene === "camera" && String(cfg.cameraSource) === "url") {
      root.lastError = "WEBCAM scene needs a local camera. For phones/IP cams use 🖥+🎥 PIP."
      return
    }

    root.goLiveIds = ids

    // PiP: staged startup — release the Qt camera session, THEN raise the
    // overlay window (it needs the freed device), let it settle, and only
    // then begin key lookups + capture.
    if (root.scene === "pip") {
      root.pipStage = 0
      pipDelay.interval = 700
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
    if (root.wsPaused) { root.wsPaused = false; setStreamsFrozen(false) } // SIGTERM needs a running process to be delivered
    twitchProc.running = false
    youtubeProc.running = false
    xProc.running = false
    root.pipStage = 0
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

  StreamProcess { id: twitchProc;  platformId: "twitch";  ctrl: root }
  StreamProcess { id: youtubeProc; platformId: "youtube"; ctrl: root }
  StreamProcess { id: xProc;       platformId: "x";       ctrl: root }

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
    twitchChatProc.running = false
    ytChatProc.running = false
    activeTwitchArg = ""
    activeYtArg = ""
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
    contentWidth: panel.fittedContentWidth(root.targetPanelWidth)
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
        onTabPageChanged: root.updateChatBridges()

        // All pages share the tallest page's height so the panel never
        // resizes itself when you switch tabs.
        readonly property real tabPageHeight: Math.max(
          streamPage.implicitHeight,
          platformsPage.implicitHeight,
          infoPage.implicitHeight,
          previewPage.implicitHeight,
          chatPage.implicitHeight)

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
            text: "SCHEDULE"
            selected: contentColumn.tabPage === 2
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: contentColumn.tabPage = 2
          }

          Button {
            text: "PREVIEW"
            selected: contentColumn.tabPage === 3
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: contentColumn.tabPage = 3
          }

          Button {
            text: "CHAT"
            selected: contentColumn.tabPage === 4
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: contentColumn.tabPage = 4
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

          Column {
            visible: root.gsrMissing
            width: parent.width
            spacing: Style.space(8)

            Row {
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "gpu-screen-recorder missing"
                color: root.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                text: "INSTALL"
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: gsrInstallProc.running = true
              }
            }
          }

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

            Row {
              visible: root.scene !== "screen"
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(64)
                text: "SOURCE"
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                text: "WEBCAM / CAPTURE CARD"
                selected: String(cfg.cameraSource) !== "url"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.updateGlobal({ cameraSource: "device" })
              }

              Button {
                text: "PHONE / IP CAM"
                selected: String(cfg.cameraSource) === "url"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.updateGlobal({ cameraSource: "url" })
              }
            }

            TextField {
              visible: root.scene !== "screen" && String(cfg.cameraSource) === "url"
              width: parent.width
              foreground: root.contentForeground
              text: String(cfg.cameraUrl)
              placeholderText: "http://192.168.1.5:8080/video · rtsp://… (DroidCam, Iriun, IP Webcam)"
              onEditingFinished: root.updateGlobal({ cameraUrl: text.trim() })
            }

            Dropdown {
              visible: root.scene !== "screen" && String(cfg.cameraSource) !== "url"
              width: parent.width
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

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.displayHz > 0
                ? "· display: " + root.displayHz + " Hz"
                : ""
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          

          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(64)
              text: "OUTPUT"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Dropdown {
              width: parent.width - Style.space(72)
              showLabel: false
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              options: Stream.resolutions().map(function(r) { return r.label })
              value: Stream.resolutionLabel(cfg.resolution)
              onChanged: function(label) { root.updateGlobal({ resolution: Stream.selectResolution(label) }) }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: Style.space(64)
              text: "BITRATE"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: ["low", "medium", "high"]

              Button {
                required property string modelData
                text: modelData
                selected: String(cfg.quality) === modelData
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.updateGlobal({ quality: modelData })
              }
            }
          }

          

            Dropdown {
              width: parent.width
              showLabel: false
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              options: {
                var opts = audioDevices.map(function(d) { return d.label })
                if (audioDevices.length === 0 && String(cfg.audio) !== "") opts.push(String(cfg.audio))
                return opts
              }
              value: {
                for (var i = 0; i < audioDevices.length; i++)
                  if (audioDevices[i].id === String(cfg.audio)) return audioDevices[i].label
                return String(cfg.audio)
              }
              enabled: audioDevices.length > 0
              onChanged: function(label) {
                for (var i = 0; i < audioDevices.length; i++)
                  if (audioDevices[i].label === label) { root.updateGlobal({ audio: audioDevices[i].id }); return }
              }
            }

          Row {
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(64)
              text: "SOURCE"
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Dropdown {
              width: Style.space(220)
              showLabel: false
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              options: {
                var opts = ["All screens"]
                monitorList.forEach(function(m) { opts.push(m.label) })
                opts.push("Portal (choose on stream)")
                opts.push("Focused window")
                if (!["screen", "portal", "focused"].includes(String(cfg.capture))
                    && monitorList.every(function(m) { return m.id !== String(cfg.capture) }))
                  opts.push(String(cfg.capture)) // preserved custom value
                return opts
              }
              value: {
                var c = String(cfg.capture)
                if (c === "screen") return "All screens"
                if (c === "portal") return "Portal (choose on stream)"
                if (c === "focused") return "Focused window"
                for (var i = 0; i < monitorList.length; i++)
                  if (monitorList[i].id === c) return monitorList[i].label
                return c
              }
              onChanged: function(label) {
                if (label === "All screens") { root.updateGlobal({ capture: "screen" }); return }
                if (label === "Portal (choose on stream)") { root.updateGlobal({ capture: "portal" }); return }
                if (label === "Focused window") { root.updateGlobal({ capture: "focused" }); return }
                for (var i = 0; i < monitorList.length; i++)
                  if (monitorList[i].label === label) { root.updateGlobal({ capture: monitorList[i].id }); return }
                root.updateGlobal({ capture: label })
              }
            }
          }
        }
        }

        // ---- Workspace privacy -------------------------------------------
        Column {
          visible: contentColumn.tabPage === 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "HIDDEN WORKSPACES"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.hyprWorkspaces

              Button {
                required property var modelData
                readonly property int wsId: modelData.id
                readonly property string label: modelData.name !== "" ? modelData.name : String(wsId)
                text: label
                selected: root.isHiddenWs(wsId)
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.toggleHiddenWs(wsId)
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.wsPaused ? "● PAUSED" : ""
              color: root.liveColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
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
              visible: platformBlock.modelData.id === "twitch"
              width: parent.width
              foreground: root.contentForeground
              text: String(cfg.chatTwitchChannel || "")
              placeholderText: "Channel name — enables TWITCH chat"
              onEditingFinished: root.updateGlobal({ chatTwitchChannel: text.trim() })
            }

            TextField {
              visible: platformBlock.modelData.id === "youtube"
              width: parent.width
              foreground: root.contentForeground
              text: String(cfg.chatYoutubeId || "")
              placeholderText: "Video ID (watch?v=…) — enables YOUTUBE chat"
              onEditingFinished: root.updateGlobal({ chatYoutubeId: text.trim() })
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: keyField
                width: parent.width - Style.space(76)
                foreground: root.contentForeground
                password: true
                // Programmatic clears must not count as edits.
                property bool clearing: false
                placeholderText: platformBlock.hasKey
                  ? "Stored in keyring — paste to replace"
                  : "Stream key"
                onTextChanged: if (!clearing) platformBlock.keyDirty = true
              }

              Button {
                text: "SAVE KEY"
                selected: platformBlock.keyDirty
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: {
                  var secret = keyField.text.trim()
                  platformBlock.keyDirty = false
                  keyField.clearing = true
                  keyField.text = ""
                  keyField.clearing = false
                  root.storeKey(platformBlock.modelData.id, secret)
                }
              }
            }
          }
        }
        }

          // ---- Page 2: stream info (title · thumbnail · schedule) ----------
        Column {
          id: infoPage
          visible: contentColumn.tabPage === 2
          height: contentColumn.tabPageHeight
          width: parent.width
          spacing: Style.space(12)

          PanelSectionHeader {
            text: "SCHEDULED START"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Row {
            spacing: Style.space(8)

            TextField {
              width: Style.space(90)
              foreground: root.contentForeground
              text: String(cfg.startTime)
              placeholderText: "HH:MM"
              onEditingFinished: root.updateGlobal({ startTime: text.trim() })
            }

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: String(cfg.autoStart) === "true"
              foreground: root.contentForeground
              onToggled: root.updateGlobal({ autoStart: String(cfg.autoStart) === "true" ? false : true })
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.schedCountdown
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ---- Page 2: program monitor -------------------------------------
          Column {
            id: previewPage
            visible: contentColumn.tabPage === 3
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
              camShotSeq: root.camShotSeq
              camGrabbing: camGrabProc.running
              fg: root.contentForeground
              fontFamily: root.contentFontFamily
              onPlacementChanged: function(xp, yp) { root.updateGlobal({ pipXPct: xp, pipYPct: yp }) }
            }

            
          }
        // ---- Page 3: chat (one column per enabled platform) --------------
        Column {
          id: chatPage
          visible: contentColumn.tabPage === 4
          height: contentColumn.tabPageHeight
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            height: parent.height
            spacing: Style.space(8)

            Repeater {
              model: root.chatColumns

              Rectangle {
                required property var modelData
                readonly property int colCount: root.chatColumns.length
                width: Math.floor((parent.width - Style.space(8) * (colCount - 1)) / colCount)
                height: parent.height
                color: "#000000"
                radius: Style.space(4)
                clip: true

                Column {
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  spacing: Style.space(6)

                  Text {
                    text: modelData.title + " · " + (modelData.lines.length || "")
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }

                  Flickable {
                    id: chatScroll
                    width: parent.width
                    height: parent.height - headerLabel.height - Style.space(12)
                    contentWidth: width
                    contentHeight: msgList.implicitHeight
                    clip: true

                    property bool pinned: true
                    onContentHeightChanged: if (pinned) contentY = Math.max(0, contentHeight - height)
                    onDragEnded: pinned = (contentY >= contentHeight - height - Style.space(24))

                    Column {
                      id: msgList
                      width: chatScroll.width
                      spacing: Style.space(3)

                      Repeater {
                        model: modelData.lines

                        delegate: Text {
                          required property var modelData
                          width: chatScroll.width
                          wrapMode: Text.WrapAnywhere
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                          text: modelData.u !== "" ? modelData.u + ": " + modelData.m : modelData.m
                        }
                      }

                      Item { width: 1; height: 1 }
                    }
                  }

                  Text {
                    id: headerLabel
                    visible: modelData.lines.length === 0
                    text: modelData.key === "x" ? "no public chat API" : "waiting for messages…"
                    color: root.dim
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }

        // Error / status line — fixed slot so status messages never resize
        // the panel.
        Item {
          width: parent.width
          height: Style.space(20)
          clip: true

          Text {
            width: parent.width
            visible: root.lastError !== ""
            text: root.lastError
            color: root.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        // The single action: starts or stops every enabled platform.
        Button {
          width: parent.width
          leftAlign: true
          bordered: true
          text: root.live ? "■ STOP STREAMING" : "● GO LIVE — ALL PLATFORMS"
          selected: root.live
          foreground: root.contentForeground
          accent: root.liveColor
          fontFamily: root.contentFontFamily
          onClicked: root.toggleStream()
        }

        
      }
    }
  }

}
