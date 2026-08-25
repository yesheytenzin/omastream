import qs.Ui

// The single action: starts or stops every enabled platform.
// `ctrl` is the owning panel root.
Button {
  id: goLiveButton

  property var ctrl: null

  width: parent.width
  leftAlign: true
  bordered: true
  text: ctrl.live ? "■ STOP STREAMING" : "● GO LIVE — ALL PLATFORMS"
  selected: ctrl.live
  foreground: ctrl.contentForeground
  accent: ctrl.liveColor
  fontFamily: ctrl.contentFontFamily
  onClicked: ctrl.toggleStream()
}
