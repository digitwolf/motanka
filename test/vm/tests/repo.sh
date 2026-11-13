#!/usr/bin/env bash
# VM test for the packaging foundations (tasks 5.3 to 5.5): build the
# keyring, source and metapackage for noble and resolute in a build VM, make
# a signed test repository with chumak/build-repo, install the keyring and
# source packages in a fresh test VM, check signature, pin priorities and
# Release metadata, purge, and compare Fingerprints.
#
# Usage: test/vm/tests/repo.sh     (test/run-all runs it)
#
# Environment: MOTANKA_VM_RELEASE (resolute or noble; the test VM release,
# default resolute; the build VM is always resolute), MOTANKA_VM_RESULTS.
# Needs the TEST signing key from chumak/gen-test-key.
#
# Checks:
#   - every built .deb carries the version from packaging/version.sh
#   - build-repo refuses a non-Motanka package without --allow-foreign (3.6)
#   - Release of every suite: Origin and Label Motanka, Suite, Codename,
#     amd64, main, Acquire-By-Hash yes, Valid-Until at most 14 days after
#     Date and in the future, InRelease and Release.gpg present, by-hash
#     files match their digests (4.2, 4.7)
#   - the metapackage depends on motanka-source-<release> | motanka-source
#   - installed motanka.sources is deb822 with Signed-By (4.3), the pin file
#     equals design.md (4.4, 4.6)
#   - apt-get update against the test repo verifies the signature and
#     fetches indexes by hash; a tampered InRelease is rejected (4.2)
#   - apt-cache policy: 500 for motanka-*, -1 and no candidate for the dummy
#     package hello-motanka-test from the same repo (4.4, 4.6)
#   - after purge, the Fingerprint equals the one before install apart from
#     the Allowlist (3.13)
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
MV_USAGE="test/vm/tests/repo.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git sha256sum

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-repo}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-repo-test
SUITES=(noble noble-edge resolute resolute-edge)
MOTANKA_PKGS=(motanka-archive-keyring motanka-source-noble motanka-source-noble-edge
  motanka-source-resolute motanka-source-resolute-edge motanka)

failures=0
pass() { mv_log "PASS: $*"; }
fail() {
  mv_log "FAIL: $*"
  failures=$((failures + 1))
}
finish() {
  mv_log "logs: $results"
  if ((failures > 0)); then
    mv_log "$failures check(s) failed"
    exit 1
  fi
  mv_log "all checks passed"
  exit 0
}

# --- 0. signing key -----------------------------------------------------------
if [[ ! -s $MV_KEYS/motanka-test-archive.sec.asc || ! -s $MV_KEYS/fingerprint ]]; then
  mv_die "no TEST signing key in $MV_KEYS; run chumak/gen-test-key first"
fi
key_fpr=$(tr -d '[:space:]' <"$MV_KEYS/fingerprint")
repo_fpr=$(sed -n 's/^# Fingerprint: //p' "$MV_REPO/packaging/keys/motanka-archive.asc" 2>/dev/null | tr -d '[:space:]')
if [[ $key_fpr != "$repo_fpr" ]]; then
  mv_die "packaging/keys/motanka-archive.asc (${repo_fpr:-none}) does not match the key in $MV_KEYS ($key_fpr); run chumak/gen-test-key"
fi

# --- 1. build in a build VM -------------------------------------------------
mv_up_build_vm
bvm=$MV_BOOTED
mv_log "building packages in $bvm"
if ! "$MV_LIB_DIR/build" --vm "$bvm" --suite all \
  "$MV_REPO/packaging/motanka-archive-keyring" \
  "$MV_REPO/packaging/motanka-source" \
  "$MV_REPO/packaging/motanka" >"$results/debs.txt"; then
  fail "test/vm/build failed (logs in $results/build-*)"
  finish
