#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for packaging/version.sh: format, and ordering between releases
# under dpkg --compare-versions (requirement 11.6). Runs inside a test VM,
# which has dpkg.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  VERSION_SH="$BATS_TEST_DIRNAME/../../packaging/version.sh"
  VERSION_FILE="$BATS_TEST_DIRNAME/../../packaging/VERSION"
}

# v <suite> [options...]: prints the version or fails the test.
v() {
  local suite=$1
  shift
  bash "$VERSION_SH" "$@" "$suite"
}

@test "examples from the design: 0.1.0 on noble and resolute" {
  run v noble --version 0.1.0
  assert_success
  assert_output '0.1.0-1~ubuntu24.04.1'
  run v resolute --version 0.1.0
  assert_success
  assert_output '0.1.0-1~ubuntu26.04.1'
}

@test "the default version comes from packaging/VERSION" {
  local want
  want=$(tr -d '[:space:]' <"$VERSION_FILE")
  [[ $want =~ ^[0-9][A-Za-z0-9.+~]*$ ]]
  run v noble
  assert_success
  assert_output "$want-1~ubuntu24.04.1"
}

@test "edge suites use the version of their release" {
  run v noble-edge --version 0.3.1
  assert_output '0.3.1-1~ubuntu24.04.1'
  run v resolute-edge --version 0.3.1
  assert_output '0.3.1-1~ubuntu26.04.1'
}

@test "revision and build number are placed in the scheme" {
  run v resolute --version 1.2.0 --rev 3 --build 2
  assert_success
  assert_output '1.2.0-3~ubuntu26.04.2'
}

@test "every output is a valid Debian version" {
  local s
  for s in noble noble-edge resolute resolute-edge; do
    run dpkg --validate-version "$(v "$s" --version 0.2.0~rc1)"
    assert_success
  done
}

@test "for the same Motanka version and revision, resolute sorts above noble" {
  local ver rev b1 b2 n r
  for ver in 0.1.0 0.1.1 0.2.0~rc1 0.10.0 1.0.0 2.3.4+git1; do
    for rev in 1 2 10; do
      for b1 in 1 2 9; do
        for b2 in 1 2 9; do
          n=$(v noble --version "$ver" --rev "$rev" --build "$b1")
          r=$(v resolute --version "$ver" --rev "$rev" --build "$b2")
          if ! dpkg --compare-versions "$r" gt "$n"; then
            fail "expected $r > $n"
          fi
        done
      done
    done
  done
}

@test "a higher Motanka version on noble sorts above a lower one on resolute" {
  local pair lo hi r1 r2 n r
  for pair in 0.1.0:0.1.1 0.1.9:0.2.0 0.9.9:1.0.0 0.2.0~rc1:0.2.0 0.9.0:0.10.0 1.0.0:1.0.0+git1; do
    lo=${pair%%:*}
    hi=${pair#*:}
    for r1 in 1 2 10; do
      for r2 in 1 2 10; do
        n=$(v noble --version "$hi" --rev "$r1")
        r=$(v resolute --version "$lo" --rev "$r2")
        if ! dpkg --compare-versions "$n" gt "$r"; then
          fail "expected $n > $r"
        fi
      done
    done
  done
}

@test "an unknown suite is a usage error" {
  run v bionic
  assert_failure 2
  assert_output --partial "unknown suite 'bionic'"
}

@test "a version with a hyphen is rejected" {
  run v noble --version 0.1-0
  assert_failure 2
  assert_output --partial 'invalid Motanka version'
}

@test "a zero or non-numeric revision is rejected" {
  run v noble --rev 0
  assert_failure 2
  run v noble --rev x
  assert_failure 2
  run v noble --build 0
  assert_failure 2
}

@test "no suite is a usage error" {
  run bash "$VERSION_SH"
  assert_failure 2
}
