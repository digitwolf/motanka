#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for test/vm/fptwin.py, the twin comparison of the release
# upgrade VM test (task 22.3): changes both VMs made are accepted, changes
# only the tested VM made are reported, identity differences between the
# VMs are accepted while both keep them, the Allowlist of tools/fpdiff.py
# applies, and an obsolete package the twin's upgrader removed is a note.

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  FPTWIN="$BATS_TEST_DIRNAME/../vm/fptwin.py"
  A0="$BATS_TEST_TMPDIR/a0" A1="$BATS_TEST_TMPDIR/a1"
  B0="$BATS_TEST_TMPDIR/b0" B1="$BATS_TEST_TMPDIR/b1"
  # The twins on 24.04, with their own host names.
  make_fp "$A0" noble "$SHA_A"
  make_fp "$B0" noble "$SHA_B"
  # Both after the release upgrade: new versions, a changed /etc file.
  make_fp "$A1" resolute "$SHA_A"
  make_fp "$B1" resolute "$SHA_B"
}

# make_fp <folder> <noble|resolute> <hostname-sha>
make_fp() {
  local d=$1 v=5.2.21-2ubuntu4 issue=$SHA_A
  if [[ $2 == resolute ]]; then
    v=5.3-1ubuntu1 issue=$SHA_C
  fi
  mkdir -p "$d"
  printf 'bash\t%s\tinstalled\nlibold1\t1.0-1\tinstalled\n' "$v" >"$d/packages.tsv"
  if [[ $2 == resolute ]]; then
    printf 'bash\t%s\tinstalled\n' "$v" >"$d/packages.tsv"
  fi
  printf '# root /etc\n/etc\td\t0755\t0:0\t-\n/etc/hostname\tf\t0644\t0:0\t%s\n/etc/issue\tf\t0644\t0:0\t%s\n' \
    "$3" "$issue" >"$d/etc.sha256"
  printf '# root /home/tester\n/home/tester\td\t0750\t1000:1000\t-\n' >"$d/home-tester.sha256"
  printf 'kernel.hostname = %s\nvm.swappiness = 60\n' "${3:0:8}" >"$d/sysctl.txt"
  printf 'sudo:x:27:tester\n' >"$d/groups.txt"
}

fptwin() {
  run python3 "$FPTWIN" "$A0" "$A1" "$B0" "$B1"
}

@test "changes both VMs made and identity differences both kept are accepted" {
  fptwin
  assert_success
  assert_output ''
}

@test "a package only the tested VM has after the upgrade is reported" {
  printf 'libfoo2\t2.0-1\tinstalled\n' >>"$A1/packages.tsv"
  fptwin
  assert_failure 1
  assert_line 'packages.tsv: libfoo2: the twin ends with absent, the tested VM with 2.0-1 installed (both had absent before)'
}

@test "a file the tested VM left changed is reported" {
  printf '/etc/motanka-left\tf\t0644\t0:0\t%s\n' "$SHA_C" >>"$A1/etc.sha256"
  sed -i "s|^/etc/issue\tf\t0644\t0:0\t.*|/etc/issue\tf\t0644\t0:0\t$SHA_B|" "$A1/etc.sha256"
  fptwin
  assert_failure 1
  assert_line --partial 'etc.sha256: /etc/issue: the twin ends with f 0644 0:0 cccc'
  assert_line --partial 'etc.sha256: /etc/motanka-left: the twin ends with absent'
}

@test "an identity value only one VM changed is reported" {
  sed -i "s|^/etc/hostname\tf\t0644\t0:0\t.*|/etc/hostname\tf\t0644\t0:0\t$SHA_C|" "$A1/etc.sha256"
  fptwin
  assert_failure 1
  assert_line --partial 'etc.sha256: /etc/hostname: differed between the VMs before; the tested VM changed it'
}

@test "an obsolete package the twin's upgrader removed and the tested VM kept is a note" {
  printf 'libold1\t1.0-1\tinstalled\n' >>"$A1/packages.tsv"
  fptwin
  assert_success
  assert_output "note: packages.tsv: libold1: kept at 1.0-1 installed; the twin's upgrader removed it as obsolete"
}

@test "the Allowlist of tools/fpdiff.py applies" {
  printf '/var/log/dist-upgrade\td\t0755\t0:0\t-\n' >>"$A1/etc.sha256"
  printf '# root /var\n/var/log/apt/history.log\tf\t0644\t0:0\t%s\n' "$SHA_C" >"$A0/var.sha256"
  cp "$A0/var.sha256" "$A1/var.sha256"
  cp "$A0/var.sha256" "$B0/var.sha256"
  printf '# root /var\n' >"$B1/var.sha256"
  printf '/home/tester/.cache/x\tf\t0644\t1000:1000\t%s\n' "$SHA_C" >>"$A1/home-tester.sha256"
  fptwin
  assert_success
  assert_output ''
}

@test "a file missing from one Fingerprint is reported" {
  rm "$B1/groups.txt"
  fptwin
  assert_failure 1
  assert_line --regexp '^groups\.txt: missing in .*/b1$'
}
