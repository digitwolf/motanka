-- Fixture: Lua Hyprland config. hl.exec_cmd("sudo pacman -Syu") in this comment is not a call.
o.bind("SUPER + K", "Keys", "omarchy-menu-keybindings")
hl.exec_cmd("uwsm-app -- pkexec snapper list")
local p = paths.omarchy_path .. "/default/hypr/fixture"
hl.bind("SUPER + U", hl.dsp.exec_cmd("yay -Syu"))
