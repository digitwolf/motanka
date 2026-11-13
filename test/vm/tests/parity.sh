#!/usr/bin/env bash
# VM test of parity with Upstream on Arch Linux (task 24.3; requirement
# 13.6): run the same probe (test/parity/probe.sh) in a reference VM that
# runs Upstream at the stable pin on Arch Linux and in a Motanka VM, save
# both documents and screenshots, and compare them with test/parity/diff.py
# against the accepted differences in test/parity/expected.tsv.
#
# Usage: test/vm/tests/parity.sh
#   test/run-all runs it only with MOTANKA_VM_PARITY=1: the first run builds
#   the Arch reference image (test/vm/image arch omarchy), which downloads
#   and installs several GB, and the stable pin must still be the version
#   Upstream's stable package repository serves.
#
# Environment:
#   MOTANKA_VM_RELEASE     release of the Motanka VM: resolute (default) or
#                          noble
#   MOTANKA_VM_RESULTS     log folder
#   MOTANKA_PARITY_SETTLE  seconds each session settles before the probe
#                          records it (default 20)
#   MOTANKA_PARITY_FIRST_RUN_TIMEOUT
#                          seconds the probe in the Motanka VM waits for
#                          Upstream's first-run work (default 300)
#   test/vm/image documents MOTANKA_VM_ARCH_IMAGE_VERSION,
#   MOTANKA_VM_ARCH_KEYRING, MOTANKA_VM_ARCH_KEY_FPR and
#   MOTANKA_PARITY_ARCH_ANY_VERSION for the reference image.
#
# Both VMs need MOTANKA_VM_GPU=gl (Hyprland in QEMU, spike S3), so the user
# needs read and write access to the host's render node.
#
# The Motanka VM (multiuser variant) gets Motanka the way a user installs
# it: test/vm/local-repo.sh builds the Motanka packages of the working tree
# once (or reuses an earlier build of the same tree) and publishes them in a
# signed local repository, and the real Installer ('motanka install --yes'
# from the source tree, guest phases serve and install of
# test/vm/remove-guest.sh, as test/vm/tests/roundtrip.sh runs them) installs
# Motanka with the Package_Map's Ubuntu packages from it. The Stack .debs,
# motanka-qt6 and motanka-stack-shell must be cached in
# ~/.cache/motanka-vm/debs/<release>/; when the last two are missing the
# test fails with the build commands. Then the phases prepare, login and
# logout of test/vm/first-login-guest.sh log alice in: tty1 autologin runs
# the Motanka session launcher. prepare installs the test tool grim (for
# the screenshot) when the Installer did not; the log says so, because the
# probe's "tools" category then no longer shows that gap.
#
# In both VMs the probe runs as user alice inside her running session: on
# the reference VM SDDM logs her into Upstream's omarchy.desktop session at
# boot. In the Motanka VM the probe first waits (probe.sh --wait-*) until
# Upstream's first-run work is done: the default theme is recorded in
# ~/.local/state/motanka/default-theme, the wallpaper layer
# omarchy-background is mapped and no omarchy-provision-first-run process
# runs. What was not reached is printed and recorded in probe.json as the
# error "first-run", which diff.py reports.
#
# Results in MOTANKA_VM_RESULTS:
#   reference/probe.json, reference/screenshot.png, reference/raw/
#   motanka/probe.json, motanka/screenshot.png, motanka/raw/
#   parity-diff.txt                  the output of diff.py
#   probe-reference.log, probe-motanka.log
#   reference-install.log            Upstream's /var/log/omarchy-install.log
#   reference-state.tsv              the reference image's record (pin,
#                                    package versions, step results) and
#                                    the files of /usr/share/omarchy that
#                                    differ from the pinned tarball
#   reference-journal.log
#   debs.txt, build-*.log            the package build (when not reused)
#   guest-serve.log, guest-install.log
#                                    the Installer phases
#   system-ledger.tsv                the Motanka VM's System_Ledger: the
#                                    Ubuntu packages the Installer added
#   guest-prepare.log, guest-login.log, guest-logout.log
#                                    the first-login phases
#   guest-logs/installer/, guest-logs/first-login/
# The test fails if the install fails, a probe document is missing or
# diff.py reports an unexpected difference.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/parity.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar gpgv git
settle=${MOTANKA_PARITY_SETTLE:-20}
if [[ ! $settle =~ ^[0-9]+$ ]]; then
  mv_usage "MOTANKA_PARITY_SETTLE must be a number of seconds, got '$settle'"
fi
first_run_timeout=${MOTANKA_PARITY_FIRST_RUN_TIMEOUT:-300}
if [[ ! $first_run_timeout =~ ^[1-9][0-9]*$ ]]; then
  mv_usage "MOTANKA_PARITY_FIRST_RUN_TIMEOUT must be a number of seconds, got '$first_run_timeout'"
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-parity}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
PARITY="$MV_REPO/test/parity"
GUEST_P=/tmp/motanka-parity
GUEST_T=/tmp/motanka-first-login
GUEST_R=/tmp/motanka-remove-test
# Packages lr_repo adds only when they are cached, and motanka-core needs.
SHELL_PKGS=(motanka-qt6 motanka-stack-shell)
# Upstream's first-run work in the Motanka session (probe.sh --wait-*).
FIRST_RUN_WAIT=(--first-run-timeout "$first_run_timeout"
  --wait-file .local/state/motanka/default-theme
  --wait-layer omarchy-background
  --wait-gone omarchy-provision-first-run)
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

