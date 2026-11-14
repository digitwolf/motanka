#!/usr/bin/env bash
# VM round-trip test (task 19.4; requirements 10.1, 10.9, 10.13, 10.14,
# 13.1-13.3): Fingerprint, install through the real Installer from a local
# signed repository, first login into the Motanka session, a theme switch
# through the Upstream command, a menu package install through the Helper,
# a web app through the override, 'motanka remove', Fingerprint again; the
# two Fingerprints must be equal apart from the Allowlist (tools/fpdiff.py).
# The guest half is test/vm/remove-guest.sh.
#
# Usage: test/vm/tests/roundtrip.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE       resolute (default: variants fresh,
#                            fresh+apps, gnome-snaps+apps, kde+apps,
#                            multiuser) or noble (variants fresh,
#                            fresh+apps, gnome-snaps+apps, kde+apps)
#   MOTANKA_VM_RESULTS       log folder
#   MOTANKA_ROUNDTRIP_LOGIN  0 to skip the first login
#   MOTANKA_ROUNDTRIP_VARIANTS  space-separated subset of the variants; a
#                            variant with the suffix +apps installs with
#                            'motanka install --yes --apps' (task 26.3)
#
# Packages and repository: test/vm/local-repo.sh builds them once from the
# working tree (and reuses an earlier build of the same tree), so all
# variants install the same .debs.
#
# The round trip does the real first login (guest phase "login": the
# session launcher runs per-user setup, then the theme switch runs inside
# the session) whenever the installed motanka-core ships
# /opt/motanka/libexec/motanka/user-setup, checked in each VM after the
# install, and a virgl GPU is available (MOTANKA_VM_GPU=gl, spike S3).
# Only as a fallback, when one of these is missing or with
# MOTANKA_ROUNDTRIP_LOGIN=0, the login is skipped with SKIP lines saying
# why, per-user setup is stood in for by starting the User_Ledger through
# its library (guest phase "ledger-start", never used after a real login)
# and the theme switch runs without a session (OMARCHY_THEME_HEADLESS=1).
#
# Per variant, from a fresh overlay:
#   serve, snapshot "before", Fingerprint "before", install, (multiuser:
#   a User_Ledger in alice's home folder), login with a theme switch inside
#   the session (or the headless stand-ins), menu install, web app, logout,
#   capture check (the session capture was ended at logout and the
#   User_Ledger records no unplanned path),
#   'motanka remove --dry-run' (lists the menu package and the web app as
#   kept, and alice as another user), Fingerprint "pre-remove",
#   'motanka remove --yes --purge' with /usr/bin/motanka, Fingerprint
#   "after". The removal uses --purge because 10.1 requires the earlier
#   state, and without --purge the menu installs stay by design (10.9); the
#   dry run checks the listing without --purge. On multiuser, alice's home
#   folder is compared between "pre-remove" and "after" (unchanged, 10.13)
#   and left out of the "before"/"after" comparison. The comparison applies
#   the Allowlist and nothing else; tools/fpdiff.py reads the desktop class
#   of the Allowlist from compat/home-paths.tsv.
#
# A "+apps" pass (requirements 3.14, 3.15, 10.15) also takes a policy
# snapshot right before and right after the install and requires them to be
# equal (enabled system units, sysctl values, binfmt, modules-load.d,
# firewall rules, nsswitch.conf, polkit rules; a unit that turns active only
# counts when a package of the install owns it), checks motanka-apps,
# motanka-herdr, herdr and the ledgered answer after the install, and that
# all three are gone after the removal. Its label ends in "-apps".
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/roundtrip.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-roundtrip}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-remove-test

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

if [[ $release == resolute ]]; then
  variants=(fresh fresh+apps gnome-snaps+apps kde+apps multiuser)
else
  variants=(fresh fresh+apps gnome-snaps+apps kde+apps)
fi
if [[ -n ${MOTANKA_ROUNDTRIP_VARIANTS:-} ]]; then
  read -r -a variants <<<"$MOTANKA_ROUNDTRIP_VARIANTS"
  for v in "${variants[@]}"; do
    mv_check_variant "${v%+apps}"
  done
fi

GUEST_USER_SETUP=/opt/motanka/libexec/motanka/user-setup

# The real first login runs unless it cannot: these reasons apply to every
# variant; run_variant also checks, after the install, that motanka-core
# ships per-user setup ($GUEST_USER_SETUP).
login=1
reason=""
if [[ ${MOTANKA_ROUNDTRIP_LOGIN:-1} == 0 ]]; then
  login=0 reason="MOTANKA_ROUNDTRIP_LOGIN=0"
