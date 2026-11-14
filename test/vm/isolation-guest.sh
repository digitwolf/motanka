#!/usr/bin/env bash
# shellcheck disable=SC2329 # check functions are called by name
# Guest half of test/vm/tests/isolation.sh (task 15.5; requirements 5.3,
# 5.5, 5.7, 5.9, 5.10, 5.11). Runs INSIDE a throwaway test VM as user
# tester (passwordless sudo in the VM). Never run it on a real machine: it
# configures GDM autologin and restarts the display manager.
#
# Usage: bash isolation-guest.sh <phase> <release> [arguments...]
#
# The Other_Session is GNOME ("ubuntu" session) through GDM autologin. Work
# folder /tmp/motanka-isolation-test (T): logs/ collects output, state/
# holds the views. Every check prints "PASS: ..." or "FAIL: ..."; the exit
# code is 1 if any check failed in the phase.
#
# Phases, in the order the host runs them:
#   other <label>  log tester into GNOME through GDM autologin, wait until
#                  gnome-shell runs and graphical-session.target is active,
#                  then (unless <label> is "warmup") record the view of the
#                  Other_Session in state/view-<label>/ and check it; log
#                  out and restore the GDM and AccountsService files.
#                  The view, with the GNOME session's own environment
#                  (gnome-shell's /proc/<pid>/environ):
#                    env.txt        that environment, sorted; VOLATILE
#                                   variables keep their name only
#                    user-env.txt   systemctl --user show-environment, the
#                                   same way
#                    units.txt      the user manager's enabled unit files
#                    dconf.ini      dconf dump / (the default profile)
#                    shell.txt      what an interactive bash finds for
#                                   pacman, yay, omarchy-theme-set,
#                                   omarchy-menu, hyprctl, uwsm, walker
#                    autostart.txt  autostart entries GNOME starts
#                    menu.txt       application entries GNOME shows
#                    fonts.txt      fc-list families
#                    etc-env.txt    /etc/profile.d, /etc/environment and
#                                   ~/.config/environment.d (5.3)
#                  Checks: the GNOME session runs; zero Motanka user units
#                  are active and zero processes run from /opt/motanka
#                  (5.5); the interactive shell finds no Shim and no
#                  Motanka command (5.9).
#   other-in <label>
#                  the same, but stays logged in, so that the host can take
#                  the Fingerprint from the running Other_Session
#   other-out      log out of GNOME (after other-in)
#   owned          state/owned-packages.txt: the Motanka_Packages and the
#                  Foreign_Packages the System_Ledger records (pkg-installed,
#                  pkg-adopted, new installs in plan lines);
#                  state/owned-paths.txt: what those packages own (dpkg -L),
#                  the dconf database motanka-core's postinst compiles,
#                  /etc/ld.so.cache (ldconfig's cache of the installed
#                  libraries), the paths tester's User_Ledger records and,
#                  as trees, the Namespaced_Paths and the User_Ledger's own
#                  folder (test/vm/fpowned.py reads both)
#   motanka-settings
#                  while the Motanka session runs (round-trip guest phase
#                  "login" before it): set the cursor theme and the colour
#                  scheme with gsettings in the session's environment;
#                  the Motanka dconf database (DCONF_PROFILE=motanka) has
#                  them afterwards.
#   compare <a> <b>
#                  each part of view <b> equals view <a>: dconf.ini (5.7),
#                  user-env.txt (5.11) and the rest (5.10). A difference
#                  is printed as a unified diff.
set -euo pipefail
export LC_ALL=C.UTF-8

