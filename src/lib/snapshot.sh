# shellcheck shell=bash
# shellcheck disable=SC2329 # library: its functions are called by the files that source it
# Snapshots of the Updater, the Config_Archive (design.md, "Updater,
# snapshots and rollback"; requirements 9.9, 9.10, 9.12), and the package
# steps that the Updater and rollback share.
#
# One snapshot per update, /var/lib/motanka/snapshots/<id>/ (root, 0700),
# where <id> is the update's run ID (20261113T091502Z-a1b2c3):
#   manifest.tsv   every installed Motanka_Package, one line each:
#                    <package> TAB <version> TAB <architecture> TAB debs/<file>
#   debs/<file>    the .deb of that version: copied from apt's cache
#                  (/var/cache/apt/archives), else fetched with
#                  "apt-get download <package>=<version>", else rebuilt with
#                  dpkg-repack when that is installed. Its Package and
#                  Version fields are checked.
#   users.tsv      one line per user (uid 1000-59999) with a User_Ledger:
#                    <uid> TAB <gid> TAB <name> TAB <archive> TAB <paths-file>
#   user-<uid>.tar.zst   that user's files, read as the user with tar
#                  (user-<uid>.tar.gz where zstd is not installed)
#   user-<uid>.paths     what the archive holds, one line each:
#                    root TAB <Namespaced_Path> TAB present|absent
#                    file TAB <ledgered path>
#                  The roots are .config/dconf/motanka, .config/omarchy,
#                  .local/share/omarchy and .local/state/omarchy. The files
#                  are the paths outside them that the User_Ledger records
#                  Motanka writing (create, replace, symlink, block,
#                  menu-desktop) and that exist. The User_Ledger's own folder
#                  (~/.local/state/motanka) and the caches are not archived:
#                  a rollback keeps the ledger as it is, so every file
#                  Motanka wrote stays known to the Remover.
#   snapper        <config> TAB <pre-number>, written by the Updater when it
#                  made a snapper pre snapshot
# A snapshot is built as <id>.partial and renamed to <id> after
# manifest.tsv is written and every file is fsynced, so an interrupted
# snapshot is never used; the next snapshot deletes it. The newest 3
# complete snapshots are kept (mk_snapshot_prune).
#
# mk_snapshot_restore_user puts a user's archive back: each root is deleted
# and, when it was present, restored whole; each file is restored. Ledgered
# files that did not exist at the time of the snapshot are left as they are.
#
# Users' files are read and written as that user (setpriv), never as root.
# Requires common.sh, sysledger.sh, aptsim.sh and userledger.sh. Callers
# hold the system lock; no command started here inherits its descriptor.
# Test hook: MOTANKA_ROOT (common.sh) for every system path; users then come
# from $MOTANKA_ROOT/etc/passwd and their home folders are inside it.
# dpkg-query, dpkg-deb, apt-get, apt-mark, dpkg-repack, setpriv, snapper,
# tar, zstd and gzip are found through PATH.

if [[ -n ${MK_SNAPSHOT_LOADED:-} ]]; then
  return 0
fi
MK_SNAPSHOT_LOADED=1

readonly MK_SNAP_DIR=/var/lib/motanka/snapshots
readonly MK_SNAP_CACHE=/var/cache/apt/archives
readonly MK_SNAP_KEEP=3
readonly MK_SNAP_ID_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$'
readonly MK_SNAP_USER_PATH=/usr/local/bin:/usr/bin:/bin
readonly -a MK_SNAP_ROOTS=(.config/dconf/motanka .config/omarchy .local/share/omarchy .local/state/omarchy)

# --- helpers --------------------------------------------------------------

# mk_snapshot_nolock <command...>: runs the command without the descriptor
# of the system lock, so nothing it leaves running keeps the lock.
mk_snapshot_nolock() {
  if [[ -n ${MK_LOCK_FD:-} ]]; then
    "$@" {MK_LOCK_FD}>&-
  else
    "$@"
  fi
}

