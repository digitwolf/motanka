# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # library: its variables and functions are used by the files that source it
# Shared library of the motanka CLI: exit codes, output with NO_COLOR
# support, journal logging, the system lock, fsync and identifiers.
#
# Sourced by src/motanka (which sets -euo pipefail) and by the unit tests.
# It does not change shell options itself.
#
# Test hook: MOTANKA_ROOT, when set, is a fake root folder that every
# system path below is resolved in (mk_path). The tests set it; no command
# line option changes it.

if [[ -n ${MK_COMMON_LOADED:-} ]]; then
  return 0
fi
MK_COMMON_LOADED=1

# Exit codes (design.md, CLI).
readonly MK_EXIT_OK=0
readonly MK_EXIT_ERROR=1
readonly MK_EXIT_USAGE=2
readonly MK_EXIT_UNSUPPORTED=3
readonly MK_EXIT_PREFLIGHT=4
readonly MK_EXIT_FOREIGN=5
readonly MK_EXIT_VERIFY=6
readonly MK_EXIT_GUARD=7
readonly MK_EXIT_MIGRATION=8
readonly MK_EXIT_LOCKED=9
readonly MK_EXIT_SUITE=10
readonly MK_EXIT_AUTH=11
readonly MK_EXIT_SESSION=12

# Options shared by the subcommands; set by mk_parse_common_opt.
MK_DRY_RUN=0
MK_YES=0
MK_NOT_A_VM=0
# Name of the running subcommand, used in messages and journal entries.
MK_CMD=${MK_CMD:-motanka}
# Run identifier for ledger lines; created on first use by mk_run_id.
MK_RUN_ID=${MK_RUN_ID:-}

# Longest journal message in bytes; longer messages are cut. Messages
# carry paths and package names only, never file contents (12.6).
readonly MK_LOG_MAX=1000

# --- paths --------------------------------------------------------------

# mk_path <absolute-path>: the path inside MOTANKA_ROOT (tests) or itself.
mk_path() {
  printf '%s%s\n' "${MOTANKA_ROOT:-}" "$1"
}

# --- output -------------------------------------------------------------

MK_C_RED="" MK_C_YELLOW="" MK_C_BOLD="" MK_C_RESET=""

# mk_color_init: colour on stderr only if it is a terminal, NO_COLOR is
# unset or empty (no-color.org), and TERM is not "dumb".
mk_color_init() {
  MK_C_RED="" MK_C_YELLOW="" MK_C_BOLD="" MK_C_RESET=""
  if [[ -z ${NO_COLOR:-} && -t 2 && ${TERM:-dumb} != dumb ]]; then
    MK_C_RED=$'\e[31m' MK_C_YELLOW=$'\e[33m' MK_C_BOLD=$'\e[1m' MK_C_RESET=$'\e[0m'
  fi
}

# mk_info <message>: progress message on stderr.
mk_info() {
  printf '%s\n' "$*" >&2
}

# mk_warn <message>: warning on stderr and in the journal.
mk_warn() {
  printf '%smotanka: warning:%s %s\n' "$MK_C_YELLOW" "$MK_C_RESET" "$*" >&2
  mk_log warning "$*"
}

# mk_error <message>: error on stderr and in the journal.
mk_error() {
  printf '%smotanka: error:%s %s\n' "$MK_C_RED" "$MK_C_RESET" "$*" >&2
  mk_log err "$*"
}

# mk_cmd_name: "motanka" or "motanka <subcommand>".
mk_cmd_name() {
  if [[ $MK_CMD == motanka ]]; then
    printf 'motanka\n'
  else
    printf 'motanka %s\n' "$MK_CMD"
  fi
}

# mk_die <exit-code> <message>: prints the message and exits. Usage errors
# (exit 2) are not written to the journal.
mk_die() {
  local code=$1
  shift
  if [[ $code == "$MK_EXIT_USAGE" ]]; then
    printf '%s%s:%s %s\n' "$MK_C_BOLD" "$(mk_cmd_name)" "$MK_C_RESET" "$*" >&2
  else
    mk_error "$*"
  fi
  exit "$code"
}

# mk_usage_error <message>: exit 2 with a hint to --help.
mk_usage_error() {
  mk_die "$MK_EXIT_USAGE" "$* (see '$(mk_cmd_name) --help')"
}

# mk_not_implemented: exit 2 for subcommands that later tasks fill in.
mk_not_implemented() {
  mk_die "$MK_EXIT_USAGE" "not implemented yet"
}

# --- journal ------------------------------------------------------------

