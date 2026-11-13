#!/usr/bin/env bash
# shellcheck disable=SC2329 # phase functions are called by name
# shellcheck disable=SC2088 # "~/..." in messages is literal text
# shellcheck disable=SC2024 # redirects write the test logs as tester on purpose
# Guest half of test/vm/tests/roundtrip.sh and test/vm/tests/remove-edge.sh
# (tasks 19.3, 19.4). Runs INSIDE a throwaway test VM as user tester, who
# has passwordless sudo there. Never run it on a real machine: it installs
# and removes Motanka and configures automatic login.
#
# Usage: bash remove-guest.sh <phase> <release> [arguments...]
#
# Layout in the VM:
#   /tmp/motanka-remove-test/www/repo   the signed test repository
#   /tmp/motanka-remove-test/logs/      logs, copied back by the host
#   /tmp/motanka-remove-test/state/     snapshots and values shared by phases
#   /home/tester/motanka/src/           the CLI under test (source tree)
#
# Phases (each prints PASS:/FAIL: lines and exits 1 if a check failed):
#   serve                 serve www/ on 127.0.0.1:8765
#   snapshot <label>      packages, manual marks and session entries
#   install               'motanka install --yes' from the source tree
#   interrupt             an install killed (SIGKILL to its process group)
#                         right after the keyring and source packages are
#                         installed; the System_Ledger keeps the open run
#   partial-setup         an interrupted per-user setup of tester: the
#                         User_Ledger library (the one user-setup uses)
#                         writes setup-begin, session files, files in
#                         Namespaced_Paths and a marked block in ~/.bashrc;
#                         then a temporary file and a torn ledger line, as a
#                         kill leaves them, and unledgered files inside the
#                         Namespaced_Paths
#   ledger-start          setup-begin and setup-end through the same
#                         library, standing in for a first login only when
#                         the login is skipped (the fallback of
#                         roundtrip.sh); it fails when tester already has
#                         a User_Ledger, for example from a real first
#                         login
#   other-ledger <user>   a User_Ledger in another user's home folder,
#                         written as that user
#   login                 automatic login of tester into the Motanka
#                         session (GDM, SDDM, or getty on tty1 when there
#                         is no display manager); the session runs, per-user
#                         setup ended, 'motanka remove --dry-run' exits 12
#                         while it runs, and a theme switch through the
#                         Upstream command inside the session
#   logout                restores the login configuration and ends the
#                         session
#   theme                 a theme switch through the Upstream command
#                         without a session (OMARCHY_THEME_HEADLESS=1)
#   menu-install          the smallest apt outcome of the Package_Map that
#                         is not installed, installed through the Helper
#                         (as root with PKEXEC_UID, as pkexec runs it)
#   webapp                a web app through the omarchy-webapp-install
#                         override, with a local icon; the override must
#                         report the entry it installed, which must carry
#                         OnlyShowIn=Motanka; and a menu-desktop ledger
#                         line; on failure the Wrapper, override, folder,
#                         ledger and journal are shown
#   capture-check [session|none]
#                         no unplanned entry in tester's User_Ledger, and
#                         (session, the default) the session capture was
#                         ended at logout; lists adopted and observed paths
#   remove-dry <cli> [user...]
#                         'motanka remove --dry-run' exits 0, prints the
#                         Plan, lists the menu package and the web app as
#                         kept and the given users as other users
#   remove <cli> <online|offline> [--purge]
#                         'motanka remove --yes' exits 0, offline inside
#                         'unshare --net' (no network at all); then: no
#                         motanka package known to dpkg, no /opt/motanka,
#                         no /usr/share/omarchy, no /var/lib/motanka, the
#                         ledger archived in /var/log, nothing left in
#                         /run/motanka, the session entries equal those of
#                         snapshot "before" (10.14), tester's Motanka
#                         folders gone, the menu package removed with
#                         --purge and kept without
# <cli> is "installed" (/usr/bin/motanka) or "source" (the source tree).
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

