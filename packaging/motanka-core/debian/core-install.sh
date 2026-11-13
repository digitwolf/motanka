#!/usr/bin/env bash
# Build steps of the motanka-core source package, called by debian/rules
# from the top of the unpacked source tree inside the sbuild chroot.
#
# Usage: bash debian/core-install.sh <build|test|install|verify> <suite>
#
# Inputs in the source tree:
#   omarchy/         Upstream at the stable Upstream_Pin, the orig-omarchy
#                    component. packaging/build.sh unpacked it with
#                    tools/vendor, which checked its SHA-256 against
#                    upstream.pin (7.1).
#   src/             the CLI, its libraries and commands, the launcher, the
#                    Helper, run-upstream, shims, overrides and compat-bin
#   tools/pkgmap, tools/genwrappers, packages.yaml, upstream.pin,
#   compat/*.tsv, compat/inventory/<stable commit>.tsv,
#   keys/motanka-archive.asc
#                    imported from the repository (build-imports)
#
# build    compiles debian/build/package-map.tsv for the suite with
#          tools/pkgmap and generates one Wrapper per Upstream bin/ file
#          into debian/build/wrappers with tools/genwrappers. Every Upstream
#          command name must start with "omarchy", so no Wrapper can take
#          the name of a Stack program in /opt/motanka/bin. Fails when a
#          target of Upstream's config/ tree has no Home_Path_Class in
#          compat/home-paths.tsv (src/libexec/user-setup --plan), and when
#          Upstream's install/user/all.sh and compat/user-scripts.tsv do not
#          name the same per-user scripts.
# test     checks the syntax of every shell file in src/ and debian/.
# install  installs into debian/motanka-core:
#            /usr/bin/motanka                                  src/motanka
#            /opt/motanka/libexec/motanka/lib/*.sh             src/lib/*.sh
#            /opt/motanka/libexec/motanka/cmd/*.sh             src/cmd/*.sh
#            /opt/motanka/libexec/motanka/<program>            src/libexec/*
#            /opt/motanka/libexec/motanka/{shims,overrides,compat-bin}/
#            /opt/motanka/libexec/motanka/keys/motanka-archive.asc
#            /opt/motanka/share/omarchy/                       omarchy/, unchanged
#            /opt/motanka/share/omarchy-view/                  the overlay that
#              /usr/share/omarchy links to: bin -> ../../bin (the Wrappers),
#              and <entry> -> ../omarchy/<entry> for every other top-level
#              entry of omarchy/ (design.md, "Session findings")
#            /opt/motanka/share/motanka/inventory.tsv          compat/inventory/
#                                                              <stable commit>.tsv
#            /opt/motanka/bin/<Upstream command>               the Wrappers
#            /opt/motanka/share/motanka/DEV_BUILD              unless the build
#                                                              profile is
#                                                              pkg.motanka.release
#          The static files (session entry, units, dconf, portal and polkit
#          files, the data files in /opt/motanka/share/motanka) are in
#          debian/motanka-core.install; the links in debian/motanka-core.links.
# verify   runs before dh_builddeb, on the finished package tree:
#            - /opt/motanka/share/omarchy equals omarchy/ (diff -r, links
#              compared as links);
#            - every file in /opt/motanka/bin is a generated Wrapper;
#            - /usr/share/omarchy is a link to /opt/motanka/share/omarchy-view,
#              which has exactly one link per top-level entry of omarchy/,
#              each resolving inside the package tree;
#            - every autostart entry outside the vendored tree has an
#              OnlyShowIn key that names Motanka (5.8).
set -euo pipefail
export LC_ALL=C.UTF-8

readonly PKG=motanka-core
readonly D=debian/$PKG
readonly LX=opt/motanka/libexec/motanka
readonly VENDORED=opt/motanka/share/omarchy
readonly VIEW=opt/motanka/share/omarchy-view
readonly B=debian/build
readonly MARKER='# Motanka Wrapper for Upstream bin/'

