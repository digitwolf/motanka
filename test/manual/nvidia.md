# Manual NVIDIA hardware test

Task 24.4; requirements 8.9 and 13.9. The VM tests cannot use an NVIDIA GPU, so every Motanka version is tested by hand on a real NVIDIA machine before it is published. The result goes into `test/manual/results/<version>-nvidia.md`, where `<version>` is the first line of `packaging/VERSION` (for example `0.1.0`). The publish job of `.github/workflows/ci.yml` runs `ci/check-nvidia-record` and stops when that file is missing or does not pass.

## Rules

- Never run this on the development host. It is a Protected_Host, and every Motanka build refuses to change it.
- Use a test machine, or a spare disk in one, whose data you can lose. It must have no `/etc/motanka-protected` and no `~/.config/motanka-protected`.
- Test both releases: a fresh Ubuntu 24.04 LTS desktop (noble) and a fresh Ubuntu 26.04 LTS desktop (resolute), one after the other on the same machine, each with the default GNOME desktop.
- The NVIDIA driver must be version 555 or later from the Ubuntu archive (`sudo ubuntu-drivers install`, or a `nvidia-driver-<version>` package of 555 or later), with kernel mode setting on (`/sys/module/nvidia_drm/parameters/modeset` is `Y`).
- The packages under test are the development builds of the commit to be published, from the CI run of that commit. They carry the marker `/opt/motanka/share/motanka/DEV_BUILD`, so `motanka remove` needs `--i-know-this-is-not-a-vm` on this real machine. That is what the option is for; the automated tests never pass it.

## What you need

- The 40-digit commit to be published and its Motanka version (`packaging/VERSION` at that commit).
- A checkout of that commit on the test machine, for `test/vm/collect-fingerprint.sh` and `tools/fpdiff.py`. Running them changes nothing: the collector writes only a temporary folder under `/run`.
- The candidate repositories of that commit. Each `vm` job of `.github/workflows/ci.yml` for the `roundtrip` test uploads the signed test repository it installed from as the artifact `candidate-repo-noble` or `candidate-repo-resolute`. They are signed with the TEST key of that CI run, which is embedded in their `install.sh`, and serve the URI `http://127.0.0.1:8765/repo`. Download the one for the release under test:

  ```
  gh run download <run-id> --repo digitwolf/motanka --name candidate-repo-<release> --dir ~/motanka-test/www/repo
  ```

## Steps

Do steps 1 to 14 on noble, then reinstall the machine with resolute and do them again. Work in `~/motanka-test`.

1. Install the screenshot tool before the first Fingerprint, so that it does not show up as a difference: `sudo apt-get install grim`.
2. Record the machine:

   ```
   lsb_release -ds; uname -r
   lspci -nn | grep -Ei 'vga|3d|display'
   nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
   cat /proc/driver/nvidia/version
   cat /sys/module/nvidia_drm/parameters/modeset
   dpkg-query -W gdm3
   ```

3. Fingerprint before, from the checkout: `sudo bash test/vm/collect-fingerprint.sh | (mkdir -p ~/motanka-test/fp-before && tar -C ~/motanka-test/fp-before -xf -)`.
4. In a second terminal, serve the repository and leave it running until step 12: `cd ~/motanka-test/www && python3 -m http.server --bind 127.0.0.1 8765`.
5. Dry run. The output must name the NVIDIA driver and say the Stack supports it:

   ```
   curl -fsSL http://127.0.0.1:8765/repo/install.sh | sudo env MOTANKA_APT_URI=http://127.0.0.1:8765/repo bash -s -- --dry-run
   ```

