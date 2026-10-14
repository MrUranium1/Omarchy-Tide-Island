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
SYMLINK_FILE="$PREFIX/.symlink-sha256"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
DESKTOP_STATE="$STATE_DIR/desktop-entries.json"
PATH_STATE="$STATE_DIR/path-links.json"

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

installed_content_hash() {
  local prefix="$1"
  (
    cd "$prefix" 2>/dev/null \
      && { find bin lib share -type f -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; }
  )
}

symlink_hash() {
  local dir="$1"
  (
    cd "$dir"
    find bin lib share -type l -printf '%p %l\n' 2>/dev/null | LC_ALL=C sort
  ) | sha256sum | cut -d' ' -f1
}

VENDOR_SYMLINK_HASH="$(symlink_hash "$VENDOR")"
installed_hash=""
installed_symlink_hash=""
if [[ -d $PREFIX ]]; then
  installed_hash="$(installed_content_hash "$PREFIX" || true)"
  installed_symlink_hash="$(symlink_hash "$PREFIX" || true)"
fi
prefix_extras=""
if [[ -d $PREFIX ]]; then
  prefix_extras="$(find "$PREFIX" -mindepth 1 -maxdepth 1 \
    ! -name bin ! -name lib ! -name share ! -name .version ! -name .content-sha256 \
    ! -name .symlink-sha256 ! -name .unit-sha256 -print -quit)"
fi

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
    && [[ "$installed_hash" == "$CONTENT_HASH" && -z $prefix_extras ]] \
    && [[ "$installed_symlink_hash" == "$VENDOR_SYMLINK_HASH" ]] \
    && [[ -x "$PREFIX/bin/tide-island" ]] \
    && [[ -x "$PREFIX/bin/tide-island-config-app" ]]; then
    log "bundled Tide Island $VERSION already installed at $PREFIX."
  else
    if [[ -e $PREFIX ]]; then
      if [[ ! -f $VERSION_FILE || ! -f $CONTENT_FILE ]]; then
        log "refusing to replace unverified files at $PREFIX; move or remove them manually if they are yours."
        exit 1
      fi
      previous_content="$(cat "$CONTENT_FILE")"
      actual_content="$(installed_content_hash "$PREFIX" || true)"
      recorded_symlinks="$(cat "$SYMLINK_FILE" 2>/dev/null || true)"
      [[ -n $recorded_symlinks ]] || recorded_symlinks="$VENDOR_SYMLINK_HASH"
      extra_prefix_files="$(find "$PREFIX" -mindepth 1 -maxdepth 1 \
        ! -name bin ! -name lib ! -name share ! -name .version ! -name .content-sha256 \
        ! -name .symlink-sha256 ! -name .unit-sha256 -print -quit)"
      if [[ -z $previous_content || $actual_content != "$previous_content" \
        || $installed_symlink_hash != "$recorded_symlinks" || -n $extra_prefix_files ]]; then
        log "refusing to replace a modified runtime prefix at $PREFIX; preserve or back up its contents before repairing."
        exit 1
      fi
    fi
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
    printf '%s\n' "$VENDOR_SYMLINK_HASH" >"$SYMLINK_FILE"
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
elif [[ -L $UNIT || ( -e $UNIT && ! -f $UNIT ) ]]; then
  log "keeping existing non-regular service unit path $UNIT."
elif [[ -f $UNIT ]] && ! grep -qF "$UNIT_MARKER" "$UNIT"; then
  log "keeping your existing $UNIT (not managed by this plugin)."
elif [[ -f $UNIT ]] && [[ -n $(cat "$PREFIX/.unit-sha256" 2>/dev/null || true) ]] \
  && [[ $(sha256sum "$UNIT" | cut -d' ' -f1) == "$(cat "$PREFIX/.unit-sha256")" ]]; then
  log "managed unit $UNIT is unchanged."
elif [[ -f $UNIT ]] && [[ -n $(cat "$PREFIX/.unit-sha256" 2>/dev/null || true) ]] \
  && [[ $(sha256sum "$UNIT" | cut -d' ' -f1) != "$(cat "$PREFIX/.unit-sha256")" ]]; then
  log "keeping user-modified managed unit $UNIT."
elif [[ -f $UNIT ]]; then
  log "keeping unverified managed-looking unit $UNIT; ownership metadata is missing."
