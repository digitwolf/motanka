#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2016 # setup and helpers are called by bats; Makefile and substvar strings are literal
# Unit tests for the motanka-apps source package (task 26.1; requirements
# 3.4, 3.14, 7.2, 7.3): its control file, rules and copyright, the pinned
# herdr binary in stack/apps-components.tsv, the Package_Map entry of herdr,
# and the Upstream names of debian/pkgmap-depends. No network; nothing is
# built.
#
# Membership in Upstream's base list needs an Upstream tree at the stable
# pin (the repository has none; packaging/build.sh and ci/pin-gates fetch
# it). That test reads MOTANKA_UPSTREAM_TREE, or the tree ci/pin-gates
# leaves in .cache/ci/pin-gates/trees/<stable commit>/, and is skipped
# without one; the pin gate "apps" of ci/pin-gates makes the same check in
# CI.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  PKG="$REPO/packaging/motanka-apps"
  LIST="$PKG/debian/pkgmap-depends"
  TSV="$REPO/stack/apps-components.tsv"
  FETCH="$REPO/stack/fetch-sources"
  HERDR_URL=https://github.com/herdrdev/herdr/releases/download/v0.9.5/herdr-linux-x86_64
  HERDR_SHA=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
}

# names: the names of debian/pkgmap-depends, comments and spaces dropped,
# with a leading '?' kept.
names() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$LIST"
}

# helper_names: the names the header of debian/pkgmap-depends lists as
# left to the Helper (its comment lines indented by three spaces).
helper_names() {
  sed -n 's/^#   //p' "$LIST" | tr ' ' '\n' | sed '/^$/d'
}

# compiled <release>: tools/pkgmap compile of the repository's packages.yaml.
compiled() {
  python3 "$REPO/tools/pkgmap" compile "$1" --map "$REPO/packages.yaml"
}

# outcome <release> <name>: "<kind>\t<targets>" of a name.
outcome() {
  compiled "$1" | awk -F'\t' -v n="$2" '$1 == n { print $2 "\t" $3; exit }'
}

@test "control: metapackage motanka-apps (all) with Depends from @PKGMAP_DEPENDS@ and motanka-herdr (amd64) with the binary" {
  local c="$PKG/debian/control"
  run sed -n 's/^Source: //p' "$c"
  assert_output motanka-apps
  run sed -n 's/^Package: //p' "$c"
  assert_output "$(printf 'motanka-apps\nmotanka-herdr')"
  run awk 'BEGIN { RS = "" } /^Package: motanka-apps\n/' "$c"
  assert_output --partial $'\nSection: metapackages\n'
  assert_output --partial $'\nArchitecture: all\n'
  assert_output --partial 'motanka-herdr (= ${source:Version}),'
  assert_output --partial '${misc:Depends},'
  run awk 'BEGIN { RS = "" } /^Package: motanka-herdr\n/' "$c"
  assert_output --partial $'\nArchitecture: amd64\n'
  assert_output --partial '${shlibs:Depends},'
  run grep -c -E '^[[:space:]]+@PKGMAP_DEPENDS@,?[[:space:]]*$' "$c"
  assert_output 1
  run grep -E '^Build-Depends: debhelper-compat \(= 13\)$' "$c"
  assert_success
  [[ ! -e $PKG/debian/control.in ]] || fail "control.in and control both exist"
}

@test "rules: herdr/herdr-linux-x86_64 is installed as /opt/motanka/bin/herdr with mode 0755 and not stripped" {
  local r="$PKG/debian/rules"
  run grep -E '^export DEB_BUILD_MAINT_OPTIONS = hardening=\+all$' "$r"
  assert_success
  run grep -Fx 'HERDR := herdr/herdr-linux-x86_64' "$r"
  assert_success
  run grep -Fx 'HERDR_DEST := debian/motanka-herdr/opt/motanka/bin/herdr' "$r"
  assert_success
  run grep -F $'\tinstall -D -m 0755 $(HERDR) $(HERDR_DEST)' "$r"
  assert_success
  run grep -Fx $'\tdh_strip -Xopt/motanka/bin/herdr' "$r"
  assert_success
  run grep -Fx $'\tdh_dwz -Xopt/motanka/bin/herdr' "$r"
  assert_success
}

@test "the package has no maintainer scripts and is built for both releases" {
  local s
  for s in preinst postinst prerm postrm config; do
    [[ ! -e $PKG/debian/motanka-apps.$s && ! -e $PKG/debian/motanka-herdr.$s && ! -e $PKG/debian/$s ]] || fail "debian has a $s script"
  done
  [[ ! -e $PKG/suites ]] || fail "a suites file limits the releases"
  run cat "$PKG/debian/source/format"
  assert_output '3.0 (quilt)'
  run head -n 1 "$PKG/debian/changelog"
  assert_output --regexp '^motanka-apps \([0-9][^)]*-1\) UNRELEASED; urgency=medium$'
}

@test "copyright covers herdr/* as Apache-2.0 with a stand-alone licence paragraph" {
  local c="$PKG/debian/copyright"
  run awk 'BEGIN { RS = "" } /^Files: herdr\/\*\n/' "$c"
  assert_output --partial 'Copyright: herdr contributors (herdrdev)'
  assert_output --partial 'License: Apache-2.0'
  run awk 'BEGIN { RS = "" } /^License: Apache-2.0\n/' "$c"
  assert_output --partial '/usr/share/common-licenses/Apache-2.0'
  run grep -c '^Files: ' "$c"
  assert_output 2
}

