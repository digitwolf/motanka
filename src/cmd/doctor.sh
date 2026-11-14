# shellcheck shell=bash
# shellcheck disable=SC2329 # functions are called by src/motanka and by the unit tests
# motanka doctor (design.md: Doctor, CLI, Error Handling; requirements 1.7,
# 11.2, 12.1-12.4, 12.6-12.9).
#
# usage: motanka doctor [--json] [--fix [--i-know-this-is-not-a-vm]]
#
# The report (12.1-12.3, 12.8, 12.9, 1.7):
#   system    release, Motanka version, development build, the apt source
#             (motanka-source-<suite> package, suite, Enabled, URI),
#             Channel, Upstream_Pin, Stack package versions (motanka-stack*,
#             motanka-stack-shell, motanka-qt6), Motanka_Apps (whether
#             motanka-apps is installed, with its version, and the last
#             apps-answer line of the System_Ledger with its time and
#             source, or none; never a problem), GPU driver as the session
#             launcher detects it (src/lib/gpu.sh), display manager (the
#             Installer's preflight functions in src/cmd/install.sh),
#             snapshot method, and the System_Ledger: recorded Ubuntu
#             packages, those no longer installed, interrupted runs
#   features_unavailable  every Upstream package whose Package_Map outcome
#             on the running release is skip, with its reason
#   shim_calls  every "unsupported call" journal entry with the identifier
#             motanka of the last 30 days (journalctl -t motanka --since
#             "30 days ago")
#   home      the User_Ledger of the user: ledgered paths that are missing
#             or changed since Motanka wrote them (Namespaced_Paths, which
#             session programs rewrite, are checked for missing only), a
#             pending session capture, unplanned entries and observed
#             desktop paths
#   problems  what keeps Motanka from working, each with its fix command:
#             a suite that is not the running release's, a disabled or
#             missing source, Motanka packages built for the other release,
#             an unsupported release, GPU driver or display manager, and
#             interrupted runs
#   skipped   the parts that were not read, and why
# --json prints the same report as one JSON document on one line (12.7),
# built by python3's json module. The text and the JSON come from the same
# records, so they hold the same fields.
#
# Who reads what. As a normal user: the user's own home folder, and the
# system parts that need no privilege; the journal of other users is read
# only by members of systemd-journal or adm, and the snapshots and snapper's
# configuration only by root (both listed as skipped). As root (sudo): every
# system part, and the home folder of SUDO_USER, read as that user through
# setpriv; without SUDO_USER the home part is skipped.
#
# Without --fix the Doctor changes nothing: no file, no package, no ledger
# line, no lock (12.4). It prints paths, package names and versions, never
# file contents from home folders (12.6): ledgered files are compared by
# their SHA-256, links by the SHA-256 of their target.
#
# --fix (11.2), as root, after the guards (Protected_Host; a Dev_Build
# outside a VM unless --i-know-this-is-not-a-vm) and the system lock: when
# the apt source does not name the running release's suite of its Channel,
# is disabled (a release upgrade adds "Enabled: no", spike S4), or is
# missing:
#   1. downloads motanka-source-<release suite> and verifies it against the
#      signed SHA256SUMS of the Motanka_Repo (src/lib/aptsim.sh); the
#      repository is MOTANKA_APT_URI, else the URI of the current
#      motanka.sources, else the default
#   2. dpkg --force-depends --purge every motanka-source-* package dpkg
#      knows, so their locally modified conffile goes too (installing over
#      it would keep the disabled file); --force-depends because the
#      motanka metapackage depends on a motanka-source package, which step 3
#      provides again
#   3. dpkg --install --force-confnew of the verified package (and of the
#      keyring package when it is not installed)
#   4. checks that motanka.sources names the suite and is enabled, then
#      apt-get update, and that apt lists the signed Motanka suite
# Nothing else changes. An interrupted --fix is completed by running it
# again: a missing source is installed the same way. The report follows.
#
# Exit codes: 0 report printed (and --fix switched the source or had
# nothing to fix); 1 error, also when apt-get update failed after the
# switch; 2 usage; 3 the running release has no Motanka suite (--fix);
# 6 verification failed (--fix); 7 guard refused (--fix); 9 lock held
# (--fix); 11 --fix without root.
#
# Test hooks: MOTANKA_ROOT (common.sh) for every system path; users of
# SUDO_USER then come from $MOTANKA_ROOT/etc/passwd. dpkg, dpkg-query,
# apt-get, apt-cache, journalctl, snapper and id are found through PATH.

if [[ -n ${MK_DOCTOR_LOADED:-} ]]; then
  return 0
fi
MK_DOCTOR_LOADED=1

_mk_dr_base=${MK_LIBEXEC:-}
if [[ -z $_mk_dr_base ]]; then
  _mk_dr_base=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
# shellcheck source=../lib/common.sh
source "$_mk_dr_base/lib/common.sh"
# shellcheck source=../lib/guard.sh
source "$_mk_dr_base/lib/guard.sh"
# shellcheck source=../lib/sysledger.sh
source "$_mk_dr_base/lib/sysledger.sh"
# shellcheck source=../lib/aptsim.sh
source "$_mk_dr_base/lib/aptsim.sh"
# shellcheck source=../lib/userledger.sh
source "$_mk_dr_base/lib/userledger.sh"
# shellcheck source=../lib/homepaths.sh
source "$_mk_dr_base/lib/homepaths.sh"
# shellcheck source=../lib/capture.sh
source "$_mk_dr_base/lib/capture.sh"
# shellcheck source=../lib/snapshot.sh
source "$_mk_dr_base/lib/snapshot.sh"
# shellcheck source=../lib/gpu.sh
source "$_mk_dr_base/lib/gpu.sh"
# The display manager checks of the Installer's preflight (read-only
# functions; sourcing the file runs nothing).
# shellcheck source=install.sh
source "$_mk_dr_base/cmd/install.sh"

readonly MK_DR_SOURCES=/etc/apt/sources.list.d/motanka.sources
readonly MK_DR_SHARE=/opt/motanka/share/motanka
readonly MK_DR_JOURNAL_SINCE="30 days ago"
readonly MK_DR_TIME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
readonly MK_DR_FIX_CMD="sudo motanka doctor --fix"
readonly MK_DR_PKG_RE='^[a-z0-9][a-z0-9+.-]*$'
readonly -a MK_DR_STACK_PKGS=(motanka-stack motanka-stack-libs motanka-stack-hyprland
  motanka-stack-tools motanka-stack-shell motanka-qt6)

MK_JSON=0 MK_FIX=0
MK_DR_ROOT=0
MK_DR_HOME="" MK_DR_USER=""
MK_DR_OS_ID="" MK_DR_OS_VERSION="" MK_DR_OS_CODENAME="" MK_DR_OS_PRETTY=""
MK_DR_SUPPORTED=0
declare -gA MK_DR_PKG_ST=() MK_DR_PKG_VER=()
MK_DR_SRC_PRESENT=0 MK_DR_SRC_SUITE="" MK_DR_SRC_ENABLED=1 MK_DR_SRC_URI=""
MK_DR_PROB_ID=() MK_DR_PROB_MSG=() MK_DR_PROB_FIX=()
MK_DR_SKIP_PART=() MK_DR_SKIP_REASON=()
MK_DR_FIX_ACTION="" MK_DR_FIX_MSG="" MK_DR_FIX_TO="" MK_DR_FIX_SUITE="" MK_DR_FIX_APT=""
MK_DR_FIX_FROM=()

# The report builder: reads the records on stdin (see _mk_dr_rec) and
# prints the text report or the JSON document; also reads the journal.
#   python3 -I -c "$MK_DR_PY" text|json     < records
#   python3 -I -c "$MK_DR_PY" journal <since>   prints shim_calls records
#   python3 -I -c "$MK_DR_PY" string <value>    one JSON string
IFS= read -r -d '' MK_DR_PY <<'PY' || true
import json
import subprocess
import sys
from datetime import datetime, timezone

