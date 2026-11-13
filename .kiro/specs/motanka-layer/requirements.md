# Requirements Document

## Introduction

Motanka lets a user run upstream Omarchy (a Hyprland desktop built for Arch Linux) on an Ubuntu installation that is already in use. It installs as a separate login session next to the existing desktop, follows upstream Omarchy as it changes, and can be removed so that the system returns to its earlier state.

This spec covers the first deliverable: install, per-user setup, session isolation, the compatibility layer, the platform stack, updates and removal on Ubuntu 24.04 LTS and Ubuntu 26.04 LTS.

Out of scope:

- Ubuntu releases other than 24.04 LTS and 26.04 LTS, including interim releases and Ubuntu derivatives.
- Architectures other than amd64.
- A bootable ISO or any disk partitioning.
- Omarchy features that change the bootloader, initramfs or disk encryption (Limine menu, boot splash, autologin after disk unlock).
- Replacing, removing or reconfiguring the user's existing desktop, snaps or display manager.
- Theme packs beyond those shipped by upstream Omarchy.
- Use of the Omarchy name or branding in package, command or session names.

## Glossary

- **Supported_Release**: Ubuntu 24.04 LTS (`noble`) or Ubuntu 26.04 LTS (`resolute`), amd64, at any point release, with the `main` and `universe` components enabled.
- **Host**: the Ubuntu installation Motanka is installed on, including its packages, system files and every user's home folder.
- **Upstream**: the `basecamp/omarchy` repository. Its default branch is `quattro`.
- **Upstream_Pin**: the exact Upstream commit a Motanka release vendors.
- **Installer**: the `motanka install` command.
- **Remover**: the `motanka remove` command.
- **Updater**: the `motanka update` command.
- **Doctor**: the `motanka doctor` command.
- **Motanka_Repo**: the signed apt repository that serves Motanka packages, with one suite per Supported_Release and channel.
- **Motanka_Package**: a .deb whose name starts with `motanka-`, or the `motanka` metapackage.
- **Foreign_Package**: any installed package that is not a Motanka_Package.
- **Stack**: the Hyprland compositor and its companion programs and libraries at the versions the Upstream_Pin expects, shipped as Motanka_Packages under `/opt/motanka`.
- **Compat_Layer**: the package map, command shims and script overrides that translate Upstream's Arch-specific calls to Ubuntu.
- **Package_Map**: the file that maps each Arch package name Upstream installs to one outcome per Supported_Release: an apt package, a Motanka_Package, a Flatpak, an upstream binary, or `skip` with a reason.
- **Shim**: a Motanka-provided command named after an Arch tool (`pacman`, `yay`, `mkinitcpio`, `limine-*`, `snapper`) that translates or logs the call.
- **Motanka_Session**: the Wayland login session Motanka adds to the display manager.
- **Other_Session**: any login session on the Host that is not the Motanka_Session, such as GNOME or KDE.
- **System_Ledger**: the record under `/var/lib/motanka/` of every system change the Installer and Updater made.
- **User_Ledger**: the per-user record under `~/.local/state/motanka/` of every home-folder change Motanka made, with backups of replaced files.
- **Namespaced_Path**: a home-folder path that only Motanka or vendored Upstream code uses: `~/.config/dconf/motanka`, `~/.config/omarchy`, `~/.local/share/omarchy`, `~/.local/state/omarchy`, `~/.local/state/motanka`, `~/.cache/omarchy`, `~/.cache/motanka`.
- **Shared_File**: a home-folder file that programs outside the Motanka_Session also read, such as `~/.bashrc`, `~/.zshrc`, `~/.profile`, `~/.gitconfig`, `~/.config/gtk-3.0/settings.ini`, `~/.config/gtk-4.0/settings.ini` and `~/.config/mimeapps.list`.
- **Fingerprint**: a snapshot of Host state made of the installed package list with versions, the manually-installed package list, checksums of `/etc`, system and user unit files, `dconf dump /` per user, checksums of each home folder, the snap list, groups and `sysctl -a`.
- **Allowlist**: the fixed list of paths excluded from Fingerprint comparison: apt caches and lists, `/var/log`, the journal, archived Motanka ledgers, each user's `~/.cache`, `~/.local/state/motanka-removed-<date>/` folders and sysctl keys whose values change without configuration.
- **Helper**: the single root-owned program under `/opt/motanka/libexec/` that performs Motanka's privileged package operations after polkit authorisation.
- **Dev_Build**: a Motanka build that does not come from a published Motanka_Repo suite, marked by the file `/opt/motanka/share/motanka/DEV_BUILD`.
- **Protected_Host**: a machine that has the file `/etc/motanka-protected` or, for a user, `~/.config/motanka-protected`.
- **Channel**: `stable` (follows Upstream release tags) or `edge` (follows the Upstream default branch).
- **Migration**: a script in Upstream's `migrations/` folder.
- **CI_Pipeline**: the automated test system that runs on every Motanka change and every Upstream_Pin bump.

