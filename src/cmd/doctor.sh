# shellcheck shell=bash
# shellcheck disable=SC2329 # functions are called by src/motanka and by the unit tests
# shellcheck disable=SC2088 # "~/..." in the report is literal text, not a path to expand
# motanka doctor (design.md, Doctor; requirements 12.2, 12.4, 12.6-12.8).
#
# This part reports the home folder: whether a User_Ledger exists, whether
# a session capture is pending, every User_Ledger entry recorded as
# unplanned (6.10, 12.8) and every path recorded as observed, that is
# written by Ubuntu's session components and left alone by the Remover
# (design.md, "Session-time home writes"). The other report fields (task
# 22.1) and --fix (task 22.2) are added by later tasks; --fix exits 2
# "not implemented yet" until then.
#
# The home folder is that of the user who runs the Doctor; as root with
# SUDO_USER set, that user's. The Doctor only reads: no file, no ledger
# line, no lock (12.4). It prints paths, never file contents (12.6).
#
# Exit codes: 0 report printed; 1 the home folder cannot be read; 2 usage
# or --fix.
#
# Test hooks: MOTANKA_ROOT (common.sh); the SUDO_USER's home folder is then
# read from $MOTANKA_ROOT/etc/passwd.

if [[ -n ${MK_DOCTOR_LOADED:-} ]]; then
  return 0
fi
MK_DOCTOR_LOADED=1

_mk_dr_base=${MK_LIBEXEC:-}
if [[ -z $_mk_dr_base ]]; then
  _mk_dr_base=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
# shellcheck source=../lib/common.sh
source "$_mk_dr_base/lib/common.sh"
# shellcheck source=../lib/userledger.sh
source "$_mk_dr_base/lib/userledger.sh"
# shellcheck source=../lib/homepaths.sh
source "$_mk_dr_base/lib/homepaths.sh"
# shellcheck source=../lib/capture.sh
source "$_mk_dr_base/lib/capture.sh"

MK_JSON=0 MK_FIX=0
MK_DR_HOME="" MK_DR_USER=""
MK_DR_UNPLANNED=() MK_DR_OBSERVED=()
MK_DR_ENTRIES=0

mk_doctor_usage() {
  cat <<'EOF'
usage: motanka doctor [--json] [--fix]

Reports Motanka's state. Changes nothing unless --fix is given.

  --json      print the report as one JSON document
  --fix       switch the repository source to the suite of the running
              release
  -h, --help  show this help

The home-folder part lists paths that a Motanka session or per-user setup
changed without a ledger entry (unplanned) and paths Ubuntu's own session
components wrote (desktop); 'motanka remove' leaves both.
EOF
}

