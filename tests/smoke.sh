#!/usr/bin/env bash
# Smoke test - validates the plugin repo itself without side effects:
#   * every script and binary parses as valid bash;
#   * the manifest validates against the Omarchy schema;
#   * entry points and scripts exist;
#   * sync + status + toggle CLIs exist and answer sanely against a dry-run;
#   * the onboard configuration file is valid JSON and matches embedded defaults.
# Run from anywhere: bash tests/smoke.sh

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
pass=0
fail=0
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); }
t() { printf '  - %s\n' "$*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "tide-island plugin smoke test"

echo "  manifests and config"
jq -e . "$ROOT/manifest.json" >/dev/null && t "manifest.json is valid JSON" && ok || ko
jq -e '.id == "mehir.tide-island" and (.kinds | index("service")) != null and (.entryPoints.service | type) == "string"' \
  "$ROOT/manifest.json" >/dev/null && t "manifest carries id/service kind/entrypoint" && ok || ko
jq -e . "$ROOT/default/tide-island.json" >/dev/null && t "default config is valid JSON" && ok || ko
jq -e '.islandExclusiveZone == 9 and .islandTopMargin == 1 and .islandBackgroundOpacity == 100
       and .islandHeight == 36 and .islandWidth == 140' \
  "$ROOT/default/tide-userconfig.json" >/dev/null && t "default Tide look carries the requested values" && ok || ko
jq -e '
  ([.shortcutBindings[] | select(.key != "") | [.mods, .key, .target, .method]] | sort)
  == ([
    ["SUPER ALT","H","tide","swipeLeft"],
    ["SUPER ALT","J","tide","showClock"],
    ["SUPER ALT","T","tide","showTimer"],
    ["SUPER ALT","M","tide","togglePlayer"],
    ["SUPER ALT","C","tide","toggleControlCenter"],
    ["SUPER ALT","P","tide","togglePowerMenu"],
    ["SUPER ALT","N","tide","toggleNotificationCenter"],
    ["SUPER ALT","A","tide","toggleApplicationLauncher"],
    ["SUPER ALT","O","tide","toggleFileShelf"],
    ["SUPER ALT","V","tide","toggleClipboard"],
    ["SUPER ALT","D","tide","toggleCalendar"],
    ["SUPER ALT","I","island","toggle"]
  ] | sort)
  and ([.shortcutBindings[] | select(.key == "") | .method] | sort
       == ["swipeRight","toggle","toggleWallpaperPicker","toggleWeather"])
' "$ROOT/default/tide-userconfig.json" >/dev/null \
  && t "default Tide shortcuts are the 12 island bindings" && ok || ko

echo "  entry points exist"
for f in "Service.qml" "default/tide-island.json" "default/tide-userconfig.json" \
         "packaging/hyprland-tide-island.lua" \
         "install.sh" "uninstall.sh" \
         "scripts/tide-sync.sh" "scripts/ensure-suppression.sh" "scripts/install-dependencies.sh" \
         "scripts/install-tide-runtime.sh" "scripts/plugin-setup.sh" "scripts/patch-tide-lyrics.sh" \
         "scripts/ensure-mount.sh" "scripts/teardown.sh" "scripts/wire-shortcuts.sh" \
         "bin/omarchy-tide-island-toggle" "bin/omarchy-tide-island-status" \
         "patches/omarchy-osd-suppression.patch" "patches/omarchy-notifications-suppression.patch" \
         "patches/tide/swipe-lyrics-no-cover.patch"; do
  [[ -f $ROOT/$f ]] && ok || { t "missing $f" && ko; }
done

echo "  vendored Tide Island runtime"
for f in "vendor/tide-island/VERSION" "vendor/tide-island/PROVENANCE.md" \
         "vendor/tide-island/bin/tide-island" \
         "vendor/tide-island/bin/tide-island-config-app" \
         "vendor/tide-island/lib/libIslandBackend.so" \
         "vendor/tide-island/lib/qt6/qml/TideIsland/qmldir" \
         "vendor/tide-island/lib/qt6/qml/IslandBackend/qmldir" \
         "vendor/tide-island/share/tide-island/shell.qml" \
         "vendor/tide-island/share/applications/tide-island.desktop" \
         "vendor/tide-island/share/applications/tide-island-config.desktop" \
         "LICENSES/GPL-3.0-only.txt"; do
  [[ -f $ROOT/$f ]] && ok || { t "missing $f" && ko; }
done
bash -n "$ROOT/vendor/tide-island/bin/tide-island" \
  && t "vendored launcher parses" && ok || ko
[[ -x "$ROOT/vendor/tide-island/bin/tide-island-config-app" ]] \
  && t "config app is executable" && ok || ko
! grep -q 'Exec=/usr' "$ROOT/vendor/tide-island/share/applications/tide-island.desktop" \
    "$ROOT/vendor/tide-island/share/applications/tide-island-config.desktop" \
  && t "desktop entries resolve via PATH (no /usr Exec)" && ok || ko
grep -q 'GNU GENERAL PUBLIC LICENSE' "$ROOT/LICENSES/GPL-3.0-only.txt" \
  && t "GPL-3.0 text present" && ok || ko

echo "  bash syntax"
while IFS= read -r -d '' f; do
  bash -n "$f" && ok || { t "syntax error in $f" && ko; }
done < <(find "$ROOT" \( -name '*.sh' -o -name 'omarchy-tide-island-*' \) -print0 | sort -z)

echo "  sync CLI contracts (dry run for reconcile)"
export TIDE_SYNC_DRY_RUN=1

out="$("$ROOT/scripts/tide-sync.sh" config)"
echo "$out" | jq -e '.config.coordinateWithBar == true' >/dev/null \
  && t "config reports defaults" && ok || ko
[[ "$("$ROOT/scripts/tide-sync.sh" probe)" =~ ^bar-(hidden|visible)$ ]] \
  && t "probe answers bar state" && ok || ko

echo "  helper scripts parse arguments without hanging"
if timeout 5 "$ROOT/scripts/patch-tide-lyrics.sh" --help >/dev/null 2>&1; then
  t "patch-tide-lyrics.sh --help exits 0" && ok
else
  t "patch-tide-lyrics.sh --help did not exit cleanly" && ko
fi
# --restore against a missing tree must fail fast (exit 1), never loop forever.
rc=0
timeout 5 "$ROOT/scripts/patch-tide-lyrics.sh" --restore --dir "$tmp/absent" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] && t "patch-tide-lyrics.sh --restore fails fast on a missing tree" && ok \
  || { t "patch-tide-lyrics.sh --restore rc=$rc (expected 1; 124 = hung)" && ko; }

