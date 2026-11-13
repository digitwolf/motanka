#!/usr/bin/env bash
# shellcheck disable=SC2329 # check functions are called by name
# Guest half of test/vm/tests/session.sh. Runs INSIDE a throwaway test VM as
# user tester (passwordless sudo in the VM). Never run it on a real machine:
# it installs and purges packages and configures tty1 autologin.
#
# Usage: bash session-guest.sh <phase> <release>
#
# Work folder /tmp/motanka-session-test (T): debs/ holds the motanka-stack
# and motanka-core .debs, debcheck is tools/debcheck, logs/ collects output,
# shot.png is the screenshot. Every check prints "PASS: ..." or "FAIL: ...";
# the exit code is 1 if any check failed in the phase.
#
# Phases, in the order the host runs them:
#   prepare  install grim (the screenshot tool) and record the package list.
#   install  apt-get install the local .debs; tools/debcheck on motanka-core;
#            the session entry; /usr/share/omarchy links to the overlay
#            omarchy-view (bin: the Wrappers; the rest: the vendored tree,
#            which is root-owned and writable by nobody else); the
#            Wrappers; the dconf profile and the compiled database (read
#            with DCONF_PROFILE=motanka; the default profile does not see
#            it); the target's .wants link; the portal file; the DEV_BUILD
#            marker; no autostart file and no ~/.config/systemd.
#   session  round 1: tty1 autologin runs the launcher. Hyprland runs from
#            /opt/motanka/bin under the Stack's start-hyprland, inside the
#            uwsm unit wayland-wm@*.service, whose unit file is the Stack's
#            and whose ExecStart is the Stack's uwsm; uwsm's signal handler
#            runs from /opt/motanka/libexec/uwsm. The compositor's
#            environment has XDG_CURRENT_DESKTOP=Motanka:Hyprland,
#            XDG_SESSION_DESKTOP=motanka, DCONF_PROFILE=motanka,
#            OMARCHY_PATH=/usr/share/omarchy and /opt/motanka/bin first on
#            PATH. motanka-session.target and motanka-session-cleanup.service
#            are active. omarchy-version through its Wrapper does not print
#            "dev"; pacman is not found on the session PATH; hyprctl lists
#            Virtual-1; grim takes a screenshot; no process has
#            LD_LIBRARY_PATH. Logout with "uwsm stop": the launcher ends,
#            its unit links are gone, and every Session_Env_List variable of
#            the user manager has its value from before the session again,
#            or is unset.
#            round 2: the session starts again; the launcher is killed with
#            SIGKILL, then "uwsm stop" ends the session, and
#            motanka-session-cleanup.service alone restores the user
#            manager's environment.
#   purge    remove the autologin setup; purge the Motanka packages and
#            exactly the packages their install pulled in; the compiled dconf
#            database, the dconf profile, the session entry,
#            /usr/share/omarchy and /opt/motanka are gone; the package set
#            equals the one after prepare.
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

T=/tmp/motanka-session-test
L=$T/logs
PREFIX=/opt/motanka
LAUNCHER=$PREFIX/libexec/motanka/session
ENV_LIST=$PREFIX/share/motanka/session-env.list
DROPIN_DIR=/etc/systemd/system/getty@tty1.service.d
DROPIN=$DROPIN_DIR/autologin.conf
PROFILE=$HOME/.bash_profile
APT=(sudo env DEBIAN_FRONTEND=noninteractive apt-get -q -y -o DPkg::Lock::Timeout=300)
MOTANKA_PKGS=(motanka-core motanka-stack motanka-stack-hyprland motanka-stack-tools motanka-stack-libs
  motanka-stack-shell motanka-qt6)
UID_=$(id -u)
RT=/run/user/$UID_
export XDG_RUNTIME_DIR=$RT
export DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus

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
    echo "session-guest.sh: refusing to run outside a VM" >&2
    exit 7
  fi
  if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
    echo "session-guest.sh: refusing to run on a Protected_Host" >&2
    exit 7
  fi
}

