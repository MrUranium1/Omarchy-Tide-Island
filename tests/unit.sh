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
  if (cd "$tmp/apply" && patch -p1 --no-backup-if-mismatch <"$ROOT/$relpatch" >/dev/null 2>&1); then
    t "$relpatch applies to pristine file" && ok
  else
    t "$relpatch FAILED to apply to pristine file" && ko
  fi
  if (cd "$tmp/apply" && patch -p1 -R --dry-run <"$ROOT/$relpatch" >/dev/null 2>&1); then
    t "$relpatch reverse-applies cleanly" && ok
  else
    t "$relpatch FAILED reverse-apply" && ko
  fi
  rm -rf "$tmp/apply"
done

echo
echo "unit: $pass passed, $fail failed"
(( fail == 0 ))