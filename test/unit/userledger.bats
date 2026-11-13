#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for src/lib/userledger.sh: entry format, write-ahead order,
# write-then-rename, backups, marked blocks, the reverse walk (6.2, 6.3,
# 6.11, 10.2-10.4), and the property test of task 9.5: for any generated
# sequence of create, replace, symlink and marked-block actions on a temp
# home folder, applying them and walking the ledger in reverse restores the
# tree byte for byte, also when the sequence is cut at any point, including
# between a ledger line and its action and inside a torn ledger line.
#
# The property test runs MK_PROP_RUNS sequences (default 200) from the
# fixed seed MK_PROP_SEED (default 20261113), so a failure reproduces.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  chmod +x "$STUBS/systemd-cat"
  export PATH="$STUBS:$PATH"
  # shellcheck source=../../src/lib/common.sh
  source "$REPO/src/lib/common.sh"
  # shellcheck source=../../src/lib/userledger.sh
  source "$REPO/src/lib/userledger.sh"
  H="$BATS_TEST_TMPDIR/home"
  mkdir -p "$H"
  export MK_HOME="$H"
  L="$H/.local/state/motanka/ledger"
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC"
}

# src <name> <content>: a source file with that content; backslash escapes
# such as \n are expanded.
src() {
  printf '%b' "$2" >"$SRC/$1"
  printf '%s\n' "$SRC/$1"
}

# entries: the ledger without the time and run ID columns.
entries() {
  cut -f3- "$L"
}

