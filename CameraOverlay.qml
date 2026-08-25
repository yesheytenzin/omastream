import QtQuick
import QtMultimedia
import Quickshell
import qs.Commons
import qs.Ui

// On-stream camera overlay: an always-on-top layer-shell window showing the
// webcam (or network source), captured by gpu-screen-recorder along with the
// desktop. Placement/size come from the panel's saved percentages; dragging
// the video writes them back.
PanelWindow {
  id: root

  required property var panelRoot

  readonly property real scrW: screen ? screen.width : 1920
  readonly property real scrH: screen ? screen.height : 1080
  readonly property real tileW: scrW * (Number(panelRoot.cfg.pipSizePct) || 22) / 100
  readonly property real tileH: tileW * 3 / 4

  screen: Quickshell.screens && Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

  anchors {
    bottom: true
    right: true
  }

  implicitWidth: Math.round(tileW)
  implicitHeight: Math.round(tileH)
  exclusiveZone: -1
  color: "transparent"

  margins {
    right: Math.max(8, Math.round((scrW - implicitWidth) * (100 - (Number(panelRoot.cfg.pipXPct) || 72)) / 100))
    bottom: Math.max(8, Math.round((scrH - implicitHeight) * (100 - (Number(panelRoot.cfg.pipYPct) || 62)) / 100))
  }

  // ---- Live sources --------------------------------------------------------
  MediaDevices { id: mediaDevices }

  CaptureSession {
    id: camSession
    camera: Camera {
      id: camera
      cameraDevice: {
        var want = String(panelRoot.cfg.cameraDevice || "")
        var list = mediaDevices.videoInputs || []
        for (var i = 0; i < list.length; i++)
          if (String(list[i].id) === want) return list[i]
        return mediaDevices.defaultVideoInput
      }
      onActiveChanged: console.log("[omastream] overlay camera active:", active)
      onErrorOccurred: function(error, errorString) {
        console.log("[omastream] overlay camera ERROR:", errorString)
      }
    }
    videoOutput: localOut
  }

  Component.onCompleted: {
    var list = mediaDevices.videoInputs || []
    console.log("[omastream] overlay: cameras detected =", list.length,
                "| selected =", String(panelRoot.cfg.cameraDevice),
                "| source =", String(panelRoot.cfg.cameraSource),
                "| visible =", visible)
  }

  // Delayed start: the layer surface must be mapped and the sink attached
  // before the camera starts, or the ffmpeg backend delivers black frames.
  Timer {
    id: startDelay
    interval: 400
    onTriggered: if (root.visible && !camera.active) {
      console.log("[omastream] overlay: starting camera")
      camera.active = true
    }
  }
  onVisibleChanged: if (visible) startDelay.restart()


  MediaPlayer {
    id: netPlayer
    source: String(panelRoot.cfg.cameraSource) === "url" ? String(panelRoot.cfg.cameraUrl) : ""
    videoOutput: netOut
    autoPlay: String(panelRoot.cfg.cameraSource) === "url" && root.visible && String(panelRoot.cfg.cameraUrl) !== ""
    onErrorOccurred: function(error, errorString) {
      console.log("[omastream] overlay network camera:", errorString)
    }
  }

  Item {
    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      color: "#000000"
      radius: Style.space(6)

      VideoOutput {
        id: localOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: String(panelRoot.cfg.cameraSource) !== "url"
      }

      VideoOutput {
        id: netOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
        visible: String(panelRoot.cfg.cameraSource) === "url"
      }

      Text {
        visible: !(String(panelRoot.cfg.cameraSource) === "url" ? netOut.videoVisible : localOut.videoVisible)
        anchors.centerIn: parent
        text: String(panelRoot.cfg.cameraSource) === "url" ? "connecting…" : "CAM"
        color: "#888888"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Drag anywhere on the overlay to reposition; position persists.
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.OpenHandCursor
      property int startX: 0
      property int startY: 0
      property real startRight: 0
      property real startBottom: 0
      onPressed: function(mouse) {
        startX = mouse.x; startY = mouse.y
        startRight = root.margins.right
        startBottom = root.margins.bottom
        cursorShape = Qt.ClosedHandCursor
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var dx = mouse.x - startX
        var dy = mouse.y - startY
        root.margins.right = Math.max(8, Math.min(scrW - width - 8, startRight - dx))
        root.margins.bottom = Math.max(8, Math.min(scrH - height - 8, startBottom - dy))
      }
      onReleased: {
        cursorShape = Qt.OpenHandCursor
        var availW = Math.max(1, scrW - width)
        var availH = Math.max(1, scrH - height)
        var xp = Math.round(100 - root.margins.right / availW * 100)
        var yp = Math.round(100 - root.margins.bottom / availH * 100)
        panelRoot.updateGlobal({ pipXPct: xp, pipYPct: yp })
      }
    }
  }
}
