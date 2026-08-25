import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: statusLine
  property var ctrl: null
  width: parent.width
  height: Style.space(16)
  clip: true
  Text {
    width: parent.width
    anchors.verticalCenter: parent.verticalCenter
    visible: ctrl.lastError !== ""
    text: ctrl.lastError
    color: ctrl.urgent
    font.family: ctrl.contentFontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
