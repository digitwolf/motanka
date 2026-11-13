#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # stub scripts are single-quoted on purpose
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; variables are set per test on purpose
# Unit tests for task 15.1 and 15.2: the session launcher
# src/libexec/session, its cleanup mode, the session entry and the
# Session_Env_List (5.1, 5.2, 5.11, 5.12, 5.14, 8.6, 8.9).
#
# The Stack (uwsm, start-hyprland, Hyprland), per-user setup, sysfs and
# /proc live in a fake root (MOTANKA_ROOT). loginctl, systemctl and
# systemd-cat are stubs on PATH; the systemctl stub keeps the user manager's
# environment in $STUB_STATE/env (one "NAME<TAB>value" line each) and prints
# it as systemctl show-environment does, quoting values with $'...'.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  SESSION="$REPO/src/libexec/session"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  export STUB_STATE="$BATS_TEST_TMPDIR/state"
  S=$STUB_STATE
  STUBS="$BATS_TEST_TMPDIR/stubs"
  P="$MOTANKA_ROOT/opt/motanka"
  mkdir -p "$S" "$STUBS" "$P/bin" "$P/libexec/motanka" "$P/share/motanka" "$P/lib/systemd/user"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 0700 "$XDG_RUNTIME_DIR"
  export XDG_SESSION_ID=5
  unset LD_LIBRARY_PATH DCONF_PROFILE OMARCHY_PATH XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP
  export XDG_DATA_DIRS=/usr/local/share:/usr/share
  export NO_COLOR=1

  cp "$REPO/packaging/motanka-core/session-env.list" "$P/share/motanka/"
  local u
  for u in wayland-wm@.service wayland-wm-env@.service wayland-session@.target \
    wayland-session-bindpid@.service app-graphical.slice hyprsunset.service; do
    printf '[Unit]\n' >"$P/lib/systemd/user/$u"
  done
  printf '#!/bin/sh\nexit 0\n' >"$P/bin/start-hyprland"
  printf '#!/bin/sh\nexit 0\n' >"$P/bin/Hyprland"
  cat >"$P/bin/uwsm" <<'EOF'
#!/bin/bash
S=$STUB_STATE
printf '%s\n' "$@" >"$S/uwsm.args"
env | LC_ALL=C sort >"$S/uwsm.env"
echo uwsm >>"$S/order"
find "$XDG_RUNTIME_DIR/systemd/user" -maxdepth 1 -type l -printf '%f -> %l\n' 2>/dev/null |
  LC_ALL=C sort >"$S/units-during"
echo active >"$S/active-graphical-session.target"
for _ in $(seq 60); do
  grep -qx -- '--user start motanka-session.target' "$S/systemctl.log" 2>/dev/null && break
  sleep 0.1
done
# What uwsm and the compositor put into the user manager.
systemctl --user set-environment XDG_CURRENT_DESKTOP=Motanka:Hyprland DCONF_PROFILE=motanka \
  OMARCHY_PATH=/usr/share/omarchy "PATH=$PATH" "XDG_DATA_DIRS=$XDG_DATA_DIRS" \
  WAYLAND_DISPLAY=wayland-1 "EDITOR=omarchy-launch-editor --inline"
rm -f "$S/active-graphical-session.target"
exit "$(cat "$S/uwsm.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$P/bin/uwsm" "$P/bin/start-hyprland" "$P/bin/Hyprland"

  cat >"$STUBS/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
S=$STUB_STATE
printf '%s\n' "$*" >>"$S/systemctl.log"
if [[ ${1:-} == --user ]]; then
  shift
fi
q() {
  local v=$1
  if [[ $v =~ ^[A-Za-z0-9_@%+=:,./-]*$ ]]; then
    printf '%s' "$v"
  else
    v=${v//\\/\\\\}
    v=${v//\'/\\\'}
    printf "\$'%s'" "$v"
  fi
}
drop() {
  grep -v "^$1"$'\t' "$S/env" >"$S/env.new" || true
  mv -f "$S/env.new" "$S/env"
}
case ${1:-} in
  show-environment)
    [[ ! -e $S/env-fail ]] || exit 1
    while IFS=$'\t' read -r n v; do
      [[ -n $n ]] || continue
      printf '%s=%s\n' "$n" "$(q "$v")"
    done <"$S/env"
    ;;
  set-environment)
    shift
    for a in "$@"; do
      drop "${a%%=*}"
      printf '%s\t%s\n' "${a%%=*}" "${a#*=}" >>"$S/env"
    done
    ;;
  unset-environment)
    shift
    for n in "$@"; do
      drop "$n"
    done
    ;;
  is-active)
    shift
    [[ ${1:-} != --quiet ]] || shift
    st=$(cat "$S/active-$1" 2>/dev/null || echo inactive)
    echo "$st"
    [[ $st == active ]]
    ;;
  show)
    echo "${STUB_DBUS_ID:-dbus-broker.service}"
    ;;
