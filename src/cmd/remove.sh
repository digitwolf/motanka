# shellcheck shell=bash
# motanka remove: option parsing. The user and system phases are added by
# tasks 19.1 to 19.3.

mk_remove_usage() {
  cat <<'EOF'
usage: motanka remove [--dry-run] [--yes] [--purge]

Removes Motanka and returns this installation to its earlier state. Works
without network access.

  --dry-run   print every planned action, change nothing
  --yes, -y   do not ask for confirmation
  --purge     also remove packages and web apps installed from Omarchy
              menus (kept and listed otherwise)
  -h, --help  show this help
EOF
}

# shellcheck disable=SC2034 # MK_PURGE is read by the remove phases of tasks 19.x
mk_cmd_remove() {
  MK_PURGE=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_remove_usage
        exit "$MK_EXIT_OK"
        ;;
      --purge)
        MK_PURGE=1
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
