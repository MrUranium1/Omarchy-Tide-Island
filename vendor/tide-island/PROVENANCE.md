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
bin/tide-island-config-app          settings GUI (compiled from upstream source)
lib/libIslandBackend.so             compiled backend shared library
lib/qt6/qml/TideIsland/             QML module (incl. the config-app QML)
lib/qt6/qml/IslandBackend/          QML module (qmldir + plugin)
share/tide-island/                  QML tree, lyrics backend (bin/lyricsmpris),
                                    and helper scripts
share/applications/tide-island.desktop
share/applications/tide-island-config.desktop
```

## What is intentionally not bundled

- `bin/tide-island-spotify-setup` (optional Spicetify bridge helper).

## Corresponding source

The bundled files are unmodified copies of the upstream 1.0.41 build. Their
corresponding source is the upstream repository above; no source changes were
made by this project. See the GPL-3.0-only text for the license terms.

The one exception is `bin/tide-island-config-app`, which is compiled from the
upstream 1.0.41 source tarball (`Tide-island-app/`, the upstream CMake build,
`-DCMAKE_INSTALL_PREFIX=/usr`, release build, no patches) rather than copied
from a binary package. Its own QML is embedded in the binary as Qt resources;
`share/applications/tide-island-config.desktop` differs from upstream only in
that `Exec=tide-island-config-app` resolves via `PATH` instead of a hardcoded
`/usr/bin/` prefix, so the same entry works for the bundled prefix.