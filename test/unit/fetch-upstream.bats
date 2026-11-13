#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for tools/fetch-upstream (task 15.4): download, SHA-256 check
# against upstream.pin, member checks and the orig-omarchy component name.
# The "download" reads a fixture tarball through a file:// URL; nothing
# leaves the VM.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  TOOL="$REPO/tools/fetch-upstream"
  T=$BATS_TEST_TMPDIR
  COMMIT=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$T/srv" "$T/src"
}

# make_tarball <top-folder>: writes $T/srv/$COMMIT.tar.gz with a bin/ file
# below <top-folder> and prints its SHA-256.
make_tarball() {
  rm -rf "$T/src"
  mkdir -p "$T/src/$1/bin"
  printf '#!/bin/bash\necho hi\n' >"$T/src/$1/bin/omarchy-hello"
  tar -C "$T/src" -czf "$T/srv/$COMMIT.tar.gz" "$1"
  sha256sum <"$T/srv/$COMMIT.tar.gz" | cut -c1-64
}

# write_pin <sha256>
write_pin() {
  printf 'stable\t%s\tv9.9.9\t%s\nedge\t%s\t-\t%s\n' "$COMMIT" "$1" "$COMMIT" "$1" >"$T/pin"
}

fetch() {
  run python3 "$TOOL" --pin "$T/pin" --out "$T/out" --version 0.1.0 --url-base "file://$T/srv" "$@"
}

@test "a tarball that matches the pin is cached and linked as the orig-omarchy component" {
  write_pin "$(make_tarball "omarchy-$COMMIT")"
  fetch
  assert_success
  assert_line --index 0 --partial 'downloading'
  assert_equal "${lines[-1]}" "$T/out/orig"
  run cmp "$T/srv/$COMMIT.tar.gz" "$T/out/orig/motanka-core_0.1.0.orig-omarchy.tar.gz"
  assert_success
  run cmp "$T/srv/$COMMIT.tar.gz" "$T/out/downloads/omarchy-$COMMIT.tar.gz"
  assert_success
}

@test "a second run uses the cached tarball without downloading" {
  write_pin "$(make_tarball "omarchy-$COMMIT")"
  fetch
  assert_success
  rm -f "$T/srv/$COMMIT.tar.gz"
  fetch
  assert_success
  assert_output --partial 'cached'
  [[ -f $T/out/orig/motanka-core_0.1.0.orig-omarchy.tar.gz ]]
}

@test "a tarball whose SHA-256 differs from the pin: exit 6 and the download is deleted" {
  make_tarball "omarchy-$COMMIT" >/dev/null
  write_pin "$(printf '0%.0s' {1..64})"
  fetch
  assert_failure 6
  assert_output --partial 'does not match the stable pin'
  [[ ! -e $T/out/downloads/omarchy-$COMMIT.tar.gz ]]
  [[ ! -e $T/out/orig/motanka-core_0.1.0.orig-omarchy.tar.gz ]]
}

@test "a tarball with another top folder fails with exit 1" {
  write_pin "$(make_tarball other-top)"
  fetch
  assert_failure 1
  assert_output --partial "is outside omarchy-$COMMIT/"
  [[ ! -e $T/out/orig/motanka-core_0.1.0.orig-omarchy.tar.gz ]]
}

@test "the edge channel and another source name are honoured" {
  write_pin "$(make_tarball "omarchy-$COMMIT")"
  fetch --channel edge --source motanka-core-test
  assert_success
  [[ -f $T/out/orig/motanka-core-test_0.1.0.orig-omarchy.tar.gz ]]
}

@test "a pin file without the channel is a usage error" {
  printf 'edge\t%s\t-\t%s\n' "$COMMIT" "$(printf 'a%.0s' {1..64})" >"$T/pin"
  fetch
  assert_failure 2
  assert_output --partial 'exactly one line for stable'
}

@test "an http URL base is refused" {
  write_pin "$(make_tarball "omarchy-$COMMIT")"
  run python3 "$TOOL" --pin "$T/pin" --out "$T/out" --url-base http://example.invalid
  assert_failure 2
}

@test "the repository's upstream.pin has a valid stable line" {
  run grep -cE $'^stable\t[0-9a-f]{40}\t[^\t]+\t[0-9a-f]{64}$' "$REPO/upstream.pin"
  assert_output 1
}
