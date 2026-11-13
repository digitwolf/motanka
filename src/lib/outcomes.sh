# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # library: its variables and functions are used by the files that source it
# Package_Map outcomes and Helper calls of the Compat_Layer (design.md,
# "Wrappers, shims and the Helper").
#
# The pacman and yay shims and the omarchy-pkg-* overrides look up Arch
# package names in package-map.tsv for the running release here, and
# install or remove their outcomes. Every privileged package operation goes
# through the Helper (7.11):
#
#   apt, motanka  "helper install|remove <package...>" with the Ubuntu or
#                 Motanka package names of the outcome.
#   flatpak       Flatpak itself through the Helper when it is missing
#                 (7.15; the Helper records it in the System_Ledger), the
#                 flathub remote added with --user when it is missing, then
#                 "flatpak install --user --noninteractive flathub <app-id>".
#                 The desktop entry Flatpak exports is shadowed by
#                 ~/.local/share/applications/<app-id>.desktop, a copy with
#                 OnlyShowIn=Motanka; and X-Motanka-Flatpak=<app-id>, written
#                 through the User_Ledger as a menu-desktop entry (5.13,
#                 7.7). Other sessions then do not list the app, and the
#                 Remover can tell which Flatpak a ledger entry stands for.
#   binary        download and SHA-256 check (4.8). On a mismatch the
#                 download is deleted and the call returns 6 (4.9). A
#                 destination under /opt/motanka/ is installed by the Helper
#                 (which checks the file again); a destination in a
#                 Namespaced_Path (~/...) is written through the User_Ledger.
#   skip          the recorded reason is printed and the call succeeds (7.6).
#
# Removal touches only what Motanka installed (rule 1): Ubuntu packages in
# the System_Ledger, Flatpak apps whose shadow entry is in the User_Ledger,
# and binary outcomes. Everything else is kept, with a message and a
# journal entry.
#
# mk_oc_unsupported is the common end of Upstream commands that Motanka
# does not support: it prints "<command>: not available in Motanka:
# <reason>", writes an "unsupported call" journal entry and exits 64.
#
# Requires common.sh; sysledger.sh for removals and the Helper;
# userledger.sh for Flatpak and Namespaced_Path binary outcomes.
#
# Test hooks, for unprivileged callers (the Helper unsets them as root):
#   MOTANKA_PACKAGE_MAP  the package-map.tsv to read
#   MOTANKA_HELPER       the Helper program to run
#   MOTANKA_ROOT         fake root for /etc/os-release and the System_Ledger
#                        (common.sh)

if [[ -n ${MK_OUTCOMES_LOADED:-} ]]; then
  return 0
fi
MK_OUTCOMES_LOADED=1

readonly MK_OC_MAP_PATH=/opt/motanka/share/motanka/package-map.tsv
readonly MK_OC_HELPER_PATH=/opt/motanka/libexec/motanka/helper
readonly MK_OC_FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo
readonly MK_OC_ONLY_SHOW_IN='OnlyShowIn=Motanka;'
readonly MK_OC_EXIT_UNSUPPORTED=64
readonly MK_OC_ARCH_RE='^[a-z0-9@_+][a-z0-9@._+-]*$'
readonly MK_OC_DEB_RE='^[a-z0-9][a-z0-9+.-]+$'
readonly MK_OC_FLATPAK_RE='^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$'
readonly MK_OC_SHA_RE='^[0-9a-f]{64}$'

# Fields of the entry found by the last mk_oc_lookup:
#   kind    apt, motanka, flatpak, binary or skip
#   target  package names (comma-separated), app ID, URL, or -
#   f4      note or reason; the SHA-256 for binary
#   f5      the destination for binary, empty otherwise
MK_OC_KIND="" MK_OC_TARGET="" MK_OC_F4="" MK_OC_F5=""
MK_OC_MAP_OK=""
MK_OC_LEDGER_LOADED=""
declare -gA MK_OC_LEDGER=()

# --- the map --------------------------------------------------------------

# mk_oc_map_file: path of package-map.tsv.
mk_oc_map_file() {
  if [[ -n ${MOTANKA_PACKAGE_MAP:-} ]]; then
    printf '%s\n' "$MOTANKA_PACKAGE_MAP"
  else
    mk_path "$MK_OC_MAP_PATH"
  fi
}

