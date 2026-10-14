#!/usr/bin/env bash
#
# tests/live.sh — end-to-end live test of the Tide Island <-> bar coordination.
# Requires the omarchy shell to be running (logged-in session) and takes over
# the bar/Tide state while it runs. Every assertion ends with the bar hidden
# and Tide Island running exactly as it was before. Run: bash tests/live.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLAG="$HOME/.local/state/omarchy/toggles/bar-off"
POPUPS="$HOME/.local/state/omarchy/notifications/popups"
HISTORY="$HOME/.local/state/omarchy/notifications/history"
TOGGLE="$HOME/.local/bin/omarchy-tide-island-toggle"
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "    PASS: $*"; }
ko() { fail=$((fail + 1)); echo "    FAIL: $*"; }

runtest() { echo "  - $*"; }

tide_pids() { pgrep -af 'quickshell -p .*tide-island' | wc -l || true; }

# Count regular files in a directory; returns 0 for a missing/empty directory.
count_files() { local d="$1"; [[ -d $d ]] || { echo 0; return 0; }; find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l; }

wait_until() { # $1 = single-quoted condition (evaluated each pass), $2 = label, $3 = timeout secs
  local deadline=$((SECONDS + ${3:-10}))
  while (( SECONDS < deadline )); do
    if eval "$1" >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  return 0 # callers assert the result; never abort the suite via errexit
}

restore_state() {
  mkdir -p "$(dirname "$FLAG")"
  touch "$FLAG" >/dev/null 2>&1 || true
  systemctl --user start tide-island.service 2>/dev/null || true
  omarchy-shell tide-island sync 2>/dev/null || true
}
trap restore_state EXIT

echo "tide-island live integration test"
echo "  pre-flight: shell reachability + state"

if ! out="$(omarchy-shell tide-island ping 2>/dev/null || true)"; then out=""; fi
[[ "$out" == "ok" ]] && ok "IPC ping returns ok" || ko "IPC ping ('$out')"

status_json="$(omarchy-shell tide-island status 2>/dev/null || true)"
if echo "$status_json" | jq -e '.plugin == "mehir.tide-island"' >/dev/null 2>&1; then
  ok "status JSON is for mehir.tide-island"
  [[ $(jq -r '.configOk' <<<"$status_json") == "true" ]] && ok "configOk" || ko "configOk false: $(jq -r '.configError' <<<"$status_json")"
  echo "  field sanity: barHidden=$(jq -r .barHidden <<<"$status_json") tideActive=$(jq -r .tideActive <<<"$status_json")"
else
  ko "status JSON unparseable: $status_json"
fi

echo "  A. single Tide Island process"
[[ $(tide_pids) -eq 1 ]] && ok "exactly one quickshell tide process" || ko "tide process count = $(tide_pids)"

echo "  B. toggle coordination (bar hidden <-> visible)"
t0_flag=0; [[ -f $FLAG ]] && t0_flag=1
t0_active=$(systemctl --user is-active tide-island.service 2>/dev/null || echo unknown)

if (( t0_flag )); then
  "$TOGGLE"
  wait_until '[[ ! -f "$FLAG" ]] && [[ "$(systemctl --user is-active tide-island.service 2>/dev/null)" == inactive ]]' "bar shown + service stopped"
  [[ ! -f $FLAG ]] && ok "toggle removed bar-off flag" || ko "flag still present"
  [[ $(systemctl --user is-active tide-island.service 2>/dev/null) == "inactive" ]] \
    && ok "service stopped with bar visible" || ko "service not stopped"
  s0="hidden"; s1="visible"
else
  s0="visible"
fi

"$TOGGLE" # <- back to hidden (Tide on)
wait_until '[[ -f "$FLAG" ]] && [[ "$(systemctl --user is-active tide-island.service 2>/dev/null)" == active ]]' "bar hidden + service active"
[[ -f $FLAG ]] && ok "toggle restored bar-off flag" || ko "flag missing after second toggle"
[[ $(systemctl --user is-active tide-island.service 2>/dev/null) == "active" ]] \
  && ok "service active with bar hidden" || ko "service not active"
[[ "$(omarchy-shell tide-island status 2>/dev/null | jq -r .tideActive 2>/dev/null || true)" == "active" ]] \
  && ok "plugin reports tide active" || ko "plugin does not report active"
[[ $(tide_pids) -eq 1 ]] && ok "still exactly one tide process after toggles" || ko "process count = $(tide_pids)"

echo "  C. OSD stands down while Tide Island owns the screen"
[[ -f $FLAG ]] || { mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; systemctl --user start tide-island.service; sleep 1; }
omarchy osd -i volume-high -p 33 >/dev/null 2>&1 || true
sleep 0.5
[[ "$(omarchy-shell osd state 2>/dev/null || true)" == "closed" ]] \
  && ok "OSD suppressed (closed) while bar hidden" || ko "OSD open while bar hidden"

