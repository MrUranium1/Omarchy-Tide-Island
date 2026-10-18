#!/usr/bin/env bash
# Regression test for the bounded auto-setup that stops the startup bounce loop.
#
# Background: the setup-complete marker (~/.local/state/omarchy/tide-island/
# auto-setup.done) is written ONLY by scripts/ensure-mount.sh once the patched
# OSD/notifications clones are verified SERVING at runtime. While it is absent,
# Service.qml re-ran install.sh on every shell load; each run spawns a detached
# ensure-mount.sh that bounces the mounted plugin set (up to five
# `omarchy-shell shell rescanPlugins` reloads), so a setup that could not
# converge produced a multi-blink storm at every startup. Service.qml now bounds
# auto-setup: each attempt is recorded in auto-setup.state and only re-runs after
# a cooldown, giving up after maxAutoSetupAttempts.
#
# This test asserts the bounding is present and behaves, WITHOUT touching a real
# session, and that the security-critical pieces it must not disturb are intact:
#   * the gate records attempts, blocks on cooldown, blocks when exhausted, and
#     resets the budget when the marker appears;
#   * the upgrade migration (scripts/migrate.sh — the hardened-launcher + config
#     privacy refresh) still runs on every load, independent of the auto-setup
#     marker, so bounding auto-setup can never skip the security migration;
#   * the marker is still only written after a verified mount (ensure-mount.sh)
#     and is still cleared on removal (teardown.sh), so the budget restarts for
#     a genuine reinstall.
#
# Run from anywhere: bash tests/auto-setup-bounds.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SERVICE="$ROOT/Service.qml"
ENSURE_MOUNT="$ROOT/scripts/ensure-mount.sh"
TEARDOWN="$ROOT/scripts/teardown.sh"
pass=0
fail=0
t() { printf '  - %s\n' "$*"; }
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); printf '    ^^ FAILED\n'; }

echo "Tide Island bounded auto-setup tests"

# --------------------------------------------------------------- structural
t "Service.qml declares the auto-setup state file"
grep -q 'auto-setup\.state' "$SERVICE" && ok || ko

t "Service.qml bounds attempts (maxAutoSetupAttempts) and a cooldown"
grep -q 'maxAutoSetupAttempts' "$SERVICE" && grep -q 'autoSetupCooldownSec' "$SERVICE" && ok || ko

t "setupGateProbe records attempts and blocks on exhausted/cooldown"
grep -q 'gate=no:exhausted' "$SERVICE" && grep -q 'gate=no:cooldown' "$SERVICE" \
  && grep -q 'auto-setup\.state' "$SERVICE" && ok || ko

# The upgrade migration must stay independent of the auto-setup marker, so the
# bounding can never suppress the hardened-launcher / config-privacy refresh.
t "upgrade migration runs independent of the auto-setup marker (security fix intact)"
maybe_migrate_body="$(awk '/function maybeMigrate/{f=1} f{print} f&&/^\s*}/{exit}' "$SERVICE")"
grep -q 'maybeMigrate' "$SERVICE" && grep -q 'migrateProc' "$SERVICE" \
  && grep -q 'migrateScript' "$SERVICE" && ! grep -q 'autoSetupMarker\|setupGateProbe' <<<"$maybe_migrate_body" \
  && ok || ko

t "migrate.sh still performs the hardened-launcher + config-privacy refresh"
grep -q 'install-tide-runtime\.sh' "$ROOT/scripts/migrate.sh" \
  && grep -q 'harden-tide-config\.sh' "$ROOT/scripts/migrate.sh" && ok || ko

t "auto-setup.done is still only written by ensure-mount after a verified mount"
grep -q 'wrote setup-complete marker' "$ENSURE_MOUNT" \
  && grep -q 'suppression_live' "$ENSURE_MOUNT" && ok || ko

t "teardown clears the setup marker so a reinstall restarts the budget"
grep -q 'auto-setup\.done' "$TEARDOWN" && grep -q 'cleared the setup-complete marker' "$TEARDOWN" && ok || ko

