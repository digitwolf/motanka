#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # scripts are single-quoted on purpose
# Unit tests for tasks 13.6 and 13.7: the omarchy-pkg-* and web-app
# overrides (5.13, 7.3, 7.7), the provisioning override
# omarchy-provision-user (6.4, 6.5), the overrides for Upstream scripts with Arch
# tools or paths (7.8), compat/overrides.tsv and tools/checkoverrides
# (7.10). The Helper and every system command are stubs
# (fixtures/compat/stubs).

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  use_helper_stub
  O=$SRC/overrides
  PIN=$(awk -F'\t' '$1 == "stable" { print $2 }' "$REPO/upstream.pin")
}

helper_calls() {
  if [[ -e $LOGS/helper ]]; then
    cat "$LOGS/helper"
  fi
}

# --- omarchy-pkg-* ----------------------------------------------------------

@test "omarchy-pkg-present and omarchy-pkg-missing check Package_Map outcomes" {
  run "$O/omarchy-pkg-present" fd
  assert_failure 1
  run "$O/omarchy-pkg-missing" fd
  assert_success
  installed fd-find
  run "$O/omarchy-pkg-present" fd
  assert_success
  run "$O/omarchy-pkg-missing" fd
  assert_failure 1
  run "$O/omarchy-pkg-present" fd limine
  assert_failure 1
  run "$O/omarchy-pkg-missing" fd not-in-the-map
  assert_success
  run "$O/omarchy-pkg-present"
  assert_success
}

@test "omarchy-pkg-add installs missing outcomes through the Helper and checks them" {
  installed gvfs-backends
  run "$O/omarchy-pkg-add" fd gvfs-mtp
  assert_success
  run helper_calls
  assert_output 'install fd-find'
  rm "$LOGS/helper"
  run "$O/omarchy-pkg-add" fd
  assert_success
  [[ ! -e $LOGS/helper ]]
}

@test "omarchy-pkg-add: a skip outcome prints the reason and succeeds" {
  run "$O/omarchy-pkg-add" limine
  assert_success
  assert_output --partial 'bootloader is out of scope'
  [[ ! -e $LOGS/helper ]]
}

@test "omarchy-pkg-add exits 1 for an unmapped name, a refused install or a package that did not install" {
  run "$O/omarchy-pkg-add" not-in-the-map
  assert_failure 1
  FAKE_HELPER_RC=11 run "$O/omarchy-pkg-add" fd
  assert_failure 1
  write_script "$T/lazy-helper" 'exit 0'
  MOTANKA_HELPER=$T/lazy-helper run "$O/omarchy-pkg-add" fd
  assert_failure 1
  assert_output --partial "Error: Package 'fd' did not install"
}

@test "omarchy-pkg-aur-add maps AUR names like omarchy-pkg-add" {
  run "$O/omarchy-pkg-aur-add" hyprsunset
  assert_success
  run helper_calls
  assert_output 'install motanka-stack-tools'
}

@test "omarchy-pkg-drop removes what Motanka installed and keeps the rest" {
  installed fd-find
  installed gvfs-backends
  ledger_line menu-install 1000 fd-find apt
  run "$O/omarchy-pkg-drop" fd gvfs-smb fcitx5-gtk
  assert_success
  assert_output --partial 'kept gvfs-backends'
  run helper_calls
  assert_output 'remove fd-find'
  run "$O/omarchy-pkg-drop"
  assert_success
}

@test "omarchy-pkg-defaults prints the base list for x86 and refuses aarch64" {
  local up
  up=$(fake_upstream)
  export OMARCHY_PATH=$up
  run "$O/omarchy-pkg-defaults"
  assert_success
  assert_output $'fd\nfcitx5-gtk\nlimine'
  run "$O/omarchy-pkg-defaults" generic
  assert_output $'fd\nfcitx5-gtk\nlimine'
  run "$O/omarchy-pkg-defaults" aarch64-apple
  assert_failure 1
  run "$O/omarchy-pkg-defaults" vax
  assert_failure 1
}