phase=${1:-}
release=${2:-}
if (($# >= 2)); then
  shift 2
else
  set --
fi
ARGS=("$@")
T=/tmp/motanka-remove-test
L=$T/logs
S=$T/state
PORT=8765
URI=http://127.0.0.1:$PORT/repo
CLI=$HOME/motanka/src/motanka
LEDGER=/var/lib/motanka/ledger
PREFIX=/opt/motanka
LAUNCHER=$PREFIX/libexec/motanka/session
WEBAPP_NAME="Motanka Roundtrip"
UID_=$(id -u)
RT=/run/user/$UID_
SENV=()
fails=0

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$@" 2>/dev/null || true; }

virt=$(systemd-detect-virt 2>/dev/null || true)
if [[ -z $virt || $virt == none ]]; then
  echo "remove-guest.sh: refusing to run outside a VM (systemd-detect-virt: ${virt:-unavailable})" >&2
  exit 1
fi
if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
  echo "remove-guest.sh: refusing to run on a Protected_Host" >&2
  exit 1
fi
case $release in
  noble | resolute) ;;
  *)
    echo "remove-guest.sh: unknown release '$release'" >&2
    exit 2
    ;;
esac
mkdir -p "$L" "$S"
chmod a+rx "$T"

# --- helpers ------------------------------------------------------------------

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

installed() {
  local s
  # shellcheck disable=SC2016 # dpkg-query field, not a shell variable
  s=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)
  [[ $s == installed ]]
}

# motanka_cmd <installed|source>: fills MCMD with the command that runs the
# CLI as root.
motanka_cmd() {
  if [[ $1 == installed ]]; then
    MCMD=(motanka)
  else
    MCMD=(bash "$CLI")
  fi
}

hyprland_running() {
  pgrep -u "$UID_" -x Hyprland >/dev/null
}

no_session() {
  ! pgrep -u "$UID_" -x Hyprland >/dev/null && ! pgrep -u "$UID_" -f "$LAUNCHER" >/dev/null
}

setup_done() {
  [[ -f $HOME/.local/state/motanka/ledger ]] &&
    grep -q $'\tsetup-end\t' "$HOME/.local/state/motanka/ledger"
}

# session_env: SENV holds the environment of the running compositor.
session_env() {
  local pid
  pid=$(pgrep -u "$UID_" -x Hyprland | head -n 1 || true)
  SENV=()
  if [[ -n $pid && -r /proc/$pid/environ ]]; then
    mapfile -d '' -t SENV <"/proc/$pid/environ"
  fi
}

detect_dm() {
  if systemctl is-active --quiet gdm3 2>/dev/null || systemctl is-active --quiet gdm 2>/dev/null; then
    echo gdm
  elif systemctl is-active --quiet sddm 2>/dev/null; then
    echo sddm
  fi
}

# save_path <path>: records the file or its absence for restore_paths.
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

# save_dir <path>: records that the folder must be deleted again if the
# test creates it.
save_dir() {
  if ! sudo test -d "$1"; then
    printf '%s\t+dir\n' "$1" >>"$S/restore.tsv"
  fi
}

restore_paths() {
  local f b
  [[ -f $S/restore.tsv ]] || return 0
  while IFS=$'\t' read -r f b; do
    case $b in
      -) sudo rm -f -- "$f" ;;
      +dir) sudo rmdir -- "$f" 2>/dev/null || true ;;
      *) sudo cp -a -- "$b" "$f" ;;
    esac
  done < <(tac "$S/restore.tsv")
  rm -f -- "$S/restore.tsv"
}

snapshot() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Status}\n' |
    awk -F'\t' '$3 != "not-installed" { print $1 "\t" $2 "\t" $3 }' | sort -u >"$S/$1.pkgs"
  apt-mark showmanual | sort -u >"$S/$1.manual"
  find /usr/share/wayland-sessions /usr/share/xsessions -maxdepth 1 -name '*.desktop' 2>/dev/null |
    sort >"$S/$1.sessions"
}

unfinished_runs() {
  awk -F'\t' '
    $3 == "run-begin" && !($2 in b) { b[$2] = 1; o[++n] = $2 }
    $3 == "run-end" { e[$2] = 1 }
    END { for (i = 1; i <= n; i++) if (!(o[i] in e)) print o[i] }' "$1"
}

# --- phases -------------------------------------------------------------------

phase_serve() {
  local i
  chmod -R a+rX "$T/www"
  setsid -f python3 -u -m http.server --bind 127.0.0.1 --directory "$T/www" "$PORT" \
    >"$L/http.log" 2>&1 </dev/null
  for ((i = 0; i < 50; i++)); do
    if curl -fsS -o /dev/null "$URI/SHA256SUMS" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if curl -fsS -o /dev/null "$URI/SHA256SUMS"; then
    pass "serving the test repository at $URI"
  else
    fail "the test repository is not served at $URI"
    show "$L/http.log"
  fi
}

