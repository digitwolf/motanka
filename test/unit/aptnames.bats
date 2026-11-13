#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup_file, setup, teardown_file and helpers are called by bats
# Unit tests for tools/aptnames: a signed file:// mirror with the release,
# -updates and -security pockets of noble and resolute gives one sorted
# name list per release; a Packages file whose checksum differs from the
# signed InRelease, an InRelease signed by another key and data after the
# signature are refused, and nothing is written for that release.

bats_require_minimum_version 1.5.0

setup_file() {
  if ! command -v gpg >/dev/null 2>&1 || ! command -v gpgv >/dev/null 2>&1; then
    export APTNAMES_SKIP="gpg or gpgv is not installed"
    return 0
  fi
  # A short path: gpg-agent's socket must fit into a socket address.
  GNUPGHOME=$(mktemp -d /tmp/aptnames-gpg.XXXXXX)
  export GNUPGHOME
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'aptnames test <aptnames@example.invalid>' ed25519 sign never
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'other test <other@example.invalid>' ed25519 sign never
  TEST_FPR=$(gpg --batch --with-colons --list-secret-keys aptnames@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')
  OTHER_FPR=$(gpg --batch --with-colons --list-secret-keys other@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')
  export TEST_FPR OTHER_FPR
  KEYRING="$BATS_FILE_TMPDIR/test-keyring.gpg"
  gpg --batch --export "$TEST_FPR" >"$KEYRING"
  export KEYRING
}

teardown_file() {
  if [[ -n ${GNUPGHOME:-} && $GNUPGHOME == /tmp/aptnames-gpg.* ]]; then
    gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf -- "$GNUPGHOME"
  fi
}

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if [[ -n ${APTNAMES_SKIP:-} ]]; then
    skip "$APTNAMES_SKIP"
  fi
  REPO="$BATS_TEST_DIRNAME/../.."
  APTNAMES="$REPO/tools/aptnames"
  MIRROR="$BATS_TEST_TMPDIR/mirror"
  OUT="$BATS_TEST_TMPDIR/out"
}

# make_suite <suite> <main names> <universe names> [signing fingerprint]:
# writes dists/<suite>/ with xz-compressed Packages files and a clearsigned
# InRelease.
make_suite() {
  local suite=$1 main=$2 universe=$3 fpr=${4:-$TEST_FPR} d
  d="$MIRROR/dists/$suite"
  mkdir -p "$d/main/binary-amd64" "$d/universe/binary-amd64"
  python3 - "$d" "$main" "$universe" "$suite" <<'PY'
import hashlib, lzma, os, sys
d, main, universe, suite = sys.argv[1:5]
lines = [f"Origin: Ubuntu", f"Suite: {suite}", "SHA256:"]
for comp, names in (("main", main), ("universe", universe)):
    text = "".join(f"Package: {n}\nVersion: 1.0\nArchitecture: amd64\n\n" for n in names.split())
    data = lzma.compress(text.encode())
    rel = f"{comp}/binary-amd64/Packages.xz"
    with open(os.path.join(d, rel), "wb") as f:
        f.write(data)
    lines.append(f" {hashlib.sha256(data).hexdigest()} {len(data)} {rel}")
with open(os.path.join(d, "Release"), "w") as f:
    f.write("\n".join(lines) + "\n")
PY
  gpg --batch --quiet --yes --local-user "$fpr" --clearsign --output "$d/InRelease" "$d/Release"
}

make_mirror() {
  make_suite noble "base-files zsh" "fd-find"
  make_suite noble-updates "zsh" "ripgrep"
  make_suite noble-security "base-files" ""
  make_suite resolute "base-files" "fd-find hyprland"
  make_suite resolute-updates "" "hyprland"
  make_suite resolute-security "openssl" ""
}

aptnames() {
  run --separate-stderr python3 "$APTNAMES" --out "$OUT" --mirror "file://$MIRROR" --keyring "$KEYRING"
}

@test "writes one sorted list per release from every pocket and component" {
  make_mirror
  aptnames
  assert_success
  run cat "$OUT/noble.txt"
  assert_output "$(printf '%s\n' base-files fd-find ripgrep zsh)"
  run cat "$OUT/resolute.txt"
  assert_output "$(printf '%s\n' base-files fd-find hyprland openssl)"
  run find "$OUT" -mindepth 1 -name '.aptnames*'
  assert_output ''
}

@test "a Packages file that differs from the signed InRelease is refused" {
  make_mirror
  python3 -c 'import lzma, sys; open(sys.argv[1], "wb").write(lzma.compress(b"Package: evil\n\n"))' \
    "$MIRROR/dists/resolute-updates/universe/binary-amd64/Packages.xz"
  aptnames
  assert_failure 1
  [[ $stderr == *'resolute-updates/universe/binary-amd64/Packages.xz: size or SHA-256 differs'* ]]
  [[ ! -e $OUT/resolute.txt ]]
}

@test "an InRelease signed by another key is refused" {
  make_mirror
  make_suite noble-security "base-files" "" "$OTHER_FPR"
  aptnames
  assert_failure 1
  [[ $stderr == *'noble-security/InRelease: the signature does not verify'* ]]
  [[ ! -e $OUT/noble.txt ]]
}

@test "data after the signature is refused" {
  make_mirror
  printf 'Package: injected\n' >>"$MIRROR/dists/noble/InRelease"
  aptnames
  assert_failure 1
  [[ $stderr == *'noble/InRelease'* ]]
}

@test "a missing pocket fails the run" {
  make_mirror
  rm -rf -- "$MIRROR/dists/resolute-security"
  aptnames
  assert_failure 1
  [[ $stderr == *'cannot download'*'resolute-security/InRelease'* ]]
}

@test "usage errors exit 2" {
  run --separate-stderr python3 "$APTNAMES"
  assert_failure 2
  run --separate-stderr python3 "$APTNAMES" --out "$OUT" --mirror ftp://example.invalid
  assert_failure 2
  run --separate-stderr python3 "$APTNAMES" --out "$OUT" --keyring "$BATS_TEST_TMPDIR/none.gpg"
  assert_failure 2
}