esac
EOF
  cat >"$STUBS/loginctl" <<'EOF'
#!/bin/bash
S=$STUB_STATE
printf '%s\n' "$*" >>"$S/loginctl.log"
case $1 in
  show-user)
    [[ ! -e $S/loginctl-fail ]] || exit 1
    cat "$S/sessions" 2>/dev/null || echo "$XDG_SESSION_ID"
    ;;
  show-session)
    cat "$S/session-$2" 2>/dev/null || exit 1
    ;;
esac
EOF
  cat >"$STUBS/systemd-cat" <<'EOF'
#!/bin/bash
{
  printf '[%s] ' "$*"
  cat
} >>"$STUB_STATE/journal"
EOF
  cat >"$STUBS/dbus-update-activation-environment" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$STUB_STATE/dbus.args"
EOF
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"

  printf 'PATH\t/usr/local/bin:/usr/bin:/bin\nHOME\t/home/tester\nLANG\tC.UTF-8\nXDG_DATA_DIRS\t/usr/share:/var/lib/snapd/desktop\nEDITOR\tvim -n\nGREETING\thello world\n' >"$S/env"
  LC_ALL=C sort "$S/env" >"$S/env.before"
  : >"$S/systemctl.log"
  gpu card0 i915
  mkdir -p "$MOTANKA_ROOT/sys/class/drm/card0-eDP-1"
}

# gpu <card> <driver>: a DRM card bound to <driver> in the fake sysfs.
gpu() {
  mkdir -p "$MOTANKA_ROOT/sys/class/drm/$1/device"
  ln -sfn "../../../../bus/pci/drivers/$2" "$MOTANKA_ROOT/sys/class/drm/$1/device/driver"
}

# nvidia <version>: the loaded NVIDIA driver reports <version>.
nvidia() {
  mkdir -p "$MOTANKA_ROOT/proc/driver/nvidia"
  printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  %s  Release Build\n' "$1" \
    >"$MOTANKA_ROOT/proc/driver/nvidia/version"
}

# user_setup <exit-code>: installs a per-user setup stub.
user_setup() {
  cat >"$P/libexec/motanka/user-setup" <<EOF
#!/bin/bash
echo setup >>"\$STUB_STATE/order"
printf '%s\n' "\${DCONF_PROFILE:-unset}" "\${XDG_CURRENT_DESKTOP:-unset}" >"\$STUB_STATE/setup.env"
exit $1
EOF
  chmod +x "$P/libexec/motanka/user-setup"
}

session() {
  run bash "$SESSION" "$@"
}

env_now() {
  LC_ALL=C sort "$S/env"
}

@test "starts the Stack's uwsm with Upstream's arguments and the Stack's start-hyprland and Hyprland" {
  session
  assert_success
  run cat "$S/uwsm.args"
  assert_output "$(printf '%s\n' start -U run -g -1 -e -D Motanka:Hyprland -N Motanka \
    -C 'Omarchy-compatible Hyprland session' -- "$P/bin/start-hyprland" --path "$P/bin/Hyprland")"
}

@test "exports the session environment and never LD_LIBRARY_PATH" {
  local orig=$PATH
  PATH="/opt/motanka/bin:$orig" LD_LIBRARY_PATH=/somewhere XDG_DATA_DIRS=/usr/share:/opt/motanka/share session
  assert_success
  run grep -x 'XDG_CURRENT_DESKTOP=Motanka:Hyprland' "$S/uwsm.env"
  assert_success
  run grep -x 'XDG_SESSION_DESKTOP=motanka' "$S/uwsm.env"
  assert_success
  run grep -x 'DCONF_PROFILE=motanka' "$S/uwsm.env"
  assert_success
  run grep -x 'OMARCHY_PATH=/usr/share/omarchy' "$S/uwsm.env"
  assert_success
  run grep -x "PATH=/opt/motanka/bin:$orig" "$S/uwsm.env"
  assert_success
  run grep -x 'XDG_DATA_DIRS=/opt/motanka/share:/usr/share' "$S/uwsm.env"
  assert_success
  run grep '^LD_LIBRARY_PATH=' "$S/uwsm.env"
  assert_failure
  run grep -F 'LD_LIBRARY_PATH was set for the session and is removed' "$S/journal"
  assert_success
}