phase=${1:-}
release=${2:-}
if (($# >= 2)); then
  shift 2
else
  set --
fi
ARGS=("$@")
T=/tmp/motanka-isolation-test
L=$T/logs
S=$T/state
PREFIX=/opt/motanka
UID_=$(id -u)
GENV=()
fails=0
mkdir -p "$L" "$S"

# Variables whose value changes from one login to the next; their names
# are compared, their values are not.
VOLATILE='^(XDG_SESSION_ID|INVOCATION_ID|JOURNAL_STREAM|MANAGERPID|MANAGERPIDFDID|SYSTEMD_EXEC_PID|XAUTHORITY|SESSION_MANAGER|DESKTOP_STARTUP_ID|GIO_LAUNCHED_DESKTOP_FILE_PID|MEMORY_PRESSURE_WATCH|MEMORY_PRESSURE_WRITE|LISTEN_PID|LISTEN_FDS|LISTEN_FDNAMES|NOTIFY_SOCKET|WATCHDOG_PID|WATCHDOG_USEC|GNOME_SETUP_DISPLAY|XDG_ACTIVATION_TOKEN|_|SHLVL|PWD|OLDPWD)='

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$@" 2>/dev/null || true; }

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

shell_pid() {
  pgrep -u "$UID_" -x gnome-shell | head -n 1 || true
}
gnome_running() {
  [[ -n $(shell_pid) ]] && systemctl --user is-active --quiet graphical-session.target
}
gnome_gone() {
  [[ -z $(shell_pid) ]]
}
gnome_env() {
  local pid
  pid=$(shell_pid)
  GENV=()
  if [[ -n $pid && -r /proc/$pid/environ ]]; then
    mapfile -d '' -t GENV <"/proc/$pid/environ"
  fi
}
# as_gnome <command...>: runs it with the GNOME session's environment.
as_gnome() {
  env -i "${GENV[@]}" "$@"
}
# strip_volatile: sorted lines, VOLATILE values replaced by "<volatile>".
strip_volatile() {
  sed -E "s/${VOLATILE}.*/\\1=<volatile>/" | LC_ALL=C sort
}

# --- the restore list (GDM and AccountsService files) ---------------------

save_path() {
  local f=$1 b
  if sudo test -e "$f"; then
    b=$S/restore/$(printf '%s' "$f" | tr '/' '_')
    mkdir -p "$S/restore"
    sudo cp -a -- "$f" "$b"
    printf '%s\t%s\n' "$f" "$b" >>"$S/restore.tsv"
  else
    printf '%s\t-\n' "$f" >>"$S/restore.tsv"
  fi
}
restore_paths() {
  local f b
  [[ -f $S/restore.tsv ]] || return 0
  while IFS=$'\t' read -r f b; do
    case $b in
      -) sudo rm -f -- "$f" ;;
      *) sudo cp -a -- "$b" "$f" ;;
    esac
  done < <(tac "$S/restore.tsv")
  rm -f -- "$S/restore.tsv"
}

gnome_login() {
  local acc=/var/lib/AccountsService/users/$USER conf=/etc/gdm3/custom.conf
  rm -f "$S/restore.tsv"
  save_path "$conf"
  save_path "$acc"
  printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER" | sudo tee "$conf" >/dev/null
  printf '[User]\nSession=ubuntu\nXSession=\nSystemAccount=false\n' | sudo tee "$acc" >/dev/null
  sudo systemctl restart accounts-daemon
  sudo systemctl restart display-manager
}

gnome_logout() {
  local id
  restore_paths
  sudo systemctl restart accounts-daemon || true
  sudo systemctl restart display-manager || true
  if ! wait_for 60 gnome_gone; then
    for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3 == u { print $1 }'); do
      if [[ $(loginctl show-session "$id" -p Type --value 2>/dev/null) != tty ]]; then
        sudo loginctl terminate-session "$id" 2>/dev/null || true
      fi
    done
  fi
  if wait_for 60 gnome_gone; then
    pass "logged out of GNOME"
  else
    fail "gnome-shell of $USER still runs after logout"
  fi
}

# --- the view ---------------------------------------------------------------

