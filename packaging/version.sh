#!/usr/bin/env bash
# Print the Debian version of the Motanka packages for one suite.
#
# Usage: packaging/version.sh [--version <v>] [--rev <r>] [--build <n>] <suite>
#
#   <suite>      noble, noble-edge, resolute or resolute-edge
#   --version    Motanka version (default: the first line of packaging/VERSION)
#   --rev        Debian revision (default 1)
#   --build      per-release build number (default 1)
#
# Prints <version>-<rev>~ubuntu<release>.<n>, for example
# 0.1.0-1~ubuntu24.04.1 for noble and 0.1.0-1~ubuntu26.04.1 for resolute.
# The release number makes a resolute build sort above the noble build of the
# same Motanka version and revision (requirement 11.6).
#
# Exit codes: 0 success, 2 usage error or invalid input.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage="packaging/version.sh [--version <v>] [--rev <r>] [--build <n>] <suite>"

die_usage() {
  printf 'version.sh: %s\nusage: %s\n' "$1" "$usage" >&2
  exit 2
}

version=""
rev=1
build=1
suite=""
while (($# > 0)); do
  case $1 in
    --version | --rev | --build)
      if (($# < 2)); then
        die_usage "$1 needs a value"
      fi
      case $1 in
        --version) version=$2 ;;
        --rev) rev=$2 ;;
        --build) build=$2 ;;
      esac
      shift 2
      ;;
    -h | --help)
      printf 'usage: %s\n' "$usage"
      exit 0
      ;;
    -*)
      die_usage "unknown option '$1'"
      ;;
    *)
      if [[ -n $suite ]]; then
        die_usage "only one suite may be given"
      fi
      suite=$1
      shift
      ;;
  esac
done
if [[ -z $suite ]]; then
  die_usage "no suite given"
fi

case $suite in
  noble | noble-edge) release=24.04 ;;
  resolute | resolute-edge) release=26.04 ;;
  *) die_usage "unknown suite '$suite' (expected noble, noble-edge, resolute or resolute-edge)" ;;
esac

if [[ -z $version ]]; then
  if [[ ! -r $here/VERSION ]]; then
    printf 'version.sh: %s is missing\n' "$here/VERSION" >&2
    exit 2
  fi
  IFS= read -r version <"$here/VERSION" || true
  version=${version//[[:space:]]/}
fi

# Upstream part: starts with a digit; letters, digits, '.', '+' and '~'
# only. A hyphen would split it from the revision.
if [[ ! $version =~ ^[0-9][A-Za-z0-9.+~]*$ ]]; then
  die_usage "invalid Motanka version '$version'"
fi
if [[ ! $rev =~ ^[1-9][0-9]*$ ]]; then
  die_usage "invalid revision '$rev' (a positive integer)"
fi
if [[ ! $build =~ ^[1-9][0-9]*$ ]]; then
  die_usage "invalid build number '$build' (a positive integer)"
fi

printf '%s-%s~ubuntu%s.%s\n' "$version" "$rev" "$release" "$build"
