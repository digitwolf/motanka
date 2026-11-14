#!/usr/bin/env bash
# VM test for the Installer (task 11.4): build the packages that exist,
# publish them in a signed test repository, and run 'motanka install' on
# throwaway VMs. The guest half is test/vm/install-guest.sh.
#
# Usage: test/vm/tests/install.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE               resolute (default) or noble
#   MOTANKA_VM_RESULTS               log folder
#   MOTANKA_STACK_REBUILD            1 to rebuild the Stack even if .debs of
#                                    the current version are cached
#   MOTANKA_INSTALL_PLACEHOLDER_CORE 1 to use a placeholder motanka-core
#                                    even if packaging/motanka-core exists
#
# Build (once per run):
#   - the Stack .debs come from ~/.cache/motanka-vm/debs/<release>/, as in
#     test/vm/tests/stack.sh; if they are missing, test/vm/build builds
#     packaging/motanka-stack first (more than an hour)
#   - one build VM builds motanka-archive-keyring, motanka-source and the
#     motanka metapackage, plus motanka-core when packaging/motanka-core
#     exists. Otherwise it builds a temporary placeholder motanka-core
#     (Depends: motanka-stack, no files) and the log says so.
#   - the motanka-source .debs are repacked with URIs
#     http://127.0.0.1:8765/repo, where each test VM serves the repository
#   - chumak/build-repo signs the repository with the TEST key and
#     publishes SHA256SUMS, SHA256SUMS.gpg, install.sh and
#     motanka-cli.tar.gz next to pool/ and dists/
#
# Test VMs, each from a fresh overlay:
#   resolute: fresh (install through the bootstrap), gnome-snaps, kde and
#             multiuser (install through the CLI), and a second fresh VM
#             for the interrupted install
#   noble:    fresh (install through the bootstrap)
# On each full run: Fingerprint, dry run, an independent apt simulation,
# (fresh only) refused bad repositories, Fingerprint again (must equal the
# first: 2.3), real install, package and ledger checks (3.1, 3.2, 3.7),
# Fingerprint of the home folders and dconf (must be unchanged: 3.8), rerun
# (3.10). The interrupted run kills the Installer after the keyring step,
# checks the ledger (3.9), reruns and checks the ledger is completed.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
MV_USAGE="test/vm/tests/install.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-install}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-install-test
REPO_URI=http://127.0.0.1:8765/repo
STACK_PKGS=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools motanka-stack)
# Built separately (several hours: test/vm/build --suite <release>
# packaging/motanka-qt6 packaging/motanka-stack-shell) and needed by the real
# motanka-core, which depends on motanka-stack-shell.
SHELL_PKGS=(motanka-qt6 motanka-stack-shell)
ver=$(bash "$MV_REPO/packaging/version.sh" "$release")

failures=0
pass() { mv_log "PASS: $*"; }
fail() {
  mv_log "FAIL: $*"
  failures=$((failures + 1))
}
finish() {
  mv_log "logs: $results"
  if ((failures > 0)); then
    mv_log "$failures check(s) failed"
    exit 1
  fi
  mv_log "all checks passed"
  exit 0
}

# --- 0. signing key -----------------------------------------------------------
if [[ ! -s $MV_KEYS/motanka-test-archive.sec.asc || ! -s $MV_KEYS/fingerprint ]]; then
  mv_die "no TEST signing key in $MV_KEYS; run chumak/gen-test-key first"
fi
key_fpr=$(tr -d '[:space:]' <"$MV_KEYS/fingerprint")
repo_fpr=$(sed -n 's/^# Fingerprint: //p' "$MV_REPO/packaging/keys/motanka-archive.asc" 2>/dev/null | tr -d '[:space:]')
if [[ $key_fpr != "$repo_fpr" ]]; then
  mv_die "packaging/keys/motanka-archive.asc (${repo_fpr:-none}) does not match the key in $MV_KEYS ($key_fpr); run chumak/gen-test-key"
fi

