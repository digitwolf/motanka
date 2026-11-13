#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2119 # mk_userledger_revert takes only optional flags
# shellcheck disable=SC2016 # fixture scripts are single-quoted on purpose
# Unit tests for src/libexec/user-setup (tasks 17.1 and 17.2; requirements
# 6.1-6.5, 6.7-6.11): Home_Path_Class handling with the real
# compat/home-paths.tsv, Shared_Files left byte for byte, existing app
# configs kept, links, the dconf database, the Hyprland fragment, migration
# markers, the Call_Inventory gate for Upstream per-user scripts, the lock
# and the guards, the plan, resuming after an interruption at every step,
# and the post-setup scan with planted unplanned writes.
#
# Everything lives under BATS_TEST_TMPDIR: a fake root (MOTANKA_ROOT) with a
# small Upstream tree in /opt/motanka/share/omarchy, a home folder with
# Shared_Files, and stubs for dconf, systemd-cat and systemd-detect-virt.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if ((EUID == 0)); then
    skip "per-user setup tests must not run as root"
  fi
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
  US=$REPO/src/libexec/user-setup
  T=$BATS_TEST_TMPDIR
  export MOTANKA_ROOT=$T/root
  UP=$MOTANKA_ROOT/opt/motanka/share/omarchy
  DATA=$MOTANKA_ROOT/opt/motanka/share/motanka
  STUBS=$T/stubs
  mkdir -p "$MOTANKA_ROOT/etc" "$MOTANKA_ROOT/usr/share" "$MOTANKA_ROOT/opt/motanka/bin" "$DATA/hypr" "$STUBS"
  make_stubs
  make_upstream
  ln -s "$UP" "$MOTANKA_ROOT/usr/share/omarchy"
  cp "$REPO/compat/home-paths.tsv" "$DATA/home-paths.tsv"
  cp "$REPO/packaging/motanka-core/hypr/motanka-session.lua" "$DATA/hypr/"
  write_user_scripts
  printf '%s\n' \
    $'install/user/blocked.sh\t2\tprivileged\tsudo true' \
    $'install/user/homewrite.sh\t2\thome-write\t~/Work' \
    $'install/user/nsonly.sh\t2\thome-write\t~/.local/state/omarchy/ns.txt [namespaced]' \
    $'install/user/nsonly.sh\t3\tomarchy-path\t$OMARCHY_PATH/default' >"$DATA/inventory.tsv"
  printf '#!/bin/bash\necho fixture-wrapper\n' >"$MOTANKA_ROOT/opt/motanka/bin/omarchy-fixture-cmd"
  chmod +x "$MOTANKA_ROOT/opt/motanka/bin/omarchy-fixture-cmd"
  export HOME=$T/home
  make_home "$HOME"
  export XDG_RUNTIME_DIR=$T/run
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export PATH="$STUBS:$PATH"
  export NO_COLOR=1
  unset MK_HOME MOTANKA_SETUP_INTERRUPT OMARCHY_PATH DCONF_PROFILE FAKE_VIRT FAKE_DCONF_FAIL
  unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME
}

