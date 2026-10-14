#!/usr/bin/env bash
#
# ensure-suppression.sh
#
# Makes the Omarchy OSD and notification stack stand down while Tide Island is
# on screen. It does this without touching built-ins: it clones omarchy.osd /
# omarchy.notifications into ~/.config/omarchy/plugins/<user>.<role>/ and applies
# a small patch that hides each overlay whenever the bar-off flag is present.
#
# Idempotent and reversible:
#   * Already patched clones are detected (by marker comment) and left alone.
#   * We record whether a patch was ours or predated the plugin; --restore only
#     undoes patches this plugin applied. A clone that already carried the
#     suppression (yours, before the plugin) is never stripped.
#   * Files that were pristine when we patched them are backed up into
#     ~/.local/state/omarchy/tide-island/backups/ and restored exactly.
#   * Clones that predate the plugin are preserved, not removed; unrelated user
#     edits to the same file survive too.
#
# See patches/omarchy-osd-suppression.patch and
# patches/omarchy-notifications-suppression.patch (also in README.md).

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
BACKUPS_DIR="$STATE_DIR/backups"
STATE_MARKERS="$STATE_DIR/patch-state"
CREATED_CLONES="$STATE_DIR/created-clones"
CLONE_BASELINES="$STATE_DIR/clone-baselines"
OMARCHY_SHELL_DIR="/usr/share/omarchy/shell/plugins"

mode="apply"

usage() {
  cat <<USAGE
Usage: ensure-suppression.sh [--restore] [--help]

  --restore   Undo the suppression patches (reverse of --apply). Clones that
              predate this plugin are kept; only the suppression is removed.
  --help      Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --restore) mode="restore" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

# source id -> entry-point kind
role_settings() {
  case "$1" in
    omarchy.osd)
      echo "osd|panel|The bar-off marker|patches/omarchy-osd-suppression.patch"
      ;;
    omarchy.notifications)
      echo "notifications|service|popupsSuppressed|patches/omarchy-notifications-suppression.patch"
      ;;
  esac
}

