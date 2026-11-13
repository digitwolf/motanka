---
inclusion: always
---

# Product

Motanka is an Omarchy-compatible Hyprland layer for existing Ubuntu installations. It installs next to the current desktop as a separate login session, follows upstream Omarchy, and removes cleanly.

- Supported hosts: Ubuntu 24.04 LTS (`noble`) and Ubuntu 26.04 LTS (`resolute`), amd64.
- Upstream: `basecamp/omarchy`, default branch `quattro`. Upstream files are vendored unmodified; Motanka adds a compatibility layer around them.
- Architecture and rationale: `#[[file:DESIGN.md]]`.

## Rules that every change must keep

1. Never replace, upgrade, downgrade or remove a package Motanka does not own.
2. Write `/usr`, `/etc` and `/opt` only through Motanka .deb packages.
3. Nothing outside the Motanka session sees Motanka (environment, services, dconf, autostart, PATH).
4. Every home-folder write is in a namespaced path or recorded in a ledger with a backup.
5. Removal works offline and after an interrupted install.

## Naming

- `motanka`: CLI, packages, session. `chumak`: apt repo tooling. `vyshyvka`: theme packs. `shliakh`: update channels.
- Do not use "Omarchy" or the "Oma-" prefix in names Motanka creates. Describe the project as "Omarchy-compatible".
