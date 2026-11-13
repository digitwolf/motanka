#!/usr/bin/env python3
"""Turn the raw outputs of test/parity/probe.sh into the probe document.

Usage: probe.py --raw DIR --out FILE [--own-sid SID] [--screenshot FILE]
                [--no-session]
       probe.py first-run --home DIR --ps FILE --layers FILE [--own-sid SID]
                [--file REL]... [--layer NAMESPACE]... [--gone NAME]...

probe.sh runs the session's commands and leaves their output in DIR; this
program parses it, adds the facts that need no session command, and writes
one JSON document (format 1) to FILE:

  format   1
  meta     facts about the machine and the probe run; diff.py prints them
           but does not compare them
  every other key is a category: an object of key -> value that diff.py
  compares key by key:
    versions          omarchy-version, Hyprland (hyprctl version), Quickshell,
                      Upstream's version file
    configerrors      hyprctl configerrors: message -> count
    layers            hyprctl layers: "<level>:<namespace>" -> count
    clients           hyprctl clients: class -> count
    monitors          hyprctl monitors: name -> mode and scale
    options           hyprctl getoption: option -> value
    binds             hyprctl binds: "<submap>|<mods>|<key>" -> dispatcher,
                      argument, description, flags
    env_session       allowlisted variables a command started by the
                      compositor gets
    env_user_manager  the same variables in systemctl --user show-environment
    dbus_names        well-known names on the session bus -> owning process
                      ("-<pid>-<n>" at the end of a name becomes "-*")
    processes         names of the user's processes (outside the probe)
    units_active      active user units, without the .device, .swap and
                      .mount units the user manager mirrors from the
                      system (mounts under /run/user/<uid> are kept)
    units_failed      failed user units, filtered the same way
    queries           read-only Upstream commands -> exit code and output
    themes            omarchy-theme-list
    commands          every file of Upstream's bin/ -> found on the PATH
    command_paths     -> the path it resolves to
    tools             companion programs Upstream calls -> found on the PATH
    tool_paths        -> the path it resolves to
    menu              omarchy-menu's top level: id -> label, kind, visible
    menu_when         the "when" conditions evaluated for it: id -> result
    upstream_files    Upstream's files (bin, config, default, ...): path ->
                      SHA-256 (or "link:<target>")
    errors            steps of the probe that failed -> message

Upstream's tree is /opt/motanka/share/omarchy where Motanka vendors it, and
the resolved OMARCHY_PATH (/usr/share/omarchy) otherwise. Values that hold
the user's runtime folder have the UID replaced by $UID; memory addresses
become 0x*. Unit names drop what changes on every login: random instance
and scope ids become *, bus connection ids :1.* and the UID in
run-user-<uid> $UID; the session's first desktop name in app-<desktop>-...
units (named after XDG_CURRENT_DESKTOP) becomes $DESKTOP, so the same app
pairs up across sessions with different desktop names.

The first-run mode checks whether Upstream's first-run work in the session
is done, for probe.sh --wait-*: every --file (relative to --home) exists
and is not empty, every --layer namespace is mapped in --layers (the output
of hyprctl -j layers), and no process named --gone is in --ps (the output
of ps -o pid=,sid=,args=; process names as in "processes", the probe's own
session --own-sid left out). It prints one line per condition, "reached: "
or "pending: " and what it found, and exits 0 when all are reached, 1 when
one is pending, 2 on a usage error.

The menu is computed the way shell/plugins/menu/MenuModel.js does it: the
shipped default/omarchy/omarchy-menu.jsonc under OMARCHY_PATH, translated by
default/i18n/<language>/menu.json when ~/.config/omarchy/language names a
language, merged with ~/.config/omarchy/extensions/omarchy-menu.jsonc. An
entry is visible unless its "when" condition fails, and a submenu also
needs a visible child or a provider. Each needed "when" condition runs once
with bash in the session environment, as the menu runs it (output
discarded, 10 s limit); no menu action runs.

Exit codes: 0 written, 2 usage or input error.
"""