installed_list() {
  # shellcheck disable=SC2016 # dpkg-query fields
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
    awk -F'\t' '$2 == "installed" || $2 == "config-files" || $2 == "half-installed" || $2 == "unpacked" || $2 == "half-configured" { print $1 }' |
    sed 's/:amd64$//' | LC_ALL=C sort -u
}

# wait_for <seconds> <command...>: 0 as soon as the command succeeds.
wait_for() {
  local n=$1 i
  shift
  for ((i = 0; i < n; i++)); do
    if "$@"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

hyprland_pid() {
  pgrep -u "$UID_" -x Hyprland | head -n 1 || true
}

launcher_running() {
  pgrep -u "$UID_" -f "$LAUNCHER" >/dev/null
}

hyprland_running() {
  pgrep -u "$UID_" -x Hyprland >/dev/null
}

no_session() {
  ! hyprland_running && ! launcher_running
}

# environ_of <pid>: the process's environment, one variable per line.
environ_of() {
  sudo cat "/proc/$1/environ" 2>/dev/null | tr '\0' '\n' || true
}

# --- phases -----------------------------------------------------------------

phase_prepare() {
  mkdir -p "$L"
  "${APT[@]}" update >"$L/apt-update.log" 2>&1 || {
    fail "apt-get update failed"
    show "$L/apt-update.log"
    return
  }
  if "${APT[@]}" install --no-install-recommends grim >"$L/prepare.log" 2>&1; then
    pass "installed the test tool grim"
  else
    fail "could not install grim"
    show "$L/prepare.log"
  fi
  installed_list >"$T/pkgs-before.txt"
  find /etc/dconf -maxdepth 2 2>/dev/null | LC_ALL=C sort >"$T/etc-dconf-before.txt" || true
  if [[ -e $DROPIN || -e $PROFILE ]]; then
    fail "$DROPIN or $PROFILE exists before the test"
  fi
}

phase_install() {
  local rc=0 p f target bad
  mkdir -p "$L"
  "${APT[@]}" install "$T"/debs/*.deb >"$L/install.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "apt-get installed the local .debs: $(cd "$T/debs" && echo ./*.deb)"
  else
    fail "apt-get install of the local .debs failed (exit $rc)"
    show "$L/install.log"
    return
  fi
  for p in motanka-core motanka-stack; do
    # shellcheck disable=SC2016 # dpkg-query fields
    if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null) == "ii " ]]; then
      # shellcheck disable=SC2016 # dpkg-query field
      pass "$p is installed ($(dpkg-query -W -f='${Version}' "$p"))"
    else
      fail "$p is not installed"
    fi
  done
  # shellcheck disable=SC2016 # dpkg-query field
  echo "motanka-core Depends: $(dpkg-query -W -f='${Depends}' motanka-core)"

  rc=0
  python3 "$T/debcheck" "$T"/debs/motanka-core_*.deb >"$L/debcheck.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "tools/debcheck passes on motanka-core"
  else
    fail "tools/debcheck found problems in motanka-core (exit $rc)"
    show "$L/debcheck.log"
  fi

  f=/usr/share/wayland-sessions/motanka.desktop
  if grep -qx 'DesktopNames=Motanka;Hyprland' "$f" 2>/dev/null && grep -qx "Exec=$LAUNCHER" "$f"; then
    pass "$f runs $LAUNCHER with DesktopNames=Motanka;Hyprland"
  else
    fail "$f is missing or wrong"
    show "$f"
  fi
  if [[ -x $LAUNCHER ]]; then
    pass "$LAUNCHER is executable"
  else
    fail "$LAUNCHER is missing or not executable"
  fi

  target=$(readlink -f /usr/share/omarchy 2>/dev/null || true)
  if [[ -L /usr/share/omarchy && $target == "$PREFIX/share/omarchy-view" &&
    $(readlink -f /usr/share/omarchy/bin) == "$PREFIX/bin" &&
    $(readlink -f /usr/share/omarchy/default) == "$PREFIX/share/omarchy/default" ]]; then
    pass "/usr/share/omarchy links to the overlay $PREFIX/share/omarchy-view (bin: the Wrappers)"
  else
    fail "/usr/share/omarchy is not a link to the overlay $PREFIX/share/omarchy-view (resolves to '${target:-nothing}')"
  fi
  bad=$(sudo find "$PREFIX/share/omarchy" ! -type l \( ! -user root -o ! -group root -o -perm /022 \) -print 2>/dev/null | head -n 5 || true)
  if [[ -d $PREFIX/share/omarchy/bin && -z $bad ]]; then
    pass "the vendored Upstream tree is root-owned and writable by no one else ($(sudo find "$PREFIX/share/omarchy" -type f | wc -l) files)"
  else
    fail "the vendored Upstream tree is missing or has files not owned by root or writable by others:"
    printf '%s\n' "$bad" | show
  fi
  if [[ -f $PREFIX/share/motanka/upstream.pin ]]; then
    awk -F'\t' '$1 == "stable" { print "vendored stable pin: " $2 " " $3 }' "$PREFIX/share/motanka/upstream.pin"
  fi
  if [[ -f $PREFIX/bin/omarchy-version && $(sed -n 2p "$PREFIX/bin/omarchy-version") == '# Motanka Wrapper for Upstream bin/omarchy-version'* ]]; then
    pass "omarchy-version has a Wrapper in $PREFIX/bin ($(find "$PREFIX/bin" -name 'omarchy-*' | wc -l) Wrappers)"
  else
    fail "$PREFIX/bin/omarchy-version is not a generated Wrapper"
  fi
  for f in package-map.tsv privileged.tsv home-paths.tsv migrations.tsv session-env.list upstream.pin DEV_BUILD; do
    if [[ -f $PREFIX/share/motanka/$f ]]; then
      pass "$PREFIX/share/motanka/$f is installed"
    else
      fail "$PREFIX/share/motanka/$f is missing"
    fi
  done
  if [[ -f $PREFIX/libexec/motanka/keys/motanka-archive.asc && -x /usr/bin/motanka ]]; then
    pass "the archive key and /usr/bin/motanka are installed"
  else
    fail "the archive key or /usr/bin/motanka is missing"
  fi
  if motanka --help >"$L/motanka-help.log" 2>&1; then
    pass "motanka --help runs"
  else
    fail "motanka --help failed"
    show "$L/motanka-help.log"
  fi

  if [[ $(cat /etc/dconf/profile/motanka 2>/dev/null) == $'user-db:motanka\nsystem-db:motanka' ]]; then
    pass "/etc/dconf/profile/motanka names the motanka user and system databases"
  else
    fail "/etc/dconf/profile/motanka is missing or wrong"
  fi
  if [[ -s /etc/dconf/db/motanka ]] && ! dpkg -S /etc/dconf/db/motanka >/dev/null 2>&1; then
    pass "the postinst compiled /etc/dconf/db/motanka (not owned by a package)"
  else
    fail "/etc/dconf/db/motanka is missing or owned by a package"
  fi
  f=$(DCONF_PROFILE=motanka dconf read /org/gnome/desktop/interface/color-scheme 2>&1 || true)
  if [[ $f == "'prefer-dark'" ]]; then
    pass "with DCONF_PROFILE=motanka, color-scheme is 'prefer-dark'"
  else
    fail "with DCONF_PROFILE=motanka, color-scheme is '$f'"
  fi
  f=$(env -u DCONF_PROFILE dconf read /org/gnome/desktop/interface/color-scheme 2>&1 || true)
  if [[ $f != "'prefer-dark'" ]]; then
    pass "the default dconf profile does not see the Motanka defaults (color-scheme '${f:-unset}')"
  else
    fail "the default dconf profile sees the Motanka defaults"
  fi
  if [[ ! -e $HOME/.config/dconf/motanka ]]; then
    pass "reading the Motanka settings created no ~/.config/dconf/motanka"
  else
    fail "$HOME/.config/dconf/motanka exists before any Motanka session"
  fi

  f=/usr/lib/systemd/user/motanka-session.target.wants/motanka-session-cleanup.service
  if [[ -L $f && $(readlink -f "$f") == /usr/lib/systemd/user/motanka-session-cleanup.service ]] &&
    dpkg -S "$f" >/dev/null 2>&1; then
    pass "motanka-session-cleanup.service is wanted by motanka-session.target through a package-owned link"
  else
    fail "$f is not a package-owned link to motanka-session-cleanup.service"
  fi
  if [[ -f /usr/share/xdg-desktop-portal/motanka-portals.conf ]]; then
    pass "/usr/share/xdg-desktop-portal/motanka-portals.conf is installed"
  else
    fail "/usr/share/xdg-desktop-portal/motanka-portals.conf is missing"
  fi
  if compgen -G "/etc/xdg/autostart/*motanka*" >/dev/null || [[ -e $HOME/.config/systemd ]]; then
    fail "an autostart file in /etc/xdg/autostart or ~/.config/systemd appeared"
  else
    pass "no autostart file in /etc/xdg/autostart and no ~/.config/systemd"
  fi
  if grep -q '^/etc/profile.d\|^/etc/environment' < <(dpkg -L motanka-core); then
    fail "motanka-core ships a file under /etc/profile.d or /etc/environment"
  else
    pass "motanka-core ships nothing under /etc/profile.d or /etc/environment"
  fi

  # dbus-user-session may have been installed just now; the user manager
  # started by this SSH login then has no session bus yet.
  systemctl --user daemon-reload || true
  systemctl --user start dbus.socket 2>/dev/null || true
}

# start_session: tty1 autologin, the launcher runs once.
start_session() {
  touch "$T/launch"
  sudo systemctl restart getty@tty1
  if wait_for 120 hyprland_running; then
    return 0
  fi
  fail "Hyprland did not start on tty1 within 120 s"
  show "$L/launcher.log"
  # shellcheck disable=SC2024 # the log file belongs to the test user
  sudo journalctl _UID="$UID_" -n 80 --no-pager >"$L/user-journal.log" 2>&1 || true
  show "$L/user-journal.log"
  return 1
}

# check_env_restored <label>: every Session_Env_List variable has its value
# from env-before.txt again.
check_env_restored() {
  local label=$1 name before after bad=0
  systemctl --user show-environment | LC_ALL=C sort >"$L/env-after-$label.txt"
  while IFS= read -r name || [[ -n $name ]]; do
    name=${name%%#*}
    name=${name//[[:space:]]/}
    [[ -n $name ]] || continue
    before=$(grep "^$name=" "$L/env-before.txt" || true)
    after=$(grep "^$name=" "$L/env-after-$label.txt" || true)
    if [[ $before != "$after" ]]; then
      fail "$label: $name is '${after:-unset}' in the user manager, before the session it was '${before:-unset}'"
      bad=1
    fi
  done <"$ENV_LIST"
  if ((bad == 0)); then
    pass "$label: every Session_Env_List variable of the user manager is as before the session"
  fi
  if ! diff -u "$L/env-before.txt" "$L/env-after-$label.txt" >"$L/env-diff-$label.txt"; then
    echo "note: other differences in the user manager's environment ($label):"
    show "$L/env-diff-$label.txt"
  fi
}

uwsm_stop() {
  "$PREFIX/bin/uwsm" stop >>"$L/uwsm-stop.log" 2>&1 || true
}

session_round1() {
  local pid exe ppid pexe unit frag execstart envs path before_bin want sig wl found leaks out rc
  start_session || return 0
  pid=$(hyprland_pid)
  if [[ -z $pid ]]; then
    fail "round 1: Hyprland exited right after it started"
    show "$L/launcher.log"
    return 0
  fi
  exe=$(readlink "/proc/$pid/exe" || true)
  if [[ $exe == "$PREFIX/bin/Hyprland" ]]; then
    pass "Hyprland runs from $exe (pid $pid)"
  else
    fail "the running Hyprland is '$exe', not $PREFIX/bin/Hyprland"
  fi
  ppid=$(awk '$1 == "PPid:" { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
  pexe=$(readlink "/proc/$ppid/exe" || true)
  if [[ $pexe == "$PREFIX/bin/start-hyprland" ]]; then
    pass "its parent is $pexe"
  else
    fail "Hyprland's parent is '$pexe', not $PREFIX/bin/start-hyprland"
  fi
  unit=$(systemctl --user list-units --plain --no-legend --state=active 'wayland-wm@*.service' | awk 'NR == 1 { print $1 }' || true)
  frag=$(systemctl --user show -p FragmentPath --value "$unit" 2>/dev/null || true)
  execstart=$(systemctl --user show -p ExecStart --value "$unit" 2>/dev/null || true)
  if [[ -n $unit && $(readlink -f "$frag") == "$PREFIX/lib/systemd/user/wayland-wm@.service" && $execstart == *"$PREFIX/bin/uwsm"* ]]; then
    pass "uwsm runs the compositor as $unit, from the Stack's unit file and $PREFIX/bin/uwsm"
  else
    fail "no uwsm compositor unit from the Stack (unit '${unit:-none}', file '$frag')"
    echo "    ExecStart: $execstart"
  fi
  if grep -qF -- "${unit:-wayland-wm@}" "/proc/$pid/cgroup" 2>/dev/null; then
    pass "Hyprland is in the cgroup of $unit"
  else
    fail "Hyprland is not in the cgroup of the uwsm unit: $(cat "/proc/$pid/cgroup" 2>/dev/null)"
  fi
  if pgrep -u "$UID_" -f "$PREFIX/libexec/uwsm/signal-handler.sh" >/dev/null; then
    pass "uwsm's signal handler runs from $PREFIX/libexec/uwsm"
  else
    fail "no uwsm signal handler from $PREFIX/libexec/uwsm"
  fi

  envs=$(environ_of "$pid")
  printf '%s\n' "$envs" | LC_ALL=C sort >"$L/hyprland-environ.txt"
  for want in XDG_CURRENT_DESKTOP=Motanka:Hyprland XDG_SESSION_DESKTOP=motanka DCONF_PROFILE=motanka \
    OMARCHY_PATH=/usr/share/omarchy; do
    if grep -qx "$want" <<<"$envs"; then
      pass "the compositor has $want"
    else
      fail "the compositor lacks $want (has: $(grep "^${want%%=*}=" <<<"$envs" || echo unset))"
    fi
  done
  path=$(sed -n 's/^PATH=//p' <<<"$envs")
  before_bin=":${path%%"$PREFIX/bin"*}"
  if [[ $path == "$PREFIX/bin:"* || $path == *":$PREFIX/bin:"* ]] && [[ $before_bin != *:/usr/bin:* ]]; then
    pass "the compositor's PATH has $PREFIX/bin before /usr/bin: $path"
  else
    fail "the compositor's PATH does not have $PREFIX/bin before /usr/bin: $path"
  fi
  if grep -q '^LD_LIBRARY_PATH=' <<<"$envs"; then
    fail "the compositor has LD_LIBRARY_PATH"
  fi
  if grep -qx 'XDG_CURRENT_DESKTOP=Motanka:Hyprland' < <(systemctl --user show-environment); then
    pass "the user manager has XDG_CURRENT_DESKTOP=Motanka:Hyprland during the session"
  else
    fail "the user manager lacks XDG_CURRENT_DESKTOP=Motanka:Hyprland during the session"
  fi

  if wait_for 30 systemctl --user is-active --quiet motanka-session.target &&
    systemctl --user is-active --quiet motanka-session-cleanup.service; then
    pass "motanka-session.target and motanka-session-cleanup.service are active"
  else
    fail "motanka-session.target is $(systemctl --user is-active motanka-session.target || true), the cleanup unit $(systemctl --user is-active motanka-session-cleanup.service || true)"
  fi

  rc=0
  out=$(env -i HOME="$HOME" USER="$(id -un)" PATH="$path" XDG_RUNTIME_DIR="$RT" "$PREFIX/bin/omarchy-version" 2>&1) || rc=$?
  if [[ $out != *dev* ]]; then
    pass "omarchy-version through its Wrapper does not print 'dev' (output '${out:-}', exit $rc)"
  else
    fail "omarchy-version through its Wrapper prints '$out'"
  fi
  if env -i PATH="$path" bash -c 'command -v pacman' >/dev/null 2>&1; then
    fail "pacman is found on the session PATH: $(env -i PATH="$path" bash -c 'command -v pacman')"
  else
    pass "pacman is not on the session PATH"
  fi

  sig=""
  found=false
  for _ in $(seq 60); do
    sig=$(find "$RT/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2)
    if [[ -n $sig ]] && HYPRLAND_INSTANCE_SIGNATURE=$sig "$PREFIX/bin/hyprctl" monitors >"$L/hyprctl-monitors.txt" 2>&1 &&
      grep -q 'Virtual-1' "$L/hyprctl-monitors.txt"; then
      found=true
      break
    fi
    sleep 1
  done
  if $found; then
    pass "hyprctl monitors lists Virtual-1"
  else
    fail "hyprctl monitors does not list Virtual-1"
    show "$L/hyprctl-monitors.txt"
  fi
  if [[ -n $sig && -f $RT/hypr/$sig/hyprland.log ]]; then
    cp -f "$RT/hypr/$sig/hyprland.log" "$L/hyprland.log"
  fi
  wl=$(find "$RT" -maxdepth 1 -type s -name 'wayland-[0-9]*' -printf '%f\n' 2>/dev/null | sort | head -n 1)
  rm -f "$T/shot.png"
  if [[ -n $wl ]] && WAYLAND_DISPLAY=$wl grim "$T/shot.png" >"$L/grim.log" 2>&1 &&
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

  uwsm_stop
  if wait_for 60 no_session; then
    pass "round 1: uwsm stop ended the compositor and the launcher"
  else
    fail "round 1: the session did not end within 60 s of uwsm stop"
  fi
  if [[ -n $(find "$RT/systemd/user" -maxdepth 1 -type l -lname "$PREFIX/*" 2>/dev/null || true) ]]; then
    fail "round 1: the launcher left uwsm unit links in $RT/systemd/user"
  else
    pass "round 1: no uwsm unit links left in $RT/systemd/user"
  fi
  if systemctl --user is-active --quiet motanka-session.target; then
    fail "round 1: motanka-session.target is still active"
  else
    pass "round 1: motanka-session.target is inactive"
  fi
  check_env_restored round1
}

session_round2() {
  local lpid
  start_session || return 0
  wait_for 30 systemctl --user is-active --quiet motanka-session.target || true
  lpid=$(pgrep -u "$UID_" -f "$LAUNCHER" | head -n 1 || true)
  if [[ -z $lpid ]]; then
    fail "round 2: no launcher process found"
    return 0
  fi
  kill -KILL "$lpid"
  echo "round 2: killed the launcher (pid $lpid)"
  uwsm_stop
  if wait_for 60 no_session; then
    pass "round 2: uwsm stop ended the compositor after the launcher was killed"
  else
    fail "round 2: the session did not end within 60 s of uwsm stop"
  fi
  if sudo journalctl _UID="$UID_" -t motanka --since "-5min" --no-pager 2>/dev/null | grep -q 'restored the user manager'; then
    pass "round 2: motanka-session-cleanup.service restored the environment (journal)"
  else
    echo "note: no 'restored the user manager' journal entry from the cleanup unit"
  fi
  check_env_restored round2
  # The killed launcher could not remove its unit links; they are only in
  # the runtime folder and the next launcher replaces them.
  find "$RT/systemd/user" -maxdepth 1 -type l -lname "$PREFIX/*" -printf 'note: left by the killed launcher: %f\n' 2>/dev/null || true
}

session_teardown() {
  local id
  sudo rm -f -- "$DROPIN"
  sudo rmdir -- "$DROPIN_DIR" 2>/dev/null || true
  rm -f -- "$PROFILE" "$T/launch"
  sudo systemctl daemon-reload
  for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$0 ~ /tty1/ { print $1 }'); do
    sudo loginctl terminate-session "$id" 2>/dev/null || true
  done
  sudo systemctl restart getty@tty1 2>/dev/null || true
  if ! wait_for 30 no_session; then
    fail "the Motanka session still runs after teardown"
    pkill -KILL -u "$UID_" -x Hyprland || true
  fi
  find "$RT/systemd/user" -maxdepth 1 -type l -lname "$PREFIX/*" -delete 2>/dev/null || true
}

phase_session() {
  mkdir -p "$L"
  systemctl --user show-environment | LC_ALL=C sort >"$L/env-before.txt"
  sudo mkdir -p "$DROPIN_DIR"
  # shellcheck disable=SC2016 # $TERM is for systemd, not this shell
  printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$(id -un)" |
    sudo tee "$DROPIN" >/dev/null
  cat >"$PROFILE" <<EOF
if [ "\$(tty)" = /dev/tty1 ] && [ -e $T/launch ]; then
  rm -f $T/launch
  exec $LAUNCHER >>$L/launcher.log 2>&1
fi
EOF
  sudo systemctl daemon-reload
  session_round1 || true
  session_round2 || true
  # shellcheck disable=SC2024 # the log file belongs to the test user
  sudo journalctl _UID="$UID_" -t motanka -t uwsm --no-pager >"$L/session-journal.log" 2>&1 || true
  session_teardown
}

phase_purge() {
  local rc=0 p f
  local -a present=() extra=()
  mkdir -p "$L"
  for p in "${MOTANKA_PKGS[@]}"; do
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
    fail "apt-get purge of the Motanka packages failed (exit $rc)"
    show "$L/purge.log"
  fi
  mapfile -t extra < <(installed_list | LC_ALL=C comm -13 "$T/pkgs-before.txt" -)
  if ((${#extra[@]} > 0)); then
    rc=0
    "${APT[@]}" purge "${extra[@]}" >"$L/purge-deps.log" 2>&1 || rc=$?
    if ((rc == 0)); then
      pass "purged the ${#extra[@]} packages the install pulled in"
    else
      fail "could not purge the packages the install pulled in (exit $rc)"
      show "$L/purge-deps.log"
    fi
  fi
  for f in /etc/dconf/db/motanka /etc/dconf/db/motanka.d /etc/dconf/profile/motanka /usr/share/omarchy \
    /usr/share/wayland-sessions/motanka.desktop /usr/lib/systemd/user/motanka-session.target "$PREFIX"; do
    if [[ -e $f || -L $f ]]; then
      fail "$f still exists after purge"
    else
      pass "$f is gone"
    fi
  done
  find /etc/dconf -maxdepth 2 2>/dev/null | LC_ALL=C sort >"$L/etc-dconf-after.txt" || true
  if cmp -s "$T/etc-dconf-before.txt" "$L/etc-dconf-after.txt"; then
    pass "/etc/dconf has the same entries as before the install"
  else
    fail "/etc/dconf differs from before the install:"
    diff "$T/etc-dconf-before.txt" "$L/etc-dconf-after.txt" | show
  fi
  if [[ -e $HOME/.config/systemd ]]; then
    fail "$HOME/.config/systemd exists: the session enabled user units per user"
  else
    pass "no ~/.config/systemd"
  fi
  if [[ -n $(installed_list | LC_ALL=C comm -3 "$T/pkgs-before.txt" -) ]]; then
    fail "the package set differs from before the install:"
    installed_list | LC_ALL=C comm -3 "$T/pkgs-before.txt" - | show
  else
    pass "the package set equals the one before the install"
  fi
}

main() {
  (($# == 2)) || {
    echo "usage: bash session-guest.sh <prepare|install|session|purge> <release>" >&2
    exit 2
  }
  PHASE=$1
  RELEASE=$2
  guard
  echo "release $RELEASE, phase $PHASE"
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
