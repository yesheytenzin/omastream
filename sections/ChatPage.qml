import QtQuick
import qs.Commons
import qs.Ui

// Page: chat — one column per enabled platform.
// `ctrl` is the owning panel root (provides chatColumns + theme colors).
Column {
  id: chatPage

  property var ctrl: null

  spacing: Style.space(8)

  Row {
    width: parent.width
    height: parent.height
    spacing: Style.space(8)

    Repeater {
      model: ctrl.chatColumns

      Rectangle {
        id: chatCol
        required property var modelData
        readonly property int colCount: ctrl.chatColumns.length
        width: Math.floor((parent.width - Style.space(8) * (colCount - 1)) / colCount)
        height: parent.height
        color: "#000000"
        radius: Style.space(4)
        clip: true

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: Style.space(6)

          Text {
            text: chatCol.modelData.title + " · " + (chatCol.modelData.lines.length || "")
            color: ctrl.dim
            font.family: ctrl.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          Flickable {
            id: chatScroll
            width: parent.width
            height: parent.height - headerLabel.height - Style.space(12)
            contentWidth: width
            contentHeight: msgList.implicitHeight
            clip: true

            property bool pinned: true
            onContentHeightChanged: if (pinned) contentY = Math.max(0, contentHeight - height)
            onDragEnded: pinned = (contentY >= contentHeight - height - Style.space(24))

            Column {
              id: msgList
              width: chatScroll.width
              spacing: Style.space(3)

              Repeater {
                model: chatCol.modelData.lines

                delegate: Text {
                  required property var modelData
                  width: chatScroll.width
                  wrapMode: Text.WrapAnywhere
                  color: ctrl.contentForeground
                  font.family: ctrl.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  text: modelData.u !== "" ? modelData.u + ": " + modelData.m : modelData.m
                }
              }

              Item { width: 1; height: 1 }
            }
          }

          Text {
            id: headerLabel
            visible: chatCol.modelData.lines.length === 0
            text: chatCol.modelData.key === "x" ? "no public chat API" : "waiting for messages…"
            color: ctrl.dim
            font.family: ctrl.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
