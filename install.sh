#!/usr/bin/env bash
#
# install.sh — install the mehir.tide-island plugin on this machine
#
# Makes the plugin fully live WITHOUT touching anything you already run:
#   * never modifies ~/.config/hypr/bindings.lua on systems that have a
#     bar/tide binding already (it only wires its own keybinding module when
#     nothing binds SUPER + SHIFT + SPACE);
#   * seeds ~/.config/tide-island/userconfig.json only when you have no Tide
#     config yet and never overwrites it; never touches the Tide QML override
#     (~/.local/share/tide-island/);
#   * only patches user clones of the OSD/notifications plugins (creating them
#     first when they don't exist), and backs up every pre-patch file.
#
# Everything it does is recorded in
# ~/.local/state/omarchy/tide-island/installed.json so uninstall.sh can reverse
# it. Run install.sh again at any time to repair a missing piece.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ID="mehir.tide-island"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
BIN_TARGET="$HOME/.local/bin"
CONFIG_TARGET="$HOME/.config/omarchy/tide-island.json"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
BACKUPS="$STATE_DIR/backups"
INSTALLED_FILE="$STATE_DIR/installed.json"
HYPR="$HOME/.config/hypr"
TSTAMP="$(date +%Y%m%d-%H%M%S.%N)"

flag_keybinding=1
flag_config=1
flag_suppression=1
flag_shortcuts=1

usage() {
  cat <<USAGE
Usage: install.sh [--no-keybinding] [--no-config] [--no-suppression] [--no-shortcuts] [--help]

  --no-keybinding    Skip wiring the SUPER + SHIFT + SPACE binding. Requires a
                     separate line in hyprland.lua to load hypr/tide-island.lua.
  --no-config        Do not seed ~/.config/omarchy/tide-island.json.
  --no-suppression   Do not patch/clone the OSD and notifications plugins.
  --no-shortcuts     Do not apply the island keybindings to hyprland.lua.
  --help             Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --no-keybinding) flag_keybinding=0 ;;
    --no-config) flag_config=0 ;;
    --no-suppression) flag_suppression=0 ;;
    --no-shortcuts) flag_shortcuts=0 ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

log() { printf 'install: %s\n' "$*"; }

mkdir -p "$BIN_TARGET" "$PLUGINS_DIR" "$STATE_DIR" "$BACKUPS"
cli_shim_hashes="$(jq -c '.cliShimHashes // {}' "$INSTALLED_FILE" 2>/dev/null || printf '{}')"

# ------------------------------------------------------------- dependencies

log "checking dependencies..."
bash "$ROOT/scripts/install-dependencies.sh" || true

# ------------------------------------------------------- Tide Island runtime

# Install the bundled Tide Island into ~/.local when the user has no
# tide-island yet, so a plain "add plugin" gives them a working island. Does
# nothing if tide-island is already on PATH (e.g. the package is installed).
log "ensuring the Tide Island runtime is available..."
bash "$ROOT/scripts/install-tide-runtime.sh" \
  || log "bundled runtime install failed; install the tide-island package to fall back." >&2

# -------------------------------------------------------- Tide's own config

# Give downloaders the island's default look by seeding Tide's own
# userconfig.json once — only when the user has no Tide config yet, and never
# overwritten afterwards. Every key we omit falls back to Tide's compiled
# defaults, so only these five values are "ours".
tide_userconfig="$HOME/.config/tide-island/userconfig.json"
seed_tide_userconfig=0
if [[ -f $tide_userconfig ]]; then
  log "Tide user config exists ($tide_userconfig); keeping it and its user's values."
else
  mkdir -p "$(dirname "$tide_userconfig")"
  install -m 0644 "$ROOT/default/tide-userconfig.json" "$tide_userconfig"
  seed_tide_userconfig=1
  log "seeded $tide_userconfig with the plugin default look (status/top/opacity/36x140)."
fi

# -------------------------------------------------------------- CLI shims

