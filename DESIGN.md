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
