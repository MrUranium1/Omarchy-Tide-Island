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
TSTAMP="$(date +%Y%m%d-%H%M%S)"

flag_keybinding=1
flag_config=1
flag_suppression=1

usage() {
  cat <<USAGE
Usage: install.sh [--no-keybinding] [--no-config] [--no-suppression] [--help]

  --no-keybinding    Skip wiring the SUPER + SHIFT + SPACE binding. Requires a
                     separate line in hyprland.lua to load hypr/tide-island.lua.
  --no-config        Do not seed ~/.config/omarchy/tide-island.json.
  --no-suppression   Do not patch/clone the OSD and notifications plugins.
  --help             Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --no-keybinding) flag_keybinding=0 ;;
    --no-config) flag_config=0 ;;
    --no-suppression) flag_suppression=0 ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

log() { printf 'install: %s\n' "$*"; }

mkdir -p "$BIN_TARGET" "$PLUGINS_DIR" "$STATE_DIR" "$BACKUPS"

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
  local src="$1" name dest
  name="$(basename "$src")"
  dest="$BIN_TARGET/$name"
  if [[ -e $dest && ! -L $dest ]] && ! cmp -s "$src" "$dest"; then
    cp "$dest" "$BACKUPS/$TSTAMP.$name.shim"
    log "backed up pre-existing $dest"
  fi
  install -m 0755 "$src" "$dest"
  log "installed $dest"
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
key_module="$HYPR/tide-island.lua"
hyprland_backup=""
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
    [[ -f $key_module ]] || install -m 0644 "$ROOT/packaging/hyprland-tide-island.lua" "$key_module"
    key_wired=1
  elif (( existing_binding )); then
    log "found an existing bar/tide binding in bindings.lua; leaving your hypr config untouched."
  elif [[ -f $HYPR/hyprland.lua ]]; then
    if [[ -e $key_module ]] && ! cmp -s "$ROOT/packaging/hyprland-tide-island.lua" "$key_module"; then
      cp "$key_module" "$BACKUPS/$TSTAMP.tide-island.lua"
      log "backed up existing $key_module"
    fi
    install -m 0644 "$ROOT/packaging/hyprland-tide-island.lua" "$key_module"
    cp "$HYPR/hyprland.lua" "$BACKUPS/$TSTAMP.hyprland.lua"
    printf '\nrequire("default.hypr.require_optional").module("hypr.tide-island")\n' >>"$HYPR/hyprland.lua"
    hyprland_backup="$BACKUPS/$TSTAMP.hyprland.lua"
    key_wired=1
    log "wired $key_module into hyprland.lua (apply with hyprctl reload)."
  else
    log "no hyprland.lua found; keybinding module not wired."
  fi
else
  log "keybinding setup skipped (--no-keybinding)."
fi

# --------------------------------------------------------------- reconcile

log "reconciling service state against the bar flag..."
bash "$ROOT/scripts/tide-sync.sh" reconcile

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

jq -n \
  --arg installer "$ROOT" \
  --arg installedAt "$TSTAMP" \
  --argjson shims "$(printf '%s\n' "${cli_shims[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson configSeeded "$( (( config_seeded )) && echo true || echo false )" \
  --argjson keyWired "$( (( key_wired )) && echo true || echo false )" \
  --arg keyModule "$key_module" \
  --arg hyprlandBackup "$hyprland_backup" \
  --arg osdCloneBefore "$osd_clone_before" \
  --arg osdCloneAfter "$osd_clone_after" \
  --argjson osdCloneCreated "$osd_clone_created" \
  --arg notifCloneBefore "$notif_clone_before" \
  --arg notifCloneAfter "$notif_clone_after" \
  --argjson notifCloneCreated "$notif_clone_created" \
  --arg tideUserConfigPath "$tide_userconfig" \
  --argjson tideUserConfigSeeded "$( (( seed_tide_userconfig )) && echo true || echo false )" \
  '{ installer: $installer, installedAt: $installedAt,
     cliShims: $shims, configSeeded: $configSeeded,
     keybinding: { wired: $keyWired, module: $keyModule, hyprlandBackup: $hyprlandBackup },
     suppression: {
       osd: { before: $osdCloneBefore, after: $osdCloneAfter, createdByUs: $osdCloneCreated },
       notifications: { before: $notifCloneBefore, after: $notifCloneAfter, createdByUs: $notifCloneCreated }
     },
     tideUserConfig: { path: $tideUserConfigPath, seeded: $tideUserConfigSeeded } }' >"$INSTALLED_FILE" 2>/dev/null || {
      log "could not write $INSTALLED_FILE (missing jq?); continuing." >&2
    }
log "wrote $INSTALLED_FILE"

# ---------------------------------------------------------------- shell sync

omarchy-shell -q tide-island refresh 2>/dev/null || true

# ------------------------------------------------------------------- summary

cat <<SUMMARY

Tide Island plugin is installed.
  bindings: SUPER + SHIFT + SPACE toggles the bar and Tide Island together.
  status:   omarchy-tide-island-status
  keybinding state: $( (( key_wired )) && echo "managed by $key_module" || echo "left to your bindings.lua/hyprland.lua" )
  config:   $CONFIG_TARGET
  reverse:  run uninstall.sh to undo every step above.
SUMMARY