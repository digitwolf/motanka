#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for test/parity/probe.py, the assembler of the parity probe
# (task 24.3, requirement 13.6): its port of omarchy-menu's model (JSONC
# reading, merging the user extension, translations, visibility with "when"
# conditions run by bash), the normalisation of process names, unit
# names, bus names, modifier masks and runtime paths, the filter of mirrored
# system units, the first-run check (probe.py first-run) and probe.sh's
# validation of its --wait-* options.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  PARITY="$BATS_TEST_DIRNAME/../parity"
  FIX="$BATS_TEST_DIRNAME/fixtures/parity"
}

# py <code>: runs Python with probe.py importable as "probe".
py() {
  run env PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import probe
$1" "$PARITY" "$FIX" "$BATS_TEST_TMPDIR"
}

@test "Upstream's JSONC menu format reads with comments and trailing commas" {
  py 'items = probe.read_menu_jsonc(open(sys.argv[2] + "/menu.jsonc").read())
print(len(items), items[0]["id"], items[0]["kind"], items[-1]["id"], items[-1]["parent"])
print(probe.read_menu_jsonc("// only a comment\n"), probe.read_menu_jsonc("{ broken"))'
  assert_success
  assert_line '12 apps action system.power.off system.power'
  assert_line '[] None'
}

@test "the top level follows the menu's visibility rules with bash conditions" {
  py 'import json
items, order = probe.merge_menu(probe.read_menu_jsonc(open(sys.argv[2] + "/menu.jsonc").read()), [])
errors, results = {}, {}
when = probe.guard_runner({"PATH": "/usr/bin:/bin"}, sys.argv[3], errors, results)
top = probe.menu_top(items, order, when)
print(" ".join(k + "=" + str(int(v["visible"])) for k, v in top.items()))
print(json.dumps(results, sort_keys=True), errors)'
  assert_success
  assert_line 'apps=1 learn=1 remove=0 about=1 hidden-action=0 system=1 tools=1'
  assert_line '{"hidden-action": false, "remove.one": false, "remove.two": false, "system.power.off": true, "tools": true} {}'
}

@test "the user's extension overrides labels and adds rows; a catalog translates" {
  py 'base = probe.read_menu_jsonc(open(sys.argv[2] + "/menu.jsonc").read())
base = probe.apply_translations(base, {"learn": {"label": "Lernen"}})
user = probe.read_menu_jsonc("{\"about\": {\"label\": \"Info\", \"action\": \"true\"}, \"mine\": {\"label\": \"Mine\", \"action\": \"true\"}}")
items, order = probe.merge_menu(base, user)
top = probe.menu_top(items, order, lambda e: True)
print(top["learn"]["label"], top["about"]["label"], top["mine"]["label"], order[0], order[-1])'
  assert_success
  assert_line 'Lernen Info Mine root mine'
}

@test "a condition that runs too long counts as failed and is recorded" {
  py 'errors, results = {}, {}
when = probe.guard_runner({"PATH": "/usr/bin:/bin"}, sys.argv[3], errors, results)
probe.GUARD_TIMEOUT = 1
print(when({"id": "slow", "when": "sleep 30"}), errors)'
  assert_success
  assert_line "False {'menu-when:slow': 'timed out after 1 s'}"
}

@test "process names skip interpreters; unit names drop random instance ids" {
  py 'print(probe.process_name("/usr/bin/python3 -I /opt/motanka/bin/uwsm start -g -1"),
      probe.process_name("/usr/bin/Hyprland --watchdog-fd 4"), probe.process_name("bash"))
print(probe.normalize_unit("app-Hyprland-org.gnome.Nautilus@0123456789abcdef0123456789abcdef.service"),
      probe.normalize_unit("run-p1234-i5678.service"), probe.normalize_unit("motanka-session.target"))'
  assert_success
  assert_line 'uwsm Hyprland bash'
  assert_line 'app-Hyprland-org.gnome.Nautilus@*.service run-*.service motanka-session.target'
}

@test "modifier masks become names; runtime paths and addresses are normalised" {
  py 'raw = probe.Raw(sys.argv[3], 1001, {})
print(probe.mod_names(64), probe.mod_names(65), probe.mod_names(0) or "-", probe.mod_names("x"))
print(raw.norm("unix:path=/run/user/1001/bus 0x55d0c0ffee00"))'
  assert_success
  assert_line 'SUPER SHIFT+SUPER - x'
  assert_line "unix:path=/run/user/\$UID/bus 0x*"
}