MARK = "unsupported call: "
FIELD_OPS = {"f": "s", "F": "i", "B": "b", "Z": "z"}


def clean(value):
    """Text for a terminal: control characters become '?'."""
    if value is None:
        return ""
    return "".join("?" if ord(c) < 32 or 127 <= ord(c) < 160 else c for c in str(value))


def convert(op, val):
    if op == "s":
        return val
    if op == "i":
        return int(val)
    if op == "b":
        return val == "true"
    if op == "z":
        return None
    raise ValueError("unknown value type %r" % op)


def build(data):
    """The report from NUL-separated <op> <key> <value> records."""
    parts = data.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    if len(parts) % 3:
        raise ValueError("incomplete record")
    doc, obj = {}, None
    for i in range(0, len(parts), 3):
        op, key, val = (p.decode("utf-8", "replace") for p in parts[i:i + 3])
        if op in FIELD_OPS:
            if obj is None:
                raise ValueError("field %r outside an object" % key)
            obj[key] = convert(FIELD_OPS[op], val)
            continue
        *path, leaf = key.split(".")
        node = doc
        for name in path:
            child = node.get(name)
            if not isinstance(child, dict):
                child = node[name] = {}
            node = child
        if op in ("s", "i", "b", "z"):
            node[leaf] = convert(op, val)
        elif op in ("l", "a", "o"):
            items = node.get(leaf)
            if not isinstance(items, list):
                items = node[leaf] = []
            if op == "a":
                items.append(val)
            elif op == "o":
                obj = {}
                items.append(obj)
        else:
            raise ValueError("unknown record %r" % op)
    return doc


# --- journal -------------------------------------------------------------------


def field_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        if value and all(isinstance(x, int) for x in value):
            return bytes(x & 0xFF for x in value).decode("utf-8", "replace")
        for x in value:
            text = field_text(x)
            if text is not None:
                return text
    if isinstance(value, int):
        return str(value)
    return None


def iso(usec):
    try:
        t = int(usec) / 1e6
        return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def journal(since):
    out = sys.stdout.buffer

    def rec(op, key, val=""):
        val = str(val).replace("\0", "\ufffd")
        out.write(op.encode() + b"\0" + key.encode() + b"\0" + val.encode("utf-8", "replace") + b"\0")

    cmd = ["journalctl", "-t", "motanka", "--since", since, "-o", "json", "--no-pager", "-q"]
    error, lines = None, []
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=300, check=False)
        if p.returncode == 0:
            lines = p.stdout.splitlines()
        else:
            msg = p.stderr.decode("utf-8", "replace").strip().splitlines()
            error = "journalctl exited with %d%s" % (p.returncode, ": " + msg[0] if msg else "")
    except FileNotFoundError:
        error = "journalctl is not installed"
    except subprocess.TimeoutExpired:
        error = "journalctl did not finish within 300 s"
    calls = []
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        msg = field_text(entry.get("MESSAGE"))
        if msg is None or MARK not in msg:
            continue
        calls.append((iso(field_text(entry.get("__REALTIME_TIMESTAMP"))) or "",
                      msg[msg.index(MARK) + len(MARK):],
                      field_text(entry.get("_UID")) or ""))
    calls.sort(key=lambda c: c[0])
    rec("s", "shim_calls.since", since)
    rec("b", "shim_calls.read", "false" if error else "true")
    if error:
        rec("s", "shim_calls.error", error)
    rec("l", "shim_calls.calls")
    for when, call, uid in calls:
        rec("o", "shim_calls.calls")
        if when:
            rec("f", "time", when)
        else:
            rec("Z", "time")
        rec("f", "call", call)
        if uid.isdigit():
            rec("F", "uid", uid)
        else:
            rec("Z", "uid")


# --- text report ---------------------------------------------------------------


def line(label, value):
    label += ":"
    return "  " + label.ljust(18) + ("" if len(label) < 18 else " ") + value


def more(value):
    return "  " + " " * 18 + value


def release_name(rel):
    if rel.get("version_id") and rel.get("codename"):
        return "Ubuntu %s (%s)" % (clean(rel["version_id"]), clean(rel["codename"]))
    return clean(rel.get("pretty_name") or "this release")


def text_system(o, s):
    rel = s.get("release") or {}
    v = clean(rel.get("pretty_name") or "unknown release")
    if rel.get("codename"):
        v += " (%s)" % clean(rel["codename"])
    if rel.get("supported"):
        v += ", supported"
    else:
        v += ", not supported (Motanka supports Ubuntu 24.04 LTS and Ubuntu 26.04 LTS)"
    o.append(line("release", v))

    m = s.get("motanka") or {}
    if m.get("installed"):
        v = clean(m.get("version"))
        if m.get("core_version") and m.get("core_version") != m.get("version"):
            v += " (motanka-core %s)" % clean(m["core_version"])
        if m.get("dev_build"):
            v += ", development build"
    else:
        v = "not installed"
    o.append(line("Motanka", v))

    r = s.get("repository") or {}
    pk = ", ".join(
        clean(x.get("package")) + ("" if x.get("status") == "installed" else " (%s)" % clean(x.get("status")))
        for x in r.get("source_packages") or [])
    if r.get("file_present"):
        v = "suite %s, %s" % (clean(r.get("suite") or "none"),
                              "enabled" if r.get("enabled") else "disabled (Enabled: no)")
        if r.get("uri"):
            v += ", " + clean(r["uri"])
        v += "; package " + (pk or "none")
    else:
        v = "none (%s does not exist)" % clean(r.get("file"))
        if pk:
            v += "; package " + pk
    o.append(line("apt source", v))
    o.append(line("channel", clean(s.get("channel") or "unknown")))

    pin = s.get("upstream_pin")
    if isinstance(pin, dict) and pin.get("commit"):
        v = clean(pin["commit"])
        if pin.get("tag"):
            v += " (%s)" % clean(pin["tag"])
        v += ", %s channel" % clean(pin.get("channel"))
    else:
        v = "unknown (no upstream.pin; motanka-core is not installed)"
    o.append(line("Upstream pin", v))

    stack = s.get("stack") or []
    have = ["%s %s" % (clean(x.get("package")), clean(x.get("version"))) for x in stack if x.get("installed")]
    lack = [clean(x.get("package")) for x in stack if not x.get("installed")]
    o.append(line("Stack", ", ".join(have) if have else "not installed"))
    if have and lack:
        o.append(more("not installed: " + ", ".join(lack)))

    a = s.get("apps") or {}
    v = "installed (%s)" % clean(a.get("version")) if a.get("installed") else "not installed"
    if not a.get("ledger_read"):
        v += "; the recorded answer was not read (see Skipped)"
    elif a.get("answer"):
        src = a.get("answer_source")
        if src == "flag":
            how = "by --apps" if a["answer"] == "yes" else "by --no-apps"
        elif src == "question":
            how = "at the question"
        else:
            how = "by default (--yes without --apps, or no terminal to ask on)"
        v += "; last answer: %s, %s, on %s" % (clean(a["answer"]), how, clean(a.get("answer_time")))
    else:
        v += "; no answer recorded"
    o.append(line("motanka-apps", v))

    g = s.get("gpu") or {}
    cards = []
    for c in g.get("cards") or []:
        drv = clean(c.get("driver"))
        if c.get("driver") == "nvidia" and g.get("nvidia_version"):
            drv += " " + clean(g["nvidia_version"])
        cards.append("%s (%s, %s)" % (clean(c.get("card")), drv, clean(c.get("status"))))
    v = ", ".join(cards) or "no DRM card"
    v += "; the Motanka session can start" if g.get("supported") else "; " + clean(g.get("reason"))
    o.append(line("GPU", v))

    dm = s.get("display_manager") or {}
    if dm.get("name"):
        v = clean(dm["name"])
        v += ", Wayland sessions enabled" if dm.get("wayland") else ": " + clean(dm.get("problem"))
    else:
        v = "none found"
    o.append(line("display manager", v))

    sn = s.get("snapshots") or {}
    v = clean(sn.get("description"))
    sp = sn.get("snapper") or {}
    if not sp.get("checked"):
        v += "; snapper: not checked (needs root)"
    elif sp.get("config"):
        v += "; and a snapper pre and post pair of the config %s" % clean(sp["config"])
    else:
        v += "; snapper: no configuration for /"
    o.append(line("snapshot method", v))
    if sn.get("count") is not None:
        v = "%d kept" % sn["count"]
        if sn.get("latest"):
            v += ", latest " + clean(sn["latest"])
        o.append(line("snapshots", v))

    sl = s.get("system_ledger") or {}
    if not sl.get("read"):
        v = "not read (see Skipped)"
    elif not sl.get("present"):
        v = "none (%s does not exist)" % clean(sl.get("file"))
    else:
        v = "%s: %d Ubuntu package(s) recorded" % (clean(sl.get("file")), sl.get("packages") or 0)
        gone = sl.get("packages_missing") or []
        if gone:
            v += ", %d of them no longer installed (%s)" % (len(gone), ", ".join(clean(x) for x in gone))
        runs = sl.get("incomplete_runs") or []
        v += "; interrupted runs: " + (", ".join(clean(x) for x in runs) if runs else "none")
    o.append(line("System_Ledger", v))


