# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # library: its variables and functions are used by the scripts that source it
# Host-side helper of the VM tests that install Motanka through the real
# Installer (test/vm/tests/roundtrip.sh, test/vm/tests/remove-edge.sh):
# builds the Motanka packages of the working tree once and publishes them
# in a signed local test repository, the way test/vm/tests/install.sh does.
#
# The result is cached in ~/.cache/motanka-vm/repo-cache/<release>-<key>/
# repo/, where <key> is a hash of everything that goes into it: packaging/,
# src/, chumak/, tools/, compat/, packages.yaml, upstream.pin, install.sh,
# the Stack .debs and the TEST key. A second test with the same tree reuses
# it without booting a build VM; older entries of the release are deleted.
#
# Inputs:
#   - the TEST signing key in ~/.cache/motanka-vm/keys/ (chumak/gen-test-key)
#   - the Stack .debs of the current version in ~/.cache/motanka-vm/debs/
#     <release>/; when they are missing, test/vm/build builds
#     packaging/motanka-stack first (more than an hour). motanka-qt6 and
#     motanka-stack-shell are added when that folder has them.
#   - one build VM builds motanka-archive-keyring, motanka-source, motanka
#     and motanka-core; the motanka-source .debs are repacked with
#     URIs: http://127.0.0.1:8765/repo, where each test VM serves the
#     repository, and chumak/build-repo signs it with the TEST key.
#
# Usage, after sourcing lib.sh and calling mv_init:
#   lr_repo <release> <results-folder> || <handle the failure>
#   then LR_REPO is the repository folder and LR_VER the package version.
#
#   lr_repo_dual <results-folder> || <handle the failure>
#   one repository with both suites, noble and resolute, for the release
#   upgrade test (test/vm/tests/release-upgrade.sh): the .debs of the two
#   per-release repositories of lr_repo, published and signed together by
#   chumak/build-repo in a build VM. Then LR_DUAL_REPO is its folder and
#   LR_VER_NOBLE and LR_VER_RESOLUTE the two package versions. It is cached
#   in ~/.cache/motanka-vm/repo-cache/dual-<key>/repo, where <key> hashes the
#   SHA256SUMS of both inputs and the TEST key, and is signed again once it
#   is 7 days old (Valid-Until is 14 days).

LR_STACK_PKGS=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools motanka-stack)
LR_OPTIONAL_PKGS=(motanka-qt6 motanka-stack-shell)
LR_URI=http://127.0.0.1:8765/repo
LR_REPO=""
LR_VER=""
LR_DUAL_REPO=""
LR_VER_NOBLE=""
LR_VER_RESOLUTE=""