elif [[ ! -r $MV_GL_RENDER_NODE || ! -w $MV_GL_RENDER_NODE ]]; then
  login=0 reason="MOTANKA_VM_GPU=gl needs read and write access to $MV_GL_RENDER_NODE"
fi

# skip_login <why>: the SKIP lines of the fallback without a login.
skip_login() {
  mv_log "SKIP: first login into the Motanka session: $1."
  mv_log "SKIP: the round trip runs without a login: the User_Ledger is started through its library and the theme switch runs headless."
}

if ((login == 0)); then
  skip_login "$reason"
fi

# --- packages and repository ----------------------------------------------------
if ! lr_repo "$release" "$results"; then
  fail "no test repository for $release"
  finish
fi
pass "test repository for $release: $LR_REPO (version $LR_VER)"

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/guest" "$stage/cli/packaging/keys"
cp -f "$MV_LIB_DIR/remove-guest.sh" "$stage/guest/remove-guest.sh"
cp -f "$MV_LIB_DIR/policy-sysctl.py" "$stage/guest/policy-sysctl.py"
cp -f "$MV_REPO/tools/fpdiff.py" "$stage/guest/fpdiff.py"
cp -a "$MV_REPO/src" "$stage/cli/src"
cp -f "$MV_REPO/packaging/keys/motanka-archive.asc" "$stage/cli/packaging/keys/"

# --- helpers --------------------------------------------------------------------

# guest_phase <vm> <label> <phase> [arguments...]: runs one guest phase,
# logs it and counts its checks. Returns the phase's exit code.
guest_phase() {
  local tvm=$1 label=$2 name=$3 rc=0 f p log
  shift 3
  log=$results/$label-$name.log
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/remove-guest.sh" "$name" "$release" "$@" \
    </dev/null >"$log" 2>&1 || rc=$?
  cat "$log" >&2
  f=$(grep -c '^FAIL:' "$log" || true)
  p=$(grep -c '^PASS:' "$log" || true)
  if ((rc == 0 && f == 0)); then
    pass "$label: guest phase $name${*:+ $*} ($p checks passed)"
  else
    failures=$((failures + (f > 0 ? f : 1)))
    mv_log "FAIL: $label: guest phase $name${*:+ $*} ($f failed, exit $rc)"
  fi
  return "$rc"
}

# fingerprint <vm> <label>: prints the Fingerprint folder, or nothing.
fingerprint() {
  "$MV_LIB_DIR/fingerprint" "$1" "$2" </dev/null | tail -n 1 || true
}