## Requirements

### Requirement 1: Supported releases

**User Story:** As an Ubuntu user on 24.04 LTS or 26.04 LTS, I want Motanka to install on my release, so that I do not have to upgrade or reinstall Ubuntu first.

#### Acceptance Criteria

1. WHEN the Installer runs on a Supported_Release THEN THE Installer SHALL complete with exit code 0 and a selectable Motanka_Session.
2. THE Motanka_Repo SHALL serve every Motanka_Package for both `noble` and `resolute` at the same Motanka version, except packages that exist only to supply on `noble` what the `resolute` archive already provides (`motanka-qt6`).
3. THE Motanka_Session SHALL provide the same Upstream_Pin, the same Stack versions and the same set of working Upstream commands on both Supported_Releases.
4. IF the Host is not a Supported_Release THEN THE Installer SHALL exit with a non-zero code before making any change and name the detected release.
5. IF the Host architecture is not amd64 THEN THE Installer SHALL exit with a non-zero code before making any change.
6. IF the `universe` component is disabled THEN THE Installer SHALL exit with a non-zero code before making any change and print the command that enables it.
7. WHERE a feature cannot work on one Supported_Release THE Doctor SHALL list that feature with the reason.

### Requirement 2: Preflight and dry run

**User Story:** As a user with a system I depend on, I want to see what Motanka will change before it changes anything, so that I can decide with full information.

#### Acceptance Criteria

1. WHEN the Installer starts THEN THE Installer SHALL run all preflight checks before making any change to the Host.
2. WHEN the Installer runs with `--dry-run` THEN THE Installer SHALL print the simulated apt transaction and every home-folder path first-login setup would write.
3. WHEN the Installer runs with `--dry-run` THEN THE Installer SHALL leave the Fingerprint of the Host unchanged.
4. IF `dpkg --audit` reports a problem or any package is in a broken state THEN THE Installer SHALL exit with a non-zero code before making any change.
5. IF the root filesystem has less than 4 GB free THEN THE Installer SHALL exit with a non-zero code before making any change.
6. IF the simulated apt transaction would upgrade, downgrade or remove a Foreign_Package THEN THE Installer SHALL exit with a non-zero code and list those packages.
7. IF the Host display manager cannot start Wayland sessions THEN THE Installer SHALL exit with a non-zero code and name the display manager.
8. WHEN preflight detects an NVIDIA GPU THEN THE Installer SHALL print the detected driver and whether the Stack supports it.

### Requirement 3: Additive installation

**User Story:** As a user, I want installing Motanka to add software without altering what I already have, so that my current desktop keeps working exactly as before.

#### Acceptance Criteria

1. THE Installer SHALL leave the version of every Foreign_Package that was installed before the run unchanged.
2. THE Installer SHALL remove zero Foreign_Packages and zero snaps.
3. THE Installer SHALL write to `/usr`, `/etc` and `/opt` only by installing packages through apt.
4. THE Stack SHALL install files only under `/opt/motanka`.
5. THE Stack SHALL depend only on Motanka_Packages and on packages available in `main` or `universe` of the Supported_Release.
6. THE Motanka_Repo SHALL publish only Motanka_Packages.
7. WHEN the Installer installs a Foreign_Package as a dependency THEN THE Installer SHALL record that package in the System_Ledger.
8. THE Installer SHALL write zero files into any home folder.
9. IF the Installer is interrupted THEN THE System_Ledger SHALL contain every change made up to the interruption.
10. WHEN the Installer runs on a Host where Motanka is already installed THEN THE Installer SHALL complete without changing the System_Ledger entries of the earlier run.
11. THE Motanka_Packages SHALL contain zero setuid files, zero setgid files and zero files with file capabilities.
12. THE Motanka_Packages SHALL install no file under `/etc/ld.so.conf.d` and no file under `/etc/sudoers.d`.
13. THE Motanka_Packages SHALL remove in their purge scripts every file their install scripts generated.