# mk_log <priority> <message>: one journal entry with SYSLOG_IDENTIFIER
# motanka, through systemd-cat. Priority is a syslog name (err, warning,
# notice, info, debug). Control characters become spaces and the message is
# cut at MK_LOG_MAX bytes. A missing or failing journal never fails the
# caller; nothing is written to log files.
mk_log() {
  local prio=$1 msg
  shift
  case $prio in
    emerg | alert | crit | err | warning | notice | info | debug) ;;
    *) prio=info ;;
  esac
  msg="$(mk_cmd_name): $*"
  msg=${msg//[[:cntrl:]]/ }
  if ((${#msg} > MK_LOG_MAX)); then
    msg="${msg:0:MK_LOG_MAX}..."
  fi
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$msg" | systemd-cat -t motanka -p "$prio" 2>/dev/null || true
  fi
  return 0
}

# --- options ------------------------------------------------------------

# mk_parse_common_opt <option>: handles --dry-run, --yes/-y and
# --i-know-this-is-not-a-vm. Returns 0 if the option was one of them, 1
# otherwise. Each subcommand decides which of them it accepts.
mk_parse_common_opt() {
  case $1 in
    --dry-run) MK_DRY_RUN=1 ;;
    --yes | -y) MK_YES=1 ;;
    --i-know-this-is-not-a-vm) MK_NOT_A_VM=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# mk_confirm <question>: 0 if the user agrees. With --yes it agrees without
# asking. Without a terminal on stdin it refuses and names --yes.
mk_confirm() {
  local answer=""
  if ((MK_YES)); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    mk_info "$(mk_cmd_name): '$1' needs an answer; pass --yes to run without a terminal"
    return 1
  fi
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r answer || true
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

# --- lock ---------------------------------------------------------------

MK_LOCK_FD=""

# mk_lock_system: takes flock on /run/lock/motanka.lock without waiting.
# Exits 9 if another Motanka process holds it, 1 if the lock file cannot be
# opened. The lock is released when the process exits.
mk_lock_system() {
  local lock fd
  lock=$(mk_path /run/lock/motanka.lock)
  if [[ -n $MK_LOCK_FD ]]; then
    return 0
  fi
  if ! exec {fd}>>"$lock"; then
    mk_die "$MK_EXIT_ERROR" "cannot open the lock file $lock"
  fi
  if ! flock -n "$fd"; then
    exec {fd}>&-
    mk_die "$MK_EXIT_LOCKED" "another Motanka process is running (lock $lock is held)"
  fi
  MK_LOCK_FD=$fd
}

# --- files and identifiers ----------------------------------------------

# mk_fsync <path>...: flushes each file or folder to disk (sync(1) opens
# each argument and calls fsync on it).
mk_fsync() {
  sync -- "$@"
}

# mk_utc_now: the current time as 2026-11-13T09:15:02Z.
mk_utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# mk_hex <bytes>: that many random bytes as lowercase hex.
mk_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# mk_run_id: sets MK_RUN_ID once per process (20261113T091502Z-a1b2c3) and
# prints it.
mk_run_id() {
  if [[ -z $MK_RUN_ID ]]; then
    MK_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(mk_hex 3)"
  fi
  printf '%s\n' "$MK_RUN_ID"
}

# mk_field_ok <value>: 0 if the value can be a ledger field: not empty, no
# tab, newline or other control character.
mk_field_ok() {
  [[ -n $1 && $1 != *[[:cntrl:]]* ]]
}

# mk_ends_with_newline <file>: 0 if the file is empty or its last byte is a
# newline.
mk_ends_with_newline() {
  local last
  [[ -s $1 ]] || return 0
  last=$(tail -c 1 -- "$1" | od -An -tx1 | tr -d ' \n')
  [[ $last == 0a ]]
}

# mk_ledger_append <file> <line>: appends one line to a ledger and fsyncs
# it before returning. If the previous write was torn (the file does not
# end with a newline), that fragment is first closed with a \x01 byte and a
# newline, so readers reject it and the new line stays whole. Fsyncs the
# folder too when the file is new.
mk_ledger_append() {
  local file=$1 line=$2 new=0
  [[ -e $file ]] || new=1
  if ! mk_ends_with_newline "$file"; then
    printf '\001\n' >>"$file" || return 1
  fi
  printf '%s\n' "$line" >>"$file" || return 1
  mk_fsync "$file" || return 1
  if ((new)); then
    mk_fsync "$(dirname -- "$file")" || return 1
  fi
}
