-- Motanka session names for Hyprland. Installed by motanka-core as
-- /opt/motanka/share/motanka/hypr/motanka-session.lua; per-user setup copies
-- it, ledgered, to ~/.local/state/omarchy/toggles/hypr/motanka-session.lua.
--
-- Upstream's ~/.config/hypr/hyprland.lua loads default/hypr/envs.lua, which
-- sets XDG_CURRENT_DESKTOP and XDG_SESSION_DESKTOP to "Hyprland", and then,
-- last, every file in ~/.local/state/omarchy/toggles/hypr
-- (default/hypr/toggles.lua). This file puts the Motanka session's names
-- back, so autostart entries, web-app launchers and the portal configuration
-- that key on "Motanka" keep matching, and Upstream's
-- "dbus-update-activation-environment --systemd --all" at start pushes these
-- values into the user manager. It also runs again on every config reload.
--
-- Hyprland warns at every start when XDG_CURRENT_DESKTOP is not "Hyprland"
-- ("Your XDG_CURRENT_DESKTOP environment seems to be managed externally";
-- CCompositor::performUserChecks, Hyprland 0.57.2). The Motanka session sets
-- "Motanka:Hyprland" on purpose, so the check is turned off here.
--
-- Only the Motanka session launcher sets DCONF_PROFILE=motanka, and Upstream's
-- configuration never changes it, so another Hyprland reading the same files
-- keeps Upstream's values and the check.
if os.getenv("DCONF_PROFILE") == "motanka" then
  hl.env("XDG_CURRENT_DESKTOP", "Motanka:Hyprland")
  hl.env("XDG_SESSION_DESKTOP", "motanka")
  hl.config({ misc = { disable_xdg_env_checks = true } })
end
