# shellcheck shell=bash
# motanka doctor: option parsing. The report is added by task 22.1 and
# --fix by task 22.2. Doctor runs no guards: without --fix it changes
# nothing.

mk_doctor_usage() {
  cat <<'EOF'
usage: motanka doctor [--json] [--fix]

Reports Motanka's state. Changes nothing unless --fix is given.

  --json      print the report as one JSON document
  --fix       switch the repository source to the suite of the running
              release
  -h, --help  show this help
EOF
}

# shellcheck disable=SC2034 # MK_JSON and MK_FIX are read by the report of tasks 22.x
mk_cmd_doctor() {
  MK_JSON=0 MK_FIX=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_doctor_usage
        exit "$MK_EXIT_OK"
        ;;
      --json)
        MK_JSON=1
        ;;
      --fix)
        MK_FIX=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        mk_usage_error "unknown option '$1'"
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
