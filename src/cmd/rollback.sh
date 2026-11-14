# shellcheck shell=bash
# shellcheck disable=SC2329 # functions are called by src/motanka and by the unit tests
# motanka rollback (design.md, "Updater, snapshots and rollback";
# requirement 9.9).
#
# Steps, in order. Nothing changes before step 6.
#   1. options; root (exit 11); the system lock (exit 9)
#   2. the latest complete snapshot (src/lib/snapshot.sh); with none, exit 1
#   3. the Plan:
#      - every Motanka_Package of the snapshot goes back to its version,
#        from the .deb stored in the snapshot, so rollback works offline and
#        whether or not the repository still has that version (design.md,
#        Departures);
#      - Motanka_Packages installed now that the snapshot does not list are
#        removed;
#      - the invoking user's (SUDO_USER, else PKEXEC_UID) ledgered files and
#        Namespaced_Paths are restored from the snapshot's archive, as that
#        user. ~/.local/state/motanka, the User_Ledger, stays as it is.
#        Other users' files are not touched.
#   4. the .debs of the packages whose version differs are copied into
#      /var/lib/motanka/rollback.XXXXXX (on disk: a Stack .deb can be larger
#      than /run allows), where apt's _apt user can read them, and a
#      simulated "apt-get install --allow-downgrades <debs> <extra>-" must
#      change no Foreign_Package (exit 5)
#   5. --dry-run prints the Plan and exits 0
#   6. confirmation (or --yes); System_Ledger: run-begin update <version of
#      the snapshot>, one plan line per simulated action. The System_Ledger
#      format has no kind for a rollback; an update run is the closest, and
#      the Remover reads its plan lines the same way.
#   7. apt-get install --no-install-recommends of the .debs (with
#      --no-remove unless the simulation removes Motanka_Packages only);
#      Motanka packages that were marked automatically installed are marked
#      so again; pkg-installed lines for new Foreign_Packages (3.7)
#   8. the invoking user's archive is restored
#   9. run-end ok. The snapshot stays, so a rollback can be repeated.
# After run-begin, any exit other than success appends run-end failed.
#
# Exit codes: 0 rolled back (or dry run); 1 error, also when there is no
# snapshot; 2 usage; 5 a package Motanka does not own would change; 7 guard;
# 9 lock held; 11 not root.
#
# Test hooks: as src/cmd/update.sh.

if [[ -n ${MK_ROLLBACK_LOADED:-} ]]; then
  return 0
fi
MK_ROLLBACK_LOADED=1

_mk_rb_base=${MK_LIBEXEC:-}
if [[ -z $_mk_rb_base ]]; then
  _mk_rb_base=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
# shellcheck source=../lib/common.sh
source "$_mk_rb_base/lib/common.sh"
# shellcheck source=../lib/sysledger.sh
source "$_mk_rb_base/lib/sysledger.sh"
# shellcheck source=../lib/aptsim.sh
source "$_mk_rb_base/lib/aptsim.sh"
# shellcheck source=../lib/userledger.sh
source "$_mk_rb_base/lib/userledger.sh"
# shellcheck source=../lib/snapshot.sh
source "$_mk_rb_base/lib/snapshot.sh"

readonly MK_RB_WORK=/var/lib/motanka

MK_RB_ID=""
MK_RB_DIR=""
MK_RB_BEGUN=0 MK_RB_ENDED=0
MK_RB_USER="" MK_RB_UID=""
MK_RB_NAMES=() MK_RB_VERS=() MK_RB_DEBS=() MK_RB_EXTRA=() MK_RB_CHANGED=()

mk_rollback_usage() {
  cat <<'EOF'
usage: motanka rollback [--dry-run] [--yes]

Reinstalls the Motanka packages stored in the latest snapshot and restores
your ledgered home-folder files from it.

  --dry-run   print what would be restored, change nothing
  --yes, -y   do not ask for confirmation
  -h, --help  show this help
EOF
}

