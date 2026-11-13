#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # stub bodies and python snippets are single-quoted on purpose
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; variables are set per test on purpose
# Unit tests for src/cmd/doctor.sh (tasks 22.1, 22.2; requirements 1.7,
# 11.2, 12.1-12.4, 12.6-12.8; design.md, Doctor and "Session-time home
# writes"): the report's system fields, the per-release feature list,
# missing and changed ledgered paths, unsupported shim calls from the
# journal, User_Ledger entries recorded as unplanned and paths observed as
# written by Ubuntu's session components, a pending session capture, --json
# as one JSON document, no change without --fix, and the suite switch of
# --fix.
#
# System paths live in a fake root (MOTANKA_ROOT); the home folder and
# everything else under BATS_TEST_TMPDIR. dpkg-query reads the package
# database $FAKE_DPKG_DB ("<name> TAB <status> TAB <version>" lines);
# journalctl prints $FAKE_STATE/journal.json; dpkg, apt-get and apt-cache
# log every call to $FAKE_STATE/<tool>.log. The --fix tests make "id -u"
# print 0 and serve a fake signed repository through curl and gpgv stubs,
# as test/unit/install.bats does; the dpkg stub then unpacks installed
# .debs into the fake root.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if ((EUID == 0)); then
    skip "the Doctor reads the home folder of the user who runs it; run these tests as a normal user"
  fi
  REPO="$BATS_TEST_DIRNAME/../.."
  MOTANKA="$REPO/src/motanka"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT/etc"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FAKE_STATE"
  export FAKE_DPKG_DB="$FAKE_STATE/db"
  : >"$FAKE_DPKG_DB"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\ncat >>%q\n' "$BATS_TEST_TMPDIR/journal" >"$STUBS/systemd-cat"
  make_stubs
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export NO_COLOR=1
  unset MK_HOME SUDO_USER PKEXEC_UID MOTANKA_APT_URI FAKE_JOURNAL_RC FAKE_UPDATE_RC
  export MOTANKA_HOME_PATHS="$REPO/compat/home-paths.tsv"
  SHARE="$MOTANKA_ROOT/opt/motanka/share/motanka"
  VER_R=0.1.0-1~ubuntu26.04.1
  VER_N=0.1.0-1~ubuntu24.04.1
}

make_stubs() {
  cat >"$STUBS/dpkg-query" <<'EOF'
#!/bin/bash
fmt="" pats=()
for a in "$@"; do
  case $a in
    -W | --show) ;;
    -f=* | --showformat=*) fmt=${a#*=} ;;
    -*) ;;
    *) pats+=("$a") ;;
  esac
done
found=0
while IFS=$'\t' read -r p st v; do
  [[ -n $p ]] || continue
  for pat in "${pats[@]}"; do
    if [[ $p == $pat ]]; then
      found=1
      if [[ $fmt == *Package*Version* ]]; then
        printf '%s\t%s\t%s\n' "$p" "$st" "$v"
      elif [[ $fmt == *Package* ]]; then
        printf '%s\t%s\n' "$p" "$st"
      else
        printf '%s\t%s\n' "$st" "$v"
      fi
      break
    fi
  done
done <"$FAKE_DPKG_DB"
if ((!found)); then
  echo "dpkg-query: no packages found matching ${pats[*]}" >&2
  exit 1
fi
EOF
  cat >"$STUBS/journalctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_STATE/journalctl.args"
if [ -n "$FAKE_JOURNAL_RC" ]; then
  echo "Failed to open the journal: Permission denied" >&2
  exit "$FAKE_JOURNAL_RC"
fi
cat "$FAKE_STATE/journal.json" 2>/dev/null
exit 0
EOF
  cat >"$STUBS/dpkg" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_STATE/dpkg.log"
case $1 in
  --compare-versions | --print-architecture) exec /usr/bin/dpkg "$@" ;;
