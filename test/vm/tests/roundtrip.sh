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
#   MOTANKA_VM_RELEASE       resolute (default: variants fresh, gnome-snaps,
#                            kde, multiuser) or noble (variant fresh)
#   MOTANKA_VM_RESULTS       log folder
#   MOTANKA_ROUNDTRIP_LOGIN  0 to skip the first login
#   MOTANKA_ROUNDTRIP_VARIANTS  space-separated subset of the variants
#
# Packages and repository: test/vm/local-repo.sh builds them once from the
# working tree (and reuses an earlier build of the same tree), so all
# variants install the same .debs.
#
# The first login needs per-user setup (src/libexec/user-setup, shipped in
# motanka-core) and a virgl GPU (MOTANKA_VM_GPU=gl, spike S3). Without
# either, the login is skipped with a SKIP line saying why, per-user setup
# is stood in for by starting the User_Ledger through its library, and the
# theme switch runs without a session (OMARCHY_THEME_HEADLESS=1).
#
# Per variant, from a fresh overlay:
#   serve, snapshot "before", Fingerprint "before", install, (multiuser:
#   a User_Ledger in alice's home folder), login with a theme switch inside
#   the session (or the headless stand-ins), menu install, web app, logout,
#   'motanka remove --dry-run' (lists the menu package and the web app as
#   kept, and alice as another user), Fingerprint "pre-remove",
#   'motanka remove --yes --purge' with /usr/bin/motanka, Fingerprint
#   "after". The removal uses --purge because 10.1 requires the earlier
#   state, and without --purge the menu installs stay by design (10.9); the
#   dry run checks the listing without --purge. On multiuser, alice's home
#   folder is compared between "pre-remove" and "after" (unchanged, 10.13)
#   and left out of the "before"/"after" comparison.
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
  variants=(fresh gnome-snaps kde multiuser)
else
  variants=(fresh)
fi
if [[ -n ${MOTANKA_ROUNDTRIP_VARIANTS:-} ]]; then
  read -r -a variants <<<"$MOTANKA_ROUNDTRIP_VARIANTS"
  for v in "${variants[@]}"; do
    mv_check_variant "$v"
  done
fi

login=1
reason=""
if [[ ${MOTANKA_ROUNDTRIP_LOGIN:-1} == 0 ]]; then
  login=0 reason="MOTANKA_ROUNDTRIP_LOGIN=0"
elif [[ ! -f $MV_REPO/src/libexec/user-setup ]]; then
  login=0 reason="per-user setup (src/libexec/user-setup) is not part of motanka-core yet"
elif [[ ! -r $MV_GL_RENDER_NODE || ! -w $MV_GL_RENDER_NODE ]]; then
  login=0 reason="MOTANKA_VM_GPU=gl needs read and write access to $MV_GL_RENDER_NODE"
fi
if ((login == 0)); then
  mv_log "SKIP: first login into the Motanka session: $reason."
  mv_log "SKIP: the round trip runs without a login: the User_Ledger is started through its library and the theme switch runs headless."
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
  local variant=$1 label tvm fp_before fp_pre fp_after logged_in=0
  local -a others=()
  label=$release-$variant
  if [[ $variant == multiuser ]]; then
    others=(alice)
  fi
  if ((login)); then
    mv_log "=== $label (with the first login)"
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

  if ! guest_phase "$tvm" "$label" install; then
    mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$label-guest-logs" || true
    mv_destroy "$tvm"
    return 0
  fi
  if ((${#others[@]} > 0)); then
    guest_phase "$tvm" "$label" other-ledger "${others[@]}" || true
  fi
  if ((login)); then
    if guest_phase "$tvm" "$label" login; then
      logged_in=1
    fi
  else
    guest_phase "$tvm" "$label" ledger-start || true
    guest_phase "$tvm" "$label" theme || true
  fi
  guest_phase "$tvm" "$label" menu-install || true
  guest_phase "$tvm" "$label" webapp || true
  if ((login)); then
    guest_phase "$tvm" "$label" logout || true
    if ((!logged_in)); then
      mv_log "note: $label: the login phase failed; the round trip continues after logout"
    fi
  fi
  guest_phase "$tvm" "$label" remove-dry installed "${others[@]}" || true
  fp_pre=$(fingerprint "$tvm" "$label-pre-remove")
  guest_phase "$tvm" "$label" remove installed online --purge || true
  fp_after=$(fingerprint "$tvm" "$label-after")

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
