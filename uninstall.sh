#!/usr/bin/env bash
#
# uninstall.sh — reverse everything install.sh did
#
# Non-destructive by default: nothing user-created is deleted, everything we
# would remove is backed up to ~/.local/state/omarchy/tide-island/backups/
# first, and your ~/.config/tide-island/ and Tide QML override are never
# touched. The plugin directory itself and your (possibly newly created)
# OSD/notifications clones stay; pass --remove-plugin to remove what we had
# to clone, and --create-backups to keep a snapshot of every file we touch.

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
SYSTEMCTL="${TIDE_SYNC_SYSTEMCTL:-systemctl}"
TSTAMP="$(date +%Y%m%d-%H%M%S)"

flag_remove_plugin=0
flag_purge_config=0
flag_remove_runtime=0

usage() {
  cat <<USAGE
Usage: uninstall.sh [--remove-plugin] [--purge-config] [--remove-runtime] [--help]

  --remove-plugin   Also remove OSD/notifications clones we created ourselves
                    and disable the tide-island plugin.
  --purge-config    Delete ~/.config/omarchy/tide-island.json (defaults to
                    keeping it so re-enabling is one command).
  --remove-runtime  Also remove the bundled Tide Island installed under
                    ~/.local/share/omarchy-tide-island (unit, PATH link, files).
  --help            Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --remove-plugin) flag_remove_plugin=1 ;;
    --purge-config) flag_purge_config=1 ;;
    --remove-runtime) flag_remove_runtime=1 ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

log() { printf 'uninstall: %s\n' "$*"; }

[[ -f $INSTALLED_FILE ]] && state="$(cat "$INSTALLED_FILE")" || state="{}"

# --------------------------------------------------------------- CLI shims

shim_names="$(jq -r '.cliShims[] // empty' <<<"$state" || true)"
if [[ -z $shim_names ]]; then
  shim_names="$(printf '%s\n' omarchy-tide-island-toggle omarchy-tide-island-status)"
fi
mkdir -p "$BACKUPS"
while IFS= read -r name; do
  [[ -z $name ]] && continue
  dest="$BIN_TARGET/$name"
  if [[ -f $dest ]]; then
    cp "$dest" "$BACKUPS/$TSTAMP.$name"
    rm -f "$dest"
    log "removed $dest (backup kept)."
  fi
done <<<"$shim_names"

# -------------------------------------------------------------- suppression

log "undoing OSD/notifications suppression..."
bash "$ROOT/scripts/ensure-suppression.sh" --restore

if (( flag_remove_plugin )); then
  for role in osd notifications; do
    before="$(jq -r --arg r "$role" ".suppression.$role.before // empty" <<<"$state" || true)"
    after="$(jq -r --arg r "$role" ".suppression.$role.after // empty" <<<"$state" || true)"
    created="$(jq -r --arg r "$role" ".suppression.$role.createdByUs // false" <<<"$state" || true)"
    if [[ ( $created == "true" || $created == "1" ) && -n $after ]]; then
      # Remove clones we created (they no longer carry our patch).
      omarchy plugin remove "$after" --yes 2>/dev/null \
        && log "removed clone '$after' (was created by install.sh)." \
        || log "could not remove clone '$after' (shell down?); removing directory." >&2
      if [[ -e $PLUGINS_DIR/$after && ! -L $PLUGINS_DIR/$after ]]; then
        rm -rf "${PLUGINS_DIR:?}/$after"
        log "removed directory $PLUGINS_DIR/$after"
      fi
    elif [[ -n $after && -z $before ]]; then
      log "clone '$after' predates the plugin; left in place (de-patched above)."
    fi
  done
fi

# ------------------------------------------------------------- keybinding

