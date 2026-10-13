#!/usr/bin/env bash
#
# plugin-setup.sh
#
# Sets up every piece of the plugin: the bundled Tide Island runtime,
# OSD/notifications stand-down, CLI shims, config seed, keybinding module and a
# first reconcile. Safe to run repeatedly.
#
#   (no args)   interactive; opened in a terminal by `omarchy-shell tide-island
#               setup`, and offers to install missing packages.
#   --auto      non-interactive; run by the shell service on first load so a
#               freshly added plugin sets itself up silently.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  cat <<USAGE
Usage: plugin-setup.sh [--auto] [--help]

  --auto   Non-interactive setup (no prompts, no terminal). Used on first load.
  --help   Show this help.
USAGE
}

mode="interactive"
while (( $# )); do
  case "$1" in
    --auto) mode="auto" ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
  shift
done

if [[ $mode == "auto" ]]; then
  exec bash "$ROOT/install.sh"
fi

echo "== Tide Island plugin setup =="
echo

echo "1/2 Dependencies"
bash "$ROOT/scripts/install-dependencies.sh" || {
  printf '\nInstall the missing packages now? [y/N] '
  read -r ans
  if [[ ${ans,,} == "y" ]]; then
    bash "$ROOT/scripts/install-dependencies.sh" --install || true
  fi
}

echo
echo "2/2 Runtime, suppression, CLI shims, config, keybinding + first reconcile"
bash "$ROOT/install.sh" || {
  printf '\ninstall.sh failed; fix the reported issue and re-run setup.\n' >&2
  exit 1
}

echo
echo "== Setup finished =="
echo "  press SUPER + SHIFT + SPACE to toggle bar and Tide Island together"
echo "  run omarchy-tide-island-status for a live health readout"
read -r -p "Press Enter to close." _
