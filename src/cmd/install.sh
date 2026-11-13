# shellcheck shell=bash
# shellcheck disable=SC2329 # mk_cmd_install is called by src/motanka
# motanka install: option parsing. Preflight, the apt simulation and the
# real install are added by tasks 11.1 to 11.3.

mk_install_usage() {
  cat <<'EOF'
usage: motanka install [--dry-run] [--yes] [--channel stable|edge]

Adds Motanka to this Ubuntu installation as a separate login session.

  --dry-run          run the read-only preflight, print the simulated apt
                     transaction and every home-folder path, change nothing
  --yes, -y          do not ask for confirmation
  --channel CHANNEL  stable (default) follows Upstream release tags,
                     edge follows Upstream's default branch
  -h, --help         show this help
EOF
}

mk_cmd_install() {
  MK_CHANNEL=stable
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_install_usage
        exit "$MK_EXIT_OK"
        ;;
      --channel)
        if (($# < 2)); then
          mk_usage_error "--channel needs a value"
        fi
        MK_CHANNEL=$2
        shift
        ;;
      --channel=*)
        MK_CHANNEL=${1#*=}
        ;;
      --)
        shift
        break
        ;;
      -*)
        mk_parse_common_opt "$1" || mk_usage_error "unknown option '$1'"
        ;;
      *)
        mk_usage_error "unexpected argument '$1'"
        ;;
    esac
    shift
  done
  if (($# > 0)); then
    mk_usage_error "unexpected argument '$1'"
  fi
  case $MK_CHANNEL in
    stable | edge) ;;
    *) mk_usage_error "--channel must be stable or edge, not '$MK_CHANNEL'" ;;
  esac
  mk_not_implemented
}