# _mk_dr_home: sets MK_DR_USER and MK_DR_HOME.
_mk_dr_home() {
  local entry=""
  MK_DR_USER=$(id -un)
  MK_DR_HOME=${MK_HOME:-${HOME:-}}
  if ((EUID == 0)) && [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    if [[ -n ${MOTANKA_ROOT:-} ]]; then
      entry=$(awk -F: -v u="$SUDO_USER" '$1 == u && NF >= 7 { print $6; exit }' "$MOTANKA_ROOT/etc/passwd" 2>/dev/null || true)
      entry=${entry:+$MOTANKA_ROOT$entry}
    else
      entry=$(getent passwd -- "$SUDO_USER" 2>/dev/null | awk -F: 'NF >= 7 { print $6; exit }' || true)
    fi
    if [[ -n $entry ]]; then
      MK_DR_USER=$SUDO_USER
      MK_DR_HOME=$entry
    fi
  fi
  MK_DR_HOME=${MK_DR_HOME%/}
  if [[ $MK_DR_HOME != /* || ! -d $MK_DR_HOME ]]; then
    mk_die "$MK_EXIT_ERROR" "the home folder '${MK_DR_HOME:-unset}' does not exist"
  fi
}

# _mk_dr_read: MK_DR_ENTRIES, MK_DR_UNPLANNED and MK_DR_OBSERVED from the
# User_Ledger, each path once, in ledger order.
_mk_dr_read() {
  local verb rel
  local -A seen=()
  MK_DR_ENTRIES=0 MK_DR_UNPLANNED=() MK_DR_OBSERVED=()
  while IFS=$'\t' read -r _ _ verb _ rel _; do
    MK_DR_ENTRIES=$((MK_DR_ENTRIES + 1))
    case $verb in
      unplanned)
        if [[ -z ${seen[u:$rel]:-} ]]; then
          seen[u:$rel]=1
          MK_DR_UNPLANNED+=("$rel")
        fi
        ;;
      observed)
        if [[ -z ${seen[o:$rel]:-} ]]; then
          seen[o:$rel]=1
          MK_DR_OBSERVED+=("$rel")
        fi
        ;;
    esac
  done < <(MK_HOME=$MK_DR_HOME mk_userledger_read)
}

# _mk_dr_json_string <value>: the value as a JSON string.
_mk_dr_json_string() {
  local s=$1 out="" c i code
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      '"') out+='\"' ;;
      "\\") out+="\\\\" ;;
      $'\n') out+='\n' ;;
      $'\t') out+='\t' ;;
      $'\r') out+='\r' ;;
      [[:cntrl:]])
        printf -v code '%d' "'$c"
        printf -v c '\\u%04x' "$code"
        out+=$c
        ;;
      *) out+=$c ;;
    esac
  done
  printf '"%s"' "$out"
}

# _mk_dr_json_list <values...>: a JSON array of strings.
_mk_dr_json_list() {
  local v sep=""
  printf '['
  for v in "$@"; do
    printf '%s' "$sep"
    _mk_dr_json_string "$v"
    sep=", "
  done
  printf ']'
}

_mk_dr_print_json() {
  local ledger=false pending=false since=null
  if [[ -f $MK_DR_HOME/$MK_UL_STATE_REL/ledger ]]; then
    ledger=true
  fi
  if MK_HOME=$MK_DR_HOME mk_capture_pending; then
    pending=true
    since=$(_mk_dr_json_string "$(MK_HOME=$MK_DR_HOME mk_capture_started)")
  fi
  printf '{"home": {"user": %s, "path": %s, "user_ledger": %s, "entries": %d, ' \
    "$(_mk_dr_json_string "$MK_DR_USER")" "$(_mk_dr_json_string "$MK_DR_HOME")" "$ledger" "$MK_DR_ENTRIES"
  printf '"session_capture": {"pending": %s, "since": %s}, ' "$pending" "$since"
  printf '"unplanned": %s, ' "$(_mk_dr_json_list "${MK_DR_UNPLANNED[@]}")"
  printf '"desktop": %s}}\n' "$(_mk_dr_json_list "${MK_DR_OBSERVED[@]}")"
}

_mk_dr_print_text() {
  local p
  printf 'Home folder of %s (%s):\n' "$MK_DR_USER" "$MK_DR_HOME"
  if [[ -f $MK_DR_HOME/$MK_UL_STATE_REL/ledger ]]; then
    printf '  User_Ledger:      ~/%s/ledger (%d entries)\n' "$MK_UL_STATE_REL" "$MK_DR_ENTRIES"
  else
    printf '  User_Ledger:      none (this account has not logged into the Motanka session)\n'
  fi
  if MK_HOME=$MK_DR_HOME mk_capture_pending; then
    printf '  session capture:  pending since %s (ended when the session ends, at the next login or by motanka remove)\n' \
      "$(MK_HOME=$MK_DR_HOME mk_capture_started)"
  else
    printf '  session capture:  none pending\n'
  fi
  printf '  unplanned:        %d path(s) changed without a ledger entry; motanka remove leaves them\n' "${#MK_DR_UNPLANNED[@]}"
  for p in "${MK_DR_UNPLANNED[@]}"; do
    printf '    ~/%s\n' "$p"
  done
  printf "  desktop:          %d path(s) written by Ubuntu's session components; motanka remove leaves them\n" "${#MK_DR_OBSERVED[@]}"
  for p in "${MK_DR_OBSERVED[@]}"; do
    printf '    ~/%s\n' "$p"
  done
}

mk_cmd_doctor() {
  MK_JSON=0 MK_FIX=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_doctor_usage
        exit "$MK_EXIT_OK"
        ;;
      --json)
        MK_JSON=1
        ;;
      --fix)
        MK_FIX=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        mk_usage_error "unknown option '$1'"
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
  if ((MK_FIX)); then
    mk_not_implemented
  fi
  _mk_dr_home
  _mk_dr_read
  if ((MK_JSON)); then
    _mk_dr_print_json
  else
    _mk_dr_print_text
  fi
  exit "$MK_EXIT_OK"
}