phase_install() {
  local rc=0
  sudo env MOTANKA_APT_URI="$URI" bash "$CLI" install --yes </dev/null >"$L/install.log" 2>&1 || rc=$?
  if ((rc == 0)) && installed motanka && installed motanka-core; then
    pass "'motanka install --yes' exited 0; motanka and motanka-core are installed"
  else
    fail "'motanka install --yes' exited $rc"
    show "$L/install.log"
  fi
}

phase_interrupt() {
  local pidf=$T/interrupt.pid pid="" i state="" unfinished deadline
  sudo rm -f "$pidf"
  # shellcheck disable=SC2016 # expanded by the root shell
  sudo setsid --fork bash -c 'echo "$$" >"$1"; exec env MOTANKA_APT_URI="$2" bash "$3" install --yes' \
    _ "$pidf" "$URI" "$CLI" >"$L/interrupt.log" 2>&1 </dev/null
  for ((i = 0; i < 100; i++)); do
    [[ -s $pidf ]] && break
    sleep 0.1
  done
  pid=$(cat "$pidf" 2>/dev/null || true)
  if [[ ! $pid =~ ^[0-9]+$ ]]; then
    fail "the Installer did not start"
    show "$L/interrupt.log"
    return 0
  fi
  deadline=$((SECONDS + 1200))
  while ((SECONDS < deadline)); do
    if installed motanka-archive-keyring && installed "motanka-source-$release"; then
      state=keyring
      break
    fi
    if [[ ! -d /proc/$pid ]]; then
      state=exited
      break
    fi
    sleep 0.1
  done
  if [[ $state != keyring ]]; then
    fail "the Installer did not reach the keyring step (${state:-timeout})"
    show "$L/interrupt.log"
    sudo kill -KILL -- "-$pid" 2>/dev/null || true
    return 0
  fi
  for ((i = 0; i < 600; i++)); do
    pgrep -x dpkg >/dev/null || break
    sleep 0.05
  done
  sudo kill -KILL -- "-$pid" || true
  sleep 2
  pass "killed the Installer's process group $pid after the keyring step"
  if installed motanka; then
    fail "the interruption came too late: motanka is already installed"
  fi
  if ! sudo cat "$LEDGER" >"$S/ledger.interrupted" 2>/dev/null; then
    fail "there is no System_Ledger after the interruption"
    return 0
  fi
  unfinished=$(unfinished_runs "$S/ledger.interrupted")
  if [[ -n $unfinished ]]; then
    pass "the System_Ledger holds the interrupted run $unfinished"
  else
    fail "the System_Ledger shows no interrupted run"
    show "$S/ledger.interrupted"
  fi
}

phase_partial_setup() {
  local d=$T/setup ul=$HOME/.local/state/motanka/ledger
  mkdir -p "$d"
  printf 'motanka hypr\n' >"$d/hypr"
  printf '{}\n' >"$d/waybar"
  printf 'tokyo-night\n' >"$d/theme"
  printf 'export MOTANKA_ROUNDTRIP=1\n' >"$d/block"
  printf 'x\n' >"$d/background"
  # Folders are created only through the ledger, as per-user setup does,
  # so the Remover knows which ones to delete again.
  # shellcheck disable=SC2016 # expanded by the inner shell
  if ! bash -c 'set -euo pipefail
    source "$1/common.sh"; source "$1/userledger.sh"; d=$2
    mk_userledger_setup_begin
    mk_userledger_write session .config/hypr/hyprland.lua "$d/hypr"
    mk_userledger_write session .config/waybar/config.jsonc "$d/waybar"
    mk_userledger_write namespaced .config/omarchy/current/theme.name "$d/theme"
    mk_userledger_write namespaced .local/state/omarchy/current/background "$d/background"
    mk_userledger_write namespaced .local/share/omarchy/README "$d/background"
    mk_userledger_block shared .bashrc "$d/block"' _ "$HOME/motanka/src/lib" "$d" >"$L/partial-setup.log" 2>&1; then
    fail "the simulated per-user setup failed"
    show "$L/partial-setup.log"
    return 0
  fi
  printf 'leftover\n' >"$HOME/.config/waybar/.config.jsonc.motanka-tmp"
  printf '%s\t20261113T000000Z-dead00\tcreate\tsession\t.config/walker/' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$ul"
  # Files Upstream writes into Namespaced_Paths without a ledger entry.
  printf 'y\n' >"$HOME/.local/state/omarchy/current/theme.generation"
  printf 'z\n' >"$HOME/.local/share/omarchy/notes"
  if grep -q $'\tsetup-begin\t' "$ul" && ! grep -q $'\tsetup-end\t' "$ul" &&
    grep -qx '# >>> motanka >>>' "$HOME/.bashrc"; then
    pass "interrupted per-user setup: setup-begin without setup-end, a marked block in ~/.bashrc, a torn last ledger line"
  else
    fail "the simulated per-user setup did not leave the expected User_Ledger"
    show "$ul"
  fi
}

