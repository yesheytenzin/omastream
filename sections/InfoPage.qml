import QtQuick
import qs.Commons
import qs.Ui

// Page: stream info — scheduled start time and auto-start toggle.
// `ctrl` is the owning panel root.
Column {
  id: infoPage

  property var ctrl: null

  spacing: Style.space(12)

  PanelSectionHeader {
    text: "SCHEDULED START"
    foreground: ctrl.contentForeground
    fontFamily: ctrl.contentFontFamily
  }

  Row {
    spacing: Style.space(8)

    TextField {
      width: Style.space(90)
      foreground: ctrl.contentForeground
      text: String(ctrl.cfg.startTime)
      placeholderText: "HH:MM"
      onEditingFinished: ctrl.updateGlobal({ startTime: text.trim() })
    }

    ToggleSwitch {
      anchors.verticalCenter: parent.verticalCenter
      checked: String(ctrl.cfg.autoStart) === "true"
      foreground: ctrl.contentForeground
      onToggled: ctrl.updateGlobal({ autoStart: String(ctrl.cfg.autoStart) === "true" ? false : true })
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: ctrl.schedCountdown
      color: ctrl.dim
      font.family: ctrl.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