# desktop_applies <file> <desktops>: 0 if an entry is shown or started in a
# session whose XDG_CURRENT_DESKTOP is <desktops> (colon-separated).
desktop_applies() {
  python3 -I - "$1" "$2" <<'EOF'
import configparser, sys
path, desktops = sys.argv[1], sys.argv[2].split(":")
cp = configparser.RawConfigParser(strict=False, interpolation=None)
cp.optionxform = str
try:
    cp.read(path, encoding="utf-8")
    e = cp["Desktop Entry"]
except Exception:
    sys.exit(1)
if e.get("Hidden", "false").strip().lower() == "true":
    sys.exit(1)
only = [d for d in e.get("OnlyShowIn", "").split(";") if d]
nots = [d for d in e.get("NotShowIn", "").split(";") if d]
if only and not set(only) & set(desktops):
    sys.exit(1)
if set(nots) & set(desktops):
    sys.exit(1)
sys.exit(0)
EOF
}

# list_entries <kind> <desktops> <folder...>: the entry names that apply,
# the first folder winning for a name (as XDG lookup does).
list_entries() {
  local kind=$1 desktops=$2 d f n
  shift 2
  declare -A seen=()
  for d in "$@"; do
    [[ -d $d ]] || continue
    while IFS= read -r f; do
      n=${f#"$d"/}
      [[ -n ${seen[$n]:-} ]] && continue
      seen[$n]=1
      if [[ $kind == menu ]] && grep -qiE '^NoDisplay *= *true' "$f" 2>/dev/null; then
        continue
      fi
      if desktop_applies "$f" "$desktops"; then
        printf '%s\n' "$n"
      fi
    done < <(find "$d" -name '*.desktop' -type f 2>/dev/null | LC_ALL=C sort)
  done | LC_ALL=C sort
}

record_view() {
  local v=$S/view-$1 desktops data_dirs line c
  local -a dirs=()
  rm -rf -- "$v"
  mkdir -p "$v"
  gnome_env
  printf '%s\n' "${GENV[@]}" | strip_volatile >"$v/env.txt"
  as_gnome systemctl --user show-environment 2>/dev/null | strip_volatile >"$v/user-env.txt"
  as_gnome systemctl --user list-unit-files --state=enabled --no-legend --plain 2>/dev/null |
    awk '{ print $1 }' | LC_ALL=C sort >"$v/units.txt"
  as_gnome dconf dump / >"$v/dconf.ini" 2>"$L/dconf-$1.err" || true
  for c in pacman yay omarchy-theme-set omarchy-menu hyprctl uwsm walker; do
    line=$(as_gnome bash -ic "command -v $c" 2>/dev/null </dev/null || true)
    printf '%s: %s\n' "$c" "${line:-not found}"
  done >"$v/shell.txt"
  desktops=$(printf '%s\n' "${GENV[@]}" | sed -n 's/^XDG_CURRENT_DESKTOP=//p')
  list_entries autostart "${desktops:-GNOME}" "$HOME/.config/autostart" /etc/xdg/autostart >"$v/autostart.txt"
  data_dirs=$(printf '%s\n' "${GENV[@]}" | sed -n 's/^XDG_DATA_DIRS=//p')
  dirs=("$HOME/.local/share/applications")
  IFS=: read -r -a _dd <<<"${data_dirs:-/usr/local/share:/usr/share}"
  for c in "${_dd[@]}"; do
    dirs+=("$c/applications")
  done
  list_entries menu "${desktops:-GNOME}" "${dirs[@]}" >"$v/menu.txt"
  as_gnome fc-list --format '%{family}\n' 2>/dev/null | LC_ALL=C sort -u >"$v/fonts.txt"
  {
    echo "# /etc/profile.d"
    { find /etc/profile.d -mindepth 1 -printf '%P\n' 2>/dev/null || true; } | LC_ALL=C sort
    echo "# /etc/environment"
    cat /etc/environment 2>/dev/null || true
    echo "# ~/.config/environment.d"
    { find "$HOME/.config/environment.d" -mindepth 1 -printf '%P\n' 2>/dev/null || true; } | LC_ALL=C sort
  } >"$v/etc-env.txt"
  echo "view $1: $(wc -l <"$v/env.txt") variables, $(wc -l <"$v/units.txt") enabled user units, $(grep -c '^\[' "$v/dconf.ini" || true) dconf sections, $(wc -l <"$v/menu.txt") menu entries"
}

check_view() {
  local v=$S/view-$1 units procs
  units=$(as_gnome systemctl --user list-units --all --no-legend --plain 2>/dev/null |
    awk '$3 == "active" { print $1 }' | grep -iE 'motanka|hypr|uwsm|wayland-wm|omarchy|waybar|mako|walker|elephant|swayosd|swaybg|hypridle' || true)
  if [[ -z $units ]]; then
    pass "$1: no Motanka user unit is active while GNOME runs (5.5)"
  else
    fail "$1: Motanka user units are active while GNOME runs (5.5): $(echo "$units" | tr '\n' ' ')"
  fi
  procs=$(for p in /proc/[0-9]*; do
    e=$(readlink "$p/exe" 2>/dev/null || true)
    if [[ $e == "$PREFIX"/* ]]; then
      printf '%s %s\n' "${p#/proc/}" "$e"
    fi
  done)
  if [[ -z $procs ]]; then
    pass "$1: no process runs from $PREFIX while GNOME runs (5.5)"
  else
    fail "$1: processes run from $PREFIX while GNOME runs (5.5): $(echo "$procs" | head -n 5 | tr '\n' ' ')"
  fi
  if grep -qv ': not found$' "$v/shell.txt"; then
    fail "$1: GNOME's interactive shell finds a Shim or a Motanka command (5.9):"
    grep -v ': not found$' "$v/shell.txt" | show
  else
    pass "$1: GNOME's interactive shell finds no Shim and no Motanka command (5.9)"
  fi
}

# phase_other [stay]: with "stay", leaves GNOME running.
phase_other() {
  local label=${ARGS[0]:-} stay=${1:-}
  if [[ -z $label ]]; then
    echo "usage: isolation-guest.sh other <release> <label>" >&2
    exit 2
  fi
  if ! systemctl is-active --quiet gdm3 2>/dev/null && ! systemctl is-active --quiet gdm 2>/dev/null; then
    fail "$label: GDM is not running; the isolation test needs the gnome-snaps variant"
    return 0
  fi
  gnome_login
  if ! wait_for 180 gnome_running; then
    fail "$label: GNOME did not start within 180 s"
    # shellcheck disable=SC2024 # the log file belongs to the test user
    sudo journalctl -b -n 120 --no-pager >"$L/gnome-$label-journal.log" 2>&1 || true
    show "$L/gnome-$label-journal.log"
    gnome_logout
    return 0
  fi
  pass "$label: GNOME runs (gnome-shell $(shell_pid))"
  # GNOME finishes its startup (settings daemons, autostart) after
  # gnome-shell is up.
  sleep 20
  if [[ $label != warmup ]]; then
    record_view "$label"
    check_view "$label"
  fi
  if [[ $stay != stay ]]; then
    gnome_logout
  fi
}

phase_owned() {
  local p
  {
    dpkg-query -W -f='${Package}\n' 'motanka' 'motanka-*' 2>/dev/null || true
    sudo awk -F'\t' '
      $3 == "pkg-installed" || $3 == "pkg-adopted" { print $4 }
      $3 == "plan" { n = split($4, w, " "); if (n >= 3 && w[1] == "Inst" && substr(w[3], 1, 1) == "(") { sub(/:[A-Za-z0-9]+$/, "", w[2]); print w[2] } }
    ' /var/lib/motanka/ledger 2>/dev/null || true
  } | LC_ALL=C sort -u >"$S/owned-packages.txt"
  {
    while IFS= read -r p; do
      dpkg -L "$p" 2>/dev/null || true
    done <"$S/owned-packages.txt"
    printf '%s\n' /etc/dconf/db/motanka /etc/ld.so.cache
    awk -F'\t' -v h="$HOME" '$3 != "setup-begin" && $3 != "setup-end" && $5 != "-" && $5 != "" { print h "/" $5 }' \
      "$HOME/.local/state/motanka/ledger" 2>/dev/null || true
    printf '%s/\n' "$HOME/.config/omarchy" "$HOME/.local/share/omarchy" "$HOME/.local/state/omarchy" \
      "$HOME/.config/dconf/motanka" "$HOME/.local/state/motanka"
  } | LC_ALL=C sort -u >"$S/owned-paths.txt"
  pass "owned by Motanka: $(wc -l <"$S/owned-packages.txt") packages, $(wc -l <"$S/owned-paths.txt") paths"
}

# --- the Motanka session's settings ----------------------------------------

# first_run_themed: Upstream's first-login provisioning
# (omarchy-provision-first-run, from Hyprland's autostart) has set its
# GNOME theme, which writes color-scheme, or has finished.
first_run_themed() {
  local st=$HOME/.local/state/omarchy
  [[ -e $st/done/first-run-user ]] ||
    grep -qE '(Completed|Failed): set GNOME theme' "$st/first-run.log" 2>/dev/null
}

motanka_settings_set() {
  [[ $(env -i HOME="$HOME" DCONF_PROFILE=motanka dconf read /org/gnome/desktop/interface/cursor-theme 2>/dev/null) == "'DMZ-White'" &&
  $(env -i HOME="$HOME" DCONF_PROFILE=motanka dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null) == "'prefer-light'" ]]
}

phase_motanka_settings() {
  local pid cursor scheme
  local -a senv=()
  pid=$(pgrep -u "$UID_" -x Hyprland | head -n 1 || true)
  if [[ -z $pid ]]; then
    fail "the Motanka session does not run"
    return 0
  fi
  mapfile -d '' -t senv <"/proc/$pid/environ"
  # Upstream's first run sets color-scheme itself; a change made before
  # that would be overwritten.
  if ! wait_for 180 first_run_themed; then
    echo "note: Upstream's first run did not reach its GNOME theme step within 180 s"
  fi
  env -i "${senv[@]}" gsettings set org.gnome.desktop.interface cursor-theme DMZ-White >"$L/settings.log" 2>&1 || true
  env -i "${senv[@]}" gsettings set org.gnome.desktop.interface color-scheme prefer-light >>"$L/settings.log" 2>&1 || true
  wait_for 10 motanka_settings_set || true
  cursor=$(env -i HOME="$HOME" DCONF_PROFILE=motanka dconf read /org/gnome/desktop/interface/cursor-theme 2>/dev/null || true)
  scheme=$(env -i HOME="$HOME" DCONF_PROFILE=motanka dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null || true)
  if [[ $cursor == "'DMZ-White'" && $scheme == "'prefer-light'" ]]; then
    pass "the Motanka session's cursor theme and colour scheme are in the Motanka dconf database"
  else
    fail "the Motanka dconf database has cursor-theme ${cursor:-unset} and color-scheme ${scheme:-unset}"
    show "$L/settings.log"
  fi
}

# --- compare ----------------------------------------------------------------

phase_compare() {
  local a=$S/view-${ARGS[0]:-} b=$S/view-${ARGS[1]:-} f crit
  if [[ ! -d $a || ! -d $b ]]; then
    fail "a view is missing: $a $b"
    return 0
  fi
  for f in dconf.ini user-env.txt env.txt units.txt shell.txt autostart.txt menu.txt fonts.txt etc-env.txt; do
    case $f in
      dconf.ini) crit=5.7 ;;
      user-env.txt) crit="5.10, 5.11" ;;
      etc-env.txt) crit="5.3, 5.10" ;;
      *) crit=5.10 ;;
    esac
    if diff -u "$a/$f" "$b/$f" >"$L/diff-$f.txt" 2>&1; then
      pass "the Other_Session's $f is the same as before installation ($crit)"
    else
      fail "the Other_Session's $f differs from before installation ($crit):"
      head -n 40 "$L/diff-$f.txt" | show
    fi
  done
}

case $phase in
  other) phase_other ;;
  other-in) phase_other stay ;;
  other-out) gnome_logout ;;
  owned) phase_owned ;;
  motanka-settings) phase_motanka_settings ;;
  compare) phase_compare ;;
  *)
    echo "isolation-guest.sh: unknown phase '$phase' (release ${release:-?})" >&2
    exit 2
    ;;
esac
exit $((fails > 0 ? 1 : 0))
