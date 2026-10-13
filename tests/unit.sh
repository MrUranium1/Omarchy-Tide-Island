#!/usr/bin/env bash
# Unit tests for scripts/tide-sync.sh. Run from anywhere:
#   bash tests/unit.sh
# Requires: bash, jq, patch, and diff-testable upstream plugin files.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SYNC="$ROOT/scripts/tide-sync.sh"
FAKE="$ROOT/tests/fake-systemctl.sh"
pass=0
fail=0

t() { printf '  - %s\n' "$*"; }

ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A temporary config that points everything at the temp dir.
mkdir -p "$tmp/toggles" "$tmp/home/.local/state/omarchy/toggles"

write_config() { # $1 = coordinateWithBar $2 = startWithBarHidden $3 = stopWithBarShown
  cat >"$tmp/config.json" <<EOF
{
  "coordinateWithBar": $1,
  "startWithBarHidden": $2,
  "stopWithBarShown": $3,
  "togglesDir": "$tmp/toggles"
}
EOF
}

setup_fake() {
  echo "inactive" >"$tmp/active"
  : >"$tmp/calls"
  export TIDE_ISLAND_CONFIG="$tmp/config.json"
  export TIDE_SYNC_SYSTEMCTL="$FAKE"
  export FAKE_SYSTEMCTL_STATE_FILE="$tmp/active"
  export FAKE_SYSTEMCTL_LOG_FILE="$tmp/calls"
}

calls() { wc -l <"$tmp/calls"; }

echo "tide-sync.sh unit tests"

echo "  syntax check"
bash -n "$SYNC" && t "tide-sync.sh parses" && ok || ko

echo "  reconcile matrix (idempotent; no redundant calls)"
setup_fake
write_config true true true
touch "$tmp/toggles/bar-off"

t "bar hidden + service active -> no-op"
echo "active" >"$tmp/active"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 0 ]] && ok || { ko; }

t "bar hidden + service inactive -> one start"
echo "inactive" >"$tmp/active"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 1 && "$(cat "$tmp/active")" == "active" ]] && ok || { ko; }

t "still bar hidden + now active -> no-op"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 1 ]] && ok || { ko; }

t "bar visible + service active -> one stop"
rm -f "$tmp/toggles/bar-off"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 && "$(cat "$tmp/active")" == "inactive" ]] && ok || { ko; }

t "bar visible + service stopped -> no-op"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "coordinateWithBar=false -> never touches the service"
write_config false true true
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "startWithBarHidden=false -> bar hidden leaves service alone"
write_config true false true
touch "$tmp/toggles/bar-off"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "stopWithBarShown=false -> bar visible leaves service alone"
write_config true true false
rm -f "$tmp/toggles/bar-off"
"$SYNC" reconcile >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

t "--dry-run makes no systemctl calls"
write_config true true true
touch "$tmp/toggles/bar-off"
"$SYNC" reconcile --dry-run >/dev/null
[[ $(calls) -eq 2 ]] && ok || { ko; }

echo "  probe + config"
setup_fake
write_config true true true
touch "$tmp/toggles/bar-off"
[[ "$("$SYNC" probe)" == "bar-hidden" ]] && ok || ko
rm -f "$tmp/toggles/bar-off"
[[ "$("$SYNC" probe)" == "bar-visible" ]] && ok || ko
"$SYNC" config | jq -e '.config.coordinateWithBar == true' >/dev/null && ok || ko

echo "  defaults parity: default/tide-island.json keys present in Service.qml"
for key in $(jq -r 'keys[]' "$ROOT/default/tide-island.json"); do
  grep -q "      $key:" "$ROOT/Service.qml" && ok || { t "missing key $key in Service.qml" && ko; }
done

echo "  suppression patches apply cleanly to pristine clones then reverse"
for pair in "omarchy.osd:patches/omarchy-osd-suppression.patch:Osd.qml" \
            "omarchy.notifications:patches/omarchy-notifications-suppression.patch:Service.qml"; do
  IFS=: read -r src relpatch entry < <(printf '%s\n' "$pair")
  mkdir -p "$tmp/apply"
  cp "/usr/share/omarchy/shell/plugins/${src#omarchy.}/$entry" "$tmp/apply/$entry"
  if (cd "$tmp/apply" && patch -p1 --batch --no-backup-if-mismatch <"$ROOT/$relpatch" >/dev/null 2>&1); then
    t "$relpatch applies to pristine file" && ok
  else
    t "$relpatch FAILED to apply to pristine file" && ko
  fi
  if (cd "$tmp/apply" && patch -p1 --batch -R --dry-run <"$ROOT/$relpatch" >/dev/null 2>&1); then
    t "$relpatch reverse-applies cleanly" && ok
  else
    t "$relpatch FAILED reverse-apply" && ko
  fi
  rm -rf "$tmp/apply"
done