# phase_ledger_start: when the first login is skipped, the User_Ledger that
# per-user setup starts with (setup-begin and setup-end, through the same
# library), so that Upstream commands run later find the folders it
# records as created, as they would after a real first login. After a
# real first login it would only add a second, empty setup run, and before
# one it would make the real per-user setup find itself complete, so it
# refuses when a User_Ledger exists.
phase_ledger_start() {
  local ul=$HOME/.local/state/motanka/ledger
  if [[ -e $ul ]]; then
    fail "ledger-start stands in for a skipped first login, but $ul exists already (a real per-user setup ran)"
    return 0
  fi
  # shellcheck disable=SC2016 # expanded by the inner shell
  if bash -c 'set -euo pipefail; source "$1/common.sh"; source "$1/userledger.sh"
    mk_userledger_setup_begin; mk_userledger_setup_end' _ "$HOME/motanka/src/lib" >"$L/ledger-start.log" 2>&1; then
    pass "started the User_Ledger as per-user setup would (no real first login)"
  else
    fail "could not start the User_Ledger"
    show "$L/ledger-start.log"
  fi
}

phase_other_ledger() {
  local user=${ARGS[0]:-} lib=$T/lib
  if ! id -u "$user" >/dev/null 2>&1; then
    fail "no user '$user' in this image"
    return 0
  fi
  mkdir -p "$lib"
  cp -f "$HOME/motanka/src/lib/common.sh" "$HOME/motanka/src/lib/userledger.sh" "$lib/"
  printf 'from %s\n' "$user" >"$lib/hypr"
  chmod -R a+rX "$lib"
  # shellcheck disable=SC2016 # expanded by the inner shell
  if sudo -u "$user" -H bash -c 'set -euo pipefail; cd /
    source "$1/common.sh"; source "$1/userledger.sh"
    mk_userledger_setup_begin
    mk_userledger_write session .config/hypr/hyprland.lua "$1/hypr"
    mk_userledger_setup_end' _ "$lib" >"$L/other-ledger.log" 2>&1; then
    pass "$user has a User_Ledger"
  else
    fail "could not write a User_Ledger for $user"
    show "$L/other-ledger.log"
  fi
}

login_getty() {
  local dir=/etc/systemd/system/getty@tty1.service.d
  save_dir "$dir"
  save_path "$dir/autologin.conf"
  save_path "$HOME/.bash_profile"
  sudo mkdir -p "$dir"
  # shellcheck disable=SC2016 # $TERM is for systemd, not this shell
  printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$(id -un)" |
    sudo tee "$dir/autologin.conf" >/dev/null
  cat >"$HOME/.bash_profile" <<EOF
if [ "\$(tty)" = /dev/tty1 ] && [ -e $T/launch ]; then
  rm -f $T/launch
  exec $LAUNCHER >>$L/launcher.log 2>&1
fi
EOF
  touch "$T/launch"
  sudo systemctl daemon-reload
  sudo systemctl restart getty@tty1
}

login_gdm() {
  local acc=/var/lib/AccountsService/users/$USER conf=/etc/gdm3/custom.conf
  save_path "$conf"
  save_path "$acc"
  printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER" | sudo tee "$conf" >/dev/null
  printf '[User]\nSession=motanka\nXSession=\nSystemAccount=false\n' | sudo tee "$acc" >/dev/null
  sudo systemctl restart accounts-daemon
  sudo systemctl restart display-manager
}

login_sddm() {
  local dir=/etc/sddm.conf.d
  save_dir "$dir"
  save_path "$dir/zz-harness-autologin.conf"
  sudo mkdir -p "$dir"
  printf '[Autologin]\nUser=%s\nSession=motanka.desktop\nRelogin=false\n' "$USER" |
    sudo tee "$dir/zz-harness-autologin.conf" >/dev/null
  sudo systemctl restart display-manager
}

