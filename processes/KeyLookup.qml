import Quickshell.Io

// Generic per-platform lookup process: doubles as a presence check
// (mode "check") and as the fetch phase of go-live (mode "launch").
// `ctrl` must be set to the owning panel (provides lookupText,
// lookupError, lookupDone).
Process {
  id: lookup

  required property string platformId
  property string mode: ""
  property var ctrl: null

  function startLookup(m) {
    mode = m
    command = ["secret-tool", "lookup", "service", "omastream", "username", platformId]
    running = true
  }

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: lookup.ctrl.lookupText(lookup.platformId, lookup.mode, String(text || "").trim())
  }
  stderr: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      var t = String(text || "").trim()
      if (t !== "") lookup.ctrl.lookupError(lookup.platformId, t)
    }
  }
  onExited: function(code) { lookup.ctrl.lookupDone(lookup.platformId, lookup.mode, code) }
}