### Requirement 4: Repository trust

**User Story:** As a user, I want Motanka's packages to be verified, so that installing them does not weaken my system's security.

#### Acceptance Criteria

1. THE Installer SHALL verify the SHA-256 checksum of the keyring package before installing it.
2. THE Motanka_Repo SHALL sign the release metadata of every suite.
3. THE keyring package SHALL scope the Motanka signing key to the Motanka_Repo source with `Signed-By`.
4. THE keyring package SHALL install an apt pin that limits the Motanka_Repo to Motanka_Packages.
5. IF checksum or signature verification fails THEN THE Installer SHALL exit with a non-zero code before installing any package.
6. THE keyring package SHALL install an apt pin with a negative priority for every package from the Motanka_Repo that is not a Motanka_Package.
7. THE Motanka_Repo SHALL publish release metadata with a `Valid-Until` date at most 14 days after signing.
8. WHEN the Compat_Layer installs an upstream binary THEN THE Compat_Layer SHALL verify it against the SHA-256 checksum recorded in the Package_Map.
9. IF an upstream binary fails checksum verification THEN THE Compat_Layer SHALL delete the download and exit with a non-zero code.

### Requirement 5: Session isolation

**User Story:** As a user who still logs into GNOME or KDE, I want my other sessions to behave as if Motanka were not installed, so that trying Motanka carries no side effects.

#### Acceptance Criteria

1. WHEN the Installer completes THEN THE display manager SHALL list the Motanka_Session in addition to every session listed before.
2. THE Motanka_Session SHALL set its environment variables only in processes started by the Motanka_Session launcher.
3. THE Installer SHALL create no file under `/etc/profile.d`, no entry in `/etc/environment` and no file under any `~/.config/environment.d`.
4. THE Motanka_Session SHALL start its user services only through `motanka-session.target`.
5. WHILE an Other_Session is running THE Host SHALL run zero Motanka user services.
6. THE Motanka_Session SHALL store desktop settings in a dconf database separate from the user's default database.
7. WHEN a user changes theme, cursor or colour scheme in the Motanka_Session THEN THE output of `dconf dump /` in an Other_Session SHALL remain unchanged.
8. THE Motanka_Packages SHALL ship autostart entries only with an `OnlyShowIn` key that names the Motanka_Session.
9. THE Shims SHALL be reachable through `PATH` only inside the Motanka_Session.
10. WHILE Motanka is installed THE Fingerprint parts visible to an Other_Session SHALL equal their values before installation, apart from the Allowlist, the Motanka_Packages and the System_Ledger.
11. WHEN the Motanka_Session ends THEN THE Motanka_Session launcher SHALL remove from the systemd user manager every environment variable it imported.
12. IF the user already has another graphical session active THEN THE Motanka_Session launcher SHALL exit with a non-zero code before starting the compositor.
13. WHEN the Compat_Layer creates a desktop entry in a home folder THEN THE Compat_Layer SHALL add an `OnlyShowIn` key that names the Motanka_Session.
14. THE Motanka_Session SHALL set `LD_LIBRARY_PATH` in zero processes.

### Requirement 6: Per-user setup

**User Story:** As a user, I want Motanka to set up my account only when I first use it, so that accounts that never use Motanka stay untouched.

#### Acceptance Criteria

