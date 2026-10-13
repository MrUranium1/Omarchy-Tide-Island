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

printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/omarchy-shell"

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
FLAG="$HOME/.local/state/omarchy/toggles/bar-off"
svc() { cat "$HOME/.local/state/omarchy/fake-systemd/tide-island.service" 2>/dev/null || echo inactive; }

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
[[ "$(cat "$PREFIX/.version" 2>/dev/null)" == "$(cat "$ROOT/vendor/tide-island/VERSION")" ]] && ok "runtime version marker intact after re-run" || ko "runtime version marker changed"

echo "  uninstall (default)"
(cd "$ROOT" && bash uninstall.sh) >"$SB/u1.log" 2>&1 && ok "uninstall exits 0" || { ko "uninstall failed"; tail -n20 "$SB/u1.log"; }
[[ ! -e "$HOME/.local/bin/omarchy-tide-island-toggle" ]] && ok "shim removed" || ko "shim remains"
[[ -f "$CONFIG" ]] && ok "config preserved by default" || ko "config removed by default"
grep -q 'The bar-off marker' "$PLUGINS/mehir.osd/Osd.qml" 2>/dev/null && ko "patch not reverted" || ok "clone patch reverted"

echo "  uninstall --remove-plugin --purge-config"
(cd "$ROOT" && bash uninstall.sh --remove-plugin --purge-config) >"$SB/u2.log" 2>&1 && ok "uninstall --remove-plugin exits 0" || { ko "failed"; tail -n20 "$SB/u2.log"; }
[[ ! -d "$PLUGINS/mehir.osd" ]] && ok "osd clone removed" || ko "osd clone not removed"
[[ ! -f "$CONFIG" ]] && ok "config purged" || ko "config not purged"

echo "  reinstall"
(cd "$ROOT" && bash install.sh) >"$SB/i3.log" 2>&1 && ok "reinstall exits 0" || { ko "reinstall failed"; tail -n20 "$SB/i3.log"; }
grep -q 'The bar-off marker' "$PLUGINS/mehir.osd/Osd.qml" 2>/dev/null && ok "reinstalled cleanly" || ko "reinstall incomplete"

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

echo
echo "cleanroom: $pass passed, $fail failed"
(( fail == 0 ))
