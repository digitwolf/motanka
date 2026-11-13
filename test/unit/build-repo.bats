#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and teardown are called by bats
# Unit test for chumak/build-repo leaving out build-only packages
# (Motanka-Build-Only: yes, for example motanka-qt6-dev). Builds fixture
# .debs with dpkg-deb and signs with a throwaway key in a temporary
# GNUPGHOME, so it runs inside a test VM. The repository-level checks of
# build-repo are in test/vm/tests/repo.sh.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  umask 022
  REPO="$BATS_TEST_DIRNAME/../.."
  local tool
  for tool in gpg apt-ftparchive dpkg-deb; do
    command -v "$tool" >/dev/null || skip "$tool is not installed"
  done
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'Motanka unit test <test@example.test>' ed25519 sign never 2>/dev/null
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --armor \
    --export-secret-keys >"$BATS_TEST_TMPDIR/key.asc"
  DEBS="$BATS_TEST_TMPDIR/debs"
  mkdir -p "$DEBS"
}

teardown() {
  if [[ -n ${GNUPGHOME:-} && -d $GNUPGHOME ]]; then
    gpgconf --kill all >/dev/null 2>&1 || true
  fi
}

# fixture <package> [extra control line]: builds <package>_1.0_amd64.deb.
fixture() {
  local d="$BATS_TEST_TMPDIR/tree-$1"
  mkdir -p "$d/DEBIAN" "$d/opt/motanka/share/$1"
  printf 'fixture\n' >"$d/opt/motanka/share/$1/file"
  {
    printf 'Package: %s\nVersion: 1.0\nArchitecture: amd64\n' "$1"
    printf 'Maintainer: Test <test@example.test>\n'
    if [[ -n ${2:-} ]]; then
      printf '%s\n' "$2"
    fi
    printf 'Description: build-repo fixture\n Fixture package for test/unit/build-repo.bats.\n'
  } >"$d/DEBIAN/control"
  dpkg-deb --root-owner-group -Zgzip --build "$d" "$DEBS/${1}_1.0_amd64.deb" >/dev/null
}

@test "a build-only package is left out of the suite, others are published" {
  fixture motanka-test-dummy
  fixture motanka-qt6-dev 'Motanka-Build-Only: yes'
  run dpkg-deb --field "$DEBS/motanka-qt6-dev_1.0_amd64.deb" Motanka-Build-Only
  assert_output 'yes'

  run bash "$REPO/chumak/build-repo" --key "$BATS_TEST_TMPDIR/key.asc" \
    "$BATS_TEST_TMPDIR/out" noble="$DEBS"
  assert_success
  assert_output --partial 'skipping motanka-qt6-dev 1.0: build-only package'
  [[ -f $BATS_TEST_TMPDIR/out/pool/noble/main/m/motanka-test-dummy/motanka-test-dummy_1.0_amd64.deb ]]
  [[ ! -e $BATS_TEST_TMPDIR/out/pool/noble/main/m/motanka-qt6-dev ]]
  run grep -c '^Package: ' "$BATS_TEST_TMPDIR/out/dists/noble/main/binary-amd64/Packages"
  assert_output '1'
  run grep -F 'motanka-qt6-dev' "$BATS_TEST_TMPDIR/out/SHA256SUMS"
  assert_failure
}

@test "a package whose Motanka-Build-Only is not 'yes' is published" {
  fixture motanka-test-dummy 'Motanka-Build-Only: no'
  run bash "$REPO/chumak/build-repo" --key "$BATS_TEST_TMPDIR/key.asc" \
    "$BATS_TEST_TMPDIR/out" noble="$DEBS"
  assert_success
  refute_output --partial 'skipping'
  [[ -f $BATS_TEST_TMPDIR/out/pool/noble/main/m/motanka-test-dummy/motanka-test-dummy_1.0_amd64.deb ]]
}