cli_shims=()
install_shim() {
  local src="$1" name dest expected current source_hash tmp backup
  name="$(basename "$src")"
  dest="$BIN_TARGET/$name"
  expected="$(jq -r --arg n "$name" '.[$n] // empty' <<<"$cli_shim_hashes")"
  source_hash="$(sha256sum "$src" | cut -d' ' -f1)"
  if [[ -e $dest || -L $dest ]]; then
    if [[ -z $expected || -L $dest || ! -f $dest ]]; then
      log "keeping existing unowned CLI command $dest."
      return 0
    fi
    current="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [[ $current != "$expected" ]]; then
      log "keeping user-modified CLI shim $dest; ownership record retained for safe removal."
      return 0
    fi
    if [[ $current != "$source_hash" ]]; then
      backup="$(mktemp "$BACKUPS/$TSTAMP.$name.XXXXXX.shim")"
      cp -p "$dest" "$backup"
      tmp="$(mktemp "$BIN_TARGET/.${name}.XXXXXX")"
      install -m 0755 "$src" "$tmp"
      mv -f "$tmp" "$dest"
      log "updated managed CLI shim $dest (previous copy backed up)."
    fi
  else
    tmp="$(mktemp "$BIN_TARGET/.${name}.XXXXXX")"
    install -m 0755 "$src" "$tmp"
    if ! ln "$tmp" "$dest" 2>/dev/null; then
      rm -f "$tmp"
      log "keeping CLI command created concurrently at $dest."
      return 0
    fi
    rm -f "$tmp"
    log "installed CLI shim $dest."
  fi
  cli_shim_hashes="$(jq -c --arg n "$name" --arg h "$source_hash" '.[$n] = $h' <<<"$cli_shim_hashes")"
  cli_shims+=("$name")
}
install_shim "$ROOT/bin/omarchy-tide-island-toggle"
install_shim "$ROOT/bin/omarchy-tide-island-status"

# ----------------------------------------------------------------- config

config_seeded=0
if (( flag_config )); then
  if [[ -f $CONFIG_TARGET ]]; then
    log "config exists ($CONFIG_TARGET); keeping it."
  else
    install -m 0644 "$ROOT/default/tide-island.json" "$CONFIG_TARGET"
    config_seeded=1
    log "seeded $CONFIG_TARGET"
  fi
else
  log "config seeding skipped (--no-config)."
fi

# -------------------------------------------------------------- suppression

osd_clone_before="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.osd")) | .id] | join(",")')"
notif_clone_before="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.notifications")) | .id] | join(",")')"

if (( flag_suppression )); then
  log "ensuring OSD/notifications stand down while Tide Island is on..."
  bash "$ROOT/scripts/ensure-suppression.sh"
else
  log "suppression setup skipped (--no-suppression)."
fi

osd_clone_after="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.osd")) | .id] | join(",")')"
notif_clone_after="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.notifications")) | .id] | join(",")')"

# ------------------------------------------------------------- keybinding

key_wired=0
key_module_created=false
key_module_backup=""
key_module_sha=""
require_created_by_us=false
key_module="$HYPR/tide-island.lua"
hyprland_backup=""
if [[ -f $INSTALLED_FILE ]] \
  && [[ $(jq -r '.keybinding.module // empty' "$INSTALLED_FILE" 2>/dev/null || true) == "$key_module" ]]; then
  [[ $(jq -r '.keybinding.wired // false' "$INSTALLED_FILE" 2>/dev/null || true) == true ]] && key_wired=1
  key_module_created="$(jq -r '.keybinding.moduleCreatedByUs // false' "$INSTALLED_FILE" 2>/dev/null || echo false)"
  key_module_backup="$(jq -r '.keybinding.moduleBackup // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
  key_module_sha="$(jq -r '.keybinding.moduleSha256 // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
  require_created_by_us="$(jq -r '.keybinding.requireCreatedByUs // false' "$INSTALLED_FILE" 2>/dev/null || echo false)"
  hyprland_backup="$(jq -r '.keybinding.hyprlandBackup // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
