#!/usr/bin/env bash
#
# install-dependencies.sh
#
# Reports whether the Tide Island plugin's runtime and tooling dependencies are
# present. Read-only by default; pass --install to offer to install the missing
# Arch packages (requires sudo, so run from a terminal via scripts/setup).

set -Eeuo pipefail

mode="check"

usage() {
  cat <<USAGE
Usage: install-dependencies.sh [--install] [--help]

  --install   Offer to install missing packages (needs sudo).
  --help      Show this help.

Exit 0 when all required dependencies are present, 1 otherwise.
USAGE
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --install) mode="install" ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage >&2 && exit 2 ;;
    esac
    shift
  done
}

REQUIRED=(
  "tide-island:tide-island:the Pacific Dawn-inspired dynamic island"
  "quickshell:quickshell:the QtQuick shell that renders Tide Island"
  "jq:jq:for reading the plugin config file"
  "patch:patch:for patching the OSD/notifications clones"
)
OPTIONAL=(
  "python3:python:only for the pretty CLI status screen"
)

have() { command -v "$1" >/dev/null 2>&1; }

check() {
  local ok=0 name pkg desc
  for entry in "$@"; do
    IFS=: read -r name pkg desc < <(printf '%s\n' "$entry")
    if have "$name"; then
      printf '  %-14s present\n' "$name"
    else
      printf '  %-14s MISSING   %s\n' "$name" "$desc"
      ok=1
    fi
  done
  return $ok
}

main() {
  parse_args "$@"

  echo "Tide Island plugin dependencies"
  echo "  required:"
  check "${REQUIRED[@]}" || missing=1
  echo "  optional:"
  check "${OPTIONAL[@]}" || true

  if [[ ${missing:-0} == 1 && $mode == "install" ]]; then
    echo
    echo "Installing missing required packages (pacman -S ...)"
    local to_install=()
    for entry in "${REQUIRED[@]}"; do
      IFS=: read -r name pkg _ < <(printf '%s\n' "$entry")
      have "$name" || to_install+=("$pkg")
    done
    if ((${#to_install[@]})); then
      sudo pacman -S --needed "${to_install[@]}"
    fi
    echo "Re-checking..."
    missing=0
    check "${REQUIRED[@]}" || missing=1
  fi

  if [[ ${missing:-0} == 1 ]]; then
    [[ $mode == "check" ]] && echo
    echo "Some required dependencies are missing. Run this again with --install"
    echo "(or install them manually) before the plugin can work."
    exit 1
  fi
  echo "All required dependencies are present."
}

main "$@"