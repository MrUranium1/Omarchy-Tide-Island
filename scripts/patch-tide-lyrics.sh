#!/usr/bin/env bash
#
# patch-tide-lyrics.sh
#
# OPTIONAL, opt-in helper (never run automatically): applies
# patches/tide/swipe-lyrics-no-cover.patch to a Tide Island source tree so the
# swipe-lyrics island shows no album-cover art. This is a personal preference;
# the plugin works perfectly without it.
#
# It targets the Tide source the running service uses (the TIDE_ISLAND_QML_PATH
# override when present, otherwise the system copy), backs the file up before
# patching, and can reverse the change with --restore.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PATCH="$ROOT/patches/tide/swipe-lyrics-no-cover.patch"
TARGET="qml/island/SwipeLyricsLayer.qml"
BACKUP_ROOT="$HOME/.local/state/omarchy/tide-island/backups"
mode="apply"
tide_dir=""

resolve_tide_dir() {
  # 1) explicit --dir
  if [[ -n $tide_dir ]]; then
    echo "$tide_dir"
    return 0
  fi
  # 2) the override the running service uses
  local override env_val
  override="$HOME/.config/systemd/user/tide-island.service.d/override.conf"
  if [[ -f $override ]]; then
    env_val="$(sed -n 's/^[[:space:]]*Environment=.*TIDE_ISLAND_QML_PATH=\([^[:space:]"'"'"']*\).*/\1/p' "$override" | head -1)"
    if [[ -n $env_val && -d $env_val ]]; then
      echo "$env_val"
      return 0
    fi
  fi
  # 3) system copy
  echo "/usr/share/tide-island"
}

usage() {
  cat <<USAGE
Usage: patch-tide-lyrics.sh [--dir PATH] [--restore] [--help]

  --dir PATH   Tide Island source tree to patch (default: the one the running
               service uses, or /usr/share/tide-island).
  --restore    Undo the change (restores the pre-patch backup, or reverse-applies).
  --help       Show this help.
USAGE
}

log() { printf 'patch-tide-lyrics: %s\n' "$*"; }

while (( $# )); do
  case "$1" in
    --dir) tide_dir="${2:-}" && shift 2 ;;
    --restore) mode="restore" && shift ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
done

dir="$(resolve_tide_dir)"
file="$dir/$TARGET"
if [[ ! -f $file ]]; then
  log "target file '$file' not found. Pass --dir for the Tide source tree." >&2
  exit 1
fi

if [[ $mode == "restore" ]]; then
  backup="$(ls -1t "$BACKUP_ROOT"/*.$(basename "$dir").lyrics 2>/dev/null | head -1 || true)"
  if [[ -n $backup ]]; then
    cp "$backup" "$file"
    log "restored $file from backup."
  elif patch -p1 -R --batch --dry-run -d "$dir" <"$PATCH" >/dev/null 2>&1; then
    patch -p1 -R --batch -d "$dir" <"$PATCH" >/dev/null
    log "reverted patch in $file."
  else
    log "nothing to restore for $dir."
  fi
  exit 0
fi

if grep -q "id: lyricViewport" "$file" && grep -q "anchors.left: parent.left" "$file"; then
  log "already patched; leaving alone."
  exit 0
fi

if [[ ! -w $dir ]]; then
  log "'$dir' is not writable. System Tide copies need root:"
  log "  sudo scripts/patch-tide-lyrics.sh --dir /usr/share/tide-island"
  exit 1
fi

mkdir -p "$BACKUP_ROOT"
backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).$(basename "$dir").lyrics"
cp "$file" "$backup"
log "backed up $file -> $backup"

if patch -p1 --batch -d "$dir" <"$PATCH"; then
  log "patched $file (album cover art removed from swipe lyrics)."
else
  log "patching failed; restoring backup." >&2
  cp "$backup" "$file"
  exit 1
fi
log "restart Tide Island (systemctl --user restart tide-island) to see it."