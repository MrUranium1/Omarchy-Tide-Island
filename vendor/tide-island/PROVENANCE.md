# Vendored: Tide Island runtime

This directory contains the Tide Island application runtime, bundled so the
plugin can install the island without the user installing the `tide-island`
package. It is third-party software, **not** part of this plugin's own MIT code.

- Upstream: https://github.com/enhaoswen/Tide-island
- Version: `1.0.41` (Arch package `tide-island 1.0.41-1`)
- Immutable upstream source commit:
  [`e44fe2a5b7e09e0aacec98e18128ade662102f6f`](https://github.com/enhaoswen/Tide-island/commit/e44fe2a5b7e09e0aacec98e18128ade662102f6f)
  (the dereferenced `1.0.41` tag commit)
- License: **GPL-3.0-only** — see `LICENSES/GPL-3.0-only.txt` at the repo root.

## What is bundled

```
bin/tide-island                     launcher script (verbatim from the package)
bin/tide-island-config-app          settings GUI (compiled from upstream source)
lib/libIslandBackend.so             compiled backend shared library
lib/qt6/qml/TideIsland/             QML module (incl. the config-app QML)
lib/qt6/qml/IslandBackend/          QML module (qmldir + plugin)
share/tide-island/                  QML tree, lyrics backend (bin/lyricsmpris),
                                    and helper scripts
                                    (incl. scripts/omarchy-bridge.sh, added by
                                    this plugin — see "Plugin additions")
share/applications/tide-island.desktop
share/applications/tide-island-config.desktop
```

## What is intentionally not bundled

- `bin/tide-island-spotify-setup` (optional Spicetify bridge helper).

## Corresponding source

The bundled files correspond to the upstream 1.0.41 release at the immutable
commit above, with the plugin additions described below. Their corresponding
source is the upstream repository at that commit; see the GPL-3.0-only text for
the license terms.

The one exception among the copied files is `bin/tide-island-config-app`, which
is compiled from the `Tide-island-app/` source at the same upstream commit (the
upstream CMake build, `-DCMAKE_INSTALL_PREFIX=/usr`, release build, no patches)
rather than copied from a binary package. Its own QML is embedded in the binary
as Qt resources; `share/applications/tide-island-config.desktop` differs from
upstream only in that `Exec=tide-island-config-app` resolves via `PATH` instead
of a hardcoded `/usr/bin/` prefix, so the same entry works for the bundled
prefix.

## Plugin additions

This plugin adds Omarchy theme/wallpaper integration to the bundled runtime.
Two things differ from upstream 1.0.41:

- `share/tide-island/scripts/omarchy-bridge.sh` — **new file**, written by this
  plugin. A small, side-effect-free interface to Omarchy's theme state and its
  `omarchy-theme-set` / `omarchy-theme-bg-set` commands.
- `share/tide-island/qml/island/WallpaperPickerLayer.qml` — **modified**. When
  Omarchy is detected the picker lists the current theme's backgrounds (applied
  through Omarchy, so both interfaces stay in sync) and gains a Themes tab that
  switches themes. Without Omarchy it behaves exactly as upstream.

Both are copied verbatim to the install prefix, so no install-time patching is
involved. The full delta from upstream is recorded for auditability at
`patches/tide/omarchy-theme-integration.patch` (paths relative to this
directory; apply with `patch -p1`). The modified QML remains under
GPL-3.0-only; the original bridge script is MIT-licensed under the repository's
root `LICENSE`.
