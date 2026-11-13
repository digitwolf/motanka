# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # variables and functions are used by the tests that load this file
# Shared setup of the snapshot, Updater and rollback unit tests
# (test/unit/{snapshot,update,rollback}.bats). Everything lives under
# BATS_TEST_TMPDIR: a fake root (MOTANKA_ROOT) with os-release, the apt
# source, upstream.pin, a small vendored Upstream tree, apt's cache and the
# lock folder; the test user in $MOTANKA_ROOT/etc/passwd with a home folder
# under $MOTANKA_ROOT/home. apt-get, apt-mark, dpkg-query, dpkg-deb and dpkg
# are the model in fixtures/update/fakeapt.py; id (uid 0 for "id -u"),
# setpriv (drops its options), snapper, systemd-cat and systemd-detect-virt
# are stubs on PATH, and the migration runner
# ($MOTANKA_ROOT/opt/motanka/libexec/motanka/run-upstream) is a stub that
# logs its call. Nothing runs as root.

# update_setup: call from setup().
update_setup() {
  if ((EUID == 0)); then
    skip "the Updater tests must not run as root"
  fi
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
  MOTANKA="$REPO/src/motanka"
  FIX="$REPO/test/unit/fixtures/update"
  T=$BATS_TEST_TMPDIR
  export MOTANKA_ROOT=$T/root
  ME=$(id -un)
  MYUID=$(id -u)
  MYGID=$(id -g)
  H=$MOTANKA_ROOT/home/$ME
  mkdir -p "$MOTANKA_ROOT/etc/apt/sources.list.d" "$MOTANKA_ROOT/run/lock" "$MOTANKA_ROOT/run/user/$MYUID" \
    "$MOTANKA_ROOT/var/lib/motanka" "$MOTANKA_ROOT/var/cache/apt/archives" "$H"
  printf 'root:x:0:0:root:/root:/bin/bash\n%s:x:%s:%s:Test user:/home/%s:/bin/bash\n' \
    "$ME" "$MYUID" "$MYGID" "$ME" >"$MOTANKA_ROOT/etc/passwd"
  printf 'NAME="Ubuntu"\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\nID=ubuntu\n' \
    >"$MOTANKA_ROOT/etc/os-release"
  write_sources resolute
  mkdir -p "$MOTANKA_ROOT/opt/motanka/share/motanka" "$MOTANKA_ROOT/opt/motanka/share/omarchy/bin" \
    "$MOTANKA_ROOT/opt/motanka/share/omarchy/migrations" "$MOTANKA_ROOT/opt/motanka/libexec/motanka"
  printf 'stable\t%s\tv4.5.0\t%s\nedge\t%s\t-\t%s\n' "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" \
    "$(printf 'c%.0s' {1..40})" "$(printf 'b%.0s' {1..64})" >"$MOTANKA_ROOT/opt/motanka/share/motanka/upstream.pin"
  export FAKE_STATE=$T/state
  mkdir -p "$FAKE_STATE"
  export FAKE_DB=$FAKE_STATE/db FAKE_REPO=$FAKE_STATE/repo FAKE_LOG=$FAKE_STATE/calls.log
  : >"$FAKE_LOG"
  : >"$FAKE_DB"
  : >"$FAKE_REPO"
  unset SUDO_USER PKEXEC_UID FAKE_APT_FAIL NO_COLOR MOTANKA_OMARCHY_PATH OMARCHY_PATH MK_HOME
  export SUDO_USER=$ME
  LEDGER=$MOTANKA_ROOT/var/lib/motanka/ledger
  SNAPS=$MOTANKA_ROOT/var/lib/motanka/snapshots
  update_stubs
  write_runner
}

update_stubs() {
  local t
  STUBS=$T/stubs
  mkdir -p "$STUBS"
  for t in apt-get apt-mark dpkg-query dpkg-deb dpkg; do
    printf '#!/bin/sh\nexec python3 %q %s "$@"\n' "$FIX/fakeapt.py" "$t" >"$STUBS/$t"
  done
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  printf '#!/bin/sh\necho kvm\n' >"$STUBS/systemd-detect-virt"
  cat >"$STUBS/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ] && [ $# -eq 1 ]; then
  echo 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  {
    printf '#!/bin/sh\nlog=%q\n' "$FAKE_LOG"
    cat <<'EOF'
printf 'setpriv %s\n' "$*" >>"$log"
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then
    shift
    break
  fi
  shift
done
exec "$@"
EOF
  } >"$STUBS/setpriv"
  {
    printf '#!/bin/sh\nlog=%q\nstate=%q\n' "$FAKE_LOG" "$FAKE_STATE"
    cat <<'EOF'
printf 'snapper %s\n' "$*" >>"$log"
[ -f "$state/snapper-config" ] || exit 1
case " $* " in
  *" list-configs "*) printf '%s,/\n' "$(cat "$state/snapper-config")" ;;
  *" --type pre "*) echo 42 ;;
esac
exit 0
EOF
  } >"$STUBS/snapper"
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
}

