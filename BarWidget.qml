import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point for OmarchWeb. A web/globe icon with a small status dot that
// turns accent-colored while any managed web service is running. Clicking
// opens the control panel (services / databases / virtual hosts).
BarWidget {
  id: root
  moduleName: "io.github.giodc.omarchweb"

  readonly property bool anyRunning: panelLoader.item ? panelLoader.item.anyRunning : false
  readonly property color dotColor: panelLoader.item ? panelLoader.item.anyRunning ? Color.accent : Color.urgent : Color.urgent

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

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // Status dot: accent (running) or urgent (all stopped).
  Rectangle {
    width: Style.space(8)
    height: Style.space(8)
    radius: width / 2
    color: root.dotColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: Style.space(1)
    anchors.bottomMargin: Style.space(1)
    opacity: root.anyRunning ? 1.0 : 0.85
  }
}
