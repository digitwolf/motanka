# Implementation Plan

Rules for every task: nothing is built, installed, removed or run with `sudo` on the development host. "26.04 VM" and "24.04 VM" mean throwaway test VMs started by `test/vm/`. No task runs `git push` or publishes to the apt repo.

- [x] 1. VM test harness
- [x] 1.1 Harness library, KVM check, `up` and `down`
  - Create `test/vm/lib.sh`, `test/vm/up`, `test/vm/down`
  - Start QEMU as the current user with user-mode networking and SSH forwarded to a free port on 127.0.0.1; overlays and state under `~/.cache/motanka-vm/`
  - Exit non-zero naming the `kvm` group when `/dev/kvm` is not usable; never call `sudo`
  - _Requirements: 14.1, 14.4, 14.5, 14.6, 14.10_
- [x] 1.2 Base image download and verification for 26.04
  - Create `test/vm/image`; verify the cloud image against the signed `SHA256SUMS` with `gpgv`
  - Seed cloud-init over NoCloud HTTP from a server bound to 127.0.0.1; generate the SSH key under `~/.cache/motanka-vm/`
  - _Requirements: 14.2, 14.4, 14.5_
- [x] 1.3 `run` and `push`
  - Create `test/vm/run`, `test/vm/push` (rsync over SSH; no host folder shared into the VM)
  - Add a self-test `test/vm/selftest` that boots a 26.04 VM, runs `systemd-detect-virt`, and tears it down
  - _Requirements: 14.7, 14.9_
- [x] 1.4 Fingerprint capture and comparison
  - Create `test/vm/fingerprint`, `tools/fpdiff.py` with the Allowlist, and `test/unit/fpdiff.bats`
  - _Requirements: 10.1, 13.3_
- [x] 1.5 24.04 image and image variants
  - Extend `test/vm/image` for `noble` and for the variants `gnome-snaps`, `kde`, `multiuser` (provisioning scripts in `test/vm/variants/`)
  - _Requirements: 13.2, 14.3_
- [x] 1.6 `test/run-all`, lint and unit-test runner
  - Create `test/run-all` (`--release noble` switch), `.shellcheckrc`, `test/unit/run` using `bats-core` vendored under `test/bats/`
  - _Requirements: 13.1, 14.5_

- [x] 2. Checkpoint — run `test/run-all`, confirm a 26.04 and a 24.04 VM boot and tear down, stop for questions
  - _Requirements: 14.1, 14.2, 14.3_

- [x] 3. Feasibility spikes (each runs in a test VM and writes its result into `design.md`)
- [x] 3.1 S3: Hyprland in QEMU
  - In a 26.04 VM, start Ubuntu's own Hyprland headless; choose between `virtio-vga-gl` with `egl-headless` and software rendering; record the QEMU flags in `test/vm/lib.sh`
  - _Requirements: 8.5_
- [x] 3.2 S1: Hyprland stack on 24.04 under `/opt/motanka`
  - In a 24.04 VM, try the four approaches in the design; record bundled libraries, package size and the chosen approach; repeat the chosen approach in a 26.04 VM
  - Keep scripts in `spikes/s1/`
  - _Requirements: 1.3, 3.5, 8.1, 8.2_
- [x] 3.3 S2: Upstream call inventory
  - Create `tools/inventory` producing `compat/inventory/<pin>.tsv`; record hardcoded paths, `sudo` and Arch-tool calls, `systemctl --user enable` calls, Shared_File writes and `uwsm` use; decide on shipping `uwsm`; list required overrides
  - _Requirements: 6.5, 7.8, 7.10_
- [x] 3.4 S4: release upgrade behaviour
  - In a 24.04 VM with placeholder `/opt` packages and a third-party source, run `do-release-upgrade` to 26.04 and record what happens to both
  - _Requirements: 11.1_
- [x] 3.5 S5: display managers
  - In 24.04 and 26.04 `gnome-snaps` VMs and a `kde` VM, install a placeholder session entry with `DesktopNames=Motanka;Hyprland`; confirm listing and `XDG_CURRENT_DESKTOP`
  - _Requirements: 2.7, 5.1_

- [x] 4. Checkpoint — review spike results; stop for the owner's decision if S1 found no approach that keeps the rules
  - _Requirements: 1.1, 8.1_

