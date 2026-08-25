import QtQuick
import qs.Commons
import qs.Ui

// Hidden-workspace privacy controls: pick workspaces whose windows are
// excluded from capture while live. `ctrl` is the owning panel root.
Column {
  id: hiddenWorkspaces

  property var ctrl: null

  spacing: Style.space(8)

  PanelSectionHeader {
    text: "HIDDEN WORKSPACES"
    foreground: ctrl.contentForeground
    fontFamily: ctrl.contentFontFamily
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)

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
        onClicked: ctrl.toggleHiddenWs(wsId)
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: ctrl.wsPaused ? "● PAUSED" : ""
      color: ctrl.liveColor
      font.family: ctrl.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
