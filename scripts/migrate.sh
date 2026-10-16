#!/usr/bin/env bash
#
# migrate.sh — upgrade an already-configured mehir.tide-island installation.
#
# Why this exists
# ---------------
# On first load the shell service runs install.sh once and writes the
# auto-setup.done marker. On a later `omarchy plugin update` the plugin
# directory is refreshed (git fast-forward) but install.sh is NOT run — there
# is no install hook in the manifest — and the running service is keepLoaded,
# so it is not even recreated in-session. On the next shell start the new
# Service.qml loads but its auto-setup bails on the existing marker. An
# existing installation therefore kept the OLD bundled runtime (whose settings
# app is the native binary, not the hardened launcher added in the previous
# release) and a possibly group/world-readable userconfig.json.
#
# Service.qml calls this on every load, independent of auto-setup.done, to
# close that gap. It performs only the security-relevant refresh:
#
#   * reinstall/refresh the bundled Tide Island runtime, so
#     $PREFIX/bin/tide-island-config-app is the hardened launcher and the
#     desktop entry / PATH link that resolve to it take effect; and
#   * repair ~/.config/tide-island permissions in place (0700 / 0600), without
#     following symlinks and without ever reading or rewriting the file, so a
#     saved TLP sudo password stops being group/world readable.
#
# It never runs the heavier suppression/keybinding setup; that stays the job of
# install.sh. It is idempotent: a "generation" hash of this script, its two
# helpers and the bundled runtime content is recorded under the plugin state
# dir, and the expensive runtime refresh is skipped while it still matches.
# The config repair is cheap and runs every time, so a config loosened after
# installation is re-tightened too.
#
# Usage: migrate.sh [--auto] [--help]
#   --auto   non-interactive (the only mode; accepted for call-site symmetry).
#
# Exit 0 when the installation is migrated or already current, non-zero when
# the runtime could not be refreshed or the config could not be tightened, so
# the caller can retry on the next shell start. The hardened launcher is the
# backstop either way: it refuses to start the GUI while the password file is
# readable by other users.

set -Eeuo pipefail

log() { printf 'migrate: %s\n' "$*" >&2; }

usage() {
  cat <<USAGE
Usage: migrate.sh [--auto] [--help]

  --auto   Non-interactive (default). Run by Service.qml on every load.
  --help   Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --auto) ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
MARKER="$STATE_DIR/migrate.sha256"

# The runtime/launcher prefix install-tide-runtime.sh targets.
PREFIX="${TIDE_ISLAND_PREFIX:-$HOME/.local/share/omarchy-tide-island}"

# The config directory the settings app and the hardened launcher use. Mirror
# the launcher/helper (XDG-aware) rather than install.sh's sandbox-safe
# $HOME/.config seed, so we repair the directory the app actually reads.
if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
  config_dir="$XDG_CONFIG_HOME/tide-island"
elif [[ -n ${HOME:-} ]]; then
  config_dir="$HOME/.config/tide-island"
else
  config_dir=""
fi

# A fingerprint of the files we ship. Mirrors install-tide-runtime.sh's
# vendor_content_hash so a runtime-content change (a new vendored runtime)
# forces one more migration even when this script's own text is unchanged.
vendor_content_hash() {
  local h=""
  h="$( cd "$ROOT/vendor/tide-island" 2>/dev/null \
    && { find bin lib share -type f -print0 2>/dev/null \
      | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; } )" \
    || true
  printf '%s' "$h"
}

# The migration generation: changes whenever this script, either helper, or the
# bundled runtime content changes.
generation() {
  {
    sha256sum "$ROOT/scripts/migrate.sh" 2>/dev/null || true
    sha256sum "$ROOT/scripts/install-tide-runtime.sh" 2>/dev/null || true
    sha256sum "$ROOT/scripts/harden-tide-config.sh" 2>/dev/null || true
    printf 'vendor %s\n' "$(vendor_content_hash)"
  } | sha256sum | cut -d' ' -f1
}

rc=0

# 1) Config privacy: cheap, in-place, symlink-safe. Runs every load so a config
#    loosened after installation is re-tightened (never reads/rewrites it).
if [[ -n $config_dir ]]; then
  bash "$ROOT/scripts/harden-tide-config.sh" "$config_dir" || rc=1
fi

# 2) Runtime refresh: only when the generation changed, so the installed
#    launcher is the hardened wrapper. Record the generation only once the
#    runtime is confirmed, so a failed/refused refresh is retried next start.
gen="$(generation)"
if [[ -n $gen && -f $MARKER && "$(cat "$MARKER" 2>/dev/null)" == "$gen" ]]; then
  log "already migrated (generation ${gen:0:12}); runtime is current."
else
  if [[ -x "$PREFIX/bin/tide-island-config-app" ]] \
    && grep -q 'tide-island-config-app.real' "$PREFIX/bin/tide-island-config-app" 2>/dev/null; then
    log "runtime already carries the hardened launcher."
  else
    log "refreshing the bundled runtime so the settings app launches hardened."
  fi
  if bash "$ROOT/scripts/install-tide-runtime.sh"; then
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$gen" >"$MARKER"
    log "bundled runtime migrated (generation ${gen:0:12})."
  else
    log "bundled runtime could not be refreshed; will retry on the next shell start." >&2
    rc=1
  fi
fi

exit "$rc"
