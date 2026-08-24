import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// oma-stream bar widget: a dot that turns into a live elapsed timer while a
// simulcast is running, and opens the control panel on click.
BarWidget {
  id: root
  moduleName: "user.omastream"

  // Mirrored from the loaded panel so the label stays honest even when the
  // panel itself is closed.
  readonly property bool live: panelLoader.item ? panelLoader.item.live === true : false
  readonly property string elapsedText: panelLoader.item ? String(panelLoader.item.elapsedText || "") : ""
  readonly property string displayText: live ? "● LIVE " + elapsedText : "stream"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---- Panel forwarding — required for shell summon/hide/toggle routing ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // The open-panel indicator dot under the pill.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "user.omastream"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // Start or stop every enabled platform from scripts/keybinds.
    function toggleStream(): void {
      if (panelLoader.item && panelLoader.item.toggleStream) panelLoader.item.toggleStream()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayText
    labelVisible: true
    hasVisualContent: true
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.live
      ? "Streaming to " + (panelLoader.item ? String(panelLoader.item.activeCount) : "?") + " platform(s) — click for controls"
      : "oma-stream — click to configure and go live"

    onPressed: function(b) {
      if (b !== Qt.RightButton) root.togglePanel()
    }
  }
}
