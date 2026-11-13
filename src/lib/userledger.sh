# shellcheck shell=bash
# shellcheck disable=SC2329 # library: its functions are called by the files that source it
# User_Ledger: ~/.local/state/motanka/ledger (design.md, Data Models).
#
# One line per home-folder change, fields separated by tabs:
#   <utc-time> <run-id> <verb> <class> <path> <before> <after> <backup-id>
#
#   verb    setup-begin, create, replace, symlink, block, menu-desktop,
#           unplanned, adopt, observed, setup-end
#   class   namespaced, session, app, shared, or - (setup-*, unplanned);
#           session or app for adopt; desktop for observed
#   path    relative to the home folder; a trailing / marks a folder that
#           Motanka created (create) or adopted (adopt), or a folder an
#           Ubuntu session component created (observed); - for setup-*
#   before  state of the path before the change, after: the state Motanka
#           wrote. A state is - (absent), the SHA-256 of a regular file's
#           content, or l:<SHA-256 of the target> for a symbolic link.
#   backup  ID of the copy of the earlier file or link under
#           ~/.local/state/motanka/backups/<backup-id>/<path>, or -
#
# The session capture (src/lib/capture.sh) writes three verbs for paths
# that appeared during a Motanka session without a ledger entry:
#   adopt     <session|app> <path> - <state when adopted> -   (a folder:
#             <path/> - - -). Upstream or Stack code of the session created
#             it; a revert deletes it when it still has that state, moves it
#             aside when it changed, and removes an adopted folder when it is
#             empty.
#   observed  desktop <path> - <state or -> -   An Ubuntu session component
#             created it, as it does for any graphical login; a revert
#             leaves it and lists it, and so does the Doctor.
#   unplanned - <path> - <state or -> -   Nothing Motanka knows created or
#             changed it; a revert lists it and leaves it (6.10, 12.8).
#
# Write-ahead (6.2, 6.3, 3.9): a change first creates its missing parent
# folders (each ledgered before its mkdir), then copies the existing file
# into a backup and fsyncs it, then appends and fsyncs the ledger line, and
# only then writes the new file to a temporary name next to the target
# (.<name>.motanka-tmp) and renames it over the target (6.11).
# mk_userledger_mkdir creates folders the same way, without a file.
#
# mk_userledger_revert walks the ledger in reverse (10.2) and restores the
# earlier state (10.3). A path whose state is neither the "after" nor the
# "before" state was edited by the user and moves to
# ~/.local/state/motanka-removed-<date>/ first (10.4); for a marked block,
# the block is cut out of the edited file instead (10.5). An entry inside a
# Namespaced_Path (other than the state folder) is deleted whatever its
# state, never moved aside or restored: the Remover deletes those folders
# whole (10.5), and programs of the session rewrite files in them (the
# dconf database ~/.config/dconf/motanka is rewritten by dconf-service,
# files under ~/.config/omarchy and ~/.local/state/omarchy by Upstream's
# commands), which is no edit by the user. Every step checks the current
# state, so a revert can be interrupted and run again.
# mk_userledger_revert_plan takes the same decisions without changing
# anything (the Remover's --dry-run).
#
# mk_userledger_lock takes the per-user lock $XDG_RUNTIME_DIR/motanka.lock
# that per-user setup and the Remover's user phase share (exit code 9 when
# it is held).
#
# The functions run as the user who owns the home folder. Home folder:
# MK_HOME, or HOME. Requires common.sh.

if [[ -n ${MK_USERLEDGER_LOADED:-} ]]; then
  return 0
fi
MK_USERLEDGER_LOADED=1

readonly MK_UL_STATE_REL=.local/state/motanka
readonly MK_UL_BLOCK_BEGIN='# >>> motanka >>>'
readonly MK_UL_BLOCK_END='# <<< motanka <<<'
# Namespaced_Paths (requirements.md, Glossary), relative to the home folder.
readonly -a MK_UL_NAMESPACED=(.config/dconf/motanka .config/omarchy .local/share/omarchy
  .local/state/omarchy .local/state/motanka .cache/omarchy .cache/motanka)

# Set by the _mk_ul_stage_* functions for the commit step.
_MK_UL_ABS=""
_MK_UL_SRC=""
_MK_UL_TARGET=""

# The descriptor of the per-user lock once mk_userledger_lock holds it.
MK_UL_LOCK_FD=""

# Ledger lines that mk_userledger_revert_plan treats as written after the
# ledger's last line (the lines a pending session capture end would write,
# "mk_capture_end --plan"). The revert itself never reads them.
MK_UL_PLAN_EXTRA=()

# State of one reverse walk (_mk_ul_walk): the mode (apply or plan), the
# home and state folders, and, in a plan, the simulated effect of the steps
# so far: _MK_UL_SIM maps a path a step touched to "<state> TAB <content
# file>", _MK_UL_TAKEN holds the motanka-removed-<date> destinations the
# plan used, _MK_UL_TRIED the folders it listed.
_MK_UL_MODE=apply
_MK_UL_HOME=""
_MK_UL_STATEDIR=""
declare -gA _MK_UL_SIM=() _MK_UL_TAKEN=() _MK_UL_TRIED=()

# --- paths and states ---------------------------------------------------

