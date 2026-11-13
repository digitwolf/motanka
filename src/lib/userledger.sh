# shellcheck shell=bash
# shellcheck disable=SC2329 # library: its functions are called by the files that source it
# User_Ledger: ~/.local/state/motanka/ledger (design.md, Data Models).
#
# One line per home-folder change, fields separated by tabs:
#   <utc-time> <run-id> <verb> <class> <path> <before> <after> <backup-id>
#
#   verb    setup-begin, create, replace, symlink, block, menu-desktop,
#           unplanned, setup-end
#   class   namespaced, session, app, shared, or - (setup-*, unplanned)
#   path    relative to the home folder; a trailing / marks a folder that
#           Motanka created; - for setup-*
#   before  state of the path before the change, after: the state Motanka
#           wrote. A state is - (absent), the SHA-256 of a regular file's
#           content, or l:<SHA-256 of the target> for a symbolic link.
#   backup  ID of the copy of the earlier file or link under
#           ~/.local/state/motanka/backups/<backup-id>/<path>, or -
#
# Write-ahead (6.2, 6.3, 3.9): a change first creates its missing parent
# folders (each ledgered before its mkdir), then copies the existing file
# into a backup and fsyncs it, then appends and fsyncs the ledger line, and
# only then writes the new file to a temporary name next to the target
# (.<name>.motanka-tmp) and renames it over the target (6.11).
#
# mk_userledger_revert walks the ledger in reverse (10.2) and restores the
# earlier state (10.3). A path whose state is neither the "after" nor the
# "before" state was edited by the user and moves to
# ~/.local/state/motanka-removed-<date>/ first (10.4); for a marked block,
# the block is cut out of the edited file instead (10.5). Every step checks
# the current state, so a revert can be interrupted and run again.
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