- [x] 5. Packaging foundations
- [x] 5.1 Build VM with per-release chroots
  - Create `test/vm/build` and `packaging/build.sh`: a build VM with `sbuild` chroots for `noble` and `resolute`, `dpkg-buildflags` hardening, `SOURCE_DATE_EPOCH`, `lintian`
  - _Requirements: 1.2, 14.1_
- [x] 5.2 Package content check
  - Create `tools/debcheck` and `test/unit/debcheck.bats`: fail on paths outside the design's file layout, setuid, setgid, capabilities, and files under `/etc/ld.so.conf.d`, `/etc/sudoers.d`, `/etc/profile.d`, `/etc/sysctl.d`
  - _Requirements: 3.3, 3.4, 3.11, 3.12, 5.3, 8.8_
- [x] 5.3 Keyring and source packages
  - Create `packaging/motanka-archive-keyring/` (key, apt pin) and `packaging/motanka-source/` (four suites, deb822, `Signed-By`, mutual conflicts)
  - Build in the build VM with a test key
  - _Requirements: 4.3, 4.4, 4.6_
- [x] 5.4 Local repo tooling
  - Create `chumak/build-repo`: `dists/` with `by-hash`, signed `InRelease`, `Valid-Until` 14 days, Origin `Motanka`, four suites; `test/vm/tests/repo.sh` installs the keyring from it in a 26.04 VM
  - _Requirements: 4.2, 4.7, 3.6, 9.3_
- [x] 5.5 Metapackage and version scheme
  - Create `packaging/motanka/`, `packaging/version.sh` and `test/unit/version.bats` comparing `noble` and `resolute` versions with `dpkg --compare-versions`
  - _Requirements: 1.2, 11.6_

- [ ] 6. Checkpoint — run `test/run-all`, stop for questions
  - _Requirements: 13.1_

- [x] 7. Stack packages (approach from S1)
- [x] 7.1 `motanka-stack-libs`
  - Create `packaging/motanka-stack-libs/` and `stack/versions.tsv`; build for both releases in the build VM; RUNPATH only
  - _Requirements: 3.4, 3.5, 8.1, 8.2_
- [x] 7.2 `motanka-stack-hyprland`
  - Create `packaging/motanka-stack-hyprland/`; install in a 26.04 VM that also has Ubuntu's `hyprland` and check that package is unchanged
  - _Requirements: 8.1, 8.4_
- [x] 7.3 `motanka-stack-tools`, AppArmor profiles and `motanka-stack`
  - Create `packaging/motanka-stack-tools/`, `packaging/motanka-stack/`, profiles under `packaging/*/apparmor/`
  - _Requirements: 8.7, 8.8_
- [x] 7.4 Stack test on both releases
  - Create `test/vm/tests/stack.sh`: start the Stack compositor in 26.04 and 24.04 VMs, check library paths resolve under `/opt/motanka` and `LD_LIBRARY_PATH` is unset
  - _Requirements: 1.3, 5.14, 8.2, 8.5_

- [x] 7.5 `motanka-qt6` for 24.04 (added after spike S1)
  - Create `packaging/motanka-qt6/` and its component list: Qt 6.10.2 qtbase, qtshadertools, qtsvg, qtdeclarative, qtwayland built with GCC 16 under `/opt/motanka`, noble only; build in the build VM (noble chroot)
  - _Requirements: 3.4, 3.5, 8.1, 8.2_
- [x] 7.6 `motanka-stack-shell` (Quickshell) for both releases (added after spike S1)
  - Create `packaging/motanka-stack-shell/`: cpptrace 1.0.4 with libunwind and libdwarf-lite as an orig component, Quickshell 0.3.2; against `motanka-qt6` on noble and the archive Qt on resolute; extend `test/vm/tests/stack.sh` to start `quickshell --version` and a trivial shell config in the session
  - _Requirements: 1.3, 3.4, 8.1, 8.2_

- [x] 7.7 Qt 6.12.0 for both releases (added after the first-login VM test)
  - Move `motanka-qt6` to Qt 6.12.0 with qtimageformats, build it for noble and resolute, build `motanka-stack-shell` against it on both, map Upstream's qt6-* names to `motanka-qt6` on both, and extend `test/vm/tests/stack.sh` with a QML file that declares `var native` and a WebP image (design.md, "Qt for both releases")
  - _Requirements: 1.2, 1.3, 3.4, 8.1, 8.2_

- [ ] 8. Checkpoint — run `test/run-all` and `test/run-all --release noble`, stop for questions
  - _Requirements: 13.1_