# --- 1. Stack .debs -------------------------------------------------------------
have_stack() {
  local p
  for p in "${STACK_PKGS[@]}"; do
    [[ -f $MV_DEBS/$release/${p}_${ver}_amd64.deb ]] || return 1
  done
}
if [[ ${MOTANKA_STACK_REBUILD:-0} == 1 ]] || ! have_stack; then
  mv_log "building packaging/motanka-stack for $release (this takes more than an hour)"
  if ! "$MV_LIB_DIR/build" --suite "$release" "$MV_REPO/packaging/motanka-stack" \
    >"$results/stack-debs.txt"; then
    fail "test/vm/build failed for motanka-stack on $release (logs in $results/build-$release*)"
    finish
  fi
fi
if ! have_stack; then
  fail "no motanka-stack .debs of version $ver in $MV_DEBS/$release/"
  finish
fi
pass "Stack .debs $ver for $release"

# --- 2. other packages and the test repository, in one build VM ----------------
core_dir=$MV_REPO/packaging/motanka-core
placeholder=1
if [[ ${MOTANKA_INSTALL_PLACEHOLDER_CORE:-0} != 1 ]] &&
  [[ -f $core_dir/debian/control || -f $core_dir/debian/control.in ]]; then
  placeholder=0
fi
pkgs=("$MV_REPO/packaging/motanka-archive-keyring" "$MV_REPO/packaging/motanka-source" "$MV_REPO/packaging/motanka")
if ((placeholder == 0)); then
  pkgs+=("$MV_REPO/packaging/motanka-fonts" "$core_dir")
  for p in "${SHELL_PKGS[@]}"; do
    if [[ ! -f $MV_DEBS/$release/${p}_${ver}_amd64.deb ]]; then
      fail "no $p .deb of version $ver in $MV_DEBS/$release/ (motanka-core depends on it); build it with test/vm/build --suite $release packaging/motanka-qt6 packaging/motanka-stack-shell"
    fi
  done
  if ((failures > 0)); then
    finish
  fi
fi

mv_up_build_vm
bvm=$MV_BOOTED
mv_log "building ${pkgs[*]##*/} for $release in $bvm"
if ! "$MV_LIB_DIR/build" --vm "$bvm" --suite "$release" "${pkgs[@]}" >"$results/debs.txt"; then
  fail "test/vm/build failed (logs in $results/build-$release*)"
  finish
fi

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/in" "$stage/guest" "$stage/cli/packaging/keys"
while IFS= read -r f; do
  base=${f##*/}
  case $base in
    *-dbgsym_*) continue ;;
    motanka-source-*)
      if [[ $base != "motanka-source-${release}_"* ]]; then
        continue
      fi
      ;;
  esac
  cp -f "$f" "$stage/in/"
done <"$results/debs.txt"
for p in "${STACK_PKGS[@]}"; do
  cp -f "$MV_DEBS/$release/${p}_${ver}_amd64.deb" "$stage/in/"
done
if ((placeholder == 0)); then
  for p in "${SHELL_PKGS[@]}"; do
    cp -f "$MV_DEBS/$release/${p}_${ver}_amd64.deb" "$stage/in/"
  done
  if [[ ! -f $stage/in/motanka-fonts_${ver}_all.deb ]]; then
    fail "test/vm/build did not produce motanka-fonts_${ver}_all.deb"
  fi
fi
for p in motanka-archive-keyring "motanka-source-$release" motanka; do
  if [[ ! -f $stage/in/${p}_${ver}_all.deb ]]; then
    fail "test/vm/build did not produce ${p}_${ver}_all.deb"
  fi
done
if ((placeholder == 0)) && ! compgen -G "$stage/in/motanka-core_${ver}_*.deb" >/dev/null; then
  fail "test/vm/build did not produce motanka-core $ver"
fi
if ((failures > 0)); then
  finish
fi
if ((placeholder)); then
  mv_log "NOTE: packaging/motanka-core does not exist yet (or MOTANKA_INSTALL_PLACEHOLDER_CORE=1);"
  mv_log "NOTE: this test builds a TEMPORARY PLACEHOLDER motanka-core (Depends: motanka-stack, no files)"
fi

mv_copy_to_vm "$bvm" "$stage/in" /tmp/inst-in
mv_copy_to_vm "$bvm" "$MV_KEYS" "/home/$MV_GUEST_USER/.cache/motanka-vm/keys"
rc=0
"$MV_LIB_DIR/run" "$bvm" -- bash -s -- "$release" "$ver" "$REPO_URI" "$placeholder" \
  <<'EOF' >"$results/build-repo.log" 2>&1 || rc=$?
