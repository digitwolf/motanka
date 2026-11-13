#!/usr/bin/env bash
# Motanka bootstrap: fetches the motanka CLI from the Motanka repository,
# verifies it, and runs 'motanka install' from a temporary folder. It
# installs nothing itself; the Installer runs its read-only preflight
# before any change.
#
#   curl -fsSL https://digitwolf.github.io/motanka/apt/install.sh | sudo bash -s -- --dry-run
#   curl -fsSL https://digitwolf.github.io/motanka/apt/install.sh | sudo bash -s -- --yes
#
# Arguments go to 'motanka install' ([--dry-run] [--yes] [--channel edge]).
# Without a terminal the Installer needs --yes or --dry-run.
#
# Trust: chumak/build-repo publishes this file with the archive's public
# key embedded below, next to SHA256SUMS, its signature SHA256SUMS.gpg and
# motanka-cli.tar.gz. This script checks SHA256SUMS with gpgv against the
# embedded key, then the tarball against SHA256SUMS. The copy in the source
# tree has no key and refuses to run.
#
# Environment: MOTANKA_APT_URI (default https://digitwolf.github.io/motanka/apt).
# Exit codes: those of 'motanka install'; 6 when verification fails, 7 on
# a Protected_Host, 11 without root, 1 on other errors.
set -euo pipefail

MOTANKA_ARCHIVE_KEY=$(
  cat <<'MOTANKA_KEY'
# @archive-key@
MOTANKA_KEY
)

die() {
  local code=$1
  shift
  printf 'motanka install.sh: %s\n' "$*" >&2
  exit "$code"
}

main() {
  local uri work m home want got in=/dev/null
  uri=${MOTANKA_APT_URI:-https://digitwolf.github.io/motanka/apt}
  uri=${uri%/}
  [[ $uri =~ ^https?://[A-Za-z0-9._~:@%+=,/-]+$ ]] || die 2 "MOTANKA_APT_URI must be an http or https URL"
  [[ $(id -u) -eq 0 ]] || die 11 "run it as root: curl -fsSL $uri/install.sh | sudo bash -s -- --yes"
  home=""
  if [[ -n ${SUDO_USER:-} ]]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6) || home=""
  fi
  for m in /etc/motanka-protected ${home:+"$home/.config/motanka-protected"}; do
    if [[ -e $m || -L $m ]]; then
      die 7 "refused: this machine is a Protected_Host ($m exists)"
    fi
  done
  [[ $MOTANKA_ARCHIVE_KEY == *'-----BEGIN PGP PUBLIC KEY BLOCK-----'* ]] ||
    die 1 "this copy of install.sh has no embedded archive key; use $uri/install.sh"
  for m in curl gpgv sha256sum tar base64; do
    command -v "$m" >/dev/null || die 1 "$m is missing"
  done

  mkdir -p /run/motanka
  chmod 0755 /run/motanka
  work=$(mktemp -d /run/motanka/bootstrap.XXXXXX)
  # shellcheck disable=SC2064 # expand $work now
  trap "rm -rf -- '$work'" EXIT
  mkdir -m 0700 "$work/gnupg"

  printf '%s\n' "$MOTANKA_ARCHIVE_KEY" | sed 's/\r$//' | awk '
    $0 == "-----BEGIN PGP PUBLIC KEY BLOCK-----" { inb = 1; hdr = 1; next }
    !inb { next }
    $0 == "-----END PGP PUBLIC KEY BLOCK-----" { exit }
    hdr { if ($0 == "") hdr = 0; next }
    /^=/ { exit }
    { print }' | base64 -d >"$work/key.gpg" || die 6 "the embedded archive key is damaged"

  for m in SHA256SUMS SHA256SUMS.gpg motanka-cli.tar.gz; do
    curl --fail --silent --show-error --location --proto '=http,https' \
      --output "$work/$m" "$uri/$m" || die 1 "cannot download $uri/$m"
  done
  if ! gpgv --homedir "$work/gnupg" --status-fd 1 --keyring "$work/key.gpg" \
    "$work/SHA256SUMS.gpg" "$work/SHA256SUMS" >"$work/gpgv.status" 2>"$work/gpgv.log" ||
    ! grep -q '^\[GNUPG:\] VALIDSIG ' "$work/gpgv.status"; then
    cat "$work/gpgv.log" >&2
    die 6 "the signature of $uri/SHA256SUMS does not verify with the Motanka archive key"
  fi
  want=$(awk '$2 == "motanka-cli.tar.gz" { print $1 }' "$work/SHA256SUMS")
  got=$(sha256sum "$work/motanka-cli.tar.gz" | cut -d' ' -f1)
  if [[ -z $want || $got != "$want" ]]; then
    rm -f -- "$work/motanka-cli.tar.gz"
    die 6 "checksum mismatch for $uri/motanka-cli.tar.gz"
  fi
  mkdir "$work/cli"
  tar -C "$work/cli" --no-same-owner -xzf "$work/motanka-cli.tar.gz"
  [[ -f $work/cli/motanka-cli/motanka ]] || die 1 "motanka-cli.tar.gz has no motanka-cli/motanka"

  # stdin may be this script (curl | bash): give the Installer the terminal
  # instead, or nothing.
  if [[ -t 0 ]]; then
    in=/dev/stdin
  elif { : </dev/tty; } 2>/dev/null; then
    in=/dev/tty
  fi
  MOTANKA_APT_URI=$uri bash "$work/cli/motanka-cli/motanka" install "$@" <"$in"
}

main "$@"