6. Install with the same command and `--yes` instead of `--dry-run`. It must exit 0. No `--i-know-this-is-not-a-vm` is needed here: the development-build marker arrives with the packages.
7. Log out of GNOME. The login screen must list Motanka next to the earlier sessions. Choose Motanka and log in. The first login runs per-user setup and asks once about shell integration; answer Decline.
8. In the Motanka session, open a terminal (Super+Return) and run the checks of the session VM test (`test/vm/session-guest.sh`, phase `session`):

   ```
   printf '%s\n' "$XDG_CURRENT_DESKTOP" "$XDG_SESSION_DESKTOP" "$DCONF_PROFILE" "$OMARCHY_PATH"
   printf '%s\n' "${PATH%%:*}"
   systemctl --user is-active motanka-session.target motanka-session-cleanup.service
   readlink -f "/proc/$(pgrep -u "$USER" -x Hyprland | head -n 1)/exe"
   grep -ihE 'renderer|nvidia' "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log | head -n 5
   hyprctl configerrors
   hyprctl monitors | grep -E '^Monitor'
   omarchy-version
   command -v pacman || echo "no pacman"
   for e in /proc/[0-9]*/environ; do tr '\0' '\n' <"$e" 2>/dev/null | grep -q '^LD_LIBRARY_PATH=' && echo "$e"; done; echo done
   grim ~/motanka-test/shot-$(lsb_release -cs).png
   ```

   Expected: `Motanka:Hyprland`, `motanka`, `motanka`, `/usr/share/omarchy`; `/opt/motanka/bin`; `active` twice; `/opt/motanka/bin/Hyprland`; a renderer line that names the NVIDIA GPU; no configuration errors; one `Monitor` line per connected monitor, each showing output; a version that is not `dev`; `no pacman`; only `done`; a screenshot with Upstream's bar and wallpaper.

9. Open the Omarchy menu (Super+Alt+Space), pick another theme under Style, and check that the bar, the wallpaper and the terminal colours change.
10. Log out from the Omarchy menu (System, Logout). The login screen must come back. Log into GNOME and check that it works as before, that `systemctl --user list-units 'motanka*'` lists no unit, and that `systemctl --user show-environment | grep -E '^(DCONF_PROFILE|OMARCHY_PATH)='` prints nothing.
11. Still in GNOME, remove Motanka. It must exit 0:

    ```
    sudo motanka remove --yes --i-know-this-is-not-a-vm
    ```

12. Stop the repository server of step 4.
13. Fingerprint after, and compare. `tools/fpdiff.py` must exit 0 (no difference apart from the Allowlist):

    ```
    sudo bash test/vm/collect-fingerprint.sh | (mkdir -p ~/motanka-test/fp-after && tar -C ~/motanka-test/fp-after -xf -)
    python3 tools/fpdiff.py ~/motanka-test/fp-before ~/motanka-test/fp-after
    ```

14. Fill in the section of the release in the record below.

When both releases are done, copy the template to `test/manual/results/<version>-nvidia.md`, fill in every `[fill in: ...]`, add the screenshots as `test/manual/results/<version>-nvidia-noble.png` and `test/manual/results/<version>-nvidia-resolute.png`, and commit them, for example as `test: record the NVIDIA hardware test of <version>`.

A check that fails is recorded as FAIL with what happened in the notes, and the version is not published. `ci/check-nvidia-record` accepts the record only when every check of both releases is PASS, both drivers are 555 or later, each `Motanka package version` is the version `packaging/version.sh` gives for that release, and each release ends with `Result: PASS`. Observations that are not checks, such as suspend and resume, go under Notes.

## Record template

The checker reads the rows of the noble table below as the list of required checks, so add a check here, not only in a record.

