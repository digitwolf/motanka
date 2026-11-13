#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # scripts are single-quoted on purpose
# Unit tests for task 13.3: the default-deny sudo dispatcher, the boot and
# snapshot tool shims, and compat/privileged.tsv (7.4, 7.5). /usr/bin/sudo
# is never run: MOTANKA_REAL_SUDO is a stand-in that logs its arguments to
# $LOGS/real-sudo, and notify-send is a stub.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  use_helper_stub
  SUDO=$SRC/shims/sudo
  PIN=$(awk -F'\t' '$1 == "stable" { print $2 }' "$REPO/upstream.pin")
}

real_sudo_calls() {
  if [[ -e $LOGS/real-sudo ]]; then
    cat "$LOGS/real-sudo"
  fi
}

notifications() {
  if [[ -e $LOGS/notify-send ]]; then
    cat "$LOGS/notify-send"
  fi
}

@test "sudo -v, -k and -K without a command change nothing and exit 0" {
  local a
  for a in -v -k -K -nv --validate; do
    run "$SUDO" "$a"
    assert_success
  done
  run real_sudo_calls
  assert_output ''
}

@test "a shim behind sudo and its options runs unprivileged" {
  installed fd-find 9.0-1
  run "$SUDO" pacman -Q fd
  assert_success
  assert_output 'fd 9.0-1'
  run "$SUDO" -n -u root -E -- pacman -Syu --noconfirm
  assert_success
  run "$SUDO" --preserve-env=PATH -uroot pacman -S --noconfirm fd
  assert_success
  run cat "$LOGS/helper"
  assert_output 'install fd-find'
  run real_sudo_calls
  assert_output ''
}

@test "an override behind sudo runs unprivileged" {
  run "$SUDO" omarchy-lifecycle-dispatch setup-boot
  assert_success
  run real_sudo_calls
  assert_output ''
}

@test "mkinitcpio, limine-* and snapper log the call and exit 64, also behind sudo" {
  local name
  for name in mkinitcpio limine limine-mkinitcpio limine-update limine-entry-tool \
    limine-snapper-sync limine-snapper-restore snapper; do
    run "$SRC/shims/$name" --some-arg
    assert_failure 64
    assert_output --partial "$name: not available in Motanka"
  done
  run "$SUDO" limine-update
  assert_failure 64
  run "$SUDO" mkinitcpio -P
  assert_failure 64
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: limine-snapper-restore --some-arg'
  assert_output --partial 'unsupported call: snapper --some-arg'
  assert_output --partial 'unsupported call: mkinitcpio -P'
  run real_sudo_calls
  assert_output ''
}

@test "an allow line runs the real sudo with the original arguments" {
  export MOTANKA_UPSTREAM_CMD=omarchy-update-time
  run "$SUDO" systemctl restart systemd-timesyncd
  assert_success
  run "$SUDO" -n systemctl restart systemd-timesyncd
  assert_success
  run real_sudo_calls
  assert_output $'systemctl restart systemd-timesyncd\n-n systemctl restart systemd-timesyncd'
  run cat "$LOGS/journal"
  assert_output --partial 'allowed: sudo systemctl restart systemd-timesyncd (from omarchy-update-time)'
}

@test "allow patterns match exactly what is allowed" {
  export MOTANKA_UPSTREAM_CMD=omarchy-restart-audio
  run "$SUDO" usbreset 001/004
  assert_success
  run "$SUDO" usbreset /dev/bus/usb/001/004
  assert_failure 64
  export MOTANKA_UPSTREAM_CMD=omarchy-windows-key
  run "$SUDO" cat /sys/firmware/acpi/tables/MSDM
  assert_success
  run "$SUDO" strings /sys/firmware/acpi/tables/MSDM
  assert_success
  run "$SUDO" tee /sys/firmware/acpi/tables/MSDM
  assert_failure 64
  export MOTANKA_UPSTREAM_CMD=omarchy-update-time
  run "$SUDO" systemctl enable systemd-timesyncd
  assert_failure 64
  run real_sudo_calls
  assert_output $'usbreset 001/004\ncat /sys/firmware/acpi/tables/MSDM\nstrings /sys/firmware/acpi/tables/MSDM'
}

@test "an unsupported line refuses with exit 64, a journal entry and a notification" {
  export MOTANKA_UPSTREAM_CMD=omarchy-update-boot
  run "$SUDO" true
  assert_failure 64
  assert_output --partial "sudo true is not available in Motanka: verifies Limine and initramfs boot files"
  run notifications
  assert_output --partial 'omarchy-update-boot is not available in Motanka'
  run cat "$LOGS/journal"
  assert_output --partial 'unsupported call: sudo true (from omarchy-update-boot)'
  run real_sudo_calls
  assert_output ''
}

