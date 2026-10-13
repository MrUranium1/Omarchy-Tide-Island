#!/usr/bin/env bash
#
# wire-shortcuts.sh
#
# Applies the island keybindings to the Hyprland Lua config, written into the
# Tide Island settings app's OWN managed block, so the shortcuts are live
# immediately on a fresh install and stay consistent with the settings app.
#
# The bindings come from the plugin's default user config
# (default/tide-userconfig.json) — the very file the app reads — so the installed
# binds and the app's defaults never drift apart.
#
# Non-destructive and idempotent:
#   * If the managed block already exists (written by the settings app or a
#     previous install) it is left exactly as-is: never duplicated, never
#     overwritten.
#   * A block that predated this plugin is reported as createdByUs=false and is
#     never removed by teardown.
#   * The command path is resolved to the actually-installed Quickshell QML dir,
#     so the binds run the runtime that is present.
#
# Modes:
#   --apply        (default) ensure the managed block exists. Prints one JSON
#                  object (the state install.sh records) on stdout.
#   --print-block  Print only the generated block (used by the tests).
#
# Overrides (mainly for tests):
#   TIDE_ISLAND_HYPRLAND_LUA_CONFIG   config path (default ~/.config/hypr/hyprland.lua)
#   TIDE_ISLAND_BINDINGS_FILE         source userconfig (default plugin default)
#   TIDE_ISLAND_QML_PATH              Quickshell QML dir for the bind command
#   TIDE_ISLAND_PREFIX                bundled runtime prefix
#   TIDE_ISLAND_QUICKSHELL            quickshell binary
#
# Logs go to stderr; stdout stays pure JSON so install.sh can capture it.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE_DIR="$HOME/.local/state/omarchy/tide-island"
INSTALLED_FILE="$STATE_DIR/installed.json"
BACKUPS="$STATE_DIR/backups"

BEGIN_MARKER="-- Tide Island shortcuts: begin (managed by Tide Island Config App)."
END_MARKER="-- Tide Island shortcuts: end."

bindings_file="${TIDE_ISLAND_BINDINGS_FILE:-$ROOT/default/tide-userconfig.json}"
config="${TIDE_ISLAND_HYPRLAND_LUA_CONFIG:-$HOME/.config/hypr/hyprland.lua}"
mode="apply"

usage() {
  cat <<USAGE
Usage: wire-shortcuts.sh [--apply|--print-block] [--bindings-file F] [--config F] [--help]

  --apply        Ensure the managed shortcut block exists (default). Prints the
                 install-state JSON on stdout.
  --print-block  Print the block that would be written, then exit.
  --bindings-file F  Read shortcut bindings from F (default: plugin default).
  --config F     Write the block to F (default: ~/.config/hypr/hyprland.lua).
  --help         Show this help.
USAGE
}

while (( $# )); do
  case "$1" in
    --apply) mode="apply" ;;
    --print-block) mode="print" ;;
    --bindings-file) bindings_file="${2:?}"; shift ;;
    --config) config="${2:?}"; shift ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

log() { printf 'wire-shortcuts: %s\n' "$*" >&2; }

sha_of() { printf '%s\n' "$1" | sha256sum | awk '{print $1}'; }

# The Quickshell QML dir to bind against: whatever is actually installed. Prefer
# the bundled runtime, else derive it from the config app's own location (exactly
# how the settings app resolves it), else fall back to the system path.
resolve_qml_path() {
  if [[ -n ${TIDE_ISLAND_QML_PATH:-} ]]; then
    printf '%s\n' "$TIDE_ISLAND_QML_PATH"
    return 0
  fi
  local prefix="${TIDE_ISLAND_PREFIX:-$HOME/.local/share/omarchy-tide-island}"
  if [[ -d "$prefix/share/tide-island" ]]; then
    printf '%s\n' "$prefix/share/tide-island"
    return 0
  fi
  local app
  app="$(command -v tide-island-config-app 2>/dev/null || true)"
  if [[ -n $app ]]; then
    app="$(readlink -f -- "$app")"
    printf '%s\n' "$(dirname "$(dirname "$app")")/share/tide-island"
    return 0
  fi
  printf '%s\n' "/usr/share/tide-island"
}

