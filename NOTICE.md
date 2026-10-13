# NOTICE

This repository is original work (MIT) plus small patches derived from other
projects. Their licenses are honored as follows.

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
  (see the project's LICENSE/COPYING or the installed package).
- The patch does not change Tide Island's licensing: applying or redistributing
  it applies only to Tide Island's GPL-3.0-only code as normal.

## Shared config format

`default/tide-island.json` shares the field names used by the user config with
the plugin at runtime; it is original work (MIT).