import argparse
import hashlib
import json
import os
import pwd
import re
import shutil
import signal
import subprocess
import sys
import time

FORMAT = 1
VENDORED_ROOT = "/opt/motanka/share/omarchy"
DEFAULT_OMARCHY_PATH = "/usr/share/omarchy"
REFERENCE_STATE = "/var/lib/motanka-parity"
UPSTREAM_FOLDERS = ("applications", "bin", "config", "default", "install", "migrations", "shell", "themes")
GUARD_TIMEOUT = 10
OUTPUT_LIMIT = 2000

# Companion programs Upstream's scripts, bindings and menu call.
TOOLS = (
    "Hyprland", "hyprctl", "start-hyprland", "uwsm", "uwsm-app", "quickshell", "qs", "hyprpicker",
    "hyprsunset", "hyprlock", "hypridle", "grim", "slurp", "wl-copy", "wl-paste", "wtype", "jq", "gum",
    "fzf", "socat", "xdg-terminal-exec", "xdg-open", "notify-send", "foot", "alacritty", "ghostty",
    "chromium", "nautilus", "btop", "fastfetch", "nvim", "owe", "fcitx5", "brightnessctl", "pamixer",
    "wpctl", "playerctl", "tesseract", "gpu-screen-recorder", "localsend", "imv", "mpv", "evince",
    "lazygit", "starship", "zoxide", "eza", "bat", "fd", "rg", "mise", "tmux", "herdr", "docker",
    "ttfx", "tldr", "locate", "waybar", "mako", "walker", "swayosd-client",
)

# Environment variables recorded: these names, and names with these prefixes,
# except ENV_SKIP (values that differ on every login).
ENV_NAMES = frozenset((
    "PATH", "LANG", "LANGUAGE", "EDITOR", "VISUAL", "TERMINAL", "BROWSER", "DCONF_PROFILE",
    "LD_LIBRARY_PATH", "LD_PRELOAD", "DISPLAY", "WAYLAND_DISPLAY", "XCOMPOSEFILE", "XMODIFIERS",
    "INPUT_METHOD", "GSK_RENDERER", "DESKTOP_SESSION", "SHELL", "DBUS_SESSION_BUS_ADDRESS",
    "_JAVA_AWT_WM_NONREPARENTING", "NO_AT_BRIDGE", "GTK_USE_PORTAL",
))
ENV_PREFIXES = (
    "OMARCHY_", "XDG_", "QT_", "GDK_", "GTK_", "MOZ_", "ELECTRON_", "OZONE_", "SDL_", "CLUTTER_",
    "XCURSOR_", "HYPRCURSOR_", "HYPRLAND_", "UWSM_", "AQ_", "WLR_", "LIBVA_", "LC_",
)
ENV_SKIP = frozenset(("HYPRLAND_INSTANCE_SIGNATURE", "XDG_SESSION_ID", "XDG_VTNR", "XDG_SEAT_PATH",
                      "XDG_SESSION_PATH", "OMARCHY_STARTUP_CURSOR_SESSION"))

# Short-lived helpers that say nothing about the session.
PROCESS_SKIP = frozenset((
    "bash", "sh", "dash", "zsh", "sleep", "timeout", "env", "cat", "tr", "sort", "grep", "sed", "awk",
    "head", "tail", "cut", "ps", "sudo", "runuser", "su", "ssh", "sshd", "sshd-session", "tee", "xargs",
    "find", "flock", "stdbuf", "python3", "python",
))
INTERPRETERS = re.compile(r"^(python[0-9.]*|bash|sh|dash|perl|node|env)$")

LAYER_LEVELS = {"0": "background", "1": "bottom", "2": "top", "3": "overlay"}
MODS = ((1, "SHIFT"), (2, "CAPS"), (4, "CTRL"), (8, "ALT"), (16, "MOD2"), (32, "MOD3"), (64, "SUPER"),
        (128, "MOD5"))