- [x] 9. Core data and CLI
- [x] 9.1 Package map
  - Create `packages.yaml` from Upstream's package lists at the pin, `tools/pkgmap` (validate, compile to `package-map.tsv` per release), `test/unit/pkgmap.bats`; fail on an unmapped Upstream package
  - _Requirements: 7.2, 7.9_
- [x] 9.2 CLI skeleton, exit codes, journal logging, lock
  - Create `src/motanka`, `src/lib/common.sh`, `test/unit/cli.bats`; `NO_COLOR`, `--yes`, `--dry-run` parsing; `flock` on `/run/lock/motanka.lock`
  - _Requirements: 9.11, 12.5, 12.6_
- [x] 9.3 Guards
  - Create `src/lib/guard.sh`, `test/unit/guard.bats`: Protected_Host and Dev_Build checks
  - _Requirements: 14.8, 14.11_
- [x] 9.4 System_Ledger library
  - Create `src/lib/sysledger.sh`, `test/unit/sysledger.bats`: append with fsync, read back after truncation
  - _Requirements: 3.7, 3.9_
- [x] 9.5 User_Ledger library with property test
  - Create `src/lib/userledger.sh`, `test/unit/userledger.bats`: write-then-rename, backups, reverse walk; for any generated action sequence, truncated at any point, the reverse walk restores the temp home byte for byte
  - _Requirements: 6.2, 6.3, 6.11, 10.2, 10.3, 10.4_

- [ ] 10. Checkpoint — run `test/run-all`, stop for questions
  - _Requirements: 13.1_

- [ ] 11. Installer
- [ ] 11.1 Preflight
  - Create `src/cmd/install.sh` (preflight part), `test/unit/preflight.bats`: release, architecture, `universe`, dpkg state, 4 GB free, display manager, NVIDIA driver report
  - _Requirements: 1.4, 1.5, 1.6, 2.1, 2.4, 2.5, 2.7, 2.8_
- [ ] 11.2 Private apt simulation and dry run
  - Extend `src/cmd/install.sh`, add `src/lib/aptsim.sh`: verify keyring checksum, private apt lists under `/run/motanka`, reject Foreign_Package changes, print the Plan
  - _Requirements: 2.2, 2.3, 2.6, 4.1, 4.5_
- [ ] 11.3 Real install and rerun
  - Extend `src/cmd/install.sh`, add `install.sh` bootstrap: `apt-get install --no-remove`, ledger lines, no home-folder writes, unchanged ledger on rerun
  - _Requirements: 1.1, 3.1, 3.2, 3.8, 3.10_
- [ ] 11.4 Installer VM tests
  - Create `test/vm/tests/install.sh`: dry-run fingerprint equality, install on every 26.04 variant, apt simulation check, interrupted install; run the fresh variant on 24.04
  - _Requirements: 2.3, 3.1, 3.2, 3.9, 13.5_

- [ ] 12. Checkpoint — run `test/run-all` and `test/run-all --release noble`, stop for questions
  - _Requirements: 13.1_

- [ ] 13. Compatibility layer
- [ ] 13.1 Vendored Upstream and wrappers
  - Create `upstream.pin`, `tools/vendor` (fetch at pin, verify tarball checksum), `tools/genwrappers`, `src/libexec/run-upstream`, `test/unit/wrappers.bats`
  - _Requirements: 5.9, 7.1, 7.14_
- [ ] 13.2 `pacman` and `yay` shims
  - Create `src/shims/pacman`, `src/shims/yay`, `test/unit/shim-pacman.bats` covering the translation table and exit 64
  - _Requirements: 7.3, 7.4, 7.5, 7.6_
- [ ] 13.3 `sudo` dispatcher and logging shims
  - Create `src/shims/sudo`, `src/shims/{mkinitcpio,snapper,limine-*}`, `test/unit/shim-sudo.bats`
  - _Requirements: 7.4, 7.5_
- [ ] 13.4 Helper and polkit action
  - Create `src/libexec/helper`, `packaging/motanka-core/org.motanka.policy`, `test/unit/helper.bats`: for any name outside the map and ledgers the Helper refuses; exit 11 on denial; `menu-install` ledger lines
  - _Requirements: 7.7, 7.11, 7.12, 7.13_
- [ ] 13.5 Binary and Flatpak outcomes
  - Create `src/lib/outcomes.sh`, `test/unit/outcomes.bats`: SHA-256 verification, delete on mismatch, Flatpak installed through the Helper when missing, apps with `--user`
  - _Requirements: 4.8, 4.9, 7.15_