make_stubs() {
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_VIRT:-kvm}"\n[ "${FAKE_VIRT:-kvm}" != none ]\n' >"$STUBS/systemd-detect-virt"
  {
    printf '#!/bin/sh\n'
    printf 'printf "dconf %%s\\n" "$*" >>%q\n' "$T/dconf.calls"
    cat <<'EOF'
[ -z "${FAKE_DCONF_FAIL:-}" ] || { echo "dconf: failure" >&2; exit 1; }
[ "$1" = compile ] && [ -d "$3" ] || exit 2
printf 'GVariant database fixture\n' >"$2"
EOF
  } >"$STUBS/dconf"
  chmod +x "$STUBS"/*
}

# write_file <path> <content>
write_file() {
  mkdir -p "${1%/*}"
  printf '%s\n' "$2" >"$1"
}

# write_script <path> <body>
write_script() {
  mkdir -p "${1%/*}"
  printf '#!/bin/bash\n%s\n' "$2" >"$1"
  chmod +x "$1"
}

make_upstream() {
  write_file "$UP/config/hypr/hyprland.lua" '-- upstream hyprland.lua'
  write_file "$UP/config/hypr/autostart.lua" '-- upstream autostart.lua'
  ln -s hyprland.lua "$UP/config/hypr/link.lua"
  write_file "$UP/config/alacritty/alacritty.toml" '# upstream alacritty'
  write_file "$UP/config/btop/btop.conf" '# upstream btop'
  write_file "$UP/config/git/config" '[upstream]'
  write_file "$UP/config/autostart/print-applet.desktop" '[Desktop Entry]'
  write_file "$UP/config/wireplumber/wireplumber.conf.d/a.conf" 'upstream'
  write_file "$UP/config/omarchy/shell.json" '{}'
  write_file "$UP/config/starship.toml" '# upstream starship'
  write_file "$UP/migrations/1700000000.sh" 'echo one'
  write_file "$UP/migrations/1700000001.sh" 'echo two'
  write_file "$UP/version" '4.0.0.alpha'
  write_script "$UP/install/user/ok.sh" 'mkdir -p "$HOME/.local/state/omarchy"
printf "omarchy=%s\nwrapper=%s\ncontext=%s\n" "$OMARCHY_PATH" "$(command -v omarchy-fixture-cmd)" "$OMARCHY_SETUP_CONTEXT" >"$HOME/.local/state/omarchy/ok.txt"
if read -r _; then echo stdin-open >>"$HOME/.local/state/omarchy/ok.txt"; fi'
  write_script "$UP/install/user/blocked.sh" 'sudo true
touch "$HOME/.config/blocked.txt"'
  write_script "$UP/install/user/homewrite.sh" 'mkdir -p "$HOME/Work"'
  write_script "$UP/install/user/nsonly.sh" 'mkdir -p "$HOME/.local/state/omarchy"
touch "$HOME/.local/state/omarchy/ns.txt"'
  write_script "$UP/install/user/skipped.sh" 'touch "$HOME/.config/skipped.txt"'
  write_script "$UP/install/user/fails.sh" 'exit 3'
}

# write_user_scripts [extra line]: the fixture user-scripts.tsv.
write_user_scripts() {
  {
    printf '# fixture\n'
    printf 'install/user/ok.sh\trun\tfixture\n'
    printf 'install/user/blocked.sh\trun\tfixture\n'
    printf 'install/user/homewrite.sh\trun\tfixture\n'
    printf 'install/user/nsonly.sh\trun\tfixture\n'
    printf 'install/user/skipped.sh\tskip\tthe fixture reason\n'
    printf 'install/user/fails.sh\trun\tfixture\n'
    if (($# > 0)); then
      printf '%s\n' "$1"
    fi
  } >"$DATA/user-scripts.tsv"
}

# make_home <dir>: a home folder like the multiuser image's: Shared_Files,
# an app config of the user's own and an older Hyprland config.
make_home() {
  local h=$1
  mkdir -p "$h"
  write_file "$h/.bashrc" '# my bashrc'
  write_file "$h/.profile" '# my profile'
  write_file "$h/.gitconfig" '[user] name = me'
  write_file "$h/.config/gtk-3.0/settings.ini" '[Settings]'
  write_file "$h/.config/gtk-4.0/settings.ini" '[Settings]'
  write_file "$h/.config/mimeapps.list" '[Default Applications]'
  write_file "$h/.config/btop/btop.conf" '# my btop'
  write_file "$h/.config/hypr/hyprland.lua" '-- my old hyprland.lua'
  touch -d '2026-01-01 00:00:00' "$h/.bashrc" "$h/.profile" "$h/.gitconfig" \
    "$h/.config/gtk-3.0/settings.ini" "$h/.config/gtk-4.0/settings.ini" \
    "$h/.config/mimeapps.list" "$h/.config/btop/btop.conf" "$h/.config/hypr/hyprland.lua"
}

ledger() {
  cut -f3- "$HOME/.local/state/motanka/ledger"
}

sha() {
  sha256sum <"$1" | cut -c1-64
}

# manifest <home> [exclude...]: type, mode, link target and content hash of
# every path, without the given relative folders.
manifest() {
  local h=$1 e
  shift
  local -a prune=()
  for e in "$@"; do
    prune+=(-path "./$e" -prune -o)
  done
  (
    cd "$h" || exit 1
    find . -mindepth 1 "${prune[@]}" -printf '%P\t%y\t%m\t%l\n' | LC_ALL=C sort
    find . "${prune[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

shared_sums() {
  (cd "$HOME" && sha256sum .bashrc .profile .gitconfig .config/gtk-3.0/settings.ini \
    .config/gtk-4.0/settings.ini .config/mimeapps.list)
}

# --- 17.1: classes, Shared_Files, links, dconf -------------------------------

@test "first login writes the planned targets through the ledger and ends with setup-end" {
  local old_sha id
  old_sha=$(sha "$HOME/.config/hypr/hyprland.lua")
  run bash "$US"
  assert_success
  run ledger
  assert_line --index 3 $'setup-begin\t-\t-\t-\t-\t-'
  assert_equal "${lines[-1]}" $'setup-end\t-\t-\t-\t-\t-'
  cmp "$UP/config/hypr/hyprland.lua" "$HOME/.config/hypr/hyprland.lua"
  cmp "$UP/config/hypr/autostart.lua" "$HOME/.config/hypr/autostart.lua"
  cmp "$UP/config/alacritty/alacritty.toml" "$HOME/.config/alacritty/alacritty.toml"
  cmp "$UP/config/starship.toml" "$HOME/.config/starship.toml"
  cmp "$UP/config/omarchy/shell.json" "$HOME/.config/omarchy/shell.json"
  run ledger
  assert_line "$(printf 'create\tsession\t.config/hypr/autostart.lua\t-\t%s\t-' "$(sha "$UP/config/hypr/autostart.lua")")"
  assert_line "$(printf 'create\tapp\t.config/alacritty/alacritty.toml\t-\t%s\t-' "$(sha "$UP/config/alacritty/alacritty.toml")")"
  assert_line "$(printf 'create\tnamespaced\t.config/omarchy/shell.json\t-\t%s\t-' "$(sha "$UP/config/omarchy/shell.json")")"
  # The older hyprland.lua was backed up before it was replaced (6.3).
  id=$(ledger | awk -F'\t' '$1 == "replace" && $3 == ".config/hypr/hyprland.lua" { print $6 }')
  [[ -n $id && $id != - ]]
  assert_equal "$(sha "$HOME/.local/state/motanka/backups/$id/.config/hypr/hyprland.lua")" "$old_sha"
  run ledger
  assert_line "$(printf 'replace\tsession\t.config/hypr/hyprland.lua\t%s\t%s\t%s' "$old_sha" "$(sha "$UP/config/hypr/hyprland.lua")" "$id")"
}

@test "Shared_Files stay byte for byte and shared Upstream targets are not written" {
  local before
  before=$(shared_sums)
  run bash "$US"
  assert_success
  assert_equal "$(shared_sums)" "$before"
  [[ ! -e $HOME/.config/git && ! -e $HOME/.config/autostart && ! -e $HOME/.config/wireplumber ]]
  run ledger
  refute_line --partial $'\tshared\t'
  refute_line --partial $'\t.bashrc\t'
}

@test "an existing app config is kept with a notice; an absent one is written" {
  run bash "$US"
  assert_success
  assert_output --partial 'keeping your ~/.config/btop/btop.conf'
  assert_equal "$(cat "$HOME/.config/btop/btop.conf")" '# my btop'
  run ledger
  refute_line --partial '.config/btop/'
  [[ -f $HOME/.config/alacritty/alacritty.toml ]]
}

@test "a link in Upstream's config tree becomes a ledgered link" {
  run bash "$US"
  assert_success
  [[ -L $HOME/.config/hypr/link.lua ]]
  assert_equal "$(readlink "$HOME/.config/hypr/link.lua")" hyprland.lua
  run ledger
  assert_line --regexp $'^symlink\tsession\t\\.config/hypr/link\\.lua\t-\tl:[0-9a-f]{64}\t-$'
}

@test "the dconf database ~/.config/dconf/motanka is compiled and ledgered" {
  run bash "$US"
  assert_success
  assert_equal "$(cat "$HOME/.config/dconf/motanka")" 'GVariant database fixture'
  run cat "$T/dconf.calls"
  assert_output --regexp '^dconf compile .*/\.local/state/motanka/dconf\.[^/]+/motanka .*/keyfiles$'
  run ledger
  assert_line "$(printf 'create\tnamespaced\t.config/dconf/\t-\t-\t-')"
  assert_line "$(printf 'create\tnamespaced\t.config/dconf/motanka\t-\t%s\t-' "$(sha "$HOME/.config/dconf/motanka")")"
  run find "$HOME/.local/state/motanka" -maxdepth 1 -name 'dconf.*'
  assert_output ''
}

