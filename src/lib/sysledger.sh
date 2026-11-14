# shellcheck shell=bash
# shellcheck disable=SC2329 # library: its functions are called by the files that source it
# System_Ledger: /var/lib/motanka/ledger (design.md, Data Models).
#
# One line per event, fields separated by tabs:
#   <utc-time>  <run-id>  <verb>  <fields...>
#   run-begin      install|update|remove  <motanka-version>
#   plan           <apt simulation line>
#   pkg-installed  <name>  <version>  auto|manual
#   menu-install   <uid>  <name>  apt|binary
#   apps-answer    yes|no  flag|question|default
#   run-end        ok|failed
#
# apps-answer is the answer of one install run to the Motanka_Apps
# question (3.15): flag for --apps or --no-apps, question for an answer at
# the question, default for no without a question (--yes without --apps,
# or no terminal to ask on). The Installer writes it right after
# run-begin, only when motanka-apps was not installed at the start of the
# run. The Doctor reports the last one (mk_sysledger_last_apps_answer).
#
# Every line is appended and fsynced before the function returns, so a
# caller that writes the line before its action keeps the ledger complete up
# to any interruption (3.9). Readers skip a torn last line and any line that
# does not match the format. Fields cannot be empty or hold control
# characters.
#
# Callers hold the system lock (mk_lock_system) while they write.
# Requires common.sh. Test hook: MOTANKA_ROOT (see common.sh).

if [[ -n ${MK_SYSLEDGER_LOADED:-} ]]; then
  return 0
fi
MK_SYSLEDGER_LOADED=1

readonly MK_SYSLEDGER_PATH=/var/lib/motanka/ledger

# mk_sysledger_file: path of the System_Ledger.
mk_sysledger_file() {
  mk_path "$MK_SYSLEDGER_PATH"
}

