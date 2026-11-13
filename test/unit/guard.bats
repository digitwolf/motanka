#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # bash -c scripts are single-quoted on purpose
# Unit tests for src/lib/guard.sh: Protected_Host (14.11) and Dev_Build
# (14.8) checks. Markers and users live in a fake root (MOTANKA_ROOT);
# systemd-detect-virt is a stub on PATH.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  LIB="$REPO/src/lib"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT/etc" "$MOTANKA_ROOT/home/alice/.config" "$MOTANKA_ROOT/home/bob/.config"
  printf 'root:x:0:0:root:/root:/bin/bash\nalice:x:1001:1001:Alice:/home/alice:/bin/bash\nbob:x:1002:1002:Bob:/home/bob:/bin/bash\n' \
    >"$MOTANKA_ROOT/etc/passwd"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  cat >"$STUBS/systemd-detect-virt" <<'EOF'
#!/bin/sh
if [ -n "$FAKE_VIRT" ]; then echo "$FAKE_VIRT"; fi
[ "$FAKE_VIRT" != none ] && [ -n "$FAKE_VIRT" ]
EOF
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  chmod +x "$STUBS/systemd-detect-virt" "$STUBS/systemd-cat"
  export PATH="$STUBS:$PATH"
  export FAKE_VIRT=kvm
  unset SUDO_USER PKEXEC_UID
}

# guards <args...>: runs mk_guards with the arguments in a new shell.
guards() {
  run bash -c 'set -euo pipefail; source "$1/common.sh"; source "$1/guard.sh"; MK_CMD=install; shift; mk_guards "$@"; echo passed' _ "$LIB" "$@"
}

dev_build() {
  mkdir -p "$MOTANKA_ROOT/opt/motanka/share/motanka"
  touch "$MOTANKA_ROOT/opt/motanka/share/motanka/DEV_BUILD"
}

@test "no marker and a published build: the guards pass" {
  if [[ -e /etc/motanka-protected || -e /opt/motanka/share/motanka/DEV_BUILD ]]; then
    skip "this VM has a real marker"
  fi
  guards --yes
  assert_success
  assert_output 'passed'
}

@test "/etc/motanka-protected refuses with exit 7 and names the marker" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  guards
  assert_failure 7
  assert_output --partial "Protected_Host ($MOTANKA_ROOT/etc/motanka-protected exists)"
  refute_output --partial passed
}

@test "a Protected_Host refuses for every flag" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  dev_build
  local flags
  local -a args
  for flags in '' '--yes' '--dry-run' '--i-know-this-is-not-a-vm' '--i-know-this-is-not-a-vm --yes --dry-run'; do
    read -r -a args <<<"$flags"
    FAKE_VIRT=kvm guards "${args[@]}"
    assert_failure 7
    FAKE_VIRT=none guards "${args[@]}"
    assert_failure 7
  done
}

@test "a dangling symbolic link is a marker too" {
  ln -s /nonexistent "$MOTANKA_ROOT/etc/motanka-protected"
  guards
  assert_failure 7
}

@test "SUDO_USER's ~/.config/motanka-protected refuses" {
  touch "$MOTANKA_ROOT/home/alice/.config/motanka-protected"
  SUDO_USER=alice guards
  assert_failure 7
  assert_output --partial "$MOTANKA_ROOT/home/alice/.config/motanka-protected"
}

@test "PKEXEC_UID's ~/.config/motanka-protected refuses" {
  touch "$MOTANKA_ROOT/home/alice/.config/motanka-protected"
  PKEXEC_UID=1001 guards
  assert_failure 7
  assert_output --partial "$MOTANKA_ROOT/home/alice/.config/motanka-protected"
}

@test "another user's marker does not refuse" {
  if [[ -e /etc/motanka-protected || -e /opt/motanka/share/motanka/DEV_BUILD ]]; then
    skip "this VM has a real marker"
  fi
  touch "$MOTANKA_ROOT/home/bob/.config/motanka-protected"
  SUDO_USER=alice guards
  assert_success
  PKEXEC_UID=1001 guards
  assert_success
}

@test "mk_guard_user_homes lists the real home and the fake-root homes" {
  local real
  real=$(getent passwd "$(id -u)" | cut -d: -f6)
  run env SUDO_USER=alice PKEXEC_UID=1002 bash -c 'source "$1/common.sh"; source "$1/guard.sh"; mk_guard_user_homes' _ "$LIB"
  assert_success
  assert_line "$real"
  assert_line "$MOTANKA_ROOT/home/alice"
  assert_line "$MOTANKA_ROOT/home/bob"
}

@test "a Dev_Build where systemd-detect-virt prints none exits 7" {
  dev_build
  FAKE_VIRT=none guards --yes
  assert_failure 7
  assert_output --partial 'development build'
  assert_output --partial 'test/vm/'
}

@test "a Dev_Build where systemd-detect-virt prints nothing exits 7" {
  dev_build
  FAKE_VIRT='' guards
  assert_failure 7
}

@test "a Dev_Build in a VM passes" {
  local v
  dev_build
  for v in kvm qemu microsoft oracle lxc; do
    FAKE_VIRT=$v guards
    assert_success
  done
}

@test "a Dev_Build outside a VM passes with --i-know-this-is-not-a-vm and warns" {
  dev_build
  FAKE_VIRT=none guards --dry-run --i-know-this-is-not-a-vm
  assert_success
  assert_output --partial 'continuing because --i-know-this-is-not-a-vm was given'
  assert_line 'passed'
}

@test "the flag after -- does not count" {
  dev_build
  FAKE_VIRT=none guards -- --i-know-this-is-not-a-vm
  assert_failure 7
}

@test "a published build rejects --i-know-this-is-not-a-vm as a usage error" {
  if [[ -e /opt/motanka/share/motanka/DEV_BUILD ]]; then
    skip "this VM has a development build installed"
  fi
  guards --i-know-this-is-not-a-vm
  assert_failure 2
  assert_output --partial 'accepted by development builds only'
}

@test "the Protected_Host check runs before the Dev_Build check" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  guards --i-know-this-is-not-a-vm
  assert_failure 7
  assert_output --partial 'Protected_Host'
}
