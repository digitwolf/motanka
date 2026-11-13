#!/usr/bin/env bash
# Build steps of the motanka-fonts source package, called by debian/rules
# from the top of the unpacked source tree inside the sbuild chroot.
#
# Usage: bash debian/fonts-build.sh <install|verify> [<package tree>]
#
# Input: jetbrains-mono-nerd/, the orig-jetbrains-mono-nerd component
# (stack/fonts-components.tsv): Nerd Fonts' JetBrainsMono release archive,
# unpacked unchanged. The archive has no top-level folder, so its files sit
# at the top of the component folder; they are found by name at any depth,
# so a later archive with a folder works too.
#
# install  copies every font that debian/fonts.list names, and the
#          archive's OFL.txt, into the package tree (default
#          debian/motanka-fonts), unchanged, mode 0644:
#            /opt/motanka/share/fonts/jetbrains-mono-nerd/<file>
#            /usr/share/doc/motanka-fonts/OFL.txt
#          Fails when a listed file is missing or found more than once,
#          when it does not start like a TrueType or OpenType font, and
#          when the archive has no OFL.txt.
# verify   runs before dh_builddeb, on the finished package tree: the font
#          folder holds exactly the listed files, and fc-scan reports for
#          each the family, weight and slant debian/fonts.list gives.
set -euo pipefail
export LC_ALL=C.UTF-8

readonly COMPONENT=jetbrains-mono-nerd
readonly LIST=debian/fonts.list
readonly FONT_REL=opt/motanka/share/fonts/jetbrains-mono-nerd
readonly DOC_REL=usr/share/doc/motanka-fonts
readonly NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

log() {
  printf 'fonts-build: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

# read_list: fills FILES, FAMILIES, WEIGHTS and SLANTS from debian/fonts.list.
read_list() {
  local line file family weight slant n=0
  FILES=() FAMILIES=() WEIGHTS=() SLANTS=()
  [[ -f $LIST ]] || die "$LIST is missing"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    if [[ -z $line || $line == \#* ]]; then
      continue
    fi
    IFS=$'\t' read -r file family weight slant <<<"$line"
    if [[ ! $file =~ $NAME_RE || -z $family || ! $weight =~ ^[0-9]+$ || ! $slant =~ ^[0-9]+$ ]]; then
      die "$LIST:$n: expected <file> TAB <family> TAB <weight> TAB <slant>"
    fi
    FILES+=("$file")
    FAMILIES+=("$family")
    WEIGHTS+=("$weight")
    SLANTS+=("$slant")
  done <"$LIST"
  ((${#FILES[@]} > 0)) || die "$LIST names no font"
}

# find_one <file name>: prints the one regular file of that name below the
# component folder, or fails.
find_one() {
  local name=$1
  local -a found=()
  mapfile -t found < <(find "$COMPONENT" -type f -name "$name" -print | LC_ALL=C sort)
  case ${#found[@]} in
    1) printf '%s\n' "${found[0]}" ;;
    0) die "$COMPONENT/ has no $name; Nerd Fonts renamed its files, update $LIST" ;;
    *) die "$COMPONENT/ has $name more than once: ${found[*]}" ;;
  esac
}

# is_font <file>: 0 if the file starts with a TrueType, OpenType or font
# collection signature.
is_font() {
  local magic
  magic=$(od -An -tx1 -N4 -- "$1" | tr -d ' \n')
  case $magic in
    00010000 | 4f54544f | 74727565 | 74746366) return 0 ;;
  esac
  return 1
}

cmd_install() {
  local tree=$1 i src ofl
  [[ -d $COMPONENT ]] || die "$COMPONENT/ is missing: the source package lacks its orig-$COMPONENT component (packaging/build.sh adds it)"
  read_list
  install -d -m 0755 "$tree/$FONT_REL" "$tree/$DOC_REL"
  for i in "${!FILES[@]}"; do
    src=$(find_one "${FILES[i]}")
    is_font "$src" || die "$src is not a TrueType or OpenType font"
    install -m 0644 "$src" "$tree/$FONT_REL/${FILES[i]}"
  done
  ofl=$(find_one OFL.txt)
  install -m 0644 "$ofl" "$tree/$DOC_REL/OFL.txt"
  log "installed ${#FILES[@]} fonts into /$FONT_REL and the licence into /$DOC_REL/OFL.txt"
}

# has_family <comma-separated families> <family>: 0 if the list holds it.
has_family() {
  local list=$1 want=$2 f
  local -a fams=()
  IFS=, read -r -a fams <<<"$list"
  for f in "${fams[@]}"; do
    if [[ $f == "$want" ]]; then
      return 0
    fi
  done
  return 1
}

cmd_verify() {
  local tree=$1 i f got family weight slant bad=0
  local -a present=() want=()
  command -v fc-scan >/dev/null || die "fc-scan is missing; debian/control must build-depend on fontconfig"
  read_list
  mapfile -t present < <(find "$tree/$FONT_REL" -mindepth 1 -printf '%P\n' | LC_ALL=C sort)
  mapfile -t want < <(printf '%s\n' "${FILES[@]}" | LC_ALL=C sort)
  if [[ ${present[*]} != "${want[*]}" ]]; then
    die "/$FONT_REL holds '${present[*]}', expected '${want[*]}'"
  fi
  for i in "${!FILES[@]}"; do
    f=$tree/$FONT_REL/${FILES[i]}
    # awk reads to the end, so fc-scan never gets SIGPIPE under pipefail.
    got=$(fc-scan --format '%{family}\t%{weight}\t%{slant}\n' "$f" 2>/dev/null | awk 'NR == 1') || got=""
    IFS=$'\t' read -r family weight slant <<<"$got"
    if ! has_family "$family" "${FAMILIES[i]}"; then
      log "${FILES[i]}: fc-scan reports the families '$family', not '${FAMILIES[i]}'"
      bad=1
    fi
    if ! awk -v a="$weight" -v b="${WEIGHTS[i]}" -v c="$slant" -v d="${SLANTS[i]}" \
      'BEGIN { exit !(a != "" && c != "" && a + 0 == b + 0 && c + 0 == d + 0) }'; then
      log "${FILES[i]}: fc-scan reports weight '$weight' and slant '$slant', expected ${WEIGHTS[i]} and ${SLANTS[i]}"
      bad=1
    fi
  done
  ((bad == 0)) || die "the fonts do not match $LIST"
  log "verified ${#FILES[@]} fonts in /$FONT_REL with fc-scan"
}

main() {
  local tree
  (($# >= 1 && $# <= 2)) || die "usage: bash debian/fonts-build.sh <install|verify> [<package tree>]"
  tree=${2:-debian/motanka-fonts}
  case $1 in
    install) cmd_install "$tree" ;;
    verify) cmd_verify "$tree" ;;
    *) die "unknown step '$1'" ;;
  esac
}

main "$@"
