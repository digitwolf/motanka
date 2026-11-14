# shellcheck shell=bash
# shellcheck disable=SC2329 # functions are called by src/motanka and by the unit tests
# motanka update (design.md: Update flow, "Updater, snapshots and
# rollback", CLI, Error Handling; requirements 9.1, 9.2, 9.7, 9.8,
# 9.10-9.12, 11.5, 12.5).
#
# Steps, in order. Nothing changes before step 7.
#   1. options; root (exit 11); the system lock (exit 9). A second Updater
#      stops here and changes nothing (9.11): the first one holds the lock
#      until it exits, migrations included.
#   2. motanka-core is installed, else exit 1
#   3. the suite of /etc/apt/sources.list.d/motanka.sources is the running
#      release (VERSION_CODENAME) or <release>-edge, and the source is not
#      disabled; else exit 10 with 'sudo motanka doctor --fix' (11.5). The
#      suite gives the Channel: <release>-edge is edge, <release> stable.
#   4. the invoking user (SUDO_USER, else PKEXEC_UID; root is none) and
#      whether that user's per-user setup completed
#   5. apt-get update (a dry run uses private lists in
#      /run/motanka/update.XXXXXX instead), then a simulated
#      "apt-get install <every installed Motanka_Package>"; with
#      motanka-apps installed this includes motanka-apps and motanka-herdr,
#      so new Depends of a new motanka-apps are installed and get
#      pkg-installed lines in step 9 like those of motanka-core. The
#      Updater never installs motanka-apps when it is not installed.
#   6. refuse with exit 5, before any change, when the transaction would
#      upgrade, downgrade or remove a Foreign_Package (9.2). With --system,
#      upgrades and downgrades of Foreign_Packages are allowed and listed;
#      removals are always refused. --dry-run prints the Plan and exits 0.
#      With nothing to upgrade and no pending migration: exit 0, nothing
#      written.
#   7. System_Ledger: run-begin update, one plan line per simulated action
#   8. snapshot (src/lib/snapshot.sh): the version and .deb of every
#      installed Motanka_Package, and an archive of each user's ledgered
#      files and Namespaced_Paths (9.10); then a snapper pre snapshot when
#      snapper has a config for / (9.12)
#   9. apt-get install --no-remove --no-install-recommends of the
#      Motanka_Packages (without --no-remove only when the simulation
#      removes Motanka_Packages and nothing else); Motanka packages that
#      were marked automatically installed are marked so again;
#      pkg-installed lines for new Foreign_Packages (3.7)
#  10. the Channel's Upstream_Pin: the vendored tree comes with
#      motanka-core, so the upgrade moved it; the pin of the Channel in
#      upstream.pin and the vendored tree are checked and reported
#  11. the invoking user's pending migrations, as that user, through the
#      Wrapper scope: /opt/motanka/libexec/motanka/run-upstream
#      omarchy-migrate (src/overrides/omarchy-migrate, 9.7). A failure stops
#      the update with exit 8; the runner names the migration, and the
#      snapshot stays (9.8). A user whose per-user setup has not completed
#      has nothing pending: the first login records every migration. Other
#      users' migrations run when they run 'sudo motanka update' (Upstream's
#      update menu does, through the omarchy-update override); they are
#      listed.
#  12. snapper post snapshot; run-end ok
# 9.1's order is steps 8, 9, 10, 11. The snapshot comes after the
# simulation, so a refused update leaves no snapshot (only 3 are kept).
# After run-begin, any exit other than success appends run-end failed,
# completes the snapper pair and names the snapshot that 'sudo motanka
# rollback' returns to.
#
# Exit codes: 0 updated, up to date, or dry run; 1 error; 2 usage; 5 a
# package Motanka does not own would change; 7 guard; 8 a migration failed;
# 9 lock held (the system lock, or the invoking user's per-user lock);
# 10 the repository suite does not match the release; 11 not root.
#
# Test hooks: MOTANKA_ROOT (common.sh) for every system path, the migration
# runner included; users then come from $MOTANKA_ROOT/etc/passwd. apt-get,
# apt-mark, dpkg-query, dpkg-deb, setpriv and snapper are found through
# PATH.