fi
pass "test/vm/build built the packages for noble and resolute"

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/noble" "$stage/resolute" "$stage/install"
for s in noble resolute; do
  ver=$(bash "$MV_REPO/packaging/version.sh" "$s")
  for p in "${MOTANKA_PKGS[@]}"; do
    f=$MV_DEBS/$s/${p}_${ver}_all.deb
    if grep -qxF "$f" "$results/debs.txt" && [[ -f $f ]]; then
      cp -f "$f" "$stage/$s/"
    else
      fail "$s: test/vm/build did not produce ${f##*/}"
    fi
  done
done
if ((failures > 0)); then
  finish
fi
pass "all .debs carry the versions from packaging/version.sh"
rel_ver=$(bash "$MV_REPO/packaging/version.sh" "$release")
cp -f "$stage/$release/motanka-archive-keyring_${rel_ver}_all.deb" \
  "$stage/$release/motanka-source-${release}_${rel_ver}_all.deb" "$stage/install/"

# --- 2. dummy package and repository, in the build VM ------------------------
mv_copy_to_vm "$bvm" "$stage/noble" /tmp/repo-in/noble
mv_copy_to_vm "$bvm" "$stage/resolute" /tmp/repo-in/resolute
mv_copy_to_vm "$bvm" "$MV_KEYS" "/home/$MV_GUEST_USER/.cache/motanka-vm/keys"
rc=0
"$MV_LIB_DIR/run" "$bvm" -- bash -s <<'EOF' >"$results/build-repo.log" 2>&1 || rc=$?
set -euo pipefail
d=$(mktemp -d)
mkdir -p "$d/DEBIAN" "$d/usr/share/doc/hello-motanka-test" /tmp/repo-in/dummy
cat >"$d/DEBIAN/control" <<'CTL'
Package: hello-motanka-test
Version: 1.0
Architecture: all
Maintainer: Motanka test <test@example.test>
Description: dummy package for the Motanka repository pin test
 A package that is not a Motanka_Package, published in the test
 repository only to check that the apt pin gives it priority -1.
CTL
printf 'dummy\n' >"$d/usr/share/doc/hello-motanka-test/README"
chmod -R u=rwX,go=rX "$d"
dpkg-deb --root-owner-group --build "$d" /tmp/repo-in/dummy/hello-motanka-test_1.0_all.deb
rc=0
bash ~/motanka/chumak/build-repo /tmp/repo-refused resolute=/tmp/repo-in/dummy || rc=$?
if ((rc == 0)); then
  echo "FAIL: build-repo accepted hello-motanka-test without --allow-foreign"
  exit 1
fi
echo "PASS: build-repo refused hello-motanka-test without --allow-foreign (exit $rc)"
bash ~/motanka/chumak/build-repo --allow-foreign /tmp/repo-out \
  noble=/tmp/repo-in/noble noble=/tmp/repo-in/dummy \
  noble-edge=/tmp/repo-in/noble \
  resolute=/tmp/repo-in/resolute resolute=/tmp/repo-in/dummy \
  resolute-edge=/tmp/repo-in/resolute
EOF
cat "$results/build-repo.log" >&2
if ((rc != 0)); then
  fail "making the test repository failed (exit $rc)"
  finish
fi
pass "build-repo refuses a foreign package and built four suites"
rm -rf -- "$results/repo"
mv_copy_from_vm "$bvm" /tmp/repo-out "$results/repo"
mv_destroy "$bvm"

