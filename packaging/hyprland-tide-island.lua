-- mehir.tide-island — Hyprland keybinding
--
-- Installed by scripts/install.sh into ~/.config/hypr/tide-island.lua and
-- wired into hyprland.lua through require_optional, which loads this file only
-- when the plugin directory is present:
--
--   -- hyprland.lua (or a custom needs a "packaging" entry):
--   require("default.hypr.require_optional").module("hypr.tide-island")
--
-- SUPER + SHIFT + SPACE toggles the top bar and Tide Island together. The
-- toggle itself is driven by omarchy-tide-island-toggle (installed to
-- ~/.local/bin), which prefers IPC through the Tide Island shell service and
-- falls back to direct coordination.

if o and hl then
  hl.unbind("SUPER + SHIFT + SPACE")

  o.bind("SUPER + SHIFT + SPACE", "Toggle top bar and Tide Island",
    "~/.local/bin/omarchy-tide-island-toggle")

  -- Keep the Tide Island Settings (config) app floating and centered
  hl.windowrulev2("float,class:^(tide-island-config-app)$")
  hl.windowrulev2("float,title:^(Tide Island Config Application|Tide Island Settings)$")
  hl.windowrulev2("center,class:^(tide-island-config-app)$")
  hl.windowrulev2("center,title:^(Tide Island Config Application|Tide Island Settings)$")
  hl.windowrulev2("noanim,class:^(tide-island-config-app)$")
  hl.windowrulev2("noanim,title:^(Tide Island Config Application|Tide Island Settings)$")
end