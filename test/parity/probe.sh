#!/usr/bin/env bash
# Parity probe (task 24.3, requirement 13.6): records user-visible facts of a
# running Upstream session as one JSON document, the same way on the Arch
# reference VM and on a Motanka VM, so that test/parity/diff.py can compare
# the two.
#
# Usage: probe.sh --out DIR [--settle SECONDS] [--timeout SECONDS]
#
# Runs INSIDE a test VM as the user whose graphical session is running; it
# refuses root, a machine that is not a VM and a Protected_Host. It changes
# nothing: every command it runs only reads state.
#
# Steps:
#   1. Wait up to --timeout s (default 300) for the user's Hyprland and its
#      IPC socket.
#   2. Ask the compositor to run a one-line script that writes its
#      environment (env -0) to DIR/raw/session.env, so that later commands
#      see what a command started from a keybinding sees. If that fails, the
#      compositor's initial environment from /proc is used and the error is
#      recorded. The dump is deleted at the end; probe.json keeps only the
#      allowlisted variables.
#   3. Wait up to 120 s for Upstream's shell to answer
#      "omarchy-shell shell ping", then --settle s more (default 20).
#   4. In that environment: a grim screenshot DIR/screenshot.png; hyprctl -j
#      version, configerrors, layers, clients, binds, monitors and selected
#      getoption values; quickshell --version; systemctl --user active and
#      failed units and show-environment; busctl --user list; the user's
#      processes; read-only Upstream queries (omarchy-version, the current
#      theme and font, the shell's ping and plugin list, and the readers
#      omarchy-menu itself runs every time it opens); omarchy-theme-list.
#   5. test/parity/probe.py turns DIR/raw/ into DIR/probe.json. It adds the
#      Upstream commands and companion tools on the session PATH with their
#      resolved paths, the top level of omarchy-menu (from its JSONC files
#      and the "when" conditions the menu evaluates; no menu action runs),
#      the SHA-256 of Upstream's files, and the allowlisted environment
#      variables.
#
# Nothing is read from home-folder files except what those commands print,
# the menu's own files (menu definitions, language code) and the names of
# themes.
#
# Exit codes: 0 probe.json written; 1 no session found (probe.json is still
# written and names the error); 2 usage error; 7 refused (root, not a VM,
# Protected_Host).
set -euo pipefail
export LC_ALL=C.UTF-8
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
USAGE="probe.sh --out DIR [--settle SECONDS] [--timeout SECONDS]"
SHELL_TIMEOUT=120

# Hyprland options read with hyprctl getoption.
OPTIONS=(general:gaps_in general:gaps_out general:border_size general:layout decoration:rounding
  decoration:active_opacity decoration:inactive_opacity input:kb_layout input:repeat_rate
  input:repeat_delay input:follow_mouse misc:disable_hyprland_logo misc:force_default_wallpaper
  cursor:no_hardware_cursors)

# Read-only Upstream queries. From "omarchy-bar background" on, these are the
# readers omarchy-menu runs on every open (GUARD_READERS in
# shell/plugins/menu/MenuModel.js), with the same arguments.
QUERIES=(
  "omarchy-version"
  "omarchy-theme-current"
  "omarchy-font-current"
  "omarchy-hw-platform"
  "omarchy-shell shell ping"
  "omarchy-shell shell listPlugins"
  "omarchy-menu ping"
  "omarchy-bar background"
  "omarchy-bar get omarchy.power showPercentage"
  "omarchy-bar get omarchy.clock format"
  "omarchy-bar get omarchy.clock verticalFormat"
  "omarchy-bar position"
  "omarchy-channel-current"
  "omarchy-default-agent"
  "omarchy-default-browser"
  "omarchy-default-editor"
  "omarchy-default-terminal"
  "omarchy-default-dictation"
  "omarchy-dns"
  "omarchy-dock autohide"
  "omarchy-dock position"
  "omarchy-hyprland-corners"
  "omarchy-hyprland-window-transparency"
  "omarchy-hyprland-workspace-layout-default"
  "omarchy-shell notifications isDnd"
  "omarchy-toggle-nightlight --status"
)

say() { printf 'probe: %s\n' "$*" >&2; }

usage_error() {
  say "$1"
  printf 'usage: %s\n' "$USAGE" >&2
  exit 2
}

