#!/usr/bin/env bash
#
# tide-sync.sh
#
# Core state machine shared by the Tide Island Omarchy plugin. It keeps the
# tide-island systemd service synchronized with the Omarchy "bar-off" flag:
#
#   bar hidden (bar-off present)  ->  tide-island.service should be running
#   bar visible (bar-off absent)  ->  tide-island.service should be stopped
#
# Everything is configurable through ~/.config/omarchy/tide-island.json (see
# default/tide-island.json for the schema and defaults). Start/stop is
# idempotent, so this script is safe to run from any trigger: the plugin's
# flag watcher, the Super+Shift+Space keybinding, or a manual `omarchy toggle bar`.
#
# Exit codes are always 0 unless the script itself is mis-invoked. A failed
# service start/stop is reported on stderr but does not poison the watcher
# loop that calls this script repeatedly.

set -Eeuo pipefail

# ------------------------------------------------------------------ resolve paths

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_CONFIG="$ROOT/default/tide-island.json"

CONFIG_FILE="${TIDE_ISLAND_CONFIG:-$HOME/.config/omarchy/tide-island.json}"
SYSTEMCTL="${TIDE_SYNC_SYSTEMCTL:-systemctl}"
DRY_RUN=0

# ------------------------------------------------------------- config access

# Merge the shipped defaults with the user config (user wins) into stdout.
merged_config() {
  jq -s '.[0] * .[1] | { config: . }' "$DEFAULT_CONFIG" "$CONFIG_FILE" 2>/dev/null \
    || jq -s '.[0] | { config: . }' "$DEFAULT_CONFIG"
}

# Expand "~" / "$HOME" and other simple variables in a config path.
expand_path() {
  local value="${1//\~/$HOME}"
  value="${value//\$\{HOME\}/$HOME}"
  value="${value//\$HOME/$HOME}"
  printf '%s' "$value"
}

load_config() {
  CONFIG_JSON="$(merged_config)"
}

json_field() {
  jq -r --arg key "$1" '.config[$key] // empty' <<<"$CONFIG_JSON"
}

# ---------------------------------------------------------------- derived state

flag_path() {
  local dir file
  dir="$(json_field togglesDir)"
  file="$(json_field barOffFile)"
  dir="$(expand_path "${dir:-$HOME/.local/state/omarchy/toggles}")"
  file="${file:-bar-off}"
  printf '%s/%s' "$dir" "$file"
}

bar_is_hidden() {
  [[ -f "$(flag_path)" ]]
}

service_name() {
  json_field serviceName
}

# ------------------------------------------------------------------- commands

usage() {
  cat <<USAGE
Usage: tide-sync.sh <reconcile|probe|config> [--dry-run] [--help]

Keeps the Tide Island systemd service synchronized with the Omarchy bar-off
flag. Shared by the mehir.tide-island shell service and its CLI.

Commands:
  reconcile   Start or stop the tide systemd service to match the bar flag.
  probe       Print "bar-hidden" or "bar-visible".
  config      Print the effective configuration as JSON.

Options:
  --dry-run   Print the action instead of running systemctl.
  --help      Show this help.

Environment overrides (mainly for tests):
  TIDE_ISLAND_CONFIG          path to the user config file
  TIDE_SYNC_DRY_RUN=1         equivalent to --dry-run
  TIDE_SYNC_SYSTEMCTL         systemctl command (default "systemctl")
USAGE
}

service_current() {
  local name
  name="$(service_name)"
  "$SYSTEMCTL" --user is-active "$name" 2>/dev/null || true
}

ensure_tide_running() {
  local name current
  name="$(service_name)"
  current="$(service_current)"
  if [[ $current == "active" ]]; then
    log "tide-sync: $name is already active."
    return 0
  fi
  if (( DRY_RUN )); then
    log "tide-sync: [dry-run] would start $name (current: ${current:-unknown})."
    return 0
  fi
  if "$SYSTEMCTL" --user start "$name"; then
    log "tide-sync: started $name."
  else
    log "tide-sync: FAILED to start $name." >&2
  fi
}

ensure_tide_stopped() {
  local name current
  name="$(service_name)"
  current="$(service_current)"
  if [[ $current == "inactive" || $current == "dead" ]]; then
    log "tide-sync: $name is already stopped."
    return 0
  fi
  if (( DRY_RUN )); then
    log "tide-sync: [dry-run] would stop $name (current: ${current:-unknown})."
    return 0
  fi
  if "$SYSTEMCTL" --user stop "$name"; then
    log "tide-sync: stopped $name."
  else
    log "tide-sync: FAILED to stop $name." >&2
  fi
}

cmd_reconcile() {
  load_config

  if [[ $(json_field coordinateWithBar) != "true" ]]; then
    log "tide-sync: coordination disabled (coordinateWithBar=false); leaving $(
      service_name
    ) alone."
    return 0
  fi

  if [[ $(json_field serviceName) == "null" || -z "$(service_name)" ]]; then
    log "tide-sync: no serviceName configured; nothing to do." >&2
    return 0
  fi

  if bar_is_hidden; then
    if [[ $(json_field startWithBarHidden) == "true" ]]; then
      ensure_tide_running
    else
      log "tide-sync: bar hidden but startWithBarHidden=false; leaving service alone."
    fi
  else
    if [[ $(json_field stopWithBarShown) == "true" ]]; then
      ensure_tide_stopped
    else
      log "tide-sync: bar visible but stopWithBarShown=false; leaving service alone."
    fi
  fi
}

cmd_probe() {
  load_config
  if bar_is_hidden; then
    printf 'bar-hidden\n'
  else
    printf 'bar-visible\n'
  fi
}

cmd_config() {
  load_config
  jq '{ config: .config }' <<<"$CONFIG_JSON" 2>/dev/null || printf '%s\n' "$CONFIG_JSON"
}

log() {
  printf '%s\n' "$*"
}

# ---------------------------------------------------------------------- main

main() {
  local command=""
  while (( $# )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        if [[ -z "$command" ]]; then
          command="$1"
        else
          usage >&2
          return 2
        fi
        ;;
    esac
    shift
  done

  [[ -n $command ]] || {
    usage >&2
    return 2
  }

  case "$command" in
    reconcile) cmd_reconcile ;;
    probe) cmd_probe ;;
    config) cmd_config ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"