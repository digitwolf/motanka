---
inclusion: always
---

# Testing: virtual machines only

The development host is a daily-use Ubuntu 26.04 laptop with encrypted LVM and personal data. Motanka must never be installed, removed or tested on it.

## Hard rules

- No task, script, hook or agent may run `motanka install`, `motanka remove`, `motanka update`, `apt install`, `apt purge`, `dpkg -i`, or any `sudo` command on the development host.
- No task may write outside the repository folder on the development host, except VM disk images and caches under `~/.cache/motanka-vm/`.
- Package builds run inside a VM or a container, because build dependencies must not be installed on the host.
- Allowed on the host: editing files, `shellcheck`, `git`, and starting or stopping QEMU VMs as the current user. Unit tests (`bats`) and `shfmt` also run inside a VM, never on the host.
- The host has `~/.config/motanka-protected`, so every Motanka build refuses to change it.
- Every Motanka command that changes a system refuses to run unless it detects a VM (`systemd-detect-virt` is not `none`) or the user passes `--i-know-this-is-not-a-vm`. Test scripts never pass that flag.

## Test VMs

- **Primary:** Ubuntu 26.04 LTS (`resolute`) cloud image, amd64. All development testing runs here.
- **Secondary:** Ubuntu 24.04 LTS (`noble`) cloud image, for release-specific tests and the 24.04 → 26.04 upgrade test.
- VMs are started with `qemu-system-x86_64 -enable-kvm` as the current user, user-mode networking, SSH forwarded to a local port, and cloud-init seeded over NoCloud HTTP (no extra host packages).
- Each test starts from a copy-on-write overlay of a base image and deletes the overlay afterwards, so every run begins from a known state.
- Base image variants: fresh server, GNOME desktop with snaps, KDE flavour, multi-user.
- The repo is copied into the VM (rsync over SSH); the VM never mounts the host home folder.

## Commands (to be implemented under `test/vm/`)

- `test/vm/up <release> <variant>`: create an overlay and boot it.
- `test/vm/run <name> -- <command>`: run a command in the VM over SSH.
- `test/vm/fingerprint <name>`: capture the Fingerprint.
- `test/vm/down <name>`: stop the VM and delete the overlay.
- `test/run-all`: `shellcheck` on the host, then unit tests and VM tests inside 26.04 VMs; `--release noble` for 24.04.
- `bats-core`, `bats-support` and `bats-assert` are vendored under `test/bats/{core,support,assert}`.
- Test logs for the implementer are copied to `~/.cache/motanka-vm/results/<run-id>/`.
