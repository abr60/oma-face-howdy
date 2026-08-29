# Face Howdy

[![GitHub](https://img.shields.io/badge/GitHub-abr60%2Foma--face--howdy-181717?logo=github&logoColor=white)](https://github.com/abr60/oma-face-howdy)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Unlock your Omarchy desktop with your face — **Howdy**, installed and managed
entirely through a native Omarchy wizard.

A self-contained [Omarchy](https://omarchy.org/) plugin that brings real
IR-camera face recognition to:

- **sudo** and **polkit** prompts
- the **SDDM** login screen
- the **Hyprland lock screen** (unlock by face when you lift the laptop lid,
  like Windows Hello, or just hit Enter)

Everything the plugin needs is bundled in this plugin: the Quickshell wizard
(Service.qml), the privileged setup/teardown scripts under `bin/`, the
lock-screen patch under `system/`, and the tests under `test/`. There is **no
dependency on Omarchy source** — any Omarchy user with an IR (infrared) camera
can install it.

License: [MIT](LICENSE).

> **What's Howdy?** [Howdy](https://github.com/boltgolt/howdy) is the Linux
> analog of Windows Hello — a PAM module that unlocks the system by comparing a
> live infrared frame of your face against enrolled models.
> `linux-enable-ir-emitter` powers the IR illuminator that makes face unlock
> work in the dark.

## Features

- **Single Omarchy wizard window** (themed like the Omarchy menu) that walks
  through the whole setup: install packages → detect the IR camera and
  configure the IR emitter → download the face models → wire up PAM.
- **Graphical, impressive progress view** — a live progress bar, a scrolling
  log, and a rotating stream of fun quotes while the heavy lifting happens.
- **No manual terminal steps.** Everything privileged runs through `pkexec`
  (background authorization pops up), so no sudo juggling is needed.
- **Works on the lock screen** without configuring anything by hand: it clones
  the stock lock plugin into your user config, patches it with a small,
  marker-guarded Howdy bridge, and switches the shell to use it. It stays in
  sync with Omarchy's latest lock plugin because it re-clones fresh and
  re-applies the patch idempotently.
- **Idempotent and upgrade-proof.** Re-enabling the plugin (or running it again
  after an `omarchy update`) re-applies any PAM lines or lock-patch changes that
  a system update may have cleared.
- **Choose your removal behavior.** Removing always clears the Howdy PAM lines
  and restores the stock lock screen so your password auth works again; you
  then **choose** whether to also delete the packages/face models (which take a
  while to reinstall) or keep them for an instant re-enable.
- **Face data manager** — add, test, and clear your enrolled faces from the
  same window.
- **Menu entry** under **setup › Security › Face Howdy**, installed by the
  plugin itself into your user's menu extension so it survives Omarchy
  upgrades.

## Requirements

- An Omarchy desktop with a camera whose infrared (IR/GREY) stream is exposed
  as a video4linux device — typically an IR-capable webcam (many ThinkPads,
  Lenovo `04f2:*`, etc.).
- An AUR helper (`yay`, `paru`, or Omarchy's `omarchy-pkg-aur-add`) to build
  `howdy-next-git` and `linux-enable-ir-emitter-git` on first install.
- `v4l-utils` (auto-installed).

On first install the IR emitter must be calibrated once in a terminal:

```sh
sudo linux-enable-ir-emitter configure
```

The wizard's IR step writes the udev rule and systemd services; if the emitter
is uncalibrated the status screen shows "IR calibrated: Not set" with this
instruction, and `sudo linux-enable-ir-emitter run` is still triggered on
every Howdy auth as a fallback.

## Installation

```sh
omarchy plugin add https://github.com/abr60/oma-face-howdy.git --enable
```

Enabling the plugin self-installs the **setup › Security › Face Howdy** row
into `~/.config/omarchy/extensions/omarchy-menu.jsonc`, so the wizard is
reachable from the Omarchy menu with no manual config. The row lives in your
user config (not the shipped defaults), so it survives Omarchy upgrades.
Disabling or removing the plugin takes the row back out automatically.

### Running the wizard

Open it from the Omarchy menu (**Setup → Security → Face Howdy**), or from a
terminal:

```sh
omarchy-shell shell toggle face.howdy
```

The wizard shows your current status and offers:

1. **Install** — runs `packages → IR emitter → models → PAM` with progress.
2. It then asks you to confirm the PAM deploy.
3. **Face data** — Add / Test / Clear your face.
4. **Remove** — keep-or-delete packages, always restoring stock auth + lock.

After install and lock deploy, the shell restarts automatically. There is no
separate enrollment step to run by hand — use **Face data → Add face** from the
wizard (Howdy's own terminal UI opens).

## A note on security

This is the same trade-off as Windows Hello. Howdy's `pam_howdy.so` is
configured as a **sufficient** (not sole) auth factor, so your password remains
a fallback and nothing is ever removed. Face unlock is a convenience, not a
hard guarantee against a determined attacker with your photo — treat it as
you would any other face unlock.

## Uninstalling

```sh
omarchy plugin remove face.howdy --yes
```

Or remove **inside** the wizard first, which clears the system changes, then
remove the plugin. If any menu row is ever left behind:

```sh
omarchy-howdy-menu-install --remove
```

Removing always clears the Howdy PAM lines from `sudo` / `sddm` / `polkit-1`,
removes `omarchy-lock-howdy`, disables the IR-emitter systemd services/udev
rule, and restores the stock lock screen — so you're never locked out. You
choose whether the `howdy*` packages and face models are kept or deleted.

## How it works (for the curious)

- **Plugin lifecycle is deliberately safe.** `omarchy plugin enable/disable/remove`
  run no privileged code, so this plugin drives every system change itself from
  the QML window via `pkexec` → the bundled `bin/omarchy-howdy-setup-system` /
  `bin/omarchy-howdy-teardown-system` scripts (the same "privileged bridge"
  pattern the thinkfan widget uses).
- **Phases are idempotent.** Each phase of `setup-system` (packages / IR /
  models / PAM) is safe to re-run, and the lock patch uses a marker guard so it
  never double-applies and is never wiped by an `omarchy update`.
- **The lock screen.** `deploy-lock` clones the stock `omarchy.lock` into your
  per-user plugins, applies the bundled Howdy patch to its `Service.qml`
  (adding a Howdy PAM context + IR retry path), and flips `shell.json` to use
  the patched clone while disabling the stock one — all reversible.

## License

[MIT](LICENSE). Not affiliated with Howdy, linux-enable-ir-emitter, or Omarchy.
