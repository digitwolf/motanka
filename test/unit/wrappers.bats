#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # scripts and expected texts are single-quoted on purpose
# Unit tests for task 13.1: upstream.pin, tools/vendor, tools/genwrappers,
# src/libexec/run-upstream and src/compat-bin (5.9, 7.1, 7.14). Upstream
# trees and tarballs are small fixtures in BATS_TEST_TMPDIR; nothing is
# downloaded.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  COMMIT=ac2690cd7be4f47e4a255f5e2e78d904d436b068
}

# make_tarball <top-folder>: a gzip tarball $T/up.tar.gz of a small tree in
# $T/tarsrc/<top-folder>; prints its SHA-256.
make_tarball() {
  local top=$1 src=$T/tarsrc sum
  rm -rf "$src"
  mkdir -p "$src/$top/bin" "$src/$top/default"
  printf '#!/bin/bash\necho a\n' >"$src/$top/bin/omarchy-a"
  chmod 0755 "$src/$top/bin/omarchy-a"
  printf 'text\n' >"$src/$top/default/readme.txt"
  chmod 0644 "$src/$top/default/readme.txt"
  ln -s ../default/readme.txt "$src/$top/bin/omarchy-link"
  tar -C "$src" -czf "$T/up.tar.gz" "$top"
  sum=$(sha256sum <"$T/up.tar.gz")
  printf '%s\n' "${sum:0:64}"
}

# write_pin <sha256>: $T/pin with both channels at $COMMIT.
write_pin() {
  printf '# test pin\nstable\t%s\tv0.0.1\t%s\nedge\t%s\t-\t%s\n' "$COMMIT" "$1" "$COMMIT" "$1" >"$T/pin"
}

# env_script <upstream-tree>: bin/omarchy-env prints the Wrapper scope.
env_script() {
  write_script "$1/bin/omarchy-env" 'printf "PATH=%s\nOMARCHY_PATH=%s\nCMD=%s\nPACMAN=%s\nSUDO=%s\n" "$PATH" "$OMARCHY_PATH" "$MOTANKA_UPSTREAM_CMD" "$(command -v pacman || echo none)" "$(command -v sudo || echo none)"'
}

@test "upstream.pin pins stable and edge to v4.5.0 with the tarball checksum" {
  run grep -v '^#' "$REPO/upstream.pin"
  assert_success
  assert_equal "${#lines[@]}" 2
  assert_line "$(printf 'stable\t%s\tv4.5.0\t%s' "$COMMIT" 9e50de71792bff128070905a48258171e5a482c540f515e96ced30a50f88ddc6)"
  assert_line "$(printf 'edge\t%s\t-\t%s' "$COMMIT" 9e50de71792bff128070905a48258171e5a482c540f515e96ced30a50f88ddc6)"
}

@test "tools/vendor unpacks a tarball that matches the pin, unchanged" {
  local sha before
  sha=$(make_tarball "omarchy-$COMMIT")
  write_pin "$sha"
  before=$(sha256sum <"$T/up.tar.gz")
  run "$REPO/tools/vendor" --pin "$T/pin" --tarball "$T/up.tar.gz" stable "$T/out"
  assert_success
  run diff -r --no-dereference "$T/tarsrc/omarchy-$COMMIT" "$T/out"
  assert_success
  assert_equal "$(stat -c %a "$T/out/bin/omarchy-a")" 755
  assert_equal "$(stat -c %a "$T/out/default/readme.txt")" 644
  assert_equal "$(readlink "$T/out/bin/omarchy-link")" ../default/readme.txt
  assert_equal "$(sha256sum <"$T/up.tar.gz")" "$before"
  run ls -A "$T"
  refute_output --partial .vendor.
}

@test "tools/vendor refuses a tarball whose checksum differs: exit 6, nothing unpacked, the file kept" {
  local before zeros
  make_tarball "omarchy-$COMMIT" >/dev/null
  zeros=$(printf '0%.0s' {1..64})
  write_pin "$zeros"
  before=$(sha256sum <"$T/up.tar.gz")
  run "$REPO/tools/vendor" --pin "$T/pin" --tarball "$T/up.tar.gz" edge "$T/out"
  assert_failure 6
  assert_output --partial 'SHA-256 mismatch'
  [[ ! -e $T/out ]]
  assert_equal "$(sha256sum <"$T/up.tar.gz")" "$before"
  run ls -A "$T"
  refute_output --partial .vendor.
}

@test "tools/vendor refuses members outside the omarchy-<commit> folder" {
  local sha
  sha=$(make_tarball other-folder)
  write_pin "$sha"
  run "$REPO/tools/vendor" --pin "$T/pin" --tarball "$T/up.tar.gz" stable "$T/out"
  assert_failure 1
  assert_output --partial "outside omarchy-$COMMIT/"
  [[ ! -e $T/out ]]
}

