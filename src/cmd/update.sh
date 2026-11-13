# shellcheck shell=bash
# motanka update: option parsing. The update flow is added by task 21.2.

mk_update_usage() {
  cat <<'EOF'
usage: motanka update [--dry-run] [--yes] [--system]

Takes a snapshot, upgrades the Motanka packages, moves to the channel's
Upstream pin and runs pending migrations.

  --dry-run   print the planned upgrade, change nothing
  --yes, -y   do not ask for confirmation
  --system    allow the upgrade to change packages Motanka does not own
  -h, --help  show this help
EOF
}

# shellcheck disable=SC2034 # MK_SYSTEM is read by the update flow of task 21.2
mk_cmd_update() {
  MK_SYSTEM=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_update_usage
        exit "$MK_EXIT_OK"
        ;;
      --system)
        MK_SYSTEM=1
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
  mk_not_implemented
}
