#!/usr/bin/env python3
"""The contract between the core (logic) and a style (look), checked.

Everything a style must provide is derived from `main` every time this runs, so
the contract follows the logic: when main adds a Theme token, a widget property
or a surface, the next check asks every style for it.

    check_style.py                     check the working tree against main
    check_style.py --ref style/<name>  check a style branch
    check_style.py --since <commit>    also list what main changed since
                                       <commit> that the style has to port
    check_style.py --contract          print the contract as main defines it

Checks:
  manifest     .quickshell-style.json: api 1, name, description
  scope        a style branch changes nothing outside style/ and its manifest
  kit          every file in main's style/theme and style/widgets exists, keeps
               its root type, `pragma Singleton` and every public member
  frame        style/Frame.qml exists, and the style reaches every panel and
               modal that main's own style/ reaches (a new feature on main
               needs a way in on every style)
  views        style/views/<Surface>.qml replaces a real surface, keeps its
               root type and modalId/panelId, and carries no logic of its own
  layout       a style branch invents its own layout: every replaceable surface
               has a view of its own, and neither those views nor the frame
               (Frame.qml, everything outside theme/, widgets/, views/,
               animations/) are main's files or close copies of them
  animations   a style branch ships at least one window animation in
               style/animations/<name>/ (config, open.glsl, close.glsl), and it
               compiles

Exit status 1 when a check fails.
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = ".quickshell-style.json"
KIT_DIRS = ("style/theme", "style/widgets")
# What makes a view "logic": it talks to processes, files, sockets or D-Bus
# itself instead of reading a service. A style view must not.
LOGIC = re.compile(
    r"\b(Process|FileView|Socket|SocketServer|DBusProperty|IpcHandler|JsonAdapter)\s*\{"
    r"|\bexecDetached\b|\bQuickshell\.exec\b"
)
MEMBER = re.compile(
    r"^\s*(?:(?:readonly|required|default)\s+)*property\s+[\w<>.]+\s+(\w+)"
    r"|^\s*signal\s+(\w+)"
    r"|^\s*function\s+(\w+)\s*\("
)
NESTED = re.compile(r"^\s*(?:readonly\s+)?property\s+QtObject\s+(\w+)\s*:\s*QtObject\s*\{")
ROOT = re.compile(r"^\s*([A-Z][\w.]*)\s*\{")
IDENT = re.compile(r"^\s*(modalId|panelId)\s*:\s*\"([^\"]+)\"", re.M)


# ------------------------------------------------------------------ sources

class Tree:
    """Files of a git ref, or of the working tree when ref is None."""

    def __init__(self, ref: str | None):
        self.ref = ref

    def files(self, prefix: str) -> list[str]:
        if self.ref is None:
            root = REPO / prefix
            if not root.exists():
                return []
            return sorted(str(p.relative_to(REPO)) for p in root.rglob("*") if p.is_file())
        out = git("ls-tree", "-r", "--name-only", self.ref, "--", prefix, check=False)
        return sorted(line for line in out.splitlines() if line)

    def read(self, path: str) -> str | None:
        if self.ref is None:
            p = REPO / path
            return p.read_text() if p.is_file() else None
        result = subprocess.run(["git", "show", f"{self.ref}:{path}"], cwd=REPO,
                                capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True)
    if check and result.returncode:
        raise SystemExit(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


# ------------------------------------------------------------------ parsing

def strip(source: str) -> str:
    """Comments removed, strings blanked; braces and line breaks kept."""
    out, i, n = [], 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
            continue
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("\n" * source.count("\n", i, end))
            i = end
            continue
        if c in "\"'`":
            quote, j = c, i + 1
            while j < n and source[j] != quote:
                j += 2 if source[j] == "\\" else 1
            chunk = source[i:j + 1]
            out.append(quote + "\n" * chunk.count("\n") + quote)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def interface(source: str) -> dict:
    """Root type, singleton-ness and public member names of a QML file."""
    code = strip(source)
    members, root, depth, nested = set(), "", 0, []
    for line in code.splitlines():
        if depth == 0 and not root:
            m = ROOT.match(line)
            if m:
                root = m.group(1)
        elif depth == 1 or (nested and depth == nested[-1][1]):
            prefix = f"{nested[-1][0]}." if nested and depth == nested[-1][1] else ""
            m = NESTED.match(line) if not prefix else None
            if m:
                members.add(m.group(1))
                nested.append((m.group(1), depth + 1))
            else:
                m = MEMBER.match(line)
                if m:
                    members.add(prefix + next(g for g in m.groups() if g))
        depth += line.count("{") - line.count("}")
        while nested and depth < nested[-1][1]:
            nested.pop()
    return {"root": root, "singleton": "pragma Singleton" in source, "members": members}


# ------------------------------------------------------------------ model

def surfaces(tree: Tree) -> dict:
    """Every surface core/Surfaces.qml creates: name -> core file, root, id."""
    text = tree.read("core/Surfaces.qml") or ""
    names = sorted(set(re.findall(r"^\s*([A-Z]\w*) \{\}\s*$", text, re.M)))
    views = {Path(p).stem: p for p in tree.files("core/views") if p.endswith(".qml")}
    result = {}
    for name in names:
        path = views.get(name)
        if not path:
            continue
        source = tree.read(path) or ""
        ident = IDENT.search(strip_keep_strings(source))
        result[name] = {
            "path": path,
            "root": interface(source)["root"],
            "id": f"{ident.group(1)}: {ident.group(2)}" if ident else "",
            "logic": bool(LOGIC.search(strip(source))),
        }
    return result


def strip_keep_strings(source: str) -> str:
    return re.sub(r"//[^\n\"]*$", "", source, flags=re.M)


def reached(tree: Tree, ids: set[str]) -> set[str]:
    """Surface ids the files under style/ name as string literals."""
    found = set()
    for path in tree.files("style"):
        if path.endswith(".qml"):
            found |= ids & set(re.findall(r"\"([a-zA-Z]+)\"", tree.read(path) or ""))
    return found


def kit(tree: Tree) -> dict:
    return {p: interface(tree.read(p) or "") for d in KIT_DIRS for p in tree.files(d) if p.endswith(".qml")}


# ------------------------------------------------------------------ checks

class Report:
    def __init__(self):
        self.failures, self.notes = [], []

    def fail(self, area: str, message: str):
        self.failures.append(f"{area:<11} {message}")

    def note(self, area: str, message: str):
        self.notes.append(f"{area:<11} {message}")


def check(base: Tree, style: Tree, is_style_branch: bool, compile_animations: bool) -> Report:
    report = Report()

    raw = style.read(MANIFEST)
    try:
        manifest = json.loads(raw or "")
        if manifest.get("api") != 1:
            report.fail("manifest", f"{MANIFEST}: api must be 1")
        for key in ("name", "description"):
            if not str(manifest.get(key, "")).strip():
                report.fail("manifest", f"{MANIFEST}: {key} is empty")
    except ValueError:
        report.fail("manifest", f"{MANIFEST} missing or not JSON")

    if is_style_branch:
        if style.ref is None:
            changed = git("diff", "--name-only", base.ref, "--", ".", f":!style", f":!{MANIFEST}", check=False)
            untracked = git("ls-files", "--others", "--exclude-standard", "--", ".", ":!style", check=False)
            changed = "\n".join(filter(None, [changed, untracked]))
        else:
            changed = git("diff", "--name-only", f"{base.ref}...{style.ref}", "--", ".", ":!style", f":!{MANIFEST}", check=False)
        for path in filter(None, changed.splitlines()):
            report.fail("scope", f"{path} is outside style/ – logic changes belong on main")

    if style.read("style/Frame.qml") is None:
        report.fail("frame", "style/Frame.qml is missing")

    base_surfaces = surfaces(base)
    ids = {info["id"].split(": ")[1] for info in base_surfaces.values() if info["id"]}
    for missing in sorted(reached(base, ids) - reached(style, ids)):
        owner = next(n for n, i in base_surfaces.items() if i["id"].endswith(f": {missing}"))
        report.fail("frame", f"nothing in style/ opens `{missing}` ({owner}) – main's style does; give it a way in")

    base_kit, style_kit = kit(base), kit(style)
    for path, want in base_kit.items():
        have = style_kit.get(path)
        if have is None:
            report.fail("kit", f"{path} is missing")
            continue
        if have["root"] != want["root"]:
            report.fail("kit", f"{path}: root type {have['root']} – main has {want['root']}")
        if want["singleton"] and not have["singleton"]:
            report.fail("kit", f"{path}: lost `pragma Singleton`")
        for member in sorted(want["members"] - have["members"]):
            report.fail("kit", f"{path}: missing `{member}`")

    for path in style.files("style/views"):
        name = Path(path).stem
        if not path.endswith(".qml") or name == "Overrides":
            continue
        core = base_surfaces.get(name)
        if core is None:
            report.fail("views", f"{path} replaces no surface (core/Surfaces.qml creates no {name})")
            continue
        source = style.read(path) or ""
        own = interface(source)
        if own["root"] != core["root"]:
            report.fail("views", f"{path}: root type {own['root']} – the core view is a {core['root']}")
        ident = IDENT.search(strip_keep_strings(source))
        own_id = f"{ident.group(1)}: {ident.group(2)}" if ident else ""
        if own_id != core["id"]:
            report.fail("views", f"{path}: `{own_id or 'no id'}` – the core view has `{core['id'] or 'none'}`")
        hit = LOGIC.search(strip(source))
        if hit:
            report.fail("views", f"{path}: `{hit.group(0).strip()}` – logic belongs in a core service or component")
        if core["logic"]:
            report.fail("views", f"{path}: {core['path']} still carries logic; replacing it would copy that logic – "
                                 "restyle it through the kit instead, or move its logic into core first (on main)")

    if is_style_branch:
        check_layout(base, style, base_surfaces, report)

    animations = [p for p in style.files("style/animations")]
    names = sorted({Path(p).parts[2] for p in animations if len(Path(p).parts) > 3})
    if is_style_branch and not names:
        report.fail("animations", "no window animation in style/animations/<name>/")
    for name in names:
        root = f"style/animations/{name}"
        for part, marker in (("config", None), ("open.glsl", "open_color("), ("close.glsl", "close_color(")):
            text = style.read(f"{root}/{part}")
            if text is None:
                report.fail("animations", f"{root}/{part} is missing")
            elif marker and marker not in text:
                report.fail("animations", f"{root}/{part} defines no `{marker[:-1]}`")
        if compile_animations and all(style.read(f"{root}/{part}") for part in ("config", "open.glsl", "close.glsl")):
            # compiled as a plain shader from a copy, so a branch that is not
            # checked out can be checked too
            with tempfile.TemporaryDirectory() as tmp:
                src = Path(tmp) / "shaders" / name
                src.mkdir(parents=True)
                for part in ("config", "open.glsl", "close.glsl"):
                    (src / part).write_text(style.read(f"{root}/{part}"))
                out = Path(tmp) / "out"
                result = subprocess.run(
                    [sys.executable, str(REPO / "scripts/build_animation_preview.py"), f"shader:{name}",
                     "--animations-root", tmp, "--out-dir", str(out), "--force"], capture_output=True, text=True)
                errors = sorted(out.rglob("*.error"))
                if result.returncode or errors:
                    lines = errors[0].read_text().strip().splitlines() if errors else result.stderr.strip().splitlines()
                    # the first line naming a place in the shader, not the summary
                    detail = next((l for l in lines if re.search(r":\d+:", l)), lines[-1] if lines else "unknown error")
                    report.fail("animations", f"style:{name} does not compile: {detail}")
                else:
                    report.note("animations", f"style:{name} compiles")
    return report


# Above this share of identical lines a file counts as main's layout, recoloured.
COPY_LIMIT = 0.55
OWN_AREAS = ("style/theme/", "style/widgets/", "style/views/", "style/animations/")


def likeness(a: str, b: str) -> float:
    """Share of lines two QML files have in common, whitespace ignored."""
    lines = lambda s: [l.strip() for l in strip(s).splitlines() if l.strip() not in ("", "{", "}")]
    return difflib.SequenceMatcher(None, lines(a), lines(b), autojunk=False).ratio()


def check_layout(base: Tree, style: Tree, base_surfaces: dict, report: Report):
    """A style is a new design, not main's arrangement in other colours."""
    for name, core in base_surfaces.items():
        path = f"style/views/{name}.qml"
        own = style.read(path)
        if core["logic"]:
            if own is None:
                report.note("layout", f"{name} keeps main's layout until its logic moves into core")
            continue
        if own is None:
            report.fail("layout", f"{name} is drawn in main's layout – give it {path}")
            continue
        share = likeness(own, base.read(core["path"]) or "")
        if share > COPY_LIMIT:
            report.fail("layout", f"{path} is {share:.0%} {core['path']} – invent its layout, don't recolour main's")

    for path in style.files("style"):
        if not path.endswith(".qml") or path.startswith(OWN_AREAS):
            continue
        theirs = base.read(path)
        if theirs is None:
            continue
        share = likeness(style.read(path) or "", theirs)
        if share > COPY_LIMIT:
            report.fail("layout", f"{path} is {share:.0%} main's – the frame must be this style's own")