@test "tools/vendor refuses an existing destination and an unknown channel" {
  local sha
  sha=$(make_tarball "omarchy-$COMMIT")
  write_pin "$sha"
  mkdir "$T/out"
  run "$REPO/tools/vendor" --pin "$T/pin" --tarball "$T/up.tar.gz" stable "$T/out"
  assert_failure 1
  assert_output --partial 'already exists'
  run "$REPO/tools/vendor" --pin "$T/pin" --tarball "$T/up.tar.gz" beta "$T/out2"
  assert_failure 2
  [[ ! -e $T/out2 ]]
}

@test "the cached Upstream tarball verifies against upstream.pin and unpacks to the cached tree" {
  local tarball=$REPO/.cache/upstream/omarchy-v4.5.0.tar.gz want sum
  if [[ ! -f $tarball || ! -d $REPO/.cache/upstream/omarchy/bin ]]; then
    skip "no cached Upstream tarball in this copy of the repository"
  fi
  want=$(awk -F'\t' '$1 == "stable" { print $4 }' "$REPO/upstream.pin")
  sum=$(sha256sum <"$tarball")
  if [[ ${sum:0:64} != "$want" ]]; then
    skip "the cached tarball is not the pinned commit archive"
  fi
  run "$REPO/tools/vendor" --tarball "$tarball" stable "$T/out"
  assert_success
  # The cached tree has Upstream's top-level AGENTS.md and CLAUDE.md renamed
  # to *.upstream-ref.md, so AI tools working in this repository do not
  # read them as instructions. Undo exactly those two renames in a copy;
  # every other difference fails the comparison.
  local cached=$T/cached f
  cp -a -- "$REPO/.cache/upstream/omarchy" "$cached"
  for f in AGENTS CLAUDE; do
    if [[ -e $cached/$f.upstream-ref.md || -L $cached/$f.upstream-ref.md ]]; then
      [[ ! -e $cached/$f.md && ! -L $cached/$f.md ]]
      mv -- "$cached/$f.upstream-ref.md" "$cached/$f.md"
    fi
  done
  run diff -r --no-dereference "$cached" "$T/out"
  assert_success
}

@test "tools/genwrappers writes one executable Wrapper per bin/ file" {
  local up
  up=$(fake_upstream)
  write_script "$up/bin/omarchy-a" 'echo a'
  write_script "$up/bin/omarchy-b" 'echo b'
  mkdir -p "$up/bin/subfolder"
  run "$REPO/tools/genwrappers" "$up" "$T/wrappers"
  assert_success
  run ls -A "$T/wrappers"
  assert_output $'omarchy-a\nomarchy-b'
  assert_equal "$(stat -c %a "$T/wrappers/omarchy-a")" 755
  run cat "$T/wrappers/omarchy-b"
  assert_output "$(printf '%s\n' '#!/bin/bash' \
    '# Motanka Wrapper for Upstream bin/omarchy-b; generated by tools/genwrappers, do not edit.' \
    'set -euo pipefail' \
    'exec /opt/motanka/libexec/motanka/run-upstream omarchy-b "$@"')"
}

@test "tools/genwrappers deletes stale Wrappers and refuses a folder with other files" {
  local up
  up=$(fake_upstream)
  write_script "$up/bin/omarchy-a" 'echo a'
  write_script "$up/bin/omarchy-b" 'echo b'
  run "$REPO/tools/genwrappers" "$up" "$T/wrappers"
  assert_success
  rm "$up/bin/omarchy-b"
  run "$REPO/tools/genwrappers" "$up" "$T/wrappers"
  assert_success
  [[ -f $T/wrappers/omarchy-a && ! -e $T/wrappers/omarchy-b ]]
  printf 'mine\n' >"$T/wrappers/notes"
  run "$REPO/tools/genwrappers" "$up" "$T/wrappers"
  assert_failure 1
  assert_output --partial 'not a generated Wrapper'
  [[ -f $T/wrappers/notes ]]
}

@test "tools/genwrappers refuses an Upstream file name that is not a command name" {
  local up
  up=$(fake_upstream)
  write_script "$up/bin/bad name" 'echo x'
  run "$REPO/tools/genwrappers" "$up" "$T/wrappers"
  assert_failure 1
  assert_output --partial 'not a valid command name'
}

@test "run-upstream sets OMARCHY_PATH, MOTANKA_UPSTREAM_CMD and the Wrapper scope PATH" {
  local up
  up=$(fake_upstream)
  env_script "$up"
  export MOTANKA_OMARCHY_PATH=$up
  PATH="$STUBS:/usr/bin:/bin" run "$SRC/libexec/run-upstream" omarchy-env
  assert_success
  assert_line "PATH=$SRC/overrides:$SRC/shims:$SRC/compat-bin:$up/bin:$STUBS:/usr/bin:/bin"
  assert_line "OMARCHY_PATH=$up"
  assert_line "CMD=omarchy-env"
  assert_line "PACMAN=$SRC/shims/pacman"
  assert_line "SUDO=$SRC/shims/sudo"
}