log() {
  printf 'core-install: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

# inventory_file: compat/inventory/<commit of the stable pin>.tsv
inventory_file() {
  local commit
  commit=$(awk -F'\t' '$1 == "stable" { print $2; exit }' upstream.pin)
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || die "upstream.pin has no valid stable commit"
  printf 'compat/inventory/%s.tsv\n' "$commit"
}

check_inputs() {
  local f
  [[ -d omarchy/bin ]] || die "omarchy/bin is missing: the source package lacks its orig-omarchy component (packaging/build.sh adds it)"
  for f in src/motanka tools/pkgmap tools/genwrappers packages.yaml upstream.pin \
    compat/privileged.tsv compat/home-paths.tsv compat/migrations.tsv compat/user-scripts.tsv \
    keys/motanka-archive.asc; do
    [[ -f $f ]] || die "$f is missing (debian/../build-imports lists it)"
  done
  f=$(inventory_file)
  [[ -f $f ]] || die "$f, the Call_Inventory of the stable pin, is missing (run tools/inventory; build-imports lists compat/inventory/)"
}

# check_home_plan: every per-user setup target has a Home_Path_Class.
check_home_plan() {
  local unclassified
  if ! bash src/libexec/user-setup --plan --upstream omarchy --home-paths compat/home-paths.tsv \
    >"$B/home-plan.tsv" 2>"$B/home-plan.err"; then
    unclassified=$(awk -F'\t' '$1 == "unclassified" { print "  " $3 }' "$B/home-plan.tsv" | head -n 20)
    cat "$B/home-plan.err" >&2
    die "targets of Upstream's config/ tree without a Home_Path_Class in compat/home-paths.tsv:
$unclassified"
  fi
  log "per-user setup plan: $(wc -l <"$B/home-plan.tsv") targets, all classified"
}

# check_user_scripts: compat/user-scripts.tsv names exactly the scripts of
# Upstream's install/user/all.sh.
check_user_scripts() {
  local listed upstream missing extra
  [[ -f omarchy/install/user/all.sh ]] || die "omarchy/install/user/all.sh is missing"
  # shellcheck disable=SC2016 # matches the literal text $OMARCHY_INSTALL
  upstream=$(sed -n 's|^[[:space:]]*run_logged[[:space:]]*"\$OMARCHY_INSTALL/\(user/[^"]*\)".*|install/\1|p' \
    omarchy/install/user/all.sh | LC_ALL=C sort -u)
  listed=$(awk -F'\t' '$0 !~ /^#/ && NF >= 2 { print $1 }' compat/user-scripts.tsv | LC_ALL=C sort -u)
  missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$upstream") <(printf '%s\n' "$listed") | sed '/^$/d')
  extra=$(LC_ALL=C comm -13 <(printf '%s\n' "$upstream") <(printf '%s\n' "$listed") | sed '/^$/d')
  if [[ -n $missing || -n $extra ]]; then
    die "compat/user-scripts.tsv does not match omarchy/install/user/all.sh; review these scripts:
${missing:+  not listed: $(tr '\n' ' ' <<<"$missing")}
${extra:+  no longer in all.sh: $(tr '\n' ' ' <<<"$extra")}"
  fi
  log "compat/user-scripts.tsv lists all $(wc -l <<<"$upstream") per-user scripts of install/user/all.sh"
}

cmd_build() {
  local f name
  check_inputs
  rm -rf -- "$B"
  mkdir -p -- "$B"
  python3 tools/pkgmap compile "$SUITE" --map packages.yaml -o "$B/package-map.tsv"
  log "package-map.tsv for $SUITE: $(grep -vc '^#' "$B/package-map.tsv") entries"
  for f in omarchy/bin/*; do
    [[ -f $f ]] || continue
    name=${f##*/}
    if [[ $name != omarchy* ]]; then
      die "Upstream command bin/$name does not start with 'omarchy'; its Wrapper could take the name of a Stack program in /opt/motanka/bin"
    fi
  done
  bash tools/genwrappers omarchy "$B/wrappers"
  check_home_plan
  check_user_scripts
}