BIND_FLAGS = (("l", "locked"), ("r", "release"), ("e", "repeat"), ("o", "longPress"), ("n", "non_consuming"),
              ("m", "mouse"))
LANGUAGE_RE = re.compile(r"^[a-z]{2,3}(-[A-Z]{2})?$")
HEX_ADDRESS_RE = re.compile(r"\b0x[0-9a-fA-F]{6,}\b")
BUS_NAME_IDS_RE = re.compile(r"-[0-9]+-[0-9]+$")
FIRST_LINE_LIMIT = 120


# --- omarchy-menu (a port of shell/plugins/menu/MenuModel.js) --------------

def strip_jsonc(raw):
    """MenuModel.stripJsonc: drops whole-line // comments and trailing commas."""
    text = re.sub(r"^\s*//[^\n]*(\n|$)", "", str(raw or ""), flags=re.M)
    return re.sub(r",(\s*[}\]])", r"\1", text)


def normalize_item(item_id, raw):
    value = raw or {}
    parent = value.get("parent")
    if parent is None:
        parent = ".".join(item_id.split(".")[:-1]) if "." in item_id else "root"
    if item_id == "root":
        parent = ""
    kind = "action" if value.get("action") else ("link" if value.get("target") else "menu")
    return {
        "id": item_id,
        "parent": parent,
        "kind": kind,
        "label": value.get("label") or item_id,
        "title": value.get("title") or "",
        "description": value.get("description") or "",
        "target": value.get("target") or "",
        "provider": value.get("provider") or "",
        "when": value.get("when") or "",
    }


def read_menu_jsonc(raw):
    """MenuModel.readMenuJsonc: the items, [] for an empty file, None if not a menu."""
    stripped = strip_jsonc(raw)
    if not stripped.strip():
        return []
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    source = parsed["items"] if isinstance(parsed.get("items"), dict) else parsed
    return [normalize_item(k, v) for k, v in source.items() if isinstance(v, dict)]


def apply_translations(items, catalog):
    """MenuModel.applyTranslations (label, title and description)."""
    if not isinstance(catalog, dict):
        return list(items)
    out = []
    for entry in items:
        translated = catalog.get(entry["id"])
        if not isinstance(translated, dict):
            out.append(entry)
            continue
        entry = dict(entry)
        for field in ("label", "title", "description"):
            if translated.get(field):
                entry[field] = translated[field]
        out.append(entry)
    return out


def merge_menu(default_items, user_items):
    """MenuModel.mergeMenuSources: (items by id, order)."""
    items, order = {}, []
    for source in (default_items or [], user_items or []):
        for entry in source:
            if entry["id"] not in items:
                order.append(entry["id"])
            merged = dict(items.get(entry["id"], {}))
            merged.update(entry)
            items[entry["id"]] = merged
    if "root" not in items:
        items["root"] = normalize_item("root", {"label": "Go"})
        order.insert(0, "root")
    return items, order


def is_visible(items, order, entry, when, depth=0):
    """MenuModel.isVisible; when(entry) answers the entry's condition."""
    if not entry:
        return False
    if entry["when"] and not when(entry):
        return False
    if entry["kind"] not in ("menu", "link"):
        return True
    if entry["provider"]:
        return True
    if depth >= 32:
        return False
    target = entry["target"] if entry["kind"] == "link" else entry["id"]
    for child_id in order:
        child = items.get(child_id)
        if child and child["parent"] == target and is_visible(items, order, child, when, depth + 1):
            return True
    return False


def menu_top(items, order, when):
    """The top-level entries: id -> label, kind, visible."""
    out = {}
    for item_id in order:
        entry = items[item_id]
        if item_id == "root" or entry["parent"] != "root":
            continue
        out[item_id] = {"label": entry["label"], "kind": entry["kind"],
                        "visible": is_visible(items, order, entry, when)}
    return out