@test "the environment keeps allowlisted names only, without per-login values" {
  py 'raw = probe.Raw(sys.argv[3], 1001, {})
env = probe.parse_env(["PATH=/usr/bin", "XDG_CURRENT_DESKTOP=Hyprland", "HYPRLAND_INSTANCE_SIGNATURE=abc",
                       "XDG_SESSION_ID=3", "SECRET_TOKEN=x", "OMARCHY_PATH=/usr/share/omarchy", "XDG_RUNTIME_DIR=/run/user/1001",
                       "OMARCHY_STARTUP_CURSOR_SESSION=efb50993_1794581783_1083611601"], raw)
print(sorted(env.items()))'
  assert_success
  assert_line "[('OMARCHY_PATH', '/usr/share/omarchy'), ('PATH', '/usr/bin'), ('XDG_CURRENT_DESKTOP', 'Hyprland'), ('XDG_RUNTIME_DIR', '/run/user/\$UID')]"
}

@test "unit names drop the session's desktop name, scope ids, bus connection ids and the UID" {
  py 'print(probe.normalize_unit("app-Hyprland-udiskie-7894a99d.scope", "Hyprland"),
      probe.normalize_unit("app-Hyprland-udiskie-7894a99d.scope", "Motanka"),
      probe.normalize_unit("dbus-:1.19-org.a11y.atspi.Registry@0.service"),
      probe.normalize_unit("run-user-1001.mount", uid=1001), probe.normalize_unit("run-user-10010-doc.mount", uid=1001))
print(probe.session_unit("boot.mount"), probe.session_unit("run-user-1001-gvfs.mount"),
      probe.session_unit("sys-subsystem-net-devices-eth0.device"), probe.session_unit("swap-swapfile.swap"),
      probe.session_unit("pipewire.socket"))'
  assert_success
  assert_line "app-\$DESKTOP-udiskie-*.scope app-Hyprland-udiskie-*.scope dbus-:1.*-org.a11y.atspi.Registry@0.service run-user-\$UID.mount run-user-10010-doc.mount"
  assert_line 'False True False False True'
}

@test "the session's units leave out mirrored system units; bus names drop pid suffixes" {
  py 'd = sys.argv[3]
def put(name, text):
    open(d + "/" + name, "w").write(text)
    open(d + "/" + name + ".rc", "w").write("0\n")
put("units-active.txt", "app-Motanka-omarchy\\x2dhyprland\\x2dmonitor\\x2dwatch-57e753ea.scope loaded active running x\n"
    "boot-efi.mount loaded active mounted /boot/efi\nrun-user-1001-doc.mount loaded active mounted x\n"
    "sys-devices-virtual-tty-ttyprintk.device loaded active plugged x\nswap-swapfile.swap loaded active active x\n"
    "motanka-session.target loaded active active x\n")
put("units-failed.txt", "")
put("busctl.txt", "org.kde.StatusNotifierHost-612-1794581783598 612 quickshell alice :1.40 user@1001.service - -\n"
    "org.fcitx.Fcitx5 700 fcitx5 alice :1.41 user@1001.service - -\n"
    ":1.40 612 quickshell alice :1.40 user@1001.service - -\n")
raw = probe.Raw(d, 1001, {})
doc = {c: {} for c in probe.CATEGORIES}
probe.collect_session(raw, doc, ["XDG_CURRENT_DESKTOP=Motanka:Hyprland"], "")
print(" ".join(sorted(doc["units_active"])))
print(" ".join(sorted(doc["dbus_names"])), doc["units_failed"])'
  assert_success
  assert_line "app-\$DESKTOP-omarchy\\x2dhyprland\\x2dmonitor\\x2dwatch-*.scope motanka-session.target run-user-\$UID-doc.mount"
  assert_line 'org.fcitx.Fcitx5 org.kde.StatusNotifierHost-* {}'
}

