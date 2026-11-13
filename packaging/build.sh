#!/usr/bin/env bash
# Build Motanka source packages for one suite with sbuild. Runs INSIDE a
# build VM provisioned by test/vm/build-provision.sh, as user tester;
# test/vm/build calls it. Never run it on a real machine.
#
# Usage: SOURCE_DATE_EPOCH=<seconds> \
#   bash packaging/build.sh --suite <noble|resolute> --out <dir>
#                           [--orig-dir <dir>] <package-dir>...
#
# For each package folder (one with debian/control or debian/control.in):
#   1. copy it to <out>/.work/<source>/<source>-<version>/ and add the files
#      listed in its build-imports file (paths under packaging/, or under
#      the repository root when they start with '/');
#   2. stamp debian/changelog: the UNRELEASED top entry becomes
#      <source> (<version from packaging/version.sh>) <suite>, dated
#      SOURCE_DATE_EPOCH, so dpkg-buildpackage in the chroot derives the
#      same SOURCE_DATE_EPOCH;
#   3. if there is a debian/control.in, generate debian/control for the
#      suite: lines between "#if <suite>..." and "#endif" are kept only when
#      the suite is listed, the directive lines are dropped;
#   4. make the orig tarball reproducibly (sorted, fixed owner and mtime);
#      then copy every <source>_<upstream>.orig-<component>.tar.* found in
#      --orig-dir next to it and unpack it into <component>/ (dpkg-source
#      3.0 (quilt) multi-orig). A package that imports /stack/components.tsv
#      needs one such tarball per component listed there;
#   5. make the source package with dpkg-source -b (format 3.0 (quilt): a
#      native package cannot carry the Debian revision of the version scheme);
#   6. sbuild in unshare mode with ~/.cache/sbuild/<suite>-amd64.tar.zst,
#      DEB_BUILD_MAINT_OPTIONS=hardening=+all (debian/rules must export it),
#      plus the extra apt sources its sbuild-repos file lists for the suite
#      (build time only);
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
usage="packaging/build.sh --suite <noble|resolute> --out <dir> [--orig-dir <dir>] <package-dir>..."

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
# with '/'; it lands at the same relative path in the tree.
import_files() {
  local pkgdir=$1 tree=$2 line base rel
  [[ -f $pkgdir/build-imports ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    if [[ $line == /* ]]; then
      base=$repo
      rel=${line#/}
    else
      base=$repo/packaging
      rel=$line
    fi
    if [[ ! $rel =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ || $rel == *..* ]]; then
      log "invalid path '$line' in $pkgdir/build-imports"
      return 1
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
  if [[ -f $tree/stack/components.tsv ]]; then
    while IFS=$'\t' read -r name _; do
      [[ -z $name || $name == \#* ]] && continue
      if [[ ! " ${found[*]} " == *" $name "* ]]; then
        missing+=("$name")
      fi
    done <"$tree/stack/components.tsv"
    if ((${#missing[@]} > 0)); then
      log "no ${src}_$upstream.orig-<component> tarball in '${orig_dir:-(no --orig-dir)}' for: ${missing[*]}"
      log "run stack/fetch-sources (test/vm/build does it) and pass --orig-dir"
      return 1
    fi
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
  local pkgdir=$1 src first version upstream work base tree logs control f
  local -a debs checked
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

  if ! tar -C "$work" --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner --mode=go-w,a+rX --format=gnu \
    --exclude="$base/debian" -cf - "$base" |
    xz -9 -T1 -c >"$work/${src}_$upstream.orig.tar.xz"; then
    log "could not create the orig tarball for $src"
    return 1
  fi
  unpack_components "$src" "$upstream" "$work" "$tree" || return 1
  sbuild_repo_args "$pkgdir" "$suite" || return 1
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
    --no-run-autopkgtest --build-dir="$work" "${SBUILD_REPO_ARGS[@]}" "$dsc") \
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
SBUILD_REPO_ARGS=()
while (($# > 0)); do
  case $1 in
    --suite | --out | --orig-dir)
      if (($# < 2)); then
        die_usage "$1 needs a value"
      fi
      case $1 in
        --suite) suite=$2 ;;
        --out) out=$2 ;;
        --orig-dir) orig_dir=$2 ;;
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
