import qs.Commons
import qs.Ui

Button {
  id: goLiveButton
  property var ctrl: null
  width: parent.width
  implicitHeight: Style.spacing.controlHeight + Style.space(4)
  leftAlign: true
  bordered: true
  text: ctrl.live ? "■ STOP STREAMING" : "● GO LIVE — ALL PLATFORMS"
  selected: ctrl.live
  foreground: ctrl.contentForeground
  accent: ctrl.liveColor
  fontFamily: ctrl.contentFontFamily
  fontSize: Style.font.bodySmall
  horizontalPadding: Style.space(8)
  verticalPadding: Style.space(6)
  onClicked: ctrl.toggleStream()
}
