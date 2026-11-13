# shellcheck shell=bash
# Fixture: home-folder writes. A comment with > ~/.bashrc is not a write.
mkdir -p ~/.config/omarchy/themes
cp -f "$OMARCHY_PATH/config/hypr/hyprland.lua" \
  "$HOME/.config/hypr/hyprland.lua"
echo "source x" >>"${HOME}/.bashrc"
cat >"${XDG_CONFIG_HOME:-$HOME/.config}/fixture/app.conf" <<EOF
sudo pacman -S in-heredoc
rm -rf ~/.config/from-heredoc
EOF
user_file="$HOME/.config/fixture/user.conf"
touch "$user_file"
ln -snf "$HOME/.local/state/omarchy/current/theme/btop.theme" ~/.config/btop/themes/current.theme
sed -i 's/a/b/' ~/.config/fixture/sed.conf
tar -xzf /tmp/fixture.tgz -C "$XDG_DATA_HOME/fixture"
echo "done" | tee -a ~/.local/state/omarchy/fixture.log >/dev/null
