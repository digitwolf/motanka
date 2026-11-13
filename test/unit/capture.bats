#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test changes are intended
# shellcheck disable=SC2119 # mk_userledger_revert and mk_capture_end take only optional flags
# Unit tests for src/lib/capture.sh, the session capture (design.md,
# "Session-time home writes"; requirements 6.4, 6.9, 6.10, 10.1-10.5,
# 12.8): capture start and end, classes from the real compat/home-paths.tsv,
# the rule that a path present at the start is never adopted (also when it
# was replaced by a rename), crash recovery (a start without an end), the
# plan, and the reverse walk of what the capture recorded (adopted files
# deleted when unchanged and moved aside when changed, adopted folders
# removed when empty, plan equal to apply). The cost test lists 100 000
# entries; MK_CAPTURE_START_MS (default 1500) and MK_CAPTURE_END_MS
# (default 2500) are its limits in milliseconds.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if ((EUID == 0)); then
    skip "the capture runs as the user who owns the home folder; run these tests as a normal user"
  fi
  REPO="$BATS_TEST_DIRNAME/../.."
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  chmod +x "$STUBS/systemd-cat"
  export PATH="$STUBS:$PATH"
  export NO_COLOR=1
  # shellcheck source=../../src/lib/common.sh
  source "$REPO/src/lib/common.sh"
  # shellcheck source=../../src/lib/userledger.sh
  source "$REPO/src/lib/userledger.sh"
  # shellcheck source=../../src/lib/homepaths.sh
  source "$REPO/src/lib/homepaths.sh"
  # shellcheck source=../../src/lib/capture.sh
  source "$REPO/src/lib/capture.sh"
  H="$BATS_TEST_TMPDIR/home"
  mkdir -p "$H"
  export MK_HOME="$H"
  export MOTANKA_HOME_PATHS="$REPO/compat/home-paths.tsv"
  L="$H/.local/state/motanka/ledger"
  C="$H/.local/state/motanka/capture"
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC"
}

# put <path> [content]: a file in the home folder.
put() {
  mkdir -p "$(dirname -- "$H/$1")"
  printf '%s\n' "${2:-x}" >"$H/$1"
}

# entries: the ledger without the time and run-ID columns.
entries() {
  cut -f3- "$L"
}

sha() {
  sha256sum <"$1" | cut -c1-64
}

