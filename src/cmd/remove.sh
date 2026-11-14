# shellcheck shell=bash
# shellcheck disable=SC2329 # functions are called by src/motanka, by the user phase and by the unit tests
# shellcheck disable=SC2088 # "~/..." in messages is literal text, not a path to expand
# motanka remove (design.md: Remove flow, CLI, Data Models, Error Handling;
# requirements 10.1-10.15, 11.4, 12.5).
#
# Motanka_Apps (10.15) needs no rule of its own: motanka-apps and
# motanka-herdr are motanka-* packages, so step 6 purges them with the
# others, and the Foreign_Packages they brought are named by the plan and
# pkg-installed lines of the install (or update) run that installed them.
#
# Steps, in order. Nothing changes before step 8.
#   1. options; root (exit 11)
#   2. copy the Remover (the motanka command, lib/*.sh, cmd/remove.sh,
#      package-map.tsv and home-paths.tsv) to /run/motanka/remove.XXXXXX
#      and run from there,
#      because the packages that hold it are about to be purged. It runs
#      as "bash <copy>/motanka", so a noexec /run does not matter.
#   3. the system lock (exit 9)
#   4. refuse (exit 12) while a Motanka_Session runs for any user: a logind
#      session whose Desktop names motanka, or a held
#      /run/user/<uid>/motanka/session.lock of the session launcher
#   5. the invoking user (SUDO_USER, else PKEXEC_UID; root is none) and the
#      other users that have a User_Ledger
#   6. the Plan:
#      - home folder: computed by the user phase, run as the invoking user
#      - every motanka and motanka-* package dpkg knows (any state but
#        not-installed) is purged; a simulation must remove no other
#        package and install nothing (exit 5 otherwise)
#      - Foreign_Packages: the System_Ledger's pkg-installed and
#        pkg-adopted names (pkg-adopted: what a release upgrade installed or
#        kept only for Motanka, recorded by the next update) and the
#        packages that plan lines of install and update runs name as new
#        installs ("Inst <name> (" - this covers an interrupted install,
#        whose pkg-installed lines were never written). A name is a
#        candidate only if it is known to dpkg, not recorded as manual and
#        still marked auto by apt-mark; packages the ledger does not name
#        are never removed (10.7, 10.8). A ledgered package (not recorded
#        as manual) that is down to its configuration files is purged too;
#        nothing can depend on it. Packages installed from Upstream menus
#        (menu-install ... apt) are kept and listed, unless --purge (10.9).
#        The candidates are checked with "apt-get -s purge <Motanka
#        packages> <set>": a member that a package outside the set depends
#        on (Depends or Pre-Depends, directly or through Provides), so that
#        the purge would remove that package too, is dropped and listed as
#        kept, and the check repeats. apt's resolver decides, so a
#        dependency that another installed alternative still satisfies
#        ("polkitd | pkexec" with polkitd installed) does not keep a
#        member. Recommends and Suggests of other packages do not keep a
#        member either: Motanka installed it, so before the install those
#        were unmet. apt's autoremove marking is not used for this, because
#        it keeps every package that a Recommends, a Suggests or any
#        alternative of an installed package names. No autoremove is ever
#        run.
#      - binary outcomes installed from menus under /opt/motanka: kept and
#        listed, deleted with --purge
#   7. --dry-run prints the Plan and exits 0 (10.10)
#   8. a real run asks for confirmation (or --yes), creates
#      /run/motanka/remover.active and writes run-begin remove and one plan
#      line per package to the System_Ledger (when it exists)
#   9. user phase, as the invoking user (setpriv), holding the per-user
#      lock $XDG_RUNTIME_DIR/motanka.lock that per-user setup holds while
#      it runs (exit 9 when it is held): a session capture that is still
#      pending is ended first (mk_capture_end, src/lib/capture.sh: paths a
#      Motanka session created are adopted, observed or recorded as
#      unplanned; the dry run lists what it would record, through
#      mk_capture_end --plan, and writes nothing), then Flatpak apps from menus
#      (uninstalled only with --purge), the User_Ledger walked in reverse
#      (mk_userledger_revert: unchanged files restored or deleted, edited
#      files moved to ~/.local/state/motanka-removed-<date>/, marked blocks
#      removed, entries inside Namespaced_Paths deleted whatever their
#      state, created and adopted folders removed when empty, adopted
#      files deleted when unchanged and moved aside when changed, unplanned
#      and observed paths listed and left), then the
#      Namespaced_Paths, empty folders the ledger records as created, and
#      complete marked blocks left in shell rc files (10.2-10.5). The dry
#      run lists the same walk through mk_userledger_revert_plan. If it
#      fails, the Remover stops (exit 1) before any package changes.
#  10. dpkg --configure for unconfigured motanka-* packages only;
#      dpkg --purge --force-remove-reinstreq for half-installed ones
#  11. apt-get purge of the Motanka packages (10.6)
#  12. the Foreign_Package set is computed again on the new state and
#      intersected with the planned one, checked, and purged; then the
#      directories under /etc of the packages that stay installed, listed
#      before step 11, are recreated with their mode and owner if a
#      maintainer script deleted them (dh_apparmor's postrm deletes
#      /etc/apparmor.d/disable on purge), and the directories of the
#      purged packages, also listed before step 11, that are left empty
#      and that no installed package lists are deleted (dpkg leaves a
#      directory behind when packages purged after its owner filled it)
#  13. run-end ok; the System_Ledger is archived to
#      /var/log/motanka-ledger-<date> and /var/lib/motanka is deleted
# Other users' home folders are listed and never touched (10.13). The
# Remover never runs apt-get update and downloads nothing (10.11).
#
# /var/lib/motanka and motanka-core's postrm: from step 8 until it exits,
# the Remover keeps /run/motanka/remover.active (holding its PID), and
# motanka-core's "postrm purge" leaves /var/lib/motanka alone while that
# file exists; the Remover archives and deletes the folder itself in step
# 13. Without the file (motanka-core purged with apt directly) the postrm
# archives the ledger to /var/log/motanka-ledger-<date> and deletes the
# folder. The Remover also reads a copy of the System_Ledger taken in step
# 6 and keeps that copy up to date, so it works in either case.
#
# Exit codes: 0 removed (or dry run); 1 error; 2 usage; 5 purging the
# Motanka packages would remove a package Motanka does not own, or the
# removal would install a package; 7 guard;
# 9 lock held (system lock, or the invoking user's per-user lock);
# 11 not root; 12 a Motanka session is running.
#
# Test hooks: MOTANKA_ROOT (common.sh) for every system path; users are
# then read from $MOTANKA_ROOT/etc/passwd and their home folders are
# inside MOTANKA_ROOT. apt-get, apt-mark, dpkg, dpkg-query, loginctl,
# setpriv and flatpak are found through PATH. With MOTANKA_ROOT set, the
# user phase keeps the caller's PATH.

if [[ -n ${MK_REMOVE_LOADED:-} ]]; then
  return 0
fi
MK_REMOVE_LOADED=1

_mk_rm_base=${MK_LIBEXEC:-}
if [[ -z $_mk_rm_base ]]; then
  _mk_rm_base=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
# shellcheck source=../lib/common.sh
source "$_mk_rm_base/lib/common.sh"
# shellcheck source=../lib/sysledger.sh
source "$_mk_rm_base/lib/sysledger.sh"
# shellcheck source=../lib/userledger.sh
source "$_mk_rm_base/lib/userledger.sh"
# shellcheck source=../lib/homepaths.sh
source "$_mk_rm_base/lib/homepaths.sh"
# shellcheck source=../lib/capture.sh
source "$_mk_rm_base/lib/capture.sh"

readonly MK_RM_RUN=/run/motanka
readonly MK_RM_MARKER=/run/motanka/remover.active
readonly MK_RM_VARLIB=/var/lib/motanka
readonly MK_RM_ARCHIVE=/var/log/motanka-ledger
readonly MK_RM_MAP=/opt/motanka/share/motanka/package-map.tsv
readonly MK_RM_PREFIX=/opt/motanka
readonly MK_RM_UL_STATE=.local/state/motanka
readonly MK_RM_USER_PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly MK_RM_FLATPAK_RE='^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$'
# Namespaced_Paths (requirements.md, Glossary), as the User_Ledger library
# lists them.
readonly -a MK_RM_NAMESPACED=("${MK_UL_NAMESPACED[@]}")
# Shell rc files that may hold a marked block (6.6).
readonly -a MK_RM_RC_FILES=(.bashrc .zshrc .profile .bash_profile .zprofile .config/fish/config.fish)

MK_PURGE=0
MK_RM_WORK=""
MK_RM_LEDGER=""
MK_RM_BEGUN=0
MK_RM_ENDED=0
MK_RM_MARKED=0
MK_RM_DEGRADED=0
MK_RM_USER="" MK_RM_UID="" MK_RM_GID="" MK_RM_HOME=""
declare -gA MK_RM_STATUS=() MK_RM_VERSION=() MK_RM_AUTO=()
MK_RM_MOTANKA=() MK_RM_CONFIGURE=() MK_RM_FORCE=()
MK_RM_FOREIGN=() MK_RM_CHECKED=() MK_RM_KEPT=() MK_RM_BINARIES=() MK_RM_OTHERS=()
# Filled by _mk_rm_user_read in the user phase.
_MK_RM_U_MENU=() _MK_RM_U_DIRS=() _MK_RM_U_FLATPAKS=() _MK_RM_U_BLOCKS=()
# Paths the planned User_Ledger walk deletes or moves (_mk_rm_user_plan).
declare -gA _MK_RM_U_GONE=()
MK_RM_U_PURGE=0

