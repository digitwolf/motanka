#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2016 # setup and helpers are called by bats; ${misc:Depends} and code strings are literal
# Unit tests for pkgmap_depends of packaging/build.sh (task 26.1;
# requirements 3.4, 7.2): the Upstream names of debian/pkgmap-depends
# become the suite's apt or motanka Depends in debian/control, and an
# optional name ("?name") is left out on a suite where it has no such
# outcome. build.sh is sourced for its functions in a fake package tree
# with its own packages.yaml; nothing is built.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  BUILD="$REPO/packaging/build.sh"
  TREE=$BATS_TEST_TMPDIR/tree
  mkdir -p "$TREE/debian"
  # alpha: apt everywhere; beta: skip on noble, apt on resolute; gamma:
  # flatpak; delta: motanka; epsilon: binary.
  cat >"$TREE/packages.yaml" <<'EOF'
alpha:
  all: {apt: alpha-deb}
beta:
  noble: {skip: "not in the 24.04 archive"}
  resolute: {apt: beta-deb}
delta:
  all: {motanka: motanka-delta, reason: "Motanka build"}
epsilon:
  all: {binary: {dest: /opt/motanka/bin/epsilon, sha256: 0000000000000000000000000000000000000000000000000000000000000000, url: "https://example.test/epsilon"}, reason: "release binary"}
gamma:
  all: {flatpak: org.example.Gamma, reason: "Flathub app"}
EOF
  cat >"$TREE/debian/control" <<'EOF'
Source: motanka-test
Maintainer: Test <test@example.test>

Package: motanka-test
Architecture: all
Depends: ${misc:Depends},
         @PKGMAP_DEPENDS@
Description: test
 Test.
EOF
}

# depends <list lines>...: writes debian/pkgmap-depends.
depends() {
  printf '%s\n' "$@" >"$TREE/debian/pkgmap-depends"
}

# pd <suite>: runs pkgmap_depends on the tree for the suite.
pd() {
  run bash -c 'source "$1" && pkgmap_depends "$2" "$3"' _ "$BUILD" "$TREE" "$1"
}

# control_depends: the Depends lines of the generated control file.
control_depends() {
  awk '/^Depends:/ { on = 1 } on && /^Description:/ { exit } on' "$TREE/debian/control"
}

@test "an optional name whose outcome is skip on the suite is left out, with the log line" {
  depends '# header comment' alpha $'?beta\t# resolute only'
  pd noble
  assert_success
  assert_output --partial 'debian/pkgmap-depends: optional beta left out on noble (skip)'
  run control_depends
  assert_output "$(printf '%s\n' 'Depends: ${misc:Depends},' '         alpha-deb,')"
}

@test "an optional name whose outcome is apt on the suite is a Depends" {
  depends alpha $'?beta\t# resolute only'
  pd resolute
  assert_success
  refute_output --partial 'left out'
  run control_depends
  assert_output "$(printf '%s\n' 'Depends: ${misc:Depends},' '         alpha-deb,' '         beta-deb,')"
}

@test "optional names with flatpak and binary outcomes are left out; a motanka outcome is a Depends" {
  depends '?gamma' '?epsilon' delta
  pd noble
  assert_success
  assert_output --partial 'debian/pkgmap-depends: optional gamma left out on noble (flatpak)'
  assert_output --partial 'debian/pkgmap-depends: optional epsilon left out on noble (binary)'
  run control_depends
  assert_output "$(printf '%s\n' 'Depends: ${misc:Depends},' '         motanka-delta,')"
}

@test "a plain name whose outcome is skip on the suite still fails" {
  depends alpha beta
  pd noble
  assert_failure
  assert_output --partial "beta has the outcome 'skip' on noble"
  run grep -c '@PKGMAP_DEPENDS@' "$TREE/debian/control"
  assert_output 1
}

@test "an optional name without an entry fails" {
  depends alpha '?zeta'
  pd resolute
  assert_failure
  assert_output --partial 'debian/pkgmap-depends: zeta has no entry in'
}

@test "a lone '?' is not a name" {
  depends alpha '?'
  pd resolute
  assert_failure
  assert_output --partial "'?' is not an Upstream package name"
}

@test "sourcing build.sh defines its functions without running a build" {
  run bash -c 'source "$1" && declare -F pkgmap_depends gen_control unpack_components' _ "$BUILD"
  assert_success
  refute_output --partial 'usage'
}
