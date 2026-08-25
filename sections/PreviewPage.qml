import QtQuick
import qs.Commons
import qs.Ui
import ".."

Column {
  id: previewPage
  property var ctrl: null
  spacing: Style.space(6)
  width: parent.width

  Monitor {
    width: parent.width
    implicitHeight: width * 9 / 16
    scene: ctrl.scene
    streaming: ctrl.live
    elapsedText: ctrl.elapsedText
    pipXPct: Number(ctrl.cfg.pipXPct) || 72
    pipYPct: Number(ctrl.cfg.pipYPct) || 62
    pipSizePct: Number(ctrl.cfg.pipSizePct) || 22
    camShotSeq: ctrl.camShotSeq
    camGrabbing: ctrl.camGrabRunning
    fg: ctrl.contentForeground
    fontFamily: ctrl.contentFontFamily
    onPlacementChanged: function(xp, yp) { ctrl.updateGlobal({ pipXPct: xp, pipYPct: yp }) }
  }
}
