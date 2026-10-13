#!/usr/bin/env bash
#
# uninstall.sh — reverse everything install.sh did.
#
# Non-destructive by default: nothing user-created is deleted, everything we
# would remove is backed up to ~/.local/state/omarchy/tide-island/backups/
# first, and a customized ~/.config/tide-island/ is never touched. The plugin
# directory itself and your (possibly newly created) OSD/notifications clones
# stay; pass --remove-plugin to remove what we had to clone.
#
# The actual work lives in scripts/teardown.sh, which is also installed to
# ~/.local/lib/omarchy-tide-island/teardown.sh so the plugin can undo itself
# when it is removed with `omarchy plugin remove` instead.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ID="mehir.tide-island"
INSTALLED_LIB_TEARDOWN="$HOME/.local/lib/omarchy-tide-island/teardown.sh"

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

# Prefer the in-repo teardown (always current); fall back to the installed copy
# in case uninstall.sh is run from somewhere without scripts/.
teardown="$ROOT/scripts/teardown.sh"
[[ -f $teardown ]] || teardown="$INSTALLED_LIB_TEARDOWN"
if [[ ! -f $teardown ]]; then
  log "cannot find teardown.sh (looked in $ROOT/scripts and $INSTALLED_LIB_TEARDOWN)." >&2
  exit 1
fi

args=()
(( flag_remove_plugin )) && args+=(--remove-clones)
(( flag_purge_config )) && args+=(--purge-config)
(( flag_remove_runtime )) && args+=(--remove-runtime)

if (( ${#args[@]} )); then
  log "running teardown (${args[*]})..."
  bash "$teardown" "${args[@]}"
else
  log "running teardown..."
  bash "$teardown"
fi

# --------------------------------------------------------------- the plugin

if (( flag_remove_plugin )); then
  if command -v omarchy >/dev/null 2>&1 && omarchy plugin remove "$PLUGIN_ID" --yes >/dev/null 2>&1; then
    log "removed plugin '$PLUGIN_ID'."
  else
    log "could not remove the plugin via omarchy (shell down?); its files remain at $HOME/.config/omarchy/plugins/$PLUGIN_ID"
  fi
else
  log "kept the plugin '$PLUGIN_ID' itself (disable anytime: omarchy plugin rm $PLUGIN_ID --yes)."
fi

log "done. Reload the shell (relogin or reload omarchy-shell) to pick up changes."
