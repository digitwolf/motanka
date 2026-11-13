#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for tools/fpdiff.py: Allowlist handling, output and exit codes.

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  FPDIFF="$BATS_TEST_DIRNAME/../../tools/fpdiff.py"
  BEFORE="$BATS_TEST_TMPDIR/before"
  AFTER="$BATS_TEST_TMPDIR/after"
  make_fingerprint "$BEFORE"
  make_fingerprint "$AFTER"
}

make_fingerprint() {
  local d=$1
  mkdir -p "$d"
  printf 'bash\t5.2.21-2ubuntu4\tinstalled\ncoreutils\t9.4-3ubuntu6\tinstalled\n' >"$d/packages.tsv"
  printf 'bash\ncoreutils\n' >"$d/manual.txt"
  printf '# root /etc\n/etc\td\t0755\t0:0\t-\n/etc/hostname\tf\t0644\t0:0\t%s\n' "$SHA_A" >"$d/etc.sha256"
  printf 'system ssh.service enabled enabled\nglobal pipewire.service enabled enabled\n' >"$d/units.txt"
  printf '[org/gnome/desktop/interface]\ncolor-scheme=%s\n' "'default'" >"$d/dconf-alice.ini"
  printf '# root /home/alice\n/home/alice\td\t0750\t1001:1001\t-\n/home/alice/.bashrc\tf\t0644\t1001:1001\t%s\n' "$SHA_A" >"$d/home-alice.sha256"
  printf 'firefox 140.0 6000 latest/stable mozilla** -\n' >"$d/snaps.txt"
  printf 'alice:x:1001:\nsudo:x:27:\n' >"$d/groups.txt"
  printf 'fs.file-nr = 1024\t0\t9223372036854775807\nkernel.random.uuid = 0b0c6c3e-0000-4000-8000-000000000001\nvm.swappiness = 60\n' >"$d/sysctl.txt"
  printf '# root /usr/share/wayland-sessions\n/usr/share/wayland-sessions\td\t0755\t0:0\t-\n' >"$d/sessions.txt"
}

# add_home_entry <path>: adds a file entry to alice's home in AFTER.
add_home_entry() {
  printf '%s\tf\t0644\t1001:1001\t%s\n' "$1" "$SHA_B" >>"$AFTER/home-alice.sha256"
}

fpdiff() {
  run python3 "$FPDIFF" "$BEFORE" "$AFTER"
}

@test "identical Fingerprints: exit 0 and no output" {
  fpdiff
  assert_success
  assert_output ''
}

@test "a changed package version is reported" {
  printf 'bash\t5.2.21-2ubuntu5\tinstalled\ncoreutils\t9.4-3ubuntu6\tinstalled\n' >"$AFTER/packages.tsv"
  fpdiff
  assert_failure 1
  assert_output --partial 'packages.tsv: changed bash: 5.2.21-2ubuntu4 installed -> 5.2.21-2ubuntu5 installed'
}

@test "an added package is reported" {
  printf 'hyprland\t0.41.2-1\tinstalled\n' >>"$AFTER/packages.tsv"
  fpdiff
  assert_failure 1
  assert_output --partial 'packages.tsv: added hyprland (0.41.2-1 installed)'
}

@test "a file under ~/.cache is allowlisted" {
  add_home_entry /home/alice/.cache/thumbnails/normal/x.png
  add_home_entry /home/alice/.cache
  fpdiff
  assert_success
  assert_output ''
}

@test "a sibling of ~/.cache is not allowlisted" {
  add_home_entry /home/alice/.cachefile
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: added /home/alice/.cachefile'
}

@test "a motanka-removed-<date> folder is allowlisted" {
  add_home_entry /home/alice/.local/state/motanka-removed-2026-11-12
  add_home_entry /home/alice/.local/state/motanka-removed-2026-11-12/hypr/hyprland.conf
  fpdiff
  assert_success
}

@test "a left-over User_Ledger is reported" {
  add_home_entry /home/alice/.local/state/motanka/ledger
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: added /home/alice/.local/state/motanka/ledger'
}

