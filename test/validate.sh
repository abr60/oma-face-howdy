#!/bin/bash

# Validate the face.howdy plugin folder. Uses the Omarchy validator when
# available, and falls back to the same core checks via jq so plugin authors
# without Omarchy can still gate their work.

set -euo pipefail

PLUGIN_DIR="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  exec omarchy-plugin-validate "$PLUGIN_DIR"
fi

fail() {
  echo "validate: $*" >&2
  exit 1
}

MANIFEST="$PLUGIN_DIR/manifest.json"
[[ -f $MANIFEST ]] || fail "missing manifest.json in $PLUGIN_DIR"
jq -e . "$MANIFEST" >/dev/null 2>&1 || fail "manifest.json is not valid JSON"

jq -e '.schemaVersion == 1' "$MANIFEST" >/dev/null 2>&1 || fail "unsupported or missing schemaVersion"

for field in id name version kinds entryPoints; do
  jq -e --arg f "$field" 'has($f)' "$MANIFEST" >/dev/null 2>&1 || fail "manifest missing required field '$field'"
done

ID=$(jq -r '.id // ""' "$MANIFEST")
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid plugin id '$ID'"
[[ $ID != *".."* ]] || fail "invalid plugin id '$ID'"
[[ $ID != omarchy.* ]] || fail "plugin id '$ID' uses the reserved omarchy.* namespace"

jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' "$MANIFEST" >/dev/null 2>&1 ||
  fail "'kinds' must be a non-empty array"
jq -e '(.entryPoints | type) == "object"' "$MANIFEST" >/dev/null 2>&1 ||
  fail "'entryPoints' must be an object"

jq -e '(.kinds | index("service")) != null' "$MANIFEST" >/dev/null 2>&1 &&
  jq -e '.entryPoints | has("service")' "$MANIFEST" >/dev/null 2>&1 ||
  fail "kind 'service' requires an 'entryPoints.service' to load"

EP=$(jq -r '.entryPoints.service // ""' "$MANIFEST")
[[ -n $EP && $EP != /* && $EP != *".."* ]] || fail "invalid entry point: '$EP'"
[[ -f "$PLUGIN_DIR/$EP" ]] || fail "entry point file not found: '$EP'"

# Bundled scripts must be present and executable.
for bin in omarchy-howdy-setup-system omarchy-howdy-teardown-system \
           omarchy-howdy-deploy-lock omarchy-howdy-restore-lock \
           omarchy-howdy-status omarchy-howdy-menu-install \
           omarchy-howdy-menu-entry; do
  [[ -f "$PLUGIN_DIR/bin/$bin" ]] || fail "missing bundled script bin/$bin"
  [[ -x "$PLUGIN_DIR/bin/$bin" ]] || fail "bin/$bin is not executable"
done

link=$(find "$PLUGIN_DIR" -name .git -prune -o -type l -print -quit 2>/dev/null)
[[ -z $link ]] || fail "symlinks are not allowed inside a plugin folder: $link"

echo "validate: $PLUGIN_DIR looks valid"
