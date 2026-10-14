#!/usr/bin/env bash
#
# install-tide-runtime.sh
#
# Installs the bundled Tide Island runtime into an unprivileged prefix under
# $HOME (no sudo, no system-wide changes) so the island works without the user
# installing the `tide-island` package. The launcher resolves its resources
# relative to itself, so any prefix works.
#
#   PREFIX  ~/.local/share/omarchy-tide-island   (override: TIDE_ISLAND_PREFIX)
#
# If a tide-island is already available on PATH (e.g. the package is installed),
# this does nothing, so it never clobbers a system install. Idempotent.
#
# Exit 0 when the runtime is available, 1 on failure.

set -Eeuo pipefail

log() { printf 'install-tide-runtime: %s\n' "$*" >&2; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VENDOR="$ROOT/vendor/tide-island"
PREFIX="${TIDE_ISLAND_PREFIX:-$HOME/.local/share/omarchy-tide-island}"
SYSTEMCTL="${TIDE_SYNC_SYSTEMCTL:-systemctl}"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
APPS_DIR="$HOME/.local/share/applications"
SERVICE="tide-island.service"
UNIT="$UNIT_DIR/$SERVICE"
UNIT_MARKER="# managed by mehir.tide-island"
VERSION_FILE="$PREFIX/.version"
CONTENT_FILE="$PREFIX/.content-sha256"

[[ -x "$VENDOR/bin/tide-island" ]] || {
  log "bundled runtime missing at $VENDOR (corrupt checkout?)"
  exit 1
}
VERSION="$(cat "$VENDOR/VERSION" 2>/dev/null || echo unknown)"

# A stable fingerprint of the actual files we ship (not just the version
# string), so local changes to the vendored tree are redeployed even when
# upstream's VERSION is unchanged.
vendor_content_hash() {
  local h=""
  h="$( cd "$VENDOR" 2>/dev/null \
    && { find bin lib share -type f -print0 2>/dev/null \
      | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; } )" \
    || true
  printf '%s' "$h"
}
CONTENT_HASH="$(vendor_content_hash)"

already_on_path=0
if [[ ${TIDE_ISLAND_FORCE_BUNDLE:-0} == 1 ]]; then
  already_on_path=0
else
  found="$(command -v tide-island 2>/dev/null || true)"
  # 'command -v' may report our own ~/.local/bin link; resolve it and compare
  # real paths so a system install is the only thing that counts.
  if [[ -n $found && "$(readlink -f -- "$found")" != "$PREFIX/bin/tide-island" ]]; then
    already_on_path=1
  fi
fi

# ------------------------------------------------------------- copy the tree

if (( already_on_path )); then
  log "a tide-island is already on PATH ('$(command -v tide-island)'); leaving it alone."
else
  if [[ "$(cat "$VERSION_FILE" 2>/dev/null || true)" == "$VERSION" ]] \
    && [[ "$(cat "$CONTENT_FILE" 2>/dev/null || true)" == "$CONTENT_HASH" ]] \
    && [[ -x "$PREFIX/bin/tide-island" ]] \
    && [[ -x "$PREFIX/bin/tide-island-config-app" ]]; then
    log "bundled Tide Island $VERSION already installed at $PREFIX."
  else
    if [[ "$(cat "$VERSION_FILE" 2>/dev/null || true)" == "$VERSION" ]] \
      && [[ -x "$PREFIX/bin/tide-island" ]]; then
      log "refreshing bundled Tide Island $VERSION at $PREFIX (content changed)."
    else
      log "installing bundled Tide Island $VERSION -> $PREFIX"
    fi
    rm -rf "${PREFIX:?}/bin" "${PREFIX:?}/lib" "${PREFIX:?}/share"
    mkdir -p "$PREFIX"
    cp -a "$VENDOR/bin" "$VENDOR/lib" "$VENDOR/share" "$PREFIX/"
    chmod 0755 "$PREFIX/bin/tide-island" "$PREFIX/bin/tide-island-config-app"
    [[ -d "$PREFIX/share/tide-island/bin" ]] \
      && chmod 0755 "$PREFIX/share/tide-island/bin/"* 2>/dev/null || true
    printf '%s\n' "$VERSION" >"$VERSION_FILE"
    printf '%s\n' "$CONTENT_HASH" >"$CONTENT_FILE"
  fi
fi

# --------------------------------------------------------------- user service

write_unit() {
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT" <<UNIT_FILE
$UNIT_MARKER
[Unit]
Description=Tide Island Dynamic Island (bundled by the mehir.tide-island plugin)
After=graphical-session.target

[Service]
Type=simple
ExecStart=$PREFIX/bin/tide-island
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
UNIT_FILE
}

if (( already_on_path )); then
  : # a system unit already ships with the package
elif [[ -f $UNIT ]] && ! grep -qF "$UNIT_MARKER" "$UNIT"; then
  log "keeping your existing $UNIT (not managed by this plugin)."
else
  write_unit
  log "wrote $UNIT"
  if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  fi
fi

# ------------------------------------------------------------------ PATH shim

if (( ! already_on_path )); then
  mkdir -p "$BIN_DIR"
  for name in tide-island tide-island-config-app; do
    target="$BIN_DIR/$name"
    if [[ -e $target && ! -L $target ]]; then
      log "keeping pre-existing $target (not a symlink)."
    else
      ln -sf "$PREFIX/bin/$name" "$target"
      log "linked $target -> $PREFIX/bin/$name"
    fi
  done
fi

# --------------------------------------------------------------- desktop entry

if [[ -f "$VENDOR/share/applications/tide-island.desktop" ]]; then
  mkdir -p "$APPS_DIR"
  install -m 0644 "$VENDOR/share/applications/tide-island.desktop" \
    "$APPS_DIR/tide-island.desktop"
fi
if [[ -f "$VENDOR/share/applications/tide-island-config.desktop" ]]; then
  mkdir -p "$APPS_DIR"
  install -m 0644 "$VENDOR/share/applications/tide-island-config.desktop" \
    "$APPS_DIR/tide-island-config.desktop"
fi

log "done (prefix=$PREFIX, version=$VERSION)."
