#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for tools/pkgmap: validation failures, compilation to
# package-map.tsv, the report, and the real packages.yaml against the
# Upstream tree and apt name lists in .cache/ when they are present.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  PKGMAP="$REPO/tools/pkgmap"
  UP="$BATS_TEST_TMPDIR/upstream"
  APT="$BATS_TEST_TMPDIR/aptnames"
  MAP="$BATS_TEST_TMPDIR/packages.yaml"
  mkdir -p "$UP/install" "$APT"
  printf '# base list\nfoo\nbar # inline comment\n\n' >"$UP/install/omarchy-base.packages"
  printf 'baz\nfoo\n' >"$UP/install/omarchy-other.packages"
  printf '# nothing x86_64-only\n' >"$UP/install/omarchy-x86_64-only.packages"
  printf 'bar\nfoo-ubuntu\n' >"$APT/noble.txt"
  printf 'bar\nbar2\nfoo-ubuntu\n' >"$APT/resolute.txt"
  cat >"$MAP" <<'EOF'
# fixture map
bar:
  noble: {apt: bar}
  resolute: {apt: [bar, bar2]}
baz:
  all: {skip: "not needed here"}
foo:
  all: {apt: foo-ubuntu, reason: "renamed in Ubuntu"}
EOF
}

validate() {
  run python3 "$PKGMAP" validate --upstream "$UP" --aptnames "$APT" --map "$MAP"
}

# write_map <line>...: replaces the fixture map with the given lines.
write_map() {
  printf '%s\n' "$@" >"$MAP"
}

@test "a complete map validates" {
  validate
  assert_success
  assert_output --partial 'no problems'
}

@test "an Upstream package without an entry fails validation" {
  write_map 'bar:' '  all: {apt: bar}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'baz: in an Upstream list but not in the Package_Map'
}

@test "an apt target missing from one release fails for that release only" {
  write_map 'bar:' '  all: {apt: [bar, bar2]}' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line "bar (noble): apt package 'bar2' does not exist in noble"
  refute_line --partial 'bar (resolute)'
}

@test "a binary outcome without url and sha256 fails" {
  write_map 'bar:' '  all: {apt: bar}' 'baz:' '  all: {binary: {dest: /opt/motanka/apps/baz}, reason: "upstream binary"}' \
    'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'baz (all): binary without url'
  assert_line 'baz (all): binary without sha256'
}

@test "a binary outcome with a bad url, checksum or destination fails" {
  write_map 'bar:' '  all: {apt: bar}' \
    'baz:' '  all: {binary: {dest: /usr/local/bin/baz, sha256: ABC, url: "http://example.test/baz"}, reason: "upstream binary"}' \
    'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'baz (all): binary url must start with https://'
  assert_line 'baz (all): binary sha256 must be 64 lowercase hex digits'
  assert_line 'baz (all): binary dest must be under /opt/motanka/ or a Namespaced_Path'
}

@test "non-apt outcomes without a reason fail" {
  write_map 'bar:' '  noble: {motanka: motanka-stack-tools}' '  resolute: {flatpak: org.example.Bar}' \
    'baz:' '  all: {skip: ""}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'bar (noble): non-apt outcome without a reason'
  assert_line 'bar (resolute): non-apt outcome without a reason'
  assert_line 'baz (all): skip needs a non-empty reason'
}

@test "a motanka outcome must name a Motanka_Package" {
  write_map 'bar:' '  all: {motanka: hyprland, reason: "Stack"}' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line "bar (all): 'hyprland' is not a Motanka_Package name"
}

@test "a missing release fails" {
  write_map 'bar:' '  noble: {apt: bar}' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'bar: no outcome for resolute'
}

@test "all combined with a release fails" {
  write_map 'bar:' '  all: {apt: bar}' '  noble: {apt: bar}' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line "bar: 'all' cannot be combined with a release"
}

@test "unsorted entries fail" {
  write_map 'foo:' '  all: {apt: foo-ubuntu}' 'bar:' '  all: {apt: bar}' 'baz:' '  all: {skip: "x"}'
  validate
  assert_failure 1
  assert_line "entries not sorted: 'bar' comes after 'foo'"
}

@test "unsorted keys inside an outcome fail" {
  write_map 'bar:' '  all: {reason: "note", apt: bar}' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_output --partial 'are not sorted'
}

@test "lines outside the format fail with their line number" {
  write_map 'bar:' '  all: apt bar' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'packages.yaml:2: line does not match the format'
}

@test "two kinds in one outcome fail" {
  write_map 'bar:' '  all: {apt: bar, skip: "x"}' 'baz:' '  all: {skip: "x"}' 'foo:' '  all: {apt: foo-ubuntu}'
  validate
  assert_failure 1
  assert_line 'bar (all): exactly one of apt, motanka, flatpak, binary, skip is required'
}