fi
if (( flag_keybinding )); then
  already_wired=0
  if [[ -f $HYPR/hyprland.lua ]] && grep -q 'hypr\.tide-island' "$HYPR/hyprland.lua"; then
    already_wired=1
  fi
  existing_binding=0
  if [[ -f $HYPR/bindings.lua ]] \
    && grep -Eq 'SUPER *\+ *SHIFT *\+ *SPACE|toggle-bar-tide|omarchy-tide-island-toggle' "$HYPR/bindings.lua"; then
    existing_binding=1
  fi

  if (( already_wired )); then
    log "hyprland.lua already loads hypr.tide-island; keeping it."
    key_wired=1
  elif (( existing_binding )); then
    log "found an existing bar/tide binding in bindings.lua; leaving your hypr config untouched."
  elif [[ -f $HYPR/hyprland.lua ]]; then
    if [[ -e $key_module ]]; then
      cp "$key_module" "$BACKUPS/$TSTAMP.tide-island.lua"
      key_module_backup="$BACKUPS/$TSTAMP.tide-island.lua"
      log "backed up existing $key_module"
    else
      key_module_created=true
    fi
    install -m 0644 "$ROOT/packaging/hyprland-tide-island.lua" "$key_module"
    key_module_sha="$(sha256sum "$key_module" | cut -d' ' -f1)"
    cp "$HYPR/hyprland.lua" "$BACKUPS/$TSTAMP.hyprland.lua"
    printf '\nrequire("default.hypr.require_optional").module("hypr.tide-island")\n' >>"$HYPR/hyprland.lua"
    hyprland_backup="$BACKUPS/$TSTAMP.hyprland.lua"
    require_created_by_us=true
    key_wired=1
    log "wired $key_module into hyprland.lua (apply with hyprctl reload)."
  else
    log "no hyprland.lua found; keybinding module not wired."
  fi
else
  log "keybinding setup skipped (--no-keybinding)."
fi

# ------------------------------------------------------- island shortcuts

# Apply the island keybindings (the same twelve the settings app shows) into the
# app's OWN managed block in hyprland.lua, so they are live on a fresh install
# without opening the settings app. Non-destructive: a block that is already
# there (app- or user-made) is left untouched, and teardown only removes a block
# we created and nobody has edited since.
shortcut_state="$(jq -n '{ wired: false, createdByUs: false, config: "", blockSha256: "", qmlPath: "", backup: "" }')"
if (( flag_shortcuts )); then
  if [[ -f $HYPR/hyprland.lua ]]; then
    log "wiring the island keybindings into hyprland.lua..."
    if captured="$(bash "$ROOT/scripts/wire-shortcuts.sh" --apply 2>>"$STATE_DIR/wire-shortcuts.log")"; then
      shortcut_state="$captured"
      if [[ "$(jq -r '.createdByUs' <<<"$shortcut_state")" == true ]]; then
        log "island keybindings enabled (managed block written to hyprland.lua)."
      else
        log "existing island keybinding block kept (left untouched)."
      fi
    else
      log "island keybinding wiring failed; see $STATE_DIR/wire-shortcuts.log." >&2
    fi
  else
    log "no hyprland.lua found; island keybindings left to the settings app."
  fi
else
  log "shortcut setup skipped (--no-shortcuts)."
fi

# --------------------------------------------------------------- reconcile

log "reconciling service state against the bar flag..."
bash "$ROOT/scripts/tide-sync.sh" reconcile

# ------------------------------------------------------- teardown helper

# Install the self-contained teardown outside the plugin directory so the plugin
# can undo itself when it is removed with `omarchy plugin remove` (which deletes
# the plugin dir without running any hook). Keep a copy of the seeded Tide
# userconfig next to the state so uninstall knows what it may reclaim.
mkdir -p "$HOME/.local/lib/omarchy-tide-island"
install -m 0755 "$ROOT/scripts/teardown.sh" "$HOME/.local/lib/omarchy-tide-island/teardown.sh"
mkdir -p "$HOME/.local/lib/omarchy-tide-island/patches"
install -m 0644 "$ROOT/patches/omarchy-osd-suppression.patch" \
  "$HOME/.local/lib/omarchy-tide-island/patches/omarchy-osd-suppression.patch"
install -m 0644 "$ROOT/patches/omarchy-notifications-suppression.patch" \
  "$HOME/.local/lib/omarchy-tide-island/patches/omarchy-notifications-suppression.patch"