else
  write_unit
  sha256sum "$UNIT" | cut -d' ' -f1 >"$PREFIX/.unit-sha256"
  log "wrote $UNIT"
  if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  fi
fi

# ------------------------------------------------------------------ PATH shim

if (( ! already_on_path )); then
  mkdir -p "$BIN_DIR"
  path_state="$(cat "$PATH_STATE" 2>/dev/null || printf '{}')"
  for name in tide-island tide-island-config-app; do
    target="$BIN_DIR/$name"
    expected="$(jq -r --arg n "$name" '.[$n] // empty' <<<"$path_state")"
    if [[ -e $target || -L $target ]]; then
      if [[ -L $target && $expected == "$PREFIX/bin/$name" ]] \
        && [[ $(readlink "$target") == "$expected" ]]; then
        log "managed PATH link $target is unchanged."
      else
        log "keeping existing unowned or user-modified PATH entry $target."
      fi
    else
      if ln -s "$PREFIX/bin/$name" "$target" 2>/dev/null; then
        path_state="$(jq -c --arg n "$name" --arg p "$PREFIX/bin/$name" '.[$n] = $p' <<<"$path_state")"
        mkdir -p "$STATE_DIR"
        path_tmp="$(mktemp "$STATE_DIR/.path-links.XXXXXX")"
        printf '%s\n' "$path_state" >"$path_tmp"
        mv -f "$path_tmp" "$PATH_STATE"
        log "linked $target -> $PREFIX/bin/$name"
      else
        log "keeping PATH entry created concurrently at $target."
      fi
    fi
  done
fi

# --------------------------------------------------------------- desktop entry

desktop_hash() { sha256sum "$1" | cut -d' ' -f1; }
desktop_state="$(cat "$DESKTOP_STATE" 2>/dev/null || printf '{}')"

install_desktop_entry() {
  local name="$1" source="$VENDOR/share/applications/$1" target="$APPS_DIR/$1"
  local expected current tmp state_tmp hash
  [[ -f $source ]] || return 0
  expected="$(jq -r --arg n "$name" '.[$n] // empty' <<<"$desktop_state")"

  if [[ -e $target || -L $target ]]; then
    if [[ -n $expected && -f $target && ! -L $target ]] \
      && [[ $(desktop_hash "$target") == "$expected" ]]; then
      current="$(desktop_hash "$source")"
      [[ $current == "$expected" ]] && return 0
      mkdir -p "$STATE_DIR/backups"
      cp -p "$target" "$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S.%N).$name.desktop"
      tmp="$(mktemp "$APPS_DIR/.${name}.XXXXXX")"
      install -m 0644 "$source" "$tmp"
      mv -f "$tmp" "$target"
      hash="$(desktop_hash "$target")"
      desktop_state="$(jq -c --arg n "$name" --arg h "$hash" '.[$n] = $h' <<<"$desktop_state")"
      state_tmp="$(mktemp "$STATE_DIR/.desktop-entries.XXXXXX")"
      printf '%s\n' "$desktop_state" >"$state_tmp"
      mv -f "$state_tmp" "$DESKTOP_STATE"
      log "updated managed desktop entry $target (previous version backed up)."
      return 0
    fi
    log "keeping existing unowned or user-modified desktop entry $target."
    return 0
  fi

  mkdir -p "$APPS_DIR" "$STATE_DIR"
  tmp="$(mktemp "$APPS_DIR/.${name}.XXXXXX")"
  install -m 0644 "$source" "$tmp"
  hash="$(desktop_hash "$tmp")"
  if ln "$tmp" "$target" 2>/dev/null; then
    desktop_state="$(jq -c --arg n "$name" --arg h "$hash" '.[$n] = $h' <<<"$desktop_state")"
    state_tmp="$(mktemp "$STATE_DIR/.desktop-entries.XXXXXX")"
    printf '%s\n' "$desktop_state" >"$state_tmp"
    mv -f "$state_tmp" "$DESKTOP_STATE"
    log "installed and recorded ownership of $target."
  else
    log "keeping desktop entry created concurrently at $target."
  fi
  rm -f "$tmp"
}

install_desktop_entry tide-island.desktop
install_desktop_entry tide-island-config.desktop

log "done (prefix=$PREFIX, version=$VERSION)."
