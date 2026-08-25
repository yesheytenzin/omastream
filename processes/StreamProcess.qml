import Quickshell.Io
import "../Stream.js" as Stream

// Per-platform stream process wrapper. `ctrl` must be set to the owning
// panel (provides lastStreamStderr and handleExit).
Process {
  id: streamProc

  required property string platformId
  property var ctrl: null

  stdout: StdioCollector {}
  stderr: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      var t = String(text || "").trim()
      if (t !== "") {
        console.log("[omastream] " + streamProc.platformId + " stderr:\n" + t)
        streamProc.ctrl.lastStreamStderr = Stream.pickErrorLine(t)
      }
    }
  }
  onExited: function(code) {
    console.log("[omastream] " + platformId + " exited code=" + code)
    streamProc.ctrl.handleExit(code)
  }
}