phase_login() {
  local dm rc=0
  dm=$(detect_dm)
  printf '%s\n' "${dm:-getty}" >"$S/login-dm"
  echo "login through: ${dm:-getty autologin on tty1}"
  rm -f "$S/restore.tsv"
  case $dm in
    gdm) login_gdm ;;
    sddm) login_sddm ;;
    *) login_getty ;;
  esac
  if ! wait_for 180 hyprland_running; then
    fail "the Motanka session did not start within 180 s"
    show "$L/launcher.log"
    # shellcheck disable=SC2024 # the log file belongs to the test user
    sudo journalctl -b -t motanka -n 80 --no-pager >"$L/login-journal.log" 2>&1 || true
    show "$L/login-journal.log"
    return 0
  fi
  pass "the Motanka session runs (Hyprland $(pgrep -u "$UID_" -x Hyprland | head -n 1))"
  if wait_for 120 setup_done; then
    pass "per-user setup ran and wrote setup-end to the User_Ledger"
  else
    fail "per-user setup did not finish within 120 s"
  fi
  sudo motanka remove --dry-run </dev/null >"$L/remove-in-session.log" 2>&1 || rc=$?
  if ((rc == 12)) && grep -q 'log out of every Motanka session' "$L/remove-in-session.log"; then
    pass "'motanka remove --dry-run' exits 12 while the Motanka session runs"
  else
    fail "'motanka remove --dry-run' exited $rc while the Motanka session runs, expected 12"
    show "$L/remove-in-session.log"
  fi
  theme_switch session
}