OUT=""
SETTLE=20
TIMEOUT=300
while (($# > 0)); do
  case $1 in
    --out | --settle | --timeout)
      if (($# < 2)); then
        usage_error "$1 needs a value"
      fi
      case $1 in
        --out) OUT=$2 ;;
        --settle) SETTLE=$2 ;;
        --timeout) TIMEOUT=$2 ;;
      esac
      shift 2
      ;;
    -h | --help)
      printf 'usage: %s\n' "$USAGE"
      exit 0
      ;;
    *)
      usage_error "unknown argument '$1'"
      ;;
  esac
done
if [[ -z $OUT ]]; then
  usage_error "--out is required"
fi
# The folder ends up inside a script the compositor runs, so only plain
# characters are accepted.
if [[ ! $OUT =~ ^/[A-Za-z0-9._/-]+$ || $OUT == *..* ]]; then
  usage_error "--out must be an absolute path of letters, digits, '.', '_', '-' and '/', got '$OUT'"
fi
if [[ ! $SETTLE =~ ^[0-9]+$ || ! $TIMEOUT =~ ^[1-9][0-9]*$ ]]; then
  usage_error "--settle and --timeout take a number of seconds"
fi

if ((EUID == 0)); then
  say "refusing to run as root; run it as the user whose session is running"
  exit 7
fi
virt=$(systemd-detect-virt 2>/dev/null || true)
if [[ -z $virt || $virt == none ]]; then
  say "refusing to run outside a test VM (systemd-detect-virt: ${virt:-unavailable})"
  exit 7
fi
if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
  say "refusing to run on a Protected_Host"
  exit 7
fi

RAW=$OUT/raw
mkdir -p "$OUT"
rm -rf -- "$RAW" "$OUT/probe.json" "$OUT/screenshot.png"
mkdir -p "$RAW"
: >"$RAW/errors.tsv"
UIDN=$(id -u)
RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$UIDN}
OWN_SID=$(ps -o sid= -p "$$" | tr -d ' ')
HPID=""
SIG=""
BENV=()
SENV=()