@test "an existing dconf database is kept; a failing dconf compile stops setup before setup-end" {
  write_file "$HOME/.config/dconf/motanka" 'my settings'
  run bash "$US"
  assert_success
  assert_equal "$(cat "$HOME/.config/dconf/motanka")" 'my settings'
  run ledger
  refute_line --partial '.config/dconf/motanka'

  export HOME=$T/home2
  make_home "$HOME"
  FAKE_DCONF_FAIL=1 run bash "$US"
  assert_failure 1
  assert_output --partial 'dconf compile could not create the database'
  assert_output --partial 'resumes at the next login'
  run ledger
  refute_line --partial setup-end
  [[ ! -e $HOME/.config/dconf/motanka ]]
}

@test "the Hyprland fragment and the migration markers are written" {
  run bash "$US"
  assert_success
  cmp "$REPO/packaging/motanka-core/hypr/motanka-session.lua" \
    "$HOME/.local/state/omarchy/toggles/hypr/motanka-session.lua"
  [[ -f $HOME/.local/state/omarchy/migrations/1700000000.sh && ! -s $HOME/.local/state/omarchy/migrations/1700000000.sh ]]
  [[ -f $HOME/.local/state/omarchy/migrations/1700000001.sh ]]
  run ledger
  assert_line --regexp $'^create\tsession\t\\.local/state/omarchy/toggles/hypr/motanka-session\\.lua\t-\t[0-9a-f]{64}\t-$'
  assert_line --regexp $'^create\tnamespaced\t\\.local/state/omarchy/migrations/1700000000\\.sh\t-\t[0-9a-f]{64}\t-$'
}