@test "without XDG_DATA_DIRS the default folders follow /opt/motanka/share" {
  unset XDG_DATA_DIRS
  session
  assert_success
  run grep -x 'XDG_DATA_DIRS=/opt/motanka/share:/usr/local/share:/usr/share' "$S/uwsm.env"
  assert_success
}

@test "another active graphical session of the user refuses the start with exit 12 and a journal entry" {
  printf '5 7\n' >"$S/sessions"
  printf 'Type=wayland\nState=online\nClass=user\n' >"$S/session-7"
  session
  assert_failure 12
  assert_output --partial 'already has another graphical session (logind session 7 (wayland, online))'
  run grep -F '[-t motanka -p err] motanka session: refused: user' "$S/journal"
  assert_success
  [[ ! -e $S/uwsm.args ]]
}

@test "an X11 session of the user refuses the start too" {
  printf '5 9\n' >"$S/sessions"
  printf 'Type=x11\nState=active\nClass=user\n' >"$S/session-9"
  session
  assert_failure 12
  [[ ! -e $S/uwsm.args ]]
}

@test "its own session, tty sessions, greeters and closing sessions do not refuse the start" {
  printf '5 6 7 8\n' >"$S/sessions"
  printf 'Type=wayland\nState=active\nClass=user\n' >"$S/session-5"
  printf 'Type=tty\nState=online\nClass=user\n' >"$S/session-6"
  printf 'Type=x11\nState=closing\nClass=user\n' >"$S/session-7"
  printf 'Type=wayland\nState=active\nClass=greeter\n' >"$S/session-8"
  session
  assert_success
  [[ -e $S/uwsm.args ]]
}

@test "an active graphical-session.target refuses the start with exit 12" {
  echo active >"$S/active-graphical-session.target"
  session
  assert_failure 12
  assert_output --partial 'graphical-session.target of user'
  [[ ! -e $S/uwsm.args ]]
}

@test "a second launcher of the same user is refused with exit 12" {
  local fd
  mkdir -p "$XDG_RUNTIME_DIR/motanka" && chmod 0700 "$XDG_RUNTIME_DIR/motanka"
  exec {fd}>>"$XDG_RUNTIME_DIR/motanka/session.lock"
  flock -n "$fd"
  session
  exec {fd}>&-
  assert_failure 12
  assert_output --partial 'another Motanka session of user'
  [[ ! -e $S/uwsm.args ]]
}

@test "virtio_gpu is supported" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 virtio_gpu
  session
  assert_success
  run grep -F 'GPU: card0 (virtio_gpu)' "$S/journal"
  assert_success
}

@test "a virtio GPU on its PCI function (kernel 7.0 layout) is supported" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 virtio-pci
  mkdir -p "$MOTANKA_ROOT/sys/class/drm/card0/device/virtio2"
  ln -sfn ../../../../bus/virtio/drivers/virtio_gpu "$MOTANKA_ROOT/sys/class/drm/card0/device/virtio2/driver"
  session
  assert_success
  run grep -F 'GPU: card0 (virtio_gpu)' "$S/journal"
  assert_success
}

@test "a PCI virtio device without a virtio GPU driver is not supported" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 virtio-pci
  session
  assert_failure 12
  assert_output --partial 'the GPU driver of card0 (virtio-pci) is not supported'
}

@test "every supported driver starts the session" {
  local d
  for d in i915 xe amdgpu radeon nouveau virtio_gpu; do
    rm -rf "$MOTANKA_ROOT/sys/class/drm/card0" "$S/uwsm.args"
    gpu card0 "$d"
    session
    assert_success
    [[ -e $S/uwsm.args ]]
  done
}

@test "the NVIDIA driver 560 is supported" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 nvidia
  nvidia 560.35.03
  session
  assert_success
  run grep -F 'GPU: card0 (nvidia 560.35.03)' "$S/journal"
  assert_success
}

@test "the NVIDIA driver 555 is supported, read from /sys/module/nvidia/version" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 nvidia
  mkdir -p "$MOTANKA_ROOT/sys/module/nvidia"
  printf '555.42.02\n' >"$MOTANKA_ROOT/sys/module/nvidia/version"
  session
  assert_success
}

@test "the NVIDIA driver 550 refuses the start with exit 12 and the reason in the journal" {
  gpu card1 nvidia
  nvidia 550.120
  session
  assert_failure 12
  assert_output --partial 'card1 runs the NVIDIA driver 550.120; the Motanka session needs the NVIDIA driver 555 or later'
  run grep -F 'refused: card1 runs the NVIDIA driver 550.120' "$S/journal"
  assert_success
  [[ ! -e $S/uwsm.args ]]
}