# --- 3. Release metadata, on the host copy -----------------------------------
now=$(date -u +%s)
for s in "${SUITES[@]}"; do
  dist=$results/repo/dists/$s
  rel=$dist/Release
  if [[ ! -f $rel ]]; then
    fail "$s: no Release"
    continue
  fi
  ok=true
  for field in "Origin: Motanka" "Label: Motanka" "Suite: $s" "Codename: $s" \
    "Architectures: amd64" "Components: main" "Acquire-By-Hash: yes"; do
    if ! grep -qxF "$field" "$rel"; then
      fail "$s: Release lacks '$field'"
      ok=false
    fi
  done
  d_str=$(sed -n 's/^Date: //p' "$rel")
  v_str=$(sed -n 's/^Valid-Until: //p' "$rel")
  d_s=$(date -u -d "$d_str" +%s 2>/dev/null || echo x)
  v_s=$(date -u -d "$v_str" +%s 2>/dev/null || echo x)
  if [[ ! $d_s =~ ^[0-9]+$ || ! $v_s =~ ^[0-9]+$ ]]; then
    fail "$s: Date '$d_str' or Valid-Until '$v_str' is missing or unreadable"
    ok=false
  elif ((v_s - d_s > 14 * 86400 || v_s <= now || v_s - now > 14 * 86400)); then
    fail "$s: Valid-Until $v_str is not within 14 days (Date $d_str)"
    ok=false
  fi
  if ! head -n 1 "$dist/InRelease" 2>/dev/null | grep -qx -- '-----BEGIN PGP SIGNED MESSAGE-----' ||
    ! grep -qx -- '-----BEGIN PGP SIGNATURE-----' "$dist/Release.gpg" 2>/dev/null; then
    fail "$s: InRelease or Release.gpg missing or not a signature"
    ok=false
  fi
  while read -r digest _ path; do
    [[ $path == main/binary-amd64/Packages* ]] || continue
    bh=$dist/main/binary-amd64/by-hash/SHA256/$digest
    if [[ ! -f $bh ]] || [[ $(sha256sum "$bh" | cut -d' ' -f1) != "$digest" ]] ||
      [[ $(sha256sum "$dist/$path" | cut -d' ' -f1) != "$digest" ]]; then
      fail "$s: by-hash file for $path is missing or wrong"
      ok=false
    fi
  done < <(sed -n '/^SHA256:$/,/^[^ ]/p' "$rel" | grep '^ ')
  if $ok; then
    pass "$s: Release fields, Valid-Until ($v_str), signatures and by-hash"
  fi
done
meta_dep=$(awk '/^Package: motanka$/ { p = 1 } p && /^Depends:/ { print; exit }' \
  "$results/repo/dists/$release/main/binary-amd64/Packages")
if [[ $meta_dep == *"motanka-source-$release | motanka-source"* &&
  $meta_dep == *motanka-core* && $meta_dep == *motanka-stack* &&
  $meta_dep == *motanka-archive-keyring* ]]; then
  pass "metapackage: $meta_dep"
else
  fail "metapackage dependencies are wrong: '$meta_dep'"
fi

# --- 4. test VM -------------------------------------------------------------
tvm=$("$MV_LIB_DIR/up" "$release" fresh </dev/null | tail -n 1)
if ! mv_valid_name "$tvm"; then
  mv_die "test/vm/up printed an invalid VM name '$tvm'"
fi
MV_CLEANUP_VMS+=("$tvm")
mv_copy_to_vm "$tvm" "$results/repo" "$GUEST_T/www/repo"
mv_copy_to_vm "$tvm" "$stage/install" "$GUEST_T/debs"

rc=0
"$MV_LIB_DIR/run" "$tvm" -- bash -s -- "$release" <<'EOF' >"$results/serve.log" 2>&1 || rc=$?
set -euo pipefail
release=$1
T=/tmp/motanka-repo-test
mkdir -p "$T/logs"
chmod -R a+rX "$T"
cp -a "$T/www/repo" "$T/www/repo-bad"
sed -i 's/^Label: Motanka$/Label: Tampered/' "$T/www/repo-bad/dists/$release/InRelease"
grep -qx 'Label: Tampered' "$T/www/repo-bad/dists/$release/InRelease"
setsid -f python3 -u -m http.server --bind 127.0.0.1 --directory "$T/www" 0 \
  >"$T/logs/http.log" 2>&1 </dev/null
port=""
for _ in $(seq 50); do
  port=$(sed -n 's/.* port \([0-9][0-9]*\).*/\1/p' "$T/logs/http.log" | head -n 1)
  [[ -n $port ]] && break
  sleep 0.2