def text_home(o, h):
    o.append("Home folder of %s (%s):" % (clean(h.get("user")), clean(h.get("path"))))
    if h.get("user_ledger"):
        f, hp = h.get("ledger_file") or "", h.get("path") or ""
        rel = "~/" + f[len(hp) + 1:] if hp and f.startswith(hp + "/") else f
        o.append(line("User_Ledger", "%s (%d entries)" % (clean(rel), h.get("entries") or 0)))
    else:
        o.append(line("User_Ledger", "none (this account has not logged into the Motanka session)"))
    cap = h.get("session_capture") or {}
    if cap.get("pending"):
        o.append(line("session capture", "pending since %s (ended when the session ends, at the next login or by motanka remove)"
                      % clean(cap.get("since"))))
    else:
        o.append(line("session capture", "none pending"))
    gone = h.get("missing") or []
    o.append(line("missing", "%d ledgered path(s) Motanka wrote are gone" % len(gone)))
    for x in gone:
        o.append("    ~/%s (%s)" % (clean(x.get("path")), clean(x.get("entry"))))
    changed = h.get("changed") or []
    o.append(line("changed", "%d ledgered path(s) differ from what Motanka wrote (Namespaced_Paths are not compared)"
                  % len(changed)))
    for x in changed:
        o.append("    ~/%s (%s)" % (clean(x.get("path")), clean(x.get("entry"))))
    unplanned = h.get("unplanned") or []
    o.append(line("unplanned", "%d path(s) changed without a ledger entry; motanka remove leaves them" % len(unplanned)))
    for p in unplanned:
        o.append("    ~/%s" % clean(p))
    desktop = h.get("desktop") or []
    o.append(line("desktop", "%d path(s) written by Ubuntu's session components; motanka remove leaves them"
                  % len(desktop)))
    for p in desktop:
        o.append("    ~/%s" % clean(p))


def text(d):
    o = []
    ra = d.get("running_as") or {}
    o.append("Motanka doctor, running as %s%s" % (clean(ra.get("user")), " (root)" if ra.get("root") else ""))
    fix = d.get("fix")
    if isinstance(fix, dict):
        o.append("")
        o.append("Fix: " + clean(fix.get("message")))
    s = d.get("system") or {}
    o.append("")
    o.append("System:")
    text_system(o, s)

    o.append("")
    o.append("Problems:")
    problems = d.get("problems") or []
    if not problems:
        o.append("  none found")
    for p in problems:
        o.append("  - " + clean(p.get("message")))
        if p.get("fix"):
            o.append("    fix: " + clean(p["fix"]))

    feats = d.get("features_unavailable")
    if isinstance(feats, list):
        o.append("")
        o.append("Not available on %s: %d package(s) of Upstream's package lists (Package_Map outcome skip):"
                 % (release_name(s.get("release") or {}), len(feats)))
        groups = {}
        for f in feats:
            groups.setdefault(f.get("reason") or "", []).append(f.get("package") or "")
        for reason, names in groups.items():
            o.append("  %s: %s" % (clean(reason), ", ".join(clean(n) for n in names)))

    sc = d.get("shim_calls") or {}
    since = clean(sc.get("since") or "")
    period = "the last " + since[:-4] if since.endswith(" ago") else "since " + since
    o.append("")
    if not sc.get("read"):
        o.append("Unsupported shim calls in %s: not read: %s" % (period, clean(sc.get("error"))))
    else:
        calls = sc.get("calls") or []
        o.append("Unsupported shim calls in %s: %d" % (period, len(calls)))
        groups = {}
        for c in calls:
            g = groups.setdefault(c.get("call") or "", [0, ""])
            g[0] += 1
            g[1] = c.get("time") or g[1]
        for call, (n, last) in groups.items():
            o.append("  %dx  %s%s" % (n, clean(call), "  (last %s)" % clean(last) if last else ""))
        if not sc.get("complete"):
            o.append("  (only the journal entries this user may read; see Skipped)")

    skipped = d.get("skipped") or []
    if skipped:
        o.append("")
        o.append("Skipped:")
        for x in skipped:
            o.append("  - %s: %s" % (clean(x.get("part")), clean(x.get("reason"))))

    h = d.get("home")
    if isinstance(h, dict):
        o.append("")
        text_home(o, h)
    return "\n".join(o) + "\n"


def main(argv):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "string" and len(argv) == 3:
        sys.stdout.write(json.dumps(argv[2]))
        return 0
    if mode == "journal" and len(argv) == 3:
        journal(argv[2])
        return 0
    if mode in ("text", "json") and len(argv) == 2:
        try:
            doc = build(sys.stdin.buffer.read())
        except ValueError as e:
            sys.stderr.write("motanka doctor: invalid report records: %s\n" % e)
            return 1
        sys.stdout.write(json.dumps(doc) + "\n" if mode == "json" else text(doc))
        return 0
    sys.stderr.write("usage: report text|json | journal <since> | string <value>\n")
    return 2


sys.exit(main(sys.argv))
PY
readonly MK_DR_PY

mk_doctor_usage() {
  cat <<'EOF'
usage: motanka doctor [--json] [--fix [--i-know-this-is-not-a-vm]]

Reports Motanka's state: release, Motanka version, channel, Upstream pin,
Stack versions, motanka-apps and the recorded answer about it, GPU
driver, display manager, snapshot method, features not
available on this release, unsupported shim calls of the last 30 days, and
the home folder's ledgered, missing, changed, unplanned and desktop paths.
Changes nothing unless --fix is given.

  --json      print the report as one JSON document
  --fix       as root: switch the Motanka apt source to the suite of the
              running release (after a release upgrade), then report
  --i-know-this-is-not-a-vm
              with --fix on a development build: run outside a VM
  -h, --help  show this help

Run as your user for your home folder; run with sudo for the parts that
need root (snapshots, the whole journal) and your home folder.
EOF
}

# --- records --------------------------------------------------------------------

# _mk_dr_rec <op> <key> [value]: one record of the report on stdout, three
# NUL-terminated fields. <op>: s string, i integer, b true/false, z null,
# l an empty list, a a string appended to a list, o a new object appended
# to a list; f, F, B, Z set a string, integer, boolean or null field of the
# newest object. Keys are dotted paths (system.release.codename).
_mk_dr_rec() {
  printf '%s\0%s\0%s\0' "$1" "$2" "${3-}"
}

# _mk_dr_str <key> <value>: a string, or null when the value is empty.
_mk_dr_str() {
  if [[ -n ${2-} ]]; then
    _mk_dr_rec s "$1" "$2"
  else
    _mk_dr_rec z "$1"
  fi
}

