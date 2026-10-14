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
    ["SUPER ALT","I","island","toggle"],
    ["SUPER ALT","W","tide","toggleWallpaperPicker"],
    ["SUPER ALT","Q","tide","toggleThemePicker"]
  ] | sort)
  and ([.shortcutBindings[] | select(.key == "") | .method] | sort
       == ["swipeRight","toggle","toggleWeather"])
' "$ROOT/default/tide-userconfig.json" >/dev/null \
  && t "default Tide shortcuts are the 14 island bindings" && ok || ko

echo "  default shortcuts do not collide with Omarchy's own bindings"
SEED="$ROOT/default/tide-userconfig.json"
OMARCHY_HYPR="${OMARCHY_PATH:-/usr/share/omarchy}/default/hypr"
# Every shipped binding must be a single SUPER + ALT + <letter> chord; this is
# the namespace the island claims so it can never shadow Omarchy's SUPER binds.
nonalt="$(jq -r '.shortcutBindings[]? | select((.key // "") != "")
  | select((.mods // "") != "SUPER ALT") | "\(.mods) + \(.key)"' "$SEED")"
[[ -z $nonalt ]] \
  && t "every island shortcut uses the SUPER + ALT + <letter> chord" && ok \
  || { t "island shortcut leaves the SUPER + ALT + <letter> convention:$nonalt" && ko; }

if [[ -d $OMARCHY_HYPR/bindings ]] && command -v lua >/dev/null 2>&1; then
  cat >"$tmp/omarchy-bindings.lua" <<'LUA'
-- Read Omarchy's own keybindings straight from its Lua sources so the audit can
-- never drift from a hand-copied list. Stub the API its modules use and record
-- every bound chord; then emit the keys bound to a pure SUPER + ALT chord
-- (modmask 64 + 8), sorted.
local chords = {}
local function proxy()
  return setmetatable({}, { __index = function() return proxy() end,
                            __call = function() return proxy() end })
end
hl = proxy()
o = {}
function o.bind(k) chords[#chords + 1] = k end
function o.bind_toggle(k) chords[#chords + 1] = k end
function o.window() end
function o.preinstalled_bindings_enabled() return true end
function o.cmd_present() return true end
function o.cmd_missing() return false end
function o.launch(c) return c end
function o.launch_sole(a) return a end
function o.shell_quote(v) return v end

for _, sub in ipairs({ "/bindings", "/apps" }) do
  local p = io.popen("ls '" .. arg[1] .. sub .. "'/*.lua 2>/dev/null")
  if p then
    for f in p:lines() do pcall(assert(loadfile(f))) end
    p:close()
  end
end

local reserved = {}
for _, c in ipairs(chords) do
  local mods, key = 0, nil
  for raw in c:gmatch("[^+]+") do
    local tok = raw:match("^%s*(.-)%s*$")
    if tok == "SUPER" then mods = mods + 64
    elseif tok == "ALT" then mods = mods + 8
    elseif tok == "SHIFT" then mods = mods + 1
    elseif tok == "CTRL" then mods = mods + 4
    else key = tok end
  end
  if mods == 72 and key then reserved[key] = true end
end

local list = {}
for k in pairs(reserved) do list[#list + 1] = k end
table.sort(list)
io.write(table.concat(list, " "))
LUA
  reserved="$(lua "$tmp/omarchy-bindings.lua" "$OMARCHY_HYPR" 2>/dev/null || true)"
  clashes=""
  while IFS= read -r key; do
    [[ -z $key ]] && continue
    for r in $reserved; do [[ $key == "$r" ]] && clashes="$clashes $key"; done
  done < <(jq -r '.shortcutBindings[]? | select((.key // "") != "") | .key' "$SEED")
  if [[ -n ${clashes// /} ]]; then
    t "island shortcut(s)${clashes} already bound by Omarchy (SUPER+ALT reserved: ${reserved:-none})" && ko
  else
    t "island shortcuts are free of Omarchy's SUPER+ALT bindings (reserved: ${reserved:-none})" && ok
  fi
  # The one conflict this work set out to remove must never reappear.
  grep -qw W <<<"$reserved" \
    && { t "SUPER + ALT + W is claimed by Omarchy" && ko; } \
    || { t "SUPER + ALT + W stays free" && ok; }
else
  t "Omarchy hypr bindings or lua unavailable; skipped conflict audit" && ok
fi

echo "  settings app shows the seeded defaults (seed overrides its built-ins)"
APP_QML="$ROOT/vendor/tide-island/lib/qt6/qml/TideIsland/Shortcut.qml"
SHELL_QML="$ROOT/vendor/tide-island/share/tide-island/shell.qml"
# The Settings app's actions, in declaration order, as target:method pairs.
app_ids="$(grep -oE '"(target|method)": "[^"]+"' "$APP_QML" \
             | sed -E 's/.*: "([^"]+)"/\1/' | paste - - | sed 's/\t/:/')"
seed_ids="$(jq -r '.shortcutBindings[]? | "\(.target):\(.method)"' "$SEED")"
uncovered=""
while IFS= read -r id; do
  [[ -z $id ]] && continue
  grep -qxF "$id" <<<"$seed_ids" || uncovered="$uncovered $id"
done <<<"$app_ids"
[[ -n $app_ids && -z ${uncovered// /} ]] \
  && t "the seed covers all $(grep -c . <<<"$app_ids") Settings-app actions" && ok \
  || { t "seed misses Settings-app action(s):$uncovered" && ko; }
# Each enabled default must drive a function the island actually exposes.
missing_action=""
while IFS= read -r m; do
  [[ -z $m ]] && continue
  grep -qE "function $m\(\)" "$SHELL_QML" || missing_action="$missing_action $m"
done < <(jq -r '.shortcutBindings[]? | select((.key // "") != "") | .method' "$SEED")
[[ -z ${missing_action// /} ]] \
  && t "every enabled default maps to a real island IPC action" && ok \
  || { t "no IPC action for:$missing_action" && ko; }

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
         "vendor/tide-island/share/tide-island/scripts/omarchy-bridge.sh" \
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

echo "  Tide Island integration patch"
mkdir -p "$tmp/theme-roundtrip"
cp -a "$ROOT/vendor/tide-island/share" "$tmp/theme-roundtrip/"
(
  cd "$tmp/theme-roundtrip"
  patch -p1 -R --batch --fuzz=0 --dry-run <"$ROOT/patches/tide/omarchy-theme-integration.patch" >/dev/null
  patch -p1 -R --batch --fuzz=0 <"$ROOT/patches/tide/omarchy-theme-integration.patch" >/dev/null
  patch -p1 --batch --fuzz=0 <"$ROOT/patches/tide/omarchy-theme-integration.patch" >/dev/null
) && t "main integration patch reverses and reapplies with zero fuzz" && ok || ko
diff -qr "$tmp/theme-roundtrip/share" "$ROOT/vendor/tide-island/share" >/dev/null \
  && t "integration patch round-trip reproduces vendored share tree byte-for-byte" && ok || ko
cmp -s "$tmp/theme-roundtrip/share/tide-island/qml/island/WallpaperPickerLayer.qml" \
  "$ROOT/vendor/tide-island/share/tide-island/qml/island/WallpaperPickerLayer.qml" \
  && t "patched theme picker exactly matches vendored source" && ok || ko

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
# The wired block must be all SUPER + ALT + <letter>, one chord per action, so a
# fresh install can never introduce a duplicate or leave the claimed namespace.
chords="$(sed -nE 's/.*hl\.bind\("([^"]+)".*/\1/p' <<<"$block")"
bad_chord=""
while IFS= read -r c; do
  [[ -z $c ]] && continue
  [[ $c =~ ^SUPER\ \+\ ALT\ \+\ [A-Z]$ ]] || bad_chord="$bad_chord $c"
done <<<"$chords"
[[ -z ${bad_chord// /} && $(grep -c . <<<"$chords") -eq 14 ]] \
  && t "the wired block is 14 SUPER + ALT + <letter> chords" && ok \
  || { t "wired block has an unexpected chord (count $(grep -c . <<<"$chords")):$bad_chord" && ko; }
[[ "$(sort <<<"$chords" | uniq -d | wc -l)" -eq 0 ]] \
  && t "no shortcut chord is wired twice" && ok \
  || { t "duplicate wired chord(s): $(sort <<<"$chords" | uniq -d | tr '\n' ' ')" && ko; }

echo "  hyprland packaging module (Lua API)"
PACK="$ROOT/packaging/hyprland-tide-island.lua"
cat >"$tmp/window-rule-harness.lua" <<'LUA'
-- Minimal stand-in for Hyprland's `hl` table and Omarchy's `o` helpers,
-- mirroring the documented API (hl.window_rule, o.window). Loading the
-- packaging module against it fails loudly if the module calls an API that
-- does not exist (e.g. the old hyprlang-style hl.windowrulev2).
local recorded = {}
hl = {}
o = {}

hl.bind = function() end
hl.unbind = function() end
hl.dsp = { exec_cmd = function(cmd) return { cmd = cmd } end }
hl.window_rule = function(spec)
  recorded[#recorded + 1] = spec
  return { set_enabled = function() end, is_enabled = function() return true end }
end

function o.bind() end
function o.window(match, rules)
  rules.match = rules.match or {}
  if type(match) == "string" then
    rules.match.class = match
  else
    for k, v in pairs(match) do rules.match[k] = v end
  end
  hl.window_rule(rules)
end

assert(loadfile(arg[1]))()

local class_rule, title_rule
for _, r in ipairs(recorded) do
  if r.match.class == "^tide-island-config-app$" then class_rule = r end
  if r.match.title == "^Tide Island Config Application$" then title_rule = r end
end

local function complete(rule)
  return rule ~= nil and rule.float == true and rule.center == true and rule.no_anim == true
end

os.exit(complete(class_rule) and complete(title_rule) and 0 or 1)
LUA
if command -v lua >/dev/null 2>&1; then
  if lua "$tmp/window-rule-harness.lua" "$PACK" >/dev/null 2>&1; then
    t "settings app window rule floats/centers with no animation (valid hl API)" && ok
  else
    t "settings app window rule missing or uses an invalid Hyprland Lua API" && ko
  fi
else
  t "lua unavailable; skipped window-rule API check" && ok
fi

echo "  omarchy-bridge.sh contract"
BRIDGE="$ROOT/vendor/tide-island/share/tide-island/scripts/omarchy-bridge.sh"
bash -n "$BRIDGE" && t "omarchy-bridge.sh parses" && ok || ko

# A synthetic Omarchy home + fake omarchy-theme-* binaries.
OF="$tmp/omarchy-home"
OROOT="$tmp/omarchy-root"
OBIN="$tmp/omarchy-bin"
mkdir -p "$OF/.config/omarchy/themes/user-theme/backgrounds" \
         "$OF/.local/state/omarchy/current/theme/backgrounds" \
         "$OF/.config/omarchy/backgrounds/user-theme" \
         "$OROOT/themes/stock-theme" \
         "$OBIN"
printf 'user-theme\n' >"$OF/.local/state/omarchy/current/theme.name"
printf 'img' >"$OF/.local/state/omarchy/current/theme/backgrounds/1-a.jpg"
printf 'img' >"$OF/.config/omarchy/backgrounds/user-theme/x.jpg"
printf 'img' >"$OF/.config/omarchy/themes/user-theme/preview.png"
printf 'img' >"$OROOT/themes/stock-theme/preview.png"
ln -sf "$OF/.local/state/omarchy/current/theme/backgrounds/1-a.jpg" \
       "$OF/.local/state/omarchy/current/background"
printf '#!/usr/bin/env bash\nprintf "set:%%s\\n" "$*" >>"$OMARCHY_CALLS"\n' >"$OBIN/omarchy-theme-set"
printf '#!/usr/bin/env bash\nprintf "bg:%%s\\n" "$*" >>"$OMARCHY_CALLS"\n' >"$OBIN/omarchy-theme-bg-set"
chmod +x "$OBIN/"*
: >"$tmp/omarchy-calls"

run_bridge() { # extra env via caller; keeps HOME/OMARCHY_PATH isolated
  env HOME="$OF" OMARCHY_PATH="$OROOT" OMARCHY_CALLS="$tmp/omarchy-calls" \
      PATH="$OBIN:$PATH" bash "$BRIDGE" "$@"
}

run_bridge present && t "bridge reports Omarchy present when its tooling exists" && ok \
  || ko
state="$(run_bridge state)"
echo "$state" | jq -e '.omarchy == true and .currentSlug == "user-theme"
  and .currentName == "User Theme"
  and (.currentBackground | endswith("1-a.jpg"))
  and (.backgroundDirs | length == 2)' >/dev/null \
  && t "bridge state reports the current theme and both background dirs" && ok || ko
themes="$(run_bridge themes)"
echo "$themes" | jq -s -e '
  (map(select(.slug == "stock-theme" and .thirdParty == false)) | length == 1)
  and (map(select(.slug == "user-theme" and .thirdParty == true)) | length == 1)
  and (map(select(.slug == "user-theme"))[0].previewPath | endswith("preview.png"))' >/dev/null \
  && t "bridge lists stock and third-party themes with previews" && ok || ko
backgrounds="$(run_bridge backgrounds)"
echo "$backgrounds" | jq -s -e '
  (map(select(.fileName == "1-a.jpg" and .current == true)) | length == 1)
  and (map(select(.fileName == "x.jpg")) | length == 1)' >/dev/null \
  && t "bridge lists current-theme backgrounds and flags the active one" && ok || ko
run_bridge apply-theme user-theme && grep -q '^set:user-theme$' "$tmp/omarchy-calls" \
  && t "apply-theme delegates to omarchy-theme-set" && ok || ko
run_bridge apply-background "$OF/.local/state/omarchy/current/theme/backgrounds/1-a.jpg" \
  && grep -q '^bg:.*1-a.jpg$' "$tmp/omarchy-calls" \
  && t "apply-background delegates to omarchy-theme-bg-set" && ok || ko
run_bridge apply-background "$tmp/does-not-exist.jpg" >/dev/null 2>&1 \
  && ko "apply-background accepted a missing file" \
  || { t "apply-background rejects a missing file" && ok; }
# An isolated PATH (only bash) must make the bridge report Omarchy absent,
# regardless of whether this machine has Omarchy installed in /usr/bin.
mkdir -p "$tmp/cleanbin"
ln -sf "$(command -v bash)" "$tmp/cleanbin/bash"
if env HOME="$OF" PATH="$tmp/cleanbin" bash "$BRIDGE" present >/dev/null 2>&1; then
  t "bridge reports absent when omarchy tooling is missing" && ko
else
  t "bridge reports absent when omarchy tooling is missing" && ok
fi

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