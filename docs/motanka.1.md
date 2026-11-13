% MOTANKA(1) Motanka | Motanka manual
%
% 2026-11-13

# NAME

motanka - Omarchy-compatible Hyprland session for Ubuntu

# SYNOPSIS

**motanka** **install** [`--dry-run`] [`--yes`] [`--channel` *CHANNEL*]

**motanka** **remove** [`--dry-run`] [`--yes`] [`--purge`]

**motanka** **update** [`--dry-run`] [`--yes`] [`--system`]

**motanka** **rollback** [`--dry-run`] [`--yes`]

**motanka** **doctor** [`--json`] [`--fix`]

**motanka** **help**

# DESCRIPTION

Motanka is an Omarchy-compatible Hyprland layer for Ubuntu 24.04 LTS (noble) and Ubuntu 26.04 LTS (resolute) on amd64.
It installs next to the current desktop as a separate login session named Motanka, follows upstream Omarchy, and removes cleanly.
Upstream Omarchy is shipped unmodified in `/opt/motanka/share/omarchy`, and the Hyprland stack it expects in `/opt/motanka`.
Motanka records every change it makes to the system in the System_Ledger, and every change to a home folder in that user's User_Ledger, so that **motanka remove** can undo them.

**install**, **remove**, **update** and **rollback** change the system and run as root, for example with **sudo**.
**doctor** runs as any user and changes nothing unless `--fix` is given.
Every command writes its actions to the systemd journal with the identifier `motanka`; read them with **journalctl -t motanka**.

# COMMANDS

## install

Adds Motanka to this Ubuntu installation as a separate login session.
It first runs every read-only preflight check: the release, the architecture, the `universe` component, the dpkg state, 4 GB of free space on the root filesystem, the display manager and, when an NVIDIA GPU is present, its driver.
It then downloads the keyring and source packages of the running release from the Motanka repository, checks them against the signed `SHA256SUMS`, simulates the apt transaction, and refuses when a package Motanka does not own would be upgraded, downgraded or removed.
After a real run, choose Motanka at the login screen; per-user setup runs at the first login.
Running it again on an installed system changes nothing.

`--dry-run`
:   Run the preflight, verify the repository, and print the simulated apt transaction and every home-folder path first-login setup would write.
    Change nothing.

`--yes`, `-y`
:   Do not ask for confirmation.

`--channel` *CHANNEL*, `--channel=`*CHANNEL*
:   **stable** (the default) follows the release tags of upstream Omarchy; **edge** follows its default branch.

## remove

Removes Motanka and returns the system to its state before the install.
It refuses while a Motanka session runs.
As the invoking user it walks that user's User_Ledger in reverse: files Motanka wrote that nobody changed since are restored from their backup or deleted, files the user edited are moved to `~/.local/state/motanka-removed-`*DATE*, and the Motanka folders and marked shell blocks are deleted.
It then purges every Motanka package and removes the Ubuntu packages that the System_Ledger records as installed for Motanka, unless another package needs them or they were marked as manually installed since.
It works without network access and after an interrupted install or setup.
Other users' home folders are listed, never changed.

`--dry-run`
:   Print every planned action and change nothing.

`--yes`, `-y`
:   Do not ask for confirmation.

`--purge`
:   Also remove the packages and web apps installed from Omarchy menus.
    Without it they are kept and listed.

## update

Takes a snapshot, upgrades the Motanka packages, moves to the Upstream pin of the channel and runs the invoking user's pending upstream migrations, in that order.
It refuses when the Motanka apt source names a suite that does not match the running release; **sudo motanka doctor --fix** switches it.
A failing migration stops the update with its name and keeps the snapshot for **motanka rollback**.

`--dry-run`
:   Print the planned upgrade and change nothing.

`--yes`, `-y`
:   Do not ask for confirmation.

`--system`
:   Allow the upgrade to upgrade or downgrade packages Motanka does not own.
    Removing such a package is always refused.

## rollback

Reinstalls the Motanka packages of the latest snapshot from the package files stored in it, and restores the invoking user's ledgered home-folder files from it.
It works without network access.

`--dry-run`
:   Print what would be restored and change nothing.

`--yes`, `-y`
:   Do not ask for confirmation.

## doctor

Reports the release, the Motanka version, the channel, the Upstream pin, the Stack versions, the GPU driver, the display manager, the snapshot method, the features that are not available on this release, the unsupported calls of Arch commands logged in the last 30 days, and the ledgered paths of the home folder that are missing or changed, unplanned or written by the desktop.
Run it as your user for your home folder, or with **sudo** for the parts that need root and your home folder.
Without `--fix` it changes nothing.

`--json`
:   Print the report as one JSON document.

`--fix`
:   As root, when the Motanka apt source is missing, disabled, or names a suite that is not the running release's (after a release upgrade): replace it with the `motanka-source-`*SUITE* package of the running release, then print the report.