# mk_snapshot_root: the snapshot folder.
mk_snapshot_root() {
  mk_path "$MK_SNAP_DIR"
}

# mk_snapshot_path <id>: the folder of one snapshot.
mk_snapshot_path() {
  printf '%s/%s\n' "$(mk_snapshot_root)" "$1"
}

# mk_snapshot_list: IDs of the complete snapshots, oldest first.
mk_snapshot_list() {
  local root d id
  local -a ids=()
  root=$(mk_snapshot_root)
  if [[ ! -d $root ]]; then
    return 0
  fi
  for d in "$root"/*; do
    id=${d##*/}
    if [[ -d $d && ! -L $d && $id =~ $MK_SNAP_ID_RE && -f $d/manifest.tsv ]]; then
      ids+=("$id")
    fi
  done
  if ((${#ids[@]} > 0)); then
    printf '%s\n' "${ids[@]}" | LC_ALL=C sort
  fi
}

# mk_snapshot_latest: prints the ID of the newest complete snapshot, or
# returns 1 when there is none.
mk_snapshot_latest() {
  local last
  last=$(mk_snapshot_list | tail -n 1)
  [[ -n $last ]] || return 1
  printf '%s\n' "$last"
}

# --- users ----------------------------------------------------------------

_mk_snap_passwd() {
  if [[ -n ${MOTANKA_ROOT:-} ]]; then
    cat -- "$MOTANKA_ROOT/etc/passwd" 2>/dev/null || true
  else
    getent passwd 2>/dev/null || true
  fi
}

# mk_snapshot_lookup_user <name-or-uid>: prints
# <uid> TAB <gid> TAB <name> TAB <home>, or returns 1. The home folder is
# inside MOTANKA_ROOT in tests.
mk_snapshot_lookup_user() {
  local entry name uid gid home
  entry=$(_mk_snap_passwd | awk -F: -v u="$1" '($1 == u || $3 == u) && NF >= 7 { print $1 ":" $3 ":" $4 ":" $6; exit }')
  [[ -n $entry ]] || return 1
  IFS=: read -r name uid gid home <<<"$entry"
  if [[ ! $uid =~ ^[0-9]+$ || ! $gid =~ ^[0-9]+$ || $home != /* ]] || ! mk_field_ok "$name"; then
    return 1
  fi
  home=$(mk_path "$home")
  printf '%s\t%s\t%s\t%s\n' "$uid" "$gid" "$name" "${home%/}"
}

# mk_snapshot_users: the same line for every user with uid 1000-59999
# whose home folder has a User_Ledger.
mk_snapshot_users() {
  local name uid gid home h
  local -A seen=()
  while IFS=: read -r name _ uid gid _ home _; do
    if [[ ! $uid =~ ^[0-9]+$ || ! $gid =~ ^[0-9]+$ ]] || ((uid < 1000 || uid >= 60000)); then
      continue
    fi
    if [[ $home != /?* || -n ${seen[$uid]:-} ]] || ! mk_field_ok "$name"; then
      continue
    fi
    seen[$uid]=1
    h=$(mk_path "$home")
    h=${h%/}
    if [[ -f $h/.local/state/motanka/ledger && ! -L $h/.local/state/motanka/ledger ]]; then
      printf '%s\t%s\t%s\t%s\n' "$uid" "$gid" "$name" "$h"
    fi
  done < <(_mk_snap_passwd)
}

# mk_snapshot_as_user <uid> <gid> <home> <command...>: runs the command as
# the user, in /, with only HOME, USER, LOGNAME, PATH and LANG set (with
# MOTANKA_ROOT set, the caller's PATH and MOTANKA_ROOT are kept); through
# setpriv when this process is root, directly otherwise. Extra variables
# are given as "env VAR=value" in front of the command.
mk_snapshot_as_user() {
  local uid=$1 gid=$2 home=$3 name
  shift 3
  name=$(_mk_snap_passwd | awk -F: -v u="$uid" '$3 == u { print $1; exit }')
  local -a envs=("HOME=$home" "USER=$name" "LOGNAME=$name" "PATH=$MK_SNAP_USER_PATH" "LANG=C.UTF-8")
  if [[ -n ${MOTANKA_ROOT:-} ]]; then
    envs+=("PATH=$PATH" "MOTANKA_ROOT=$MOTANKA_ROOT")
  fi
  if [[ $(id -u) == 0 ]]; then
    (cd / && mk_snapshot_nolock setpriv --reuid="$uid" --regid="$gid" --init-groups -- \
      env -i "${envs[@]}" "$@")
  else
    (cd / && mk_snapshot_nolock env -i "${envs[@]}" "$@")
  fi
}

# --- packages ---------------------------------------------------------------

# mk_snapshot_motanka_packages: <package> TAB <version> TAB <architecture>
# of every installed Motanka_Package, sorted.
mk_snapshot_motanka_packages() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${Package}\t${db:Status-Status}\t${Version}\t${Architecture}\n' 2>/dev/null |
    awk -F'\t' '{ sub(/:.*/, "", $1) }
      ($1 == "motanka" || $1 ~ /^motanka-[a-z0-9][a-z0-9+.-]*$/) && $2 == "installed" && $3 != "" && $4 != "" {
        print $1 "\t" $3 "\t" $4
      }' | LC_ALL=C sort -u
}

# _mk_snap_deb_is <file> <package> <version>
_mk_snap_deb_is() {
  [[ $(dpkg-deb --field "$1" Package 2>/dev/null) == "$2" &&
    $(dpkg-deb --field "$1" Version 2>/dev/null) == "$3" ]]
}

# _mk_snap_store_deb <debs-folder> <package> <version> <architecture>:
# stores the .deb of that version and prints its file name.
_mk_snap_store_deb() {
  local debs=$1 name=$2 ver=$3 arch=$4 file cache f
  file=${name}_${ver//:/%3a}_${arch}.deb
  cache=$(mk_path "$MK_SNAP_CACHE")/$file
  if [[ -f $cache && ! -L $cache ]] && _mk_snap_deb_is "$cache" "$name" "$ver"; then
    cp -- "$cache" "$debs/$file" || return 1
    mk_log info "snapshot: $name $ver from apt's cache"
    printf '%s\n' "$file"
    return 0
  fi
  rm -f -- "$debs/$file"
  if (cd -- "$debs" && LC_ALL=C mk_snapshot_nolock apt-get -q download "$name=$ver") >&2 &&
    [[ -f $debs/$file ]] && _mk_snap_deb_is "$debs/$file" "$name" "$ver"; then
    mk_log info "snapshot: $name $ver downloaded with apt-get download"
    printf '%s\n' "$file"
    return 0
  fi
  rm -f -- "$debs/$file"
  if command -v dpkg-repack >/dev/null 2>&1 && (cd -- "$debs" && mk_snapshot_nolock dpkg-repack "$name") >&2; then
    for f in "$debs/${name}"_*.deb; do
      if [[ -f $f ]] && _mk_snap_deb_is "$f" "$name" "$ver"; then
        if [[ $f != "$debs/$file" ]]; then
          mv -f -- "$f" "$debs/$file" || return 1
        fi
        mk_log info "snapshot: $name $ver rebuilt with dpkg-repack"
        printf '%s\n' "$file"
        return 0
      fi
    done
  fi
  mk_error "snapshot: cannot store $name $ver: it is not in apt's cache, apt-get download cannot fetch it, and dpkg-repack is not installed"
  return 1
}

# --- user archives ----------------------------------------------------------

# _mk_snap_in_roots <path>: 0 if the path is a root or below one.
_mk_snap_in_roots() {
  local r
  for r in "${MK_SNAP_ROOTS[@]}"; do
    if [[ $1 == "$r" || $1 == "$r"/* ]]; then
      return 0
    fi
  done
  return 1
}

# _mk_snap_user_entries <home>: the lines of user-<uid>.paths.
_mk_snap_user_entries() {
  local home=$1 r p ledger=$1/.local/state/motanka/ledger
  if [[ -L $ledger || ! -f $ledger ]]; then
    ledger=/dev/null
  fi
  for r in "${MK_SNAP_ROOTS[@]}"; do
    if [[ -e $home/$r || -L $home/$r ]]; then
      printf 'root\t%s\tpresent\n' "$r"
    else
      printf 'root\t%s\tabsent\n' "$r"
    fi
  done
  while IFS= read -r p; do
    if [[ -z $p ]] || _mk_snap_in_roots "$p"; then
      continue
    fi
    if [[ $p == .local/state/motanka || $p == .local/state/motanka/* || $p == .cache/* ]]; then
      continue
    fi
    if [[ -e $home/$p || -L $home/$p ]]; then
      printf 'file\t%s\n' "$p"
    fi
  done < <(_mk_snap_ledgered_paths "$ledger")
}

# _mk_snap_ledgered_paths <ledger>: the files and links the User_Ledger
# records Motanka writing, sorted, without duplicates.
_mk_snap_ledgered_paths() {
  mk_userledger_read "$1" 2>/dev/null |
    awk -F'\t' '$3 ~ /^(create|replace|symlink|block|menu-desktop)$/ && $5 !~ /\/$/ { print $5 }' |
    LC_ALL=C sort -u
}

# _mk_snap_archive_user <snapshot-folder> <uid> <gid> <name> <home>: writes
# user-<uid>.paths and the archive and appends the users.tsv line.
_mk_snap_archive_user() {
  local dir=$1 uid=$2 gid=$3 name=$4 home=$5 kind p state archive rc=0
  local paths=$dir/user-$uid.paths list=$dir/user-$uid.list tarf=$dir/user-$uid.tar
  if ! _mk_snap_user_entries "$home" >"$paths"; then
    mk_error "snapshot: cannot list the ledgered files of $name"
    return 1
  fi
  : >"$list"
  while IFS=$'\t' read -r kind p state; do
    if [[ $kind == file || ($kind == root && $state == present) ]]; then
      printf '%s\0' "$p" >>"$list"
    fi
  done <"$paths"
  mk_snapshot_as_user "$uid" "$gid" "$home" tar --null -C "$home" -T - -cf - <"$list" >"$tarf" || rc=$?
  rm -f -- "$list"
  if ((rc > 1)); then
    rm -f -- "$tarf"
    mk_error "snapshot: tar could not read the files of $name (exit $rc)"
    return 1
  fi
  if ((rc == 1)); then
    mk_warn "snapshot: some files of $name changed while they were archived"
  fi
  if command -v zstd >/dev/null 2>&1; then
    archive=user-$uid.tar.zst
    if ! zstd -q -f --rm -o "$dir/$archive" -- "$tarf"; then
      rm -f -- "$tarf" "$dir/$archive"
      mk_error "snapshot: zstd could not compress the archive of $name"
      return 1
    fi
  else
    archive=user-$uid.tar.gz
    if ! gzip -n -f -- "$tarf"; then
      rm -f -- "$tarf" "$dir/$archive"
      mk_error "snapshot: gzip could not compress the archive of $name"
      return 1
    fi
  fi
  chmod 0600 -- "$dir/$archive" "$paths" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$uid" "$gid" "$name" "$archive" "user-$uid.paths" >>"$dir/users.tsv"
  mk_log info "snapshot: archived the ledgered files of $name ($(grep -c . "$paths") entries)"
}

# --- create, prune, read ------------------------------------------------------

# mk_snapshot_create <id>: takes a snapshot (see the top). Returns 1, after
# deleting what it wrote, when any part fails.
mk_snapshot_create() {
  local id=$1 root part dir line name ver arch file uid gid uname home old n=0 m=0
  local -a pkgs=() users=() files=()
  if [[ ! $id =~ $MK_SNAP_ID_RE ]]; then
    mk_error "invalid snapshot ID '$id'"
    return 1
  fi
  root=$(mk_snapshot_root)
  if ! (umask 077 && mkdir -p -- "$root") || ! chmod 0700 -- "$root"; then
    mk_error "cannot create $root"
    return 1
  fi
  for old in "$root"/*.partial; do
    if [[ -d $old && ! -L $old ]]; then
      rm -rf -- "$old"
    fi
  done
  part=$root/$id.partial
  dir=$root/$id
  if [[ -e $dir || -L $dir ]]; then
    mk_error "the snapshot $id exists already"
    return 1
  fi
  if ! mkdir -m 0700 -- "$part" "$part/debs"; then
    mk_error "cannot create $part"
    return 1
  fi
  mapfile -t pkgs < <(mk_snapshot_motanka_packages)
  if ((${#pkgs[@]} == 0)); then
    rm -rf -- "$part"
    mk_error "no Motanka package is installed; there is nothing to snapshot"
    return 1
  fi
  : >"$part/manifest.tmp"
  for line in "${pkgs[@]}"; do
    IFS=$'\t' read -r name ver arch <<<"$line"
    if ! file=$(_mk_snap_store_deb "$part/debs" "$name" "$ver" "$arch"); then
      rm -rf -- "$part"
      return 1
    fi
    printf '%s\t%s\t%s\tdebs/%s\n' "$name" "$ver" "$arch" "$file" >>"$part/manifest.tmp"
    n=$((n + 1))
  done
  : >"$part/users.tsv"
  mapfile -t users < <(mk_snapshot_users)
  for line in "${users[@]}"; do
    IFS=$'\t' read -r uid gid uname home <<<"$line"
    if ! _mk_snap_archive_user "$part" "$uid" "$gid" "$uname" "$home"; then
      rm -rf -- "$part"
      return 1
    fi
    m=$((m + 1))
  done
  mv -f -- "$part/manifest.tmp" "$part/manifest.tsv"
  mapfile -t files < <(find "$part" -type f)
  if ! chmod 0600 -- "${files[@]}" || ! mk_fsync "${files[@]}" "$part/debs" "$part" ||
    ! mv -T -- "$part" "$dir" || ! mk_fsync "$root"; then
    rm -rf -- "$part"
    mk_error "cannot complete the snapshot $id in $root"
    return 1
  fi
  mk_log info "snapshot $id: $n Motanka package(s), the files of $m user(s)"
  mk_info "took the snapshot $id: $n Motanka package(s) and the ledgered files of $m user(s)"
  mk_snapshot_prune
}

# mk_snapshot_prune [keep]: deletes all but the newest <keep> (3) complete
# snapshots.
mk_snapshot_prune() {
  local keep=${1:-$MK_SNAP_KEEP} root i
  local -a ids=()
  mapfile -t ids < <(mk_snapshot_list)
  root=$(mk_snapshot_root)
  for ((i = 0; i < ${#ids[@]} - keep; i++)); do
    rm -rf -- "${root:?}/${ids[i]}" || return 1
    mk_log info "deleted the old snapshot ${ids[i]}"
  done
}

# mk_snapshot_manifest <id>: the valid lines of the snapshot's manifest.
mk_snapshot_manifest() {
  local f
  f=$(mk_snapshot_path "$1")/manifest.tsv
  [[ -f $f ]] || return 1
  awk -F'\t' 'NF == 4 && ($1 == "motanka" || $1 ~ /^motanka-[a-z0-9][a-z0-9+.-]*$/) &&
    $2 ~ /^[0-9][A-Za-z0-9.+~:-]*$/ && $4 ~ /^debs\/[A-Za-z0-9._+~%-]+\.deb$/' "$f"
}

# mk_snapshot_has_user <id> <uid>: 0 if the snapshot holds an archive of
# the user.
mk_snapshot_has_user() {
  local f
  f=$(mk_snapshot_path "$1")/users.tsv
  [[ -f $f ]] && awk -F'\t' -v u="$2" '$1 == u { found = 1 } END { exit !found }' "$f"
}

# mk_snapshot_restore_user <id> <uid>: restores the user's archive (see the
# top). Returns 0 when restored, 2 when the snapshot holds no archive of
# the user, 1 on failure.
mk_snapshot_restore_user() {
  local id=$1 want=$2 dir line uid gid name archive paths entry home kind p state r ok
  local -a dec=() st=()
  dir=$(mk_snapshot_path "$id")
  line=$(awk -F'\t' -v u="$want" '$1 == u { print; exit }' "$dir/users.tsv" 2>/dev/null) || line=""
  if [[ -z $line ]]; then
    return 2
  fi
  IFS=$'\t' read -r uid _ _ archive paths <<<"$line"
  if [[ ! $archive =~ ^user-[0-9]+\.tar\.(zst|gz)$ || ! $paths =~ ^user-[0-9]+\.paths$ ||
    ! -f $dir/$archive || ! -f $dir/$paths ]]; then
    mk_error "the snapshot $id has a damaged entry for uid $want"
    return 1
  fi
  if ! entry=$(mk_snapshot_lookup_user "$uid"); then
    mk_error "the user with uid $uid no longer exists; the snapshot $id keeps their files"
    return 1
  fi
  IFS=$'\t' read -r _ gid name home <<<"$entry"
  if [[ ! -d $home ]]; then
    mk_error "the home folder $home of $name does not exist"
    return 1
  fi
  case $archive in
    *.zst) dec=(zstd -q -d -c --) ;;
    *) dec=(gzip -d -c --) ;;
  esac
  if ! command -v "${dec[0]}" >/dev/null 2>&1; then
    mk_error "${dec[0]} is needed to read $dir/$archive"
    return 1
  fi
  while IFS=$'\t' read -r kind p state; do
    if [[ $kind != root ]]; then
      continue
    fi
    ok=0
    for r in "${MK_SNAP_ROOTS[@]}"; do
      if [[ $p == "$r" ]]; then
        ok=1
      fi
    done
    if ((!ok)) || [[ $state != present && $state != absent ]]; then
      mk_error "the snapshot $id names an unexpected folder '$p' for $name"
      return 1
    fi
    if [[ -e $home/$p || -L $home/$p ]]; then
      if ! mk_snapshot_as_user "$uid" "$gid" "$home" rm -rf -- "$home/$p"; then
        mk_error "cannot replace ~/$p of $name"
        return 1
      fi
    fi
  done <"$dir/$paths"
  if "${dec[@]}" "$dir/$archive" | mk_snapshot_as_user "$uid" "$gid" "$home" tar -C "$home" --overwrite -xpf -; then
    st=("${PIPESTATUS[@]}")
  else
    st=("${PIPESTATUS[@]}")
  fi
  if [[ ${st[0]:-1} != 0 || ${st[1]:-1} != 0 ]]; then
    mk_error "cannot restore the files of $name from the snapshot $id (${dec[0]} exit ${st[0]:-?}, tar exit ${st[1]:-?})"
    return 1
  fi
  mk_log info "restored the ledgered files of $name from the snapshot $id"
}

# --- snapper ----------------------------------------------------------------

# mk_snapshot_snapper_config: prints the snapper config whose subvolume is
# /, or returns 1 (no snapper, or no config for /).
mk_snapshot_snapper_config() {
  local out cfg=""
  if ! command -v snapper >/dev/null 2>&1; then
    return 1
  fi
  if out=$(LC_ALL=C mk_snapshot_nolock snapper --csvout --no-headers list-configs --columns config,subvolume 2>/dev/null); then
    cfg=$(awk -F, '$2 == "/" { print $1; exit }' <<<"$out")
  fi
  if [[ -z $cfg ]] && out=$(LC_ALL=C mk_snapshot_nolock snapper list-configs 2>/dev/null); then
    cfg=$(awk -F'|' 'NF >= 2 {
        c = $1; s = $2
        gsub(/^[ \t]+|[ \t]+$/, "", c); gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s == "/" && c != "Config") { print c; exit }
      }' <<<"$out")
  fi
  [[ $cfg =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s\n' "$cfg"
}

# mk_snapshot_snapper_pre <config> <description>: creates a pre snapshot
# and prints its number.
mk_snapshot_snapper_pre() {
  local num
  num=$(LC_ALL=C mk_snapshot_nolock snapper -c "$1" create --type pre --print-number \
    --cleanup-algorithm number --description "$2" 2>/dev/null) || return 1
  num=${num//[[:space:]]/}
  [[ $num =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$num"
}

# mk_snapshot_snapper_post <config> <pre-number> <description>: creates the
# matching post snapshot.
mk_snapshot_snapper_post() {
  LC_ALL=C mk_snapshot_nolock snapper -c "$1" create --type post --pre-number "$2" \
    --cleanup-algorithm number --description "$3" >/dev/null 2>&1
}

# --- package steps of the Updater and rollback --------------------------------

# mk_snapshot_apt <apt-get arguments...>: a real apt-get run, without
# questions (conffiles keep their local version), with its output on
# stderr.
mk_snapshot_apt() {
  mk_log info "apt-get $*"
  DEBIAN_FRONTEND=noninteractive mk_snapshot_nolock apt-get -y -q \
    -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@" </dev/null >&2
}

# mk_snapshot_auto_packages <package...>: the arguments that apt-mark
# shows as automatically installed.
mk_snapshot_auto_packages() {
  local name
  local -A auto=()
  while IFS= read -r name; do
    if [[ -n $name ]]; then
      auto[${name%%:*}]=1
    fi
  done < <(apt-mark showauto 2>/dev/null || true)
  for name in "$@"; do
    if [[ -n ${auto[$name]:-} ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# mk_snapshot_mark_auto <package...>: marks the installed ones as
# automatically installed again ("apt-get install <name>" marks a package
# manual).
mk_snapshot_mark_auto() {
  local name
  local -a still=()
  for name in "$@"; do
    if mk_installed_version "$name" >/dev/null; then
      still+=("$name")
    fi
  done
  if ((${#still[@]} > 0)) && ! mk_snapshot_nolock apt-mark auto "${still[@]}" >/dev/null 2>&1; then
    mk_warn "could not mark ${still[*]} as automatically installed again"
  fi
  return 0
}

# mk_snapshot_ledger_new <parsed-simulation>: a pkg-installed line for each
# Foreign_Package the transaction installed new (3.7), unless the
# System_Ledger has one. <parsed-simulation> is mk_aptsim_parse output.
mk_snapshot_ledger_new() {
  local op pkg old ver mode
  local -A recorded=() manual=()
  while IFS= read -r pkg; do
    if [[ -n $pkg ]]; then
      recorded[$pkg]=1
    fi
  done < <(mk_sysledger_packages 2>/dev/null)
  while IFS= read -r pkg; do
    if [[ -n $pkg ]]; then
      manual[${pkg%%:*}]=1
    fi
  done < <(apt-mark showmanual 2>/dev/null || true)
  while IFS=$'\t' read -r op pkg old _; do
    if [[ $op != Inst || $old != - || -n ${recorded[$pkg]:-} ]] || mk_is_motanka_package "$pkg"; then
      continue
    fi
    if ! ver=$(mk_installed_version "$pkg"); then
      continue
    fi
    mode=auto
    if [[ -n ${manual[$pkg]:-} ]]; then
      mode=manual
    fi
    mk_sysledger_pkg_installed "$pkg" "$ver" "$mode" || return 1
    recorded[$pkg]=1
  done <"$1"
}
