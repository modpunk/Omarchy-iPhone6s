-- Omarchy Phone session (iPhone 6s image, Hyprland 0.56 Lua).
-- The phone shell's own config does the work: monitors and keys from
-- devices/$OPHONE_DEVICE.lua, then `qs -p $OPHONE_SHELL/qs` at start.
-- phone-hyprland exports OPHONE_DEVICE=iphone6s and OPHONE_SHELL.
--   PHONE_PLAIN=1 phone-hyprland     plain foot-only session (plain.lua)
if os.getenv("PHONE_PLAIN") == "1" then
  dofile(os.getenv("HOME") .. "/.config/hypr/plain.lua")
  return
end

local shell = os.getenv("OPHONE_SHELL") or "/usr/share/omarchy-phone/shell"
dofile(shell .. "/hypr/hyprland.lua")

-- Image overrides, proven on the phone with the plain config.
hl.config({
  xwayland = { enabled = false },           -- Xwayland isn't installed
  cursor = { no_hardware_cursors = true },  -- simpledrm has no cursor plane
  misc = { disable_hyprland_guiutils_check = true },  -- hyprland-guiutils isn't installed
})
hl.env("GSK_RENDERER", "cairo")      -- GTK4 apps: CPU renderer, cheaper than GL on llvmpipe
hl.env("QS_ICON_THEME", "Adwaita")   -- app icons for the home grid (Yaru isn't in ALARM)