## help

**motanka help**, **motanka** `--help` and **motanka** `-h` print the commands, their options and the exit statuses.
Every command also accepts `-h` and `--help`.

# DEVELOPMENT BUILDS

A development build, one that does not come from a published Motanka suite, has the file `/opt/motanka/share/motanka/DEV_BUILD`.
On such a build, **install**, **remove**, **update**, **rollback** and **doctor** `--fix` refuse to run with exit status 7 when **systemd-detect-virt** reports no virtual machine.

`--i-know-this-is-not-a-vm`
:   Run a development build outside a virtual machine anyway.
    Published builds reject this option as a usage error.

A machine with `/etc/motanka-protected`, or a user with `~/.config/motanka-protected`, is a protected host.
There every build refuses **install**, **remove**, **update**, **rollback** and **doctor** `--fix` with exit status 7, whatever the options.

# EXIT STATUS

`0`
:   Success.

`1`
:   Unexpected error.

`2`
:   Usage error.

`3`
:   Unsupported host: release, architecture or the `universe` component.

`4`
:   Preflight failed: dpkg state, free space or display manager.

`5`
:   A package Motanka does not own would change.

`6`
:   Checksum or signature verification failed.

`7`
:   A guard refused: protected host, or development build outside a virtual machine.

`8`
:   A migration failed.

`9`
:   Another Motanka process holds the lock.

`10`
:   The repository suite does not match the running release.

`11`
:   Authorisation denied, or the command needs root.

`12`
:   Session refused: a Motanka session is running, the GPU driver is not supported, or another graphical session is active.

The commands use these statuses:

- **install**: 0, 1, 2, 3, 4, 5, 6, 7, 9, 11
- **remove**: 0, 1, 2, 5, 7, 9, 11, 12
- **update**: 0, 1, 2, 5, 7, 8, 9, 10, 11
- **rollback**: 0, 1, 2, 5, 7, 9, 11
- **doctor**: 0, 1, 2, and with `--fix` also 3, 6, 7, 9, 11

# ENVIRONMENT

`NO_COLOR`
:   When set to a non-empty value, messages are not coloured.
    Colour is used only when standard error is a terminal and `TERM` is not `dumb`.

`MOTANKA_APT_URI`
:   The Motanka repository that **install** and **doctor** `--fix` download the keyring and source packages from.
    The default is `https://digitwolf.github.io/motanka/apt`; **doctor** `--fix` without it uses the repository of the current `motanka.sources`.

`SUDO_USER`, `PKEXEC_UID`
:   The invoking user, set by **sudo** or **pkexec**.
    **remove**, **update**, **rollback** and **doctor** work on the home folder of that user.
    When neither is set, or the user is root, they read and change no home folder.

`MOTANKA_ROOT`
:   A hook of the unit tests that moves every system path into a folder.
    Never set it on a real system.

# FILES

`/usr/bin/motanka`
:   This command.

`/opt/motanka/`
:   The Hyprland stack, the command wrappers in `/opt/motanka/bin`, and the programs and data of Motanka.

`/opt/motanka/share/omarchy/`
:   Upstream Omarchy at the pinned commit, unmodified and read-only.
    `/usr/share/omarchy` links to a view of it.

`/opt/motanka/share/motanka/upstream.pin`
:   The Upstream pin of each channel.

`/opt/motanka/share/motanka/DEV_BUILD`
:   Marks a development build.

`/usr/share/wayland-sessions/motanka.desktop`
:   The Motanka login session.

`/etc/apt/sources.list.d/motanka.sources`
:   The Motanka apt source, owned by the `motanka-source-`*SUITE* package.

`/usr/share/keyrings/motanka-archive-keyring.gpg`, `/etc/apt/preferences.d/motanka`
:   The repository signing key, and the apt pin that limits the repository to Motanka packages.

`/var/lib/motanka/ledger`
:   The System_Ledger: one line per system change of **install**, **update** and **rollback**.

`/var/lib/motanka/snapshots/`
:   The snapshots of **update**; the newest 3 are kept.

`/var/log/motanka-ledger-`*DATE*
:   The System_Ledger, archived by **remove**.

`~/.local/state/motanka/`
:   The User_Ledger (`ledger`), the backups of replaced files (`backups/`) and the session capture (`capture/`).

`~/.local/state/motanka-removed-`*DATE*`/`
:   Files the user edited after Motanka wrote them, moved there by **remove**.

`/run/lock/motanka.lock`, `$XDG_RUNTIME_DIR/motanka.lock`
:   The system lock and the per-user lock.

`/etc/motanka-protected`, `~/.config/motanka-protected`
:   Mark a protected host; see DEVELOPMENT BUILDS.

# SEE ALSO

**apt-get**(8), **journalctl**(1), **sudo**(8)

The project: `https://github.com/digitwolf/motanka`