_mk_rb_require_root() {
  if [[ $(id -u) != 0 ]]; then
    mk_die "$MK_EXIT_AUTH" "motanka rollback must run as root: sudo motanka rollback"
  fi
}

# _mk_rb_invoking_user: MK_RB_USER and MK_RB_UID, or nothing for root.
_mk_rb_invoking_user() {
  local who="" entry uid name
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    who=$SUDO_USER
  elif [[ ${PKEXEC_UID:-} =~ ^[0-9]+$ && $PKEXEC_UID != 0 ]]; then
    who=$PKEXEC_UID
  fi
  if [[ -z $who ]]; then
    return 0
  fi
  if ! entry=$(mk_snapshot_lookup_user "$who"); then
    mk_warn "the invoking user '$who' has no passwd entry; no home folder is restored"
    return 0
  fi
  IFS=$'\t' read -r uid _ name _ <<<"$entry"
  if [[ $uid != 0 ]]; then
    MK_RB_USER=$name
    MK_RB_UID=$uid
  fi
}

# _mk_rb_load: the snapshot's packages, the indexes of those whose installed
# version differs (MK_RB_CHANGED), and the Motanka packages installed now
# that the snapshot does not list.
_mk_rb_load() {
  local line name ver deb have
  local -A listed=()
  MK_RB_NAMES=() MK_RB_VERS=() MK_RB_DEBS=() MK_RB_EXTRA=() MK_RB_CHANGED=()
  while IFS=$'\t' read -r name ver _ deb; do
    have=$(mk_installed_version "$name") || have=""
    if [[ $have != "$ver" ]]; then
      MK_RB_CHANGED+=("${#MK_RB_NAMES[@]}")
    fi
    MK_RB_NAMES+=("$name")
    MK_RB_VERS+=("$ver")
    MK_RB_DEBS+=("$deb")
    listed[$name]=1
  done < <(mk_snapshot_manifest "$MK_RB_ID")
  if ((${#MK_RB_NAMES[@]} == 0)); then
    mk_die "$MK_EXIT_ERROR" "the snapshot $MK_RB_ID lists no Motanka package; nothing was changed"
  fi
  while IFS= read -r line; do
    name=${line%%$'\t'*}
    if [[ -z ${listed[$name]:-} ]]; then
      MK_RB_EXTRA+=("$name")
    fi
  done < <(mk_snapshot_motanka_packages)
}

# _mk_rb_stage: copies the .debs of the changed packages into
# MK_RB_DIR/debs, after deleting folders left by killed rollbacks.
_mk_rb_stage() {
  local work d i src old
  work=$(mk_path "$MK_RB_WORK")
  if ! mkdir -p -- "$work"; then
    mk_die "$MK_EXIT_ERROR" "cannot create $work; nothing was changed"
  fi
  for old in "$work"/rollback.*; do
    if [[ -d $old && ! -L $old ]]; then
      rm -rf -- "$old"
    fi
  done
  d=$(mktemp -d "$work/rollback.XXXXXX") || mk_die "$MK_EXIT_ERROR" "cannot create a folder in $work; nothing was changed"
  MK_RB_DIR=$d
  if ! mkdir -- "$d/debs" || ! chmod 0755 -- "$d" "$d/debs"; then
    mk_die "$MK_EXIT_ERROR" "cannot prepare $d; nothing was changed"
  fi
  for i in "${MK_RB_CHANGED[@]}"; do
    src=$(mk_snapshot_path "$MK_RB_ID")/${MK_RB_DEBS[i]}
    if [[ ! -f $src ]] || ! cp -- "$src" "$d/debs/" || ! chmod 0644 -- "$d/debs/${src##*/}"; then
      mk_die "$MK_EXIT_ERROR" "the snapshot $MK_RB_ID lacks ${MK_RB_DEBS[i]}; nothing was changed"
    fi
  done
}

# _mk_rb_args: the apt-get install arguments: the .debs, then each extra
# Motanka package with a trailing "-" (remove it).
_mk_rb_args() {
  local i name
  for i in "${MK_RB_CHANGED[@]}"; do
    printf '%s\n' "$MK_RB_DIR/debs/${MK_RB_DEBS[i]##*/}"
  done
  for name in "${MK_RB_EXTRA[@]}"; do
    printf '%s-\n' "$name"
  done
}

_mk_rb_print_plan() {
  local i have
  printf 'Rollback to the snapshot %s:\n' "$MK_RB_ID"
  for i in "${!MK_RB_NAMES[@]}"; do
    have=$(mk_installed_version "${MK_RB_NAMES[i]}") || have="not installed"
    if [[ $have == "${MK_RB_VERS[i]}" ]]; then
      printf '  %-28s %s (unchanged)\n' "${MK_RB_NAMES[i]}" "$have"
    else
      printf '  %-28s %s -> %s\n' "${MK_RB_NAMES[i]}" "$have" "${MK_RB_VERS[i]}"
    fi
  done
  for i in "${MK_RB_EXTRA[@]}"; do
    printf '  %-28s removed (not in the snapshot)\n' "$i"
  done
  printf 'Simulated apt transaction:\n'
  if [[ -s $MK_RB_DIR/plan.txt ]]; then
    sed 's/^/  /' "$MK_RB_DIR/plan.txt"
  else
    printf '  nothing to change\n'
  fi
  if [[ -z $MK_RB_USER ]]; then
    printf 'Home folder: none restored (no invoking user; run the rollback with sudo from your account).\n'
  elif mk_snapshot_has_user "$MK_RB_ID" "$MK_RB_UID"; then
    printf "Home folder: %s's ledgered files and Motanka folders are restored as they were at the snapshot.\n" "$MK_RB_USER"
  else
    printf 'Home folder: the snapshot holds no files of %s.\n' "$MK_RB_USER"
  fi
  printf '\nDry run: nothing was changed.\n'
}

_mk_rb_on_exit() {
  local rc=$?
  trap - EXIT
  if ((MK_RB_BEGUN && !MK_RB_ENDED)); then
    MK_RB_ENDED=1
    mk_sysledger_end failed || true
  fi
  if [[ -n $MK_RB_DIR && -d $MK_RB_DIR ]]; then
    rm -rf -- "$MK_RB_DIR" || true
  fi
  exit "$rc"
}

# _mk_rb_restore_user: step 8.
_mk_rb_restore_user() {
  local rc=0
  if [[ -z $MK_RB_USER ]]; then
    mk_info "no invoking user: no home folder was restored"
    return 0
  fi
  mk_snapshot_restore_user "$MK_RB_ID" "$MK_RB_UID" || rc=$?
  case $rc in
    0) mk_info "restored the ledgered files and Motanka folders of $MK_RB_USER" ;;
    2) mk_info "the snapshot $MK_RB_ID holds no files of $MK_RB_USER; the home folder was left as it is" ;;
    *) mk_die "$MK_EXIT_ERROR" "the packages are rolled back, but the files of $MK_RB_USER could not be restored; 'sudo motanka rollback' tries again" ;;
  esac
}