def catch_up(base: Tree, style: Tree, since: str) -> list[str]:
    """What main changed since `since` that this style draws itself."""
    lines = []
    base_surfaces = surfaces(base)
    before = surfaces(Tree(since))
    for name in sorted(set(base_surfaces) - set(before)):
        lines.append(f"new    surface {name} ({base_surfaces[name]['path']}) – check it looks right in this style")
    for path in style.files("style/views"):
        core = base_surfaces.get(Path(path).stem)
        if not core:
            continue
        log = git("log", "--oneline", f"{since}..{base.ref}", "--", core["path"], check=False)
        if log:
            lines.append(f"port   {path}  ← {core['path']} changed on main:")
            lines += [f"         {entry}" for entry in log.splitlines()]
    for path in filter(None, git("diff", "--name-only", since, base.ref, "--", "style/", check=False).splitlines()):
        mine, theirs = style.read(path), base.read(path)
        if theirs is None:
            continue
        if mine is None:
            lines.append(f"new    {path}  (main added it; use it in this style or ignore it)")
        elif mine != theirs:
            log = git("log", "--oneline", f"{since}..{base.ref}", "--", path, check=False)
            lines.append(f"port   {path}  ← main changed it, this style kept its own:")
            lines += [f"         {entry}" for entry in log.splitlines()]
    return lines