install -m 0644 "$ROOT/default/tide-userconfig.json" "$STATE_DIR/seeded-userconfig.json"
log "installed removal helper and recovery patches under \$HOME/.local/lib/omarchy-tide-island"

# ---------------------------------------------------------- installed.json

osd_clone_created=false
notif_clone_created=false
[[ -z $osd_clone_before && -n $osd_clone_after ]] && osd_clone_created=true
[[ -z $notif_clone_before && -n $notif_clone_after ]] && notif_clone_created=true

# Preserve "we created this clone" across re-runs: on a second install the clone
# already exists, so the before/after comparison can no longer tell. Once we
# created a clone, it stays ours for uninstall.sh --remove-plugin.
if [[ -f $INSTALLED_FILE ]]; then
  [[ "$(jq -r '.suppression.osd.createdByUs // false' "$INSTALLED_FILE" 2>/dev/null)" == true ]] && osd_clone_created=true
  [[ "$(jq -r '.suppression.notifications.createdByUs // false' "$INSTALLED_FILE" 2>/dev/null)" == true ]] && notif_clone_created=true
  # Keep the earliest "before" we ever saw so uninstall can recognise a clone
  # that already existed before the very first install.
  prev_osd_before="$(jq -r '.suppression.osd.before // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
  prev_notif_before="$(jq -r '.suppression.notifications.before // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
  [[ -n $prev_osd_before ]] && osd_clone_before="$prev_osd_before"
  [[ -n $prev_notif_before ]] && notif_clone_before="$prev_notif_before"
fi

osd_clone_baseline="$(jq -r '.suppression.osd.baselineFingerprint // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
notif_clone_baseline="$(jq -r '.suppression.notifications.baselineFingerprint // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
[[ -n $osd_clone_baseline ]] || osd_clone_baseline="$(cat "$STATE_DIR/clone-baselines/$osd_clone_after" 2>/dev/null || true)"
[[ -n $notif_clone_baseline ]] || notif_clone_baseline="$(cat "$STATE_DIR/clone-baselines/$notif_clone_after" 2>/dev/null || true)"
if [[ -n $key_module_sha ]]; then
  :
elif [[ $key_module_created == true && -f $key_module ]]; then
  key_module_sha="$(sha256sum "$key_module" | cut -d' ' -f1)"
fi

jq -n \
  --arg installer "$ROOT" \
  --arg installedAt "$TSTAMP" \
  --argjson shims "$(printf '%s\n' "${cli_shims[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson shimHashes "$cli_shim_hashes" \
  --argjson configSeeded "$( (( config_seeded )) && echo true || echo false )" \
  --argjson keyWired "$( (( key_wired )) && echo true || echo false )" \
  --arg keyModule "$key_module" \
  --arg hyprlandBackup "$hyprland_backup" \
  --argjson keyModuleCreated "$key_module_created" \
  --arg keyModuleBackup "$key_module_backup" \
  --arg keyModuleSha "$key_module_sha" \
  --argjson requireCreatedByUs "$require_created_by_us" \
  --arg osdCloneBefore "$osd_clone_before" \
  --arg osdCloneAfter "$osd_clone_after" \
  --argjson osdCloneCreated "$osd_clone_created" \
  --arg osdCloneBaseline "$osd_clone_baseline" \
  --arg notifCloneBefore "$notif_clone_before" \
  --arg notifCloneAfter "$notif_clone_after" \
  --argjson notifCloneCreated "$notif_clone_created" \
  --arg notifCloneBaseline "$notif_clone_baseline" \
  --arg tideUserConfigPath "$tide_userconfig" \
  --argjson tideUserConfigSeeded "$( (( seed_tide_userconfig )) && echo true || echo false )" \
  --argjson shortcutBinding "$shortcut_state" \
  '{ installer: $installer, installedAt: $installedAt,
     cliShims: $shims, cliShimHashes: $shimHashes, configSeeded: $configSeeded,
     keybinding: { wired: $keyWired, module: $keyModule, hyprlandBackup: $hyprlandBackup,
                   moduleCreatedByUs: $keyModuleCreated, moduleBackup: $keyModuleBackup,
                   moduleSha256: $keyModuleSha,
                   requireCreatedByUs: $requireCreatedByUs },
     shortcutBinding: $shortcutBinding,
     suppression: {
       osd: { before: $osdCloneBefore, after: $osdCloneAfter, createdByUs: $osdCloneCreated,
              baselineFingerprint: $osdCloneBaseline },
       notifications: { before: $notifCloneBefore, after: $notifCloneAfter, createdByUs: $notifCloneCreated,
                        baselineFingerprint: $notifCloneBaseline }
     },
     tideUserConfig: { path: $tideUserConfigPath, seeded: $tideUserConfigSeeded } }' >"$INSTALLED_FILE" 2>/dev/null || {
      log "could not write $INSTALLED_FILE (missing jq?); continuing." >&2
    }