esac
if [[ $1 == --force-depends && $2 == --purge && $# == 3 ]]; then
  awk -F'\t' -v p="$3" '$1 != p' "$FAKE_DPKG_DB" >"$FAKE_DPKG_DB.new"
  mv "$FAKE_DPKG_DB.new" "$FAKE_DPKG_DB"
  rm -f "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
  exit 0
fi
if [[ $1 == --install ]]; then
  shift
  if [[ ${1:-} == --force-confnew ]]; then
    shift
  fi
  for d in "$@"; do
    dpkg-deb -x "$d" "$MOTANKA_ROOT"
    printf '%s\tinstalled\t%s\n' "$(dpkg-deb -f "$d" Package)" "$(dpkg-deb -f "$d" Version)" >>"$FAKE_DPKG_DB"
  done
  exit 0
fi
echo "dpkg stub: unexpected call: $*" >&2
exit 99
EOF
  cat >"$STUBS/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_STATE/apt-get.log"
for a in "$@"; do
  if [ "$a" = update ]; then
    exit "${FAKE_UPDATE_RC:-0}"
  fi
done
echo "apt-get stub: unexpected call: $*" >&2
exit 99
EOF
  cat >"$STUBS/apt-cache" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_STATE/apt-cache.log"
echo "Package files:"
for s in ${FAKE_POLICY_SUITES-resolute resolute-edge}; do
  echo " 500 http://repo.test/apt $s/main amd64 Packages"
  echo "     release o=Motanka,a=$s,n=$s,l=Motanka,c=main,b=amd64"
done
EOF
  cat >"$STUBS/systemd-detect-virt" <<'EOF'
#!/bin/sh
echo kvm
EOF
}

# lib <function> [arguments...]: a User_Ledger or capture function on the
# test home.
lib() {
  bash -c 'set -euo pipefail
    for l in common userledger homepaths capture; do source "$1/src/lib/$l.sh"; done
    shift; "$@"' _ "$REPO" "$@"
}

# manifest: every path below the test home with its type and content hash.
manifest() {
  (
    cd "$HOME" || exit 1
    find . -printf '%P\t%y\t%m\t%T@\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

# root_manifest: the same for the fake root.
root_manifest() {
  (
    cd "$MOTANKA_ROOT" || exit 1
    find . -printf '%P\t%y\t%m\t%T@\t%l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

doctor() {
  run --separate-stderr bash "$MOTANKA" doctor "$@"
}

# check_json <python statements>: runs them with d bound to the JSON
# document of the last doctor run.
check_json() {
  printf '%s' "$output" >"$BATS_TEST_TMPDIR/doc.json"
  run python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[2])
print("ok")' "$BATS_TEST_TMPDIR/doc.json" "$1"
  assert_success
  assert_output ok
}

# --- fake system --------------------------------------------------------------------

# fake_release <codename> <version> [pretty name]
fake_release() {
  printf 'PRETTY_NAME="%s"\nNAME="Ubuntu"\nVERSION_ID="%s"\nVERSION_CODENAME=%s\nID=ubuntu\n' \
    "${3:-Ubuntu $2 LTS}" "$2" "$1" >"$MOTANKA_ROOT/etc/os-release"
}

# fake_pkg <name> <version> [status]
fake_pkg() {
  printf '%s\t%s\t%s\n' "$1" "${3:-installed}" "$2" >>"$FAKE_DPKG_DB"
}

# fake_installed <version> <source-suite>: Motanka installed at <version>,
# with the motanka-source package of <source-suite>.
fake_installed() {
  local p
  for p in motanka motanka-core motanka-archive-keyring motanka-stack motanka-stack-libs \
    motanka-stack-hyprland motanka-stack-tools motanka-stack-shell; do
    fake_pkg "$p" "$1"
  done
  fake_pkg motanka-qt6 "6.12.0-${1#*-}"
  fake_pkg "motanka-source-$2" "$1"
}

# fake_sources <suite> [disabled]: /etc/apt/sources.list.d/motanka.sources;
# "disabled" adds the "Enabled: no" a release upgrade writes.
fake_sources() {
  mkdir -p "$MOTANKA_ROOT/etc/apt/sources.list.d"
  {
    printf '# Motanka apt source for the suite %s\n' "$1"
    printf 'Types: deb\nURIs: http://repo.test/apt\nSuites: %s\nComponents: main\n' "$1"
    printf 'Architectures: amd64\nSigned-By: /usr/share/keyrings/motanka-archive-keyring.gpg\n'
    if [[ ${2:-} == disabled ]]; then
      printf 'Enabled: no\n'
    fi
  } >"$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
}

# fake_core <release>: upstream.pin and a package-map.tsv with skip lines.
fake_core() {
  mkdir -p "$SHARE"
  cp "$REPO/upstream.pin" "$SHARE/upstream.pin"
  {
    printf '# package-map.tsv for %s\n' "$1"
    printf 'alsa-utils\tapt\talsa-utils\t-\n'
    if [[ $1 == noble ]]; then
      printf 'fastfetch\tskip\t-\tnot in the 24.04 archive; needs a decision\n'
      printf 'gum\tskip\t-\tnot in the 24.04 archive; needs a decision\n'
    else
      printf 'fastfetch\tapt\tfastfetch\t-\n'
    fi
    printf 'hyprsunset\tmotanka\tmotanka-stack-tools\tbuilt for the Stack\n'
    printf 'limine\tskip\t-\tkernel and boot changes are out of scope\n'
  } >"$SHARE/package-map.tsv"
}

# fake_gpu <card> <driver>
fake_gpu() {
  mkdir -p "$MOTANKA_ROOT/sys/class/drm/$1/device"
  ln -sfn "../../../../bus/pci/drivers/$2" "$MOTANKA_ROOT/sys/class/drm/$1/device/driver"
}

fake_dm() {
  mkdir -p "$MOTANKA_ROOT/etc/systemd/system"
  ln -sfn "/usr/lib/systemd/system/$1.service" "$MOTANKA_ROOT/etc/systemd/system/display-manager.service"
}

# fake_host <release> <version> <source-suite> [disabled]: a Host with
# Motanka installed.
fake_host() {
  fake_release "$1" "$2"
  if [[ $3 == noble* ]]; then
    fake_installed "$VER_N" "$3"
  else
    fake_installed "$VER_R" "$3"
  fi
  fake_sources "$3" "${4:-}"
  fake_core "$1"
  fake_gpu card0 virtio_gpu
  fake_dm gdm3
}

# --- home-folder part (tests of the session capture task) ----------------------------

@test "without a User_Ledger the Doctor says so and lists nothing" {
  doctor
  assert_success
  assert_line --regexp '^Home folder of .+ \(.*/home\):$'
  assert_line --partial 'User_Ledger:      none'
  assert_line '  session capture:  none pending'
  assert_line --partial 'unplanned:        0 path(s)'
  assert_line --partial 'desktop:          0 path(s)'
  [[ ! -e $HOME/.local ]]
}

@test "the Doctor lists unplanned and desktop entries and a pending capture, and changes nothing" {
  mkdir -p "$HOME/.config" "$HOME/.local/share"
  lib mk_capture_start
  sleep 0.05
  printf 'x\n' >"$HOME/.XCompose"
  mkdir -p "$HOME/Downloads" "$HOME/.local/share/keyrings"
  printf 'k\n' >"$HOME/.local/share/keyrings/login.keyring"
  lib mk_capture_end
  printf 'f\n' >"$HOME/.config/foo.conf"
  lib mk_userledger_record_unplanned .config/foo.conf
  lib mk_capture_start
  local before
  before=$(manifest)
  doctor
  assert_success
  assert_line --regexp '^  User_Ledger: +~/\.local/state/motanka/ledger \([0-9]+ entries\)$'
  assert_line --regexp '^  session capture:  pending since [0-9]{4}-[0-9]{2}-[0-9]{2}T'
  assert_line --partial 'unplanned:        2 path(s)'
  assert_line '    ~/.XCompose'
  assert_line '    ~/.config/foo.conf'
  assert_line --partial 'desktop:          3 path(s)'
  assert_line '    ~/Downloads/'
  assert_line '    ~/.local/share/keyrings/'
  assert_line '    ~/.local/share/keyrings/login.keyring'
  assert_equal "$(manifest)" "$before"
}

@test "--json prints one JSON document with the same entries" {
  mkdir -p "$HOME/.config"
  lib mk_capture_start
  sleep 0.05
  printf 'x\n' >"$HOME/.XCompose"
  mkdir -p "$HOME/Music"
  lib mk_capture_end
  doctor --json
  assert_success
  assert_equal "${#lines[@]}" 1
  run python3 -c 'import json, sys
d = json.loads(sys.argv[1])["home"]
assert d["user_ledger"] is True, d
assert d["session_capture"] == {"pending": False, "since": None}, d
assert d["unplanned"] == [".XCompose"], d
assert d["desktop"] == ["Music/"], d
print("ok")' "$output"
  assert_success
  assert_output ok
}

@test "JSON strings escape quotes, backslashes and control characters" {
  run bash -c 'source "$1/src/lib/common.sh"; MK_LIBEXEC=$1/src; source "$1/src/cmd/doctor.sh"; _mk_dr_json_string "$2"' _ "$REPO" $'a"b\\c\td\x01'
  assert_success
  assert_output '"a\"b\\c\td\u0001"'
}

# --- system part (12.1, 1.7) -----------------------------------------------------------

@test "the report names the release, version, channel, Upstream pin, Stack, GPU driver, display manager and snapshot method (12.1)" {
  fake_host resolute 26.04 resolute
  doctor
  assert_success
  assert_line --regexp '^  release: +Ubuntu 26\.04 LTS \(resolute\), supported$'
  assert_line --regexp '^  Motanka: +0\.1\.0-1~ubuntu26\.04\.1$'
  assert_line --regexp '^  apt source: +suite resolute, enabled, http://repo\.test/apt; package motanka-source-resolute$'
  assert_line --regexp '^  channel: +stable$'
  assert_line --regexp '^  Upstream pin: +ac2690cd7be4f47e4a255f5e2e78d904d436b068 \(v4\.5\.0\), stable channel$'
  assert_line --regexp '^  Stack: +motanka-stack 0\.1\.0-1~ubuntu26\.04\.1, .*motanka-stack-shell 0\.1\.0-1~ubuntu26\.04\.1, motanka-qt6 6\.12\.0-1~ubuntu26\.04\.1$'
  assert_line --regexp '^  GPU: +card0 \(virtio_gpu, supported\); the Motanka session can start$'
  assert_line --regexp '^  display manager: +gdm3, Wayland sessions enabled$'
  assert_line --regexp "^  snapshot method: +Motanka's Config_Archive .*; snapper: not checked \(needs root\)$"
  assert_line --regexp '^  System_Ledger: +none '
  assert_line '  none found'
  assert_line --regexp '^  - snapshots: .*readable by root only; run: sudo motanka doctor$'
}

@test "--json prints the same report as one JSON document (12.7)" {
  fake_host resolute 26.04 resolute-edge
  doctor --json
  assert_success
  assert_equal "${#lines[@]}" 1
  check_json 's = d["system"]
assert s["release"] == {"id": "ubuntu", "version_id": "26.04", "codename": "resolute", "pretty_name": "Ubuntu 26.04 LTS", "supported": True}, s["release"]
assert s["motanka"] == {"installed": True, "version": "0.1.0-1~ubuntu26.04.1", "core_version": "0.1.0-1~ubuntu26.04.1", "dev_build": False}, s["motanka"]
r = s["repository"]
assert (r["suite"], r["enabled"], r["matches_release"], r["uri"]) == ("resolute-edge", True, True, "http://repo.test/apt"), r
assert [p["package"] for p in r["source_packages"]] == ["motanka-source-resolute-edge"], r
assert s["channel"] == "edge", s["channel"]
assert s["upstream_pin"] == {"channel": "edge", "commit": "ac2690cd7be4f47e4a255f5e2e78d904d436b068", "tag": None}, s["upstream_pin"]
stack = {x["package"]: x["version"] for x in s["stack"]}
assert stack["motanka-qt6"] == "6.12.0-1~ubuntu26.04.1" and stack["motanka-stack-shell"] == "0.1.0-1~ubuntu26.04.1", stack
assert set(stack) == {"motanka-stack", "motanka-stack-libs", "motanka-stack-hyprland", "motanka-stack-tools", "motanka-stack-shell", "motanka-qt6"}, stack
assert s["gpu"]["supported"] is True and s["gpu"]["cards"] == [{"card": "card0", "driver": "virtio_gpu", "status": "supported"}], s["gpu"]
assert s["display_manager"] == {"name": "gdm3", "wayland": True, "problem": None}, s["display_manager"]
assert s["snapshots"]["method"] == "config-archive" and s["snapshots"]["snapper"]["checked"] is False, s["snapshots"]
assert s["system_ledger"]["present"] is False, s["system_ledger"]
assert d["problems"] == [], d["problems"]
assert any(x["part"] == "snapshots" for x in d["skipped"]), d["skipped"]
assert d["shim_calls"]["read"] is True and d["shim_calls"]["calls"] == [], d["shim_calls"]
assert d["home"]["user_ledger"] is False, d["home"]
assert d["running_as"]["root"] is False, d["running_as"]'
}

@test "the GPU verdict is the session launcher's: an old NVIDIA driver is a problem with the launcher's reason" {
  fake_host resolute 26.04 resolute
  fake_gpu card1 nvidia
  mkdir -p "$MOTANKA_ROOT/proc/driver/nvidia"
  printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  550.120  Release Build\n' \
    >"$MOTANKA_ROOT/proc/driver/nvidia/version"
  doctor
  assert_success
  assert_line --regexp '^  GPU: +card0 \(virtio_gpu, supported\), card1 \(nvidia 550\.120, refused\); refused: card1 runs the NVIDIA driver 550\.120; the Motanka session needs the NVIDIA driver 555 or later$'
  assert_line '  - the Motanka session would not start: card1 runs the NVIDIA driver 550.120; the Motanka session needs the NVIDIA driver 555 or later'
}

@test "after a release upgrade the Doctor reports the other release's suite, the disabled source and the old packages, with the fix command (11.5)" {
  fake_host resolute 26.04 noble disabled
  doctor
  assert_success
  assert_line --regexp '^  apt source: +suite noble, disabled \(Enabled: no\), http://repo\.test/apt; package motanka-source-noble$'
  assert_line --partial "  - the Motanka apt source names the suite 'noble', but this system runs Ubuntu 26.04 (resolute)"
  assert_line --partial '  - the Motanka apt source is disabled (Enabled: no in /etc/apt/sources.list.d/motanka.sources)'
  assert_line --partial '  - 10 Motanka package(s) are builds for another Ubuntu release than 26.04: motanka motanka-archive-keyring motanka-core'
  assert_line '    fix: sudo motanka doctor --fix'
  assert_line '    fix: sudo motanka doctor --fix, then sudo motanka update'
  doctor --json
  assert_success
  check_json 'ids = [p["id"] for p in d["problems"]]
assert ids == ["suite-mismatch", "source-disabled", "packages-other-release"], ids
r = d["system"]["repository"]
assert r["matches_release"] is False and r["enabled"] is False, r
assert d["problems"][0]["fix"] == "sudo motanka doctor --fix", d["problems"][0]'
}

@test "features the running release lacks are listed with the Package_Map's reasons (1.7)" {
  fake_host noble 24.04 noble
  doctor
  assert_success
  assert_line "Not available on Ubuntu 24.04 (noble): 3 package(s) of Upstream's package lists (Package_Map outcome skip):"
  assert_line '  not in the 24.04 archive; needs a decision: fastfetch, gum'
  assert_line '  kernel and boot changes are out of scope: limine'
  doctor --json
  check_json 'assert d["features_unavailable"] == [
  {"package": "fastfetch", "reason": "not in the 24.04 archive; needs a decision"},
  {"package": "gum", "reason": "not in the 24.04 archive; needs a decision"},
  {"package": "limine", "reason": "kernel and boot changes are out of scope"}], d["features_unavailable"]'
}

@test "without motanka-core the feature list is skipped with the reason" {
  fake_release resolute 26.04
  doctor --json
  assert_success
  check_json 'assert d["features_unavailable"] is None
assert any(x["part"] == "features" and "package-map.tsv is missing" in x["reason"] for x in d["skipped"]), d["skipped"]
assert d["system"]["motanka"]["installed"] is False'
}

@test "the System_Ledger's packages that are gone and its interrupted runs are reported" {
  fake_host resolute 26.04 resolute
  fake_pkg libfoo1 1.2-3
  mkdir -p "$MOTANKA_ROOT/var/lib/motanka"
  printf '%s\n' \
    $'2026-11-13T09:00:00Z\t20261113T090000Z-aaaaaa\trun-begin\tinstall\t0.1.0-1~ubuntu26.04.1' \
    $'2026-11-13T09:00:01Z\t20261113T090000Z-aaaaaa\tpkg-installed\tlibfoo1\t1.2-3\tauto' \
    $'2026-11-13T09:00:02Z\t20261113T090000Z-aaaaaa\tpkg-installed\tfoo-tools\t1.2-3\tauto' \
    $'2026-11-13T09:00:03Z\t20261113T090000Z-aaaaaa\trun-end\tok' \
    $'2026-11-13T10:00:00Z\t20261113T100000Z-bbbbbb\trun-begin\tupdate\t0.1.0-2~ubuntu26.04.1' \
    >"$MOTANKA_ROOT/var/lib/motanka/ledger"
  doctor
  assert_success
  assert_line --regexp '^  System_Ledger: +/var/lib/motanka/ledger: 2 Ubuntu package\(s\) recorded, 1 of them no longer installed \(foo-tools\); interrupted runs: 20261113T100000Z-bbbbbb$'
  assert_line --partial '  - the System_Ledger records 1 run(s) that did not finish (20261113T100000Z-bbbbbb)'
}

# --- home part: missing and changed paths (12.2) ----------------------------------------

@test "missing and changed ledgered paths are listed; Namespaced_Paths are checked for missing only (12.2)" {
  local src=$BATS_TEST_TMPDIR/src
  mkdir -p "$src"
  printf 'a\n' >"$src/a"
  printf 'b\n' >"$src/b"
  lib mk_userledger_setup_begin
  lib mk_userledger_write session .config/hypr/a.conf "$src/a"
  lib mk_userledger_write session .config/hypr/b.conf "$src/b"
  lib mk_userledger_write session .config/hypr/c.conf "$src/a"
  lib mk_userledger_write namespaced .config/omarchy/current/theme.name "$src/a"
  lib mk_userledger_write namespaced .config/omarchy/gone "$src/a"
  lib mk_userledger_symlink session .config/waybar/style.css ../omarchy/current/theme/waybar.css
  lib mk_userledger_mkdir app .config/walker/
  lib mk_userledger_setup_end
  rm "$HOME/.config/hypr/a.conf" "$HOME/.config/omarchy/gone" "$HOME/.config/waybar/style.css"
  rmdir "$HOME/.config/walker"
  printf 'edited by the user\n' >>"$HOME/.config/hypr/b.conf"
  printf 'rewritten by a theme switch\n' >"$HOME/.config/omarchy/current/theme.name"
  local before
  before=$(manifest)
  doctor
  assert_success
  assert_line --partial '  missing:          4 ledgered path(s)'
  assert_line '    ~/.config/hypr/a.conf (create)'
  assert_line '    ~/.config/omarchy/gone (create)'
  assert_line '    ~/.config/waybar/style.css (symlink)'
  assert_line '    ~/.config/walker/ (create)'
  assert_line --partial '  changed:          1 ledgered path(s)'
  assert_line '    ~/.config/hypr/b.conf (create)'
  refute_line '    ~/.config/hypr/c.conf (create)'
  refute_line --partial 'theme.name'
  refute_output --partial 'edited by the user'
  doctor --json
  check_json 'h = d["home"]
assert [x["path"] for x in h["missing"]] == [".config/hypr/a.conf", ".config/omarchy/gone", ".config/waybar/style.css", ".config/walker/"], h["missing"]
assert h["changed"] == [{"path": ".config/hypr/b.conf", "entry": "create"}], h["changed"]'
  assert_equal "$(manifest)" "$before"
}

# --- journal (12.3) ---------------------------------------------------------------------

@test "unsupported shim calls of the last 30 days come from the journal (12.3)" {
  python3 - "$FAKE_STATE/journal.json" <<'PY'
import json, sys
rows = [
    {"MESSAGE": "motanka shim: unsupported call: pacman -Syyu (from omarchy-update)", "__REALTIME_TIMESTAMP": "1763024102000000", "_UID": "1000"},
    {"MESSAGE": "motanka install: preflight passed on resolute", "__REALTIME_TIMESTAMP": "1763024103000000", "_UID": "0"},
    {"MESSAGE": "motanka shim: unsupported call: pacman -Syyu (from omarchy-update)", "__REALTIME_TIMESTAMP": "1763110502000000", "_UID": "1000"},
    {"MESSAGE": list('motanka sudo: unsupported call: sudo tee /etc/x (from omarchy-dns): "q" \\ \x1b[31m'.encode()), "__REALTIME_TIMESTAMP": "1763110503000000", "_UID": "1000"},
    {"MESSAGE": None},
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
    f.write("not json at all\n")
PY
  doctor
  assert_success
  run cat "$FAKE_STATE/journalctl.args"
  assert_output "$(printf '%s\n' -t motanka --since '30 days ago' -o json --no-pager -q)"
  doctor
  assert_line 'Unsupported shim calls in the last 30 days: 3'
  assert_line '  2x  pacman -Syyu (from omarchy-update)  (last 2025-11-14T08:55:02Z)'
  assert_line '  1x  sudo tee /etc/x (from omarchy-dns): "q" \ ?[31m  (last 2025-11-14T08:55:03Z)'
  [[ $output != *$'\e'* ]]
  doctor --json
  assert_equal "${#lines[@]}" 1
  check_json 'c = d["shim_calls"]["calls"]
assert [x["call"] for x in c] == ["pacman -Syyu (from omarchy-update)", "pacman -Syyu (from omarchy-update)", "sudo tee /etc/x (from omarchy-dns): \"q\" \\ \x1b[31m"], c
assert c[0] == {"time": "2025-11-13T08:55:02Z", "call": "pacman -Syyu (from omarchy-update)", "uid": 1000}, c[0]'
}

@test "a journal that cannot be read is reported, and the report still prints" {
  export FAKE_JOURNAL_RC=1
  doctor
  assert_success
  assert_line 'Unsupported shim calls in the last 30 days: not read: journalctl exited with 1: Failed to open the journal: Permission denied'
  assert_line --regexp '^Home folder of '
}

# --- no change without --fix (12.4) ---------------------------------------------------------

@test "without --fix the Doctor changes nothing and runs no package tool (12.4)" {
  fake_host resolute 26.04 noble disabled
  mkdir -p "$MOTANKA_ROOT/run/lock"
  local src=$BATS_TEST_TMPDIR/src root_before home_before
  mkdir -p "$src"
  printf 'a\n' >"$src/a"
  lib mk_userledger_write session .config/hypr/a.conf "$src/a"
  root_before=$(root_manifest)
  home_before=$(manifest)
  doctor
  assert_success
  doctor --json
  assert_success
  assert_equal "$(root_manifest)" "$root_before"
  assert_equal "$(manifest)" "$home_before"
  [[ ! -e $FAKE_STATE/dpkg.log && ! -e $FAKE_STATE/apt-get.log && ! -e $FAKE_STATE/apt-cache.log ]]
}

@test "--i-know-this-is-not-a-vm is accepted with --fix only" {
  doctor --i-know-this-is-not-a-vm
  assert_failure 2
  [[ $stderr == *'accepted with --fix only'* ]]
}

@test "--fix without root exits 11 and changes nothing" {
  fake_host resolute 26.04 noble disabled
  local before
  before=$(root_manifest)
  doctor --fix
  assert_failure 11
  [[ $stderr == *'must run as root: sudo motanka doctor --fix'* ]]
  assert_output ''
  assert_equal "$(root_manifest)" "$before"
}

# --- property: hostile ledger states (12.6, 12.7) -----------------------------------------

# gen_ledger <seed> <home> <secret> <expected.json>: a User_Ledger of
# random valid entries with hostile path names (quotes, backslashes,
# spaces, shell and format syntax, non-ASCII), interleaved with lines the
# reader must skip (control characters, a newline inside a path, garbage,
# a torn last line), and files and links whose content and targets carry
# <secret>. Writes the home part the Doctor must report.
gen_ledger() {
  python3 - "$@" <<'PY'
import hashlib, json, os, random, sys

seed, home, secret, out = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
rnd = random.Random(seed)
NAMES = ["plain", "sp ace", 'quo"te', "apo'strophe", "back\\slash", "trailing\\", "$(touch PWNED)",
         "`id`", "%s%n%x", '{"a": [1]}', "]}],", "üñí©ødé", "日本語", "semi;colon", "star*glob?",
         "\\n literal", "-dash", "#hash", 'a\\"b\\\\c', "<tag>&amp;"]
T = "2026-11-13T09:15:02Z"
lines = []
exp = {"entries": 0, "unplanned": [], "desktop": [], "missing": [], "changed": []}


def rid():
    return "20261113T091502Z-%06x" % rnd.randrange(1 << 24)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def add(verb, cls, path, before, after):
    lines.append("\t".join([T, rid(), verb, cls, path, before, after, "-"]))
    exp["entries"] += 1


for k in range(rnd.randrange(4, 14)):
    d = ".config/%s-%d" % (rnd.choice(NAMES), k)
    rel = d + "/" + rnd.choice(NAMES)
    kind = rnd.choice(["file", "adopt", "link", "dir", "unplanned", "observed"])
    fate = rnd.choice(["same", "missing", "changed"])
    content = ("%s %d\n" % (secret, k)).encode()
    target = "%s/target-%d" % (secret, k)
    if kind in ("file", "adopt"):
        if kind == "file":
            verb = rnd.choice(["create", "replace", "block", "menu-desktop"])
            add(verb, rnd.choice(["session", "app", "shared"]), rel, "-" if verb == "create" else sha(b"old"), sha(content))
        else:
            add("adopt", rnd.choice(["session", "app"]), rel, "-", sha(content))
        if fate != "missing":
            os.makedirs(os.path.join(home, d), exist_ok=True)
            with open(os.path.join(home, rel), "wb") as f:
                f.write(content if fate == "same" else content + secret.encode())
    elif kind == "link":
        add("symlink", rnd.choice(["session", "app"]), rel, "-", "l:" + sha(target.encode()))
        if fate != "missing":
            os.makedirs(os.path.join(home, d), exist_ok=True)
            os.symlink(target if fate == "same" else target + "-edited", os.path.join(home, rel))
    elif kind == "dir":
        rel = d + "/"
        add("create", rnd.choice(["session", "app"]), rel, "-", "-")
        if fate != "missing":
            os.makedirs(os.path.join(home, d), exist_ok=True)
            fate = "same"
    elif kind == "unplanned":
        add("unplanned", "-", rel, "-", sha(content))
        exp["unplanned"].append(rel)
        fate = None
    else:
        add("observed", "desktop", rel, "-", "-")
        exp["desktop"].append(rel)
        fate = None
    if fate == "missing":
        exp["missing"].append(rel)
    elif fate == "changed":
        exp["changed"].append(rel)
    if rnd.random() < 0.5:
        lines.append("\t".join([T, rid(), "create", "session", ".config/" + secret + "\x1b[31m", "-", sha(b"x"), "-"]))
    if rnd.random() < 0.5:
        lines.append("\t".join([T, rid(), "unplanned", "-", ".config/" + secret + "\nsplit", "-", "-", "-"]))
    if rnd.random() < 0.3:
        lines.append(secret + ' garbage \\ " \' \x01')

state = os.path.join(home, ".local/state/motanka")
os.makedirs(state, exist_ok=True)
with open(os.path.join(state, "ledger"), "w", encoding="utf-8", newline="") as f:
    for line in lines:
        f.write(line + "\n")
    if rnd.random() < 0.4:
        f.write(T + "\t" + rid() + "\tcreate\tsession\t" + secret)
with open(out, "w") as f:
    json.dump(exp, f)
PY
}

@test "property: for generated ledger states with hostile path names, --json always parses, lists exactly the expected paths, and no home-file content appears (12.6, 12.7)" {
  local i secret h exp
  for i in $(seq 1 15); do
    secret="MKSECRET$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    case $((i % 3)) in
      0) h="$BATS_TEST_TMPDIR/home-$i" ;;
      1) h="$BATS_TEST_TMPDIR/ho \"me\" \\ \$x '$i'" ;;
      2) h="$BATS_TEST_TMPDIR/ho"$'\n'"me-$i" ;;
    esac
    mkdir -p "$h"
    exp="$BATS_TEST_TMPDIR/expected-$i.json"
    gen_ledger "$i" "$h" "$secret" "$exp"
    : >"$BATS_TEST_TMPDIR/journal"
    run --separate-stderr env HOME="$h" bash "$MOTANKA" doctor --json
    assert_success
    assert_equal "${#lines[@]}" 1
    [[ $output != *"$secret"* && $stderr != *"$secret"* ]]
    printf '%s' "$output" >"$BATS_TEST_TMPDIR/doc.json"
    run python3 -c 'import json, sys
h = json.load(open(sys.argv[1]))["home"]
e = json.load(open(sys.argv[2]))
assert h["path"] == sys.argv[3], (h["path"], sys.argv[3])
assert h["entries"] == e["entries"], (h["entries"], e["entries"])
assert h["unplanned"] == e["unplanned"], (h["unplanned"], e["unplanned"])
assert h["desktop"] == e["desktop"], (h["desktop"], e["desktop"])
assert [x["path"] for x in h["missing"]] == e["missing"], (h["missing"], e["missing"])
assert [x["path"] for x in h["changed"]] == e["changed"], (h["changed"], e["changed"])
print("ok")' "$BATS_TEST_TMPDIR/doc.json" "$exp" "$h"
    assert_success
    assert_output ok
    run --separate-stderr env HOME="$h" bash "$MOTANKA" doctor
    assert_success
    [[ $output != *"$secret"* && $stderr != *"$secret"* ]]
    run grep -c -F -- "$secret" "$BATS_TEST_TMPDIR/journal"
    assert_output 0
  done
}

# --- --fix (11.2) -----------------------------------------------------------------------------

# mkdeb <package> <version> <tree> <out.deb>
mkdeb() {
  mkdir -p "$3/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.test>\nDescription: test package\n test package for doctor.bats\n' \
    "$1" "$2" >"$3/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$3" "$4" >/dev/null
}

sign_sums() {
  (cd "$FAKE_WWW" && find pool -type f -name '*.deb' | LC_ALL=C sort | xargs -r sha256sum) >"$FAKE_WWW/SHA256SUMS"
  printf 'good:%s\n' "$(sha256sum <"$FAKE_WWW/SHA256SUMS" | cut -c1-64)" >"$FAKE_WWW/SHA256SUMS.gpg"
}

# fix_setup: "id -u" prints 0, and a signed fake repository with the
# keyring and source packages of resolute, resolute-edge and noble.
fix_setup() {
  local suite ver k s pool
  mkdir -p "$MOTANKA_ROOT/run/lock"
  cat >"$STUBS/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ] && [ $# -eq 1 ]; then
  echo 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  cat >"$STUBS/curl" <<'EOF'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out=$2; shift ;;
    --proto | --proto-redir | --connect-timeout | --max-time | --retry) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$url" >>"$FAKE_STATE/curl.log"
path=${url#http://repo.test/apt/}
if [ "$path" = "$url" ] || [ ! -f "$FAKE_WWW/$path" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cp "$FAKE_WWW/$path" "$out"
EOF
  cat >"$STUBS/gpgv" <<'EOF'
#!/bin/sh
while [ $# -gt 2 ]; do
  shift
done
want="good:$(sha256sum <"$2" | cut -c1-64)"
if [ "$(cat "$1")" = "$want" ]; then
  echo "[GNUPG:] GOODSIG 0123456789ABCDEF test"
  echo "[GNUPG:] VALIDSIG 0123456789ABCDEF test"
  exit 0
fi
echo "[GNUPG:] BADSIG 0123456789ABCDEF test"
exit 1
EOF
  chmod +x "$STUBS/id" "$STUBS/curl" "$STUBS/gpgv"
  export FAKE_WWW="$BATS_TEST_TMPDIR/www/apt"
  for suite in resolute resolute-edge noble; do
    ver=$VER_R
    if [[ $suite == noble ]]; then
      ver=$VER_N
    fi
    k=$BATS_TEST_TMPDIR/pkg-keyring-$suite
    s=$BATS_TEST_TMPDIR/pkg-source-$suite
    mkdir -p "$k/usr/share/keyrings" "$k/etc/apt/preferences.d" "$s/etc/apt/sources.list.d"
    printf 'binary keyring\n' >"$k/usr/share/keyrings/motanka-archive-keyring.gpg"
    printf 'Package: *\nPin: release o=Motanka\nPin-Priority: -1\n' >"$k/etc/apt/preferences.d/motanka"
    printf 'Types: deb\nURIs: http://repo.test/apt\nSuites: %s\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/motanka-archive-keyring.gpg\n' \
      "$suite" >"$s/etc/apt/sources.list.d/motanka.sources"
    pool=$FAKE_WWW/pool/$suite/main/m
    mkdir -p "$pool/motanka-archive-keyring" "$pool/motanka-source"
    mkdeb motanka-archive-keyring "$ver" "$k" "$pool/motanka-archive-keyring/motanka-archive-keyring_${ver}_all.deb"
    mkdeb "motanka-source-$suite" "$ver" "$s" "$pool/motanka-source/motanka-source-${suite}_${ver}_all.deb"
  done
  sign_sums
}

# db_has <package>: 0 if the fake package database lists it.
db_has() {
  awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$FAKE_DPKG_DB"
}

@test "--fix purges the old source package, then installs the running release's, then runs apt-get update (11.2)" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  doctor --fix
  assert_success
  [[ $stderr == *'switched the Motanka apt source from motanka-source-noble to motanka-source-resolute (suite resolute)'* ]]
  run grep -n -E -- '^--force-depends --purge |^--install ' "$FAKE_STATE/dpkg.log"
  assert_line --index 0 --regexp '^[0-9]+:--force-depends --purge motanka-source-noble$'
  assert_line --index 1 --regexp '^[0-9]+:--install --force-confnew .*/source\.deb$'
  assert_equal "${#lines[@]}" 2
  run cat "$FAKE_STATE/apt-get.log"
  assert_output '-q -o DPkg::Lock::Timeout=300 update'
  run grep -c 'pool/resolute/main/m/motanka-source/motanka-source-resolute_' "$FAKE_STATE/curl.log"
  assert_output 1
  run db_has motanka-source-noble
  assert_failure
  db_has motanka-source-resolute
  run cat "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
  assert_line 'Suites: resolute'
  refute_line --partial 'Enabled'
  [[ ! -e $MOTANKA_ROOT/run/motanka || -z $(ls -A "$MOTANKA_ROOT/run/motanka") ]]
  doctor --json
  assert_success
  check_json 'ids = [p["id"] for p in d["problems"]]
assert "suite-mismatch" not in ids and "source-disabled" not in ids, ids
assert ids == ["packages-other-release"], ids
assert d["problems"][0]["fix"] == "sudo motanka update", d["problems"][0]
assert d["system"]["repository"]["matches_release"] is True'
}

@test "--fix reports the switch in the JSON document and in the journal" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  doctor --fix --json
  assert_success
  assert_equal "${#lines[@]}" 1
  check_json 'f = d["fix"]
assert f["action"] == "switched" and f["purged"] == ["motanka-source-noble"], f
assert f["installed"] == "motanka-source-resolute" and f["suite"] == "resolute" and f["apt_update"] == "ok", f
assert d["home"] is None and any(x["part"] == "home" for x in d["skipped"]), d["skipped"]
assert d["running_as"]["root"] is True'
  run grep -F 'fix: dpkg --force-depends --purge motanka-source-noble' "$BATS_TEST_TMPDIR/journal"
  assert_success
}

@test "--fix keeps the edge channel" {
  fix_setup
  fake_host resolute 26.04 noble-edge disabled
  doctor --fix
  assert_success
  run db_has motanka-source-noble-edge
  assert_failure
  db_has motanka-source-resolute-edge
  run cat "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
  assert_line 'Suites: resolute-edge'
}

@test "--fix with the enabled source of the running release changes nothing" {
  fix_setup
  fake_host resolute 26.04 resolute
  local before
  before=$(root_manifest)
  doctor --fix
  assert_success
  [[ $stderr == *'nothing to fix'* ]]
  assert_line --regexp '^Fix: the Motanka apt source names the suite resolute of this release and is enabled; nothing to fix$'
  [[ ! -e $FAKE_STATE/dpkg.log && ! -e $FAKE_STATE/apt-get.log && ! -e $FAKE_STATE/curl.log ]]
  assert_equal "$(root_manifest | grep -v 'run/lock')" "$(printf '%s\n' "$before" | grep -v 'run/lock')"
}

@test "--fix on a disabled source of the running suite purges and reinstalls its package" {
  fix_setup
  fake_host resolute 26.04 resolute disabled
  doctor --fix
  assert_success
  run grep -E -- '^--force-depends --purge |^--install ' "$FAKE_STATE/dpkg.log"
  assert_line --index 0 --regexp '^--force-depends --purge motanka-source-resolute$'
  assert_line --index 1 --regexp '^--install --force-confnew '
  db_has motanka-source-resolute
  run cat "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
  refute_line --partial 'Enabled'
}

@test "--fix also installs the keyring package when it is missing" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  awk -F'\t' '$1 != "motanka-archive-keyring"' "$FAKE_DPKG_DB" >"$FAKE_DPKG_DB.new"
  mv "$FAKE_DPKG_DB.new" "$FAKE_DPKG_DB"
  doctor --fix
  assert_success
  run grep -E -- '^--install ' "$FAKE_STATE/dpkg.log"
  assert_output --regexp '^--install --force-confnew .*/keyring\.deb .*/source\.deb$'
  db_has motanka-archive-keyring
}