if [[ -n ${MK_UPDATE_LOADED:-} ]]; then
  return 0
fi
MK_UPDATE_LOADED=1

_mk_up_base=${MK_LIBEXEC:-}
if [[ -z $_mk_up_base ]]; then
  _mk_up_base=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
# shellcheck source=../lib/common.sh
source "$_mk_up_base/lib/common.sh"
# shellcheck source=../lib/sysledger.sh
source "$_mk_up_base/lib/sysledger.sh"
# shellcheck source=../lib/aptsim.sh
source "$_mk_up_base/lib/aptsim.sh"
# shellcheck source=../lib/userledger.sh
source "$_mk_up_base/lib/userledger.sh"
# shellcheck source=../lib/snapshot.sh
source "$_mk_up_base/lib/snapshot.sh"

readonly MK_UP_SOURCES=/etc/apt/sources.list.d/motanka.sources
readonly MK_UP_PIN=/opt/motanka/share/motanka/upstream.pin
readonly MK_UP_VENDORED=/opt/motanka/share/omarchy
readonly MK_UP_RUNNER=/opt/motanka/libexec/motanka/run-upstream
readonly MK_UP_RUN=/run/motanka
readonly MK_UP_DOCTOR="sudo motanka doctor --fix"

MK_SYSTEM=0
MK_UP_CODENAME="" MK_UP_SUITE="" MK_UP_CHANNEL=""
MK_UP_DIR=""
MK_UP_BEGUN=0 MK_UP_ENDED=0
MK_UP_SNAPSHOT=""
MK_UP_SNAPPER_CFG="" MK_UP_SNAPPER_PRE=""
MK_UP_USER="" MK_UP_UID="" MK_UP_GID="" MK_UP_HOME="" MK_UP_SETUP=0
MK_UP_PKGS=()
MK_UP_PENDING=()
MK_UP_ALLOWED=()

mk_update_usage() {
  cat <<'EOF'
usage: motanka update [--dry-run] [--yes] [--system]

Takes a snapshot, upgrades the Motanka packages, moves to the channel's
Upstream pin and runs pending migrations.

  --dry-run   print the planned upgrade, change nothing
  --yes, -y   do not ask for confirmation
  --system    allow the upgrade to change packages Motanka does not own
  -h, --help  show this help
EOF
}

# --- checks -------------------------------------------------------------

_mk_up_require_root() {
  if [[ $(id -u) != 0 ]]; then
    mk_die "$MK_EXIT_AUTH" "motanka update must run as root: sudo motanka update"
  fi
}

