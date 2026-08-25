import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: hiddenWorkspaces
  property var ctrl: null
  spacing: Style.space(6)
  width: parent.width

  PanelSectionHeader {
    text: "HIDDEN WORKSPACES"
    foreground: ctrl.contentForeground
    fontFamily: ctrl.contentFontFamily
  }

  Flow {
    width: parent.width
    spacing: Style.space(4)
    Repeater {
      model: ctrl.hyprWorkspaces
      Button {
        required property var modelData
        readonly property int wsId: modelData.id
        readonly property string label: modelData.name !== "" ? modelData.name : String(wsId)
        text: label
        selected: ctrl.isHiddenWs(wsId)
        foreground: ctrl.contentForeground
        fontFamily: ctrl.contentFontFamily
        fontSize: Style.font.bodySmall
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(4)
        onClicked: ctrl.toggleHiddenWs(wsId)
      }
    }
    Text {
      leftPadding: Style.space(4)
      topPadding: Style.space(4)
      text: ctrl.wsPaused ? "\u25CF PAUSED" : ""
      color: ctrl.liveColor
      font.family: ctrl.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
