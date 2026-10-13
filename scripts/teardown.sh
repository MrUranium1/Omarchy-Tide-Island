#!/usr/bin/env bash
#
# teardown.sh — reverse everything install.sh set up.
#
# Unlike uninstall.sh this is deliberately self-contained: it depends on NO file
# inside the plugin directory, so it still works after `omarchy plugin remove`
# has deleted mehir.tide-island. install.sh copies this script to
# ~/.local/lib/omarchy-tide-island/teardown.sh, and Service.qml runs that copy
# from Component.onDestruction when it notices its own plugin directory
# vanished, so removing the plugin undoes the OSD/notification stand-down (and
# the rest) even when it was removed with `omarchy plugin remove` rather than
# our uninstall.sh.
#
# Flags:
#   --remove-clones    Remove the OSD/notification clones we created ourselves
#                      (they are otherwise de-patched but kept).
#   --remove-runtime   Remove the bundled Tide Island from ~/.local.
#   --purge-config     Delete ~/.config/omarchy/tide-island.json.
#   --if-plugin-gone   No-op unless the plugin directory is already missing
#                      (used by the Component.onDestruction guard).
#   --final            Remove the state directory and this helper when done
#                      (used for a fully automatic removal).
#
# State lives in ~/.local/state/omarchy/tide-island/installed.json (written by
# install.sh); backups of every file we touched are kept in .../backups/.

set -Eeuo pipefail

PLUGIN_ID="mehir.tide-island"
HOME_DIR="$HOME"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"
BIN_TARGET="$HOME/.local/bin"
CONFIG_TARGET="$HOME/.config/omarchy/tide-island.json"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
BACKUPS="$STATE_DIR/backups"
STATE_MARKERS="$STATE_DIR/patch-state"
INSTALLED_FILE="$STATE_DIR/installed.json"
SEED_FILE="$STATE_DIR/seeded-userconfig.json"
LIB_DIR="$HOME/.local/lib/omarchy-tide-island"
HYPR="$HOME/.config/hypr"
UPSTREAM="/usr/share/omarchy/shell/plugins"
TIDE_USERCONFIG="$HOME/.config/tide-island/userconfig.json"
SYSTEMCTL="${TIDE_SYNC_SYSTEMCTL:-systemctl}"
TSTAMP="$(date +%Y%m%d-%H%M%S)"

opt_remove_clones=0
opt_remove_runtime=0
opt_purge_config=0
opt_if_gone=0
opt_final=0

usage() {
  cat <<USAGE
Usage: teardown.sh [--remove-clones] [--remove-runtime] [--purge-config]
                   [--if-plugin-gone] [--final] [--help]

  --remove-clones    Remove the OSD/notification clones we created.
  --remove-runtime   Remove the bundled Tide Island from ~/.local.
  --purge-config     Delete ~/.config/omarchy/tide-island.json.
  --if-plugin-gone   Only act when the plugin directory is missing.
  --final            Remove the state directory + this helper when done.
  --help             Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --remove-clones) opt_remove_clones=1 ;;
    --remove-runtime) opt_remove_runtime=1 ;;
    --purge-config) opt_purge_config=1 ;;
    --if-plugin-gone) opt_if_gone=1 ;;
    --final) opt_final=1 ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

log() { printf 'teardown: %s\n' "$*"; }

# The automatic path calls us while the shell is being torn down; bail unless the
# plugin really is gone, so a hot-reload or disable is never mistaken for a
# removal.
if (( opt_if_gone )) && [[ -e $PLUGIN_DIR ]]; then
  log "plugin still present at $PLUGIN_DIR; nothing to do."
  exit 0
fi

state="{}"
[[ -f $INSTALLED_FILE ]] && state="$(cat "$INSTALLED_FILE" 2>/dev/null || echo '{}')"

resync_shell() {
  command -v omarchy-shell >/dev/null 2>&1 || return 0
  omarchy-shell -q shell rescanPlugins 2>/dev/null || true
  omarchy-shell -q osd syncSuppression 2>/dev/null || true
  omarchy-shell -q notifications syncSuppression 2>/dev/null || true
}

