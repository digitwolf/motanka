# shellcheck shell=bash
# shellcheck disable=SC2329 # functions are called by src/motanka and by the unit tests
# motanka install (design.md: Install sequence, CLI, Error Handling;
# requirements 1.1, 1.4-1.6, 2.1-2.11, 3.1, 3.2, 3.7-3.10, 3.15, 4.1,
# 4.5).
#
# Steps, in order. Nothing on the Host changes before step 6.
#   1. options; root (exit 11); the system lock (exit 9). --apps and
#      --no-apps together are a usage error (exit 2).
#   2. preflight, read-only (mk_preflight): release, architecture,
#      universe, dpkg state, free space, display manager, NVIDIA report.
#      Every check runs; the first failure's exit code is returned.
#   3. download the keyring and source packages of the running suite and
#      verify them against the signed SHA256SUMS (aptsim.sh; exit 6)
#   4. apt-get update and a simulated install of motanka with a private
#      apt configuration under /run/motanka
#   5. refuse (exit 5) if a Foreign_Package would be upgraded, downgraded
#      or removed. Then the Motanka_Apps question (2.9-2.11), once, when
#      motanka-apps is not installed:
#        --apps answers yes, --no-apps no (recorded as "flag")
#        --yes alone answers no, and so does a missing terminal on stdin;
#          one line says how to add the applications later ("default")
#        otherwise mk_ask_yes_no asks on the terminal, showing how many
#          packages motanka-apps adds to the simulation of step 4 and
#          their download size (a private simulation of motanka with
#          motanka-apps, and apt-get --print-uris of it); without them it
#          asks anyway. An empty answer is no ("question").
#      With yes, motanka-apps joins the package list of every later step:
#      the Plan becomes the private simulation of motanka with
#      motanka-apps, and its Foreign_Package check refuses with exit 5.
#      When motanka-apps is installed, nothing is asked; --no-apps then
#      leaves it installed and says how to remove it.
#      --dry-run prints the simulated transaction, the answer and the
#      home-folder Plan on stdout and exits 0.
#   6. System_Ledger: run-begin, apps-answer (when the run has an answer,
#      3.15), then one plan line per simulated action, each fsynced before
#      the next step (3.9)
#   7. the account list is saved (mk_accounts_begin); apt-get install of
#      the two verified .debs (skipped for a package already installed at
#      that version or newer); apt-get update
#   8. simulate again with the Host's own configuration (with motanka-apps
#      when the answer is yes); refuse Foreign changes (exit 5); ledger the
#      actions the first simulation did not show
#   9. apt-get install --no-remove --no-install-recommends motanka
#      motanka-source-<suite>, and
#      motanka-apps when the answer is yes; an account-created line for
#      each account the transactions added (mk_accounts_end)
#  10. pkg-installed for every Foreign_Package that a plan line of an
#      install run names as new and that is installed now, unless already
#      recorded (3.7; this also completes an interrupted earlier run);
#      run-end failed for earlier install runs that never ended; run-end ok
#
# If the simulation shows nothing to install, the keyring and source
# packages are installed at least at the verified versions, and no earlier
# install run is unfinished, the Installer exits 0 at step 6 and writes
# nothing (3.10), not even the answer of step 5. That path is never taken
# when the answer is yes and motanka-apps is not installed: its plan
# installs motanka-apps. After run-begin, any exit other than success appends
# run-end failed. The Installer writes nothing into any home folder (3.8):
# downloads, gpgv's home folder and apt's private lists all live under
# /run/motanka.
#
# Requires common.sh, sysledger.sh and aptsim.sh (sourced by src/motanka).
# Test hook: MOTANKA_ROOT (see common.sh).

readonly MK_MIN_FREE_KIB=$((4 * 1024 * 1024))
readonly MK_NVIDIA_MIN_MAJOR=555
readonly MK_HOME_PATHS=/opt/motanka/share/motanka/home-paths.tsv
readonly MK_APPS_PKG=motanka-apps
readonly MK_APPS_LATER="sudo motanka install --apps"

MK_CHANNEL=stable
MK_SUITE=""
MK_PF_CODENAME=""
MK_PF_DM=""
MK_PF_FAIL_CODE=0
MK_INSTALL_BEGUN=0
MK_INSTALL_ENDED=0
# The packages this run installs: motanka, motanka-source-<suite>, and
# motanka-apps when the answer is yes.
MK_INSTALL_PKGS=()
# The Motanka_Apps question: the flag (yes for --apps, no for --no-apps),
# the answer and its source (flag, question or default; both empty when
# motanka-apps is installed already), the installed version of
# motanka-apps, and what the question shows (packages added, download
# size in bytes; empty when unknown), and whether sim-apps.txt holds a
# successful simulation.
MK_APPS_FLAG=""
MK_APPS_ANSWER=""
MK_APPS_SOURCE=""
MK_APPS_INSTALLED=""
MK_APPS_N=""
MK_APPS_BYTES=""
MK_APPS_SIM=0