# note <step> <message>: records an error for probe.json.
note() {
  local msg=${2//$'\n'/ }
  printf '%s\t%s\n' "$1" "${msg//$'\t'/ }" >>"$RAW/errors.tsv"
  say "$1: $msg"
}

assemble() {
  python3 "$HERE/probe.py" --raw "$RAW" --out "$OUT/probe.json" --own-sid "$OWN_SID" \
    --screenshot "$OUT/screenshot.png" "$@"
}

compositor_pid() {
  pgrep -u "$UIDN" -x Hyprland 2>/dev/null | head -n 1 || true
}

# Prints the newest Hyprland instance of the user that has an IPC socket.
instance_sig() {
  local -a dirs=()
  local d
  mapfile -t dirs < <(find "$RUNTIME/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%f\n' 2>/dev/null |
    sort -rn | cut -f2)
  for d in "${dirs[@]}"; do
    if [[ -S $RUNTIME/hypr/$d/.socket.sock ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# Prints the user's Wayland socket name, if any.
wayland_socket() {
  find "$RUNTIME" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' 2>/dev/null | sort | head -n 1 || true
}

wait_for_session() {
  local deadline=$((SECONDS + TIMEOUT))
  say "waiting up to $TIMEOUT s for the Hyprland session of $(id -un)"
  while :; do
    HPID=$(compositor_pid)
    SIG=$(instance_sig || true)
    if [[ -n $HPID && -n $SIG && -r /proc/$HPID/environ ]]; then
      mapfile -d '' -t BENV <"/proc/$HPID/environ"
      BENV+=("XDG_RUNTIME_DIR=$RUNTIME" "HYPRLAND_INSTANCE_SIGNATURE=$SIG")
      if timeout 10 env -i "${BENV[@]}" hyprctl -j monitors </dev/null >/dev/null 2>&1; then
        say "Hyprland $HPID, instance $SIG"
        return 0
      fi
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 2
  done
}

capture_session_env() {
  local script=$RAW/envdump.sh reply i sock
  cat >"$script" <<EOF
#!/bin/sh
env -0 >$RAW/session.env.tmp && mv $RAW/session.env.tmp $RAW/session.env
EOF
  reply=$(timeout 10 env -i "${BENV[@]}" hyprctl dispatch "hl.dsp.exec_cmd(\"/bin/sh $script\")" </dev/null 2>&1 || true)
  if [[ $reply != *ok* ]]; then
    timeout 10 env -i "${BENV[@]}" hyprctl dispatch exec "/bin/sh $script" </dev/null >/dev/null 2>&1 || true
  fi
  for ((i = 0; i < 20; i++)); do
    if [[ -s $RAW/session.env ]]; then
      echo dispatch >"$RAW/session.src"
      mapfile -d '' -t SENV <"$RAW/session.env"
      return 0
    fi
    sleep 1
  done
  note session-env "the compositor did not run the environment dump (dispatch answered '$reply'); using its initial environment"
  SENV=("${BENV[@]}")
  sock=$(wayland_socket)
  if [[ -n $sock ]]; then
    SENV+=("WAYLAND_DISPLAY=$sock")
  fi
  SENV+=("DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME/bus")
  printf '%s\0' "${SENV[@]}" >"$RAW/session.env"
  echo proc >"$RAW/session.src"
}

# run_raw <file> <seconds> <command...>: runs a command in the session
# environment; stdout to raw/<file>, stderr to raw/<file>.err, exit code to
# raw/<file>.rc.
run_raw() {
  local name=$1 secs=$2 rc=0
  shift 2
  timeout --kill-after=5 "$secs" env -i "${SENV[@]}" "$@" </dev/null >"$RAW/$name" 2>"$RAW/$name.err" || rc=$?
  printf '%s\n' "$rc" >"$RAW/$name.rc"
}

raw_rc() {
  cat "$RAW/$1.rc" 2>/dev/null || echo 1
}

wait_for_shell() {
  local deadline=$((SECONDS + SHELL_TIMEOUT))
  while :; do
    run_raw shell-ping.txt 10 omarchy-shell shell ping
    if [[ $(raw_rc shell-ping.txt) == 0 ]]; then
      say "Upstream's shell answers"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      note shell "omarchy-shell shell ping did not answer within $SHELL_TIMEOUT s"
      return 0
    fi
    sleep 3
  done
}

collect() {
  local x o q i
  local -a argv
  run_raw grim.txt 30 grim "$OUT/screenshot.png"
  if [[ $(raw_rc grim.txt) != 0 ]]; then
    note screenshot "grim failed: $(head -n 1 "$RAW/grim.txt.err")"
  fi
  for x in version configerrors layers clients binds monitors; do
    run_raw "hypr-$x.json" 20 hyprctl -j "$x"
  done
  : >"$RAW/options.tsv"
  i=0
  for o in "${OPTIONS[@]}"; do
    run_raw "option-$i.json" 10 hyprctl -j getoption "$o"
    printf '%s\toption-%s.json\n' "$o" "$i" >>"$RAW/options.tsv"
    i=$((i + 1))
  done
  run_raw quickshell-version.txt 10 quickshell --version
  if [[ $(raw_rc quickshell-version.txt) != 0 ]]; then
    run_raw quickshell-version.txt 10 qs --version
  fi
  run_raw units-active.txt 20 systemctl --user list-units --state=active --no-legend --plain --no-pager
  run_raw units-failed.txt 20 systemctl --user list-units --state=failed --no-legend --plain --no-pager
  run_raw user-env.txt 20 systemctl --user show-environment
  run_raw busctl.txt 20 busctl --user list --no-legend --no-pager
  ps -u "$UIDN" -o pid=,sid=,args= >"$RAW/ps.txt" 2>/dev/null || true
  : >"$RAW/queries.tsv"
  i=0
  for q in "${QUERIES[@]}"; do
    read -r -a argv <<<"$q"
    run_raw "query-$i.txt" 20 "${argv[@]}"
    printf '%s\tquery-%s.txt\n' "$q" "$i" >>"$RAW/queries.tsv"
    i=$((i + 1))
  done
  run_raw themes.txt 20 omarchy-theme-list
}

if ! wait_for_session; then
  note session "no Hyprland session with an IPC socket for $(id -un) within $TIMEOUT s"
  assemble --no-session
  say "wrote $OUT/probe.json (no session)"
  exit 1
fi
capture_session_env
wait_for_shell
if ((SETTLE > 0)); then
  say "letting the session settle for $SETTLE s"
  sleep "$SETTLE"
fi
collect
assemble
# probe.json holds the allowlisted variables; the full dump is not kept.
rm -f -- "$RAW/session.env" "$RAW/envdump.sh"
say "wrote $OUT/probe.json"