# mk_oc_release: VERSION_CODENAME from /etc/os-release, for example resolute.
mk_oc_release() {
  local file line codename=""
  file=$(mk_path /etc/os-release)
  if [[ ! -r $file ]]; then
    mk_error "cannot read $file"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == VERSION_CODENAME=* ]]; then
      codename=${line#VERSION_CODENAME=}
      codename=${codename//\"/}
      codename=${codename//\'/}
      break
    fi
  done <"$file"
  if [[ ! $codename =~ ^[a-z]+$ ]]; then
    mk_error "$file names no release codename"
    return 1
  fi
  printf '%s\n' "$codename"
}

# mk_oc_map_release: the release named in the map's header line
# ("# package-map.tsv for <release>, ...").
mk_oc_map_release() {
  local file header="" re='^# package-map\.tsv for ([a-z]+)[, ]'
  file=$(mk_oc_map_file)
  [[ -r $file ]] || return 1
  IFS= read -r header <"$file" || true
  [[ $header =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# mk_oc_map_check: 0 if the map is readable and compiled for the running
# release. Otherwise prints an error and returns 1, or 10 when the map is
# for another release (after a release upgrade, until "motanka doctor
# --fix" and "motanka update" install the new one).
mk_oc_map_check() {
  local file release map_release
  if [[ -n $MK_OC_MAP_OK ]]; then
    return 0
  fi
  file=$(mk_oc_map_file)
  if [[ ! -r $file ]]; then
    mk_error "cannot read the Package_Map $file"
    return 1
  fi
  release=$(mk_oc_release) || return 1
  map_release=$(mk_oc_map_release) || map_release=""
  if [[ $map_release != "$release" ]]; then
    mk_error "the Package_Map $file is for '${map_release:-an unknown release}', but this system runs '$release'; run 'sudo motanka doctor --fix' and then 'sudo motanka update'"
    return "$MK_EXIT_SUITE"
  fi
  MK_OC_MAP_OK=1
}

# mk_oc_arch_name_ok <name>, mk_oc_deb_name_ok <name>: name syntax.
mk_oc_arch_name_ok() {
  [[ $1 =~ $MK_OC_ARCH_RE ]]
}

mk_oc_deb_name_ok() {
  [[ $1 =~ $MK_OC_DEB_RE ]]
}

# mk_oc_motanka_package <name>: 0 for motanka and motanka-*.
mk_oc_motanka_package() {
  [[ $1 == motanka || $1 == motanka-* ]]
}

# mk_oc_lookup <arch-name>: finds the entry and sets MK_OC_KIND,
# MK_OC_TARGET, MK_OC_F4 and MK_OC_F5. Returns 1 when the name is invalid,
# the map is unreadable or the name has no entry.
mk_oc_lookup() {
  local name=$1 file line
  MK_OC_KIND="" MK_OC_TARGET="" MK_OC_F4="" MK_OC_F5=""
  mk_oc_arch_name_ok "$name" || return 1
  file=$(mk_oc_map_file)
  [[ -r $file ]] || return 1
  line=$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$file") || return 1
  [[ -n $line ]] || return 1
  IFS=$'\t' read -r _ MK_OC_KIND MK_OC_TARGET MK_OC_F4 MK_OC_F5 <<<"$line"
  [[ -n $MK_OC_KIND && -n $MK_OC_TARGET ]]
}

# --- installed state ------------------------------------------------------

# mk_oc_deb_installed <package>: 0 if dpkg reports it installed.
mk_oc_deb_installed() {
  local status
  # shellcheck disable=SC2016 # a dpkg-query format, not a shell expansion
  status=$(dpkg-query -W --showformat='${db:Status-Abbrev}' "$1" 2>/dev/null) || return 1
  [[ $status == ii* ]]
}

# mk_oc_deb_version <package>: the installed version.
mk_oc_deb_version() {
  local v
  # shellcheck disable=SC2016 # a dpkg-query format, not a shell expansion
  v=$(dpkg-query -W --showformat='${Version}' "$1" 2>/dev/null) || return 1
  printf '%s\n' "$v"
}

# mk_oc_deb_summary <package>: the one-line description.
mk_oc_deb_summary() {
  local s
  # shellcheck disable=SC2016 # a dpkg-query format, not a shell expansion
  s=$(dpkg-query -W --showformat='${binary:Summary}' "$1" 2>/dev/null) || return 1
  printf '%s\n' "$s"
}

# mk_oc_home: the home folder (MK_HOME, or HOME), without a trailing /.
mk_oc_home() {
  local home=${MK_HOME:-${HOME:-}}
  printf '%s\n' "${home%/}"
}

# mk_oc_flatpak_installed <app-id>: 0 if the app is installed for this user.
mk_oc_flatpak_installed() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak info --user "$1" >/dev/null 2>&1
}

# mk_oc_binary_path <dest>: the file a binary destination names: ~/ is the
# home folder; other paths go through mk_path.
mk_oc_binary_path() {
  case $1 in
    "~/"*) printf '%s/%s\n' "$(mk_oc_home)" "${1#"~/"}" ;;
    *) mk_path "$1" ;;
  esac
}

# mk_oc_namespaced <home-relative-path>: 0 for a file below a
# Namespaced_Path that a binary outcome may use.
mk_oc_namespaced() {
  case $1 in
    .config/omarchy/?* | .local/share/omarchy/?* | .local/state/omarchy/?* | .cache/omarchy/?* | .cache/motanka/?*) ;;
    *) return 1 ;;
  esac
  [[ /$1/ != */../* && /$1/ != */./* && $1 != */ ]]
}

