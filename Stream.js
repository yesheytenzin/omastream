// Helpers for building gpu-screen-recorder invocations per platform.
.pragma library

var PLATFORMS = [
  { id: "twitch",  label: "Twitch",  defaultUrl: "rtmp://live.twitch.tv/app/" },
  { id: "youtube", label: "YouTube", defaultUrl: "rtmp://a.rtmp.youtube.com/live2/" },
  { id: "x",       label: "X",       defaultUrl: "" }
]

function platforms() {
  return PLATFORMS
}

function platform(id) {
  for (var i = 0; i < PLATFORMS.length; i++)
    if (PLATFORMS[i].id === id) return PLATFORMS[i]
  return null
}

// Full RTMP ingest target for a configured platform entry.
// Keys live in the system keyring and are appended at go-live time by
// buildArgs, not stored on the entry.
function targetUrl(entry) {
  if (!entry) return ""
  return String(entry.url || "").trim()
}

// True when an entry is ready to start: enabled and has an ingest URL.
// The stream key is fetched from the keyring separately at go-live.
function isReady(entry) {
  return !!entry && entry.enabled === true && targetUrl(entry) !== ""
}

// Build the argv for one platform's stream. `key` comes from the keyring
// lookup phase; empty means the ingest URL already embeds its credentials.
function buildArgs(cfg, url, key) {
  var target = url + String(key || "")
  return [
    "gpu-screen-recorder",
    "-w", String(cfg.capture || "screen"),
    "-f", String(cfg.fps || 60),
    "-a", String(cfg.audio || "default_output"),
    "-k", "h264",
    "-c", "flv", // RTMP container — gsr can't deduce it from an rtmp:// URL
    "-ac", "aac",
    "-bm", "vbr",
    "-q", String(cfg.quality || "medium"),
    "-o", target
  ]
}

function formatElapsed(ms) {
  var total = Math.max(0, Math.floor(ms / 1000))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return h > 0 ? pad(h) + ":" + pad(m) + ":" + pad(s) : pad(m) + ":" + pad(s)
}
