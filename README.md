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
creates + patches the OSD/notification clones and wires the keybinding. The
Tide Island **Settings** app is bundled too — open it from the app menu
("Tide Island Settings") or run `tide-island-config-app`. Then the island
appears whenever the bar is hidden. On a machine with no Tide config yet, it
also seeds Tide's own `~/.config/tide-island/userconfig.json` once with the
default island look below (existing configs are never overwritten).

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
5. Reconciles Tide Island against the current bar state.

Everything is recorded in `~/.local/state/omarchy/tide-island/installed.json`.
Repeat `install.sh` to repair; `uninstall.sh` reverses it (nothing user-created
is ever deleted, just backed up, and a stand-down you had before the plugin is
left in place). Pass `--remove-runtime` to also remove the bundled Tide Island
from `~/.local`.

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