import QtQuick
import QtMultimedia
import Quickshell.Io
import qs.Commons
import qs.Ui

// Program monitor: a 16:9 canvas mirroring what the stream will show.
//   - scene "screen"/"pip": desktop snapshot refreshed every ~2s via grim
//     (Hyprland screencopy — no portal dialogs), camera tile on top in pip
//   - scene "camera":       the webcam fills the canvas, fully live
// The camera is true live video (Qt Camera); the desktop layer is a fast
// slideshow because Wayland has no dialog-free continuous capture for us.
Item {
  id: root

  property string scene: "screen"
  property bool streaming: false
  property string elapsedText: ""
  property real pipXPct: 72        // camera tile position, % of canvas width/height
  property real pipYPct: 62
  property real pipSizePct: 22     // tile width, % of canvas width
  property string cameraDeviceId: ""
  property string cameraSource: "device"
  property string cameraUrl: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.55)
  property string fontFamily: Style.font.family

  signal placementChanged(real xPct, real yPct)

  readonly property bool active: visible && width > 0
  property int shotSeq: 0
  property bool shotBusy: false

  implicitHeight: width * 9 / 16

  MediaDevices { id: mediaDevices }

  // Native resolution of the active camera format (falls back to a common
  // UVC default until the camera reports one). Drives the tile's aspect so
  // there are never letterbox bars or padding around the feed.
  readonly property var camResolution: {
    var f = camera.cameraFormat
    if (f && f.resolution && f.resolution.width > 0 && f.resolution.height > 0)
      return f.resolution
    return Qt.size(640, 480)
  }

  function selectedDevice() {
    var want = String(cameraDeviceId || "")
    var list = mediaDevices.videoInputs || []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].id) === want) return list[i]
    return mediaDevices.defaultVideoInput
  }

  function takeShot() {
    if (!root.active || root.scene === "camera" || root.shotBusy) return
    root.shotBusy = true
    shotProc.running = true
  }

  Timer {
    id: shotTimer
    interval: 2000
    repeat: true
    running: root.active && root.scene !== "camera"
    triggeredOnStart: true
    onTriggered: root.takeShot()
  }

  Process {
    id: shotProc
    command: ["grim", "-t", "jpeg", "-q", "55", "/tmp/omastream-desktop.jpg"]
    onExited: function(code) {
      root.shotBusy = false
      if (code === 0) root.shotSeq++
    }
  }

  // ---- Camera layer -------------------------------------------------------
  MediaPlayer {
    id: netPlayer
    source: root.cameraSource === "url" ? root.cameraUrl : ""
    videoOutput: netOut
    onErrorOccurred: function(error, errorString) {
      console.log("[omastream] network camera error: " + errorString)
    }
  }

  // Pause/resume with the page, and never keep a socket open off-tab.
  onVisibleChanged: refreshNetPlayback()
  onCameraSourceChanged: refreshNetPlayback()
  onCameraUrlChanged: refreshNetPlayback()
  function refreshNetPlayback() {
    if (root.visible && root.active && root.cameraSource === "url" && root.scene !== "screen" && root.cameraUrl !== "")
      netPlayer.play()
    else
      netPlayer.stop()
  }

  CaptureSession {
    id: camSession
    camera: Camera {
      id: camera
      cameraDevice: root.selectedDevice()
      active: root.active && root.scene !== "screen"
    }
    videoOutput: camOut
  }

  Rectangle {
    id: canvas
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.space(8) : 0
    color: "#000000"
    clip: true

    Image {
      id: shotImg
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      cache: false
      asynchronous: true
      visible: root.scene !== "camera"
      source: root.scene !== "camera" && root.shotSeq > 0
        ? "file:///tmp/omastream-desktop.jpg?seq=" + root.shotSeq
        : ""
      opacity: root.scene !== "camera" ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    Text {
      visible: root.scene !== "camera" && shotImg.source === ""
      anchors.centerIn: parent
      text: "DESKTOP PREVIEW · UPDATING…"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 2
    }

    

    // Camera tile — full canvas in WEBCAM scene, draggable tile in PIP
    Item {
      id: camTile
      visible: root.scene !== "screen"
      width: root.scene === "camera" ? parent.width : parent.width * root.pipSizePct / 100
      height: root.scene === "camera"
        ? parent.height
        : Math.max(1, width * root.camResolution.height / root.camResolution.width)
      x: root.scene === "camera"
        ? 0
        : Math.max(0, Math.min(parent.width - width, parent.width * root.pipXPct / 100))
      y: root.scene === "camera"
        ? 0
        : Math.max(0, Math.min(parent.height - height, parent.height * root.pipYPct / 100))

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        clip: true

        VideoOutput {
          id: camOut
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectCrop
          visible: root.cameraSource !== "url"
        }

        VideoOutput {
          id: netOut
          anchors.fill: parent
          fillMode: VideoOutput.PreserveAspectFit
          visible: root.cameraSource === "url"
        }

        Text {
          visible: (root.cameraSource === "url" ? !netOut.videoVisible : !camOut.videoVisible)
          anchors.centerIn: parent
          text: root.cameraSource === "url" ? "CONNECTING…" : "CAM"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: root.scene === "pip"
        cursorShape: Qt.OpenHandCursor
        drag.target: camTile
        drag.minimumX: 0
        drag.minimumY: 0
        onPressed: cursorShape = Qt.ClosedHandCursor
        onReleased: {
          cursorShape = Qt.OpenHandCursor
          var xp = Math.round(camTile.x / canvas.width * 100)
          var yp = Math.round(camTile.y / canvas.height * 100)
          root.placementChanged(xp, yp)
        }
      }
    }



    // LIVE badge
    Rectangle {
      visible: root.streaming
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.topMargin: Style.space(8)
      anchors.leftMargin: Style.space(8)
      width: liveRow.implicitWidth + Style.space(12)
      height: liveRow.implicitHeight + Style.space(6)
      radius: height / 2
      color: "#CC220000"

      Row {
        id: liveRow
        anchors.centerIn: parent
        spacing: Style.space(5)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: width
          radius: width / 2
          color: Color.urgent
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "LIVE " + root.elapsedText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }
      }
    }

    Text {
      visible: root.scene !== "pip"
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.bottomMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      text: root.scene === "camera" ? "WEBCAM ONLY" : "FULL SCREEN"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