remove_clone() {
  local id="$1"
  if command -v omarchy >/dev/null 2>&1 && omarchy plugin remove "$id" --yes >/dev/null 2>&1; then
    log "removed clone '$id'."
  fi
  if [[ -e "$PLUGINS_DIR/$id" && ! -L "$PLUGINS_DIR/$id" ]]; then
    rm -rf "${PLUGINS_DIR:?}/$id"
    log "removed directory $PLUGINS_DIR/$id"
  fi
  rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
}

# ------------------------------------------------------------- suppression

# State-less fallback: sweep every clone of this role for our own marker. Used
# when installed.json is gone (a previous --final, a manual clear, or a reap
# that ran after the state was already removed) yet our suppression patch is
# still live in the clones. Only clones whose entry point actually carries our
# marker are touched, so an unrelated custom clone is never harmed.
scan_and_clean() {
  local role="$1" skip="$2" m id entry file base backup upstream marker
  for m in "$PLUGINS_DIR"/*/manifest.json; do
    [[ -f $m ]] || continue
    id="$(basename "$(dirname "$m")")"
    [[ $id == "$skip" || $id == "$PLUGIN_ID" ]] && continue
    [[ "$(jq -r '.omarchy.clonedFrom // .clonedFrom // empty' "$m" 2>/dev/null || true)" == "omarchy.$role" ]] || continue
    entry="$(jq -r '.entryPoints.panel // .entryPoints.service // .entryPoints.barWidget // empty' "$m" 2>/dev/null || true)"
    [[ -z $entry ]] && continue
    file="${m%/manifest.json}/$entry"
    [[ -f $file ]] || continue
    marker="The bar-off marker"
    [[ $role == notifications ]] && marker="popupsSuppressed"
    grep -q "$marker" "$file" || continue

    if (( opt_remove_clones )); then
      remove_clone "$id"
      continue
    fi
    base="$(basename "$file")"
    backup="$(ls -1t "$BACKUPS"/*."$id".$base 2>/dev/null | head -1 || true)"
    upstream="$UPSTREAM/$role/$base"
    if [[ -n $backup ]]; then
      cp "$backup" "$file"
      log "de-suppressed '$id' (restored $base from backup)."
    elif [[ -f $upstream ]]; then
      cp "$upstream" "$file"
      log "de-suppressed '$id' (restored $base from the built-in)."
    else
      log "cannot restore '$id' automatically; re-clone it if popups misbehave." >&2
      continue
    fi
    rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
  done
}

undo_suppression() {
  mkdir -p "$BACKUPS"
  local role id created marker entry file base backup upstream dir handled
  for role in osd notifications; do
    handled=""
    id="$(jq -r --arg r "$role" '.suppression[$r].after // empty' <<<"$state" 2>/dev/null || true)"
    created="$(jq -r --arg r "$role" '.suppression[$r].createdByUs // false' <<<"$state" 2>/dev/null || true)"
    if [[ -n $id ]]; then
      handled="$id"
      dir="$PLUGINS_DIR/$id"
      if [[ ! -d $dir ]]; then
        rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
      else
        if [[ $created == "true" && $opt_remove_clones == 1 ]]; then
          remove_clone "$id"
        else
          marker="$(cat "$STATE_MARKERS/$id" 2>/dev/null || true)"
          if [[ $marker == preexisting ]]; then
            log "clone '$id' was already suppressed before the plugin; leaving it untouched."
          elif [[ -n $marker || $created == "true" ]]; then
            entry="$(jq -r '.entryPoints.panel // .entryPoints.service // .entryPoints.barWidget // empty' \
              "$dir/manifest.json" 2>/dev/null || true)"
            if [[ -z $entry ]]; then
              log "cannot determine the entry point of '$id'; leaving it."
            else
              file="$dir/$entry"
              base="$(basename "$file")"
              backup="$(ls -1t "$BACKUPS"/*."$id".$base 2>/dev/null | head -1 || true)"
              upstream="$UPSTREAM/$role/$base"
              if [[ -n $backup ]]; then
                cp "$backup" "$file"
                rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
                log "de-suppressed '$id' (restored $base from backup)."
              elif [[ -f $upstream ]]; then
                cp "$upstream" "$file"
                rm -f "$STATE_MARKERS/$id" 2>/dev/null || true
                log "de-suppressed '$id' (restored $base from the built-in)."
              elif (( opt_remove_clones )); then
                remove_clone "$id"
              else
                log "could not restore '$id'; re-clone it if popups misbehave." >&2
              fi
            fi
          else
            log "no record of this plugin patching '$id'; leaving it untouched."
          fi
        fi
      fi
    fi
    scan_and_clean "$role" "$handled"
  done
}

undo_suppression

# --------------------------------------------------------------- CLI shims

shim_names="$(jq -r '.cliShims[]? // empty' <<<"$state" 2>/dev/null || true)"
if [[ -z $shim_names ]]; then
  shim_names="$(printf '%s\n' omarchy-tide-island-toggle omarchy-tide-island-status)"
fi
while IFS= read -r name; do
  [[ -z $name ]] && continue
  dest="$BIN_TARGET/$name"
  if [[ -f $dest || -L $dest ]]; then
    cp "$dest" "$BACKUPS/$TSTAMP.$name" 2>/dev/null || true
    rm -f "$dest"
    log "removed $dest (backup kept)."
  fi
done <<<"$shim_names"

# ------------------------------------------------------------- keybinding

if [[ $(jq -r '.keybinding.wired // false' <<<"$state" 2>/dev/null || echo false) == "true" ]]; then
  module="$(jq -r '.keybinding.module // empty' <<<"$state" 2>/dev/null || true)"
  hyprland_backup="$(jq -r '.keybinding.hyprlandBackup // empty' <<<"$state" 2>/dev/null || true)"
  if [[ -n $module && -f $module ]]; then
    mkdir -p "$BACKUPS"
    cp "$module" "$BACKUPS/$TSTAMP.$(basename "$module")"
    rm -f "$module"
    log "removed $module (backup kept)."
  fi
  if [[ -f $HYPR/hyprland.lua ]]; then
    if [[ -n $hyprland_backup && -f $hyprland_backup ]]; then
      mkdir -p "$BACKUPS"
      cp "$HYPR/hyprland.lua" "$BACKUPS/$TSTAMP.hyprland.lua"
      cp "$hyprland_backup" "$HYPR/hyprland.lua"
      log "restored $HYPR/hyprland.lua from backup."
    elif grep -q 'hypr.tide-island' "$HYPR/hyprland.lua"; then
      mkdir -p "$BACKUPS"
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

if (( opt_purge_config )) && [[ -f $CONFIG_TARGET ]]; then
  mkdir -p "$BACKUPS"
  cp "$CONFIG_TARGET" "$BACKUPS/$TSTAMP.tide-island.json"
  rm -f "$CONFIG_TARGET"
  log "removed $CONFIG_TARGET (backup kept)."
else
  log "left $CONFIG_TARGET in place."
fi

# ---------------------------------------------------------------- runtime

if (( opt_remove_runtime )); then
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
  log "kept the bundled runtime."
fi

# ------------------------------------------------------------- tide config

# Remove a userconfig.json we seeded, but only while it still matches the seed
# untouched (a customized config is the user's own and stays).
if [[ -f $TIDE_USERCONFIG && -f $SEED_FILE ]] && cmp -s "$TIDE_USERCONFIG" "$SEED_FILE"; then
  rm -f "$TIDE_USERCONFIG"
  log "removed seeded $TIDE_USERCONFIG (still the untouched plugin default)."
else
  log "left $TIDE_USERCONFIG in place (customized, or not seeded by this plugin)."
fi

resync_shell

# ------------------------------------------------------------------- final

if (( opt_final )); then
  log "final: removing plugin state."
  rm -rf "${STATE_DIR:?}"
  # Delete the helper after we are done reading it; unlinking a running shell
  # script is safe on Linux (bash holds the open fd).
  rm -rf "${LIB_DIR:?}"
fi

log "done."