echo "  ensure-suppression state tracking (sandboxed HOME)"
es_upstream="/usr/share/omarchy/shell/plugins/osd/Osd.qml"
es="$tmp/es"
mkdir -p "$es/bin" "$es/home/.config/omarchy/plugins/mehir.osd"
cat >"$es/bin/omarchy-plugin-list" <<'EOS'
#!/usr/bin/env bash
echo '[{"id":"mehir.osd","firstParty":false,"clonedFrom":"omarchy.osd","enabled":true}]'
EOS
cat >"$es/bin/omarchy-shell" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$es/bin/omarchy-plugin-list" "$es/bin/omarchy-shell"
printf '{"entryPoints":{"panel":"Osd.qml"}}' >"$es/home/.config/omarchy/plugins/mehir.osd/manifest.json"
es_osd="$es/home/.config/omarchy/plugins/mehir.osd/Osd.qml"
es_state="$es/home/.local/state/omarchy/tide-island/patch-state/mehir.osd"
es_backups="$es/home/.local/state/omarchy/tide-island/backups"
run_es() { HOME="$es/home" PATH="$es/bin:$PATH" bash "$ROOT/scripts/ensure-suppression.sh" "$@"; }

cp "$es_upstream" "$es_osd"
run_es >/dev/null 2>&1 || true
t "apply to a pristine clone patches it and records 'applied'"
grep -q 'The bar-off marker' "$es_osd" && [[ "$(cat "$es_state" 2>/dev/null)" == applied ]] && ok || ko
t "apply backs the pristine file up"
[[ -n "$(ls -1 "$es_backups" 2>/dev/null)" ]] && ok || ko

run_es --restore >/dev/null 2>&1 || true
t "--restore undoes a patch we applied (back to pristine, state cleared)"
cmp -s "$es_osd" "$es_upstream" && [[ ! -f $es_state ]] && ok || ko

# Pre-existing suppression: patch the clone, then drop our state marker so the
# clone looks like it was suppressed before the plugin ever ran.
cp "$es_upstream" "$es_osd"
(cd "$es/home/.config/omarchy/plugins/mehir.osd" && patch -p1 --batch --no-backup-if-mismatch <"$ROOT/patches/omarchy-osd-suppression.patch" >/dev/null 2>&1)
rm -f "$es_state"
run_es >/dev/null 2>&1 || true
t "apply on an already-patched clone records 'preexisting'"
[[ "$(cat "$es_state" 2>/dev/null)" == preexisting ]] && ok || ko

run_es --restore >/dev/null 2>&1 || true
t "--restore leaves a pre-existing suppression untouched"
grep -q 'The bar-off marker' "$es_osd" && ok || ko

echo "  install-tide-runtime.sh (sandboxed HOME, forced bundle)"
ir="$tmp/ir"
ir_prefix="$ir/home/.local/share/omarchy-tide-island"
mkdir -p "$ir/home/.local/bin"
run_ir() {
  HOME="$ir/home" TIDE_ISLAND_FORCE_BUNDLE=1 TIDE_ISLAND_PREFIX="$ir_prefix" \
    TIDE_SYNC_SYSTEMCTL=/bin/true bash "$ROOT/scripts/install-tide-runtime.sh" "$@"
}
run_ir >/dev/null 2>&1
t "installs the launcher and backend into the prefix"
[[ -x "$ir_prefix/bin/tide-island" && -f "$ir_prefix/lib/libIslandBackend.so" ]] && ok || ko
t "installs the QML tree"
[[ -f "$ir_prefix/share/tide-island/shell.qml" ]] && ok || ko
t "installs the settings GUI into the prefix"
[[ -x "$ir_prefix/bin/tide-island-config-app" ]] && ok || ko
t "links the config app onto PATH"
[[ -L "$ir/home/.local/bin/tide-island-config-app" ]] && ok || ko
t "installs both desktop entries"
[[ -f "$ir/home/.local/share/applications/tide-island.desktop" \
  && -f "$ir/home/.local/share/applications/tide-island-config.desktop" ]] && ok || ko
t "writes a user unit carrying our marker"
grep -q 'managed by mehir.tide-island' "$ir/home/.config/systemd/user/tide-island.service" && ok || ko
t "links tide-island onto PATH"
[[ -L "$ir/home/.local/bin/tide-island" ]] && ok || ko
t "second run is idempotent"
run_ir >/dev/null 2>&1 && [[ "$(cat "$ir_prefix/.version")" == "$(cat "$ROOT/vendor/tide-island/VERSION")" ]] && ok || ko

printf 'FOREIGN UNIT\n' >"$ir/home/.config/systemd/user/tide-island.service"
run_ir >/dev/null 2>&1
t "never clobbers a foreign (non-managed) unit"
grep -q 'FOREIGN UNIT' "$ir/home/.config/systemd/user/tide-island.service" && ok || ko

echo
echo "unit: $pass passed, $fail failed"
(( fail == 0 ))