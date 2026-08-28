import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// face.howdy — Omarchy-native Howdy face-unlock wizard.
//
// Overlay plugin: menu-launched window that walks through installing Howdy,
// configuring the IR emitter, wiring PAM, enrolling a face, and removing
// everything cleanly. All privileged ops go through pkexec → bundled bin/ scripts.
//
// UI adapts to 5 states: not installed (hero CTA) / installing (phases) /
// needs attention (banner) / protected (face-ring hero + chips) / remove.
// Icons are Nerd Font PUA glyphs (UI font = JetBrainsMono Nerd Font).

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
  property string page: "status"       // status | install | confirm | remove | facelist | details
  property var status: ({})
  property bool statusLoaded: false
  property var cellModel: []

  property string intent: ""           // "" | install | deployPam | remove | enroll | test | clearFace
  property string progressLabel: ""
  property bool installing: false
  property bool installComplete: false
  property string logText: ""
  property string currentQuote: "Hang tight…"
  property var quotes: []

  // ------------------------------------------------------------------ style
  readonly property color surfaceColor: Color.polkit.background
  readonly property color surfaceText: Color.polkit.text
  readonly property color surfaceBorder: Color.polkit.border
  readonly property color accent: Color.accent
  readonly property color foreground: Color.foreground
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color scrim: Color.polkit.scrim
  // Warning amber: the palette has no warning token, so compose a warm one
  // for "almost there" attention surfaces (mockup: --border-warning family).
  readonly property color warn: "#e8a94f"
  readonly property int r: Style.cornerRadius
  property string ff: Style.font.menuFamily
  property int cm: Style.spacing.panelPadding
  property int sp: Style.spacing.md
  property int cardW: Math.min(Style.space(440), panel.width - Style.gapsOut * 2)
  property int cardH: Math.min(Style.space(580), panel.height - Style.gapsOut * 2)
  property int btnH: Math.max(Style.space(34), Style.font.body + Style.spacing.controlPaddingY)

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
    root.cellModel = root.statusCells()
  }
  function yes(v) { return v === "yes" }
  function installed() { return root.yes(root.status.howdy_pkg) && root.yes(root.status.leire_pkg) }
  function pamDeployed() { return root.yes(root.status.pam_howdy_sudo) || root.yes(root.status.lock_pam) }
  function fullyActive() { return root.pamDeployed() && root.yes(root.status.enrolled) }
  function needsAttention() { return root.installed() && !root.fullyActive() }

  // -------------------------------------------------------------- install
  function startInstall() {
    root.intent = "install"
    root.installComplete = false
    root.beginTask("packages")
    root.runPhase("packages")
  }
  function startDeployPam() {
    root.intent = "deployPam"
    root.installComplete = false
    root.beginTask("pam")
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
        case "packages": root.progressLabel = "ir";     root.runPhase("ir");     return
        case "ir":       root.progressLabel = "models"; root.runPhase("models"); return
        case "models":   root.progressLabel = "pam";    root.runPhase("pam");    return
        case "pam":      root.finishSetup(); root.deployLock(); return
      }
    } else if (root.intent === "deployPam") {
      root.finishSetup(); root.deployLock(); return
    } else if (root.intent === "remove") {
      root.finishSetup(); root.scheduleShellRestart(); return
    } else {
      root.finishSetup(); return
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
    root.currentQuote = "All done."
    root.intent = ""
    root.refreshStatus()
  }
  function scheduleShellRestart() { Util.execDetached("omarchy restart shell") }
  function deployLock() {
    lockProc.collected = ""
    lockProc.command = ["/bin/bash", "-c", root.tool("omarchy-howdy-deploy-lock")]
    lockProc.running = true
  }

  // --------------------------------------------------------------- face
  function enrollFace() {
    root.intent = "enroll"
    root.beginTask("enroll")
    root.runUserCmd("sudo howdy add 2>&1 || true; '" + root.pluginBin + "/omarchy-howdy-refresh-state' 2>/dev/null; echo 'done: enroll'")
  }
  function testFace() {
    root.intent = "test"
    root.beginTask("test")
    root.runUserCmd("sudo howdy test 2>&1 || true; echo 'done: test'")
  }
  function removeFace() {
    root.intent = "clearFace"
    root.beginTask("clear")
    root.runUserCmd("sudo howdy clear -y 2>&1 || true; '" + root.pluginBin + "/omarchy-howdy-refresh-state' 2>/dev/null; echo 'done: clear'")
  }
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
    root.beginTask("remove")
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

  // Phase label shown in the phase list
  function phaseLabel(p) {
    return ({ packages: "Installing packages", ir: "Configuring IR emitter",
               models: "Downloading face models", pam: "Wiring PAM + lock screen",
               enroll: "Enrolling face", test: "Testing recognition",
               clear: "Clearing face data", remove: "Removing…" })[p] || p
  }
  // Which phase index are we on (0-3 for install flow)
  function phaseIndex() {
    return ({ packages: 0, ir: 1, models: 2, pam: 3 })[root.progressLabel] ?? -1
  }
  function installProgress() {
    return ({ packages: 0.15, ir: 0.40, models: 0.65, pam: 0.88, done: 1.0 })[root.progressLabel] ?? 0.3
  }

  function overviewTitle() {
    if (!root.statusLoaded) return "Checking…"
    if (root.installComplete) return "All done"
    if (root.fullyActive()) return "Active"
    if (root.needsAttention()) return "Almost there"
    return "Not set up"
  }
  function overviewText() {
    var s = root.status, rows = []
    if (root.installed()) rows.push("Packages installed")
    if (root.yes(s.models)) rows.push("Face models ready")
    if (root.yes(s.enrolled)) rows.push("Face enrolled")
    if (root.pamDeployed()) rows.push("PAM wired")
    if (root.yes(s.ir_udev)) rows.push("IR emitter configured")
    if (rows.length === 0) rows.push("Run install to set up face unlock")
    return rows.join("  ·  ")
  }
  function subtitle() {
    if (!root.statusLoaded) return "Reading state…"
    if (root.fullyActive()) return "Face unlock is active"
    if (root.needsAttention()) return "One more step needed"
    return "Convenient face unlock for your ThinkPad"
  }
  // What's blocking full activation (for the attention banner)
  function blockingStep() {
    if (!root.installed()) return ""
    if (!root.pamDeployed()) return "PAM isn't wired yet — deploy it to enable face unlock"
    if (!root.yes(root.status.enrolled)) return "No face enrolled yet — add one to activate unlock"
    return ""
  }

  function statusCells() {
    var s = root.status, arr = []
    function add(label, key) {
      arr.push({ label: label, value: root.yes(s[key]) ? "Enabled" : "Not set", okay: root.yes(s[key]) })
    }
    add("Howdy package",  "howdy_pkg")
    add("IR emitter pkg", "leire_pkg")
    add("PAM (sudo)",     "pam_howdy_sudo")
    add("Lock PAM",       "lock_pam")
    add("IR emitter",     "ir_udev")
    add("Face models",    "models")
    add("Face enrolled",  "enrolled")
    var lockName = String(s.active_lock || "stock")
    arr.push({ label: "Lock screen", value: lockName !== "stock" ? lockName : "Stock", okay: lockName !== "stock" })
    return arr
  }

  // Compact chip strip for the protected state (mockup: status-strip).
  function chips() {
    var s = root.status, arr = []
    function add(label, key) { arr.push({ label: label, okay: root.yes(s[key]) }) }
    add("Howdy",        "howdy_pkg")
    add("IR emitter",   "leire_pkg")
    add("PAM",          "pam_howdy_sudo")
    add("Lock screen",  "lock_pam")
    add("Face enrolled","enrolled")
    return arr
  }

  function installCompleteMsg() {
    if (root.yes(root.status.enrolled)) return "All set up and a face is enrolled."
    return "Ready — enroll a face via Face data → Add."
  }
  function primaryLabel() {
    if (root.page === "install") return root.installComplete ? "Done" : "Working…"
    if (root.page === "confirm") return "Deploy PAM"
    if (root.installing) return "Working…"
    if (!root.installed()) return "Install"
    if (!root.yes(root.status.enrolled)) return "Enroll face"
    return "Re-enroll"
  }
  function primaryVisible() {
    if (root.page === "status") return root.installed() && !root.installing
    return root.page === "install" || root.page === "confirm"
  }
  function primaryIcon() {
    if (root.page === "confirm") return "\uf099d"          // shield-lock
    if (!root.installed()) return "\uf0db3"                // bolt
    return "\uf0014"                                       // account-plus
  }
  function primaryAction() {
    switch (root.page) {
      case "status":
        if (root.installing) return
        if (!root.installed()) { root.startInstall(); return }
        root.page = "facelist"; return
      case "install":
        if (root.installComplete) { root.page = "status"; root.installComplete = false; return }
        return
      case "confirm": root.startDeployPam(); return
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
        root.logText += data + "\n"
        root.nextQuote()
      }
    }
    onExited: {
      if (exitCode !== 0) root.logText += "Error: step failed.\n"
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
    onExited: { root.logText += lockProc.collected; root.scheduleShellRestart() }
  }
  Process {
    id: removeProc
    property string collected: ""
    command: ["pkexec", "/bin/bash", "--", "-c", "true"]
    stdout: SplitParser { onRead: function(data) { removeProc.collected += data + "\n" } }
    onExited: { root.logText += removeProc.collected; root.onSetupDone(exitCode === 0) }
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

    // Scrim
    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    // Card
    BorderSurface {
      id: card
      width: root.cardW
      height: root.cardH
      radius: root.r
      anchors.centerIn: parent
      color: root.surfaceColor
      borderSpec: Border.surfaceSpec("polkit", "border", root.surfaceBorder, Math.max(1, Style.space(1)))
      padding: root.cm
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onPressed: function(event) { if (event.key === Qt.Key_Escape) root.dismiss() }

        Column {
          anchors.fill: parent
          spacing: root.sp

          // ------------------------------------------------- header
          Item {
            id: hdr
            width: parent.width
            height: Style.space(48)

            // Icon circle
            Rectangle {
              id: iconCircle
              width: Style.space(36)
              height: Style.space(36)
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: Util.alpha(root.accent, 0.1)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(root.accent, 0.2)

              Text {
                anchors.centerIn: parent
                text: "\uf0237"          // fingerprint / face-id
                color: root.accent
                font.family: root.ff
                font.pixelSize: Style.font.icon
              }
            }

            // Title + subtitle
            Column {
              anchors.left: iconCircle.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "Face Howdy"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.body + 1
                font.bold: true
              }
              Text {
                text: root.statusLoaded ? root.subtitle() : "Reading state…"
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }

            // Status pill — right side, only on status page
            Rectangle {
              visible: root.page === "status" && root.statusLoaded
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: pillTxt.implicitWidth + Style.space(20)
              height: Style.space(22)
              radius: height / 2
              color: {
                if (root.fullyActive()) return Util.alpha(root.accent, 0.12)
                if (root.needsAttention()) return Util.alpha(root.warn, 0.12)
                return Util.alpha(root.muted, 0.08)
              }
              border.width: Math.max(1, Style.space(1))
              border.color: {
                if (root.fullyActive()) return Util.alpha(root.accent, 0.35)
                if (root.needsAttention()) return Util.alpha(root.warn, 0.35)
                return Util.alpha(root.muted, 0.2)
              }

              Row {
                anchors.centerIn: parent
                spacing: Style.space(5)
                Rectangle {
                  width: Style.space(6)
                  height: Style.space(6)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: {
                    if (root.fullyActive()) return root.accent
                    if (root.needsAttention()) return root.warn
                    return root.muted
                  }
                }
                Text {
                  id: pillTxt
                  text: root.fullyActive() ? "Active"
                      : (root.needsAttention() ? "Almost there" : "Not set up")
                  color: {
                    if (root.fullyActive()) return root.accent
                    if (root.needsAttention()) return root.warn
                    return root.muted
                  }
                  font.family: root.ff
                  font.pixelSize: Style.font.caption - 1
                  font.bold: true
                }
              }
            }
          }

          // ------------------------------------------------- body
          Item {
            id: body
            width: parent.width
            height: parent.height - hdr.height - footerRow.height - root.sp * 3 - Math.max(1, Style.space(1))

            // ---- STATUS page ----
            Column {
              visible: root.page === "status"
              anchors.fill: parent
              spacing: root.sp

              // --- Not installed: hero CTA view ---
              Column {
                visible: !root.statusLoaded || (!root.installed() && !root.installing)
                width: parent.width
                spacing: root.sp

                Item {
                  width: parent.width
                  height: Style.space(76)
                  Rectangle {
                    width: Style.space(64)
                    height: Style.space(64)
                    radius: width / 2
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    color: Util.alpha(root.accent, 0.07)
                    border.width: Math.max(1, Style.space(1))
                    border.color: Util.alpha(root.accent, 0.18)
                    Text {
                      anchors.centerIn: parent
                      text: "\uf0237"          // fingerprint
                      color: root.accent
                      font.family: root.ff
                      font.pixelSize: Style.space(30)
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: "Face unlock for your desktop"
                  color: root.surfaceText
                  font.family: root.ff
                  font.pixelSize: Style.font.title
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }
                Text {
                  width: parent.width
                  text: "Like Windows Hello — unlock sudo, SDDM and your lock screen with your face. Uses your ThinkPad's IR camera."
                  color: root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  lineHeight: 1.5
                }

                // Feature rows
                Column {
                  width: parent.width
                  spacing: Style.space(8)
                  topPadding: Style.space(4)

                  Repeater {
                    model: [
                      { i: "\uf06cc", t: "Wires into sudo, polkit and SDDM" },
                      { i: "\uf0594", t: "Works in the dark via IR emitter" },
                      { i: "\uf084",  t: "Password stays as fallback — always" },
                      { i: "\uf0450", t: "Idempotent — safe to re-run after updates" }
                    ]
                    delegate: Row {
                      width: parent.width
                      spacing: Style.space(10)
                      Text {
                        text: modelData.i
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        width: Style.space(18)
                        horizontalAlignment: Text.AlignHCenter
                      }
                      Text {
                        text: modelData.t
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                // Centered CTA (hidden while status is still loading)
                Item {
                  visible: root.statusLoaded
                  width: parent.width
                  height: Style.space(40)
                  Button {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Install Face Howdy"
                    iconText: "\uf0db3"          // bolt
                    selected: true
                    fontFamily: root.ff
                    onClicked: root.startInstall()
                  }
                }
              }

              // --- Needs attention: warning banner + mini cells ---
              Column {
                visible: root.statusLoaded && root.needsAttention() && !root.installing
                width: parent.width
                spacing: root.sp

                Rectangle {
                  width: parent.width
                  height: attnCol.implicitHeight + Style.space(24)
                  radius: root.r
                  color: Util.alpha(root.warn, 0.06)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.warn, 0.28)
                  clip: true

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                    anchors.right: parent.right; anchors.rightMargin: Style.space(14)
                    spacing: Style.space(12)

                    Text {
                      text: "\uf0026"            // alert
                      color: root.warn
                      font.family: root.ff
                      font.pixelSize: Style.font.iconLarge
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Column {
                      id: attnCol
                      width: parent.width - Style.space(12) - Style.font.iconLarge
                      spacing: Style.space(3)
                      Text {
                        text: "Almost there"
                        color: root.warn
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        width: parent.width
                        text: root.blockingStep()
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        lineHeight: 1.4
                      }
                    }
                  }
                }

                // Mini cell grid — only noteworthy cells with a bad one flagged
                Grid {
                  width: parent.width
                  columns: 2
                  spacing: Style.space(6)
                  Repeater {
                    model: root.cellModel
                    delegate: MiniCell {
                      width: (parent.width - Style.space(6)) / 2
                      label: modelData.label
                      good: modelData.okay
                      valueText: modelData.value
                    }
                  }
                }
              }

              // --- Fully active: protected face-ring hero + chips ---
              Column {
                visible: root.statusLoaded && root.fullyActive() && !root.installing
                width: parent.width
                spacing: root.sp

                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  topPadding: Style.space(2)

                  Item {
                    width: parent.width
                    height: Style.space(84)
                    Rectangle {
                      width: Style.space(72)
                      height: Style.space(72)
                      radius: width / 2
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.verticalCenter: parent.verticalCenter
                      color: Util.alpha(root.accent, 0.08)
                      border.width: Math.max(2, Style.space(2))
                      border.color: Util.alpha(root.accent, 0.5)
                      Text {
                        anchors.centerIn: parent
                        text: "\uf0237"          // fingerprint
                        color: root.accent
                        font.family: root.ff
                        font.pixelSize: Style.space(34)
                      }
                    }
                  }
                  Text {
                    width: parent.width
                    text: "Running"
                    color: root.surfaceText
                    font.family: root.ff
                    font.pixelSize: Style.font.title
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                  }
                  Text {
                    width: parent.width
                    text: "Face unlock is active across sudo, polkit and your lock screen"
                    color: root.muted
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    lineHeight: 1.5
                  }
                }

                // Chip strip
                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: root.chips()
                    delegate: Rectangle {
                      height: Style.space(24)
                      width: chipRow.implicitWidth + Style.space(14)
                      radius: height / 2
                      color: Util.alpha(root.accent, 0.07)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.accent, 0.25)
                      Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: Style.space(5)
                        Text {
                          text: "\uf012c"         // check
                          color: root.accent
                          font.family: root.ff
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          text: modelData.label
                          color: root.muted
                          font.family: root.ff
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }
                  }
                }

                // Details link
                Item {
                  width: parent.width
                  height: Style.space(26)
                  Button {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Status details"
                    iconText: "\uf0142"          // chevron-right
                    bordered: true
                    fontFamily: root.ff
                    onClicked: root.page = "details"
                  }
                }
              }
            }

            // ---- DETAILS page ----
            Column {
              visible: root.page === "details"
              anchors.fill: parent
              spacing: root.sp

              Text {
                text: "Status details"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                width: parent.width
                text: "Everything Face Howdy manages — blue means active, gray means not set."
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                lineHeight: 1.45
              }

              Grid {
                width: parent.width
                columns: 2
                spacing: Style.space(6)
                Repeater {
                  model: root.cellModel
                  delegate: MiniCell {
                    width: (parent.width - Style.space(6)) / 2
                    label: modelData.label
                    good: modelData.okay
                    valueText: modelData.value
                  }
                }
              }
            }

            // ---- INSTALL page ----
            Column {
              visible: root.page === "install"
              anchors.fill: parent
              spacing: root.sp

              // Phase header: label + %
              Row {
                width: parent.width
                Text {
                  id: labelPct
                  text: root.progressLabel === "done" ? "All done" : root.phaseLabel(root.progressLabel)
                  color: root.surfaceText
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Item { width: parent.width - labelPct.implicitWidth - pctTxt.implicitWidth; height: 1 }
                Text {
                  id: pctTxt
                  text: Math.round(root.installProgress() * 100) + "%"
                  color: root.accent
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }

              // Progress bar
              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: Style.space(2)
                color: Util.alpha(root.accent, 0.1)
                Rectangle {
                  width: parent.width * root.installProgress()
                  height: parent.height
                  radius: parent.radius
                  color: root.accent
                  Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
              }

              // Phase list
              Column {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: ["packages", "ir", "models", "pam"]
                  delegate: Item {
                    width: parent.width
                    height: Style.space(34)
                    property int idx: index
                    property int cur: root.phaseIndex()
                    property bool isDone: idx < cur || root.installComplete
                    property bool isActive: idx === cur && root.installing
                    property bool isPending: idx > cur && !root.installComplete

                    Rectangle {
                      anchors.fill: parent
                      radius: root.r
                      color: {
                        if (isDone) return Util.alpha(root.accent, 0.07)
                        if (isActive) return Util.alpha(root.accent, 0.12)
                        return Util.alpha(root.muted, 0.04)
                      }
                      border.width: Math.max(1, Style.space(1))
                      border.color: {
                        if (isDone) return Util.alpha(root.accent, 0.2)
                        if (isActive) return Util.alpha(root.accent, 0.35)
                        return Util.alpha(root.muted, 0.1)
                      }

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(12)
                        anchors.rightMargin: Style.space(12)
                        spacing: Style.space(10)

                        // State icon
                        Item {
                          width: Style.space(18)
                          height: parent.height
                          Text {
                            anchors.centerIn: parent
                            text: isDone ? "\uf05e0"            // check-circle
                               : isActive ? "\uf0772"           // loading
                               : "\uf0766"                      // circle-outline
                            color: isDone || isActive ? root.accent : root.muted
                            font.family: root.ff
                            font.pixelSize: Style.font.iconSmall
                            rotation: isActive ? 90 : 0
                            transformOrigin: Item.Center
                            RotationAnimation on rotation {
                              from: 0
                              to: 360
                              duration: 1000
                              loops: Animation.Infinite
                              running: isActive
                            }
                          }
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.phaseLabel(modelData)
                          color: {
                            if (isDone || isActive) return root.surfaceText
                            return root.muted
                          }
                          font.family: root.ff
                          font.pixelSize: Style.font.body
                          font.bold: isActive
                        }
                      }
                    }
                  }
                }
              }

              // Quote
              Rectangle {
                id: quoteBox
                width: parent.width
                height: quoteCol.implicitHeight + Style.space(16)
                radius: Style.space(6)
                color: Util.alpha(root.accent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                visible: root.installing
                Text {
                  id: quoteCol
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(12)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(12)
                  text: "\u201c" + root.currentQuote + "\u201d"
                  color: root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                  font.italic: true
                  wrapMode: Text.WordWrap
                  lineHeight: 1.4
                }
              }

              // Log
              Rectangle {
                width: parent.width
                height: Math.max(Style.space(110), body.height - quoteBox.height - Style.space(250))
                radius: root.r
                color: Util.alpha(Color.background, 0.6)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.muted, 0.12)
                clip: true

                Flickable {
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  contentHeight: logTxt.implicitHeight
                  flickableDirection: Flickable.VerticalFlick
                  boundsBehavior: Flickable.StopAtBounds
                  onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

                  Text {
                    id: logTxt
                    width: parent.width
                    text: root.logText || "—"
                    color: Util.alpha(root.muted, 0.9)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 1
                    wrapMode: Text.Wrap
                    lineHeight: 1.5
                  }
                }
              }

              // Complete message
              Text {
                visible: root.installComplete
                width: parent.width
                text: root.installCompleteMsg()
                color: root.accent
                font.family: root.ff
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ---- CONFIRM page ----
            Column {
              visible: root.page === "confirm"
              anchors.fill: parent
              spacing: root.sp

              Text {
                text: "Deploy PAM?"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Rectangle {
                width: parent.width
                height: confirmTxt.implicitHeight + Style.space(24)
                radius: root.r
                color: Util.alpha(root.accent, 0.05)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.15)
                clip: true

                Rectangle {
                  anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                  width: Style.space(3)
                  color: root.accent
                }

                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                  anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                  spacing: Style.space(12)
                  Text {
                    text: "\uf099d"             // shield-lock
                    color: root.accent
                    font.family: root.ff
                    font.pixelSize: Style.font.iconLarge
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    id: confirmTxt
                    width: parent.width - Style.font.iconLarge - Style.space(12)
                    text: "Adds a pam_howdy line to sudo, SDDM and polkit. Patches your lock screen to unlock by face on lid open. Password stays as fallback."
                    color: root.surfaceText
                    font.family: root.ff
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                    lineHeight: 1.45
                  }
                }
              }
            }

            // ---- REMOVE page ----
            Column {
              visible: root.page === "remove"
              anchors.fill: parent
              spacing: root.sp

              Column {
                width: parent.width
                spacing: Style.space(8)
                topPadding: Style.space(2)

                Item {
                  width: parent.width
                  height: Style.space(56)
                  Text {
                    anchors.centerIn: parent
                    text: "\uf099e"             // shield-off
                    color: root.urgent
                    font.family: root.ff
                    font.pixelSize: Style.space(36)
                  }
                }
                Text {
                  width: parent.width
                  text: "Remove Face Howdy?"
                  color: root.urgent
                  font.family: root.ff
                  font.pixelSize: Style.font.title
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                }
                Text {
                  width: parent.width
                  text: "PAM lines are always cleared and password auth restored. Choose what to do with the packages."
                  color: root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  lineHeight: 1.45
                }
              }

              // Two option cards
              Column {
                width: parent.width
                spacing: Style.space(8)

                // Keep packages
                Rectangle {
                  width: parent.width
                  height: keepCol.implicitHeight + Style.space(24)
                  radius: root.r
                  color: Util.alpha(root.muted, 0.04)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.muted, 0.15)

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startRemove(true)
                    hoverEnabled: true
                    onContainsMouseChanged: parent.color = containsMouse
                      ? Util.alpha(root.muted, 0.08) : Util.alpha(root.muted, 0.04)
                  }

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                    anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                    spacing: Style.space(12)
                    Text {
                      text: "\uf012c"            // check
                      color: root.muted
                      font.family: root.ff
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Column {
                      id: keepCol
                      width: parent.width - Style.font.body - Style.space(12)
                      spacing: Style.space(3)
                      Text {
                        text: "Keep packages"
                        color: root.surfaceText
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        width: parent.width
                        text: "Clears PAM and the lock patch. Re-enabling later is instant."
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }

                // Delete packages
                Rectangle {
                  width: parent.width
                  height: deleteCol.implicitHeight + Style.space(24)
                  radius: root.r
                  color: Util.alpha(root.urgent, 0.05)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.urgent, 0.2)

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startRemove(false)
                    hoverEnabled: true
                    onContainsMouseChanged: parent.color = containsMouse
                      ? Util.alpha(root.urgent, 0.1) : Util.alpha(root.urgent, 0.05)
                  }

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: Style.space(16)
                    anchors.right: parent.right; anchors.rightMargin: Style.space(16)
                    spacing: Style.space(12)
                    Text {
                      text: "\uf0a79"            // trash-can
                      color: root.urgent
                      font.family: root.ff
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Column {
                      id: deleteCol
                      width: parent.width - Style.font.body - Style.space(12)
                      spacing: Style.space(3)
                      Text {
                        text: "Remove everything"
                        color: root.urgent
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        width: parent.width
                        text: "Uninstalls howdy and IR emitter packages and deletes enrolled face data."
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }
                  }
                }
              }
            }

            // ---- FACELIST page ----
            Column {
              visible: root.page === "facelist"
              anchors.fill: parent
              spacing: root.sp

              Text {
                text: "Face data"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                text: "Add opens Howdy's terminal UI to enroll. Test runs a recognition check. Clear removes all enrolled faces."
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                lineHeight: 1.45
              }

              Column {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: "Add face"
                  iconText: "\uf0014"          // account-plus
                  selected: true
                  width: parent.width
                  fontFamily: root.ff
                  onClicked: root.enrollFace()
                }
                Button {
                  text: "Test recognition"
                  iconText: "\uf0208"          // eye
                  bordered: true
                  width: parent.width
                  fontFamily: root.ff
                  onClicked: root.testFace()
                }
                Button {
                  text: "Clear faces"
                  iconText: "\uf0015"          // account-remove
                  bordered: true
                  foreground: root.urgent
                  width: parent.width
                  fontFamily: root.ff
                  onClicked: root.removeFace()
                }
              }
            }
          }

          // ------------------------------------------------- footer
          Row {
            id: footerRow
            width: parent.width
            height: root.btnH
            spacing: root.sp

            // Left: Back or Remove
            Button {
              id: backBtn
              text: "Back"
              iconText: "\uf004d"              // arrow-left
              bordered: true
              fontFamily: root.ff
              visible: root.page === "facelist" || root.page === "remove" || root.page === "confirm" || root.page === "details"
              onClicked: root.page = "status"
            }
            Button {
              id: removeBtn
              text: "Remove"
              iconText: "\uf0a79"              // trash-can
              bordered: true
              foreground: root.urgent
              fontFamily: root.ff
              visible: root.page === "status" && (root.installed() || root.pamDeployed()) && !root.installing
              onClicked: root.page = "remove"
            }

            // Spacer — pushes right-side buttons to the right
            Item {
              height: 1
              width: footerRow.width
                - (backBtn.visible ? backBtn.width + root.sp : 0)
                - (removeBtn.visible ? removeBtn.width + root.sp : 0)
                - (deployBtn.visible ? deployBtn.width + root.sp : 0)
                - (faceDataBtn.visible ? faceDataBtn.width + root.sp : 0)
                - (primaryBtn.visible ? primaryBtn.width + root.sp : 0)
            }

            // Right cluster
            Button {
              id: deployBtn
              text: "Deploy PAM"
              iconText: "\uf099d"              // shield-lock
              bordered: true
              fontFamily: root.ff
              visible: root.page === "status" && root.installed() && !root.pamDeployed() && !root.installing
              onClicked: root.page = "confirm"
            }
            Button {
              id: faceDataBtn
              text: "Face data"
              iconText: "\uf0004"              // account
              bordered: true
              fontFamily: root.ff
              visible: root.page === "status" && root.installed() && !root.installing
              onClicked: root.page = "facelist"
            }
            Button {
              id: primaryBtn
              text: root.primaryLabel()
              iconText: root.primaryIcon()
              selected: true
              fontFamily: root.ff
              visible: root.primaryVisible()
              onClicked: root.primaryAction()
            }
          }
        }
      }
    }
  }

  // ================================================================ components

  // MiniCell — compact status cell with a check LED and label/value.
  component MiniCell : Rectangle {
    id: mc
    property string label: ""
    property string valueText: ""
    property bool good: false

    height: Math.max(Style.space(38), Style.font.body + Style.space(18))
    radius: root.r

    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }

    color: mc.good ? Util.alpha(root.accent, 0.06) : Util.alpha(root.muted, 0.04)
    border {
      width: Math.max(1, Style.space(1))
      color: mc.good ? Util.alpha(root.accent, 0.2) : Util.alpha(root.muted, 0.12)
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      // LED circle with check
      Rectangle {
        width: Style.space(20)
        height: Style.space(20)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: mc.good ? Util.alpha(root.accent, 0.15) : Util.alpha(root.muted, 0.08)
        border.width: Math.max(1, Style.space(1))
        border.color: mc.good ? Util.alpha(root.accent, 0.35) : Util.alpha(root.muted, 0.2)
        Text {
          anchors.centerIn: parent
          text: "\uf012c"                    // check
          color: mc.good ? root.accent : root.muted
          font.family: root.ff
          font.pixelSize: Style.font.caption - 2
          font.bold: true
        }
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        Text {
          text: mc.label
          color: root.muted
          font.family: root.ff
          font.pixelSize: Style.font.caption - 2
        }
        Text {
          text: mc.valueText
          color: mc.good ? root.surfaceText : root.muted
          font.family: root.ff
          font.pixelSize: Style.font.caption
          font.bold: mc.good
        }
      }
    }
  }
}