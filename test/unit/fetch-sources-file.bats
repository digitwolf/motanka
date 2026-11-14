#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for the components of build "file" in stack/fetch-sources
# (task 26.1; requirements 7.2, 7.3, 8.1): one file, pinned by SHA-256, is
# downloaded into DIR/downloads/<name>-<version>.<file name> and packed
# into the reproducible orig component <source>_<V>.orig-<name>.tar.gz with
# the top folder <name>/. The download function is replaced by a copy from
# a local folder, so nothing leaves the VM.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  FETCH="$REPO/stack/fetch-sources"
  T=$BATS_TEST_TMPDIR
  OUT=$T/out
  SRV=$T/srv
  ORIG_TGZ=$OUT/orig/motanka-test_1.0.0.orig-tool.tar.gz
  mkdir -p "$SRV"
  # The "release binary": an ELF header and some bytes, mode 0755 on the
  # server, so the test sees that the tarball holds it as 0644.
  printf '\177ELF\002\001\001\000payload\n' >"$SRV/tool-linux-x86_64"
  chmod 0755 "$SRV/tool-linux-x86_64"
}

# sha <file>: its SHA-256.
sha() {
  sha256sum <"$1" | cut -c1-64
}

# tsv [<sha256>] [<url>]: $T/c.tsv with the file component tool 2.0.0
# (default: the served file's SHA-256 and .../download/v2.0.0/tool-linux-x86_64).
tsv() {
  local digest=${1:-$(sha "$SRV/tool-linux-x86_64")}
  local url=${2:-https://example.test/download/v2.0.0/tool-linux-x86_64}
  printf '#@source motanka-test\n#@packages motanka-test\n# name\tversion\turl\tsha256\tbuild\tsuites\tpackage\ntool\t2.0.0\t%s\t%s\tfile\tboth\tmotanka-test\n' \
    "$url" "$digest" >"$T/c.tsv"
}

# fetch: runs fetch-sources' main with download() copying <URL basename>
# from $SRV.
fetch() {
  run python3 - "$FETCH" "$SRV" --components "$T/c.tsv" --out "$OUT" --version 1.0.0 <<'EOF'
import importlib.machinery, importlib.util, os, shutil, sys
loader = importlib.machinery.SourceFileLoader("fetch_sources", sys.argv[1])
spec = importlib.util.spec_from_loader("fetch_sources", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
srv = sys.argv[2]

def download(url, dest):
    src = os.path.join(srv, url.rsplit("/", 1)[-1])
    if not os.path.exists(src):
        raise OSError(f"download of {url} failed: no {src}")
    shutil.copyfile(src, dest)

mod.download = download
sys.exit(mod.main(sys.argv[3:]))
EOF
}

# check_meta <tarball>: prints "ok" if the gzip header has mtime 0 and no
# file name, and every member has mtime 0, owner and group 0 with empty
# names, folders 0755 and files 0644, sorted by path.
check_meta() {
  python3 - "$1" <<'EOF'
import sys, tarfile
with open(sys.argv[1], "rb") as f:
    head = f.read(10)
assert head[:2] == b"\x1f\x8b", "not gzip"
assert head[3] & 0x08 == 0, "the gzip header has a file name"
assert head[4:8] == b"\0\0\0\0", "the gzip header mtime is not 0"
names = []
with tarfile.open(sys.argv[1], "r:gz") as tar:
    for m in tar:
        assert (m.mtime, m.uid, m.gid, m.uname, m.gname) == (0, 0, 0, "", ""), m.name
        assert m.isdir() or m.isfile(), m.name
        assert m.mode == (0o755 if m.isdir() else 0o644), (m.name, oct(m.mode))
        names.append(m.name.rstrip("/").split("/"))
assert names == sorted(names), "members are not sorted by path"
print("ok")
EOF
}

@test "a file component is downloaded under its file name and packed below the top folder <name>/" {
  tsv
  fetch
  assert_success
  assert_equal "${lines[-1]}" "$OUT/orig"
  assert_output --partial 'tool: tool-linux-x86_64 packed into motanka-test_1.0.0.orig-tool.tar.gz'
  [[ -f $OUT/downloads/tool-2.0.0.tool-linux-x86_64 ]] || fail "the download is not in downloads/<name>-<version>.<file name>"
  run tar -tzf "$ORIG_TGZ"
  assert_success
  assert_output "$(printf '%s\n' tool/ tool/tool-linux-x86_64)"
  tar -xzOf "$ORIG_TGZ" tool/tool-linux-x86_64 >"$T/got"
  run cmp "$SRV/tool-linux-x86_64" "$T/got"
  assert_success
  run ls "$OUT/orig"
  assert_output motanka-test_1.0.0.orig-tool.tar.gz
}

@test "two runs write byte-identical file tarballs with fixed metadata and mode 0644" {
  tsv
  fetch
  assert_success
  cp "$ORIG_TGZ" "$T/first.tar.gz"
  rm -rf "$OUT/orig" "$OUT/downloads"
  fetch
  assert_success
  run cmp "$T/first.tar.gz" "$ORIG_TGZ"
  assert_success
  run check_meta "$ORIG_TGZ"
  assert_output ok
}

@test "a cached file with the pinned SHA-256 is not downloaded again" {
  tsv
  fetch
  assert_success
  rm -f "$SRV/tool-linux-x86_64"
  fetch
  assert_success
  assert_output --partial 'tool 2.0.0: cached'
  [[ -f $ORIG_TGZ ]]
}

@test "a file whose SHA-256 differs from the pin exits 6, is deleted and writes no orig file" {
  tsv "$(printf 'other' | sha256sum | cut -c1-64)"
  fetch
  assert_failure 6
  assert_output --partial 'does not match the pinned'
  [[ ! -e $OUT/downloads/tool-2.0.0.tool-linux-x86_64 ]] || fail "the mismatching download was kept"
  [[ ! -e $ORIG_TGZ ]] || fail "an orig tarball was written"
  [[ ! -e $OUT/orig ]] || fail "the orig folder was laid out"
}

@test "an empty file exits 1 and writes no orig file" {
  : >"$SRV/tool-linux-x86_64"
  tsv
  fetch
  assert_failure 1
  assert_output --partial 'the downloaded file tool-linux-x86_64 is empty'
  [[ ! -e $ORIG_TGZ ]] || fail "an orig tarball was written"
}

@test "--check validates a file component without network and writes nothing" {
  tsv
  run env https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
    python3 "$FETCH" --components "$T/c.tsv" --out "$T/never" --version 1.0.0 --check
  assert_success
  assert_output --partial '1 components, valid (source motanka-test)'
  [[ ! -e $T/never ]] || fail "--check wrote into the output folder"
}

@test "a file component whose URL has no file name is rejected" {
  local url
  for url in https://example.test/download/ https://example.test 'https://example.test/x/%2e%2e'; do
    tsv - "$url"
    run python3 "$FETCH" --components "$T/c.tsv" --check
    assert_failure 2
    assert_output --partial 'last path segment is a file name'
  done
}

@test "a file component needs no tarball extension, other builds still do" {
  tsv
  run python3 "$FETCH" --components "$T/c.tsv" --check
  assert_success
  sed -i 's/\tfile\t/\tsource\t/' "$T/c.tsv"
  run python3 "$FETCH" --components "$T/c.tsv" --check
  assert_failure 2
  assert_output --partial 'cannot tell the compression'
}
