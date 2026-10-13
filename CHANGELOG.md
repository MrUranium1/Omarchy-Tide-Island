# Changelog

All notable changes to the mehir.tide-island plugin.

## [0.1.0] - 2026-10-13

Initial release.

- Service plugin `mehir.tide-island` that coordinates Tide Island with the
  Omarchy bar via a shared scripts/tide-sync.sh state machine.
- `SUPER + SHIFT + SPACE` keybinding (packaging/hyprland-tide-island.lua,
  wired only when no bar/tide binding exists).
- CLI shims `omarchy-tide-island-toggle` and `omarchy-tide-island-status`
  with IPC-first, direct-fallback behavior.
- OSD and notifications stand-down via patches to user clones of
  omarchy.osd / omarchy.notifications (ensure-suppression.sh, reversible).
- Optional opt-in Tide Island swipe-lyrics patch (no album cover).
- Configurable through ~/.config/omarchy/tide-island.json with shipped
  defaults and offline unit tests covering the reconcile matrix.
- install.sh / uninstall.sh with full state recording and backups for
  reversible removal.
- Bundled Tide Island runtime (`vendor/tide-island/`, upstream 1.0.41) installed
  unprivileged into `~/.local` so the island works without the `tide-island`
  package.
- Silent auto-setup on first plugin load (Service.qml + `plugin-setup.sh
  --auto`): adding the plugin installs the runtime, shims and suppression once.
- `scripts/install-tide-runtime.sh` (relocatable prefix, user systemd unit,
  PATH shim) and OSD/notification suppression.
- Bundles the Tide Island settings GUI (`tide-island-config-app`, built from
  the upstream 1.0.41 source) with its "Tide Island Settings" desktop entry and
  a `~/.local/bin` shim, so the settings app shows up alongside the island.
- Ship a default island look: on a machine with no Tide config yet, the install
  seeds `~/.config/tide-island/userconfig.json` once (Reserved Top Space 9, Top
  Margin 1, Background Transparency 100, island 36x140); existing configs are
  never overwritten and an untouched seed is removed on uninstall.
- Removal now undoes itself however the plugin is removed: install notes a
  self-contained teardown outside the plugin dir, and removing `mehir.tide-island`
  (even via `omarchy plugin remove`, which has no uninstall hook) restores the
  OSD/notification stand-down — volume/display popups and notifications return
  to the normal bar path — and removes shims, keybinding and bundled runtime.
  `uninstall.sh` is now a thin wrapper over `scripts/teardown.sh` (backups and
  the pre-existing-stand-down rule are unchanged).
- Clean-room lifecycle test (`tests/cleanroom.sh`).