@test "sudo -n refuses quietly: no notification" {
  export MOTANKA_UPSTREAM_CMD=omarchy-update-boot
  run "$SUDO" -n true
  assert_failure 64
  run notifications
  assert_output ''
}

@test "unlisted commands and calls without a known caller are refused" {
  export MOTANKA_UPSTREAM_CMD=omarchy-not-in-the-table
  run "$SUDO" systemctl restart systemd-timesyncd
  assert_failure 64
  assert_output --partial 'no rule in privileged.tsv allows this call'
  unset MOTANKA_UPSTREAM_CMD
  run "$SUDO" systemctl restart systemd-timesyncd
  assert_failure 64
  run real_sudo_calls
  assert_output ''
}

@test "an override line is refused and logged as an error" {
  printf 'omarchy-foo\t*\toverride\treplaced by an override\n' >"$T/table.tsv"
  export MOTANKA_PRIVILEGED_TSV=$T/table.tsv MOTANKA_UPSTREAM_CMD=omarchy-foo
  run "$SUDO" sed -i s/a/b/ /etc/x
  assert_failure 64
  run cat "$LOGS/journal"
  assert_output --partial '-p err'
  assert_output --partial "Upstream's omarchy-foo ran instead of its Motanka override"
}

@test "root shells, sudoedit and unknown options are refused" {
  export MOTANKA_UPSTREAM_CMD=omarchy-update-time
  local a
  local -a args
  for a in '-s' '-i' '-e /etc/hosts' '--edit /etc/hosts' '-X systemctl' '--bogus systemctl'; do
    read -r -a args <<<"$a"
    run "$SUDO" "${args[@]}"
    assert_failure 64
  done
  run real_sudo_calls
  assert_output ''
}

@test "-h, -V and -l go to the real sudo, which changes nothing" {
  run "$SUDO" -V
  assert_success
  run "$SUDO" -l
  assert_success
  run real_sudo_calls
  assert_output $'-V\n-l'
}

@test "the caller is the nearest Upstream script in the process tree, not the environment" {
  local up
  up=$(fake_upstream)
  # Each script runs a second command, so bash cannot exec sudo in its place.
  write_script "$up/bin/omarchy-update-time" $'sudo systemctl restart systemd-timesyncd\nexit $?'
  write_script "$up/bin/omarchy-other" $'sudo systemctl restart systemd-timesyncd\nexit $?'
  write_script "$up/bin/omarchy-restart-audio" $'timeout 5 sudo usbreset 002/003\nexit $?'
  export OMARCHY_PATH=$up
  export PATH="$SRC/shims:$PATH"
  MOTANKA_UPSTREAM_CMD=omarchy-outer run "$up/bin/omarchy-update-time"
  assert_success
  MOTANKA_UPSTREAM_CMD=omarchy-update-time run "$up/bin/omarchy-other"
  assert_failure 64
  assert_output --partial 'omarchy-other: sudo systemctl restart systemd-timesyncd is not available'
  run "$up/bin/omarchy-restart-audio"
  assert_success
  run real_sudo_calls
  assert_output $'systemctl restart systemd-timesyncd\nusbreset 002/003'
}

@test "privileged.tsv has one valid line per Upstream bin/ command with privileged findings" {
  local inventory=$REPO/compat/inventory/$PIN.tsv table=$REPO/compat/privileged.tsv
  [[ -f $inventory ]]
  run awk -F'\t' '!/^#/ && NF > 0 && (NF != 4 || $1 == "" || $2 == "" || $4 == "" || ($3 != "allow" && $3 != "override" && $3 != "unsupported"))' "$table"
  assert_output ''
  local listed expected duplicates
  duplicates=$(awk -F'\t' '!/^#/ && NF > 0 { print $1 }' "$table" | sort | uniq -d)
  assert_equal "$duplicates" ""
  listed=$(awk -F'\t' '!/^#/ && NF > 0 { print $1 }' "$table" | sort)
  expected=$(awk -F'\t' '$3 == "privileged" && $1 ~ /^bin\/[^\/]+$/ { sub(/^bin\//, "", $1); print $1 }' "$inventory" | sort -u)
  assert_equal "$listed" "$expected"
  assert_equal "$(wc -l <<<"$listed")" 72
}

@test "privileged.tsv: override lines have an override, allow lines a specific pattern" {
  local c p a r
  while IFS=$'\t' read -r c p a r; do
    [[ -n $c && $c != '#'* ]] || continue
    case $a in
      override)
        [[ -x $SRC/overrides/$c ]] || fail "$c is marked override but src/overrides/$c is missing"
        ;;
      allow)
        [[ $p != '*' ]] || fail "$c allows every call"
        ;;
    esac
    [[ -n $r ]]
  done <"$REPO/compat/privileged.tsv"
}