# Set by the _mk_ul_stage_* functions for the commit step.
_MK_UL_ABS=""
_MK_UL_SRC=""
_MK_UL_TARGET=""

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
  local class=$1 rel=$2 home rest part prefix="" abs
  home=$(_mk_ul_home) || return 1
  [[ $rel == */* ]] || return 0
  rest=${rel%/*}
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

# --- revert -------------------------------------------------------------

# _mk_ul_report <action> <path> [detail]: one line on stdout and in the
# journal.
_mk_ul_report() {
  local IFS=$'\t'
  printf '%s\n' "$*"
  mk_log info "user ledger revert: $*"
}

# _mk_ul_move_aside <home> <path>: moves an edited path to
# ~/.local/state/motanka-removed-<date>/<path>.
_mk_ul_move_aside() {
  local home=$1 rel=$2 root dest n=1
  root=$home/.local/state/motanka-removed-$(date -u +%Y-%m-%d)
  dest=$root/$rel
  while [[ -e $dest || -L $dest ]]; do
    dest=$root/$rel.$n
    n=$((n + 1))
  done
  mkdir -p -- "${dest%/*}" || return 1
  mv -T -- "$home/$rel" "$dest" || return 1
  _mk_ul_report moved "$rel" "${dest#"$home"/}"
}

# _mk_ul_restore <home> <state> <path> <before> <backup>: puts the earlier
# state back: deletes the path, or copies the backup over it.
_mk_ul_restore() {
  local home=$1 state=$2 rel=$3 before=$4 backup=$5 abs tmp copy
  abs=$home/$rel
  if [[ $before == - ]]; then
    if [[ -e $abs || -L $abs ]]; then
      rm -f -- "$abs" || return 1
      _mk_ul_report deleted "$rel"
    fi
    return 0
  fi
  copy=$state/backups/$backup/$rel
  if [[ $backup == - || (! -e $copy && ! -L $copy) ]]; then
    mk_error "backup of $rel is missing; left as it is"
    return 1
  fi
  mkdir -p -- "${abs%/*}" || return 1
  tmp=$(_mk_ul_tmp "$abs")
  rm -f -- "$tmp" || return 1
  cp -P --preserve=mode,timestamps -- "$copy" "$tmp" || return 1
  mv -fT -- "$tmp" "$abs" || return 1
  _mk_ul_report restored "$rel"
}

# _mk_ul_revert_object <home> <state> <path> <before> <after> <backup>
_mk_ul_revert_object() {
  local home=$1 state=$2 rel=$3 before=$4 after=$5 backup=$6 cur
  cur=$(_mk_ul_state "$home/$rel") || return 1
  if [[ $cur == "$after" ]]; then
    _mk_ul_restore "$home" "$state" "$rel" "$before" "$backup"
  elif [[ $cur == "$before" ]]; then
    return 0
  else
    if [[ $cur != - ]]; then
      _mk_ul_move_aside "$home" "$rel" || return 1
    fi
    _mk_ul_restore "$home" "$state" "$rel" "$before" "$backup"
  fi
}

# _mk_ul_revert_block <home> <state> <path> <before> <after> <backup>
_mk_ul_revert_block() {
  local home=$1 state=$2 rel=$3 before=$4 after=$5 backup=$6 abs cur tmp
  abs=$home/$rel
  cur=$(_mk_ul_state "$abs") || return 1
  if [[ $cur == "$after" || $cur == - ]]; then
    if [[ $cur == - && $before == - ]]; then
      return 0
    fi
    _mk_ul_restore "$home" "$state" "$rel" "$before" "$backup"
  elif [[ $cur == "$before" ]]; then
    return 0
  elif [[ -f $abs && ! -L $abs ]]; then
    tmp=$(_mk_ul_tmp "$abs")
    rm -f -- "$tmp" || return 1
    _mk_ul_strip_block "$abs" >"$tmp" || return 1
    chmod --reference="$abs" -- "$tmp" || return 1
    mv -fT -- "$tmp" "$abs" || return 1
    _mk_ul_report block-removed "$rel"
  else
    _mk_ul_report kept "$rel"
  fi
}

# _mk_ul_revert_dir <home> <path/>: removes a folder Motanka created if it
# is empty; keeps it otherwise.
_mk_ul_revert_dir() {
  local home=$1 rel=$2 abs
  abs=$home/${rel%/}
  if [[ -d $abs && ! -L $abs ]]; then
    if rmdir -- "$abs" 2>/dev/null; then
      _mk_ul_report deleted "$rel"
    else
      _mk_ul_report kept "$rel"
    fi
  fi
  return 0
}

# mk_userledger_revert [--purge]: walks the User_Ledger in reverse and
# restores every ledgered path. Prints one line per action on stdout:
#   restored|deleted|kept|block-removed|unplanned <path>
#   moved <path> <new path>
# menu-desktop entries are kept and listed unless --purge is given (10.9);
# unplanned entries are listed and left. When every entry was handled, the
# state folder (ledger and backups) is deleted, then the folders on the way
# to it that the ledger records as created. Returns 1 and keeps the ledger
# if any entry failed, so the revert can be run again.
mk_userledger_revert() {
  local purge=0 home state ledger i failed=0 d
  local verb rel before after backup
  local -a lines=() deferred=()
  case ${1:-} in
    --purge) purge=1 ;;
    "") ;;
    *)
      mk_error "mk_userledger_revert: unknown option '$1'"
      return 1
      ;;
  esac
  home=$(_mk_ul_home) || return 1
  state=$home/$MK_UL_STATE_REL
  ledger=$state/ledger
  if [[ -f $ledger ]]; then
    mapfile -t lines < <(mk_userledger_read "$ledger")
  fi
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r _ _ verb _ rel before after backup <<<"${lines[i]}"
    case $verb in
      setup-begin | setup-end)
        continue
        ;;
      unplanned)
        _mk_ul_report unplanned "$rel"
        continue
        ;;
      menu-desktop)
        if ((!purge)); then
          _mk_ul_report kept "$rel"
          continue
        fi
        ;;
    esac
    if [[ $rel == */ ]]; then
      if _mk_ul_is_state_ancestor "$rel"; then
        deferred+=("${rel%/}")
      else
        _mk_ul_revert_dir "$home" "$rel" || failed=1
      fi
      continue
    fi
    rm -f -- "$(_mk_ul_tmp "$home/$rel")" 2>/dev/null || true
    if [[ $verb == block ]]; then
      _mk_ul_revert_block "$home" "$state" "$rel" "$before" "$after" "$backup" || failed=1
    else
      _mk_ul_revert_object "$home" "$state" "$rel" "$before" "$after" "$backup" || failed=1
    fi
  done
  if ((failed)); then
    mk_error "some ledgered paths could not be restored; the User_Ledger is kept in $state"
    return 1
  fi
  if [[ -e $state || -L $state ]]; then
    rm -rf -- "$state" || return 1
  fi
  for d in "${deferred[@]}"; do
    if [[ -d $home/$d ]]; then
      rmdir -- "$home/$d" 2>/dev/null || true
    fi
  done
  return 0
}