@test "omarchy-pkg-aur-accessible is false without asking the network; omarchy-pkg-aur-install is not available" {
  run "$O/omarchy-pkg-aur-accessible"
  assert_failure 1
  [[ ! -e $LOGS/curl ]]
  run "$O/omarchy-pkg-aur-install"
  assert_failure 64
  assert_output --partial 'not available in Motanka'
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: omarchy-pkg-aur-install'
}

@test "omarchy-pkg-install --preview describes a Package_Map entry" {
  run "$O/omarchy-pkg-install" --preview fd
  assert_success
  assert_line 'Outcome  : apt fd-find'
  assert_line 'Status   : not installed'
  assert_line 'Package: fd-find'
}

@test "omarchy-pkg-remove offers nothing when this user installed nothing from menus" {
  run "$O/omarchy-pkg-remove"
  assert_success
  assert_output 'No packages installed from Motanka menus to remove.'
}

# --- omarchy-webapp-install -------------------------------------------------

# webapp_upstream: a stand-in for Upstream's omarchy-webapp-install that
# writes a desktop entry and an icon below $HOME, like the real script.
webapp_upstream() {
  local up
  up=$(fake_upstream)
  write_script "$up/bin/omarchy-webapp-install" 'set -e
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
printf "icon\n" >"$HOME/.local/share/icons/hicolor/256x256/apps/$1.png"
printf "[Desktop Entry]\nVersion=1.0\nName=%s\nExec=omarchy-launch-webapp \"%s\"\nType=Application\nIcon=%s\n" "$1" "$2" "$1" >"$HOME/.local/share/applications/$1.desktop"
chmod +x "$HOME/.local/share/applications/$1.desktop"
echo "config=$XDG_CONFIG_HOME"
[[ -z ${FAKE_WEBAPP_FAIL:-} ]] || exit 3'
  printf '%s\n' "$up"
}

