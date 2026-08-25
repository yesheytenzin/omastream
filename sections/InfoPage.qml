import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: infoPage
  property var ctrl: null
  spacing: Style.space(8)
  width: parent.width

  PanelSectionHeader {
    text: "SCHEDULED START"
    foreground: ctrl.contentForeground
    fontFamily: ctrl.contentFontFamily
  }

  Row {
    width: parent.width
    spacing: Style.space(4)
    TextField {
      width: Style.space(84)
      implicitHeight: Style.spacing.controlHeight
      foreground: ctrl.contentForeground
        font.pixelSize: Style.font.bodySmall
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
      leftPadding: Style.space(4)
      text: ctrl.schedCountdown
      color: ctrl.dim
      font.family: ctrl.contentFontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      width: parent.width - Style.space(140)
    }
  }
}
