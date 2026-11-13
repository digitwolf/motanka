#!/usr/bin/env bash
# Guest half of test/vm/tests/stack.sh. Runs INSIDE a throwaway test VM as
# user tester (passwordless sudo in the VM). Never run it on a real machine:
# it installs and purges packages and configures tty1 autologin.
#
# Usage: bash stack-guest.sh <phase> <release> <hyprland-version>
#
# Work folder /tmp/motanka-stack-test (T): debs/ holds the motanka-stack
# .debs, debcheck is tools/debcheck, logs/ collects output, shot.png is the
# screenshot. Every check prints "PASS: ..." or "FAIL: ..."; the exit code
# is 1 if any check failed in the phase.
#
# Phases, in the order the host runs them:
#   prepare  install the test tools (binutils, grim; Ubuntu's hyprland on
#            resolute) and record the package list and the state of
#            Ubuntu's hyprland. The host takes the "before" Fingerprint
#            after this phase.
#   install  apt-get install the local .debs; tools/debcheck; paths;
#            RUNPATH, RPATH and ldd of every ELF under /opt/motanka; which
#            libstdc++ the Stack uses; Ubuntu's hyprland unchanged.
#   session  start /opt/motanka/bin/start-hyprland on tty1 through getty
#            autologin; Hyprland runs from /opt/motanka, hyprctl lists
#            Virtual-1, grim takes a screenshot, no process has
#            LD_LIBRARY_PATH, the loaded libstdc++ is the expected one. The
#            autologin drop-in and ~/.bash_profile are removed afterwards.
#   purge    purge the Stack packages and exactly the packages their install
#            pulled in; Ubuntu's hyprland unchanged; /opt/motanka gone. The
#            host takes the "after" Fingerprint after this phase.
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

T=/tmp/motanka-stack-test
L=$T/logs
PREFIX=/opt/motanka
STACK_PKGS=(motanka-stack motanka-stack-hyprland motanka-stack-tools motanka-stack-libs)
SYSTEM_LIB_DIRS=(/lib /lib64 /usr/lib /usr/lib64 /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu)
DROPIN_DIR=/etc/systemd/system/getty@tty1.service.d
DROPIN=$DROPIN_DIR/autologin.conf
PROFILE=$HOME/.bash_profile
APT=(sudo -E apt-get -q -y -o DPkg::Lock::Timeout=300)

fails=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$@" || true; }

guard() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -z $virt || $virt == none ]]; then
    echo "stack-guest.sh: refusing to run outside a VM" >&2
    exit 7
  fi
  if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
    echo "stack-guest.sh: refusing to run on a Protected_Host" >&2
    exit 7
  fi
}

# hyprland_state: version, status and dpkg --verify of Ubuntu's hyprland.
hyprland_state() {
  # shellcheck disable=SC2016 # dpkg-query fields
  dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' hyprland 2>/dev/null || echo "hyprland absent"
  sudo dpkg --verify hyprland 2>&1 || true
  if [[ -e /usr/bin/Hyprland ]]; then
    sha256sum /usr/bin/Hyprland
  fi
}

check_hyprland_unchanged() {
  local when=$1
  if [[ $RELEASE != resolute ]]; then
    pass "$when: Ubuntu's hyprland check skipped ($RELEASE has no hyprland package)"
    return 0
  fi
  hyprland_state >"$L/hyprland-$when.txt"
  if cmp -s "$T/hyprland-before.txt" "$L/hyprland-$when.txt"; then
    pass "$when: Ubuntu's hyprland is installed and unchanged ($(head -n 1 "$L/hyprland-$when.txt"))"
  else
    fail "$when: Ubuntu's hyprland changed"
    diff "$T/hyprland-before.txt" "$L/hyprland-$when.txt" | show
  fi
}

installed_list() {
  # shellcheck disable=SC2016 # dpkg-query fields
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
    awk -F'\t' '$2 == "installed" || $2 == "config-files" || $2 == "half-installed" || $2 == "unpacked" || $2 == "half-configured" { print $1 }' |
    sed 's/:amd64$//' | LC_ALL=C sort -u
}

