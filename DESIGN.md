# Motanka design

## Goal

Run upstream Omarchy on any supported Ubuntu installation, keep pace with upstream, and be fully removable.

## Approach: overlay, not fork

Omarchy's code is vendored unmodified at a pinned upstream commit. Motanka translates only the Arch-specific commands and paths that code calls.

```
basecamp/omarchy   pinned commit, vendored untouched
        │
compat layer       package map · command shims · overrides · migration ledger
        │
platform repo      Motanka apt repo with the current Hyprland stack in /opt/motanka
        │
supported Ubuntu release
```

## Upstream tracking

- Upstream default branch: `quattro` (`master` is stale).
- `stable` channel follows upstream release tags (v4.5.0 at the time of writing).
- `edge` channel follows `quattro`, bumped daily and merged when CI passes.

## Rules (all enforced in CI)

1. Never replace, upgrade, downgrade or remove a package Motanka does not own. The apt repo ships only `motanka-` prefixed packages. The Hyprland stack lives in `/opt/motanka`.
2. Write system paths only through dpkg. Every file in `/usr`, `/etc` and `/opt` belongs to a package.
3. Nothing outside the session sees Motanka.
   - No `/etc/environment`, `/etc/profile.d` or `~/.config/environment.d`.
   - User services hang off `motanka-session.target`, never `graphical-session.target`.
   - Desktop settings use a separate store via `DCONF_PROFILE`.
   - Autostart entries carry `OnlyShowIn=`.
4. Every write into a home folder is namespaced or recorded in a ledger.
5. Removal works offline and after an interrupted install.

## Compat layer

- **Package map** (`packages.yaml`): keyed by Arch package name. For each Ubuntu release: an apt name, the Motanka repo, Flatpak, an upstream binary, or `skip` with a reason. CI fails on an unmapped upstream package.
- **Helper overrides**: the 10 `omarchy-pkg-*` scripts, which carry about 72% of Omarchy's package operations.
- **Shims**: private `pacman`, `yay`, `mkinitcpio`, `limine-*` and `snapper` commands on the PATH of Omarchy's own processes only. Unsupported calls are logged.
- **Overrides**: Ubuntu versions of scripts that shims cannot cover (updater, mirrors, keyrings, boot configuration). CI flags upstream changes to overridden files.

## Ownership of changes

| Change | Owner | Undone by |
|---|---|---|
| apt source, signing key, pinning | `motanka-archive-keyring` | `apt purge` |
| Hyprland stack in `/opt/motanka` | `motanka-stack` | `apt purge` |
| Vendored Omarchy, shims, overrides, session entry, launcher, user services, dconf profile | `motanka-core` | `apt purge` |
| Packages pulled from Ubuntu | system ledger | removing exactly those packages |
| Optional system tweaks | `motanka-tweaks` (opt-in) | `apt purge` |
| Omarchy's own folders in the home folder | the namespace | deleting those prefixes |
| Session-only configs (`hypr`, `waybar`, …) | user ledger and backups | restoring the backup or deleting the file |
| Shared files (shell rc, git, GTK) | untouched by default; opt-in marked block | deleting the marked block |
| Packages and web apps installed from Omarchy menus | ledger | listed on removal; kept unless `--purge` |

## Install

1. Preflight, read-only. `--dry-run` stops here and prints the simulated apt run and every home-folder path.
2. Install the keyring package (checksum verified), then `apt install motanka`. Record the transaction in `/var/lib/motanka/ledger`.
3. Per-user setup runs on first login to the session. Each step is written to `~/.local/state/motanka/ledger` before it runs.

## Remove

`motanka remove [--purge] [--dry-run]`

1. Walk the user ledger in reverse. Unchanged files are restored or deleted. Edited files move to `~/.local/state/motanka-removed-<date>/`.
2. `apt purge` the `motanka-*` packages, then remove only the Ubuntu packages in the system ledger.
3. Other users' home folders are listed, not touched.

## Updates

Snapshot, `apt upgrade`, move vendored Omarchy to the channel pin, run migrations, restart what changed. Each new upstream migration is classified in CI as `ok`, `override` or `n/a`. Snapshots use snapper on btrfs, LVM snapshots where there is free space, and config-only snapshots otherwise.

## Tests

- **Round trip**: fingerprint the system, install, use, check other sessions are unchanged, remove, compare fingerprints.
- **Parity**: run one probe script on a reference Omarchy VM and on Motanka at the same commit, and diff the output.
- **Edge cases**: interrupted install, offline removal, removal after `do-release-upgrade`.

## Build order

1. Ubuntu 24.04 LTS and 26.04 LTS (amd64): vendored Omarchy, package map, helper overrides, separate session, dconf isolation, ledger-based removal, Hyprland stack in the Motanka repo.
2. Update bot, migration classifier, channels.
3. Parity comparison and the full test matrix.
4. Snapshot methods and update polish.

## Naming

- `motanka`: CLI and packages.
- `chumak`: the apt repo that carries the stack.
- `vyshyvka`: theme packs.
- `shliakh`: update channels.

## Linux practices

These decisions tighten the design above. Where they differ from an earlier section, this section wins.

### Filesystem layout

