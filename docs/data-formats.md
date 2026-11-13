# Data format details

This file records details of the formats in `design.md` (Data Models) that the implementation of tasks 9.1 to 9.5 had to settle. They should move into `design.md` when the spec files are updated to match what was built.

## packages.yaml and package-map.tsv

- `packages.yaml` is a strict YAML subset, parsed by `tools/pkgmap` without a YAML library. The grammar is in the docstring of `tools/pkgmap`. Entries are sorted in byte order; `validate` fails otherwise.
- Every outcome other than `apt` has a `reason`. On `apt`, a `reason` is an optional note (for example "Ubuntu installs the command as fdfind").
- `apt` and `motanka` accept a list of package names: `{apt: [fcitx5-frontend-gtk3, fcitx5-frontend-gtk4]}`. In `package-map.tsv` the names are joined with commas.
- `package-map.tsv` starts with one `#` header line naming the release. Lines:

  ```
  <arch-name>  apt      <name[,name...]>        <note or ->
  <arch-name>  motanka  <package[,package...]>  <reason>
  <arch-name>  flatpak  <flathub-app-id>        <reason>
  <arch-name>  binary   <url>  <sha256>  <dest>
  <arch-name>  skip     -                       <reason>
  ```

  A `binary` line has a fifth field, `dest`, because the Helper needs the URL, the checksum and the destination.

## System_Ledger and User_Ledger

- Fields are never empty and never contain control characters; `-` stands for "none".
- Each append is followed by `sync <ledger>` (fsync), and by `sync <folder>` when the ledger file is new.
- If the previous append was torn (the file does not end with a newline), the next append first closes the fragment with the byte `\x01` and a newline. Readers skip lines with control characters, lines that do not match the format, and a last line without its newline, and warn once on stderr.

### User_Ledger

- `<path>` is relative to the home folder. A trailing `/` marks a folder Motanka created (`create` lines only); missing parent folders are ledgered this way before their `mkdir`.
- The folders on the way to `~/.local/state/motanka` that did not exist are ledgered as `create namespaced .local/`, `.local/state/`, `.local/state/motanka/` right after the ledger file is created. The reverse walk removes them last, after deleting the state folder.
- `<sha256-before>` and `<sha256-after>` hold a state: `-` (absent), the SHA-256 of a regular file's content, or `l:<SHA-256 of the link target>` for a symbolic link.
- `unplanned`, `setup-begin` and `setup-end` lines use `-` as class.
- Order of one change: parent folders, backup copy (fsynced) at `~/.local/state/motanka/backups/<backup-id>/<path>`, ledger line (fsynced), new content written to `.<name>.motanka-tmp` next to the target, rename over the target.
- Backup IDs look like `20261113T091502Z-1a2b3c4d`.
- The reverse walk prints one line per action: `restored`, `deleted`, `kept`, `block-removed` or `unplanned`, a tab, and the path; `moved`, the path and the new path under `~/.local/state/motanka-removed-<UTC date>/`.

## Test hooks

- `MOTANKA_ROOT`: a fake root folder for system paths (`/run/lock`, `/var/lib/motanka`, `/etc`, `/opt`). The guards check markers inside it and at their real paths, so it can add refusals but never remove one.
- `MK_HOME`: the home folder of the User_Ledger functions (default `HOME`).
- No command-line option changes a path.