# write_runner: the migration runner stub. It runs under "env -i", so its
# paths are written in. $FAKE_STATE/pending lists pending migrations;
# $FAKE_STATE/migrate-rc is its exit code.
write_runner() {
  local f=$MOTANKA_ROOT/opt/motanka/libexec/motanka/run-upstream
  {
    printf '#!/bin/bash\nlog=%q\nstate=%q\n' "$FAKE_LOG" "$FAKE_STATE"
    cat <<'EOF'
printf 'runner %s HOME=%s XDG_RUNTIME_DIR=%s UNATTENDED=%s\n' "$*" "$HOME" "${XDG_RUNTIME_DIR:-}" \
  "${OMARCHY_UPDATE_UNATTENDED:-}" >>"$log"
if [[ ${2:-} == --pending ]]; then
  if [[ -s $state/pending ]]; then
    cat "$state/pending"
    exit 0
  fi
  exit 1
fi
rc=$(cat "$state/migrate-rc" 2>/dev/null || echo 0)
if ((rc != 0)); then
  echo "motanka migrate: error: migration 1799999903 failed (exit 3)" >&2
fi
exit "$rc"
EOF
  } >"$f"
  chmod +x "$f"
}

# write_sources <suite> [enabled]: /etc/apt/sources.list.d/motanka.sources.
write_sources() {
  {
    printf 'Types: deb\nURIs: http://127.0.0.1:8765/repo\nSuites: %s\nComponents: main\n' "$1"
    if [[ -n ${2:-} ]]; then
      printf 'Enabled: %s\n' "$2"
    fi
    printf 'Signed-By: /usr/share/keyrings/motanka-archive-keyring.gpg\n'
  } >"$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
}

# pkg <name> <version> [arch] [auto|manual]: an installed package.
pkg() {
  printf '%s\tinstalled\t%s\t%s\t%s\n' "$1" "$2" "${3:-all}" "${4:-auto}" >>"$FAKE_DB"
}

# offer <name> <version> [arch] [depends]: a version in apt's lists.
offer() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-all}" "${4:--}" >>"$FAKE_REPO"
}

# cached <name> <version> [arch]: the .deb of that version in apt's cache.
cached() {
  write_deb "$MOTANKA_ROOT/var/cache/apt/archives/${1}_${2//:/%3a}_${3:-all}.deb" "$1" "$2" "${3:-all}"
}

# write_deb <file> <name> <version> [arch] [depends]: a fake .deb.
write_deb() {
  mkdir -p "${1%/*}"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nDepends: %s\n' "$2" "$3" "${4:-all}" "${5:--}" >"$1"
}

# installed_version <name>: the version in the fake database.
installed_version() {
  awk -F'\t' -v n="$1" '$1 == n && $2 == "installed" { print $3 }' "$FAKE_DB"
}

# mark_of <name>: auto or manual.
mark_of() {
  awk -F'\t' -v n="$1" '$1 == n { print $5 }' "$FAKE_DB"
}

# motanka_installed <version>: motanka, motanka-core and motanka-stack at
# the version, with their .debs in apt's cache; motanka-archive-keyring and
# motanka-source-resolute at 0.1.0-1 offered by the repository only.
motanka_installed() {
  local v=$1 p
  pkg motanka "$v" all manual
  for p in motanka-core motanka-stack; do
    pkg "$p" "$v" all auto
    cached "$p" "$v"
  done
  cached motanka "$v"
  pkg motanka-archive-keyring 0.1.0-1 all manual
  pkg motanka-source-resolute 0.1.0-1 all manual
  offer motanka-archive-keyring 0.1.0-1
  offer motanka-source-resolute 0.1.0-1
  offer motanka "$v"
  offer motanka-core "$v"
  offer motanka-stack "$v"
}

# ul_line <verb> <class> <path> <before> <after>: appends a User_Ledger
# line to the test user's ledger.
ul_line() {
  local f=$H/.local/state/motanka/ledger
  mkdir -p "${f%/*}"
  printf '2026-11-13T09:00:00Z\t20261113T090000Z-abcdef\t%s\t%s\t%s\t%s\t%s\t-\n' "$@" >>"$f"
}

# user_set_up: a completed per-user setup with one ledgered session file
# and files in the Namespaced_Paths.
user_set_up() {
  local sha
  mkdir -p "$H/.config/hypr" "$H/.local/state/omarchy/migrations" "$H/.config/omarchy"
  printf 'hypr config\n' >"$H/.config/hypr/hyprland.lua"
  printf 'omarchy config\n' >"$H/.config/omarchy/shell.json"
  sha=$(sha256sum <"$H/.config/hypr/hyprland.lua")
  ul_line setup-begin - - - -
  ul_line create session .config/hypr/hyprland.lua - "${sha:0:64}"
  ul_line setup-end - - - -
}

# calls <tool>: the logged calls of one tool, in order.
calls() {
  awk -v t="$1" '$1 == t { sub(/^[^ ]+ /, ""); print }' "$FAKE_LOG"
}