@test "an NVIDIA card of unknown driver version refuses the start" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 nvidia
  session
  assert_failure 12
  assert_output --partial 'NVIDIA driver of unknown version'
}

@test "a GPU with an unsupported driver refuses the start with exit 12" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm/card0"
  gpu card0 vmwgfx
  session
  assert_failure 12
  assert_output --partial 'the GPU driver of card0 (vmwgfx) is not supported'
  run grep -F 'card0 (vmwgfx) is not supported' "$S/journal"
  assert_success
}

@test "no DRM card refuses the start with exit 12" {
  rm -rf "$MOTANKA_ROOT/sys/class/drm"
  session
  assert_failure 12
  assert_output --partial 'no GPU with a kernel display driver was found'
}

@test "an unsupported driver next to a supported one is logged and ignored" {
  gpu card1 evdi
  session
  assert_success
  run grep -F 'ignoring card1 (evdi)' "$S/journal"
  assert_success
}

@test "per-user setup runs before the compositor, with the session environment" {
  user_setup 0
  session
  assert_success
  run cat "$S/order"
  assert_output "$(printf 'setup\nuwsm')"
  run cat "$S/setup.env"
  assert_output "$(printf 'motanka\nMotanka:Hyprland')"
}

@test "without per-user setup the session starts and says so in the journal" {
  session
  assert_success
  run grep -F 'no per-user setup is installed' "$S/journal"
  assert_success
}

@test "a failing per-user setup stops the start with exit 1 before the compositor" {
  user_setup 3
  session
  assert_failure 1
  assert_output --partial 'per-user setup failed (exit 3)'
  [[ ! -e $S/uwsm.args ]]
}

@test "uwsm's units are linked into the runtime unit folder for the session and removed afterwards" {
  local dst=$XDG_RUNTIME_DIR/systemd/user
  mkdir -p "$dst"
  printf 'mine\n' >"$dst/other.service"
  session
  assert_success
  run cat "$S/units-during"
  assert_line "wayland-wm@.service -> $P/lib/systemd/user/wayland-wm@.service"
  assert_line "wayland-wm-env@.service -> $P/lib/systemd/user/wayland-wm-env@.service"
  assert_line "wayland-session@.target -> $P/lib/systemd/user/wayland-session@.target"
  assert_line "wayland-session-bindpid@.service -> $P/lib/systemd/user/wayland-session-bindpid@.service"
  assert_line "app-graphical.slice -> $P/lib/systemd/user/app-graphical.slice"
  refute_output --partial hyprsunset
  run find "$dst" -type l
  assert_output ''
  run cat "$dst/other.service"
  assert_output mine
  run grep -cx -- '--user daemon-reload' "$S/systemctl.log"
  assert_output 2
}

@test "motanka-session.target starts once the graphical session is active and stops at the end" {
  session
  assert_success
  run grep -x -- '--user start motanka-session.target' "$S/systemctl.log"
  assert_success
  run grep -x -- '--user stop motanka-session.target' "$S/systemctl.log"
  assert_success
}

@test "the user manager's environment is the same after the session as before it" {
  session
  assert_success
  run env_now
  assert_output "$(cat "$S/env.before")"
  [[ ! -e $XDG_RUNTIME_DIR/motanka/session-env.pre ]]
}

@test "uwsm's exit code is passed through and the session is still cleaned up" {
  echo 3 >"$S/uwsm.rc"
  session
  assert_failure 3
  run env_now
  assert_output "$(cat "$S/env.before")"
  run find "$XDG_RUNTIME_DIR/systemd/user" -type l
  assert_output ''
}

@test "values left by an earlier Motanka session are removed before the snapshot" {
  printf 'PATH\t/opt/motanka/bin:/usr/bin\nDCONF_PROFILE\tmotanka\nXDG_CURRENT_DESKTOP\tMotanka:Hyprland\nHOME\t/home/tester\n' >"$S/env"
  session
  assert_success
  run grep -F 'still has the environment of an earlier Motanka session' "$S/journal"
  assert_success
  run env_now
  assert_output "$(printf 'HOME\t/home/tester\nPATH\t/usr/bin')"
}

@test "cleanup without a snapshot strips /opt/motanka from PATH and XDG_DATA_DIRS and unsets the rest" {
  printf 'PATH\t/opt/motanka/bin:/usr/bin\nXDG_DATA_DIRS\t/opt/motanka/share:/usr/share\nDCONF_PROFILE\tmotanka\nXDG_CURRENT_DESKTOP\tMotanka:Hyprland\nWAYLAND_DISPLAY\twayland-1\nHOME\t/home/tester\n' >"$S/env"
  session cleanup
  assert_success
  run env_now
  assert_output "$(printf 'HOME\t/home/tester\nPATH\t/usr/bin\nXDG_DATA_DIRS\t/usr/share')"
}