def guard_runner(env, home, errors, results):
    """A when() for is_visible that runs each condition once with bash."""
    def when(entry):
        if entry["id"] in results:
            return results[entry["id"]]
        script = "{ " + entry["when"] + "; } >/dev/null 2>&1"
        ok = False
        try:
            proc = subprocess.Popen(["/bin/bash", "-c", script], env=env, cwd=home, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                ok = proc.wait(timeout=GUARD_TIMEOUT) == 0
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                errors[f"menu-when:{entry['id']}"] = f"timed out after {GUARD_TIMEOUT} s"
        except OSError as e:
            errors[f"menu-when:{entry['id']}"] = str(e)
        results[entry["id"]] = ok
        return ok
    return when


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def collect_menu(env, home, errors):
    omarchy_path = env.get("OMARCHY_PATH") or DEFAULT_OMARCHY_PATH
    default_path = os.path.join(omarchy_path, "default", "omarchy", "omarchy-menu.jsonc")
    raw = read_file(default_path)
    if raw is None:
        errors["menu"] = f"cannot read {default_path}"
        return {}, {}, "-"
    default_items = read_menu_jsonc(raw)
    if not default_items:
        errors["menu"] = f"{default_path} is not a menu"
        return {}, {}, "-"
    config_home = env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    lang_path = env.get("OMARCHY_LANGUAGE_FILE") or os.path.join(config_home, "omarchy", "language")
    language = (read_file(lang_path) or "").strip() or "en"
    if not LANGUAGE_RE.match(language):
        errors["menu-language"] = "the language file does not name a language code"
        language = "en"
    if language != "en":
        catalog_raw = read_file(os.path.join(omarchy_path, "default", "i18n", language, "menu.json"))
        try:
            catalog = json.loads(catalog_raw) if catalog_raw else {}
        except ValueError:
            catalog = {}
            errors["menu-language"] = f"the {language} menu catalog is not JSON"
        if isinstance(catalog, dict) and isinstance(catalog.get("items"), dict):
            catalog = catalog["items"]
        default_items = apply_translations(default_items, catalog)
    user_raw = read_file(os.path.join(home, ".config", "omarchy", "extensions", "omarchy-menu.jsonc"))
    user_items = read_menu_jsonc(user_raw) if user_raw is not None else []
    if user_items is None:
        errors["menu-extension"] = "the user's menu extension is not a menu"
        user_items = []
    items, order = merge_menu(default_items, user_items)
    results = {}
    top = menu_top(items, order, guard_runner(env, home, errors, results))
    return top, dict(results), language


# --- raw outputs ---------------------------------------------------------

class Raw:
    def __init__(self, folder, uid, errors):
        self.folder = folder
        self.uid = uid
        self.errors = errors

    def text(self, name):
        return read_file(os.path.join(self.folder, name))

    def rc(self, name):
        value = (self.text(name + ".rc") or "").strip()
        return int(value) if value.isdigit() else None

    def first_error(self, name):
        lines = (self.text(name + ".err") or "").strip().splitlines()
        return self.norm(lines[0]) if lines else ""

    def norm(self, value):
        text = str(value).replace(f"/run/user/{self.uid}", "/run/user/$UID")
        return HEX_ADDRESS_RE.sub("0x*", text)

    def output(self, name, step):
        """Stdout of a command probe.sh ran, or None (error recorded)."""
        text = self.text(name)
        rc = self.rc(name)
        if text is None or rc is None:
            self.errors[step] = "not run"
            return None
        if rc != 0:
            self.errors[step] = f"exit {rc}: {self.first_error(name)}".rstrip(": ")
            return None
        return text

    def json(self, name, step):
        text = self.output(name, step)
        if text is None:
            return None
        try:
            return json.loads(text)
        except ValueError:
            self.errors[step] = "output is not JSON"
            return None


def layer_surfaces(layers):
    """[(level, namespace)] of hyprctl -j layers output (a dict by monitor)."""
    out = []
    if not isinstance(layers, dict):
        return out
    for monitor in layers.values():
        levels = monitor.get("levels", {}) if isinstance(monitor, dict) else {}
        if not isinstance(levels, dict):
            continue
        for level, surfaces in levels.items():
            for s in surfaces or []:
                if isinstance(s, dict):
                    out.append((level, str(s.get("namespace", ""))))
    return out


def mod_names(mask):
    try:
        mask = int(mask)
    except (TypeError, ValueError):
        return str(mask)
    return "+".join(name for bit, name in MODS if mask & bit)


def collect_hyprland(raw, doc):
    v = raw.json("hypr-version.json", "hyprctl version")
    if isinstance(v, dict):
        for key in ("version", "tag", "commit", "branch", "buildAquamarine", "buildHyprlang", "buildHyprutils",
                    "buildHyprcursor", "buildHyprgraphics"):
            if key in v:
                doc["versions"][f"hyprland.{key}"] = str(v[key])

    errs = raw.json("hypr-configerrors.json", "hyprctl configerrors")
    if errs is not None:
        for e in errs if isinstance(errs, list) else [errs]:
            msg = raw.norm(e).strip()
            if msg:
                doc["configerrors"][msg] = doc["configerrors"].get(msg, 0) + 1

    layers = raw.json("hypr-layers.json", "hyprctl layers")
    for level, namespace in layer_surfaces(layers):
        key = f"{LAYER_LEVELS.get(str(level), level)}:{namespace}"
        doc["layers"][key] = doc["layers"].get(key, 0) + 1

    clients = raw.json("hypr-clients.json", "hyprctl clients")
    if isinstance(clients, list):
        for c in clients:
            name = c.get("class") or c.get("initialClass") or "(none)"
            doc["clients"][name] = doc["clients"].get(name, 0) + 1

    monitors = raw.json("hypr-monitors.json", "hyprctl monitors")
    if isinstance(monitors, list):
        for m in monitors:
            try:
                mode = f"{m.get('width')}x{m.get('height')}@{float(m.get('refreshRate', 0)):.2f}"
            except (TypeError, ValueError):
                mode = f"{m.get('width')}x{m.get('height')}"
            doc["monitors"][str(m.get("name"))] = {"mode": mode, "scale": m.get("scale")}

    binds = raw.json("hypr-binds.json", "hyprctl binds")
    if isinstance(binds, list):
        seen = {}
        for b in binds:
            key = b.get("key") or (f"code:{b.get('keycode')}" if b.get("keycode") else "")
            k = f"{b.get('submap') or 'global'}|{mod_names(b.get('modmask', 0))}|{key}"
            seen[k] = seen.get(k, 0) + 1
            if seen[k] > 1:
                k = f"{k}#{seen[k]}"
            doc["binds"][k] = {
                "dispatcher": str(b.get("dispatcher", "")),
                "arg": raw.norm(b.get("arg", "")),
                "description": str(b.get("description", "")),
                "flags": "".join(c for c, field in BIND_FLAGS if b.get(field)),
            }

    for line in (raw.text("options.tsv") or "").splitlines():
        option, _, name = line.partition("\t")
        value = raw.json(name, f"hyprctl getoption {option}")
        if isinstance(value, dict):
            value = {k: (raw.norm(x) if isinstance(x, str) else x) for k, x in value.items() if k != "option"}
            doc["options"][option] = value


def parse_env(entries, raw):
    out = {}
    for entry in entries:
        name, sep, value = entry.partition("=")
        if not sep or name in ENV_SKIP:
            continue
        if name in ENV_NAMES or name.startswith(ENV_PREFIXES):
            out[name] = raw.norm(value)
    return out


def normalize_unit(unit, desktop="", uid=None):
    unit = re.sub(r"@[0-9a-f]{8,}\.", "@*.", unit)
    unit = re.sub(r"^run-[pu][0-9]+(-i[0-9]+)?\.", "run-*.", unit)
    unit = re.sub(r"-[0-9a-f]{8,32}\.scope$", "-*.scope", unit)
    unit = re.sub(r":1\.[0-9]+", ":1.*", unit)
    if desktop and unit.startswith(f"app-{desktop}-"):
        unit = "app-$DESKTOP-" + unit[len(desktop) + 5:]
    if uid is not None:
        unit = re.sub(rf"^run-user-{uid}(?=[-.])", "run-user-$UID", unit)
    return unit


def session_unit(unit):
    """False for the device, swap and mount units the user manager mirrors
    from the system; mounts under the user's runtime folder are kept."""
    if unit.endswith((".device", ".swap")):
        return False
    return not unit.endswith(".mount") or unit.startswith("run-user-")


def normalize_bus_name(name):
    """org.kde.StatusNotifierHost-612-1794581783598 -> ...StatusNotifierHost-*"""
    return BUS_NAME_IDS_RE.sub("-*", name)


def session_desktop(env_entries):
    """The first name of XDG_CURRENT_DESKTOP in the session environment."""
    for entry in env_entries:
        name, sep, value = entry.partition("=")
        if sep and name == "XDG_CURRENT_DESKTOP":
            return value.split(":")[0]
    return ""


def process_name(args):
    tokens = args.split()
    if not tokens:
        return ""
    name = os.path.basename(tokens[0]).rstrip(":")
    if INTERPRETERS.match(name):
        for t in tokens[1:]:
            if not t.startswith("-"):
                return os.path.basename(t)
    return name


def collect_session(raw, doc, env_entries, own_sid):
    doc["env_session"] = parse_env(env_entries, raw)
    text = raw.output("user-env.txt", "systemctl --user show-environment")
    if text is not None:
        doc["env_user_manager"] = parse_env(text.splitlines(), raw)

    desktop = session_desktop(env_entries)
    for name, category in (("units-active.txt", "units_active"), ("units-failed.txt", "units_failed")):
        text = raw.output(name, f"systemctl --user list-units ({category})")
        for line in (text or "").splitlines():
            fields = line.split()
            if fields:
                unit = normalize_unit(fields[0].lstrip("●*"), desktop, raw.uid)
                if session_unit(unit):
                    doc[category][unit] = True

    text = raw.output("busctl.txt", "busctl --user list")
    for line in (text or "").splitlines():
        fields = line.split()
        if len(fields) >= 3 and not fields[0].startswith(":") and fields[1] != "-":
            doc["dbus_names"][normalize_bus_name(fields[0])] = fields[2]

    for line in (raw.text("ps.txt") or "").splitlines():
        fields = line.split(None, 2)
        if len(fields) < 3 or fields[1] == own_sid:
            continue
        name = process_name(fields[2])
        if name and not name.startswith(("(", "[")) and name not in PROCESS_SKIP:
            doc["processes"][name] = True

    for line in (raw.text("queries.tsv") or "").splitlines():
        label, _, name = line.partition("\t")
        rc = raw.rc(name)
        out = raw.norm((raw.text(name) or "").strip())
        if len(out) > OUTPUT_LIMIT:
            out = out[:OUTPUT_LIMIT] + "…"
        doc["queries"][label] = {"exit": rc, "out": out}
    q = doc["queries"].get("omarchy-version")
    if q is not None:
        doc["versions"]["omarchy-version"] = q["out"] if q["exit"] == 0 else f"exit {q['exit']}"

    text = raw.output("themes.txt", "omarchy-theme-list")
    for line in (text or "").splitlines():
        if line.strip():
            doc["themes"][line.strip()] = True

    text = raw.output("quickshell-version.txt", "quickshell --version")
    if text is not None and text.strip():
        doc["versions"]["quickshell"] = text.strip().splitlines()[0]


def which_all(names, path):
    found, paths = {}, {}
    for name in names:
        hit = shutil.which(name, path=path)
        found[name] = hit is not None
        if hit:
            paths[name] = os.path.realpath(hit)
    return found, paths


def upstream_root(env):
    if os.path.isdir(os.path.join(VENDORED_ROOT, "bin")):
        return VENDORED_ROOT
    return os.path.realpath(env.get("OMARCHY_PATH") or DEFAULT_OMARCHY_PATH)


def hash_tree(root):
    out = {}
    for folder in UPSTREAM_FOLDERS:
        for base, dirs, files in os.walk(os.path.join(root, folder)):
            dirs.sort()
            for name in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(base, d))]:
                path = os.path.join(base, name)
                rel = os.path.relpath(path, root)
                if os.path.islink(path):
                    out[rel] = "link:" + os.readlink(path)
                    continue
                h = hashlib.sha256()
                try:
                    with open(path, "rb") as f:
                        for block in iter(lambda: f.read(1 << 20), b""):
                            h.update(block)
                except OSError as e:
                    out[rel] = f"unreadable: {e.strerror}"
                    continue
                out[rel] = h.hexdigest()
    return out