- [ ] 13.6 Package and web-app overrides
  - Create `src/overrides/omarchy-pkg-*` and the web-app override adding `OnlyShowIn=Motanka;`, `test/unit/overrides.bats`
  - _Requirements: 5.13, 7.3, 7.7_
- [ ] 13.7 Overrides for pacman, Limine and mkinitcpio configuration scripts
  - Create the overrides listed by S2 under `src/overrides/`; add `tools/checkoverrides` failing when an Upstream script that touches those files has no override
  - _Requirements: 7.8, 7.10_

- [ ] 14. Checkpoint — run `test/run-all`, stop for questions
  - _Requirements: 13.1_

- [ ] 15. Session
- [ ] 15.1 Session entry and launcher
  - Create `packaging/motanka-core/motanka.desktop`, `src/libexec/session`, `test/unit/session.bats`: environment, concurrent-session refusal, GPU check including NVIDIA 555 or later
  - _Requirements: 5.1, 5.2, 5.12, 5.14, 8.6, 8.9_
- [ ] 15.2 User units, target and environment cleanup
  - Create `packaging/motanka-core/systemd/motanka-session.target`, `motanka-session-cleanup.service`, `.wants/` symlinks, `session-env.list`
  - _Requirements: 5.4, 5.5, 5.11_
- [ ] 15.3 dconf profile and purge cleanup
  - Create `packaging/motanka-core/dconf/`, `postinst` and `postrm` handling the compiled database
  - _Requirements: 3.13, 5.6, 5.7_
- [ ] 15.4 Autostart entries, portal configuration and `motanka-core` package
  - Create `packaging/motanka-core/` control files, `motanka-portals.conf`, autostart entries with `OnlyShowIn=Motanka;`; per-release `Depends` generated from `packages.yaml`
  - _Requirements: 5.8, 8.3_
- [ ] 15.5 Isolation VM tests
  - Create `test/vm/tests/isolation.sh` on the 26.04 `gnome-snaps` variant: fingerprint from a GNOME session while installed, theme switch leaves GNOME `dconf dump /` unchanged, no Motanka units in GNOME, environment removed after logout, no `pacman` in an interactive shell
  - _Requirements: 5.3, 5.5, 5.7, 5.9, 5.10, 5.11_

- [ ] 16. Checkpoint — run `test/run-all` and `test/run-all --release noble`, stop for questions
  - _Requirements: 13.1_

- [x] 17. Per-user setup
- [x] 17.1 Setup engine and path classes
  - Create `home-paths.tsv`, `src/libexec/user-setup`, `test/unit/user-setup.bats`: class handling, Shared_Files untouched, symlink and dconf database creation
  - _Requirements: 6.1, 6.4, 6.5, 6.8_
- [x] 17.2 Resume and unplanned-write scan
  - Extend `src/libexec/user-setup`, add tests for interruption at each step and for a planted unplanned write
  - _Requirements: 6.7, 6.9, 6.10_
- [x] 17.3 Shell integration prompt
  - Create `src/libexec/shell-integration`: ask once at first login, marked block on acceptance, no rc change on refusal
  - _Requirements: 6.6, 6.12_
- [x] 17.4 First-login VM test
  - Create `test/vm/tests/first-login.sh` on the 26.04 `multiuser` variant: one user logs in, the other user's home has no Motanka files; `Hyprland --verify-config` reports zero errors
  - _Requirements: 1.1, 6.8, 8.3_

- [ ] 18. Checkpoint — run `test/run-all`, stop for questions
  - _Requirements: 13.1_

- [ ] 19. Remover
- [ ] 19.1 User phase
  - Create `src/cmd/remove.sh` (user part): reverse ledger walk, edited files moved to `motanka-removed-<date>`, Namespaced_Paths and marked blocks deleted
  - _Requirements: 10.2, 10.3, 10.4, 10.5_
- [ ] 19.2 System phase
  - Extend `src/cmd/remove.sh`: self-copy to `/run/motanka`, purge Motanka_Packages, remove only ledgered Foreign_Packages still unneeded, keep and list menu installs without `--purge`, list other users
  - _Requirements: 10.6, 10.7, 10.8, 10.9, 10.13, 10.14_
- [ ] 19.3 Dry run, offline and interrupted cases
  - Extend `src/cmd/remove.sh`, add `test/vm/tests/remove-edge.sh`: dry-run fingerprint equality, removal with networking disabled, removal after an interrupted install and interrupted setup
  - _Requirements: 10.10, 10.11, 10.12_