# first_run_fixture: a home folder with the default-theme record, a layers
# answer with the wallpaper, and a process list in which the probe's own
# session (sid 300) is the only one that mentions the first-run command.
first_run_fixture() {
  H=$BATS_TEST_TMPDIR/home
  mkdir -p "$H/.local/state/motanka"
  printf 'ok\t2026-11-13T10:00:00Z\ttokyo-night\n' >"$H/.local/state/motanka/default-theme"
  printf '{"Virtual-1": {"levels": {"0": [{"namespace": "omarchy-background"}], "2": [{"namespace": "omarchy-bar"}]}}}\n' \
    >"$BATS_TEST_TMPDIR/layers.json"
  printf '  100   100 /opt/motanka/bin/Hyprland --watchdog-fd 4\n  400   300 /bin/bash /opt/motanka/bin/omarchy-provision-first-run\n' \
    >"$BATS_TEST_TMPDIR/ps.txt"
}

first_run() {
  run python3 "$PARITY/probe.py" first-run --home "$H" --ps "$BATS_TEST_TMPDIR/ps.txt" --own-sid 300 "$@"
}

@test "first-run reports each condition and exits 0 once all are reached" {
  first_run_fixture
  first_run --layers "$BATS_TEST_TMPDIR/layers.json" --file .local/state/motanka/default-theme \
    --layer omarchy-background --gone omarchy-provision-first-run
  assert_success
  assert_line 'reached: ~/.local/state/motanka/default-theme: ok 2026-11-13T10:00:00Z tokyo-night'
  assert_line 'reached: layer omarchy-background: mapped'
  assert_line 'reached: process omarchy-provision-first-run: not running'
}

@test "first-run names what is pending and exits 1" {
  first_run_fixture
  : >"$H/.local/state/motanka/empty"
  printf '  401   500 /bin/bash /opt/motanka/bin/omarchy-provision-first-run\n' >>"$BATS_TEST_TMPDIR/ps.txt"
  first_run --layers "$BATS_TEST_TMPDIR/no-such-file" --file .local/state/motanka/missing \
    --file .local/state/motanka/empty --file .local/state/motanka/default-theme \
    --layer omarchy-background --gone omarchy-provision-first-run
  assert_failure 1
  assert_line 'pending: ~/.local/state/motanka/missing: missing'
  assert_line 'pending: ~/.local/state/motanka/empty: empty'
  assert_line --partial 'reached: ~/.local/state/motanka/default-theme: ok'
  assert_line 'pending: layer omarchy-background: hyprctl layers gave no answer'
  assert_line 'pending: process omarchy-provision-first-run: still running (pid 401)'
  printf '{"Virtual-1": {"levels": {"2": [{"namespace": "omarchy-bar"}]}}}\n' >"$BATS_TEST_TMPDIR/layers.json"
  first_run --layers "$BATS_TEST_TMPDIR/layers.json" --layer omarchy-background
  assert_failure 1
  assert_line 'pending: layer omarchy-background: not mapped (layers: omarchy-bar)'
}

@test "first-run refuses paths outside the home folder and missing arguments" {
  first_run_fixture
  first_run --layers "$BATS_TEST_TMPDIR/layers.json" --file /etc/passwd
  assert_failure 2
  assert_output --partial 'must be relative to --home'
  first_run --layers "$BATS_TEST_TMPDIR/layers.json" --file .local/../../etc/passwd
  assert_failure 2
  run python3 "$PARITY/probe.py" first-run --ps "$BATS_TEST_TMPDIR/ps.txt" --layers "$BATS_TEST_TMPDIR/layers.json"
  assert_failure 2
}

@test "probe.sh refuses malformed --wait-* options before it looks for a session" {
  run bash "$PARITY/probe.sh" --out "$BATS_TEST_TMPDIR/out" --wait-file ../etc/passwd
  assert_failure 2
  assert_output --partial "wait-file takes a path relative to \$HOME"
  run bash "$PARITY/probe.sh" --out "$BATS_TEST_TMPDIR/out" --wait-file /etc/passwd
  assert_failure 2
  run bash "$PARITY/probe.sh" --out "$BATS_TEST_TMPDIR/out" --wait-gone 'a b'
  assert_failure 2
  assert_output --partial 'wait-gone takes a name'
  run bash "$PARITY/probe.sh" --out "$BATS_TEST_TMPDIR/out" --wait-layer
  assert_failure 2
  assert_output --partial 'wait-layer needs a value'
  run bash "$PARITY/probe.sh" --out "$BATS_TEST_TMPDIR/out" --first-run-timeout 0
  assert_failure 2
  assert_output --partial 'take a number of seconds'
  assert [ ! -e "$BATS_TEST_TMPDIR/out" ]
}
