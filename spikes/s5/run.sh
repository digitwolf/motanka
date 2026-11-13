#!/usr/bin/env bash
# Spike S5: do the display managers list a session entry with
# DesktopNames=Motanka;Hyprland and pass the desktop names through?
# Host-side driver. Usage: spikes/s5/run.sh <release> <variant>   (variant: gnome-snaps | kde)
# Installs a placeholder session that records its environment, logs in to it
# automatically through the display manager, and prints the relevant variables.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
rel=$1 variant=$2
vm=$("$repo/test/vm/up" "$rel" "$variant" | tail -1)
# shellcheck disable=SC2064
trap "'$repo/test/vm/down' '$vm' >/dev/null 2>&1 || true" EXIT
"$repo/test/vm/run" "$vm" -- sudo bash -s "$variant" <<'EOS'
set -euo pipefail
variant=$1
cat >/usr/local/bin/motanka-s5-session <<'EOF'
#!/bin/sh
env | sort >/tmp/s5-env.txt
exec sleep infinity
EOF
chmod 755 /usr/local/bin/motanka-s5-session
mkdir -p /usr/share/wayland-sessions
cat >/usr/share/wayland-sessions/motanka.desktop <<'EOF'
[Desktop Entry]
Name=Motanka
Comment=Spike S5 placeholder
Exec=/usr/local/bin/motanka-s5-session
DesktopNames=Motanka;Hyprland
Type=Application
EOF
if [ "$variant" = gnome-snaps ]; then
  mkdir -p /var/lib/AccountsService/users
  printf '[User]\nSession=motanka\nSystemAccount=false\n' >/var/lib/AccountsService/users/tester
  conf=/etc/gdm3/custom.conf
  sed -i 's/^#\?\s*AutomaticLoginEnable.*/AutomaticLoginEnable=true/; s/^#\?\s*AutomaticLogin\s*=.*/AutomaticLogin=tester/' "$conf"
  grep -q '^AutomaticLoginEnable=true' "$conf" || sed -i 's/^\[daemon\]/[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=tester/' "$conf"
  dm=gdm3
else
  mkdir -p /etc/sddm.conf.d
  printf '[Autologin]\nUser=tester\nSession=motanka.desktop\n' >/etc/sddm.conf.d/zz-s5.conf
  dm=sddm
fi
systemctl restart accounts-daemon 2>/dev/null || true
systemctl restart "$dm"
for _ in $(seq 1 60); do [ -s /tmp/s5-env.txt ] && break; sleep 2; done
echo "display manager: $dm $(dpkg-query -W -f '${Version}' "$dm")"
if [ -s /tmp/s5-env.txt ]; then
  grep -E '^(XDG_CURRENT_DESKTOP|XDG_SESSION_DESKTOP|XDG_SESSION_TYPE|DESKTOP_SESSION)=' /tmp/s5-env.txt
else
  echo "the placeholder session did not start"
  journalctl -b -u "$dm" --no-pager | tail -15
fi
for sid in $(loginctl list-sessions --no-legend | awk '$3=="tester" && $4=="seat0"{print $1}'); do
  loginctl show-session "$sid" -p Desktop -p Type -p Service
done
echo "tester processes: $(ps -u tester -o comm= | sort -u | tr '\n' ' ')"
EOS
