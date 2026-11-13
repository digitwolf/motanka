#!/usr/bin/env bash
# Spike S1: pack /opt/motanka from a build VM into a runtime tarball.
# Runs INSIDE the build VM after build-stack.sh. Writes ~/s1/stack-<codename>.tar.zst
# and ~/s1/runtime-deps-<codename>.txt (archive packages the runtime needs).
set -euo pipefail
[[ $(systemd-detect-virt) != none ]] || {
  echo "refusing to run outside a VM" >&2
  exit 7
}
# shellcheck disable=SC1091
. /etc/os-release
PREFIX=/opt/motanka
OUT=$HOME/s1
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

sudo apt-get install -y -q zstd binutils >/dev/null 2>&1 || true
cp -a "$PREFIX/." "$STAGE/"
rm -rf "$STAGE/include" "$STAGE/lib/pkgconfig" "$STAGE/share/pkgconfig" "$STAGE/lib/cmake" \
  "$STAGE/share/man" "$STAGE/share/doc" "$STAGE/share/aclocal"
find "$STAGE" -name '*.a' -delete
find "$STAGE" -name '*.la' -delete

# The system C++ runtime of the target release may be older than GCC 16's.
# Ship GCC 16's libstdc++ and libgcc_s where the release lacks GLIBCXX_3.4.35.
if [[ $VERSION_CODENAME == noble ]]; then
  for lib in libstdc++.so.6 libgcc_s.so.1; do
    src=$(readlink -f "/usr/lib/x86_64-linux-gnu/$lib")
    install -m644 "$src" "$STAGE/lib/$lib"
  done
fi

# Strip debug info from ELF files.
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q '^ELF'; then strip --strip-debug "$f" 2>/dev/null || true; fi
done < <(find "$STAGE" -type f -print0)

# Archive packages the runtime needs: system libraries the ELF files link to.
: >"$OUT/libs.tmp"
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q '^ELF' || continue
  ldd "$f" 2>/dev/null | awk '$3 ~ /^\// { print $3 }' >>"$OUT/libs.tmp" || true
done < <(find "$PREFIX" -type f -print0)
sort -u "$OUT/libs.tmp" | grep -v "^$PREFIX/" | while read -r l; do
  dpkg -S "$(readlink -f "$l")" 2>/dev/null || dpkg -S "$l" 2>/dev/null || echo "UNOWNED: $l"
done | cut -d: -f1 | sort -u >"$OUT/runtime-deps-$VERSION_CODENAME.txt"
# GCC 16 runtime packages come from the PPA on noble and are bundled instead.
if [[ $VERSION_CODENAME == noble ]]; then
  sed -i -e '/^libstdc++6$/d' -e '/^libgcc-s1$/d' "$OUT/runtime-deps-$VERSION_CODENAME.txt"
fi
rm -f "$OUT/libs.tmp"

tar -C "$STAGE" --owner=0 --group=0 -I 'zstd -19 -T0' -cf "$OUT/stack-$VERSION_CODENAME.tar.zst" .
echo "packed: $(du -h "$OUT/stack-$VERSION_CODENAME.tar.zst" | cut -f1) compressed, $(du -sh "$STAGE" | cut -f1) installed"
echo "runtime deps: $(wc -l <"$OUT/runtime-deps-$VERSION_CODENAME.txt") packages"