_mk_ul_home() {
  local home=${MK_HOME:-${HOME:-}}
  home=${home%/}
  if [[ $home != /* || ! -d $home ]]; then
    mk_error "home folder '${home:-unset}' is not an existing absolute path"
    return 1
  fi
  printf '%s\n' "$home"
}

# mk_userledger_state_dir, mk_userledger_file: paths for the home folder.
mk_userledger_state_dir() {
  local home
  home=$(_mk_ul_home) || return 1
  printf '%s/%s\n' "$home" "$MK_UL_STATE_REL"
}

mk_userledger_file() {
  local state
  state=$(mk_userledger_state_dir) || return 1
  printf '%s/ledger\n' "$state"
}

# _mk_ul_path_syntax_ok <path>: relative, clean, no control characters; a
# trailing / is allowed.
_mk_ul_path_syntax_ok() {
  local p=$1 part rest
  mk_field_ok "$p" || return 1
  [[ $p != /* && $p != - ]] || return 1
  rest=${p%/}
  [[ -n $rest ]] || return 1
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    [[ -n $part && $part != . && $part != .. ]] || return 1
    if [[ $rest == */* ]]; then
      rest=${rest#*/}
    else
      rest=""
    fi
  done
}

# _mk_ul_in_state <path>: 0 if the path is the state folder or inside it.
_mk_ul_in_state() {
  local p=${1%/}
  [[ $p == "$MK_UL_STATE_REL" || $p == "$MK_UL_STATE_REL"/* ]]
}

# _mk_ul_is_state_ancestor <path>: 0 for .local, .local/state and the
# state folder itself.
_mk_ul_is_state_ancestor() {
  local p=${1%/}
  [[ $p == .local || $p == .local/state || $p == "$MK_UL_STATE_REL" ]]
}

# _mk_ul_in_namespaced <path>: 0 if the path is a Namespaced_Path other
# than the state folder, or inside one.
_mk_ul_in_namespaced() {
  local p=${1%/} root
  for root in "${MK_UL_NAMESPACED[@]}"; do
    if [[ $root != "$MK_UL_STATE_REL" ]] && [[ $p == "$root" || $p == "$root"/* ]]; then
      return 0
    fi
  done
  return 1
}

# _mk_ul_path_ok <path>: a path that an action may change.
_mk_ul_path_ok() {
  if ! _mk_ul_path_syntax_ok "$1" || [[ $1 == */ ]] || _mk_ul_in_state "$1"; then
    mk_error "invalid home-folder path '$1'"
    return 1
  fi
}

_mk_ul_class_ok() {
  case $1 in
    namespaced | session | app | shared) return 0 ;;
  esac
  mk_error "invalid Home_Path_Class '$1'"
  return 1
}

# _mk_ul_sha <file>: SHA-256 of the file's content.
_mk_ul_sha() {
  local out
  out=$(sha256sum <"$1") || return 1
  printf '%s\n' "${out:0:64}"
}

# _mk_ul_link_state <target>: the state string of a link to <target>.
_mk_ul_link_state() {
  local out
  out=$(printf '%s' "$1" | sha256sum) || return 1
  printf 'l:%s\n' "${out:0:64}"
}

# _mk_ul_state <absolute-path>: -, a SHA-256, l:<SHA-256>, or dir/other
# (which never appear in the ledger).
_mk_ul_state() {
  local target
  if [[ -L $1 ]]; then
    target=$(readlink -n -- "$1" && printf x) || return 1
    _mk_ul_link_state "${target%x}"
  elif [[ -f $1 ]]; then
    _mk_ul_sha "$1"
  elif [[ -d $1 ]]; then
    printf 'dir\n'
  elif [[ -e $1 ]]; then
    printf 'other\n'
  else
    printf -- '-\n'
  fi
}

# mk_userledger_state <path>: the current state of a home-folder path, in
# the ledger's notation: - (absent), a SHA-256, l:<SHA-256> for a link; or
# dir or other, which never appear in the ledger. Per-user setup compares
# it with a ledgered entry to resume (6.7).
mk_userledger_state() {
  local home
  if ! _mk_ul_path_syntax_ok "$1" || [[ $1 == */ ]]; then
    mk_error "invalid home-folder path '$1'"
    return 1
  fi
  home=$(_mk_ul_home) || return 1
  _mk_ul_state "$home/$1"
}

# _mk_ul_tmp <absolute-path>: the temporary name used to replace it.
_mk_ul_tmp() {
  printf '%s/.%s.motanka-tmp\n' "${1%/*}" "${1##*/}"
}

# --- ledger lines -------------------------------------------------------

# _mk_ul_append <verb> <class> <path> <before> <after> <backup>
_mk_ul_append() {
  local file line
  file=$(mk_userledger_file) || return 1
  mk_run_id >/dev/null
  line=$(
    IFS=$'\t'
    printf '%s\t%s\t%s' "$(mk_utc_now)" "$MK_RUN_ID" "$*"
  )
  if ! mk_ledger_append "$file" "$line"; then
    mk_error "cannot write the User_Ledger $file"
    return 1
  fi
  mk_log info "user ledger: $1 $3"
}

