# shellcheck shell=bash
# Bash completion for motanka(1) (task 24.5).
#
# motanka-core installs this file as
# /opt/motanka/share/motanka/completions/motanka.bash and links
# /usr/share/bash-completion/completions/motanka to it, where
# bash-completion loads it on first use of the command.
#
# Completes the commands, the options each command's --help lists, and the
# values of --channel (also as --channel=VALUE). The development-build
# option --i-know-this-is-not-a-vm is never offered. An option already on
# the command line is not offered again (--yes and -y, and -h and --help,
# count as one; after --apps or --no-apps neither is offered, since they
# exclude each other). Needs no bash-completion helper functions.

_motanka_commands="install remove update rollback doctor help"
_motanka_channels="stable edge"

# _motanka_options <command>: the options of the command, one per line.
_motanka_options() {
  case $1 in
    install) printf '%s\n' --dry-run --yes -y --apps --no-apps --channel -h --help ;;
    remove) printf '%s\n' --dry-run --yes -y --purge -h --help ;;
    update) printf '%s\n' --dry-run --yes -y --system -h --help ;;
    rollback) printf '%s\n' --dry-run --yes -y -h --help ;;
    doctor) printf '%s\n' --json --fix -h --help ;;
  esac
}

# _motanka_same <option>: the option and its other spelling.
_motanka_same() {
  case $1 in
    --yes | -y) printf '%s\n' --yes -y ;;
    -h | --help) printf '%s\n' -h --help ;;
    --apps | --no-apps) printf '%s\n' --apps --no-apps ;;
    --channel=*) printf '%s\n' --channel ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_motanka() {
  local cur prev prev2="" cmd="" i w o
  local -a used=() offer=()
  local -A seen=()
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]:-}
  prev=""
  if ((COMP_CWORD >= 1)); then
    prev=${COMP_WORDS[COMP_CWORD - 1]:-}
  fi
  if ((COMP_CWORD >= 2)); then
    prev2=${COMP_WORDS[COMP_CWORD - 2]:-}
  fi

  # The command: the first word after "motanka" that is not an option.
  for ((i = 1; i < COMP_CWORD; i++)); do
    w=${COMP_WORDS[i]}
    case $w in
      -*) ;;
      *)
        cmd=$w
        break
        ;;
    esac
  done

  if [[ -z $cmd ]]; then
    if [[ $cur == -* ]]; then
      mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur")
    else
      mapfile -t COMPREPLY < <(compgen -W "$_motanka_commands" -- "$cur")
    fi
    return 0
  fi
  if [[ $cmd == help ]] || [[ -z $(_motanka_options "$cmd") ]]; then
    return 0
  fi

  # Values of --channel: "--channel VALUE", and "--channel=VALUE" both when
  # COMP_WORDBREAKS splits at "=" (the default) and when it does not.
  if [[ $cmd == install ]]; then
    if [[ $prev == --channel ]]; then
      if [[ $cur == = ]]; then
        cur=""
      fi
      mapfile -t COMPREPLY < <(compgen -W "$_motanka_channels" -- "$cur")
      return 0
    fi
    if [[ $prev == = && $prev2 == --channel ]]; then
      mapfile -t COMPREPLY < <(compgen -W "$_motanka_channels" -- "$cur")
      return 0
    fi
    if [[ $cur == --channel=* ]]; then
      mapfile -t COMPREPLY < <(compgen -P --channel= -W "$_motanka_channels" -- "${cur#--channel=}")
      return 0
    fi
  fi

  # Words after the command; "--" ends the options.
  for ((i = i + 1; i < COMP_CWORD; i++)); do
    w=${COMP_WORDS[i]}
    if [[ $w == -- ]]; then
      return 0
    fi
    if [[ $w == -* ]]; then
      used+=("$w")
    fi
  done
  for w in "${used[@]}"; do
    while IFS= read -r o; do
      seen[$o]=1
    done < <(_motanka_same "$w")
  done

  # The command takes no other arguments, so options are offered for an
  # empty word too.
  if [[ -n $cur && $cur != -* ]]; then
    return 0
  fi
  while IFS= read -r o; do
    if [[ -z ${seen[$o]:-} ]]; then
      offer+=("$o")
    fi
  done < <(_motanka_options "$cmd")
  if ((${#offer[@]} > 0)); then
    mapfile -t COMPREPLY < <(compgen -W "${offer[*]}" -- "$cur")
  fi
  return 0
}

complete -F _motanka motanka