- [ ] 19.4 Round-trip VM test
  - Create `test/vm/tests/roundtrip.sh`: fingerprint, install, first login, theme switch, menu install, web app, remove, compare; all four variants on 26.04 and the fresh variant on 24.04
  - _Requirements: 10.1, 13.1, 13.2, 13.3_

- [ ] 20. Checkpoint — run `test/run-all` and `test/run-all --release noble`, stop for questions
  - _Requirements: 13.1_

- [ ] 21. Updater
- [ ] 21.1 Snapshots
  - Create `src/lib/snapshot.sh`, `test/unit/snapshot.bats`: manifest, stored .debs, per-user archive, keep 3, snapper pair when configured
  - _Requirements: 9.10, 9.12_
- [ ] 21.2 Update flow
  - Create `src/cmd/update.sh`: suite check, simulation, `--system`, ordering of snapshot, upgrade, pin and migrations
  - _Requirements: 9.1, 9.2, 11.5_
- [ ] 21.3 Migration runner
  - Create `migrations.tsv`, `src/overrides/omarchy-migrate`, `tools/classify-migrations`, `test/unit/migrate.bats`: classes, Upstream state format, stop on failure
  - _Requirements: 9.6, 9.7, 9.8_
- [ ] 21.4 Rollback
  - Create `src/cmd/rollback.sh`: reinstall stored .debs, restore the user archive
  - _Requirements: 9.9_
- [ ] 21.5 Update VM test
  - Create `test/vm/tests/update.sh` in a 26.04 VM: update between two locally built versions, Foreign_Package versions unchanged, second concurrent update exits 9, failed migration keeps the snapshot, rollback restores
  - _Requirements: 9.1, 9.2, 9.8, 9.9, 9.11_

- [ ] 22. Doctor and release upgrade
- [ ] 22.1 Report
  - Create `src/cmd/doctor.sh`, `test/unit/doctor.bats`: fields, missing or changed ledgered paths, unplanned entries, shim calls from the journal for 30 days, per-release feature list, `--json`, no change without `--fix`
  - _Requirements: 1.7, 12.1, 12.2, 12.3, 12.4, 12.7, 12.8_
- [ ] 22.2 Suite switch with `--fix`
  - Extend `src/cmd/doctor.sh`: install the `motanka-source-<suite>` package for the running release
  - _Requirements: 11.2_
- [ ] 22.3 Release upgrade VM test
  - Create `test/vm/tests/release-upgrade.sh`: install on 24.04, `do-release-upgrade` to 26.04, `doctor --fix`, update, session starts, remove, fingerprint check
  - _Requirements: 11.1, 11.3, 11.4, 13.4_

- [ ] 23. Checkpoint — run `test/run-all` and `test/run-all --release noble`, stop for questions
  - _Requirements: 13.1_

- [ ] 24. CI and repository
- [ ] 24.1 CI workflow and publish gate
  - Create `.github/workflows/ci.yml`: lint, unit tests, package build, VM tests for both releases, publish job that depends on all of them and copies one version to `noble` and `resolute` together; the publish job stays disabled until the owner enables it
  - _Requirements: 1.2, 13.1, 13.4, 13.7, 13.8_
- [ ] 24.2 Pin-bump workflow
  - Create `.github/workflows/pin-bump.yml`: daily `edge` bump proposal, `stable` proposal on an Upstream release tag, gates from `tools/pkgmap`, `tools/checkoverrides` and `tools/classify-migrations`
  - _Requirements: 7.9, 7.10, 9.4, 9.5, 9.6_
- [ ] 24.3 Parity probe
  - Create `test/parity/probe.sh`, `test/parity/diff.py`, `test/vm/image` support for a reference Arch VM with Upstream at the pin
  - _Requirements: 13.6_
- [ ] 24.4 NVIDIA manual test record
  - Create `test/manual/nvidia.md` (steps and result template) and a CI check that requires `test/manual/results/<version>-nvidia.md` before publishing
  - _Requirements: 8.9, 13.9_
- [ ]* 24.5 Man page and shell completions
  - Create `docs/motanka.1.md`, `completions/motanka.bash`, `completions/_motanka`; add them to `motanka-core`
  - _Requirements: 12.4_

- [ ] 25. Final checkpoint — run `test/run-all` and `test/run-all --release noble`, check every acceptance criterion against a test or a documented manual check, update the spec files to match what was built
  - _Requirements: 13.1, 13.3_