# fp_equal <label> <before> <after> <what> [only|without <file>...]:
# tools/fpdiff.py finds no difference, optionally on a subset of the files.
fp_equal() {
  local label=$1 a=$2 b=$3 what=$4 mode=${5:-} rc=0 out t f
  shift 4
  if [[ -z $a || -z $b || ! -d $a || ! -d $b ]]; then
    fail "$label: $what: a Fingerprint is missing"
    return 0
  fi
  if [[ -n $mode ]]; then
    shift
    t=$(mktemp -d "$results/$label-fp.XXXXXX")
    mkdir -p "$t/a" "$t/b"
    if [[ $mode == only ]]; then
      for f in "$@"; do
        cp -f "$a/$f" "$t/a/" 2>/dev/null || true
        cp -f "$b/$f" "$t/b/" 2>/dev/null || true
      done
    else
      cp -f "$a"/* "$t/a/"
      cp -f "$b"/* "$t/b/"
      for f in "$@"; do
        rm -f -- "$t/a/$f" "$t/b/$f"
      done
    fi
    a=$t/a b=$t/b
  fi
  out=$(mktemp "$results/$label-fpdiff.XXXXXX")
  python3 "$MV_REPO/tools/fpdiff.py" "$a" "$b" >"$out" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "$label: $what"
  else
    fail "$label: $what: fpdiff exit $rc (details in $out)"
    head -n 60 "$out" >&2
  fi
}

run_variant() {
  local variant=${1%+apps} apps=0 label tvm fp_before fp_pre fp_after logged_in=0 do_login=$login rc=0
  local -a others=()
  [[ $1 == *+apps ]] && apps=1
  label=$release-$variant
  ((apps)) && label+=-apps
  if [[ $variant == multiuser ]]; then
    others=(alice)
  fi
  if ((login)); then
    mv_log "=== $label (with the first login, if motanka-core ships per-user setup)"
  else
    mv_log "=== $label (first login skipped)"
  fi
  if ((login)); then
    tvm=$(MOTANKA_VM_GPU=gl "$MV_LIB_DIR/up" "$release" "$variant" </dev/null | tail -n 1) || true
  else
    tvm=$("$MV_LIB_DIR/up" "$release" "$variant" </dev/null | tail -n 1) || true
  fi
  if ! mv_valid_name "$tvm"; then
    fail "$label: test/vm/up $release $variant failed"
    return 0
  fi
  MV_CLEANUP_VMS+=("$tvm")
  mv_copy_to_vm "$tvm" "$stage/guest" "$GUEST_T"
  mv_copy_to_vm "$tvm" "$LR_REPO" "$GUEST_T/www/repo"
  mv_copy_to_vm "$tvm" "$stage/cli" "/home/$MV_GUEST_USER/motanka"
  if ! guest_phase "$tvm" "$label" serve; then
    mv_destroy "$tvm"
    return 0
  fi
  guest_phase "$tvm" "$label" snapshot before || true
  fp_before=$(fingerprint "$tvm" "$label-before")

  local -a install_args=()
  if ((apps)); then
    install_args=(apps)
    guest_phase "$tvm" "$label" policy before || true
  fi
  if ! guest_phase "$tvm" "$label" install "${install_args[@]}"; then
    mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$label-guest-logs" || true
    mv_destroy "$tvm"
    return 0
  fi
  if ((apps)); then
    guest_phase "$tvm" "$label" policy after-install || true
    guest_phase "$tvm" "$label" policy-compare before after-install || true
    guest_phase "$tvm" "$label" apps installed || true
  fi
  if ((${#others[@]} > 0)); then
    guest_phase "$tvm" "$label" other-ledger "${others[@]}" || true
  fi
  if ((do_login)); then
    "$MV_LIB_DIR/run" "$tvm" -- test -x "$GUEST_USER_SETUP" </dev/null >/dev/null 2>&1 || rc=$?
    if ((rc == 0)); then
      pass "$label: the installed motanka-core ships $GUEST_USER_SETUP; the round trip logs in for real"
    elif ((rc == 1)); then
      do_login=0
      skip_login "$label: the installed motanka-core does not ship $GUEST_USER_SETUP"
    else
      do_login=0
      fail "$label: cannot check for $GUEST_USER_SETUP in the VM (test/vm/run exit $rc)"
    fi
  fi
  if ((do_login)); then
    if guest_phase "$tvm" "$label" login; then
      logged_in=1
    fi
  else
    guest_phase "$tvm" "$label" ledger-start || true
    guest_phase "$tvm" "$label" theme || true
  fi
  guest_phase "$tvm" "$label" menu-install || true
  guest_phase "$tvm" "$label" webapp || true
  if ((do_login)); then
    guest_phase "$tvm" "$label" logout || true
    if ((!logged_in)); then
      mv_log "note: $label: the login phase failed; the round trip continues after logout"
    fi
    guest_phase "$tvm" "$label" capture-check session || true
  else
    guest_phase "$tvm" "$label" capture-check none || true
  fi
  guest_phase "$tvm" "$label" remove-dry installed "${others[@]}" || true
  fp_pre=$(fingerprint "$tvm" "$label-pre-remove")
  guest_phase "$tvm" "$label" remove installed online --purge || true
  fp_after=$(fingerprint "$tvm" "$label-after")
  if ((apps)); then
    guest_phase "$tvm" "$label" apps gone || true
  fi

  if ((${#others[@]} > 0)); then
    fp_equal "$label" "$fp_before" "$fp_after" \
      "after removal the Fingerprint equals the one before installation, apart from the Allowlist and alice's home folder (10.1)" \
      without home-alice.sha256
    fp_equal "$label" "$fp_pre" "$fp_after" \
      "alice's home folder, which has a User_Ledger, is unchanged by the removal (10.13)" \
      only home-alice.sha256 dconf-alice.ini
  else
    fp_equal "$label" "$fp_before" "$fp_after" \
      "after removal the Fingerprint equals the one before installation, apart from the Allowlist (10.1, 13.3)"
  fi
  mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$label-guest-logs" || true
  mv_destroy "$tvm"
}

for v in "${variants[@]}"; do
  run_variant "$v"
done
finish