@test "apps-components.tsv is valid, belongs to motanka-apps, is imported by it and pins the herdr 0.9.5 binary" {
  run python3 "$FETCH" --components "$TSV" --check
  assert_success
  assert_output --partial '1 components, valid (source motanka-apps)'
  run awk -F'\t' '!/^#/ && NF { print }' "$TSV"
  assert_output "$(printf 'herdr\t0.9.5\t%s\t%s\tfile\tboth\tmotanka-herdr' "$HERDR_URL" "$HERDR_SHA")"
  run grep -l '^/stack/apps-components.tsv$' "$REPO"/packaging/*/build-imports
  assert_output "$PKG/build-imports"
}

@test "the Package_Map gives herdr to motanka-herdr on both releases" {
  run grep -A1 -x 'herdr:' "$REPO/packages.yaml"
  assert_output --partial '  all: {motanka: motanka-herdr, reason: "'
  run outcome noble herdr
  assert_output "$(printf 'motanka\tmotanka-herdr')"
  run outcome resolute herdr
  assert_output "$(printf 'motanka\tmotanka-herdr')"
}

@test "nothing else depends on motanka-apps" {
  run grep -l -E '(^|[ ,|])motanka-apps([ ,(]|$)' "$REPO"/packaging/*/debian/control "$REPO"/packaging/*/debian/control.in
  if [[ -n $output ]]; then
    assert_output "$PKG/debian/control"
  fi
  run grep -x 'herdr' "$LIST"
  assert_failure
}

@test "debian/pkgmap-depends names are unique, valid and none is left to the Helper" {
  local n
  run names
  assert_success
  (("${#lines[@]}" > 90)) || fail "only ${#lines[@]} names"
  run bash -c 'sed -e "s/#.*//" -e "s/[[:space:]]//g" -e "s/^?//" -e "/^\$/d" "$1" | sort | uniq -d' _ "$LIST"
  assert_output ''
  mapfile -t helper < <(helper_names)
  ((${#helper[@]} >= 26)) || fail "the header lists ${#helper[@]} names left to the Helper"
  for n in docker cups avahi bluez networkmanager ufw qemu-user-static-binfmt nss-mdns; do
    [[ " ${helper[*]} " == *" $n "* ]] || fail "the header does not list $n as left to the Helper"
  done
  while IFS= read -r n; do
    [[ ${n#\?} =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]] || fail "'$n' is not an Upstream package name"
    [[ " ${helper[*]} " != *" ${n#\?} "* ]] || fail "${n#\?} is left to the Helper but listed"
  done < <(names)
}

@test "plain names have an apt or motanka outcome on both releases; optional names lack one on a release" {
  local n kind r has
  compiled noble >"$BATS_TEST_TMPDIR/noble.tsv"
  compiled resolute >"$BATS_TEST_TMPDIR/resolute.tsv"
  while IFS= read -r n; do
    has=0
    for r in noble resolute; do
      kind=$(awk -F'\t' -v n="${n#\?}" '$1 == n { print $2; exit }' "$BATS_TEST_TMPDIR/$r.tsv")
      [[ -n $kind ]] || fail "${n#\?} has no Package_Map entry"
      if [[ $kind == apt || $kind == motanka ]]; then
        has=$((has + 1))
      elif [[ $n != \?* ]]; then
        fail "$n has the outcome $kind on $r; write ?$n or drop it"
      fi
    done
    if [[ $n == \?* ]]; then
      ((has == 1)) || fail "$n is optional but has an apt or motanka outcome on $has releases"
    fi
  done < <(names)
}

# upstream_tree: MOTANKA_UPSTREAM_TREE, or ci/pin-gates' tree of the stable pin.
upstream_tree() {
  local commit
  if [[ -n ${MOTANKA_UPSTREAM_TREE:-} ]]; then
    printf '%s\n' "$MOTANKA_UPSTREAM_TREE"
    return 0
  fi
  commit=$(awk -F'\t' '$1 == "stable" { print $2; exit }' "$REPO/upstream.pin")
  if [[ -n $commit && -f $REPO/.cache/ci/pin-gates/trees/$commit/install/omarchy-base.packages ]]; then
    printf '%s\n' "$REPO/.cache/ci/pin-gates/trees/$commit"
  fi
}

@test "every debian/pkgmap-depends name is in Upstream's install/omarchy-base.packages" {
  local tree base n
  tree=$(upstream_tree)
  if [[ -z $tree ]]; then
    skip "no Upstream tree: set MOTANKA_UPSTREAM_TREE (ci/pin-gates checks this in CI, gate apps)"
  fi
  base=$tree/install/omarchy-base.packages
  [[ -f $base ]] || fail "$base is missing"
  mapfile -t up < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$base")
  while IFS= read -r n; do
    [[ " ${up[*]} " == *" ${n#\?} "* ]] || fail "${n#\?} is not in $base"
  done < <(names)
  for n in $(helper_names); do
    [[ " ${up[*]} " == *" $n "* ]] || fail "$n, left to the Helper, is not in $base"
  done
}
