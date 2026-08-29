import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.giodc.omarchweb"
  ipcTarget: "io.github.giodc.omarchweb"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshMs: Math.max(5000, parseInt(setting("refreshSeconds", 30), 10) || 30) * 1000
  readonly property string webRoot: setting("webRoot", "~/Web")
  readonly property int nginxPort: parseInt(setting("nginxPort", 80), 10) || 80

  // ---- Tabs ----
  property string tab: "services"

  // ---- Services state ----
  property var services: []
  property bool servicesLoaded: false
  property string installingService: ""
  property string setupAction: "" // "install" | "uninstall"
  readonly property bool anyRunning: {
    for (var i = 0; i < services.length; i++)
      if (services[i].running) return true
    return false
  }
  readonly property var serviceKinds: [
    { key: "php-fpm",  name: "PHP-FPM",   icon: "" },
    { key: "mariadb",  name: "MariaDB",   icon: "󱓥" },
    { key: "nginx",    name: "Nginx",     icon: "󰈂" },
    { key: "postgresql", name: "PostgreSQL", icon: "" },
    { key: "redis",    name: "Redis",     icon: "󰍥" },
    { key: "mailpit",  name: "Mailpit",   icon: "󰇮", url: "http://127.0.0.1:8025" }
  ]

  // ---- Databases state ----
  property var databases: []
  property var dbUsers: []
  property var dbAccess: ({ mariadb: "", postgresql: "" })
  property bool dbLoaded: false
  property string dbEngine: "mariadb"
  readonly property var dbEngineKinds: [
    { key: "mariadb", name: "MariaDB", icon: "󱓥" },
    { key: "postgresql", name: "PostgreSQL", icon: "" }
  ]
  readonly property bool dbTabOpen: tab === "mariadb" || tab === "postgresql"
  readonly property var panelTabs: {
    var tabs = [{ key: "services", label: "Services" }]
    if (root.serviceInstalled("mariadb"))
      tabs.push({ key: "mariadb", label: "MariaDB" })
    if (root.serviceInstalled("postgresql"))
      tabs.push({ key: "postgresql", label: "PostgreSQL" })
    tabs.push({ key: "vhosts", label: "Vhosts" })
    return tabs
  }
  readonly property var visibleDatabases: {
    var engine = dbEngine
    var src = databases
    var out = []
    for (var i = 0; i < src.length; i++) {
      if (src[i] && src[i].engine === engine) out.push(src[i])
    }
    return out
  }
  readonly property var visibleDbUsers: {
    var engine = dbEngine
    var src = dbUsers
    var out = []
    for (var i = 0; i < src.length; i++) {
      if (src[i] && src[i].engine === engine) out.push(src[i])
    }
    return out
  }
  readonly property string dbEngineLabel: {
    for (var i = 0; i < dbEngineKinds.length; i++)
      if (dbEngineKinds[i].key === dbEngine) return dbEngineKinds[i].name
    return dbEngine
  }
  readonly property string dbAccessState: {
    if (!dbAccess) return ""
    return dbAccess[dbEngine] || ""
  }
  readonly property string dbEmptyMessage: {
    if (!dbLoaded) return ""
    var st = dbAccessState
    var name = dbEngineLabel
    if (st === "missing" || (root.servicesLoaded && !root.serviceInstalled(dbEngine) && st !== "ok"))
      return name + " is not installed (install it in Services)"
    if (st === "down")
      return "database server not running (start " + name + " in Services)"
    if (st === "no-role" || st === "denied")
      return name + " access is not set up for your user"
    if (st !== "ok" && root.servicesLoaded && !root.serviceRunning(dbEngine))
      return "database server not running (start " + name + " in Services)"
    if (visibleDatabases.length === 0)
      return "no databases yet"
    return ""
  }
  readonly property bool dbCanMutate: {
    var st = dbAccessState
    return st === "ok" || st === "no-role" || st === "denied" || st === "error" || st === ""
  }

  // ---- Vhosts state ----
  property var vhosts: []
  property bool vhostsLoaded: false

  // ---- Transient messages ----
  property string notice: ""
  property string noticeColor: "transparent"
  property bool busy: false

  property string actionLog: ""

  function setActionLog(stdout, stderr) {
    var text = Model.clean(stdout || "")
    var err = Model.clean(stderr || "")
    if (err.trim() !== "") {
      if (text.trim() !== "") text += "\n"
      text += err
    }
    actionLog = text.trim()
  }

  function copyLogs() {
    if (!actionLog || !root.bar) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(actionLog) + " | wl-copy"])
    setNotice("logs copied to clipboard", false)
  }

  function scriptPath(name) {
    var url = Qt.resolvedUrl("scripts/" + name)
    var s = String(url)
    if (s.indexOf("file://") === 0) s = s.substring("file://".length)
    return s
  }

  function setNotice(text, isError) {
    notice = text
    noticeColor = isError ? Color.urgent : Color.accent
    noticeTimer.restart()
  }

  // manual=true: user clicked reload — force-restart procs and show feedback.
  function refreshAll(manual) {
    if (!opened) return
    if (manual === true) {
      busy = true
      refreshBusyTimer.restart()
    }
    refreshServices()
    refreshDatabases()
    refreshVhosts()
  }

  // Prefer exec() so a click always restarts even when command is unchanged.
  function refreshServices() {
    servicesProc.exec([ scriptPath("services.sh"), "status" ])
  }

  function refreshDatabases() {
    dbProc.exec([ scriptPath("db.sh"), "list" ])
  }

  function refreshVhosts() {
    vhostProc.exec([ scriptPath("vhost.sh"), "list" ])
  }

  function serviceRunning(key) {
    for (var i = 0; i < services.length; i++)
      if (services[i].key === key && services[i].running) return true
    return false
  }

  function serviceInstalled(key) {
    for (var i = 0; i < services.length; i++)
      if (services[i].key === key && services[i].installed) return true
    return false
  }

  function ensureDbEngine() {
    if (tab === "mariadb" || tab === "postgresql") {
      if (servicesLoaded && !serviceInstalled(tab)) {
        tab = "services"
        return
      }
      dbEngine = tab
      return
    }
    if (serviceInstalled(dbEngine)) return
    if (serviceRunning("mariadb")) { dbEngine = "mariadb"; return }
    if (serviceRunning("postgresql")) { dbEngine = "postgresql"; return }
    if (serviceInstalled("mariadb")) { dbEngine = "mariadb"; return }
    if (serviceInstalled("postgresql")) { dbEngine = "postgresql"; return }
    if (dbEngine === "") dbEngine = "mariadb"
  }

  // ---- Service actions ----
  property string actingService: ""
  function actService(key, action) {
    actingService = key
    busy = true
    serviceActionProc.command = [ scriptPath("services.sh"), action, key ]
    serviceActionProc.running = true
  }

  function startService(key) { actService(key, "start") }
  function stopService(key) { actService(key, "stop") }
  function restartService(key) { actService(key, "restart") }

  // ---- Database actions ----
  property string newDbName: ""
  property string newDbUserName: ""
  property string newDbUserPass: ""
  function runDbAction(args) {
    busy = true
    dbActionProc.command = args
    dbActionProc.running = true
  }
  function createDb() {
    var name = String(newDbName).trim()
    if (!name) return
    runDbAction([ scriptPath("db.sh"), "create", dbEngine, name ])
  }
  function deleteDb(name) {
    runDbAction([ scriptPath("db.sh"), "delete", dbEngine, name ])
  }
  function createDbUser() {
    var name = String(newDbUserName).trim()
    var pass = String(newDbUserPass)
    if (!name || !pass) {
      setNotice("user needs a name and password", true)
      return
    }
    busy = true
    // Password goes over stdin, never argv (/proc is world-readable).
    dbUserCreateProc.secret = pass
    dbUserCreateProc.command = [ scriptPath("db.sh"), "user-create", dbEngine, name ]
    dbUserCreateProc.running = true
  }
  function deleteDbUser(name) {
    runDbAction([ scriptPath("db.sh"), "user-delete", dbEngine, name ])
  }
  function grantDb() {
    runDbAction([ scriptPath("db.sh"), "grant", dbEngine ])
  }
  function finishDbAction(exitCode, errText, outText) {
    busy = false
    setActionLog(outText, errText)
    if (exitCode !== 0) {
      setNotice(Model.clean(errText || outText) || "database operation failed", true)
      return
    }
    setNotice(Model.clean(outText) || "database operation done", false)
    newDbName = ""
    newDbUserName = ""
    newDbUserPass = ""
    refreshDatabases()
  }

  // ---- Vhost actions ----
  property string newVhostName: ""
  property string newVhostType: "php"
  property string newVhostHost: ""
  property string newVhostRoot: ""
  property int newVhostPort: nginxPort

  function expandHome(p) {
    var s = String(p || "").trim()
    var home = Quickshell.env("HOME") || ""
    if (!home) return s
    var broken = home + "/~/"
    if (s.indexOf(broken) === 0) s = home + "/" + s.substring(broken.length)
    if (s === home + "/~") s = home
    if (s === "~") return home
    if (s.indexOf("~/") === 0) return home + s.substring(1)
    if (s.indexOf("$HOME/") === 0) return home + s.substring(5)
    if (s !== "" && s.charAt(0) !== "/") return home + "/" + s
    return s
  }

  function addVhost() {
    var name = String(newVhostName).trim()
    if (!name) { setNotice("vhost needs a name", true); return }
    busy = true
    var projectRoot = String(newVhostRoot).trim()
    if (!projectRoot) {
      projectRoot = expandHome(String(webRoot).replace(/\/$/, "")) + "/" + name
      if (newVhostType === "laravel") projectRoot += "/public"
    } else {
      projectRoot = expandHome(projectRoot)
    }
    var args = [ scriptPath("vhost.sh"), "add", name, newVhostType ]
    // Keep optional arguments in their shell positions.
    args.push(String(newVhostHost).trim())
    args.push(projectRoot)
    args.push(newVhostType === "node" ? String(newVhostPort) : "")
    vhostActionProc.command = args
    vhostActionProc.running = true
  }

  function removeVhost(name) {
    busy = true
    vhostActionProc.command = [ scriptPath("vhost.sh"), "remove", name ]
    vhostActionProc.running = true
  }

  function openUrl(url) {
    var u = String(url || "").trim()
    if (!u) return
    browserProc.command = [ "xdg-open", u ]
    browserProc.running = true
  }

  function openVhost(vhost) {
    var host = String(vhost.host || "").trim()
    if (!host) return
    var url = "http://" + host
    if (root.nginxPort !== 80) url += ":" + root.nginxPort
    browserProc.command = [ "xdg-open", url ]
    browserProc.running = true
  }

  // ---- Setup ----
  function runSetup() {
    busy = true
    installingService = ""
    setupAction = "install"
    setupProc.command = [ scriptPath("setup.sh"), "install" ]
    setupProc.running = true
  }
  function installService(key) {
    busy = true
    installingService = key
    setupAction = "install"
    setupProc.command = [ scriptPath("setup.sh"), "install", key ]
    setupProc.running = true
  }
  function uninstallService(key) {
    busy = true
    installingService = key
    setupAction = "uninstall"
    setupProc.command = [ scriptPath("setup.sh"), "uninstall", key ]
    setupProc.running = true
  }

  // ---- Process handlers ----
  Process {
    id: servicesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.services = Model.parseServiceStatus(text, root.serviceKinds)
        root.servicesLoaded = true
        root.ensureDbEngine()
      }
    }
  }

  Process {
    id: dbProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseDbList(text)
        root.databases = parsed.databases
        root.dbUsers = parsed.users || []
        root.dbAccess = parsed.access
        root.dbAccess = parsed.access
        root.dbLoaded = true
      }
    }
  }

  Process {
    id: vhostProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.vhosts = Model.parseVhosts(text)
        root.vhostsLoaded = true
      }
    }
  }

  Process {
    id: browserProc
  }

  Process {
    id: serviceActionProc
    stdout: StdioCollector { id: serviceActionOut; waitForEnd: true }
    stderr: StdioCollector { id: serviceActionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.setActionLog(serviceActionOut.text, serviceActionErr.text)
      if (exitCode !== 0) {
        root.setNotice(Model.clean(serviceActionErr.text || serviceActionOut.text) || (root.actingService + " failed"), true)
        return
      }
      root.setNotice(Model.clean(serviceActionOut.text) || (root.actingService + " done"), false)
      root.refreshServices()
    }
  }

  Process {
    id: dbActionProc
    stdout: StdioCollector { id: dbActionOut; waitForEnd: true }
    stderr: StdioCollector { id: dbActionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.finishDbAction(exitCode, dbActionErr.text, dbActionOut.text)
    }
  }

  Process {
    id: dbUserCreateProc
    property string secret: ""
    stdinEnabled: true
    stdout: StdioCollector { id: dbUserCreateOut; waitForEnd: true }
    stderr: StdioCollector { id: dbUserCreateErr; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      root.finishDbAction(exitCode, dbUserCreateErr.text, dbUserCreateOut.text)
    }
  }

  Process {
    id: vhostActionProc
    stdout: StdioCollector { id: vhostActionOut; waitForEnd: true }
    stderr: StdioCollector { id: vhostActionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.busy = false
      root.setActionLog(vhostActionOut.text, vhostActionErr.text)
      if (exitCode !== 0) {
        root.setNotice(Model.clean(vhostActionErr.text || vhostActionOut.text) || "vhost operation failed", true)
        return
      }
      root.setNotice(Model.clean(vhostActionOut.text) || "vhost operation done", false)
      root.newVhostName = ""
      root.refreshVhosts()
      root.refreshDatabases()
    }
  }

  Process {
    id: setupProc
    stdout: StdioCollector { id: setupOut; waitForEnd: true }
    stderr: StdioCollector { id: setupErr; waitForEnd: true }
    onExited: function(exitCode) {
      var svc = root.installingService
      var action = root.setupAction
      root.busy = false
      root.installingService = ""
      root.setupAction = ""
      root.setActionLog(setupOut.text, setupErr.text)
      if (exitCode !== 0) {
        root.setNotice(Model.clean(setupErr.text || setupOut.text) || (action === "uninstall" ? "uninstall failed" : "setup failed"), true)
        return
      }
      if (svc !== "")
        root.setNotice(svc + (action === "uninstall" ? " uninstalled" : " installed"), false)
      else
        root.setNotice("setup finished", false)
      root.refreshAll()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMs
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshAll(false)
  }

  Timer {
    id: refreshBusyTimer
    interval: 500
    onTriggered: {
      root.busy = false
      root.setNotice("refreshed", false)
    }
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: root.notice = ""
  }

  // ---- Lifecycle ----
  function open() {
    root.controller.show()
    refreshAll(false)
  }
  function close() {
    root.controller.hide()
  }
  function toggle() {
    root.opened ? close() : open()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  onOpenedChanged: {
    if (opened) refreshAll(false)
  }

  onTabChanged: {
    if (tab === "mariadb" || tab === "postgresql") {
      dbEngine = tab
      if (opened) refreshDatabases()
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll(true) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus || hostField.activeFocus || dbNameField.activeFocus || dbUserNameField.activeFocus || dbUserPassField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // ---- Header ----
          Item {
            width: parent.width
            height: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

            Row {
              id: headerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              Text {
                text: "󰖟"
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: "OMARCHWEB"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: headerRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                visible: root.busy
                text: "…"
                color: Color.accent
                font.family: root.fontName
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: Style.space(28)
                height: Style.space(28)
                radius: Math.min(4, Style.cornerRadius)
                color: refreshArea.containsMouse || root.busy
                  ? Style.hoverFillFor(root.fg, Color.accent)
                  : "transparent"
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: refreshArea.containsMouse || root.busy ? Color.accent : root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshAll(true)
                }
              }
            }
          }

          // ---- Tab bar ----
          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.panelTabs

              Rectangle {
                id: tabPill
                required property var modelData
                readonly property bool selected: root.tab === modelData.key

                width: tabRow.implicitWidth + Style.space(20)
                height: tabRow.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: selected || tabArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, selected ? 0.9 : 0.4)

                Row {
                  id: tabRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)
                  Text {
                    text: tabPill.modelData.label
                    color: tabPill.selected ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    font.bold: tabPill.selected
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: tabArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.tab = tabPill.modelData.key
                }
              }
            }
          }

          // ---- Notice ----
          Text {
            visible: root.notice !== ""
            width: parent.width
            text: root.notice
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.noticeColor
            font.family: root.fontName
            font.pixelSize: Style.font.caption
          }

          // ================= SERVICES TAB =================
          Column {
            visible: root.tab === "services"
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(6)

            // Setup banner when nothing is installed.
            Rectangle {
              visible: root.servicesLoaded && !root.serviceInstalled("php-fpm") && !root.serviceInstalled("mariadb")
              width: parent.width
              implicitHeight: setupRow.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)

              Row {
                id: setupRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  text: "Web stack not installed yet."
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                  width: setupBtn.implicitWidth + Style.space(18)
                  height: Style.space(26)
                  radius: Style.cornerRadius
                  color: setupArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                  Text {
                    id: setupBtn
                    anchors.centerIn: parent
                    text: "Run setup"
                    color: Color.accent
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  MouseArea {
                    id: setupArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.runSetup()
                  }
                }
              }
            }

            Repeater {
              model: root.services

              Rectangle {
                id: svcRow
                required property var modelData
                width: parent.width
                implicitHeight: svcInner.implicitHeight + Style.space(14)
                radius: Style.cornerRadius
                color: svcArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                Item {
                  id: svcInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  implicitHeight: svcText.implicitHeight

                  Rectangle {
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: width / 2
                    color: svcRow.modelData.installed
                      ? (svcRow.modelData.running ? Color.accent : Color.urgent)
                      : root.dim
                    opacity: svcRow.modelData.installed ? 1.0 : 0.4
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: svcRow.modelData.icon
                    color: root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.title
                    width: Style.space(22)
                    horizontalAlignment: Text.AlignHCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(14)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    id: svcText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(36)
                    anchors.right: actionsRow.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    Text {
                      text: svcRow.modelData.name
                      color: root.fg
                      font.family: root.fontName
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                      width: parent.width
                    }
                    Text {
                      text: svcRow.modelData.installed
                        ? (svcRow.modelData.running
                          ? ("running · " + svcRow.modelData.state + (svcRow.modelData.key === "mailpit" ? " · smtp 1025 · ui 8025" : ""))
                          : svcRow.modelData.state)
                        : "not installed"
                      color: root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: parent.width
                    }
                  }

                  Row {
                    id: actionsRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Rectangle {
                      visible: svcRow.modelData.running && svcRow.modelData.url
                      width: openSvcBtn.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: openSvcArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                      Text {
                        id: openSvcBtn
                        anchors.centerIn: parent
                        text: "Open"
                        color: Color.accent
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        id: openSvcArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openUrl(svcRow.modelData.url)
                      }
                    }

                    Rectangle {
                      visible: svcRow.modelData.running
                      width: stopBtn.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: stopArea.containsMouse ? Style.hoverFillFor(root.fg, Color.urgent) : "transparent"
                      Text {
                        id: stopBtn
                        anchors.centerIn: parent
                        text: "Stop"
                        color: Color.urgent
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        id: stopArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.stopService(svcRow.modelData.key)
                      }
                    }

                    Rectangle {
                      visible: root.installingService === svcRow.modelData.key
                      width: installingRow.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: "transparent"
                      Row {
                        id: installingRow
                        anchors.centerIn: parent
                        spacing: Style.space(6)
                        BusyIndicator {
                          width: Style.space(13)
                          height: Style.space(13)
                          running: true
                        }
                        Text {
                          text: root.setupAction === "uninstall" ? "Uninstalling…" : "Installing…"
                          color: Color.accent
                          font.family: root.fontName
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }

                    Rectangle {
                      visible: !svcRow.modelData.installed && root.installingService !== svcRow.modelData.key
                      width: installBtn.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: installArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                      Text {
                        id: installBtn
                        anchors.centerIn: parent
                        text: "Install"
                        color: Color.accent
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        id: installArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.installService(svcRow.modelData.key)
                      }
                    }

                    Rectangle {
                      visible: svcRow.modelData.installed && !svcRow.modelData.running && root.installingService !== svcRow.modelData.key
                      width: uninstallBtn.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: uninstallArea.containsMouse ? Style.hoverFillFor(root.fg, Color.urgent) : "transparent"
                      Text {
                        id: uninstallBtn
                        anchors.centerIn: parent
                        text: "Uninstall"
                        color: Color.urgent
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        id: uninstallArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.uninstallService(svcRow.modelData.key)
                      }
                    }

                    Rectangle {
                      visible: svcRow.modelData.installed && !svcRow.modelData.running && root.installingService !== svcRow.modelData.key
                      width: startBtn.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: startArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                      Text {
                        id: startBtn
                        anchors.centerIn: parent
                        text: "Start"
                        color: Color.accent
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        id: startArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.startService(svcRow.modelData.key)
                      }
                    }

                    Rectangle {
                      visible: svcRow.modelData.installed && svcRow.modelData.running
                      width: restartBtn.implicitWidth + Style.space(16)
                      height: Style.space(24)
                      radius: Style.cornerRadius
                      color: restartArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                      Text {
                        id: restartBtn
                        anchors.centerIn: parent
                        text: "Restart"
                        color: root.fg
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        id: restartArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.restartService(svcRow.modelData.key)
                      }
                    }
                  }
                }

                MouseArea {
                  id: svcArea
                  anchors.fill: parent
                  acceptedButtons: Qt.NoButton
                  propagateComposedEvents: true
                }
              }
            }

            Text {
              visible: root.servicesLoaded
              width: parent.width
              text: "services start/stop via systemd · passwords are handled by the system"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ================= DATABASES TAB (MariaDB / PostgreSQL) =================
          Column {
            visible: root.dbTabOpen
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(8)

            Row {
              visible: root.dbCanMutate
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: dbNameField
                width: parent.width - createDbBtn.width - Style.space(8)
                placeholderText: "new database name"
                foreground: root.fg
                font.family: root.fontName
                text: root.newDbName
                onTextChanged: root.newDbName = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.createDb()
                    event.accepted = true
                  }
                }
              }

              Rectangle {
                id: createDbBtn
                width: Style.space(76)
                height: dbNameField.height
                radius: Style.cornerRadius
                color: createDbArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                Text {
                  anchors.centerIn: parent
                  text: "Create"
                  color: Color.accent
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: createDbArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.createDb()
                }
              }
            }

            Rectangle {
              visible: root.dbAccessState === "no-role" || root.dbAccessState === "denied"
              width: Math.max(Style.space(120), grantBtnText.implicitWidth + Style.space(28))
              height: Style.space(28)
              radius: Style.cornerRadius
              color: grantDbArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.6)
              Text {
                id: grantBtnText
                anchors.centerIn: parent
                text: "Grant access"
                color: Color.accent
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              MouseArea {
                id: grantDbArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.grantDb()
              }
            }

            Text {
              visible: root.dbEmptyMessage !== ""
              width: parent.width
              topPadding: Style.space(6)
              text: root.dbEmptyMessage
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.visibleDatabases

              Rectangle {
                id: dbRow
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(34)
                radius: Style.cornerRadius
                color: dbRowArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: dbRow.modelData.name
                  textFormat: Text.PlainText
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.body
                }

                Rectangle {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: delText.implicitWidth + Style.space(16)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: delArea.containsMouse ? Style.hoverFillFor(root.fg, Color.urgent) : "transparent"
                  Text {
                    id: delText
                    anchors.centerIn: parent
                    text: "Delete"
                    color: Color.urgent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: delArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.deleteDb(dbRow.modelData.name)
                  }
                }

                MouseArea {
                  id: dbRowArea
                  anchors.fill: parent
                  acceptedButtons: Qt.NoButton
                  propagateComposedEvents: true
                }
              }
            }

            PanelSectionHeader {
              visible: root.dbCanMutate
              text: "USERS"
              foreground: root.fg
              fontFamily: root.fontName
            }

            Text {
              visible: root.dbCanMutate
              width: parent.width
              text: root.dbEngine === "postgresql"
                ? "password login at 127.0.0.1 — use in WordPress / apps"
                : "password login at localhost — use in WordPress / apps"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
            }

            Column {
              visible: root.dbCanMutate
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: dbUserNameField
                width: parent.width
                placeholderText: "username"
                foreground: root.fg
                font.family: root.fontName
                text: root.newDbUserName
                onTextChanged: root.newDbUserName = text
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: dbUserPassField
                  width: parent.width - createDbUserBtn.width - Style.space(8)
                  placeholderText: "password"
                  password: true
                  foreground: root.fg
                  font.family: root.fontName
                  text: root.newDbUserPass
                  onTextChanged: root.newDbUserPass = text
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.createDbUser()
                      event.accepted = true
                    }
                  }
                }

                Rectangle {
                  id: createDbUserBtn
                  width: Style.space(76)
                  height: dbUserPassField.height
                  radius: Style.cornerRadius
                  color: createDbUserArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: "Create"
                    color: Color.accent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  MouseArea {
                    id: createDbUserArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.createDbUser()
                  }
                }
              }
            }

            Text {
              visible: root.dbLoaded && root.dbCanMutate && root.visibleDbUsers.length === 0
              width: parent.width
              text: "no app users yet"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.visibleDbUsers

              Rectangle {
                id: dbUserRow
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(34)
                radius: Style.cornerRadius
                color: dbUserRowArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)
                  Text {
                    text: dbUserRow.modelData.name
                    textFormat: Text.PlainText
                    color: root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: dbUserRow.modelData.auth === "unix_socket" || dbUserRow.modelData.auth === "peer"
                      ? "socket (panel / CLI)"
                      : "password"
                    color: root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  visible: dbUserRow.modelData.auth !== "unix_socket" && dbUserRow.modelData.auth !== "peer"
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: delUserText.implicitWidth + Style.space(16)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: delUserArea.containsMouse ? Style.hoverFillFor(root.fg, Color.urgent) : "transparent"
                  Text {
                    id: delUserText
                    anchors.centerIn: parent
                    text: "Delete"
                    color: Color.urgent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: delUserArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.deleteDbUser(dbUserRow.modelData.name)
                  }
                }

                MouseArea {
                  id: dbUserRowArea
                  anchors.fill: parent
                  acceptedButtons: Qt.NoButton
                  propagateComposedEvents: true
                }
              }
            }
          }

          // ================= VHOSTS TAB =================
          Column {
            visible: root.tab === "vhosts"
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: Style.space(8)

            // ---- Add form ----
            Column {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "NEW VIRTUAL HOST"
                foreground: root.fg
                fontFamily: root.fontName
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: nameField
                  width: (parent.width - parent.spacing) * 0.5
                  placeholderText: "project name"
                  foreground: root.fg
                  font.family: root.fontName
                  text: root.newVhostName
                  onTextChanged: root.newVhostName = text
                }

                // Type selector
                Flow {
                  width: (parent.width - parent.spacing) * 0.5
                  spacing: Style.space(4)
                  Repeater {
                    model: [ "php", "wordpress", "laravel", "node" ]
                    Rectangle {
                      id: typePill
                      required property string modelData
                      readonly property bool sel: root.newVhostType === modelData
                      width: typeText.implicitWidth + Style.space(14)
                      height: nameField.height
                      radius: Style.cornerRadius
                      color: sel || typeArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                      border.width: 1
                      border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, sel ? 0.9 : 0.4)
                      Text {
                        id: typeText
                        anchors.centerIn: parent
                        text: typePill.modelData
                        color: typePill.sel ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                        font.bold: typePill.sel
                      }
                      MouseArea {
                        id: typeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.newVhostType = typePill.modelData
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: hostField
                  width: (parent.width - parent.spacing) * 0.4
                  placeholderText: "host (default <name>.test)"
                  foreground: root.fg
                  font.family: root.fontName
                  text: root.newVhostHost
                  onTextChanged: root.newVhostHost = text
                }

                TextField {
                  id: rootField
                  width: (parent.width - parent.spacing) * 0.6
                  placeholderText: "web root (default " + root.webRoot + "/<name>)"
                  foreground: root.fg
                  font.family: root.fontName
                  text: root.newVhostRoot
                  onTextChanged: root.newVhostRoot = text
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  visible: root.newVhostType === "node"
                  id: portField
                  width: parent.width
                  placeholderText: "node port"
                  foreground: root.fg
                  font.family: root.fontName
                  text: String(root.newVhostPort)
                  onTextChanged: root.newVhostPort = parseInt(text, 10) || root.nginxPort
                }

                Text {
                  visible: root.newVhostType !== "node"
                  width: parent.width
                  text: "listen port " + root.nginxPort
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Rectangle {
                width: Math.max(Style.space(120), addBtnText.implicitWidth + Style.space(28))
                height: Style.space(32)
                radius: Style.cornerRadius
                color: addArea.containsMouse
                  ? Qt.lighter(Color.accent, 1.18)
                  : Color.accent
                border.width: 1
                border.color: Qt.lighter(Color.accent, 1.25)
                Text {
                  id: addBtnText
                  anchors.centerIn: parent
                  text: "Add vhost"
                  color: Color.background
                  font.family: root.fontName
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                MouseArea {
                  id: addArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addVhost()
                }
              }

              Text {
                width: parent.width
                text: "nginx changes may ask for your password"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }
            }

            PanelSeparator {
              foreground: root.fg
            }

            Text {
              visible: root.vhostsLoaded && root.vhosts.length === 0
              width: parent.width
              text: "no virtual hosts yet"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.vhosts

              Rectangle {
                id: vhRow
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(36)
                radius: Style.cornerRadius
                color: vhRowArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: vhRow.modelData.type
                    color: Color.accent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 0.5
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: vhRow.modelData.name
                    color: root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.body
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    visible: vhRow.modelData.host !== ""
                    text: vhRow.modelData.host
                    color: root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Rectangle {
                  id: vhOpen
                  anchors.right: vhRemove.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  width: vhOpenText.implicitWidth + Style.space(16)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: vhOpenArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                  Text {
                    id: vhOpenText
                    anchors.centerIn: parent
                    text: "Open"
                    color: Color.accent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: vhOpenArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openVhost(vhRow.modelData)
                  }
                }

                Rectangle {
                  id: vhRemove
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: vhDelText.implicitWidth + Style.space(16)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: vhDelArea.containsMouse ? Style.hoverFillFor(root.fg, Color.urgent) : "transparent"
                  Text {
                    id: vhDelText
                    anchors.centerIn: parent
                    text: "Remove"
                    color: Color.urgent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: vhDelArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeVhost(vhRow.modelData.name)
                  }
                }

                MouseArea {
                  id: vhRowArea
                  width: parent.width - Style.space(128)
                  height: parent.height
                  acceptedButtons: Qt.LeftButton
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openVhost(vhRow.modelData)
                }
              }
            }
          }

          // ---- Action log ----
          Column {
            visible: root.actionLog !== ""
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: copyLogsBtn.height

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LOG"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              Rectangle {
                id: copyLogsBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: copyLogsText.implicitWidth + Style.space(16)
                height: Style.space(24)
                radius: Style.cornerRadius
                color: copyLogsArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.5)
                Text {
                  id: copyLogsText
                  anchors.centerIn: parent
                  text: "Copy"
                  color: Color.accent
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: copyLogsArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.copyLogs()
                }
              }
            }

            Rectangle {
              width: parent.width
              radius: Style.cornerRadius
              color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.12)
              border.width: 1
              border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)
              implicitHeight: Math.min(logScroll.contentHeight + Style.space(12), Style.space(140))

              ScrollView {
                id: logScroll
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: logTextItem.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

                Text {
                  id: logTextItem
                  width: logScroll.availableWidth
                  text: root.actionLog
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                  opacity: 0.9
                }
              }
            }
          }

          // ---- Footer ----
          Text {
            width: parent.width
            text: "OmarchWeb · services, databases & virtual hosts"
            color: root.dim
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            opacity: 0.7
          }
        }
      }
    }
  }
}
