#!/usr/bin/env bash
# tests/cleanroom.sh — full install -> upgrade -> uninstall -> reinstall
# lifecycle test in a disposable $HOME with fake omarchy/systemctl/omarchy-shell
# commands. It never touches the real session or configuration.
#
# Run from anywhere: bash tests/cleanroom.sh
# Skips the clone/patch steps when the upstream Omarchy plugins are absent.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UPSTREAM="/usr/share/omarchy/shell/plugins"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  PASS: %s\n' "$*"; }
ko() { fail=$((fail + 1)); printf '  FAIL: %s\n' "$*"; }

for up in osd notifications; do
  [[ -f "$UPSTREAM/$up/manifest.json" ]] || {
    echo "cleanroom: upstream '$UPSTREAM/$up' missing; cannot run faithfully. Skipping."
    exit 0
  }
done

SB="$(mktemp -d "${TMPDIR:-/tmp}/tide-island-cleanroom.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB/home"
# Force the bundled runtime path even though this machine may have the
# tide-island package on PATH; the sandbox has its own $HOME.
export TIDE_ISLAND_FORCE_BUNDLE=1
BIN="$SB/bin"
mkdir -p "$HOME/.local/bin" "$BIN"
export PATH="$BIN:$PATH"

# ------------------------------------------------------------- fake commands
cat >"$BIN/omarchy-plugin-list" <<'EOS'
#!/usr/bin/env bash
d="${HOME}/.config/omarchy/plugins"
out="[]"
if [[ -d "$d" ]]; then
  for m in "$d"/*/manifest.json; do
    [[ -f "$m" ]] || continue
    id="$(basename "$(dirname "$m")")"
    out="$(jq -n --argjson a "$out" --arg id "$id" \
      --arg n "$(jq -r '.name // .id' "$m")" --argjson k "$(jq -c '.kinds // []' "$m")" \
      --argjson en "$(jq -c '.enabled // true' "$m")" --argjson fp "$(jq -c '.firstParty // false' "$m")" \
      --arg cf "$(jq -r '.clonedFrom // ""' "$m")" \
      '$a + [{id:$id,name:$n,kinds:$k,enabled:$en,active:$en,canDisable:true,firstParty:$fp,clonedFrom:$cf}]')"
  done
fi
printf '%s\n' "$out"
EOS

cat >"$BIN/omarchy" <<'EOS'
#!/usr/bin/env bash
if [[ "${1:-}" == "plugin" ]]; then
  shift; sub="${1:-}"; shift || true
  case "$sub" in
    clone)
      src="${1:-}"; base="${src#omarchy.}"; user="${USER:-user}"
      dest="$HOME/.config/omarchy/plugins/${user}.${base}"
      mkdir -p "$dest"
      cp -r "/usr/share/omarchy/shell/plugins/${base}/." "$dest/"
      tmp="$(mktemp)"
      jq --arg cf "$src" '. + {firstParty:false, clonedFrom:$cf, enabled:true}' \
        "$dest/manifest.json" >"$tmp" && mv "$tmp" "$dest/manifest.json"
      ;;
    remove) rm -rf "$HOME/.config/omarchy/plugins/${1:-}" ;;
    validate) exit 0 ;;
    *) exit 0 ;;
  esac
fi
exit 0
EOS

# Model the running Omarchy shell's MOUNTED plugin set: a plugin only serves
# when mount-state names it (as the real shell mounts instances at boot/reload).
# shell rescanPlugins re-derives the mounted set from the enabled patched clones
# (exactly what the real reload does once every file is in place), and
# osd/notifications syncSuppression "succeed" only when the PATCHEd clone is
# serving — mirroring the real IPC (first-party plugins have no syncSuppression).
# Pre-seed mount-state at first-party so an install that forgets to bounce
# leaves popups served by the OLD code (the reported bug) and the fix must flip
# it.
cat >"$BIN/omarchy-shell" <<'EOS'
#!/usr/bin/env bash
d="$HOME/.config/omarchy/plugins"
st="$HOME/.local/state/omarchy/tide-island/mount-state"
mkdir -p "$(dirname "$st")"
if [[ ! -f $st ]]; then
  printf 'osd=omarchy.osd notifications=omarchy.notifications\n' >"$st"
fi
if [[ ${1:-} == shell && ${2:-} == rescanPlugins ]]; then
  osd_marker=0; notif_marker=0
  [[ -f "$d/mehir.osd/Osd.qml" ]] && grep -q 'The bar-off marker' "$d/mehir.osd/Osd.qml" && osd_marker=1
  [[ -f "$d/mehir.notifications/Service.qml" ]] && grep -q 'popupsSuppressed' "$d/mehir.notifications/Service.qml" && notif_marker=1
  printf 'osd=%s notifications=%s\n' \
    "$([[ $osd_marker == 1 ]] && echo mehir.osd || echo omarchy.osd)" \
    "$([[ $notif_marker == 1 ]] && echo mehir.notifications || echo omarchy.notifications)" >"$st"
  exit 0
fi
if [[ ${1:-} == osd && ${2:-} == syncSuppression ]]; then
  grep -qw 'osd=mehir.osd' "$st" && exit 0 || exit 1
fi
if [[ ${1:-} == notifications && ${2:-} == syncSuppression ]]; then
  grep -qw 'notifications=mehir.notifications' "$st" && exit 0 || exit 1
fi
exit 0
EOS

cat >"$BIN/systemctl" <<'EOS'
#!/usr/bin/env bash
state="$HOME/.local/state/omarchy/fake-systemd"
mode=""; name=""
for a in "$@"; do
  case "$a" in
    --user) ;;
    is-active|start|stop) mode="$a" ;;
    *) name="$a" ;;
  esac
done
case "$mode" in
  is-active) cat "$state/$name" 2>/dev/null || echo inactive ;;
  start) mkdir -p "$state"; echo active >"$state/$name" ;;
  stop)  mkdir -p "$state"; echo inactive >"$state/$name" ;;
esac
EOS
chmod +x "$BIN"/*

PLUGINS="$HOME/.config/omarchy/plugins"
STATE="$HOME/.local/state/omarchy/tide-island"
CONFIG="$HOME/.config/omarchy/tide-island.json"
TIDE_USERCONFIG="$HOME/.config/tide-island/userconfig.json"
FLAG="$HOME/.local/state/omarchy/toggles/bar-off"
svc() { cat "$HOME/.local/state/omarchy/fake-systemd/tide-island.service" 2>/dev/null || echo inactive; }
wait_marker() { # $1 = timeout seconds
  local end=$((SECONDS + ${1:-20}))
  while (( SECONDS < end )); do
    [[ -f "$STATE/auto-setup.done" ]] && return 0
    sleep 0.2
  done
  return 1
}

echo "tide-island clean-room lifecycle test ($SB)"
echo "  fresh install"
(cd "$ROOT" && bash install.sh) >"$SB/i1.log" 2>&1 && ok "install exits 0" || { ko "install failed"; tail -n20 "$SB/i1.log"; }
[[ -x "$HOME/.local/bin/omarchy-tide-island-toggle" && -x "$HOME/.local/bin/omarchy-tide-island-status" ]] && ok "CLI shims installed" || ko "CLI shims missing"
PREFIX="$HOME/.local/share/omarchy-tide-island"
[[ -x "$PREFIX/bin/tide-island" ]] && ok "bundled Tide Island runtime installed" || ko "bundled runtime missing"
[[ -x "$PREFIX/bin/tide-island-config-app" ]] && ok "settings GUI bundled" || ko "settings GUI missing"
[[ -f "$PREFIX/lib/libIslandBackend.so" ]] && ok "compiled backend vendored" || ko "backend lib missing"
[[ -L "$HOME/.local/bin/tide-island" ]] && ok "tide-island linked onto PATH" || ko "no PATH link"
[[ -L "$HOME/.local/bin/tide-island-config-app" ]] && ok "config app linked onto PATH" || ko "no config app PATH link"
[[ -f "$HOME/.config/systemd/user/tide-island.service" ]] \
  && grep -q 'managed by mehir.tide-island' "$HOME/.config/systemd/user/tide-island.service" \
  && ok "user service unit written" || ko "service unit missing"
[[ -f "$HOME/.local/share/applications/tide-island.desktop" ]] && ok "desktop entry installed" || ko "desktop entry missing"
[[ -f "$HOME/.local/share/applications/tide-island-config.desktop" ]] && ok "settings desktop entry installed" || ko "settings desktop entry missing"
[[ -f "$CONFIG" ]] && ok "config seeded" || ko "config not seeded"
[[ -f "$TIDE_USERCONFIG" ]] && cmp -s "$TIDE_USERCONFIG" "$ROOT/default/tide-userconfig.json" \
  && ok "Tide userconfig seeded with the default look" || ko "Tide userconfig not seeded"
jq -e '.tideUserConfig.seeded == true' "$STATE/installed.json" >/dev/null 2>&1 \
  && ok "installed.json records the Tide config seed" || ko "installed.json missing tideUserConfig"
grep -q 'The bar-off marker' "$PLUGINS/mehir.osd/Osd.qml" 2>/dev/null && ok "osd clone patched" || ko "osd clone not patched"
grep -q 'popupsSuppressed' "$PLUGINS/mehir.notifications/Service.qml" 2>/dev/null && ok "notifications clone patched" || ko "notifications clone not patched"
[[ "$(cat "$STATE/patch-state/mehir.osd" 2>/dev/null)" == applied ]] && ok "osd recorded 'applied'" || ko "osd state not recorded"
jq -e '.suppression.osd.createdByUs == true' "$STATE/installed.json" >/dev/null 2>&1 && ok "installed.json records createdByUs" || ko "installed.json missing createdByUs"
[[ "$(svc)" == inactive ]] && ok "bar visible at install -> service stopped" || ko "service $(svc)"

echo "  functionality"
mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
(cd "$ROOT" && bash scripts/tide-sync.sh reconcile) >/dev/null 2>&1
[[ "$(svc)" == active ]] && ok "bar-off flag starts the service" || ko "service not started ($(svc))"
rm -f "$FLAG"
(cd "$ROOT" && bash scripts/tide-sync.sh reconcile) >/dev/null 2>&1
[[ "$(svc)" == inactive ]] && ok "flag removed stops the service" || ko "service not stopped ($(svc))"

echo "  upgrade (re-run install.sh)"
b0=$(find "$STATE/backups" -type f 2>/dev/null | wc -l)
(cd "$ROOT" && bash install.sh) >"$SB/i2.log" 2>&1 && ok "second install exits 0" || { ko "second install failed"; tail -n20 "$SB/i2.log"; }
b1=$(find "$STATE/backups" -type f 2>/dev/null | wc -l)
[[ "$b0" == "$b1" ]] && ok "no duplicate backups on re-run" || ko "backups grew ($b0 -> $b1)"
[[ "$(find "$PLUGINS" -maxdepth 1 -name '*.osd' | wc -l)" == 1 ]] && ok "clone not duplicated" || ko "clone duplicated"
jq -e '.suppression.osd.createdByUs == true' "$STATE/installed.json" >/dev/null 2>&1 && ok "createdByUs preserved across re-run" || ko "createdByUs lost on re-run"
cmp -s "$TIDE_USERCONFIG" "$ROOT/default/tide-userconfig.json" && ok "seeded Tide config preserved on re-run" || ko "seeded Tide config changed on re-run"
[[ "$(cat "$PREFIX/.version" 2>/dev/null)" == "$(cat "$ROOT/vendor/tide-island/VERSION")" ]] && ok "runtime version marker intact after re-run" || ko "runtime version marker changed"

echo "  uninstall (default)"
(cd "$ROOT" && bash uninstall.sh) >"$SB/u1.log" 2>&1 && ok "uninstall exits 0" || { ko "uninstall failed"; tail -n20 "$SB/u1.log"; }
[[ ! -e "$HOME/.local/bin/omarchy-tide-island-toggle" ]] && ok "shim removed" || ko "shim remains"
[[ -f "$CONFIG" ]] && ok "config preserved by default" || ko "config removed by default"
[[ ! -f "$TIDE_USERCONFIG" ]] && ok "untouched seeded Tide config removed on uninstall" || ko "seeded Tide config remains"
grep -q 'The bar-off marker' "$PLUGINS/mehir.osd/Osd.qml" 2>/dev/null && ko "patch not reverted" || ok "clone patch reverted"

echo "  uninstall --remove-plugin --purge-config"
(cd "$ROOT" && bash uninstall.sh --remove-plugin --purge-config) >"$SB/u2.log" 2>&1 && ok "uninstall --remove-plugin exits 0" || { ko "failed"; tail -n20 "$SB/u2.log"; }
[[ ! -d "$PLUGINS/mehir.osd" ]] && ok "osd clone removed" || ko "osd clone not removed"
[[ ! -f "$CONFIG" ]] && ok "config purged" || ko "config not purged"

echo "  reinstall"
(cd "$ROOT" && bash install.sh) >"$SB/i3.log" 2>&1 && ok "reinstall exits 0" || { ko "reinstall failed"; tail -n20 "$SB/i3.log"; }
grep -q 'The bar-off marker' "$PLUGINS/mehir.osd/Osd.qml" 2>/dev/null && ok "reinstalled cleanly" || ko "reinstall incomplete"
[[ -f "$TIDE_USERCONFIG" ]] && ok "Tide config re-seeded on reinstall" || ko "Tide config not re-seeded"

echo "  customized Tide config survives uninstall"
echo '{ "islandWidth": 200 }' >"$TIDE_USERCONFIG"

echo "  uninstall --remove-runtime"
(cd "$ROOT" && bash uninstall.sh --remove-plugin --remove-runtime) >"$SB/u3.log" 2>&1 \
  && ok "uninstall --remove-runtime exits 0" || { ko "failed"; tail -n20 "$SB/u3.log"; }
[[ ! -e "$PREFIX" ]] && ok "bundled runtime removed" || ko "runtime not removed"
[[ ! -e "$HOME/.config/systemd/user/tide-island.service" ]] && ok "service unit removed" || ko "unit not removed"
for name in tide-island tide-island-config-app; do
  [[ ! -e "$HOME/.local/bin/$name" ]] && ok "$name PATH link removed" || ko "$name PATH link not removed"
done
[[ ! -f "$HOME/.local/share/applications/tide-island.desktop" \
  && ! -f "$HOME/.local/share/applications/tide-island-config.desktop" ]] \
  && ok "desktop entries removed" || ko "desktop entries remain"
[[ -f "$TIDE_USERCONFIG" ]] && grep -q 200 "$TIDE_USERCONFIG" \
  && ok "customized Tide config preserved on uninstall" || ko "customized Tide config deleted"

echo "  automatic reap when the plugin is removed via 'omarchy plugin remove'"
(cd "$ROOT" && bash install.sh) >"$SB/i4.log" 2>&1 && ok "reinstall before reap exits 0" || { ko "reinstall failed"; tail -n20 "$SB/i4.log"; }
HELPER="$HOME/.local/lib/omarchy-tide-island/teardown.sh"
[[ -f $HELPER ]] && ok "teardown helper installed outside the plugin dir" || ko "teardown helper missing"
mkdir -p "$PLUGINS/mehir.tide-island"
bash "$HELPER" --remove-clones --remove-runtime --purge-config --if-plugin-gone --final >"$SB/reap-guard.log" 2>&1
[[ -d "$PLUGINS/mehir.tide-island" ]] && ok "guard: plugin untouched while installed" || ko "guard removed the installed plugin"
[[ -d "$PLUGINS/mehir.osd" ]] && ok "guard: suppression clones untouched while installed" || ko "guard removed suppression clones"
[[ -d "$STATE" ]] && ok "guard: state untouched while installed" || ko "guard wiped state while installed"
omarchy plugin remove mehir.tide-island --yes >/dev/null 2>&1
[[ ! -d "$PLUGINS/mehir.tide-island" ]] && ok "plugin removed via omarchy" || ko "plugin not removed"
bash "$HELPER" --remove-clones --remove-runtime --purge-config --if-plugin-gone --final >"$SB/reap.log" 2>&1 \
  && ok "reap exits 0" || { ko "reap failed"; tail -n20 "$SB/reap.log"; }
[[ ! -e "$PLUGINS/mehir.osd" && ! -e "$PLUGINS/mehir.notifications" ]] \
  && ok "suppression clones removed by reap" || ko "suppression clones remain after reap"
grep -rq 'The bar-off marker' "$PLUGINS" 2>/dev/null \
  && ko "OSD suppression still active after reap" || ok "OSD suppression undone by reap"
grep -rq 'popupsSuppressed' "$PLUGINS" 2>/dev/null \
  && ko "notification suppression still active after reap" || ok "notification suppression undone by reap"
[[ ! -e "$CONFIG" ]] && ok "config purged by reap" || ko "config remains after reap"
[[ ! -e "$PREFIX" ]] && ok "runtime removed by reap" || ko "runtime remains after reap"
[[ ! -e "$STATE" ]] && ok "state removed by reap" || ko "state remains after reap"
[[ ! -e "$HOME/.local/lib/omarchy-tide-island" ]] && ok "teardown helper cleaned up" || ko "helper remains"
[[ -f "$TIDE_USERCONFIG" ]] && grep -q 200 "$TIDE_USERCONFIG" \
  && ok "customized Tide config survives the reap too" || ko "reap deleted a customized Tide config"

echo "  reap still cleans suppression when the recorded state is gone"
(cd "$ROOT" && bash install.sh) >"$SB/i5.log" 2>&1 && ok "reinstall before state-less reap exits 0" || { ko "reinstall failed"; tail -n20 "$SB/i5.log"; }
rm -f "$STATE/installed.json"
rm -rf "$STATE/patch-state"
mkdir -p "$PLUGINS/mehir.tide-island"
omarchy plugin remove mehir.tide-island --yes >/dev/null 2>&1
bash "$HOME/.local/lib/omarchy-tide-island/teardown.sh" --remove-clones --remove-runtime --purge-config --if-plugin-gone --final >"$SB/reap2.log" 2>&1 \
  && ok "state-less reap exits 0" || { ko "reap failed"; tail -n20 "$SB/reap2.log"; }
[[ ! -e "$PLUGINS/mehir.osd" && ! -e "$PLUGINS/mehir.notifications" ]] \
  && ok "clones removed even without installed.json" || ko "clones survived the state-less reap"
grep -rq 'The bar-off marker\|popupsSuppressed' "$PLUGINS" 2>/dev/null \
  && ko "suppression survived the state-less reap" || ok "suppression fully undone without state"
[[ ! -e "$STATE" && ! -e "$HOME/.local/lib/omarchy-tide-island" ]] \
  && ok "state + helper reclaimed by state-less reap" || ko "reap leftovers remain"

echo "  removal without --final clears the setup marker so a re-add sets up again"
(cd "$ROOT" && bash install.sh) >"$SB/i7.log" 2>&1 && ok "install before marker-clear test exits 0" || { ko "install failed"; tail -n20 "$SB/i7.log"; }
if wait_marker 30; then
  ok "setup marker written after install"
else
  ko "no setup marker after install"
fi
mkdir -p "$PLUGINS/mehir.tide-island"
rm -rf "$PLUGINS/mehir.tide-island" # simulate the plugin directory being removed
bash "$HELPER" --remove-clones --if-plugin-gone >"$SB/reap3.log" 2>&1 \
  && ok "teardown without --final exits 0" || { ko "teardown failed"; tail -n20 "$SB/reap3.log"; }
[[ ! -f "$STATE/auto-setup.done" ]] \
  && ok "setup marker cleared on removal (a re-add will set up again)" || ko "stale marker would skip setup on re-add"
[[ -d "$STATE" ]] && ok "state (backups) retained when --final is not passed" || ko "state wrongly wiped without --final"

echo "  mount-verify self-heals an install whose runtime served the old code (problem 1)"
# The reported bug: clones are patched on disk and enabled in config, but the
# RUNNING shell still serves the unpatched first-party OSD/notifications (its
# plugin watch reloaded while the patch was still being applied). On this model
# mount-state says omarchy.*; the on-disk markers say suppressed. Install must
# detect the gap through the runtime IPC and bounce the mounted set, then only
# mark setup complete.
mkdir -p "$STATE"
printf 'osd=omarchy.osd notifications=omarchy.notifications\n' >"$STATE/mount-state"
rm -f "$STATE/auto-setup.done"
if omarchy-shell osd syncSuppression >/dev/null 2>&1; then
  ko "pre-check: osd runtime reported suppressed before the bounce"
else
  ok "pre-check: osd runtime is the unpatched build (bug modelled)"
fi
(cd "$ROOT" && bash install.sh) >"$SB/i6.log" 2>&1 && ok "install exits 0" || { ko "install failed"; tail -n20 "$SB/i6.log"; }
if wait_marker 30; then
  ok "setup marker written only once the patched clones serve"
else
  ko "setup marker never written (mount-verify did not fix the runtime)"
fi
grep -qw 'osd=mehir.osd' "$STATE/mount-state" && ok "osd runtime switched to the patched clone" || ko "osd runtime still unpatched"
grep -qw 'notifications=mehir.notifications' "$STATE/mount-state" && ok "notifications runtime switched to the patched clone" || ko "notifications runtime still unpatched"
grep -Eq 'serving at runtime|no bounce needed' "$STATE/ensure-mount.log" 2>/dev/null && ok "mount-verify logged the successful outcome" || ko "no mount-verify log"

echo "  ensure-mount.sh repairs a runtime stuck at first-party without a reinstall"
printf 'osd=omarchy.osd notifications=omarchy.notifications\n' >"$STATE/mount-state"
rm -f "$STATE/auto-setup.done"
TMP_MARKER="$SB/mount-ok.marker"
(cd "$ROOT" && bash scripts/ensure-mount.sh --marker "$TMP_MARKER") >"$SB/mount-ok.log" 2>&1 \
  && ok "ensure-mount exits 0" || { ko "ensure-mount failed"; cat "$SB/mount-ok.log"; }
[[ -f "$TMP_MARKER" ]] && ok "ensure-mount wrote the marker on success" || ko "marker not written on success"
grep -qw 'osd=mehir.osd' "$STATE/mount-state" && ok "osd repaired to the patched clone" || ko "osd not repaired"

echo "  ensure-mount.sh fails loudly and markerless when the patched clone cannot serve"
printf 'osd=omarchy.osd notifications=omarchy.notifications\n' >"$STATE/mount-state"
rm -f "$STATE/auto-setup.done" "$TMP_MARKER"
cp "$PLUGINS/mehir.osd/Osd.qml" "$SB/osd.backup.qml"
sed -i '/The bar-off marker/d' "$PLUGINS/mehir.osd/Osd.qml"
if (cd "$ROOT" && bash scripts/ensure-mount.sh --marker "$TMP_MARKER") >"$SB/mount-fail.log" 2>&1; then
  ko "ensure-mount reported success with an unpatchable OSD"
else
  ok "ensure-mount fails loudly when the patched clone cannot serve"
fi
[[ -f "$TMP_MARKER" ]] && ko "marker written despite failure" || ok "no marker on failure"
grep -q 'FAILED' "$STATE/ensure-mount.log" 2>/dev/null && ok "failure state logged for diagnosis" || ko "no failure log"
mv "$SB/osd.backup.qml" "$PLUGINS/mehir.osd/Osd.qml"

echo "  island keybindings wired into hyprland.lua at install"
HYPRLUA="$HOME/.config/hypr/hyprland.lua"
mkdir -p "$HOME/.config/hypr"
cat >"$HYPRLUA" <<'LUA'
-- user config
hl.config({})
for i = 1, 10 do
  hl.workspace(i)
end
LUA
PREFIX="$HOME/.local/share/omarchy-tide-island"

(cd "$ROOT" && bash install.sh) >"$SB/k1.log" 2>&1 && ok "install with hyprland.lua exits 0" || { ko "install failed"; tail -n20 "$SB/k1.log"; }
grep -q -- '-- Tide Island shortcuts: begin (managed by Tide Island Config App).' "$HYPRLUA" \
  && ok "install writes the managed shortcut block" || ko "no shortcut block written"
[[ "$(grep -c 'begin (managed' "$HYPRLUA")" == 1 ]] && ok "block written exactly once" || ko "block duplicated"
[[ "$(grep -c 'hl\.bind(' "$HYPRLUA")" == 13 ]] && ok "all 13 island bindings present" || ko "expected 13 bindings, found $(grep -c 'hl\.bind(' "$HYPRLUA")"
grep -q 'call island toggle' "$HYPRLUA" && ok "island toggle binding present" || ko "island toggle binding missing"
grep -q -- "$PREFIX/share/tide-island call tide swipeLeft" "$HYPRLUA" \
  && ok "bindings point at the installed QML runtime" || ko "bindings use the wrong QML path"
grep -q 'hl.workspace' "$HYPRLUA" && ok "pre-existing hyprland.lua content preserved" || ko "existing content lost"
jq -e '.shortcutBinding.createdByUs == true and .shortcutBinding.wired == true' "$STATE/installed.json" >/dev/null 2>&1 \
  && ok "installed.json records the shortcut block" || ko "installed.json missing shortcutBinding"

echo "  repeated install keeps a single block"
(cd "$ROOT" && bash install.sh) >"$SB/k2.log" 2>&1 && ok "repeat install exits 0" || ko "repeat install failed"
if [[ "$(grep -c 'begin (managed' "$HYPRLUA")" == 1 && "$(grep -c 'hl\.bind(' "$HYPRLUA")" == 13 ]]; then
  ok "repeat install leaves exactly one block"
else
  ko "repeat install changed the block"
fi

echo "  uninstall removes a block it created, preserving other content"
(cd "$ROOT" && bash uninstall.sh) >"$SB/k3.log" 2>&1 && ok "uninstall exits 0" || { ko "uninstall failed"; tail -n20 "$SB/k3.log"; }
grep -q -- '-- Tide Island shortcuts: begin' "$HYPRLUA" && ko "uninstall left our block behind" || ok "uninstall removed our block"
grep -q 'hl.workspace' "$HYPRLUA" && ok "uninstall preserved unrelated hyprland.lua content" || ko "uninstall damaged hyprland.lua"

echo "  settings-app edit survives install and uninstall"
(cd "$ROOT" && bash install.sh) >"$SB/k4.log" 2>&1 && ok "reinstall exits 0" || ko "reinstall failed"
sed -i 's/SUPER + ALT + I/SUPER + ALT + L/' "$HYPRLUA"
ed_sha="$(sha256sum "$HYPRLUA" | awk '{print $1}')"
(cd "$ROOT" && bash install.sh) >"$SB/k5.log" 2>&1 && ok "install after an app edit exits 0" || ko "install failed"
[[ "$(sha256sum "$HYPRLUA" | awk '{print $1}')" == "$ed_sha" ]] \
  && ok "install never rewrites an existing (app-edited) block" || ko "install clobbered the edited block"
(cd "$ROOT" && bash uninstall.sh) >"$SB/k6.log" 2>&1 && ok "uninstall after an app edit exits 0" || ko "uninstall failed"
grep -q 'SUPER + ALT + L' "$HYPRLUA" && ok "uninstall preserves an app-edited block" || ko "uninstall removed the edited block"

echo "  a block that predates the plugin is never claimed or removed"
rm -f "$STATE/installed.json"
cat >"$HYPRLUA" <<'LUA'
hl.config({})
LUA
printf '%s\nhl.bind("SUPER + X", do_thing)\n%s\n' \
  '-- Tide Island shortcuts: begin (managed by Tide Island Config App).' \
  '-- Tide Island shortcuts: end.' >>"$HYPRLUA"
(cd "$ROOT" && bash install.sh) >"$SB/k7.log" 2>&1 && ok "install over a foreign block exits 0" || ko "install failed"
jq -e '.shortcutBinding.createdByUs == false' "$STATE/installed.json" >/dev/null 2>&1 \
  && ok "install does not claim a block that predated the plugin" || ko "install wrongly claimed the foreign block"
[[ "$(grep -c 'begin (managed' "$HYPRLUA")" == 1 ]] && ok "install did not append a second block" || ko "install duplicated the foreign block"
(cd "$ROOT" && bash uninstall.sh) >"$SB/k8.log" 2>&1 && ok "uninstall over a foreign block exits 0" || ko "uninstall failed"
grep -q 'SUPER + X' "$HYPRLUA" && ok "uninstall leaves a foreign block untouched" || ko "uninstall removed a foreign block"

echo "  --no-shortcuts leaves hyprland.lua without a block"
cat >"$HYPRLUA" <<'LUA'
hl.config({})
LUA
(cd "$ROOT" && bash install.sh --no-shortcuts) >"$SB/k9.log" 2>&1 && ok "install --no-shortcuts exits 0" || ko "install --no-shortcuts failed"
grep -q -- '-- Tide Island shortcuts: begin' "$HYPRLUA" && ko "--no-shortcuts still wrote a block" || ok "--no-shortcuts wrote no block"

echo "  a managed block pointing at a missing runtime is repaired, not preserved"
rm -f "$STATE/installed.json"
cat >"$HYPRLUA" <<'LUA'
hl.config({})
LUA
{
  printf '%s\n' '-- Tide Island shortcuts: begin (managed by Tide Island Config App).'
  printf '%s\n' 'hl.bind("SUPER + T", hl.dsp.exec_cmd("/usr/bin/quickshell ipc --any-display -p /usr/share/tide-island call tide showTimer"))'
  printf '%s\n' '-- Tide Island shortcuts: end.'
} >>"$HYPRLUA"
(cd "$ROOT" && bash install.sh) >"$SB/k10.log" 2>&1 && ok "install over a dead-runtime block exits 0" || { ko "install failed"; tail -n20 "$SB/k10.log"; }
grep -q -- "$PREFIX/share/tide-island call tide" "$HYPRLUA" && ok "dead block repaired to the bundled runtime" || ko "block not repaired to the bundled runtime"
grep -q '/usr/share/tide-island call' "$HYPRLUA" && ko "stale runtime path survived the repair" || ok "stale runtime path removed"
[[ "$(grep -c 'begin (managed' "$HYPRLUA")" == 1 ]] && ok "repair leaves a single block" || ko "repair duplicated the block"
[[ "$(grep -c 'hl\.bind(' "$HYPRLUA")" == 13 ]] && ok "repaired block carries all 13 bindings" || ko "repaired block has $(grep -c 'hl\.bind(' "$HYPRLUA") bindings"
jq -e '.shortcutBinding.createdByUs == true' "$STATE/installed.json" >/dev/null 2>&1 && ok "repaired block is now claimed by the plugin" || ko "repair did not claim the block"
grep -q 'hl.workspace\|hl.config' "$HYPRLUA" && ok "repair preserved unrelated hyprland.lua content" || ko "repair damaged hyprland.lua"

echo "  unrelated user keybindings survive install, repeat install and uninstall"
mkdir -p "$HOME/.config/hypr"
cat >"$HOME/.config/hypr/bindings.lua" <<'LUA'
-- my own binding, must never be touched by the plugin
o.bind("SUPER + SHIFT + Q", "my thing", "my-command")
LUA
cp "$HOME/.config/hypr/bindings.lua" "$SB/bindings.before"
cat >"$HYPRLUA" <<'LUA'
hl.config({})
LUA
(cd "$ROOT" && bash install.sh) >"$SB/k10.log" 2>&1 && ok "install with a user bindings.lua exits 0" || { ko "install failed"; tail -n20 "$SB/k10.log"; }
cmp -s "$HOME/.config/hypr/bindings.lua" "$SB/bindings.before" \
  && ok "install leaves an unrelated user bindings.lua byte-for-byte" || ko "install modified the user's bindings.lua"
(cd "$ROOT" && bash install.sh) >"$SB/k11.log" 2>&1 && ok "repeat install exits 0" || ko "repeat install failed"
cmp -s "$HOME/.config/hypr/bindings.lua" "$SB/bindings.before" \
  && ok "repeat install still leaves the user bindings.lua untouched" || ko "repeat install modified bindings.lua"
(cd "$ROOT" && bash uninstall.sh) >"$SB/k12.log" 2>&1 && ok "uninstall exits 0" || ko "uninstall failed"
cmp -s "$HOME/.config/hypr/bindings.lua" "$SB/bindings.before" \
  && ok "uninstall leaves the user bindings.lua untouched" || ko "uninstall modified bindings.lua"
grep -q 'SUPER + SHIFT + Q' "$HOME/.config/hypr/bindings.lua" && ok "the user binding is still present" || ko "the user binding disappeared"

echo "  an existing customized Tide config is never overwritten by install"
mkdir -p "$(dirname "$TIDE_USERCONFIG")"
cat >"$TIDE_USERCONFIG" <<'JSON'
{ "islandWidth": 321, "shortcutBindings": [ { "mods": "SUPER ALT", "key": "Z", "target": "tide", "method": "showClock" } ] }
JSON
cp "$TIDE_USERCONFIG" "$SB/userconfig.before"
(cd "$ROOT" && bash install.sh) >"$SB/k13.log" 2>&1 && ok "install over a customized Tide config exits 0" || { ko "install failed"; tail -n20 "$SB/k13.log"; }
cmp -s "$TIDE_USERCONFIG" "$SB/userconfig.before" \
  && ok "install leaves the customized Tide config byte-for-byte" || ko "install overwrote the user's Tide config"
jq -e '.tideUserConfig.seeded == false' "$STATE/installed.json" >/dev/null 2>&1 \
  && ok "installed.json records that no seed was forced over the user's config" || ko "install wrongly recorded a Tide config seed"

echo
echo "cleanroom: $pass passed, $fail failed"
(( fail == 0 ))
