#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for task 13.2: the pacman and yay shims (7.3, 7.4, 7.5, 7.6).
# The Helper is a stub that logs its calls ($LOGS/helper); dpkg-query,
# flatpak and systemd-cat are stubs too (fixtures/compat/stubs).

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  use_helper_stub
  PACMAN=$SRC/shims/pacman
  YAY=$SRC/shims/yay
}

helper_calls() {
  if [[ -e $LOGS/helper ]]; then
    cat "$LOGS/helper"
  fi
}

@test "-S maps every Arch name and installs the Ubuntu packages through the Helper once" {
  run "$PACMAN" -S --needed --noconfirm --ask 4 --overwrite '*' -- fd fcitx5-gtk gvfs-mtp gvfs-smb
  assert_success
  run helper_calls
  assert_output 'install fd-find fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 gvfs-backends'
}

@test "-S of a motanka outcome installs the Motanka package" {
  run "$PACMAN" -S --noconfirm hyprsunset
  assert_success
  run helper_calls
  assert_output 'install motanka-stack-tools'
}

@test "-S of a skip outcome prints the reason and exits 0 without the Helper" {
  run "$PACMAN" -S --noconfirm limine
  assert_success
  assert_output --partial 'limine is not installed in Motanka: bootloader is out of scope'
  run helper_calls
  assert_output ''
}

@test "-S of an unmapped name exits 1 and installs nothing, even with mapped names" {
  run "$PACMAN" -S --noconfirm not-in-the-map
  assert_failure 1
  assert_output --partial "'not-in-the-map' has no entry in the Package_Map"
  run "$PACMAN" -S --noconfirm fd not-in-the-map
  assert_failure 1
  run helper_calls
  assert_output ''
}

@test "-Sy, -Syu, -Su and -Syyuu without names change nothing and exit 0" {
  local a
  for a in -Sy -Syu -Su -Syyuu '--sync --refresh --sysupgrade'; do
    # shellcheck disable=SC2086 # the option words are split on purpose
    run "$PACMAN" $a --noconfirm
    assert_success
    assert_output --partial 'motanka update'
  done
  run "$YAY"
  assert_success
  run "$YAY" -Sua --noconfirm --cleanafter
  assert_success
  run helper_calls
  assert_output ''
}

@test "-S without names is an error, as in pacman" {
  run "$PACMAN" -S --noconfirm
  assert_failure 1
  assert_output --partial 'no targets specified'
}

@test "-Syu with names installs the names and skips the refresh and upgrade" {
  run "$PACMAN" -Syu --needed --noconfirm fd
  assert_success
  run helper_calls
  assert_output 'install fd-find'
}

@test "repository prefixes are dropped, and yay maps AUR names the same way" {
  run "$PACMAN" -S --noconfirm extra/fd
  assert_success
  run "$YAY" -S --noconfirm --needed -- aur/hyprsunset
  assert_success
  run helper_calls
  assert_output $'install fd-find\ninstall motanka-stack-tools'
}

@test "the Helper's exit code is passed through" {
  export FAKE_HELPER_RC=11
  run "$PACMAN" -S --noconfirm fd
  assert_failure 11
}

@test "a Package_Map for another release refuses with exit 10 before the Helper" {
  write_map noble
  run "$PACMAN" -S --noconfirm fd
  assert_failure 10
  assert_output --partial "for 'noble'"
  run helper_calls
  assert_output ''
}

@test "-Rns removes only packages the System_Ledger records Motanka installing" {
  installed fd-find
  installed gvfs-backends
  ledger_line menu-install 1000 fd-find apt
  run "$PACMAN" -Rns --noconfirm fd gvfs-mtp limine not-in-the-map
  assert_success
  assert_output --partial 'kept gvfs-backends: Motanka did not install it'
  run helper_calls
  assert_output 'remove fd-find'
  run cat "$LOGS/journal"
  assert_output --partial 'kept gvfs-backends for gvfs-mtp'
}