def os_release():
    out = {}
    for line in (read_file("/etc/os-release") or "").splitlines():
        key, sep, value = line.partition("=")
        if sep and key in ("ID", "VERSION_ID", "VERSION_CODENAME", "PRETTY_NAME"):
            out[key] = value.strip().strip('"')
    return out


def packages():
    if shutil.which("pacman"):
        names = ["omarchy", "omarchy-settings", "hyprland", "quickshell", "uwsm", "xdg-desktop-portal-hyprland"]
        cmd = ["pacman", "-Q"] + names
    elif shutil.which("dpkg-query"):
        cmd = ["dpkg-query", "-W", "-f", "${Package} ${Version}\n", "motanka*"]
    else:
        return {}
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    for line in proc.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2:
            out[fields[0]] = fields[1]
    return out


def reference_record():
    out = {}
    for line in (read_file(os.path.join(REFERENCE_STATE, "reference.tsv")) or "").splitlines():
        key, sep, value = line.partition("\t")
        if sep:
            out[key] = value
    return out


def png_size(path):
    try:
        with open(path, "rb") as f:
            head = f.read(24)
    except OSError:
        return None
    if len(head) == 24 and head[:8] == b"\x89PNG\r\n\x1a\n":
        return {"file": os.path.basename(path), "bytes": os.path.getsize(path),
                "width": int.from_bytes(head[16:20], "big"), "height": int.from_bytes(head[20:24], "big")}
    return None