@test "cleanup with a snapshot restores the saved values, quoted ones included" {
  mkdir -p "$XDG_RUNTIME_DIR/motanka"
  printf '# snapshot\nPATH=/usr/bin\nEDITOR=$'"'"'vim -n'"'"'\n# complete\n' >"$XDG_RUNTIME_DIR/motanka/session-env.pre"
  printf 'PATH\t/opt/motanka/bin:/x\nDCONF_PROFILE\tmotanka\nEDITOR\tnano\nHOME\t/home/tester\n' >"$S/env"
  session cleanup
  assert_success
  run env_now
  assert_output "$(printf 'EDITOR\tvim -n\nHOME\t/home/tester\nPATH\t/usr/bin')"
}

@test "cleanup ignores an incomplete snapshot" {
  mkdir -p "$XDG_RUNTIME_DIR/motanka"
  printf 'PATH=/wrong\n' >"$XDG_RUNTIME_DIR/motanka/session-env.pre"
  printf 'PATH\t/opt/motanka/bin:/usr/bin\nDCONF_PROFILE\tmotanka\n' >"$S/env"
  session cleanup
  assert_success
  run env_now
  assert_output "$(printf 'PATH\t/usr/bin')"
}

@test "cleanup with the reference D-Bus daemon also resets its activation environment" {
  export STUB_DBUS_ID=dbus.service
  printf 'PATH\t/opt/motanka/bin:/usr/bin\nDCONF_PROFILE\tmotanka\n' >"$S/env"
  session cleanup
  assert_success
  run cat "$S/dbus.args"
  assert_line 'DCONF_PROFILE='
  assert_line 'XDG_CURRENT_DESKTOP='
  assert_line 'PATH=/usr/bin'
}

@test "cleanup with dbus-broker leaves the D-Bus activation environment alone" {
  printf 'DCONF_PROFILE\tmotanka\n' >"$S/env"
  session cleanup
  assert_success
  [[ ! -e $S/dbus.args ]]
}

@test "a missing Stack program stops the start with exit 1" {
  rm -f "$P/bin/uwsm"
  session
  assert_failure 1
  assert_output --partial "$P/bin/uwsm is missing or not executable"
}

@test "missing uwsm unit files stop the start with exit 1" {
  rm -f "$P"/lib/systemd/user/*
  session
  assert_failure 1
  assert_output --partial 'no uwsm unit files'
  [[ ! -e $S/uwsm.args ]]
}

@test "no XDG_RUNTIME_DIR stops the start with exit 1" {
  unset XDG_RUNTIME_DIR
  session
  assert_failure 1
  assert_output --partial 'XDG_RUNTIME_DIR is not set'
}

@test "an unknown argument is a usage error" {
  session --bogus
  assert_failure 2
}

@test "the Session_Env_List names every variable the launcher sets" {
  local v list="$REPO/packaging/motanka-core/session-env.list"
  for v in XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DCONF_PROFILE OMARCHY_PATH PATH XDG_DATA_DIRS \
    WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE; do
    run grep -qx "$v" "$list"
    assert_success
  done
  run grep -x 'LD_LIBRARY_PATH' "$list"
  assert_failure
}

@test "the session entry runs the launcher with the desktop names Motanka and Hyprland" {
  local entry="$REPO/packaging/motanka-core/motanka.desktop"
  run grep -x 'Name=Motanka' "$entry"
  assert_success
  run grep -x 'Exec=/opt/motanka/libexec/motanka/session' "$entry"
  assert_success
  run grep -x 'DesktopNames=Motanka;Hyprland' "$entry"
  assert_success
  run grep -x 'Type=Application' "$entry"
  assert_success
}

@test "the user units wire the cleanup to motanka-session.target, not to graphical-session.target" {
  local d="$REPO/packaging/motanka-core/systemd"
  run grep -x 'BindsTo=graphical-session.target' "$d/motanka-session.target"
  assert_success
  run grep -x 'Before=graphical-session.target' "$d/motanka-session.target"
  assert_success
  run grep -x 'PartOf=motanka-session.target' "$d/motanka-session-cleanup.service"
  assert_success
  run grep -x 'ExecStop=/opt/motanka/libexec/motanka/session cleanup' "$d/motanka-session-cleanup.service"
  assert_success
  run grep -h '^\[Install\]\|WantedBy=' "$d/motanka-session.target" "$d/motanka-session-cleanup.service"
  assert_output ''
}