clone_id_for() {
  local source="$1"
  omarchy-plugin-list --json 2>/dev/null | jq -r --arg s "$source" '
    (first(([.[] | select(.firstParty == false and .clonedFrom == $s and .enabled)])[0].id // empty)) //
    (first(([.[] | select(.firstParty == false and .clonedFrom == $s)])[0].id // empty)) //
    empty'
}

entry_pts() {
  local id="$1"
  jq -r '.entryPoints.panel // .entryPoints.service // .entryPoints.barWidget // empty' "$PLUGINS_DIR/$id/manifest.json"
}

source_basename() { echo "${1#omarchy.}"; }

log() { printf 'ensure-suppression: %s\n' "$*" >&2; }

# Remember whether THIS plugin applied the patch to a clone ("applied") or the
# clone was already patched before we got here ("preexisting"). --restore only
# ever undoes patches we applied ourselves, so a clone that already carried the
# suppression is never silently stripped.
record_state() { mkdir -p "$STATE_MARKERS"; printf '%s\n' "$2" >"$STATE_MARKERS/$1"; }
read_state() { cat "$STATE_MARKERS/$1" 2>/dev/null || true; }
clear_state() { rm -f "$STATE_MARKERS/$1"; }

ensure_clone() {
  local source="$1"
  local id
  id="$(clone_id_for "$source")"
  if [[ -n $id ]]; then
    log "using existing clone '$id' of $source."
    echo "$id"
    return 0
  fi
  log "cloning $source (Tide Island needs a patchable copy)..."
  omarchy plugin clone "$source" >/dev/null
  id="$(clone_id_for "$source")"
  if [[ -z $id ]]; then
    log "clone of $source was not discovered; is the omarchy shell running?" >&2
    return 1
  fi
  mkdir -p "$CREATED_CLONES"
  : >"$CREATED_CLONES/$id"
  mkdir -p "$CLONE_BASELINES"
  if [[ ! -f "$CLONE_BASELINES/$id" ]]; then
    clone_fingerprint "$PLUGINS_DIR/$id" >"$CLONE_BASELINES/$id.tmp"
    mv "$CLONE_BASELINES/$id.tmp" "$CLONE_BASELINES/$id"
  fi
  log "created clone '$id'."
  echo "$id"
}

clone_fingerprint() {
  local dir="$1"
  (
    cd "$dir"
    find . -mindepth 1 -printf '%y %m %P %l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) | sha256sum | cut -d' ' -f1
}

apply_to_role() {
  local source="$1" short kind marker relpatch
  IFS='|' read -r short kind marker relpatch <<<"$(role_settings "$source")"

  local id file patch
  id="$(ensure_clone "$source")" || return 1
  file="$PLUGINS_DIR/$id/$(entry_pts "$id")"
  patch="$ROOT/$relpatch"
  [[ -f "$file" ]] || {
    log "expected file '$file' is missing; skipping $source suppression." >&2
    return 1
  }

  if grep -q "$marker" "$file"; then
    if [[ -z $(read_state "$id") ]]; then
      record_state "$id" preexisting
      log "$source already carried this suppression before the plugin; recording it as preexisting and leaving it untouched (including on --restore)."
    else
      log "$source already patched ('$marker' found); leaving it alone."
    fi
    return 0
  fi

  mkdir -p "$BACKUPS_DIR"
  local backup="$BACKUPS_DIR/$(date +%Y%m%d-%H%M%S.%N).$id.$(basename "$file")"
  cp "$file" "$backup"
  log "backed up $file -> $backup"

  if patch -p1 --batch --no-backup -d "$PLUGINS_DIR/$id" <"$patch"; then
    record_state "$id" applied
    if [[ -f "$CREATED_CLONES/$id" && ! -f "$CLONE_BASELINES/$id" ]]; then
      mkdir -p "$CLONE_BASELINES"
      clone_fingerprint "$PLUGINS_DIR/$id" >"$CLONE_BASELINES/$id.tmp"
      mv "$CLONE_BASELINES/$id.tmp" "$CLONE_BASELINES/$id"
    fi
    log "patched $id."
  else
    log "patching $id FAILED; restoring backup." >&2
    cp "$backup" "$file"
    return 1
  fi
}

restore_role() {
  local source="$1" short kind marker relpatch
  IFS='|' read -r short kind marker relpatch <<<"$(role_settings "$source")"

  local id file patch upstream
  id="$(clone_id_for "$source")"
  [[ -n $id ]] || {
    log "no clone of $source; nothing to restore."
    return 0
  }
  file="$PLUGINS_DIR/$id/$(entry_pts "$id")"
  patch="$ROOT/$relpatch"
  upstream="$OMARCHY_SHELL_DIR/$(source_basename "$source")/$(basename "$file")"

  # Never undo a suppression the user already had before this plugin. Only
  # patches we applied ourselves (recorded as "applied") are reversed.
  local state
  state="$(read_state "$id")"
  if [[ $state == preexisting ]]; then
    log "'$id' was suppressed before this plugin; leaving it untouched."
    return 0
  fi
  if [[ -z $state ]]; then
    log "no record of this plugin patching '$id'; leaving it untouched."
    return 0
  fi

  # 1) If the user already restored the original, just clear our marker.
  local backup
  backup="$(ls -1t "$BACKUPS_DIR"/*."$id".$(basename "$file") 2>/dev/null | head -1 || true)"
  if [[ -n $backup ]] && cmp -s "$backup" "$file"; then
    clear_state "$id"
    log "$file is already pristine; cleared the plugin marker."
    return 0
  fi

  # 2) Already pristine (never patched / already reverted).
  if [[ -f $upstream ]] && cmp -s "$file" "$upstream"; then
    clear_state "$id"
    log "$file is already pristine."
    return 0
  fi

  if [[ -n $backup && -f $patch ]] && command -v diff3 >/dev/null 2>&1; then
    local restore_dir restore_entry merge_status
    restore_dir="$(mktemp -d "${TMPDIR:-/tmp}/tide-island-restore.XXXXXX")"
    restore_entry="$restore_dir/patched/$(basename "$file")"
    mkdir -p "$(dirname "$restore_entry")"
    cp -p "$backup" "$restore_entry"
    if patch -p1 --batch --no-backup -d "$(dirname "$restore_entry")" <"$patch" >/dev/null 2>&1; then
      merge_status=0
      diff3 -m "$file" "$restore_entry" "$backup" >"$restore_dir/merged" || merge_status=$?
      if (( merge_status == 0 )); then
        chmod --reference="$file" "$restore_dir/merged"
        mv -f "$restore_dir/merged" "$file"
        clear_state "$id"
        rm -rf -- "$restore_dir"
        log "reverted the suppression patch in $id; unrelated clone edits were preserved."
        return 0
      fi
    fi
    rm -rf -- "$restore_dir"
  fi

  log "cannot automatically un-apply suppression in '$id' ($file) because it"
  log "the current file conflicts with the patch. It and its backup were preserved."
  log "Review $file and $backup, then restore or merge the suppression manually." >&2
  return 1
}

mkdir -p "$PLUGINS_DIR" "$STATE_DIR"

if [[ $mode == "restore" ]]; then
  restore_role omarchy.osd || true
  restore_role omarchy.notifications || true
else
  apply_to_role omarchy.osd || true
  apply_to_role omarchy.notifications || true
fi

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins 2>/dev/null || true
  omarchy-shell -q osd syncSuppression 2>/dev/null || true
  omarchy-shell -q notifications syncSuppression 2>/dev/null || true
fi
log "done (mode=$mode)."