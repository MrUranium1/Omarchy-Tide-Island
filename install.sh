#!/usr/bin/env bash
#
# install.sh — install the mehir.tide-island plugin on this machine
#
# Makes the plugin fully live WITHOUT touching anything you already run:
#   * never modifies ~/.config/hypr/bindings.lua on systems that have a
#     bar/tide binding already (it only wires its own keybinding module when
#     nothing binds SUPER + SHIFT + SPACE);
#   * never touches your Tide Island config (~/.config/tide-island/) or the
#     Tide QML override (~/.local/share/tide-island/);
#   * only patches user clones of the OSD/notifications plugins (creating them
#     first when they don't exist), and backs up every pre-patch file.
#
# Everything it does is recorded in
# ~/.local/state/omarchy/tide-island/installed.json so uninstall.sh can reverse
# it. Run install.sh again at any time to repair a missing piece.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ID="mehir.tide-island"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
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
flag_yes=""

usage() {
  cat <<USAGE
Usage: install.sh [--no-keybinding] [--no-config] [--no-suppression] [-y] [--help]

  --no-keybinding    Skip wiring the SUPER + SHIFT + SPACE binding. Requires a
                     separate line in hyprland.lua to load hypr/tide-island.lua.
  --no-config        Do not seed ~/.config/omarchy/tide-island.json.
  --no-suppression   Do not patch/clone the OSD and notifications plugins.
  -y, --yes          Do not ask before reparative steps.
  --help             Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --no-keybinding) flag_keybinding=0 ;;
    --no-config) flag_config=0 ;;
    --no-suppression) flag_suppression=0 ;;
    -y | --yes) flag_yes=1 ;;
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

osd_clone_before="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.osd"))[].id] | join(",")')"
notif_clone_before="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.notifications"))[].id] | join(",")')"

if (( flag_suppression )); then
  log "ensuring OSD/notifications stand down while Tide Island is on..."
  bash "$ROOT/scripts/ensure-suppression.sh"
else
  log "suppression setup skipped (--no-suppression)."
fi

osd_clone_after="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.osd"))[].id] | join(",")')"
notif_clone_after="$(omarchy-plugin-list --json 2>/dev/null | jq -r '[(.[] | select(.firstParty == false and .clonedFrom == "omarchy.notifications"))[].id] | join(",")')"

# ------------------------------------------------------------- keybinding

key_wired=0
key_module="$HYPR/tide-island.lua"
hyprland_backup=""
if (( flag_keybinding )); then
  if [[ -f $HYPR/hyprland.lua ]] && grep -q 'tide-island' "$HYPR/hyprland.lua"; then
    log "hyprland.lua already loads the tide-island module; keeping it."
    key_wired=1
    key_module="$HYPR/tide-island.lua"
  elif [[ -f $HYPR/bindings.lua ]] && grep -E 'SHIFT *\+ *SPACE|toggle-bar-tide|tide-island-toggle' "$HYPR/bindings.lua" >/dev/null 2>&1; then
    log "found an existing bar/tide binding in bindings.lua; leaving hypr config untouched."
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
    log "wired $key_module into hyprland.lua (relaunch or hyprctl reload to apply)."
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

osd_clone_created=0
notif_clone_created=0
[[ -n $osd_clone_before || -z $osd_clone_after ]] || osd_clone_created=1
[[ -n $notif_clone_before || -z $notif_clone_after ]] || notif_clone_created=1

jq -n \
  --arg installer "$ROOT" \
  --arg installedAt "$TSTAMP" \
  --argjson shims "$(printf '%s\n' "${cli_shims[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson configSeeded "$config_seeded" \
  --argjson keyWired "$key_wired" \
  --arg keyModule "$key_module" \
  --arg hyprlandBackup "$hyprland_backup" \
  --arg osdCloneBefore "$osd_clone_before" \
  --arg osdCloneAfter "$osd_clone_after" \
  --argjson osdCloneCreated "$osd_clone_created" \
  --arg notifCloneBefore "$notif_clone_before" \
  --arg notifCloneAfter "$notif_clone_after" \
  --argjson notifCloneCreated "$notif_clone_created" \
  '{ installer: $installer, installedAt: $installedAt,
     cliShims: $shims, configSeeded: $configSeeded,
     keybinding: { wired: $keyWired, module: $keyModule, hyprlandBackup: $hyprlandBackup },
     suppression: {
       osd: { before: $osdCloneBefore, after: $osdCloneAfter, createdByUs: $osdCloneCreated },
       notifications: { before: $notifCloneBefore, after: $notifCloneAfter, createdByUs: $notifCloneCreated }
     } }' >"$INSTALLED_FILE" 2>/dev/null || {
      log "could not write $INSTALLED_FILE (missing jq?); continuing." >&2
    }
log "wrote $INSTALLED_FILE"

# ---------------------------------------------------------------- shell sync

omarchy-shell -q "$PLUGIN_ID" refresh 2>/dev/null || true

# ------------------------------------------------------------------- summary

cat <<SUMMARY

Tide Island plugin is installed.
  bindings: SUPER + SHIFT + SPACE toggles the bar and Tide Island together.
  status:   omarchy-tide-island-status
  keybinding state: $( (( key_wired )) && echo "managed by $key_module" || echo "left to your bindings.lua/hyprland.lua" )
  config:   $CONFIG_TARGET
  reverse:  run uninstall.sh to undo every step above.
SUMMARY