# manifest <home>: type, mode, link target and content hash of every path.
manifest() {
  (
    cd "$1" || exit 1
    find . -mindepth 1 -printf '%P\t%y\t%m\t%l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

sha() {
  sha256sum <"$1" | cut -c1-64
}

@test "a new file is ledgered with its parents and the state folder's parents" {
  mk_userledger_write session .config/hypr/hyprland.lua "$(src a 'hello\n')"
  run entries
  assert_success
  assert_equal "${lines[0]}" "$(printf 'create\tnamespaced\t.local/\t-\t-\t-')"
  assert_equal "${lines[1]}" "$(printf 'create\tnamespaced\t.local/state/\t-\t-\t-')"
  assert_equal "${lines[2]}" "$(printf 'create\tnamespaced\t.local/state/motanka/\t-\t-\t-')"
  assert_equal "${lines[3]}" "$(printf 'create\tsession\t.config/\t-\t-\t-')"
  assert_equal "${lines[4]}" "$(printf 'create\tsession\t.config/hypr/\t-\t-\t-')"
  assert_equal "${lines[5]}" "$(printf 'create\tsession\t.config/hypr/hyprland.lua\t-\t%s\t-' "$(sha "$SRC/a")")"
  cmp "$SRC/a" "$H/.config/hypr/hyprland.lua"
}

@test "existing state folders are not ledgered as created" {
  mkdir -p "$H/.local/state"
  mk_userledger_write app .config/btop/btop.conf "$(src a x)"
  run entries
  assert_equal "${lines[0]}" "$(printf 'create\tnamespaced\t.local/state/motanka/\t-\t-\t-')"
  refute_line --partial $'\t.local/\t'
}

@test "a replaced file is backed up first, with its content and mode" {
  mkdir -p "$H/.config/waybar"
  printf 'user config\n' >"$H/.config/waybar/config"
  chmod 0600 "$H/.config/waybar/config"
  local before
  before=$(sha "$H/.config/waybar/config")
  mk_userledger_write session .config/waybar/config "$(src new 'motanka config\n')"
  local -a f
  IFS=$'\t' read -r -a f < <(tail -n 1 "$L")
  assert_equal "${f[2]}" replace
  assert_equal "${f[5]}" "$before"
  assert_equal "${f[6]}" "$(sha "$SRC/new")"
  [[ ${f[7]} =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$ ]]
  local copy="$H/.local/state/motanka/backups/${f[7]}/.config/waybar/config"
  run cat "$copy"
  assert_output 'user config'
  assert_equal "$(stat -c %a "$copy")" 600
  cmp "$SRC/new" "$H/.config/waybar/config"
}

@test "the ledger line and the backup are on disk before the rename" {
  mkdir -p "$H/.config/walker"
  printf 'old\n' >"$H/.config/walker/config.toml"
  export ORDER="$BATS_TEST_TMPDIR/order" LEDGER="$L" CHECK_PATH=.config/walker/config.toml
  export CHECK_ABS="$H/.config/walker/config.toml" BACKUPS="$H/.local/state/motanka/backups"
  cat >"$STUBS/sync" <<'EOF'
#!/bin/sh
echo "sync $*" >>"$ORDER"
exec /usr/bin/sync "$@"
EOF
  cat >"$STUBS/mv" <<'EOF'
#!/bin/sh
for last; do :; done
if [ "$last" = "$CHECK_ABS" ]; then
  pat=$(printf '\t%s\t' "$CHECK_PATH")
  state=not-ledgered
  grep -qF -- "$pat" "$LEDGER" && state=ledgered
  backup=no-backup
  ls "$BACKUPS"/*/"$CHECK_PATH" >/dev/null 2>&1 && backup=backup
  echo "mv $last $state $backup" >>"$ORDER"
fi
exec /usr/bin/mv "$@"
EOF
  chmod +x "$STUBS/sync" "$STUBS/mv"
  mk_userledger_write session "$CHECK_PATH" "$(src new 'new\n')"
  run cat "$ORDER"
  assert_line "mv $CHECK_ABS ledgered backup"
  local i synced=-1 moved=-1
  for i in "${!lines[@]}"; do
    if [[ ${lines[i]} == "sync -- $L" && $synced -lt 0 ]]; then
      synced=$i
    fi
    if [[ ${lines[i]} == "mv $CHECK_ABS"* ]]; then
      moved=$i
    fi
  done
  ((synced >= 0 && synced < moved))
}

@test "files are replaced by rename: new inode, no temporary file left" {
  mkdir -p "$H/.config/foot"
  printf 'a\n' >"$H/.config/foot/foot.ini"
  local inode
  inode=$(stat -c %i "$H/.config/foot/foot.ini")
  mk_userledger_write app .config/foot/foot.ini "$(src new 'b\n')"
  [[ $(stat -c %i "$H/.config/foot/foot.ini") != "$inode" ]]
  run ls -A "$H/.config/foot"
  assert_output 'foot.ini'
}

@test "the new file takes the source file's mode" {
  local s
  s=$(src script '#!/bin/sh\n')
  chmod 0755 "$s"
  mk_userledger_write session .local/share/omarchy-x/run "$s"
  assert_equal "$(stat -c %a "$H/.local/share/omarchy-x/run")" 755
}

@test "symbolic links are created and replaced with an l: state" {
  mk_userledger_symlink session .config/hypr/current "../themes/a"
  [[ -L $H/.config/hypr/current ]]
  assert_equal "$(readlink "$H/.config/hypr/current")" ../themes/a
  local want
  want="l:$(printf '%s' ../themes/a | sha256sum | cut -c1-64)"
  run tail -n 1 "$L"
  assert_output --regexp "$(printf '\tsymlink\tsession\t.config/hypr/current\t-\t%s\t-$' "$want")"
  mk_userledger_symlink session .config/hypr/current "../themes/b"
  assert_equal "$(readlink "$H/.config/hypr/current")" ../themes/b
  run tail -n 1 "$L"
  assert_output --regexp "$(printf '\tsymlink\tsession\t.config/hypr/current\tl:[0-9a-f]{64}\tl:[0-9a-f]{64}\t[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$')"
}

@test "a block is added to a new file, appended after a final newline, and replaced in place" {
  local body1 body2
  body1=$(src b1 'eval "$(motanka-shell)"\n')
  body2=$(src b2 'source /opt/motanka/share/motanka/shell.bash\n')
  mk_userledger_block shared .bashrc "$body1"
  run cat "$H/.bashrc"
  assert_output $'# >>> motanka >>>\neval "$(motanka-shell)"\n# <<< motanka <<<'
  printf 'export A=1' >"$H/.zshrc"
  mk_userledger_block shared .zshrc "$body1"
  run cat "$H/.zshrc"
  assert_output $'export A=1\n# >>> motanka >>>\neval "$(motanka-shell)"\n# <<< motanka <<<'
  printf 'alias x=y\n' >>"$H/.zshrc"
  mk_userledger_block shared .zshrc "$body2"
  run cat "$H/.zshrc"
  assert_output $'export A=1\n# >>> motanka >>>\nsource /opt/motanka/share/motanka/shell.bash\n# <<< motanka <<<\nalias x=y'
  run grep -c '^# >>> motanka >>>$' "$H/.zshrc"
  assert_output 1
}

@test "a block is refused for a symbolic link and for a body with a marker" {
  ln -s dotfiles/bashrc "$H/.bashrc"
  run mk_userledger_block shared .bashrc "$(src b 'x\n')"
  assert_failure
  assert_output --partial 'symbolic link'
  [[ -L $H/.bashrc ]]
  run mk_userledger_block shared .zshrc "$(src m '# <<< motanka <<<\n')"
  assert_failure
  assert_output --partial 'block marker'
  [[ ! -e $H/.zshrc ]]
}

@test "invalid paths and classes are refused without a ledger line" {
  local s p
  s=$(src a x)
  for p in /etc/passwd ../x a/../b ./a a//b .local/state/motanka/ledger .local/state/motanka "dir/" "$(printf 'a\tb')" -; do
    run mk_userledger_write session "$p" "$s"
    assert_failure
  done
  run mk_userledger_write bogus .config/x "$s"
  assert_failure
  if [[ -e $L ]]; then
    run entries
    refute_output --partial $'\tsession\t'
  fi
}

@test "a folder in the way is refused" {
  mkdir -p "$H/.config/x"
  run mk_userledger_write session .config/x "$(src a x)"
  assert_failure
  [[ -d $H/.config/x ]]
}

@test "revert restores replaced files, deletes created ones and removes created folders" {
  mkdir -p "$H/.config/hypr"
  printf 'mine\n' >"$H/.config/hypr/hyprland.lua"
  printf 'rc\n' >"$H/.bashrc"
  local before
  before=$(manifest "$H")
  mk_userledger_setup_begin
  mk_userledger_write session .config/hypr/hyprland.lua "$(src a 'new\n')"
  mk_userledger_write session .config/waybar/config.jsonc "$(src b '{}\n')"
  mk_userledger_symlink session .config/hypr/theme "$H/.config/omarchy/current/theme"
  mk_userledger_block shared .bashrc "$(src c 'x=1\n')"
  mk_userledger_setup_end
  run mk_userledger_revert
  assert_success
  assert_line "$(printf 'restored\t.bashrc')"
  assert_line "$(printf 'deleted\t.config/hypr/theme')"
  assert_line "$(printf 'deleted\t.config/waybar/config.jsonc')"
  assert_line "$(printf 'deleted\t.config/waybar/')"
  assert_line "$(printf 'restored\t.config/hypr/hyprland.lua')"
  assert_equal "$(manifest "$H")" "$before"
}

@test "revert walks the ledger in reverse order" {
  mk_userledger_write session .config/a/one "$(src a 1)"
  mk_userledger_write session .config/a/one "$(src b 2)"
  mk_userledger_write session .config/a/two "$(src c 3)"
  run mk_userledger_revert
  assert_success
  assert_equal "${lines[0]}" "$(printf 'deleted\t.config/a/two')"
  assert_equal "${lines[1]}" "$(printf 'restored\t.config/a/one')"
  assert_equal "${lines[2]}" "$(printf 'deleted\t.config/a/one')"
  assert_equal "${lines[3]}" "$(printf 'deleted\t.config/a/')"
  assert_equal "${lines[4]}" "$(printf 'deleted\t.config/')"
  run ls -A "$H"
  assert_output ''
}

@test "an edited file moves to motanka-removed-<date> and the backup is restored" {
  mkdir -p "$H/.config/alacritty"
  printf 'orig\n' >"$H/.config/alacritty/alacritty.toml"
  mk_userledger_write app .config/alacritty/alacritty.toml "$(src a 'motanka\n')"
  printf 'edited by the user\n' >>"$H/.config/alacritty/alacritty.toml"
  mk_userledger_write app .config/alacritty/extra.toml "$(src b 'x\n')"
  printf 'also edited\n' >"$H/.config/alacritty/extra.toml"
  run mk_userledger_revert
  assert_success
  local day
  day=$(date -u +%Y-%m-%d)
  assert_line "$(printf 'moved\t.config/alacritty/alacritty.toml\t.local/state/motanka-removed-%s/.config/alacritty/alacritty.toml' "$day")"
  assert_line "$(printf 'moved\t.config/alacritty/extra.toml\t.local/state/motanka-removed-%s/.config/alacritty/extra.toml' "$day")"
  run cat "$H/.config/alacritty/alacritty.toml"
  assert_output 'orig'
  run cat "$H/.local/state/motanka-removed-$day/.config/alacritty/alacritty.toml"
  assert_output $'motanka\nedited by the user'
  [[ ! -e $H/.config/alacritty/extra.toml ]]
  [[ ! -e $H/.local/state/motanka ]]
}

@test "an edited file with a block keeps the user's edits and loses the block" {
  printf 'a=1\n' >"$H/.bashrc"
  mk_userledger_block shared .bashrc "$(src b 'eval x\n')"
  printf 'b=2\n' >>"$H/.bashrc"
  run mk_userledger_revert
  assert_success
  assert_line "$(printf 'block-removed\t.bashrc')"
  run cat "$H/.bashrc"
  assert_output $'a=1\nb=2'
}

@test "menu desktop entries are kept without --purge and deleted with it" {
  mk_userledger_menu_desktop .local/share/applications/app.desktop "$(src d '[Desktop Entry]\nOnlyShowIn=Motanka;\n')"
  cp -r "$H" "$BATS_TEST_TMPDIR/home2"
  run mk_userledger_revert
  assert_success
  assert_line "$(printf 'kept\t.local/share/applications/app.desktop')"
  [[ -f $H/.local/share/applications/app.desktop ]]
  MK_HOME="$BATS_TEST_TMPDIR/home2"
  run mk_userledger_revert --purge
  assert_success
  assert_line "$(printf 'deleted\t.local/share/applications/app.desktop')"
  run ls -A "$BATS_TEST_TMPDIR/home2"
  assert_output ''
}

@test "unplanned entries are listed and left in place" {
  mk_userledger_setup_begin
  mkdir -p "$H/.config/someapp"
  printf 'x\n' >"$H/.config/someapp/state"
  mk_userledger_record_unplanned .config/someapp/state
  run tail -n 1 "$L"
  assert_output --regexp "$(printf '\tunplanned\t-\t.config/someapp/state\t-\t[0-9a-f]{64}\t-$')"
  run mk_userledger_revert
  assert_success
  assert_line "$(printf 'unplanned\t.config/someapp/state')"
  [[ -f $H/.config/someapp/state ]]
}

@test "revert is idempotent and can run again after a failure" {
  mkdir -p "$H/.config/hypr"
  printf 'mine\n' >"$H/.config/hypr/a"
  local before
  before=$(manifest "$H")
  mk_userledger_write session .config/hypr/a "$(src a 'new\n')"
  mk_userledger_write session .config/hypr/b "$(src b 'new\n')"
  local backups="$H/.local/state/motanka/backups"
  mv "$backups" "$BATS_TEST_TMPDIR/hidden"
  run mk_userledger_revert
  assert_failure
  [[ -f $L ]]
  [[ ! -e $H/.config/hypr/b ]]
  mv "$BATS_TEST_TMPDIR/hidden" "$backups"
  run mk_userledger_revert
  assert_success
  assert_equal "$(manifest "$H")" "$before"
  run mk_userledger_revert
  assert_success
  assert_output ''
}

@test "read skips a torn last line" {
  mk_userledger_write session .config/a "$(src a x)"
  mk_userledger_write session .config/b "$(src b y)"
  local size
  size=$(stat -c %s "$L")
  truncate -s $((size - 10)) "$L"
  run --separate-stderr mk_userledger_read
  assert_success
  refute_output --partial '.config/b'
  assert_output --partial '.config/a'
  [[ $stderr == *'skipped 1'* ]]
}

# --- property test ------------------------------------------------------

POOL=(.bashrc .zshrc .config/app1/conf .config/app1/extra.ini
  .config/app2/deep/settings.json .local/share/thing/data
  .local/state/other/x top.txt ".config/sp ace/f g")
CLASSES=(namespaced session app)
WORDS=(alpha beta gamma "two words" 'quote"d' 'tab	in' "x=1" "" '# >>> not a marker' "\$HOME")

# rnd <n>: R becomes a random number in 0..n-1 (no subshell, so the seeded
# RANDOM sequence stays deterministic).
rnd() {
  R=$((RANDOM % $1))
}

# gen_content <file>: 0-4 random lines, with a final newline 3 times in 4.
gen_content() {
  local n i out=""
  rnd 5
  n=$R
  for ((i = 0; i < n; i++)); do
    rnd ${#WORDS[@]}
    out+="${WORDS[R]} $RANDOM"
    if ((i < n - 1)); then
      out+=$'\n'
    fi
  done
  rnd 4
  if ((n > 0 && R > 0)); then
    out+=$'\n'
  fi
  printf '%s' "$out" >"$1"
  rnd 3
  case $R in
    0) chmod 0600 "$1" ;;
    1) chmod 0644 "$1" ;;
    2) chmod 0755 "$1" ;;
  esac
}

# gen_tree <home>: a random starting home folder.
gen_tree() {
  local home=$1 p
  mkdir -p "$home"
  rnd 3
  case $R in
    0) mkdir -p "$home/.local/state" ;;
    1) mkdir -p "$home/.local" ;;
  esac
  rnd 2
  if ((R)); then
    mkdir -p "$home/.config/app2"
  fi
  for p in "${POOL[@]}"; do
    rnd 2
    ((R)) || continue
    mkdir -p "$(dirname "$home/$p")"
    rnd 5
    if ((R == 0)); then
      ln -s "target-$RANDOM" "$home/$p"
    else
      gen_content "$home/$p"
    fi
  done
}

# apply_action <index> <stage-only>: one random action; with stage-only=1
# only the part up to and including the ledger line runs.
apply_action() {
  local i=$1 stage=$2 p class kind s abs
  rnd ${#POOL[@]}
  p=${POOL[R]}
  rnd ${#CLASSES[@]}
  class=${CLASSES[R]}
  rnd 3
  kind=$R
  abs=$MK_HOME/$p
  if [[ -d $abs && ! -L $abs ]]; then
    ACTIONS+=("$i skip $p")
    return 0
  fi
  if ((kind == 2)) && [[ -L $abs ]]; then
    kind=0
  fi
  s=$BATS_TEST_TMPDIR/prop-src-$i
  case $kind in
    0)
      gen_content "$s"
      ACTIONS+=("$i write $class $p")
      if ((stage)); then
        _mk_ul_stage_write "$class" "$p" "$s"
      else
        mk_userledger_write "$class" "$p" "$s"
      fi
      ;;
    1)
      local target="t-$RANDOM"
      rnd 3
      if ((R == 0)); then
        target="../a b/$target"
      fi
      ACTIONS+=("$i symlink $class $p -> $target")
      if ((stage)); then
        _mk_ul_stage_symlink "$class" "$p" "$target"
      else
        mk_userledger_symlink "$class" "$p" "$target"
      fi
      ;;
    2)
      gen_content "$s"
      grep -vxF -e '# >>> motanka >>>' -e '# <<< motanka <<<' "$s" >"$s.body" || true
      ACTIONS+=("$i block $class $p")
      if ((stage)); then
        _mk_ul_stage_block "$class" "$p" "$s.body"
      else
        mk_userledger_block "$class" "$p" "$s.body"
      fi
      ;;
  esac
}

# tear_last_line: cuts 1 to all bytes of the ledger's last line.
tear_last_line() {
  local size len
  size=$(stat -c %s "$L")
  len=$(tail -n 1 "$L" | wc -c)
  rnd "$len"
  truncate -s $((size - R - 1)) "$L"
}

@test "property: apply, cut anywhere, revert restores the tree byte for byte" {
  local runs=${MK_PROP_RUNS:-200} seed=${MK_PROP_SEED:-20261113}
  local run n k mode i before after
  RANDOM=$seed
  for ((run = 0; run < runs; run++)); do
    MK_HOME="$BATS_TEST_TMPDIR/prop-home"
    L="$MK_HOME/.local/state/motanka/ledger"
    rm -rf "$MK_HOME"
    gen_tree "$MK_HOME"
    before=$(manifest "$MK_HOME")
    ACTIONS=()
    rnd 8
    n=$((R + 1))
    rnd $((n + 1))
    k=$R
    rnd 3
    mode=$R
    for ((i = 0; i < k; i++)); do
      if ! apply_action "$i" 0 >/dev/null 2>&1; then
        fail "run $run (seed $seed): action failed: ${ACTIONS[*]: -1}"
      fi
    done
    if ((k < n && mode > 0)); then
      if apply_action "$k" 1 >/dev/null 2>&1; then
        ACTIONS+=("$k interrupted after the ledger line")
        if ((mode == 2)) && [[ ${ACTIONS[-2]} != *" skip "* ]]; then
          tear_last_line
          ACTIONS+=("$k last ledger line torn")
        fi
      else
        fail "run $run (seed $seed): staging failed: ${ACTIONS[*]: -1}"
      fi
    fi
    if ! mk_userledger_revert >/dev/null 2>"$BATS_TEST_TMPDIR/revert.err"; then
      fail "run $run (seed $seed): revert failed: $(cat "$BATS_TEST_TMPDIR/revert.err"); actions: ${ACTIONS[*]}"
    fi
    after=$(manifest "$MK_HOME")
    if [[ $after != "$before" ]]; then
      fail "run $run (seed $seed): tree differs after revert; actions: $(printf '[%s] ' "${ACTIONS[@]}")
$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    fi
  done
}
