#!/usr/bin/env bash
# Provision the kde base image: the KDE Plasma desktop with SDDM.
# Runs as root inside a build VM, fed through stdin by test/vm/image.
set -euo pipefail

apt_get() {
  apt-get -y -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# apt-get update can collide with apt-daily on first boot; retry it.
apt_update() {
  local i
  for ((i = 1; i <= 10; i++)); do
    if apt_get update; then
      return 0
    fi
    echo "apt-get update failed (attempt $i), retrying in 30 s" >&2
    sleep 30
  done
  return 1
}

main() {
  exec </dev/null
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1

  apt_update
  apt_get install kde-plasma-desktop sddm

  systemctl set-default graphical.target
  apt_get clean
}

main "$@"