set -euo pipefail
release=$1 ver=$2 uri=$3 placeholder=$4
in=/tmp/inst-in
out=/tmp/inst-repo
rm -rf "$out"
if [[ $placeholder == 1 ]]; then
  d=$(mktemp -d)
  mkdir -p "$d/DEBIAN" "$d/usr/share/doc/motanka-core"
  cat >"$d/DEBIAN/control" <<CTL
Package: motanka-core
Version: $ver
Architecture: all
Maintainer: Motanka test <test@example.test>
Depends: motanka-stack
Section: misc
Priority: optional
Description: TEST PLACEHOLDER for motanka-core, Installer VM test only
 Built by test/vm/tests/install.sh while packaging/motanka-core does not
 exist yet. It installs only this documentation file.
CTL
  printf 'Temporary placeholder built by test/vm/tests/install.sh.\n' \
    >"$d/usr/share/doc/motanka-core/README"
  chmod -R u=rwX,go=rX "$d"
  dpkg-deb --root-owner-group --build "$d" "$in/motanka-core_${ver}_all.deb" >/dev/null
  echo "PLACEHOLDER: built a temporary motanka-core $ver because packaging/motanka-core does not exist yet"
fi
for deb in "$in"/motanka-source-*_all.deb; do
  d=$(mktemp -d)
  dpkg-deb -R "$deb" "$d"
  f=$d/etc/apt/sources.list.d/motanka.sources
  sed -i "s|^URIs: .*|URIs: $uri|" "$f"
  grep -qxF "URIs: $uri" "$f"
  if [[ -f $d/DEBIAN/md5sums ]] && grep -q ' etc/apt/sources.list.d/motanka.sources$' "$d/DEBIAN/md5sums"; then
    sum=$(cd "$d" && md5sum etc/apt/sources.list.d/motanka.sources)
    sed -i "s|^[0-9a-f]*  etc/apt/sources.list.d/motanka.sources\$|$sum|" "$d/DEBIAN/md5sums"
  fi
  dpkg-deb --root-owner-group --build "$d" "$deb.new" >/dev/null
  mv -f "$deb.new" "$deb"
  echo "repacked ${deb##*/} with URIs: $uri"
done
bash ~/motanka/chumak/build-repo "$out" "$release=$in"
EOF
cat "$results/build-repo.log" >&2
if ((rc != 0)); then
  fail "making the test repository failed (exit $rc)"
  finish
fi
rm -rf -- "$results/repo"
mv_copy_from_vm "$bvm" /tmp/inst-repo "$results/repo"
mv_destroy "$bvm"
for f in SHA256SUMS SHA256SUMS.gpg install.sh motanka-cli.tar.gz; do
  if [[ ! -s $results/repo/$f ]]; then
    fail "the test repository has no $f"
  fi
done
if ! grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$results/repo/install.sh"; then
  fail "the published install.sh carries no archive key"
fi
if ((failures > 0)); then
  finish
fi
pass "test repository for $release with SHA256SUMS, its signature, install.sh and motanka-cli.tar.gz"

cp -f "$MV_LIB_DIR/install-guest.sh" "$stage/guest/install-guest.sh"
cp -a "$MV_REPO/src" "$stage/cli/src"
cp -f "$MV_REPO/packaging/keys/motanka-archive.asc" "$stage/cli/packaging/keys/"

# --- 3. test VMs ----------------------------------------------------------------

# guest_phase <vm> <label> <phase> [argument]: runs one guest phase, logs it
# and counts its checks. Returns the phase's exit code.
guest_phase() {
  local tvm=$1 label=$2 name=$3 arg=${4:-} rc=0 f p log
  log=$results/$label-$name.log
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/install-guest.sh" "$name" "$release" "$arg" \
    </dev/null >"$log" 2>&1 || rc=$?
  cat "$log" >&2
  f=$(grep -c '^FAIL:' "$log" || true)
  p=$(grep -c '^PASS:' "$log" || true)
  if ((rc == 0 && f == 0)); then
    pass "$label: guest phase $name${arg:+ $arg} ($p checks passed)"
  else
    failures=$((failures + (f > 0 ? f : 1)))
    mv_log "FAIL: $label: guest phase $name${arg:+ $arg} ($f failed, exit $rc)"
  fi
  return "$rc"
}