# _mk_ul_valid_line <line>: 0 if the line is a complete, valid entry.
_mk_ul_valid_line() {
  local line=$1 f4 hash_re='^(-|l:[0-9a-f]{64}|[0-9a-f]{64})$'
  local -a f
  [[ ${line//$'\t'/} != *[[:cntrl:]]* ]] || return 1
  [[ $line != *$'\t\t'* && $line != $'\t'* && $line != *$'\t' ]] || return 1
  IFS=$'\t' read -r -a f <<<"$line"
  ((${#f[@]} == 8)) || return 1
  [[ ${f[0]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [[ ${f[5]} =~ $hash_re && ${f[6]} =~ $hash_re ]] || return 1
  [[ ${f[7]} == - || ${f[7]} =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$ ]] || return 1
  f4=${f[4]}
  case ${f[2]} in
    setup-begin | setup-end)
      [[ ${f[3]} == - && $f4 == - && ${f[5]} == - && ${f[6]} == - && ${f[7]} == - ]]
      ;;
    unplanned)
      [[ ${f[3]} == - ]] && _mk_ul_path_syntax_ok "$f4" && [[ $f4 != */ ]]
      ;;
    adopt)
      [[ ${f[3]} == session || ${f[3]} == app ]] || return 1
      _mk_ul_path_syntax_ok "$f4" || return 1
      [[ ${f[5]} == - && ${f[7]} == - ]] || return 1
      if [[ $f4 == */ ]]; then
        [[ ${f[6]} == - ]]
      else
        [[ ${f[6]} != - ]]
      fi
      ;;
    observed)
      [[ ${f[3]} == desktop ]] && _mk_ul_path_syntax_ok "$f4" && [[ ${f[5]} == - && ${f[7]} == - ]]
      ;;
    create | replace | symlink | block | menu-desktop)
      case ${f[3]} in
        namespaced | session | app | shared) ;;
        *) return 1 ;;
      esac
      _mk_ul_path_syntax_ok "$f4" || return 1
      if [[ $f4 == */ ]]; then
        [[ ${f[2]} == create && ${f[5]} == - && ${f[6]} == - && ${f[7]} == - ]]
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# mk_userledger_read [file]: prints every complete, valid entry in order;
# warns once on stderr if lines were skipped (a torn last line or a line
# that does not match the format).
mk_userledger_read() {
  local file=${1:-} line skipped=0
  if [[ -z $file ]]; then
    file=$(mk_userledger_file) || return 1
  fi
  if [[ ! -e $file ]]; then
    return 0
  fi
  while IFS= read -r line; do
    if _mk_ul_valid_line "$line"; then
      printf '%s\n' "$line"
    else
      skipped=$((skipped + 1))
    fi
  done <"$file"
  if ! mk_ends_with_newline "$file"; then
    skipped=$((skipped + 1))
  fi
  if ((skipped > 0)); then
    mk_warn "$file: skipped $skipped incomplete or invalid line(s)"
  fi
  return 0
}

# --- setup --------------------------------------------------------------

# mk_userledger_init: creates the state folder and the ledger once. Folders
# on the way to the state folder that did not exist are ledgered as created
# right after the ledger file exists, so a revert removes them again.
mk_userledger_init() {
  local home state rel abs d
  local -a created=()
  home=$(_mk_ul_home) || return 1
  state=$home/$MK_UL_STATE_REL
  if [[ -f $state/ledger ]]; then
    return 0
  fi
  for rel in .local .local/state "$MK_UL_STATE_REL"; do
    abs=$home/$rel
    if [[ -d $abs ]]; then
      continue
    fi
    if [[ -e $abs || -L $abs ]]; then
      mk_error "$abs exists and is not a folder"
      return 1
    fi
    if [[ $rel == "$MK_UL_STATE_REL" ]]; then
      mkdir -m 0700 -- "$abs" || return 1
    else
      mkdir -- "$abs" || return 1
    fi
    created+=("$rel/")
  done
  (umask 077 && : >>"$state/ledger") || return 1
  mk_fsync "$state/ledger" "$state" || return 1
  for d in "${created[@]}"; do
    _mk_ul_append create namespaced "$d" - - - || return 1
  done
}

# mk_userledger_setup_begin, mk_userledger_setup_end: markers of one run of
# per-user setup (6.7).
mk_userledger_setup_begin() {
  mk_userledger_init || return 1
  _mk_ul_append setup-begin - - - - -
}

mk_userledger_setup_end() {
  mk_userledger_init || return 1
  _mk_ul_append setup-end - - - - -
}

# mk_userledger_record_unplanned <path>: records a path that changed during
# setup without a ledger entry (6.10). A revert reports it and leaves it.
mk_userledger_record_unplanned() {
  local home rel=$1 cur
  _mk_ul_path_ok "$rel" || return 1
  home=$(_mk_ul_home) || return 1
  mk_userledger_init || return 1
  cur=$(_mk_ul_state "$home/$rel") || return 1
  case $cur in
    dir | other) cur=- ;;
  esac
  _mk_ul_append unplanned - "$rel" - "$cur" -
}

# mk_userledger_adopt_line <class> <path>: prints the adopt line
# (without its time and run-ID fields) for a path that exists now: a
# regular file or link with its current state, or a folder as "<path>/".
# Returns 1, printing nothing, when the path is missing or another kind of
# file, or the class is not session or app.
mk_userledger_adopt_line() {
  local class=$1 rel=${2%/} home cur
  case $class in
    session | app) ;;
    *) return 1 ;;
  esac
  if ! _mk_ul_path_syntax_ok "$rel" || _mk_ul_in_state "$rel"; then
    return 1
  fi
  home=$(_mk_ul_home) || return 1
  cur=$(_mk_ul_state "$home/$rel") || return 1
  case $cur in
    dir)
      if [[ -L $home/$rel ]]; then
        return 1
      fi
      printf 'adopt\t%s\t%s/\t-\t-\t-\n' "$class" "$rel"
      ;;
    - | other) return 1 ;;
    *) printf 'adopt\t%s\t%s\t-\t%s\t-\n' "$class" "$rel" "$cur" ;;
  esac
}

# mk_userledger_adopt <class> <path>: records that Motanka's session
# created a path it did not ledger beforehand (see adopt at the top).
mk_userledger_adopt() {
  local line
  line=$(mk_userledger_adopt_line "$1" "$2") || {
    mk_error "cannot adopt '$2' as $1: it is not a file, link or folder in the home folder"
    return 1
  }
  mk_userledger_init || return 1
  local -a f
  IFS=$'\t' read -r -a f <<<"$line"
  _mk_ul_append "${f[@]}"
}