# _mk_dr_bool <key> <0|1>
_mk_dr_bool() {
  if (($2)); then
    _mk_dr_rec b "$1" true
  else
    _mk_dr_rec b "$1" false
  fi
}

# _mk_dr_json_string <value>: the value as a JSON string.
_mk_dr_json_string() {
  python3 -I -c "$MK_DR_PY" string "$1"
}

# _mk_dr_problem <id> <message> [fix]
_mk_dr_problem() {
  MK_DR_PROB_ID+=("$1")
  MK_DR_PROB_MSG+=("$2")
  MK_DR_PROB_FIX+=("${3:-}")
}

# _mk_dr_skip <part> <reason>
_mk_dr_skip() {
  MK_DR_SKIP_PART+=("$1")
  MK_DR_SKIP_REASON+=("$2")
}

# --- state of the system ---------------------------------------------------------

# _mk_dr_read_release: MK_DR_OS_* from os-release and MK_DR_SUPPORTED, by
# the Installer's rule (1.4).
_mk_dr_read_release() {
  local f want=""
  MK_DR_OS_ID="" MK_DR_OS_VERSION="" MK_DR_OS_CODENAME="" MK_DR_OS_PRETTY="" MK_DR_SUPPORTED=0
  f=$(mk_path /etc/os-release)
  if [[ ! -r $f ]]; then
    f=$(mk_path /usr/lib/os-release)
  fi
  if [[ -r $f ]]; then
    MK_DR_OS_ID=$(_mk_pf_os_release "$f" ID)
    MK_DR_OS_VERSION=$(_mk_pf_os_release "$f" VERSION_ID)
    MK_DR_OS_CODENAME=$(_mk_pf_os_release "$f" VERSION_CODENAME)
    MK_DR_OS_PRETTY=$(_mk_pf_os_release "$f" PRETTY_NAME)
  fi
  if [[ $MK_DR_OS_ID == ubuntu ]]; then
    case $MK_DR_OS_CODENAME in
      noble) want=24.04 ;;
      resolute) want=26.04 ;;
    esac
  fi
  if [[ -n $want ]] && [[ -z $MK_DR_OS_VERSION || $MK_DR_OS_VERSION == "$want" ]]; then
    MK_DR_SUPPORTED=1
  fi
}

# _mk_dr_read_packages: status and version of every Motanka_Package dpkg
# knows (MK_DR_PKG_ST, MK_DR_PKG_VER).
_mk_dr_read_packages() {
  local name st ver
  MK_DR_PKG_ST=() MK_DR_PKG_VER=()
  while IFS=$'\t' read -r name st ver; do
    name=${name%%:*}
    if [[ $name != motanka && $name != motanka-* ]] || [[ ! $name =~ $MK_DR_PKG_RE ]]; then
      continue
    fi
    if [[ -z $st || $st == not-installed ]]; then
      continue
    fi
    MK_DR_PKG_ST[$name]=$st
    MK_DR_PKG_VER[$name]=$ver
  done < <(
    # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
    dpkg-query -W -f='${Package}\t${db:Status-Status}\t${Version}\n' motanka 'motanka-*' 2>/dev/null || true
  )
}

# _mk_dr_installed <package>: 0 if dpkg has the package installed.
_mk_dr_installed() {
  [[ ${MK_DR_PKG_ST[$1]:-} == installed ]]
}

# _mk_dr_read_source: motanka.sources, read as the Updater reads it (the
# first occurrence of each field): MK_DR_SRC_PRESENT, MK_DR_SRC_SUITE
# (first suite), MK_DR_SRC_ENABLED (0 for "Enabled: no") and MK_DR_SRC_URI
# (first URI).
_mk_dr_read_source() {
  local f key val
  MK_DR_SRC_PRESENT=0 MK_DR_SRC_SUITE="" MK_DR_SRC_ENABLED=1 MK_DR_SRC_URI=""
  f=$(mk_path "$MK_DR_SOURCES")
  if [[ ! -f $f || ! -r $f ]]; then
    return 0
  fi
  MK_DR_SRC_PRESENT=1
  while IFS=$'\t' read -r key val; do
    case $key in
      suites) MK_DR_SRC_SUITE=$val ;;
      uris) MK_DR_SRC_URI=$val ;;
      enabled)
        if [[ ${val,,} == no ]]; then
          MK_DR_SRC_ENABLED=0
        fi
        ;;
    esac
  done < <(awk '
    { sub(/\r$/, "") }
    /^#/ || /^[ \t]/ { next }
    {
      i = index($0, ":")
      if (i == 0) next
      k = tolower(substr($0, 1, i - 1)); v = substr($0, i + 1)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (k == "suites" || k == "uris") { split(v, w, /[ \t]+/); v = w[1] }
      if ((k == "suites" || k == "uris" || k == "enabled") && !(k in seen)) { seen[k] = 1; print k "\t" v }
    }' "$f")
}

# _mk_dr_source_packages: the motanka-source-* packages dpkg knows, sorted.
_mk_dr_source_packages() {
  local p
  for p in "${!MK_DR_PKG_ST[@]}"; do
    if [[ $p == motanka-source-* ]]; then
      printf '%s\n' "$p"
    fi
  done | LC_ALL=C sort
}

# _mk_dr_channel: the Channel of the apt source (edge for a suite or a
# source package ending in -edge), or nothing when there is none.
_mk_dr_channel() {
  local p ch=""
  if [[ -n $MK_DR_SRC_SUITE ]]; then
    if [[ $MK_DR_SRC_SUITE == *-edge ]]; then
      printf 'edge\n'
    else
      printf 'stable\n'
    fi
    return 0
  fi
  while IFS= read -r p; do
    if [[ $p == *-edge ]]; then
      ch=edge
    elif [[ -z $ch ]]; then
      ch=stable
    fi
  done < <(_mk_dr_source_packages)
  if [[ -n $ch ]]; then
    printf '%s\n' "$ch"
  fi
}

# _mk_dr_suite_ok: 0 when the apt source names the running release's suite
# (either Channel).
_mk_dr_suite_ok() {
  [[ -n $MK_DR_OS_CODENAME ]] &&
    [[ $MK_DR_SRC_SUITE == "$MK_DR_OS_CODENAME" || $MK_DR_SRC_SUITE == "$MK_DR_OS_CODENAME-edge" ]]
}

# --- the system part of the report -------------------------------------------------

_mk_dr_emit_release() {
  _mk_dr_str system.release.id "$MK_DR_OS_ID"
  _mk_dr_str system.release.version_id "$MK_DR_OS_VERSION"
  _mk_dr_str system.release.codename "$MK_DR_OS_CODENAME"
  _mk_dr_str system.release.pretty_name "$MK_DR_OS_PRETTY"
  _mk_dr_bool system.release.supported "$MK_DR_SUPPORTED"
  if ((!MK_DR_SUPPORTED)); then
    _mk_dr_problem release-unsupported "this system runs ${MK_DR_OS_PRETTY:-an unknown release} (ID=${MK_DR_OS_ID:-none}, VERSION_CODENAME=${MK_DR_OS_CODENAME:-none}); Motanka supports Ubuntu 24.04 LTS (noble) and Ubuntu 26.04 LTS (resolute)"
  fi
}

_mk_dr_emit_motanka() {
  local installed=0 version="" core="" dev=0
  if _mk_dr_installed motanka || _mk_dr_installed motanka-core; then
    installed=1
  fi
  if _mk_dr_installed motanka; then
    version=${MK_DR_PKG_VER[motanka]}
  fi
  if _mk_dr_installed motanka-core; then
    core=${MK_DR_PKG_VER[motanka-core]}
  fi
  if mk_guard_is_dev_build; then
    dev=1
  fi
  _mk_dr_bool system.motanka.installed "$installed"
  _mk_dr_str system.motanka.version "${version:-$core}"
  _mk_dr_str system.motanka.core_version "$core"
  _mk_dr_bool system.motanka.dev_build "$dev"
}

