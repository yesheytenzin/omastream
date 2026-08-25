import QtQuick
import qs.Commons
import qs.Ui
import "../Stream.js" as Stream

// Compact, uniform stream settings — same height/width, responsive.
Column {
  id: streamPage
  property var ctrl: null
  spacing: Style.space(8)
  width: parent.width

  Column {
    width: parent.width
    spacing: Style.space(6)

    Column {
      visible: ctrl.gsrMissing
      width: parent.width
      spacing: Style.space(6)
      Row {
        spacing: Style.space(4)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "gpu-screen-recorder missing"
          color: ctrl.urgent
          font.family: ctrl.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          text: "INSTALL"
          bordered: true
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: ctrl.installGsr()
        }
      }
    }

    PanelSectionHeader {
      text: "SCENE"
      foreground: ctrl.contentForeground
      fontFamily: ctrl.contentFontFamily
    }

    Row {
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: [
          { id: "screen", label: "🖥 SCREEN" },
          { id: "pip",    label: "🖥+🎥 PIP" },
          { id: "camera", label: "🎥 WEBCAM" }
        ]
        Button {
          required property var modelData
          text: modelData.label
          selected: ctrl.scene === modelData.id
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: ctrl.updateGlobal({ scene: modelData.id })
        }
      }
    }

    Column {
      visible: ctrl.scene !== "screen"
      width: parent.width
      spacing: Style.space(6)

      Row {
        width: parent.width
        spacing: Style.space(4)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(52)
          text: "SOURCE"
          color: ctrl.dim
          font.family: ctrl.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          text: "WEBCAM / CAPTURE CARD"
          selected: String(ctrl.cfg.cameraSource) !== "url"
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: ctrl.updateGlobal({ cameraSource: "device" })
        }
        Button {
          text: "PHONE / IP CAM"
          selected: String(ctrl.cfg.cameraSource) === "url"
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: ctrl.updateGlobal({ cameraSource: "url" })
        }
      }

      TextField {
        visible: ctrl.scene !== "screen" && String(ctrl.cfg.cameraSource) === "url"
        width: parent.width
        implicitHeight: Style.spacing.controlHeight
        foreground: ctrl.contentForeground
        font.pixelSize: Style.font.bodySmall
        text: String(ctrl.cfg.cameraUrl)
        placeholderText: "http://192.168.1.5:8080/video · rtsp://…"
        onEditingFinished: ctrl.updateGlobal({ cameraUrl: text.trim() })
      }

      Dropdown {
        visible: ctrl.scene !== "screen" && String(ctrl.cfg.cameraSource) !== "url"
        width: parent.width
        implicitHeight: Style.spacing.controlHeight
        showLabel: false
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        options: ctrl.cameras.length > 0
          ? ctrl.cameras.map(function(d) { return String(d.description) })
          : ["No cameras detected"]
        value: ctrl.cameraName !== "" ? ctrl.cameraName : (ctrl.cameras.length > 0 ? "Select camera" : "No cameras detected")
        enabled: ctrl.cameras.length > 0
        onChanged: function(desc) { ctrl.selectCamera(desc) }
      }

      Row {
        visible: ctrl.scene === "pip"
        width: parent.width
        spacing: Style.space(4)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(52)
          text: "CAM SIZE"
          color: ctrl.dim
          font.family: ctrl.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Repeater {
          model: [{ v: 15, label: "S" }, { v: 22, label: "M" }, { v: 30, label: "L" }]
          Button {
            required property var modelData
            text: modelData.label
            selected: Number(ctrl.cfg.pipSizePct) === modelData.v
            foreground: ctrl.contentForeground
            fontFamily: ctrl.contentFontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(4)
            onClicked: ctrl.updateGlobal({ pipSizePct: modelData.v })
          }
        }
      }

      Button {
        visible: ctrl.scene === "pip"
        width: parent.width
        text: ctrl.camPreviewOn ? "■ CLOSE CAMERA PREVIEW" : "◎ PREVIEW & ARRANGE CAMERA"
        selected: ctrl.camPreviewOn
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(4)
        onClicked: ctrl.toggleCamPreview()
      }
    }
  }

  PanelSeparator { foreground: ctrl.contentForeground }

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: "CAPTURE"
      foreground: ctrl.contentForeground
      fontFamily: ctrl.contentFontFamily
    }

    Row {
      width: parent.width
      spacing: Style.space(4)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(52)
        text: "FPS"
        color: ctrl.dim
        font.family: ctrl.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        text: "30"
        selected: Number(ctrl.cfg.fps) === 30
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(4)
        onClicked: ctrl.updateGlobal({ fps: 30 })
      }
      Button {
        text: "60"
        selected: Number(ctrl.cfg.fps) === 60
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(4)
        onClicked: ctrl.updateGlobal({ fps: 60 })
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        leftPadding: Style.space(4)
        text: ctrl.displayHz > 0 ? "· " + ctrl.displayHz + " Hz" : ""
        color: ctrl.dim
        font.family: ctrl.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(4)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(52)
        text: "OUTPUT"
        color: ctrl.dim
        font.family: ctrl.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Dropdown {
        width: parent.width - Style.space(56)
        implicitHeight: Style.spacing.controlHeight
        showLabel: false
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        options: Stream.resolutions().map(function(r) { return r.label })
        value: Stream.resolutionLabel(ctrl.cfg.resolution)
        onChanged: function(label) { ctrl.updateGlobal({ resolution: Stream.selectResolution(label) }) }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(4)
      Text {
        width: Style.space(52)
        text: "BITRATE"
        color: ctrl.dim
        font.family: ctrl.contentFontFamily
        font.pixelSize: Style.font.bodySmall
        topPadding: Style.space(6)
      }
      Repeater {
        model: ["low", "medium", "high"]
        Button {
          required property string modelData
          text: modelData
          selected: String(ctrl.cfg.quality) === modelData
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: ctrl.updateGlobal({ quality: modelData })
        }
      }
    }

    Dropdown {
      width: parent.width
      implicitHeight: Style.spacing.controlHeight
      showLabel: false
      foreground: ctrl.contentForeground
      fontFamily: ctrl.contentFontFamily
      options: {
        var opts = ctrl.audioDevices.map(function(d) { return d.label })
        if (ctrl.audioDevices.length === 0 && String(ctrl.cfg.audio) !== "") opts.push(String(ctrl.cfg.audio))
        return opts
      }
      value: {
        for (var i = 0; i < ctrl.audioDevices.length; i++)
          if (ctrl.audioDevices[i].id === String(ctrl.cfg.audio)) return ctrl.audioDevices[i].label
        return String(ctrl.cfg.audio)
      }
      enabled: ctrl.audioDevices.length > 0
      onChanged: function(label) {
        for (var i = 0; i < ctrl.audioDevices.length; i++)
          if (ctrl.audioDevices[i].label === label) { ctrl.updateGlobal({ audio: ctrl.audioDevices[i].id }); return }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(4)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(52)
        text: "SOURCE"
        color: ctrl.dim
        font.family: ctrl.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Dropdown {
        width: parent.width - Style.space(56)
        implicitHeight: Style.spacing.controlHeight
        showLabel: false
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        options: {
          var opts = ["All screens"]
          ctrl.monitorList.forEach(function(m) { opts.push(m.label) })
          opts.push("Portal (choose on stream)")
          opts.push("Focused window")
          if (!["screen", "portal", "focused"].includes(String(ctrl.cfg.capture))
              && ctrl.monitorList.every(function(m) { return m.id !== String(ctrl.cfg.capture) }))
            opts.push(String(ctrl.cfg.capture))
          return opts
        }
        value: {
          var c = String(ctrl.cfg.capture)
          if (c === "screen") return "All screens"
          if (c === "portal") return "Portal (choose on stream)"
          if (c === "focused") return "Focused window"
          for (var i = 0; i < ctrl.monitorList.length; i++)
            if (ctrl.monitorList[i].id === c) return ctrl.monitorList[i].label
          return c
        }
        onChanged: function(label) {
          if (label === "All screens") { ctrl.updateGlobal({ capture: "screen" }); return }
          if (label === "Portal (choose on stream)") { ctrl.updateGlobal({ capture: "portal" }); return }
          if (label === "Focused window") { ctrl.updateGlobal({ capture: "focused" }); return }
          for (var i = 0; i < ctrl.monitorList.length; i++)
            if (ctrl.monitorList[i].label === label) { ctrl.updateGlobal({ capture: ctrl.monitorList[i].id }); return }
          ctrl.updateGlobal({ capture: label })
        }
      }
    }
  }
}
