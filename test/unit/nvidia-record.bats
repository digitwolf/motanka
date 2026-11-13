#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for ci/check-nvidia-record (task 24.4; requirements 8.9,
# 13.9): a record filled in from the template of test/manual/nvidia.md
# passes; a missing record, an unfilled field, an old driver, a failed,
# missing or extra check, a wrong package version and a failed result do
# not.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  CHECK="$REPO/ci/check-nvidia-record"
  TEMPLATE="$REPO/test/manual/nvidia.md"
  V=9.8.7
  RECORD="$BATS_TEST_TMPDIR/$V-nvidia.md"
}

# filled_record: the template with every field filled in for version $V,
# every check PASS and driver 570.153.02.
filled_record() {
  local vn vr
  vn=$(bash "$REPO/packaging/version.sh" --version "$V" noble)
  vr=$(bash "$REPO/packaging/version.sh" --version "$V" resolute)
  template_block |
    awk -v v="$V" -v vn="$vn" -v vr="$vr" '
      /^## / { sec = $2 }
      /^Motanka version: / { print "Motanka version: " v; next }
      /^Commit: / { print "Commit: 0123456789abcdef0123456789abcdef01234567"; next }
      /^Driver: / { print "Driver: 570.153.02"; next }
      /^Motanka package version: / { print "Motanka package version: " (sec == "noble" ? vn : vr); next }
      {
        gsub(/\[fill in: PASS or FAIL\]/, "PASS")
        gsub(/\[fill in[^]]*\]/, "x")
        print
      }'
}

check() {
  run --separate-stderr bash "$CHECK" --version "$V" --record "$RECORD"
}

# template_block: the record template, the "```markdown" block of the
# test description.
template_block() {
  awk -v fence='```' '$0 == fence "markdown" { f = 1; next } f && $0 == fence { exit } f' "$TEMPLATE"
}

@test "the template of test/manual/nvidia.md has the check table for both releases" {
  local tmpl
  tmpl=$(template_block)
  grep -qx '## noble' <<<"$tmpl"
  grep -qx '## resolute' <<<"$tmpl"
  [[ $(grep -c '^| .* | \[fill in: PASS or FAIL\] | |$' <<<"$tmpl") -ge 30 ]]
}

@test "a record filled in from the template passes" {
  filled_record >"$RECORD"
  check
  assert_success
  assert_output --partial "passes for noble resolute (18 checks per release)"
}

@test "a missing record fails and names the test description" {
  check
  assert_failure 1
  assert_output --partial "$V-nvidia.md is missing"
  assert_output --partial "test/manual/nvidia.md"
}

@test "the default record path is test/manual/results/<version>-nvidia.md" {
  run --separate-stderr bash "$CHECK" --version 0.0.0-not-a-version
  assert_failure 2
  run --separate-stderr bash "$CHECK" --version 0.0.0~ci.test
  assert_failure 1
  assert_output --partial "test/manual/results/0.0.0~ci.test-nvidia.md is missing"
}

@test "a field left as [fill in fails" {
  filled_record | sed 's/^Tester: x$/Tester: [fill in: name]/' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "still hold '[fill in'"
}

@test "a driver older than 555 fails" {
  filled_record | awk '/^## resolute$/ { r = 1 } r && /^Driver: / { print "Driver: 550.163.01"; next } { print }' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "resolute: driver 550.163.01 is older than 555"
}

@test "a failed check fails" {
  filled_record | sed 's/^| hyprctl configerrors reports no errors | PASS |/| hyprctl configerrors reports no errors | FAIL |/' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "check 'hyprctl configerrors reports no errors' is 'FAIL', not PASS"
}

@test "a check of the template without a row fails" {
  filled_record | awk '/^## noble$/ { n = 1 } /^## resolute$/ { n = 0 } n && /^\| remove --yes exits 0 \|/ { next } { print }' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "noble: the check 'remove --yes exits 0' of the template has no row"
}

@test "a package version of the other release fails" {
  local vn
  vn=$(bash "$REPO/packaging/version.sh" --version "$V" noble)
  filled_record | awk -v vn="$vn" '/^## resolute$/ { r = 1 } r && /^Motanka package version: / { print "Motanka package version: " vn; next } { print }' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "resolute: 'Motanka package version: $vn' is not"
}

@test "a result that is not PASS fails" {
  filled_record | awk '/^## noble$/ { n = 1 } /^## resolute$/ { n = 0 } n && /^Result: / { print "Result: FAIL"; next } { print }' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "noble: 'Result: FAIL' is not PASS"
}

@test "a missing release section fails" {
  filled_record | awk '/^## resolute$/ { exit } { print }' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "no '## resolute' section"
}

@test "a record of another version or without the commit fails" {
  filled_record | sed -e 's/^Motanka version: .*/Motanka version: 1.0.0/' -e 's/^Commit: .*/Commit: abc/' >"$RECORD"
  check
  assert_failure 1
  assert_output --partial "'Motanka version: 1.0.0' does not name $V"
  assert_output --partial "'Commit:' must be the 40-digit commit"
}