@test "a changed home file is reported with old and new values" {
  printf '# root /home/alice\n/home/alice\td\t0750\t1001:1001\t-\n/home/alice/.bashrc\tf\t0644\t1001:1001\t%s\n' "$SHA_B" >"$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial "home-alice.sha256: changed /home/alice/.bashrc: f 0644 1001:1001 $SHA_A -> f 0644 1001:1001 $SHA_B"
}

@test "a removed home file is reported" {
  printf '# root /home/alice\n/home/alice\td\t0750\t1001:1001\t-\n' >"$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'home-alice.sha256: removed /home/alice/.bashrc'
}

@test "volatile sysctl keys are allowlisted" {
  printf 'fs.file-nr = 2048\t0\t9223372036854775807\nkernel.random.uuid = 0b0c6c3e-0000-4000-8000-000000000002\nvm.swappiness = 60\n' >"$AFTER/sysctl.txt"
  fpdiff
  assert_success
}

@test "a configured sysctl change is reported" {
  printf 'fs.file-nr = 1024\t0\t9223372036854775807\nkernel.random.uuid = 0b0c6c3e-0000-4000-8000-000000000001\nvm.swappiness = 10\n' >"$AFTER/sysctl.txt"
  fpdiff
  assert_failure 1
  assert_output --partial 'sysctl.txt: changed vm.swappiness: 60 -> 10'
}

@test "a new file in /etc is reported" {
  printf '/etc/apt/sources.list.d/motanka.sources\tf\t0644\t0:0\t%s\n' "$SHA_B" >>"$AFTER/etc.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial 'etc.sha256: added /etc/apt/sources.list.d/motanka.sources'
}

@test "system paths in the Allowlist are ignored in tree files" {
  printf '# root /var\n/var/log/motanka-ledger-2026-11-12\tf\t0600\t0:0\t%s\n/var/cache/apt/pkgcache.bin\tf\t0644\t0:0\t%s\n' "$SHA_A" "$SHA_A" >"$BEFORE/var.sha256"
  printf '# root /var\n/var/log/motanka-ledger-2026-11-12\tf\t0600\t0:0\t%s\n' "$SHA_B" >"$AFTER/var.sha256"
  fpdiff
  assert_success
}

@test "a dconf change is reported with its full key" {
  printf '[org/gnome/desktop/interface]\ncolor-scheme=%s\n' "'prefer-dark'" >"$AFTER/dconf-alice.ini"
  fpdiff
  assert_failure 1
  assert_output --partial "dconf-alice.ini: changed org/gnome/desktop/interface/color-scheme: 'default' -> 'prefer-dark'"
}

@test "line-based files show removed and added lines" {
  printf 'alice:x:1001:\nsudo:x:27:alice\n' >"$AFTER/groups.txt"
  fpdiff
  assert_failure 1
  assert_line 'groups.txt: - sudo:x:27:'
  assert_line 'groups.txt: + sudo:x:27:alice'
}

@test "a file present on one side only is reported" {
  rm "$AFTER/snaps.txt"
  fpdiff
  assert_failure 1
  assert_output --partial "snaps.txt: only in $BEFORE"
}

@test "a new user's home folder is reported" {
  printf '# root /home/bob\n/home/bob\td\t0750\t1002:1002\t-\n' >"$AFTER/home-bob.sha256"
  fpdiff
  assert_failure 1
  assert_output --partial "home-bob.sha256: only in $AFTER"
}

@test "a missing folder is an input error" {
  run python3 "$FPDIFF" "$BEFORE" "$BATS_TEST_TMPDIR/missing"
  assert_failure 2
  assert_output --partial 'not a folder'
}

@test "a home tree file without a root header is an input error" {
  printf '/home/alice/.bashrc\tf\t0644\t1001:1001\t%s\n' "$SHA_A" >"$AFTER/home-alice.sha256"
  fpdiff
  assert_failure 2
}

@test "wrong number of arguments is a usage error" {
  run python3 "$FPDIFF" "$BEFORE"
  assert_failure 2
}