# fp_equal <label> <before> <after> <what>: tools/fpdiff.py finds no
# difference.
fp_equal() {
  local label=$1 a=$2 b=$3 what=$4 rc=0 out
  out=$results/$label-fpdiff-${a##*/}-${b##*/}.txt
  python3 "$MV_REPO/tools/fpdiff.py" "$a" "$b" >"$out" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "$label: $what"
  else
    fail "$label: $what: fpdiff exit $rc"
    cat "$out" >&2
  fi
}

# homes_equal <label> <before> <after>: the home-folder and dconf parts of
# two Fingerprints are equal, apart from the Allowlist (3.8).
homes_equal() {
  local label=$1 a=$2 b=$3 t
  local -a fa fb
  t=$results/$label-homes
  rm -rf -- "$t"
  mkdir -p "$t/before" "$t/after"
  shopt -s nullglob
  fa=("$a"/home-*.sha256 "$a"/dconf-*.ini)
  fb=("$b"/home-*.sha256 "$b"/dconf-*.ini)
  shopt -u nullglob
  if ((${#fa[@]} == 0)); then
    fail "$label: the Fingerprint $a has no home-folder files"
    return 0
  fi
  cp -f "${fa[@]}" "$t/before/"
  if ((${#fb[@]} > 0)); then
    cp -f "${fb[@]}" "$t/after/"
  fi
  fp_equal "$label" "$t/before" "$t/after" "no home folder and no dconf database changed during the install (3.8)"
}

# run_variant <variant> <full|interrupt> [bootstrap|cli]
run_variant() {
  local variant=$1 mode=$2 how=${3:-cli} label tvm="" fp_before fp_dry fp_inst
  label=$release-$variant
  if [[ $mode == interrupt ]]; then
    label=$label-interrupt
  fi
  mv_log "=== $label ($mode${how:+, $how})"
  tvm=$("$MV_LIB_DIR/up" "$release" "$variant" </dev/null | tail -n 1) || true
  if ! mv_valid_name "$tvm"; then
    fail "$label: test/vm/up $release $variant failed"
    return 0
  fi
  MV_CLEANUP_VMS+=("$tvm")
  mv_copy_to_vm "$tvm" "$stage/guest" "$GUEST_T"
  mv_copy_to_vm "$tvm" "$results/repo" "$GUEST_T/www/repo"
  mv_copy_to_vm "$tvm" "$stage/cli" "/home/$MV_GUEST_USER/motanka"
  if ! guest_phase "$tvm" "$label" serve; then
    mv_destroy "$tvm"
    return 0
  fi
  guest_phase "$tvm" "$label" snapshot before || true
  fp_before=$("$MV_LIB_DIR/fingerprint" "$tvm" "$label-before" | tail -n 1)

  if [[ $mode == full ]]; then
    guest_phase "$tvm" "$label" dryrun || true
    guest_phase "$tvm" "$label" simcheck || true
    if [[ $variant == fresh ]]; then
      guest_phase "$tvm" "$label" badrepos || true
    fi
    fp_dry=$("$MV_LIB_DIR/fingerprint" "$tvm" "$label-dry" | tail -n 1)
    fp_equal "$label" "$fp_before" "$fp_dry" \
      "the Fingerprint after the dry run, the apt simulation and the refused installs equals the one before (2.3)"
    if guest_phase "$tvm" "$label" install "$how"; then
      guest_phase "$tvm" "$label" check before || true
      fp_inst=$("$MV_LIB_DIR/fingerprint" "$tvm" "$label-installed" | tail -n 1)
      homes_equal "$label" "$fp_before" "$fp_inst"
      guest_phase "$tvm" "$label" rerun || true
    fi
  else
    if guest_phase "$tvm" "$label" interrupt; then
      guest_phase "$tvm" "$label" check before || true
      fp_inst=$("$MV_LIB_DIR/fingerprint" "$tvm" "$label-installed" | tail -n 1)
      homes_equal "$label" "$fp_before" "$fp_inst"
    fi
  fi
  mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$label-guest-logs" || true
  mv_destroy "$tvm"
}

if [[ $release == resolute ]]; then
  run_variant fresh full bootstrap
  run_variant gnome-snaps full cli
  run_variant kde full cli
  run_variant multiuser full cli
  run_variant fresh interrupt cli
else
  run_variant fresh full bootstrap
fi
finish
