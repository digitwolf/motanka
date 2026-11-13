---
inclusion: always
---

# Tech

- **Language:** Bash (`set -euo pipefail`) for the CLI, shims, overrides and package scripts. Python 3 standard library only where Bash is a poor fit (package map validation, fingerprint diff). No other runtime dependency.
- **Packaging:** Debian source packages built with `debhelper` (compat 13) in a clean `sbuild` chroot per release, checked with `lintian`. Versions carry the release (`1.2.0-1~ubuntu24.04.1`). One suite per release and channel: `noble`, `noble-edge`, `resolute`, `resolute-edge`.
- **Stack prefix:** `/opt/motanka`, with binaries finding their libraries there (RUNPATH). No `ld.so.conf.d`, no `LD_LIBRARY_PATH`, no setuid or capabilities, no sudoers files. Privileged work goes through one polkit-authorised helper.
- **Logging:** systemd journal, identifier `motanka`. No log files.
- **Linux practices:** the 'Linux practices' section of `DESIGN.md` is binding.
- **Data files:** `packages.yaml` (package map), `upstream.pin` (upstream commit per channel), ledgers as line-oriented text.
- **Lint:** `shellcheck` and `shfmt -i 2` on every shell file.
- **Tests:** `bats-core` for shell unit tests; VM round-trip tests driven by scripts under `test/vm/`.
- **CI:** GitHub Actions. Jobs build packages and run tests inside VMs or containers, never on the runner's own system packages.
- **Commits:** Conventional Commits v1.0.0. No attribution trailers.

## Build and test environment

All building, installing, removing and testing happens in disposable QEMU/KVM virtual machines. See `testing.md`. The development host has `qemu-system-x86_64` and `/dev/kvm` (user is in the `kvm` group). It has no libvirt, no `cloud-localds`, and sudo needs a password, so host-side tooling must run unprivileged. Host tools the harness may use: `qemu-system-x86_64`, `qemu-img`, `ssh`, `rsync`, `gpgv`, `python3`, `zstd`.