done
if [[ -z $port ]]; then
  cat "$T/logs/http.log"
  exit 1
fi
printf '%s\n' "$port" >"$T/port"
echo "serving $T/www on 127.0.0.1:$port"
EOF
cat "$results/serve.log" >&2
if ((rc != 0)); then
  fail "could not serve the test repository in $tvm"
  finish
fi

fp_before=$("$MV_LIB_DIR/fingerprint" "$tvm" repo-before | tail -n 1)

rc=0
"$MV_LIB_DIR/run" "$tvm" -- bash -s -- "$release" <<'EOF' >"$results/guest.log" 2>&1 || rc=$?
set -euo pipefail
release=$1
T=/tmp/motanka-repo-test
L=$T/logs
port=$(<"$T/port")
fails=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$1" || true; }

rc=0
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "$T"/debs/motanka-archive-keyring_*.deb "$T"/debs/motanka-source-"$release"_*.deb \
  >"$L/install.log" 2>&1 || rc=$?
if ((rc == 0)); then
  pass "installed motanka-archive-keyring and motanka-source-$release from local .debs"
else
  fail "apt-get install of the local .debs failed (exit $rc)"
  show "$L/install.log"
  exit 1
fi

src=/etc/apt/sources.list.d/motanka.sources
for l in "Types: deb" "URIs: https://digitwolf.github.io/motanka/apt" "Suites: $release" \
  "Components: main" "Architectures: amd64" \
  "Signed-By: /usr/share/keyrings/motanka-archive-keyring.gpg"; do
  if grep -qxF "$l" "$src"; then
    pass "motanka.sources has '$l'"
  else
    fail "motanka.sources lacks '$l'"
  fi
done
if printf 'Package: *\nPin: release o=Motanka\nPin-Priority: -1\n\nPackage: motanka motanka-*\nPin: release o=Motanka\nPin-Priority: 500\n' |
  cmp -s - /etc/apt/preferences.d/motanka; then
  pass "/etc/apt/preferences.d/motanka equals the pin in design.md"
else
  fail "/etc/apt/preferences.d/motanka differs from design.md"
  show /etc/apt/preferences.d/motanka
fi
if [[ -s /usr/share/keyrings/motanka-archive-keyring.gpg ]]; then
  pass "keyring installed"
else
  fail "/usr/share/keyrings/motanka-archive-keyring.gpg is missing"
fi

# Private apt configuration: only the test repository, private lists and
# cache. The installed motanka.sources is copied with its URIs replaced.
apt_dir() {
  local name=$1 uri=$2 d=$T/apt-$1
  sudo rm -rf "$d"
  sudo mkdir -p "$d/sources.list.d" "$d/lists/partial" "$d/cache/archives/partial"
  sed "s|^URIs: .*|URIs: $uri|" "$src" | sudo tee "$d/sources.list.d/motanka.sources" >/dev/null
}
apt_opts() {
  local d=$T/apt-$1
  OPTS=(-o "Dir::Etc::SourceList=/dev/null" -o "Dir::Etc::SourceParts=$d/sources.list.d"
    -o "Dir::State::Lists=$d/lists" -o "Dir::Cache=$d/cache")
}

apt_dir good "http://127.0.0.1:$port/repo"
apt_opts good
rc=0
sudo apt-get "${OPTS[@]}" update >"$L/update-good.log" 2>&1 || rc=$?
if ((rc == 0)) && ! grep -Eq '^(W|E|Err):' "$L/update-good.log" &&
  compgen -G "$T/apt-good/lists/*_InRelease" >/dev/null; then
  pass "apt-get update verified the signed InRelease"
else
  fail "apt-get update against the test repository failed (exit $rc)"
  show "$L/update-good.log"
fi
if grep -q "GET /repo/dists/$release/main/binary-amd64/by-hash/SHA256/" "$L/http.log"; then
  pass "apt fetched the package index by hash"
