# Motanka

An Omarchy-compatible Hyprland layer for existing Ubuntu installations. It installs alongside your current desktop, tracks upstream Omarchy as it moves, and removes cleanly.

A *lialka-motanka* is a Ukrainian folk doll made without needles or scissors, only by winding and tying cloth. It can be unwound back into the original fabric. Motanka follows the same rule: it wraps your system, never cuts into it.

**Status:** design stage. Nothing is installable yet. See [DESIGN.md](DESIGN.md).

## Promises

- **Additive only.** No existing package is replaced, upgraded, downgraded or removed. Snaps, shell rc files and GNOME settings stay as they are.
- **Separate session.** Motanka appears as its own entry on the login screen. Other sessions never see its environment, services or settings.
- **Removable.** `motanka remove` returns the system to its earlier state, and a round-trip test in CI proves it.
- **Rolling.** Upstream Omarchy is vendored unmodified and bumped automatically when CI passes.

## Not affiliated

Motanka is an independent project. Omarchy is a trademark of its owners, and Motanka is not endorsed by Basecamp or 37signals. Ubuntu is a trademark of Canonical Ltd.