# install_view: the overlay /opt/motanka/share/omarchy-view.
install_view() {
  local e name n=0
  install -d -m 0755 "$D/$VIEW"
  while IFS= read -r -d '' e; do
    name=${e##*/}
    if [[ $name == bin ]]; then
      ln -s ../../bin "$D/$VIEW/bin"
    else
      ln -s "../omarchy/$name" "$D/$VIEW/$name"
    fi
    n=$((n + 1))
  done < <(find omarchy -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
  log "installed the overlay /$VIEW with $n links (bin -> /opt/motanka/bin)"
}

cmd_test() {
  local f first n=0
  while IFS= read -r -d '' f; do
    first=""
    IFS= read -r first <"$f" || true
    case $first in
      '#!/bin/bash'* | '#!/usr/bin/env bash'* | '# shellcheck shell=bash'*)
        bash -n "$f" || die "bash syntax error in $f"
        ;;
      '#!/bin/sh'*)
        sh -n "$f" || die "sh syntax error in $f"
        ;;
      *) continue ;;
    esac
    n=$((n + 1))
  done < <(find src debian -type f -print0 | LC_ALL=C sort -z)
  log "syntax checked $n shell files"
}

# install_tree <from> <to>: copies a folder of programs; files get 0755.
install_tree() {
  local from=$1 to=$2 f rel
  install -d -m 0755 "$D/$to"
  while IFS= read -r -d '' f; do
    rel=${f#"$from"/}
    if [[ -L $f ]]; then
      die "$f is a symbolic link; $from must hold regular files only"
    elif [[ -d $f ]]; then
      install -d -m 0755 "$D/$to/$rel"
    else
      install -m 0755 "$f" "$D/$to/$rel"
    fi
  done < <(find "$from" -mindepth 1 -print0 | LC_ALL=C sort -z)
}

is_release_build() {
  [[ " ${DEB_BUILD_PROFILES:-} " == *" pkg.motanka.release "* ]]
}

cmd_install() {
  local f n
  check_inputs
  [[ -d $B/wrappers && -f $B/package-map.tsv ]] || die "run the build step first"

  install -D -m 0755 src/motanka "$D/usr/bin/motanka"
  install -d -m 0755 "$D/$LX/lib" "$D/$LX/cmd" "$D/$LX/keys"
  for f in src/lib/*.sh; do
    install -m 0644 "$f" "$D/$LX/lib/"
  done
  for f in src/cmd/*.sh; do
    install -m 0644 "$f" "$D/$LX/cmd/"
  done
  for f in src/libexec/*; do
    [[ -f $f && ! -L $f ]] || die "$f is not a regular file"
    install -m 0755 "$f" "$D/$LX/"
  done
  install_tree src/shims "$LX/shims"
  install_tree src/overrides "$LX/overrides"
  install_tree src/compat-bin "$LX/compat-bin"

  grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' keys/motanka-archive.asc ||
    die "keys/motanka-archive.asc holds no public key block"
  if grep -q 'PRIVATE KEY' keys/motanka-archive.asc; then
    die "keys/motanka-archive.asc contains secret key material"
  fi
  install -m 0644 keys/motanka-archive.asc "$D/$LX/keys/"

  install -d -m 0755 "$D/opt/motanka/share"
  cp -a omarchy "$D/$VENDORED"
  install_view

  install -d -m 0755 "$D/opt/motanka/bin"
  n=0
  for f in "$B"/wrappers/*; do
    install -m 0755 "$f" "$D/opt/motanka/bin/"
    n=$((n + 1))
  done
  log "installed $n Wrappers"

  install -d -m 0755 "$D/opt/motanka/share/motanka"
  install -m 0644 "$(inventory_file)" "$D/opt/motanka/share/motanka/inventory.tsv"
  if is_release_build; then
    log "release build (profile pkg.motanka.release): no DEV_BUILD marker"
  else
    printf 'Development build of motanka-core, not from a published Motanka suite.\n' \
      >"$D/opt/motanka/share/motanka/DEV_BUILD"
    chmod 0644 "$D/opt/motanka/share/motanka/DEV_BUILD"
    log "development build: installed /opt/motanka/share/motanka/DEV_BUILD"
  fi
}

cmd_verify() {
  local f first second target writable bad=0
  if ! diff -r --no-dereference omarchy "$D/$VENDORED" >"$B/vendored.diff" 2>&1; then
    head -n 20 "$B/vendored.diff" >&2
    die "/$VENDORED differs from the vendored Upstream tree"
  fi
  log "/$VENDORED equals the vendored Upstream tree"
  writable=$(find "$D/$VENDORED" ! -type l -perm /022 -print)
  if [[ -n $writable ]]; then
    head -n 10 <<<"$writable" >&2
    die "files in /$VENDORED are writable by group or others; it must be read-only for users"
  fi

  for f in "$D"/opt/motanka/bin/*; do
    first="" second=""
    {
      IFS= read -r first || true
      IFS= read -r second || true
    } <"$f"
    if [[ -L $f || $first != '#!/bin/bash' || $second != "$MARKER"* ]]; then
      log "$f is not a generated Wrapper"
      bad=1
    fi
  done
  ((bad == 0)) || die "/opt/motanka/bin may hold only Wrappers"

  [[ -L $D/usr/share/omarchy ]] || die "/usr/share/omarchy is not a symbolic link"
  target=$(readlink -- "$D/usr/share/omarchy")
  if [[ $target != ../../$VIEW && $target != /$VIEW ]]; then
    die "/usr/share/omarchy points to $target, not /$VIEW"
  fi
  verify_view

  while IFS= read -r -d '' f; do
    if ! grep -Eq '^OnlyShowIn=([^#]*;)?Motanka(;|$)' "$f"; then
      log "autostart entry ${f#"$D"} has no OnlyShowIn key naming Motanka"
      bad=1
    fi
  done < <(find "$D" -path "$D/$VENDORED" -prune -o -path '*/autostart/*.desktop' -type f -print0)
  ((bad == 0)) || die "every autostart entry must carry OnlyShowIn=Motanka; (5.8)"
  log "package tree verified"
}

# verify_view: the overlay has one link per top-level entry of omarchy/:
# bin to ../../bin, every other entry to ../omarchy/<entry>, and each
# resolves inside the package tree.
verify_view() {
  local e name want got bad=0 n
  [[ -d $D/$VIEW && ! -L $D/$VIEW ]] || die "/$VIEW is missing"
  while IFS= read -r -d '' e; do
    name=${e##*/}
    if [[ $name == bin ]]; then
      want=../../bin
    else
      want=../omarchy/$name
    fi
    if [[ ! -L $D/$VIEW/$name ]]; then
      log "/$VIEW/$name is missing or not a link"
      bad=1
      continue
    fi
    got=$(readlink -- "$D/$VIEW/$name")
    if [[ $got != "$want" || ! -e $D/$VIEW/$name ]]; then
      log "/$VIEW/$name links to $got, expected $want (resolving inside the package)"
      bad=1
    fi
  done < <(find omarchy -mindepth 1 -maxdepth 1 -print0)
  n=$(find omarchy -mindepth 1 -maxdepth 1 | wc -l)
  if [[ $(find "$D/$VIEW" -mindepth 1 -maxdepth 1 | wc -l) != "$n" ]]; then
    log "/$VIEW has entries that are not top-level entries of the vendored tree"
    bad=1
  fi
  ((bad == 0)) || die "the overlay /$VIEW does not match the vendored tree"
  log "/$VIEW: $n links, bin -> /opt/motanka/bin"
}

main() {
  (($# == 2)) || die "usage: bash debian/core-install.sh <build|test|install|verify> <suite>"
  SUITE=$2
  case $SUITE in
    noble | resolute) ;;
    *) die "the changelog distribution must be noble or resolute (got '$SUITE'); build with packaging/build.sh" ;;
  esac
  case $1 in
    build) cmd_build ;;
    test) cmd_test ;;
    install) cmd_install ;;
    verify) cmd_verify ;;
    *) die "unknown step '$1'" ;;
  esac
}

main "$@"
