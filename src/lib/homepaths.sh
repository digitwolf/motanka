# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # library: its variables and functions are used by the files that source it
# Home_Path_Class lookup in home-paths.tsv (design.md, Data Models and
# "Session-time home writes").
#
# home-paths.tsv has one "<glob> TAB <class>" line per entry; blank lines
# and lines starting with '#' are ignored. A glob is relative to the home
# folder: "*" and "?" match within one path component, "**" matches any
# number of them, every other character matches itself. The first line
# whose glob matches a path decides its class:
#   namespaced, session, app, shared or desktop.
# A folder that no glob matches takes the class of a path inside it
# ("<folder>/x"), as tools/classify-migrations and tools/fpdiff.py do.
#
# Per-user setup (src/libexec/user-setup), the session capture
# (src/lib/capture.sh) and the web-app and provisioning overrides read the
# installed copy, /opt/motanka/share/motanka/home-paths.tsv, unless
# MOTANKA_HOME_PATHS names another file (the Remover's copy in
# /run/motanka, and tests).
#
# Requires common.sh.

if [[ -n ${MK_HOMEPATHS_LOADED:-} ]]; then
  return 0
fi
MK_HOMEPATHS_LOADED=1

readonly MK_HP_DEFAULT=/opt/motanka/share/motanka/home-paths.tsv

# Anchored extended regular expressions and their classes, in file order.
MK_HP_RE=()
MK_HP_CLASS=()

# mk_hp_file: the home-paths.tsv to read.
mk_hp_file() {
  if [[ -n ${MOTANKA_HOME_PATHS:-} ]]; then
    printf '%s\n' "$MOTANKA_HOME_PATHS"
  else
    mk_path "$MK_HP_DEFAULT"
  fi
}

# _mk_hp_glob_re <glob>: sets REPLY to the glob as an anchored extended
# regular expression that bash's =~ and awk read the same way. Characters
# other than letters, digits, "_", "/" and "-" are put in a bracket
# expression, except "\" and "^", which are escaped.
_mk_hp_glob_re() {
  local g=$1 re="" c i
  for ((i = 0; i < ${#g}; i++)); do
    c=${g:i:1}
    case $c in
      '*')
        if [[ ${g:i+1:1} == '*' ]]; then
          re+='.*'
          i=$((i + 1))
        else
          re+='[^/]*'
        fi
        ;;
      '?') re+='[^/]' ;;
      [A-Za-z0-9_/-]) re+=$c ;;
      "\\") re+="\\\\" ;;
      '^') re+='\^' ;;
      *) re+="[$c]" ;;
    esac
  done
  REPLY="^$re\$"
}

# mk_hp_glob_re <glob>: prints the regular expression of a glob.
mk_hp_glob_re() {
  _mk_hp_glob_re "$1"
  printf '%s\n' "$REPLY"
}

# mk_hp_load <home-paths.tsv>: fills MK_HP_RE and MK_HP_CLASS. Returns 1
# when the file cannot be read. A line with an unknown class is skipped
# with a warning.
mk_hp_load() {
  local tsv=$1 glob class
  MK_HP_RE=()
  MK_HP_CLASS=()
  if [[ ! -r $tsv ]]; then
    return 1
  fi
  while IFS=$'\t' read -r glob class _ || [[ -n $glob ]]; do
    if [[ -z $glob || $glob == \#* ]]; then
      continue
    fi
    case $class in
      namespaced | session | app | shared | desktop) ;;
      *)
        mk_warn "ignoring '$glob' in $tsv: unknown class '${class:-}'"
        continue
        ;;
    esac
    _mk_hp_glob_re "$glob"
    MK_HP_RE+=("$REPLY")
    MK_HP_CLASS+=("$class")
  done <"$tsv"
}

# mk_hp_clear: no classes loaded; every path is of no class.
mk_hp_clear() {
  MK_HP_RE=()
  MK_HP_CLASS=()
}

# mk_hp_class <path>: prints the class of a home-relative path; returns 1
# when no glob matches.
mk_hp_class() {
  local i
  for i in "${!MK_HP_RE[@]}"; do
    if [[ $1 =~ ${MK_HP_RE[i]} ]]; then
      printf '%s\n' "${MK_HP_CLASS[i]}"
      return 0
    fi
  done
  return 1
}

# mk_hp_dir_class <path>: the class of a home-relative folder: its own,
# else the class of "<path>/x". Returns 1 when neither matches.
mk_hp_dir_class() {
  mk_hp_class "$1" || mk_hp_class "$1/x"
}

# mk_hp_table: prints "<regular expression> TAB <class>" per loaded line,
# for awk programs that classify many paths in one process.
mk_hp_table() {
  local i
  for i in "${!MK_HP_RE[@]}"; do
    printf '%s\t%s\n' "${MK_HP_RE[i]}" "${MK_HP_CLASS[i]}"
  done
}
