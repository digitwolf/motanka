# shellcheck shell=bash
# shellcheck disable=SC2329 # library: its functions are called by the files that source it
# Session capture: home-folder paths written during a Motanka session that
# per-user setup never saw (design.md, "Session-time home writes";
# requirements 6.4, 6.9, 6.10, 10.1-10.5, 12.8).
#
# mk_capture_start (the session launcher, before per-user setup and uwsm):
#   ends a capture that an earlier session left open (crash, power loss),
#   then creates ~/.local/state/motanka/capture/start, whose modification
#   time marks the start, and capture/paths, the paths that exist now in
#   the scanned roots, one "<type> TAB <path>" line each (find's %y).
# mk_capture_end [--plan] (ExecStop of motanka-session-cleanup.service and
#   the launcher at the end of the session, the next mk_capture_start, the
#   Remover's user phase before its ledger walk): compares the scanned
#   roots with capture/paths and, for every path that is not in the
#   User_Ledger yet, writes one ledger line by its Home_Path_Class
#   (home-paths.tsv, src/lib/homepaths.sh):
#     path absent at the start (new):
#       namespaced      nothing; the Remover deletes the Namespaced_Paths
#       session, app    adopt (files, links and folders)
#       desktop         observed
#       shared, none    unplanned; below a new folder recorded as unplanned
#                       only paths of another class get lines of their own.
#                       A new folder of no class of its own that holds
#                       adopted paths is adopted too (so the Remover removes
#                       it when it is empty); one that holds only observed
#                       paths is observed.
#     path present at the start (a file or link changed after the start
#     marker, by content, metadata or rename):
#       namespaced, desktop  nothing
#       other           unplanned
#   A path that existed at the start is never adopted, also when it was
#   replaced by a rename. Then capture/start and capture/paths are deleted.
#   With --plan it prints the ledger lines it would write and changes
#   nothing (no file, no ledger line, no temporary file).
#
# Scanned roots: ~/.config and ~/.local with everything below them; every
# top-level entry of the home folder; below top-level folders whose names
# start with "." (other than .config and .local) four levels deep from the
# home folder. ~/.cache, the Namespaced_Paths and
# ~/.local/state/motanka-removed-* are not walked; mount points are not
# entered. A new folder whose content the scope leaves out (a new top-level
# folder such as ~/Work, or a new folder at the fourth level) is walked
# whole at the end. Changed paths are looked for only in ~/.config,
# ~/.local and the top-level dot entries.
#
# The walk is one find(1) with -printf, one tr(1) and, at the end, one
# awk(1) pass; no process runs per path except for the hashes of adopted
# and observed files.
#
# The functions run as the user who owns the home folder (MK_HOME, or
# HOME), and the caller holds the per-user lock (mk_userledger_lock).
# Requires common.sh, userledger.sh and homepaths.sh.

if [[ -n ${MK_CAPTURE_LOADED:-} ]]; then
  return 0
fi
MK_CAPTURE_LOADED=1

readonly MK_CAP_REL=.local/state/motanka/capture