is_elf() {
  [[ $(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]
}

in_system_dir() {
  local d=${1%/*} s
  for s in "${SYSTEM_LIB_DIRS[@]}"; do
    [[ $d == "$s" ]] && return 0
  done
  return 1
}

# --- phases -----------------------------------------------------------------

phase_prepare() {
  local -a tools=(binutils grim)
  mkdir -p "$L"
  if [[ $RELEASE == resolute ]]; then
    tools+=(hyprland)
  fi
  "${APT[@]}" update >"$L/apt-update.log" 2>&1 || {
    fail "apt-get update failed"
    show "$L/apt-update.log"
    return
  }
  if "${APT[@]}" install --no-install-recommends "${tools[@]}" >"$L/prepare.log" 2>&1; then
    pass "installed the test tools: ${tools[*]}"
  else
    fail "could not install the test tools: ${tools[*]}"
    show "$L/prepare.log"
  fi
  hyprland_state >"$T/hyprland-before.txt"
  installed_list >"$T/pkgs-before.txt"
  if [[ -e $DROPIN || -e $PROFILE ]]; then
    fail "$DROPIN or $PROFILE exists before the test"
  fi
  if grep -rqs toolchain-r /etc/apt/sources.list /etc/apt/sources.list.d/; then
    fail "the toolchain PPA is configured in the test VM"
  else
    pass "no toolchain PPA in the test VM's apt sources"
  fi
  echo "system libstdc++ provides up to: $(grep -ao 'GLIBCXX_3\.4\.[0-9]*' "$(readlink -f /usr/lib/x86_64-linux-gnu/libstdc++.so.6)" | sort -Vu | tail -n 1)"
  echo "kernel.apparmor_restrict_unprivileged_userns = $(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
}

check_paths() {
  local p f bad=0
  for p in "${STACK_PKGS[@]}"; do
    while IFS= read -r f; do
      case $f in
        /. | /opt | /usr | /usr/share | /usr/share/doc | /usr/share/lintian | /usr/share/lintian/overrides) ;;
        "$PREFIX" | "$PREFIX"/*) ;;
        /usr/share/doc/"$p" | /usr/share/doc/"$p"/*) ;;
        /usr/share/lintian/overrides/"$p") ;;
        *)
          fail "$p installs $f outside $PREFIX"
          bad=1
          ;;
      esac
    done < <(dpkg -L "$p")
  done
  if ((bad == 0)); then
    pass "every Stack file is under $PREFIX (plus /usr/share/doc/<pkg> and lintian overrides)"
  fi
}

check_elves() {
  local f dyn runpath comp needs_stack line lib target n=0 bad=0
  local -a parts
  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    n=$((n + 1))
    dyn=$(readelf -d "$f" 2>/dev/null || true)
    if grep -q '(RPATH)' <<<"$dyn"; then
      fail "$f has an RPATH: $(grep '(RPATH)' <<<"$dyn")"
      bad=1
    fi
    runpath=$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]$/\1/p' <<<"$dyn")
    if [[ -n $runpath ]]; then
      IFS=: read -r -a parts <<<"$runpath"
      for comp in "${parts[@]}"; do
        if [[ $comp != "$PREFIX/lib" ]]; then
          fail "$f has RUNPATH '$runpath' (only $PREFIX/lib allowed)"
          bad=1
          break
        fi
      done
    fi
    grep -q '(NEEDED)' <<<"$dyn" || continue
    ldd "$f" >"$L/ldd.tmp" 2>&1 || true
    needs_stack=false
    while IFS= read -r line; do
      if [[ $line == *"not found"* ]]; then
        fail "$f: unresolved library: ${line//[[:space:]]/ }"
        bad=1
        continue
      fi
      [[ $line == *" => "* ]] || continue
      lib=${line#*=> }
      target=${lib%% (*}
      [[ $target == /* ]] || continue
      if [[ $target == "$PREFIX/lib/"* ]]; then
        needs_stack=true
      elif ! in_system_dir "$target"; then
        fail "$f resolves ${line%% =>*} from $target, outside $PREFIX/lib and the system library folders"
        bad=1
      fi
    done <"$L/ldd.tmp"
    if $needs_stack && [[ -z $runpath ]]; then
      case ${f##*/} in
        libstdc++.so.6 | libgcc_s.so.1) ;;
        *)
          fail "$f loads Stack libraries but has no RUNPATH"
          bad=1
          ;;
      esac
    fi
  done < <(sudo find "$PREFIX" -type f -print0)
  rm -f "$L/ldd.tmp"
  if ((n == 0)); then
    fail "no ELF file under $PREFIX"
  elif ((bad == 0)); then
    pass "$n ELF files: no RPATH, RUNPATH only $PREFIX/lib, every library resolves from $PREFIX/lib or the system"
  fi
}

