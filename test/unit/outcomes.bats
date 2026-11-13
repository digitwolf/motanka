#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for task 13.5: src/lib/outcomes.sh, the binary and Flatpak
# outcomes (4.8, 4.9, 7.15), desktop entries limited to the Motanka session
# (5.13) and removals that keep what Motanka did not install. The Helper,
# curl and flatpak are stubs that log their calls (fixtures/compat/stubs).

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  use_helper_stub
  MK_CMD="test"
  # shellcheck source=../../src/lib/common.sh
  source "$SRC/lib/common.sh"
  # shellcheck source=../../src/lib/sysledger.sh
  source "$SRC/lib/sysledger.sh"
  # shellcheck source=../../src/lib/userledger.sh
  source "$SRC/lib/userledger.sh"
  # shellcheck source=../../src/lib/outcomes.sh
  source "$SRC/lib/outcomes.sh"
  USER_LEDGER=$HOME/.local/state/motanka/ledger
}

helper_calls() {
  if [[ -e $LOGS/helper ]]; then
    cat "$LOGS/helper"
  fi
}

@test "a desktop entry gets OnlyShowIn=Motanka; in its [Desktop Entry] group only" {
  printf '%s\n' '# comment' '[Desktop Entry]' 'Name=App' 'NotShowIn=KDE;' 'OnlyShowIn=GNOME;' \
    'X-Motanka-Flatpak=old' 'Exec=app' '' '[Desktop Action new]' 'Name=New' 'OnlyShowIn=GNOME;' >"$T/in.desktop"
  run mk_oc_desktop_only_show_in "$T/in.desktop" "$T/out.desktop" X-Motanka-Flatpak=org.example.App
  assert_success
  run cat "$T/out.desktop"
  assert_output "$(printf '%s\n' '# comment' '[Desktop Entry]' 'OnlyShowIn=Motanka;' 'X-Motanka-Flatpak=org.example.App' \
    'Name=App' 'Exec=app' '' '[Desktop Action new]' 'Name=New' 'OnlyShowIn=GNOME;')"
}

@test "a file without a [Desktop Entry] group is refused" {
  printf '[Something]\nName=x\n' >"$T/in.desktop"
  run mk_oc_desktop_only_show_in "$T/in.desktop" "$T/out.desktop"
  assert_failure
}

