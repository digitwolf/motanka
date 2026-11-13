# shellcheck shell=bash disable=SC2034,SC2329
# (Library file: its variables and functions are used by the scripts that
# source it.)
#
# Shared code for the Motanka VM test harness (test/vm/*, test/run-all).
#
# Every host-side script that sources this file:
# - refuses to run as root and never calls sudo;
# - writes only inside the repository and ~/.cache/motanka-vm/;
# - needs /dev/kvm to be readable and writable by the current user
#   before it starts a VM.
#
# State under ~/.cache/motanka-vm/:
#   base/                verified cloud images and variant base images
#   vms/<name>/          overlay.qcow2, pid, ssh.port, seed/, serial.log,
#                        qemu.log, http.log, known_hosts, release, variant
#   ssh/                 ed25519 key, generated on first use
#   fp/<name>/<label>/   Fingerprints
#   results/<run-id>/    logs for the implementer
#
# Environment:
#   MOTANKA_VM_CPUS      vCPUs per VM (default 4)
#   MOTANKA_VM_RAM       memory per VM, QEMU syntax (default 6G)
#   MOTANKA_VM_GPU       "gl" for a virgl GPU backed by the host render node
#                        (needed to run Hyprland; spike S3), otherwise unset
#   MOTANKA_VM_GPU_ARGS  QEMU display and GPU arguments, split on spaces
#                        (overrides MOTANKA_VM_GPU)
#                        (default "-vga none -device virtio-vga -display none";
#                        to be revisited after spike S3)
#   MOTANKA_VM_RESULTS   if set, serial and QEMU logs of every VM that is
#                        torn down are copied there; must be a folder under
#                        ~/.cache/motanka-vm/results/
#   MOTANKA_VM_DISK      virtual size of a VM's overlay disk (default 40G;
#                        the overlay only grows as the guest writes)
#   MOTANKA_BUILD_VM_CPUS  vCPUs of a build VM (default: host CPUs, at most 10)
#   MOTANKA_BUILD_VM_RAM   memory of a build VM (default 10G)
#
# Besides the Ubuntu releases, test/vm/image and test/vm/up know one
# reference target for the parity probe (task 24.3): release "arch" with the
# single variant "omarchy", an Arch Linux cloud image with Upstream installed
# at the stable pin. VM names are then arch-omarchy-<6 hex digits>.
# test/run-all never boots it unless MOTANKA_VM_PARITY=1.

MV_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MV_REPO=$(cd "$MV_LIB_DIR/../.." && pwd)

MV_STATE="$HOME/.cache/motanka-vm"
MV_KEYS="$MV_STATE/keys"
MV_DEBS="$MV_STATE/debs"
MV_BASE="$MV_STATE/base"
MV_VMS="$MV_STATE/vms"
MV_SSH_DIR="$MV_STATE/ssh"
MV_KEY="$MV_SSH_DIR/id_ed25519"
MV_FP="$MV_STATE/fp"
MV_RESULTS="$MV_STATE/results"

MV_RELEASES=(resolute noble)
MV_VARIANTS=(fresh gnome-snaps kde multiuser)
MV_NAME_RE='^((resolute|noble)-(fresh|gnome-snaps|kde|multiuser)|arch-omarchy)-[0-9a-f]{6}$'
# The parity reference target (see the header).
MV_ARCH_RELEASE=arch
MV_ARCH_VARIANT=omarchy
MV_ARCH_IMAGES_URL=https://geo.mirror.pkgbuild.com/images
MV_GUEST_USER=tester
MV_GUEST_REPO=/home/tester/motanka
MV_DISK_SIZE=${MOTANKA_VM_DISK:-40G}
MV_BOOT_TIMEOUT=600
MV_DOWN_TIMEOUT=60
MV_DEFAULT_GPU_ARGS="-vga none -device virtio-vga -display none"
MV_GL_RENDER_NODE=${MOTANKA_VM_RENDER_NODE:-/dev/dri/renderD128}
MV_GL_GPU_ARGS="-vga none -device virtio-vga-gl -display egl-headless,rendernode=$MV_GL_RENDER_NODE"
MV_CLOUDIMG_URL=https://cloud-images.ubuntu.com/releases
MV_CLOUDIMG_KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg

MV_PROG=${MV_PROG:-vm}
MV_USAGE=${MV_USAGE:-}
MV_CLEANUP_VMS=()
MV_CLEANUP_PATHS=()
MV_BOOTED=""
MV_HTTP_PORT=""
MV_SSH_OPTS=()
MV_SSH_DEST=""
MV_SSH=()

