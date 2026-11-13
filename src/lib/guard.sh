# shellcheck shell=bash
# shellcheck disable=SC2329 # library: its functions are called by the files that source it
# Safety guards that install, remove, update and rollback run before
# anything else (design.md, Guards; requirements 14.8 and 14.11).
#
#   Protected_Host  /etc/motanka-protected, or ~/.config/motanka-protected
#                   of an invoking user, exists: exit 7, for every build
#                   and every flag.
#   Dev_Build       /opt/motanka/share/motanka/DEV_BUILD exists and
#                   systemd-detect-virt prints "none": exit 7 unless
#                   --i-know-this-is-not-a-vm is given. A published build
#                   rejects that flag as a usage error (exit 2).
#
# Invoking users: the current user, and when set, SUDO_USER (a name) and
# PKEXEC_UID (a uid). Checking all of them can only add refusals.
#
# Test hook: MOTANKA_ROOT (see common.sh). The markers are looked up both
# inside MOTANKA_ROOT and at their real paths, and users both in
# $MOTANKA_ROOT/etc/passwd and through getent, so the hook can add
# refusals but never remove one. systemd-detect-virt is found through PATH,
# which the tests point at a stub.
#
# Requires common.sh.

if [[ -n ${MK_GUARD_LOADED:-} ]]; then
  return 0
fi
MK_GUARD_LOADED=1

readonly MK_PROTECTED_MARKER=/etc/motanka-protected
readonly MK_USER_PROTECTED_MARKER=.config/motanka-protected
readonly MK_DEV_BUILD_MARKER=/opt/motanka/share/motanka/DEV_BUILD
readonly MK_NOT_A_VM_FLAG=--i-know-this-is-not-a-vm

# _mk_guard_passwd_home <file> <name-or-uid>: home folder of the user from a
# passwd(5) file, or nothing.
_mk_guard_passwd_home() {
  [[ -r $1 ]] || return 0
  awk -F: -v u="$2" '($1 == u || $3 == u) && NF >= 7 { print $6; exit }' "$1"
}

# _mk_guard_nss_home <name-or-uid>: home folder through getent, or nothing.
_mk_guard_nss_home() {
  getent passwd -- "$1" 2>/dev/null | awk -F: 'NF >= 7 { print $6; exit }' || true
}

# mk_guard_user_homes: prints every home folder whose user-level marker
# applies, one per line: real homes, then homes from the fake root
# (prefixed with MOTANKA_ROOT).
mk_guard_user_homes() {
  local -a users=()
  local u home
  users+=("$(id -u)")
  if [[ -n ${SUDO_USER:-} ]]; then
    users+=("$SUDO_USER")
  fi
  if [[ -n ${PKEXEC_UID:-} ]]; then
    users+=("$PKEXEC_UID")
  fi
  for u in "${users[@]}"; do
    home=$(_mk_guard_nss_home "$u")
    if [[ -n $home ]]; then
      printf '%s\n' "$home"
    fi
    if [[ -n ${MOTANKA_ROOT:-} ]]; then
      home=$(_mk_guard_passwd_home "$MOTANKA_ROOT/etc/passwd" "$u")
      if [[ -n $home ]]; then
        printf '%s%s\n' "$MOTANKA_ROOT" "$home"
      fi
    fi
  done
}

# mk_guard_protected_marker: prints the first Protected_Host marker found
# and returns 0, or returns 1 if there is none.
mk_guard_protected_marker() {
  local m home
  for m in "$MK_PROTECTED_MARKER" ${MOTANKA_ROOT:+"$MOTANKA_ROOT$MK_PROTECTED_MARKER"}; do
    if [[ -e $m || -L $m ]]; then
      printf '%s\n' "$m"
      return 0
    fi
  done
  while IFS= read -r home; do
    m="$home/$MK_USER_PROTECTED_MARKER"
    if [[ -e $m || -L $m ]]; then
      printf '%s\n' "$m"
      return 0
    fi
  done < <(mk_guard_user_homes)
  return 1
}

# mk_guard_protected_host: exits 7 on a Protected_Host.
mk_guard_protected_host() {
  local marker
  if marker=$(mk_guard_protected_marker); then
    mk_die "$MK_EXIT_GUARD" "refused: this machine is a Protected_Host ($marker exists); no build and no flag changes it"
  fi
}

# mk_guard_is_dev_build: 0 if the DEV_BUILD marker exists.
mk_guard_is_dev_build() {
  [[ -e $MK_DEV_BUILD_MARKER ]] ||
    [[ -n ${MOTANKA_ROOT:-} && -e $MOTANKA_ROOT$MK_DEV_BUILD_MARKER ]]
}

# mk_guard_virt: prints what systemd-detect-virt reports, "none" when it
# reports nothing or is missing.
mk_guard_virt() {
  local virt=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null || true)
  fi
  virt=${virt%%$'\n'*}
  printf '%s\n' "${virt:-none}"
}

# mk_guard_flag_given <args...>: 0 if --i-know-this-is-not-a-vm is among
# the arguments before a "--".
mk_guard_flag_given() {
  local a
  for a in "$@"; do
    [[ $a == -- ]] && return 1
    [[ $a == "$MK_NOT_A_VM_FLAG" ]] && return 0
  done
  return 1
}

# mk_guard_dev_build <args...>: the Dev_Build check, given the subcommand's
# arguments. Exits 7 on a Dev_Build outside a VM without the flag, and 2
# when the flag is given to a published build.
mk_guard_dev_build() {
  local flag=0 virt
  if mk_guard_flag_given "$@"; then
    flag=1
  fi
  if ! mk_guard_is_dev_build; then
    if ((flag)); then
      mk_die "$MK_EXIT_USAGE" "$MK_NOT_A_VM_FLAG is accepted by development builds only"
    fi
    return 0
  fi
  virt=$(mk_guard_virt)
  if [[ $virt != none ]]; then
    return 0
  fi
  if ((flag)); then
    mk_warn "development build outside a virtual machine; continuing because $MK_NOT_A_VM_FLAG was given"
    return 0
  fi
  mk_die "$MK_EXIT_GUARD" "refused: this is a development build and systemd-detect-virt reports no virtual machine; test it in a VM (test/vm/), or pass $MK_NOT_A_VM_FLAG"
}

# mk_guards <args...>: both guards in order, for install, remove, update and
# rollback, before their options are parsed.
mk_guards() {
  mk_guard_protected_host
  mk_guard_dev_build "$@"
}
