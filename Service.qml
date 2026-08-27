import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// face.howdy — the Omarchy-native Howdy face-unlock wizard.
//
// A "service" kind plugin: a menu-launched window (not a bar widget) that
// walks the user through installing Howdy + the IR emitter, deploying the PAM
// integration and lock-screen patch, enrolling their face, testing, and
// cleaningly removing the whole thing.
//
// The Omarchy plugin lifecycle (enable/disable/remove) deliberately runs no
// privileged code, so this window drives every privileged/system change itself
// through a pkexec bridge to the bundled bin/ scripts (the same pattern the
// thinkfan widget uses). It owns its own menu row (setup > security > Face
// Howdy) so it stays reachable across Omarchy upgrades, and cleans that row up
// when it is disabled or removed.

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property string pluginBin: (root.manifest && root.manifest.__sourceDir)
    ? root.manifest.__sourceDir.replace(/\/$/, "") + "/bin"
    : ""

  function tool(name) {
    if (root.pluginBin)
      return "'" + (root.pluginBin + "/" + name).replace(/'/g, "'\\''") + "'"
    return name
  }

  // ------------------------------------------------------------------ state
  property bool opened: false
  property string page: "status"       // status | install | confirm | remove | facelist
  property var status: ({})
  property bool statusLoaded: false

  // What the privileged "setup" process is doing right now. Drives both the
  // progress bar and the phase-advancing sequence in onSetupDone.
  property string intent: ""           // "" | install | deployPam | remove | enroll | test | clearFace
  property string progressLabel: ""
  property bool installing: false
  property bool installComplete: false
  property string logText: ""
  property string currentQuote: "Gathering photons…"
  property var quotes: []

  // ------------------------------------------------------------------ style
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(440), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(580), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(42), Style.font.body + Style.spacing.controlPaddingY * 2)
  property int buttonHeight: Math.max(Style.space(38), Style.font.body + Style.spacing.controlPaddingY)

  // ---------------------------------------------------------------- open
  function open(payloadJson) {
    root.opened = true
    root.page = "status"
    root.statusLoaded = false
    root.refreshStatus()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { root.opened = false }
  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "face.howdy")
  }
  function toggle() { if (root.opened) root.dismiss(); else root.open("{}") }

  // -------------------------------------------------------------- status
  function refreshStatus() {
    statusProc.command = ["bash", "-c", root.tool("omarchy-howdy-status")]
    statusProc.running = true
  }
  function parseStatus() {
    root.status = {}
    var lines = String(statusProc.collected).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq < 0) continue
      root.status[lines[i].slice(0, eq)] = lines[i].slice(eq + 1)
    }
    root.statusLoaded = true
  }
  function yes(v) { return v === "yes" }
  function installed() { return root.yes(root.status.howdy_pkg) && root.yes(root.status.leire_pkg) }
  function pamDeployed() { return root.yes(root.status.pam_howdy_sudo) || root.yes(root.status.lock_pam) }

  // -------------------------------------------------------------- install
  // Full sequence: packages → ir → models → pam. After pam we patch the lock.
  function startInstall() {
    root.intent = "install"
    root.installComplete = false
    root.beginTask("installing packages")
    root.runPhase("packages")
  }

  function startDeployPam() {
    root.intent = "deployPam"
    root.installComplete = false
    root.beginTask("wiring PAM")
    root.runPhase("pam")
  }

  function runPhase(phase) {
    root.nextQuote()
    setupProc.phase = phase
    setupProc.collected = ""
    setupProc.command = ["pkexec", "/bin/bash", "--",
      (root.pluginBin + "/omarchy-howdy-setup-system").replace(/'/g, "'\\''"),
      phase]
    setupProc.running = true
  }

  function beginTask(label) {
    root.installing = true
    root.progressLabel = label
    root.logText = ""
    root.page = "install"
  }

  function onSetupDone(ok) {
    if (!ok) { root.failTask(); return }
    if (root.intent === "install") {
      switch (setupProc.phase) {
        case "packages": root.progressLabel = "configuring IR emitter"; root.runPhase("ir"); return
        case "ir": root.progressLabel = "downloading face models"; root.runPhase("models"); return
        case "models": root.progressLabel = "wiring PAM"; root.runPhase("pam"); return
        case "pam":
          root.finishSetup()
          root.deployLock()      // patch + activate lock screen
          return
      }
    } else if (root.intent === "deployPam") {
      root.finishSetup()
      root.deployLock()
      return
    } else if (root.intent === "remove") {
      root.finishSetup()
      // lock restore already ran inside removeProc; just refresh + restart.
      root.scheduleShellRestart()
      return
    } else {
      // enroll / test / clearFace / etc.
      root.finishSetup()
      return
    }
  }

  function failTask() {
    root.installing = false
    root.page = "status"
    root.intent = ""
    root.refreshStatus()
  }

  function finishSetup() {
    root.installing = false
    root.installComplete = true
    root.progressLabel = "done"
    root.currentQuote = "Face unlocked. Welcome aboard!"
    root.intent = ""
    root.refreshStatus()
  }

  function scheduleShellRestart() {
    Util.execDetached("omarchy restart shell")
  }

  function deployLock() {
    // Patch + activate the lock screen (unprivileged), then restart shell.
    lockProc.collected = ""
    lockProc.command = ["/bin/bash", "-c", root.tool("omarchy-howdy-deploy-lock")]
    lockProc.running = true
  }

  // --------------------------------------------------------------- face
  // These run Howdy's own terminal UI under root via the setup process, so the
  // log window shows live output and the "done" sequence runs on completion.
  function enrollFace() {
    root.intent = "enroll"
    root.beginTask("enrolling face")
    root.runUserCmd("sudo howdy add 2>&1 || true; echo 'done: enroll'")
  }
  function testFace() {
    root.intent = "test"
    root.beginTask("testing face")
    root.runUserCmd("sudo howdy test 2>&1 || true; echo 'done: test'")
  }
  function removeFace() {
    root.intent = "clearFace"
    root.beginTask("clearing faces")
    root.runUserCmd("sudo howdy clear -y 2>&1 || true; echo 'done: clear'")
  }

  // Run an arbitrary (root) command through the shared setup process.
  function runUserCmd(cmd) {
    root.nextQuote()
    setupProc.phase = cmd
    setupProc.collected = ""
    setupProc.command = ["pkexec", "/bin/bash", "--", "-c", cmd]
    setupProc.running = true
  }

  // ---------------------------------------------------------------- remove
  function startRemove(keepPkgs) {
    root.intent = "remove"
    root.installComplete = false
    root.beginTask("removing")
    removeProc.collected = ""
    removeProc.command = ["pkexec", "/bin/bash", "--", "-c",
      "'" + root.pluginBin + "/omarchy-howdy-teardown-system' " + (keepPkgs ? "keep-pkgs" : "delete-pkgs") +
      " 2>&1; echo '---'; '" + root.pluginBin + "/omarchy-howdy-restore-lock' 2>&1; echo 'remove:done'"]
    removeProc.running = true
  }

  // ---------------------------------------------------------- self-menu
  property bool menuRowInstalled: false
  onPluginBinChanged: {
    if (!root.menuRowInstalled && root.pluginBin) {
      root.menuRowInstalled = true
      Util.execDetached(root.tool("omarchy-howdy-menu-install"))
      root.loadQuotes()
    }
  }
  Component.onDestruction: {
    var ext = Quickshell.env("OMARCHY_MENU_EXTENSION")
    var dir = ext ? String(ext).replace(/\/[^\/]*$/, "") : Quickshell.env("HOME") + "/.config/omarchy/extensions"
    Util.execDetached(Util.shellQuote(dir + "/omarchy-howdy-menu-entry") + " --remove")
  }

  // -------------------------------------------------------------- helpers
  function loadQuotes() {
    if (!root.pluginBin) return
    quotesProc.command = ["cat", root.pluginBin.replace(/\/bin$/, "") + "/assets/quotes.txt"]
    quotesProc.running = true
  }
  function nextQuote() {
    if (root.quotes.length === 0) { root.currentQuote = "Working…"; return }
    root.currentQuote = root.quotes[Math.floor(Math.random() * root.quotes.length)]
  }
  function pageLabel() {
    switch (root.page) {
      case "install": return root.installComplete ? "COMPLETE" : "SETUP"
      case "confirm": return "CONFIRM"
      case "remove": return "REMOVE"
      case "facelist": return "FACE DATA"
      default: return "STATUS"
    }
  }

  // ------------------------------------------------------------- processes
  Process {
    id: statusProc
    property string collected: ""
    command: ["bash", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { statusProc.collected += data + "\n" } }
    onExited: root.parseStatus()
  }

  Process {
    id: setupProc
    property string collected: ""
    property string phase: ""
    command: ["pkexec", "/bin/bash", "--", "true"]
    stdout: SplitParser {
      onRead: function(data) {
        setupProc.collected += data + "\n"
        root.logText += data
        root.nextQuote()
      }
    }
    onExited: {
      if (exitCode !== 0) root.logText += "ERROR: step failed.\n"
      root.onSetupDone(exitCode === 0)
    }
  }

  Process {
    id: quotesProc
    command: ["cat", "/dev/null"]
    stdout: SplitParser {
      onRead: function(data) { root.quotes = String(data).split("\n").filter(Boolean) }
    }
  }

  Process {
    id: lockProc
    property string collected: ""
    command: ["/bin/bash", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { lockProc.collected += data + "\n" } }
    onExited: {
      root.logText += lockProc.collected
      root.scheduleShellRestart()
    }
  }

  Process {
    id: removeProc
    property string collected: ""
    command: ["pkexec", "/bin/bash", "--", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { removeProc.collected += data + "\n" } }
    onExited: {
      root.logText += removeProc.collected
      root.onSetupDone(exitCode === 0)
    }
  }

  // ---------------------------------------------------------------- window
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "face.howdy"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) root.dismiss() }

        Column {
          anchors.fill: parent
          spacing: root.contentSpacing

          // header
          Row {
            id: headerRow
            width: parent.width
            height: Math.max(Style.font.title, Style.font.body) + 4
            spacing: root.contentSpacing
            Text { text: "🗿"; font.family: root.fontFamily; font.pixelSize: Style.font.title; anchors.verticalCenter: parent.verticalCenter }
            Text { text: "Face Howdy"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
            Text {
              text: root.pageLabel()
              color: root.border
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
            }
          }
          Rectangle { width: parent.width; height: 1; color: root.border }

          // body
          Item {
            id: body
            width: parent.width
            height: Math.max(140, card.height - headerRow.height - footer.height - root.contentSpacing * 3)

            // status
            Column {
              visible: root.page === "status"
              width: parent.width
              spacing: root.contentSpacing
              Text {
                text: root.statusLoaded ? root.overviewText() : "Checking…"
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap; width: parent.width; lineHeight: 1.4
              }
              Column {
                width: parent.width; spacing: 4
                Repeater {
                  model: root.statusRows()
                  delegate: Row {
                    width: parent.width; height: root.rowHeight; spacing: root.contentSpacing
                    Text {
                      width: parent.width - 110; elide: Text.ElideRight
                      text: model.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                    }
                    Rectangle {
                      width: 96; height: Math.max(0, parent.height - 14); radius: root.cornerRadius
                      color: model.okay ? root.selectedBackground : root.scrim
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        anchors.centerIn: parent; text: model.value
                        color: model.okay ? root.selectedText : root.foreground
                        font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
                      }
                    }
                  }
                }
              }
            }

            // install / working
            Column {
              visible: root.page === "install"
              width: parent.width; spacing: root.contentSpacing
              Rectangle {
                width: parent.width; height: Math.max(Style.space(16), 10); radius: root.cornerRadius; color: root.scrim
                Rectangle {
                  width: parent.width * root.installProgress(); height: parent.height; radius: root.cornerRadius
                  color: root.selectedBackground
                  Behavior on width { NumberAnimation { duration: 250 } }
                }
              }
              Text {
                text: root.installProgressLabel()
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
              }
              Text {
                text: root.installing ? root.currentQuote : (root.installComplete ? root.installCompleteMsg() : "")
                color: root.border; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.italic: true
                wrapMode: Text.WordWrap; width: parent.width
                visible: root.installing || root.installComplete
              }
              Rectangle {
                width: parent.width; height: Math.max(120, parent.height - 130); radius: root.cornerRadius; color: root.scrim; clip: true
                Flickable {
                  anchors.fill: parent; anchors.margins: root.contentSpacing
                  contentHeight: logCol.implicitHeight
                  Column {
                    id: logCol; width: parent.width
                    Text {
                      text: root.logText; color: root.foreground; font.family: "monospace"
                      font.pixelSize: Style.font.body - 2; wrapMode: Text.Wrap; width: parent.width
                    }
                  }
                }
              }
            }

            // confirm
            Column {
              visible: root.page === "confirm"
              width: parent.width; spacing: root.contentSpacing
              Text {
                text: "Ready to wire Howdy into the system.\n\nThis injects one pam_howdy auth line into sudo, SDDM and polkit, creates a dedicated omarchy-lock-howdy PAM service, configures the IR emitter to fire at unlock, and patches your lock screen to unlock by face when you lift the lid or hit Enter.\n\nYour password auth stays as a fallback and nothing is removed. Proceed?"
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap; width: parent.width; lineHeight: 1.4
              }
            }

            // remove
            Column {
              visible: root.page === "remove"
              width: parent.width; spacing: root.contentSpacing
              Text {
                text: "Remove Face Howdy?\n\nYour password auth is always left working. Choose whether to also uninstall the howdy / IR-emitter packages (and your enrolled face), or keep them so a later re-enable is instant."
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap; width: parent.width; lineHeight: 1.4
              }
              Row {
                width: parent.width; spacing: root.contentSpacing
                Btn { text: "Remove (keep pkgs)"; accent: true; onClicked: root.startRemove(true) }
                Btn { text: "Remove + delete pkgs"; onClicked: root.startRemove(false) }
              }
            }

            // face data
            Column {
              visible: root.page === "facelist"
              width: parent.width; spacing: root.contentSpacing
              Text {
                text: "Face data.\n\nAdd opens Howdy's own terminal UI to enroll your face. Test runs a recognition check. Clear removes all enrolled faces. Everything runs under root."
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap; width: parent.width; lineHeight: 1.4
              }
              Row {
                width: parent.width; spacing: root.contentSpacing
                Btn { text: "Add face"; accent: true; onClicked: root.enrollFace() }
                Btn { text: "Test"; onClicked: root.testFace() }
                Btn { text: "Clear faces"; onClicked: root.removeFace() }
              }
            }
          }

          // footer
          Row {
            id: footer
            width: parent.width
            height: root.buttonHeight
            spacing: root.contentSpacing

            Btn { text: "Close"; onClicked: root.dismiss() }

            Btn {
              text: "Back"
              visible: root.page === "facelist" || root.page === "remove" || root.page === "confirm"
              onClicked: root.page = "status"
            }

            Btn {
              text: "Deploy PAM"
              visible: root.page === "status" && root.installed() && !root.pamDeployed() && !root.installing
              onClicked: root.page = "confirm"
            }

            Btn {
              text: "Face data"
              visible: root.page === "status" && root.installed() && !root.installing
              onClicked: root.page = "facelist"
            }

            Btn {
              text: "Remove"
              visible: root.page === "status" && (root.installed() || root.pamDeployed()) && !root.installing
              onClicked: root.page = "remove"
            }

            Btn {
              text: root.primaryLabel()
              accent: true
              visible: root.primaryVisible()
              onClicked: root.primaryAction()
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------- label / progress fns
  function installProgress() {
    switch (root.progressLabel) {
      case "installing packages": return 0.2
      case "configuring IR emitter": return 0.45
      case "downloading face models": return 0.7
      case "wiring PAM": return 0.9
      case "removing": return 0.6
      default: return root.installComplete ? 1 : 0.3
    }
  }
  function installProgressLabel() {
    var m = { "installing packages": "Installing packages (can take a while)",
              "configuring IR emitter": "Configuring IR emitter",
              "downloading face models": "Downloading face models",
              "wiring PAM": "Wiring PAM + lock screen",
              "enrolling face": "Enrolling your face…",
              "testing face": "Testing recognition…",
              "clearing faces": "Clearing enrolled faces…",
              "removing": "Removing…" }
    return root.installComplete ? "Complete" : (m[root.progressLabel] || root.progressLabel)
  }

  function overviewText() {
    var s = root.status, rows = []
    if (root.installed()) rows.push("Howdy packages installed.")
    if (root.yes(s.models)) rows.push("Face models downloaded.")
    if (root.yes(s.enrolled)) rows.push("A face is enrolled.")
    if (root.pamDeployed()) rows.push("PAM integration active.")
    if (root.yes(s.ir_udev)) rows.push("IR emitter configured.")
    if (rows.length === 0) rows.push("Face unlock isn't set up yet. Run Install to begin.")
    return rows.join("\n") + "\n"
  }

  function statusRows() {
    var s = root.status, arr = []
    function add(label, key, okVal) {
      arr.push({ label: label, value: root.yes(s[key]) ? "on" : "off", okay: root.yes(s[key]) === okVal })
    }
    add("Howdy package", "howdy_pkg", true)
    add("IR emitter pkg", "leire_pkg", true)
    add("PAM (sudo)", "pam_howdy_sudo", true)
    add("Lock PAM", "lock_pam", true)
    add("IR emitter", "ir_udev", true)
    add("Face models", "models", true)
    add("Face enrolled", "enrolled", true)
    arr.push({ label: "Lock screen", value: String(s.active_lock || "stock"), okay: String(s.active_lock || "stock") !== "stock" })
    return arr
  }

  function installCompleteMsg() {
    if (root.yes(root.status.enrolled)) return "Setup complete and a face is enrolled."
    return "Packages, models and auth are ready — now enroll your face (Face data → Add)."
  }

  function primaryLabel() {
    switch (root.page) {
      case "status":
        if (root.installing) return "Working…"
        return root.installed()
          ? (root.yes(root.status.enrolled) ? "Re-enroll" : "Enroll")
          : "Install"
      case "install": return root.installComplete ? "OK" : "Working…"
      case "confirm": return "Deploy PAM"
      default: return "OK"
    }
  }
  function primaryVisible() {
    switch (root.page) {
      case "status": return !root.installing
      case "install": return true
      case "confirm": return true
      default: return false   // remove / facelist use their inline buttons
    }
  }
  function primaryAction() {
    switch (root.page) {
      case "status":
        if (root.installing) return
        if (root.installed()) { root.page = "facelist"; return }
        root.startInstall(); return
      case "install":
        if (root.installComplete) { root.page = "status"; root.installComplete = false; return }
        return
      case "confirm": root.startDeployPam(); return
    }
  }

  // ------------------------------------------------------------------ button
  component Btn : Rectangle {
    id: b
    property string text: ""
    property bool accent: false
    signal clicked()
    implicitHeight: root.buttonHeight
    implicitWidth: Math.max(Style.space(84), label.implicitWidth + root.contentSpacing * 2)
    radius: root.cornerRadius
    color: b.accent ? root.selectedBackground : "transparent"
    border.width: b.accent ? 0 : 1
    border.color: root.border
    Text {
      id: label
      anchors.centerIn: parent
      text: b.text
      color: b.accent ? root.selectedText : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      anchors.fill: parent; hoverEnabled: true
      onEntered: if (!b.accent) b.color = root.selectedBackground
      onExited: if (!b.accent) b.color = "transparent"
      onClicked: b.clicked()
    }
  }
}