# _lr_deb <release> <package>: the cached .deb of LR_VER, or nothing.
_lr_deb() {
  local f
  for f in "$MV_DEBS/$1/${2}_${LR_VER}_amd64.deb" "$MV_DEBS/$1/${2}_${LR_VER}_all.deb"; do
    if [[ -f $f ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

_lr_have_stack() {
  local p
  for p in "${LR_STACK_PKGS[@]}"; do
    _lr_deb "$1" "$p" >/dev/null || return 1
  done
}

# _lr_key <release>: the cache key (16 hex digits).
_lr_key() {
  local release=$1 p f
  {
    printf 'release %s version %s uri %s\n' "$release" "$LR_VER" "$LR_URI"
    (
      cd "$MV_REPO" &&
        find packaging src chumak tools compat packages.yaml upstream.pin install.sh \
          -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) || true
    for p in "${LR_STACK_PKGS[@]}" "${LR_OPTIONAL_PKGS[@]}"; do
      if f=$(_lr_deb "$release" "$p"); then
        sha256sum "$f" | cut -c1-64
      fi
    done
    cat -- "$MV_KEYS/fingerprint"
  } | sha256sum | cut -c1-16
}

# lr_repo <release> <results-folder>: sets LR_REPO and LR_VER. Returns 1,
# after logging why, when a build fails.
lr_repo() {
  local release=$1 results=$2 key key_fpr repo_fpr cache stage bvm f base p rc=0
  local -a pkgs
  LR_REPO=""
  LR_VER=$(bash "$MV_REPO/packaging/version.sh" "$release")
  if [[ ! -s $MV_KEYS/motanka-test-archive.sec.asc || ! -s $MV_KEYS/fingerprint ]]; then
    mv_log "FAIL: no TEST signing key in $MV_KEYS; run chumak/gen-test-key first"
    return 1
  fi
  key_fpr=$(tr -d '[:space:]' <"$MV_KEYS/fingerprint")
  repo_fpr=$(sed -n 's/^# Fingerprint: //p' "$MV_REPO/packaging/keys/motanka-archive.asc" 2>/dev/null | tr -d '[:space:]')
  if [[ $key_fpr != "$repo_fpr" ]]; then
    mv_log "FAIL: packaging/keys/motanka-archive.asc (${repo_fpr:-none}) does not match the key in $MV_KEYS ($key_fpr); run chumak/gen-test-key"
    return 1
  fi

  if ! _lr_have_stack "$release"; then
    mv_log "building packaging/motanka-stack for $release (this takes more than an hour)"
    if ! "$MV_LIB_DIR/build" --suite "$release" "$MV_REPO/packaging/motanka-stack" \
      >"$results/stack-debs.txt"; then
      mv_log "FAIL: test/vm/build failed for motanka-stack on $release"
      return 1
    fi
    if ! _lr_have_stack "$release"; then
      mv_log "FAIL: no motanka-stack .debs of version $LR_VER in $MV_DEBS/$release/"
      return 1
    fi
  fi

  key=$(_lr_key "$release")
  cache=$MV_STATE/repo-cache/$release-$key
  if [[ -s $cache/repo/SHA256SUMS && -s $cache/repo/SHA256SUMS.gpg && -s $cache/repo/install.sh ]]; then
    mv_log "reusing the test repository $cache/repo (same tree, same Stack)"
    LR_REPO=$cache/repo
    return 0
  fi

  stage=$MV_STATE/repo-cache/.$release-$key.$$
  rm -rf -- "$stage"
  mkdir -p "$stage/in"
  MV_CLEANUP_PATHS+=("$stage")
  pkgs=("$MV_REPO/packaging/motanka-archive-keyring" "$MV_REPO/packaging/motanka-source"
    "$MV_REPO/packaging/motanka" "$MV_REPO/packaging/motanka-core")
  mv_up_build_vm
  bvm=$MV_BOOTED
  mv_log "building ${pkgs[*]##*/} for $release in $bvm"
  if ! "$MV_LIB_DIR/build" --vm "$bvm" --suite "$release" "${pkgs[@]}" >"$results/debs.txt"; then
    mv_destroy "$bvm"
    mv_log "FAIL: test/vm/build failed (logs in $results/build-$release*)"
    return 1
  fi
  while IFS= read -r f; do
    base=${f##*/}
    case $base in
      *-dbgsym_*) continue ;;
      motanka-source-*)
        if [[ $base != "motanka-source-${release}_"* ]]; then
          continue
        fi
        ;;
    esac
    cp -f -- "$f" "$stage/in/"
  done <"$results/debs.txt"
  for p in "${LR_STACK_PKGS[@]}" "${LR_OPTIONAL_PKGS[@]}"; do
    if f=$(_lr_deb "$release" "$p"); then
      cp -f -- "$f" "$stage/in/"
    fi
  done
  for p in motanka-archive-keyring "motanka-source-$release" motanka; do
    if [[ ! -f $stage/in/${p}_${LR_VER}_all.deb ]]; then
      mv_log "FAIL: test/vm/build did not produce ${p}_${LR_VER}_all.deb"
      rc=1
    fi
  done
  if ! compgen -G "$stage/in/motanka-core_${LR_VER}_*.deb" >/dev/null; then
    mv_log "FAIL: test/vm/build did not produce motanka-core $LR_VER"
    rc=1
  fi
  if ((rc != 0)); then
    mv_destroy "$bvm"
    return 1
  fi

  mv_copy_to_vm "$bvm" "$stage/in" /tmp/lr-in
  mv_copy_to_vm "$bvm" "$MV_KEYS" "/home/$MV_GUEST_USER/.cache/motanka-vm/keys"
  "$MV_LIB_DIR/run" "$bvm" -- bash -s -- "$release" "$LR_URI" \
    <<'EOF' >"$results/build-repo.log" 2>&1 || rc=$?
set -euo pipefail
release=$1 uri=$2
in=/tmp/lr-in
out=/tmp/lr-repo
rm -rf "$out"
for deb in "$in"/motanka-source-*_all.deb; do
  d=$(mktemp -d)
  dpkg-deb -R "$deb" "$d"
  f=$d/etc/apt/sources.list.d/motanka.sources
  sed -i "s|^URIs: .*|URIs: $uri|" "$f"
  grep -qxF "URIs: $uri" "$f"
  if [[ -f $d/DEBIAN/md5sums ]] && grep -q ' etc/apt/sources.list.d/motanka.sources$' "$d/DEBIAN/md5sums"; then
    sum=$(cd "$d" && md5sum etc/apt/sources.list.d/motanka.sources)
    sed -i "s|^[0-9a-f]*  etc/apt/sources.list.d/motanka.sources\$|$sum|" "$d/DEBIAN/md5sums"
  fi
  dpkg-deb --root-owner-group --build "$d" "$deb.new" >/dev/null
  mv -f "$deb.new" "$deb"
  echo "repacked ${deb##*/} with URIs: $uri"
done
bash ~/motanka/chumak/build-repo "$out" "$release=$in"
EOF
  if ((rc != 0)); then
    cat "$results/build-repo.log" >&2
    mv_destroy "$bvm"
    mv_log "FAIL: making the test repository failed (exit $rc)"
    return 1
  fi
  mv_copy_from_vm "$bvm" /tmp/lr-repo "$stage/repo"
  mv_destroy "$bvm"
  for f in SHA256SUMS SHA256SUMS.gpg install.sh motanka-cli.tar.gz; do
    if [[ ! -s $stage/repo/$f ]]; then
      mv_log "FAIL: the test repository has no $f"
      return 1
    fi
  done
  rm -rf -- "$stage/in"
  find "$MV_STATE/repo-cache" -mindepth 1 -maxdepth 1 -type d -name "$release-*" \
    -exec rm -rf -- {} + 2>/dev/null || true
  mv -T -- "$stage" "$cache"
  mv_log "built the test repository $cache/repo"
  LR_REPO=$cache/repo
}

# lr_repo_dual <results-folder>: sets LR_DUAL_REPO, LR_VER_NOBLE and
# LR_VER_RESOLUTE (see the top). Returns 1, after logging why, when a build
# fails.
lr_repo_dual() {
  local results=$1 noble resolute key cache stage bvm f rc=0
  LR_DUAL_REPO=""
  if ! lr_repo noble "$results"; then
    return 1
  fi
  noble=$LR_REPO
  LR_VER_NOBLE=$LR_VER
  if ! lr_repo resolute "$results"; then
    return 1
  fi
  resolute=$LR_REPO
  LR_VER_RESOLUTE=$LR_VER

  key=$({
    sha256sum "$noble/SHA256SUMS" "$resolute/SHA256SUMS" | cut -c1-64
    cat -- "$MV_KEYS/fingerprint"
  } | sha256sum | cut -c1-16)
  cache=$MV_STATE/repo-cache/dual-$key
  if [[ -s $cache/repo/SHA256SUMS && -s $cache/repo/SHA256SUMS.gpg ]] &&
    [[ -z $(find "$cache/repo/SHA256SUMS" -mmin +$((7 * 24 * 60)) 2>/dev/null) ]]; then
    mv_log "reusing the noble and resolute test repository $cache/repo"
    LR_DUAL_REPO=$cache/repo
    return 0
  fi

  stage=$MV_STATE/repo-cache/.dual-$key.$$
  rm -rf -- "$stage"
  mkdir -p "$stage/in/noble" "$stage/in/resolute"
  MV_CLEANUP_PATHS+=("$stage")
  find "$noble/pool/noble" -type f -name '*.deb' -exec cp -f -t "$stage/in/noble" -- {} +
  find "$resolute/pool/resolute" -type f -name '*.deb' -exec cp -f -t "$stage/in/resolute" -- {} +
  for f in "motanka-source-noble_${LR_VER_NOBLE}_all.deb" "motanka-archive-keyring_${LR_VER_NOBLE}_all.deb"; do
    if [[ ! -f $stage/in/noble/$f ]]; then
      mv_log "FAIL: the noble test repository $noble has no $f"
      return 1
    fi
  done
  for f in "motanka-source-resolute_${LR_VER_RESOLUTE}_all.deb" "motanka-archive-keyring_${LR_VER_RESOLUTE}_all.deb"; do
    if [[ ! -f $stage/in/resolute/$f ]]; then
      mv_log "FAIL: the resolute test repository $resolute has no $f"
      return 1
    fi
  done

  mv_up_build_vm
  bvm=$MV_BOOTED
  mv_log "publishing the noble and resolute packages in one repository in $bvm"
  if ! "$MV_LIB_DIR/push" "$bvm" </dev/null >"$results/dual-push.log" 2>&1; then
    cat "$results/dual-push.log" >&2
    mv_destroy "$bvm"
    mv_log "FAIL: could not copy the repository into $bvm"
    return 1
  fi
  mv_copy_to_vm "$bvm" "$stage/in" /tmp/lr-dual-in
  mv_copy_to_vm "$bvm" "$MV_KEYS" "/home/$MV_GUEST_USER/.cache/motanka-vm/keys"
  "$MV_LIB_DIR/run" "$bvm" -- bash -s <<'EOF' >"$results/dual-build-repo.log" 2>&1 || rc=$?
set -euo pipefail
command -v apt-ftparchive >/dev/null ||
  sudo env DEBIAN_FRONTEND=noninteractive apt-get -q -y -o DPkg::Lock::Timeout=300 install apt-utils >/dev/null
rm -rf /tmp/lr-dual-repo
bash ~/motanka/chumak/build-repo /tmp/lr-dual-repo noble=/tmp/lr-dual-in/noble resolute=/tmp/lr-dual-in/resolute
EOF
  if ((rc != 0)); then
    cat "$results/dual-build-repo.log" >&2
    mv_destroy "$bvm"
    mv_log "FAIL: chumak/build-repo failed for the noble and resolute repository (exit $rc)"
    return 1
  fi
  mv_copy_from_vm "$bvm" /tmp/lr-dual-repo "$stage/repo"
  mv_destroy "$bvm"
  for f in SHA256SUMS SHA256SUMS.gpg install.sh dists/noble/InRelease dists/resolute/InRelease; do
    if [[ ! -s $stage/repo/$f ]]; then
      mv_log "FAIL: the noble and resolute test repository has no $f"
      return 1
    fi
  done
  rm -rf -- "$stage/in"
  find "$MV_STATE/repo-cache" -mindepth 1 -maxdepth 1 -type d -name 'dual-*' \
    -exec rm -rf -- {} + 2>/dev/null || true
  mv -T -- "$stage" "$cache"
  mv_log "built the noble and resolute test repository $cache/repo"
  LR_DUAL_REPO=$cache/repo
}