# _mk_dr_emit_repository: the apt source, its Channel and the suite
# problems (11.5).
_mk_dr_emit_repository() {
  local p ch matches=0 any=0
  _mk_dr_rec s system.repository.file "$MK_DR_SOURCES"
  _mk_dr_bool system.repository.file_present "$MK_DR_SRC_PRESENT"
  _mk_dr_str system.repository.suite "$MK_DR_SRC_SUITE"
  if ((MK_DR_SRC_PRESENT)); then
    _mk_dr_bool system.repository.enabled "$MK_DR_SRC_ENABLED"
    if _mk_dr_suite_ok; then
      matches=1
    fi
    _mk_dr_bool system.repository.matches_release "$matches"
  else
    _mk_dr_rec z system.repository.enabled
    _mk_dr_rec z system.repository.matches_release
  fi
  _mk_dr_str system.repository.uri "$MK_DR_SRC_URI"
  _mk_dr_rec l system.repository.source_packages
  while IFS= read -r p; do
    any=1
    _mk_dr_rec o system.repository.source_packages
    _mk_dr_rec f package "$p"
    _mk_dr_rec f status "${MK_DR_PKG_ST[$p]}"
    _mk_dr_rec f version "${MK_DR_PKG_VER[$p]}"
  done < <(_mk_dr_source_packages)
  ch=$(_mk_dr_channel)
  _mk_dr_str system.channel "$ch"

  if ! _mk_dr_installed motanka-core && ((!any && !MK_DR_SRC_PRESENT)); then
    return 0
  fi
  if ((!MK_DR_SRC_PRESENT)); then
    _mk_dr_problem source-missing "there is no Motanka apt source ($MK_DR_SOURCES), so Motanka gets no updates" "$MK_DR_FIX_CMD"
    return 0
  fi
  if ((MK_DR_SUPPORTED)) && ! _mk_dr_suite_ok; then
    _mk_dr_problem suite-mismatch "the Motanka apt source names the suite '${MK_DR_SRC_SUITE:-none}', but this system runs Ubuntu $MK_DR_OS_VERSION ($MK_DR_OS_CODENAME); 'motanka update' refuses to run until the source names the suite of this release" "$MK_DR_FIX_CMD"
  fi
  if ((!MK_DR_SRC_ENABLED)); then
    _mk_dr_problem source-disabled "the Motanka apt source is disabled (Enabled: no in $MK_DR_SOURCES), as a release upgrade leaves it" "$MK_DR_FIX_CMD"
  fi
}

# _mk_dr_emit_other_release: Motanka packages built for another release
# than the running one (left by a release upgrade until 'motanka update').
_mk_dr_emit_other_release() {
  local p fix="sudo motanka update"
  local -a other=()
  local re='~ubuntu([0-9]+\.[0-9]+)\.'
  if ((!MK_DR_SUPPORTED)) || [[ -z $MK_DR_OS_VERSION ]]; then
    return 0
  fi
  for p in "${!MK_DR_PKG_ST[@]}"; do
    if _mk_dr_installed "$p" && [[ ${MK_DR_PKG_VER[$p]} =~ $re ]] && [[ ${BASH_REMATCH[1]} != "$MK_DR_OS_VERSION" ]]; then
      other+=("$p")
    fi
  done
  if ((${#other[@]} == 0)); then
    return 0
  fi
  mapfile -t other < <(printf '%s\n' "${other[@]}" | LC_ALL=C sort)
  if ((!MK_DR_SRC_PRESENT || !MK_DR_SRC_ENABLED)) || ! _mk_dr_suite_ok; then
    fix="$MK_DR_FIX_CMD, then sudo motanka update"
  fi
  _mk_dr_problem packages-other-release "${#other[@]} Motanka package(s) are builds for another Ubuntu release than $MK_DR_OS_VERSION: ${other[*]}" "$fix"
}

_mk_dr_emit_pin() {
  local pin ch line commit tag
  ch=$(_mk_dr_channel)
  ch=${ch:-stable}
  pin=$(mk_path "$MK_DR_SHARE/upstream.pin")
  line=""
  if [[ -r $pin ]]; then
    line=$(awk -F'\t' -v c="$ch" '$1 == c { print $2 "\t" $3; exit }' "$pin" 2>/dev/null || true)
  fi
  IFS=$'\t' read -r commit tag <<<"$line"
  if [[ ! ${commit:-} =~ ^[0-9a-f]{40}$ ]]; then
    _mk_dr_rec z system.upstream_pin
    return 0
  fi
  if [[ ${tag:-} == - ]]; then
    tag=""
  fi
  _mk_dr_rec s system.upstream_pin.channel "$ch"
  _mk_dr_rec s system.upstream_pin.commit "$commit"
  _mk_dr_str system.upstream_pin.tag "${tag:-}"
}

_mk_dr_emit_stack() {
  local p
  _mk_dr_rec l system.stack
  for p in "${MK_DR_STACK_PKGS[@]}"; do
    _mk_dr_rec o system.stack
    _mk_dr_rec f package "$p"
    if _mk_dr_installed "$p"; then
      _mk_dr_rec B installed true
      _mk_dr_rec f version "${MK_DR_PKG_VER[$p]}"
    else
      _mk_dr_rec B installed false
      _mk_dr_rec Z version
    fi
  done
}

# _mk_dr_emit_apps: whether motanka-apps is installed, and the last answer
# to the Motanka_Apps question the System_Ledger recorded (12.9). A
# report, never a problem. An unreadable System_Ledger is listed as
# skipped by _mk_dr_emit_sysledger.
_mk_dr_emit_apps() {
  local file line="" t="" answer="" src="" readable=1
  if _mk_dr_installed motanka-apps; then
    _mk_dr_rec b system.apps.installed true
    _mk_dr_rec s system.apps.version "${MK_DR_PKG_VER["motanka-apps"]}"
  else
    _mk_dr_rec b system.apps.installed false
    _mk_dr_rec z system.apps.version
  fi
  file=$(mk_sysledger_file)
  if [[ -e $file && ! -r $file ]]; then
    readable=0
  elif [[ -e $file ]]; then
    line=$(mk_sysledger_last_apps_answer "$file" 2>/dev/null) || line=""
  fi
  if [[ -n $line ]]; then
    IFS=$'\t' read -r t answer src <<<"$line"
  fi
  _mk_dr_bool system.apps.ledger_read "$readable"
  _mk_dr_str system.apps.answer "$answer"
  _mk_dr_str system.apps.answer_time "$t"
  _mk_dr_str system.apps.answer_source "$src"
}

# _mk_dr_emit_gpu: the session launcher's verdict (src/lib/gpu.sh).
_mk_dr_emit_gpu() {
  local ok=1 c name drv status
  if ! mk_gpu_scan; then
    ok=0
  fi
  _mk_dr_rec l system.gpu.cards
  for c in "${MK_GPU_CARDS[@]}"; do
    IFS=$'\t' read -r name drv status <<<"$c"
    _mk_dr_rec o system.gpu.cards
    _mk_dr_rec f card "$name"
    _mk_dr_rec f driver "$drv"
    _mk_dr_rec f status "$status"
  done
  _mk_dr_bool system.gpu.supported "$ok"
  _mk_dr_str system.gpu.reason "$MK_GPU_REASON"
  _mk_dr_str system.gpu.nvidia_version "$MK_GPU_NVIDIA_VERSION"
  if ((!ok)); then
    _mk_dr_problem gpu-unsupported "the Motanka session would not start: ${MK_GPU_REASON#refused: }"
  fi
}

# _mk_dr_emit_dm: the display manager, as the Installer's preflight sees
# it (2.7).
_mk_dr_emit_dm() {
  local dm problem="" wayland=1
  dm=$(mk_preflight_detect_dm 2>/dev/null || true)
  case $dm in
    "") ;;
    gdm3 | sddm | lightdm)
      if problem=$(_mk_pf_wayland_problem "$dm"); then
        wayland=0
      else
        problem=""
      fi
      ;;
    *)
      wayland=0
      problem="not supported; the Motanka session needs GDM, SDDM or LightDM"
      ;;
  esac
  _mk_dr_str system.display_manager.name "$dm"
  if [[ -n $dm ]]; then
    _mk_dr_bool system.display_manager.wayland "$wayland"
  else
    _mk_dr_rec z system.display_manager.wayland
  fi
  _mk_dr_str system.display_manager.problem "$problem"
  if [[ -n $problem ]]; then
    _mk_dr_problem display-manager "display manager $dm: $problem"
  fi
}

