#!/usr/bin/env bash
# Build Motanka source packages for one suite with sbuild. Runs INSIDE a
# build VM provisioned by test/vm/build-provision.sh, as user tester;
# test/vm/build calls it. Never run it on a real machine.
#
# Usage: SOURCE_DATE_EPOCH=<seconds> \
#   bash packaging/build.sh --suite <noble|resolute> --out <dir>
#                           [--orig-dir <dir>] [--extra-debs <dir>]...
#                           <package-dir>...
#
# Packages are built in the order given. For each package folder (one with
# debian/control or debian/control.in):
#   0. if the folder has a suites file (suite names, '#' comments) that does
#      not list <suite>, skip it with its first comment as the reason; a
#      skipped package is not a failure;
#   1. copy it to <out>/.work/<source>/<source>-<version>/ and add the files
#      listed in its build-imports file (paths under packaging/, or under
#      the repository root when they start with '/'; a path ending in '/'
#      copies that folder with everything below it);
#   2. stamp debian/changelog: the UNRELEASED top entry becomes
#      <source> (<version from packaging/version.sh>) <suite>, dated
#      SOURCE_DATE_EPOCH, so dpkg-buildpackage in the chroot derives the
#      same SOURCE_DATE_EPOCH;
#   3. if there is a debian/control.in, generate debian/control for the
#      suite: lines between "#if <suite>..." and "#endif" are kept only when
#      the suite is listed, the directive lines are dropped. If the package
#      has a debian/pkgmap-depends file (Upstream package names), the line
#      "@PKGMAP_DEPENDS@" in debian/control becomes one line per apt or
#      motanka outcome of those names for the suite (tools/pkgmap compile
#      of the package's imported packages.yaml);
#   4. make the orig tarball reproducibly (sorted, fixed owner and mtime);
#      then copy every <source>_<upstream>.orig-<component>.tar.* found in
#      --orig-dir next to it and unpack it into <component>/ (dpkg-source
#      3.0 (quilt) multi-orig). A package that imports a components file
#      (/stack/*components.tsv) needs one such tarball per component listed
#      there. A package that imports /upstream.pin needs the component
#      omarchy, the Upstream tarball (tools/fetch-upstream makes it); it is
#      unpacked by tools/vendor, which first checks it against the stable
#      pin (7.1);
#   5. make the source package with dpkg-source -b (format 3.0 (quilt): a
#      native package cannot carry the Debian revision of the version scheme);
#   6. sbuild in unshare mode with ~/.cache/sbuild/<suite>-amd64.tar.zst,
#      DEB_BUILD_MAINT_OPTIONS=hardening=+all (debian/rules must export it),
#      plus the extra apt sources its sbuild-repos file lists for the suite
#      and, through sbuild --extra-package, the locally built Motanka .debs
#      its sbuild-local file lists for the suite (lines "<suite> <binary
#      package>..."). Each one must be <name>_<version>_{amd64,all}.deb of
#      the version being built, found in <out> (built earlier in this run)
#      or in a --extra-debs folder. Both are build time only;
#   7. lintian on the .dsc and the .debs: errors fail the build, warnings
#      are printed;
#   8. tools/debcheck on the .debs except -dbgsym packages (their files are
#      under /usr/lib/debug by definition).
# Results of passing builds go to <out>/ (.deb, .ddeb, .dsc, .changes,
# .buildinfo, tarballs); logs of every build go to <out>/logs/. Exit 1 if
# any package failed, 2 on a usage error.
set -euo pipefail
export LC_ALL=C.UTF-8

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
usage="packaging/build.sh --suite <noble|resolute> --out <dir> [--orig-dir <dir>] [--extra-debs <dir>]... <package-dir>..."

log() {
  printf 'build.sh: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

die_usage() {
  log "$1"
  printf 'usage: %s\n' "$usage" >&2
  exit 2
}

guard() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -z $virt || $virt == none ]]; then
    die "refusing to run outside a VM (systemd-detect-virt: ${virt:-unavailable}); use test/vm/build"
  fi
  if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
    die "refusing to run on a Protected_Host"
  fi
}