```markdown
# NVIDIA hardware test of Motanka [fill in: the version]

Motanka version: [fill in: the version, the first line of packaging/VERSION]
Commit: [fill in: the 40-digit commit of the CI run whose candidate repositories were installed]
CI run: [fill in: the URL of that CI run]
Tester: [fill in: name or GitHub handle]
Machine: [fill in: vendor and model]
GPU: [fill in: the lspci line, with the PCI ID]

## noble

Date: [fill in: YYYY-MM-DD]
Release: [fill in: lsb_release -ds]
Kernel: [fill in: uname -r]
Driver: [fill in: the driver_version of nvidia-smi, for example 570.153.02]
Kernel module: [fill in: the first line of /proc/driver/nvidia/version]
nvidia-drm modeset: [fill in: Y]
Display manager: [fill in: dpkg-query -W gdm3]
Motanka package version: [fill in: dpkg-query -W -f='${Version}' motanka-core, while installed]
Screenshot: [fill in: the file name]

| Check | Result | Notes |
|---|---|---|
| install --dry-run names the NVIDIA driver and says the Stack supports it | [fill in: PASS or FAIL] | |
| install --yes exits 0 | [fill in: PASS or FAIL] | |
| the login screen lists Motanka next to the earlier sessions | [fill in: PASS or FAIL] | |
| the first login completes per-user setup and asks once about shell integration | [fill in: PASS or FAIL] | |
| the session environment: Motanka:Hyprland, motanka, motanka, /usr/share/omarchy, /opt/motanka/bin first on PATH | [fill in: PASS or FAIL] | |
| motanka-session.target and motanka-session-cleanup.service are active | [fill in: PASS or FAIL] | |
| Hyprland runs from /opt/motanka/bin and renders on the NVIDIA GPU | [fill in: PASS or FAIL] | |
| hyprctl configerrors reports no errors | [fill in: PASS or FAIL] | |
| every connected monitor shows output | [fill in: PASS or FAIL] | |
| Upstream's bar and wallpaper are shown (screenshot) | [fill in: PASS or FAIL] | |
| omarchy-version does not print dev | [fill in: PASS or FAIL] | |
| pacman is not on the session PATH | [fill in: PASS or FAIL] | |
| no process has LD_LIBRARY_PATH | [fill in: PASS or FAIL] | |
| a theme switch from the Omarchy menu applies | [fill in: PASS or FAIL] | |
| logout returns to the login screen | [fill in: PASS or FAIL] | |
| GNOME afterwards: works, no motanka units, no Motanka variables in the user manager | [fill in: PASS or FAIL] | |
| remove --yes exits 0 | [fill in: PASS or FAIL] | |
| tools/fpdiff.py fp-before fp-after exits 0 | [fill in: PASS or FAIL] | |

Notes: [fill in: anything else seen, or none]

Result: [fill in: PASS or FAIL]

## resolute

Date: [fill in: YYYY-MM-DD]
Release: [fill in: lsb_release -ds]
Kernel: [fill in: uname -r]
Driver: [fill in: the driver_version of nvidia-smi, for example 570.153.02]
Kernel module: [fill in: the first line of /proc/driver/nvidia/version]
nvidia-drm modeset: [fill in: Y]
Display manager: [fill in: dpkg-query -W gdm3]
Motanka package version: [fill in: dpkg-query -W -f='${Version}' motanka-core, while installed]
Screenshot: [fill in: the file name]

| Check | Result | Notes |
|---|---|---|
| install --dry-run names the NVIDIA driver and says the Stack supports it | [fill in: PASS or FAIL] | |
| install --yes exits 0 | [fill in: PASS or FAIL] | |
| the login screen lists Motanka next to the earlier sessions | [fill in: PASS or FAIL] | |
| the first login completes per-user setup and asks once about shell integration | [fill in: PASS or FAIL] | |
| the session environment: Motanka:Hyprland, motanka, motanka, /usr/share/omarchy, /opt/motanka/bin first on PATH | [fill in: PASS or FAIL] | |
| motanka-session.target and motanka-session-cleanup.service are active | [fill in: PASS or FAIL] | |
| Hyprland runs from /opt/motanka/bin and renders on the NVIDIA GPU | [fill in: PASS or FAIL] | |
| hyprctl configerrors reports no errors | [fill in: PASS or FAIL] | |
| every connected monitor shows output | [fill in: PASS or FAIL] | |
| Upstream's bar and wallpaper are shown (screenshot) | [fill in: PASS or FAIL] | |
| omarchy-version does not print dev | [fill in: PASS or FAIL] | |
| pacman is not on the session PATH | [fill in: PASS or FAIL] | |
| no process has LD_LIBRARY_PATH | [fill in: PASS or FAIL] | |
| a theme switch from the Omarchy menu applies | [fill in: PASS or FAIL] | |
| logout returns to the login screen | [fill in: PASS or FAIL] | |
| GNOME afterwards: works, no motanka units, no Motanka variables in the user manager | [fill in: PASS or FAIL] | |
| remove --yes exits 0 | [fill in: PASS or FAIL] | |
| tools/fpdiff.py fp-before fp-after exits 0 | [fill in: PASS or FAIL] | |

Notes: [fill in: anything else seen, or none]

Result: [fill in: PASS or FAIL]
```