_mk_rb_run() {
  local d=$MK_RB_DIR raw version removes=0
  local -a args=() auto=()
  mapfile -t args < <(_mk_rb_args)
  if [[ $(awk -F'\t' '$1 == "Remv" || $1 == "Purg" { n++ } END { print n + 0 }' "$d/plan.tsv") != 0 ]]; then
    removes=1
  fi
  mk_info "Motanka returns to the snapshot $MK_RB_ID; see the list with --dry-run."
  if ! mk_confirm "Roll back to the snapshot $MK_RB_ID?"; then
    mk_die "$MK_EXIT_ERROR" "cancelled; nothing was changed"
  fi
  version=${MK_RB_VERS[0]}
  for raw in "${!MK_RB_NAMES[@]}"; do
    if [[ ${MK_RB_NAMES[raw]} == motanka ]]; then
      version=${MK_RB_VERS[raw]}
    fi
  done
  mk_sysledger_begin update "$version" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger; nothing was changed"
  MK_RB_BEGUN=1
  while IFS= read -r raw; do
    mk_sysledger_plan "$raw" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  done <"$d/plan.txt"

  if [[ -s $d/plan.tsv ]]; then
    mapfile -t auto < <(mk_snapshot_auto_packages "${MK_RB_NAMES[@]}")
    if ((removes)); then
      mk_snapshot_apt install --allow-downgrades --no-install-recommends "${args[@]}" ||
        mk_die "$MK_EXIT_ERROR" "apt-get could not install the packages of the snapshot $MK_RB_ID"
    else
      mk_snapshot_apt install --allow-downgrades --no-remove --no-install-recommends "${args[@]}" ||
        mk_die "$MK_EXIT_ERROR" "apt-get could not install the packages of the snapshot $MK_RB_ID"
    fi
    if ((${#auto[@]} > 0)); then
      mk_snapshot_mark_auto "${auto[@]}"
    fi
    mk_snapshot_ledger_new "$d/plan.tsv" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  else
    mk_info "the Motanka packages already have the versions of the snapshot"
  fi
  _mk_rb_restore_user
  MK_RB_ENDED=1
  mk_sysledger_end ok || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  mk_info "Rolled back to the snapshot $MK_RB_ID. Log out of the Motanka session and back in to use it."
}

mk_cmd_rollback() {
  local -a args=() changes=()
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_rollback_usage
        exit "$MK_EXIT_OK"
        ;;
      --)
        shift
        break
        ;;
      -*)
        mk_parse_common_opt "$1" || mk_usage_error "unknown option '$1'"
        ;;
      *)
        mk_usage_error "unexpected argument '$1'"
        ;;
    esac
    shift
  done
  if (($# > 0)); then
    mk_usage_error "unexpected argument '$1'"
  fi

  _mk_rb_require_root
  mk_lock_system
  mk_log info "rollback started (dry run $MK_DRY_RUN)"
  if ! MK_RB_ID=$(mk_snapshot_latest); then
    mk_die "$MK_EXIT_ERROR" "there is no snapshot to return to; 'sudo motanka update' takes one before every update"
  fi
  _mk_rb_invoking_user
  _mk_rb_load

  trap _mk_rb_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _mk_rb_stage
  mapfile -t args < <(_mk_rb_args)
  if ((${#args[@]} > 0)); then
    mk_aptsim_simulate "$MK_RB_DIR/sim.txt" system --allow-downgrades "${args[@]}"
  else
    : >"$MK_RB_DIR/sim.txt"
  fi
  mk_aptsim_plan_lines "$MK_RB_DIR/sim.txt" >"$MK_RB_DIR/plan.txt"
  mk_aptsim_parse "$MK_RB_DIR/sim.txt" >"$MK_RB_DIR/plan.tsv"
  mapfile -t changes < <(mk_aptsim_foreign_changes "$MK_RB_DIR/plan.tsv")
  if ((${#changes[@]} > 0)); then
    mk_info "The rollback would change these packages that Motanka does not own:"
    printf '  %s\n' "${changes[@]}" >&2
    mk_die "$MK_EXIT_FOREIGN" "refused: the rollback would change ${#changes[@]} package(s) Motanka does not own; nothing was changed"
  fi

  if ((MK_DRY_RUN)); then
    _mk_rb_print_plan
    mk_log info "dry run finished; nothing changed"
    exit "$MK_EXIT_OK"
  fi
  _mk_rb_run
  exit "$MK_EXIT_OK"
}
