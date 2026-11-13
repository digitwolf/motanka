#!/usr/bin/env bash
# Build Motanka source packages for one suite with sbuild. Runs INSIDE a
# build VM provisioned by test/vm/build-provision.sh, as user tester;
# test/vm/build calls it. Never run it on a real machine.
#
# Usage: SOURCE_DATE_EPOCH=<seconds> \
#   bash packaging/build.sh --suite <noble|resolute> --out <dir> <package-dir>...
#
# For each package folder (one with debian/control):
#   1. copy it to <out>/.work/<source>/<source>-<version>/ and add the files
#      listed in its build-imports file (paths under packaging/);
#   2. stamp debian/changelog: the UNRELEASED top entry becomes
#      <source> (<version from packaging/version.sh>) <suite>, dated
#      SOURCE_DATE_EPOCH, so dpkg-buildpackage in the chroot derives the
#      same SOURCE_DATE_EPOCH;
#   3. make the orig tarball reproducibly (sorted, fixed owner and mtime)
#      and the source package with dpkg-source -b (format 3.0 (quilt): a
#      native package cannot carry the Debian revision of the version scheme);
#   4. sbuild in unshare mode with ~/.cache/sbuild/<suite>-amd64.tar.zst,
#      DEB_BUILD_MAINT_OPTIONS=hardening=+all (debian/rules must export it);
#   5. lintian on the .dsc and the .debs: errors fail the build, warnings
#      are printed;
#   6. tools/debcheck on the .debs.
# Results of passing builds go to <out>/; logs of every build go to
# <out>/logs/. Exit 1 if any package failed, 2 on a usage error.
set -euo pipefail
export LC_ALL=C.UTF-8

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
usage="packaging/build.sh --suite <noble|resolute> --out <dir> <package-dir>..."

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
import_files() {
  local pkgdir=$1 tree=$2 line
  [[ -f $pkgdir/build-imports ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    if [[ ! $line =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ || $line == *..* ]]; then
      log "invalid path '$line' in $pkgdir/build-imports"
      return 1
    fi
    if [[ ! -f $repo/packaging/$line ]]; then
      log "packaging/$line (from $pkgdir/build-imports) is missing"
      if [[ $line == keys/* ]]; then
        log "create the development key with chumak/gen-test-key on the host"
      fi
      return 1
    fi
    mkdir -p "$tree/$(dirname "$line")"
    cp -f "$repo/packaging/$line" "$tree/$line"
  done <"$pkgdir/build-imports"
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
  local pkgdir=$1 src first version upstream work base tree logs
  local -a debs
  if [[ ! -f $pkgdir/debian/control || ! -f $pkgdir/debian/changelog ]]; then
    log "$pkgdir has no debian/control or debian/changelog"
    return 1
  fi
  src=$(sed -n 's/^Source:[[:space:]]*//p' "$pkgdir/debian/control" | head -n 1)
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

  if ! tar -C "$work" --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner --mode=go-w,a+rX --format=gnu \
    --exclude="$base/debian" -cf - "$base" |
    xz -9 -T1 -c >"$work/${src}_$upstream.orig.tar.xz"; then
    log "could not create the orig tarball for $src"
    return 1
  fi
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
    --no-run-autopkgtest --build-dir="$work" "$dsc") \
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

  rc=0
  python3 "$repo/tools/debcheck" "${debs[@]}" >"$logs/$src.debcheck.log" 2>&1 || rc=$?
  if ((rc != 0)); then
    cat "$logs/$src.debcheck.log" >&2
    log "tools/debcheck failed for $src"
    return 1
  fi

  find "$work" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' \
    -o -name '*.changes' -o -name '*.buildinfo' -o -name '*.tar.*' \) \
    -exec mv -f {} "$out/" \;
  log "built $src: $(printf '%s ' "${debs[@]##*/}")"
}

suite=""
out=""
pkgs=()
while (($# > 0)); do
  case $1 in
    --suite | --out)
      if (($# < 2)); then
        die_usage "$1 needs a value"
      fi
      if [[ $1 == --suite ]]; then suite=$2; else out=$2; fi
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