# The awk program of mk_capture_end. Inputs, in order: the class table
# ("<regex> TAB <class>"), the ledgered paths (one per line, without a
# trailing /), capture/paths, the listing at the end (sorted by path) and
# the changed paths. Output: "<verb> TAB <class> TAB <type> TAB <path>".
# shellcheck disable=SC2016 # an awk program, not shell expansions
readonly MK_CAP_AWK='
function class(p, isdir,   i) {
  for (i = 1; i <= nre; i++) if (p ~ re[i]) return cls[i]
  if (isdir) for (i = 1; i <= nre; i++) if ((p "/x") ~ re[i]) return cls[i]
  return ""
}
function path_of(line,   p) {
  p = substr(line, 3)
  sub(/^\.\//, "", p)
  return p
}
function under_unplanned(p,   n, parts, q, i) {
  n = split(p, parts, "/")
  q = ""
  for (i = 1; i < n; i++) {
    q = (i == 1) ? parts[1] : q "/" parts[i]
    if (q in unplanned_dir) return 1
  }
  return 0
}
function mark_parents(p, what,   n, parts, q, i) {
  n = split(p, parts, "/")
  q = ""
  for (i = 1; i < n; i++) {
    q = (i == 1) ? parts[1] : q "/" parts[i]
    if (what == "observed") { has_observed[q] = 1 }
    else if (!(q in has_adopted)) { has_adopted[q] = what }
  }
}
BEGIN { FS = "\t" }
FILENAME == ARGV[1] { if ($0 != "") { re[++nre] = $1; cls[nre] = $2 }; next }
FILENAME == ARGV[2] { if ($0 != "") known[$0] = 1; next }
FILENAME == ARGV[3] { if ($0 != "") existed[path_of($0)] = 1; next }
FILENAME == ARGV[4] {
  if ($0 == "") next
  t = substr($0, 1, 1); p = path_of($0)
  if (p == "" || (p in known) || (p in existed) || (p in seen)) next
  seen[p] = 1
  c = class(p, t == "d")
  if (c == "namespaced") next
  np++; new_p[np] = p; new_t[np] = t; new_c[np] = c
  if (c == "session" || c == "app") mark_parents(p, c)
  else if (c == "desktop") mark_parents(p, "observed")
  next
}
FILENAME == ARGV[5] {
  if ($0 == "") next
  t = substr($0, 1, 1); p = path_of($0)
  if (!(p in existed) || (p in known) || (p in changed)) next
  changed[p] = 1
  c = class(p, 0)
  if (c == "namespaced" || c == "desktop") next
  nc++; ch_line[nc] = "unplanned\t" (c == "" ? "-" : c) "\t" t "\t" p
}
END {
  # New paths, folders before what they hold. A new folder without a class
  # of its own that holds adopted paths is adopted too (removed when it is
  # empty), one that holds only observed paths is observed; below a new
  # folder recorded as unplanned, unplanned paths get no line of their own.
  for (i = 1; i <= np; i++) {
    p = new_p[i]; t = new_t[i]; c = new_c[i]
    if (c == "session" || c == "app") { print "adopt\t" c "\t" t "\t" p; continue }
    if (c == "desktop") { print "observed\tdesktop\t" t "\t" p; continue }
    if (t == "d" && (p in has_adopted)) { print "adopt\t" has_adopted[p] "\t" t "\t" p; continue }
    if (t == "d" && (p in has_observed)) { print "observed\tdesktop\t" t "\t" p; continue }
    if (under_unplanned(p)) continue
    if (t == "d") unplanned_dir[p] = 1
    print "unplanned\t" (c == "" ? "-" : c) "\t" t "\t" p
  }
  for (i = 1; i <= nc; i++) print ch_line[i]
}
'

# mk_capture_dir: ~/.local/state/motanka/capture of the home folder.
mk_capture_dir() {
  local home
  home=$(_mk_ul_home) || return 1
  printf '%s/%s\n' "$home" "$MK_CAP_REL"
}

# mk_capture_pending: 0 if a capture was started and not ended.
mk_capture_pending() {
  local dir
  dir=$(mk_capture_dir 2>/dev/null) || return 1
  [[ -f $dir/start ]]
}

# mk_capture_started: prints the UTC time the pending capture started.
mk_capture_started() {
  local dir t=""
  dir=$(mk_capture_dir) || return 1
  [[ -f $dir/start ]] || return 1
  IFS=$'\t' read -r t _ <"$dir/start" || true
  printf '%s\n' "${t:-unknown}"
}

# _mk_cap_find <home> <list|changed> [marker]: prints "<type> TAB <path>"
# lines (find's %y and the home-relative path) for the scanned roots (see
# the top); "changed" prints only regular files and links changed after
# the marker's modification time. Newlines in names become \x01, so a
# name with one is a single line that mk_field_ok rejects. Folders that
# cannot be read are left out.
_mk_cap_find() {
  local home=$1 mode=$2 marker=${3:-} root
  local -a prune=(-path ./.cache) out=() top=()
  for root in "${MK_UL_NAMESPACED[@]}"; do
    if [[ $root != .cache/* ]]; then
      prune+=(-o -path "./$root")
    fi
  done
  prune+=(-o -path './.local/state/motanka-removed-*')
  if [[ $mode == changed ]]; then
    out=(\( -type f -o -type l \) \( -newer "$marker" -o -cnewer "$marker" \) -printf '%y\t%P\0')
    top=(-false)
  else
    out=(-printf '%y\t%P\0')
    top=("${out[@]}")
  fi
  (
    cd -- "$home" || exit 1
    find . -xdev -mindepth 1 \
      \( "${prune[@]}" \) -prune -o \
      \( -path './[!.]*' -prune \( "${top[@]}" -o -true \) \) -o \
      \( -path './*/*/*/*' ! -path './.config/*' ! -path './.local/*' -prune \( "${out[@]}" -o -true \) \) -o \
      \( "${out[@]}" \) 2>/dev/null || true
  ) | tr '\n\0' '\001\n'
}

# _mk_cap_below <home> <path>: every entry below a new folder, as
# "<type> TAB ./<path>/<entry>" lines.
_mk_cap_below() {
  (
    cd -- "$1" || exit 1
    find "./$2" -xdev -mindepth 1 -printf '%y\t%p\0' 2>/dev/null || true
  ) | tr '\n\0' '\001\n'
}

# mk_capture_start: see the top. Returns 1 when the capture files cannot
# be written; the session goes on without a capture then.
mk_capture_start() {
  local home dir n
  home=$(_mk_ul_home) || return 1
  if mk_capture_pending; then
    mk_log notice "the session capture started at $(mk_capture_started) was not ended (the session did not end cleanly); ending it first"
    # shellcheck disable=SC2119 # ends the capture for real, without --plan
    mk_capture_end || return 1
  fi
  mk_userledger_init || return 1
  dir=$home/$MK_CAP_REL
  if ! mkdir -p -- "$dir" || ! chmod 0700 -- "$dir"; then
    mk_error "cannot create $dir"
    return 1
  fi
  rm -f -- "$dir/start.tmp" "$dir/paths.tmp"
  mk_run_id >/dev/null
  # The marker is written before the walk, so a change during the walk is
  # newer than the marker.
  if ! printf '%s\t%s\n' "$(mk_utc_now)" "$MK_RUN_ID" >"$dir/start.tmp" ||
    ! _mk_cap_find "$home" list >"$dir/paths.tmp" ||
    ! mk_fsync "$dir/start.tmp" "$dir/paths.tmp" ||
    ! mv -fT -- "$dir/paths.tmp" "$dir/paths" ||
    ! mv -fT -- "$dir/start.tmp" "$dir/start" ||
    ! mk_fsync "$dir"; then
    rm -f -- "$dir/start.tmp" "$dir/paths.tmp" "$dir/start"
    mk_error "cannot write the session capture in $dir"
    return 1
  fi
  n=$(wc -l <"$dir/paths")
  mk_log info "session capture started: $n paths in the scanned roots"
}

# _mk_cap_known: the User_Ledger's paths, without a trailing /.
_mk_cap_known() {
  mk_userledger_read 2>/dev/null |
    awk -F'\t' '$3 != "setup-begin" && $3 != "setup-end" && $5 != "-" { p = $5; sub(/\/$/, "", p); print p }'
}

# _mk_cap_actions <home> <dir>: the awk pass of mk_capture_end, printing
# "<verb> TAB <class> TAB <type> TAB <path>" lines.
_mk_cap_actions() {
  local home=$1 dir=$2 end_list changed known table line p
  local -a below=()
  end_list=$(_mk_cap_find "$home" list)
  # New folders whose content the scope of the walk leaves out.
  while IFS= read -r p; do
    if [[ -n $p ]]; then
      below+=("$(_mk_cap_below "$home" "$p")")
    fi
  done < <(
    printf '%s\n' "$end_list" | awk -F'\t' '
      FILENAME == ARGV[1] { existed[substr($0, 3)] = 1; next }
      $1 == "d" {
        p = substr($0, 3)
        if (p in existed) next
        n = split(p, parts, "/")
        if ((n == 1 && substr(p, 1, 1) != ".") || (n == 4 && parts[1] != ".config" && parts[1] != ".local")) print p
      }' "$dir/paths" -
  )
  changed=$(_mk_cap_find "$home" changed "$dir/start")
  known=$(_mk_cap_known)
  table=$(mk_hp_table)
  # The listing at the end, sorted by path so that a folder comes before
  # what it holds; names with a tab are left out (no ledger field holds
  # one).
  awk "$MK_CAP_AWK" \
    <(printf '%s\n' "$table") \
    <(printf '%s\n' "$known") \
    "$dir/paths" \
    <(
      {
        printf '%s\n' "$end_list"
        for line in "${below[@]}"; do
          printf '%s\n' "$line"
        done
      } | awk -F'\t' 'NF == 2 { p = $2; sub(/^\.\//, "", p); print p "\t" $0 }' |
        LC_ALL=C sort -t $'\t' -k1,1 -u | cut -f2-
    ) \
    <(printf '%s\n' "$changed")
}

# shellcheck disable=SC2120 # --plan is optional; most callers pass nothing
# mk_capture_end [--plan]: see the top. Returns 1 when the User_Ledger
# cannot be written; the capture stays pending then, and the next
# mk_capture_start or the Remover ends it.
mk_capture_end() {
  local plan=0 home dir tsv now verb class type rel state line n=0 bad=0 out actions
  local -a lines=()
  case ${1:-} in
    --plan) plan=1 ;;
    "") ;;
    *)
      mk_error "mk_capture_end: unknown option '$1'"
      return 1
      ;;
  esac
  home=$(_mk_ul_home) || return 1
  dir=$home/$MK_CAP_REL
  if [[ ! -f $dir/start ]]; then
    return 0
  fi
  if [[ ! -f $dir/paths ]]; then
    mk_warn "the session capture in $dir has no listing of the paths at its start; nothing is adopted from it"
    if ((!plan)); then
      rm -f -- "$dir/start"
    fi
    return 0
  fi
  tsv=$(mk_hp_file)
  if ! mk_hp_load "$tsv"; then
    mk_warn "cannot read $tsv; every path the Motanka session created is recorded as unplanned"
    mk_hp_clear
  fi
  if ! actions=$(_mk_cap_actions "$home" "$dir"); then
    mk_error "cannot compare the home folder with the session capture in $dir; it stays pending"
    return 1
  fi
  now=$(mk_utc_now)
  mk_run_id >/dev/null
  while IFS=$'\t' read -r verb class type rel; do
    if [[ -z $verb ]]; then
      continue
    fi
    if ! mk_field_ok "$rel" || ! _mk_ul_path_syntax_ok "$rel" || [[ $rel == */ ]] || _mk_ul_in_state "$rel"; then
      bad=$((bad + 1))
      continue
    fi
    line=""
    case $verb in
      adopt)
        line=$(mk_userledger_adopt_line "$class" "$rel") || line=""
        ;;
      observed)
        if [[ $type == d ]]; then
          line=$(printf 'observed\tdesktop\t%s/\t-\t-\t-' "$rel")
        else
          state=$(_mk_ul_state "$home/$rel") || state=-
          case $state in
            dir | other) state=- ;;
          esac
          line=$(printf 'observed\tdesktop\t%s\t-\t%s\t-' "$rel" "$state")
        fi
        ;;
      unplanned)
        line=$(printf 'unplanned\t-\t%s\t-\t-\t-' "$rel")
        ;;
    esac
    if [[ -n $line ]]; then
      lines+=("$now"$'\t'"$MK_RUN_ID"$'\t'"$line")
      n=$((n + 1))
    fi
  done <<<"$actions"
  if ((bad > 0)); then
    mk_warn "the session capture skipped $bad path(s) whose names have control characters"
  fi
  if ((plan)); then
    if ((n > 0)); then
      printf '%s\n' "${lines[@]}"
    fi
    return 0
  fi
  if ((n > 0)); then
    out=$dir/end.tmp
    rm -f -- "$out"
    if ! (umask 077 && printf '%s\n' "${lines[@]}" >"$out") || ! mk_userledger_append_lines "$out"; then
      rm -f -- "$out"
      mk_error "cannot write the session capture into the User_Ledger; it stays pending"
      return 1
    fi
    rm -f -- "$out"
  fi
  if ! rm -f -- "$dir/start" "$dir/paths" || ! mk_fsync "$dir"; then
    mk_error "cannot delete the session capture in $dir"
    return 1
  fi
  mk_log info "session capture ended: $n User_Ledger line(s) (adopted, observed or unplanned paths)"
}