else
  fail "apt did not fetch the package index by hash"
  show "$L/http.log"
fi

apt_dir bad "http://127.0.0.1:$port/repo-bad"
apt_opts bad
rc=0
sudo apt-get "${OPTS[@]}" update >"$L/update-bad.log" 2>&1 || rc=$?
if ((rc != 0)) && ! compgen -G "$T/apt-bad/lists/*_InRelease" >/dev/null; then
  pass "apt-get update rejected a tampered InRelease (exit $rc)"
else
  fail "apt-get update accepted a tampered InRelease"
  show "$L/update-bad.log"
fi

apt_opts good
if ! sudo apt-cache "${OPTS[@]}" policy motanka-archive-keyring "motanka-source-$release" \
  motanka hello-motanka-test >"$L/policy.txt" 2>&1; then
  fail "apt-cache policy failed"
fi
show "$L/policy.txt"
# field <package> <priority|candidate>: from apt-cache policy output.
field() {
  awk -v p="$1:" -v want="$2" '
    $0 == p { inpkg = 1; vt = 0; next }
    /^[^ ]/ { inpkg = 0 }
    inpkg && want == "candidate" && $1 == "Candidate:" { print $2; exit }
    inpkg && /Version table:/ { vt = 1; next }
    inpkg && vt && want == "priority" { if ($1 == "***") print $3; else print $2; exit }
  ' "$L/policy.txt"
}
for p in motanka-archive-keyring "motanka-source-$release" motanka; do
  prio=$(field "$p" priority)
  if [[ $prio == 500 ]]; then
    pass "apt-cache policy: $p has priority 500"
  else
    fail "apt-cache policy: $p has priority '${prio:-none}', expected 500"
  fi
done
prio=$(field hello-motanka-test priority)
cand=$(field hello-motanka-test candidate)
if [[ $prio == -1 && $cand == "(none)" ]]; then
  pass "apt-cache policy: hello-motanka-test has priority -1 and no candidate"
else
  fail "apt-cache policy: hello-motanka-test has priority '${prio:-none}', candidate '${cand:-none}'"
fi

rc=0
sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "motanka-source-$release" \
  motanka-archive-keyring >"$L/purge.log" 2>&1 || rc=$?
left=""
for f in /etc/apt/sources.list.d/motanka.sources /etc/apt/preferences.d/motanka \
  /usr/share/keyrings/motanka-archive-keyring.gpg; do
  if [[ -e $f ]]; then
    left+=" $f"
  fi
done
if ((rc == 0)) && [[ -z $left ]]; then
  pass "purge removed the packages and their files"
else
  fail "purge failed (exit $rc) or left files:$left"
  show "$L/purge.log"
fi
pkill -f -- "http.server --bind 127.0.0.1 --directory $T/www" || true
exit $((fails > 0 ? 1 : 0))
EOF
cat "$results/guest.log" >&2
guest_fails=$(grep -c '^FAIL:' "$results/guest.log" || true)
guest_pass=$(grep -c '^PASS:' "$results/guest.log" || true)
if ((rc == 0 && guest_fails == 0)); then
  pass "in-VM checks on $release ($guest_pass passed)"
else
  failures=$((failures + (guest_fails > 0 ? guest_fails : 1)))
  mv_log "FAIL: in-VM checks on $release ($guest_fails failed, exit $rc)"
fi

fp_after=$("$MV_LIB_DIR/fingerprint" "$tvm" repo-after | tail -n 1)
rc=0
python3 "$MV_REPO/tools/fpdiff.py" "$fp_before" "$fp_after" >"$results/fpdiff.txt" 2>&1 || rc=$?
if ((rc == 0)); then
  pass "Fingerprint after purge equals the one before install (Allowlist applied)"
else
  fail "Fingerprint differs after purge (fpdiff exit $rc):"
  cat "$results/fpdiff.txt" >&2
fi

mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/guest-logs" || true
mv_destroy "$tvm"
finish