phase_logout() {
  local dm id
  dm=$(cat "$S/login-dm" 2>/dev/null || echo getty)
  restore_paths
  sudo systemctl daemon-reload
  if [[ $dm == gdm ]]; then
    sudo systemctl restart accounts-daemon || true
  fi
  if hyprland_running; then
    session_env
    if ((${#SENV[@]} > 0)); then
      env -i "${SENV[@]}" "$PREFIX/bin/uwsm" stop >"$L/uwsm-stop.log" 2>&1 || true
    fi
  fi
  if ! wait_for 60 no_session; then
    echo "note: the session did not end after 'uwsm stop'; terminating it"
    for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3 == u { print $1 }'); do
      if [[ $(loginctl show-session "$id" -p Type --value 2>/dev/null) != tty ]] ||
        [[ $(loginctl show-session "$id" -p TTY --value 2>/dev/null) == tty1 ]]; then
        sudo loginctl terminate-session "$id" 2>/dev/null || true
      fi
    done
  fi
  case $dm in
    gdm | sddm) sudo systemctl restart display-manager || true ;;
    *)
      for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$0 ~ /tty1/ { print $1 }'); do
        sudo loginctl terminate-session "$id" 2>/dev/null || true
      done
      sudo systemctl restart getty@tty1 || true
      ;;
  esac
  if wait_for 60 no_session; then
    pass "logged out: no compositor and no session launcher of $USER"
  else
    fail "the Motanka session still runs after logout"
    pkill -KILL -u "$UID_" -x Hyprland || true
  fi
  rm -f "$T/launch"
}

# theme_switch <session|headless>
theme_switch() {
  local how=$1 theme="" t cur rc=0
  local -a themes=()
  mapfile -t themes < <(find /usr/share/omarchy/themes/ -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f\n' 2>/dev/null | sort)
  cur=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)
  for t in "${themes[@]}"; do
    if [[ $t != "$cur" ]]; then
      theme=$t
      break
    fi
  done
  if [[ -z $theme ]]; then
    fail "no theme other than '${cur:-none}' in /usr/share/omarchy/themes"
    return 0
  fi
  if [[ $how == session ]]; then
    session_env
    env -i "${SENV[@]}" OMARCHY_THEME_WAIT=1 "$PREFIX/bin/omarchy-theme-set" "$theme" \
      </dev/null >"$L/theme.log" 2>&1 || rc=$?
  else
    env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" XDG_RUNTIME_DIR="$RT" \
      PATH="$PREFIX/bin:/usr/local/bin:/usr/bin:/bin" OMARCHY_THEME_HEADLESS=1 \
      "$PREFIX/bin/omarchy-theme-set" "$theme" </dev/null >"$L/theme.log" 2>&1 || rc=$?
  fi
  if ((rc == 0)) && [[ $(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null) == "$theme" ]]; then
    pass "theme switch ($how) to '$theme' through the omarchy-theme-set Wrapper"
  else
    fail "theme switch ($how) to '$theme' exited $rc"
    show "$L/theme.log"
  fi
}

phase_theme() {
  theme_switch headless
}

phase_menu_install() {
  local map=$PREFIX/share/motanka/package-map.tsv name kind target size best="" bestsize=0 rc=0 p
  # Command-line tools whose maintainer scripts create no users, groups or
  # services; the first one the map has and the Host lacks is used.
  local -a prefer=(btop eza bat fd-find ripgrep fzf zoxide tldr lazygit fastfetch htop tree ncdu jq gum)
  local -A apt=()
  if [[ ! -r $map ]]; then
    fail "$map is missing"
    return 0
  fi
  while IFS=$'\t' read -r name kind target _; do
    if [[ $name == '#'* || $kind != apt || -z $target || $target == *,* ]] || installed "$target"; then
      continue
    fi
    apt[$target]=1
  done <"$map"
  for p in "${prefer[@]}"; do
    if [[ -n ${apt[$p]:-} ]] && apt-cache show --no-all-versions "$p" >/dev/null 2>&1; then
      best=$p
      break
    fi
  done
  if [[ -z $best ]]; then
    for target in "${!apt[@]}"; do
      size=$(apt-cache show --no-all-versions "$target" 2>/dev/null | awk '/^Installed-Size:/ { print $2; exit }')
      if [[ $size =~ ^[0-9]+$ ]] && { [[ -z $best ]] || ((size < bestsize)); }; then
        best=$target bestsize=$size
      fi
    done
  fi
  if [[ -z $best ]]; then
    fail "the Package_Map has no apt outcome that is not installed"
    return 0
  fi
  echo "menu install: $best"
  sudo env PKEXEC_UID="$UID_" "$PREFIX/libexec/motanka/helper" install "$best" \
    </dev/null >"$L/menu-install.log" 2>&1 || rc=$?
  if ((rc == 0)) && installed "$best" &&
    sudo grep -q $'\tmenu-install\t'"$UID_"$'\t'"$best"$'\tapt$' "$LEDGER"; then
    pass "the Helper installed $best and recorded it as menu-install in the System_Ledger"
    printf '%s\n' "$best" >"$S/menu-pkg"
  else
    fail "the Helper could not install $best (exit $rc)"
    show "$L/menu-install.log"
  fi
}

# webapp_diagnose: what the web-app phase needs to explain a failure.
webapp_diagnose() {
  local w=$PREFIX/bin/omarchy-webapp-install o=$PREFIX/libexec/motanka/overrides/omarchy-webapp-install
  {
    echo "--- Wrapper $w:"
    head -n 4 "$w" 2>&1 || true
    echo "--- override $o:"
    ls -l "$o" 2>&1 || true
    echo "--- Upstream script:"
    ls -l "$PREFIX/share/omarchy/bin/omarchy-webapp-install" 2>&1 || true
    echo "--- ~/.local/share/applications:"
    ls -la "$HOME/.local/share/applications" 2>&1 || true
    echo "--- User_Ledger, last 15 lines:"
    tail -n 15 "$HOME/.local/state/motanka/ledger" 2>&1 | cut -f3- || true
    echo "--- journal (motanka), last 30 lines:"
    sudo journalctl -b -t motanka -n 30 --no-pager 2>&1 || true
  } >"$L/webapp-diagnose.log"
  show "$L/webapp-diagnose.log"
}

phase_webapp() {
  local rc=0 f rel
  rel=".local/share/applications/$WEBAPP_NAME.desktop"
  f="$HOME/$rel"
  printf '\x89PNG\r\n\x1a\n' >"$T/icon.png"
  env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" XDG_RUNTIME_DIR="$RT" \
    PATH="$PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
    "$PREFIX/bin/omarchy-webapp-install" "$WEBAPP_NAME" https://example.test/ "$T/icon.png" \
    </dev/null >"$L/webapp.log" 2>&1 || rc=$?
  if ((rc != 0)); then
    fail "the web app override exited $rc"
    show "$L/webapp.log"
    webapp_diagnose
    return 0
  fi
  if ! grep -qF "installed the web app entry ~/$rel" "$L/webapp.log"; then
    fail "the web app override exited 0 without reporting the entry it installed"
    show "$L/webapp.log"
    webapp_diagnose
    return 0
  fi
  if grep -qx 'OnlyShowIn=Motanka;' "$f" 2>/dev/null &&
    awk -F'\t' -v p="$rel" '$3 == "menu-desktop" && $4 == "app" && $5 == p { f = 1 } END { exit !f }' \
      "$HOME/.local/state/motanka/ledger"; then
    pass "the web app override wrote '$f' with OnlyShowIn=Motanka; and ledgered it"
    printf '%s\n' "$rel" >"$S/webapp"
  else
    fail "the web app override reported '$f' but it lacks OnlyShowIn=Motanka; or a menu-desktop ledger line"
    show "$L/webapp.log"
    webapp_diagnose
  fi
}

# phase_capture_check: after the session ended (or without a session),
# the User_Ledger holds no unplanned entry (6.10, 12.8: tests fail on
# them), and with a session the capture was ended. Lists the adopted and
# observed paths for the log.
phase_capture_check() {
  local ul=$HOME/.local/state/motanka/ledger cap=$HOME/.local/state/motanka/capture how=${ARGS[0]:-session}
  if [[ ! -f $ul ]]; then
    fail "no User_Ledger at $ul"
    return 0
  fi
  if [[ $how == session ]]; then
    if [[ -e $cap/start ]]; then
      fail "the session capture is still pending after logout ($cap/start exists)"
    else
      pass "the session capture was ended when the session ended"
    fi
  fi
  awk -F'\t' '$3 == "adopt" { print "    adopted:  " $4 " ~/" $5 }' "$ul"
  awk -F'\t' '$3 == "observed" { print "    observed: ~/" $5 }' "$ul"
  if awk -F'\t' '$3 == "unplanned" { f = 1 } END { exit !f }' "$ul"; then
    fail "the User_Ledger records unplanned home-folder paths:"
    awk -F'\t' '$3 == "unplanned" { print "    ~/" $5 }' "$ul"
  else
    pass "the User_Ledger records no unplanned home-folder path"
  fi
}

phase_remove_dry() {
  local how=${ARGS[0]:-installed} rc=0 pkg u
  local -a users=("${ARGS[@]:1}")
  motanka_cmd "$how"
  sudo "${MCMD[@]}" remove --dry-run </dev/null >"$L/remove-dry.out" 2>"$L/remove-dry.err" || rc=$?
  if ((rc == 0)) && grep -qx 'Dry run: nothing was changed.' "$L/remove-dry.out"; then
    pass "'motanka remove --dry-run' exited 0 and printed the Plan"
  else
    fail "'motanka remove --dry-run' exited $rc"
    show "$L/remove-dry.out" "$L/remove-dry.err"
    return 0
  fi
  if grep -Eq '^  purge +motanka-core ' "$L/remove-dry.out"; then
    pass "the Plan purges motanka-core"
  else
    fail "the Plan does not purge motanka-core"
  fi
  if [[ -s $S/menu-pkg ]]; then
    pkg=$(cat "$S/menu-pkg")
    if grep -Eq "^  keep +$pkg  \\(installed from an Omarchy menu" "$L/remove-dry.out"; then
      pass "without --purge the Plan keeps and lists the menu package $pkg (10.9)"
    else
      fail "without --purge the Plan does not list the menu package $pkg as kept"
    fi
  fi
  if [[ -s $S/webapp ]]; then
    if awk -v p="~/$(cat "$S/webapp")  (installed from an Omarchy menu; --purge removes it)" \
      '$1 == "keep" && index($0, p) { f = 1 } END { exit !f }' "$L/remove-dry.out"; then
      pass "without --purge the Plan keeps and lists the web app (10.9)"
    else
      fail "without --purge the Plan does not list the web app as kept"
    fi
  fi
  for u in "${users[@]}"; do
    if grep -Eq "^  user +$u  " "$L/remove-dry.out"; then
      pass "the Plan lists $u as another user with a User_Ledger (10.13)"
    else
      fail "the Plan does not list $u"
    fi
  done
  sed 's/^/    /' "$L/remove-dry.out"
}

phase_remove() {
  local how=${ARGS[0]:-installed} net=${ARGS[1]:-online} rc=0 left pkg root purge=0 a
  local -a extra=("${ARGS[@]:2}") cmd=(sudo)
  for a in "${extra[@]}"; do
    if [[ $a == --purge ]]; then
      purge=1
    fi
  done
  motanka_cmd "$how"
  if [[ $net == offline ]]; then
    sudo unshare --net -- ip -o link >"$L/offline-links.txt" 2>&1 || true
    echo "network interfaces inside 'unshare --net': $(awk '{ print $2 }' "$L/offline-links.txt" | tr '\n' ' ')"
    cmd+=(unshare --net --)
  fi
  "${cmd[@]}" "${MCMD[@]}" remove --yes "${extra[@]}" </dev/null >"$L/remove.out" 2>"$L/remove.err" || rc=$?
  if ((rc == 0)) && grep -qx 'Motanka was removed.' "$L/remove.out"; then
    pass "'motanka remove --yes ${extra[*]}' ($how CLI, $net) exited 0"
  else
    fail "'motanka remove --yes ${extra[*]}' ($how CLI, $net) exited $rc"
    show "$L/remove.out" "$L/remove.err"
  fi
  sed 's/^/    /' "$L/remove.out"
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  left=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' | awk '$1 ~ /^motanka(-|$)/ && $2 != "not-installed"' || true)
  if [[ -z $left ]]; then
    pass "dpkg knows no Motanka package any more (10.6)"
  else
    fail "Motanka packages are still known to dpkg: $left"
  fi
  for root in "$PREFIX" /usr/share/omarchy /usr/share/wayland-sessions/motanka.desktop /var/lib/motanka \
    /etc/apt/sources.list.d/motanka.sources /etc/apt/preferences.d/motanka; do
    if sudo test -e "$root" || sudo test -L "$root"; then
      fail "$root still exists"
    fi
  done
  if sudo sh -c 'ls -d /var/log/motanka-ledger-* >/dev/null 2>&1'; then
    pass "the System_Ledger is archived in /var/log"
  else
    fail "no archived System_Ledger in /var/log"
  fi
  if sudo find /run/motanka -mindepth 1 -maxdepth 1 \( -name 'remove.*' -o -name remover.active \) 2>/dev/null | grep -q .; then
    fail "the Remover left files in /run/motanka"
  else
    pass "the Remover left nothing in /run/motanka"
  fi
  snapshot after-remove
  if [[ -f $S/before.sessions ]]; then
    if cmp -s "$S/before.sessions" "$S/after-remove.sessions"; then
      pass "the display manager lists the same sessions as before installation (10.14)"
    else
      fail "the session entries differ from before installation"
      diff "$S/before.sessions" "$S/after-remove.sessions" | show
    fi
  fi
  for root in .local/state/motanka .config/omarchy .local/share/omarchy .local/state/omarchy .config/dconf/motanka; do
    if [[ -e $HOME/$root || -L $HOME/$root ]]; then
      fail "~/$root still exists"
    fi
  done
  if [[ -s $S/menu-pkg ]]; then
    pkg=$(cat "$S/menu-pkg")
    if ((purge)) && ! installed "$pkg"; then
      pass "--purge removed the menu package $pkg"
    elif ((!purge)) && installed "$pkg"; then
      pass "without --purge the menu package $pkg is kept (10.9)"
    elif ((purge)); then
      fail "--purge did not remove the menu package $pkg"
    else
      fail "without --purge the menu package $pkg was removed"
    fi
  fi
  if [[ -f $S/before.pkgs && ($purge == 1 || ! -s $S/menu-pkg) ]]; then
    if cmp -s "$S/before.pkgs" "$S/after-remove.pkgs"; then
      pass "the package list equals the one before installation (10.7, 10.8)"
    else
      fail "the package list differs from before installation (< before, > after):"
      diff "$S/before.pkgs" "$S/after-remove.pkgs" | show
    fi
  fi
}

case $phase in
  serve) phase_serve ;;
  snapshot)
    snapshot "${ARGS[0]:-before}"
    pass "snapshot ${ARGS[0]:-before}: $(wc -l <"$S/${ARGS[0]:-before}.pkgs") packages"
    ;;
  install) phase_install ;;
  interrupt) phase_interrupt ;;
  partial-setup) phase_partial_setup ;;
  ledger-start) phase_ledger_start ;;
  other-ledger) phase_other_ledger ;;
  login) phase_login ;;
  logout) phase_logout ;;
  theme) phase_theme ;;
  menu-install) phase_menu_install ;;
  webapp) phase_webapp ;;
  capture-check) phase_capture_check ;;
  remove-dry) phase_remove_dry ;;
  remove) phase_remove ;;
  *)
    echo "remove-guest.sh: unknown phase '$phase'" >&2
    exit 2
    ;;
esac
exit $((fails > 0 ? 1 : 0))
