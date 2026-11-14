# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # library: its variables and functions are used by the files that source it
# Private apt work of the Installer (design.md, Install sequence;
# requirements 2.2, 2.3, 2.6, 4.1, 4.5).
#
# Everything happens in one private folder, /run/motanka/install.XXXXXX
# (mk_aptsim_begin), deleted by mk_aptsim_cleanup:
#
#   dl/               SHA256SUMS, SHA256SUMS.gpg, keyring.deb, source.deb
#   gnupg/            empty home folder for gpgv
#   archive-key.gpg   the CLI's archive key, de-armored
#   keyring/ source/  the two .debs unpacked with dpkg-deb -x
#   apt/              sources.list, sources.list.d/, preferences,
#                     preferences.d/, private.conf
#   lists/ cache/     apt lists and caches of the private configuration
#
# Folders are 0755 and downloads 0644, so apt's unprivileged _apt user can
# read the keyring and the .debs.
#
# Trust chain (4.1, 4.5):
#   1. The archive key ships with the CLI: $MK_LIBEXEC/keys/motanka-archive.asc,
#      or packaging/keys/motanka-archive.asc when the CLI runs from a
#      source tree.
#   2. The repository root holds SHA256SUMS (the SHA-256 of every .deb in
#      pool/, plus install.sh and motanka-cli.tar.gz) and SHA256SUMS.gpg, a
#      detached signature made with the archive key (chumak/build-repo).
#      gpgv must report VALIDSIG for it, or the Installer exits 6.
#   3. The newest motanka-archive-keyring and motanka-source-<suite> .debs
#      of pool/<suite>/ are downloaded and used only if their SHA-256
#      matches SHA256SUMS; otherwise the download is deleted and the
#      Installer exits 6.
#   4. apt checks the signed InRelease of the Motanka suite with the
#      keyring from the verified keyring package; a failed check exits 6.
#
# The private apt configuration uses the Host's sources (except an
# installed motanka.sources) and preferences, the source and pin from the
# two .debs, and private lists and caches. apt hooks that run on update or
# around dpkg (command-not-found, update-notifier, Ubuntu Pro) are cleared,
# so the dry run writes nothing outside /run/motanka (2.3).
#
# Repository URL: MOTANKA_APT_URI, default
# https://digitwolf.github.io/motanka/apt. It only says where the keyring
# and source packages and SHA256SUMS are fetched; apt uses the URIs in the
# verified source package.
#
# Requires common.sh. Callers hold the system lock. Test hook: MOTANKA_ROOT
# (see common.sh) for /run, /etc/apt and every other system path read here.

if [[ -n ${MK_APTSIM_LOADED:-} ]]; then
  return 0
fi
MK_APTSIM_LOADED=1

readonly MK_APT_DEFAULT_URI=https://digitwolf.github.io/motanka/apt
readonly MK_APTSIM_RUN_DIR=/run/motanka
readonly MK_ARCHIVE_KEY_NAME=motanka-archive.asc

# State of this run, set by the functions below.
MK_APTSIM_DIR=""
MK_APTSIM_URI=""
MK_APTSIM_REPO_URI=""
MK_APTSIM_KEYRING_DEB=""
MK_APTSIM_KEYRING_VERSION=""
MK_APTSIM_SOURCE_DEB=""
MK_APTSIM_SOURCE_VERSION=""
MK_APTSIM_OPTS=()
_MK_PICK_PATH=""
_MK_PICK_SHA=""
_MK_PICK_VERSION=""

# --- small helpers ------------------------------------------------------

# mk_is_motanka_package <name>: 0 for motanka and motanka-*.
mk_is_motanka_package() {
  [[ $1 == motanka || $1 == motanka-* ]]
}

# mk_installed_version <package>: prints the installed version and returns
# 0, or returns 1 if the package is not installed.
mk_installed_version() {
  local out st ver
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  out=$(dpkg-query -W -f='${db:Status-Status}\t${Version}\n' "$1" 2>/dev/null) || return 1
  while IFS=$'\t' read -r st ver; do
    if [[ $st == installed && -n $ver ]]; then
      printf '%s\n' "$ver"
      return 0
    fi
  done <<<"$out"
  return 1
}

