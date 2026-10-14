# NOTICE

This repository is original work (MIT), plus small patches derived from other
projects, plus a bundled third-party runtime. Their licenses are honored as
follows.

## Original plugin code (MIT)

`Service.qml`, `scripts/*`, `bin/*`, `install.sh`, `uninstall.sh`, `tests/*`,
`packaging/hyprland-tide-island.lua`, `default/*`, `README.md`, `CHANGELOG.md`
and `vendor/tide-island/share/tide-island/scripts/omarchy-bridge.sh`

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

## Derived: Tide Island Omarchy integration (GPL-3.0-only)

`vendor/tide-island/share/tide-island/qml/island/WallpaperPickerLayer.qml` (modified)
`patches/tide/omarchy-theme-integration.patch` (record of the delta)

The modified QML is derived from Tide Island source and remains under Tide
Island's GPL-3.0-only license, not under this repository's MIT license. The
patch file records both that QML change and the separately authored bridge
script; its QML hunk is GPL-3.0-only and its bridge-script addition is MIT.

- Source: https://github.com/enhaoswen/Tide-island (Tide Island 1.0.41,
  commit `e44fe2a5b7e09e0aacec98e18128ade662102f6f`)
- License: **GPL-3.0-only** (`LICENSES/GPL-3.0-only.txt`)

## Bundled: Tide Island runtime (GPL-3.0-only)

`vendor/tide-island/` contains the Tide Island 1.0.41 runtime (launcher script,
settings GUI, QML tree, compiled `TideIsland`/`IslandBackend` QML modules,
lyrics backend), with the GPL-modified QML listed above and the separately
MIT-licensed Omarchy bridge script. The plugin installs it, unprivileged, into
the user's `~/.local/share/omarchy-tide-island` so the island works without
the user installing the `tide-island` package.

- Source: https://github.com/enhaoswen/Tide-island (Tide Island, version 1.0.41)
- Source commit: `e44fe2a5b7e09e0aacec98e18128ade662102f6f`
- Tide Island files and Tide-derived modifications: **GPL-3.0-only**
  (`LICENSES/GPL-3.0-only.txt`)
- Original bridge script: **MIT** (see the repository root `LICENSE`)
- See `vendor/tide-island/PROVENANCE.md` for the exact file list, the
  corresponding-source note, the plugin additions, and how the settings GUI is
  built.

## Runtime dependency: Quickshell (LGPL-3.0-only)

The plugin is loaded and rendered by **Quickshell** (https://quickshell.org,
licensed **LGPL-3.0-only**). `Service.qml` uses Quickshell's public QML API and
is interpreted by it at runtime; it is not linked into Quickshell, so the MIT
terms of this repository's own code are unaffected. If you modify Quickshell
itself, your changes to Quickshell remain under the LGPL.

## Scope of licenses

The plugin's orchestration code and original Omarchy bridge are MIT. The Tide
lyrics patch, the modified Tide QML, and the upstream Tide runtime remain
GPL-3.0-only. They are distributed together as an aggregate; the root MIT
license does not relicense the Tide-derived files. `manifest.json` summarizes
these distinct licenses in its single supported `license` string; this is not a
claim that the repository has one uniform license.

## Shared config format

`default/tide-island.json` shares the field names used by the user config with
the plugin at runtime; it is original work (MIT).