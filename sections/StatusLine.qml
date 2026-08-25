import QtQuick
import qs.Commons
import qs.Ui

// Error / status line — fixed slot so status messages never resize the
// panel. `ctrl` is the owning panel root.
Item {
  id: statusLine

  property var ctrl: null

  width: parent.width
  height: Style.space(20)
  clip: true

  Text {
    width: parent.width
    visible: ctrl.lastError !== ""
    text: ctrl.lastError
    color: ctrl.urgent
    font.family: ctrl.contentFontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
