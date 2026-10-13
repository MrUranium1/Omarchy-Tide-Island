#!/usr/bin/env bash
# scripts/ensure-mount.sh — make the freshly patched OSD/notifications clones
# serve at runtime, now, not only after the next shell restart.
#
# Why this exists
# ----------------
# Omarchy clones a plugin by copying its files, enabling the clone and
# redisabling the original. The shell watches ~/.config/omarchy/plugins and
# reloads the mounted set as soon as clone files appear — which can land while
# ensure-suppression.sh has not yet applied its patch. The on-disk markers then
# exist and installed.json says everything is in place, but the OSD and
# notification popups still come from the old (unpatched) code until the shell
# reloads once more. This script forces that reload after every file is in
# place and verifies, over the shell IPC, that the patched entry points are
# actually the ones serving now. Only then does it mark setup complete.
#
# Callers run it DETACHED (setsid/nohup): the reload it triggers unmounts and
# recreates this plugin's own QML service, and a child process of that service
# would be stranded mid-run by its own reload.
#
# Exit status: 0 = the patched clones are serving at runtime (and --marker was
# written); 1 = they are not, with the reasons and remedies in the state log.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
LOG="$STATE_DIR/ensure-mount.log"
MARKER=""
LIMIT=5

usage() {
  cat <<USAGE
Usage: ensure-mount.sh [--marker <file>] [--help]

Makes the patched OSD/notifications clones serve at runtime by bouncing the
shell's mounted plugin set after the patch files are in place, then verifies
over IPC. --marker touches the given file only once both entry points report
the patched clones serving (so setup is "done" only when it actually is).
USAGE
}

while (( $# )); do
  case "$1" in
    --marker)
      [[ $# -ge 2 ]] || { echo "ensure-mount: --marker needs a path" >&2; exit 2; }
      MARKER="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) echo "ensure-mount: unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR"

log() {
  printf '%s ensure-mount: %s\n' "$(date +%FT%T)" "$*" >>"$LOG"
}

# The patched clones are the versions with the suppression markers; their entry
# points expose `syncSuppression`, which no built-in has. "Function not found."
# is omarchy-shell's exit-1 reply, so a zero exit proves the patched clone is
# the mounted instance.
osd_live() { omarchy-shell osd syncSuppression >/dev/null 2>&1; }
notifications_live() { omarchy-shell notifications syncSuppression >/dev/null 2>&1; }
suppression_live() { osd_live && notifications_live; }

if ! command -v omarchy-shell >/dev/null 2>&1; then
  log "FAILED: omarchy-shell is not on PATH; cannot verify the mounted plugin set."
  echo "ensure-mount: FAILED — omarchy-shell not found; see $LOG" >&2
  exit 1
fi

log "starting (marker=${MARKER:-none})."
if suppression_live; then
  log "suppression already live at runtime; no bounce needed."
  [[ -n $MARKER ]] && { mkdir -p "$(dirname "$MARKER")"; : >"$MARKER"; touch "$MARKER"; log "wrote setup-complete marker $MARKER."; }
  echo "ensure-mount: ok"
  exit 0
fi

mounted_ok=0
attempt=0
while (( attempt < LIMIT && mounted_ok != 1 )); do
  attempt=$((attempt + 1))
  log "bouncing the mounted plugin set (attempt $attempt)."
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 2
  if suppression_live; then
    mounted_ok=1
    break
  fi
done

if (( mounted_ok == 1 )); then
  log "patched clones are now serving at runtime (attempt $attempt)."
  [[ -n $MARKER ]] && { mkdir -p "$(dirname "$MARKER")"; touch "$MARKER"; log "wrote setup-complete marker $MARKER."; }
  echo "ensure-mount: ok"
  exit 0
fi

log "FAILED: the running shell never reported the patched clones after $LIMIT attempts."
log "The files and the enabled-set are correct, but the live OSD/notifications"
log "are still the old code. Remedies:"
log "  * omarchy-restart-shell          # reload everything from disk+config"
log "  * omarchy-shell tide-island setup # re-run install + this bounce"
log "  * omarchy-plugin-list | grep osd # inspect the enabled set"
echo "ensure-mount: FAILED — see $LOG" >&2
exit 1