@test "omarchy-webapp-install limits the entry to the Motanka session and ledgers entry and icon" {
  local up entry=$HOME/.local/share/applications/HEY.desktop
  up=$(webapp_upstream)
  export OMARCHY_PATH=$up
  run "$O/omarchy-webapp-install" HEY https://hey.com HEY
  assert_success
  assert_line "config=$HOME/.config"
  run cat "$entry"
  assert_line --index 0 '[Desktop Entry]'
  assert_line --index 1 'OnlyShowIn=Motanka;'
  assert_line 'Exec=omarchy-launch-webapp "https://hey.com"'
  [[ -x $entry ]]
  [[ -f $HOME/.local/share/icons/hicolor/256x256/apps/HEY.png ]]
  run cut -f3,4,5 "$HOME/.local/state/motanka/ledger"
  assert_line "$(printf 'menu-desktop\tapp\t.local/share/applications/HEY.desktop')"
  assert_line "$(printf 'menu-desktop\tapp\t.local/share/icons/hicolor/256x256/apps/HEY.png')"
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "omarchy-webapp-install passes Upstream's failure on and writes nothing" {
  local up
  up=$(webapp_upstream)
  export OMARCHY_PATH=$up FAKE_WEBAPP_FAIL=1
  run "$O/omarchy-webapp-install" HEY https://hey.com HEY
  assert_failure 3
  [[ ! -e $HOME/.local ]]
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "omarchy-webapp-install takes Upstream's script from the vendored tree, not the Wrappers of /usr/share/omarchy" {
  run grep -c '^  omarchy=/opt/motanka/share/omarchy$' "$O/omarchy-webapp-install"
  assert_output 1
}

# --- omarchy-version --------------------------------------------------------

@test "omarchy-version prints the stable pin's tag, else Upstream's version file" {
  local up pin=$MOTANKA_ROOT/opt/motanka/share/motanka/upstream.pin
  up=$(fake_upstream)
  printf '4.0.0.alpha\n' >"$up/version"
  export OMARCHY_PATH=$up
  mkdir -p "${pin%/*}"
  printf '# pin\nstable\t%s\tv4.5.0\t%064d\n' "$PIN" 0 >"$pin"
  run bash "$O/omarchy-version"
  assert_success
  assert_output '4.5.0'
  printf 'stable\t%s\t-\t%064d\n' "$PIN" 0 >"$pin"
  run bash "$O/omarchy-version"
  assert_success
  assert_output '4.0.0.alpha'
  rm "$pin" "$up/version"
  run bash "$O/omarchy-version"
  assert_failure 1
  assert_output ''
  run grep -v '^#' "$O/omarchy-version"
  refute_output --partial pacman
}

# --- overrides for Arch tools and paths --------------------------------------

@test "every unsupported override prints why, logs and exits 64" {
  local file choice _reason name
  while IFS=$'\t' read -r file choice _reason; do
    [[ -n $file && $file != '#'* && $choice == unsupported ]] || continue
    name=${file#bin/}
    run "$O/$name" some-argument </dev/null
    if ((status != 64)); then
      fail "$name exited $status, expected 64"
    fi
    assert_output --partial "$name: not available in Motanka: "
  done <"$REPO/compat/overrides.tsv"
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: omarchy-kernel some-argument'
  assert_output --partial 'unsupported call: omarchy-refresh-pacman some-argument'
}

@test "omarchy-snapshot: create reports no snapshot tool (127), restore is not available" {
  run "$O/omarchy-snapshot" create
  assert_failure 127
  assert_output --partial 'motanka update'
  run "$O/omarchy-snapshot" restore
  assert_failure 64
  assert_output --partial 'sudo motanka rollback'
  run "$O/omarchy-snapshot"
  assert_failure 1
}

@test "omarchy-lifecycle-dispatch is a no-op for every known operation" {
  run "$O/omarchy-lifecycle-dispatch" setup-boot --owner
  assert_success
  assert_output ''
  run "$O/omarchy-lifecycle-dispatch" --resolve update-verify
  assert_success
  assert_output ''
  run "$O/omarchy-lifecycle-dispatch" bogus
  assert_failure 2
  run "$O/omarchy-lifecycle-dispatch"
  assert_failure 2
}

@test "omarchy-theme-set-browser changes nothing and succeeds, so a theme switch reports no failed retint" {
  run "$O/omarchy-theme-set-browser"
  assert_success
  assert_output ''
}

# power <state> <image-size> <resume> <swaps...>: fixture /sys/power and /proc/swaps.
power() {
  mkdir -p "$T/power"
  printf '%s\n' "$1" >"$T/power/state"
  printf '%s\n' "$2" >"$T/power/image_size"
  printf '%s\n' "$3" >"$T/power/resume"
  shift 3
  {
    printf 'Filename\tType\tSize\tUsed\tPriority\n'
    printf '%s\n' "$@"
  } >"$T/swaps"
  export OMARCHY_SYS_POWER_PATH=$T/power OMARCHY_SWAPS_PATH=$T/swaps
}

@test "omarchy-hibernation-available checks disk sleep, swap size and a resume device" {
  power 'freeze mem disk' 1000000 8:2 '/swapfile file 2000 0 -2' '/dev/zram0 partition 9999999 0 100'
  run "$O/omarchy-hibernation-available"
  assert_success
  power 'freeze mem disk' 1000000 0:0 '/swapfile file 2000 0 -2'
  run "$O/omarchy-hibernation-available"
  assert_failure 1
  power 'freeze mem' 1000000 8:2 '/swapfile file 2000 0 -2'
  run "$O/omarchy-hibernation-available"
  assert_failure 1
  power 'freeze mem disk' 1000000 8:2 '/swapfile file 900 0 -2' '/dev/zram0 partition 9999999 0 100'
  run "$O/omarchy-hibernation-available"
  assert_failure 1
}

@test "omarchy-update-available lists Motanka packages with a newer candidate" {
  installed motanka-core 0.1.0-1~ubuntu26.04.1
  installed motanka-stack 0.1.0-1~ubuntu26.04.1
  installed bluez 5.0-1
  printf 'motanka-core 0.1.0-1~ubuntu26.04.1 0.2.0-1~ubuntu26.04.1\nmotanka-stack 0.1.0-1~ubuntu26.04.1 0.1.0-1~ubuntu26.04.1\nbluez 5.0-1 6.0-1\n' >"$T/policy"
  export FAKE_POLICY=$T/policy
  run "$O/omarchy-update-available"
  assert_success
  assert_output 'motanka-core 0.1.0-1~ubuntu26.04.1 -> 0.2.0-1~ubuntu26.04.1'
  printf 'motanka-core 0.1.0-1~ubuntu26.04.1 0.1.0-1~ubuntu26.04.1\n' >"$T/policy"
  run "$O/omarchy-update-available"
  assert_failure 1
  assert_output 'Motanka is up to date'
}

@test "omarchy-update-keyring checks motanka-archive-keyring and its key" {
  run "$O/omarchy-update-keyring"
  assert_failure 1
  assert_output --partial 'motanka-archive-keyring is not installed'
  installed motanka-archive-keyring
  run "$O/omarchy-update-keyring"
  assert_failure 1
  mkdir -p "$MOTANKA_ROOT/usr/share/keyrings"
  printf 'key' >"$MOTANKA_ROOT/usr/share/keyrings/motanka-archive-keyring.gpg"
  run "$O/omarchy-update-keyring"
  assert_success
  assert_line 'Keys are correct'
}

@test "omarchy-update-pkg-prune changes nothing" {
  run "$O/omarchy-update-pkg-prune"
  assert_success
  assert_output --partial 'nothing to prune'
}

@test "omarchy-version-channel reads the suite of motanka.sources" {
  local sources=$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources
  run "$O/omarchy-version-channel"
  assert_output unknown
  mkdir -p "${sources%/*}"
  printf 'Types: deb\nURIs: https://example.invalid/chumak\nSuites: resolute\nComponents: main\n' >"$sources"
  run "$O/omarchy-version-channel"
  assert_output stable
  printf 'Types: deb\nURIs: https://example.invalid/chumak\nSuites: resolute-edge\nComponents: main\n' >"$sources"
  run "$O/omarchy-version-channel"
  assert_output edge
}

@test "omarchy-sudo-passwordless reports inactive and disabled; omarchy-migrate has nothing pending before per-user setup" {
  run "$O/omarchy-sudo-passwordless" --active
  assert_failure 1
  assert_output ''
  run "$O/omarchy-sudo-passwordless" --disable
  assert_success
  assert_output 'Passwordless sudo is already DISABLED.'
  run "$O/omarchy-migrate" --pending
  assert_failure 1
  assert_output ''
  run "$O/omarchy-migrate"
  assert_success
  assert_output --partial 'per-user setup has not completed'
}

@test "omarchy-update runs 'sudo motanka update', with --yes for -y" {
  write_script "$T/sudo" 'printf "%s\n" "$*" >>"$LOGS/sudo"'
  export MOTANKA_SUDO=$T/sudo MOTANKA_CLI=/usr/bin/motanka
  run "$O/omarchy-update"
  assert_success
  run "$O/omarchy-update" -y
  assert_success
  run cat "$LOGS/sudo"
  assert_output $'/usr/bin/motanka update\n/usr/bin/motanka update --yes'
  run "$O/omarchy-update" --bogus
  assert_failure 1
  run "$O/omarchy-update" -y extra
  assert_failure 1
}

@test "compat/overrides.tsv lists every override, and the 20 Arch-specific bin/ files are overridden" {
  local f name listed files expected missing=()
  listed=$(awk -F'\t' '!/^#/ && NF > 0 { print $1 }' "$REPO/compat/overrides.tsv" | sort)
  files=$(for f in "$O"/*; do printf 'bin/%s\n' "${f##*/}"; done | sort)
  assert_equal "$listed" "$files"
  run awk -F'\t' '!/^#/ && NF > 0 && (NF != 3 || ($2 != "implemented" && $2 != "unsupported"))' "$REPO/compat/overrides.tsv"
  assert_output ''
  expected=$(awk -F'\t' '$1 ~ /^bin\/[^\/]+$/ && ($3 == "arch-path" || ($3 == "arch-tool" && $4 !~ /^(pacman|yay)( |$)/)) { print $1 }' \
    "$REPO/compat/inventory/$PIN.tsv" | sort -u)
  assert_equal "$(wc -l <<<"$expected")" 20
  while IFS= read -r f; do
    name=${f#bin/}
    if [[ ! -f $O/$name ]]; then
      missing+=("$name")
    fi
  done <<<"$expected"
  assert_equal "${missing[*]}" ""
}

# --- tools/checkoverrides ------------------------------------------------------

# co_fixture: old and new trees, overrides, a list and an inventory in $T/co.
co_fixture() {
  local d=$T/co tree
  mkdir -p "$d/ov" "$d/reviewed"
  for tree in old new; do
    mkdir -p "$d/$tree/bin"
    printf 'a\n' >"$d/$tree/bin/omarchy-a"
    printf 'b\n' >"$d/$tree/bin/omarchy-b"
    printf 'c\n' >"$d/$tree/bin/omarchy-c"
    chmod 0755 "$d/$tree/bin/"*
  done
  printf 'override\n' >"$d/ov/omarchy-a"
  printf 'bin/omarchy-a\timplemented\tthe test override\n' >"$d/ov.tsv"
  printf 'bin/omarchy-a\t1\tarch-path\t/etc/pacman.conf\nbin/omarchy-b\t3\tarch-tool\tpacman -Q x\nbin/omarchy-c\t4\thome-write\t~/.config/x\n' >"$d/inv.tsv"
  CO_PIN=0123456789abcdef0123456789abcdef01234567
}

checkoverrides() {
  run "$REPO/tools/checkoverrides" --old "$T/co/old" --new "$T/co/new" --pin "$CO_PIN" \
    --inventory "$T/co/inv.tsv" --overrides "$T/co/ov" --overrides-list "$T/co/ov.tsv" --reviewed "$T/co/reviewed"
}

@test "checkoverrides passes when nothing watched changed" {
  co_fixture
  printf 'changed\n' >"$T/co/new/bin/omarchy-c"
  checkoverrides
  assert_success
}

@test "checkoverrides fails on a changed overridden file until it is reviewed at that content" {
  local sum
  co_fixture
  printf 'a2\n' >"$T/co/new/bin/omarchy-a"
  checkoverrides
  assert_failure 1
  assert_output --partial 'review: bin/omarchy-a changed and it has an override'
  printf 'bin/omarchy-a\t%s\tlooked at it\n' "$(printf '0%.0s' {1..64})" >"$T/co/reviewed/$CO_PIN"
  checkoverrides
  assert_failure 1
  assert_output --partial 'records 0000'
  sum=$(sha256sum <"$T/co/new/bin/omarchy-a")
  printf 'bin/omarchy-a\t%s\tlooked at it\n' "${sum:0:64}" >"$T/co/reviewed/$CO_PIN"
  checkoverrides
  assert_success
  printf '# path only\nbin/omarchy-a\n' >"$T/co/reviewed/$CO_PIN"
  checkoverrides
  assert_success
}

@test "checkoverrides fails on Arch findings in a changed or new file and on a lost executable bit" {
  co_fixture
  printf 'b2\n' >"$T/co/new/bin/omarchy-b"
  checkoverrides
  assert_failure 1
  assert_output --partial 'review: bin/omarchy-b changed and it has arch-tool or arch-path findings'
  co_fixture
  printf 'd\n' >"$T/co/new/bin/omarchy-d"
  printf 'bin/omarchy-d\t2\tarch-tool\tlimine-update\n' >>"$T/co/inv.tsv"
  checkoverrides
  assert_failure 1
  assert_output --partial 'review: bin/omarchy-d appeared'
  co_fixture
  chmod 0644 "$T/co/new/bin/omarchy-a"
  checkoverrides
  assert_failure 1
  assert_output --partial 'bin/omarchy-a changed'
}

@test "checkoverrides fails when a file with Arch configuration paths has no override, or the list is out of step" {
  co_fixture
  printf 'bin/omarchy-c\t9\tarch-path\t/boot/limine.conf\n' >>"$T/co/inv.tsv"
  checkoverrides
  assert_failure 1
  assert_output --partial 'coverage: bin/omarchy-c reads or writes pacman, Limine or mkinitcpio configuration'
  co_fixture
  printf 'x\n' >"$T/co/ov/omarchy-x"
  checkoverrides
  assert_failure 1
  assert_output --partial 'list: the override omarchy-x (bin/omarchy-x) has no line'
}

@test "checkoverrides usage errors exit 2" {
  co_fixture
  run "$REPO/tools/checkoverrides" --old "$T/co/old" --new "$T/co/new" --pin nope
  assert_failure 2
  run "$REPO/tools/checkoverrides" --old "$T/co/missing" --new "$T/co/new" --pin "$CO_PIN" --inventory "$T/co/inv.tsv"
  assert_failure 2
}

@test "checkoverrides passes for this repository's overrides and Call_Inventory" {
  mkdir -p "$T/same/bin"
  run "$REPO/tools/checkoverrides" --old "$T/same" --new "$T/same" --pin "$PIN" --reviewed "$T/none"
  assert_success
}

# --- omarchy-webapp-install: no silent success --------------------------------

@test "omarchy-webapp-install exits 1 when Upstream exits 0 without writing the named entry" {
  local up
  up=$(fake_upstream)
  export OMARCHY_PATH=$up
  write_script "$up/bin/omarchy-webapp-install" 'exit 0'
  run "$O/omarchy-webapp-install" HEY https://hey.com HEY
  assert_failure 1
  assert_output --partial "exited 0 but wrote no desktop entry named 'HEY.desktop'"
  assert_output --partial 'no web app was installed'
  [[ ! -e $HOME/.local ]]
  write_script "$up/bin/omarchy-webapp-install" 'mkdir -p "$HOME/.local/share/applications"
printf "[Desktop Entry]\nName=Other\n" >"$HOME/.local/share/applications/Other.desktop"'
  run "$O/omarchy-webapp-install" HEY https://hey.com HEY
  assert_failure 1
  assert_output --partial '.local/share/applications/Other.desktop'
  [[ ! -e $HOME/.local ]]
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "omarchy-webapp-install names every entry it installed" {
  local up
  up=$(webapp_upstream)
  export OMARCHY_PATH=$up
  run "$O/omarchy-webapp-install" 'Motanka Roundtrip' https://example.test/ icon
  assert_success
  assert_line 'motanka: installed the web app entry ~/.local/share/applications/Motanka Roundtrip.desktop for the Motanka session'
  run grep -x 'OnlyShowIn=Motanka;' "$HOME/.local/share/applications/Motanka Roundtrip.desktop"
  assert_success
}

# --- omarchy-provision-user -----------------------------------------------------

# provision_upstream: a stand-in for Upstream's omarchy-provision-user that
# writes what the real script writes (skill links, XDG user folders, GTK
# bookmarks, launchers, mimeapps.list, its done marker) below $HOME and
# sources $OMARCHY_INSTALL/user/all.sh. Prints the tree's path.
provision_upstream() {
  local up
  up=$(fake_upstream)
  mkdir -p "$up/default/agents/skills/omarchy" "$up/install/user"
  printf 'skill\n' >"$up/default/agents/skills/omarchy/SKILL.md"
  printf 'touch %q\n' "$T/all-sh-ran" >"$up/install/user/all.sh"
  write_script "$up/bin/omarchy-provision-user" 'set -euo pipefail
if [[ -f $HOME/.local/state/omarchy/done/finalize-user ]]; then echo "User finalization already complete."; exit 0; fi
mkdir -p ~/.agents/skills ~/.claude/skills
for skill in "$OMARCHY_PATH"/default/agents/skills/*/; do
  skill=${skill%/}
  ln -sfn "$skill" ~/.agents/skills/"${skill##*/}"
  ln -sfn "$skill" ~/.claude/skills/"${skill##*/}"
done
mkdir -p ~/Downloads ~/.config/gtk-3.0
printf "XDG_DESKTOP_DIR=\"\$HOME\"\n" >"${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
echo "file://$HOME/Downloads Downloads" >>~/.config/gtk-3.0/bookmarks
source "${OMARCHY_INSTALL:-$OMARCHY_PATH/install}/user/all.sh"
mkdir -p ~/.local/share/applications
printf "[Desktop Entry]\nName=HEY\nExec=omarchy-launch-webapp x\n" >~/.local/share/applications/HEY.desktop
printf "[Desktop Entry]\nName=mpv\nExec=mpv\n" >~/.local/share/applications/mpv.desktop
printf "cache\n" >~/.local/share/applications/mimeinfo.cache
printf "[Default Applications]\nx-scheme-handler/mailto=HEY.desktop\n" >"${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
mkdir -p ~/.local/state/omarchy/done
touch ~/.local/state/omarchy/done/finalize-user
echo "User finalization complete."
exit "${FAKE_PROVISION_RC:-0}"'
  printf '%s\n' "$up"
}

@test "omarchy-provision-user writes skill links, launchers and its marker through the ledger and drops Shared_Files" {
  local up
  up=$(provision_upstream)
  export OMARCHY_PATH=$up XDG_DATA_DIRS=/usr/local/share:/usr/share MOTANKA_HOME_PATHS=$REPO/compat/home-paths.tsv
  mkdir -p "$MOTANKA_ROOT/usr/share/applications"
  printf '[Desktop Entry]\nName=mpv\n' >"$MOTANKA_ROOT/usr/share/applications/mpv.desktop"
  mkdir -p "$HOME/.claude/skills"
  ln -s /my/own/skill "$HOME/.claude/skills/omarchy"
  run "$O/omarchy-provision-user"
  assert_success
  assert_output --partial 'User finalization complete.'
  assert_equal "$(readlink "$HOME/.agents/skills/omarchy")" "$up/default/agents/skills/omarchy"
  assert_equal "$(readlink "$HOME/.claude/skills/omarchy")" /my/own/skill
  run cut -f3,4,5 "$HOME/.local/state/motanka/ledger"
  assert_line "$(printf 'create\tapp\t.agents/')"
  assert_line "$(printf 'symlink\tapp\t.agents/skills/omarchy')"
  assert_line "$(printf 'create\tapp\t.local/share/applications/HEY.desktop')"
  assert_line "$(printf 'create\tnamespaced\t.local/state/omarchy/done/finalize-user')"
  refute_line --partial '.claude/skills/omarchy'
  refute_line --partial 'mpv.desktop'
  run grep -x 'OnlyShowIn=Motanka;' "$HOME/.local/share/applications/HEY.desktop"
  assert_success
  [[ ! -e $HOME/.local/share/applications/mpv.desktop && ! -e $HOME/.local/share/applications/mimeinfo.cache ]]
  [[ ! -e $HOME/Downloads && ! -e $HOME/.config/gtk-3.0 ]]
  [[ ! -e $HOME/.config/user-dirs.dirs && ! -e $HOME/.config/mimeapps.list ]]
  [[ ! -e $T/all-sh-ran ]]
  run ls -A "$TMPDIR"
  assert_output ''
  run cat "$LOGS/journal"
  assert_output --partial 'would hide the launcher of the same name from other desktops'
  assert_output --partial '.config/mimeapps.list (shared)'
  assert_output --partial '.config/user-dirs.dirs (desktop)'
}

@test "omarchy-provision-user does not run Upstream again once finalization is done, unless --force" {
  local up
  up=$(provision_upstream)
  export OMARCHY_PATH=$up MOTANKA_HOME_PATHS=$REPO/compat/home-paths.tsv
  run "$O/omarchy-provision-user"
  assert_success
  write_script "$up/bin/omarchy-provision-user" 'echo upstream-ran'
  run "$O/omarchy-provision-user"
  assert_success
  assert_output 'User finalization already complete.'
  run "$O/omarchy-provision-user" --force
  assert_success
  assert_output 'upstream-ran'
}

@test "omarchy-provision-user passes Upstream's failure on after writing what it may" {
  local up
  up=$(provision_upstream)
  export OMARCHY_PATH=$up MOTANKA_HOME_PATHS=$REPO/compat/home-paths.tsv FAKE_PROVISION_RC=4
  run "$O/omarchy-provision-user"
  assert_failure 4
  [[ -L $HOME/.agents/skills/omarchy ]]
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "omarchy-provision-user stops on an unreadable home-paths.tsv before running Upstream" {
  local up
  up=$(provision_upstream)
  export OMARCHY_PATH=$up MOTANKA_HOME_PATHS=$T/missing.tsv
  run "$O/omarchy-provision-user"
  assert_failure 1
  assert_output --partial "cannot read $T/missing.tsv"
  [[ ! -e $HOME/.local ]]
}
