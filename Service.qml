import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// face.howdy — Omarchy-native Howdy face-unlock wizard.
// UI adapts to 5 states: not installed / installing / needs attention / active / remove.
// No Nerd Font icon dependency — pure text + native FaceHowdyIcon (QtQuick.Shapes).

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
  property string page: "status"
  property var status: ({})
  property bool statusLoaded: false
  property var cellModel: []

  property string intent: ""
  property string progressLabel: ""
  property bool installing: false
  property bool installComplete: false
  property bool packagesNeedsTerminal: false
  property string packagesCmd: "yay -S --noconfirm --needed howdy-next-git linux-enable-ir-emitter-git"
  property string logText: ""
  property string currentQuote: "Hang tight…"
  property var quotes: []

  // ------------------------------------------------------------------ style
  readonly property color surfaceColor: Color.polkit.background
  readonly property color surfaceText:  Color.polkit.text
  readonly property color surfaceBorder:Color.polkit.border
  readonly property color accent:       Color.accent
  readonly property color foreground:   Color.foreground
  readonly property color muted:        Color.muted
  readonly property color urgent:       Color.urgent
  readonly property color scrim:        Color.polkit.scrim
  readonly property color warn:         "#e8a94f"

  readonly property int r:    Style.cornerRadius
  property  string ff:        Style.font.menuFamily
  property  int cm:           Style.spacing.panelPadding
  property  int sp:           Style.spacing.md
  property  int cardW:        Math.min(Style.space(440), panel.width  - Style.gapsOut * 2)
  property  int cardH:        Math.min(Style.space(580), panel.height - Style.gapsOut * 2)
  property  int btnH:         Math.max(Style.space(34), Style.font.body + Style.spacing.controlPaddingY)

  // ---------------------------------------------------------------- open
  function open(payloadJson) {
    root.opened = true
    root.page   = "status"
    root.statusLoaded = false
    root.refreshStatus()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close()   { root.opened = false }
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
    root.cellModel = root.statusCells()
  }
  function yes(v)         { return v === "yes" }
  function installed()    { return root.yes(root.status.howdy_pkg) && root.yes(root.status.leire_pkg) }
  function pamDeployed()  { return root.yes(root.status.pam_howdy_sudo) || root.yes(root.status.lock_pam) }
  function fullyActive()  { return root.pamDeployed() && root.yes(root.status.enrolled) }
  function needsAttention(){ return root.installed() && !root.fullyActive() }

  // -------------------------------------------------------------- install
  function startInstall()   { root.intent = "install";   root.installComplete = false; root.beginTask("packages"); root.runPhase("packages") }
  function startDeployPam() { root.intent = "deployPam"; root.installComplete = false; root.beginTask("pam");      root.runPhase("pam") }
  function runPhase(phase) {
    root.nextQuote()
    setupProc.phase = phase
    setupProc.collected = ""
    setupProc.command = ["pkexec", "/bin/bash", "--",
      root.pluginBin + "/omarchy-howdy-setup-system", phase]
    setupProc.running = true
  }
  function beginTask(label) { root.installing = true; root.progressLabel = label; root.packagesNeedsTerminal = false; root.logText = ""; root.page = "install" }
  function onSetupDone(ok) {
    if (!ok) { root.failTask(); return }
    if (root.intent === "install") {
      switch (setupProc.phase) {
        case "packages": root.progressLabel = "ir";     root.runPhase("ir");     return
        case "ir":       root.progressLabel = "models"; root.runPhase("models"); return
        case "models":   root.progressLabel = "pam";    root.runPhase("pam");    return
        case "pam":      root.finishSetup(); root.deployLock(); return
      }
    } else if (root.intent === "deployPam") { root.finishSetup(); root.deployLock(); return
    } else if (root.intent === "remove")    { root.finishSetup(); root.scheduleShellRestart(); return
    } else { root.finishSetup(); return }
  }
  function failTask()    { root.installing = false; root.page = "status"; root.intent = ""; root.refreshStatus() }
  function finishSetup() { root.installing = false; root.packagesNeedsTerminal = false; root.installComplete = true; root.progressLabel = "done"; root.currentQuote = "All done."; root.intent = ""; root.refreshStatus() }
  function scheduleShellRestart() { Util.execDetached("omarchy restart shell") }
  function deployLock() {
    lockProc.collected = ""
    lockProc.command = ["/bin/bash", "-c", root.tool("omarchy-howdy-deploy-lock")]
    lockProc.running = true
  }
  function restoreLock() {
    restoreLockProc.collected = ""
    restoreLockProc.command = ["/bin/bash", "-c", root.tool("omarchy-howdy-restore-lock")]
    restoreLockProc.running = true
  }

  // --------------------------------------------------------------- face / terminal
  function openPackagesTerminal() {
    var cmd = root.packagesCmd + "; echo; echo '[face.howdy] packages step finished — close this window when done'; read -p 'Press Enter to close'"
    Util.execDetached("omarchy-launch-terminal bash -lc " + Util.shellQuote(cmd))
  }
  function retryPackages() { root.packagesNeedsTerminal = false; root.runPhase("packages") }
  function enrollFace() {
    var cmd = "sudo howdy add && sudo " + root.pluginBin + "/omarchy-howdy-refresh-state; echo; echo '[face.howdy] enrollment finished — press Enter to close'; read -p 'Press Enter to close'"
    Util.execDetached("omarchy-launch-terminal bash -lc " + Util.shellQuote(cmd))
    root.logText = "Opened terminal for face enrollment — follow the prompts there, then return here."
  }
  function openTestTerminal() {
    var cmd = "sudo howdy test; echo; echo '[face.howdy] test finished — press Enter to close'; read -p 'Press Enter to close'"
    Util.execDetached("omarchy-launch-terminal bash -lc " + Util.shellQuote(cmd))
    root.logText = "Opened terminal for recognition test — results appear there."
  }
  function testFace() {
    // Option A: try in-window GUI preview via pkexec + display env injection.
    // howdy-next drops root→invoking user before opening the OpenCV window, so
    // no xhost dance is needed — just preserve DISPLAY/Wayland creds. Falls
    // back to terminal if no graphical environment is detected.
    var envArgs = []
    var d = Quickshell.env("DISPLAY")
    var w = Quickshell.env("WAYLAND_DISPLAY")
    var r = Quickshell.env("XDG_RUNTIME_DIR")
    var xa = Quickshell.env("XAUTHORITY")
    if (d)  envArgs.push("DISPLAY=" + d)
    if (w)  envArgs.push("WAYLAND_DISPLAY=" + w)
    if (r)  envArgs.push("XDG_RUNTIME_DIR=" + r)
    if (xa) envArgs.push("XAUTHORITY=" + xa)
    if (envArgs.length === 0) { root.openTestTerminal(); return }
    testProc.collected = ""
    var cmd = ["pkexec", "env"].concat(envArgs).concat(["/usr/bin/howdy", "test"])
    testProc.command = cmd
    testProc.running = true
    root.logText = "Opening recognition preview… press Q in the preview window to close it."
  }
  function removeFace() {
    root.intent = "clearFace"; root.beginTask("clear")
    root.runUserCmd("sudo howdy clear -y 2>&1; rc=$?; '" + root.pluginBin + "/omarchy-howdy-refresh-state' 2>/dev/null; exit $rc")
  }
  function runUserCmd(cmd) {
    root.nextQuote()
    setupProc.phase = cmd; setupProc.collected = ""
    setupProc.command = ["pkexec", "/bin/bash", "--", "-c", cmd]
    setupProc.running = true
  }

  // ---------------------------------------------------------------- remove
  function startRemove(keepPkgs) {
    root.intent = "remove"; root.installComplete = false; root.beginTask("remove")
    removeProc.collected = ""
    removeProc.keepPkgs = keepPkgs
    removeProc.command = ["pkexec", "/bin/bash", "--",
      root.pluginBin + "/omarchy-howdy-teardown-system", keepPkgs ? "keep-pkgs" : "delete-pkgs"]
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
  function phaseLabel(p) {
    return ({ packages: "Installing packages", ir: "Configuring IR emitter",
               models: "Downloading face models", pam: "Wiring PAM + lock screen",
               enroll: "Enrolling face", test: "Testing recognition",
               clear: "Clearing face data", remove: "Removing…" })[p] || p
  }
  function phaseIndex()    { return ({ packages: 0, ir: 1, models: 2, pam: 3 })[root.progressLabel] ?? -1 }
  function installProgress(){ return ({ packages: 0.15, ir: 0.40, models: 0.65, pam: 0.88, done: 1.0 })[root.progressLabel] ?? 0.3 }

  function subtitle() {
    if (!root.statusLoaded) return "Reading state…"
    if (root.fullyActive())     return "Face unlock is active"
    if (root.needsAttention())  return "One more step needed"
    return "Convenient face unlock for your ThinkPad"
  }
  function blockingStep() {
    if (!root.installed())        return ""
    if (!root.pamDeployed())      return "PAM isn't wired yet — deploy it to enable face unlock"
    if (!root.yes(root.status.ir_udev)) return "IR emitter not configured — re-run Install to set up the udev rule"
    if (!root.yes(root.status.ir_config)) return "IR emitter not calibrated — run: sudo linux-enable-ir-emitter configure"
    if (!root.yes(root.status.enrolled)) return "No face enrolled yet — add one to activate unlock"
    return ""
  }
  function statusCells() {
    var s = root.status, arr = []
    function add(label, key) { arr.push({ label: label, value: root.yes(s[key]) ? "Enabled" : "Not set", okay: root.yes(s[key]) }) }
    add("Howdy package",  "howdy_pkg")
    add("IR emitter pkg", "leire_pkg")
    add("PAM (sudo)",     "pam_howdy_sudo")
    add("Lock PAM",       "lock_pam")
    add("IR emitter",     "ir_udev")
    add("IR calibrated",  "ir_config")
    add("Face models",    "models")
    add("Face enrolled",  "enrolled")
    var lockName = String(s.active_lock || "stock")
    arr.push({ label: "Lock screen", value: lockName !== "stock" ? lockName : "Stock", okay: lockName !== "stock" })
    return arr
  }
  function installCompleteMsg() {
    if (root.yes(root.status.enrolled)) return "All set up — face enrolled and active."
    return "Ready — enroll a face via Face data → Add."
  }
  function continueSetup() {
    // Resume the install chain from the first missing step. Packages phase is
    // fast-path: if both AUR pkgs already present it returns immediately, so
    // calling startInstall() from any needsAttention state safely finishes the
    // remaining ir/models/pam steps without user having to guess the order.
    root.startInstall()
  }
  function primaryLabel() {
    if (root.page === "install") return root.installComplete ? "Done" : "Working…"
    if (root.page === "confirm") return "Deploy PAM"
    if (root.installing)         return "Working…"
    if (!root.installed())       return "Install"
    if (root.needsAttention()) {
      if (!root.pamDeployed() || !root.yes(root.status.ir_udev) || !root.yes(root.status.ir_config) || !root.yes(root.status.models))
        return "Finish setup"
      if (!root.yes(root.status.enrolled)) return "Enroll face"
    }
    if (!root.yes(root.status.enrolled)) return "Enroll face"
    return "Re-enroll"
  }
  function primaryVisible() {
    if (root.page === "status") return root.installed() && !root.installing
    return root.page === "install" || root.page === "confirm"
  }
  function primaryAction() {
    switch (root.page) {
      case "status":
        if (root.installing) return
        if (!root.installed()) { root.startInstall(); return }
        if (root.needsAttention()) {
          if (!root.pamDeployed() || !root.yes(root.status.ir_udev) || !root.yes(root.status.ir_config) || !root.yes(root.status.models)) {
            root.continueSetup(); return
          }
          // Only enrolled is missing — go to face enrollment.
          root.page = "facelist"; return
        }
        root.page = "facelist"; return
      case "install":
        if (root.installComplete) { root.page = "status"; root.installComplete = false; return }
        return
      case "confirm": root.startDeployPam(); return
    }
  }

  // ------------------------------------------------------------- processes
  Process {
    id: statusProc; property string collected: ""
    command: ["bash", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { statusProc.collected += data + "\n" } }
    onExited: root.parseStatus()
  }
  Process {
    id: setupProc; property string collected: ""; property string phase: ""
    command: ["pkexec", "/bin/bash", "--", "true"]
    stdout: SplitParser { onRead: function(data) { setupProc.collected += data + "\n"; root.logText += data + "\n"; root.nextQuote() } }
    onExited: {
      if (exitCode === 42) {
        root.installing = false
        root.packagesNeedsTerminal = true
        root.logText += "\n[face.howdy] Packages need a terminal — see instructions above.\n"
        return
      }
      if (exitCode !== 0) root.logText += "Error: step failed.\n"
      root.onSetupDone(exitCode === 0)
    }
  }
  Process {
    id: testProc; property string collected: ""
    command: ["pkexec", "env", "/usr/bin/howdy", "test"]
    stdout: SplitParser { onRead: function(data) { testProc.collected += data + "\n"; root.logText += data + "\n" } }
    stderr: SplitParser { onRead: function(data) { testProc.collected += data + "\n"; root.logText += data + "\n" } }
    onExited: {
      var out = String(testProc.collected)
      var noDisplay = out.indexOf("no graphical display") !== -1
                    || out.indexOf("Cannot open the interactive test preview") !== -1
      if (noDisplay) {
        root.logText += "\n[face.howdy] No display reachable — falling back to terminal.\n"
        root.openTestTerminal()
        return
      }
      if (exitCode !== 0 && out.trim() === "") {
        // pkexec cancelled or silent failure — don't spam terminal fallback
        root.logText += "Test closed (code " + exitCode + ").\n"
        return
      }
      if (exitCode !== 0) root.logText += "Test exited (code " + exitCode + ").\n"
      else root.logText += "Test finished — press Q in the preview to reopen, or close this panel.\n"
    }
  }
  Process {
    id: quotesProc; command: ["cat", "/dev/null"]
    stdout: SplitParser { onRead: function(data) { root.quotes = String(data).split("\n").filter(Boolean) } }
  }
  Process {
    id: lockProc; property string collected: ""
    command: ["/bin/bash", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { lockProc.collected += data + "\n" } }
    onExited: { root.logText += lockProc.collected; root.scheduleShellRestart() }
  }
  Process {
    id: removeProc; property string collected: ""; property bool keepPkgs: true
    command: ["pkexec", "/bin/bash", "--", "true"]
    stdout: SplitParser { onRead: function(data) { removeProc.collected += data + "\n"; root.logText += data + "\n" } }
    onExited: {
      root.logText += removeProc.collected
      if (exitCode !== 0) { root.logText += "Error: teardown failed.\n"; root.failTask(); return }
      // Teardown succeeded — now restore the stock lock screen as the unprivileged user.
      root.restoreLock()
    }
  }
  Process {
    id: restoreLockProc; property string collected: ""
    command: ["/bin/bash", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { restoreLockProc.collected += data + "\n" } }
    onExited: { root.logText += restoreLockProc.collected; root.finishSetup(); root.scheduleShellRestart() }
  }

  // ================================================================ window
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
      width: root.cardW; height: root.cardH
      radius: root.r
      anchors.centerIn: parent
      color: root.surfaceColor
      borderSpec: Border.surfaceSpec("polkit", "border", root.surfaceBorder, Math.max(1, Style.space(1)))
      padding: root.cm
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin:    card.contentTopInset
        anchors.rightMargin:  card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin:   card.contentLeftInset
        focus: true
        Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) root.dismiss() }

        Column {
          anchors.fill: parent
          spacing: root.sp

          // ------------------------------------------- header
          Item {
            id: hdr
            width: parent.width
            height: Style.space(52)

            // Icon circle — glows stronger when active
            Rectangle {
              id: iconCircle
              width: Style.space(40); height: Style.space(40)
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: {
                if (root.statusLoaded && root.fullyActive()) return Util.alpha(root.accent, 0.15)
                return Util.alpha(root.accent, 0.08)
              }
              border.width: Math.max(1, Style.space(1))
              border.color: {
                if (root.statusLoaded && root.fullyActive()) return Util.alpha(root.accent, 0.45)
                return Util.alpha(root.accent, 0.2)
              }
              Behavior on color       { ColorAnimation { duration: 300 } }
              Behavior on border.color{ ColorAnimation { duration: 300 } }

              FaceHowdyIcon {
                anchors.centerIn: parent
                iconSize: Style.space(22)
                color: root.accent
              }
            }

            // Title + subtitle
            Column {
              anchors.left: iconCircle.right; anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "Face Howdy"
                color: root.surfaceText
                font.family: root.ff; font.pixelSize: Style.font.body + 1; font.bold: true
              }
              Text {
                text: root.subtitle()
                color: root.muted
                font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }

            // Status pill
            Rectangle {
              visible: root.page === "status" && root.statusLoaded
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              width: pillContent.implicitWidth + Style.space(20)
              height: Style.space(24)
              radius: height / 2
              color: {
                if (root.fullyActive())    return Util.alpha(root.accent, 0.12)
                if (root.needsAttention()) return Util.alpha(root.warn, 0.12)
                return Util.alpha(root.muted, 0.07)
              }
              border.width: Math.max(1, Style.space(1))
              border.color: {
                if (root.fullyActive())    return Util.alpha(root.accent, 0.35)
                if (root.needsAttention()) return Util.alpha(root.warn, 0.35)
                return Util.alpha(root.muted, 0.18)
              }
              Behavior on color        { ColorAnimation { duration: 250 } }
              Behavior on border.color { ColorAnimation { duration: 250 } }

              Row {
                id: pillContent
                anchors.centerIn: parent
                spacing: Style.space(6)

                // Animated dot
                Rectangle {
                  width: Style.space(6); height: Style.space(6)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: {
                    if (root.fullyActive())    return root.accent
                    if (root.needsAttention()) return root.warn
                    return root.muted
                  }
                  Behavior on color { ColorAnimation { duration: 250 } }

                  // Pulse only when active
                  SequentialAnimation on opacity {
                    running: root.statusLoaded && root.fullyActive()
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                  }
                }

                Text {
                  id: pillTxt
                  text: root.fullyActive() ? "Active" : (root.needsAttention() ? "Almost there" : "Not set up")
                  color: {
                    if (root.fullyActive())    return root.accent
                    if (root.needsAttention()) return root.warn
                    return root.muted
                  }
                  font.family: root.ff; font.pixelSize: Style.font.caption - 1; font.bold: true
                  Behavior on color { ColorAnimation { duration: 250 } }
                }
              }
            }
          }

          // Divider with gradient fade-out on the right
          Item {
            width: parent.width; height: Math.max(1, Style.space(1))
            Rectangle {
              anchors.fill: parent
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Util.alpha(root.surfaceBorder, 0.6) }
                GradientStop { position: 0.7; color: Util.alpha(root.surfaceBorder, 0.25) }
                GradientStop { position: 1.0; color: "transparent" }
              }
            }
          }

          // ------------------------------------------- body
          Item {
            id: body
            width: parent.width
            height: parent.height - hdr.height - footerRow.height - root.sp * 3 - Style.space(1)

            // ==== STATUS page ====
            Column {
              visible: root.page === "status"
              anchors.fill: parent
              spacing: root.sp

              // --- Not installed ---
              Column {
                visible: !root.statusLoaded || (!root.installed() && !root.installing)
                width: parent.width; spacing: root.sp

                // Hero icon — larger, centered
                Item {
                  width: parent.width; height: Style.space(88)
                  Rectangle {
                    width: Style.space(72); height: Style.space(72)
                    radius: width / 2
                    anchors.centerIn: parent
                    color: Util.alpha(root.accent, 0.07)
                    border.width: Math.max(1, Style.space(1))
                    border.color: Util.alpha(root.accent, 0.15)

                    FaceHowdyIcon {
                      anchors.centerIn: parent
                      iconSize: Style.space(34)
                      color: Util.alpha(root.accent, 0.85)
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: "Face unlock for your desktop"
                  color: root.surfaceText
                  font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }
                Text {
                  width: parent.width
                  text: "Uses your ThinkPad's IR camera. Unlocks sudo, SDDM and the lock screen. Password always stays as fallback."
                  color: root.muted
                  font.family: root.ff; font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.55
                }

                // Feature pills — full-width rows, no icon glyphs
                Column {
                  width: parent.width
                  spacing: Style.space(5)
                  topPadding: Style.space(2)

                  Repeater {
                    model: [
                      "Sudo, polkit and SDDM",
                      "Works in the dark via IR",
                      "Password stays as fallback",
                      "Safe to re-run after updates"
                    ]
                    delegate: Rectangle {
                      width: parent.width
                      height: Style.space(28)
                      radius: root.r
                      color: Util.alpha(root.accent, 0.04)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.accent, 0.1)

                      // Left accent tab
                      Rectangle {
                        width: Style.space(3); height: parent.height * 0.5
                        radius: width / 2
                        anchors.left: parent.left; anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        color: Util.alpha(root.accent, 0.5)
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left; anchors.leftMargin: Style.space(20)
                        text: modelData
                        color: root.muted
                        font.family: root.ff; font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                Item {
                  visible: root.statusLoaded
                  width: parent.width; height: Style.space(40)
                  Button {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Install Face Howdy"
                    selected: true; fontFamily: root.ff
                    onClicked: root.startInstall()
                  }
                }
              }

              // --- Needs attention ---
              Column {
                visible: root.statusLoaded && root.needsAttention() && !root.installing
                width: parent.width; spacing: root.sp

                // Attention banner — left bar + text, no glyph
                Rectangle {
                  width: parent.width
                  height: attnInner.implicitHeight + Style.space(22)
                  radius: root.r
                  color: Util.alpha(root.warn, 0.05)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.warn, 0.25)
                  clip: true

                  Rectangle {
                    anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: Style.space(3); color: root.warn
                  }

                  Column {
                    id: attnInner
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                    anchors.right: parent.right; anchors.rightMargin: Style.space(14)
                    spacing: Style.space(3)
                    Text {
                      text: "Almost there"
                      color: root.warn; font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true
                    }
                    Text {
                      width: parent.width
                      text: root.blockingStep()
                      color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap; lineHeight: 1.4
                    }
                  }
                }

                // Cell grid
                Grid {
                  width: parent.width; columns: 2; spacing: Style.space(6)
                  Repeater {
                    model: root.cellModel
                    delegate: MiniCell {
                      width: (parent.width - Style.space(6)) / 2
                      label: modelData.label; good: modelData.okay; valueText: modelData.value
                    }
                  }
                }

                // CTA — the missing "finish setting up" entry. When PAM/IR/models
                // are still absent this calls continueSetup (full install chain);
                // when only a face is missing it goes to enrollment. Fixes the
                // dead-end after manual pkg install or interrupted install.
                Button {
                  width: parent.width
                  text: (!root.pamDeployed() || !root.yes(root.status.ir_udev) || !root.yes(root.status.ir_config) || !root.yes(root.status.models)) ? "Finish setup" : "Enroll face"
                  selected: true; fontFamily: root.ff
                  onClicked: {
                    if (!root.pamDeployed() || !root.yes(root.status.ir_udev) || !root.yes(root.status.ir_config) || !root.yes(root.status.models))
                      root.continueSetup()
                    else
                      root.page = "facelist"
                  }
                }
                Text {
                  width: parent.width
                  text: "or manage face data →"
                  color: Util.alpha(root.muted, 0.5)
                  font.family: root.ff; font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  visible: !root.pamDeployed() || !root.yes(root.status.ir_udev) || !root.yes(root.status.ir_config) || !root.yes(root.status.models)
                  MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: root.page = "facelist"
                  }
                }
              }

              // --- Fully active ---
              Column {
                visible: root.statusLoaded && root.fullyActive() && !root.installing
                width: parent.width; spacing: Style.space(10)

                // Hero — face icon with double ring
                Item {
                  width: parent.width; height: Style.space(100)

                  // Outer ring — subtle, large
                  Rectangle {
                    width: Style.space(84); height: Style.space(84)
                    radius: width / 2
                    anchors.centerIn: parent
                    color: "transparent"
                    border.width: Math.max(1, Style.space(1))
                    border.color: Util.alpha(root.accent, 0.15)
                  }

                  // Inner ring — main
                  Rectangle {
                    width: Style.space(68); height: Style.space(68)
                    radius: width / 2
                    anchors.centerIn: parent
                    color: Util.alpha(root.accent, 0.08)
                    border.width: Math.max(1, Style.space(2))
                    border.color: Util.alpha(root.accent, 0.45)

                    FaceHowdyIcon {
                      anchors.centerIn: parent
                      iconSize: Style.space(32)
                      color: root.accent
                    }
                  }
                }

                // Title
                Column {
                  width: parent.width; spacing: Style.space(4)
                  Text {
                    width: parent.width; text: "Running"
                    color: root.surfaceText; font.family: root.ff
                    font.pixelSize: Style.font.title; font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                  }
                  Text {
                    width: parent.width
                    text: "Face unlock active across sudo, polkit and your lock screen"
                    color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.5
                  }
                }

                // Status row — horizontal strip of labeled dots
                Rectangle {
                  width: parent.width
                  height: Style.space(38)
                  radius: root.r
                  color: Util.alpha(root.accent, 0.04)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.accent, 0.12)

                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(14)

                    Repeater {
                      model: [
                        { label: "Howdy",      key: "howdy_pkg" },
                        { label: "IR",         key: "leire_pkg" },
                        { label: "PAM",        key: "pam_howdy_sudo" },
                        { label: "Lock",       key: "lock_pam" },
                        { label: "Face",       key: "enrolled" }
                      ]
                      delegate: Row {
                        spacing: Style.space(5)
                        anchors.verticalCenter: parent.verticalCenter
                        property bool ok: root.yes(root.status[modelData.key])

                        Rectangle {
                          width: Style.space(6); height: Style.space(6)
                          radius: width / 2
                          anchors.verticalCenter: parent.verticalCenter
                          color: ok ? root.accent : Util.alpha(root.muted, 0.3)
                        }
                        Text {
                          text: modelData.label
                          color: ok ? root.surfaceText : root.muted
                          font.family: root.ff; font.pixelSize: Style.font.caption
                          font.bold: ok
                        }
                      }
                    }
                  }
                }

                // Details link — subtle text button
                Text {
                  width: parent.width
                  text: "Status details →"
                  color: Util.alpha(root.accent, 0.6)
                  font.family: root.ff; font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: root.page = "details"
                    onPressed:  parent.color = root.accent
                    onReleased: parent.color = Util.alpha(root.accent, 0.6)
                  }
                }
              }
            }

            // ==== DETAILS page ====
            Column {
              visible: root.page === "details"
              anchors.fill: parent; spacing: root.sp

              Text {
                text: "Status details"
                color: root.surfaceText; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
              }
              Text {
                width: parent.width
                text: "Everything Face Howdy manages — accent means active, gray means not set."
                color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap; lineHeight: 1.45
              }
              Grid {
                width: parent.width; columns: 2; spacing: Style.space(6)
                Repeater {
                  model: root.cellModel
                  delegate: MiniCell {
                    width: (parent.width - Style.space(6)) / 2
                    label: modelData.label; good: modelData.okay; valueText: modelData.value
                  }
                }
              }
            }

            // ==== INSTALL page ====
            Column {
              visible: root.page === "install"
              anchors.fill: parent; spacing: root.sp

              // Phase label + %
              Row {
                width: parent.width
                Text {
                  id: labelPct
                  text: root.progressLabel === "done" ? "All done" : root.phaseLabel(root.progressLabel)
                  color: root.surfaceText; font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true
                }
                Item { width: parent.width - labelPct.implicitWidth - pctTxt.implicitWidth; height: 1 }
                Text {
                  id: pctTxt
                  text: Math.round(root.installProgress() * 100) + "%"
                  color: root.accent; font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true
                }
              }

              // Progress bar
              Rectangle {
                width: parent.width; height: Style.space(3); radius: Style.space(2)
                color: Util.alpha(root.accent, 0.1)
                Rectangle {
                  width: parent.width * root.installProgress(); height: parent.height; radius: parent.radius
                  color: root.accent
                  Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

                  // Shimmer on the leading edge
                  Rectangle {
                    anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: Style.space(20)
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0.0; color: "transparent" }
                      GradientStop { position: 1.0; color: Util.alpha("#ffffff", 0.25) }
                    }
                    visible: root.installing
                  }
                }
              }

              // Phase list — text only, no glyph icons
              Column {
                width: parent.width; spacing: Style.space(4)
                Repeater {
                  model: ["packages", "ir", "models", "pam"]
                  delegate: Item {
                    width: parent.width; height: Style.space(34)
                    property int  idx:      index
                    property int  cur:      root.phaseIndex()
                    property bool isDone:   idx < cur || root.installComplete
                    property bool isActive: idx === cur && root.installing

                    Rectangle {
                      anchors.fill: parent; radius: root.r
                      color: {
                        if (isDone)   return Util.alpha(root.accent, 0.06)
                        if (isActive) return Util.alpha(root.accent, 0.11)
                        return Util.alpha(root.muted, 0.03)
                      }
                      border.width: Math.max(1, Style.space(1))
                      border.color: {
                        if (isDone)   return Util.alpha(root.accent, 0.2)
                        if (isActive) return Util.alpha(root.accent, 0.4)
                        return Util.alpha(root.muted, 0.08)
                      }
                      Behavior on color        { ColorAnimation { duration: 150 } }
                      Behavior on border.color { ColorAnimation { duration: 150 } }

                      // Left bar — replaces icon
                      Rectangle {
                        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                        width: Style.space(3); radius: root.r
                        color: {
                          if (isDone)   return Util.alpha(root.accent, 0.6)
                          if (isActive) return root.accent
                          return Util.alpha(root.muted, 0.15)
                        }
                        Behavior on color { ColorAnimation { duration: 150 } }
                      }

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(14)
                        anchors.rightMargin: Style.space(12)
                        spacing: Style.space(10)

                        // State indicator — small dot
                        Rectangle {
                          width: Style.space(6); height: Style.space(6)
                          radius: width / 2
                          anchors.verticalCenter: parent.verticalCenter
                          color: {
                            if (isDone)   return root.accent
                            if (isActive) return root.accent
                            return Util.alpha(root.muted, 0.3)
                          }
                          Behavior on color { ColorAnimation { duration: 150 } }

                          SequentialAnimation on opacity {
                            running: isActive
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.2; duration: 500; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutSine }
                          }
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.phaseLabel(modelData)
                          color: (isDone || isActive) ? root.surfaceText : root.muted
                          font.family: root.ff; font.pixelSize: Style.font.body; font.bold: isActive
                          Behavior on color { ColorAnimation { duration: 150 } }
                        }
                      }
                    }
                  }
                }
              }

              // Quote
              Rectangle {
                width: parent.width
                height: quoteTxt.implicitHeight + Style.space(18)
                radius: root.r
                color: Util.alpha(root.accent, 0.04)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.12)
                visible: root.installing

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(2); color: Util.alpha(root.accent, 0.35); radius: root.r
                }

                Text {
                  id: quoteTxt
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(14)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(12)
                  text: "\u201c" + root.currentQuote + "\u201d"
                  color: Util.alpha(root.muted, 0.75)
                  font.family: root.ff; font.pixelSize: Style.font.caption; font.italic: true
                  wrapMode: Text.WordWrap; lineHeight: 1.4
                }
              }

              // Packages terminal fallback — AUR needs a TTY
              Rectangle {
                visible: root.packagesNeedsTerminal && root.progressLabel === "packages"
                width: parent.width
                height: pkgTermCol.implicitHeight + Style.space(22)
                radius: root.r
                color: Util.alpha(root.warn, 0.06)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.warn, 0.30)
                clip: true

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(3); color: root.warn
                }

                Column {
                  id: pkgTermCol
                  anchors.left: parent.left; anchors.leftMargin: Style.space(14)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    width: parent.width
                    text: "Packages need a terminal — yay prompts for sudo"
                    color: root.warn; font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
                    wrapMode: Text.WordWrap
                  }
                  Rectangle {
                    width: parent.width; height: pkgCmdTxt.implicitHeight + Style.space(10)
                    radius: Style.space(6)
                    color: Util.alpha(Color.background, 0.9)
                    border.width: Math.max(1, Style.space(1))
                    border.color: Util.alpha(root.muted, 0.12)
                    Text {
                      id: pkgCmdTxt
                      anchors.centerIn: parent
                      width: parent.width - Style.space(16)
                      text: root.packagesCmd
                      color: root.surfaceText; font.family: "monospace"; font.pixelSize: Style.font.caption - 1
                      wrapMode: Text.Wrap
                    }
                  }
                  Row {
                    width: parent.width; spacing: Style.space(8)
                    Button { text: "Open in terminal"; selected: true; fontFamily: root.ff; onClicked: root.openPackagesTerminal() }
                    Button { text: "I've finished — continue"; bordered: true; fontFamily: root.ff; onClicked: root.retryPackages() }
                  }
                }
              }

              // Log — darker, more terminal-like
              Rectangle {
                width: parent.width
                height: Math.max(Style.space(110), body.height - Style.space(240))
                radius: root.r
                color: Util.alpha(Color.background, 0.75)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.muted, 0.1)
                clip: true

                // Top fade mask
                Rectangle {
                  anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                  height: Style.space(12); z: 1
                  gradient: Gradient {
                    GradientStop { position: 0.0; color: Util.alpha(Color.background, 0.7) }
                    GradientStop { position: 1.0; color: "transparent" }
                  }
                }

                Flickable {
                  anchors.fill: parent; anchors.margins: Style.space(10)
                  contentHeight: logTxt.implicitHeight
                  flickableDirection: Flickable.VerticalFlick
                  boundsBehavior: Flickable.StopAtBounds
                  onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

                  Text {
                    id: logTxt
                    width: parent.width; text: root.logText || "—"
                    color: Util.alpha(root.accent, 0.7)
                    font.family: "monospace"; font.pixelSize: Style.font.caption - 1
                    wrapMode: Text.Wrap; lineHeight: 1.55
                  }
                }
              }

              Text {
                visible: root.installComplete; width: parent.width
                text: root.installCompleteMsg()
                color: root.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ==== CONFIRM page ====
            Column {
              visible: root.page === "confirm"
              anchors.fill: parent; spacing: root.sp

              Text {
                text: "Deploy PAM?"
                color: root.surfaceText; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
              }

              // Info block — left bar, no icon glyph
              Rectangle {
                width: parent.width
                height: confirmTxt.implicitHeight + Style.space(28)
                radius: root.r
                color: Util.alpha(root.accent, 0.04)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                clip: true

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(3); color: root.accent
                }

                Text {
                  id: confirmTxt
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                  text: "Adds pam_howdy to sudo, SDDM and polkit. Patches your lock screen to unlock on lid open. Password stays as fallback."
                  color: root.surfaceText; font.family: root.ff; font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap; lineHeight: 1.5
                }
              }

              // Note
              Text {
                width: parent.width
                text: "A pkexec authorisation prompt will appear."
                color: Util.alpha(root.muted, 0.6)
                font.family: root.ff; font.pixelSize: Style.font.caption; font.italic: true
              }
            }

            // ==== REMOVE page ====
            Column {
              visible: root.page === "remove"
              anchors.fill: parent; spacing: root.sp

              Column {
                width: parent.width; spacing: Style.space(6); topPadding: Style.space(4)
                Text {
                  width: parent.width; text: "Remove Face Howdy?"
                  color: root.urgent; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }
                Text {
                  width: parent.width
                  text: "PAM lines are always cleared and password auth restored. Choose what happens to the packages."
                  color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.45
                }
              }

              // Option cards — full-width, left bar accent, hover
              Column {
                width: parent.width; spacing: Style.space(8)

                // Keep packages
                Rectangle {
                  id: keepCard
                  width: parent.width
                  height: keepCol.implicitHeight + Style.space(28)
                  radius: root.r
                  color: Util.alpha(root.muted, 0.04)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.muted, 0.14)
                  clip: true
                  Behavior on color        { ColorAnimation { duration: 100 } }
                  Behavior on border.color { ColorAnimation { duration: 100 } }

                  Rectangle {
                    anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: Style.space(3); color: Util.alpha(root.accent, 0.5)
                  }

                  MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: root.startRemove(true)
                    onEntered:  { keepCard.color = Util.alpha(root.muted, 0.09); keepCard.border.color = Util.alpha(root.accent, 0.2) }
                    onExited:   { keepCard.color = Util.alpha(root.muted, 0.04); keepCard.border.color = Util.alpha(root.muted, 0.14) }
                  }

                  Column {
                    id: keepCol
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: Style.space(18)
                    anchors.right: parent.right; anchors.rightMargin: Style.space(14)
                    spacing: Style.space(3)
                    Text { text: "Keep packages"; color: root.surfaceText; font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true }
                    Text {
                      width: parent.width; text: "Clears PAM and the lock patch. Re-enabling later is instant — no reinstall."
                      color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                    }
                  }
                }

                // Remove everything
                Rectangle {
                  id: deleteCard
                  width: parent.width
                  height: deleteCol.implicitHeight + Style.space(28)
                  radius: root.r
                  color: Util.alpha(root.urgent, 0.04)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.urgent, 0.18)
                  clip: true
                  Behavior on color        { ColorAnimation { duration: 100 } }
                  Behavior on border.color { ColorAnimation { duration: 100 } }

                  Rectangle {
                    anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: Style.space(3); color: Util.alpha(root.urgent, 0.6)
                  }

                  MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: root.startRemove(false)
                    onEntered:  { deleteCard.color = Util.alpha(root.urgent, 0.09); deleteCard.border.color = Util.alpha(root.urgent, 0.35) }
                    onExited:   { deleteCard.color = Util.alpha(root.urgent, 0.04); deleteCard.border.color = Util.alpha(root.urgent, 0.18) }
                  }

                  Column {
                    id: deleteCol
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: Style.space(18)
                    anchors.right: parent.right; anchors.rightMargin: Style.space(14)
                    spacing: Style.space(3)
                    Text { text: "Remove everything"; color: root.urgent; font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true }
                    Text {
                      width: parent.width; text: "Uninstalls howdy and IR emitter packages, deletes enrolled face data."
                      color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }

            // ==== FACELIST page ====
            Column {
              visible: root.page === "facelist"
              anchors.fill: parent; spacing: root.sp

              Text {
                text: "Face data"
                color: root.surfaceText; font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
              }
              Text {
                width: parent.width
                text: "Add opens terminal enrollment. Test pops a live camera preview — press Q to close. Clear removes all faces."
                color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap; lineHeight: 1.45
              }

              Column {
                width: parent.width; spacing: Style.space(8)
                Button { text: "Add face";        selected: true;  width: parent.width; fontFamily: root.ff; onClicked: root.enrollFace() }
                Button { text: "Test recognition"; bordered: true; width: parent.width; fontFamily: root.ff; onClicked: root.testFace() }
                Button {
                  text: "Clear faces"; bordered: true; foreground: root.urgent
                  width: parent.width; fontFamily: root.ff; onClicked: root.removeFace()
                }
              }
            }
          }

          // ------------------------------------------- footer
          Row {
            id: footerRow
            width: parent.width; height: root.btnH; spacing: root.sp

            Button {
              id: backBtn; text: "← Back"; bordered: true; fontFamily: root.ff
              visible: root.page === "facelist" || root.page === "remove" || root.page === "confirm" || root.page === "details"
              onClicked: root.page = "status"
            }
            Button {
              id: removeBtn; text: "Remove"; bordered: true; foreground: root.urgent; fontFamily: root.ff
              visible: root.page === "status" && (root.installed() || root.pamDeployed()) && !root.installing
              onClicked: root.page = "remove"
            }

            Item {
              height: 1
              width: footerRow.width
                - (backBtn.visible   ? backBtn.width   + root.sp : 0)
                - (removeBtn.visible ? removeBtn.width + root.sp : 0)
                - (deployBtn.visible ? deployBtn.width + root.sp : 0)
                - (faceDataBtn.visible ? faceDataBtn.width + root.sp : 0)
                - (primaryBtn.visible ? primaryBtn.width + root.sp : 0)
            }

            Button {
              id: deployBtn; text: "Deploy PAM"; bordered: true; fontFamily: root.ff
              visible: root.page === "status" && root.installed() && !root.pamDeployed() && !root.installing
              onClicked: root.page = "confirm"
            }
            Button {
              id: faceDataBtn; text: "Face data"; bordered: true; fontFamily: root.ff
              visible: root.page === "status" && root.installed() && !root.installing
              onClicked: root.page = "facelist"
            }
            Button {
              id: primaryBtn; text: root.primaryLabel(); selected: true; fontFamily: root.ff
              visible: root.primaryVisible(); onClicked: root.primaryAction()
            }
          }
        }
      }
    }
  }

  // ================================================================ components

  component MiniCell : Rectangle {
    id: mc
    property string label: ""
    property string valueText: ""
    property bool   good: false

    height: Math.max(Style.space(40), Style.font.body + Style.space(20))
    radius: root.r
    clip: true

    Behavior on color        { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }

    color: mc.good ? Util.alpha(root.accent, 0.05) : Util.alpha(root.muted, 0.03)
    border {
      width: Math.max(1, Style.space(1))
      color: mc.good ? Util.alpha(root.accent, 0.2) : Util.alpha(root.muted, 0.1)
    }

    // Left accent bar — replaces LED circle, no glyph needed
    Rectangle {
      anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
      width: Style.space(3)
      color: mc.good ? Util.alpha(root.accent, 0.7) : Util.alpha(root.muted, 0.2)
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left; anchors.leftMargin: Style.space(14)
      anchors.right: parent.right; anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        text: mc.label
        color: root.muted; font.family: root.ff; font.pixelSize: Style.font.caption - 2
      }
      Text {
        text: mc.valueText
        color: mc.good ? root.surfaceText : Util.alpha(root.muted, 0.6)
        font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: mc.good
      }
    }
  }
}