mk_remove_usage() {
  cat <<'EOF'
usage: motanka remove [--dry-run] [--yes] [--purge]

Removes Motanka and returns this installation to its earlier state. Runs as
root; your home folder is restored as you. Works without network access.

  --dry-run   print every planned action, change nothing
  --yes, -y   do not ask for confirmation
  --purge     also remove packages and web apps installed from Omarchy
              menus (kept and listed otherwise)
  -h, --help  show this help

Other users' home folders are listed, never changed. Log out of every
Motanka session first.
EOF
}

# --- small helpers --------------------------------------------------------

_mk_rm_is_motanka() {
  [[ $1 == motanka || $1 == motanka-* ]]
}

# _mk_rm_sorted <words...>: the words sorted, one per line, without empties.
_mk_rm_sorted() {
  if (($# > 0)); then
    printf '%s\n' "$@" | awk 'NF' | LC_ALL=C sort -u
  fi
}

# _mk_rm_say <action> <path> [detail]: one line of a report on stdout.
_mk_rm_say() {
  printf '  %-13s %s%s\n' "$1" "$2" "${3:+  ($3)}"
}

# _mk_rm_user_exit <code>: the Remover's exit code for a failed user phase:
# 9 when the per-user lock was held, 1 otherwise.
_mk_rm_user_exit() {
  if [[ $1 == "$MK_EXIT_LOCKED" ]]; then
    printf '%s\n' "$MK_EXIT_LOCKED"
  else
    printf '%s\n' "$MK_EXIT_ERROR"
  fi
}

# _mk_rm_kept <package> <reason>: a ledgered package that stays.
_mk_rm_kept() {
  MK_RM_KEPT+=("$1"$'\t'"$2")
}

# --- users ----------------------------------------------------------------

# _mk_rm_passwd: passwd(5) lines; from $MOTANKA_ROOT/etc/passwd in tests.
_mk_rm_passwd() {
  if [[ -n ${MOTANKA_ROOT:-} ]]; then
    cat -- "$MOTANKA_ROOT/etc/passwd" 2>/dev/null || true
  else
    getent passwd 2>/dev/null || true
  fi
}

# _mk_rm_lookup_user <name-or-uid>: prints name:uid:gid:home, or nothing.
_mk_rm_lookup_user() {
  _mk_rm_passwd | awk -F: -v u="$1" '($1 == u || $3 == u) && NF >= 7 { print $1 ":" $3 ":" $4 ":" $6; exit }'
}

# mk_remove_invoking_user: sets MK_RM_USER, MK_RM_UID, MK_RM_GID and
# MK_RM_HOME from SUDO_USER, else PKEXEC_UID. Root is no invoking user.
mk_remove_invoking_user() {
  local who="" entry name uid gid home
  MK_RM_USER="" MK_RM_UID="" MK_RM_GID="" MK_RM_HOME=""
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    who=$SUDO_USER
  elif [[ ${PKEXEC_UID:-} =~ ^[0-9]+$ && $PKEXEC_UID != 0 ]]; then
    who=$PKEXEC_UID
  fi
  if [[ -z $who ]]; then
    return 0
  fi
  entry=$(_mk_rm_lookup_user "$who")
  if [[ -z $entry ]]; then
    mk_die "$MK_EXIT_ERROR" "the invoking user '$who' has no passwd entry"
  fi
  IFS=: read -r name uid gid home <<<"$entry"
  if [[ $uid == 0 ]]; then
    return 0
  fi
  if [[ ! $uid =~ ^[0-9]+$ || ! $gid =~ ^[0-9]+$ ]]; then
    mk_die "$MK_EXIT_ERROR" "the passwd entry of '$who' has no numeric uid and gid"
  fi
  home=$(mk_path "$home")
  home=${home%/}
  if [[ $home != /* || ! -d $home ]]; then
    mk_warn "the home folder of $name ($home) does not exist; there is nothing to restore in it"
    return 0
  fi
  MK_RM_USER=$name MK_RM_UID=$uid MK_RM_GID=$gid MK_RM_HOME=$home
}

# mk_remove_other_users: fills MK_RM_OTHERS with "<name> TAB <home>" for
# every other user (root, or uid 1000-59999) whose home folder has a
# User_Ledger. Only the existence of the folder is checked.
mk_remove_other_users() {
  local name uid home h
  MK_RM_OTHERS=()
  while IFS=: read -r name _ uid _ _ home _; do
    if [[ ! $uid =~ ^[0-9]+$ ]] || ((uid != 0 && (uid < 1000 || uid >= 60000))); then
      continue
    fi
    if [[ $uid == "${MK_RM_UID:-}" || -z $home || $home == / ]]; then
      continue
    fi
    h=$(mk_path "$home")
    h=${h%/}
    if [[ -e $h/$MK_RM_UL_STATE/ledger || -d $h/$MK_RM_UL_STATE ]]; then
      MK_RM_OTHERS+=("$name"$'\t'"$h")
    fi
  done < <(_mk_rm_passwd)
}

# --- running sessions -----------------------------------------------------

# mk_remove_running_sessions: prints "<user> TAB <evidence>" for every
# Motanka_Session that runs.
mk_remove_running_sessions() {
  local id key val desktop state name f dir uid entry
  if command -v loginctl >/dev/null 2>&1; then
    while read -r id _; do
      if [[ ! $id =~ ^[A-Za-z0-9._-]+$ ]]; then
        continue
      fi
      desktop="" state="" name=""
      while IFS='=' read -r key val; do
        case $key in
          Desktop) desktop=$val ;;
          State) state=$val ;;
          Name) name=$val ;;
        esac
      done < <(loginctl show-session "$id" -p Desktop -p State -p Name 2>/dev/null || true)
      if [[ ${desktop,,} == *motanka* && $state != closing ]]; then
        printf '%s\t%s\n' "${name:-unknown}" "logind session $id"
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  fi
  for f in "$(mk_path /run/user)"/*/motanka/session.lock; do
    if [[ ! -f $f ]] || flock -n "$f" true 2>/dev/null; then
      continue
    fi
    dir=${f%/motanka/session.lock}
    uid=${dir##*/}
    entry=$(_mk_rm_lookup_user "$uid")
    name=${entry%%:*}
    printf '%s\t%s\n' "${name:-uid $uid}" "the session launcher holds ${f#"${MOTANKA_ROOT:-}"}"
  done
}

_mk_rm_refuse_sessions() {
  local s
  local -a sessions
  mapfile -t sessions < <(mk_remove_running_sessions)
  if ((${#sessions[@]} == 0)); then
    return 0
  fi
  mk_info "A Motanka session is running:"
  for s in "${sessions[@]}"; do
    mk_info "  user ${s%%$'\t'*}: ${s#*$'\t'}"
  done
  mk_die "$MK_EXIT_SESSION" "refused: log out of every Motanka session before removing Motanka; nothing was changed"
}

# --- running from /run/motanka --------------------------------------------

_mk_rm_require_root() {
  if [[ $(id -u) != 0 ]]; then
    mk_die "$MK_EXIT_AUTH" "motanka remove must run as root: sudo motanka remove"
  fi
}

# _mk_rm_self_copy <arguments...>: copies the Remover into
# /run/motanka/remove.XXXXXX and runs it from there with the same
# arguments. Returns (and sets MK_RM_WORK) when this process already is
# that copy.
_mk_rm_self_copy() {
  local here entry run d map hp
  here=$(readlink -f -- "$MK_LIBEXEC")
  if [[ -n ${MK_REMOVER_COPY:-} && $(readlink -f -- "$MK_REMOVER_COPY") == "$here" ]]; then
    MK_RM_WORK=$here
    return 0
  fi
  entry=$(readlink -f -- "$0")
  if [[ ! -f $entry || ! -r $entry ]]; then
    mk_die "$MK_EXIT_ERROR" "cannot find the motanka command ($0) to copy it to $MK_RM_RUN; nothing was changed"
  fi
  run=$(mk_path "$MK_RM_RUN")
  if ! mkdir -p -- "$run" || ! chmod 0755 -- "$run"; then
    mk_die "$MK_EXIT_ERROR" "cannot create $run; nothing was changed"
  fi
  d=$(mktemp -d "$run/remove.XXXXXX") || mk_die "$MK_EXIT_ERROR" "cannot create a folder in $run; nothing was changed"
  map=$(mk_path "$MK_RM_MAP")
  hp=$(mk_hp_file)
  if ! chmod 0755 -- "$d" || ! mkdir -m 0755 -- "$d/lib" "$d/cmd" ||
    ! cp -- "$entry" "$d/motanka" || ! cp -- "$MK_LIBEXEC"/lib/*.sh "$d/lib/" ||
    ! cp -- "$MK_LIBEXEC/cmd/remove.sh" "$d/cmd/" ||
    { [[ -r $map ]] && ! cp -- "$map" "$d/package-map.tsv"; } ||
    { [[ -r $hp ]] && ! cp -- "$hp" "$d/home-paths.tsv"; } ||
    ! chmod -R u=rwX,go=rX -- "$d"; then
    rm -rf -- "$d"
    mk_die "$MK_EXIT_ERROR" "cannot copy the Remover to $d; nothing was changed"
  fi
  mk_log info "running the Remover from $d"
  exec env MK_REMOVER_COPY="$d" bash "$d/motanka" remove "$@"
}

# _mk_rm_clean_stale: deletes copies left by Removers that were killed more
# than an hour ago. Runs with the system lock held.
_mk_rm_clean_stale() {
  local run old
  run=$(mk_path "$MK_RM_RUN")
  while IFS= read -r -d '' old; do
    if [[ $old != "$MK_RM_WORK" ]]; then
      rm -rf -- "$old"
    fi
  done < <(find "$run" -mindepth 1 -maxdepth 1 -type d -name 'remove.*' -mmin +60 -print0 2>/dev/null)
}

_mk_rm_on_exit() {
  local rc=$? run
  trap - EXIT
  if ((MK_RM_BEGUN && !MK_RM_ENDED)); then
    MK_RM_ENDED=1
    _mk_rm_ledger_append run-end failed || true
  fi
  if ((MK_RM_MARKED)); then
    rm -f -- "$(mk_path "$MK_RM_MARKER")"
  fi
  run=$(readlink -f -- "$(mk_path "$MK_RM_RUN")" 2>/dev/null || true)
  if [[ -n $MK_RM_WORK && -n $run && $MK_RM_WORK == "$run"/remove.* ]]; then
    rm -rf -- "$MK_RM_WORK"
  fi
  exit "$rc"
}

# --- System_Ledger ----------------------------------------------------------

# _mk_rm_ledger_snapshot: copies the System_Ledger into this run's folder
# (MK_RM_LEDGER), or leaves MK_RM_LEDGER empty when there is none.
_mk_rm_ledger_snapshot() {
  local live
  live=$(mk_sysledger_file)
  MK_RM_LEDGER=""
  if [[ -f $live ]]; then
    cp -- "$live" "$MK_RM_WORK/ledger" || mk_die "$MK_EXIT_ERROR" "cannot read the System_Ledger $live; nothing was changed"
    MK_RM_LEDGER=$MK_RM_WORK/ledger
  fi
}

# _mk_rm_ledger_append <verb> <fields...>: appends to the System_Ledger, if
# it still exists, and to this run's copy, which is archived when a package
# script deleted the original. Does nothing when there was no ledger.
_mk_rm_ledger_append() {
  local line
  if [[ -z $MK_RM_LEDGER ]]; then
    return 0
  fi
  if [[ -f $(mk_sysledger_file) ]]; then
    mk_sysledger_append "$@" || return 1
  fi
  mk_run_id >/dev/null
  line=$(
    IFS=$'\t'
    printf '%s\t%s\t%s' "$(mk_utc_now)" "$MK_RUN_ID" "$*"
  )
  mk_ledger_append "$MK_RM_LEDGER" "$line"
}

# _mk_rm_ledger_candidates: "<name> TAB auto|manual" for every package the
# System_Ledger records Motanka installing: pkg-installed lines (manual if
# any of them says so), pkg-adopted lines (auto) and new installs in plan lines of install and update
# runs (auto unless a pkg-installed line says otherwise).
_mk_rm_ledger_candidates() {
  if [[ -z $MK_RM_LEDGER ]]; then
    return 0
  fi
  mk_sysledger_read "$MK_RM_LEDGER" 2>/dev/null | awk -F'\t' '
    function add(p) { if (!(p in seen)) { seen[p] = 1; order[++n] = p } }
    $3 == "run-begin" { kind[$2] = $4 }
    $3 == "pkg-installed" {
      add($4)
      if (!($4 in mode) || $6 == "manual") mode[$4] = $6
    }
    $3 == "pkg-adopted" {
      add($4)
      if (!($4 in mode)) mode[$4] = "auto"
    }
    $3 == "plan" && (kind[$2] == "install" || kind[$2] == "update") {
      m = split($4, w, " ")
      if (m >= 3 && w[1] == "Inst" && substr(w[3], 1, 1) == "(") {
        p = w[2]; sub(/:[A-Za-z0-9]+$/, "", p); add(p)
      }
    }
    END { for (i = 1; i <= n; i++) { p = order[i]; print p "\t" ((p in mode) ? mode[p] : "auto") } }'
}

# _mk_rm_menu_installs: "<uid> TAB <name> TAB apt|binary" per menu install.
_mk_rm_menu_installs() {
  if [[ -n $MK_RM_LEDGER ]]; then
    mk_sysledger_menu_installs "$MK_RM_LEDGER" 2>/dev/null
  fi
}

# _mk_rm_archive_path: /var/log/motanka-ledger-<date>, with .1, .2 ... when
# taken.
_mk_rm_archive_path() {
  local base p n=1
  base=$(mk_path "$MK_RM_ARCHIVE")-$(date -u +%Y-%m-%d)
  p=$base
  while [[ -e $p || -L $p ]]; do
    p=$base.$n
    n=$((n + 1))
  done
  printf '%s\n' "$p"
}

# _mk_rm_archive_ledger: archives the System_Ledger and deletes
# /var/lib/motanka.
_mk_rm_archive_ledger() {
  local live dir src="" dest tmp
  live=$(mk_sysledger_file)
  dir=$(mk_path "$MK_RM_VARLIB")
  if [[ -f $live ]]; then
    src=$live
  elif [[ -n $MK_RM_LEDGER && -f $MK_RM_LEDGER ]]; then
    src=$MK_RM_LEDGER
  fi
  if [[ -n $src ]]; then
    dest=$(_mk_rm_archive_path)
    mkdir -p -- "${dest%/*}" || mk_die "$MK_EXIT_ERROR" "cannot create ${dest%/*}"
    tmp=$(mktemp "$dest.XXXXXX") || mk_die "$MK_EXIT_ERROR" "cannot write in ${dest%/*}"
    if ! cat -- "$src" >"$tmp" || ! chmod 0644 -- "$tmp" || ! mk_fsync "$tmp" || ! mv -T -- "$tmp" "$dest"; then
      rm -f -- "$tmp"
      mk_die "$MK_EXIT_ERROR" "cannot archive the System_Ledger to $dest; it stays in $dir"
    fi
    mk_fsync "${dest%/*}" || true
    mk_log info "archived the System_Ledger to $dest"
    mk_info "archived the System_Ledger to $dest"
  fi
  if [[ -e $dir || -L $dir ]]; then
    rm -rf -- "$dir" || mk_die "$MK_EXIT_ERROR" "cannot delete $dir"
    mk_log info "deleted $dir"
  fi
}

# --- package state ----------------------------------------------------------

# _mk_rm_load_state: MK_RM_STATUS and MK_RM_VERSION of every package dpkg
# knows, and MK_RM_AUTO for packages apt-mark shows as automatically
# installed. Architecture suffixes are removed.
_mk_rm_load_state() {
  local out name st ver
  MK_RM_STATUS=() MK_RM_VERSION=() MK_RM_AUTO=()
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  out=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\t${Version}\n' 2>/dev/null) ||
    mk_die "$MK_EXIT_ERROR" "dpkg-query cannot read the package database"
  while IFS=$'\t' read -r name st ver; do
    name=${name%%:*}
    if [[ -z $name || ${MK_RM_STATUS[$name]:-} == installed ]]; then
      continue
    fi
    MK_RM_STATUS[$name]=$st
    MK_RM_VERSION[$name]=$ver
  done <<<"$out"
  while IFS= read -r name; do
    if [[ -n $name ]]; then
      MK_RM_AUTO[${name%%:*}]=1
    fi
  done < <(apt-mark showauto 2>/dev/null || true)
}

# _mk_rm_known <package>: dpkg knows it in a state other than not-installed.
_mk_rm_known() {
  [[ -n ${MK_RM_STATUS[$1]:-} && ${MK_RM_STATUS[$1]} != not-installed ]]
}

# _mk_rm_plan_motanka: MK_RM_MOTANKA (every Motanka_Package dpkg knows),
# MK_RM_CONFIGURE (unconfigured ones) and MK_RM_FORCE (half-installed ones).
_mk_rm_plan_motanka() {
  local name
  local -a names=()
  MK_RM_MOTANKA=() MK_RM_CONFIGURE=() MK_RM_FORCE=()
  for name in "${!MK_RM_STATUS[@]}"; do
    if _mk_rm_is_motanka "$name" && _mk_rm_known "$name"; then
      names+=("$name")
    fi
  done
  mapfile -t MK_RM_MOTANKA < <(_mk_rm_sorted "${names[@]}")
  for name in "${MK_RM_MOTANKA[@]}"; do
    case ${MK_RM_STATUS[$name]} in
      unpacked | half-configured | triggers-awaited | triggers-pending) MK_RM_CONFIGURE+=("$name") ;;
      half-installed) MK_RM_FORCE+=("$name") ;;
    esac
  done
}

# --- simulations ------------------------------------------------------------

# _mk_rm_simulate <out> <apt-get arguments...>: apt-get -s. Returns 1, with
# apt's output on stderr, when apt cannot plan it.
_mk_rm_simulate() {
  local out=$1 rc=0
  shift
  mk_log info "simulating apt-get $*"
  LC_ALL=C apt-get -q -s -o Debug::NoLocking=true "$@" >"$out" 2>"$out.err" || rc=$?
  if ((rc != 0)); then
    sed 's/^/  /' "$out" "$out.err" >&2
    mk_warn "apt-get -s $* exited $rc"
    return 1
  fi
}

# _mk_rm_sim_names <simulation> <rm|inst>: packages the simulation removes
# (Remv, Purg) or installs (Inst), without architecture suffixes.
_mk_rm_sim_names() {
  awk -v want="$2" '
    (want == "rm" && ($1 == "Remv" || $1 == "Purg")) || (want == "inst" && $1 == "Inst") {
      p = $2; sub(/:[A-Za-z0-9]+$/, "", p); print p
    }' "$1"
}

# _mk_rm_check_motanka_purge: a simulated purge of MK_RM_MOTANKA must remove
# only Motanka_Packages and install nothing; exits 5 otherwise. Returns 1
# when apt cannot simulate it.
_mk_rm_check_motanka_purge() {
  local out=$MK_RM_WORK/sim-motanka.txt name
  local -a bad=()
  if ((${#MK_RM_MOTANKA[@]} == 0)); then
    return 0
  fi
  _mk_rm_simulate "$out" -o APT::Get::AutomaticRemove=false purge "${MK_RM_MOTANKA[@]}" || return 1
  while IFS= read -r name; do
    if ! _mk_rm_is_motanka "$name"; then
      bad+=("$name (removed)")
    fi
  done < <(_mk_rm_sim_names "$out" rm)
  while IFS= read -r name; do
    bad+=("$name (installed)")
  done < <(_mk_rm_sim_names "$out" inst)
  if ((${#bad[@]} > 0)); then
    mk_info "Purging the Motanka packages would change these packages Motanka does not own:"
    printf '  %s\n' "${bad[@]}" >&2
    mk_die "$MK_EXIT_FOREIGN" "refused: ${#bad[@]} package(s) Motanka does not own depend on Motanka packages; remove them first; nothing was changed"
  fi
}

# _mk_rm_dep_names: reads "<package> TAB <relation list>" lines and prints
# every package name in the lists (alternatives included; versions and
# architecture qualifiers removed).
_mk_rm_dep_names() {
  awk -F'\t' '{
    n = split($2, a, /[,|]/)
    for (i = 1; i <= n; i++) {
      t = a[i]; sub(/\(.*/, "", t); sub(/\[.*/, "", t); gsub(/[ \t]/, "", t); sub(/:.*/, "", t)
      if (t != "") print t
    }
  }'
}

# _mk_rm_verify_cascade <with-motanka:0|1> <package...>: sets MK_RM_CHECKED
# to the largest subset found whose purge (together with MK_RM_MOTANKA when
# the first argument is 1) removes no other package. A member that a
# package outside the set depends on (directly or through Provides) is
# dropped and listed as kept; when no member can be blamed, nothing is
# removed. Returns 1 when apt cannot simulate; exits 5 when the purge would
# install a package.
_mk_rm_verify_cascade() {
  local with=$1 out=$MK_RM_WORK/sim-cascade.txt name p q hit progress rounds
  shift
  local -a members=("$@") args=() extra=() keepers=() inst=() provs=() by=() pdeps=()
  local -A inset=() deps=() prov=()
  MK_RM_CHECKED=()
  rounds=$(($# + 1))
  while ((${#members[@]} > 0 && rounds > 0)); do
    rounds=$((rounds - 1))
    inset=()
    for name in "${members[@]}"; do
      inset[$name]=1
    done
    args=()
    if ((with)); then
      args=("${MK_RM_MOTANKA[@]}")
    fi
    args+=("${members[@]}")
    _mk_rm_simulate "$out" -o APT::Get::AutomaticRemove=false purge "${args[@]}" || return 1
    mapfile -t inst < <(_mk_rm_sim_names "$out" inst)
    if ((${#inst[@]} > 0)); then
      mk_die "$MK_EXIT_FOREIGN" "refused: removing the packages Motanka installed would install ${inst[*]}; nothing was changed"
    fi
    extra=()
    while IFS= read -r name; do
      if ! _mk_rm_is_motanka "$name" && [[ -z ${inset[$name]:-} ]]; then
        extra+=("$name")
      fi
    done < <(_mk_rm_sim_names "$out" rm)
    if ((${#extra[@]} == 0)); then
      MK_RM_CHECKED=("${members[@]}")
      return 0
    fi
    # deps[<name>]: the removed packages whose Depends or Pre-Depends name
    # <name>, as " a b ".
    deps=()
    while IFS=$'\t' read -r name p; do
      name=${name%%:*}
      while IFS= read -r q; do
        if [[ -n $q && ${deps[$q]:-} != *" $name "* ]]; then
          deps[$q]="${deps[$q]:- }$name "
        fi
      done < <(printf 'x\t%s\n' "$p" | _mk_rm_dep_names)
    done < <(
      # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
      dpkg-query -W -f='${Package}\t${Depends}, ${Pre-Depends}\n' "${extra[@]}" 2>/dev/null || true
    )
    prov=()
    while IFS=$'\t' read -r name p; do
      prov[${name%%:*}]=$p
    done < <(
      # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
      dpkg-query -W -f='${Package}\t${Provides}\n' "${members[@]}" 2>/dev/null || true
    )
    keepers=()
    progress=0
    for name in "${members[@]}"; do
      hit=${deps[$name]:-}
      mapfile -t provs < <(printf 'x\t%s\n' "${prov[$name]:-}" | _mk_rm_dep_names)
      for p in "${provs[@]}"; do
        read -r -a pdeps <<<"${deps[$p]:-}"
        for q in "${pdeps[@]}"; do
          if [[ " $hit " != *" $q "* ]]; then
            hit+=" $q"
          fi
        done
      done
      read -r -a by <<<"$hit"
      if ((${#by[@]} > 0)); then
        _mk_rm_kept "$name" "another installed package depends on it: ${by[*]}"
        progress=1
      else
        keepers+=("$name")
      fi
    done
    if ((!progress)); then
      for name in "${members[@]}"; do
        _mk_rm_kept "$name" "removing it would also remove ${extra[*]}"
      done
      members=()
      break
    fi
    members=("${keepers[@]}")
  done
  MK_RM_CHECKED=()
  return 0
}

# mk_remove_foreign_plan <with-motanka:0|1>: sets MK_RM_FOREIGN to the
# Foreign_Packages to purge and adds the ledgered packages that stay to
# MK_RM_KEPT (see the header). With 1 the simulation includes purging
# MK_RM_MOTANKA (the Plan, before anything changed); with 0 it is the
# state after the Motanka packages are gone. Needs _mk_rm_load_state and
# _mk_rm_plan_motanka. Returns 1 when apt cannot simulate.
mk_remove_foreign_plan() {
  local with=$1 name mode uid kind
  local -a cand=() menu=() rc_only=() r0=() names=()
  local -A ledgered=() menu_uid=()
  MK_RM_FOREIGN=() MK_RM_KEPT=()
  while IFS=$'\t' read -r name mode; do
    if [[ -n $name ]]; then
      ledgered[$name]=$mode
    fi
  done < <(_mk_rm_ledger_candidates)
  while IFS=$'\t' read -r uid name kind; do
    if [[ $kind == apt && -n $name && ,${menu_uid[$name]:-}, != *",$uid,"* ]]; then
      menu_uid[$name]=${menu_uid[$name]:+${menu_uid[$name]},}$uid
    fi
  done < <(_mk_rm_menu_installs)

  mapfile -t names < <(_mk_rm_sorted "${!ledgered[@]}")
  for name in "${names[@]}"; do
    if _mk_rm_is_motanka "$name" || [[ -n ${menu_uid[$name]:-} ]] || ! _mk_rm_known "$name"; then
      continue
    fi
    if [[ ${ledgered[$name]} == manual ]]; then
      _mk_rm_kept "$name" "recorded as manually installed when Motanka installed it"
    elif [[ ${MK_RM_STATUS[$name]} == config-files ]]; then
      # Only its configuration files are left; no package can depend on it.
      rc_only+=("$name")
    elif [[ -z ${MK_RM_AUTO[$name]:-} ]]; then
      _mk_rm_kept "$name" "marked as manually installed since Motanka installed it"
    else
      cand+=("$name")
    fi
  done
  mapfile -t names < <(_mk_rm_sorted "${!menu_uid[@]}")
  for name in "${names[@]}"; do
    if _mk_rm_is_motanka "$name" || ! _mk_rm_known "$name"; then
      continue
    fi
    if ((!MK_PURGE)); then
      _mk_rm_kept "$name" "installed from an Omarchy menu (uid ${menu_uid[$name]}); --purge removes it"
    elif [[ ${MK_RM_STATUS[$name]} == config-files ]]; then
      rc_only+=("$name")
    else
      menu+=("$name")
    fi
  done

  r0=("${cand[@]}" "${menu[@]}")
  if ((${#r0[@]} > 0)); then
    _mk_rm_verify_cascade "$with" "${r0[@]}" || return 1
  else
    MK_RM_CHECKED=()
  fi
  mapfile -t MK_RM_FOREIGN < <(_mk_rm_sorted "${MK_RM_CHECKED[@]}" "${rc_only[@]}")
}

# _mk_rm_plan_binaries: MK_RM_BINARIES, "<arch-name> TAB <destination>" for
# every binary outcome installed from a menu under /opt/motanka that is
# still there. The destination comes from this run's copy of the map.
_mk_rm_plan_binaries() {
  local map=$MK_RM_WORK/package-map.tsv name kind dest
  local -A seen=()
  MK_RM_BINARIES=()
  while IFS=$'\t' read -r _ name kind; do
    if [[ $kind != binary || -n ${seen[$name]:-} ]]; then
      continue
    fi
    seen[$name]=1
    dest=""
    if [[ -r $map ]]; then
      dest=$(awk -F'\t' -v n="$name" '$1 == n && $2 == "binary" { print $5; exit }' "$map")
    fi
    if [[ $dest != "$MK_RM_PREFIX"/?* || /$dest/ == */../* ]]; then
      _mk_rm_kept "$name" "binary installed from an Omarchy menu; its destination is unknown"
      continue
    fi
    if [[ -e $(mk_path "$dest") || -L $(mk_path "$dest") ]]; then
      MK_RM_BINARIES+=("$name"$'\t'"$dest")
    fi
  done < <(_mk_rm_menu_installs)
}

# _mk_rm_plan_system: the system part of the Plan. Sets MK_RM_DEGRADED when
# apt cannot simulate yet (a Motanka package is half-installed, for
# example); the real run then repairs first and plans again.
_mk_rm_plan_system() {
  MK_RM_DEGRADED=0
  _mk_rm_load_state
  _mk_rm_plan_motanka
  if ! _mk_rm_check_motanka_purge || ! mk_remove_foreign_plan 1; then
    MK_RM_DEGRADED=1
    MK_RM_FOREIGN=()
    mk_warn "apt cannot simulate the removal yet; the Remover first repairs the Motanka packages and then plans the packages it installed"
  fi
  _mk_rm_plan_binaries
}

# --- the user phase (runs as the invoking user) ---------------------------

# _mk_rm_user_read <home>: reads the User_Ledger into _MK_RM_U_MENU
# (menu-desktop paths), _MK_RM_U_FLATPAKS (app IDs from shadow entries),
# _MK_RM_U_DIRS (folders Motanka created or adopted, in ledger order) and
# _MK_RM_U_BLOCKS (files with a ledgered block).
_mk_rm_user_read() {
  local home=$1 ledger line verb rel abs id
  local -A seen=()
  _MK_RM_U_MENU=() _MK_RM_U_DIRS=() _MK_RM_U_FLATPAKS=() _MK_RM_U_BLOCKS=()
  ledger=$home/$MK_RM_UL_STATE/ledger
  if [[ ! -f $ledger ]]; then
    return 0
  fi
  while IFS= read -r line; do
    IFS=$'\t' read -r _ _ verb _ rel _ <<<"$line"
    case $verb in
      menu-desktop)
        if [[ -n ${seen[m:$rel]:-} ]]; then
          continue
        fi
        seen[m:$rel]=1
        _MK_RM_U_MENU+=("$rel")
        abs=$home/$rel
        if [[ -f $abs && ! -L $abs ]]; then
          id=$(awk '/^X-Motanka-Flatpak=/ { print substr($0, index($0, "=") + 1); exit }' "$abs")
          if [[ $id =~ $MK_RM_FLATPAK_RE && -z ${seen[f:$id]:-} ]]; then
            seen[f:$id]=1
            _MK_RM_U_FLATPAKS+=("$id")
          fi
        fi
        ;;
      create | adopt)
        if [[ $rel == */ && -z ${seen[d:$rel]:-} ]]; then
          seen[d:$rel]=1
          _MK_RM_U_DIRS+=("$rel")
        fi
        ;;
      block)
        _MK_RM_U_BLOCKS+=("$rel")
        ;;
    esac
  done < <(mk_userledger_read "$ledger")
}

# _mk_rm_user_line <plan|apply> <verb> <path> [detail]: one report line for
# a line of the User_Ledger walk.
_mk_rm_user_line() {
  local mode=$1 verb=$2 rel=$3 detail=${4:-} a p
  case $verb in
    restored) a=restore p=restored detail="from the backup in the User_Ledger" ;;
    deleted) a=delete p=deleted detail="" ;;
    moved) a=move p=moved detail="edited by you; moved to ~/$detail" ;;
    block-removed) a=remove-block p=removed-block detail="marked Motanka block" ;;
    unplanned) a=leave p=left detail="changed during setup or a Motanka session without a ledger entry; not restored" ;;
    observed) a=leave p=left detail="written by Ubuntu's session components, as at any graphical login; not Motanka's" ;;
    rmdir) a=delete p=deleted detail="folder Motanka created, if empty" ;;
    kept)
      a=keep p=kept
      if [[ $rel == */ ]]; then
        detail="folder is not empty"
      elif ((MK_RM_U_PURGE)); then
        detail=""
      else
        detail="installed from an Omarchy menu; --purge removes it"
      fi
      ;;
    *) a=$verb p=$verb ;;
  esac
  if [[ $mode == plan ]]; then
    _mk_rm_say "$a" "~/$rel" "$detail"
  else
    _mk_rm_say "$p" "~/$rel" "$detail"
  fi
}

# _mk_rm_has_block <file>: the file has a complete marked block.
_mk_rm_has_block() {
  awk -v b="$MK_UL_BLOCK_BEGIN" -v e="$MK_UL_BLOCK_END" '
    $0 == b { inb = 1; next }
    inb && $0 == e { found = 1; exit }
    END { exit !found }' "$1"
}

# _mk_rm_strip_blocks <file>: the file without its complete marked blocks;
# an unterminated block stays.
_mk_rm_strip_blocks() {
  awk -v b="$MK_UL_BLOCK_BEGIN" -v e="$MK_UL_BLOCK_END" '
    !inb && $0 == b { inb = 1; n = 0; held[++n] = $0; next }
    inb && $0 == e { inb = 0; n = 0; next }
    inb { held[++n] = $0; next }
    { print }
    END { if (inb) for (i = 1; i <= n; i++) print held[i] }' "$1"
}

# _mk_rm_rc_blocks <home> <plan|apply>: complete marked blocks in the shell
# rc files. In a plan, files with a ledgered block are left to the ledger
# walk.
_mk_rm_rc_blocks() {
  local home=$1 mode=$2 rc abs tmp b skip
  for rc in "${MK_RM_RC_FILES[@]}"; do
    abs=$home/$rc
    if [[ ! -f $abs || -L $abs ]]; then
      continue
    fi
    if ! _mk_rm_has_block "$abs"; then
      if grep -qxF -- "$MK_UL_BLOCK_BEGIN" "$abs"; then
        mk_warn "~/$rc has a '$MK_UL_BLOCK_BEGIN' line without its end line; it is left as it is"
      fi
      continue
    fi
    if [[ $mode == plan ]]; then
      skip=0
      for b in "${_MK_RM_U_BLOCKS[@]}"; do
        if [[ $b == "$rc" ]]; then
          skip=1
        fi
      done
      if ((!skip)); then
        _mk_rm_say remove-block "~/$rc" "marked Motanka block"
      fi
      continue
    fi
    tmp=${abs%/*}/.${abs##*/}.motanka-tmp
    rm -f -- "$tmp"
    if ! _mk_rm_strip_blocks "$abs" >"$tmp" || ! chmod --reference="$abs" -- "$tmp" ||
      ! mv -fT -- "$tmp" "$abs"; then
      rm -f -- "$tmp"
      mk_error "cannot remove the marked block from ~/$rc"
      return 1
    fi
    mk_log info "removed the marked block from ~/$rc"
    _mk_rm_say removed-block "~/$rc" "marked Motanka block"
  done
}

# _mk_rm_namespaced <home> <plan|apply> <purge>: deletes the
# Namespaced_Paths except ~/.local/state/motanka (the ledger walk deletes
# it). Without --purge, files installed from menus inside them stay. It
# runs after the ledger walk, which deletes the ledgered entries inside
# them already; a plan leaves out a Namespaced_Path that the planned walk
# deletes (_MK_RM_U_GONE), as the real run finds it gone.
_mk_rm_namespaced() {
  local home=$1 mode=$2 purge=$3 root abs k p rel n
  local -A keep=() anc=()
  if ((!purge)); then
    for k in "${_MK_RM_U_MENU[@]}"; do
      keep[$k]=1
      p=$k
      while [[ $p == */* ]]; do
        p=${p%/*}
        anc[$p]=1
      done
    done
  fi
  for root in "${MK_RM_NAMESPACED[@]}"; do
    abs=$home/$root
    if [[ $root == "$MK_RM_UL_STATE" ]] || [[ ! -e $abs && ! -L $abs ]]; then
      continue
    fi
    n=0
    for k in "${!keep[@]}"; do
      if [[ $k == "$root"/* ]]; then
        n=$((n + 1))
      fi
    done
    if [[ $mode == plan ]]; then
      if [[ -n ${_MK_RM_U_GONE[$root]:-} ]]; then
        continue
      fi
      if ((n > 0)); then
        _mk_rm_say delete "~/$root" "Namespaced_Path; keeps $n file(s) installed from menus"
      else
        _mk_rm_say delete "~/$root" "Namespaced_Path"
      fi
      continue
    fi
    if ((n == 0)) || [[ -L $abs || ! -d $abs ]]; then
      rm -rf --one-file-system -- "$abs" || {
        mk_error "cannot delete ~/$root"
        return 1
      }
      mk_log info "deleted the Namespaced_Path ~/$root"
      _mk_rm_say deleted "~/$root" "Namespaced_Path"
      continue
    fi
    while IFS= read -r -d '' p; do
      rel=${p#"$home"/}
      if [[ -n ${keep[$rel]:-} || -n ${anc[$rel]:-} ]]; then
        continue
      fi
      rm -rf --one-file-system -- "$p" || {
        mk_error "cannot delete ~/$rel"
        return 1
      }
    done < <(find "$abs" -mindepth 1 -depth -print0)
    mk_log info "deleted the Namespaced_Path ~/$root except $n file(s) installed from menus"
    _mk_rm_say deleted "~/$root" "Namespaced_Path; kept $n file(s) installed from menus"
  done
}

# _mk_rm_user_plan <home> <purge>: the home-folder part of the Plan, in
# the order the real run acts: Flatpak apps, the User_Ledger walk
# (mk_userledger_revert_plan), the Namespaced_Paths, the state folder,
# marked blocks the ledger does not know.
_mk_rm_user_plan() {
  local home=$1 purge=$2 id line verb rel detail out
  local -a opts=() lines=()
  _MK_RM_U_GONE=()
  for id in "${_MK_RM_U_FLATPAKS[@]}"; do
    if ((purge)); then
      _mk_rm_say uninstall "Flatpak $id" "installed from an Omarchy menu"
    else
      _mk_rm_say keep "Flatpak $id" "installed from an Omarchy menu; --purge removes it"
    fi
  done
  if ((purge)); then
    opts=(--purge)
  fi
  mapfile -t lines < <(mk_userledger_revert_plan "${opts[@]}")
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r verb rel detail <<<"$line"
    if [[ -n $verb && -n $rel ]]; then
      if [[ $verb == deleted || $verb == moved ]]; then
        _MK_RM_U_GONE[$rel]=1
      fi
      _mk_rm_user_line plan "$verb" "$rel" "$detail"
    fi
  done
  _mk_rm_namespaced "$home" plan "$purge"
  if [[ -e $home/$MK_RM_UL_STATE || -L $home/$MK_RM_UL_STATE ]]; then
    _mk_rm_say delete "~/$MK_RM_UL_STATE/" "User_Ledger and backups"
  fi
  out=$(_mk_rm_rc_blocks "$home" plan)
  if [[ -n $out ]]; then
    printf '%s\n' "$out"
  fi
  if ((${#_MK_RM_U_FLATPAKS[@]} + ${#lines[@]} == 0)) && [[ -z $out ]] &&
    ! _mk_rm_any_namespaced "$home"; then
    _mk_rm_say nothing "" "no Motanka files in this home folder"
  fi
}

# _mk_rm_any_namespaced <home>: 0 if a Namespaced_Path exists.
_mk_rm_any_namespaced() {
  local root
  for root in "${MK_RM_NAMESPACED[@]}"; do
    if [[ -e $1/$root || -L $1/$root ]]; then
      return 0
    fi
  done
  return 1
}

# _mk_rm_user_apply <home> <purge>: Flatpak apps from menus (--purge
# only), the User_Ledger walk (mk_userledger_revert; it deletes the
# ledgered entries inside the Namespaced_Paths, never moving them aside),
# the rest of the Namespaced_Paths, the empty folders the ledger records as
# created, and marked blocks the ledger does not know.
_mk_rm_user_apply() {
  local home=$1 purge=$2 id out rc=0 line verb rel detail i abs state_there=0
  local -a opts=() lines=()
  local -A existed=() reported=()
  for id in "${_MK_RM_U_FLATPAKS[@]}"; do
    if ((!purge)); then
      _mk_rm_say kept "Flatpak $id" "installed from an Omarchy menu"
      continue
    fi
    if ! command -v flatpak >/dev/null 2>&1 || ! flatpak info --user "$id" >/dev/null 2>&1; then
      continue
    fi
    mk_log info "flatpak uninstall --user $id"
    if flatpak uninstall --user --noninteractive "$id" >&2; then
      _mk_rm_say uninstalled "Flatpak $id"
    else
      mk_error "flatpak could not uninstall $id"
      return 1
    fi
  done
  for rel in "${_MK_RM_U_DIRS[@]}"; do
    abs=$home/${rel%/}
    if [[ -d $abs && ! -L $abs ]]; then
      existed[$rel]=1
    fi
  done
  if [[ -e $home/$MK_RM_UL_STATE || -L $home/$MK_RM_UL_STATE ]]; then
    state_there=1
  fi
  if ((purge)); then
    opts=(--purge)
  fi
  out=$(mk_userledger_revert "${opts[@]}") || rc=$?
  if [[ -n $out ]]; then
    mapfile -t lines <<<"$out"
  fi
  if ((rc != 0)); then
    for line in "${lines[@]}"; do
      IFS=$'\t' read -r verb rel detail <<<"$line"
      _mk_rm_user_line apply "$verb" "$rel" "$detail"
    done
    return 1
  fi
  _mk_rm_namespaced "$home" apply "$purge" || return 1
  for ((i = ${#_MK_RM_U_DIRS[@]} - 1; i >= 0; i--)); do
    rel=${_MK_RM_U_DIRS[i]}
    abs=$home/${rel%/}
    if [[ -d $abs && ! -L $abs ]] && rmdir -- "$abs" 2>/dev/null; then
      mk_log info "deleted the empty folder ~/$rel"
    fi
  done
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r verb rel detail <<<"$line"
    if [[ -z $verb || -z $rel ]]; then
      continue
    fi
    if [[ $rel == */ ]]; then
      reported[$rel]=1
      # Kept by the walk because Upstream's files were still in it, then
      # emptied by the deletion of the Namespaced_Paths.
      if [[ $verb == kept && ! -e $home/${rel%/} ]]; then
        verb=deleted
      fi
    fi
    _mk_rm_user_line apply "$verb" "$rel" "$detail"
  done
  if ((state_there)) && [[ ! -e $home/$MK_RM_UL_STATE && ! -L $home/$MK_RM_UL_STATE ]]; then
    reported[$MK_RM_UL_STATE/]=1
    _mk_rm_say deleted "~/$MK_RM_UL_STATE/" "User_Ledger and backups"
  fi
  # Created folders the walk did not report: the ones on the way to the
  # state folder, and the ones only the steps above emptied.
  for rel in "${_MK_RM_U_DIRS[@]}"; do
    abs=$home/${rel%/}
    if [[ -n ${existed[$rel]:-} && -z ${reported[$rel]:-} && ! -e $abs && ! -L $abs ]]; then
      reported[$rel]=1
      _mk_rm_user_line apply deleted "$rel"
    fi
  done
  _mk_rm_rc_blocks "$home" apply || return 1
}

# mk_remove_user_phase <plan|apply> <purge:0|1>: the home-folder part of the
# Remover. Runs as the user who owns the home folder (MK_HOME, or HOME);
# never as root. Exit codes: 0, 1 error, 9 the per-user lock
# ($XDG_RUNTIME_DIR/motanka.lock) is held.
mk_remove_user_phase() {
  local mode=$1 purge=$2 home rt rc=0 extra
  MK_RM_U_PURGE=$purge
  if ((EUID == 0)); then
    mk_error "the user phase of motanka remove does not run as root"
    return 1
  fi
  home=${MK_HOME:-${HOME:-}}
  home=${home%/}
  if [[ $home != /* || ! -d $home ]]; then
    mk_error "home folder '${home:-unset}' is not an existing absolute path"
    return 1
  fi
  # The lock per-user setup holds for its whole run (mk_userledger_lock).
  # Without a runtime folder the user has no session, so no per-user setup
  # can run either.
  rt=${XDG_RUNTIME_DIR:-}
  if [[ -n $rt && -d $rt && -w $rt ]]; then
    mk_userledger_lock || rc=$?
    if ((rc != 0)); then
      return "$rc"
    fi
  fi
  # A session capture that was never ended (the session did not end
  # cleanly): its paths go into the User_Ledger before the walk, so the
  # walk removes what the session created (design.md, "Session-time home
  # writes"). The dry run only adds the lines it would write to its walk.
  case $mode in
    plan)
      MK_UL_PLAN_EXTRA=()
      if mk_capture_pending; then
        if ! extra=$(mk_capture_end --plan); then
          mk_error "cannot compare the home folder with the pending session capture in ~/$MK_CAP_REL"
          return 1
        fi
        if [[ -n $extra ]]; then
          mapfile -t MK_UL_PLAN_EXTRA <<<"$extra"
        fi
      fi
      ;;
    apply)
      if mk_capture_pending && ! mk_capture_end; then
        mk_error "cannot end the pending session capture in ~/$MK_CAP_REL; nothing in the home folder was changed"
        return 1
      fi
      ;;
    *)
      mk_error "mk_remove_user_phase: unknown mode '$mode'"
      return 1
      ;;
  esac
  _mk_rm_user_read "$home"
  case $mode in
    plan) _mk_rm_user_plan "$home" "$purge" ;;
    apply) _mk_rm_user_apply "$home" "$purge" ;;
  esac
}

# _mk_rm_as_user <plan|apply>: runs the user phase as the invoking user
# with setpriv and a clean environment. Returns its exit code.
_mk_rm_as_user() {
  local mode=$1 rt rc=0
  local -a envs=()
  rt=$(mk_path "/run/user/$MK_RM_UID")
  mk_run_id >/dev/null
  envs=(HOME="$MK_RM_HOME" MK_HOME="$MK_RM_HOME" USER="$MK_RM_USER" LOGNAME="$MK_RM_USER"
    PATH="$MK_RM_USER_PATH" LANG=C.UTF-8 MK_RUN_ID="$MK_RUN_ID")
  if [[ -d $rt ]]; then
    envs+=(XDG_RUNTIME_DIR="$rt")
  fi
  if [[ -n ${NO_COLOR:-} ]]; then
    envs+=(NO_COLOR="$NO_COLOR")
  fi
  if [[ -n $MK_RM_WORK && -r $MK_RM_WORK/home-paths.tsv ]]; then
    envs+=(MOTANKA_HOME_PATHS="$MK_RM_WORK/home-paths.tsv")
  fi
  if [[ -n ${MOTANKA_ROOT:-} ]]; then
    envs+=(MOTANKA_ROOT="$MOTANKA_ROOT" PATH="$PATH")
  fi
  mk_log info "user phase ($mode) for $MK_RM_USER (uid $MK_RM_UID) through setpriv"
  # The user process gets no descriptor of the system lock.
  # shellcheck disable=SC2016 # expanded by the user's shell
  setpriv --reuid="$MK_RM_UID" --regid="$MK_RM_GID" --init-groups -- \
    env -i "${envs[@]}" bash --noprofile --norc -c \
    'set -euo pipefail; cd /; MK_LIBEXEC=$1; MK_CMD=remove; source "$1/lib/common.sh"; source "$1/cmd/remove.sh"; mk_remove_user_phase "$2" "$3"' \
    _ "$MK_LIBEXEC" "$mode" "$MK_PURGE" {MK_LOCK_FD}>&- || rc=$?
  return "$rc"
}

# --- printing the Plan --------------------------------------------------------

_mk_rm_print_plan() {
  local p entry rc=0
  printf 'Removal plan%s:\n\n' "$( ((MK_DRY_RUN)) && printf ' (dry run: nothing changes)')"
  if [[ -n $MK_RM_USER ]]; then
    printf 'Home folder of %s (%s), restored as %s:\n' "$MK_RM_USER" "$MK_RM_HOME" "$MK_RM_USER"
    _mk_rm_as_user plan || rc=$?
    if ((rc != 0)); then
      mk_die "$(_mk_rm_user_exit "$rc")" \
        "cannot plan the restore of the home folder of $MK_RM_USER (exit $rc); nothing was changed"
    fi
  else
    printf 'Home folder: none restored: no invoking user (run "sudo motanka remove" from your own account to restore your home folder too).\n'
  fi
  printf '\nPackages:\n'
  if ((${#MK_RM_MOTANKA[@]} == 0)); then
    _mk_rm_say nothing "" "no Motanka package is installed"
  fi
  for p in "${MK_RM_FORCE[@]}"; do
    _mk_rm_say force-purge "$p" "half-installed; purged with dpkg --force-remove-reinstreq"
  done
  for p in "${MK_RM_CONFIGURE[@]}"; do
    _mk_rm_say configure "$p" "${MK_RM_STATUS[$p]} by an interrupted run; dpkg --configure"
  done
  for p in "${MK_RM_MOTANKA[@]}"; do
    _mk_rm_say purge "$p ${MK_RM_VERSION[$p]:-}" "Motanka package"
  done
  for p in "${MK_RM_FOREIGN[@]}"; do
    _mk_rm_say purge "$p ${MK_RM_VERSION[$p]:-}" "installed by Motanka; no other package needs it"
  done
  if ((MK_RM_DEGRADED)); then
    _mk_rm_say plan-later "" "packages Motanka installed: computed after the Motanka packages are repaired"
  fi
  for entry in "${MK_RM_KEPT[@]}"; do
    _mk_rm_say keep "${entry%%$'\t'*}" "${entry#*$'\t'}"
  done
  printf '\nFiles:\n'
  for entry in "${MK_RM_BINARIES[@]}"; do
    if ((MK_PURGE)); then
      _mk_rm_say delete "${entry#*$'\t'}" "${entry%%$'\t'*}, installed from an Omarchy menu"
    else
      _mk_rm_say keep "${entry#*$'\t'}" "${entry%%$'\t'*}, installed from an Omarchy menu; --purge deletes it"
    fi
  done
  if [[ -n $MK_RM_LEDGER ]]; then
    _mk_rm_say archive "$MK_RM_VARLIB/ledger" "to $MK_RM_ARCHIVE-<date>"
  fi
  if [[ -e $(mk_path "$MK_RM_VARLIB") ]]; then
    _mk_rm_say delete "$MK_RM_VARLIB/"
  fi
  _mk_rm_print_others
}

_mk_rm_print_others() {
  local entry
  if ((${#MK_RM_OTHERS[@]} == 0)); then
    return 0
  fi
  printf '\nOther users with Motanka files in their home folders (left unchanged):\n'
  for entry in "${MK_RM_OTHERS[@]}"; do
    _mk_rm_say user "${entry%%$'\t'*}" "${entry#*$'\t'}/$MK_RM_UL_STATE"
  done
}

# --- the real run -----------------------------------------------------------

# _mk_rm_apt <apt-get arguments...>: the real apt-get run, never with
# autoremove, without the lock's file descriptor.
_mk_rm_apt() {
  local rc=0
  mk_log info "apt-get $*"
  DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=300 \
    -o APT::Get::AutomaticRemove=false "$@" </dev/null >&2 {MK_LOCK_FD}>&- || rc=$?
  return "$rc"
}

# _mk_rm_repair: step 10.
_mk_rm_repair() {
  local updates
  if ((${#MK_RM_FORCE[@]} > 0)); then
    mk_log info "dpkg --purge --force-remove-reinstreq ${MK_RM_FORCE[*]}"
    dpkg --purge --force-remove-reinstreq "${MK_RM_FORCE[@]}" </dev/null >&2 {MK_LOCK_FD}>&- ||
      mk_warn "dpkg could not purge the half-installed packages ${MK_RM_FORCE[*]}"
  fi
  if ((${#MK_RM_CONFIGURE[@]} > 0)); then
    mk_log info "dpkg --configure ${MK_RM_CONFIGURE[*]}"
    dpkg --configure "${MK_RM_CONFIGURE[@]}" </dev/null >&2 {MK_LOCK_FD}>&- ||
      mk_warn "dpkg --configure failed for ${MK_RM_CONFIGURE[*]}; they are purged anyway"
    return 0
  fi
  updates=$(mk_path /var/lib/dpkg/updates)
  if ((${#MK_RM_MOTANKA[@]} > 0)) && compgen -G "$updates/[0-9]*" >/dev/null; then
    # An interrupted dpkg left its journal; a dpkg run that opens the
    # database for writing applies it. The package is already configured,
    # so dpkg itself reports an error, which is expected.
    mk_log info "applying the dpkg journal left by an interrupted run"
    dpkg --configure "${MK_RM_MOTANKA[0]}" </dev/null >/dev/null 2>&1 {MK_LOCK_FD}>&- || true
  fi
}

# _mk_rm_intersect <file-a-words> <words...>: prints the words of the second
# list that are also in the first (passed as one space-separated string).
_mk_rm_intersect() {
  local a=" $1 " w
  shift
  for w in "$@"; do
    if [[ $a == *" $w "* ]]; then
      printf '%s\n' "$w"
    fi
  done
}

# _mk_rm_delete_binaries: binary outcomes from menus (--purge only), and the
# folders they leave empty that no package owns.
_mk_rm_delete_binaries() {
  local entry name dest path dir stop
  stop=$(mk_path "$MK_RM_PREFIX")
  for entry in "${MK_RM_BINARIES[@]}"; do
    name=${entry%%$'\t'*}
    dest=${entry#*$'\t'}
    path=$(mk_path "$dest")
    rm -f -- "$path" || mk_die "$MK_EXIT_ERROR" "cannot delete $dest"
    mk_log info "deleted the binary outcome of $name, $dest"
    mk_info "deleted $dest ($name)"
    dir=${path%/*}
    while [[ $dir == "$stop"/?* ]]; do
      if dpkg-query -S "${dir#"${MOTANKA_ROOT:-}"}" >/dev/null 2>&1 || ! rmdir -- "$dir" 2>/dev/null; then
        break
      fi
      dir=${dir%/*}
    done
  done
}

# _mk_rm_shared_dirs <package>...: the directories under /etc that exist
# now and that dpkg lists for a package not named here (one that stays
# installed), one per line: "<mode> <uid> <gid> <path>", sorted by path.
# Step 12 recreates those that the purge deleted: a maintainer script may
# delete a directory that another package owns, as dh_apparmor's postrm
# does on purge with "rmdir /etc/apparmor.d/disable", which belongs to
# apparmor (10.1).
_mk_rm_shared_dirs() {
  local info f name
  local -A purged=()
  local -a lists=()
  info=$(mk_path /var/lib/dpkg/info)
  for name in "$@"; do
    purged[$name]=1
  done
  for f in "$info"/*.list; do
    [[ -e $f ]] || continue
    name=${f##*/}
    name=${name%.list}
    name=${name%%:*}
    if [[ -z ${purged[$name]:-} ]]; then
      lists+=("$f")
    fi
  done
  ((${#lists[@]} > 0)) || return 0
  grep -h '^/etc/' "${lists[@]}" 2>/dev/null | LC_ALL=C sort -u |
    while IFS= read -r f; do
      f=$(mk_path "$f")
      if [[ -d $f && ! -L $f ]]; then
        stat -c '%a %u %g %n' -- "$f"
      fi
    done
}

# _mk_rm_restore_dirs <file>: recreates, parents first, every directory of
# the _mk_rm_shared_dirs list in <file> that no longer exists, with its
# mode and owner, and says so.
_mk_rm_restore_dirs() {
  local mode uid gid path
  while read -r mode uid gid path; do
    [[ -n $path ]] || continue
    if [[ ! -e $path && ! -L $path ]]; then
      if install -d -m "$mode" -o "$uid" -g "$gid" -- "$path"; then
        mk_info "recreated ${path#"${MOTANKA_ROOT:-}"}, which belongs to an installed package and which a maintainer script of a purged package deleted"
      else
        mk_warn "cannot recreate ${path#"${MOTANKA_ROOT:-}"}, which a maintainer script of a purged package deleted"
      fi
    fi
  done <"$1"
}

# _mk_rm_purged_dirs <package>...: the directories under /etc, /opt, /usr
# and /var that dpkg lists for the named packages (the ones the Remover
# purges) and that exist now, one dpkg path per line, sorted. After the
# purge, _mk_rm_prune_dirs deletes those it left empty: dpkg deletes a
# directory of a package only when it is empty at the moment that package
# is purged, so a directory whose files belong to packages purged after it
# stays behind (/etc/libreoffice/registry belongs to libreoffice-common,
# and libreoffice-calc and others put their files in it) (10.1).
_mk_rm_purged_dirs() {
  local info name f root=${MOTANKA_ROOT:-}
  local -a lists=()
  info=$(mk_path /var/lib/dpkg/info)
  for name in "$@"; do
    for f in "$info/$name.list" "$info/$name":*.list; do
      if [[ -e $f ]]; then
        lists+=("$f")
      fi
    done
  done
  ((${#lists[@]} > 0)) || return 0
  grep -hE '^/(etc|opt|usr|var)/.' "${lists[@]}" 2>/dev/null | LC_ALL=C sort -u |
    while IFS= read -r f; do
      if [[ -d $root$f && ! -L $root$f ]]; then
        printf '%s\n' "$f"
      fi
    done
}

# _mk_rm_prune_dirs <file>: deletes, deepest first, each directory of the
# _mk_rm_purged_dirs list in <file> that is empty and that no installed
# package lists (as dpkg would have, had it purged the packages in the
# other order), and says so.
_mk_rm_prune_dirs() {
  local info d root=${MOTANKA_ROOT:-}
  local -a lists=()
  info=$(mk_path /var/lib/dpkg/info)
  for d in "$info"/*.list; do
    if [[ -e $d ]]; then
      lists+=("$d")
    fi
  done
  LC_ALL=C sort -r -- "$1" | while IFS= read -r d; do
    [[ -n $d && -d $root$d && ! -L $root$d ]] || continue
    [[ -z $(ls -A -- "$root$d" 2>/dev/null) ]] || continue
    if ((${#lists[@]} > 0)) && grep -qxF -- "$d" "${lists[@]}" 2>/dev/null; then
      continue
    fi
    if rmdir -- "$root$d" 2>/dev/null; then
      mk_info "deleted $d, an empty directory of the purged packages that dpkg left behind"
    fi
  done
}

_mk_rm_run() {
  local version marker p rc=0
  local -a planned=() target=() final=() left=() kept=() vanished=()
  local -A before=()
  marker=$(mk_path "$MK_RM_MARKER")
  printf '%s\n' "$$" >"$marker" || mk_die "$MK_EXIT_ERROR" "cannot write $marker; nothing was changed"
  MK_RM_MARKED=1
  version=${MK_RM_VERSION[motanka]:-${MK_RM_VERSION[motanka-core]:-unknown}}
  if [[ -n $MK_RM_LEDGER ]]; then
    _mk_rm_ledger_append run-begin remove "$version" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger; nothing was changed"
    MK_RM_BEGUN=1
    for p in "${MK_RM_MOTANKA[@]}" "${MK_RM_FOREIGN[@]}"; do
      _mk_rm_ledger_append plan "Purg $p" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
    done
  fi

  # 9. the home folder, as the invoking user
  if [[ -n $MK_RM_USER ]]; then
    mk_info "restoring the home folder of $MK_RM_USER as $MK_RM_USER"
    printf 'Home folder of %s (%s):\n' "$MK_RM_USER" "$MK_RM_HOME"
    _mk_rm_as_user apply || rc=$?
    if ((rc != 0)); then
      mk_die "$(_mk_rm_user_exit "$rc")" \
        "the home folder of $MK_RM_USER could not be fully restored (exit $rc); no package was changed, and the User_Ledger stays in ~$MK_RM_USER/$MK_RM_UL_STATE; fix the problem above and run 'sudo motanka remove' again"
    fi
  fi

  if ((MK_PURGE)); then
    _mk_rm_delete_binaries
  fi

  # 10. repair, then plan again on the repaired state
  _mk_rm_repair
  kept=("${MK_RM_KEPT[@]}")
  planned=("${MK_RM_FOREIGN[@]}")
  _mk_rm_load_state
  _mk_rm_plan_motanka
  _mk_rm_check_motanka_purge || mk_die "$MK_EXIT_ERROR" "apt cannot plan the purge of the Motanka packages; see the output above"
  mk_remove_foreign_plan 1 || mk_die "$MK_EXIT_ERROR" "apt cannot plan the removal of the packages Motanka installed; see the output above"
  if ((MK_RM_DEGRADED)); then
    planned=("${MK_RM_FOREIGN[@]}")
    kept=("${MK_RM_KEPT[@]}")
  fi
  mapfile -t target < <(_mk_rm_intersect "${planned[*]}" "${MK_RM_FOREIGN[@]}")
  _mk_rm_shared_dirs "${MK_RM_MOTANKA[@]}" "${target[@]}" >"$MK_RM_WORK/shared-dirs.txt" ||
    mk_warn "cannot list the directories under /etc of the packages that stay installed"
  _mk_rm_purged_dirs "${MK_RM_MOTANKA[@]}" "${target[@]}" >"$MK_RM_WORK/purged-dirs.txt" ||
    mk_warn "cannot list the directories of the packages the removal purges"

  # 11. the Motanka packages
  if ((${#MK_RM_MOTANKA[@]} > 0)); then
    mk_info "purging ${#MK_RM_MOTANKA[@]} Motanka package(s)"
    _mk_rm_apt purge "${MK_RM_MOTANKA[@]}" || mk_die "$MK_EXIT_ERROR" "apt-get purge of the Motanka packages failed; run 'sudo motanka remove' again from $MK_RM_WORK/motanka while this boot lasts"
  fi
  _mk_rm_load_state
  _mk_rm_plan_motanka
  if ((${#MK_RM_MOTANKA[@]} > 0)); then
    mk_die "$MK_EXIT_ERROR" "these Motanka packages are still known to dpkg: ${MK_RM_MOTANKA[*]}"
  fi

  # 12. the Foreign_Packages Motanka installed
  if ((${#target[@]} > 0)); then
    mk_remove_foreign_plan 0 || mk_die "$MK_EXIT_ERROR" "apt cannot plan the removal of the packages Motanka installed"
    mapfile -t final < <(_mk_rm_intersect "${target[*]}" "${MK_RM_FOREIGN[@]}")
    if ((${#final[@]} > 0)); then
      _mk_rm_verify_cascade 0 "${final[@]}" || mk_die "$MK_EXIT_ERROR" "apt cannot plan the removal of the packages Motanka installed"
      final=("${MK_RM_CHECKED[@]}")
    fi
    for p in "${target[@]}"; do
      if [[ " ${final[*]} " != *" $p "* ]]; then
        kept+=("$p"$'\t'"no longer removable without removing other packages")
      fi
    done
  fi
  if ((${#final[@]} > 0)); then
    for p in "${!MK_RM_STATUS[@]}"; do
      before[$p]=${MK_RM_STATUS[$p]}
    done
    mk_info "purging ${#final[@]} package(s) Motanka installed: ${final[*]}"
    _mk_rm_apt purge "${final[@]}" || mk_die "$MK_EXIT_ERROR" "apt-get purge of the packages Motanka installed failed"
    _mk_rm_load_state
    for p in "${!before[@]}"; do
      if [[ ${before[$p]} != not-installed ]] && ! _mk_rm_known "$p" && [[ " ${final[*]} " != *" $p "* ]]; then
        vanished+=("$p")
      fi
    done
    if ((${#vanished[@]} > 0)); then
      mk_error "apt-get also removed: ${vanished[*]}"
    fi
  fi
  for p in "${final[@]}"; do
    if _mk_rm_known "$p"; then
      left+=("$p")
    fi
  done
  if ((${#left[@]} > 0)); then
    mk_die "$MK_EXIT_ERROR" "these packages Motanka installed are still installed: ${left[*]}"
  fi
  _mk_rm_restore_dirs "$MK_RM_WORK/shared-dirs.txt"
  _mk_rm_prune_dirs "$MK_RM_WORK/purged-dirs.txt"

  # 13. the System_Ledger
  MK_RM_ENDED=1
  _mk_rm_ledger_append run-end ok || mk_warn "cannot write run-end to the System_Ledger"
  _mk_rm_archive_ledger

  printf '\nMotanka was removed.\n'
  if ((${#final[@]} > 0)); then
    printf 'Purged %d package(s) Motanka installed: %s\n' "${#final[@]}" "${final[*]}"
  fi
  if ((${#kept[@]} > 0)) || ((!MK_PURGE && ${#MK_RM_BINARIES[@]} > 0)); then
    printf '\nKept:\n'
    for p in "${kept[@]}"; do
      _mk_rm_say kept "${p%%$'\t'*}" "${p#*$'\t'}"
    done
    if ((!MK_PURGE)); then
      for p in "${MK_RM_BINARIES[@]}"; do
        _mk_rm_say kept "${p#*$'\t'}" "${p%%$'\t'*}, installed from an Omarchy menu"
      done
    fi
  fi
  _mk_rm_print_others
  mk_log info "remove finished: ${#final[@]} package(s) Motanka installed purged, ${#kept[@]} kept"
}

# --- entry point --------------------------------------------------------------

mk_cmd_remove() {
  local -a args=("$@")
  MK_PURGE=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_remove_usage
        exit "$MK_EXIT_OK"
        ;;
      --purge)
        MK_PURGE=1
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

  _mk_rm_require_root
  _mk_rm_self_copy "${args[@]}"
  trap _mk_rm_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mk_lock_system
  _mk_rm_clean_stale
  mk_log info "remove started (dry run $MK_DRY_RUN, purge $MK_PURGE) from $MK_RM_WORK"
  _mk_rm_refuse_sessions
  mk_remove_invoking_user
  mk_remove_other_users
  _mk_rm_ledger_snapshot
  _mk_rm_plan_system
  _mk_rm_print_plan
  if ((MK_DRY_RUN)); then
    printf '\nDry run: nothing was changed.\n'
    mk_log info "dry run finished; nothing changed"
    exit "$MK_EXIT_OK"
  fi
  printf '\n'
  if ! mk_confirm "Remove Motanka now?"; then
    mk_die "$MK_EXIT_ERROR" "cancelled; nothing was changed"
  fi
  _mk_rm_run
  exit "$MK_EXIT_OK"
}