1. WHEN a user logs into the Motanka_Session for the first time THEN THE Motanka_Session SHALL run per-user setup before starting the desktop.
2. THE per-user setup SHALL record each home-folder write in the User_Ledger before performing it.
3. WHEN per-user setup would replace an existing file THEN THE per-user setup SHALL copy that file into the User_Ledger backup first.
4. THE per-user setup SHALL write only to Namespaced_Paths and to paths recorded in the User_Ledger.
5. THE per-user setup SHALL leave every Shared_File unchanged.
6. WHERE the user opts into shell integration THE per-user setup SHALL add one block delimited by `# >>> motanka >>>` and `# <<< motanka <<<` to the chosen shell rc file.
7. IF per-user setup is interrupted THEN THE next login to the Motanka_Session SHALL resume it from the User_Ledger.
8. WHILE a user has never logged into the Motanka_Session THE home folder of that user SHALL contain zero files created by Motanka.
9. WHEN per-user setup completes THEN THE per-user setup SHALL scan `~/.config`, `~/.local` and top-level dotfiles for paths changed during setup that are absent from the User_Ledger.
10. IF the scan finds a changed path that is absent from the User_Ledger THEN THE per-user setup SHALL record it in the User_Ledger as unplanned.
11. THE per-user setup SHALL replace files by writing a temporary file and renaming it.
12. WHEN a user logs into the Motanka_Session for the first time THEN THE per-user setup SHALL ask once whether to enable shell integration.

### Requirement 7: Compatibility layer

**User Story:** As a user, I want Omarchy's own commands and menus to work on Ubuntu, so that Motanka behaves like Omarchy without a rewritten copy of it.

#### Acceptance Criteria

1. THE Motanka_Packages SHALL ship Upstream's files at the Upstream_Pin byte-for-byte unmodified.
2. THE Package_Map SHALL contain one outcome per Supported_Release for every package named in Upstream's package lists at the Upstream_Pin.
3. WHEN Upstream code asks to install a package through an `omarchy-pkg-*` helper THEN THE Compat_Layer SHALL install the Package_Map outcome for the running Supported_Release.
4. WHEN Upstream code calls a Shim with an operation the Shim supports THEN THE Shim SHALL perform the equivalent apt or dpkg operation.
5. IF Upstream code calls a Shim with an operation the Shim does not support THEN THE Shim SHALL exit with a non-zero code and append the call to the Motanka log.
6. IF a requested package has the outcome `skip` THEN THE Compat_Layer SHALL exit with code 0 and print the recorded reason.
7. WHEN a user installs a package or web app from an Upstream menu THEN THE Compat_Layer SHALL record it in the User_Ledger or System_Ledger.
8. THE Compat_Layer SHALL ship a replacement for every Upstream script that reads or writes pacman, Limine or mkinitcpio configuration files.
9. IF the CI_Pipeline finds a package in Upstream's package lists that the Package_Map lacks THEN THE CI_Pipeline SHALL fail the Upstream_Pin bump.
10. IF an Upstream_Pin bump changes a script that the Compat_Layer replaces THEN THE CI_Pipeline SHALL fail the bump until the replacement is reviewed.
11. THE Compat_Layer SHALL perform every privileged package operation through the Helper.
12. THE Helper SHALL accept only package names that are outcomes in the Package_Map or entries in a ledger.
13. IF polkit denies authorisation THEN THE Helper SHALL exit with a non-zero code without changing any package.
14. THE Shims SHALL be reachable through `PATH` only in processes started by Upstream command wrappers.
15. WHEN a requested package has a Flatpak outcome and Flatpak is not installed THEN THE Compat_Layer SHALL install Flatpak through the Helper and record it in the System_Ledger.

### Requirement 8: Platform stack

**User Story:** As a user on an LTS release with older desktop packages, I want the Hyprland versions Omarchy expects, so that Omarchy's configuration works without being rewritten.

#### Acceptance Criteria

1. THE Stack SHALL provide Hyprland and its companion programs at the versions recorded for the Upstream_Pin.
2. THE Stack binaries SHALL load their Stack libraries from `/opt/motanka` on both Supported_Releases.
3. WHEN the Motanka_Session starts THEN `Hyprland --verify-config` SHALL report zero errors for the shipped configuration.
4. WHILE the Ubuntu `hyprland` package is installed on the Host THE Stack SHALL install and run without changing that package.
5. THE Stack SHALL start a Motanka_Session on Intel, AMD and virtual GPUs supported by the Supported_Release kernel.
6. IF the Stack does not support the detected GPU driver THEN THE Motanka_Session launcher SHALL exit and show the reason on the login screen log.
7. WHERE a Stack program needs unprivileged user namespaces THE Stack SHALL ship an AppArmor profile that grants it.
8. THE Motanka_Packages SHALL leave every kernel sysctl value unchanged.
9. WHERE the Host uses the NVIDIA driver at version 555 or later THE Stack SHALL start a Motanka_Session.

