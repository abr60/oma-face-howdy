#!/bin/bash

# Functional tests for the face.howdy bundle, focused on the parts that are
# safe to exercise without touching a real system: the marker-guarded,
# idempotent lock-plugin deploy/restore round-trip and the status output
# format. Never modifies real ~/.config — everything runs in a scratch HOME.

set -euo pipefail

PLUGIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "face-howdy-test: FAIL: $1${2:+: $2}" >&2
  exit 1
}
pass() {
  echo "ok - $1"
}

# Gate on the Omarchy validator when present.
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$PLUGIN_DIR" || fail "omarchy-plugin-validate"
  pass "plugin folder passes omarchy-plugin-validate"
else
  echo "note - omarchy-plugin-validate not found; skipping validator gate"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HOME_W="$WORK/home"
mkdir -p "$HOME_W/.config/hypr" "$HOME_W/.config/omarchy/plugins" "$HOME_W/.local/state"

STOCK_QML="/usr/share/omarchy/shell/plugins/lock/Service.qml"
if [[ ! -f $STOCK_QML ]]; then
  echo "note - stock lock Service.qml not found; synthesizing an unpatched stub"
  cat >"$HOME_W/.config/omarchy/plugins/stock.Service.qml" <<'EOF'
// minimal stock lock (no howdy marker)
Item { id: stubProperty }
EOF
  STOCK_QML="$HOME_W/.config/omarchy/plugins/stock.Service.qml"
fi

cat >"$HOME_W/.config/omarchy/shell.json" <<'EOF'
{
  "plugins": [],
  "disabledPlugins": [],
  "cloneSourceRestores": []
}
EOF

LOCK_ID="testuser.lock"   # matches `id -un` prefix if the runner is testuser, else deploy computes its own

# Pre-seed the clone so deploy-lock takes the "reconcile existing clone"
# branch (avoids invoking `omarchy plugin clone` against the real config).
os_id="$(id -un).lock"
SEED_DIR="$HOME_W/.config/omarchy/plugins/$os_id"
mkdir -p "$SEED_DIR"
cp "$STOCK_QML" "$SEED_DIR/Service.qml"
cat >"$SEED_DIR/manifest.json" <<'EOF'
{"id":"TBD","kinds":["service"],"keepLoaded":true,"entryPoints":{"service":"Service.qml"}}
EOF

export HOME="$HOME_W"
export FACE_HOWDY_SHELL_JSON="$HOME_W/.config/omarchy/shell.json"
export FACE_HOWDY_PLUGIN_ROOT="$HOME_W/.config/omarchy/plugins"
export FACE_HOWDY_STATE_DIR="$HOME_W/.local/state/face.howdy"

# 1. First deploy: patch applied, shell.json swapped, marker present once.
"$PLUGIN_DIR/bin/omarchy-howdy-deploy-lock" >/dev/null
count=$(grep -c "property bool howdyConfigured: false" "$SEED_DIR/Service.qml" || true)
[[ $count == 1 ]] || fail "expected howdy marker exactly once after deploy, got '$count'"
pass "lock plugin patched with howdy marker (once)"

grep -q "\"$os_id\"" "$HOME_W/.config/omarchy/shell.json" || (
  python3 -c "import json,sys; d=json.load(open('$HOME_W/.config/omarchy/shell.json')); ids=[p['id'] if isinstance(p,dict) else p for p in d.get('plugins',[])]; sys.exit(0 if '$os_id' in ids else 1)"
) || fail "shell.json plugins missing patched clone $os_id"
pass "shell.json enables the patched clone"

# 2. Second deploy must be idempotent (still exactly one marker, no corruption).
"$PLUGIN_DIR/bin/omarchy-howdy-deploy-lock" >/dev/null
count=$(grep -c "property bool howdyConfigured: false" "$SEED_DIR/Service.qml" || true)
[[ $count == 1 ]] || fail "re-deploy is not idempotent; marker count=$count"
pass "re-deploy is idempotent (marker still once)"

# 3. Restore flips shell.json back and clears state.
"$PLUGIN_DIR/bin/omarchy-howdy-restore-lock" >/dev/null
ids=$(python3 -c "import json; d=json.load(open('$HOME_W/.config/omarchy/shell.json')); print(len([p for p in d.get('plugins',[]) if (p['id'] if isinstance(p,dict) else p)=='$os_id']), len([x for x in d.get('disabledPlugins',[])]) )")
read -r nclone ndisabled <<<"$ids"
[[ $nclone == 0 ]] || fail "restore left clone in plugins array"
pass "restore removes the clone from shell.json"

[[ ! -f "$HOME_W/.local/state/face.howdy/deployed" ]] || fail "restore left deployed state file"
pass "restore clears face.howdy state"

# 4. Status script emits expected keys.
out="$("$PLUGIN_DIR/bin/omarchy-howdy-status")"
grep -q "^howdy_pkg=" <<<"$out" || fail "status missing howdy_pkg"
grep -q "^active_lock=" <<<"$out" || fail "status missing active_lock"
pass "status script emits known keys"

echo
echo "All face.howdy tests passed."