mk_install_usage() {
  cat <<'EOF'
usage: motanka install [--dry-run] [--yes] [--apps|--no-apps] [--channel stable|edge]

Adds Motanka to this Ubuntu installation as a separate login session.
Runs as root. Every check runs before anything changes.

  --dry-run          run the read-only preflight, verify the repository,
                     print the simulated apt transaction and the
                     home-folder paths first-login setup writes; change
                     nothing
  --yes, -y          do not ask for confirmation; without --apps, do not
                     install motanka-apps
  --apps             also install motanka-apps, the applications upstream
                     Omarchy installs by default, without asking
  --no-apps          do not install motanka-apps, without asking
  --channel CHANNEL  stable (default) follows Upstream release tags,
                     edge follows Upstream's default branch
  -h, --help         show this help

Without --apps, --no-apps and --yes, the Installer asks once whether to
install motanka-apps and shows its download size; an empty answer is no.

Environment: MOTANKA_APT_URI, the repository to fetch the keyring and
source packages from (default https://digitwolf.github.io/motanka/apt).
EOF
}

# --- preflight ----------------------------------------------------------

# _mk_pf_ok <message>, _mk_pf_fail <exit-code> <message>: report one check.
# The first failure's exit code is kept.
_mk_pf_ok() {
  mk_info "preflight: $*"
}

_mk_pf_fail() {
  local code=$1
  shift
  mk_error "preflight: $*"
  if ((MK_PF_FAIL_CODE == 0)); then
    MK_PF_FAIL_CODE=$code
  fi
}

# _mk_pf_os_release <file> <key>: the value of KEY=value, without quotes.
_mk_pf_os_release() {
  local file=$1 key=$2 line v
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line != "$key="* ]]; then
      continue
    fi
    v=${line#*=}
    case $v in
      \"*\" | \'*\') v=${v:1:${#v}-2} ;;
    esac
    printf '%s\n' "$v"
    return 0
  done <"$file"
}

# mk_preflight_release: Supported_Release (1.4). Sets MK_PF_CODENAME.
mk_preflight_release() {
  local file id codename version pretty want=""
  MK_PF_CODENAME=""
  file=$(mk_path /etc/os-release)
  if [[ ! -r $file ]]; then
    file=$(mk_path /usr/lib/os-release)
  fi
  if [[ ! -r $file ]]; then
    _mk_pf_fail "$MK_EXIT_UNSUPPORTED" "cannot read /etc/os-release, so the release is unknown; Motanka supports Ubuntu 24.04 LTS (noble) and Ubuntu 26.04 LTS (resolute)"
    return 0
  fi
  id=$(_mk_pf_os_release "$file" ID)
  codename=$(_mk_pf_os_release "$file" VERSION_CODENAME)
  version=$(_mk_pf_os_release "$file" VERSION_ID)
  pretty=$(_mk_pf_os_release "$file" PRETTY_NAME)
  pretty=${pretty:-${id:-unknown} ${version:-}}
  if [[ $id == ubuntu ]]; then
    case $codename in
      noble) want=24.04 ;;
      resolute) want=26.04 ;;
    esac
  fi
  if [[ -z $want || (-n $version && $version != "$want") ]]; then
    _mk_pf_fail "$MK_EXIT_UNSUPPORTED" "unsupported release: $pretty (ID=${id:-none}, VERSION_CODENAME=${codename:-none}, VERSION_ID=${version:-none}); Motanka supports Ubuntu 24.04 LTS (noble) and Ubuntu 26.04 LTS (resolute)"
    return 0
  fi
  MK_PF_CODENAME=$codename
  _mk_pf_ok "release: $pretty ($codename)"
}

# mk_preflight_arch: amd64 only (1.5).
mk_preflight_arch() {
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null) || arch=""
  if [[ $arch != amd64 ]]; then
    _mk_pf_fail "$MK_EXIT_UNSUPPORTED" "unsupported architecture: ${arch:-unknown}; Motanka supports amd64 only"
    return 0
  fi
  _mk_pf_ok "architecture: amd64"
}

# _mk_pf_deb822_has <file> <suite> <component>: prints yes if an enabled
# deb822 stanza of Types deb has the suite and the component.
_mk_pf_deb822_has() {
  awk -v want="$2" -v comp="$3" '
    function reset() { types = ""; suites = ""; comps = ""; enabled = "yes"; cur = "" }
    function has(list, word,   n, a, i) {
      n = split(list, a, /[ \t]+/)
      for (i = 1; i <= n; i++) if (a[i] == word) return 1
      return 0
    }
    function flush() {
      if (tolower(enabled) != "no" && has(types, "deb") && has(suites, want) && has(comps, comp)) found = 1
      reset()
    }
    BEGIN { reset() }
    { sub(/\r$/, "") }
    /^#/ { next }
    /^[ \t]*$/ { flush(); next }
    /^[ \t]/ {
      if (cur == "types") types = types " " $0
      else if (cur == "suites") suites = suites " " $0
      else if (cur == "components") comps = comps " " $0
      next
    }
    {
      i = index($0, ":")
      if (i == 0) { cur = ""; next }
      cur = tolower(substr($0, 1, i - 1))
      v = substr($0, i + 1)
      if (cur == "types") types = v
      else if (cur == "suites") suites = v
      else if (cur == "components") comps = v
      else if (cur == "enabled") { gsub(/[ \t]/, "", v); enabled = v }
    }
    END { flush(); if (found) print "yes" }
  ' "$1"
}