### Requirement 9: Rolling updates

**User Story:** As a user, I want Motanka to follow Omarchy's development, so that I get its changes without reinstalling.

#### Acceptance Criteria

1. WHEN the Updater runs THEN THE Updater SHALL take a snapshot, upgrade the Motanka_Packages, move to the Channel's Upstream_Pin and run pending Migrations, in that order.
2. THE Updater SHALL leave the version of every Foreign_Package unchanged unless the user passes `--system`.
3. THE Motanka_Repo SHALL offer the `stable` and `edge` Channels for each Supported_Release.
4. WHEN Upstream publishes a release tag THEN THE CI_Pipeline SHALL propose a `stable` Upstream_Pin bump within 24 hours.
5. WHEN the Upstream default branch changes THEN THE CI_Pipeline SHALL propose an `edge` Upstream_Pin bump within 24 hours.
6. THE CI_Pipeline SHALL classify each new Migration as `ok`, `override` or `n/a` before a bump is published.
7. WHEN the Updater runs a Migration THEN THE Updater SHALL record it in Upstream's migration state format.
8. IF a Migration fails THEN THE Updater SHALL stop, report the Migration name and leave the snapshot available.
9. WHEN the user runs `motanka rollback` THEN THE Updater SHALL restore the Motanka_Packages and User_Ledger paths to the latest snapshot.
10. THE Updater SHALL record the installed version of every Motanka_Package and an archive of the User_Ledger paths as the snapshot before every update.
11. IF a second Updater process starts while one is running THEN THE second process SHALL exit with a non-zero code without making any change.
12. WHERE snapper is configured for the root filesystem THE Updater SHALL create a snapper pre and post snapshot pair around the update.

### Requirement 10: Removal

**User Story:** As a user, I want to remove Motanka completely, so that trying it never costs me a reinstall.

#### Acceptance Criteria

1. WHEN the Remover completes THEN THE Fingerprint of the Host SHALL equal the Fingerprint taken before installation, apart from the Allowlist.
2. WHEN the Remover runs THEN THE Remover SHALL process the invoking user's User_Ledger in reverse order.
3. WHEN a ledgered file is unchanged since Motanka wrote it THEN THE Remover SHALL restore the backup or delete the file.
4. WHEN a ledgered file was edited by the user THEN THE Remover SHALL move it to `~/.local/state/motanka-removed-<date>/`.
5. THE Remover SHALL delete the invoking user's Namespaced_Paths and marked shell blocks.
6. THE Remover SHALL purge every Motanka_Package.
7. THE Remover SHALL remove the Foreign_Packages recorded in the System_Ledger that no other installed package depends on and that the user has not marked as manually installed since.
8. THE Remover SHALL remove zero Foreign_Packages that are absent from the System_Ledger.
9. WHEN the Remover runs without `--purge` THEN THE Remover SHALL keep packages and web apps the user installed from Upstream menus and list them.
10. WHEN the Remover runs with `--dry-run` THEN THE Remover SHALL print every planned action and leave the Fingerprint unchanged.
11. THE Remover SHALL complete without network access.
12. WHEN the Remover runs after an interrupted install or interrupted per-user setup THEN THE Remover SHALL complete with exit code 0.
13. WHEN other users have a User_Ledger THEN THE Remover SHALL list those users and leave their home folders unchanged.
14. WHEN the Remover completes THEN THE display manager SHALL list the same sessions as before installation.

### Requirement 11: Ubuntu release upgrade

**User Story:** As a user on 24.04 LTS, I want Motanka to survive my upgrade to 26.04 LTS, so that an Ubuntu upgrade does not strand it.

#### Acceptance Criteria

1. WHILE Motanka is installed THE `do-release-upgrade` from Ubuntu 24.04 LTS to Ubuntu 26.04 LTS SHALL complete without a package conflict caused by a Motanka_Package.
2. WHEN the Doctor runs with `--fix` after a release upgrade THEN THE Doctor SHALL switch the Motanka_Repo source to the suite of the running Supported_Release.
3. WHEN the Updater runs after the Doctor has switched the suite THEN THE Motanka_Session SHALL start on the upgraded Host.
4. WHEN the Remover runs after a release upgrade THEN THE Remover SHALL meet criteria 10.2 to 10.14.
5. IF the Motanka_Repo source names a suite that differs from the running release THEN THE Updater SHALL exit with a non-zero code and print the Doctor command.
6. THE Motanka_Package versions for `resolute` SHALL sort higher than the same Motanka version for `noble` under `dpkg --compare-versions`.