# mk_oc_present <arch-name>: 0 if the name's outcome is installed: every
# package of an apt or motanka outcome, the Flatpak app for this user, or
# the binary's file. Unmapped names and skip outcomes are not installed.
# Leaves the entry in MK_OC_*.
mk_oc_present() {
  local t
  local -a targets=()
  mk_oc_lookup "$1" || return 1
  case $MK_OC_KIND in
    apt | motanka)
      IFS=, read -r -a targets <<<"$MK_OC_TARGET"
      ((${#targets[@]} > 0)) || return 1
      for t in "${targets[@]}"; do
        mk_oc_deb_installed "$t" || return 1
      done
      return 0
      ;;
    flatpak)
      mk_oc_flatpak_installed "$MK_OC_TARGET"
      ;;
    binary)
      [[ -f $(mk_oc_binary_path "$MK_OC_F5") ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# --- the System_Ledger ----------------------------------------------------

# mk_oc_ledger_load: reads the Ubuntu package names in the System_Ledger
# (pkg-installed and apt menu-install lines) into MK_OC_LEDGER, once.
mk_oc_ledger_load() {
  local name
  if [[ -n $MK_OC_LEDGER_LOADED ]]; then
    return 0
  fi
  MK_OC_LEDGER=()
  while IFS= read -r name; do
    if [[ -n $name ]]; then
      MK_OC_LEDGER[$name]=1
    fi
  done < <(
    mk_sysledger_packages 2>/dev/null
    mk_sysledger_menu_installs 2>/dev/null | awk -F'\t' '$3 == "apt" { print $2 }'
  )
  MK_OC_LEDGER_LOADED=1
}

# mk_oc_ledgered <package>: 0 if the System_Ledger records Motanka
# installing the package.
mk_oc_ledgered() {
  mk_oc_ledger_load
  [[ -n ${MK_OC_LEDGER[$1]:-} ]]
}

# --- the Helper -----------------------------------------------------------

# mk_oc_helper <operation> <arguments...>: runs the Helper as the caller;
# it asks polkit itself. Returns the Helper's exit code (11: authorisation
# denied, nothing changed).
mk_oc_helper() {
  local helper=${MOTANKA_HELPER:-$MK_OC_HELPER_PATH} rc=0
  if [[ ! -x $helper ]]; then
    mk_error "the Helper $helper is missing"
    return 1
  fi
  "$helper" "$@" || rc=$?
  return "$rc"
}

# --- desktop entries ------------------------------------------------------

# mk_oc_desktop_only_show_in <in> <out> [key=value...]: copies a desktop
# entry and limits it to the Motanka session: OnlyShowIn=Motanka; right
# after the [Desktop Entry] header, earlier OnlyShowIn and NotShowIn keys of
# that group dropped (the specification allows only one of them), and each
# key=value argument added after it, replacing a line with the same key in
# that group. Other groups are copied unchanged. Returns non-zero when the
# file has no [Desktop Entry] group.
mk_oc_desktop_only_show_in() {
  local in=$1 out=$2 extra=""
  shift 2
  if (($# > 0)); then
    extra=$(printf '%s\n' "$@")
  fi
  MK_OC_EXTRA=$extra awk -v show="$MK_OC_ONLY_SHOW_IN" '
    BEGIN {
      n = split(ENVIRON["MK_OC_EXTRA"], xs, "\n")
      for (i = 1; i <= n; i++) {
        if (xs[i] == "") continue
        k = xs[i]
        sub(/=.*/, "", k)
        drop[k] = 1
      }
    }
    /^[ \t]*\[/ {
      group = 0
      if (!done && $0 ~ /^\[Desktop Entry\][ \t\r]*$/) group = 1
      print
      if (group) {
        print show
        for (i = 1; i <= n; i++) if (xs[i] != "") print xs[i]
        done = 1
      }
      next
    }
    group {
      k = $0
      sub(/^[ \t]+/, "", k)
      sub(/[ \t]*=.*/, "", k)
      if (k == "OnlyShowIn" || k == "NotShowIn" || (k in drop)) next
    }
    { print }
    END { if (!done) exit 3 }
  ' "$in" >"$out"
}

# --- installing outcomes --------------------------------------------------

# mk_oc_install <arch-name...>: installs the outcome of every name. Every
# name is looked up first; an unknown name fails the call before anything
# is installed, as pacman does. Returns 0, 1, 6 (checksum), 10 (map for
# another release), or the Helper's exit code.
mk_oc_install() {
  local name t bad=0
  local -a debs=() flatpaks=() binaries=() targets=()
  local -A seen=()
  mk_oc_map_check || return $?
  for name in "$@"; do
    if ! mk_oc_lookup "$name"; then
      if mk_oc_arch_name_ok "$name"; then
        mk_error "'$name' has no entry in the Package_Map for $(mk_oc_release); Motanka installs only the packages it maps"
      else
        mk_error "invalid package name '$name'"
      fi
      bad=1
      continue
    fi
    case $MK_OC_KIND in
      apt | motanka)
        IFS=, read -r -a targets <<<"$MK_OC_TARGET"
        for t in "${targets[@]}"; do
          if [[ -z ${seen[$t]:-} ]]; then
            seen[$t]=1
            debs+=("$t")
          fi
        done
        ;;
      flatpak)
        flatpaks+=("$name")
        ;;
      binary)
        binaries+=("$name")
        ;;
      skip)
        printf 'motanka: %s is not installed in Motanka: %s\n' "$name" "$MK_OC_F4" >&2
        mk_log info "skip outcome for $name: $MK_OC_F4"
        ;;
      *)
        mk_error "'$name' has an unknown outcome '$MK_OC_KIND' in the Package_Map"
        bad=1
        ;;
    esac
  done
  if ((bad)); then
    return 1
  fi
  if ((${#debs[@]} > 0)); then
    mk_oc_helper install "${debs[@]}" || return $?
  fi
  for name in "${flatpaks[@]}"; do
    mk_oc_flatpak_install "$name" || return $?
  done
  for name in "${binaries[@]}"; do
    mk_oc_binary_install "$name" || return $?
  done
  return 0
}

# mk_oc_flatpak_data: the user's data folder (XDG_DATA_HOME or
# ~/.local/share).
mk_oc_flatpak_data() {
  local home data
  home=$(mk_oc_home)
  data=${XDG_DATA_HOME:-$home/.local/share}
  printf '%s\n' "${data%/}"
}

# mk_oc_flatpak_shadow_rel <app-id>: home-relative path of the shadow
# desktop entry, or 1 when the data folder is outside the home folder.
mk_oc_flatpak_shadow_rel() {
  local home data
  home=$(mk_oc_home)
  data=$(mk_oc_flatpak_data)
  [[ $data == "$home"/?* ]] || return 1
  printf '%s/applications/%s.desktop\n' "${data#"$home"/}" "$1"
}

# mk_oc_flatpak_shadow <app-id>: writes the shadow desktop entry through
# the User_Ledger.
mk_oc_flatpak_shadow() {
  local id=$1 src rel tmp rc=0
  src=$(mk_oc_flatpak_data)/flatpak/exports/share/applications/$id.desktop
  if ! rel=$(mk_oc_flatpak_shadow_rel "$id"); then
    mk_warn "the data folder $(mk_oc_flatpak_data) is outside the home folder; $id is not limited to the Motanka session"
    return 0
  fi
  if [[ ! -r $src ]]; then
    mk_warn "Flatpak exported no desktop entry for $id; there is no menu entry to limit to the Motanka session"
    return 0
  fi
  tmp=$(mktemp) || return 1
  if ! mk_oc_desktop_only_show_in "$src" "$tmp" "X-Motanka-Flatpak=$id"; then
    rm -f -- "$tmp"
    mk_error "$src has no [Desktop Entry] group"
    return 1
  fi
  chmod 0644 "$tmp"
  mk_userledger_menu_desktop "$rel" "$tmp" || rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

# mk_oc_flatpak_shadow_ledgered <app-id>: 0 if the User_Ledger records the
# shadow entry of the app, that is, Motanka installed it.
mk_oc_flatpak_shadow_ledgered() {
  local rel
  rel=$(mk_oc_flatpak_shadow_rel "$1") || return 1
  mk_userledger_read 2>/dev/null |
    awk -F'\t' -v p="$rel" '$3 == "menu-desktop" && $5 == p { f = 1 } END { exit !f }'
}

# mk_oc_flatpak_install <arch-name>: the flatpak outcome of one name.
mk_oc_flatpak_install() {
  local name=$1 id
  if ! mk_oc_lookup "$name" || [[ $MK_OC_KIND != flatpak ]]; then
    mk_error "'$name' is not a Flatpak outcome in the Package_Map"
    return 1
  fi
  id=$MK_OC_TARGET
  if [[ ! $id =~ $MK_OC_FLATPAK_RE ]]; then
    mk_error "invalid Flatpak app ID '$id' for '$name'"
    return 1
  fi
  if ((EUID == 0)); then
    mk_error "Flatpak apps are installed for one user; install $name as that user, not as root"
    return 1
  fi
  if ! command -v flatpak >/dev/null 2>&1; then
    mk_info "motanka: installing Flatpak, which $name needs"
    mk_oc_helper install flatpak || return $?
    hash -r
    if ! command -v flatpak >/dev/null 2>&1; then
      mk_error "flatpak is still not available after installing it"
      return 1
    fi
  fi
  if ! flatpak remote-list --user --columns=name 2>/dev/null | grep -qx flathub; then
    mk_log info "adding the flathub remote for this user"
    if ! flatpak remote-add --user --if-not-exists flathub "$MK_OC_FLATHUB_URL"; then
      mk_error "cannot add the flathub remote"
      return 1
    fi
  fi
  mk_log info "flatpak install --user flathub $id for $name"
  if ! flatpak install --user --noninteractive flathub "$id"; then
    mk_error "flatpak could not install $id"
    return 1
  fi
  mk_oc_flatpak_shadow "$id"
}

# mk_oc_binary_install <arch-name>: the binary outcome of one name.
mk_oc_binary_install() {
  local name=$1 url sha dest rel="" tmpdir file actual rc=0
  if ! mk_oc_lookup "$name" || [[ $MK_OC_KIND != binary ]]; then
    mk_error "'$name' is not a binary outcome in the Package_Map"
    return 1
  fi
  url=$MK_OC_TARGET sha=$MK_OC_F4 dest=$MK_OC_F5
  if [[ ! $sha =~ $MK_OC_SHA_RE || $url != https://?* ]]; then
    mk_error "the Package_Map entry of '$name' has no valid https URL and SHA-256"
    return 1
  fi
  case $dest in
    /opt/motanka/?*) ;;
    "~/"?*)
      rel=${dest#"~/"}
      if ! mk_oc_namespaced "$rel"; then
        mk_error "the destination $dest of '$name' is not in a Namespaced_Path"
        return 1
      fi
      if ((EUID == 0)); then
        mk_error "$name installs into a home folder; install it as that user, not as root"
        return 1
      fi
      ;;
    *)
      mk_error "the destination $dest of '$name' is neither under /opt/motanka/ nor in a Namespaced_Path"
      return 1
      ;;
  esac
  tmpdir=$(mktemp -d) || return 1
  file=$tmpdir/download
  mk_log info "downloading $url for $name"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$file" "$url"; then
    rm -rf -- "$tmpdir"
    mk_error "cannot download $url"
    return 1
  fi
  actual=$(sha256sum <"$file") || actual=""
  actual=${actual:0:64}
  if [[ $actual != "$sha" ]]; then
    rm -rf -- "$tmpdir"
    mk_error "SHA-256 mismatch for $url: the Package_Map expects $sha, the download is ${actual:-unreadable}; the download was deleted"
    return "$MK_EXIT_VERIFY"
  fi
  if [[ -z $rel ]]; then
    mk_oc_helper install-binary "$name" "$file" || rc=$?
  else
    chmod 0755 "$file"
    mk_userledger_menu_desktop "$rel" "$file" || rc=$?
  fi
  rm -rf -- "$tmpdir"
  return "$rc"
}

# --- removing outcomes ----------------------------------------------------

# mk_oc_remove <arch-name...>: removes the installed outcome of every name
# that Motanka installed; keeps the rest. Unmapped names and skip outcomes
# have nothing to remove. Returns 0, 1, or the Helper's exit code.
mk_oc_remove() {
  local name t id path rc=0
  local -a debs=() targets=()
  local -A seen=()
  for name in "$@"; do
    if ! mk_oc_lookup "$name"; then
      mk_info "motanka: $name is not in the Package_Map; nothing to remove"
      continue
    fi
    case $MK_OC_KIND in
      apt | motanka)
        IFS=, read -r -a targets <<<"$MK_OC_TARGET"
        for t in "${targets[@]}"; do
          if [[ -n ${seen[$t]:-} ]]; then
            continue
          fi
          seen[$t]=1
          if ! mk_oc_deb_installed "$t"; then
            continue
          fi
          if mk_oc_ledgered "$t" && ! mk_oc_motanka_package "$t"; then
            debs+=("$t")
          else
            mk_info "motanka: kept $t: Motanka did not install it"
            mk_log notice "kept $t for $name: it is not in the System_Ledger"
          fi
        done
        ;;
      flatpak)
        id=$MK_OC_TARGET
        if ! mk_oc_flatpak_installed "$id"; then
          continue
        fi
        if ! mk_oc_flatpak_shadow_ledgered "$id"; then
          mk_info "motanka: kept the Flatpak $id: Motanka did not install it"
          mk_log notice "kept the Flatpak $id for $name: it is not in the User_Ledger"
          continue
        fi
        mk_log info "flatpak uninstall --user $id for $name"
        if ! flatpak uninstall --user --noninteractive "$id"; then
          mk_error "flatpak could not uninstall $id"
          rc=1
          continue
        fi
        path=$(mk_oc_home)/$(mk_oc_flatpak_shadow_rel "$id")
        rm -f -- "$path"
        ;;
      binary)
        path=$(mk_oc_binary_path "$MK_OC_F5")
        if [[ ! -e $path ]]; then
          continue
        fi
        case $MK_OC_F5 in
          "~/"*)
            mk_log info "deleting the binary $MK_OC_F5 of $name"
            rm -f -- "$path"
            ;;
          *)
            mk_oc_helper remove-binary "$name" || rc=$?
            ;;
        esac
        ;;
      *) ;;
    esac
  done
  if ((${#debs[@]} > 0)); then
    mk_oc_helper remove "${debs[@]}" || rc=$?
  fi
  return "$rc"
}

# --- unsupported commands -------------------------------------------------

# mk_oc_notify <title> <body>: a desktop notification through notify-send,
# when it is installed. Never fails.
mk_oc_notify() {
  if command -v notify-send >/dev/null 2>&1; then
    timeout 5 notify-send -a Motanka -- "$1" "$2" >/dev/null 2>&1 || true
  fi
  return 0
}

# mk_oc_unsupported <command> <reason> [arguments...]: prints
# "<command>: not available in Motanka: <reason>", writes an "unsupported
# call" journal entry and exits 64. Started without a terminal on stderr
# (from a menu), it also shows a desktop notification.
mk_oc_unsupported() {
  local cmd=$1 reason=$2
  shift 2
  printf '%s: not available in Motanka: %s\n' "$cmd" "$reason" >&2
  mk_log warning "unsupported call: $cmd${*:+ $*}: $reason"
  if [[ ! -t 2 ]]; then
    mk_oc_notify "$cmd is not available in Motanka" "$reason"
  fi
  exit "$MK_OC_EXIT_UNSUPPORTED"
}