# _mk_sysledger_check <verb> <fields...>: 0 if verb and fields are valid.
_mk_sysledger_check() {
  local verb=$1 f
  shift
  for f in "$@"; do
    mk_field_ok "$f" || return 1
  done
  case $verb in
    run-begin)
      (($# == 2)) && [[ $1 == install || $1 == update || $1 == remove ]]
      ;;
    plan)
      (($# == 1))
      ;;
    pkg-installed)
      (($# == 3)) && [[ $3 == auto || $3 == manual ]]
      ;;
    menu-install)
      (($# == 3)) && [[ $1 =~ ^[0-9]+$ ]] && [[ $3 == apt || $3 == binary ]]
      ;;
    apps-answer)
      (($# == 2)) && [[ $1 == yes || $1 == no ]] &&
        [[ $2 == flag || $2 == question || $2 == default ]]
      ;;
    run-end)
      (($# == 1)) && [[ $1 == ok || $1 == failed ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# _mk_sysledger_valid_line <line>: 0 if the line is a complete, valid
# System_Ledger line.
_mk_sysledger_valid_line() {
  local line=$1
  local -a f
  [[ ${line//$'\t'/} != *[[:cntrl:]]* ]] || return 1
  [[ $line != *$'\t\t'* && $line != $'\t'* && $line != *$'\t' ]] || return 1
  IFS=$'\t' read -r -a f <<<"$line"
  ((${#f[@]} >= 4)) || return 1
  [[ ${f[0]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  _mk_sysledger_check "${f[@]:2}"
}

# mk_sysledger_append <verb> <fields...>: appends one line for the current
# run (MK_RUN_ID, created if unset) and fsyncs it.
mk_sysledger_append() {
  local verb=$1 file dir line
  if ! _mk_sysledger_check "$@"; then
    mk_error "invalid System_Ledger entry: verb '$verb' with $(($# - 1)) field(s)"
    return 1
  fi
  file=$(mk_sysledger_file)
  dir=${file%/*}
  if [[ ! -d $dir ]]; then
    # Only the ledger folder itself is Motanka's; its parents keep the
    # mode mkdir gives them.
    if ! mkdir -p -- "$dir" || ! chmod 0755 -- "$dir"; then
      mk_error "cannot create $dir"
      return 1
    fi
  fi
  mk_run_id >/dev/null
  line=$(
    IFS=$'\t'
    printf '%s\t%s\t%s' "$(mk_utc_now)" "$MK_RUN_ID" "$*"
  )
  if ! mk_ledger_append "$file" "$line"; then
    mk_error "cannot write the System_Ledger $file"
    return 1
  fi
  shift
  mk_log info "system ledger: $verb $*"
}

# mk_sysledger_begin <install|update|remove> <motanka-version>
mk_sysledger_begin() {
  mk_sysledger_append run-begin "$@"
}

# mk_sysledger_plan <apt simulation line>
mk_sysledger_plan() {
  mk_sysledger_append plan "$@"
}

# mk_sysledger_pkg_installed <name> <version> <auto|manual>
mk_sysledger_pkg_installed() {
  mk_sysledger_append pkg-installed "$@"
}

# mk_sysledger_menu_install <uid> <name> <apt|binary>
mk_sysledger_menu_install() {
  mk_sysledger_append menu-install "$@"
}

# mk_sysledger_apps_answer <yes|no> <flag|question|default>
mk_sysledger_apps_answer() {
  mk_sysledger_append apps-answer "$@"
}

# mk_sysledger_end <ok|failed>
mk_sysledger_end() {
  mk_sysledger_append run-end "$@"
}

# mk_sysledger_read [file]: prints every complete, valid line in order.
# Warns once on stderr if lines were skipped.
mk_sysledger_read() {
  local file=${1:-} line skipped=0
  if [[ -z $file ]]; then
    file=$(mk_sysledger_file)
  fi
  if [[ ! -e $file ]]; then
    return 0
  fi
  # read without "|| [[ -n $line ]]": a last line without its newline is
  # a torn write and is skipped.
  while IFS= read -r line; do
    if _mk_sysledger_valid_line "$line"; then
      printf '%s\n' "$line"
    else
      skipped=$((skipped + 1))
    fi
  done <"$file"
  if mk_ends_with_newline "$file"; then
    :
  else
    skipped=$((skipped + 1))
  fi
  if ((skipped > 0)); then
    mk_warn "$file: skipped $skipped incomplete or invalid line(s)"
  fi
  return 0
}

# mk_sysledger_packages [file]: Foreign_Packages recorded as installed, one
# per line, in the order first recorded.
mk_sysledger_packages() {
  mk_sysledger_read "$@" | awk -F'\t' '$3 == "pkg-installed" && !seen[$4]++ { print $4 }'
}

# mk_sysledger_menu_installs [file]: <uid> TAB <name> TAB <apt|binary>
# for every menu install.
mk_sysledger_menu_installs() {
  mk_sysledger_read "$@" | awk -F'\t' 'BEGIN { OFS = "\t" } $3 == "menu-install" { print $4, $5, $6 }'
}

# mk_sysledger_last_apps_answer [file]: <utc-time> TAB <yes|no> TAB
# <flag|question|default> of the last apps-answer line, or nothing when
# there is none.
mk_sysledger_last_apps_answer() {
  mk_sysledger_read "$@" | awk -F'\t' '
    $3 == "apps-answer" { last = $1 "\t" $4 "\t" $5 }
    END { if (last != "") print last }'
}

# mk_sysledger_incomplete_runs [file]: run IDs that have a run-begin line
# and no run-end line, in order: runs that were interrupted.
mk_sysledger_incomplete_runs() {
  mk_sysledger_read "$@" | awk -F'\t' '
    $3 == "run-begin" && !($2 in begun) { begun[$2] = 1; order[++n] = $2 }
    $3 == "run-end" { ended[$2] = 1 }
    END { for (i = 1; i <= n; i++) if (!(order[i] in ended)) print order[i] }'
}
