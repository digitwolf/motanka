#!/usr/bin/env bash
# Spike S4: what does do-release-upgrade (24.04 -> 26.04) do to a package that
# installs under /opt from a third-party apt source?
# Host-side driver. Usage: spikes/s4/run.sh
# Everything happens in a throwaway 24.04 VM. Output: the state before and after.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
vm=$(MOTANKA_VM_CPUS=6 MOTANKA_VM_RAM=6G "$repo/test/vm/up" noble fresh | tail -1)
echo "VM: $vm" >&2
# shellcheck disable=SC2064
trap "'$repo/test/vm/down' '$vm' >/dev/null 2>&1 || true" EXIT
run() { "$repo/test/vm/run" "$vm" -- "$@"; }

run sudo bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
apt-get update -q >/dev/null
apt-get install -y -q dpkg-dev apt-utils >/dev/null
# A placeholder "motanka-s4" package: a file under /opt and a dependency on an archive package.
d=$(mktemp -d)
mkdir -p "$d/pkg/DEBIAN" "$d/pkg/opt/motanka-s4" "$d/repo/pool"
echo placeholder >"$d/pkg/opt/motanka-s4/placeholder.txt"
cat >"$d/pkg/DEBIAN/control" <<'EOF'
Package: motanka-s4
Version: 0.1.0-1~ubuntu24.04.1
Architecture: all
Maintainer: Spike <spike@example.invalid>
Depends: libpixman-1-0
Description: Spike S4 placeholder
 Installs one file under /opt.
EOF
dpkg-deb --build "$d/pkg" "$d/repo/pool/motanka-s4_0.1.0-1~ubuntu24.04.1_all.deb" >/dev/null
(cd "$d/repo" && mkdir -p dists/noble/main/binary-amd64 &&
  apt-ftparchive packages pool >dists/noble/main/binary-amd64/Packages &&
  apt-ftparchive -o APT::FTPArchive::Release::Suite=noble -o APT::FTPArchive::Release::Codename=noble \
    -o APT::FTPArchive::Release::Origin=Motanka release dists/noble >dists/noble/Release)
mkdir -p /srv && rm -rf /srv/s4repo && mv "$d/repo" /srv/s4repo
cat >/etc/systemd/system/s4repo.service <<'EOF'
[Service]
ExecStart=/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory /srv/s4repo
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now s4repo.service
sleep 1
cat >/etc/apt/sources.list.d/motanka.sources <<'EOF'
Types: deb
URIs: http://127.0.0.1:8765/
Suites: noble
Components: main
Trusted: yes
EOF
apt-get update -q >/dev/null
apt-get install -y -q motanka-s4 >/dev/null
apt-get dist-upgrade -y -q >/dev/null
echo "=== BEFORE"
dpkg-query -W motanka-s4 libpixman-1-0
cat /etc/apt/sources.list.d/motanka.sources
grep -E '^Prompt' /etc/update-manager/release-upgrades
EOS

# do-release-upgrade refuses to start while a reboot is pending.
run 'sudo systemctl reboot' || true
sleep 20
for _ in $(seq 1 60); do
  run true 2>/dev/null && break
  sleep 5
done

echo "=== running do-release-upgrade (non-interactive); this takes a while" >&2
set +e
run 'sudo DEBIAN_FRONTEND=noninteractive do-release-upgrade -f DistUpgradeViewNonInteractive' \
  >"$HOME/.cache/motanka-vm/spikes/s4-upgrade.log" 2>&1
rc=$?
set -e
echo "do-release-upgrade exit: $rc" >&2
tail -15 "$HOME/.cache/motanka-vm/spikes/s4-upgrade.log" >&2

# The upgrader asks for a reboot; reboot and wait for SSH.
run 'sudo systemctl reboot' || true
sleep 20
for _ in $(seq 1 60); do
  run true 2>/dev/null && break
  sleep 5
done

run sudo bash -s <<'EOS'
echo "=== AFTER"
. /etc/os-release; echo "release: $VERSION_ID ($VERSION_CODENAME)"
dpkg-query -W -f '${Package} ${Version} ${Status}\n' motanka-s4 2>&1 || echo "motanka-s4 not installed"
ls -la /opt/motanka-s4 2>&1
echo "--- sources files mentioning 8765:"
grep -rl 8765 /etc/apt/sources.list.d/ 2>/dev/null | while read -r f; do echo "## $f"; cat "$f"; done
echo "--- upgrader notes on obsolete/foreign packages:"
grep -iE 'obsolete|foreign|motanka-s4|third party|disabled' /var/log/dist-upgrade/main.log 2>/dev/null | tail -15
EOS