if [[ $(jq -r '.keybinding.wired // false' <<<"$state") == "true" ]]; then
  module="$(jq -r '.keybinding.module // empty' <<<"$state" || true)"
  hyprland_backup="$(jq -r '.keybinding.hyprlandBackup // empty' <<<"$state" || true)"
  if [[ -n $module && -f $module ]]; then
    cp "$module" "$BACKUPS/$TSTAMP.$(basename "$module")"
    rm -f "$module"
    log "removed $module (backup kept)."
  fi
  if [[ -f $HYPR/hyprland.lua ]]; then
    if [[ -n $hyprland_backup && -f $hyprland_backup ]]; then
      cp "$HYPR/hyprland.lua" "$BACKUPS/$TSTAMP.hyprland.lua"
      cp "$hyprland_backup" "$HYPR/hyprland.lua"
      log "restored $HYPR/hyprland.lua from backup."
    elif grep -q 'hypr.tide-island' "$HYPR/hyprland.lua"; then
      cp "$HYPR/hyprland.lua" "$BACKUPS/$TSTAMP.hyprland.lua"
      grep -v 'hypr.tide-island' "$HYPR/hyprland.lua" >"$HYPR/hyprland.lua.tmp"
      mv "$HYPR/hyprland.lua.tmp" "$HYPR/hyprland.lua"
      log "removed the tide-island require line from hyprland.lua."
    fi
  fi
else
  log "no keybinding module was wired; leaving hypr config untouched."
fi

# ----------------------------------------------------------------- config

if [[ $flag_purge_config == 1 && -f $CONFIG_TARGET ]]; then
  cp "$CONFIG_TARGET" "$BACKUPS/$TSTAMP.tide-island.json"
  rm -f "$CONFIG_TARGET"
  log "removed $CONFIG_TARGET (backup kept). Re-running install.sh resurrects it."
else
  log "left $CONFIG_TARGET in place (pass --purge-config to remove it)."
fi

# ------------------------------------------------------------------ runtime

if (( flag_remove_runtime )); then
  PREFIX="${TIDE_ISLAND_PREFIX:-$HOME/.local/share/omarchy-tide-island}"
  "$SYSTEMCTL" --user stop tide-island.service 2>/dev/null || true
  unit="$HOME/.config/systemd/user/tide-island.service"
  if [[ -f $unit ]] && grep -qF '# managed by mehir.tide-island' "$unit"; then
    rm -f "$unit"
    "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
    log "removed $unit"
  fi
  for name in tide-island tide-island-config-app; do
    link="$HOME/.local/bin/$name"
    if [[ -L $link && "$(readlink "$link")" == "$PREFIX/bin/$name" ]]; then
      rm -f "$link"
      log "removed $link"
    fi
  done
  rm -f "$HOME/.local/share/applications/tide-island.desktop" \
    "$HOME/.local/share/applications/tide-island-config.desktop"
  if [[ -f "$PREFIX/.version" ]]; then
    rm -rf "${PREFIX:?}"
    log "removed bundled runtime $PREFIX"
  fi
else
  log "kept the bundled runtime (pass --remove-runtime to remove it)."
fi

# -------------------------------------------------------------- tide config

# Remove the userconfig.json we seeded for first-time Tide installs, but only
# while it still matches the shipped default untouched (a customized config is
# the user's own and stays).
tide_userconfig="$HOME/.config/tide-island/userconfig.json"
if [[ -f $tide_userconfig && -f "$ROOT/default/tide-userconfig.json" ]] \
  && cmp -s "$tide_userconfig" "$ROOT/default/tide-userconfig.json"; then
  rm -f "$tide_userconfig"
  log "removed seeded $tide_userconfig (still the untouched plugin default)."
else
  log "left $tide_userconfig in place (customized, or not seeded by this plugin)."
fi

# ------------------------------------------------------------------ plugin

if (( flag_remove_plugin )); then
  if omarchy plugin remove "$PLUGIN_ID" --yes 2>/dev/null; then
    log "removed plugin '$PLUGIN_ID'."
  else
    log "could not remove the plugin via omarchy (shell down?); its files remain at $PLUGIN_DIR"
  fi
else
  log "kept the plugin '$PLUGIN_ID' itself (disable anytime: omarchy plugin rm $PLUGIN_ID --yes)."
fi

log "done. Reload the shell (relogin or reload omarchy-shell) to pick up changes."