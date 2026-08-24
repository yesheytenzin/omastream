// Platform presets and command building, modeled on OBS Studio's
// rtmp-services definitions (services.json) so defaults match what OBS
// would negotiate for each service.
.pragma library

var PLATFORMS = [
  {
    id: "twitch", label: "Twitch",
    // Anycast ingest — Twitch's CDN routes to the nearest POP server-side,
    // over RTMPS (encrypted). Equivalent to what OBS negotiates.
    defaultUrl: "rtmps://ingest.global-contribute.live-video.net/app",
    legacyUrls: ["rtmp://live.twitch.tv/app", "rtmp://live.twitch.tv/app/"],
    // services.json "recommended": keyint 2s, audio <= 320 (160 standard)
    rec: { keyint: 2, ab: 160 }
  },
  {
    id: "youtube", label: "YouTube",
    // OBS "YouTube - RTMPS": encrypted primary ingest
    defaultUrl: "rtmps://a.rtmps.youtube.com:443/live2",
    legacyUrls: [
      "rtmp://a.rtmp.youtube.com/live2/",
      "rtmp://a.rtmp.youtube.com/live2"
    ],
    // Backup if the primary ever acts up: rtmps://b.rtmps.youtube.com:443/live2?backup=1
    rec: { keyint: 2, ab: 160 }
  },
  {
    id: "x", label: "X",
    // Periscope/Media Studio Producer ingests: rtmp://<region>.pscp.tv:80/x
    // (ca, or, va, br, fr, ie, de, au, in, jp, kr, sg) — user pastes theirs.
    defaultUrl: "",
    legacyUrls: [],
    // services.json "recommended": keyint 3s, audio <= 128, max fps 60
    rec: { keyint: 3, ab: 128 }
  }
]

function platforms() {
  return PLATFORMS
}

function platform(id) {
  for (var i = 0; i < PLATFORMS.length; i++)
    if (PLATFORMS[i].id === id) return PLATFORMS[i]
  return null
}

// Full RTMP(S) ingest target for a configured platform entry.
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
// Encoder flags follow each service's published recommendations (keyframe
// interval, audio bitrate).
function buildArgs(cfg, url, key, id, capture) {
  var meta = platform(id)
  var rec = meta && meta.rec ? meta.rec : { keyint: 2, ab: 160 }
  // Keys append to the application path: make sure it ends with a slash so
  // "…/app" + "live_…" never becomes "…/applive_…".
  var target = url
  if (key !== "" && !/\/$/.test(url)) target += "/"
  target += String(key || "")
  return [
    "gpu-screen-recorder",
    "-w", String(capture || cfg.capture || "screen"),
    "-f", String(Math.min(Number(cfg.fps) || 60, 60)), // every service caps at 60
    "-a", String(cfg.audio || "default_output"),
    "-k", "h264", // h264 is the only codec all three services accept
    "-c", "flv",  // RTMP container — gsr can't deduce it from an rtmp:// URL
    "-ac", "aac",
    "-bm", "vbr",
    "-q", String(cfg.quality || "medium"),
    "-keyint", String(rec.keyint),
    "-ab", String(rec.ab),
    "-o", target
  ]
}

// Pick Twitch's recommended ingest from the public feed OBS queries.
// There is no client-measurable latency in the response; instead we take
// the highest-priority (lowest number) online entry and prefer its RTMPS
// template. For Twitch that resolves to the global-contribute anycast
// hostname, which their CDN routes to the nearest POP automatically.
// Returns {name, url} or null. `raw` is the response body.
function bestTwitchIngest(raw) {
  var data
  try { data = JSON.parse(raw) } catch (e) { return null }
  if (!data || !data.ingests || !data.ingests.length) return null
  var best = null
  for (var i = 0; i < data.ingests.length; i++) {
    var ing = data.ingests[i]
    if (Number(ing.availability) !== 1) continue // 1 = online
    if (!best || Number(ing.priority) < Number(best.priority))
      best = ing
  }
  if (!best) return null
  // Prefer the encrypted template; both end in /{stream_key}
  var tpl = String(best.url_template_secure || best.url_template || "")
  var url = tpl.replace("{stream_key}", "")
  if (url === "") return null
  return { name: String(best.name || ""), url: url }
}

// Pick the most informative line from a stream's stderr: prefer anything
// that looks like an actual error, fall back to the first line.
function pickErrorLine(t) {
  var lines = String(t || "").split("\n")
  for (var i = 0; i < lines.length; i++)
    if (/error|failed|denied|rejected|invalid|could not/i.test(lines[i]))
      return lines[i]
  return lines[0] || ""
}

function formatElapsed(ms) {
  var total = Math.max(0, Math.floor(ms / 1000))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return h > 0 ? pad(h) + ":" + pad(m) + ":" + pad(s) : pad(m) + ":" + pad(s)
}
