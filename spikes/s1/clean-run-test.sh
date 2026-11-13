#!/usr/bin/env bash
# Spike S1: run the packed stack on a CLEAN VM of the same release.
# Host-side driver. Usage: clean-run-test.sh <build-vm> <codename>
# Copies the stack tarball out of the build VM, boots a fresh VM with a virgl
# GPU, installs only archive runtime packages, unpacks /opt/motanka, starts
# /opt/motanka/bin/Hyprland on tty1 and saves a screenshot.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
build_vm=$1 rel=$2
out=$HOME/.cache/motanka-vm/spikes/s1
mkdir -p "$out"
"$repo/test/vm/run" "$build_vm" -- "cat ~/s1/stack-$rel.tar.zst" >"$out/stack-$rel.tar.zst"
"$repo/test/vm/run" "$build_vm" -- "cat ~/s1/runtime-deps-$rel.txt" >"$out/runtime-deps-$rel.txt"

vm=$(MOTANKA_VM_GPU=gl MOTANKA_VM_RAM=4G "$repo/test/vm/up" "$rel" fresh | tail -1)
echo "clean VM: $vm" >&2
# shellcheck disable=SC2064
trap "'$repo/test/vm/down' '$vm' >/dev/null 2>&1 || true" EXIT
"$repo/test/vm/run" "$vm" -- 'cat > /tmp/stack.tar.zst' <"$out/stack-$rel.tar.zst"
"$repo/test/vm/run" "$vm" -- 'cat > /tmp/deps.txt' <"$out/runtime-deps-$rel.txt"
"$repo/test/vm/run" "$vm" -- bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q >/dev/null
# shellcheck disable=SC2046
sudo apt-get install -y -q --no-install-recommends zstd xwayland xkb-data hwdata grim \
  libgl1-mesa-dri libegl1 libgbm1 $(cat /tmp/deps.txt) >/tmp/apt.log 2>&1 || { tail -20 /tmp/apt.log; exit 1; }
echo "PPA sources present: $(grep -rl toolchain /etc/apt/sources.list.d/ 2>/dev/null | wc -l)"
echo "system GLIBCXX max: $(strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 | grep -o '^GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"
sudo mkdir -p /opt/motanka
sudo tar -C /opt/motanka -I zstd -xf /tmp/stack.tar.zst
echo "unresolved: $(ldd /opt/motanka/bin/Hyprland | grep -c 'not found' || true)"
echo "libstdc++ used: $(ldd /opt/motanka/bin/Hyprland | awk '/libstdc\+\+/{print $3}')"
/opt/motanka/bin/Hyprland --version | head -1
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin tester --noclear %%I $TERM\n' |
  sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null
printf 'if [ "$(tty)" = /dev/tty1 ]; then exec /opt/motanka/bin/Hyprland >$HOME/hypr.log 2>&1; fi\n' >~/.bash_profile
sudo systemctl daemon-reload
sudo systemctl restart getty@tty1
sleep 15
pgrep -a Hyprland || { echo "Hyprland is not running"; tail -30 ~/hypr.log; exit 1; }
export XDG_RUNTIME_DIR=/run/user/$(id -u)
f=$(ls -d "$XDG_RUNTIME_DIR"/hypr/*/ | head -1)
grep -E 'Renderer:|drm: Starting backend' "${f}hyprland.log" | head -3
HYPRLAND_INSTANCE_SIGNATURE=$(basename "$f") /opt/motanka/bin/hyprctl monitors | head -2
WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | head -1) grim /tmp/shot.png
echo "screenshot ok"
EOS
"$repo/test/vm/run" "$vm" -- 'cat /tmp/shot.png' >"$out/shot-$rel.png"
echo "screenshot: $out/shot-$rel.png"
