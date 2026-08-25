import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Program monitor: a 16:9 canvas mirroring what the stream will show.
//   - desktop layer:  snapshot refreshed every ~2s via grim (no dialogs)
//   - camera tile:    snapshot refreshed by the panel's ffmpeg grabber
// Both are fast slideshows — deliberate: Wayland gives us no dialog-free
// continuous capture, and idle previews don't need 60fps. During GO LIVE
// the real compositor is gpu-screen-recorder + the overlay window.
Item {
  id: root

  property string scene: "screen"
  property bool streaming: false
  property string elapsedText: ""
  property real pipXPct: 72        // camera tile position, % of canvas width/height
  property real pipYPct: 62
  property real pipSizePct: 22     // tile width, % of canvas width
  property int camShotSeq: 0       // bumped by the panel each camera frame
  property bool camGrabbing: false // true while the panel's ffmpeg grab runs
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.55)
  property string fontFamily: Style.font.family

  signal placementChanged(real xPct, real yPct)

  readonly property bool active: visible && width > 0
  property int shotSeq: 0
  property bool shotBusy: false

  implicitHeight: width * 9 / 16

  function takeShot() {
    if (!root.active || root.scene === "camera" || root.shotBusy) return
    root.shotBusy = true
    shotProc.running = true
  }

  Timer {
    id: shotTimer
    interval: 33
    repeat: true
    running: root.active && root.scene !== "camera"
    triggeredOnStart: true
    onTriggered: root.takeShot()
  }

  Process {
    id: shotProc
    // Atomic write: readers never see a half-written file.
    command: ["bash", "-c",
      'grim -t jpeg -q 72 /tmp/.omastream-desktop-new.jpg '
      + '&& mv /tmp/.omastream-desktop-new.jpg /tmp/omastream-desktop.jpg']
    onExited: function(code) {
      root.shotBusy = false
      if (code === 0) root.shotSeq++
    }
  }

  Rectangle {
    id: canvas
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.space(8) : 0
    color: "#000000"
    clip: true

    // ---- Desktop layer (grim snapshots) -----------------------------------
    Image {
      id: shotImg
      anchors.fill: parent
      fillMode: Image.PreserveAspectCrop
      cache: false
      asynchronous: false
      sourceSize: Qt.size(width * Screen.devicePixelRatio || width, height * Screen.devicePixelRatio || height)
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

    // ---- Camera tile -------------------------------------------------------
    Item {
      id: camTile
      visible: root.scene !== "screen"
      width: root.scene === "camera" ? parent.width : parent.width * root.pipSizePct / 100
      height: root.scene === "camera"
        ? parent.height
        : Math.max(1, width * 3 / 4) // UVC default 640x480
      x: root.scene === "camera"
        ? 0
        : Math.max(0, Math.min(parent.width - width, (parent.width - width) * root.pipXPct / 100))
      y: root.scene === "camera"
        ? 0
        : Math.max(0, Math.min(parent.height - height, (parent.height - height) * root.pipYPct / 100))

      Rectangle {
        anchors.fill: parent
        color: "#101010"

        Image {
          id: camImg
          anchors.fill: parent
          fillMode: Image.PreserveAspectCrop
          cache: false
          asynchronous: false
          sourceSize: Qt.size(width * Screen.devicePixelRatio || width, height * Screen.devicePixelRatio || height)
          source: root.camGrabbing && root.camShotSeq > 0
            ? "file:///tmp/omastream-cam.jpg?seq=" + root.camShotSeq
            : ""
        }

        Text {
          visible: camImg.source === ""
          anchors.centerIn: parent
          text: root.camGrabbing ? "CAM · UPDATING…" : "CAMERA OFF"
          color: "#888888"
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
          var availW = Math.max(1, canvas.width - camTile.width)
          var availH = Math.max(1, canvas.height - camTile.height)
          var xp = Math.round(camTile.x / availW * 100)
          var yp = Math.round(camTile.y / availH * 100)
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
  }
}
