#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for the cache key of ci/debcache (task 24.1): the key is
# stable, and changes exactly when an input of the source package changes:
# its folder, its build-imports, its sbuild-repos keys for the suite, the
# version, and the inputs of the source package that builds a .deb its
# sbuild-local names. build and restore refuse to run outside the CI.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  DEBCACHE="$REPO/ci/debcache"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R/packaging/keys" "$R/packaging/motanka-a/debian" "$R/packaging/motanka-b/debian" "$R/stack"
  cp "$REPO/packaging/version.sh" "$R/packaging/version.sh"
  printf '0.1.0\n' >"$R/packaging/VERSION"
  printf 'key one\n' >"$R/packaging/keys/ppa.asc"
  printf 'a\t1.0\n' >"$R/stack/a-components.tsv"
  printf 'b\t1.0\n' >"$R/stack/b-components.tsv"
  printf 'u\t1.0\n' >"$R/stack/unrelated.tsv"
  printf 'Source: motanka-a\n\nPackage: motanka-a-libs\nArchitecture: amd64\n' >"$R/packaging/motanka-a/debian/control"
  printf '# imports\n/stack/a-components.tsv\n' >"$R/packaging/motanka-a/build-imports"
  printf '# extra sources\nnoble keys/ppa.asc deb http://example.invalid/ubuntu noble main\n' >"$R/packaging/motanka-a/sbuild-repos"
  printf 'Source: motanka-b\n\n#if noble resolute\nPackage: motanka-b\n#endif\nArchitecture: amd64\n' >"$R/packaging/motanka-b/debian/control.in"
  printf '/stack/b-components.tsv # the components\n' >"$R/packaging/motanka-b/build-imports"
  printf 'noble motanka-a-libs\nresolute motanka-a-libs\n' >"$R/packaging/motanka-b/sbuild-local"
  unset GITHUB_ACTIONS
}

key() {
  bash "$DEBCACHE" --repo "$R" key "packaging/$1" "$2"
}

@test "the key names the package and suite and is stable" {
  run key motanka-a noble
  assert_success
  assert_output --regexp '^motanka-debs-v1-motanka-a-noble-[0-9a-f]{40}$'
  local first=$output
  run key motanka-a noble
  assert_output "$first"
}

@test "the suite is part of the key" {
  [[ $(key motanka-a noble) != "$(key motanka-a resolute)" ]]
}

@test "a change in the package folder changes its key and the key of a package built against it" {
  local a b a2 b2
  a=$(key motanka-a noble)
  b=$(key motanka-b noble)
  printf 'override_dh_auto_build:\n' >"$R/packaging/motanka-a/debian/rules"
  a2=$(key motanka-a noble)
  b2=$(key motanka-b noble)
  [[ $a != "$a2" ]]
  [[ $b != "$b2" ]]
}

@test "a change in a package built against another one leaves the other key alone" {
  local a b
  a=$(key motanka-a noble)
  b=$(key motanka-b noble)
  printf 'changed\n' >"$R/packaging/motanka-b/README"
  [[ $(key motanka-a noble) == "$a" ]]
  [[ $(key motanka-b noble) != "$b" ]]
}

@test "an imported components file is an input; an unrelated one is not" {
  local a b
  a=$(key motanka-a noble)
  b=$(key motanka-b noble)
  printf 'u\t2.0\n' >"$R/stack/unrelated.tsv"
  [[ $(key motanka-a noble) == "$a" ]]
  [[ $(key motanka-b noble) == "$b" ]]
  printf 'a\t2.0\n' >"$R/stack/a-components.tsv"
  [[ $(key motanka-a noble) != "$a" ]]
  [[ $(key motanka-b noble) != "$b" ]]
}

@test "an sbuild-repos key file is an input only for its suite" {
  local n r
  n=$(key motanka-a noble)
  r=$(key motanka-a resolute)
  printf 'key two\n' >"$R/packaging/keys/ppa.asc"
  [[ $(key motanka-a noble) != "$n" ]]
  [[ $(key motanka-a resolute) == "$r" ]]
}

@test "the Motanka version is an input" {
  local a
  a=$(key motanka-a resolute)
  printf '0.2.0\n' >"$R/packaging/VERSION"
  [[ $(key motanka-a resolute) != "$a" ]]
}

@test "usage errors exit 2" {
  run --separate-stderr bash "$DEBCACHE" --repo "$R" key packaging/motanka-a jammy
  assert_failure 2
  run --separate-stderr bash "$DEBCACHE" --repo "$R" key stack noble
  assert_failure 2
  run --separate-stderr bash "$DEBCACHE" --repo "$R" key packaging/none noble
  assert_failure 2
  run --separate-stderr bash "$DEBCACHE" --repo "$R"
  assert_failure 2
}

@test "build and restore refuse to run outside the CI" {
  run --separate-stderr bash "$DEBCACHE" --repo "$R" build packaging/motanka-a noble
  assert_failure 1
  [[ $stderr == *'runs in the CI harness container only'* ]]
  run --separate-stderr bash "$DEBCACHE" --repo "$R" restore noble motanka-a
  assert_failure 1
  [[ $stderr == *'runs in the CI harness container only'* ]]
}