# _mk_up_os_codename: VERSION_CODENAME of the running release, or nothing.
_mk_up_os_codename() {
  local f line v
  f=$(mk_path /etc/os-release)
  if [[ ! -r $f ]]; then
    f=$(mk_path /usr/lib/os-release)
  fi
  if [[ ! -r $f ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == VERSION_CODENAME=* ]]; then
      v=${line#*=}
      v=${v//\"/}
      v=${v//\'/}
      printf '%s\n' "$v"
      return 0
    fi
  done <"$f"
}

# _mk_up_source_field <file> <field>: the first word of a deb822 field.
_mk_up_source_field() {
  awk -v want="$2" '
    { sub(/\r$/, "") }
    /^#/ { next }
    {
      i = index($0, ":")
      if (i == 0) next
      if (tolower(substr($0, 1, i - 1)) != want) next
      v = substr($0, i + 1)
      sub(/^[ \t]+/, "", v)
      split(v, w, /[ \t]+/)
      print w[1]
      exit
    }' "$1"
}

# mk_update_check_suite: step 3. Sets MK_UP_CODENAME, MK_UP_SUITE and
# MK_UP_CHANNEL, or exits 10.
mk_update_check_suite() {
  local src codename suite enabled
  codename=$(_mk_up_os_codename)
  src=$(mk_path "$MK_UP_SOURCES")
  if [[ ! -r $src ]]; then
    mk_die "$MK_EXIT_SUITE" "there is no Motanka apt source ($MK_UP_SOURCES); install the one of this release with: $MK_UP_DOCTOR; nothing was changed"
  fi
  suite=$(_mk_up_source_field "$src" suites)
  enabled=$(_mk_up_source_field "$src" enabled)
  if [[ -z $codename || ($suite != "$codename" && $suite != "$codename-edge") ]]; then
    mk_die "$MK_EXIT_SUITE" "the Motanka apt source names the suite '${suite:-none}', but this system runs Ubuntu ${codename:-of an unknown release}; switch to the suite of this release with: $MK_UP_DOCTOR; nothing was changed"
  fi
  if [[ ${enabled,,} == no ]]; then
    mk_die "$MK_EXIT_SUITE" "the Motanka apt source ($MK_UP_SOURCES) is disabled (Enabled: no), as a release upgrade leaves it; repair it with: $MK_UP_DOCTOR; nothing was changed"
  fi
  MK_UP_CODENAME=$codename
  MK_UP_SUITE=$suite
  MK_UP_CHANNEL=stable
  if [[ $suite == *-edge ]]; then
    MK_UP_CHANNEL=edge
  fi
  mk_log info "suite $suite matches the running release $codename (channel $MK_UP_CHANNEL)"
}

# _mk_up_setup_done <home>: the last setup marker of the user's User_Ledger
# is setup-end.
_mk_up_setup_done() {
  local f=$1/.local/state/motanka/ledger last
  if [[ ! -f $f || -L $f ]]; then
    return 1
  fi
  last=$(mk_userledger_read "$f" 2>/dev/null |
    awk -F'\t' '$3 == "setup-begin" || $3 == "setup-end" { v = $3 } END { print v }')
  [[ $last == setup-end ]]
}

# _mk_up_invoking_user: step 4.
_mk_up_invoking_user() {
  local who="" entry
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    who=$SUDO_USER
  elif [[ ${PKEXEC_UID:-} =~ ^[0-9]+$ && $PKEXEC_UID != 0 ]]; then
    who=$PKEXEC_UID
  fi
  if [[ -z $who ]]; then
    return 0
  fi
  if ! entry=$(mk_snapshot_lookup_user "$who"); then
    mk_warn "the invoking user '$who' has no passwd entry; no migration runs"
    return 0
  fi
  IFS=$'\t' read -r MK_UP_UID MK_UP_GID MK_UP_USER MK_UP_HOME <<<"$entry"
  if [[ $MK_UP_UID == 0 || ! -d $MK_UP_HOME ]]; then
    MK_UP_USER="" MK_UP_UID="" MK_UP_GID="" MK_UP_HOME=""
    return 0
  fi
  if _mk_up_setup_done "$MK_UP_HOME"; then
    MK_UP_SETUP=1
  fi
}

# --- the migration runner -------------------------------------------------

# _mk_up_runner <arguments...>: the migration runner as the invoking user,
# in the Wrapper scope.
_mk_up_runner() {
  local rt
  local -a envs=()
  rt=$(mk_path "/run/user/$MK_UP_UID")
  if [[ -d $rt ]]; then
    envs+=("XDG_RUNTIME_DIR=$rt")
  fi
  if ((MK_YES)); then
    envs+=(OMARCHY_UPDATE_UNATTENDED=1)
  fi
  mk_snapshot_as_user "$MK_UP_UID" "$MK_UP_GID" "$MK_UP_HOME" \
    env "${envs[@]}" "$(mk_path "$MK_UP_RUNNER")" omarchy-migrate "$@"
}

# _mk_up_load_pending: MK_UP_PENDING, the pending migrations of the
# invoking user now (before the upgrade).
_mk_up_load_pending() {
  local out rc=0
  MK_UP_PENDING=()
  if ((!MK_UP_SETUP)) || [[ ! -x $(mk_path "$MK_UP_RUNNER") ]]; then
    return 0
  fi
  out=$(_mk_up_runner --pending </dev/null 2>/dev/null) || rc=$?
  if ((rc == 0)); then
    mapfile -t MK_UP_PENDING < <(printf '%s\n' "$out" | awk 'NF')
  fi
}

# --- apt ------------------------------------------------------------------

# _mk_up_workdir: the private folder of this run, with private apt lists
# for a dry run.
_mk_up_workdir() {
  local run d
  run=$(mk_path "$MK_UP_RUN")
  if ! mkdir -p -- "$run" || ! chmod 0755 -- "$run"; then
    mk_die "$MK_EXIT_ERROR" "cannot create $run; nothing was changed"
  fi
  d=$(mktemp -d "$run/update.XXXXXX") || mk_die "$MK_EXIT_ERROR" "cannot create a folder in $run; nothing was changed"
  MK_UP_DIR=$d
  MK_APTSIM_OPTS=()
  if ((!MK_DRY_RUN)); then
    return 0
  fi
  if ! mkdir -p -- "$d/lists/partial" "$d/cache/archives/partial" ||
    ! chmod 0755 -- "$d" "$d/lists" "$d/cache" "$d/cache/archives"; then
    mk_die "$MK_EXIT_ERROR" "cannot prepare $d; nothing was changed"
  fi
  cat >"$d/apt.conf" <<'EOF'
// Private configuration of 'motanka update --dry-run': no hooks, so the
// simulation writes nothing outside this folder.
#clear APT::Update::Pre-Invoke;
#clear APT::Update::Post-Invoke;
#clear APT::Update::Post-Invoke-Success;
#clear DPkg::Pre-Invoke;
#clear DPkg::Post-Invoke;
EOF
  chmod 0644 -- "$d/apt.conf"
  MK_APTSIM_OPTS=(-c "$d/apt.conf" -o "Dir::State::Lists=$d/lists"
    -o "Dir::Cache=$d/cache" -o "Dir::Cache::archives=$d/cache/archives")
}

# _mk_up_apt_update: apt-get update, with the private lists in a dry run.
_mk_up_apt_update() {
  local rc=0 log=$MK_UP_DIR/update.log
  if ((MK_DRY_RUN)); then
    mk_info "apt-get update with private lists in $MK_UP_DIR"
  else
    mk_info "apt-get update"
  fi
  mk_log info "apt-get update (dry run $MK_DRY_RUN)"
  LC_ALL=C mk_snapshot_nolock apt-get "${MK_APTSIM_OPTS[@]}" -q -o DPkg::Lock::Timeout=300 update \
    >"$log" 2>&1 || rc=$?
  if ((rc != 0)); then
    sed 's/^/  /' "$log" >&2
    mk_die "$MK_EXIT_ERROR" "apt-get update failed (exit $rc); check the network connection; nothing was changed"
  fi
}

# _mk_up_simulate: the simulated transaction in plan.txt (raw lines) and
# plan.tsv (mk_aptsim_parse).
_mk_up_simulate() {
  local d=$MK_UP_DIR mode=system
  if ((MK_DRY_RUN)); then
    mode=private
  fi
  mk_aptsim_simulate "$d/sim.txt" "$mode" "${MK_UP_PKGS[@]}"
  mk_aptsim_plan_lines "$d/sim.txt" >"$d/plan.txt"
  mk_aptsim_parse "$d/sim.txt" >"$d/plan.tsv"
}

# _mk_up_check_foreign: step 6. Fills MK_UP_ALLOWED with the changes
# --system allows.
_mk_up_check_foreign() {
  local line
  local -a changes=() refused=()
  MK_UP_ALLOWED=()
  mapfile -t changes < <(mk_aptsim_foreign_changes "$MK_UP_DIR/plan.tsv")
  for line in "${changes[@]}"; do
    if ((MK_SYSTEM)) && [[ $line != *'(removal)' ]]; then
      MK_UP_ALLOWED+=("$line")
    else
      refused+=("$line")
    fi
  done
  if ((${#refused[@]} > 0)); then
    mk_info "The update would change these packages that Motanka does not own:"
    printf '  %s\n' "${refused[@]}" >&2
    if ((MK_SYSTEM)); then
      mk_die "$MK_EXIT_FOREIGN" "refused: the update would remove ${#refused[@]} package(s) Motanka does not own, which --system does not allow; nothing was changed"
    fi
    mk_die "$MK_EXIT_FOREIGN" "refused: the update would change ${#refused[@]} package(s) Motanka does not own; nothing was changed (--system allows upgrades of them)"
  fi
  if ((${#MK_UP_ALLOWED[@]} > 0)); then
    mk_warn "--system: the update changes ${#MK_UP_ALLOWED[@]} package(s) Motanka does not own: ${MK_UP_ALLOWED[*]}"
  fi
}

# _mk_up_count <op...>: the number of plan.tsv lines with one of the ops.
_mk_up_count() {
  local ops=" $* "
  awk -F'\t' -v ops="$ops" 'index(ops, " " $1 " ") { n++ } END { print n + 0 }' "$MK_UP_DIR/plan.tsv"
}

# _mk_up_target_version: the motanka (else motanka-core) version this run
# installs, for the run-begin line.
_mk_up_target_version() {
  local v="" p
  for p in motanka motanka-core; do
    v=$(awk -F'\t' -v p="$p" '$1 == "Inst" && $2 == p { print $4; exit }' "$MK_UP_DIR/plan.tsv")
    if [[ -n $v && $v != - ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  done
  for p in motanka motanka-core; do
    if v=$(mk_installed_version "$p"); then
      printf '%s\n' "$v"
      return 0
    fi
  done
  printf 'unknown\n'
}

# --- dry run --------------------------------------------------------------

_mk_up_print_plan() {
  local users cfg line
  printf 'Motanka update plan for Ubuntu %s: suite %s (channel %s)\n' "$MK_UP_CODENAME" "$MK_UP_SUITE" "$MK_UP_CHANNEL"
  printf 'Simulated apt transaction (apt-get install --no-install-recommends %s):\n' "${MK_UP_PKGS[*]}"
  if [[ -s $MK_UP_DIR/plan.txt ]]; then
    sed 's/^/  /' "$MK_UP_DIR/plan.txt"
  else
    printf '  nothing to upgrade\n'
  fi
  if ((${#MK_UP_ALLOWED[@]} > 0)); then
    printf 'Packages Motanka does not own that change (allowed by --system):\n'
    for line in "${MK_UP_ALLOWED[@]}"; do
      printf '  %s\n' "$line"
    done
  else
    printf 'No package Motanka does not own changes or is removed.\n'
  fi
  users=$(mk_snapshot_users | grep -c . || true)
  printf 'Snapshot before the upgrade: %d Motanka package(s) with their .debs, and the ledgered files of %d user(s).\n' \
    "${#MK_UP_PKGS[@]}" "$users"
  if cfg=$(mk_snapshot_snapper_config); then
    printf 'snapper: a pre and a post snapshot of the config %s.\n' "$cfg"
  fi
  if [[ -z $MK_UP_USER ]]; then
    printf 'Migrations: no invoking user; run the update with sudo from your account.\n'
  elif ((!MK_UP_SETUP)); then
    printf "Migrations: none for %s: per-user setup has not completed, and the first login records every migration.\n" "$MK_UP_USER"
  else
    printf 'Migrations: %d pending for %s now; the upgrade may add more, which run after it.\n' \
      "${#MK_UP_PENDING[@]}" "$MK_UP_USER"
  fi
  printf '\nDry run: nothing was changed.\n'
}

# --- real run ---------------------------------------------------------------

_mk_up_snapper_pre() {
  local cfg num
  cfg=$(mk_snapshot_snapper_config) || return 0
  if num=$(mk_snapshot_snapper_pre "$cfg" "motanka update $MK_UP_SNAPSHOT"); then
    MK_UP_SNAPPER_CFG=$cfg
    MK_UP_SNAPPER_PRE=$num
    printf '%s\t%s\n' "$cfg" "$num" >"$(mk_snapshot_path "$MK_UP_SNAPSHOT")/snapper" || true
    mk_info "snapper: pre snapshot $num of the config $cfg"
    mk_log info "snapper pre snapshot $num of the config $cfg"
  else
    mk_warn "snapper could not create a pre snapshot of the config $cfg; the update goes on with Motanka's own snapshot"
  fi
}

_mk_up_snapper_post() {
  local pre=$MK_UP_SNAPPER_PRE
  if [[ -z $pre ]]; then
    return 0
  fi
  MK_UP_SNAPPER_PRE=""
  if mk_snapshot_snapper_post "$MK_UP_SNAPPER_CFG" "$pre" "motanka update $MK_UP_SNAPSHOT"; then
    mk_log info "snapper post snapshot for the pre snapshot $pre"
  else
    mk_warn "snapper could not create the post snapshot for the pre snapshot $pre"
  fi
}

# _mk_up_upgrade <removes:0|1>: step 9.
_mk_up_upgrade() {
  local removes=$1
  local -a args=(install) auto=()
  mapfile -t auto < <(mk_snapshot_auto_packages "${MK_UP_PKGS[@]}")
  if ((!removes)); then
    args+=(--no-remove)
  fi
  args+=(--no-install-recommends)
  mk_info "upgrading the Motanka packages"
  if ! mk_snapshot_apt "${args[@]}" "${MK_UP_PKGS[@]}"; then
    mk_die "$MK_EXIT_ERROR" "apt-get could not upgrade the Motanka packages"
  fi
  if ((${#auto[@]} > 0)); then
    mk_snapshot_mark_auto "${auto[@]}"
  fi
  mk_snapshot_ledger_new "$MK_UP_DIR/plan.tsv" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
}

# _mk_up_pin: step 10.
_mk_up_pin() {
  local pin line commit tag vendored
  pin=$(mk_path "$MK_UP_PIN")
  line=$(awk -F'\t' -v c="$MK_UP_CHANNEL" '$1 == c { print $2 "\t" $3; exit }' "$pin" 2>/dev/null) || line=""
  IFS=$'\t' read -r commit tag <<<"$line"
  if [[ ! ${commit:-} =~ ^[0-9a-f]{40}$ ]]; then
    mk_die "$MK_EXIT_ERROR" "$MK_UP_PIN has no $MK_UP_CHANNEL pin; reinstall motanka-core"
  fi
  vendored=$(mk_path "$MK_UP_VENDORED")
  if [[ ! -d $vendored/bin || ! -d $vendored/migrations ]]; then
    mk_die "$MK_EXIT_ERROR" "the vendored Upstream tree $MK_UP_VENDORED is incomplete; reinstall motanka-core"
  fi
  if [[ -z ${tag:-} || $tag == - ]]; then
    tag=""
  fi
  mk_info "Upstream pin of the $MK_UP_CHANNEL channel: $commit${tag:+ ($tag)}"
  mk_log info "at the $MK_UP_CHANNEL Upstream pin $commit${tag:+ ($tag)}"
}

# _mk_up_migrate: step 11.
_mk_up_migrate() {
  local rc=0
  if [[ -z $MK_UP_USER ]]; then
    mk_info "migrations: no invoking user; each user's pending migrations run when that user runs 'sudo motanka update'"
    return 0
  fi
  if ((!MK_UP_SETUP)); then
    mk_info "migrations: none for $MK_UP_USER: per-user setup has not completed, and the first login records every migration"
    return 0
  fi
  if [[ ! -x $(mk_path "$MK_UP_RUNNER") ]]; then
    mk_die "$MK_EXIT_ERROR" "the migration runner $MK_UP_RUNNER is missing; reinstall motanka-core"
  fi
  mk_info "running the pending migrations of $MK_UP_USER"
  _mk_up_runner || rc=$?
  case $rc in
    0)
      mk_log info "the migrations of $MK_UP_USER are done"
      ;;
    "$MK_EXIT_MIGRATION")
      mk_die "$MK_EXIT_MIGRATION" "the update stopped: a migration of $MK_UP_USER failed (named above); it stays pending"
      ;;
    "$MK_EXIT_LOCKED")
      mk_die "$MK_EXIT_LOCKED" "another per-user Motanka operation of $MK_UP_USER is running; run 'sudo motanka update' again to run the pending migrations"
      ;;
    *)
      mk_die "$MK_EXIT_ERROR" "the migration runner failed for $MK_UP_USER (exit $rc)"
      ;;
  esac
}

_mk_up_list_others() {
  local uid name
  local -a others=()
  while IFS=$'\t' read -r uid _ name _; do
    if [[ $uid != "${MK_UP_UID:-}" ]]; then
      others+=("$name")
    fi
  done < <(mk_snapshot_users)
  if ((${#others[@]} > 0)); then
    mk_info "other users with Motanka set up: ${others[*]}; their pending migrations run when each of them runs 'sudo motanka update'"
  fi
}

_mk_up_on_exit() {
  local rc=$?
  trap - EXIT
  _mk_up_snapper_post || true
  if ((MK_UP_BEGUN && !MK_UP_ENDED)); then
    MK_UP_ENDED=1
    mk_sysledger_end failed || true
  fi
  if ((rc != 0)) && [[ -n $MK_UP_SNAPSHOT ]]; then
    mk_info "the snapshot $MK_UP_SNAPSHOT is kept; 'sudo motanka rollback' returns to it"
  fi
  if [[ -n $MK_UP_DIR && -d $MK_UP_DIR ]]; then
    rm -rf -- "$MK_UP_DIR" || true
  fi
  exit "$rc"
}

# _mk_up_run: steps 7 to 12.
_mk_up_run() {
  local inst rm version raw
  inst=$(_mk_up_count Inst)
  rm=$(_mk_up_count Remv Purg)
  if ((inst == 0 && rm == 0 && ${#MK_UP_PENDING[@]} == 0)); then
    mk_info "Motanka is up to date ($(mk_installed_version motanka-core)); no migration is pending"
    mk_log info "up to date; nothing changed"
    return 0
  fi
  mk_info "The update installs or upgrades $inst package(s), removes $rm Motanka package(s), and runs the pending migrations of ${MK_UP_USER:-no user}."
  if ! mk_confirm "Update Motanka now?"; then
    mk_die "$MK_EXIT_ERROR" "cancelled; nothing was changed"
  fi

  version=$(_mk_up_target_version)
  mk_sysledger_begin update "$version" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger; nothing was changed"
  MK_UP_BEGUN=1
  while IFS= read -r raw; do
    mk_sysledger_plan "$raw" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  done <"$MK_UP_DIR/plan.txt"

  MK_UP_SNAPSHOT=$MK_RUN_ID
  if ! mk_snapshot_create "$MK_UP_SNAPSHOT"; then
    MK_UP_SNAPSHOT=""
    mk_die "$MK_EXIT_ERROR" "cannot take the snapshot; no package was changed"
  fi
  _mk_up_snapper_pre

  if ((inst > 0 || rm > 0)); then
    _mk_up_upgrade "$((rm > 0))"
  else
    mk_info "no Motanka package has an upgrade"
  fi
  _mk_up_pin
  _mk_up_migrate
  _mk_up_snapper_post
  _mk_up_list_others
  MK_UP_ENDED=1
  mk_sysledger_end ok || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  mk_info "Motanka $(mk_installed_version motanka-core) is up to date. Log out of the Motanka session and back in to use it."
}

# --- entry point ------------------------------------------------------------

mk_cmd_update() {
  MK_SYSTEM=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_update_usage
        exit "$MK_EXIT_OK"
        ;;
      --system)
        MK_SYSTEM=1
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

  _mk_up_require_root
  mk_lock_system
  mk_log info "update started (dry run $MK_DRY_RUN, --system $MK_SYSTEM)"
  if ! mk_installed_version motanka-core >/dev/null; then
    mk_die "$MK_EXIT_ERROR" "Motanka is not installed (motanka-core is missing); install it with: sudo motanka install"
  fi
  mk_update_check_suite
  _mk_up_invoking_user

  trap _mk_up_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _mk_up_workdir
  mapfile -t MK_UP_PKGS < <(mk_snapshot_motanka_packages | cut -f1)
  _mk_up_apt_update
  _mk_up_simulate
  _mk_up_check_foreign
  _mk_up_load_pending

  if ((MK_DRY_RUN)); then
    _mk_up_print_plan
    mk_log info "dry run finished; nothing changed"
    exit "$MK_EXIT_OK"
  fi
  _mk_up_run
  exit "$MK_EXIT_OK"
}
