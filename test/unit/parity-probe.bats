#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for test/parity/probe.py, the assembler of the parity probe
# (task 24.3, requirement 13.6): its port of omarchy-menu's model (JSONC
# reading, merging the user extension, translations, visibility with "when"
# conditions run by bash), and the normalisation of process names, unit
# names, modifier masks and runtime paths.

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
                       "XDG_SESSION_ID=3", "SECRET_TOKEN=x", "OMARCHY_PATH=/usr/share/omarchy", "XDG_RUNTIME_DIR=/run/user/1001"], raw)
print(sorted(env.items()))'
  assert_success
  assert_line "[('OMARCHY_PATH', '/usr/share/omarchy'), ('PATH', '/usr/bin'), ('XDG_CURRENT_DESKTOP', 'Hyprland'), ('XDG_RUNTIME_DIR', '/run/user/\$UID')]"
}