_mk_dr_emit_snapshots() {
  local cfg="" latest="" n=0 method=config-archive id
  _mk_dr_rec s system.snapshots.description "Motanka's Config_Archive before every update: the installed Motanka packages with their .debs and an archive of each user's ledgered files, in /var/lib/motanka/snapshots"
  if ((!MK_DR_ROOT)); then
    _mk_dr_rec s system.snapshots.method "$method"
    _mk_dr_rec b system.snapshots.snapper.checked false
    _mk_dr_rec z system.snapshots.snapper.config
    _mk_dr_rec z system.snapshots.count
    _mk_dr_rec z system.snapshots.latest
    _mk_dr_skip snapshots "the snapshots in /var/lib/motanka/snapshots and snapper's configurations are readable by root only; run: sudo motanka doctor"
    return 0
  fi
  if cfg=$(mk_snapshot_snapper_config); then
    method=config-archive+snapper
  else
    cfg=""
  fi
  while IFS= read -r id; do
    if [[ -n $id ]]; then
      n=$((n + 1))
      latest=$id
    fi
  done < <(mk_snapshot_list 2>/dev/null || true)
  _mk_dr_rec s system.snapshots.method "$method"
  _mk_dr_rec b system.snapshots.snapper.checked true
  _mk_dr_str system.snapshots.snapper.config "$cfg"
  _mk_dr_rec i system.snapshots.count "$n"
  _mk_dr_str system.snapshots.latest "$latest"
}