# mk_userledger_append_lines <file>: appends complete entries (every field,
# time and run ID included, one per line) to the User_Ledger with one fsync.
# Every line is checked first; nothing is appended if one is invalid. A
# torn last line is closed first, as mk_ledger_append does.
mk_userledger_append_lines() {
  local src=$1 file line new=0 n=0
  if [[ ! -s $src ]]; then
    return 0
  fi
  if ! mk_ends_with_newline "$src"; then
    mk_error "refusing to append $src to the User_Ledger: its last line has no newline"
    return 1
  fi
  while IFS= read -r line; do
    if ! _mk_ul_valid_line "$line"; then
      mk_error "refusing to write an invalid User_Ledger line: ${line//$'\t'/ }"
      return 1
    fi
    n=$((n + 1))
  done <"$src"
  mk_userledger_init || return 1
  file=$(mk_userledger_file) || return 1
  [[ -e $file ]] || new=1
  if ! mk_ends_with_newline "$file"; then
    printf '\001\n' >>"$file" || return 1
  fi
  if ! cat -- "$src" >>"$file" || ! mk_fsync "$file"; then
    mk_error "cannot write the User_Ledger $file"
    return 1
  fi
  if ((new)); then
    mk_fsync "${file%/*}" || return 1
  fi
  mk_log info "user ledger: appended $n line(s)"
}

# --- staging: everything up to and including the ledger line ------------

# _mk_ul_new_backup <state-dir>: creates a new, empty backup folder and
# prints its ID.
_mk_ul_new_backup() {
  local id i
  if [[ ! -d $1/backups ]]; then
    mkdir -- "$1/backups" || return 1
  fi
  chmod 0700 -- "$1/backups" || return 1
  for i in 1 2 3 4 5 6 7 8; do
    id="$(date -u +%Y%m%dT%H%M%SZ)-$(mk_hex 4)"
    if mkdir -m 0700 -- "$1/backups/$id" 2>/dev/null; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  mk_error "cannot create a backup folder in $1/backups"
  return 1
}