# _mk_pf_oneline_has <file> <suite> <component>: the same for a one-line
# sources.list file.
_mk_pf_oneline_has() {
  awk -v want="$2" -v comp="$3" '
    { sub(/\r$/, ""); sub(/#.*/, "") }
    $1 != "deb" { next }
    {
      i = 2
      if (substr($i, 1, 1) == "[") {
        while (i <= NF && substr($i, length($i), 1) != "]") i++
        i++
      }
      if ($(i + 1) != want) next
      for (j = i + 2; j <= NF; j++) if ($j == comp) found = 1
    }
    END { if (found) print "yes" }
  ' "$1"
}

# mk_preflight_component_enabled <suite> <component>: 0 if the apt sources
# enable the component for the suite.
mk_preflight_component_enabled() {
  local suite=$1 comp=$2 etc f
  etc=$(mk_path /etc/apt)
  for f in "$etc/sources.list" "$etc"/sources.list.d/*.list "$etc"/sources.list.d/*.sources; do
    if [[ ! -f $f ]]; then
      continue
    fi
    if [[ $f == *.sources ]]; then
      if [[ $(_mk_pf_deb822_has "$f" "$suite" "$comp") == yes ]]; then
        return 0
      fi
    elif [[ $(_mk_pf_oneline_has "$f" "$suite" "$comp") == yes ]]; then
      return 0
    fi
  done
  return 1
}

# mk_preflight_universe: universe enabled for the release (1.6).
mk_preflight_universe() {
  if mk_preflight_component_enabled "$MK_PF_CODENAME" universe; then
    _mk_pf_ok "apt component universe: enabled"
    return 0
  fi
  _mk_pf_fail "$MK_EXIT_UNSUPPORTED" "the universe component is not enabled for $MK_PF_CODENAME; enable it with: sudo add-apt-repository universe"
}

# mk_preflight_dpkg: dpkg --audit clean and apt-get check passes (2.4).
mk_preflight_dpkg() {
  local out rc=0 ok=1
  out=$(dpkg --audit 2>&1) || rc=$?
  if ((rc != 0)) || [[ -n $out ]]; then
    _mk_pf_fail "$MK_EXIT_PREFLIGHT" "dpkg --audit reports packages in a broken state; repair them first, for example with: sudo dpkg --configure -a"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    ok=0
  fi
  rc=0
  out=$(LC_ALL=C apt-get -q -o Debug::NoLocking=true check 2>&1) || rc=$?
  if ((rc != 0)); then
    _mk_pf_fail "$MK_EXIT_PREFLIGHT" "apt-get check reports broken dependencies; repair them first, for example with: sudo apt-get --fix-broken install"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    ok=0
  fi
  if ((ok)); then
    _mk_pf_ok "package state: dpkg --audit and apt-get check are clean"
  fi
}

# mk_preflight_space: at least 4 GiB free on / (2.5).
mk_preflight_space() {
  local avail
  avail=$(df -P -k -- "$(mk_path /)" 2>/dev/null | awk 'NR == 2 { print $4 }') || avail=""
  if [[ ! $avail =~ ^[0-9]+$ ]]; then
    _mk_pf_fail "$MK_EXIT_PREFLIGHT" "cannot read the free space of the root filesystem"
    return 0
  fi
  if ((avail < MK_MIN_FREE_KIB)); then
    _mk_pf_fail "$MK_EXIT_PREFLIGHT" "the root filesystem has $((avail / 1024)) MiB free; Motanka needs at least 4 GiB ($((MK_MIN_FREE_KIB / 1024)) MiB)"
    return 0
  fi
  _mk_pf_ok "free space on /: $((avail / 1024)) MiB (at least $((MK_MIN_FREE_KIB / 1024)) MiB needed)"
}

# mk_preflight_detect_dm: prints the display manager's name (gdm3, sddm,
# lightdm, or another unit name), or nothing when there is none. Read from
# the display-manager.service alias, else /etc/X11/default-display-manager.
mk_preflight_detect_dm() {
  local link f name="" line=""
  link=$(mk_path /etc/systemd/system/display-manager.service)
  if [[ -L $link ]]; then
    name=$(readlink -- "$link") || name=""
    name=${name##*/}
    name=${name%.service}
  fi
  if [[ -z $name || $name == null ]]; then
    name=""
    f=$(mk_path /etc/X11/default-display-manager)
    if [[ -r $f ]]; then
      IFS= read -r line <"$f" || true
      name=${line##*/}
    fi
  fi
  case $name in
    gdm | gdm3) name=gdm3 ;;
  esac
  printf '%s\n' "$name"
}

# _mk_pf_ini_get <section> <key> <file>...: the last value of key=value in
# [section] across the files that exist; nothing if unset.
_mk_pf_ini_get() {
  local sec=$1 key=$2 f
  local -a files=()
  shift 2
  for f in "$@"; do
    if [[ -f $f && -r $f ]]; then
      files+=("$f")
    fi
  done
  if ((${#files[@]} == 0)); then
    return 0
  fi
  awk -v sec="$sec" -v key="$key" '
    FNR == 1 { insec = 0 }
    { sub(/\r$/, "") }
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[/ {
      s = $0; sub(/^[ \t]*\[/, "", s); sub(/\][ \t]*$/, "", s)
      insec = (s == sec)
      next
    }
    insec {
      i = index($0, "=")
      if (i == 0) next
      k = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k != key) next
      v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
      val = v; found = 1
    }
    END { if (found) print val }
  ' "${files[@]}"
}

# _mk_pf_falsy <value>: 0 for false, 0, no and off (any case).
_mk_pf_falsy() {
  case ${1,,} in
    false | 0 | no | off) return 0 ;;
  esac
  return 1
}

# _mk_pf_list_has <list> <separator> <folder>: 0 if the list names the
# folder, with or without a trailing slash.
_mk_pf_list_has() {
  local item
  local -a items
  IFS=$2 read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    if [[ ${item%/} == "${3%/}" ]]; then
      return 0
    fi
  done
  return 1
}

# _mk_pf_wayland_problem <dm>: prints why the display manager cannot start
# Wayland sessions and returns 0, or returns 1 when it can.
_mk_pf_wayland_problem() {
  local dm=$1 f v
  local -a files
  case $dm in
    gdm3)
      for f in /etc/gdm3/custom.conf /etc/gdm3/daemon.conf /etc/gdm/custom.conf; do
        v=$(_mk_pf_ini_get daemon WaylandEnable "$(mk_path "$f")")
        if [[ -n $v ]] && _mk_pf_falsy "$v"; then
          printf 'WaylandEnable=%s in %s\n' "$v" "$f"
          return 0
        fi
      done
      ;;
    sddm)
      files=("$(mk_path /usr/lib/sddm/sddm.conf.d)"/*.conf "$(mk_path /etc/sddm.conf.d)"/*.conf "$(mk_path /etc/sddm.conf)")
      v=$(_mk_pf_ini_get Wayland SessionDir "${files[@]}")
      if [[ -n $v ]] && ! _mk_pf_list_has "$v" , /usr/share/wayland-sessions; then
        printf '[Wayland] SessionDir=%s does not include /usr/share/wayland-sessions\n' "$v"
        return 0
      fi
      ;;
    lightdm)
      files=("$(mk_path /usr/share/lightdm/lightdm.conf.d)"/*.conf "$(mk_path /etc/lightdm/lightdm.conf.d)"/*.conf "$(mk_path /etc/lightdm/lightdm.conf)")
      v=$(_mk_pf_ini_get LightDM sessions-directory "${files[@]}")
      if [[ -n $v ]] && ! _mk_pf_list_has "$v" : /usr/share/wayland-sessions; then
        printf '[LightDM] sessions-directory=%s does not include /usr/share/wayland-sessions\n' "$v"
        return 0
      fi
      ;;
  esac
  return 1
}

# mk_preflight_display_manager: GDM, SDDM or LightDM with Wayland sessions
# enabled (2.7). No display manager at all is a warning only: the session
# entry is still installed, and a display manager can be added later.
mk_preflight_display_manager() {
  local dm reason
  dm=$(mk_preflight_detect_dm)
  MK_PF_DM=$dm
  case $dm in
    "")
      mk_warn "preflight: no display manager found; the Motanka session is chosen at the login screen of GDM, SDDM or LightDM, so install one of them to log in to Motanka"
      ;;
    gdm3 | sddm | lightdm)
      if reason=$(_mk_pf_wayland_problem "$dm"); then
        _mk_pf_fail "$MK_EXIT_PREFLIGHT" "display manager $dm cannot start Wayland sessions: $reason"
      else
        _mk_pf_ok "display manager: $dm (Wayland sessions enabled)"
      fi
      ;;
    *)
      _mk_pf_fail "$MK_EXIT_PREFLIGHT" "display manager $dm is not supported; the Motanka session needs GDM, SDDM or LightDM"
      ;;
  esac
}

# mk_preflight_nvidia_version: prints the loaded NVIDIA driver version
# (/proc/driver/nvidia/version, else /sys/module/nvidia/version) or
# nothing.
mk_preflight_nvidia_version() {
  local f line tok
  local -a toks
  f=$(mk_path /proc/driver/nvidia/version)
  if [[ -r $f ]]; then
    IFS= read -r line <"$f" || true
    read -r -a toks <<<"$line"
    for tok in "${toks[@]}"; do
      if [[ $tok =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s\n' "$tok"
        return 0
      fi
    done
  fi
  f=$(mk_path /sys/module/nvidia/version)
  if [[ -r $f ]]; then
    IFS= read -r line <"$f" || true
    if [[ $line =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]]; then
      printf '%s\n' "$line"
    fi
  fi
}

# mk_preflight_nvidia_gpu_driver: prints the kernel driver bound to the
# first NVIDIA display device ("none" when unbound), or nothing when there
# is no NVIDIA display device.
mk_preflight_nvidia_gpu_driver() {
  local dev vendor class drv
  for dev in "$(mk_path /sys/bus/pci/devices)"/*; do
    if [[ ! -r $dev/vendor || ! -r $dev/class ]]; then
      continue
    fi
    vendor=$(<"$dev/vendor")
    class=$(<"$dev/class")
    if [[ $vendor != 0x10de || $class != 0x03* ]]; then
      continue
    fi
    drv=none
    if [[ -L $dev/driver ]]; then
      drv=$(readlink -- "$dev/driver") || drv=none
      drv=${drv##*/}
    fi
    printf '%s\n' "$drv"
    return 0
  done
}

# mk_preflight_gpu: reports the NVIDIA driver and whether the Stack
# supports it (2.8, 8.9). A report, never a failure: the session launcher
# refuses an unsupported driver (8.6).
mk_preflight_gpu() {
  local ver drv major
  ver=$(mk_preflight_nvidia_version)
  if [[ -n $ver ]]; then
    major=${ver%%.*}
    if ((10#$major >= MK_NVIDIA_MIN_MAJOR)); then
      _mk_pf_ok "GPU: NVIDIA driver $ver, supported by the Stack ($MK_NVIDIA_MIN_MAJOR or later)"
    else
      mk_warn "preflight: GPU: NVIDIA driver $ver is not supported by the Stack; the Motanka session needs the NVIDIA driver $MK_NVIDIA_MIN_MAJOR or later"
    fi
    return 0
  fi
  drv=$(mk_preflight_nvidia_gpu_driver)
  if [[ -n $drv ]]; then
    mk_warn "preflight: GPU: NVIDIA GPU with driver $drv, not supported by the Stack; the Motanka session needs the NVIDIA driver $MK_NVIDIA_MIN_MAJOR or later"
    return 0
  fi
  _mk_pf_ok "GPU: no NVIDIA GPU found"
}

# mk_preflight: every read-only check, in order (2.1). Exits with the exit
# code of the first failed check after all of them ran.
mk_preflight() {
  MK_PF_FAIL_CODE=0
  mk_info "preflight (read-only):"
  mk_preflight_release
  mk_preflight_arch
  if [[ -n $MK_PF_CODENAME ]]; then
    mk_preflight_universe
  fi
  mk_preflight_dpkg
  mk_preflight_space
  mk_preflight_display_manager
  mk_preflight_gpu
  if ((MK_PF_FAIL_CODE != 0)); then
    mk_info "$(mk_cmd_name): preflight failed; nothing was changed"
    exit "$MK_PF_FAIL_CODE"
  fi
  mk_log info "preflight passed on $MK_PF_CODENAME (display manager ${MK_PF_DM:-none})"
}

# --- shared steps -------------------------------------------------------

_mk_install_on_exit() {
  local rc=$?
  trap - EXIT
  if ((MK_INSTALL_BEGUN && !MK_INSTALL_ENDED)); then
    MK_INSTALL_ENDED=1
    mk_sysledger_end failed || true
  fi
  mk_aptsim_cleanup
  exit "$rc"
}

_mk_install_require_root() {
  if [[ $(id -u) != 0 ]]; then
    mk_die "$MK_EXIT_AUTH" "motanka install must run as root: sudo motanka install"
  fi
}

# _mk_install_refuse_foreign <parsed-simulation> <what-changed> [what]:
# exits 5 and lists the packages if a Foreign_Package would change (2.6).
# [what] names what is installed (default Motanka).
_mk_install_refuse_foreign() {
  local -a changes
  mapfile -t changes < <(mk_aptsim_foreign_changes "$1")
  if ((${#changes[@]} > 0)); then
    mk_info "The apt transaction would change these packages that Motanka does not own:"
    printf '  %s\n' "${changes[@]}" >&2
    mk_die "$MK_EXIT_FOREIGN" "refused: installing ${3:-Motanka} would change ${#changes[@]} package(s) Motanka does not own; $2"
  fi
}

# _mk_install_apt <apt-get arguments...>: runs apt-get on the Host's
# configuration with its output on stderr. Without a terminal or with
# --yes, debconf does not ask.
_mk_install_apt() {
  local rc=0
  mk_log info "apt-get $*"
  if ((MK_YES)) || [[ ! -t 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@" </dev/null >&2 || rc=$?
  else
    apt-get -o DPkg::Lock::Timeout=300 "$@" >&2 || rc=$?
  fi
  return "$rc"
}

# _mk_install_interrupted_runs: IDs of install runs in the System_Ledger
# with a run-begin and no run-end, apart from the current run.
_mk_install_interrupted_runs() {
  mk_sysledger_read 2>/dev/null | awk -F'\t' -v self="${MK_RUN_ID:-}" '
    $3 == "run-begin" && $4 == "install" && !($2 in begun) { begun[$2] = 1; order[++n] = $2 }
    $3 == "run-end" { ended[$2] = 1 }
    END { for (i = 1; i <= n; i++) if (!(order[i] in ended) && order[i] != self) print order[i] }'
}

# _mk_install_planned_new: packages that a plan line of any install run
# names as a new installation ("Inst <name> (<version> ..."), in order.
_mk_install_planned_new() {
  mk_sysledger_read 2>/dev/null | awk -F'\t' '
    $3 == "run-begin" { kind[$2] = $4 }
    $3 == "plan" && kind[$2] == "install" {
      n = split($4, w, " ")
      if (n >= 3 && w[1] == "Inst" && substr(w[3], 1, 1) == "(") {
        p = w[2]; sub(/:[A-Za-z0-9]+$/, "", p); print p
      }
    }'
}

# _mk_install_deb_current <package> <version>: 0 if the package is
# installed at that version or newer.
_mk_install_deb_current() {
  local have
  have=$(mk_installed_version "$1") || return 1
  dpkg --compare-versions "$have" ge "$2"
}

# _mk_install_nothing_to_do: 0 when Motanka is installed and the run would
# change nothing (3.10).
_mk_install_nothing_to_do() {
  [[ ! -s $MK_APTSIM_DIR/plan.txt ]] || return 1
  if [[ $MK_APPS_ANSWER == yes ]] && ! mk_installed_version "$MK_APPS_PKG" >/dev/null; then
    return 1
  fi
  mk_installed_version motanka >/dev/null || return 1
  _mk_install_deb_current motanka-archive-keyring "$MK_APTSIM_KEYRING_VERSION" || return 1
  _mk_install_deb_current "motanka-source-$MK_SUITE" "$MK_APTSIM_SOURCE_VERSION" || return 1
  [[ -z $(_mk_install_interrupted_runs) ]]
}

# _mk_install_target_version: the motanka version this run installs, for
# the run-begin line.
_mk_install_target_version() {
  local v
  v=$(awk -F'\t' '$1 == "Inst" && $2 == "motanka" { print $4; exit }' "$MK_APTSIM_DIR/plan.tsv")
  if [[ -z $v || $v == - ]]; then
    v=$(mk_installed_version motanka) || v=unknown
  fi
  printf '%s\n' "$v"
}

# --- the Motanka_Apps question (2.9-2.11) -------------------------------

# _mk_install_apps_size: simulates motanka with motanka-apps in the private
# configuration (sim-apps.txt) and sets MK_APPS_N, the packages it newly
# installs that the simulation of step 4 (plan.tsv) does not, and
# MK_APPS_BYTES, their download size from apt-get --print-uris ("'<URI>'
# <file> <size> <hash>" lines; the private cache is empty, so every package
# is listed). A value apt cannot give stays empty; nothing here fails.
_mk_install_apps_size() {
  local d=$MK_APTSIM_DIR rc=0 n
  local -a pkgs=("${MK_INSTALL_PKGS[@]}" "$MK_APPS_PKG")
  MK_APPS_N="" MK_APPS_BYTES="" MK_APPS_SIM=0
  mk_log info "simulating apt-get install ${pkgs[*]} (private configuration) for the size of $MK_APPS_PKG"
  LC_ALL=C apt-get "${MK_APTSIM_OPTS[@]}" -q -s install --no-install-recommends "${pkgs[@]}" \
    >"$d/sim-apps.txt" 2>"$d/sim-apps.txt.err" || rc=$?
  if ((rc != 0)); then
    mk_log warning "apt cannot simulate the installation of $MK_APPS_PKG (apt-get exit $rc); asking without its size"
    return 0
  fi
  MK_APPS_SIM=1
  mk_aptsim_parse "$d/sim-apps.txt" >"$d/sim-apps.tsv"
  awk -F'\t' '
    FILENAME == ARGV[1] { if ($1 == "Inst") base[$2] = 1; next }
    $1 == "Inst" && $3 == "-" && !($2 in base) && !seen[$2]++ { print $2 }
  ' "$d/plan.tsv" "$d/sim-apps.tsv" >"$d/apps-new.txt"
  n=$(wc -l <"$d/apps-new.txt")
  MK_APPS_N=$((n))
  rc=0
  LC_ALL=C apt-get "${MK_APTSIM_OPTS[@]}" -o Debug::NoLocking=true --print-uris -qq install --no-install-recommends "${pkgs[@]}" \
    >"$d/uris-apps.txt" 2>"$d/uris-apps.txt.err" || rc=$?
  if ((rc != 0)); then
    mk_log warning "apt-get --print-uris for $MK_APPS_PKG exited $rc; asking without the download size"
    return 0
  fi
  MK_APPS_BYTES=$(awk '
    FILENAME == ARGV[1] { want[$1] = 1; next }
    {
      p = $2; sub(/_.*/, "", p)
      if ((p in want) && $3 ~ /^[0-9]+$/) s += $3
    }
    END { printf "%.0f\n", s }
  ' "$d/apps-new.txt" "$d/uris-apps.txt")
  if [[ ! $MK_APPS_BYTES =~ ^[0-9]+$ ]]; then
    MK_APPS_BYTES=""
  fi
}

# _mk_install_mb <bytes>: the size in MB (10^6 bytes), as apt prints it.
_mk_install_mb() {
  local b=$1
  if ((b > 0 && b < 500000)); then
    printf 'less than 1 MB\n'
  else
    printf '%d MB\n' $(((b + 500000) / 1000000))
  fi
}

# _mk_install_apps_question: the question, with the size when it is known.
_mk_install_apps_question() {
  local what=$MK_APPS_PKG
  if [[ -n $MK_APPS_N ]]; then
    what+=": $MK_APPS_N more package(s)"
    if [[ -n $MK_APPS_BYTES ]]; then
      what+=", $(_mk_install_mb "$MK_APPS_BYTES") to download"
    else
      what+=", download size unknown"
    fi
  else
    what+=", size unknown"
  fi
  printf 'Also install the applications upstream Omarchy installs by default (%s)?\n' "$what"
}

# _mk_install_apps_decide: the answer to the Motanka_Apps question, in
# MK_APPS_ANSWER and MK_APPS_SOURCE (see step 5 at the top).
_mk_install_apps_decide() {
  local q rc=0
  MK_APPS_ANSWER="" MK_APPS_SOURCE=""
  MK_APPS_INSTALLED=$(mk_installed_version "$MK_APPS_PKG") || MK_APPS_INSTALLED=""
  if [[ -n $MK_APPS_INSTALLED ]]; then
    if [[ $MK_APPS_FLAG == no ]]; then
      mk_info "$MK_APPS_PKG $MK_APPS_INSTALLED is installed and stays installed: --no-apps does not remove it. 'sudo motanka remove' removes Motanka with everything it installed; 'sudo apt purge $MK_APPS_PKG' removes only that metapackage, and the packages it brought stay until 'sudo motanka remove'."
    fi
    return 0
  fi
  if [[ -n $MK_APPS_FLAG ]]; then
    MK_APPS_ANSWER=$MK_APPS_FLAG MK_APPS_SOURCE=flag
    return 0
  fi
  MK_APPS_ANSWER=no MK_APPS_SOURCE=default
  if ((MK_YES)); then
    mk_info "$MK_APPS_PKG: --yes without --apps does not install the applications upstream Omarchy installs by default; add them later with: $MK_APPS_LATER"
    return 0
  fi
  if ! mk_stdin_tty; then
    mk_info "$MK_APPS_PKG: there is no terminal to ask on, so the applications upstream Omarchy installs by default are not installed; add them later with: $MK_APPS_LATER"
    return 0
  fi
  _mk_install_apps_size
  q=$(_mk_install_apps_question)
  MK_APPS_SOURCE=question
  mk_ask_yes_no "$q" || rc=$?
  if ((rc == 0)); then
    MK_APPS_ANSWER=yes
  fi
  mk_log info "$MK_APPS_PKG question answered $MK_APPS_ANSWER"
}

# _mk_install_apps_plan: with yes, motanka-apps joins the package list and
# the Plan becomes the private simulation of motanka with motanka-apps;
# exits 5 when it would change a Foreign_Package.
_mk_install_apps_plan() {
  local d=$MK_APTSIM_DIR
  if [[ $MK_APPS_ANSWER != yes ]]; then
    return 0
  fi
  MK_INSTALL_PKGS+=("$MK_APPS_PKG")
  if ((MK_APPS_SIM)); then
    cp -- "$d/sim-apps.txt" "$d/sim.txt"
  else
    mk_aptsim_simulate "$d/sim.txt" private "${MK_INSTALL_PKGS[@]}"
  fi
  mk_aptsim_plan_lines "$d/sim.txt" >"$d/plan.txt"
  mk_aptsim_parse "$d/sim.txt" >"$d/plan.tsv"
  _mk_install_refuse_foreign "$d/plan.tsv" "nothing was changed; 'sudo motanka install --no-apps' installs Motanka without it" \
    "Motanka with $MK_APPS_PKG"
}

# _mk_install_apps_how: how this run answered, for messages.
_mk_install_apps_how() {
  case $MK_APPS_SOURCE in
    flag)
      if [[ $MK_APPS_ANSWER == yes ]]; then
        printf 'by --apps\n'
      else
        printf 'by --no-apps\n'
      fi
      ;;
    question) printf 'at the question\n' ;;
    *) printf 'by default (--yes without --apps, or no terminal to ask on)\n' ;;
  esac
}

# --- dry run ------------------------------------------------------------

# _mk_install_print_apps: the Motanka_Apps line of the dry run (2.11).
_mk_install_print_apps() {
  if [[ -n $MK_APPS_INSTALLED ]]; then
    printf '%s %s is installed already.\n' "$MK_APPS_PKG" "$MK_APPS_INSTALLED"
  elif [[ $MK_APPS_ANSWER == yes ]]; then
    printf '%s: included, answered yes %s.\n' "$MK_APPS_PKG" "$(_mk_install_apps_how)"
  else
    printf '%s: not included, answered no %s; add it later with: %s\n' \
      "$MK_APPS_PKG" "$(_mk_install_apps_how)" "$MK_APPS_LATER"
  fi
}

# _mk_install_print_home_plan: the home-folder paths per-user setup writes
# at a user's first login (2.2).
_mk_install_print_home_plan() {
  local f glob class
  f=$(mk_path "$MK_HOME_PATHS")
  printf "Home-folder Plan: per-user setup writes these paths at each user's first login\n"
  printf 'to the Motanka session. The Installer itself writes nothing into any home folder.\n'
  if [[ ! -r $f ]]; then
    printf '  computed at first login (%s is not installed yet)\n' "$MK_HOME_PATHS"
    return 0
  fi
  while IFS=$'\t' read -r glob class _; do
    if [[ -z $glob || $glob == \#* ]]; then
      continue
    fi
    case $class in
      namespaced | session | app)
        printf '  %-10s  %s\n' "$class" "$glob"
        ;;
      shared)
        printf '  %-10s  %s (left unchanged; a marked block only with shell integration)\n' "$class" "$glob"
        ;;
    esac
  done <"$f"
}

# _mk_install_print_plan: the dry-run report on stdout.
_mk_install_print_plan() {
  local d=$MK_APTSIM_DIR n
  n=$(awk -F'\t' '$1 == "Inst"' "$d/plan.tsv" | wc -l)
  printf 'Simulated apt transaction for the suite %s\n' "$MK_SUITE"
  printf '(apt-get install --no-remove --no-install-recommends %s):\n' "${MK_INSTALL_PKGS[*]}"
  if [[ -s $d/plan.txt ]]; then
    sed 's/^/  /' "$d/plan.txt"
  else
    printf '  nothing to install\n'
  fi
  printf '%d package(s) to install; no package Motanka does not own changes or is removed.\n' "$n"
  _mk_install_print_apps
  printf '\n'
  _mk_install_print_home_plan
  printf '\nDry run: nothing was changed.\n'
}

# --- real run -----------------------------------------------------------

# _mk_install_ledger_new_actions <simulation> <parsed>: appends plan lines
# for actions the first simulation did not show.
_mk_install_ledger_new_actions() {
  local i extra=0 op pkg new
  local -a raws rows
  local -A seen=()
  while IFS=$'\t' read -r op pkg _ new; do
    seen["$op $pkg $new"]=1
  done <"$MK_APTSIM_DIR/plan.tsv"
  mapfile -t raws < <(mk_aptsim_plan_lines "$1")
  mapfile -t rows <"$2"
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r op pkg _ new <<<"${rows[i]}"
    if [[ -n ${seen["$op $pkg $new"]:-} ]]; then
      continue
    fi
    mk_sysledger_plan "${raws[i]}" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
    extra=$((extra + 1))
  done
  if ((extra > 0)); then
    mk_warn "the transaction changed after apt-get update: $extra action(s) the first simulation did not show; they are recorded in the System_Ledger"
  fi
}

# _mk_install_record_packages: pkg-installed lines (3.7).
_mk_install_record_packages() {
  local pkg ver mode
  local -A recorded=() manual=() handled=()
  while IFS= read -r pkg; do
    if [[ -n $pkg ]]; then
      recorded[$pkg]=1
    fi
  done < <(mk_sysledger_packages 2>/dev/null)
  while IFS= read -r pkg; do
    if [[ -n $pkg ]]; then
      manual[${pkg%%:*}]=1
    fi
  done < <(apt-mark showmanual 2>/dev/null || true)
  while IFS= read -r pkg; do
    if [[ -z $pkg || -n ${handled[$pkg]:-} || -n ${recorded[$pkg]:-} ]] || mk_is_motanka_package "$pkg"; then
      continue
    fi
    handled[$pkg]=1
    if ! ver=$(mk_installed_version "$pkg"); then
      continue
    fi
    mode=auto
    if [[ -n ${manual[$pkg]:-} ]]; then
      mode=manual
    fi
    mk_sysledger_pkg_installed "$pkg" "$ver" "$mode" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  done < <(_mk_install_planned_new)
}

# _mk_install_close_interrupted: run-end failed for earlier install runs
# that never ended; this run completed what they planned.
_mk_install_close_interrupted() {
  local id
  local -a ids
  mapfile -t ids < <(_mk_install_interrupted_runs)
  for id in "${ids[@]}"; do
    if [[ -z $id ]]; then
      continue
    fi
    MK_RUN_ID=$id mk_sysledger_end failed || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
    mk_info "closed the interrupted install run $id in the System_Ledger"
  done
}

# _mk_install_local_debs: installs the verified keyring and source .debs,
# except those already installed at that version or newer.
_mk_install_local_debs() {
  local -a debs=()
  if ! _mk_install_deb_current motanka-archive-keyring "$MK_APTSIM_KEYRING_VERSION"; then
    debs+=("$MK_APTSIM_KEYRING_DEB")
  fi
  if ! _mk_install_deb_current "motanka-source-$MK_SUITE" "$MK_APTSIM_SOURCE_VERSION"; then
    debs+=("$MK_APTSIM_SOURCE_DEB")
  fi
  if ((${#debs[@]} == 0)); then
    mk_info "the keyring and source packages are already installed"
    return 0
  fi
  mk_info "installing the verified keyring and source packages"
  _mk_install_apt install -y --no-remove --no-install-recommends "${debs[@]}" ||
    mk_die "$MK_EXIT_ERROR" "apt-get could not install the keyring and source packages; 'sudo motanka install' resumes from the System_Ledger"
}

_mk_install_run() {
  local d=$MK_APTSIM_DIR version raw n m
  if _mk_install_nothing_to_do; then
    mk_info "Motanka $(mk_installed_version motanka) is already installed; nothing to change"
    mk_log info "already installed; nothing changed"
    return 0
  fi
  n=$(awk -F'\t' '$1 == "Inst"' "$d/plan.tsv" | wc -l)
  m=$(awk -F'\t' '$1 == "Inst" && ($2 == "motanka" || $2 ~ /^motanka-/)' "$d/plan.tsv" | wc -l)
  mk_info "The Installer will install $n package(s): $m Motanka package(s) and $((n - m)) from Ubuntu."
  if [[ $MK_APPS_ANSWER == yes ]]; then
    mk_info "They include $MK_APPS_PKG and the applications it depends on."
  fi
  mk_info "No package Motanka does not own changes, and no home folder is written. See the list with --dry-run."
  if ! mk_confirm "Install Motanka now?"; then
    mk_die "$MK_EXIT_ERROR" "cancelled; nothing was changed"
  fi

  version=$(_mk_install_target_version)
  mk_sysledger_begin install "$version" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger; nothing was changed"
  MK_INSTALL_BEGUN=1
  if [[ -n $MK_APPS_ANSWER ]]; then
    mk_sysledger_apps_answer "$MK_APPS_ANSWER" "$MK_APPS_SOURCE" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  fi
  while IFS= read -r raw; do
    mk_sysledger_plan "$raw" || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  done <"$d/plan.txt"

  mk_accounts_begin || mk_die "$MK_EXIT_ERROR" "cannot save the account list; nothing was changed"
  _mk_install_local_debs
  mk_info "apt-get update"
  _mk_install_apt -q update ||
    mk_die "$MK_EXIT_ERROR" "apt-get update failed; run 'sudo motanka install' again when the network works"

  mk_aptsim_simulate "$d/sim-host.txt" system "${MK_INSTALL_PKGS[@]}"
  mk_aptsim_parse "$d/sim-host.txt" >"$d/sim-host.tsv"
  _mk_install_refuse_foreign "$d/sim-host.tsv" "the keyring and source packages are installed; 'sudo motanka remove' removes them"
  _mk_install_ledger_new_actions "$d/sim-host.txt" "$d/sim-host.tsv"

  if [[ $MK_APPS_ANSWER == yes ]]; then
    mk_info "installing motanka and $MK_APPS_PKG"
  else
    mk_info "installing motanka"
  fi
  _mk_install_apt install -y --no-remove --no-install-recommends "${MK_INSTALL_PKGS[@]}" ||
    mk_die "$MK_EXIT_ERROR" "apt-get could not install ${MK_INSTALL_PKGS[*]}; the System_Ledger records the plan, and 'sudo motanka install' resumes"

  mk_accounts_end || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  _mk_install_record_packages
  _mk_install_close_interrupted
  MK_INSTALL_ENDED=1
  mk_sysledger_end ok || mk_die "$MK_EXIT_ERROR" "cannot write the System_Ledger"
  mk_info "Motanka $version is installed. Log out and choose \"Motanka\" at the login screen."
}

# --- entry point --------------------------------------------------------

mk_cmd_install() {
  local d apps=0 no_apps=0
  MK_CHANNEL=stable
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_install_usage
        exit "$MK_EXIT_OK"
        ;;
      --apps)
        apps=1
        ;;
      --no-apps)
        no_apps=1
        ;;
      --channel)
        if (($# < 2)); then
          mk_usage_error "--channel needs a value"
        fi
        MK_CHANNEL=$2
        shift
        ;;
      --channel=*)
        MK_CHANNEL=${1#*=}
        ;;
      --)
        shift
        break
        ;;
      -*)
        mk_parse_common_opt "$1" || mk_usage_error "unknown option '$1'"
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
  case $MK_CHANNEL in
    stable | edge) ;;
    *) mk_usage_error "--channel must be stable or edge, not '$MK_CHANNEL'" ;;
  esac
  if ((apps && no_apps)); then
    mk_usage_error "--apps and --no-apps cannot be given together"
  fi
  MK_APPS_FLAG=""
  if ((apps)); then
    MK_APPS_FLAG=yes
  elif ((no_apps)); then
    MK_APPS_FLAG=no
  fi
  mk_aptsim_uri

  _mk_install_require_root
  mk_lock_system
  mk_log info "install started (channel $MK_CHANNEL, dry run $MK_DRY_RUN, apps ${MK_APPS_FLAG:-ask}, repository $MK_APTSIM_URI)"
  mk_preflight
  MK_SUITE=$MK_PF_CODENAME
  if [[ $MK_CHANNEL == edge ]]; then
    MK_SUITE=$MK_SUITE-edge
  fi
  MK_INSTALL_PKGS=(motanka "motanka-source-$MK_SUITE")

  trap _mk_install_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mk_aptsim_begin
  d=$MK_APTSIM_DIR
  mk_aptsim_fetch_verified "$MK_SUITE"
  mk_aptsim_prepare "$MK_SUITE"
  mk_aptsim_update "$MK_SUITE"
  mk_aptsim_simulate "$d/sim.txt" private "${MK_INSTALL_PKGS[@]}"
  mk_aptsim_plan_lines "$d/sim.txt" >"$d/plan.txt"
  mk_aptsim_parse "$d/sim.txt" >"$d/plan.tsv"
  _mk_install_refuse_foreign "$d/plan.tsv" "nothing was changed"
  _mk_install_apps_decide
  _mk_install_apps_plan

  if ((MK_DRY_RUN)); then
    _mk_install_print_plan
    mk_log info "dry run finished; nothing changed"
    exit "$MK_EXIT_OK"
  fi
  _mk_install_run
  exit "$MK_EXIT_OK"
}