@test "--fix refuses a source package that fails verification with exit 6 and changes nothing" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  printf 'tampered' >>"$FAKE_WWW/pool/resolute/main/m/motanka-source/motanka-source-resolute_${VER_R}_all.deb"
  local before
  before=$(cat "$FAKE_DPKG_DB" "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources")
  doctor --fix
  assert_failure 6
  [[ $stderr == *'checksum mismatch'* ]]
  assert_output ''
  run grep -E -- '--purge|--install' "$FAKE_STATE/dpkg.log"
  assert_failure
  [[ ! -e $FAKE_STATE/apt-get.log ]]
  assert_equal "$(cat "$FAKE_DPKG_DB" "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources")" "$before"
}

@test "--fix on a release without a Motanka suite exits 3 and changes nothing" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  fake_release questing 25.10 "Ubuntu 25.10"
  doctor --fix
  assert_failure 3
  [[ $stderr == *'Ubuntu 25.10'* ]]
  [[ ! -e $FAKE_STATE/curl.log && ! -e $FAKE_STATE/apt-get.log ]]
  db_has motanka-source-noble
}

@test "--fix on a Protected_Host exits 7" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  doctor --fix
  assert_failure 7
  [[ ! -e $FAKE_STATE/curl.log ]]
  db_has motanka-source-noble
}

@test "--fix exits 1 after switching when apt-get update fails" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  export FAKE_UPDATE_RC=100
  doctor --fix --json
  assert_failure 1
  db_has motanka-source-resolute
  check_json 'assert d["fix"]["action"] == "switched" and d["fix"]["apt_update"] == "failed", d["fix"]'
}

@test "--fix when apt does not list the signed Motanka suite after the update exits 1" {
  fix_setup
  fake_host resolute 26.04 noble disabled
  export FAKE_POLICY_SUITES=""
  doctor --fix
  assert_failure 1
  [[ $stderr == *'did not load the signed Motanka suite resolute'* ]]
}

@test "--fix without Motanka installed has nothing to switch" {
  fix_setup
  fake_release resolute 26.04
  doctor --fix
  assert_success
  [[ $stderr == *'Motanka is not installed'* ]]
  [[ ! -e $FAKE_STATE/dpkg.log && ! -e $FAKE_STATE/curl.log ]]
}
