# Changelog

All notable changes to the mehir.tide-island plugin.

## [Unreleased]

- Fixed the control center's Silent button to toggle the actual SwayNotificationCenter
  Do Not Disturb state even when it changed outside Tide Island.
- Added Omarchy wallpaper and theme discovery/switching to the bundled Tide
  Island picker; themes now populate the preview carousel immediately after
  discovery instead of waiting for a search edit.
- Made desktop entries, CLI shims, service units, and the bundled runtime
  ownership-aware: preserve pre-existing files and user modifications, and
  refuse unsafe replacement or removal when fingerprints do not match.
- Made clone teardown reverse only the suppression patch hunks. Plugin-created
  clones are removed only when their complete tree matches the recorded
  creation snapshot; modified or unverified clones and their recovery backups
  are retained with actionable conflict logs.
- Changed automatic plugin removal to preserve both user configuration files
  and recovery state. Explicit config purging now requires typing `PURGE`.
- Restricted Hyprland cleanup to the exact require line and shortcut block
  recorded as plugin-created.
- Removed the obsolete malformed duplicate theme-picker patch; retained the
  main theme integration patch and added a zero-fuzz round-trip test.
- Corrected shortcut parity expectations, GPL license text, Tide Island source
  commit provenance, and the repository's mixed-license descriptions.
- Hardened the clipboard panel's image cache: decoded clipboard PNGs and their
  directory are private regardless of the inherited umask, and caches left
  world-readable by earlier builds are repaired in place.
- Stopped parsing clipboard history entries as rich text: the clipboard
  panel's clip labels now render with `Text.PlainText`, so a clip containing
  markup (e.g. `<img src="…">`) can no longer make the shell fetch a URL
  from clipboard content when history opens.

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
  never overwritten and the Tide userconfig is preserved on uninstall.
- Seed the settings app's default shortcuts in that same one-time config: the
  seed now carries the island keybindings (`SUPER + ALT +` H/J/T/M/C/P/N/A/O/V/D
  for the island views, plus `SUPER + ALT + I` to toggle the island) with the
  other app actions left disabled, so `tide-island-config-app` shows them as the
  defaults for a fresh install while existing configs are untouched.
- Apply those same island keybindings to `hyprland.lua` at install time
  (`scripts/wire-shortcuts.sh`), written into the settings app's own managed
  block, so the shortcuts are live on a fresh install without opening the
  settings app. Idempotent and non-destructive: an existing block (app- or
  user-made) is never duplicated or overwritten, and teardown removes a block
  only when we created it and it is still byte-for-byte untouched — a block the
  user or the settings app has since edited is kept. `install.sh --no-shortcuts`
  opts out.
- Removal now undoes itself however the plugin is removed: install notes a
  self-contained teardown outside the plugin dir, and removing `mehir.tide-island`
  (even via `omarchy plugin remove`, which has no uninstall hook) restores the
  OSD/notification stand-down — volume/display popups and notifications return
  to the normal bar path — and removes shims, keybinding and bundled runtime.
  `uninstall.sh` is now a thin wrapper over `scripts/teardown.sh` (backups and
  the pre-existing-stand-down rule are unchanged).
- Clean-room lifecycle test (`tests/cleanroom.sh`).
- Install no longer trusts disk markers: setup is marked complete only after the
  patched OSD/notifications clones are actually serving at runtime. When the
  shell's plugin watcher reloads the mounted set while the patch is still being
  applied, a final mount-verification (`scripts/ensure-mount.sh`) bounces the
  set (`shell rescanPlugins`), verifies over the shell IPC (patched clones
  expose `syncSuppression`; first-party code does not), and only then writes
  the auto-setup marker — failures are logged with remedies and retried on the
  next shell start.
- `Service.qml` probes suppression over the runtime IPC as well as the files,
  so reported stand-down state tracks what is actually mounted.
- Removal now clears the transient setup-complete marker even when state is
  kept (e.g. `uninstall.sh` without `--final`), so re-adding the plugin runs
  setup again instead of trusting a stale marker and silently skipping the
  OSD/notification stand-down.
- The "Editing Cloned Plugin" toast seen during setup is Omarchy's own clone
  confirmation (from `omarchy plugin clone`), not an error; install adds an
  explainer notification so the silent set-up stays comprehensible.
- Regression tests: unit, smoke and clean-room suites now cover the mount
  bounce — self-heal of an install that raced the patch, repair of a runtime
  stuck at first-party, and a loud failure that leaves no "done" marker when
  the patched clone cannot serve.