def contract(base: Tree) -> str:
    out = ["# The style contract, as main defines it right now", ""]
    out.append("## Kit – same files, same root type, at least these members")
    for path, info in kit(base).items():
        singleton = "  (pragma Singleton)" if info["singleton"] else ""
        out.append(f"{path}: {info['root']}{singleton}")
        if info["members"]:
            out.append("    " + ", ".join(sorted(info["members"])))
    out.append("")
    out.append("## Surfaces – style/views/<Name>.qml may replace the ones marked `replaceable`")
    for name, info in surfaces(base).items():
        kind = "keeps logic, restyle via the kit" if info["logic"] else "replaceable"
        ident = f", {info['id']}" if info["id"] else ""
        out.append(f"{name:<18} {info['root']}{ident:<24} {kind:<34} {info['path']}")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref", help="style branch or commit to check (default: working tree)")
    parser.add_argument("--base", default="main")
    parser.add_argument("--since", help="list what main changed since this commit that the style must port")
    parser.add_argument("--contract", action="store_true", help="print the contract and exit")
    parser.add_argument("--no-compile", action="store_true", help="skip compiling style animations")
    args = parser.parse_args()

    base = Tree(args.base)
    if args.contract:
        print(contract(base))
        return 0

    style = Tree(args.ref)
    head = args.ref or git("rev-parse", "--abbrev-ref", "HEAD")
    is_style_branch = git("rev-parse", head, check=False) != git("rev-parse", args.base, check=False) \
        or (args.ref is None and head != args.base)
    report = check(base, style, is_style_branch, not args.no_compile)

    if args.since:
        lines = catch_up(base, style, args.since)
        print("catch-up" if lines else "catch-up    nothing on main to port")
        for line in lines:
            print("  " + line)
    for line in report.notes:
        print("ok          " + line)
    for line in report.failures:
        print("FAIL        " + line)
    if not report.failures:
        print(f"contract    ok ({head} against {args.base})")
    return 1 if report.failures else 0


if __name__ == "__main__":
    sys.exit(main())
