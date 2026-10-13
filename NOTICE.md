# NOTICE

This repository is original work (MIT), plus small patches derived from other
projects, plus a bundled third-party runtime. Their licenses are honored as
follows.

## Original plugin code (MIT)

`Service.qml`, `scripts/*`, `bin/*`, `install.sh`, `uninstall.sh`, `tests/*`,
`packaging/hyprland-tide-island.lua`, `default/*`, `README.md`, `CHANGELOG.md`

Copyright (c) 2026 Mehir — licensed under the MIT License (see LICENSE).

## Derived: suppression patches (MIT)

`patches/omarchy-osd-suppression.patch`
`patches/omarchy-notifications-suppression.patch`

These are modifications of the Omarchy first-party `osd` and `notifications`
shell plugins. They only add a 'stand down while the bar-off flag is present'
behavior on top of the original files.

- Source: https://github.com/basecamp/omarchy (Omarchy, the operating mode project)
- Upstream files this repository's patch hunks apply to:
  `/usr/share/omarchy/shell/plugins/osd/Osd.qml` and
  `/usr/share/omarchy/shell/plugins/notifications/Service.qml`
- License: **MIT** (as packaged by Omarchy 4.x). The Omarchy copyright notice
  is retained in the files the patch modifies.

## Derived: Tide Island lyrics patch (GPL-3.0-only)

`patches/tide/swipe-lyrics-no-cover.patch`

This is a modification of Tide Island's `SwipeLyricsLayer.qml` (removes the
album-cover art from the swipe-lyrics island). It is derived from Tide Island
source code and must be distributed under Tide Island's license.

- Source: https://github.com/enhaoswen/Tide-island (Tide Island)
- Copyright and license: Tide Island is licensed **GPL-3.0-only**
  (see the project's LICENSE/COPYING or the installed package). A verbatim copy
  of that license is included in `LICENSES/GPL-3.0-only.txt`.
- The patch does not change Tide Island's licensing: applying or redistributing
  it applies only to Tide Island's GPL-3.0-only code as normal.

## Bundled: Tide Island runtime (GPL-3.0-only)

`vendor/tide-island/` is an unmodified copy of the Tide Island 1.0.41 runtime
(launcher script, QML tree, compiled `TideIsland`/`IslandBackend` QML modules,
lyrics backend). The plugin installs it, unprivileged, into the user's
`~/.local/share/omarchy-tide-island` so the island works without the user
installing the `tide-island` package.

- Source: https://github.com/enhaoswen/Tide-island (Tide Island, version 1.0.41)
- License: **GPL-3.0-only** (`LICENSES/GPL-3.0-only.txt`)
- See `vendor/tide-island/PROVENANCE.md` for the exact file list and the
  corresponding-source note. No source changes were made by this project.

## Runtime dependency: Quickshell (LGPL-3.0-only)

The plugin is loaded and rendered by **Quickshell** (https://quickshell.org,
licensed **LGPL-3.0-only**). `Service.qml` uses Quickshell's public QML API and
is interpreted by it at runtime; it is not linked into Quickshell, so the MIT
terms of this repository's own code are unaffected. If you modify Quickshell
itself, your changes to Quickshell remain under the LGPL.

## Scope of licenses

The plugin's own code is one independent work (MIT). The Tide lyrics patch is a
separate, Tide-derived work (GPL-3.0-only), and the bundled runtime in
`vendor/tide-island/` is Tide Island itself (GPL-3.0-only). They are merely
distributed together in this repository (an aggregate); the GPL obligations
apply only to the GPL-covered patch and the vendored runtime, not to the
MIT-licensed plugin.

## Shared config format

`default/tide-island.json` shares the field names used by the user config with
the plugin at runtime; it is original work (MIT).