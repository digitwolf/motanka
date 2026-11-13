#!/usr/bin/env bash
# Provision the gnome-snaps base image: Ubuntu's minimal GNOME desktop with
# GDM, plus the Firefox and Thunderbird snaps.
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
  local s
  if [[ $(id -u) -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1

  apt_update
  apt_get install ubuntu-desktop-minimal

  snap wait system seed.loaded
  for s in firefox thunderbird; do
    if snap list "$s" >/dev/null 2>&1; then
      echo "snap $s is already installed"
    else
      snap install "$s"
    fi
  done
  # Fixed snap revisions keep Fingerprints taken during a test comparable.
  snap refresh --hold

  systemctl set-default graphical.target
  apt_get clean
}

main "$@"
