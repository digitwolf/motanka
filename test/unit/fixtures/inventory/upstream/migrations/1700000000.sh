# shellcheck shell=bash
# Fixture: user units, session tools and a case statement.
systemctl --user enable --now omarchy-fixture.service
systemctl --user daemon-reload
systemctl enable --now system-only.service
case "$1" in
pacman) echo "pattern only" ;;
*) uwsm-app -- omarchy-launch-fixture ;;
esac
hyprctl dispatch exec "sudo limine-update"
sudo -v
mkdir -p ~/.config/systemd/user