check_cxx_runtime() {
  local got gcc
  got=$(ldd "$PREFIX/bin/Hyprland" | awk '$1 == "libstdc++.so.6" { print $3 }')
  gcc=$(ldd "$PREFIX/bin/Hyprland" | awk '$1 == "libgcc_s.so.1" { print $3 }')
  if [[ $RELEASE == noble ]]; then
    if [[ $got == "$PREFIX/lib/libstdc++.so.6" ]]; then
      pass "noble: Hyprland uses the bundled libstdc++ ($got)"
    else
      fail "noble: Hyprland uses libstdc++ from '${got:-nowhere}', expected $PREFIX/lib/libstdc++.so.6"
    fi
    if [[ -z $gcc || $gcc == "$PREFIX/lib/libgcc_s.so.1" ]]; then
      pass "noble: libgcc_s is the bundled one (${gcc:-not needed directly})"
    else
      fail "noble: Hyprland uses libgcc_s from $gcc"
    fi
  else
    if [[ $got == /usr/lib/x86_64-linux-gnu/libstdc++.so.6 ]]; then
      pass "resolute: Hyprland uses the system libstdc++ ($got)"
    else
      fail "resolute: Hyprland uses libstdc++ from '${got:-nowhere}', expected the system one"
    fi
    if compgen -G "$PREFIX/lib/libstdc++*" >/dev/null || compgen -G "$PREFIX/lib/libgcc_s*" >/dev/null; then
      fail "resolute: a C++ runtime is bundled in $PREFIX/lib"
    else
      pass "resolute: no C++ runtime bundled"
    fi
  fi
}