# _mk_ul_mkdir_private <base> <relative-folder>: creates each missing
# folder of <relative-folder> below the existing <base>, each with mode
# 0700.
_mk_ul_mkdir_private() {
  local dir=$1 rest=$2 part
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    if [[ $rest == */* ]]; then
      rest=${rest#*/}
    else
      rest=""
    fi
    dir=$dir/$part
    if [[ ! -d $dir ]]; then
      mkdir -m 0700 -- "$dir" || return 1
    fi
  done
}

# _mk_ul_ensure_parents <class> <path>: creates missing parent folders of
# <path>, each ledgered as "create <class> <folder>/" before its mkdir.
_mk_ul_ensure_parents() {
  [[ $2 == */* ]] || return 0
  _mk_ul_ensure_dirs "$1" "${2%/*}"
}

# _mk_ul_ensure_dirs <class> <folder>: creates each missing folder of the
# home-relative <folder> (no trailing /), from the top down, each ledgered
# as "create <class> <folder>/" before its mkdir.
_mk_ul_ensure_dirs() {
  local class=$1 rest=$2 home part prefix="" abs
  home=$(_mk_ul_home) || return 1
  while [[ -n $rest ]]; do
    part=${rest%%/*}
    if [[ $rest == */* ]]; then
      rest=${rest#*/}
    else
      rest=""
    fi
    prefix=${prefix:+$prefix/}$part
    abs=$home/$prefix
    if [[ -d $abs ]]; then
      continue
    fi
    if [[ -e $abs || -L $abs ]]; then
      mk_error "$abs exists and is not a folder"
      return 1
    fi
    _mk_ul_append create "$class" "$prefix/" - - - || return 1
    mkdir -- "$abs" || return 1
  done
}

# _mk_ul_stage <verb> <class> <path> <after>: the common part of every
# change. <verb> "write" becomes create or replace. Sets _MK_UL_ABS.
_mk_ul_stage() {
  local verb=$1 class=$2 rel=$3 after=$4 home state abs before backup=- copy
  home=$(_mk_ul_home) || return 1
  mk_userledger_init || return 1
  state=$home/$MK_UL_STATE_REL
  abs=$home/$rel
  before=$(_mk_ul_state "$abs") || return 1
  case $before in
    dir | other)
      mk_error "$abs is not a regular file or a symbolic link; not changed"
      return 1
      ;;
  esac
  if [[ $verb == write ]]; then
    if [[ $before == - ]]; then
      verb=create
    else
      verb=replace
    fi
  fi
  _mk_ul_ensure_parents "$class" "$rel" || return 1
  if [[ $before != - ]]; then
    backup=$(_mk_ul_new_backup "$state") || return 1
    copy=$state/backups/$backup/$rel
    if [[ $rel == */* ]]; then
      _mk_ul_mkdir_private "$state/backups/$backup" "${rel%/*}" || return 1
    fi
    cp -P --preserve=mode,timestamps -- "$abs" "$copy" || return 1
    if [[ $(_mk_ul_state "$copy") != "$before" ]]; then
      mk_error "$abs changed while it was backed up; not changed"
      return 1
    fi
    if [[ -L $copy ]]; then
      mk_fsync "${copy%/*}" || return 1
    else
      mk_fsync "$copy" "${copy%/*}" || return 1
    fi
  fi
  _mk_ul_append "$verb" "$class" "$rel" "$before" "$after" "$backup" || return 1
  _MK_UL_ABS=$abs
}

# _mk_ul_stage_write <class> <path> <source-file>
_mk_ul_stage_write() {
  local class=$1 rel=$2 src=$3 after
  if ! _mk_ul_class_ok "$class" || ! _mk_ul_path_ok "$rel"; then
    return 1
  fi
  if [[ ! -f $src || ! -r $src ]]; then
    mk_error "source '$src' is not a readable file"
    return 1
  fi
  after=$(_mk_ul_sha "$src") || return 1
  _mk_ul_stage write "$class" "$rel" "$after" || return 1
  _MK_UL_SRC=$src
}

# _mk_ul_stage_menu_desktop <path> <source-file>
_mk_ul_stage_menu_desktop() {
  local rel=$1 src=$2 after
  _mk_ul_path_ok "$rel" || return 1
  if [[ ! -f $src || ! -r $src ]]; then
    mk_error "source '$src' is not a readable file"
    return 1
  fi
  after=$(_mk_ul_sha "$src") || return 1
  _mk_ul_stage menu-desktop app "$rel" "$after" || return 1
  _MK_UL_SRC=$src
}

# _mk_ul_stage_symlink <class> <path> <target>
_mk_ul_stage_symlink() {
  local class=$1 rel=$2 target=$3 after
  if ! _mk_ul_class_ok "$class" || ! _mk_ul_path_ok "$rel"; then
    return 1
  fi
  if ! mk_field_ok "$target"; then
    mk_error "invalid link target for $rel"
    return 1
  fi
  after=$(_mk_ul_link_state "$target") || return 1
  _mk_ul_stage symlink "$class" "$rel" "$after" || return 1
  _MK_UL_TARGET=$target
}

# _mk_ul_block_content <file-or-/dev/null> <body-file>: the file with one
# marked block holding <body-file>: an existing block is replaced in place,
# otherwise the block is appended after a final newline.
_mk_ul_block_content() {
  awk -v begin="$MK_UL_BLOCK_BEGIN" -v end="$MK_UL_BLOCK_END" -v body="$2" '
    function block(   line) {
      print begin
      while ((getline line < body) > 0) print line
      close(body)
      print end
    }
    $0 == begin { if (!done) { block(); done = 1 }; skip = 1; next }
    skip && $0 == end { skip = 0; next }
    skip { next }
    { print }
    END { if (!done) block() }
  ' "$1"
}

# _mk_ul_strip_block <file>: the file without its marked block lines.
_mk_ul_strip_block() {
  awk -v begin="$MK_UL_BLOCK_BEGIN" -v end="$MK_UL_BLOCK_END" '
    $0 == begin { skip = 1; next }
    skip && $0 == end { skip = 0; next }
    skip { next }
    { print }
  ' "$1"
}

# _mk_ul_stage_block <class> <path> <body-file>: stages the file with the
# block in ~/.local/state/motanka/staging.* (_MK_UL_SRC).
_mk_ul_stage_block() {
  local class=$1 rel=$2 body=$3 home abs state staging after input=/dev/null
  if ! _mk_ul_class_ok "$class" || ! _mk_ul_path_ok "$rel"; then
    return 1
  fi
  if [[ ! -f $body || ! -r $body ]]; then
    mk_error "block body '$body' is not a readable file"
    return 1
  fi
  if grep -qxF -e "$MK_UL_BLOCK_BEGIN" -e "$MK_UL_BLOCK_END" -- "$body"; then
    mk_error "block body '$body' contains a block marker"
    return 1
  fi
  home=$(_mk_ul_home) || return 1
  abs=$home/$rel
  if [[ -L $abs ]]; then
    mk_error "$abs is a symbolic link; a block is added only to a regular file"
    return 1
  fi
  if [[ -e $abs ]]; then
    if [[ ! -f $abs ]]; then
      mk_error "$abs is not a regular file; not changed"
      return 1
    fi
    input=$abs
  fi
  mk_userledger_init || return 1
  state=$home/$MK_UL_STATE_REL
  staging=$(umask 077 && mktemp -- "$state/staging.XXXXXX") || return 1
  if ! _mk_ul_block_content "$input" "$body" >"$staging"; then
    rm -f -- "$staging"
    return 1
  fi
  if [[ $input == /dev/null ]]; then
    chmod 0644 -- "$staging" || return 1
  else
    chmod --reference="$abs" -- "$staging" || return 1
  fi
  after=$(_mk_ul_sha "$staging") || return 1
  _MK_UL_SRC=$staging
  _mk_ul_stage block "$class" "$rel" "$after"
}

# --- commit -------------------------------------------------------------

# _mk_ul_commit_file <absolute-path> <source-file>: write-then-rename.
_mk_ul_commit_file() {
  local abs=$1 src=$2 tmp
  tmp=$(_mk_ul_tmp "$abs")
  rm -f -- "$tmp" || return 1
  cp --preserve=mode -- "$src" "$tmp" || return 1
  mk_fsync "$tmp" || return 1
  mv -fT -- "$tmp" "$abs" || return 1
  mk_fsync "${abs%/*}"
}

# _mk_ul_commit_symlink <absolute-path> <target>
_mk_ul_commit_symlink() {
  local abs=$1 target=$2 tmp
  tmp=$(_mk_ul_tmp "$abs")
  rm -f -- "$tmp" || return 1
  ln -s -- "$target" "$tmp" || return 1
  mv -fT -- "$tmp" "$abs" || return 1
  mk_fsync "${abs%/*}"
}

# --- public changes -----------------------------------------------------

# mk_userledger_write <class> <path> <source-file>: creates or replaces a
# regular file with the content and mode of <source-file>.
mk_userledger_write() {
  _mk_ul_stage_write "$@" || return 1
  _mk_ul_commit_file "$_MK_UL_ABS" "$_MK_UL_SRC"
}

# mk_userledger_menu_desktop <path> <source-file>: a desktop entry written
# for an Upstream menu install (5.13, 7.7). A revert keeps it unless
# --purge is given.
mk_userledger_menu_desktop() {
  _mk_ul_stage_menu_desktop "$@" || return 1
  _mk_ul_commit_file "$_MK_UL_ABS" "$_MK_UL_SRC"
}

# mk_userledger_symlink <class> <path> <target>: creates or replaces a
# symbolic link.
mk_userledger_symlink() {
  _mk_ul_stage_symlink "$@" || return 1
  _mk_ul_commit_symlink "$_MK_UL_ABS" "$_MK_UL_TARGET"
}

# mk_userledger_block <class> <path> <body-file>: adds the marked block
# (# >>> motanka >>> ... # <<< motanka <<<) to a regular file, or replaces
# the block already there (6.6).
mk_userledger_block() {
  _mk_ul_stage_block "$@" || return 1
  _mk_ul_commit_file "$_MK_UL_ABS" "$_MK_UL_SRC" || return 1
  rm -f -- "$_MK_UL_SRC"
}

# mk_userledger_mkdir <class> <folder/>: creates the folder and each of its
# missing parents inside the home folder. Every folder it creates is
# ledgered as "create <class> <folder>/" before its mkdir, so a revert
# removes it again when it is empty; folders that exist are not ledgered.
mk_userledger_mkdir() {
  local class=${1:-} rel=${2:-}
  _mk_ul_class_ok "$class" || return 1
  if ! _mk_ul_path_syntax_ok "$rel" || _mk_ul_in_state "$rel"; then
    mk_error "invalid home-folder path '$rel'"
    return 1
  fi
  mk_userledger_init || return 1
  _mk_ul_ensure_dirs "$class" "${rel%/}"
}

# --- per-user lock ------------------------------------------------------

# mk_userledger_lock: takes flock on $XDG_RUNTIME_DIR/motanka.lock without
# waiting and keeps it until the process exits (MK_UL_LOCK_FD). Per-user
# setup and the Remover's user phase take it for their whole run. Returns
# 0; 9 (MK_EXIT_LOCKED) when another process holds it; 1 when
# XDG_RUNTIME_DIR is not a folder or the lock file cannot be opened.
mk_userledger_lock() {
  local rt=${XDG_RUNTIME_DIR:-} fd
  if [[ -n $MK_UL_LOCK_FD ]]; then
    return 0
  fi
  if [[ -z $rt || ! -d $rt ]]; then
    mk_error "XDG_RUNTIME_DIR is not set or not a folder; per-user Motanka operations run inside a login session"
    return 1
  fi
  if ! exec {fd}>>"$rt/motanka.lock"; then
    mk_error "cannot open the per-user lock $rt/motanka.lock"
    return 1
  fi
  if ! flock -n "$fd"; then
    exec {fd}>&-
    mk_error "another per-user Motanka operation of $(id -un) is running (lock $rt/motanka.lock is held); try again when it has finished"
    return "$MK_EXIT_LOCKED"
  fi
  MK_UL_LOCK_FD=$fd
}

# --- revert -------------------------------------------------------------

# mk_userledger_revert and mk_userledger_revert_plan share one walk,
# _mk_ul_walk, so a plan takes exactly the decisions a revert takes. The
# step functions below act in apply mode; in plan mode they change nothing
# and record their effect in _MK_UL_SIM and _MK_UL_TAKEN instead (see the
# top), so later steps on the same paths see the simulated state.

# _mk_ul_say <action> <path> [detail]: one result line on stdout; a revert
# also writes it to the journal.
_mk_ul_say() {
  local IFS=$'\t'
  printf '%s\n' "$*"
  if [[ $_MK_UL_MODE == apply ]]; then
    mk_log info "user ledger revert: $*"
  fi
}

# _mk_ul_sim_get <path>: in a plan, prints the simulated entry of a path a
# step touched. A path below one a step touched is absent: that path is no
# folder any more. Returns 1 if no step touched the path or its ancestors.
_mk_ul_sim_get() {
  local p=$1
  if [[ -n ${_MK_UL_SIM[$p]+x} ]]; then
    printf '%s\n' "${_MK_UL_SIM[$p]}"
    return 0
  fi
  while [[ $p == */* ]]; do
    p=${p%/*}
    if [[ -n ${_MK_UL_SIM[$p]+x} ]]; then
      printf -- '-\t\n'
      return 0
    fi
  done
  return 1
}

# _mk_ul_sim_set <path> <state> [content-file]
_mk_ul_sim_set() {
  _MK_UL_SIM[$1]="$2"$'\t'"${3:-}"
}

# _mk_ul_cur <path>: the state of a home-relative path; in a plan, after
# the steps simulated so far.
_mk_ul_cur() {
  local e
  if [[ $_MK_UL_MODE == plan ]] && e=$(_mk_ul_sim_get "$1"); then
    printf '%s\n' "${e%%$'\t'*}"
  else
    _mk_ul_state "$_MK_UL_HOME/$1"
  fi
}

# _mk_ul_sim_dir <path>: 0 if the home-relative path is a folder after the
# steps simulated so far.
_mk_ul_sim_dir() {
  local abs=$_MK_UL_HOME/$1
  [[ -d $abs && ! -L $abs ]] || return 1
  [[ $_MK_UL_MODE == apply ]] || ! _mk_ul_sim_get "$1" >/dev/null
}

# _mk_ul_step_delete <path>: deletes a path that is there.
_mk_ul_step_delete() {
  if [[ $_MK_UL_MODE == apply ]]; then
    rm -rf --one-file-system -- "${_MK_UL_HOME:?}/$1" || return 1
  else
    _mk_ul_sim_set "$1" -
  fi
  _mk_ul_say deleted "$1"
}

# _mk_ul_step_move_aside <path>: moves an edited path to
# ~/.local/state/motanka-removed-<date>/<path> (.1, .2 ... when taken).
_mk_ul_step_move_aside() {
  local rel=$1 root dest n=1
  root=$_MK_UL_HOME/.local/state/motanka-removed-$(date -u +%Y-%m-%d)
  dest=$root/$rel
  while [[ -e $dest || -L $dest || -n ${_MK_UL_TAKEN[$dest]+x} ]]; do
    dest=$root/$rel.$n
    n=$((n + 1))
  done
  if [[ $_MK_UL_MODE == apply ]]; then
    mkdir -p -- "${dest%/*}" || return 1
    mv -T -- "$_MK_UL_HOME/$rel" "$dest" || return 1
  else
    _MK_UL_TAKEN[$dest]=1
    _mk_ul_sim_set "$rel" -
  fi
  _mk_ul_say moved "$rel" "${dest#"$_MK_UL_HOME"/}"
}

# _mk_ul_step_restore <path> <before> <backup>: puts the earlier state
# back: deletes the path, or copies the backup over it.
_mk_ul_step_restore() {
  local rel=$1 before=$2 backup=$3 abs tmp copy cur
  abs=$_MK_UL_HOME/$rel
  if [[ $before == - ]]; then
    cur=$(_mk_ul_cur "$rel") || return 1
    if [[ $cur != - ]]; then
      _mk_ul_step_delete "$rel" || return 1
    fi
    return 0
  fi
  copy=$_MK_UL_STATEDIR/backups/$backup/$rel
  if [[ $backup == - || (! -e $copy && ! -L $copy) ]]; then
    if [[ $_MK_UL_MODE == apply ]]; then
      mk_error "backup of $rel is missing; left as it is"
    else
      mk_warn "the backup of ~/$rel is missing; restoring the home folder will stop with an error"
    fi
    return 1
  fi
  if [[ $_MK_UL_MODE == apply ]]; then
    mkdir -p -- "${abs%/*}" || return 1
    tmp=$(_mk_ul_tmp "$abs")
    rm -f -- "$tmp" || return 1
    cp -P --preserve=mode,timestamps -- "$copy" "$tmp" || return 1
    mv -fT -- "$tmp" "$abs" || return 1
  else
    _mk_ul_sim_set "$rel" "$before" "$copy"
  fi
  _mk_ul_say restored "$rel"
}

# _mk_ul_step_object <path> <before> <after> <backup>: a file or link.
_mk_ul_step_object() {
  local rel=$1 before=$2 after=$3 backup=$4 cur
  cur=$(_mk_ul_cur "$rel") || return 1
  if [[ $cur == "$after" ]]; then
    _mk_ul_step_restore "$rel" "$before" "$backup"
  elif [[ $cur == "$before" ]]; then
    return 0
  else
    if [[ $cur != - ]]; then
      _mk_ul_step_move_aside "$rel" || return 1
    fi
    _mk_ul_step_restore "$rel" "$before" "$backup"
  fi
}

# _mk_ul_step_block <path> <before> <after> <backup>: a file with a marked
# block. An edited file keeps the user's edits and loses the block.
_mk_ul_step_block() {
  local rel=$1 before=$2 after=$3 backup=$4 abs cur tmp e src sum
  abs=$_MK_UL_HOME/$rel
  cur=$(_mk_ul_cur "$rel") || return 1
  if [[ $cur == "$after" || $cur == - ]]; then
    if [[ $cur == - && $before == - ]]; then
      return 0
    fi
    _mk_ul_step_restore "$rel" "$before" "$backup"
  elif [[ $cur == "$before" ]]; then
    return 0
  elif [[ $cur =~ ^[0-9a-f]{64}$ ]]; then
    # A regular file: only those have a bare SHA-256 as their state.
    if [[ $_MK_UL_MODE == apply ]]; then
      tmp=$(_mk_ul_tmp "$abs")
      rm -f -- "$tmp" || return 1
      _mk_ul_strip_block "$abs" >"$tmp" || return 1
      chmod --reference="$abs" -- "$tmp" || return 1
      mv -fT -- "$tmp" "$abs" || return 1
    else
      src=$abs
      if e=$(_mk_ul_sim_get "$rel"); then
        src=${e#*$'\t'}
      fi
      # The simulated content is <src> without its block: cutting the block
      # again changes nothing, so <src> stays the content file.
      sum=$(_mk_ul_strip_block "$src" | sha256sum) || return 1
      _mk_ul_sim_set "$rel" "${sum:0:64}" "$src"
    fi
    _mk_ul_say block-removed "$rel"
  else
    _mk_ul_say kept "$rel"
  fi
}

# _mk_ul_step_namespaced <path>: an entry inside a Namespaced_Path is
# deleted if it is there, whatever its state (see the top).
_mk_ul_step_namespaced() {
  local cur
  cur=$(_mk_ul_cur "$1") || return 1
  if [[ $cur != - ]]; then
    _mk_ul_step_delete "$1"
  fi
}

# _mk_ul_step_dir <path/>: removes a folder Motanka created if it is empty
# and keeps it otherwise. A plan cannot know whether the folder will be
# empty then: it prints "rmdir <path/>" once for each folder there.
_mk_ul_step_dir() {
  local rel=$1 abs
  abs=$_MK_UL_HOME/${rel%/}
  if ! _mk_ul_sim_dir "${rel%/}"; then
    return 0
  fi
  if [[ $_MK_UL_MODE == plan ]]; then
    if [[ -z ${_MK_UL_TRIED[$rel]+x} ]]; then
      _MK_UL_TRIED[$rel]=1
      _mk_ul_say rmdir "$rel"
    fi
  elif rmdir -- "$abs" 2>/dev/null; then
    _mk_ul_say deleted "$rel"
  else
    _mk_ul_say kept "$rel"
  fi
  return 0
}

# _mk_ul_walk <apply|plan> <purge:0|1>: the reverse walk of the
# User_Ledger (see mk_userledger_revert and mk_userledger_revert_plan).
_mk_ul_walk() {
  local purge=$2 ledger i failed=0 d verb rel before after backup
  local -a lines=() deferred=()
  _MK_UL_MODE=$1
  _MK_UL_SIM=()
  _MK_UL_TAKEN=()
  _MK_UL_TRIED=()
  _MK_UL_HOME=$(_mk_ul_home) || return 1
  _MK_UL_STATEDIR=$_MK_UL_HOME/$MK_UL_STATE_REL
  ledger=$_MK_UL_STATEDIR/ledger
  if [[ -f $ledger ]]; then
    mapfile -t lines < <(mk_userledger_read "$ledger")
  fi
  if [[ $_MK_UL_MODE == plan ]]; then
    for d in "${MK_UL_PLAN_EXTRA[@]}"; do
      if _mk_ul_valid_line "$d"; then
        lines+=("$d")
      fi
    done
  fi
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r _ _ verb _ rel before after backup <<<"${lines[i]}"
    case $verb in
      setup-begin | setup-end)
        continue
        ;;
      unplanned)
        _mk_ul_say unplanned "$rel"
        continue
        ;;
      observed)
        _mk_ul_say observed "$rel"
        continue
        ;;
      menu-desktop)
        if ((!purge)); then
          _mk_ul_say kept "$rel"
          continue
        fi
        ;;
    esac
    if [[ $rel == */ ]]; then
      if _mk_ul_is_state_ancestor "$rel"; then
        deferred+=("${rel%/}")
      else
        _mk_ul_step_dir "$rel" || failed=1
      fi
      continue
    fi
    if [[ $_MK_UL_MODE == apply ]]; then
      rm -f -- "$(_mk_ul_tmp "$_MK_UL_HOME/$rel")" 2>/dev/null || true
    fi
    if _mk_ul_in_namespaced "$rel"; then
      _mk_ul_step_namespaced "$rel" || failed=1
    elif [[ $verb == block ]]; then
      _mk_ul_step_block "$rel" "$before" "$after" "$backup" || failed=1
    else
      _mk_ul_step_object "$rel" "$before" "$after" "$backup" || failed=1
    fi
  done
  if ((failed)); then
    if [[ $_MK_UL_MODE == apply ]]; then
      mk_error "some ledgered paths could not be restored; the User_Ledger is kept in $_MK_UL_STATEDIR"
    fi
    return 1
  fi
  if [[ $_MK_UL_MODE == plan ]]; then
    for d in "${deferred[@]}"; do
      if [[ $d != "$MK_UL_STATE_REL" ]]; then
        _mk_ul_step_dir "$d/"
      fi
    done
    return 0
  fi
  if [[ -e $_MK_UL_STATEDIR || -L $_MK_UL_STATEDIR ]]; then
    rm -rf -- "$_MK_UL_STATEDIR" || return 1
  fi
  for d in "${deferred[@]}"; do
    if [[ -d $_MK_UL_HOME/$d ]]; then
      rmdir -- "$_MK_UL_HOME/$d" 2>/dev/null || true
    fi
  done
  return 0
}

