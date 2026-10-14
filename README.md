# Tide Island Plugin

Keep [Tide Island](https://github.com/enhaoswen/Tide-island) and the Omarchy
bar from ever showing at the same time, and let Tide Island own screen space
cleanly when it does.

- `SUPER + SHIFT + SPACE` toggles the top bar **and** Tide Island together
  (Tide Island runs while the bar is hidden, stops when the bar returns).
- While the bar is hidden the built-in OSD and notification popups stand down,
  because Tide Island renders its own volume/brightness control center and
  notification stack. History is unaffected: silenced toasts are still archived
  to history on their normal expiry (the newest 10 are kept), and DND still
  works.
- Reconciles itself at shell start, on every flag change and after rapid
  toggles, so a session restart can never strand the bar and the island both
  visible (or both hidden) on top of each other.

## How it works

```
SUPER+SHIFT+SPACE ──> omarchy-tide-island-toggle (CLI shim)
                        │  prefers IPC            falls back to scripts/
                        ▼                          ▼
                   omarchy-shell tide-island toggle
                        │
                        ▼
              ~/.local/state/omarchy/toggles/bar-off  <-- flip or create
                        │
                        ▼
        scripts/tide-sync.sh reconcile   (idempotent state machine)
        bar-off present  ->  tide-island.service start
        bar-off absent   ->  tide-island.service stop
                        │
                        ▼
   patched OSD / notifications clones watch the same flag
   and hide their overlays while it is present (see patches/)
```

The whole thing is a single **service** plugin (`mehir.tide-island`) so it can
watch the flag, own the reconciliation and talk to the CLI over IPC without
any polling daemon.

## Installation

Prerequisites: `quickshell`, `jq`, `patch` (all present on a stock Omarchy).
Tide Island itself is **bundled** with the plugin, so there is no separate
package/AUR step. `scripts/install-dependencies.sh` reports anything missing.

### Add it as a plugin (recommended)

```sh
omarchy plugin add https://github.com/MrUranium1/Omarchy-Tide-Island --enable
```

The first time the plugin loads it notices it is not set up yet and runs the
whole setup by itself: it installs the bundled Tide Island into
`~/.local/share/omarchy-tide-island` (no sudo), links `~/.local/bin/tide-island`,
installs the user `tide-island.service`, adds the CLI shims, seeds the config,
creates + patches the OSD/notification clones, wires the keybinding, and applies
the island keybindings to `hyprland.lua`. The
Tide Island **Settings** app is bundled too — open it from the app menu
("Tide Island Settings") or run `tide-island-config-app`. The bundled island
includes an **Omarchy-aware wallpaper/theme picker** (activated by
`SUPER + ALT + W` when the managed shortcuts are wired) that lists the
backgrounds and themes of the current Omarchy theme, switching them via
Omarchy's own commands so both interfaces stay in sync. Then the island
appears whenever the bar is hidden. On a machine with no Tide config yet, it
also seeds Tide's own `~/.config/tide-island/userconfig.json` once with the
default island look below (existing configs are never overwritten).

Removal is equally automatic: removing the plugin (e.g. `omarchy plugin remove
mehir.tide-island`) undoes the whole setup by itself — see [Removal](#removal).

### Manual install

```sh
bash install.sh            # from a checkout
# or, from any Omarchy session:
omarchy-shell tide-island setup
```

Either path does all of this, safely:

1. Installs the bundled Tide Island into `~/.local/share/omarchy-tide-island`
   (skipped when you already have `tide-island` on `PATH`), then the
   `omarchy-tide-island-toggle` / `omarchy-tide-island-status` commands into
   `~/.local/bin/`.
2. Seeds `~/.config/omarchy/tide-island.json` (only if absent), and — only when
   you have no Tide config yet — `~/.config/tide-island/userconfig.json` with the
   default island look (below).
3. Clones `omarchy.osd` / `omarchy.notifications` into your config (only if
   you don't have clones yet) and patches them to stand down while the flag
   is present. Never touches the built-ins. Every file we modify is backed up
   to `~/.local/state/omarchy/tide-island/backups/`. If you already had a
   suppressed clone, it is detected and left exactly as-is (and never reverted
   by `uninstall.sh`).
4. Wires the keybinding **only when nothing already binds
   `SUPER + SHIFT + SPACE`** — if your `bindings.lua`/`hyprland.lua` already
   handles it, your config is left untouched. On a fresh machine it installs
   `packaging/hyprland-tide-island.lua` into `~/.config/hypr/` and adds one
   `require_optional` line to `hyprland.lua`.
5. Ensures the patched clones actually serve right away. Setup is only marked
   complete once the OSD/notifications clones report live over the shell IPC:
   a final mount-verification (`scripts/ensure-mount.sh`) bounces the shell's
   mounted plugin set and re-checks, so a watcher-driven reload that raced the
   patch never leaves the stand-down dormant until the next restart.
6. Applies the island keybindings to `hyprland.lua` via
   `scripts/wire-shortcuts.sh`, written into the settings app's own managed
   block so the island's `SUPER + ALT +` shortcuts (H/J/T/M/C/P/N/A/O/V/D for
   the island views, I to toggle the island, W to open the wallpaper/theme
   picker) are live on a fresh install without opening the settings app. It is
   idempotent (an existing block is never duplicated) and non-destructive (a
   block you or the app edited is left alone); skip it with `install.sh
   --no-shortcuts`.
7. Reconciles Tide Island against the current bar state.

Note: standing down the built-in OSD/notification overlays uses Omarchy's own
clone mechanism, so you see the standard "Editing Cloned Plugin" toast during
setup — that is Omarchy confirming it created a clone for customization. It is
expected, not an error, and Omarchy's behaviour is left unchanged; install
follows it with an explainer notification.

Everything is recorded in `~/.local/state/omarchy/tide-island/installed.json`.
Repeat `install.sh` to repair; `uninstall.sh` reverses it (nothing user-created
is ever deleted, just backed up, and a stand-down you had before the plugin is
left in place). Pass `--remove-runtime` to also remove the bundled Tide Island
from `~/.local`.

## Removal

Two ways, both undo the OSD/notification stand-down (so the volume/display OSD
and notification popups go back to normal instead of disappearing into the
island):

1. **`omarchy plugin remove mehir.tide-island`** — enough on its own. The
   plugin notices its directory is gone and runs the self-contained teardown
   installed at `~/.local/lib/omarchy-tide-island/teardown.sh`, which removes
   the suppression clones it created, the CLI shims, the keybinding, the
   bundled runtime and the recorded state. (The island shortcut block it wrote
   to `hyprland.lua` is removed too, but only while it is still untouched.)
   (`scripts/teardown.sh` is installed *outside* the plugin directory precisely
   so it survives the plugin being deleted.)
2. **`bash uninstall.sh --remove-plugin --remove-runtime`** — from a checkout;
   logs what it backs up before removing. Add `--purge-config` to also delete
   the plugin config. A shutdown stand-down you already had *before* this
   plugin is detected and left untouched in both cases.

A `~/.config/tide-island/userconfig.json` you customized is always kept; only
a config the plugin seeded (and that you never touched) is reclaimed.

## Configuration

`~/.config/omarchy/tide-island.json` (defaults shown — the file only needs the
keys you want to change):

```json
{
  "coordinateWithBar": true,
  "startWithBarHidden": true,
  "stopWithBarShown": true,
  "suppressOsd": true,
  "suppressNotifications": true,
  "serviceName": "tide-island.service",
  "togglesDir": "~/.local/state/omarchy/toggles",
  "barOffFile": "bar-off"
}
```

| Key                    | Effect                                                    |
| ---------------------- | --------------------------------------------------------- |
| `coordinateWithBar`    | Master switch: tie the tide service to the bar flag.      |
| `startWithBarHidden`   | Start the tide service when the bar is hidden.            |
| `stopWithBarShown`     | Stop (and take down) the tide service when the bar shows. |
| `suppressOsd`          | OSD overlay stands down while the flag is present.        |
| `suppressNotifications`| Notification popups stand down; history still records.    |
| `serviceName`          | systemd unit to start/stop.                               |
| `togglesDir` / `barOffFile` | Where the bar-off flag lives.                       |

## Default island look

The first install seeds Tide's own `userconfig.json` (only when you have none)
with this small look. Every other setting stays at Tide Island's own defaults:

```json
{
  "islandExclusiveZone": 9,
  "islandTopMargin": 1,
  "islandBackgroundOpacity": 100,
  "islandHeight": 36,
  "islandWidth": 140
}
```

i.e. Reserved Top Space 9, Top Margin 1, Background Transparency 100 (opaque),
island 36 px tall and 140 px wide. This is a one-time seed — changing or
removing it later is entirely yours; the settings app reflects it normally.

## Default island shortcuts

On a fresh install the island's shortcuts live in the `SUPER + ALT +` namespace
so they never shadow Omarchy's own `SUPER` or `SUPER + ALT` bindings (Omarchy
reserves `SUPER + ALT +` F, G, K and S). The seed gives the settings app these
defaults:

| Shortcut | Action |
| --- | --- |
| `SUPER + ALT + I` | Toggle island |
| `SUPER + ALT + H` | Previous island view |
| `SUPER + ALT + J` | Clock view |
| `SUPER + ALT + T` | Timer |
| `SUPER + ALT + M` | Music player |
| `SUPER + ALT + C` | Control center |
| `SUPER + ALT + P` | Power menu |
| `SUPER + ALT + N` | Notification history |
| `SUPER + ALT + A` | Application launcher |
| `SUPER + ALT + O` | File shelf |
| `SUPER + ALT + V` | Clipboard manager |
| `SUPER + ALT + D` | Calendar |
| `SUPER + ALT + W` | Wallpaper library |

Left unassigned by default: workspace overview (`overview:toggle`), the "next
island view" swipe (`tide:swipeRight`) and weather (`tide:toggleWeather`) —
assign them in the settings app if you want them.

The seed is written once (only when you have no Tide config) and the same
chords are wired into the settings app's managed block in `hyprland.lua`, so
they are live on a fresh install without opening the app. `tests/smoke.sh`
re-reads Omarchy's own binding sources on every run and fails if a shipped chord
would ever collide with one of Omarchy's.

## Optional: swipe-lyrics without album art

A purely personal change to Tide Island itself (remove the cover thumbnail in
the swipe-lyrics island). It is opt-in and never applied automatically:

```sh
scripts/patch-tide-lyrics.sh              # applies to the running Tide copy
scripts/patch-tide-lyrics.sh --restore    # undoes it
```

## What this never touches

- `~/.config/tide-island/userconfig.json` — never overwritten. When you have no
  Tide config at all, the first install seeds it once with the default island
  look (above); a config you already had or later change is left entirely alone.
- Your Tide QML override / `~/.local/share/tide-island/` — never. The bundled
  runtime is installed to a separate prefix (`~/.local/share/omarchy-tide-island`)
  so it cannot collide with an override you already have.
- The built-in `omarchy.osd` / `omarchy.notifications` plugins — never;
  only your own clones are patched (creating them if needed).
- Your Hyprland bindings when a bar/tide binding already exists.

## Compatibility & dependencies

- The stand-down is implemented as patches against Omarchy's first-party
  `omarchy.osd` / `omarchy.notifications` plugins, so it is **version
  sensitive**: if Omarchy changes those plugins, `scripts/ensure-suppression.sh`
  may need updating. Patches are applied only to your own clones (never the
  built-ins); `tests/unit.sh` checks they apply and reverse cleanly.
- Making the patched clones serve immediately relies on Omarchy's shell IPC
  (`omarchy-shell <target> syncSuppression` and `shell rescanPlugins`). If that
  interface changes, `scripts/ensure-mount.sh` fails safe — it logs the reason,
  writes no "setup complete" marker, and retries on the next shell start rather
  than reporting a false success.
- Verified against the first-party OSD/notifications shipped with the Omarchy
  version in use at the time of writing. `tests/cleanroom.sh` models the whole
  lifecycle offline, so regressions are caught without a live session.

## Tests

```sh
bash tests/unit.sh       # offline: sync state machine, config parity, patch applicability
bash tests/smoke.sh      # repo self-check incl. shell schema validation
bash tests/cleanroom.sh  # full install -> upgrade -> uninstall -> reinstall in a throwaway $HOME
bash tests/live.sh       # needs a live Omarchy session; toggles bar/Tide and verifies
```

`tests/cleanroom.sh` fakes `omarchy`, `omarchy-shell` and `systemctl` and runs
the whole lifecycle inside a disposable `$HOME`, so it is safe to run on a real
machine without disturbing the session.

## Licensing

See NOTICE.md and LICENSE. The plugin's own code is MIT. The suppression
patches are modifications of Omarchy's MIT plugins. The Tide lyrics patch is a
derivative of Tide Island's GPL-3.0-only code (`LICENSES/GPL-3.0-only.txt`).
The bundled Tide Island runtime under `vendor/tide-island/` is Tide Island
itself and stays **GPL-3.0-only** (see `vendor/tide-island/PROVENANCE.md`).
Quickshell (LGPL-3.0-only) is a runtime dependency, used as a separate program.