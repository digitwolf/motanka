#!/usr/bin/env bash
# shellcheck disable=SC2329 # phase functions are called by name
# Guest half of test/vm/tests/first-login.sh. Runs INSIDE a throwaway test VM
# of the multiuser variant as user tester (passwordless sudo in the VM).
# Never run it on a real machine: it installs packages and configures tty1
# autologin for user alice.
#
# Usage: bash first-login-guest.sh <phase> <release>
#
# Work folder /tmp/motanka-first-login (T): debs/ holds the local .debs,
# logs/ collects output, alice/ belongs to alice (the autologin flag and the
# compositor probe). Every check prints "PASS: ..." or "FAIL: ..."; the exit
# code is 1 if any check failed in the phase.
#
# Phases, in the order the host runs them:
#   prepare  apt-get update; record bob's home folder (paths, types, modes,
#            sizes, times, link targets, SHA-256 of every file) and the
#            SHA-256 of alice's Shared_Files.
#   install  apt-get install the local .debs; /usr/share/omarchy links to
#            the overlay omarchy-view (bin: the Wrappers in /opt/motanka/bin,
#            default: the vendored tree); per-user setup, shell integration,
#            the default theme, their data files and units are installed;
#            motanka-fonts has its 8 fonts under /opt/motanka/share/fonts and
#            nothing in the system's font folders, no file in /etc/fonts
#            names /opt/motanka, and motanka-core depends on motanka-fonts;
#            "fc-list" of bob and of alice outside the Motanka session has no
#            JetBrainsMono Nerd Font (5.10);
#            omarchy-version through its Wrapper prints the vendored version;
#            neither alice's nor bob's home folder has a Motanka file and
#            bob's is unchanged (6.8).
#   login    tty1 autologin of alice runs the session launcher. Then:
#            per-user setup completed (setup-end in alice's User_Ledger), no
#            unplanned entry, the Hyprland fragment is ledgered, alice's
#            Shared_Files are unchanged; Hyprland --verify-config on alice's
#            config reports zero errors, and so does "hyprctl configerrors" in
#            the running compositor (8.3); after Upstream's
#            dbus-update-activation-environment ran (OZONE_PLATFORM=wayland is
#            in the user manager), "systemctl --user show-environment" has
#            XDG_CURRENT_DESKTOP=Motanka:Hyprland and
#            XDG_SESSION_DESKTOP=motanka; a command the compositor starts has
#            both too and resolves omarchy-version to the Wrapper in
#            /opt/motanka/bin; the default theme is applied in the session
#            (~/.local/state/omarchy/current/theme.name is tokyo-night, which
#            omarchy-theme-set makes of "Tokyo Night", and
#            motanka-default-theme recorded "ok"); the desktop shell has
#            FONTCONFIG_PATH=/opt/motanka/share/motanka/fontconfig and, with
#            that environment, "fc-match monospace" (the family the bar asks
#            for) gives JetBrainsMono Nerd Font from /opt/motanka/share/fonts;
#            "hyprctl layers" has the wallpaper layer omarchy-background and
#            the theme's background link points to an image; then a
#            screenshot; "fc-list" of bob and of alice outside the session
#            still has no JetBrainsMono Nerd Font; bob's home folder is
#            unchanged and holds no Motanka file (6.8).
#   logout   stop alice's session and remove the autologin setup; once the
#            session capture has ended, alice's User_Ledger has no unplanned
#            path and the default theme's btop link is adopted.
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

T=/tmp/motanka-first-login
L=$T/logs
AT=$T/alice
PREFIX=/opt/motanka
LAUNCHER=$PREFIX/libexec/motanka/session
DROPIN_DIR=/etc/systemd/system/getty@tty1.service.d
DROPIN=$DROPIN_DIR/autologin.conf
APT=(sudo env DEBIAN_FRONTEND=noninteractive apt-get -q -y -o DPkg::Lock::Timeout=300)
WRAPPER_MARKER='# Motanka Wrapper for Upstream bin/'
SETUP_TIMEOUT=300
THEME_TIMEOUT=240
FONT_FAMILY='JetBrainsMono Nerd Font'
FONTS_DIR=$PREFIX/share/fonts
FONTCONFIG_DIR=$PREFIX/share/motanka/fontconfig

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
    echo "first-login-guest.sh: refusing to run outside a VM" >&2
    exit 7
  fi
  if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
    echo "first-login-guest.sh: refusing to run on a Protected_Host" >&2
    exit 7
  fi
}

user_home() {
  getent passwd "$1" | cut -d: -f6
}

