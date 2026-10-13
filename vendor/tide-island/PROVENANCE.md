# Vendored: Tide Island runtime

This directory contains the Tide Island application runtime, bundled so the
plugin can install the island without the user installing the `tide-island`
package. It is third-party software, **not** part of this plugin's own MIT code.

- Upstream: https://github.com/enhaoswen/Tide-island
- Version: `1.0.41` (Arch package `tide-island 1.0.41-1`, upstream `main`)
- License: **GPL-3.0-only** — see `LICENSES/GPL-3.0-only.txt` at the repo root.

## What is bundled

```
bin/tide-island                     launcher script (verbatim from the package)
lib/libIslandBackend.so             compiled backend shared library
lib/qt6/qml/TideIsland/             QML module (qmldir + libTideIslandplugin.so)
lib/qt6/qml/IslandBackend/          QML module (qmldir + plugin)
share/tide-island/                  QML tree, lyrics backend (bin/lyricsmpris),
                                    and helper scripts
share/applications/tide-island.desktop
```

## What is intentionally not bundled

- `bin/tide-island-config-app` (the ~6.6 MB settings GUI) and its desktop entry.
  The island runs without it; Hyprland never invokes it. Users who want the
  settings GUI can install the upstream `tide-island` package.
- `bin/tide-island-spotify-setup` (optional Spicetify bridge helper).

## Corresponding source

The bundled files are unmodified copies of the upstream 1.0.41 build. Their
corresponding source is the upstream repository above; no source changes were
made by this project. See the GPL-3.0-only text for the license terms.