@test "the fragment puts the Motanka desktop names back only in the Motanka session" {
  local f=$REPO/packaging/motanka-core/hypr/motanka-session.lua
  run grep -c '^if os.getenv("DCONF_PROFILE") == "motanka" then$' "$f"
  assert_output 1
  run grep -E '^  hl\.env\(' "$f"
  assert_line '  hl.env("XDG_CURRENT_DESKTOP", "Motanka:Hyprland")'
  assert_line '  hl.env("XDG_SESSION_DESKTOP", "motanka")'
}

@test "only paths in the ledger or under a Namespaced_Path change (6.4)" {
  local before after ledgered line p n=0
  before=$(manifest "$HOME" | LC_ALL=C sort)
  run bash "$US"
  assert_success
  after=$(manifest "$HOME" .local/state/motanka | LC_ALL=C sort)
  ledgered=$(ledger | cut -f3 | sed 's|/$||')
  while IFS= read -r line; do
    if [[ $line =~ ^[0-9a-f]{64}\ \ \./(.*)$ ]]; then
      p=${BASH_REMATCH[1]}
    else
      p=${line%%$'\t'*}
    fi
    n=$((n + 1))
    case $p in
      .local/state/motanka | .config/omarchy | .config/omarchy/* | .local/state/omarchy | .local/state/omarchy/*) continue ;;
    esac
    if ! grep -qxF -- "$p" <<<"$ledgered"; then
      fail "the path ~/$p changed but is neither ledgered nor namespaced"
    fi
  done < <(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  ((n > 10))
}

@test "a target without a Home_Path_Class is skipped with a warning" {
  write_file "$UP/config/unknown-app/settings" 'x'
  run bash "$US"
  assert_success
  assert_output --partial 'not written: ~/.config/unknown-app/settings has no Home_Path_Class'
  [[ ! -e $HOME/.config/unknown-app ]]
}

@test "a second login finds setup complete and changes nothing" {
  run bash "$US"
  assert_success
  cp "$HOME/.local/state/motanka/ledger" "$T/ledger.first"
  run bash "$US"
  assert_success
  cmp "$T/ledger.first" "$HOME/.local/state/motanka/ledger"
}

# --- Upstream per-user scripts -------------------------------------------------

@test "Upstream scripts run only when listed as run and clean in the Call_Inventory" {
  run bash "$US"
  assert_success
  run cat "$HOME/.local/state/omarchy/ok.txt"
  assert_line "omarchy=$MOTANKA_ROOT/usr/share/omarchy"
  assert_line "wrapper=$MOTANKA_ROOT/opt/motanka/bin/omarchy-fixture-cmd"
  assert_line 'context=runtime'
  refute_line stdin-open
  [[ -f $HOME/.local/state/omarchy/ns.txt ]]
  [[ ! -e $HOME/.config/blocked.txt && ! -e $HOME/Work && ! -e $HOME/.config/skipped.txt ]]
  run cat "$HOME/.local/state/motanka/setup-scripts"
  assert_line --regexp $'^install/user/ok\\.sh\tok\t0\t'
  assert_line --regexp $'^install/user/nsonly\\.sh\tok\t0\t'
  assert_line --regexp $'^install/user/fails\\.sh\tfailed\t3\t'
  refute_line --partial blocked.sh
  refute_line --partial homewrite.sh
  refute_line --partial skipped.sh
}

@test "a blocked or failing Upstream script is reported and setup still completes" {
  run bash "$US"
  assert_success
  assert_output --partial "not running Upstream's install/user/blocked.sh: the Call_Inventory has 1 finding(s)"
  assert_output --partial "not running Upstream's install/user/homewrite.sh"
  assert_output --partial "Upstream's install/user/fails.sh failed (exit 3)"
  run ledger
  assert_equal "${lines[-1]}" $'setup-end\t-\t-\t-\t-\t-'
}

@test "without the Call_Inventory no Upstream script runs" {
  rm "$DATA/inventory.tsv"
  run bash "$US"
  assert_success
  [[ ! -e $HOME/.local/state/omarchy/ok.txt ]]
  assert_output --partial 'no Call_Inventory at'
}

# --- lock and guards -------------------------------------------------------------

@test "a held per-user lock exits 9 without writing" {
  local fd
  exec {fd}>>"$XDG_RUNTIME_DIR/motanka.lock"
  flock -n "$fd"
  run bash "$US"
  exec {fd}>&-
  assert_failure 9
  assert_output --partial 'is held'
  [[ ! -e $HOME/.local/state/motanka ]]
}

@test "a Protected_Host exits 7 without writing" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  run bash "$US"
  assert_failure 7
  [[ ! -e $HOME/.local/state/motanka && ! -e $HOME/.config/alacritty ]]
}

@test "a Dev_Build outside a VM exits 7 without writing" {
  touch "$DATA/DEV_BUILD"
  FAKE_VIRT=none run bash "$US"
  assert_failure 7
  [[ ! -e $HOME/.local/state/motanka ]]
  FAKE_VIRT=kvm run bash "$US"
  assert_success
}

@test "no XDG_RUNTIME_DIR is an error before any write" {
  unset XDG_RUNTIME_DIR
  run bash "$US"
  assert_failure 1
  [[ ! -e $HOME/.local/state/motanka ]]
}

# --- plan ------------------------------------------------------------------------

@test "--plan prints every target with its class and changes nothing" {
  local before
  before=$(manifest "$HOME")
  run bash "$US" --plan
  assert_success
  assert_line $'write\tsession\t.config/hypr/hyprland.lua'
  assert_line $'write-if-absent\tapp\t.config/btop/btop.conf'
  assert_line $'skip\tshared\t.config/git/config'
  assert_line $'write\tnamespaced\t.config/omarchy/shell.json'
  assert_line $'write\tsession\t.local/state/omarchy/toggles/hypr/motanka-session.lua'
  assert_line $'write\tnamespaced\t.local/state/omarchy/migrations/1700000000.sh'
  assert_line $'write\tnamespaced\t.config/dconf/motanka'
  assert_equal "$(manifest "$HOME")" "$before"
}

@test "--plan fails on an unclassified target" {
  write_file "$T/up/config/unknown-app/x" 'x'
  run bash "$US" --plan --upstream "$T/up" --home-paths "$REPO/compat/home-paths.tsv"
  assert_failure 1
  assert_line $'unclassified\t-\t.config/unknown-app/x'
}

@test "every target of the cached Upstream tree has a Home_Path_Class" {
  local cached=$REPO/.cache/upstream/omarchy
  if [[ ! -d $cached/config ]]; then
    skip "no cached Upstream tree in this copy of the repository (the motanka-core build runs the same check)"
  fi
  run bash "$US" --plan --upstream "$cached" --home-paths "$REPO/compat/home-paths.tsv"
  assert_success
  refute_line --partial unclassified
}

@test "compat/user-scripts.tsv lists every per-user script of the cached Upstream tree" {
  local cached=$REPO/.cache/upstream/omarchy/install/user/all.sh s
  if [[ ! -f $cached ]]; then
    skip "no cached Upstream tree in this copy of the repository (the motanka-core build runs the same check)"
  fi
  while IFS= read -r s; do
    run awk -F'\t' -v s="$s" '$1 == s { found = 1 } END { exit !found }' "$REPO/compat/user-scripts.tsv"
    assert_success
  done < <(sed -n 's|^run_logged "\$OMARCHY_INSTALL/\(user/[^"]*\)".*|install/\1|p' "$cached")
}

@test "compat/user-scripts.tsv runs only vm-no-animations.sh and platform-setup.sh, both clean in the inventory" {
  local inv s
  inv=$REPO/compat/inventory/$(awk -F'\t' '$1 == "stable" { print $2 }' "$REPO/upstream.pin").tsv
  run awk -F'\t' '$0 !~ /^#/ && $2 == "run" { print $1 }' "$REPO/compat/user-scripts.tsv"
  assert_output $'install/user/hardware/vm-no-animations.sh\ninstall/user/platform-setup.sh'
  for s in install/user/hardware/vm-no-animations.sh install/user/platform-setup.sh; do
    run awk -F'\t' -v f="$s" '$1 == f && ($3 ~ /^(arch-tool|arch-path|privileged|user-unit)$/ || ($3 == "home-write" && index($4, "[namespaced]") == 0))' "$inv"
    assert_output ''
  done
  run awk -F'\t' '$0 !~ /^#/ && NF >= 2 && $2 != "run" && $2 != "skip"' "$REPO/compat/user-scripts.tsv"
  assert_output ''
}

# --- 17.2: resume after interruption ---------------------------------------------

@test "interrupted at every step, the next login resumes and ends like an uninterrupted run" {
  local ref point n
  export HOME=$T/ref
  make_home "$HOME"
  run bash "$US"
  assert_success
  ref=$(manifest "$HOME" .local/state/motanka)
  n=0
  for point in begin target:1 target:4 target:9 targets dconf scripts scan; do
    n=$((n + 1))
    export HOME=$T/home-int-$n
    make_home "$HOME"
    MOTANKA_SETUP_INTERRUPT=$point run bash "$US"
    if ((status != 137)); then
      fail "interruption at $point: exit $status, expected 137 (SIGKILL)"
    fi
    run ledger
    refute_line --partial setup-end
    run bash "$US"
    assert_success
    assert_output --partial 'resuming per-user setup'
    run ledger
    assert_equal "${lines[-1]}" $'setup-end\t-\t-\t-\t-\t-'
    refute_line --partial unplanned
    assert_equal "$(ledger | grep -c '^setup-begin')" 2
    assert_equal "$(manifest "$HOME" .local/state/motanka)" "$ref"
  done
}

@test "a ledger line whose rename never happened is written again on resume" {
  local up_sha old_sha
  MOTANKA_SETUP_INTERRUPT=begin run bash "$US"
  assert_equal "$status" 137
  up_sha=$(sha "$UP/config/hypr/autostart.lua")
  old_sha=$(sha "$HOME/.config/hypr/hyprland.lua")
  # The two lines a run killed between ledger line and rename leaves.
  printf '2026-11-13T09:00:00Z\t20261113T090000Z-abcdef\tcreate\tsession\t.config/hypr/autostart.lua\t-\t%s\t-\n' \
    "$up_sha" >>"$HOME/.local/state/motanka/ledger"
  printf '2026-11-13T09:00:00Z\t20261113T090000Z-abcdef\treplace\tsession\t.config/hypr/hyprland.lua\t%s\t%s\t20261113T090000Z-abcd\n' \
    "$old_sha" "$(sha "$UP/config/hypr/hyprland.lua")" >>"$HOME/.local/state/motanka/ledger"
  run bash "$US"
  assert_success
  cmp "$UP/config/hypr/autostart.lua" "$HOME/.config/hypr/autostart.lua"
  cmp "$UP/config/hypr/hyprland.lua" "$HOME/.config/hypr/hyprland.lua"
  assert_equal "$(ledger | awk -F'\t' '$3 == ".config/hypr/autostart.lua"' | wc -l)" 2
  assert_equal "$(ledger | awk -F'\t' '$1 == "replace" && $3 == ".config/hypr/hyprland.lua"' | wc -l)" 2
}

@test "a ledgered target the user changed before the resume is left alone" {
  MOTANKA_SETUP_INTERRUPT=targets run bash "$US"
  assert_equal "$status" 137
  printf 'my edit\n' >"$HOME/.config/alacritty/alacritty.toml"
  run bash "$US"
  assert_success
  assert_output --partial 'per-user setup leaves ~/.config/alacritty/alacritty.toml as it is'
  assert_equal "$(cat "$HOME/.config/alacritty/alacritty.toml")" 'my edit'
}

@test "after setup, removing the Namespaced_Paths and walking the ledger back restores the home folder" {
  local before
  before=$(manifest "$HOME")
  run bash "$US"
  assert_success
  rm -rf "$HOME/.config/omarchy" "$HOME/.local/state/omarchy" "$HOME/.config/dconf/motanka"
  (
    # shellcheck source=../../src/lib/common.sh
    source "$REPO/src/lib/common.sh"
    # shellcheck source=../../src/lib/userledger.sh
    source "$REPO/src/lib/userledger.sh"
    mk_userledger_revert >/dev/null
  )
  assert_equal "$(manifest "$HOME")" "$before"
}

# --- 17.2: the post-setup scan ----------------------------------------------------

@test "a planted unplanned write is ledgered as unplanned; namespaced and older files are not" {
  write_script "$UP/install/user/plants.sh" 'printf "x\n" >"$HOME/.config/planted.conf"
printf "x\n" >"$HOME/.planted-dotfile"
mkdir -p "$HOME/.config/planted-dir" "$HOME/.agents/skills"
ln -s /nowhere "$HOME/.agents/skills/planted-link"
touch "$HOME/.config/gtk-3.0/settings.ini"
mkdir -p "$HOME/.local/state/omarchy" && touch "$HOME/.local/state/omarchy/planted-namespaced"
mkdir -p "$HOME/.cache/x" && touch "$HOME/.cache/x/planted-cache"'
  write_user_scripts $'install/user/plants.sh\trun\tfixture'
  write_file "$HOME/.config/old-but-untouched.conf" 'old'
  touch -d '2026-01-01 00:00:00' "$HOME/.config/old-but-untouched.conf"
  run bash "$US"
  assert_success
  assert_output --partial "unplanned change: ~/.config/planted.conf changed during per-user setup"
  run ledger
  assert_line "$(printf 'unplanned\t-\t.config/planted.conf\t-\t%s\t-' "$(sha "$HOME/.config/planted.conf")")"
  assert_line "$(printf 'unplanned\t-\t.planted-dotfile\t-\t%s\t-' "$(sha "$HOME/.planted-dotfile")")"
  assert_line $'unplanned\t-\t.config/planted-dir\t-\t-\t-'
  assert_line --regexp $'^unplanned\t-\t\\.agents/skills/planted-link\t-\tl:[0-9a-f]{64}\t-$'
  assert_line --regexp $'^unplanned\t-\t\\.config/gtk-3\\.0/settings\\.ini\t-\t[0-9a-f]{64}\t-$'
  refute_line --partial planted-namespaced
  refute_line --partial planted-cache
  refute_line --partial old-but-untouched
  refute_line --partial $'unplanned\t-\t.config/hypr/'
  assert_equal "${lines[-1]}" $'setup-end\t-\t-\t-\t-\t-'
}

@test "the scan without planted writes ledgers nothing as unplanned" {
  run bash "$US"
  assert_success
  run ledger
  refute_line --partial unplanned
}

@test "an unplanned write of an interrupted run is caught by the resumed scan" {
  write_script "$UP/install/user/plants.sh" 'printf "x\n" >"$HOME/.config/planted.conf"'
  write_user_scripts $'install/user/plants.sh\trun\tfixture'
  MOTANKA_SETUP_INTERRUPT=scripts run bash "$US"
  assert_equal "$status" 137
  run bash "$US"
  assert_success
  run ledger
  assert_line --partial $'unplanned\t-\t.config/planted.conf\t'
  assert_equal "$(ledger | grep -c $'^unplanned\t')" 1
}

# --- the program -------------------------------------------------------------------

@test "user-setup passes bash -n and has a usage" {
  run bash -n "$US"
  assert_success
  run bash "$US" --help
  assert_success
  assert_output --partial 'usage: user-setup'
  run bash "$US" --bogus
  assert_failure 2
}