@test "-R of packages that are not installed changes nothing; -R without names is an error" {
  ledger_line menu-install 1000 fd-find apt
  run "$PACMAN" -R --noconfirm fd
  assert_success
  run helper_calls
  assert_output ''
  run "$PACMAN" -R
  assert_failure 1
}

@test "-Rdd and -Rs are accepted like -R" {
  installed fd-find
  ledger_line pkg-installed fd-find 1.0-1 auto
  run "$PACMAN" -Rdd --noconfirm fd
  assert_success
  run "$PACMAN" -Rs fd
  assert_success
  run helper_calls
  assert_output $'remove fd-find\nremove fd-find'
}

@test "-Q and -Qq report installed outcomes and exit 1 for a missing one" {
  installed fd-find 9.0-1
  run "$PACMAN" -Q fd
  assert_success
  assert_output 'fd 9.0-1'
  run "$PACMAN" -Qq -- fd
  assert_success
  assert_output 'fd'
  run --separate-stderr "$PACMAN" -Q fd fcitx5-gtk
  assert_failure 1
  assert_output 'fd 9.0-1'
  [[ $stderr == *"error: package 'fcitx5-gtk' was not found"* ]]
  run "$PACMAN" -Q limine
  assert_failure 1
  run "$PACMAN" -Q not-in-the-map
  assert_failure 1
}

@test "-Q of a multi-package outcome needs every package" {
  installed fcitx5-frontend-gtk3
  run "$PACMAN" -Q fcitx5-gtk
  assert_failure 1
  installed fcitx5-frontend-gtk4
  run "$PACMAN" -Q fcitx5-gtk
  assert_success
}

@test "-Q of a Flatpak outcome asks flatpak for the user's installation" {
  run "$PACMAN" -Q chromium
  assert_failure 1
  echo org.chromium.Chromium >>"$LOGS/flatpak-installed"
  run "$PACMAN" -Q chromium
  assert_success
  assert_output 'chromium flatpak'
}

@test "-Qi prints the details of an installed outcome" {
  installed fd-find 9.0-1
  run "$PACMAN" -Qi fd
  assert_success
  assert_line 'Name            : fd'
  assert_line 'Version         : 9.0-1'
  assert_line 'Description     : summary of fd-find'
  assert_line 'Installed As    : apt fd-find'
}

@test "-Q and -Qq without names list the installed Ubuntu packages" {
  installed fd-find 9.0-1
  installed bluez 5.0-1
  run "$PACMAN" -Q
  assert_success
  assert_output $'fd-find 9.0-1\nbluez 5.0-1'
  run "$PACMAN" -Qq
  assert_output $'fd-find\nbluez'
}

@test "unsupported calls exit 64 and are logged to the journal" {
  local a
  local -a args
  for a in '-Qo /usr/bin/fd' '-Qqe' '-Qtdq' '-Qem' '-U ./x.pkg.tar.zst' '-Ss fd' '-Sii fd' '-Slq' \
    '-D --asexplicit fd' '-Rc fd' '-Rs --print fd' '--version' '-Fy' '-Si fd' '-Qi'; do
    read -r -a args <<<"$a"
    run "$PACMAN" "${args[@]}"
    assert_failure 64
    assert_output --partial 'not available in Motanka'
  done
  run "$PACMAN"
  assert_failure 64
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: pacman -Qo /usr/bin/fd'
  assert_output --partial 'unsupported call: pacman -D --asexplicit fd'
  assert_output --partial '-t motanka'
  run helper_calls
  assert_output ''
}

@test "unsupported yay calls name yay in the journal, with the calling Upstream command" {
  export MOTANKA_UPSTREAM_CMD=omarchy-pkg-aur-install
  run "$YAY" -Slqa
  assert_failure 64
  run "$YAY" -Gpa fd
  assert_failure 64
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: yay -Slqa (from omarchy-pkg-aur-install)'
}