resolve_quickshell() {
  if [[ -n ${TIDE_ISLAND_QUICKSHELL:-} ]]; then
    printf '%s\n' "$TIDE_ISLAND_QUICKSHELL"
    return 0
  fi
  local bin
  bin="$(command -v quickshell 2>/dev/null || true)"
  printf '%s\n' "${bin:-/usr/bin/quickshell}"
}

lua_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Emit the managed block (markers + the enabled bindings) on stdout.
generate_block() {
  local qml quickshell mods key target method chord command
  qml="$(resolve_qml_path)"
  quickshell="$(resolve_quickshell)"

  printf '%s\n' "$BEGIN_MARKER"
  printf '%s\n' "-- Empty shortcuts are disabled and intentionally omitted."

  while IFS=$'\t' read -r mods key target method; do
    [[ -n ${key:-} ]] || continue
    chord="${mods// / + }"
    [[ -n $chord ]] && chord="$chord + "
    chord="${chord}${key}"
    command="$quickshell ipc --any-display -p $qml call $target $method"
    printf 'hl.bind(%s, hl.dsp.exec_cmd(%s))\n' "$(lua_quote "$chord")" "$(lua_quote "$command")"
  done < <(jq -r '
    .shortcutBindings[]?
    | select((.key // "") != "")
    | [.mods, .key, .target, .method] | @tsv
  ' "$bindings_file")

  printf '%s\n' "$END_MARKER"
}

# Print the lines of the managed block already present in $1 (begin..end
# inclusive), or nothing when the file has no block.
extract_block() {
  [[ -f $1 ]] || return 0
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { inb = 1 }
    inb { print }
    $0 == e { inb = 0 }
  ' "$1"
}

state_json() { # wired createdByUs blockSha qmlPath backup
  jq -n \
    --argjson wired "$1" \
    --argjson ours "$2" \
    --arg sha "$3" \
    --arg qml "$4" \
    --arg backup "$5" \
    --arg config "$config" \
    '{ wired: $wired, createdByUs: $ours, config: $config,
       blockSha256: $sha, qmlPath: $qml, backup: $backup }'
}

qml_path="$(resolve_qml_path)"

require_bindings() {
  [[ -f $bindings_file ]] || {
    log "bindings file '$bindings_file' not found." >&2
    exit 1
  }
}

if [[ $mode == "print" ]]; then
  require_bindings
  generate_block
  exit 0
fi

# ---------------------------------------------------------------- --apply

if [[ ! -f $config ]]; then
  log "no Hyprland Lua config at $config; leaving shortcuts to the settings app."
  state_json false false "" "$qml_path" ""
  exit 0
fi

# Preserve ownership + the original block hash across re-runs: install.sh
# rewrites installed.json every time, so read the previous record here.
prior_ours=false
prior_sha=""
if [[ -f $INSTALLED_FILE ]]; then
  prior_ours="$(jq -r '.shortcutBinding.createdByUs // false' "$INSTALLED_FILE" 2>/dev/null || echo false)"
  prior_sha="$(jq -r '.shortcutBinding.blockSha256 // empty' "$INSTALLED_FILE" 2>/dev/null || true)"
fi

existing="$(extract_block "$config")"
if [[ -n $existing ]]; then
  # A block is already there (settings app, or a previous install). Never
  # duplicate or overwrite it; remember whether it was ours to begin with.
  block_sha="${prior_sha:-$(sha_of "$existing")}"
  log "managed shortcut block already present in $config; leaving it untouched."
  state_json true "$prior_ours" "$block_sha" "$qml_path" ""
  exit 0
fi

require_bindings
block="$(generate_block)"

mkdir -p "$BACKUPS"
backup="$BACKUPS/$(date +%Y%m%d-%H%M%S).hyprland.lua"
cp "$config" "$backup"
log "backed up $config -> $backup"

was_empty=1
[[ -s $config ]] && was_empty=0
{
  (( was_empty )) || printf '\n'
  printf '%s\n' "$block"
} >>"$config"
log "wired the island shortcuts into $config (apply with hyprctl reload)."

state_json true true "$(sha_of "$block")" "$qml_path" "$backup"