echo "  D. OSD shows again when the bar is visible"
rm -f "$FLAG"
systemctl --user stop tide-island.service 2>/dev/null || true
sleep 1
omarchy osd -i volume-high -p 66 -d 8000 >/dev/null 2>&1 || true
wait_until '[[ "$(omarchy-shell osd state 2>/dev/null || true)" == open ]]' "osd open"
[[ "$(omarchy-shell osd state 2>/dev/null || true)" == "open" ]] \
  && ok "OSD visible with bar visible" || ko "OSD not open"
omarchy-shell osd close >/dev/null 2>&1 || true
sleep 0.2
omarchy-shell osd close >/dev/null 2>&1 || true
restore_state
sleep 1

echo "  E. notifications suppressed (history still recorded)"
# Use the real toggle so the notification plugin's probe is nudged; a raw
# touch would leave its suppression state stale.
[[ -f $FLAG ]] || "$TOGGLE"
wait_until '[[ "$(omarchy-shell tide-island status 2>/dev/null | jq -r .notificationsSuppression 2>/dev/null || true)" == "true" ]]' "notifications suppression on" 10
tag="live-suppressed-$$"
notify-send -a tide-plugin-test "$tag" "suppressed popup" >/dev/null 2>&1 || true
sleep 1.5
popups_during=$(count_files "$POPUPS")
# A suppressed toast never shows, but is archived to history when its own
# expiry timer fires (normal urgency = 8s). History is capped at 10 entries
# (historyLimit), so assert the entry landed rather than that the count grew.
wait_until 'grep -rlq "$tag" "$HISTORY" 2>/dev/null' "suppressed notification archived" 16
[[ $popups_during -eq 0 ]] && ok "no popup while suppressed" || ko "popup(s) shown while suppressed ($popups_during)"
newest="$(ls -t "$HISTORY" 2>/dev/null | head -1 || true)"
if [[ -n $newest ]] && grep -q "$tag" "$HISTORY/$newest" 2>/dev/null; then
  ok "history archived the suppressed notification (newest: $newest)"
else
  ko "suppressed notification missing from newest history entry"
fi

echo "  F. repeated rapid toggles stay consistent"
for _ in 1 2 3 4; do "$TOGGLE"; sleep 0.3; done
sleep 1.5
[[ -f $FLAG ]] && ok "flag settled hidden after rapid toggles" || ko "flag in wrong state after rapid toggles"
[[ $(systemctl --user is-active tide-island.service 2>/dev/null) == "active" ]] \
  && ok "service settled active after rapid toggles" || ko "service state off after rapid toggles"
[[ $(tide_pids) -eq 1 ]] && ok "exactly one tide process survived rapid toggles" || ko "process count = $(tide_pids)"

echo "  G. CLI status is informative"
status="$(omarchy-tide-island-status 2>&1 || true)"
echo "$status" | grep -Eq 'bar hidden[[:space:]]+yes' && ok "CLI status: bar hidden yes" || ko "CLI status missing bar-hidden"
echo "$status" | grep -Eq 'OSD stands down[[:space:]]+yes' && ok "CLI status: OSD stands down" || ko "CLI status missing OSD suppression"
echo "$status" | grep -Eq 'notifications stand down[[:space:]]+yes' && ok "CLI status: notifications stand down" || ko "CLI status missing notification suppression"

echo "  H. shipped island shortcuts are free against the live compositor"
if command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1; then
  seed="$ROOT/default/tide-userconfig.json"
  # Live pure SUPER+ALT letter bindings that belong to something other than the
  # island. Omarchy's own binds carry a description; the island's managed block
  # is written by its settings app as lua binds with none, so it never counts.
  live_reserved="$(hyprctl binds -j 2>/dev/null \
    | jq -r '.[] | select(.modmask == 72) | .key
             | select(test("^[A-Z]$"))' 2>/dev/null || true)"
  live_owned="$(hyprctl binds -j 2>/dev/null \
    | jq -r '.[] | select(.modmask == 72)
             | select(((.description // "") | test("island|tide"; "i")))
             | .key' 2>/dev/null || true)"
  reserved_letters=""
  while IFS= read -r k; do
    [[ -z $k ]] && continue
    grep -qxF "$k" <<<"$live_owned" && continue
    reserved_letters="$reserved_letters $k"
  done <<<"$live_reserved"
  clash=""
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    for r in $reserved_letters; do [[ $key == "$r" ]] && clash="$clash $key"; done
  done < <(jq -r '.shortcutBindings[]? | select((.key // "") != "") | .key' "$seed")
  [[ -z ${clash// /} ]] \
    && ok "no shipped island shortcut collides with a live SUPER+ALT binding (live reserved:${reserved_letters:-none})" \
    || ko "island shortcut(s)${clash} collide with a live SUPER+ALT binding"
else
  ok "hyprctl unavailable in this session; skipped live keybinding collision check"
fi

echo
echo "live: $pass passed, $fail failed"
(( fail == 0 ))