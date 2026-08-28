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
  // Reactive status-cell model. Populated in parseStatus() so the Repeater
  // below actually updates when the status script returns (a `model:`
  // function call would otherwise be evaluated only once and stay stale).
  property var cellModel: []

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
    root.cellModel = root.statusCells()   // refresh the cell grid now that status is known
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

  // -------------------------------------------------------------- install
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
      // Cinematic visual dimming in the background
      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          orientation: Gradient.Vertical
          GradientStop { position: 0.0; color: Util.alpha(Color.background, 0.1) }
          GradientStop { position: 0.5; color: Util.alpha("#000000", 0.65) }
          GradientStop { position: 1.0; color: Util.alpha(Color.background, 0.3) }
        }
      }
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

      // Dual-tone inner gloss gradient for premium depth
      Rectangle {
        anchors.fill: parent
        radius: root.cornerRadius
        color: "transparent"
        gradient: Gradient {
          orientation: Gradient.Vertical
          GradientStop { position: 0.0; color: Util.alpha("#ffffff", 0.02) }
          GradientStop { position: 1.0; color: Util.alpha("#000000", 0.12) }
        }
        z: -1
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        // Explicitly align within the padded margins of the BorderSurface
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) root.dismiss() }

        Column {
          anchors.fill: parent
          spacing: root.contentSpacing

          // ------------------------------------------------- hero header
          Item {
            id: heroHeader
            width: parent.width
            height: Math.max(Style.space(56), Style.font.title + Style.space(16))

            // Premium SVG face monogram with pulsating scanner glow
            Item {
              id: mono
              width: Style.space(46)
              height: Style.space(46)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              // Outer breathing/pulsing accent ring
              Rectangle {
                anchors.centerIn: parent
                width: parent.width + Style.space(8)
                height: parent.height + Style.space(8)
                radius: width / 2
                color: "transparent"
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.3)
                scale: pulseAnimation.scaleVal
                opacity: pulseAnimation.opacityVal

                SequentialAnimation on scale {
                  id: pulseAnimation
                  loops: Animation.Infinite
                  running: true
                  property real scaleVal: 1.0
                  property real opacityVal: 0.8
                  
                  NumberAnimation { from: 0.94; to: 1.15; duration: 1500; easing.type: Easing.InOutSine }
                  NumberAnimation { from: 1.15; to: 0.94; duration: 1500; easing.type: Easing.InOutSine }
                }
                
                SequentialAnimation on opacity {
                  loops: Animation.Infinite
                  running: true
                  NumberAnimation { from: 0.8; to: 0.15; duration: 1500; easing.type: Easing.InOutSine }
                  NumberAnimation { from: 0.15; to: 0.8; duration: 1500; easing.type: Easing.InOutSine }
                }
              }

              // Beautiful native high-quality vector face illustration
              Image {
                anchors.centerIn: parent
                width: Style.space(38)
                height: Style.space(38)
                source: root.pluginBin ? "file://" + root.pluginBin.replace(/\/bin$/, "") + "/assets/face-howdy.svg" : ""
                fillMode: Image.PreserveAspectFit
                smooth: true
              }
            }

            Column {
              anchors.left: mono.right
              anchors.leftMargin: root.contentSpacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
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

            // High-tech accent page-label pill with a live pulsating status dot
            Rectangle {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: pillRow.implicitWidth + Style.space(16)
              height: pillRow.implicitHeight + Style.space(8)
              radius: height / 2
              color: Util.alpha(root.accent, 0.08)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(root.accent, 0.3)

              Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: Style.space(6)
                
                Rectangle {
                  width: Style.space(6)
                  height: Style.space(6)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.page === "status" && root.pamDeployed() && root.yes(root.status.enrolled) ? root.accent : (root.page === "remove" ? root.urgent : root.accent)
                  
                  SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: true
                    NumberAnimation { from: 1.0; to: 0.3; duration: 1200; easing.type: Easing.InOutQuad }
                    NumberAnimation { from: 0.3; to: 1.0; duration: 1200; easing.type: Easing.InOutQuad }
                  }
                }

                Text {
                  id: pill
                  text: root.pageLabel()
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 1
                  font.bold: true
                  font.letterSpacing: 0.5
                }
              }
            }
          }

          // Gorgeous gradient divider fading elegantly to transparent at the edges
          Rectangle {
            width: parent.width
            height: Math.max(1, Style.space(1))
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: "transparent" }
              GradientStop { position: 0.5; color: Util.alpha(root.surfaceBorder, 0.45) }
              GradientStop { position: 1.0; color: "transparent" }
            }
          }

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

              // Left-accent-strip structured overview banner
              Rectangle {
                width: parent.width
                height: summaryCol.implicitHeight + Style.space(22)
                radius: root.cornerRadius
                color: Util.alpha(root.polkitAccent(), 0.06)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.polkitAccent(), 0.15)
                clip: true

                // Security status indicator bar
                Rectangle {
                  id: safetyStrip
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Style.space(4)
                  color: {
                    if (!root.statusLoaded) return root.muted
                    if (root.pamDeployed() && root.yes(root.status.enrolled)) return root.accent
                    if (root.installed()) return root.accent
                    return root.urgent
                  }
                }

                Column {
                  id: summaryCol
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(20)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(20)
                  spacing: Style.space(3)

                  Text {
                    width: parent.width
                    text: root.statusLoaded ? root.overviewTitle() : "Checking…"
                    color: root.surfaceText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body + 1
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: root.statusLoaded ? root.overviewText() : "Reading system state…"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    lineHeight: 1.35
                  }
                }
              }

              // Readout cells structured into a clean, perfectly aligned 2-column grid
              Grid {
                width: parent.width
                columns: 2
                spacing: root.contentSpacing

                Repeater {
                  model: root.cellModel
                  delegate: Cell {
                    width: (parent.width - root.contentSpacing) / 2
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

              // Highly detailed dual-rail progress track
              Rectangle {
                width: parent.width
                height: Math.max(Style.space(18), Style.font.body)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                clip: true

                // Horizontal gradient bar with glowing end cap
                Rectangle {
                  id: fill
                  width: parent.width * root.installProgress()
                  height: parent.height
                  radius: root.cornerRadius
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Util.alpha(root.accent, 0.35) }
                    GradientStop { position: 1.0; color: root.accent }
                  }
                  Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.InOutQuad } }

                  // Shiny leading edge highlight
                  Rectangle {
                    anchors.right: parent.right
                    width: Style.space(3)
                    height: parent.height
                    color: "#ffffff"
                    opacity: 0.7
                  }
                }
                Text {
                  anchors.right: parent.right; anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.installPercent()
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 1
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

              // Beautiful speech-bubble styled fun quote card
              Rectangle {
                width: parent.width
                height: quoteText.implicitHeight + Style.space(18)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                visible: root.installing || root.installComplete

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(10)

                  Text {
                    text: "“"
                    color: Util.alpha(root.accent, 0.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title + 2
                    font.bold: true
                    anchors.top: parent.top
                    anchors.topMargin: Style.space(2)
                  }

                  Text {
                    id: quoteText
                    width: parent.width - Style.space(38)
                    text: root.installing ? root.currentQuote : (root.installComplete ? root.installCompleteMsg() : "")
                    color: root.surfaceText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.italic: true
                    wrapMode: Text.WordWrap
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              // Retro-modern developer console terminal for logs
              Rectangle {
                width: parent.width
                height: Math.max(120, parent.height - Style.space(150))
                radius: root.cornerRadius
                color: "#0a0c0e"
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.18)
                clip: true

                // Embedded console title badge
                Rectangle {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.top: parent.top
                  anchors.topMargin: Style.space(8)
                  width: terminalLabel.implicitWidth + Style.space(12)
                  height: terminalLabel.implicitHeight + Style.space(4)
                  radius: Style.space(4)
                  color: Util.alpha(root.accent, 0.1)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.accent, 0.2)
                  z: 2
                  
                  Text {
                    id: terminalLabel
                    anchors.centerIn: parent
                    text: "CONSOLE LOG"
                    color: Util.alpha(root.accent, 0.8)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 2
                    font.bold: true
                  }
                }

                Flickable {
                  anchors.fill: parent
                  anchors.margins: root.contentSpacing
                  contentHeight: logCol.implicitHeight
                  flickableDirection: Flickable.VerticalFlick
                  boundsBehavior: Flickable.StopAtBounds

                  Column {
                    id: logCol; width: parent.width
                    Text {
                      text: root.logText
                      color: "#b0bccc"
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
                text: "Ready to deploy"
                color: root.surfaceText
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                wrapMode: Text.WordWrap
              }

              // Structured info callout frame with a vertical accent bar
              Rectangle {
                width: parent.width
                height: explain.implicitHeight + Style.space(24)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                clip: true

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(4)
                  color: root.accent
                }

                Text {
                  id: explain
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                  text: "This injects one pam_howdy auth line into sudo, SDDM and polkit, creates a dedicated omarchy-lock-howdy PAM service, configures the IR emitter to fire at unlock, and patches your lock screen to unlock by face when you lift the lid or hit Enter.\n\nYour password auth stays as a fallback and nothing is removed. Proceed?"
                  color: root.surfaceText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.45
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

              // Danger callout frame with a red warning vertical strip
              Rectangle {
                width: parent.width
                height: explain2.implicitHeight + Style.space(24)
                radius: root.cornerRadius
                color: Util.alpha(root.urgent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.urgent, 0.15)
                clip: true

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(4)
                  color: root.urgent
                }

                Text {
                  id: explain2
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                  text: "Your password auth is always left working. Choose whether to also uninstall the howdy / IR-emitter packages (and your enrolled face), or keep them so a later re-enable is instant."
                  color: root.surfaceText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.45
                }
              }
              Row {
                spacing: root.contentSpacing
                Button {
                  text: "🗑  Remove (keep pkgs)"
                  selected: true
                  onClicked: root.startRemove(true)
                }
                Button {
                  text: "💥  Remove + delete pkgs"
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

              // Informational card with a beautiful accent line
              Rectangle {
                width: parent.width
                height: explain3.implicitHeight + Style.space(24)
                radius: root.cornerRadius
                color: Util.alpha(root.accent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                clip: true

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(4)
                  color: root.accent
                }

                Text {
                  id: explain3
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                  text: "Add opens Howdy's own terminal UI to enroll your face. Test runs a recognition check. Clear removes all enrolled faces. Everything runs under root."
                  color: root.surfaceText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.45
                }
              }
              Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: root.contentSpacing
                Button {
                  text: "＋  Add face"
                  selected: true
                  width: Style.space(220)
                  onClicked: root.enrollFace()
                }
                Button {
                  text: "🔍  Test recognition"
                  bordered: true
                  width: Style.space(220)
                  onClicked: root.testFace()
                }
                Button {
                  text: "✕  Clear faces"
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
              text: "✕  Close"
              bordered: true
              onClicked: root.dismiss()
            }

            Button {
              text: "←  Back"
              bordered: true
              visible: root.page === "facelist" || root.page === "remove" || root.page === "confirm"
              onClicked: root.page = "status"
            }

            Button {
              text: "⚙  Deploy PAM"
              bordered: true
              visible: root.page === "status" && root.installed() && !root.pamDeployed() && !root.installing
              onClicked: root.page = "confirm"
            }

            Button {
              text: "👤  Face data"
              bordered: true
              visible: root.page === "status" && root.installed() && !root.installing
              onClicked: root.page = "facelist"
            }

            Button {
              text: "🗑  Remove"
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
  // A single readout cell: glassmorphic, glowing, and beautifully interactive.
  component Cell : Rectangle {
    id: cell
    property string label: ""
    property string valueText: ""
    property bool good: false

    readonly property real cellH: Math.max(root.rowHeight - 4, Style.font.body + Style.space(18))
    readonly property real cellW: Style.space(208)

    width: cell.cellW // Default width, can be overridden by grid
    height: cell.cellH
    radius: root.cornerRadius

    // Smooth color state transitions on hover/tactile interaction
    Behavior on color { ColorAnimation { duration: 150 } }
    Behavior on border.color { ColorAnimation { duration: 150 } }

    MouseArea {
      id: cellHover
      anchors.fill: parent
      hoverEnabled: true
    }

    color: cellHover.containsMouse
      ? (cell.good ? Util.alpha(root.accent, 0.14) : Util.alpha(root.muted, 0.12))
      : (cell.good ? Util.alpha(root.accent, 0.06) : Util.alpha(root.muted, 0.04))

    border {
      width: Math.max(1, Style.space(1))
      color: cellHover.containsMouse
        ? (cell.good ? Util.alpha(root.accent, 0.5) : Util.alpha(root.muted, 0.35))
        : (cell.good ? Util.alpha(root.accent, 0.25) : Util.alpha(root.muted, 0.15))
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      // Status indicator LED ring
      Rectangle {
        id: ledRing
        width: Style.space(18)
        height: Style.space(18)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: cell.good ? Util.alpha(root.accent, 0.15) : Util.alpha(root.urgent, 0.15)
        border.width: Math.max(1, Style.space(1))
        border.color: cell.good ? root.accent : root.urgent

        Text {
          anchors.centerIn: parent
          text: cell.good ? "✓" : "✗"
          color: cell.good ? root.accent : root.urgent
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
          font.pixelSize: Style.font.caption - 1
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
    if (!root.statusLoaded) return "Reading setup state…"
    if (root.yes(root.status.enrolled) && root.pamDeployed()) return "Face unlock is active"
    if (root.installed()) return "Looking good — almost there"
    return "Add Windows-Hello-style face unlock"
  }

  function primaryLabel() {
    switch (root.page) {
      case "status":
        if (root.installing) return "⌛  Working…"
        return root.installed()
          ? (root.yes(root.status.enrolled) ? "🔄  Re-enroll" : "👤  Enroll")
          : "⚡  Install"
      case "install": return root.installComplete ? "✔  OK" : "⌛  Working…"
      case "confirm": return "⚙  Deploy PAM"
      default: return "✔  OK"
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
