-- Omarchy Phone starter config (Hyprland 0.56 Lua).
-- iPhone 6s: 750x1334 simpledrm framebuffer, no GPU driver, so Mesa llvmpipe
-- renders everything on the CPU. Keep effects off.
hl.monitor({ output = "", mode = "preferred", position = "0x0", scale = 2 })

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

hl.config({
  general = { gaps_in = 2, gaps_out = 4, border_size = 1, layout = "dwindle" },
  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },
  animations = { enabled = false },
  misc = { force_default_wallpaper = 0, disable_hyprland_logo = true },
  xwayland = { enabled = false },
  cursor = { no_hardware_cursors = true },
  -- Touch: apple_z2 registers "iPhone 6s Touchscreen" (INPUT_PROP_DIRECT),
  -- so libinput maps it to the only output. Orientation and range are fixed
  -- in the kernel DT (touchscreen-inverted-x/-y, touchscreen-swapped-x-y,
  -- touchscreen-size-x/-y), not here; keep transform 0 unless the panel is
  -- rotated with hl.monitor. Check with: hyprctl configerrors
  input = {
    kb_layout = "us",
    touchdevice = { enabled = true, transform = 0 },
  },
})

hl.on("hyprland.start", function()
  hl.exec_cmd("foot")
end)

local mod = "SUPER"
hl.bind(mod .. " + Return", hl.dsp.exec_cmd("foot"))
hl.bind(mod .. " + W", hl.dsp.window.close())