# --- messages ---------------------------------------------------------------

mv_log() {
  printf '%s: %s\n' "$MV_PROG" "$*" >&2
}

mv_die() {
  mv_log "error: $*"
  exit 1
}

# mv_usage [message]: print the message and the script's usage, exit 2.
mv_usage() {
  if (($# > 0)); then
    mv_log "$1"
  fi
  printf 'usage: %s\n' "$MV_USAGE" >&2
  exit 2
}

# --- setup and cleanup ------------------------------------------------------

mv_init() {
  MV_PROG=$(basename "$0")
  umask 077
  if [[ $(id -u) -eq 0 ]]; then
    mv_die "refusing to run as root; run the test harness as your normal user"
  fi
  mv_check_results_env
  mkdir -p "$MV_BASE" "$MV_VMS" "$MV_FP" "$MV_RESULTS"
  trap mv_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Destroys every VM and removes every temporary path still registered.
mv_on_exit() {
  local rc=$? item
  trap - EXIT
  for item in "${MV_CLEANUP_VMS[@]}"; do
    mv_log "cleaning up VM $item"
    mv_destroy "$item" || true
  done
  for item in "${MV_CLEANUP_PATHS[@]}"; do
    if [[ $item == "$MV_STATE"/* ]]; then
      rm -rf -- "$item" || true
    fi
  done
  exit "$rc"
}

mv_unregister() {
  local keep=() n
  for n in "${MV_CLEANUP_VMS[@]}"; do
    if [[ $n != "$1" ]]; then
      keep+=("$n")
    fi
  done
  MV_CLEANUP_VMS=("${keep[@]}")
}

mv_check_results_env() {
  local r=${MOTANKA_VM_RESULTS:-}
  if [[ -z $r ]]; then
    return 0
  fi
  if [[ $r != "$MV_RESULTS"/* || $r == *..* ]]; then
    mv_die "MOTANKA_VM_RESULTS must be a folder under $MV_RESULTS/, got '$r'"
  fi
}

# --- checks -----------------------------------------------------------------

mv_check_kvm() {
  if [[ ! -e /dev/kvm ]]; then
    mv_die "/dev/kvm does not exist; enable hardware virtualisation (KVM) on this host"
  fi
  if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    mv_die "/dev/kvm is not readable and writable by user $(id -un); the user must be in the kvm group (add it, then log in again)"
  fi
}

mv_need() {
  local c missing=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if ((${#missing[@]} > 0)); then
    mv_die "missing host tools: ${missing[*]}"
  fi
}

mv_release_version() {
  case $1 in
    resolute) printf '26.04\n' ;;
    noble) printf '24.04\n' ;;
    *) return 1 ;;
  esac
}

mv_check_release() {
  if ! mv_release_version "$1" >/dev/null; then
    mv_usage "unknown release '$1' (expected one of: ${MV_RELEASES[*]})"
  fi
}

mv_check_variant() {
  local v
  for v in "${MV_VARIANTS[@]}"; do
    if [[ $1 == "$v" ]]; then
      return 0
    fi
  done
  mv_usage "unknown variant '$1' (expected one of: ${MV_VARIANTS[*]})"
}

# mv_check_image_target <release> <variant>: an Ubuntu release with one of
# its variants, or the parity reference target "arch omarchy". Used by
# test/vm/image and test/vm/up only; everything else stays Ubuntu-only.
mv_check_image_target() {
  if [[ $1 == "$MV_ARCH_RELEASE" ]]; then
    if [[ $2 != "$MV_ARCH_VARIANT" ]]; then
      mv_usage "unknown variant '$2' for release $MV_ARCH_RELEASE (expected: $MV_ARCH_VARIANT)"
    fi
    return 0
  fi
  mv_check_release "$1"
  mv_check_variant "$2"
}

mv_valid_name() {
  [[ $1 =~ $MV_NAME_RE ]]
}

# mv_require_vm <name>: the name is valid and its state folder exists.
mv_require_vm() {
  if ! mv_valid_name "$1"; then
    mv_usage "invalid VM name '$1' (expected <release>-<variant>-<6 hex digits>)"
  fi
  if [[ ! -d $MV_VMS/$1 ]]; then
    mv_die "no such VM: $1"
  fi
}

# mv_require_running <name>
mv_require_running() {
  mv_require_vm "$1"
  if ! mv_qemu_pid "$1" >/dev/null; then
    mv_die "VM $1 is not running"
  fi
}

# --- small helpers ----------------------------------------------------------

mv_hex6() {
  python3 -c 'import secrets; print(secrets.token_hex(3))'
}

# Prints a TCP port on 127.0.0.1 that is free at the time of the call.
mv_free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# mv_pid_matches <pid> <text>: the process is alive and its command line
# contains <text>. Guards against killing a reused pid.
mv_pid_matches() {
  local pid=$1 needle=$2 cmd
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  [[ -r /proc/$pid/cmdline ]] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  [[ -n $cmd && $cmd == *"$needle"* ]]
}

# Prints the QEMU pid of a running VM, or returns 1.
mv_qemu_pid() {
  local dir=$MV_VMS/$1 pid
  [[ -r $dir/pid ]] || return 1
  pid=$(<"$dir/pid") || return 1
  pid=${pid//[^0-9]/}
  mv_pid_matches "$pid" "$dir/overlay.qcow2" || return 1
  printf '%s\n' "$pid"
}

# mv_wait_exit <name> <seconds>: returns 1 if QEMU still runs afterwards.
mv_wait_exit() {
  local deadline=$((SECONDS + $2))
  while mv_qemu_pid "$1" >/dev/null; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 1
  done
}

# --- SSH --------------------------------------------------------------------

# Generates the harness key on first use. Two harness processes may race
# here, so the key is created in a temporary folder that is then renamed.
mv_ensure_key() {
  local tmp
  if [[ -f $MV_KEY && -f $MV_KEY.pub ]]; then
    return 0
  fi
  mv_need ssh-keygen
  tmp=$(mktemp -d "$MV_STATE/.ssh.XXXXXX")
  ssh-keygen -q -t ed25519 -N '' -C motanka-vm -f "$tmp/id_ed25519" </dev/null
  if ! mv -T "$tmp" "$MV_SSH_DIR" 2>/dev/null; then
    rm -rf -- "$tmp"
  fi
  if [[ ! -f $MV_KEY || ! -f $MV_KEY.pub ]]; then
    mv_die "could not create the SSH key in $MV_SSH_DIR"
  fi
  mv_log "generated SSH key $MV_KEY"
}

# mv_ssh_args <name>: fills MV_SSH_OPTS, MV_SSH_DEST and MV_SSH (the full
# ssh command line without the remote command).
mv_ssh_args() {
  local dir=$MV_VMS/$1 port
  if [[ ! -r $dir/ssh.port ]]; then
    mv_die "VM $1 has no SSH port recorded"
  fi
  port=$(<"$dir/ssh.port")
  if [[ ! $port =~ ^[0-9]+$ ]]; then
    mv_die "VM $1 has an invalid SSH port '$port'"
  fi
  MV_SSH_OPTS=(
    -F /dev/null
    -i "$MV_KEY"
    -p "$port"
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=8
    -o ForwardAgent=no
    -o ForwardX11=no
  )
  MV_SSH_DEST="$MV_GUEST_USER@127.0.0.1"
  MV_SSH=(ssh "${MV_SSH_OPTS[@]}" "$MV_SSH_DEST")
}

# --- cloud-init seed --------------------------------------------------------

mv_write_seed() {
  local name=$1 dir=$MV_VMS/$1 pub
  pub=$(<"$MV_KEY.pub")
  cat >"$dir/seed/meta-data" <<EOF
instance-id: motanka-$name
local-hostname: $name
EOF
  cat >"$dir/seed/user-data" <<EOF
#cloud-config
users:
  - name: $MV_GUEST_USER
    gecos: Motanka test user
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "$pub"
ssh_pwauth: false
disable_root: true
package_update: false
package_upgrade: false
package_reboot_if_required: false
EOF
  # The Arch reference VM has no apt and no needrestart: an empty vendor-data.
  if [[ $(cat "$dir/release" 2>/dev/null) == "$MV_ARCH_RELEASE" ]]; then
    printf '#cloud-config\n{}\n' >"$dir/seed/vendor-data"
    return 0
  fi
  # Harness-wide defaults: no background apt runs, so two Fingerprints of
  # the same VM differ only by what the test did. The file name avoids
  # "motanka" so tests looking for Motanka leftovers do not match it.
  cat >"$dir/seed/vendor-data" <<'EOF'
#cloud-config
write_files:
  - path: /etc/apt/apt.conf.d/99harness-no-periodic
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "0";
      APT::Periodic::Unattended-Upgrade "0";
  # needrestart would restart ssh.service during an apt run over SSH and
  # drop the session (seen on 24.04): list only, never restart.
  - path: /etc/needrestart/conf.d/99harness-list-only.conf
    permissions: "0644"
    content: |
      $nrconf{restart} = 'l';
EOF
}

# mv_start_http <vm-dir>: serves <vm-dir>/seed on 127.0.0.1 and sets
# MV_HTTP_PORT. The server picks its own port, so there is no race.
mv_start_http() {
  local dir=$1 pid port="" i
  python3 -u -m http.server --bind 127.0.0.1 --directory "$dir/seed" 0 \
    </dev/null >"$dir/http.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$dir/http.pid"
  for ((i = 0; i < 50; i++)); do
    port=$(sed -n 's/.* port \([0-9][0-9]*\).*/\1/p' "$dir/http.log" | head -n 1)
    if [[ -n $port ]] || ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if [[ -z $port ]]; then
    cat "$dir/http.log" >&2 || true
    mv_die "the cloud-init seed HTTP server did not start"
  fi
  MV_HTTP_PORT=$port
}

mv_stop_http() {
  local dir=$1 pid
  if [[ ! -f $dir/http.pid ]]; then
    return 0
  fi
  pid=$(<"$dir/http.pid")
  if mv_pid_matches "$pid" "$dir/seed"; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f -- "$dir/http.pid"
}

# --- QEMU -------------------------------------------------------------------

# mv_start_qemu <name> <http-port>: starts QEMU in its own session, records
# the pid (QEMU writes it) and the SSH port. Retries with a new port if the
# chosen one was taken in the meantime.
mv_start_qemu() {
  local name=$1 http_port=$2 dir=$MV_VMS/$1
  local cpus=${MOTANKA_VM_CPUS:-4} ram=${MOTANKA_VM_RAM:-6G}
  local attempt port launcher i started
  local -a gpu args
  if [[ ! $cpus =~ ^[1-9][0-9]*$ ]]; then
    mv_die "MOTANKA_VM_CPUS must be a positive integer, got '$cpus'"
  fi
  if [[ ! $ram =~ ^[1-9][0-9]*[MG]?$ ]]; then
    mv_die "MOTANKA_VM_RAM must look like 6G or 6144M, got '$ram'"
  fi
  local gpu_default=$MV_DEFAULT_GPU_ARGS
  if [[ ${MOTANKA_VM_GPU:-} == gl ]]; then
    if [[ ! -r $MV_GL_RENDER_NODE || ! -w $MV_GL_RENDER_NODE ]]; then
      mv_die "MOTANKA_VM_GPU=gl needs read and write access to $MV_GL_RENDER_NODE (granted to the user logged in at the local seat)"
    fi
    gpu_default=$MV_GL_GPU_ARGS
  fi
  read -r -a gpu <<<"${MOTANKA_VM_GPU_ARGS-$gpu_default}"

  for attempt in 1 2 3; do
    port=$(mv_free_port)
    rm -f -- "$dir/pid"
    # shellcheck disable=SC2054 # commas belong to QEMU option values
    args=(
      -name "$name"
      -machine q35
      -enable-kvm
      -cpu host
      -smp "$cpus"
      -m "$ram"
      -nographic
      -serial "file:$dir/serial.log"
      -monitor none
      -parallel none
      # Overlays are thrown away, so guest flushes can be skipped.
      -drive "file=$dir/overlay.qcow2,if=virtio,format=qcow2,cache=unsafe,discard=unmap"
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22"
      -device virtio-net-pci,netdev=net0
      -device virtio-rng-pci
      # NoCloud over HTTP. i= lets cloud-init trust its cache on reboot,
      # when the seed server is gone.
      -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$http_port/;i=motanka-$name"
      -pidfile "$dir/pid"
      "${gpu[@]}"
    )
    setsid qemu-system-x86_64 "${args[@]}" </dev/null >"$dir/qemu.log" 2>&1 &
    launcher=$!
    started=false
    for ((i = 0; i < 30; i++)); do
      sleep 0.2
      if mv_qemu_pid "$name" >/dev/null; then
        # Alive 2 s after start: device and network setup succeeded.
        if ((i >= 10)); then
          started=true
          break
        fi
      elif ! kill -0 "$launcher" 2>/dev/null; then
        break
      fi
    done
    if ! $started && mv_qemu_pid "$name" >/dev/null; then
      started=true
    fi
    if $started; then
      printf '%s\n' "$port" >"$dir/ssh.port"
      return 0
    fi
    kill "$launcher" 2>/dev/null || true
    if grep -qi 'host forwarding' "$dir/qemu.log" && ((attempt < 3)); then
      mv_log "SSH port $port was taken, retrying"
      continue
    fi
    cat "$dir/qemu.log" >&2 || true
    mv_die "QEMU failed to start $name"
  done
}

mv_boot_failed() {
  local name=$1 msg=$2
  mv_log "serial console of $name (last 60 lines):"
  tail -n 60 "$MV_VMS/$name/serial.log" >&2 || true
  mv_die "$name: $msg"
}

# mv_wait_ready <name>: waits until SSH answers and cloud-init has finished.
mv_wait_ready() {
  local name=$1 dir=$MV_VMS/$1 deadline remaining rc
  deadline=$((SECONDS + MV_BOOT_TIMEOUT))
  mv_ssh_args "$name"
  mv_log "waiting for SSH on 127.0.0.1:$(<"$dir/ssh.port")"
  until timeout 30 "${MV_SSH[@]}" true </dev/null >/dev/null 2>&1; do
    if ! mv_qemu_pid "$name" >/dev/null; then
      mv_boot_failed "$name" "QEMU exited during boot"
    fi
    if ((SECONDS >= deadline)); then
      mv_boot_failed "$name" "timed out after $MV_BOOT_TIMEOUT s waiting for SSH"
    fi
    sleep 3
  done
  remaining=$((deadline - SECONDS))
  if ((remaining < 1)); then
    remaining=1
  fi
  mv_log "waiting for cloud-init to finish"
  rc=0
  timeout "$remaining" "${MV_SSH[@]}" cloud-init status --wait </dev/null >/dev/null 2>&1 || rc=$?
  case $rc in
    0) ;;
    2)
      mv_log "warning: cloud-init finished with recoverable errors:"
      "${MV_SSH[@]}" cloud-init status --long </dev/null >&2 || true
      ;;
    124)
      mv_boot_failed "$name" "timed out after $MV_BOOT_TIMEOUT s waiting for cloud-init"
      ;;
    *)
      "${MV_SSH[@]}" cloud-init status --long </dev/null >&2 || true
      mv_boot_failed "$name" "cloud-init failed (exit code $rc)"
      ;;
  esac
}

# mv_boot <release> <variant> <backing-image>: creates an overlay, boots it
# and waits until it is ready. Sets MV_BOOTED to the VM name. The VM stays
# registered for cleanup; callers that keep it call mv_unregister.
mv_boot() {
  local release=$1 variant=$2 backing=$3 name dir
  name="$release-$variant-$(mv_hex6)"
  dir="$MV_VMS/$name"
  mkdir "$dir"
  MV_CLEANUP_VMS+=("$name")
  mkdir "$dir/seed"
  printf '%s\n' "$release" >"$dir/release"
  printf '%s\n' "$variant" >"$dir/variant"
  if [[ ! $MV_DISK_SIZE =~ ^[1-9][0-9]*G$ ]]; then
    mv_die "MOTANKA_VM_DISK must look like 40G, got '$MV_DISK_SIZE'"
  fi
  qemu-img create -q -f qcow2 -F qcow2 -b "$backing" "$dir/overlay.qcow2" "$MV_DISK_SIZE"
  mv_write_seed "$name"
  mv_start_http "$dir"
  mv_log "booting $name from $(basename "$backing")"
  mv_start_qemu "$name" "$MV_HTTP_PORT"
  mv_wait_ready "$name"
  # The seed server keeps running until mv_destroy: a reboot inside the VM
  # fetches the same seed (same instance-id), so cloud-init does not treat
  # the VM as new and regenerate its SSH host keys.
  MV_BOOTED=$name
}

# mv_save_logs <name>: copies the VM's logs to MOTANKA_VM_RESULTS, if set.
mv_save_logs() {
  local name=$1 dir=$MV_VMS/$1 r=${MOTANKA_VM_RESULTS:-}
  if [[ -z $r ]]; then
    return 0
  fi
  mkdir -p "$r"
  if [[ -f $dir/serial.log ]]; then
    cp -f "$dir/serial.log" "$r/$name.serial.log"
  fi
  if [[ -s $dir/qemu.log ]]; then
    cp -f "$dir/qemu.log" "$r/$name.qemu.log"
  fi
}

# mv_destroy <name>: stops the seed server, kills QEMU if it still runs and
# deletes the VM's state folder, including the overlay.
mv_destroy() {
  local name=$1 dir=$MV_VMS/$1 pid i
  mv_valid_name "$name" || return 1
  if [[ ! -d $dir ]]; then
    mv_unregister "$name"
    return 0
  fi
  mv_stop_http "$dir"
  if pid=$(mv_qemu_pid "$name"); then
    kill "$pid" 2>/dev/null || true
    for ((i = 0; i < 25; i++)); do
      mv_qemu_pid "$name" >/dev/null || break
      sleep 0.2
    done
    if pid=$(mv_qemu_pid "$name"); then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
  fi
  mv_save_logs "$name" || true
  rm -rf -- "$dir"
  mv_unregister "$name"
}

# mv_poweroff <name> <seconds>: clean shutdown over SSH. Returns 1 if QEMU
# still runs after <seconds>.
mv_poweroff() {
  local name=$1 seconds=$2
  if ! mv_qemu_pid "$name" >/dev/null; then
    return 0
  fi
  if [[ -r $MV_VMS/$name/ssh.port ]]; then
    mv_ssh_args "$name"
    timeout 30 "${MV_SSH[@]}" sudo systemctl poweroff </dev/null >/dev/null 2>&1 || true
  fi
  mv_wait_exit "$name" "$seconds"
}

# mv_rsync_rsh: prints the ssh command line for rsync -e. rsync splits it on
# spaces and honours quotes but not backslashes.
mv_rsync_rsh() {
  local out=ssh arg
  for arg in "${MV_SSH_OPTS[@]}"; do
    if [[ $arg =~ ^[A-Za-z0-9_./:=@,+-]+$ ]]; then
      out+=" $arg"
    elif [[ $arg != *"'"* ]]; then
      out+=" '$arg'"
    else
      mv_die "cannot pass '$arg' to rsync"
    fi
  done
  printf '%s\n' "$out"
}

# --- build VMs and file copies ----------------------------------------------

# mv_up_build_vm: boots a resolute fresh VM sized for package builds
# (MOTANKA_BUILD_VM_CPUS, MOTANKA_BUILD_VM_RAM) and sets MV_BOOTED to its
# name. The VM is registered for cleanup; callers that keep it call
# mv_unregister.
mv_up_build_vm() {
  local n cpus ram name
  n=$(nproc 2>/dev/null || echo 4)
  if ((n > 10)); then
    n=10
  fi
  cpus=${MOTANKA_BUILD_VM_CPUS:-$n}
  ram=${MOTANKA_BUILD_VM_RAM:-10G}
  mv_log "booting a build VM ($cpus vCPUs, $ram)"
  name=$(MOTANKA_VM_CPUS=$cpus MOTANKA_VM_RAM=$ram "$MV_LIB_DIR/up" resolute fresh </dev/null | tail -n 1)
  if ! mv_valid_name "$name"; then
    mv_die "test/vm/up printed an invalid VM name '$name'"
  fi
  MV_CLEANUP_VMS+=("$name")
  MV_BOOTED=$name
}

# mv_copy_to_vm <name> <host-dir> <guest-dir>: copies the content of a host
# folder into a guest folder (created if needed) with tar over SSH.
mv_copy_to_vm() {
  local name=$1 src=$2 dest=$3 q
  mv_ssh_args "$name"
  printf -v q '%q' "$dest"
  tar -C "$src" -cf - . | "${MV_SSH[@]}" "mkdir -p -- $q && tar -C $q -xf -"
}

# mv_copy_from_vm <name> <guest-dir> <host-dir>: copies the content of a
# guest folder into a host folder (created if needed) with tar over SSH.
# The host folder must be inside ~/.cache/motanka-vm/.
mv_copy_from_vm() {
  local name=$1 src=$2 dest=$3 q
  if [[ $dest != "$MV_STATE"/* || $dest == *..* ]]; then
    mv_die "refusing to copy into $dest: not under $MV_STATE/"
  fi
  mv_ssh_args "$name"
  printf -v q '%q' "$src"
  mkdir -p "$dest"
  "${MV_SSH[@]}" "tar -C $q -cf - ." </dev/null | tar -C "$dest" --no-same-owner -xf -
}