# import_files <pkgdir> <tree>: copies the files named in <pkgdir>/build-imports.
# A path is relative to packaging/, or to the repository root if it starts
# with '/'; it lands at the same relative path in the tree. A path ending in
# '/' names a folder, which is copied with everything below it.
import_files() {
  local pkgdir=$1 tree=$2 line base rel folder
  [[ -f $pkgdir/build-imports ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    folder=0
    if [[ $line == ?*/ ]]; then
      folder=1
    fi
    if [[ $line == /* ]]; then
      base=$repo
      rel=${line#/}
    else
      base=$repo/packaging
      rel=$line
    fi
    rel=${rel%/}
    if [[ ! $rel =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ || $rel == *..* ]]; then
      log "invalid path '$line' in $pkgdir/build-imports"
      return 1
    fi
    if ((folder)); then
      if [[ ! -d $base/$rel || -L $base/$rel ]]; then
        log "${base#"$repo"/}/$rel/ (from $pkgdir/build-imports) is not a folder"
        return 1
      fi
      if [[ -e $tree/$rel ]]; then
        log "$rel/ (from $pkgdir/build-imports) clashes with $rel in the package folder"
        return 1
      fi
      mkdir -p "$tree/$rel"
      cp -R -- "$base/$rel/." "$tree/$rel/" || return 1
      continue
    fi
    if [[ ! -f $base/$rel ]]; then
      log "${base#"$repo"/}/$rel (from $pkgdir/build-imports) is missing"
      if [[ $rel == keys/* ]]; then
        log "create the development key with chumak/gen-test-key on the host"
      fi
      return 1
    fi
    mkdir -p "$tree/$(dirname "$rel")"
    cp -f "$base/$rel" "$tree/$rel"
  done <"$pkgdir/build-imports"
}

# gen_control <control.in> <control> <suite>: keeps the lines of
# "#if <suite> [<suite>...]" ... "#endif" blocks only for listed suites.
gen_control() {
  awk -v suite="$3" -v file="$1" '
    /^#if([ \t]|$)/ {
      if (inblk) { printf "%s:%d: nested #if\n", file, NR > "/dev/stderr"; bad = 1; exit 1 }
      inblk = 1; keep = 0
      for (i = 2; i <= NF; i++) if ($i == suite) keep = 1
      next
    }
    /^#endif[ \t]*$/ {
      if (!inblk) { printf "%s:%d: #endif without #if\n", file, NR > "/dev/stderr"; bad = 1; exit 1 }
      inblk = 0
      next
    }
    !inblk || keep { print }
    END {
      if (!bad && inblk) { printf "%s: #if without #endif\n", file > "/dev/stderr"; exit 1 }
    }
  ' "$1" >"$2.new" && mv -f "$2.new" "$2"
}

# pkgmap_depends <tree> <suite>: when <tree>/debian/pkgmap-depends exists,
# replaces the line "@PKGMAP_DEPENDS@" (optionally followed by a comma) of
# <tree>/debian/control with the suite's apt or motanka outcomes of the
# Upstream package names listed there, one "         <name>," line each,
# sorted and without duplicates. A name without an entry, or with a skip,
# flatpak or binary outcome, fails the build.
pkgmap_depends() {
  local tree=$1 s=$2 list=$1/debian/pkgmap-depends control=$1/debian/control map line kind targets
  local -a names=() deps=() t=()
  [[ -f $list ]] || return 0
  map=$tree/packages.yaml
  [[ -f $map ]] || map=$repo/packages.yaml
  if ! grep -Eq '^[[:space:]]*@PKGMAP_DEPENDS@,?[[:space:]]*$' "$control"; then
    log "$list exists, but debian/control has no @PKGMAP_DEPENDS@ line"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    if [[ -n $line ]]; then
      names+=("$line")
    fi
  done <"$list"
  if ! python3 "$repo/tools/pkgmap" compile "$s" --map "$map" -o "$tree/debian/pkgmap-depends.tsv"; then
    log "tools/pkgmap could not compile $map for $s"
    return 1
  fi
  for line in "${names[@]}"; do
    kind=$(awk -F'\t' -v n="$line" '$1 == n { print $2 "\t" $3; exit }' "$tree/debian/pkgmap-depends.tsv")
    targets=${kind#*$'\t'}
    kind=${kind%%$'\t'*}
    case $kind in
      apt | motanka) ;;
      "")
        log "debian/pkgmap-depends: $line has no entry in $map"
        return 1
        ;;
      *)
        log "debian/pkgmap-depends: $line has the outcome '$kind' on $s; only apt and motanka outcomes can be Depends"
        return 1
        ;;
    esac
    IFS=, read -r -a t <<<"$targets"
    deps+=("${t[@]}")
  done
  rm -f -- "$tree/debian/pkgmap-depends.tsv"
  : >"$tree/debian/pkgmap-depends.lines"
  if ((${#deps[@]} > 0)); then
    printf '%s\n' "${deps[@]}" | LC_ALL=C sort -u |
      awk 'NF { printf "         %s,\n", $0 }' >"$tree/debian/pkgmap-depends.lines"
  fi
  awk -v f="$tree/debian/pkgmap-depends.lines" '
    /^[[:space:]]*@PKGMAP_DEPENDS@,?[[:space:]]*$/ { while ((getline l < f) > 0) print l; next }
    { print }
  ' "$control" >"$control.new" && mv -f "$control.new" "$control"
  rm -f -- "$tree/debian/pkgmap-depends.lines"
  log "Depends from packages.yaml for $s: ${deps[*]:-none}"
}

# unpack_components <src> <upstream> <work> <tree>: copies the orig
# component tarballs of the source package from $orig_dir into <work> and
# unpacks each into <tree>/<component>, as dpkg-source -x would.
unpack_components() {
  local src=$1 upstream=$2 work=$3 tree=$4 f comp name
  local -a found=() missing=()
  if [[ -n $orig_dir ]]; then
    shopt -s nullglob
    for f in "$orig_dir/${src}_$upstream.orig-"*.tar.{gz,xz,bz2}; do
      comp=${f##*/}
      comp=${comp#"${src}_$upstream.orig-"}
      comp=${comp%.tar.*}
      if [[ ! $comp =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        log "invalid component name '$comp' in ${f##*/}"
        shopt -u nullglob
        return 1
      fi
      if [[ -e $tree/$comp ]]; then
        log "component $comp clashes with $comp/ in the package folder"
        shopt -u nullglob
        return 1
      fi
      cp -f "$f" "$work/" || return 1
      if [[ $comp == omarchy && -f $tree/upstream.pin ]]; then
        # The vendored Upstream: tools/vendor refuses a tarball whose
        # SHA-256 differs from the stable pin and unpacks it unchanged.
        if ! bash "$repo/tools/vendor" --pin "$tree/upstream.pin" --tarball "$f" stable "$tree/$comp"; then
          log "tools/vendor refused ${f##*/} for the stable pin in upstream.pin"
          shopt -u nullglob
          return 1
        fi
        found+=("$comp")
        continue
      fi
      mkdir "$tree/$comp" || return 1
      if ! tar -C "$tree/$comp" --strip-components=1 --no-same-owner -xf "$f"; then
        log "could not unpack ${f##*/}"
        shopt -u nullglob
        return 1
      fi
      found+=("$comp")
    done
    shopt -u nullglob
  fi
  if [[ -f $tree/upstream.pin && ! " ${found[*]} " == *" omarchy "* ]]; then
    log "no ${src}_$upstream.orig-omarchy.tar.gz in '${orig_dir:-(no --orig-dir)}'"
    log "run tools/fetch-upstream (test/vm/build does it) and pass --orig-dir"
    return 1
  fi
  shopt -s nullglob
  local -a tsvs=("$tree"/stack/*components.tsv)
  shopt -u nullglob
  for f in "${tsvs[@]}"; do
    while IFS=$'\t' read -r name _; do
      [[ -z $name || $name == \#* ]] && continue
      if [[ ! " ${found[*]} " == *" $name "* ]]; then
        missing+=("$name")
      fi
    done <"$f"
  done
  if ((${#missing[@]} > 0)); then
    log "no ${src}_$upstream.orig-<component> tarball in '${orig_dir:-(no --orig-dir)}' for: ${missing[*]}"
    log "run stack/fetch-sources --components <file> (test/vm/build does it) and pass --orig-dir"
    return 1
  fi
  if ((${#found[@]} > 0)); then
    log "$src: ${#found[@]} orig components"
  fi
}

# sbuild_repo_args <pkgdir> <suite>: fills SBUILD_REPO_ARGS from the
# package's sbuild-repos file (<suite> <key under packaging/> <apt line>).
sbuild_repo_args() {
  local pkgdir=$1 s=$2 rsuite key line
  SBUILD_REPO_ARGS=()
  [[ -f $pkgdir/sbuild-repos ]] || return 0
  while read -r rsuite key line || [[ -n $rsuite ]]; do
    [[ -z $rsuite || $rsuite == \#* ]] && continue
    [[ $rsuite == "$s" ]] || continue
    if [[ ! $key =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ || $key == *..* || ! -f $repo/packaging/$key ]]; then
      log "$pkgdir/sbuild-repos: key file packaging/$key is missing or invalid"
      return 1
    fi
    if [[ ! $line =~ ^deb\ [a-z]+:// ]]; then
      log "$pkgdir/sbuild-repos: invalid apt source '$line'"
      return 1
    fi
    SBUILD_REPO_ARGS+=("--extra-repository=$line" "--extra-repository-key=$repo/packaging/$key")
    log "extra build-time source for $s: $line"
  done <"$pkgdir/sbuild-repos"
}

# local_deb_args <pkgdir> <src> <suite> <version>: fills SBUILD_LOCAL_ARGS
# from the package's sbuild-local file (<suite> <binary package>...).
local_deb_args() {
  local pkgdir=$1 src=$2 s=$3 version=$4 rsuite rest name d f found
  local -a names
  SBUILD_LOCAL_ARGS=()
  [[ -f $pkgdir/sbuild-local ]] || return 0
  while read -r rsuite rest || [[ -n $rsuite ]]; do
    [[ -z $rsuite || $rsuite == \#* ]] && continue
    [[ $rsuite == "$s" ]] || continue
    rest=${rest%%#*}
    read -r -a names <<<"$rest"
    for name in "${names[@]}"; do
      if [[ ! $name =~ ^motanka(-[a-z0-9][a-z0-9+.-]*)?$ ]]; then
        log "$pkgdir/sbuild-local: '$name' is not a Motanka package name"
        return 1
      fi
      found=""
      for d in "$out" "${extra_debs[@]}"; do
        for f in "$d/${name}_${version}_amd64.deb" "$d/${name}_${version}_all.deb"; do
          if [[ -f $f ]]; then
            found=$f
            break 2
          fi
        done
      done
      if [[ -z $found ]]; then
        log "$src needs ${name}_${version}_amd64.deb for $s, which is neither built earlier in this run nor in --extra-debs (${extra_debs[*]:-none given})"
        log "build the source package that makes $name for $s first, or name it before $src"
        return 1
      fi
      SBUILD_LOCAL_ARGS+=("--extra-package=$found")
      log "local build dependency for $s: ${found##*/}"
    done
  done <"$pkgdir/sbuild-local"
}

# skip_reason <pkgdir> <suite>: prints why the package is not built for the
# suite and returns 0, or returns 1 if it is built.
skip_reason() {
  local pkgdir=$1 s=$2 line word reason="" listed=""
  local -a words
  [[ -f $pkgdir/suites ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^#[[:space:]]*(.*)$ ]]; then
      if [[ -z $reason ]]; then
        reason=${BASH_REMATCH[1]}
      fi
      continue
    fi
    read -r -a words <<<"${line%%#*}"
    for word in "${words[@]}"; do
      if [[ $word == "$s" ]]; then
        return 1
      fi
      listed+=" $word"
    done
  done <"$pkgdir/suites"
  printf 'built for%s only%s\n' "${listed:- no suite}" "${reason:+: $reason}"
}

# stamp_changelog <file> <source> <version> <suite>
stamp_changelog() {
  local file=$1 src=$2 version=$3 suite=$4 date
  date=$(LC_ALL=C date -u -R -d "@$SOURCE_DATE_EPOCH")
  awk -v hdr="$src ($version) $suite; urgency=medium" -v date="$date" '
    NR == 1 { print hdr; next }
    !done && /^ -- / { sub(/>  .*$/, ">  " date); print; done = 1; next }
    { print }
  ' "$file" >"$file.new"
  mv -f "$file.new" "$file"
}

# build_one <package-dir>: returns non-zero if the package failed.
build_one() {
  local pkgdir=$1 src first version upstream work base tree logs control f why
  local -a debs checked
  if why=$(skip_reason "$pkgdir" "$suite"); then
    log "skipping ${pkgdir##*/} for $suite: $why ($pkgdir/suites)"
    return 0
  fi
  control=$pkgdir/debian/control
  if [[ ! -f $control && -f $pkgdir/debian/control.in ]]; then
    control=$pkgdir/debian/control.in
  fi
  if [[ ! -f $control || ! -f $pkgdir/debian/changelog ]]; then
    log "$pkgdir has no debian/control (or control.in) or debian/changelog"
    return 1
  fi
  src=$(sed -n 's/^Source:[[:space:]]*//p' "$control" | head -n 1)
  if [[ ! $src =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
    log "$pkgdir/debian/control has no valid Source field"
    return 1
  fi
  IFS= read -r first <"$pkgdir/debian/changelog"
  if [[ ! $first =~ ^$src\ \([^\)]+\)\ UNRELEASED\; ]]; then
    log "$pkgdir/debian/changelog must start with an UNRELEASED entry for $src, found: $first"
    return 1
  fi
  if ! grep -Eq '^export DEB_BUILD_MAINT_OPTIONS[[:space:]]*\??=[[:space:]]*hardening=\+all' "$pkgdir/debian/rules"; then
    log "$pkgdir/debian/rules must export DEB_BUILD_MAINT_OPTIONS = hardening=+all"
    return 1
  fi

  version=$(bash "$here/version.sh" "$suite") || return 1
  upstream=${version%%-*}
  work=$out/.work/$src
  base=$src-$upstream
  tree=$work/$base
  logs=$out/logs
  log "$src $version for $suite"
  rm -rf -- "$work"
  mkdir -p "$tree" "$logs" || return 1
  cp -a "$pkgdir/." "$tree/" || return 1
  rm -rf -- "$tree/debian/build"
  # The repository copy may have lost the executable bit.
  chmod 0755 "$tree/debian/rules" || return 1
  import_files "$pkgdir" "$tree" || return 1
  stamp_changelog "$tree/debian/changelog" "$src" "$version" "$suite" || return 1
  if [[ -f $tree/debian/control.in ]]; then
    if ! gen_control "$tree/debian/control.in" "$tree/debian/control" "$suite"; then
      log "could not generate debian/control for $src ($suite)"
      return 1
    fi
    rm -f -- "$tree/debian/control.in"
  fi
  pkgmap_depends "$tree" "$suite" || return 1

  if ! tar -C "$work" --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner --mode=go-w,a+rX --format=gnu \
    --exclude="$base/debian" -cf - "$base" |
    xz -9 -T1 -c >"$work/${src}_$upstream.orig.tar.xz"; then
    log "could not create the orig tarball for $src"
    return 1
  fi
  unpack_components "$src" "$upstream" "$work" "$tree" || return 1
  sbuild_repo_args "$pkgdir" "$suite" || return 1
  local_deb_args "$pkgdir" "$src" "$suite" "$version" || return 1
  if ! (cd "$work" && dpkg-source -b "$base") >"$logs/$src.source.log" 2>&1; then
    cat "$logs/$src.source.log" >&2
    log "dpkg-source failed for $src"
    return 1
  fi
  local dsc=$work/${src}_$version.dsc
  [[ -f $dsc ]] || {
    log "dpkg-source produced no $dsc"
    return 1
  }

  log "sbuild $src for $suite (log: $logs/$src.sbuild.log)"
  if ! (cd "$work" && DEB_BUILD_MAINT_OPTIONS=hardening=+all sbuild \
    --chroot-mode=unshare --chroot="$suite-amd64" --dist="$suite" --arch=amd64 \
    --arch-all --arch-any --no-run-lintian --no-run-piuparts \
    --no-run-autopkgtest --build-dir="$work" "${SBUILD_REPO_ARGS[@]}" \
    "${SBUILD_LOCAL_ARGS[@]}" "$dsc") \
    >"$logs/$src.sbuild.log" 2>&1; then
    find "$work" -maxdepth 1 -type f -name '*.build' -exec cp -f {} "$logs/" \;
    tail -n 60 "$logs/$src.sbuild.log" >&2
    log "sbuild failed for $src"
    return 1
  fi
  find "$work" -maxdepth 1 -type f -name '*.build' -exec cp -f {} "$logs/" \;

  mapfile -t debs < <(find "$work" -maxdepth 1 -type f -name '*.deb' | LC_ALL=C sort)
  if ((${#debs[@]} == 0)); then
    log "sbuild produced no .deb for $src"
    return 1
  fi

  local rc=0
  lintian --fail-on error "$dsc" "${debs[@]}" >"$logs/$src.lintian.log" 2>&1 || rc=$?
  if [[ -s $logs/$src.lintian.log ]]; then
    log "lintian output for $src:"
    sed 's/^/  /' "$logs/$src.lintian.log" >&2
  fi
  if ((rc != 0)); then
    log "lintian reported errors for $src (exit $rc)"
    return 1
  fi

  checked=()
  for f in "${debs[@]}"; do
    if [[ ${f##*/} != *-dbgsym_* ]]; then
      checked+=("$f")
    fi
  done
  rc=0
  python3 "$repo/tools/debcheck" "${checked[@]}" >"$logs/$src.debcheck.log" 2>&1 || rc=$?
  if ((rc != 0)); then
    cat "$logs/$src.debcheck.log" >&2
    log "tools/debcheck failed for $src"
    return 1
  fi

  find "$work" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.ddeb' -o -name '*.dsc' \
    -o -name '*.changes' -o -name '*.buildinfo' -o -name '*.tar.*' \) \
    -exec mv -f {} "$out/" \;
  log "built $src: $(printf '%s ' "${debs[@]##*/}")"
}

suite=""
out=""
orig_dir=""
pkgs=()
extra_debs=()
SBUILD_REPO_ARGS=()
SBUILD_LOCAL_ARGS=()
while (($# > 0)); do
  case $1 in
    --suite | --out | --orig-dir | --extra-debs)
      if (($# < 2)); then
        die_usage "$1 needs a value"
      fi
      case $1 in
        --suite) suite=$2 ;;
        --out) out=$2 ;;
        --orig-dir) orig_dir=$2 ;;
        --extra-debs) extra_debs+=("$2") ;;
      esac
      shift 2
      ;;
    -h | --help)
      printf 'usage: %s\n' "$usage"
      exit 0
      ;;
    -*) die_usage "unknown option '$1'" ;;
    *)
      pkgs+=("$1")
      shift
      ;;
  esac
done
case $suite in
  noble | resolute) ;;
  *) die_usage "--suite must be noble or resolute" ;;
esac
if [[ -z $out ]]; then
  die_usage "--out is required"
fi
if ((${#pkgs[@]} == 0)); then
  die_usage "no package folder given"
fi
if [[ ! ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]]; then
  die_usage "SOURCE_DATE_EPOCH must be set to a number of seconds"
fi
export SOURCE_DATE_EPOCH
guard
for tool in sbuild dpkg-source lintian xz python3; do
  command -v "$tool" >/dev/null || die "$tool is missing; run test/vm/build-provision.sh first"
done
if [[ ! -s $HOME/.cache/sbuild/$suite-amd64.tar.zst ]]; then
  die "no chroot $HOME/.cache/sbuild/$suite-amd64.tar.zst; run test/vm/build-provision.sh $suite"
fi
mkdir -p "$out/logs"
out=$(cd "$out" && pwd)
if [[ -n $orig_dir ]]; then
  if [[ ! -d $orig_dir ]]; then
    die_usage "--orig-dir $orig_dir is not a folder"
  fi
  orig_dir=$(cd "$orig_dir" && pwd)
fi
for i in "${!extra_debs[@]}"; do
  if [[ ! -d ${extra_debs[$i]} ]]; then
    die_usage "--extra-debs ${extra_debs[$i]} is not a folder"
  fi
  extra_debs[i]=$(cd "${extra_debs[$i]}" && pwd)
done

failed=()
for p in "${pkgs[@]}"; do
  if [[ ! -d $p ]]; then
    log "no such folder: $p"
    failed+=("$p")
    continue
  fi
  p=$(cd "$p" && pwd)
  if ! build_one "$p"; then
    failed+=("$(basename "$p")")
  fi
done
rm -rf -- "$out/.work"
if ((${#failed[@]} > 0)); then
  log "FAILED for $suite: ${failed[*]}"
  exit 1
fi
log "all packages built for $suite"