# ---------------------------------------------------------------- behavioral
# Drive the real gate embedded in Service.qml against a throwaway $HOME. The
# gate interpolates two QML properties (maxAutoSetupAttempts, cooldown), so the
# extraction substitutes them from Service.qml's own declarations.
extract_gate() {
  python3 - "$SERVICE" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
maxa = re.search(r'maxAutoSetupAttempts:\s*(\d+)', src).group(1)
cool = re.search(r'autoSetupCooldownSec:\s*(\d+)', src).group(1)
m = re.search(r'id:\s*setupGateProbe.*?command:\s*\["bash",\s*"-c",\s*(.*?)\]\s*\n\s*stdout:', src, re.S)
body = m.group(1)
script = "".join(p.encode().decode('unicode_escape')
                 for p in re.findall(r'"((?:[^"\\]|\\.)*)"', body))
script = script.replace("attempts >=  ", "attempts >= %s " % maxa)
script = script.replace("now - last <  ", "now - last < %s " % cool)
sys.stdout.write(script)
PY
}

if command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  export HOME="$tmp/home"
  mkdir -p "$HOME"
  STATE="$HOME/.local/state/omarchy/tide-island"
  MARKER="$STATE/auto-setup.done"
  GATE="$tmp/gate.sh"
  extract_gate >"$GATE"

  t "gate extraction produced a runnable script"
  bash -n "$GATE" && [[ -s $GATE ]] && ok || ko

  out="$(bash "$GATE")"
  t "fresh install (no marker, no state) is allowed to set up"
  [[ "$out" == "gate=yes" ]] && ok || ko
  t "the attempt is recorded"
  [[ "$(jq -r '.attempts' "$STATE/auto-setup.state")" == 1 ]] && ok || ko

  out="$(bash "$GATE")"
  t "an immediate re-run is blocked by the cooldown"
  [[ "$out" == "gate=no:cooldown" ]] && ok || ko

  printf '{"attempts":3,"lastAttempt":1}\n' >"$STATE/auto-setup.state"
  out="$(bash "$GATE")"
  t "a setup that already used its budget is blocked (exhausted)"
  [[ "$out" == "gate=no:exhausted" ]] && ok || ko

  : >"$MARKER"
  out="$(bash "$GATE")"
  t "the marker short-circuits the gate and resets the budget"
  [[ "$out" == "gate=no:marker" ]] && [[ "$(jq -r '.attempts' "$STATE/auto-setup.state")" == 0 ]] && ok || ko

  # ------------------------------------------ repeated install/uninstall cycles
  # teardown.sh clears the setup marker on removal; it must ALSO clear the
  # attempt budget, otherwise attempts accumulate across cycles until the bound
  # exhausts and a later reinstall's auto-setup is silently skipped. Run the
  # real teardown in a sandbox (fake omarchy binaries so no live session is
  # touched) and assert an exhausted budget becomes fresh for the next cycle.
  #
  # Model a heavily-used install: the budget was drawn down to exhaustion by
  # earlier cycles and, after a failed setup, no marker is present — so the
  # next load's auto-setup is silently blocked.
  rm -f "$MARKER"
  printf '{"attempts":3,"lastAttempt":1}\n' >"$STATE/auto-setup.state"
  out="$(bash "$GATE")"
  t "precondition: an exhausted budget blocks auto-setup"
  [[ "$out" == "gate=no:exhausted" ]] && ok || ko

  # A prior successful cycle also leaves the marker; uninstall must clear both
  # so the next reinstall starts fresh.
  : >"$MARKER"
  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin"
  for b in omarchy omarchy-shell omarchy-plugin-list systemctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fakebin/$b"
    chmod +x "$fakebin/$b"
  done
  trc=0
  PATH="$fakebin:$PATH" bash "$ROOT/scripts/teardown.sh" >"$tmp/teardown.log" 2>&1 || trc=$?
  t "teardown runs in the sandbox"
  [[ $trc -eq 0 ]] && ok || { ko; tail -20 "$tmp/teardown.log"; }

  t "teardown clears the attempt budget alongside the marker"
  [[ ! -e "$STATE/auto-setup.state" ]] && ok || ko
  t "teardown clears the setup marker (existing behavior preserved)"
  [[ ! -e "$MARKER" ]] && ok || ko

  out="$(bash "$GATE")"
  t "the next cycle's auto-setup starts with a fresh budget (not exhausted)"
  [[ "$out" == "gate=yes" ]] && [[ "$(jq -r '.attempts' "$STATE/auto-setup.state")" == 1 ]] && ok || ko
else
  echo "  (skipping behavioral gate tests: python3/jq not available)"
fi

echo
printf 'auto-setup-bounds: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