@test "run-upstream runs the override when there is one, Upstream's file otherwise" {
  local up
  up=$(fake_upstream)
  write_script "$up/bin/omarchy-pkg-aur-accessible" 'echo upstream; exit 0'
  write_script "$up/bin/omarchy-hello" 'echo "hello $*"'
  export MOTANKA_OMARCHY_PATH=$up
  run "$SRC/libexec/run-upstream" omarchy-pkg-aur-accessible
  assert_failure 1
  refute_output --partial upstream
  run "$SRC/libexec/run-upstream" omarchy-hello a 'b c'
  assert_success
  assert_output 'hello a b c'
  run "$SRC/libexec/run-upstream" omarchy-missing
  assert_failure 127
  run "$SRC/libexec/run-upstream" ../omarchy-hello
  assert_failure 2
}

@test "shims are on PATH only below a Wrapper, and nested Wrappers do not grow PATH" {
  local up
  up=$(fake_upstream)
  env_script "$up"
  write_script "$up/bin/omarchy-outer" 'exec "$WRAPPERS/omarchy-env"'
  run "$REPO/tools/genwrappers" --runner "$SRC/libexec/run-upstream" "$up" "$T/wrappers"
  assert_success
  export WRAPPERS=$T/wrappers MOTANKA_OMARCHY_PATH=$up
  # The session PATH has the Wrappers and no shim folder.
  PATH="$T/wrappers:/usr/bin:/bin" run bash -c 'command -v pacman || echo none; command -v sudo || echo none; command -v omarchy-env'
  refute_output --partial "$SRC/shims"
  assert_line "$T/wrappers/omarchy-env"
  PATH="$T/wrappers:/usr/bin:/bin" run omarchy-env
  assert_success
  assert_line "PACMAN=$SRC/shims/pacman"
  PATH="$T/wrappers:/usr/bin:/bin" run omarchy-outer
  assert_success
  assert_line "PATH=$SRC/overrides:$SRC/shims:$SRC/compat-bin:$up/bin:$T/wrappers:/usr/bin:/bin"
  assert_line "CMD=omarchy-env"
}

@test "run-upstream takes Upstream's bin from the vendored tree, since /usr/share/omarchy/bin is the Wrappers" {
  run grep -x 'readonly VENDORED_DEFAULT=/opt/motanka/share/omarchy' "$SRC/libexec/run-upstream"
  assert_success
  run grep -x 'upstream_bin=$vendored/bin' "$SRC/libexec/run-upstream"
  assert_success
  run grep -x 'readonly OMARCHY_DEFAULT=/usr/share/omarchy' "$SRC/libexec/run-upstream"
  assert_success
}

@test "bat and fd inside the Wrapper scope run batcat and fdfind" {
  local up
  up=$(fake_upstream)
  write_script "$up/bin/omarchy-cat" 'bat --plain x; fd -t f y'
  export MOTANKA_OMARCHY_PATH=$up
  run "$SRC/libexec/run-upstream" omarchy-cat
  assert_success
  assert_line 'batcat --plain x'
  assert_line 'fdfind -t f y'
}

@test "magick runs the real magick when there is one (ImageMagick 7, 26.04)" {
  local bin=$BATS_TEST_TMPDIR/im7
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "im7 magick $*"\n' >"$bin/magick"
  chmod +x "$bin/magick"
  PATH="$SRC/compat-bin:$bin:/usr/bin:/bin" run "$SRC/compat-bin/magick" identify -ping x.webp
  assert_success
  assert_output 'im7 magick identify -ping x.webp'
}

@test "without a real magick it runs the ImageMagick 6 commands (24.04)" {
  local bin=$BATS_TEST_TMPDIR/im6 t
  mkdir -p "$bin"
  for t in identify convert; do
    printf '#!/bin/sh\necho "im6 %s $*"\n' "$t" >"$bin/$t"
    chmod +x "$bin/$t"
  done
  PATH="$SRC/compat-bin:$bin:/usr/bin:/bin" run "$SRC/compat-bin/magick" identify -ping -format '%w %h' x.webp
  assert_success
  assert_output 'im6 identify -ping -format %w %h x.webp'
  PATH="$SRC/compat-bin:$bin:/usr/bin:/bin" run "$SRC/compat-bin/magick" -size 10x10 xc:none out.png
  assert_success
  assert_output 'im6 convert -size 10x10 xc:none out.png'
}

@test "magick without any ImageMagick exits 127 and names the package" {
  PATH="$SRC/compat-bin:$BATS_TEST_TMPDIR/empty" run "$SRC/compat-bin/magick" identify x
  assert_failure 127
  assert_output --partial 'imagemagick'
}

@test "the Compat_Layer's programs are executable in the repository" {
  local f
  local -a bad=()
  for f in "$REPO"/tools/{vendor,genwrappers,checkoverrides} "$SRC"/libexec/{run-upstream,helper,user-setup,shell-integration} \
    "$SRC"/shims/* "$SRC"/overrides/* "$SRC"/compat-bin/*; do
    if [[ ! -x $f ]]; then
      bad+=("${f#"$REPO"/}")
    fi
  done
  assert_equal "${bad[*]}" ""
}
