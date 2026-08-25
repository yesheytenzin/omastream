import QtQuick
import qs.Commons
import qs.Ui
import "../Stream.js" as Stream

Column {
  id: platformsPage
  property var ctrl: null
  spacing: Style.space(8)
  width: parent.width

  Repeater {
    model: Stream.platforms()
    Column {
      id: platformBlock
      required property var modelData
      width: parent.width
      spacing: Style.space(6)

      readonly property var entry: ctrl.entryFor(modelData.id)
      property bool keyDirty: false
      readonly property bool hasKey: ctrl.keyPresent[modelData.id] === true
      readonly property bool streaming: ctrl.live && entry.enabled === true && ctrl.procFor(modelData.id).running

      Item {
        width: parent.width
        implicitHeight: Math.max(platformLabel.implicitHeight, platformSwitch.implicitHeight)
        Rectangle {
          id: statusDot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: width
          radius: width / 2
          color: streaming ? ctrl.liveColor : (parent.parent.enabled ? ctrl.dim : "transparent")
          border.width: 1
          border.color: ctrl.dim
        }
        Text {
          id: platformLabel
          anchors.left: statusDot.right
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: platformBlock.modelData.label.toUpperCase()
          color: ctrl.contentForeground
          font.family: ctrl.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1.0
        }
        ToggleSwitch {
          id: platformSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: platformBlock.entry.enabled
          foreground: ctrl.contentForeground
          onToggled: ctrl.updateEntry(platformBlock.modelData.id, { enabled: !ctrl.entryFor(platformBlock.modelData.id).enabled })
        }
      }

      TextField {
        width: parent.width
        implicitHeight: Style.spacing.controlHeight
        foreground: ctrl.contentForeground
        font.pixelSize: Style.font.bodySmall
        text: platformBlock.entry.url
        placeholderText: platformBlock.modelData.id === "x" ? "rtmp://<region>.pscp.tv:80/x — from X Producer" : "RTMP(S) ingest URL"
        onEditingFinished: {
          if (platformBlock.modelData.id === "twitch") ctrl.ingestStatus = ""
          ctrl.updateEntry(platformBlock.modelData.id, { url: text.trim() })
        }
      }

      Row {
        visible: platformBlock.modelData.id === "twitch"
        width: parent.width
        spacing: Style.space(4)
        Button {
          text: "◎ PICK FASTEST INGEST"
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: ctrl.pickTwitchIngest()
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: ctrl.ingestStatus
          color: ctrl.dim
          font.family: ctrl.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          width: parent.width - Style.space(140)
        }
      }

      TextField {
        visible: platformBlock.modelData.id === "twitch"
        width: parent.width
        implicitHeight: Style.spacing.controlHeight
        foreground: ctrl.contentForeground
        font.pixelSize: Style.font.bodySmall
        text: String(ctrl.cfg.chatTwitchChannel || "")
        placeholderText: "Channel name — enables TWITCH chat"
        onEditingFinished: ctrl.updateGlobal({ chatTwitchChannel: text.trim() })
      }

      TextField {
        visible: platformBlock.modelData.id === "youtube"
        width: parent.width
        implicitHeight: Style.spacing.controlHeight
        foreground: ctrl.contentForeground
        font.pixelSize: Style.font.bodySmall
        text: String(ctrl.cfg.chatYoutubeId || "")
        placeholderText: "Video ID (watch?v=…) — enables YOUTUBE chat"
        onEditingFinished: ctrl.updateGlobal({ chatYoutubeId: text.trim() })
      }

      Row {
        width: parent.width
        spacing: Style.space(4)
        TextField {
          id: keyField
          width: parent.width - Style.space(68)
          implicitHeight: Style.spacing.controlHeight
          foreground: ctrl.contentForeground
        font.pixelSize: Style.font.bodySmall
          password: true
          property bool clearing: false
          placeholderText: platformBlock.hasKey ? "Stored in keyring — paste to replace" : "Stream key"
          onTextChanged: if (!clearing) platformBlock.keyDirty = true
        }
        Button {
          width: Style.space(64)
          text: "SAVE KEY"
          selected: platformBlock.keyDirty
          bordered: true
          foreground: ctrl.contentForeground
          fontFamily: ctrl.contentFontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(4)
          onClicked: {
            var secret = keyField.text.trim()
            platformBlock.keyDirty = false
            keyField.clearing = true
            keyField.text = ""
            keyField.clearing = false
            ctrl.storeKey(platformBlock.modelData.id, secret)
          }
        }
      }
    }
  }
}
