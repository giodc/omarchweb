import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point for OmarchWeb. Globe icon is accent-colored while any
// managed web service is running, urgent when all are stopped. Clicking
// opens the control panel (services / databases / virtual hosts).
BarWidget {
  id: root
  moduleName: "io.github.giodc.omarchweb"

  readonly property bool anyRunning: panelLoader.item ? panelLoader.item.anyRunning : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refreshAll) panelLoader.item.refreshAll(true)
  }

  // Shape contract for shell summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖟"
    slotSize: Style.bar.statusSlot
    active: root.anyRunning
    useActiveColor: true
    activeColor: Color.accent
    foreground: Color.urgent
    tooltipText: "OmarchWeb"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }
}