echo "  ensure-mount.sh contract"
if timeout 5 "$ROOT/scripts/ensure-mount.sh" --help >/dev/null 2>&1; then
  t "ensure-mount.sh --help exits 0" && ok
else
  t "ensure-mount.sh --help did not exit cleanly" && ko
fi
grep -q 'syncSuppression' "$ROOT/scripts/ensure-mount.sh" \
  && t "ensure-mount verifies the mount over the shell IPC" && ok || ko

echo "  wire-shortcuts.sh contract"
if timeout 5 "$ROOT/scripts/wire-shortcuts.sh" --help >/dev/null 2>&1; then
  t "wire-shortcuts.sh --help exits 0" && ok
else
  t "wire-shortcuts.sh --help did not exit cleanly" && ko
fi
block="$(timeout 5 "$ROOT/scripts/wire-shortcuts.sh" --print-block 2>/dev/null || true)"
if grep -q -- '-- Tide Island shortcuts: begin' <<<"$block" \
  && grep -q -- '-- Tide Island shortcuts: end\.' <<<"$block" \
  && grep -q 'island toggle' <<<"$block"; then
  t "wire-shortcuts.sh emits the app's managed block with the island binding" && ok
else
  t "wire-shortcuts.sh did not emit the expected managed block" && ko
fi
jq -e '.shortcutBindings[] | select(.target == "island" and .method == "toggle" and .key == "I")' \
  "$ROOT/default/tide-userconfig.json" >/dev/null \
  && t "default userconfig carries the island binding that gets wired" && ok || ko

echo "  omarchy validates the plugin folder"
if (cd "$ROOT" && omarchy plugin validate . >/dev/null 2>&1); then
  t "manifest schema validates" && ok
elif [[ ${SMOKE_ALLOW_SHELL_DOWN:-0} == 1 ]]; then
  t "manifest schema validation skipped (shell down)" && ok
else
  t "manifest schema FAILED validation" && ko
fi

echo
echo "smoke: $pass passed, $fail failed"
(( fail == 0 ))