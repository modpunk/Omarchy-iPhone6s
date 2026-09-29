-- Omarchy on the Omarchy Phone: Omarchy's menu keys and environment.
-- Loaded by the image's ~/.config/hypr/hyprland.lua (a guarded dofile the
-- omarchy-core stage appends), after the phone shell's own config.
-- Keys follow Omarchy 4 (default/hypr/bindings/utilities.lua).

hl.env("OMARCHY_PATH", "/usr/share/omarchy")
hl.env("OMARCHY_CORE", "/usr/share/omarchy-core")
hl.env("OMARCHY_THEME_SKIP_BACKGROUND", "1")   -- themes ship without wallpapers here

hl.bind("SUPER + SPACE", hl.dsp.exec_cmd("omarchy-menu toggle"))
hl.bind("SUPER + ESCAPE", hl.dsp.exec_cmd("omarchy-menu toggle system"))
hl.bind("SUPER + SHIFT + CTRL + SPACE", hl.dsp.exec_cmd("omarchy-menu summon style.theme"))
hl.bind("SUPER + CTRL + C", hl.dsp.exec_cmd("omarchy-menu toggle trigger.capture"))
hl.bind("SUPER + CTRL + O", hl.dsp.exec_cmd("omarchy-menu toggle trigger.toggle"))

-- The menu (and pickers opened outside a terminal) float over the app column.
hl.window_rule({
  match = { class = "^omarchy-menu$" },
  float = true,
  center = true,
  size = { "(monitor_w*0.94)", "(monitor_h*0.62)" },
})