# manifest: type, mode, link target and content hash of every path.
manifest() {
  (
    cd "$H" || exit 1
    find . -mindepth 1 -printf '%P\t%y\t%m\t%l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

# a_moment: makes later changes newer than files written before, also on
# file systems with coarse timestamps.
a_moment() {
  sleep 0.05
}

@test "capture start lists the scanned roots without ~/.cache, Namespaced_Paths and motanka-removed folders" {
  put .config/hypr/hyprland.lua
  put .local/share/applications/a.desktop
  put .cache/thumbnails/x.png
  put .config/omarchy/current/theme.name
  put .local/state/omarchy/done/first-run-user
  put .local/state/motanka-removed-2026-11-13/.config/x
  put Documents/report.odt
  put notes.txt
  put .mozilla/firefox/abc.default/prefs.js
  put .mozilla/firefox/abc.default/storage/permanent/x
  run mk_capture_start
  assert_success
  [[ -f $C/start && -f $C/paths ]]
  run cut -f2 "$C/paths"
  assert_line .config
  assert_line .config/hypr/hyprland.lua
  assert_line .local/share/applications/a.desktop
  assert_line Documents
  assert_line notes.txt
  assert_line .mozilla/firefox/abc.default/prefs.js
  assert_line .mozilla/firefox/abc.default/storage
  refute_line --partial .cache
  refute_line --partial .config/omarchy
  refute_line --partial .local/state/omarchy
  refute_line --partial motanka-removed
  refute_line --partial .local/state/motanka
  refute_line Documents/report.odt
  refute_line --partial storage/permanent
  run grep -c $'^d\t.config$' "$C/paths"
  assert_output 1
}

@test "capture end adopts new session and app paths, observes desktop paths and records the rest as unplanned" {
  mkdir -p "$H/.config/hypr" "$H/.local/share"
  mk_capture_start
  a_moment
  put .config/hypr/extra.lua 'session'
  put .config/btop/themes/current.theme 'theme'
  put .local/share/hyprland/lastVersion '0.57.2'
  mkdir -p "$H/.agents/skills"
  ln -s /usr/share/omarchy/default/agents/skills/omarchy "$H/.agents/skills/omarchy"
  put .local/share/keyrings/login.keyring 'keyring'
  mkdir -p "$H/Downloads"
  put .config/mystery/a.conf
  put .config/mystery/sub/b.conf
  put .XCompose 'compose'
  put .config/omarchy/new.json 'ns'
  run mk_capture_end
  assert_success
  [[ ! -e $C/start && ! -e $C/paths ]]
  run entries
  assert_line "$(printf 'adopt\tsession\t.config/hypr/extra.lua\t-\t%s\t-' "$(sha "$H/.config/hypr/extra.lua")")"
  assert_line "$(printf 'adopt\tapp\t.config/btop/\t-\t-\t-')"
  assert_line "$(printf 'adopt\tapp\t.config/btop/themes/\t-\t-\t-')"
  assert_line --partial "$(printf 'adopt\tapp\t.config/btop/themes/current.theme\t-\t')"
  assert_line "$(printf 'adopt\tapp\t.local/share/hyprland/\t-\t-\t-')"
  assert_line --partial "$(printf 'adopt\tapp\t.local/share/hyprland/lastVersion\t-\t')"
  assert_line "$(printf 'adopt\tapp\t.agents/\t-\t-\t-')"
  assert_line "$(printf 'adopt\tapp\t.agents/skills/\t-\t-\t-')"
  assert_line --regexp $'^adopt\tapp\t\.agents/skills/omarchy\t-\tl:[0-9a-f]{64}\t-$'
  assert_line "$(printf 'observed\tdesktop\t.local/share/keyrings/\t-\t-\t-')"
  assert_line "$(printf 'observed\tdesktop\t.local/share/keyrings/login.keyring\t-\t%s\t-' "$(sha "$H/.local/share/keyrings/login.keyring")")"
  assert_line "$(printf 'observed\tdesktop\tDownloads/\t-\t-\t-')"
  assert_line "$(printf 'unplanned\t-\t.config/mystery\t-\t-\t-')"
  assert_line "$(printf 'unplanned\t-\t.XCompose\t-\t-\t-')"
  refute_line --partial .config/mystery/
  refute_line --partial .config/omarchy
  refute_line --partial $'\t.config/hypr/\t'
  # folders come before what they hold
  local a b
  a=$(grep -n $'\t.agents/\t' "$L" | cut -d: -f1)
  b=$(grep -n $'\t.agents/skills/omarchy\t' "$L" | cut -d: -f1)
  ((a < b))
}

@test "a path that existed at the start is never adopted, also when it was replaced by a rename" {
  put .config/btop/btop.conf 'mine'
  put .config/fcitx5/config 'mine too'
  put .local/share/hyprland/lastVersion '0.53'
  mk_capture_start
  a_moment
  printf 'replaced\n' >"$H/.config/btop/.btop.conf.tmp"
  mv -f "$H/.config/btop/.btop.conf.tmp" "$H/.config/btop/btop.conf"
  rm "$H/.config/fcitx5/config"
  printf 'recreated\n' >"$H/.config/fcitx5/config"
  # moved over with its old modification time
  printf '0.57\n' >"$BATS_TEST_TMPDIR/lastVersion"
  touch -d '2020-01-01' "$BATS_TEST_TMPDIR/lastVersion"
  mv -f "$BATS_TEST_TMPDIR/lastVersion" "$H/.local/share/hyprland/lastVersion"
  run mk_capture_end
  assert_success
  run entries
  refute_line --regexp '^adopt'
  assert_line "$(printf 'unplanned\t-\t.config/btop/btop.conf\t-\t-\t-')"
  assert_line "$(printf 'unplanned\t-\t.config/fcitx5/config\t-\t-\t-')"
  assert_line "$(printf 'unplanned\t-\t.local/share/hyprland/lastVersion\t-\t-\t-')"
}

@test "a changed path that is in the User_Ledger already gets no line; namespaced and desktop changes get none either" {
  printf 'setup\n' >"$SRC/hypr"
  mk_userledger_write session .config/hypr/hyprland.lua "$SRC/hypr"
  put .local/share/keyrings/login.keyring 'old'
  put .config/omarchy/current/theme.name 'old'
  mk_capture_start
  a_moment
  printf 'theme switch\n' >"$H/.config/hypr/hyprland.lua"
  printf 'new\n' >"$H/.local/share/keyrings/login.keyring"
  printf 'new\n' >"$H/.config/omarchy/current/theme.name"
  local before
  before=$(wc -l <"$L")
  run mk_capture_end
  assert_success
  assert_equal "$(wc -l <"$L")" "$before"
}

@test "a capture start without an end is ended by the next start, before the new listing" {
  mk_capture_start
  a_moment
  put .config/btop/themes/current.theme 'from the crashed session'
  # power loss: no end; the next login starts a capture again
  run mk_capture_start
  assert_success
  run entries
  assert_line --partial "$(printf 'adopt\tapp\t.config/btop/themes/current.theme\t-\t')"
  [[ -f $C/start ]]
  run grep -c $'\t.config/btop/themes/current.theme$' "$C/paths"
  assert_output 1
  a_moment
  run mk_capture_end
  assert_success
  run grep -c $'\t.config/btop/themes/current.theme\t' "$L"
  assert_output 1
}

@test "a new folder whose content the walk leaves out is walked whole at the end" {
  mkdir -p "$H/.hermes/profiles/work"
  mk_capture_start
  a_moment
  mkdir -p "$H/Work/tries/2026-11-13-x"
  put Work/tries/2026-11-13-x/notes.md
  mkdir -p "$H/.hermes/profiles/work/skills"
  ln -s /usr/share/omarchy/default/agents/skills/omarchy "$H/.hermes/profiles/work/skills/omarchy"
  run mk_capture_end
  assert_success
  run entries
  assert_line "$(printf 'adopt\tapp\tWork/\t-\t-\t-')"
  assert_line "$(printf 'adopt\tapp\tWork/tries/\t-\t-\t-')"
  assert_line "$(printf 'unplanned\t-\tWork/tries/2026-11-13-x\t-\t-\t-')"
  assert_line "$(printf 'adopt\tapp\t.hermes/profiles/work/skills/\t-\t-\t-')"
  assert_line --regexp $'^adopt\tapp\t\.hermes/profiles/work/skills/omarchy\t-\tl:'
}

@test "a new folder of no class that holds adopted paths is adopted; one with only desktop paths is observed" {
  mk_capture_start
  a_moment
  put .local/share/hyprland/lastVersion
  put .local/state/wireplumber/default-routes
  put .config/pulse/cookie
  run mk_capture_end
  assert_success
  run entries
  # .local and .local/state hold the User_Ledger: created and ledgered by
  # the capture start itself
  assert_line "$(printf 'create\tnamespaced\t.local/\t-\t-\t-')"
  refute_line "$(printf 'adopt\tapp\t.local/\t-\t-\t-')"
  assert_line "$(printf 'adopt\tapp\t.local/share/\t-\t-\t-')"
  assert_line "$(printf 'adopt\tapp\t.local/share/hyprland/\t-\t-\t-')"
  assert_line "$(printf 'observed\tdesktop\t.local/state/wireplumber/\t-\t-\t-')"
  assert_line "$(printf 'observed\tdesktop\t.config/\t-\t-\t-')"
  assert_line "$(printf 'observed\tdesktop\t.config/pulse/\t-\t-\t-')"
}

@test "the revert deletes unchanged adopted files, moves changed ones aside, removes empty adopted folders; plan equals apply" {
  mkdir -p "$H/.config"
  printf 'setup\n' >"$SRC/hypr"
  mk_userledger_write session .config/hypr/hyprland.lua "$SRC/hypr"
  rm "$H/.config/hypr/hyprland.lua"
  local before
  mk_capture_start
  a_moment
  put .config/btop/themes/current.theme 'theme'
  put .local/share/hyprland/lastVersion '0.57.2'
  mkdir -p "$H/.claude/skills"
  ln -s /nowhere/omarchy "$H/.claude/skills/omarchy"
  put .local/share/keyrings/login.keyring
  mk_capture_end
  # the user edits one adopted file; a file the user puts into an adopted
  # folder keeps that folder
  printf 'my edit\n' >>"$H/.local/share/hyprland/lastVersion"
  put .claude/skills/mine.md
  before=$(manifest)
  run mk_userledger_revert_plan
  assert_success
  local plan=$output
  assert_equal "$(manifest)" "$before"
  run mk_userledger_revert
  assert_success
  local applied=$output
  assert_line "$(printf 'deleted\t.config/btop/themes/current.theme')"
  assert_line "$(printf 'deleted\t.config/btop/themes/')"
  assert_line "$(printf 'deleted\t.config/btop/')"
  assert_line "$(printf 'deleted\t.claude/skills/omarchy')"
  assert_line "$(printf 'kept\t.claude/skills/')"
  assert_line --regexp $'^moved\t\.local/share/hyprland/lastVersion\t\.local/state/motanka-removed-[0-9-]+/\.local/share/hyprland/lastVersion$'
  assert_line "$(printf 'deleted\t.local/share/hyprland/')"
  assert_line "$(printf 'observed\t.local/share/keyrings/login.keyring')"
  [[ ! -e $H/.config/btop && ! -e $H/.local/share/hyprland && -f $H/.local/share/keyrings/login.keyring ]]
  [[ -f $H/.claude/skills/mine.md && ! -L $H/.claude/skills/omarchy ]]
  run cat "$H"/.local/state/motanka-removed-*/.local/share/hyprland/lastVersion
  assert_output $'0.57.2\nmy edit'
  # the plan takes the same decisions; it prints rmdir where the revert
  # prints deleted or kept for a folder
  assert_equal "$(printf '%s\n' "$plan" | grep -v $'^rmdir\t' | cut -f1,2)" \
    "$(printf '%s\n' "$applied" | grep -Ev $'^(deleted|kept)\t.*/$' | cut -f1,2)"
}

@test "--plan prints the lines capture end would write and changes nothing" {
  mk_capture_start
  a_moment
  put .config/btop/themes/current.theme 'theme'
  put .config/mystery/a.conf
  put .local/share/keyrings/login.keyring
  local before plan
  before=$(manifest)
  run mk_capture_end --plan
  assert_success
  plan=$output
  assert_equal "$(manifest)" "$before"
  [[ -f $C/start ]]
  local line
  local -a planned=()
  mapfile -t planned <<<"$plan"
  ((${#planned[@]} >= 4))
  for line in "${planned[@]}"; do
    _mk_ul_valid_line "$line" || fail "invalid planned line: $line"
  done
  mk_capture_end
  assert_equal "$(printf '%s\n' "$plan" | cut -f3-)" "$(tail -n "$(printf '%s\n' "$plan" | wc -l)" "$L" | cut -f3-)"
}

@test "without home-paths.tsv capture end adopts nothing and records new paths as unplanned" {
  mkdir -p "$H/.config"
  mk_capture_start
  a_moment
  put .config/btop/themes/current.theme
  export MOTANKA_HOME_PATHS="$BATS_TEST_TMPDIR/missing.tsv"
  run mk_capture_end
  assert_success
  assert_output --partial 'every path the Motanka session created is recorded as unplanned'
  run entries
  refute_line --regexp '^adopt'
  assert_line "$(printf 'unplanned\t-\t.config/btop\t-\t-\t-')"
}

@test "capture end without a pending capture changes nothing; a start without its listing is dropped" {
  run mk_capture_end
  assert_success
  [[ ! -e $H/.local ]]
  mk_capture_start
  rm "$C/paths"
  put .config/btop/themes/current.theme
  run mk_capture_end
  assert_success
  assert_output --partial 'has no listing of the paths at its start'
  [[ ! -e $C/start ]]
  run entries
  refute_line --regexp '^(adopt|unplanned)'
}

@test "names with a newline are skipped with a warning" {
  mk_capture_start
  a_moment
  mkdir -p "$H/.config/btop"
  printf 'x\n' >"$H/.config/btop/bad"$'\n'"name"
  run mk_capture_end
  assert_success
  assert_output --partial 'skipped 1 path(s) whose names have control characters'
}

@test "cost: capture start and end over 100 000 entries stay within their limits" {
  local i t0 t1 start_ms end_ms
  mkdir -p "$H/.local/share/big"
  (
    cd "$H/.local/share/big" || exit 1
    for ((i = 0; i < 100; i++)); do
      mkdir "d$i"
      (cd "d$i" && touch f{0..999})
    done
  )
  put .config/hypr/hyprland.lua
  t0=$EPOCHREALTIME
  mk_capture_start
  t1=$EPOCHREALTIME
  start_ms=$(((10#${t1//[!0-9]/} - 10#${t0//[!0-9]/}) / 1000))
  run wc -l <"$C/paths"
  ((output > 100000))
  put .config/btop/themes/current.theme
  t0=$EPOCHREALTIME
  mk_capture_end
  t1=$EPOCHREALTIME
  end_ms=$(((10#${t1//[!0-9]/} - 10#${t0//[!0-9]/}) / 1000))
  printf '# capture start %d ms, capture end %d ms over %s entries\n' "$start_ms" "$end_ms" "$output" >&3
  ((start_ms <= ${MK_CAPTURE_START_MS:-1500})) || fail "capture start took $start_ms ms"
  ((end_ms <= ${MK_CAPTURE_END_MS:-2500})) || fail "capture end took $end_ms ms"
  run grep -c $'\tadopt\t' "$L"
  assert_output 3
}