### Requirement 12: Diagnostics

**User Story:** As a user or maintainer, I want one command that explains Motanka's state, so that problems can be diagnosed and reported.

#### Acceptance Criteria

1. WHEN the Doctor runs THEN THE Doctor SHALL report the Supported_Release, Motanka version, Channel, Upstream_Pin, Stack versions, GPU driver, display manager and snapshot method.
2. WHEN the Doctor runs THEN THE Doctor SHALL report every ledgered path that is missing or changed.
3. WHEN the Doctor runs THEN THE Doctor SHALL report every unsupported Shim call logged in the last 30 days.
4. THE Doctor SHALL make no change to the Host unless the user passes `--fix`.
5. THE Installer, Remover and Updater SHALL write each action to the systemd journal with the identifier `motanka`.
6. THE Motanka logs and Doctor output SHALL contain no file contents from home folders.
7. WHEN the Doctor runs with `--json` THEN THE Doctor SHALL print its report as one JSON document.
8. WHEN the Doctor runs THEN THE Doctor SHALL report every User_Ledger entry recorded as unplanned.

### Requirement 13: Verification

**User Story:** As a maintainer, I want the install, isolation and removal promises tested automatically on both releases, so that a regression cannot ship.

#### Acceptance Criteria

1. THE CI_Pipeline SHALL run the round-trip test on both Supported_Releases for every change and every Upstream_Pin bump.
2. THE round-trip test SHALL run on a fresh image, an image with GNOME and snaps installed, a KDE flavour image and a multi-user image.
3. THE round-trip test SHALL compare the Fingerprint before installation, during installation from an Other_Session and after removal.
4. THE CI_Pipeline SHALL test removal after an interrupted install, removal without network access and removal after a release upgrade from 24.04 to 26.04.
5. THE CI_Pipeline SHALL simulate `apt-get install motanka` on each test image and fail if any Foreign_Package would change version or be removed.
6. THE CI_Pipeline SHALL run one probe script on a reference Omarchy system and on Motanka at the same Upstream_Pin and publish the difference.
7. IF a round-trip or isolation test fails THEN THE CI_Pipeline SHALL block publication to the Motanka_Repo.
8. THE Motanka_Repo SHALL publish a version to `noble` and `resolute` only when the CI_Pipeline passed for both.
9. THE CI_Pipeline SHALL block publication of a Motanka version until a manual NVIDIA hardware test result for that version is recorded in the repository.

### Requirement 14: Test isolation

**User Story:** As a developer working on a laptop that holds my own data, I want all Motanka building and testing to happen in virtual machines, so that a defect in Motanka cannot damage the machine I develop on.

#### Acceptance Criteria

1. THE test harness SHALL run every install, update, removal and package build inside a QEMU/KVM virtual machine.
2. THE test harness SHALL use an Ubuntu 26.04 LTS virtual machine for all development testing.
3. THE test harness SHALL use an Ubuntu 24.04 LTS virtual machine for release-specific tests and the release upgrade test.
4. THE test harness SHALL start each test from a copy-on-write overlay of a base image and delete the overlay when the test ends.
5. THE test harness SHALL run on the development host without `sudo` and without installing host packages.
6. THE test harness SHALL write on the development host only inside the repository folder and `~/.cache/motanka-vm/`.
7. THE test virtual machines SHALL have no access to the development host's home folder.
8. IF a Dev_Build runs where `systemd-detect-virt` reports `none` THEN THE Installer, Remover and Updater SHALL exit with a non-zero code before making any change unless the user passes `--i-know-this-is-not-a-vm`.
9. THE test harness SHALL never pass `--i-know-this-is-not-a-vm`.
10. IF `/dev/kvm` is not usable by the current user THEN THE test harness SHALL exit with a non-zero code and name the missing permission.
11. IF the Host is a Protected_Host THEN THE Installer, Remover and Updater SHALL exit with a non-zero code before making any change, for every build and every flag.