# mk_aptsim_uri: validates MOTANKA_APT_URI (or the default) and sets
# MK_APTSIM_URI without a trailing slash. Exits 2 on an invalid value.
mk_aptsim_uri() {
  local uri=${MOTANKA_APT_URI:-$MK_APT_DEFAULT_URI}
  uri=${uri%/}
  if [[ ! $uri =~ ^https?://[A-Za-z0-9._~:@%+=,/-]+$ ]]; then
    mk_die "$MK_EXIT_USAGE" "MOTANKA_APT_URI must be an http or https URL without spaces, got '$uri'"
  fi
  MK_APTSIM_URI=$uri
}

# --- private folder -----------------------------------------------------

# mk_aptsim_begin: creates /run/motanka (0755) and this run's private
# folder, after deleting install.* folders left by killed runs. Exits 1 on
# failure.
mk_aptsim_begin() {
  local run d old
  run=$(mk_path "$MK_APTSIM_RUN_DIR")
  if [[ ! -d $run ]]; then
    mkdir -p -- "$run" || mk_die "$MK_EXIT_ERROR" "cannot create $run"
  fi
  chmod 0755 -- "$run" || mk_die "$MK_EXIT_ERROR" "cannot set the mode of $run"
  for old in "$run"/install.*; do
    if [[ -d $old && ! -L $old ]]; then
      rm -rf -- "$old"
    fi
  done
  d=$(mktemp -d "$run/install.XXXXXX") || mk_die "$MK_EXIT_ERROR" "cannot create a private folder in $run"
  MK_APTSIM_DIR=$d
  if ! mkdir -- "$d/dl" "$d/keyring" "$d/source" "$d/apt" "$d/apt/sources.list.d" \
    "$d/apt/preferences.d" "$d/lists" "$d/lists/partial" "$d/cache" \
    "$d/cache/archives" "$d/cache/archives/partial" ||
    ! chmod 0755 -- "$d" "$d/dl" "$d/keyring" "$d/source" "$d/apt" \
      "$d/apt/sources.list.d" "$d/apt/preferences.d" "$d/lists" "$d/cache" \
      "$d/cache/archives" ||
    ! mkdir -m 0700 -- "$d/gnupg"; then
    mk_die "$MK_EXIT_ERROR" "cannot prepare the private folder $d"
  fi
  mk_log info "private apt folder $d"
}

# mk_aptsim_cleanup: deletes the private folder of this run.
mk_aptsim_cleanup() {
  if [[ -n $MK_APTSIM_DIR && -d $MK_APTSIM_DIR ]]; then
    rm -rf -- "$MK_APTSIM_DIR" || true
  fi
  MK_APTSIM_DIR=""
}

# --- downloads and verification -----------------------------------------

# _mk_aptsim_fetch <url> <dest>: downloads with curl, or with apt-helper
# when curl is missing. Returns 1 on failure.
_mk_aptsim_fetch() {
  local url=$1 dest=$2
  rm -f -- "$dest"
  mk_log info "downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --proto '=http,https' \
      --proto-redir '=http,https' --connect-timeout 30 --max-time 900 \
      --retry 2 --output "$dest" "$url" || return 1
  elif [[ -x /usr/lib/apt/apt-helper ]]; then
    /usr/lib/apt/apt-helper download-file "$url" "$dest" >/dev/null || return 1
  else
    mk_error "neither curl nor /usr/lib/apt/apt-helper is available to download $url"
    return 1
  fi
  [[ -f $dest ]] || return 1
  chmod 0644 -- "$dest"
}

# _mk_aptsim_get <repo-relative-path> <dest>: downloads from the repository
# or exits 1.
_mk_aptsim_get() {
  if ! _mk_aptsim_fetch "$MK_APTSIM_URI/$1" "$2"; then
    rm -f -- "$2"
    mk_die "$MK_EXIT_ERROR" "cannot download $MK_APTSIM_URI/$1; check the network connection; nothing was installed"
  fi
}

# mk_aptsim_key_file: prints the path of the armored archive key that ships
# with the CLI, or returns 1.
mk_aptsim_key_file() {
  local base=${MK_LIBEXEC:-} f
  if [[ -z $base ]]; then
    return 1
  fi
  for f in "$base/keys/$MK_ARCHIVE_KEY_NAME" "$base/../packaging/keys/$MK_ARCHIVE_KEY_NAME"; do
    if [[ -f $f && -r $f ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# mk_aptsim_dearmor <armored-key> <out>: writes the binary OpenPGP packets
# of the first public key block (what gpg --dearmor writes), with base64
# from coreutils, so gpg itself is not needed. Returns 1 if there is no
# block or it does not decode.
mk_aptsim_dearmor() {
  local in=$1 out=$2
  if ! sed -e 's/\r$//' -- "$in" | awk '
    $0 == "-----BEGIN PGP PUBLIC KEY BLOCK-----" {
      if (!seen) { inb = 1; hdr = 1; seen = 1 }
      next
    }
    !inb { next }
    $0 == "-----END PGP PUBLIC KEY BLOCK-----" { inb = 0; next }
    hdr { if ($0 == "") hdr = 0; next }
    /^=/ { crc = 1; next }
    crc { next }
    { print }
  ' | base64 -d >"$out" 2>/dev/null; then
    rm -f -- "$out"
    return 1
  fi
  [[ -s $out ]]
}

# _mk_aptsim_gpgv <signature> <data>: 0 if gpgv reports a valid signature
# by the archive key.
_mk_aptsim_gpgv() {
  local sig=$1 data=$2 d=$MK_APTSIM_DIR
  if ! command -v gpgv >/dev/null 2>&1; then
    printf 'gpgv is missing (package gpgv)\n' >"$d/gpgv.log"
    return 1
  fi
  if ! gpgv --homedir "$d/gnupg" --status-fd 1 --keyring "$d/archive-key.gpg" \
    "$sig" "$data" >"$d/gpgv.status" 2>"$d/gpgv.log"; then
    return 1
  fi
  grep -q '^\[GNUPG:\] VALIDSIG ' "$d/gpgv.status"
}

# _mk_aptsim_pick <SHA256SUMS> <suite> <package>: finds the newest
# pool/<suite>/.../<package>_<version>_all.deb in SHA256SUMS and sets
# _MK_PICK_PATH, _MK_PICK_SHA and _MK_PICK_VERSION. Lines with an invalid
# hash, path or version are ignored. Returns 1 if there is none.
_mk_aptsim_pick() {
  local sums=$1 suite=$2 name=$3 sha path rest file ver
  _MK_PICK_PATH="" _MK_PICK_SHA="" _MK_PICK_VERSION=""
  while read -r sha path rest; do
    if [[ -n $rest || ! $sha =~ ^[0-9a-f]{64}$ ]]; then
      continue
    fi
    path=${path#\*}
    if [[ $path != "pool/$suite/"* || ! $path =~ ^[A-Za-z0-9._+~/-]+$ || $path == *..* ]]; then
      continue
    fi
    file=${path##*/}
    if [[ $file != "${name}_"*_all.deb ]]; then
      continue
    fi
    ver=${file#"${name}_"}
    ver=${ver%_all.deb}
    if [[ ! $ver =~ ^[0-9][A-Za-z0-9.+~-]*$ ]]; then
      continue
    fi
    if [[ -z $_MK_PICK_VERSION ]] || dpkg --compare-versions "$ver" gt "$_MK_PICK_VERSION"; then
      _MK_PICK_PATH=$path _MK_PICK_SHA=$sha _MK_PICK_VERSION=$ver
    fi
  done <"$sums"
  [[ -n $_MK_PICK_PATH ]]
}

# _mk_aptsim_get_deb <suite> <package> <dest>: downloads the newest .deb of
# the package for the suite and checks its SHA-256 and control fields.
# Exits 6 (deleting the download) on a mismatch, 1 if it is not listed.
_mk_aptsim_get_deb() {
  local suite=$1 name=$2 dest=$3 got
  if ! _mk_aptsim_pick "$MK_APTSIM_DIR/dl/SHA256SUMS" "$suite" "$name"; then
    mk_die "$MK_EXIT_ERROR" "$MK_APTSIM_URI/SHA256SUMS lists no $name package for the suite $suite; nothing was installed"
  fi
  _mk_aptsim_get "$_MK_PICK_PATH" "$dest"
  got=$(sha256sum <"$dest")
  got=${got:0:64}
  if [[ $got != "$_MK_PICK_SHA" ]]; then
    rm -f -- "$dest"
    mk_die "$MK_EXIT_VERIFY" "checksum mismatch for $MK_APTSIM_URI/$_MK_PICK_PATH: SHA256SUMS has $_MK_PICK_SHA, the download has $got; the download was deleted and nothing was installed"
  fi
  if [[ $(dpkg-deb --field "$dest" Package 2>/dev/null) != "$name" ||
  $(dpkg-deb --field "$dest" Version 2>/dev/null) != "$_MK_PICK_VERSION" ]]; then
    rm -f -- "$dest"
    mk_die "$MK_EXIT_VERIFY" "$MK_APTSIM_URI/$_MK_PICK_PATH is not the package $name $_MK_PICK_VERSION; the download was deleted and nothing was installed"
  fi
  mk_info "verified $name $_MK_PICK_VERSION (SHA-256 $got)"
  mk_log info "verified $name $_MK_PICK_VERSION against SHA256SUMS"
}

# mk_aptsim_fetch_verified <suite>: downloads SHA256SUMS and its signature,
# verifies them with gpgv, then downloads and verifies the keyring and
# source packages of the suite (MK_APTSIM_KEYRING_DEB, MK_APTSIM_SOURCE_DEB
# and their versions). Exits 6 on any verification failure, 1 when a
# download fails.
mk_aptsim_fetch_verified() {
  local suite=$1 d=$MK_APTSIM_DIR key
  if [[ -z $MK_APTSIM_URI ]]; then
    mk_aptsim_uri
  fi
  if ! key=$(mk_aptsim_key_file); then
    mk_die "$MK_EXIT_VERIFY" "the archive key that verifies the Motanka repository is missing (expected ${MK_LIBEXEC:-<libexec>}/keys/$MK_ARCHIVE_KEY_NAME); nothing was installed"
  fi
  if ! mk_aptsim_dearmor "$key" "$d/archive-key.gpg"; then
    mk_die "$MK_EXIT_VERIFY" "cannot read the archive key $key; nothing was installed"
  fi
  mk_info "downloading the signed checksums from $MK_APTSIM_URI"
  _mk_aptsim_get SHA256SUMS "$d/dl/SHA256SUMS"
  _mk_aptsim_get SHA256SUMS.gpg "$d/dl/SHA256SUMS.gpg"
  if ! _mk_aptsim_gpgv "$d/dl/SHA256SUMS.gpg" "$d/dl/SHA256SUMS"; then
    if [[ -s $d/gpgv.log ]]; then
      sed 's/^/  /' "$d/gpgv.log" >&2
    fi
    mk_die "$MK_EXIT_VERIFY" "the signature of $MK_APTSIM_URI/SHA256SUMS does not verify with the Motanka archive key $key; nothing was installed"
  fi
  mk_info "verified SHA256SUMS: signed by the Motanka archive key"
  mk_log info "verified the signature of $MK_APTSIM_URI/SHA256SUMS"
  MK_APTSIM_KEYRING_DEB=$d/dl/keyring.deb
  _mk_aptsim_get_deb "$suite" motanka-archive-keyring "$MK_APTSIM_KEYRING_DEB"
  MK_APTSIM_KEYRING_VERSION=$_MK_PICK_VERSION
  MK_APTSIM_SOURCE_DEB=$d/dl/source.deb
  _mk_aptsim_get_deb "$suite" "motanka-source-$suite" "$MK_APTSIM_SOURCE_DEB"
  MK_APTSIM_SOURCE_VERSION=$_MK_PICK_VERSION
}

# --- private apt configuration ------------------------------------------

# _mk_aptsim_copy_files <to-dir> <skip-name> <file>...: copies each
# argument that is a regular file into <to-dir>, except files named
# <skip-name>. Unmatched glob patterns are skipped.
_mk_aptsim_copy_files() {
  local to=$1 skip=$2 f
  shift 2
  for f in "$@"; do
    if [[ ! -f $f || ${f##*/} == "$skip" ]]; then
      continue
    fi
    cp -- "$f" "$to/${f##*/}" || return 1
  done
}

# mk_aptsim_prepare <suite>: unpacks the verified .debs and writes the
# private apt configuration; sets MK_APTSIM_OPTS and MK_APTSIM_REPO_URI.
# Exits 1 if a package lacks an expected file.
mk_aptsim_prepare() {
  local suite=$1 d=$MK_APTSIM_DIR etc kr pin src
  if ! dpkg-deb -x "$MK_APTSIM_KEYRING_DEB" "$d/keyring" ||
    ! dpkg-deb -x "$MK_APTSIM_SOURCE_DEB" "$d/source"; then
    mk_die "$MK_EXIT_ERROR" "cannot unpack the keyring and source packages in $d"
  fi
  kr=$d/keyring/usr/share/keyrings/motanka-archive-keyring.gpg
  pin=$d/keyring/etc/apt/preferences.d/motanka
  src=$d/source/etc/apt/sources.list.d/motanka.sources
  if [[ ! -s $kr || ! -f $pin ]]; then
    mk_die "$MK_EXIT_ERROR" "the package motanka-archive-keyring lacks /usr/share/keyrings/motanka-archive-keyring.gpg or /etc/apt/preferences.d/motanka"
  fi
  if [[ ! -f $src ]] || ! grep -qxF "Suites: $suite" "$src" || ! grep -q '^Signed-By:' "$src"; then
    mk_die "$MK_EXIT_ERROR" "the package motanka-source-$suite has no /etc/apt/sources.list.d/motanka.sources for the suite $suite with a Signed-By field"
  fi
  MK_APTSIM_REPO_URI=$(sed -n 's/^URIs:[[:space:]]*//p' "$src" | head -n 1)
  MK_APTSIM_REPO_URI=${MK_APTSIM_REPO_URI%%[[:space:]]*}
  MK_APTSIM_REPO_URI=${MK_APTSIM_REPO_URI%/}
  if [[ ! $MK_APTSIM_REPO_URI =~ ^https?://[^[:space:]]+$ ]]; then
    mk_die "$MK_EXIT_ERROR" "the package motanka-source-$suite names no http or https repository"
  fi
  if [[ $MK_APTSIM_REPO_URI != "$MK_APTSIM_URI" ]]; then
    mk_info "note: the packages came from $MK_APTSIM_URI; apt uses the repository $MK_APTSIM_REPO_URI named by motanka-source-$suite"
  fi

  etc=$(mk_path /etc/apt)
  if [[ -f $etc/sources.list ]]; then
    cp -- "$etc/sources.list" "$d/apt/sources.list"
  else
    : >"$d/apt/sources.list"
  fi
  if [[ -f $etc/preferences ]]; then
    cp -- "$etc/preferences" "$d/apt/preferences"
  else
    : >"$d/apt/preferences"
  fi
  if ! _mk_aptsim_copy_files "$d/apt/sources.list.d" motanka.sources \
    "$etc"/sources.list.d/*.list "$etc"/sources.list.d/*.sources ||
    ! _mk_aptsim_copy_files "$d/apt/preferences.d" motanka "$etc"/preferences.d/*; then
    mk_die "$MK_EXIT_ERROR" "cannot copy the apt sources and preferences into $d/apt"
  fi
  awk -v kr="$kr" '/^Signed-By:/ { print "Signed-By: " kr; next } { print }' "$src" \
    >"$d/apt/sources.list.d/motanka.sources"
  cp -- "$pin" "$d/apt/preferences.d/motanka"
  cat >"$d/apt/private.conf" <<'EOF'
// Private configuration of the Motanka Installer: no hooks, so a
// simulation writes nothing outside its private folder.
#clear APT::Update::Pre-Invoke;
#clear APT::Update::Post-Invoke;
#clear APT::Update::Post-Invoke-Success;
#clear APT::Install::Pre-Invoke;
#clear APT::Install::Post-Invoke;
#clear APT::Install::Post-Invoke-Success;
#clear DPkg::Pre-Invoke;
#clear DPkg::Pre-Install-Pkgs;
#clear DPkg::Post-Invoke;
#clear DPkg::Post-Invoke-Success;
EOF
  find "$d/apt" -type f -exec chmod 0644 {} +
  MK_APTSIM_OPTS=(
    -c "$d/apt/private.conf"
    -o "Dir::Etc::SourceList=$d/apt/sources.list"
    -o "Dir::Etc::SourceParts=$d/apt/sources.list.d"
    -o "Dir::Etc::Preferences=$d/apt/preferences"
    -o "Dir::Etc::PreferencesParts=$d/apt/preferences.d"
    -o "Dir::State::Lists=$d/lists"
    -o "Dir::Cache=$d/cache"
    -o "Dir::Cache::archives=$d/cache/archives"
  )
}

# mk_aptsim_update <suite>: apt-get update with the private configuration;
# then the Motanka suite must be in apt's policy, which apt allows only for
# a signed and valid InRelease. Exits 6 on a signature or validity error,
# 1 on any other failure.
mk_aptsim_update() {
  local suite=$1 d=$MK_APTSIM_DIR rc=0
  mk_info "apt-get update with a private configuration in $d"
  mk_log info "private apt-get update for the suite $suite"
  LC_ALL=C apt-get "${MK_APTSIM_OPTS[@]}" -q update >"$d/update.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    if apt-cache "${MK_APTSIM_OPTS[@]}" policy >"$d/policy.txt" 2>/dev/null &&
      grep -Eq "(^|[ ,])o=Motanka,a=$suite,n=$suite(,|$)" "$d/policy.txt"; then
      return 0
    fi
    mk_info "apt-get update finished, but apt does not list the Motanka suite $suite"
  fi
  sed 's/^/  /' "$d/update.log" >&2
  if grep -Eqi 'NO_PUBKEY|BADSIG|EXPKEYSIG|GPG error|not signed|signature|is expired|not valid yet' "$d/update.log"; then
    mk_die "$MK_EXIT_VERIFY" "apt could not verify the signed index of the Motanka suite $suite; nothing was installed"
  fi
  mk_die "$MK_EXIT_ERROR" "apt-get update with the private configuration did not load the Motanka suite $suite (exit $rc); check the network connection; nothing was installed"
}

# mk_aptsim_simulate <out> <private|system> <package>...: apt-get -s
# install --no-install-recommends with the private or the Host's
# configuration. Like the Helper, the Installer, the Updater and Rollback
# install no Recommends: Motanka's packages name what they need in
# Depends, and a Recommends of a Foreign_Package could start a service or
# change system policy (3.14). The simulation
# does not pass --no-remove, so planned removals show up as Remv lines and
# can be listed; the real install passes it. Exits 1 if apt cannot plan
# the installation.
mk_aptsim_simulate() {
  local out=$1 mode=$2 rc=0
  shift 2
  local -a opts=()
  if [[ $mode == private ]]; then
    opts=("${MK_APTSIM_OPTS[@]}")
  fi
  mk_log info "simulating apt-get install $* ($mode configuration)"
  LC_ALL=C apt-get "${opts[@]}" -q -s install --no-install-recommends "$@" >"$out" 2>"$out.err" || rc=$?
  if ((rc != 0)); then
    sed 's/^/  /' "$out" "$out.err" >&2
    mk_die "$MK_EXIT_ERROR" "apt cannot plan the installation of $* (apt-get exit $rc)"
  fi
}

# mk_aptsim_plan_lines <simulation>: the Inst, Remv and Purg lines, without
# trailing blanks; these become the System_Ledger's plan lines.
mk_aptsim_plan_lines() {
  awk '$1 == "Inst" || $1 == "Remv" || $1 == "Purg" { gsub(/\t/, " "); sub(/[ \r]+$/, ""); print }' "$1"
}

# mk_aptsim_parse <simulation>: one line per Inst, Remv and Purg action, in
# the order of mk_aptsim_plan_lines:
#   <Inst|Remv|Purg> TAB <package> TAB <installed version|-> TAB <new version|->
# An architecture suffix (:amd64) is removed from the package name.
mk_aptsim_parse() {
  awk '
    $1 == "Inst" || $1 == "Remv" || $1 == "Purg" {
      op = $1; pkg = $2; old = "-"; new = "-"
      sub(/:[A-Za-z0-9]+$/, "", pkg)
      rest = $0
      sub(/^[A-Za-z]+ +[^ ]+ */, "", rest)
      if (substr(rest, 1, 1) == "[") {
        e = index(rest, "]")
        if (e > 2) old = substr(rest, 2, e - 2)
        rest = substr(rest, e + 1)
        sub(/^ +/, "", rest)
      }
      if (op == "Inst" && substr(rest, 1, 1) == "(") {
        new = substr(rest, 2)
        sp = index(new, " ")
        if (sp > 0) new = substr(new, 1, sp - 1)
        else sub(/\)$/, "", new)
      }
      print op "\t" pkg "\t" old "\t" new
    }
  ' "$1"
}

# mk_aptsim_foreign_changes <parsed>: one line per Foreign_Package that the
# transaction would upgrade, downgrade or remove (2.6, 3.1, 3.2):
#   <package> <old> -> <new> (upgrade|downgrade)
#   <package> <old> (removal)
mk_aptsim_foreign_changes() {
  local op pkg old new
  while IFS=$'\t' read -r op pkg old new; do
    if mk_is_motanka_package "$pkg"; then
      continue
    fi
    case $op in
      Remv | Purg)
        printf '%s %s (removal)\n' "$pkg" "$old"
        ;;
      Inst)
        if [[ $old == - || $new == - ]]; then
          continue
        fi
        if dpkg --compare-versions "$new" gt "$old"; then
          printf '%s %s -> %s (upgrade)\n' "$pkg" "$old" "$new"
        elif dpkg --compare-versions "$new" lt "$old"; then
          printf '%s %s -> %s (downgrade)\n' "$pkg" "$old" "$new"
        fi
        ;;
    esac
  done <"$1"
}
