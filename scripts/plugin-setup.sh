#!/usr/bin/env bash
#
# plugin-setup.sh
#
# Interactive setup launcher, opened in a terminal by
# `omarchy-shell tide-island setup`. Runs every opt-in piece of the plugin:
# dependency check (+ optional install), OSD/notifications suppression, CLI
# shims, config seeding and the keybinding module (skipped automatically when
# a bar/tide binding already exists). Safe to run repeatedly.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

echo "== Tide Island plugin setup =="
echo

echo "1/3 Dependencies"
bash "$ROOT/scripts/install-dependencies.sh" || {
  printf '\nInstall the missing packages now? [y/N] '
  read -r ans
  if [[ ${ans,,} == "y" ]]; then
    bash "$ROOT/scripts/install-dependencies.sh" --install || true
  fi
}

echo
echo "2/3 OSD + notifications stand-down (clones + patches)"
if bash "$ROOT/scripts/ensure-suppression.sh"; then
  :
fi

echo
echo "3/3 CLI shims, config seed, keybinding + first reconcile"
bash "$ROOT/install.sh" -y || {
  printf '\ninstall.sh failed; fix the reported issue and re-run setup.\n' >&2
  exit 1
}

echo
echo "== Setup finished =="
echo "  press SUPER + SHIFT + SPACE to toggle bar and Tide Island together"
echo "  run omarchy-tide-island-status for a live health readout"
read -r -p "Press Enter to close." _