CATEGORIES = ("versions", "configerrors", "layers", "clients", "monitors", "options", "binds", "env_session",
              "env_user_manager", "dbus_names", "processes", "units_active", "units_failed", "queries", "themes",
              "commands", "command_paths", "tools", "tool_paths", "menu", "menu_when", "upstream_files",
              "errors")


def build(args):
    errors = {}
    uid = os.getuid()
    user = pwd.getpwuid(uid)
    raw = Raw(args.raw, uid, errors)
    doc = {"format": FORMAT}
    for c in CATEGORIES:
        doc[c] = {}

    for line in (raw.text("errors.tsv") or "").splitlines():
        step, _, msg = line.partition("\t")
        if step:
            errors[step] = raw.norm(msg)

    env_bytes = b""
    try:
        with open(os.path.join(args.raw, "session.env"), "rb") as f:
            env_bytes = f.read()
    except OSError:
        pass
    entries = [e.decode("utf-8", "replace") for e in env_bytes.split(b"\0") if e]
    env = {}
    for e in entries:
        name, sep, value = e.partition("=")
        if sep:
            env[name] = value
    home = env.get("HOME") or user.pw_dir

    root = upstream_root(env)
    if not args.no_session:
        collect_hyprland(raw, doc)
        collect_session(raw, doc, entries, args.own_sid)
        top, when, language = collect_menu(env, home, errors)
        doc["menu"], doc["menu_when"] = top, when
    else:
        language = "-"
    bin_dir = os.path.join(root, "bin")
    names = sorted(os.listdir(bin_dir)) if os.path.isdir(bin_dir) else []
    if not names:
        errors["commands"] = f"no Upstream bin/ under {root}"
    path = env.get("PATH") or os.environ.get("PATH", "")
    doc["commands"], doc["command_paths"] = which_all(names, path)
    doc["tools"], doc["tool_paths"] = which_all(TOOLS, path)
    doc["upstream_files"] = hash_tree(root)
    version_file = read_file(os.path.join(root, "version"))
    if version_file is not None and version_file.strip():
        doc["versions"]["upstream-version-file"] = version_file.strip().splitlines()[0]
    doc["errors"] = errors

    doc["meta"] = {
        "probe": {"format": FORMAT, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
        "os": os_release(),
        "kernel": os.uname().release,
        "user": user.pw_name,
        "upstream_root": root,
        "session_env_source": (raw.text("session.src") or "-").strip(),
        "menu_language": language,
        "screenshot": png_size(args.screenshot) if args.screenshot else None,
        "packages": packages(),
        "reference": reference_record(),
    }
    return doc


# --- first-run mode (probe.sh --wait-*) ----------------------------------

def first_line(path):
    text = read_file(path) or ""
    line = text.splitlines()[0] if text.strip() else ""
    line = " ".join(line.split())
    if len(line) > FIRST_LINE_LIMIT:
        line = line[:FIRST_LINE_LIMIT] + "…"
    return line


def first_run_status(home, ps_text, layers, files=(), namespaces=(), gone=(), own_sid=""):
    """[(reached, description)], one per condition, in the order given."""
    out = []
    for rel in files:
        path = os.path.join(home, rel)
        if not os.path.isfile(path):
            out.append((False, f"~/{rel}: missing"))
        elif os.path.getsize(path) == 0:
            out.append((False, f"~/{rel}: empty"))
        else:
            out.append((True, f"~/{rel}: {first_line(path) or '(blank first line)'}"))
    mapped = sorted({ns for _, ns in layer_surfaces(layers)})
    for ns in namespaces:
        if layers is None:
            out.append((False, f"layer {ns}: hyprctl layers gave no answer"))
        elif ns in mapped:
            out.append((True, f"layer {ns}: mapped"))
        else:
            out.append((False, f"layer {ns}: not mapped (layers: {' '.join(mapped) or 'none'})"))
    procs = []
    for line in (ps_text or "").splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[1] != own_sid:
            procs.append((fields[0], process_name(fields[2])))
    for name in gone:
        pids = [pid for pid, pname in procs if pname == name]
        if pids:
            out.append((False, f"process {name}: still running (pid {', '.join(pids)})"))
        else:
            out.append((True, f"process {name}: not running"))
    return out


def first_run_main(argv):
    p = argparse.ArgumentParser(prog="probe.py first-run",
                                description="Check whether Upstream's first-run work in the session is done.")
    p.add_argument("--home", required=True)
    p.add_argument("--ps", required=True)
    p.add_argument("--layers", required=True)
    p.add_argument("--own-sid", default="")
    p.add_argument("--file", action="append", default=[])
    p.add_argument("--layer", action="append", default=[])
    p.add_argument("--gone", action="append", default=[])
    args = p.parse_args(argv)
    for rel in args.file:
        if rel.startswith("/") or ".." in rel.split("/"):
            print(f"probe.py first-run: --file must be relative to --home, got {rel!r}", file=sys.stderr)
            return 2
    layers = None
    text = read_file(args.layers)
    if text and text.strip():
        try:
            layers = json.loads(text)
        except ValueError:
            layers = None
    status = first_run_status(args.home, read_file(args.ps), layers, args.file, args.layer, args.gone,
                              args.own_sid)
    for reached, what in status:
        print(("reached: " if reached else "pending: ") + what)
    return 0 if all(reached for reached, _ in status) else 1


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["first-run"]:
        return first_run_main(argv[1:])
    p = argparse.ArgumentParser(prog="probe.py", description=__doc__.split("\n", 1)[0])
    p.add_argument("--raw", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--own-sid", default="")
    p.add_argument("--screenshot")
    p.add_argument("--no-session", action="store_true")
    args = p.parse_args(argv)
    if not os.path.isdir(args.raw):
        print(f"probe.py: not a folder: {args.raw}", file=sys.stderr)
        return 2
    doc = build(args)
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
