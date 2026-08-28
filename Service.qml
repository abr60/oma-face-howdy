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

  // ------------------------------------------------------------------ icons
  // Nerd Font PUA glyphs (UI font = JetBrainsMono Nerd Font, verified with
  // fontTools against /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf).
  // WARNING: QML/JS "\uXXXX" escapes are EXACTLY 4 hex digits, so 5-digit PUA
  // codepoints (all these are in U+F0000+) MUST come from String.fromCodePoint()
  // at runtime — a literal "\uf0014" parses as U+F001 + "4" (renders a wrong
  // FontAwesome glyph + stray digit). Never write these as string literals.
  readonly property string gFingerprint: String.fromCodePoint(0xF0237) // md-fingerprint
  readonly property string gNight:      String.fromCodePoint(0xF0594) // md-weather_night (IR/works in dark)
  readonly property string gKey:        String.fromCodePoint(0xF030B) // md-key_variant (password fallback)
  readonly property string gRefresh:    String.fromCodePoint(0xF0450) // md-refresh (idempotent)
  readonly property string gTune:       String.fromCodePoint(0xF062E) // md-tune (PAM wiring)
  readonly property string gSync:       String.fromCodePoint(0xF04E6) // md-sync (re-enroll)
  readonly property string gDelete:     String.fromCodePoint(0xF06CC) // md-delete_empty (remove hero)
  readonly property string gTrash:      String.fromCodePoint(0xF0A79) // md-trash_can (remove actions)
  readonly property string gBolt:       String.fromCodePoint(0xF0DB3) // md-bolt (install CTA)
  readonly property string gAlert:      String.fromCodePoint(0xF0026) // md-alert (attention banner)
  readonly property string gCheck:      String.fromCodePoint(0xF012C) // md-check (good MiniCell)
  readonly property string gCheckCircle:String.fromCodePoint(0xF05E0) // md-check_circle (done phase)
  readonly property string gLoading:    String.fromCodePoint(0xF0772) // md-loading (active phase)
  readonly property string gPending:    String.fromCodePoint(0xF0B8D) // md-dots_horizontal_circle_outline
  readonly property string gChevron:    String.fromCodePoint(0xF0142) // md-chevron_right (details)
  readonly property string gAccount:    String.fromCodePoint(0xF0004) // md-account (face data)
  readonly property string gAccountPlus:String.fromCodePoint(0xF0014) // md-account_plus
  readonly property string gAccountRm:  String.fromCodePoint(0xF0015) // md-account_remove
  readonly property string gEye:        String.fromCodePoint(0xF0208) // md-eye (test recognition)
  readonly property string gBack:       String.fromCodePoint(0xF004D) // md-arrow_left

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
    if (root.page === "confirm") return root.gTune         // md-tune (configuring PAM, not a security action)
    if (!root.installed()) return root.gBolt               // bolt
    return root.gSync                                      // md-sync (re-enroll = re-sync face data)
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

    // Atmospheric backdrop.
    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    // Subtle accent bloom behind the card. Deliberately lightweight:
    // no ShaderEffect or blur dependency.
    Rectangle {
      anchors.centerIn: parent
      width: root.cardW + Style.space(110)
      height: root.cardH + Style.space(110)
      radius: Style.space(42)
      color: Util.alpha(root.accent, 0.018)
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardW
      height: root.cardH
      radius: Style.space(20)
      anchors.centerIn: parent
      color: root.surfaceColor
      borderSpec: Border.surfaceSpec("polkit", "border", root.surfaceBorder, Math.max(1, Style.space(1)))
      padding: root.cm

      // Fine outer edge gives the panel a more premium, layered surface.
      Rectangle {
        anchors.fill: parent
        anchors.margins: Style.space(1)
        radius: Style.space(19)
        color: "transparent"
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(root.accent, 0.045)
        z: -1
      }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) root.dismiss()
        }

        Column {
          anchors.fill: parent
          spacing: Style.space(16)

          // ============================================================
          // HEADER
          // ============================================================
          Item {
            id: hdr
            width: parent.width
            height: Style.space(50)

            Rectangle {
              id: iconTile
              width: Style.space(42)
              height: Style.space(42)
              radius: Style.space(13)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              color: Util.alpha(root.accent, 0.085)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(root.accent, 0.20)

              FaceHowdyIcon {
                anchors.centerIn: parent
                iconSize: Style.space(24)
                color: root.accent
              }
            }

            Column {
              anchors.left: iconTile.right
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Face Howdy"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.body + 2
                font.weight: Font.DemiBold
              }

              Text {
                text: root.statusLoaded ? root.subtitle() : "Reading security state…"
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              visible: root.page === "status" && root.statusLoaded
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: statusText.implicitWidth + Style.space(22)
              height: Style.space(27)
              radius: height / 2
              color: root.fullyActive()
                     ? Util.alpha(root.accent, 0.095)
                     : root.needsAttention()
                       ? Util.alpha(root.warn, 0.095)
                       : Util.alpha(root.muted, 0.055)
              border.width: Math.max(1, Style.space(1))
              border.color: root.fullyActive()
                            ? Util.alpha(root.accent, 0.25)
                            : root.needsAttention()
                              ? Util.alpha(root.warn, 0.25)
                              : Util.alpha(root.muted, 0.12)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(7)

                Rectangle {
                  width: Style.space(6)
                  height: Style.space(6)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.fullyActive()
                         ? root.accent
                         : root.needsAttention()
                           ? root.warn
                           : root.muted
                }

                Text {
                  id: statusText
                  text: root.fullyActive()
                        ? "Protected"
                        : root.needsAttention()
                          ? "Attention"
                          : "Not set up"
                  color: root.fullyActive()
                         ? root.accent
                         : root.needsAttention()
                           ? root.warn
                           : root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption - 1
                  font.weight: Font.DemiBold
                }
              }
            }
          }

          // ============================================================
          // BODY
          // ============================================================
          Item {
            id: body
            width: parent.width
            height: parent.height - hdr.height - footerRow.height - Style.space(16) * 3

            // ----------------------------------------------------------
            // STATUS
            // ----------------------------------------------------------
            Column {
              visible: root.page === "status"
              anchors.fill: parent
              spacing: Style.space(14)

              // Empty / not installed hero.
              Column {
                visible: !root.statusLoaded || (!root.installed() && !root.installing)
                width: parent.width
                spacing: Style.space(11)

                Item {
                  width: parent.width
                  height: Style.space(122)

                  Rectangle {
                    width: Style.space(104)
                    height: Style.space(104)
                    radius: width / 2
                    anchors.centerIn: parent
                    color: Util.alpha(root.accent, 0.025)
                    border.width: Math.max(1, Style.space(1))
                    border.color: Util.alpha(root.accent, 0.12)

                    Rectangle {
                      width: Style.space(82)
                      height: Style.space(82)
                      radius: width / 2
                      anchors.centerIn: parent
                      color: Util.alpha(root.accent, 0.055)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.accent, 0.20)

                      FaceHowdyIcon {
                        anchors.centerIn: parent
                        iconSize: Style.space(38)
                        color: root.accent
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: "Face unlock for your desktop"
                  color: root.surfaceText
                  font.family: root.ff
                  font.pixelSize: Style.font.title + 2
                  font.weight: Font.DemiBold
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  width: parent.width
                  text: "Use your IR camera to unlock your desktop authentication flow. Your password remains available as fallback."
                  color: root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption + 1
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  lineHeight: 1.45
                }

                // Four quiet capability chips.
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(7)
                  rowSpacing: Style.space(7)

                  Repeater {
                    model: [
                      { i: root.gFingerprint, t: "sudo + polkit" },
                      { i: root.gNight, t: "IR in darkness" },
                      { i: root.gKey, t: "Password fallback" },
                      { i: root.gRefresh, t: "Safe to re-run" }
                    ]

                    delegate: Rectangle {
                      width: (parent.width - Style.space(7)) / 2
                      height: Style.space(38)
                      radius: Style.space(10)
                      color: Util.alpha(root.muted, 0.028)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.muted, 0.08)

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(10)
                        spacing: Style.space(8)

                        OpticalGlyph {
                          text: modelData.i
                          color: root.accent
                          fontFamily: root.ff
                          fontSize: Style.font.caption
                          width: Style.space(17)
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          text: modelData.t
                          color: root.muted
                          font.family: root.ff
                          font.pixelSize: Style.font.caption - 1
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.space(3)
                }

                Button {
                  visible: root.statusLoaded
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Install Face Howdy"
                  iconText: root.gBolt
                  selected: true
                  fontFamily: root.ff
                  onClicked: root.startInstall()
                }
              }

              // Attention state.
              Column {
                visible: root.statusLoaded && root.needsAttention() && !root.installing
                width: parent.width
                spacing: Style.space(11)

                Rectangle {
                  width: parent.width
                  height: attentionColumn.implicitHeight + Style.space(22)
                  radius: Style.space(13)
                  color: Util.alpha(root.warn, 0.045)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.warn, 0.20)

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(11)

                    Rectangle {
                      width: Style.space(34)
                      height: Style.space(34)
                      radius: Style.space(11)
                      color: Util.alpha(root.warn, 0.09)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.warn, 0.18)
                      anchors.verticalCenter: parent.verticalCenter

                      OpticalGlyph {
                        anchors.centerIn: parent
                        text: root.gAlert
                        color: root.warn
                        fontFamily: root.ff
                        fontSize: Style.font.body
                      }
                    }

                    Column {
                      id: attentionColumn
                      width: parent.width - Style.space(45)
                      spacing: Style.space(3)

                      Text {
                        text: "Almost there"
                        color: root.warn
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        font.weight: Font.DemiBold
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

                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(7)
                  rowSpacing: Style.space(7)

                  Repeater {
                    model: root.cellModel
                    delegate: MiniCell {
                      width: (parent.width - Style.space(7)) / 2
                      label: modelData.label
                      good: modelData.okay
                      valueText: modelData.value
                    }
                  }
                }
              }

              // Fully protected state.
              Column {
                visible: root.statusLoaded && root.fullyActive() && !root.installing
                width: parent.width
                spacing: Style.space(11)

                Item {
                  width: parent.width
                  height: Style.space(142)

                  Rectangle {
                    width: Style.space(116)
                    height: Style.space(116)
                    radius: width / 2
                    anchors.centerIn: parent
                    color: Util.alpha(root.accent, 0.018)
                    border.width: Style.space(2)
                    border.color: Util.alpha(root.accent, 0.20)

                    Rectangle {
                      width: Style.space(94)
                      height: Style.space(94)
                      radius: width / 2
                      anchors.centerIn: parent
                      color: Util.alpha(root.accent, 0.055)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.accent, 0.34)

                      FaceHowdyIcon {
                        anchors.centerIn: parent
                        iconSize: Style.space(42)
                        color: root.accent
                      }
                    }

                    Rectangle {
                      width: Style.space(12)
                      height: Style.space(12)
                      radius: width / 2
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      anchors.rightMargin: Style.space(11)
                      anchors.bottomMargin: Style.space(12)
                      color: root.accent
                      border.width: Style.space(3)
                      border.color: root.surfaceColor
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: "You're protected."
                  color: root.surfaceText
                  font.family: root.ff
                  font.pixelSize: Style.font.title + 3
                  font.weight: Font.DemiBold
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  width: parent.width
                  text: "Face recognition is active across your desktop authentication stack."
                  color: root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption + 1
                  wrapMode: Text.WordWrap
                  horizontalAlignment: Text.AlignHCenter
                  lineHeight: 1.45
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)

                  Repeater {
                    model: root.chips()
                    delegate: Rectangle {
                      height: Style.space(27)
                      width: chipRow.implicitWidth + Style.space(16)
                      radius: height / 2
                      color: Util.alpha(root.accent, 0.045)
                      border.width: Math.max(1, Style.space(1))
                      border.color: Util.alpha(root.accent, 0.15)

                      Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: Style.space(5)

                        OpticalGlyph {
                          text: root.gCheck
                          color: root.accent
                          fontFamily: root.ff
                          fontSize: Style.font.caption - 1
                        }

                        Text {
                          text: modelData.label
                          color: root.muted
                          font.family: root.ff
                          font.pixelSize: Style.font.caption - 1
                          font.weight: Font.DemiBold
                        }
                      }
                    }
                  }
                }

                Item { width: parent.width; height: Style.space(2) }

                Button {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "View security status"
                  iconText: root.gChevron
                  bordered: true
                  fontFamily: root.ff
                  onClicked: root.page = "details"
                }
              }
            }

            // ----------------------------------------------------------
            // DETAILS
            // ----------------------------------------------------------
            Column {
              visible: root.page === "details"
              anchors.fill: parent
              spacing: Style.space(12)

              Text {
                text: "Security status"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title + 2
                font.weight: Font.DemiBold
              }

              Text {
                width: parent.width
                text: "A complete view of the components managed by Face Howdy."
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption + 1
                wrapMode: Text.WordWrap
                lineHeight: 1.45
              }

              Rectangle {
                width: parent.width
                height: Style.space(1)
                color: Util.alpha(root.muted, 0.08)
              }

              Grid {
                width: parent.width
                columns: 2
                columnSpacing: Style.space(7)
                rowSpacing: Style.space(7)

                Repeater {
                  model: root.cellModel
                  delegate: MiniCell {
                    width: (parent.width - Style.space(7)) / 2
                    label: modelData.label
                    good: modelData.okay
                    valueText: modelData.value
                  }
                }
              }
            }

            // ----------------------------------------------------------
            // INSTALLATION
            // ----------------------------------------------------------
            Column {
              visible: root.page === "install"
              anchors.fill: parent
              spacing: Style.space(11)

              Row {
                width: parent.width

                Text {
                  id: installTitle
                  text: root.installComplete ? "Setup complete" : "Setting things up…"
                  color: root.surfaceText
                  font.family: root.ff
                  font.pixelSize: Style.font.title + 1
                  font.weight: Font.DemiBold
                }

                Item {
                  width: parent.width - installTitle.implicitWidth - installPercent.implicitWidth
                  height: 1
                }

                Text {
                  id: installPercent
                  text: Math.round(root.installProgress() * 100) + "%"
                  color: root.accent
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  font.weight: Font.DemiBold
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: Util.alpha(root.accent, 0.075)

                Rectangle {
                  width: parent.width * root.installProgress()
                  height: parent.height
                  radius: parent.radius
                  color: root.accent
                  Behavior on width {
                    NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                  }
                }
              }

              Text {
                width: parent.width
                text: root.phaseLabel(root.progressLabel)
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }

              Column {
                width: parent.width
                spacing: Style.space(5)

                Repeater {
                  model: ["packages", "ir", "models", "pam"]

                  delegate: Item {
                    width: parent.width
                    height: Style.space(40)

                    property int idx: index
                    property int cur: root.phaseIndex()
                    property bool isDone: idx < cur || root.installComplete
                    property bool isActive: idx === cur && root.installing

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.space(11)
                      color: isActive
                             ? Util.alpha(root.accent, 0.075)
                             : isDone
                               ? Util.alpha(root.accent, 0.032)
                               : Util.alpha(root.muted, 0.022)
                      border.width: Math.max(1, Style.space(1))
                      border.color: isActive
                                    ? Util.alpha(root.accent, 0.22)
                                    : isDone
                                      ? Util.alpha(root.accent, 0.10)
                                      : Util.alpha(root.muted, 0.07)
                    }

                    Rectangle {
                      width: Style.space(25)
                      height: Style.space(25)
                      radius: width / 2
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(9)
                      anchors.verticalCenter: parent.verticalCenter
                      color: isDone || isActive
                             ? Util.alpha(root.accent, 0.10)
                             : Util.alpha(root.muted, 0.045)
                      border.width: Math.max(1, Style.space(1))
                      border.color: isDone || isActive
                                    ? Util.alpha(root.accent, 0.25)
                                    : Util.alpha(root.muted, 0.10)

                      OpticalGlyph {
                        anchors.centerIn: parent
                        text: isDone ? root.gCheckCircle : isActive ? root.gLoading : root.gPending
                        color: isDone || isActive ? root.accent : root.muted
                        fontFamily: root.ff
                        fontSize: Style.font.caption

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
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(45)
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.phaseLabel(modelData)
                      color: isDone || isActive ? root.surfaceText : root.muted
                      font.family: root.ff
                      font.pixelSize: Style.font.body
                      font.weight: isActive ? Font.DemiBold : Font.Normal
                    }
                  }
                }
              }

              Rectangle {
                id: quoteBox
                width: parent.width
                height: quoteText.implicitHeight + Style.space(18)
                radius: Style.space(11)
                color: Util.alpha(root.accent, 0.032)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.10)
                visible: root.installing

                Text {
                  id: quoteText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  text: "“" + root.currentQuote + "”"
                  color: root.muted
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                  font.italic: true
                  wrapMode: Text.WordWrap
                  lineHeight: 1.35
                }
              }

              Rectangle {
                width: parent.width
                height: Math.max(Style.space(96), body.height - quoteBox.height - Style.space(208))
                radius: Style.space(11)
                color: Util.alpha(Color.background, 0.45)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.muted, 0.09)
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
                    text: root.logText || "Waiting for output…"
                    color: Util.alpha(root.muted, 0.88)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 1
                    wrapMode: Text.Wrap
                    lineHeight: 1.45
                  }
                }
              }

              Text {
                visible: root.installComplete
                width: parent.width
                text: root.installCompleteMsg()
                color: root.accent
                font.family: root.ff
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }
            }

            // ----------------------------------------------------------
            // CONFIRM PAM
            // ----------------------------------------------------------
            Column {
              visible: root.page === "confirm"
              anchors.fill: parent
              spacing: Style.space(14)

              Item {
                width: parent.width
                height: Style.space(76)

                Rectangle {
                  width: Style.space(60)
                  height: Style.space(60)
                  radius: Style.space(18)
                  anchors.centerIn: parent
                  color: Util.alpha(root.accent, 0.065)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.accent, 0.17)

                  OpticalGlyph {
                    anchors.centerIn: parent
                    text: root.gTune
                    color: root.accent
                    fontFamily: root.ff
                    fontSize: Style.space(28)
                  }
                }
              }

              Text {
                width: parent.width
                text: "Enable system authentication"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title + 2
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                width: parent.width
                text: "Connect face recognition to sudo, SDDM, polkit and the lock screen."
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption + 1
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                lineHeight: 1.45
              }

              Rectangle {
                width: parent.width
                height: confirmText.implicitHeight + Style.space(28)
                radius: Style.space(13)
                color: Util.alpha(root.accent, 0.038)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.12)

                Rectangle {
                  width: Style.space(3)
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  color: root.accent
                }

                Text {
                  id: confirmText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(18)
                  anchors.rightMargin: Style.space(16)
                  text: "Adds pam_howdy to sudo, SDDM and polkit, and patches your lock screen for face unlock. Password authentication stays available as fallback."
                  color: root.surfaceText
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  lineHeight: 1.45
                }
              }
            }

            // ----------------------------------------------------------
            // FACE DATA
            // ----------------------------------------------------------
            Column {
              visible: root.page === "facelist"
              anchors.fill: parent
              spacing: Style.space(12)

              Text {
                text: "Face data"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title + 2
                font.weight: Font.DemiBold
              }

              Text {
                width: parent.width
                text: "Manage the face profiles used by Howdy. Enrollment opens Howdy's terminal interface."
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption + 1
                wrapMode: Text.WordWrap
                lineHeight: 1.45
              }

              Rectangle {
                width: parent.width
                height: Style.space(76)
                radius: Style.space(13)
                color: Util.alpha(root.accent, 0.038)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.accent, 0.12)

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(11)

                  Rectangle {
                    width: Style.space(44)
                    height: Style.space(44)
                    radius: Style.space(13)
                    anchors.verticalCenter: parent.verticalCenter
                    color: Util.alpha(root.accent, 0.075)

                    FaceHowdyIcon {
                      anchors.centerIn: parent
                      iconSize: Style.space(24)
                      color: root.accent
                    }
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      text: root.yes(root.status.enrolled) ? "Face profile enrolled" : "No face profile"
                      color: root.surfaceText
                      font.family: root.ff
                      font.pixelSize: Style.font.body
                      font.weight: Font.DemiBold
                    }

                    Text {
                      text: root.yes(root.status.enrolled) ? "Ready for recognition" : "Add a face to continue"
                      color: root.muted
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Item { width: parent.width; height: Style.space(1) }

              Button {
                width: parent.width
                text: "Add face"
                iconText: root.gAccountPlus
                selected: true
                fontFamily: root.ff
                onClicked: root.enrollFace()
              }

              Button {
                width: parent.width
                text: "Test recognition"
                iconText: root.gEye
                bordered: true
                fontFamily: root.ff
                onClicked: root.testFace()
              }

              Button {
                width: parent.width
                text: "Clear enrolled faces"
                iconText: root.gAccountRm
                bordered: true
                foreground: root.urgent
                fontFamily: root.ff
                onClicked: root.removeFace()
              }
            }

            // ----------------------------------------------------------
            // REMOVE
            // ----------------------------------------------------------
            Column {
              visible: root.page === "remove"
              anchors.fill: parent
              spacing: Style.space(11)

              Item {
                width: parent.width
                height: Style.space(76)

                Rectangle {
                  width: Style.space(58)
                  height: Style.space(58)
                  radius: Style.space(17)
                  anchors.centerIn: parent
                  color: Util.alpha(root.urgent, 0.055)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.urgent, 0.17)

                  OpticalGlyph {
                    anchors.centerIn: parent
                    text: root.gDelete
                    color: root.urgent
                    fontFamily: root.ff
                    fontSize: Style.space(27)
                  }
                }
              }

              Text {
                width: parent.width
                text: "Remove Face Howdy?"
                color: root.surfaceText
                font.family: root.ff
                font.pixelSize: Style.font.title + 2
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                width: parent.width
                text: "PAM lines are cleared and password authentication restored. Choose what to do with the packages."
                color: root.muted
                font.family: root.ff
                font.pixelSize: Style.font.caption + 1
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                lineHeight: 1.45
              }

              Item { width: parent.width; height: Style.space(2) }

              Column {
                width: parent.width
                spacing: Style.space(8)

                // Keep packages.
                Rectangle {
                  width: parent.width
                  height: Style.space(76)
                  radius: Style.space(13)
                  color: keepMouse.containsMouse ? Util.alpha(root.muted, 0.065) : Util.alpha(root.muted, 0.028)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.muted, 0.12)

                  Behavior on color { ColorAnimation { duration: 100 } }

                  MouseArea {
                    id: keepMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startRemove(true)
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(11)

                    Rectangle {
                      width: Style.space(40)
                      height: Style.space(40)
                      radius: Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      color: Util.alpha(root.muted, 0.055)

                      OpticalGlyph {
                        anchors.centerIn: parent
                        text: root.gCheck
                        color: root.muted
                        fontFamily: root.ff
                        fontSize: Style.font.body
                      }
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        text: "Keep packages"
                        color: root.surfaceText
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        font.weight: Font.DemiBold
                      }

                      Text {
                        text: "Clear the configuration only."
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                // Delete everything.
                Rectangle {
                  width: parent.width
                  height: Style.space(76)
                  radius: Style.space(13)
                  color: deleteMouse.containsMouse ? Util.alpha(root.urgent, 0.085) : Util.alpha(root.urgent, 0.040)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.urgent, 0.16)

                  Behavior on color { ColorAnimation { duration: 100 } }

                  MouseArea {
                    id: deleteMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startRemove(false)
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(11)

                    Rectangle {
                      width: Style.space(40)
                      height: Style.space(40)
                      radius: Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      color: Util.alpha(root.urgent, 0.065)

                      OpticalGlyph {
                        anchors.centerIn: parent
                        text: root.gTrash
                        color: root.urgent
                        fontFamily: root.ff
                        fontSize: Style.font.body
                      }
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        text: "Remove everything"
                        color: root.urgent
                        font.family: root.ff
                        font.pixelSize: Style.font.body
                        font.weight: Font.DemiBold
                      }

                      Text {
                        text: "Uninstall packages and delete enrolled face data."
                        color: root.muted
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }
          }

          // ============================================================
          // FOOTER
          // ============================================================
          Row {
            id: footerRow
            width: parent.width
            height: root.btnH
            spacing: Style.space(7)

            Button {
              id: backBtn
              text: "Back"
              iconText: root.gBack
              bordered: true
              fontFamily: root.ff
              visible: root.page === "facelist" || root.page === "remove" || root.page === "confirm" || root.page === "details"
              onClicked: root.page = "status"
            }

            Button {
              id: removeBtn
              text: "Remove"
              iconText: root.gTrash
              bordered: true
              foreground: root.urgent
              fontFamily: root.ff
              visible: root.page === "status" && (root.installed() || root.pamDeployed()) && !root.installing
              onClicked: root.page = "remove"
            }

            Item {
              height: 1
              width: footerRow.width
                - (backBtn.visible ? backBtn.width + footerRow.spacing : 0)
                - (removeBtn.visible ? removeBtn.width + footerRow.spacing : 0)
                - (deployBtn.visible ? deployBtn.width + footerRow.spacing : 0)
                - (faceDataBtn.visible ? faceDataBtn.width + footerRow.spacing : 0)
                - (primaryBtn.visible ? primaryBtn.width + footerRow.spacing : 0)
            }

            Button {
              id: deployBtn
              text: "Deploy PAM"
              iconText: root.gTune
              bordered: true
              fontFamily: root.ff
              visible: root.page === "status" && root.installed() && !root.pamDeployed() && !root.installing
              onClicked: root.page = "confirm"
            }

            Button {
              id: faceDataBtn
              text: "Face data"
              iconText: root.gAccount
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

  component MiniCell : Rectangle {
    id: mc
    property string label: ""
    property string valueText: ""
    property bool good: false

    height: Math.max(Style.space(46), Style.font.body + Style.space(18))
    radius: Style.space(11)
    color: mc.good ? Util.alpha(root.accent, 0.045) : Util.alpha(root.muted, 0.026)
    border.width: Math.max(1, Style.space(1))
    border.color: mc.good ? Util.alpha(root.accent, 0.15) : Util.alpha(root.muted, 0.09)

    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(9)
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(21)
        height: Style.space(21)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: mc.good ? Util.alpha(root.accent, 0.12) : Util.alpha(root.muted, 0.055)
        border.width: Math.max(1, Style.space(1))
        border.color: mc.good ? Util.alpha(root.accent, 0.27) : Util.alpha(root.muted, 0.11)

        OpticalGlyph {
          anchors.centerIn: parent
          visible: mc.good
          text: root.gCheck
          color: root.accent
          fontFamily: root.ff
          fontSize: Style.font.caption - 2
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
          font.weight: mc.good ? Font.DemiBold : Font.Normal
        }
      }
    }
  }
}