_mk_dr_emit_sysledger() {
  local file p st n=0
  local -a pkgs=() runs=() gone=()
  local -A have=()
  file=$(mk_sysledger_file)
  _mk_dr_rec s system.system_ledger.file "$MK_SYSLEDGER_PATH"
  if [[ ! -e $file ]]; then
    _mk_dr_rec b system.system_ledger.read true
    _mk_dr_rec b system.system_ledger.present false
    return 0
  fi
  if [[ ! -r $file ]]; then
    _mk_dr_rec b system.system_ledger.read false
    _mk_dr_rec b system.system_ledger.present true
    _mk_dr_skip system_ledger "$MK_SYSLEDGER_PATH is not readable by $(id -un); run: sudo motanka doctor"
    return 0
  fi
  mapfile -t pkgs < <(mk_sysledger_packages "$file" 2>/dev/null | awk -v re="$MK_DR_PKG_RE" '$0 ~ re')
  mapfile -t runs < <(mk_sysledger_incomplete_runs "$file" 2>/dev/null)
  if ((${#pkgs[@]} > 0)); then
    while IFS=$'\t' read -r p st; do
      if [[ $st == installed ]]; then
        have[${p%%:*}]=1
      fi
    done < <(
      # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
      dpkg-query -W -f='${Package}\t${db:Status-Status}\n' "${pkgs[@]}" 2>/dev/null || true
    )
    for p in "${pkgs[@]}"; do
      n=$((n + 1))
      if [[ -z ${have[$p]:-} ]]; then
        gone+=("$p")
      fi
    done
  fi
  _mk_dr_rec b system.system_ledger.read true
  _mk_dr_rec b system.system_ledger.present true
  _mk_dr_rec i system.system_ledger.packages "$n"
  _mk_dr_rec l system.system_ledger.packages_missing
  for p in "${gone[@]}"; do
    _mk_dr_rec a system.system_ledger.packages_missing "$p"
  done
  _mk_dr_rec l system.system_ledger.incomplete_runs
  for p in "${runs[@]}"; do
    if [[ -n $p ]]; then
      _mk_dr_rec a system.system_ledger.incomplete_runs "$p"
    fi
  done
  if ((${#runs[@]} > 0)) && [[ -n ${runs[0]} ]]; then
    _mk_dr_problem interrupted-run "the System_Ledger records ${#runs[@]} run(s) that did not finish (${runs[*]}); 'sudo motanka install' completes an interrupted install, 'sudo motanka remove' removes Motanka" "sudo motanka install"
  fi
}

# _mk_dr_emit_features: Upstream packages without an outcome on the running
# release (1.7): the skip lines of the installed package-map.tsv, which is
# compiled for this release.
_mk_dr_emit_features() {
  local map name kind reason
  map=$(mk_path "$MK_DR_SHARE/package-map.tsv")
  if [[ ! -r $map ]]; then
    _mk_dr_rec z features_unavailable
    _mk_dr_skip features "$MK_DR_SHARE/package-map.tsv is missing (motanka-core is not installed), so the features this release lacks are not known"
    return 0
  fi
  _mk_dr_rec l features_unavailable
  while IFS=$'\t' read -r name kind _ reason _ || [[ -n $name ]]; do
    if [[ -z $name || $name == \#* || $kind != skip ]]; then
      continue
    fi
    _mk_dr_rec o features_unavailable
    _mk_dr_rec f package "$name"
    _mk_dr_rec f reason "${reason:-no reason recorded}"
  done <"$map"
}

# _mk_dr_emit_journal: unsupported shim calls of the last 30 days (12.3).
_mk_dr_emit_journal() {
  local complete=0 g
  local -a groups=()
  if ((MK_DR_ROOT)); then
    complete=1
  else
    read -r -a groups <<<"$(id -Gn 2>/dev/null || true)"
    for g in "${groups[@]}"; do
      case $g in
        systemd-journal | adm | wheel) complete=1 ;;
      esac
    done
  fi
  _mk_dr_bool shim_calls.complete "$complete"
  if ((!complete)); then
    _mk_dr_skip "journal of other users" "$(id -un) is not in the systemd-journal or adm group, so only this user's unsupported shim calls are listed; run: sudo motanka doctor"
  fi
  if ! python3 -I -c "$MK_DR_PY" journal "$MK_DR_JOURNAL_SINCE"; then
    _mk_dr_rec b shim_calls.read false
    _mk_dr_rec s shim_calls.error "the journal could not be read"
  fi
}

# --- the home part of the report -----------------------------------------------------

# _mk_dr_in_namespaced <path>: 0 for a Namespaced_Path or a path inside one.
_mk_dr_in_namespaced() {
  local p=${1%/} root
  for root in "${MK_UL_NAMESPACED[@]}"; do
    if [[ $p == "$root" || $p == "$root"/* ]]; then
      return 0
    fi
  done
  return 1
}

# _mk_dr_home_records <user> <home>: the home part of the report, read as
# the user who owns the home folder. Compares each ledgered path with the
# state its last ledger entry recorded; never prints file contents.
_mk_dr_home_records() {
  local user=$1 home=$2 ledger verb rel after cur since n=0 i
  local -a order=() unplanned=() observed=() missing=() missing_v=() changed=() changed_v=()
  local -A last_verb=() last_after=() seen=()
  ledger=$home/$MK_UL_STATE_REL/ledger
  _mk_dr_rec s home.user "$user"
  _mk_dr_rec s home.path "$home"
  _mk_dr_rec s home.ledger_file "$ledger"
  if [[ -f $ledger ]]; then
    _mk_dr_rec b home.user_ledger true
  else
    _mk_dr_rec b home.user_ledger false
  fi
  while IFS=$'\t' read -r _ _ verb _ rel _ after _; do
    n=$((n + 1))
    case $verb in
      unplanned)
        if [[ -z ${seen[u:$rel]:-} ]]; then
          seen[u:$rel]=1
          unplanned+=("$rel")
        fi
        ;;
      observed)
        if [[ -z ${seen[o:$rel]:-} ]]; then
          seen[o:$rel]=1
          observed+=("$rel")
        fi
        ;;
      create | replace | symlink | block | menu-desktop | adopt)
        if [[ -z ${last_verb[p:$rel]:-} ]]; then
          order+=("$rel")
        fi
        last_verb[p:$rel]=$verb
        last_after[p:$rel]=$after
        ;;
    esac
  done < <(MK_HOME=$home mk_userledger_read)
  _mk_dr_rec i home.entries "$n"

  if MK_HOME=$home mk_capture_pending; then
    since=$(MK_HOME=$home mk_capture_started 2>/dev/null) || since=""
    if [[ ! $since =~ $MK_DR_TIME_RE ]]; then
      since=unknown
    fi
    _mk_dr_rec b home.session_capture.pending true
    _mk_dr_rec s home.session_capture.since "$since"
  else
    _mk_dr_rec b home.session_capture.pending false
    _mk_dr_rec z home.session_capture.since
  fi

  for rel in "${order[@]}"; do
    verb=${last_verb[p:$rel]}
    if [[ $rel == */ ]]; then
      if [[ ! -d $home/${rel%/} || -L $home/${rel%/} ]]; then
        missing+=("$rel") missing_v+=("$verb")
      fi
      continue
    fi
    cur=$(MK_HOME=$home mk_userledger_state "$rel" 2>/dev/null) || continue
    if [[ $cur == - ]]; then
      missing+=("$rel") missing_v+=("$verb")
    elif ! _mk_dr_in_namespaced "$rel" && [[ $cur != "${last_after[p:$rel]}" ]]; then
      changed+=("$rel") changed_v+=("$verb")
    fi
  done
  _mk_dr_rec l home.missing
  for i in "${!missing[@]}"; do
    _mk_dr_rec o home.missing
    _mk_dr_rec f path "${missing[i]}"
    _mk_dr_rec f entry "${missing_v[i]}"
  done
  _mk_dr_rec l home.changed
  for i in "${!changed[@]}"; do
    _mk_dr_rec o home.changed
    _mk_dr_rec f path "${changed[i]}"
    _mk_dr_rec f entry "${changed_v[i]}"
  done
  _mk_dr_rec l home.unplanned
  for rel in "${unplanned[@]}"; do
    _mk_dr_rec a home.unplanned "$rel"
  done
  _mk_dr_rec l home.desktop
  for rel in "${observed[@]}"; do
    _mk_dr_rec a home.desktop "$rel"
  done
}

# _mk_dr_home: as a normal user, sets MK_DR_USER and MK_DR_HOME (MK_HOME,
# else HOME) or exits 1 when that folder does not exist.
_mk_dr_home() {
  MK_DR_USER=$(id -un)
  MK_DR_HOME=${MK_HOME:-${HOME:-}}
  MK_DR_HOME=${MK_DR_HOME%/}
  if [[ $MK_DR_HOME != /* || ! -d $MK_DR_HOME ]]; then
    mk_die "$MK_EXIT_ERROR" "the home folder '${MK_DR_HOME:-unset}' does not exist"
  fi
}

# _mk_dr_emit_home: the home part; as root, SUDO_USER's home folder read
# as that user.
_mk_dr_emit_home() {
  local entry uid gid name home rc=0
  if ((!MK_DR_ROOT)); then
    _mk_dr_home_records "$MK_DR_USER" "$MK_DR_HOME"
    return 0
  fi
  if [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
    _mk_dr_rec z home
    _mk_dr_skip home "running as root without SUDO_USER, so there is no user whose home folder to read; run 'motanka doctor' as that user, or with sudo from that user's account"
    return 0
  fi
  if ! entry=$(mk_snapshot_lookup_user "$SUDO_USER"); then
    _mk_dr_rec z home
    _mk_dr_skip home "SUDO_USER '$SUDO_USER' has no passwd entry"
    return 0
  fi
  IFS=$'\t' read -r uid gid name home <<<"$entry"
  if [[ ! -d $home || $uid == 0 ]]; then
    _mk_dr_rec z home
    _mk_dr_skip home "the home folder '$home' of $name does not exist"
    return 0
  fi
  # shellcheck disable=SC2016 # expanded by the inner shell
  mk_snapshot_as_user "$uid" "$gid" "$home" bash -c 'set -euo pipefail
    MK_LIBEXEC=$1
    source "$1/cmd/doctor.sh"
    _mk_dr_home_records "$2" "$3"' _ "$_mk_dr_base" "$name" "$home" || rc=$?
  if ((rc != 0)); then
    _mk_dr_skip home "reading the home folder of $name as $name failed (exit $rc); the home part may be incomplete"
  fi
}

# --- the whole report ----------------------------------------------------------------

_mk_dr_emit_list() {
  local i
  _mk_dr_rec l problems
  for i in "${!MK_DR_PROB_ID[@]}"; do
    _mk_dr_rec o problems
    _mk_dr_rec f id "${MK_DR_PROB_ID[i]}"
    _mk_dr_rec f message "${MK_DR_PROB_MSG[i]}"
    if [[ -n ${MK_DR_PROB_FIX[i]} ]]; then
      _mk_dr_rec f fix "${MK_DR_PROB_FIX[i]}"
    else
      _mk_dr_rec Z fix
    fi
  done
  _mk_dr_rec l skipped
  for i in "${!MK_DR_SKIP_PART[@]}"; do
    _mk_dr_rec o skipped
    _mk_dr_rec f part "${MK_DR_SKIP_PART[i]}"
    _mk_dr_rec f reason "${MK_DR_SKIP_REASON[i]}"
  done
}

_mk_dr_emit_fix() {
  local p
  if ((!MK_FIX)); then
    return 0
  fi
  _mk_dr_rec s fix.action "$MK_DR_FIX_ACTION"
  _mk_dr_rec s fix.message "$MK_DR_FIX_MSG"
  _mk_dr_rec l fix.purged
  for p in "${MK_DR_FIX_FROM[@]}"; do
    _mk_dr_rec a fix.purged "$p"
  done
  _mk_dr_str fix.installed "$MK_DR_FIX_TO"
  _mk_dr_str fix.suite "$MK_DR_FIX_SUITE"
  _mk_dr_str fix.apt_update "$MK_DR_FIX_APT"
}

# _mk_dr_emit: every record of the report, in the order of the document.
_mk_dr_emit() {
  MK_DR_PROB_ID=() MK_DR_PROB_MSG=() MK_DR_PROB_FIX=()
  MK_DR_SKIP_PART=() MK_DR_SKIP_REASON=()
  _mk_dr_rec i format 1
  _mk_dr_rec s generated "$(mk_utc_now)"
  _mk_dr_rec s running_as.user "$(id -un)"
  _mk_dr_rec i running_as.uid "$(id -u)"
  _mk_dr_bool running_as.root "$MK_DR_ROOT"
  _mk_dr_emit_fix
  _mk_dr_read_release
  _mk_dr_read_packages
  _mk_dr_read_source
  _mk_dr_emit_release
  _mk_dr_emit_motanka
  _mk_dr_emit_repository
  _mk_dr_emit_other_release
  _mk_dr_emit_pin
  _mk_dr_emit_stack
  _mk_dr_emit_apps
  _mk_dr_emit_gpu
  _mk_dr_emit_dm
  _mk_dr_emit_snapshots
  _mk_dr_emit_sysledger
  _mk_dr_emit_features
  _mk_dr_emit_journal
  _mk_dr_emit_home
  _mk_dr_emit_list
}

# --- --fix ------------------------------------------------------------------------------

# _mk_dr_fix_result <none|switched> <message>
_mk_dr_fix_result() {
  MK_DR_FIX_ACTION=$1
  MK_DR_FIX_MSG=$2
  mk_info "$(mk_cmd_name) --fix: $2"
  mk_log info "fix: $2"
}

# _mk_dr_dpkg <dpkg arguments...>: dpkg without questions and without the
# descriptor of the system lock, its output on stderr.
_mk_dr_dpkg() {
  DEBIAN_FRONTEND=noninteractive mk_snapshot_nolock dpkg "$@" </dev/null >&2
}

# _mk_dr_check_source_deb <deb> <suite>: the verified package holds an
# enabled motanka.sources for the suite with a Signed-By field.
_mk_dr_check_source_deb() {
  local deb=$1 suite=$2 d f
  d=$MK_APTSIM_DIR/source
  rm -rf -- "$d"
  mkdir -p -- "$d"
  if ! dpkg-deb -x "$deb" "$d"; then
    mk_die "$MK_EXIT_ERROR" "cannot unpack motanka-source-$suite in $d; nothing was changed"
  fi
  f=$d$MK_DR_SOURCES
  if [[ ! -f $f ]] || ! grep -qxF "Suites: $suite" "$f" || ! grep -q '^Signed-By:' "$f" ||
    grep -qi '^Enabled:[[:space:]]*no' "$f"; then
    mk_die "$MK_EXIT_ERROR" "the package motanka-source-$suite has no enabled $MK_DR_SOURCES for the suite $suite with a Signed-By field; nothing was changed"
  fi
}

# _mk_dr_fix: --fix (see the top). Returns 0, or 1 when apt-get update
# failed after the switch; exits on every other failure.
_mk_dr_fix() {
  local target channel pkg p policy="" rc=0
  local -a old=() debs=()
  if ((!MK_DR_ROOT)); then
    mk_die "$MK_EXIT_AUTH" "motanka doctor --fix must run as root: $MK_DR_FIX_CMD"
  fi
  mk_guard_protected_host
  if ((MK_NOT_A_VM)); then
    mk_guard_dev_build "$MK_NOT_A_VM_FLAG"
  else
    mk_guard_dev_build
  fi
  mk_lock_system
  mk_log info "doctor --fix started"
  _mk_dr_read_release
  _mk_dr_read_packages
  _mk_dr_read_source
  if ((!MK_DR_SUPPORTED)); then
    mk_die "$MK_EXIT_UNSUPPORTED" "this system runs ${MK_DR_OS_PRETTY:-an unknown release}; the Motanka repository has suites for Ubuntu 24.04 LTS (noble) and Ubuntu 26.04 LTS (resolute) only; nothing was changed"
  fi
  mapfile -t old < <(_mk_dr_source_packages)
  if ((${#old[@]} == 0 && !MK_DR_SRC_PRESENT)) && [[ -z ${MK_DR_PKG_ST[motanka-core]:-} ]]; then
    _mk_dr_fix_result none "Motanka is not installed, so there is no apt source to switch; install it with: sudo motanka install"
    return 0
  fi
  channel=$(_mk_dr_channel)
  target=$MK_DR_OS_CODENAME
  if [[ $channel == edge ]]; then
    target=$target-edge
  fi
  pkg=motanka-source-$target
  MK_DR_FIX_SUITE=$target
  if ((MK_DR_SRC_PRESENT && MK_DR_SRC_ENABLED)) && [[ $MK_DR_SRC_SUITE == "$target" ]] &&
    ((${#old[@]} == 1)) && [[ ${old[0]} == "$pkg" ]] && _mk_dr_installed "$pkg"; then
    _mk_dr_fix_result none "the Motanka apt source names the suite $target of this release and is enabled; nothing to fix"
    return 0
  fi

  if [[ -z ${MOTANKA_APT_URI:-} && $MK_DR_SRC_URI =~ ^https?://[A-Za-z0-9._~:@%+=,/-]+$ ]]; then
    MOTANKA_APT_URI=$MK_DR_SRC_URI
  fi
  mk_aptsim_uri
  mk_info "switching the Motanka apt source to the suite $target (repository $MK_APTSIM_URI)"
  trap 'mk_aptsim_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mk_aptsim_begin
  mk_aptsim_fetch_verified "$target"
  _mk_dr_check_source_deb "$MK_APTSIM_SOURCE_DEB" "$target"
  if ! _mk_dr_installed motanka-archive-keyring; then
    debs+=("$MK_APTSIM_KEYRING_DEB")
  fi
  debs+=("$MK_APTSIM_SOURCE_DEB")

  MK_DR_FIX_FROM=("${old[@]}")
  for p in "${old[@]}"; do
    mk_info "purging $p, with its $MK_DR_SOURCES"
    mk_log notice "fix: dpkg --force-depends --purge $p"
    if ! _mk_dr_dpkg --force-depends --purge "$p"; then
      mk_die "$MK_EXIT_ERROR" "dpkg could not purge $p; run '$MK_DR_FIX_CMD' again when dpkg is free (check with: sudo dpkg --audit)"
    fi
  done
  mk_info "installing $pkg $MK_APTSIM_SOURCE_VERSION"
  mk_log notice "fix: dpkg --install --force-confnew ${debs[*]##*/}"
  if ! _mk_dr_dpkg --install --force-confnew "${debs[@]}"; then
    mk_die "$MK_EXIT_ERROR" "dpkg could not install $pkg, so no Motanka apt source is configured now; run '$MK_DR_FIX_CMD' again"
  fi
  MK_DR_FIX_TO=$pkg
  mk_aptsim_cleanup
  trap - EXIT HUP INT TERM

  _mk_dr_read_source
  if ((!MK_DR_SRC_PRESENT || !MK_DR_SRC_ENABLED)) || [[ $MK_DR_SRC_SUITE != "$target" ]]; then
    mk_die "$MK_EXIT_ERROR" "$pkg is installed, but $MK_DR_SOURCES does not name the enabled suite $target; run '$MK_DR_FIX_CMD' again"
  fi
  mk_info "apt-get update"
  if LC_ALL=C mk_snapshot_nolock apt-get -q -o DPkg::Lock::Timeout=300 update </dev/null >&2; then
    policy=$(LC_ALL=C apt-cache policy 2>/dev/null) || policy=""
  fi
  if grep -Eq "(^|[ ,])o=Motanka,a=$target,n=$target(,|$)" <<<"$policy"; then
    MK_DR_FIX_APT=ok
  else
    MK_DR_FIX_APT=failed
    rc=1
    mk_warn "apt-get update did not load the signed Motanka suite $target; check the network connection, then run 'sudo apt-get update' and 'sudo motanka update'"
  fi
  _mk_dr_fix_result switched "switched the Motanka apt source from ${old[*]:-none} to $pkg (suite $target); apt-get update: $MK_DR_FIX_APT; next: sudo motanka update"
  return "$rc"
}

# --- entry point ------------------------------------------------------------------------

mk_cmd_doctor() {
  local mode=text rc=0
  MK_JSON=0 MK_FIX=0 MK_NOT_A_VM=0
  while (($# > 0)); do
    case $1 in
      -h | --help)
        mk_doctor_usage
        exit "$MK_EXIT_OK"
        ;;
      --json)
        MK_JSON=1
        ;;
      --fix)
        MK_FIX=1
        ;;
      "$MK_NOT_A_VM_FLAG")
        MK_NOT_A_VM=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        mk_usage_error "unknown option '$1'"
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
  if ((MK_NOT_A_VM && !MK_FIX)); then
    mk_usage_error "$MK_NOT_A_VM_FLAG is accepted with --fix only"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    mk_die "$MK_EXIT_ERROR" "python3 is missing; the Doctor builds its report with it (motanka-core depends on python3)"
  fi
  MK_DR_ROOT=0
  if [[ $(id -u) == 0 ]]; then
    MK_DR_ROOT=1
  fi
  if ((MK_FIX)); then
    _mk_dr_fix || rc=$?
  fi
  if ((!MK_DR_ROOT)); then
    _mk_dr_home
  fi
  if ((MK_JSON)); then
    mode=json
  fi
  if ! _mk_dr_emit | python3 -I -c "$MK_DR_PY" "$mode"; then
    mk_die "$MK_EXIT_ERROR" "could not build the report"
  fi
  exit "$rc"
}