phase_install() {
  local p rc=0 v
  mkdir -p "$L"
  "${APT[@]}" install "$T"/debs/*.deb >"$L/install.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "apt-get installed the local Stack .debs: $(cd "$T/debs" && echo ./*.deb)"
  else
    fail "apt-get install of the Stack .debs failed (exit $rc)"
    show "$L/install.log"
    return
  fi
  for p in "${STACK_PKGS[@]}"; do
    # shellcheck disable=SC2016 # dpkg-query field
    if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null) == "ii " ]]; then
      pass "$p is installed"
    else
      fail "$p is not installed"
    fi
  done
  rc=0
  python3 "$T/debcheck" "$T"/debs/*.deb >"$L/debcheck.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "tools/debcheck passes on every Stack .deb"
  else
    fail "tools/debcheck found problems (exit $rc)"
    show "$L/debcheck.log"
  fi
  check_paths
  check_elves
  check_cxx_runtime
  v=$("$PREFIX/bin/Hyprland" --version 2>&1 | head -n 3 || true)
  if grep -qF "$HYPR_VERSION" <<<"$v"; then
    pass "Hyprland --version reports $HYPR_VERSION"
  else
    fail "Hyprland --version does not report $HYPR_VERSION:"
    printf '%s\n' "$v" | show
  fi
  if compgen -G "/etc/ld.so.conf.d/*motanka*" >/dev/null || grep -qs LD_LIBRARY_PATH /etc/environment; then
    fail "an ld.so.conf.d entry or LD_LIBRARY_PATH in /etc/environment appeared"
  else
    pass "no ld.so.conf.d entry and no LD_LIBRARY_PATH in /etc/environment"
  fi
  check_hyprland_unchanged after-install
}

session_teardown() {
  local id
  sudo rm -f -- "$DROPIN"
  sudo rmdir -- "$DROPIN_DIR" 2>/dev/null || true
  rm -f -- "$PROFILE"
  sudo systemctl daemon-reload
  for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$0 ~ /tty1/ { print $1 }'); do
    sudo loginctl terminate-session "$id" 2>/dev/null || true
  done
  sudo systemctl restart getty@tty1 2>/dev/null || true
  for _ in $(seq 30); do
    pgrep -u "$(id -u)" -x Hyprland >/dev/null || break
    sleep 1
  done
  if pgrep -u "$(id -u)" -x Hyprland >/dev/null; then
    fail "Hyprland still runs after the session was terminated"
    pkill -KILL -u "$(id -u)" -x Hyprland || true
  fi
}

phase_session() {
  session_run || true
  session_teardown
}

session_run() {
  local pid exe rt sig wl found leaks lib want
  mkdir -p "$L" "$T/xdg/config" "$T/xdg/data" "$T/xdg/state" "$T/xdg/cache"
  sudo mkdir -p "$DROPIN_DIR"
  # shellcheck disable=SC2016 # $TERM is for systemd, not this shell
  printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$(id -un)" |
    sudo tee "$DROPIN" >/dev/null
  # Hyprland's own config, data and cache go to the work folder, not $HOME.
  cat >"$PROFILE" <<EOF
if [ "\$(tty)" = /dev/tty1 ] && [ -x $PREFIX/bin/start-hyprland ]; then
  export XDG_CONFIG_HOME=$T/xdg/config XDG_DATA_HOME=$T/xdg/data XDG_STATE_HOME=$T/xdg/state XDG_CACHE_HOME=$T/xdg/cache
  export PATH=$PREFIX/bin:\$PATH
  exec $PREFIX/bin/start-hyprland --path $PREFIX/bin/Hyprland >$T/logs/start-hyprland.log 2>&1
fi
EOF
  sudo systemctl daemon-reload
  sudo systemctl restart getty@tty1

  pid=""
  for _ in $(seq 90); do
    pid=$(pgrep -u "$(id -u)" -x Hyprland | head -n 1 || true)
    [[ -n $pid ]] && break
    sleep 1
  done
  if [[ -z $pid ]]; then
    fail "Hyprland did not start on tty1 within 90 s"
    show "$T/logs/start-hyprland.log"
    return
  fi
  exe=$(readlink "/proc/$pid/exe" || true)
  if [[ $exe == "$PREFIX/bin/Hyprland" ]]; then
    pass "Hyprland runs from $exe (pid $pid) under start-hyprland"
  else
    fail "the running Hyprland is $exe, not $PREFIX/bin/Hyprland"
  fi

  rt=/run/user/$(id -u)
  sig=""
  found=false
  for _ in $(seq 60); do
    sig=$(find "$rt/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2)
    if [[ -n $sig ]] && HYPRLAND_INSTANCE_SIGNATURE=$sig XDG_RUNTIME_DIR=$rt \
      "$PREFIX/bin/hyprctl" monitors >"$L/hyprctl-monitors.txt" 2>&1 &&
      grep -q 'Virtual-1' "$L/hyprctl-monitors.txt"; then
      found=true
      break
    fi
    sleep 1
  done
  if $found; then
    pass "hyprctl monitors lists Virtual-1: $(grep -m1 'Virtual-1' "$L/hyprctl-monitors.txt")"
  else
    fail "hyprctl monitors does not list Virtual-1"
    show "$L/hyprctl-monitors.txt"
  fi
  if [[ -n $sig && -f $rt/hypr/$sig/hyprland.log ]]; then
    cp -f "$rt/hypr/$sig/hyprland.log" "$L/hyprland.log"
    grep -E 'Renderer:|drm: Starting backend' "$L/hyprland.log" | head -n 3 || true
  fi

  wl=$(find "$rt" -maxdepth 1 -type s -name 'wayland-[0-9]*' -printf '%f\n' 2>/dev/null | sort | head -n 1)
  rm -f "$T/shot.png"
  if [[ -n $wl ]] && XDG_RUNTIME_DIR=$rt WAYLAND_DISPLAY=$wl grim "$T/shot.png" >"$L/grim.log" 2>&1 &&
    [[ $(head -c 8 "$T/shot.png" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]]; then
    pass "grim captured a screenshot from $wl ($(stat -c %s "$T/shot.png") bytes)"
  else
    fail "grim could not capture a screenshot (socket '${wl:-none}')"
    show "$L/grim.log"
  fi

  # shellcheck disable=SC2016 # the script runs in the root shell
  leaks=$(sudo bash -c 'for f in /proc/[0-9]*/environ; do
      if tr "\0" "\n" <"$f" 2>/dev/null | grep -q "^LD_LIBRARY_PATH="; then
        p=${f#/proc/}; p=${p%/environ}
        printf "%s %s\n" "$p" "$(tr "\0" " " <"/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"
      fi
    done')
  if [[ -z $leaks ]]; then
    pass "no process has LD_LIBRARY_PATH in its environment"
  else
    fail "processes with LD_LIBRARY_PATH:"
    printf '%s\n' "$leaks" | show
  fi

  lib=$(sudo grep -o '/[^ ]*libstdc++\.so[^ ]*' "/proc/$pid/maps" | sort -u | head -n 1 || true)
  if [[ $RELEASE == noble ]]; then
    want=$PREFIX/lib/libstdc++.so.6
  else
    want=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
  fi
  if [[ $(readlink -f "${lib:-/nonexistent}" 2>/dev/null) == "$(readlink -f "$want")" ]]; then
    pass "the running Hyprland has $lib mapped"
  else
    fail "the running Hyprland maps libstdc++ '${lib:-none}', expected $want"
  fi
  check_hyprland_unchanged after-session
}

phase_purge() {
  local rc=0 p
  local -a present=() extra=()
  mkdir -p "$L"
  for p in "${STACK_PKGS[@]}"; do
    if dpkg-query -W "$p" >/dev/null 2>&1; then
      present+=("$p")
    fi
  done
  if ((${#present[@]} > 0)); then
    "${APT[@]}" purge "${present[@]}" >"$L/purge.log" 2>&1 || rc=$?
  fi
  if ((rc == 0)); then
    pass "purged ${present[*]:-nothing}"
  else
    fail "apt-get purge of the Stack failed (exit $rc)"
    show "$L/purge.log"
  fi
  mapfile -t extra < <(installed_list | LC_ALL=C comm -13 "$T/pkgs-before.txt" -)
  if ((${#extra[@]} > 0)); then
    rc=0
    "${APT[@]}" purge "${extra[@]}" >"$L/purge-deps.log" 2>&1 || rc=$?
    if ((rc == 0)); then
      pass "purged the ${#extra[@]} packages the Stack pulled in"
    else
      fail "could not purge the packages the Stack pulled in (exit $rc)"
      show "$L/purge-deps.log"
    fi
  fi
  if [[ -e $PREFIX ]]; then
    fail "$PREFIX still exists after purge:"
    sudo find "$PREFIX" | head -n 20 | show
  else
    pass "$PREFIX is gone"
  fi
  if [[ -n $(installed_list | LC_ALL=C comm -3 "$T/pkgs-before.txt" -) ]]; then
    fail "the package set differs from before the install:"
    installed_list | LC_ALL=C comm -3 "$T/pkgs-before.txt" - | show
  else
    pass "the package set equals the one before the install"
  fi
  check_hyprland_unchanged after-purge
}

main() {
  (($# == 3)) || {
    echo "usage: bash stack-guest.sh <prepare|install|session|purge> <release> <hyprland-version>" >&2
    exit 2
  }
  PHASE=$1
  RELEASE=$2
  HYPR_VERSION=$3
  guard
  case $PHASE in
    prepare) phase_prepare ;;
    install) phase_install ;;
    session) phase_session ;;
    purge) phase_purge ;;
    *)
      echo "unknown phase '$PHASE'" >&2
      exit 2
      ;;
  esac
  exit $((fails > 0 ? 1 : 0))
}

main "$@"
