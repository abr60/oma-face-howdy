import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// face.howdy — the Omarchy-native Howdy face-unlock wizard.
//
// An "overlay" kind plugin: a menu-launched window (not a bar widget) that
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
//
// Styled as a security control panel: a polkit-style accent panel with a hero
// header, status readout cells, accent progress, and matched qs.Ui controls.

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
  // Security-panel palette: the polkit auth surface (built for lock/polkit
  // dialogs) accents the whole window, with urgent for destructive actions.
  readonly property color surfaceColor: Color.polkit.background
  readonly property color surfaceText: Color.polkit.text
  readonly property color surfaceBorder: Color.polkit.border
  readonly property color accent: Color.accent
  readonly property color foreground: Color.foreground
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color scrim: Color.polkit.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.spacing.controlPaddingY * 2)
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

  function statusGood(key) { return root.yes(root.status[key]) }

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
    root.runUserCmd("sudo howdy add 2>&1 || true; '" + root.pluginBin + "/omarchy-howdy-refresh-state' 2>/dev/null; echo 'done: enroll'")
  }
  function testFace() {
    root.intent = "test"
    root.beginTask("testing face")
    root.runUserCmd("sudo howdy test 2>&1 || true; echo 'done: test'")
  }
  function removeFace() {
    root.intent = "clearFace"
    root.beginTask("clearing faces")
    root.runUserCmd("sudo howdy clear -y 2>&1 || true; '" + root.pluginBin + "/omarchy-howdy-refresh-state' 2>/dev/null; echo 'done: clear'")
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

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      // subtle radial dim in the center so the panel feels layered
    }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.surfaceColor
      borderSpec: Border.surfaceSpec("polkit", "border", root.surfaceBorder, Math.max(1, Style.space(1)))
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

          // ------------------------------------------------- hero header
          Item {
            id: heroHeader
            width: parent.width
            height: Math.max(Style.space(52), Style.font.title + Style.space(12))

            // accent-ringed face monogram
            Rectangle {
              id: mono
              width: Style.space(42); height: Style.space(42)
              radius: Style.space(21)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: Util.alpha(root.accent, 0.10)
              border.width: Math.max(1, Style.space(1))
              border.color: root.accent
              Text {
                anchors.centerIn: parent
                text: "◉"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              anchors.left: mono.right
              anchors.leftMargin: root.contentSpacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: 1
              Text {
                text: "Face Howdy"
                color: root.surfaceText
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: root.subtitle()
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // accent page-label pill
            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: pill.implicitWidth + Style.space(16)
              height: pill.implicitHeight + Style.space(8)
              radius: (pill.implicitHeight + Style.space(8)) / 2
              color: Util.alpha(root.accent, 0.16)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(root.accent, 0.35)
              Text {
                id: pill
                anchors.centerIn: parent
                text: root.pageLabel()
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Rectangle { width: parent.width; height: Math.max(1, Style.space(1)); color: Util.alpha(root.surfaceBorder, 0.55) }

          // ------------------------------------------------------- body
          Item {
            id: body
            width: parent.width
            height: Math.max(150, card.height - heroHeader.height - footer.height - root.contentSpacing * 3)

            // status — hero summary + readout cells
            Column {
              visible: root.page === "status"
              anchors.fill: parent
              spacing: root.contentSpacing

              // summary banner
              Rectangle {
                width: parent.width
                height: summaryCol.implicitHeight + Style.space(16)
                radius: root.cornerRadius
                color: Util.alpha(root.polkitAccent(), 0.10)
                border.width: 0
                Column {
                  id: summaryCol
                  anchors.centerIn: parent
                  width: parent.width - Style.space(24)
                  spacing: 2
                  Text {
                    width: parent.width
                    text: root.statusLoaded ? root.overviewTitle() : "Checking…"
                    color: root.surfaceText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                  }
                  Text {
                    width: parent.width
                    text: root.statusLoaded ? root.overviewText() : "Reading system state…"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    lineHeight: 1.3
                    horizontalAlignment: Text.AlignHCenter
                  }
                }
              }

              // readout cells grid (2 columns)
              Flow {
                width: parent.width
                spacing: root.contentSpacing

                Repeater {
                  model: root.statusCells()
                  delegate: Cell {
                    label: modelData.label
                    good: modelData.okay
                    valueText: modelData.value
                  }
                }
              }
            }

            // install / working — accent progress + quote + live log
            Column {
              visible: root.page === "install"
              anchors.fill: parent
              spacing: root.contentSpacing

              Rectangle {
                width: parent.width
                height: Math.max(Style.space(18), Style.font.body)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.12)
                clip: true
                Rectangle {
                  id: fill
                  width: parent.width * root.installProgress()
                  height: parent.height
                  radius: root.cornerRadius
                  color: Util.alpha(root.accent, 0.55)
                  Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                }
                Text {
                  anchors.right: parent.right; anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.installPercent()
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Text {
                text: root.installProgressLabel()
                color: root.surfaceText
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              // fun-quote callout
              Text {
                width: parent.width
                text: root.installing ? root.currentQuote : (root.installComplete ? root.installCompleteMsg() : "")
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.italic: true
                wrapMode: Text.WordWrap
                visible: root.installing || root.installComplete
              }

              // live log
              Rectangle {
                width: parent.width
                height: Math.max(120, parent.height - Style.space(150))
                radius: root.cornerRadius
                color: Util.alpha(Color.background, 0.40)
                clip: true
                Flickable {
                  anchors.fill: parent; anchors.margins: root.contentSpacing
                  contentHeight: logCol.implicitHeight
                  Column {
                    id: logCol; width: parent.width
                    Text {
                      text: root.logText
                      color: root.muted
                      font.family: "monospace"
                      font.pixelSize: Style.font.body - 2
                      wrapMode: Text.Wrap
                      width: parent.width
                    }
                  }
                }
              }
            }

            // confirm
            Column {
              visible: root.page === "confirm"
              anchors.fill: parent
              spacing: root.contentSpacing
              Text {
                width: parent.width
                text: "Ready to wire Howdy into the system."
                color: root.surfaceText
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                wrapMode: Text.WordWrap
              }
              Rectangle {
                width: parent.width
                height: explain.implicitHeight + Style.space(16)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.06)
                Text {
                  id: explain
                  anchors.centerIn: parent
                  width: parent.width - Style.space(24)
                  text: "This injects one pam_howdy auth line into sudo, SDDM and polkit, creates a dedicated omarchy-lock-howdy PAM service, configures the IR emitter to fire at unlock, and patches your lock screen to unlock by face when you lift the lid or hit Enter.\n\nYour password auth stays as a fallback and nothing is removed. Proceed?"
                  color: root.surfaceText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.4
                }
              }
            }

            // remove — urgent caution
            Column {
              visible: root.page === "remove"
              anchors.fill: parent
              spacing: root.contentSpacing
              Text {
                width: parent.width
                text: "Remove Face Howdy?"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                wrapMode: Text.WordWrap
              }
              Rectangle {
                width: parent.width
                height: explain2.implicitHeight + Style.space(16)
                radius: root.cornerRadius
                color: Util.alpha(root.urgent, 0.10)
                Text {
                  id: explain2
                  anchors.centerIn: parent
                  width: parent.width - Style.space(24)
                  text: "Your password auth is always left working. Choose whether to also uninstall the howdy / IR-emitter packages (and your enrolled face), or keep them so a later re-enable is instant."
                  color: root.surfaceText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.4
                }
              }
              Row {
                spacing: root.contentSpacing
                Button {
                  text: "Remove (keep pkgs)"
                  selected: true
                  onClicked: root.startRemove(true)
                }
                Button {
                  text: "Remove + delete pkgs"
                  selected: true
                  accent: root.urgent
                  onClicked: root.startRemove(false)
                }
              }
            }

            // face data — action rows
            Column {
              visible: root.page === "facelist"
              anchors.fill: parent
              spacing: root.contentSpacing
              Text {
                width: parent.width
                text: "Face data"
                color: root.surfaceText
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                wrapMode: Text.WordWrap
              }
              Rectangle {
                width: parent.width
                height: explain3.implicitHeight + Style.space(16)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.06)
                Text {
                  id: explain3
                  anchors.centerIn: parent
                  width: parent.width - Style.space(24)
                  text: "Add opens Howdy's own terminal UI to enroll your face. Test runs a recognition check. Clear removes all enrolled faces. Everything runs under root."
                  color: root.surfaceText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.4
                }
              }
              Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.contentSpacing
                Button {
                  text: "Add face"
                  selected: true
                  width: Style.space(220)
                  onClicked: root.enrollFace()
                }
                Button {
                  text: "Test recognition"
                  bordered: true
                  width: Style.space(220)
                  onClicked: root.testFace()
                }
                Button {
                  text: "Clear faces"
                  selected: true
                  accent: root.urgent
                  width: Style.space(220)
                  onClicked: root.removeFace()
                }
              }
            }
          }

          // ------------------------------------------------------- footer
          Row {
            id: footer
            width: parent.width
            height: root.buttonHeight
            spacing: root.contentSpacing

            Button {
              text: "Close"
              bordered: true
              onClicked: root.dismiss()
            }

            Button {
              text: "Back"
              bordered: true
              visible: root.page === "facelist" || root.page === "remove" || root.page === "confirm"
              onClicked: root.page = "status"
            }

            Button {
              text: "Deploy PAM"
              bordered: true
              visible: root.page === "status" && root.installed() && !root.pamDeployed() && !root.installing
              onClicked: root.page = "confirm"
            }

            Button {
              text: "Face data"
              bordered: true
              visible: root.page === "status" && root.installed() && !root.installing
              onClicked: root.page = "facelist"
            }

            Button {
              text: "Remove"
              bordered: true
              visible: root.page === "status" && (root.installed() || root.pamDeployed()) && !root.installing
              onClicked: root.page = "remove"
            }

            Button {
              text: root.primaryLabel()
              selected: true
              visible: root.primaryVisible()
              onClicked: root.primaryAction()
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ cells
  // A single readout cell: accent-tinted when the led is "good".
  component Cell : Rectangle {
    id: cell
    property string label: ""
    property string valueText: ""
    property bool good: false

    readonly property real cellH: Math.max(root.rowHeight - 4, Style.font.body + Style.space(18))
    readonly property real cellW: Style.space(208)

    width: cell.cellW
    height: cell.cellH
    radius: root.cornerRadius
    color: cell.good ? Util.alpha(root.accent, 0.12) : Util.alpha(root.muted, 0.10)
    border {
      width: Math.max(1, Style.space(1))
      color: cell.good ? Util.alpha(root.accent, 0.45) : Util.alpha(root.muted, 0.25)
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(8); anchors.bottomMargin: Style.space(8)
      spacing: Style.space(8)

      // status led / glyph
      Rectangle {
        width: Style.space(14); height: Style.space(14)
        radius: Style.space(7)
        anchors.verticalCenter: parent.verticalCenter
        color: cell.good ? root.accent : root.urgent
        Text {
          anchors.centerIn: parent
          text: cell.good ? "✓" : "✗"
          color: root.surfaceColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        Text {
          text: cell.label
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: cell.valueText
          color: cell.good ? root.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
    }
  }

  // ------------------------------------------------- label / progress fns
  function polkitAccent() {
    return Color.polkit.accent
  }
  function installPercent() {
    return Math.round(root.installProgress() * 100) + "%"
  }
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

  function overviewTitle() {
    if (!root.statusLoaded) return "Checking…"
    if (root.installComplete) return "Setup complete"
    if (root.pamDeployed() && root.yes(root.status.enrolled)) return "Protected"
    if (root.installed()) return "Ready to secure"
    return "Not set up yet"
  }
  function overviewText() {
    var s = root.status, rows = []
    if (root.installed()) rows.push("Howdy packages installed.")
    if (root.yes(s.models)) rows.push("Face models downloaded.")
    if (root.yes(s.enrolled)) rows.push("A face is enrolled.")
    if (root.pamDeployed()) rows.push("PAM integration active.")
    if (root.yes(s.ir_udev)) rows.push("IR emitter configured.")
    if (rows.length === 0) rows.push("Run Install to enable face unlock.")
    return rows.join("  •  ")
  }

  function statusCells() {
    var s = root.status, arr = []
    function add(label, key) {
      arr.push({ label: label, value: root.yes(s[key]) ? "Enabled" : "Not set", okay: root.yes(s[key]) })
    }
    add("Howdy package", "howdy_pkg")
    add("IR emitter pkg", "leire_pkg")
    add("PAM (sudo)", "pam_howdy_sudo")
    add("Lock PAM", "lock_pam")
    add("IR emitter", "ir_udev")
    add("Face models", "models")
    add("Face enrolled", "enrolled")
    var lockName = String(s.active_lock || "stock")
    var lockGood = lockName !== "stock"
    arr.push({ label: "Lock screen", value: lockGood ? lockName : "Stock", okay: lockGood })
    return arr
  }

  function installCompleteMsg() {
    if (root.yes(root.status.enrolled)) return "Setup complete and a face is enrolled."
    return "Packages, models and auth are ready — now enroll your face (Face data → Add)."
  }

  function subtitle() {
    if (root.yes(root.status.enrolled) && root.pamDeployed()) return "Face unlock is active"
    if (root.installed()) return "Looking good — almost there"
    return "Add Windows-Hello-style face unlock"
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
}