# _mk_ul_purge_opt <function> [--purge]: prints 1 for --purge, 0 without.
_mk_ul_purge_opt() {
  local fn=$1
  shift
  if (($# > 1)); then
    mk_error "$fn: unexpected argument '$2'"
    return 1
  fi
  case ${1:-} in
    --purge) printf '1\n' ;;
    "") printf '0\n' ;;
    *)
      mk_error "$fn: unknown option '$1'"
      return 1
      ;;
  esac
}

# mk_userledger_revert [--purge]: walks the User_Ledger in reverse and
# restores every ledgered path. Prints one line per action on stdout,
# fields separated by tabs:
#   restored|deleted|kept|block-removed|unplanned|observed <path>
#   moved <path> <new path>
# menu-desktop entries are kept and listed unless --purge is given (10.9);
# unplanned and observed entries are listed and left; adopted files are
# deleted when unchanged and moved aside when changed, adopted folders are
# removed when empty; entries inside a Namespaced_Path are deleted. When every entry was handled, the state folder (ledger and
# backups) is deleted, then the folders on the way to it that the ledger
# records as created, if they are empty (no line for these). Returns 1 and
# keeps the ledger if any entry failed, so the revert can be run again.
mk_userledger_revert() {
  local purge
  purge=$(_mk_ul_purge_opt mk_userledger_revert "$@") || return 1
  _mk_ul_walk apply "$purge"
}

# mk_userledger_revert_plan [--purge]: prints the lines
# "mk_userledger_revert [--purge]" would print now, in the same order and
# format, except that a folder Motanka created is printed once as
# "rmdir <path/>" (where the revert prints deleted or kept, depending on
# whether the folder is empty by then), and that the folders on the way to
# the state folder are printed as "rmdir <path/>" too. The lines in
# MK_UL_PLAN_EXTRA count as written after the ledger's last line. Changes
# nothing: no file, no ledger line, no temporary file. Returns 1, after a
# warning on stderr, when the revert would fail (a missing backup).
mk_userledger_revert_plan() {
  local purge
  purge=$(_mk_ul_purge_opt mk_userledger_revert_plan "$@") || return 1
  _mk_ul_walk plan "$purge"
}