# deb_of <package>: the cached .deb of the current version, or nothing.
deb_of() {
  local f
  for f in "$MV_DEBS/$release/${1}_${ver}_amd64.deb" "$MV_DEBS/$release/${1}_${ver}_all.deb"; do
    if [[ -f $f ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# up_vm <release> <variant> <ram>: boots a VM with a virgl GPU, registers it
# for cleanup and prints its name; prints nothing if it did not start.
up_vm() {
  local name
  name=$(MOTANKA_VM_GPU=gl MOTANKA_VM_RAM=${MOTANKA_VM_RAM:-$3} "$MV_LIB_DIR/up" "$1" "$2" </dev/null | tail -n 1) || true
  if mv_valid_name "$name"; then
    printf '%s\n' "$name"
  fi
}

# probe_vm <vm> <label> [probe.sh options...]: runs the probe as alice in
# her session and copies its results to $results/<label>/. Returns 1 if
# there is no probe.json.
probe_vm() {
  local vm=$1 label=$2 rc=0 opts=""
  shift 2
  if (($# > 0)); then
    printf -v opts ' %q' "$@"
  fi
  mv_copy_to_vm "$vm" "$results/stage-probe" "$GUEST_P"
  "$MV_LIB_DIR/run" "$vm" -- "sudo chmod 0755 $GUEST_P && sudo chmod 0644 $GUEST_P/probe.sh $GUEST_P/probe.py &&
    sudo rm -rf $GUEST_P/out && sudo install -d -o alice -g alice -m 0755 $GUEST_P/out" </dev/null
  "$MV_LIB_DIR/run" "$vm" -- "sudo -u alice env -i HOME=/home/alice USER=alice LOGNAME=alice \
    PATH=/usr/local/bin:/usr/bin:/bin XDG_RUNTIME_DIR=/run/user/\$(id -u alice) \
    bash $GUEST_P/probe.sh --out $GUEST_P/out --settle $settle$opts" \
    </dev/null >"$results/probe-$label.log" 2>&1 || rc=$?
  cat "$results/probe-$label.log" >&2
  rm -rf -- "${results:?}/$label"
  mv_copy_from_vm "$vm" "$GUEST_P/out" "$results/$label" || true
  if [[ ! -s $results/$label/probe.json ]]; then
    fail "$label: the probe wrote no probe.json (exit $rc)"
    return 1
  fi
  if ((rc == 0)); then
    pass "$label: probe.json and screenshot.png written"
  else
    fail "$label: the probe found no running session (exit $rc); see $label/probe.json"
  fi
}

# phase <installer|first-login> <name> [arguments...]: runs one guest phase
# in the Motanka VM, of test/vm/remove-guest.sh or
# test/vm/first-login-guest.sh, and logs it.
phase() {
  local script=$1 name=$2 rc=0 f
  local -a cmd
  shift 2
  case $script in
    installer) cmd=(bash "$GUEST_R/remove-guest.sh" "$name" "$release" "$@") ;;
    first-login) cmd=(bash "$GUEST_T/first-login-guest.sh" "$name" "$release") ;;
  esac
  "$MV_LIB_DIR/run" "$tvm" -- "${cmd[@]}" </dev/null >"$results/guest-$name.log" 2>&1 || rc=$?
  cat "$results/guest-$name.log" >&2
  f=$(grep -c '^FAIL:' "$results/guest-$name.log" || true)
  mv_log "guest phase $name: exit $rc, $f failed check(s)"
  return "$rc"
}

# collect_motanka_logs: copies the Motanka VM's guest logs and its
# System_Ledger to the results.
collect_motanka_logs() {
  mv_copy_from_vm "$tvm" "$GUEST_R/logs" "$results/guest-logs/installer" || true
  mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/guest-logs/first-login" || true
  "$MV_LIB_DIR/run" "$tvm" -- 'sudo cat /var/lib/motanka/ledger' \
    </dev/null >"$results/system-ledger.tsv" 2>&1 || true
}

# --- 1. what the test needs ---------------------------------------------------
if [[ ! -r $MV_GL_RENDER_NODE || ! -w $MV_GL_RENDER_NODE ]]; then
  fail "both VMs need MOTANKA_VM_GPU=gl: read and write access to $MV_GL_RENDER_NODE"
  finish
fi
missing=()
for p in "${SHELL_PKGS[@]}"; do
  if ! deb_of "$p" >/dev/null; then
    missing+=("${p}_${ver}_{amd64,all}.deb")
  fi
done
if ((${#missing[@]} > 0)); then
  fail "missing .debs of version $ver in $MV_DEBS/$release/: ${missing[*]} (motanka-core depends on them)"
  mv_log "build them first, for example:"
  mv_log "  test/vm/build --suite $release packaging/motanka-qt6 packaging/motanka-stack-shell"
  finish
fi

if ! lr_repo "$release" "$results"; then
  fail "no test repository for $release"
  finish
fi
pass "test repository for $release: $LR_REPO (version $LR_VER)"

rm -rf -- "$results/stage" "$results/stage-probe"
mkdir -p "$results/stage/first-login" "$results/stage/installer" "$results/stage/cli/packaging/keys" \
  "$results/stage-probe"
cp -f "$MV_LIB_DIR/first-login-guest.sh" "$results/stage/first-login/first-login-guest.sh"
cp -f "$MV_LIB_DIR/remove-guest.sh" "$results/stage/installer/remove-guest.sh"
cp -a "$MV_REPO/src" "$results/stage/cli/src"
cp -f "$MV_REPO/packaging/keys/motanka-archive.asc" "$results/stage/cli/packaging/keys/"
cp -f "$PARITY/probe.sh" "$PARITY/probe.py" "$results/stage-probe/"

# --- 2. the reference VM: Upstream on Arch Linux --------------------------------
mv_log "booting the Arch Linux reference VM (the first run builds its base image)"
rvm=$(up_vm "$MV_ARCH_RELEASE" "$MV_ARCH_VARIANT" 6G)
if [[ -z $rvm ]]; then
  fail "the reference VM did not start (test/vm/up $MV_ARCH_RELEASE $MV_ARCH_VARIANT)"
else
  MV_CLEANUP_VMS+=("$rvm")
  probe_vm "$rvm" reference || true
  "$MV_LIB_DIR/run" "$rvm" -- 'sudo cat /var/log/omarchy-install.log' \
    </dev/null >"$results/reference-install.log" 2>&1 || true
  "$MV_LIB_DIR/run" "$rvm" -- 'cat /var/lib/motanka-parity/reference.tsv; echo; cat /var/lib/motanka-parity/pin-check.tsv' \
    </dev/null >"$results/reference-state.tsv" 2>&1 || true
  "$MV_LIB_DIR/run" "$rvm" -- 'sudo journalctl -b --no-pager -n 3000' \
    </dev/null >"$results/reference-journal.log" 2>&1 || true
  mv_destroy "$rvm"
fi

# --- 3. the Motanka VM -----------------------------------------------------------
mv_log "booting the Motanka VM ($release multiuser)"
tvm=$(up_vm "$release" multiuser 4G)
if [[ -z $tvm ]]; then
  fail "the Motanka VM did not start (test/vm/up $release multiuser)"
else
  MV_CLEANUP_VMS+=("$tvm")
  mv_copy_to_vm "$tvm" "$results/stage/installer" "$GUEST_R"
  mv_copy_to_vm "$tvm" "$LR_REPO" "$GUEST_R/www/repo"
  mv_copy_to_vm "$tvm" "$results/stage/cli" "/home/$MV_GUEST_USER/motanka"
  mv_copy_to_vm "$tvm" "$results/stage/first-login" "$GUEST_T"
  if phase installer serve && phase installer install; then
    pass "the Installer installed Motanka from the test repository (guest-install.log)"
    rc=0
    # shellcheck disable=SC2016 # dpkg-query field, expanded in the VM
    "$MV_LIB_DIR/run" "$tvm" -- 'test "$(dpkg-query -W -f="\${db:Status-Status}" grim 2>/dev/null)" = installed' \
      </dev/null >/dev/null 2>&1 || rc=$?
    if ((rc != 0)); then
      mv_log "note: the Installer did not install grim; the prepare phase installs it for the screenshot, so tools.grim hides that gap"
    fi
    if ! phase first-login prepare; then
      mv_log "note: the prepare phase failed (guest-prepare.log); logging in anyway"
    fi
    if ! phase first-login login; then
      mv_log "note: first-login checks failed in the login phase (guest-login.log); probing anyway"
    fi
    probe_vm "$tvm" motanka "${FIRST_RUN_WAIT[@]}" || true
    phase first-login logout || true
  else
    fail "the Installer could not install Motanka (guest-serve.log, guest-install.log, guest-logs/installer/)"
  fi
  collect_motanka_logs
  mv_destroy "$tvm"
fi

# --- 4. the comparison -------------------------------------------------------------
if [[ -s $results/reference/probe.json && -s $results/motanka/probe.json ]]; then
  rc=0
  python3 "$PARITY/diff.py" --expected "$PARITY/expected.tsv" \
    "$results/reference/probe.json" "$results/motanka/probe.json" >"$results/parity-diff.txt" 2>&1 || rc=$?
  cat "$results/parity-diff.txt" >&2
  case $rc in
    0) pass "no unexpected difference from Upstream on Arch Linux (parity-diff.txt)" ;;
    1) fail "unexpected differences from Upstream on Arch Linux (parity-diff.txt)" ;;
    *) fail "diff.py failed (exit $rc, parity-diff.txt)" ;;
  esac
else
  fail "no comparison: a probe document is missing"
fi
finish