AHOME=$(user_home alice)
BHOME=$(user_home bob)
AUID=$(id -u alice)
ART=/run/user/$AUID
ALEDGER=$AHOME/.local/state/motanka/ledger

# as_alice <command...>: runs a command as alice in her user session.
as_alice() {
  sudo -u alice env HOME="$AHOME" XDG_RUNTIME_DIR="$ART" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$ART/bus" "$@"
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

# home_manifest <home>: every path with type, mode, size, time and link
# target, then the SHA-256 of every file.
home_manifest() {
  sudo find "$1" -mindepth 1 -printf '%P\t%y\t%m\t%s\t%T@\t%l\n' | LC_ALL=C sort
  sudo find "$1" -type f -print0 | LC_ALL=C sort -z | sudo xargs -0 -r sha256sum
}

alice_shared_sums() {
  local f
  for f in .bashrc .profile .gitconfig .config/gtk-3.0/settings.ini .config/gtk-4.0/settings.ini \
    .config/mimeapps.list; do
    if sudo test -f "$AHOME/$f"; then
      printf '%s  %s\n' "$(sudo sha256sum -- "$AHOME/$f" | cut -c1-64)" "$f"
    else
      printf 'missing  %s\n' "$f"
    fi
  done
}

# motanka_files <home>: Motanka's files in a home folder, if any.
motanka_files() {
  sudo find "$1" \( -path "$1/.local/state/motanka" -o -path "$1/.config/dconf/motanka" \
    -o -path "$1/.local/state/omarchy" -o -path "$1/.config/omarchy" -o -name '*motanka*' \) -print
}

check_bob() {
  local label=$1 left
  home_manifest "$BHOME" >"$L/bob-$label.txt"
  if cmp -s "$T/bob-before.txt" "$L/bob-$label.txt"; then
    pass "$label: bob's home folder is byte for byte as before the install"
  else
    fail "$label: bob's home folder changed:"
    diff "$T/bob-before.txt" "$L/bob-$label.txt" | head -n 20 | show
  fi
  left=$(motanka_files "$BHOME")
  if [[ -z $left ]]; then
    pass "$label: bob's home folder holds no Motanka file"
  else
    fail "$label: Motanka files in bob's home folder:"
    printf '%s\n' "$left" | show
  fi
}

# fc_list_as <user>: fc-list as a login of that user outside the Motanka
# session sees it (a clean environment). Its font cache goes to a temporary
# folder, so the check writes nothing into the home folder.
fc_list_as() {
  local user=$1 home cache rc=0
  home=$(user_home "$user")
  cache=$(sudo -u "$user" mktemp -d /tmp/motanka-fc.XXXXXX)
  sudo -u "$user" env -i HOME="$home" PATH=/usr/bin:/bin LANG=C.UTF-8 XDG_CACHE_HOME="$cache" \
    fc-list : family file || rc=$?
  sudo rm -rf -- "$cache"
  return "$rc"
}

# check_fonts_hidden <label>: Motanka's fonts are invisible outside the
# Motanka session, for bob and for alice (5.10).
check_fonts_hidden() {
  local label=$1 user out rc
  for user in bob alice; do
    rc=0
    out=$(fc_list_as "$user" 2>&1) || rc=$?
    printf '%s\n' "$out" >"$L/fc-list-$user-$label.txt"
    if ((rc != 0)); then
      fail "$label: fc-list as $user failed (exit $rc)"
      tail -n 5 "$L/fc-list-$user-$label.txt" | show
    elif grep -qiF -e "$FONT_FAMILY" -e "$FONTS_DIR" "$L/fc-list-$user-$label.txt"; then
      fail "$label: fc-list of $user outside the Motanka session lists Motanka's fonts:"
      grep -iF -e "$FONT_FAMILY" -e "$FONTS_DIR" "$L/fc-list-$user-$label.txt" | head -n 5 | show
    else
      pass "$label: fc-list of $user outside the Motanka session has no $FONT_FAMILY ($(grep -c . "$L/fc-list-$user-$label.txt") fonts)"
    fi
  done
}

check_fonts_installed() {
  local n bad deps
  n=$(find "$FONTS_DIR" -type f -name '*.ttf' 2>/dev/null | wc -l)
  if ((n == 8)); then
    pass "motanka-fonts installed its 8 fonts under $FONTS_DIR"
  else
    fail "$FONTS_DIR holds $n .ttf files, expected 8"
  fi
  if [[ -s /usr/share/doc/motanka-fonts/OFL.txt ]]; then
    pass "motanka-fonts ships the fonts' licence as /usr/share/doc/motanka-fonts/OFL.txt"
  else
    fail "/usr/share/doc/motanka-fonts/OFL.txt is missing"
  fi
  bad=$(dpkg -L motanka-fonts 2>/dev/null | grep -E '^/(etc/fonts|usr/share/fonts|usr/local/share/fonts)(/|$)' || true)
  if [[ -z $bad ]]; then
    pass "motanka-fonts installs nothing into the system's font folders or /etc/fonts"
  else
    fail "motanka-fonts installs into the system's font configuration:"
    printf '%s\n' "$bad" | show
  fi
  if sudo grep -rqsF -- "$PREFIX" /etc/fonts; then
    fail "a file under /etc/fonts names $PREFIX:"
    sudo grep -rlF -- "$PREFIX" /etc/fonts | show
  else
    pass "no file under /etc/fonts names $PREFIX"
  fi
  if [[ -s $FONTCONFIG_DIR/fonts.conf ]] && grep -qF "<dir>$FONTS_DIR</dir>" "$FONTCONFIG_DIR/fonts.conf"; then
    pass "the session's font configuration $FONTCONFIG_DIR/fonts.conf adds $FONTS_DIR"
  else
    fail "$FONTCONFIG_DIR/fonts.conf is missing or does not add $FONTS_DIR"
  fi
  # shellcheck disable=SC2016 # dpkg-query field
  deps=$(dpkg-query -W -f='${Depends}' motanka-core 2>/dev/null || true)
  if [[ ", $deps," =~ ,\ motanka-fonts[\ ,] ]]; then
    pass "motanka-core depends on motanka-fonts"
  else
    fail "motanka-core does not depend on motanka-fonts (Depends: $deps)"
  fi
}

# --- phases -----------------------------------------------------------------

phase_prepare() {
  mkdir -p "$L"
  if [[ -z $AHOME || -z $BHOME || ! -d $AHOME || ! -d $BHOME ]]; then
    fail "the multiuser image has no users alice and bob"
    return
  fi
  if "${APT[@]}" update >"$L/apt-update.log" 2>&1; then
    pass "apt-get update"
  else
    fail "apt-get update failed"
    show "$L/apt-update.log"
  fi
  if "${APT[@]}" install --no-install-recommends grim >"$L/prepare-grim.log" 2>&1; then
    pass "installed the test tool grim"
  else
    fail "could not install grim"
  fi
  home_manifest "$BHOME" >"$T/bob-before.txt"
  alice_shared_sums >"$T/alice-shared-before.txt"
  pass "recorded bob's home folder ($(grep -c . "$T/bob-before.txt") lines) and alice's Shared_Files"
  if [[ -n $(motanka_files "$AHOME") ]]; then
    fail "alice's home folder already has Motanka files before the install"
  fi
}

phase_install() {
  local rc=0 p f u out v want
  mkdir -p "$L"
  "${APT[@]}" install "$T"/debs/*.deb >"$L/install.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "apt-get installed the local .debs: $(cd "$T/debs" && echo ./*.deb)"
  else
    fail "apt-get install of the local .debs failed (exit $rc)"
    tail -n 40 "$L/install.log" | show
    return
  fi
  for p in motanka-core motanka-stack motanka-stack-shell motanka-fonts; do
    # shellcheck disable=SC2016 # dpkg-query fields
    if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null) == "ii " ]]; then
      # shellcheck disable=SC2016 # dpkg-query field
      pass "$p is installed ($(dpkg-query -W -f='${Version}' "$p"))"
    else
      fail "$p is not installed"
    fi
  done

  if [[ -L /usr/share/omarchy && $(readlink -f /usr/share/omarchy) == "$PREFIX/share/omarchy-view" ]]; then
    pass "/usr/share/omarchy links to $PREFIX/share/omarchy-view"
  else
    fail "/usr/share/omarchy resolves to '$(readlink -f /usr/share/omarchy 2>/dev/null || true)', not $PREFIX/share/omarchy-view"
  fi
  if [[ $(readlink -f /usr/share/omarchy/bin) == "$PREFIX/bin" &&
    $(readlink -f /usr/share/omarchy/default) == "$PREFIX/share/omarchy/default" &&
    $(readlink -f /usr/share/omarchy/bin/omarchy-version) == "$PREFIX/bin/omarchy-version" ]]; then
    pass "the overlay's bin is the Wrappers and its default is the vendored tree"
  else
    fail "the overlay is wrong: bin -> $(readlink -f /usr/share/omarchy/bin), default -> $(readlink -f /usr/share/omarchy/default)"
  fi
  for f in libexec/motanka/user-setup libexec/motanka/shell-integration libexec/motanka/default-theme; do
    if [[ -x $PREFIX/$f ]]; then
      pass "$PREFIX/$f is installed"
    else
      fail "$PREFIX/$f is missing or not executable"
    fi
  done
  for f in home-paths.tsv user-scripts.tsv inventory.tsv hypr/motanka-session.lua; do
    if [[ -s $PREFIX/share/motanka/$f ]]; then
      pass "$PREFIX/share/motanka/$f is installed"
    else
      fail "$PREFIX/share/motanka/$f is missing"
    fi
  done
  for u in motanka-shell-integration.service motanka-default-theme.service; do
    f=/usr/lib/systemd/user/motanka-session.target.wants/$u
    if [[ -L $f ]] && dpkg -S "$f" >/dev/null 2>&1; then
      pass "$u is wanted by motanka-session.target through a package-owned link"
    else
      fail "$f is not a package-owned link"
    fi
  done
  check_fonts_installed
  check_fonts_hidden after-install

  want=$(awk -F'\t' '$1 == "stable" { print $3 }' "$PREFIX/share/motanka/upstream.pin")
  want=${want#v}
  rc=0
  out=$(env -i HOME="$HOME" PATH="$PREFIX/bin:/usr/bin:/bin" "$PREFIX/bin/omarchy-version" 2>&1) || rc=$?
  if ((rc == 0)) && [[ $out == "$want" ]]; then
    pass "omarchy-version through its Wrapper prints the vendored version $out"
  else
    fail "omarchy-version through its Wrapper printed '$out' (exit $rc), expected '$want'"
  fi

  for v in alice bob; do
    f=$(user_home "$v")
    if [[ -z $(motanka_files "$f") ]]; then
      pass "before any login, $v's home folder has no Motanka file"
    else
      fail "before any login, $v's home folder has Motanka files:"
      motanka_files "$f" | show
    fi
  done
  check_bob after-install
}

# start_alice_session: tty1 autologin of alice, which runs the launcher once.
start_alice_session() {
  # $T arrives with the staging folder's mode 0700; alice must reach $AT.
  chmod 0711 "$T"
  sudo install -d -o alice -g alice -m 0755 "$AT"
  sudo -u alice touch "$AT/launch"
  sudo mkdir -p "$DROPIN_DIR"
  # shellcheck disable=SC2016 # $TERM is for systemd, not this shell
  printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin alice --noclear %%I $TERM\n' |
    sudo tee "$DROPIN" >/dev/null
  if sudo test -e "$AHOME/.bash_profile"; then
    fail "alice already has a ~/.bash_profile; the test would replace it"
    return 1
  fi
  sudo -u alice tee "$AHOME/.bash_profile" >/dev/null <<EOF
# Written by test/vm/first-login-guest.sh: start the Motanka session once on tty1.
if [ "\$(tty)" = /dev/tty1 ] && [ -e $AT/launch ]; then
  rm -f $AT/launch
  exec $LAUNCHER >>$AT/launcher.log 2>&1
fi
[ -r "\$HOME/.profile" ] && . "\$HOME/.profile"
EOF
  sudo systemctl daemon-reload
  sudo systemctl restart getty@tty1
}

setup_done() {
  sudo test -f "$ALEDGER" && sudo awk -F'\t' '$3 == "setup-end" { found = 1 } END { exit !found }' "$ALEDGER"
}

hyprland_running() {
  pgrep -u alice -x Hyprland >/dev/null
}

alice_sig() {
  sudo find "$ART/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null |
    sort -n | tail -n 1 | cut -d' ' -f2
}

upstream_envs_pushed() {
  as_alice systemctl --user show-environment 2>/dev/null | grep -qx 'OZONE_PLATFORM=wayland'
}

collect_alice_logs() {
  local sig
  sudo cp -f "$AT/launcher.log" "$L/launcher-alice.log" 2>/dev/null || true
  sudo cp -f "$ALEDGER" "$L/alice-ledger.tsv" 2>/dev/null || true
  sig=$(alice_sig)
  if [[ -n $sig ]]; then
    sudo cp -f "$ART/hypr/$sig/hyprland.log" "$L/hyprland-alice.log" 2>/dev/null || true
  fi
  # shellcheck disable=SC2024 # the log file belongs to the test user
  sudo journalctl _UID="$AUID" --no-pager -n 400 >"$L/alice-journal.log" 2>&1 || true
  sudo chown -R "$(id -u):$(id -g)" "$L" 2>/dev/null || true
}

check_setup() {
  local unplanned
  if wait_for "$SETUP_TIMEOUT" setup_done; then
    pass "per-user setup completed for alice (setup-end in her User_Ledger, $(sudo grep -c . "$ALEDGER") lines)"
  else
    fail "no setup-end in $ALEDGER within $SETUP_TIMEOUT s"
    collect_alice_logs
    tail -n 40 "$L/launcher-alice.log" 2>/dev/null | show
    return 1
  fi
  unplanned=$(sudo awk -F'\t' '$3 == "unplanned" { print $5 }' "$ALEDGER")
  if [[ -z $unplanned ]]; then
    pass "the post-setup scan found no unplanned home-folder change"
  else
    fail "unplanned entries in alice's User_Ledger:"
    printf '%s\n' "$unplanned" | show
  fi
  if sudo awk -F'\t' '$5 == ".local/state/omarchy/toggles/hypr/motanka-session.lua" && $4 == "session" { found = 1 } END { exit !found }' "$ALEDGER" &&
    sudo cmp -s "$PREFIX/share/motanka/hypr/motanka-session.lua" "$AHOME/.local/state/omarchy/toggles/hypr/motanka-session.lua"; then
    pass "the Hyprland fragment is installed as a ledgered session file"
  else
    fail "the Hyprland fragment is missing or not ledgered as a session file"
  fi
  if sudo test -s "$AHOME/.config/dconf/motanka"; then
    pass "alice has the dconf database ~/.config/dconf/motanka"
  else
    fail "alice has no ~/.config/dconf/motanka"
  fi
  alice_shared_sums >"$L/alice-shared-after.txt"
  if cmp -s "$T/alice-shared-before.txt" "$L/alice-shared-after.txt"; then
    pass "alice's Shared_Files are unchanged"
  else
    fail "alice's Shared_Files changed:"
    diff "$T/alice-shared-before.txt" "$L/alice-shared-after.txt" | show
  fi
}

check_verify_config() {
  local rc=0 sig out n
  # Upstream's startup-cursor.lua passes HYPRLAND_INSTANCE_SIGNATURE to
  # hl.env, which a compositor always has; a name of its own keeps the check
  # away from the running instance's sockets.
  as_alice env OMARCHY_PATH=/usr/share/omarchy DCONF_PROFILE=motanka XDG_CURRENT_DESKTOP=Motanka:Hyprland \
    XDG_SESSION_DESKTOP=motanka PATH="$PREFIX/bin:/usr/local/bin:/usr/bin:/bin" \
    HYPRLAND_INSTANCE_SIGNATURE=motanka-verify-config \
    timeout 120 "$PREFIX/bin/Hyprland" --verify-config --config "$AHOME/.config/hypr/hyprland.lua" \
    >"$L/verify-config.log" 2>&1 || rc=$?
  if ((rc == 0)) && { grep -qi 'config ok' "$L/verify-config.log" || ! grep -qi 'error' "$L/verify-config.log"; }; then
    pass "Hyprland --verify-config reports zero errors for alice's config: $(grep -i 'config' "$L/verify-config.log" | tail -n 1)"
  elif ((rc >= 128)) && ! grep -q 'Lua error' "$L/verify-config.log"; then
    # Hyprland 0.57.2 crashes in --verify-config with a Lua config after it
    # fails to bind its IPC socket (seen with SIGSEGV, exit 139), with no
    # config error reported. The running compositor's configerrors check
    # below is the gate for 8.3.
    echo "SKIP: Hyprland --verify-config crashed (exit $rc) without a config error; relying on hyprctl configerrors"
  else
    fail "Hyprland --verify-config failed (exit $rc):"
    tail -n 30 "$L/verify-config.log" | show
  fi

  sig=$(alice_sig)
  rc=0
  out=$(as_alice env HYPRLAND_INSTANCE_SIGNATURE="$sig" "$PREFIX/bin/hyprctl" -j configerrors 2>&1) || rc=$?
  printf '%s\n' "$out" >"$L/configerrors.json"
  n=$(python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    print("unparsable")
    sys.exit(0)
items = data if isinstance(data, list) else [data]
print(sum(1 for e in items if str(e).strip()))' <<<"$out")
  if ((rc == 0)) && [[ $n == 0 ]]; then
    pass "hyprctl configerrors in the running compositor reports zero errors"
  else
    fail "hyprctl configerrors (exit $rc) reports '$n' error(s):"
    head -n 20 "$L/configerrors.json" | show
  fi
}

check_environment() {
  local env_now
  if wait_for 90 upstream_envs_pushed; then
    pass "Upstream's dbus-update-activation-environment pushed the compositor's environment (OZONE_PLATFORM=wayland)"
  else
    fail "OZONE_PLATFORM=wayland never reached the user manager: Upstream's envs did not run or were not pushed"
  fi
  env_now=$(as_alice systemctl --user show-environment 2>&1 || true)
  printf '%s\n' "$env_now" | LC_ALL=C sort >"$L/alice-user-manager-env.txt"
  if grep -qx 'XDG_CURRENT_DESKTOP=Motanka:Hyprland' <<<"$env_now" &&
    grep -qx 'XDG_SESSION_DESKTOP=motanka' <<<"$env_now"; then
    pass "systemctl --user show-environment has XDG_CURRENT_DESKTOP=Motanka:Hyprland and XDG_SESSION_DESKTOP=motanka"
  else
    fail "the user manager has $(grep -E '^XDG_(CURRENT|SESSION)_DESKTOP=' <<<"$env_now" | tr '\n' ' ')"
  fi
}

# screenshot_alice: grim captures alice's session after the desktop shell
# had time to draw, into the results folder (evidence, not a check).
screenshot_alice() {
  local sock
  sleep 15
  sock=$(sudo find "$ART" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' 2>/dev/null | sort | head -n 1)
  if [[ -z $sock ]]; then
    echo "note: no Wayland socket in $ART; no screenshot"
    return 0
  fi
  if as_alice env WAYLAND_DISPLAY="$sock" grim "$AT/session.png" >"$L/grim.log" 2>&1; then
    sudo cp -f "$AT/session.png" "$L/session-alice.png"
    sudo chown "$(id -u):$(id -g)" "$L/session-alice.png"
    echo "screenshot: session-alice.png ($(stat -c %s "$L/session-alice.png") bytes)"
  else
    echo "note: grim failed: $(tail -n 1 "$L/grim.log")"
  fi
}

check_compositor_probe() {
  local sig out rc want real
  sig=$(alice_sig)
  sudo -u alice tee "$AT/probe.sh" >/dev/null <<EOF
#!/bin/sh
out=$AT/probe.out
p=\$(command -v omarchy-version || true)
{
  printf 'XDG_CURRENT_DESKTOP=%s\n' "\${XDG_CURRENT_DESKTOP-}"
  printf 'XDG_SESSION_DESKTOP=%s\n' "\${XDG_SESSION_DESKTOP-}"
  printf 'which=%s\n' "\$p"
  printf 'real=%s\n' "\$(readlink -f "\$p" 2>/dev/null)"
  printf 'version=%s\n' "\$(omarchy-version 2>&1)"
  printf 'PATH=%s\n' "\$PATH"
} >"\$out.tmp" && mv "\$out.tmp" "\$out"
EOF
  sudo -u alice rm -f "$AT/probe.out"
  rc=0
  out=$(as_alice env HYPRLAND_INSTANCE_SIGNATURE="$sig" "$PREFIX/bin/hyprctl" dispatch \
    "hl.dsp.exec_cmd(\"/bin/sh $AT/probe.sh\")" 2>&1) || rc=$?
  if ((rc != 0)) || [[ $out != *ok* ]]; then
    echo "note: Lua dispatch answered '$out' (exit $rc); trying the legacy exec dispatcher"
    as_alice env HYPRLAND_INSTANCE_SIGNATURE="$sig" "$PREFIX/bin/hyprctl" dispatch exec "/bin/sh $AT/probe.sh" \
      >>"$L/probe-dispatch.log" 2>&1 || true
  fi
  if ! wait_for 20 sudo test -s "$AT/probe.out"; then
    fail "a command started from the compositor did not run (no $AT/probe.out)"
    return
  fi
  # shellcheck disable=SC2024 # the copy belongs to the test user
  sudo cat "$AT/probe.out" >"$L/probe.out"
  if grep -qx 'XDG_CURRENT_DESKTOP=Motanka:Hyprland' "$L/probe.out" &&
    grep -qx 'XDG_SESSION_DESKTOP=motanka' "$L/probe.out"; then
    pass "a command started from the compositor has XDG_CURRENT_DESKTOP=Motanka:Hyprland and XDG_SESSION_DESKTOP=motanka"
  else
    fail "a command started from the compositor has: $(grep '^XDG_' "$L/probe.out" | tr '\n' ' ')"
  fi
  real=$(sed -n 's/^real=//p' "$L/probe.out")
  if [[ $real == "$PREFIX/bin/omarchy-version" && $(sed -n 2p "$real") == "$WRAPPER_MARKER"* ]]; then
    pass "omarchy-version resolves to the Wrapper $real (found as $(sed -n 's/^which=//p' "$L/probe.out"))"
  else
    fail "omarchy-version resolves to '$real' in the compositor, not the Wrapper $PREFIX/bin/omarchy-version"
  fi
  want=$(awk -F'\t' '$1 == "stable" { print $3 }' "$PREFIX/share/motanka/upstream.pin")
  if grep -qx "version=${want#v}" "$L/probe.out"; then
    pass "omarchy-version from the compositor prints ${want#v}"
  else
    fail "omarchy-version from the compositor printed '$(sed -n 's/^version=//p' "$L/probe.out")'"
  fi
}

theme_name() {
  sudo cat "$AHOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true
}

# theme_applied: 0 when the current theme is Tokyo Night. omarchy-theme-set
# stores the name lowercased with dashes ("tokyo-night").
theme_applied() {
  local n
  n=$(theme_name)
  n=${n,,}
  n=${n// /-}
  [[ $n == tokyo-night ]]
}

theme_recorded() {
  sudo test -s "$AHOME/.local/state/motanka/default-theme"
}

check_default_theme() {
  local state unit
  if wait_for "$THEME_TIMEOUT" theme_applied; then
    pass "the default theme was applied in the session: theme.name is '$(theme_name)' (Tokyo Night)"
  else
    fail "no default theme within $THEME_TIMEOUT s: theme.name is '$(theme_name)'"
  fi
  wait_for 120 theme_recorded || true
  state=$(sudo cat "$AHOME/.local/state/motanka/default-theme" 2>/dev/null || true)
  if [[ $state == ok$'\t'* ]]; then
    pass "motanka-default-theme recorded its run: $(tr '\t' ' ' <<<"$state")"
  else
    fail "motanka-default-theme recorded '${state:-nothing}', expected ok"
  fi
  unit=$(as_alice systemctl --user show -p ActiveState -p Result motanka-default-theme.service 2>&1 | tr '\n' ' ' || true)
  echo "motanka-default-theme.service: $unit"
}

# check_session_fonts: the desktop shell's environment points fontconfig at
# Motanka's configuration, and with it "monospace", the family of the bar's
# text and icons (shell/Commons/Style.qml), is JetBrainsMono Nerd Font.
check_session_fonts() {
  local pid who=quickshell fcp out family file
  pid=$(pgrep -u alice -x quickshell || true)
  pid=${pid%%$'\n'*}
  if [[ -z $pid ]]; then
    who=Hyprland
    pid=$(pgrep -u alice -x Hyprland || true)
    pid=${pid%%$'\n'*}
  fi
  if [[ -z $pid ]]; then
    fail "neither quickshell nor Hyprland runs for alice; the session's font configuration cannot be checked"
    return 0
  fi
  sudo cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | LC_ALL=C sort >"$L/session-env-$who.txt" || true
  fcp=$(sed -n 's/^FONTCONFIG_PATH=//p' "$L/session-env-$who.txt")
  if [[ $fcp == "$FONTCONFIG_DIR" || $fcp == "$FONTCONFIG_DIR":* ]]; then
    pass "$who (pid $pid) has FONTCONFIG_PATH=$fcp"
  else
    fail "$who (pid $pid) has FONTCONFIG_PATH='${fcp:-unset}', expected $FONTCONFIG_DIR"
  fi
  out=$(as_alice env FONTCONFIG_PATH="${fcp:-$FONTCONFIG_DIR}" fc-match -f '%{family}\t%{file}\n' monospace 2>&1 || true)
  printf '%s\n' "$out" >"$L/fc-match-session.txt"
  family=${out%%$'\t'*}
  file=${out#*$'\t'}
  if [[ ,$family, == *",$FONT_FAMILY,"* && $file == "$FONTS_DIR"/* ]]; then
    pass "in the session, monospace (the bar's font family) is $FONT_FAMILY from $file"
  else
    fail "in the session, fc-match monospace gives '$out', expected $FONT_FAMILY from $FONTS_DIR"
  fi
}

# check_wallpaper: the desktop shell's wallpaper layer is mapped and the
# theme's background link points to an image.
check_wallpaper() {
  local sig out ns bg
  sig=$(alice_sig)
  out=$(as_alice env HYPRLAND_INSTANCE_SIGNATURE="$sig" "$PREFIX/bin/hyprctl" -j layers 2>&1 || true)
  printf '%s\n' "$out" >"$L/layers.json"
  ns=$(python3 -c 'import json, sys
def walk(x):
    if isinstance(x, dict):
        if isinstance(x.get("namespace"), str):
            yield x["namespace"]
        for v in x.values():
            yield from walk(v)
    elif isinstance(x, list):
        for v in x:
            yield from walk(v)
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
print(" ".join(sorted(set(walk(data)))))' <<<"$out")
  if [[ " $ns " == *" omarchy-background "* ]]; then
    pass "hyprctl layers has the wallpaper layer omarchy-background (layers: $ns)"
  else
    fail "hyprctl layers has no omarchy-background layer (layers: ${ns:-none})"
  fi
  bg=$(sudo readlink -f "$AHOME/.local/state/omarchy/current/background" 2>/dev/null || true)
  if [[ -n $bg ]] && sudo test -f "$bg"; then
    pass "the theme's background link points to the image $bg"
  else
    fail "the background link ~/.local/state/omarchy/current/background resolves to '${bg:-nothing}'"
  fi
}

phase_login() {
  mkdir -p "$L"
  start_alice_session || return 0
  check_setup || return 0
  if wait_for 120 hyprland_running; then
    pass "Hyprland runs for alice (pid $(pgrep -u alice -x Hyprland | head -n 1))"
  else
    fail "Hyprland did not start for alice within 120 s"
    collect_alice_logs
    tail -n 40 "$L/launcher-alice.log" 2>/dev/null | show
    return 0
  fi
  check_environment
  check_verify_config
  check_compositor_probe
  check_default_theme
  check_session_fonts
  check_wallpaper
  screenshot_alice
  echo "shell integration decision: $(sudo cat "$AHOME/.local/state/motanka/shell-integration" 2>/dev/null || echo 'none yet')"
  check_fonts_hidden after-login
  check_bob after-login
  collect_alice_logs
}

phase_logout() {
  local id
  mkdir -p "$L"
  as_alice "$PREFIX/bin/uwsm" stop >>"$L/uwsm-stop.log" 2>&1 || true
  sudo rm -f -- "$DROPIN"
  sudo rmdir -- "$DROPIN_DIR" 2>/dev/null || true
  sudo rm -f -- "$AHOME/.bash_profile" "$AT/launch"
  sudo systemctl daemon-reload
  for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$3 == "alice" { print $1 }'); do
    sudo loginctl terminate-session "$id" 2>/dev/null || true
  done
  sudo systemctl restart getty@tty1 2>/dev/null || true
  if wait_for 60 bash -c '! pgrep -u alice -x Hyprland >/dev/null'; then
    pass "alice's session ended"
  else
    fail "alice's Hyprland still runs after logout"
  fi
  check_capture
  collect_alice_logs
}

capture_ended() {
  ! sudo test -e "$AHOME/.local/state/motanka/capture/start"
}

# check_capture: the session capture recorded the default theme's writes by
# their class, and none as unplanned (design.md, "Session-time home writes").
check_capture() {
  local unplanned
  if ! wait_for 90 capture_ended; then
    echo "SKIP: alice's session capture is still pending 90 s after logout; it ends at her next login or at 'motanka remove'"
    return 0
  fi
  unplanned=$(sudo awk -F'\t' '$3 == "unplanned" { print $5 }' "$ALEDGER")
  if [[ -z $unplanned ]]; then
    pass "after the session, alice's User_Ledger has no unplanned home-folder path"
  else
    fail "unplanned paths in alice's User_Ledger after the session:"
    printf '%s\n' "$unplanned" | show
  fi
  if sudo awk -F'\t' '$3 == "adopt" && $5 == ".config/btop/themes/current.theme" { found = 1 } END { exit !found }' "$ALEDGER"; then
    pass "the session capture adopted the default theme's ~/.config/btop/themes/current.theme"
  else
    fail "the session capture has no adopt line for ~/.config/btop/themes/current.theme"
  fi
}

main() {
  (($# == 2)) || {
    echo "usage: bash first-login-guest.sh <prepare|install|login|logout> <release>" >&2
    exit 2
  }
  PHASE=$1
  RELEASE=$2
  guard
  echo "release $RELEASE, phase $PHASE"
  case $PHASE in
    prepare) phase_prepare ;;
    install) phase_install ;;
    login) phase_login ;;
    logout) phase_logout ;;
    *)
      echo "unknown phase '$PHASE'" >&2
      exit 2
      ;;
  esac
  exit $((fails > 0 ? 1 : 0))
}

main "$@"