- `/opt/motanka` holds the stack, vendored Omarchy (`/opt/motanka/share/omarchy`, read-only, root-owned), wrappers, shims and the Helper. Only these files live outside it, because the system looks for them in fixed places: `/usr/bin/motanka`, the session entry in `/usr/share/wayland-sessions/`, user units in `/usr/lib/systemd/user/`, the polkit action, the portal configuration, AppArmor profiles, the dconf profile and keyring, shell completions and the man page. All are package-owned and prefixed `motanka`.
- State in `/var/lib/motanka`. No log files: everything goes to the systemd journal with the identifier `motanka`.
- Stack binaries find their libraries through RUNPATH. No `ld.so.conf.d` entry and no `LD_LIBRARY_PATH`, because both leak into programs that are not part of the stack.
- No setuid, setgid or file-capability binaries. Hyprland gets its seat from logind.
- No kernel modules, no DKMS, no sysctl changes.

### Privilege

- No sudoers files. Privileged package operations go through one Helper, authorised by polkit (`pkexec`), which accepts only package names found in the root-owned Package_Map or a ledger.
- Upstream scripts call `sudo pacman …`, and sudo resets `PATH`, so a `pacman` shim alone is never found. The wrapper scope therefore includes a `sudo` dispatcher: if the command is a shimmed tool it runs the shim, which calls the Helper; anything else is passed to the real `/usr/bin/sudo`. The dispatcher runs unprivileged and grants nothing.

### Shim scope

- Shims are not on the session `PATH`. Each upstream command gets a generated wrapper in `/opt/motanka/bin` that sets `PATH` to include the shim folder and then runs the unmodified upstream script. Interactive shells and other programs never see a `pacman` command, so distro-detection tools are not misled.

### Session

- The session entry declares `DesktopNames=Motanka;Hyprland`, so `XDG_CURRENT_DESKTOP=Motanka:Hyprland`. Autostart entries, web-app launchers and portal configuration key on `Motanka`. They stay hidden in GNOME, KDE and in Ubuntu's own Hyprland session.
- `motanka-session.target` binds to `graphical-session.target`, so portals and other standard session services start normally. Motanka's own units are wanted only by `motanka-session.target`, through package-owned symlinks. Nothing is enabled per user, so `~/.config/systemd` is not written.
- Variables imported into the systemd user manager are removed when the session ends, because that manager outlives the session and is shared with the user's other sessions.
- The launcher refuses to start if the user already has another graphical session active.
- `XDG_DATA_DIRS` gains `/opt/motanka/share` inside the session only.

### Packaging

- Each release's packages are built in a clean chroot of that release (`sbuild`), with `dpkg-buildflags` hardening and `SOURCE_DATE_EPOCH` for reproducible output. `lintian` runs on every package.
- Versions carry the release, for example `1.2.0-1~ubuntu24.04.1` and `1.2.0-1~ubuntu26.04.1`, so a release upgrade moves forward.
- Files that maintainer scripts generate (the compiled dconf database, caches) are removed in `postrm purge`. Maintainer scripts never touch home folders.
- Stack programs that need unprivileged user namespaces ship an AppArmor profile that grants it. The system-wide restriction stays on.
- Candidates for the 24.04 stack build, to be settled by the first spike: a newer GCC with `libstdc++` shipped in `/opt/motanka/lib`, or the same compiler with `-static-libstdc++`; newer Wayland and input libraries built into `/opt/motanka`; Mesa and the kernel always come from the host.

### Repository

- deb822 `.sources` file with `Signed-By` pointing at the key shipped in the keyring package.
- apt pin: negative priority for everything in the repo except `motanka` and `motanka-*`. A mistake or compromise in the repo cannot replace a host package.
- Signed `InRelease` with `Valid-Until` at most 14 days, and `Acquire-By-Hash` so clients never see a half-updated index.
- Third-party binaries named in the Package_Map are pinned by SHA-256 and installed under `/opt/motanka` or a namespaced home path. No `curl | sh`.

### Home folder

- Planned writes are known in advance from the vendored `config/` tree. They are backed up and ledgered before the write, and files are replaced by write-then-rename.
- After per-user setup a scan of `~/.config`, `~/.local` and top-level dotfiles finds anything else that changed. Such paths are ledgered as unplanned, shown by `motanka doctor`, and fail CI.
- Locks: `flock` on `/run/lock/motanka.lock` for system operations and `$XDG_RUNTIME_DIR/motanka.lock` for per-user ones.

### Snapshots

- Motanka's own snapshot is the list of installed Motanka package versions plus an archive of the ledgered user paths. Rollback reinstalls those versions from the repo and restores the archive.
- Motanka does not create LVM snapshots. If snapper is already configured for the root filesystem, the updater adds a pre and post pair.

### Safety guards

- A Dev_Build (not from a published suite) refuses to install, update or remove outside a virtual machine unless `--i-know-this-is-not-a-vm` is passed. Published builds have no such check, so real users are not asked for the flag.
- A Protected_Host (`/etc/motanka-protected` or `~/.config/motanka-protected`) refuses every build and every flag.

### CLI

- `motanka <install|remove|update|rollback|doctor>`, with `--dry-run`, `--yes` for non-interactive use, `--json` on `doctor`, documented exit codes, `NO_COLOR` support, a man page and bash and zsh completions.