@test "a binary outcome for a Namespaced_Path is checked, written through the User_Ledger and the download removed" {
  export FAKE_DOWNLOAD=$T/download-ns
  run mk_oc_binary_install nsbin
  assert_success
  local dest=$HOME/.local/share/omarchy/bin/nsbin
  cmp "$T/download-ns" "$dest"
  assert_equal "$(stat -c %a "$dest")" 755
  run grep -c "$(printf 'menu-desktop\tapp\t.local/share/omarchy/bin/nsbin\t')" "$USER_LEDGER"
  assert_output 1
  run cat "$LOGS/curl"
  assert_output --partial 'proto =https'
  assert_output --partial 'https://example.invalid/nsbin'
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "a binary whose SHA-256 differs is deleted and the call returns 6" {
  printf 'tampered\n' >"$T/evil"
  export FAKE_DOWNLOAD=$T/evil
  run mk_oc_binary_install nsbin
  assert_failure 6
  assert_output --partial 'SHA-256 mismatch'
  assert_output --partial 'the download was deleted'
  [[ ! -e $HOME/.local/share/omarchy/bin/nsbin ]]
  run ls -A "$TMPDIR"
  assert_output ''
  run mk_oc_binary_install optbin
  assert_failure 6
  run helper_calls
  assert_output ''
}

@test "a binary outcome under /opt/motanka is handed to the Helper after the check" {
  export FAKE_DOWNLOAD=$T/download-opt
  run mk_oc_binary_install optbin
  assert_success
  run helper_calls
  assert_output --regexp "^install-binary optbin $TMPDIR/tmp\.[A-Za-z0-9]+/download$"
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "a failed download installs nothing" {
  export FAKE_DOWNLOAD=$T/download-ns FAKE_CURL_RC=22
  run mk_oc_binary_install nsbin
  assert_failure 1
  [[ ! -e $HOME/.local/share/omarchy/bin/nsbin ]]
  run ls -A "$TMPDIR"
  assert_output ''
}

@test "a Flatpak outcome installs Flatpak through the Helper, adds flathub for the user and shadows the entry" {
  rm -f "$STUBS/flatpak"
  hash -r
  if command -v flatpak >/dev/null 2>&1; then
    skip "this VM has a real flatpak on PATH"
  fi
  run mk_oc_install chromium
  assert_success
  run helper_calls
  assert_output 'install flatpak'
  run cat "$LOGS/flatpak"
  assert_line 'remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo'
  assert_line 'install --user --noninteractive flathub org.chromium.Chromium'
  local shadow=$HOME/.local/share/applications/org.chromium.Chromium.desktop
  run cat "$shadow"
  assert_line --index 0 '[Desktop Entry]'
  assert_line --index 1 'OnlyShowIn=Motanka;'
  assert_line --index 2 'X-Motanka-Flatpak=org.chromium.Chromium'
  refute_line 'NotShowIn=KDE;'
  assert_line 'OnlyShowIn=GNOME;'
  run grep -c "$(printf 'menu-desktop\tapp\t.local/share/applications/org.chromium.Chromium.desktop\t')" "$USER_LEDGER"
  assert_output 1
}

@test "with Flatpak and flathub present, only the app is installed" {
  echo flathub >"$LOGS/flatpak-remotes"
  run mk_oc_install chromium
  assert_success
  run helper_calls
  assert_output ''
  run cat "$LOGS/flatpak"
  refute_output --partial remote-add
  assert_line 'install --user --noninteractive flathub org.chromium.Chromium'
}

@test "a skip outcome prints its reason and succeeds" {
  run mk_oc_install limine
  assert_success
  assert_output --partial 'limine is not installed in Motanka: bootloader is out of scope'
  run helper_calls
  assert_output ''
}

@test "mk_oc_install returns 10 for a Package_Map of another release" {
  write_map noble
  run mk_oc_install fd
  assert_failure 10
}

@test "mk_oc_present follows each outcome kind" {
  run mk_oc_present fd
  assert_failure
  installed fd-find
  run mk_oc_present fd
  assert_success
  run mk_oc_present limine
  assert_failure
  run mk_oc_present nsbin
  assert_failure
  mkdir -p "$HOME/.local/share/omarchy/bin"
  touch "$HOME/.local/share/omarchy/bin/nsbin"
  run mk_oc_present nsbin
  assert_success
  run mk_oc_present 'Not/A/Name'
  assert_failure
}

@test "removing a Flatpak outcome uninstalls only an app Motanka installed" {
  echo flathub >"$LOGS/flatpak-remotes"
  run mk_oc_install chromium
  assert_success
  run mk_oc_remove chromium
  assert_success
  run cat "$LOGS/flatpak"
  assert_line 'uninstall --user --noninteractive org.chromium.Chromium'
  [[ ! -e $HOME/.local/share/applications/org.chromium.Chromium.desktop ]]
}

@test "a Flatpak app the user installed without Motanka is kept" {
  echo org.chromium.Chromium >"$LOGS/flatpak-installed"
  run mk_oc_remove chromium
  assert_success
  assert_output --partial 'kept the Flatpak org.chromium.Chromium'
  run cat "$LOGS/flatpak"
  refute_output --partial uninstall
}

@test "removing binary outcomes: a home file is deleted, an /opt file goes to the Helper" {
  mkdir -p "$HOME/.local/share/omarchy/bin" "$MOTANKA_ROOT/opt/motanka/apps"
  touch "$HOME/.local/share/omarchy/bin/nsbin" "$MOTANKA_ROOT/opt/motanka/apps/optbin"
  run mk_oc_remove nsbin optbin
  assert_success
  [[ ! -e $HOME/.local/share/omarchy/bin/nsbin ]]
  run helper_calls
  assert_output 'remove-binary optbin'
}

@test "mk_oc_unsupported prints the reason, logs, notifies without a terminal and exits 64" {
  run mk_oc_unsupported omarchy-example "it needs Arch" extra arg
  assert_failure 64
  assert_output 'omarchy-example: not available in Motanka: it needs Arch'
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: omarchy-example extra arg: it needs Arch'
  run cat "$LOGS/notify-send"
  assert_output --partial 'omarchy-example is not available in Motanka'
}