@test "an entry no Upstream list names is a warning only" {
  write_map 'bar:' '  all: {apt: bar}' 'baz:' '  all: {skip: "x"}' 'extra:' '  all: {skip: "old"}' 'foo:' '  all: {apt: foo-ubuntu}'
  run --separate-stderr python3 "$PKGMAP" validate --upstream "$UP" --aptnames "$APT" --map "$MAP"
  assert_success
  [[ $stderr == *'warning: extra: not in any Upstream list'* ]]
}

@test "a missing Upstream list is an input error" {
  rm "$UP/install/omarchy-other.packages"
  validate
  assert_failure 2
  assert_output --partial 'cannot read Upstream list'
}

@test "a missing apt name list is an input error" {
  rm "$APT/resolute.txt"
  validate
  assert_failure 2
  assert_output --partial 'cannot read apt name list'
}

@test "compile writes the Data Models format for noble" {
  run --separate-stderr python3 "$PKGMAP" compile noble --map "$MAP"
  assert_success
  assert_equal "${#lines[@]}" 4
  [[ ${lines[0]} == '# package-map.tsv for noble,'* ]]
  assert_equal "${lines[1]}" "$(printf 'bar\tapt\tbar\t-')"
  assert_equal "${lines[2]}" "$(printf 'baz\tskip\t-\tnot needed here')"
  assert_equal "${lines[3]}" "$(printf 'foo\tapt\tfoo-ubuntu\trenamed in Ubuntu')"
}

@test "compile joins several apt names with commas" {
  run --separate-stderr python3 "$PKGMAP" compile resolute --map "$MAP"
  assert_success
  assert_line "$(printf 'bar\tapt\tbar,bar2\t-')"
}

@test "compile writes motanka, flatpak and binary lines" {
  local sha
  sha=$(printf '%064d' 0 | tr 0 a)
  write_map 'a1:' '  all: {motanka: [motanka-stack-shell, motanka-qt6], reason: "Stack"}' \
    'b2:' '  all: {flatpak: org.example.App, reason: "not in the archive"}' \
    'c3:' "  all: {binary: {dest: /opt/motanka/apps/c3, sha256: $sha, url: \"https://example.test/c3.tar.gz\"}, reason: \"upstream binary\"}"
  run --separate-stderr python3 "$PKGMAP" compile noble --map "$MAP"
  assert_success
  assert_line "$(printf 'a1\tmotanka\tmotanka-stack-shell,motanka-qt6\tStack')"
  assert_line "$(printf 'b2\tflatpak\torg.example.App\tnot in the archive')"
  assert_line "$(printf 'c3\tbinary\thttps://example.test/c3.tar.gz\t%s\t/opt/motanka/apps/c3' "$sha")"
}

@test "compile -o writes the file through a rename and leaves no temporary file" {
  local out="$BATS_TEST_TMPDIR/out"
  mkdir "$out"
  run python3 "$PKGMAP" compile noble --map "$MAP" -o "$out/package-map.tsv"
  assert_success
  run ls -A "$out"
  assert_output 'package-map.tsv'
  run python3 "$PKGMAP" compile noble --map "$MAP"
  assert_equal "$(cat "$out/package-map.tsv")" "$output"
}

@test "compile of an invalid map fails without output" {
  write_map 'bar:' '  all: {motanka: motanka-x}'
  run --separate-stderr python3 "$PKGMAP" compile noble --map "$MAP"
  assert_failure 1
  refute_output --partial $'\t'
}

@test "compile of an unknown release is a usage error" {
  run python3 "$PKGMAP" compile jammy --map "$MAP"
  assert_failure 2
  assert_output --partial "unknown release 'jammy'"
}

@test "report counts outcomes per release" {
  run python3 "$PKGMAP" report --map "$MAP"
  assert_success
  assert_line --regexp '^outcome +noble +resolute$'
  assert_line --regexp '^apt +2 +2$'
  assert_line --regexp '^skip +1 +1$'
  assert_line --regexp '^total +3 +3$'
}

@test "no command is a usage error" {
  run python3 "$PKGMAP"
  assert_failure 2
}

@test "the real packages.yaml validates against Upstream at the pin" {
  local upstream="$REPO/.cache/upstream/omarchy" aptnames="$REPO/.cache/aptnames"
  if [[ ! -d $upstream/install || ! -f $aptnames/noble.txt ]]; then
    skip "no Upstream tree or apt name lists in .cache/"
  fi
  run python3 "$PKGMAP" validate --upstream "$upstream" --aptnames "$aptnames"
  assert_success
}

@test "the real packages.yaml compiles for both releases" {
  local rel
  for rel in noble resolute; do
    run --separate-stderr python3 "$PKGMAP" compile "$rel"
    assert_success
    [[ ${lines[0]} == "# package-map.tsv for $rel,"* ]]
    ((${#lines[@]} > 200))
  done
}