log "wrote $INSTALLED_FILE"

# ---------------------------------- explain the clone hand-over (one time)

# Omarchy itself shows "Editing Cloned Plugin" when the clone step replaces the
# built-in (that is its supported clone workflow's confirmation). Explain what
# actually happened so nobody is confused by it. Sent only when THIS run created
# the clones, so a repair re-run stays quiet.
if (( flag_suppression )) && [[ "$(jq -r '.suppression.osd.createdByUs // false' "$INSTALLED_FILE" 2>/dev/null)" == true ]]; then
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send --app-name "Tide Island" \
      "Tide Island now owns the OSD and notification popups" \
      "Volume/display OSD and notification toasts now come from the My OSD and My Notifications clones while the island is on; removing the plugin restores Omarchy's originals. The two 'Editing Cloned Plugin' toasts are Omarchy's own clone confirmation." \
      >/dev/null 2>&1 || true
  fi
fi

# ------------------------------------------------- mount (problem 1 fix)

# The OSD/notifications clones are patched on disk and enabled in config, but
# the RUNNING shell may have mounted them before the patch landed (its plugin
# watch reloads mid-clone), leaving unpatched code serving the popups. Resolve
# this by bouncing the mounted set in a DETACHED process — the reload it
# triggers unmounts and recreates this plugin's own shell service, so the
# bounce must not be its child — and let it verify, over the shell IPC, that
# the patched clones are the ones serving now. It (and only it) writes the
# auto-setup marker, so "setup done" means "suppression actually live".
if (( flag_suppression )); then
  if [[ -x $ROOT/scripts/ensure-mount.sh ]]; then
    log "making the patched OSD/notifications clones serve at runtime (detached verify)..."
    # Delay one second first so install.sh (and the caller's QML process) can
    # finish printing/returning before its own reload recreates the service.
    ( sleep 1; setsid nohup bash "$ROOT/scripts/ensure-mount.sh" --marker "$STATE_DIR/auto-setup.done" \
        >/dev/null 2>&1 </dev/null ) &
    disown 2>/dev/null || true
  else
    log "ensure-mount.sh missing; suppression takes effect on the next shell restart." >&2
  fi
else
  # Opted out of suppression: still mark setup finished so a later auto-setup
  # does not silently re-enable what --no-suppression disabled.
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/auto-setup.done"
fi

# ---------------------------------------------------------------- shell sync

# Nudge the running plugin (if any) to refresh its status and reconcile now.
omarchy-shell -q tide-island refresh 2>/dev/null || true

# ------------------------------------------------------------------- summary

cat <<SUMMARY

Tide Island plugin is installed.
  bindings: SUPER + SHIFT + SPACE toggles the bar and Tide Island together.
  status:   omarchy-tide-island-status
  keybinding state: $( (( key_wired )) && echo "managed by $key_module" || echo "left to your bindings.lua/hyprland.lua" )
  shortcuts: $( [[ "$(jq -r '.shortcutBinding.createdByUs' "$INSTALLED_FILE" 2>/dev/null)" == true ]] \
                && echo "island keybindings written to hyprland.lua" \
                || echo "left to your hyprland.lua / the Tide Island settings app" )
  config:   $CONFIG_TARGET
  reverse:  run uninstall.sh to undo every step above.
SUMMARY