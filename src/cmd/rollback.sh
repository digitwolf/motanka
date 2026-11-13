# shellcheck shell=bash
# shellcheck disable=SC2329 # mk_cmd_rollback is called by src/motanka
# motanka rollback: option parsing. Rollback is added by task 21.4.

mk_rollback_usage() {
  cat <<'EOF'
usage: motanka rollback [--dry-run] [--yes]

Reinstalls the Motanka packages stored in the latest snapshot and restores
your ledgered home-folder files from it.

  --dry-run   print what would be restored, change nothing
  --yes, -y   do not ask for confirmation
  -h, --help  show this help
EOF
}

mk_cmd_rollback() {
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_rollback_usage
        exit "$MK_EXIT_OK"
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
