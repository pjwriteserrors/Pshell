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
  palette      the Theme still follows the wallpaper: under several test
               palettes its colour roles stay close to main's and change as
               much as main's do (ThemeProbe.qml; skipped with --no-palette)
  animations   a style branch ships at least one window animation in
               style/animations/<name>/ (config, open.glsl, close.glsl), and it
               compiles

Exit status 1 when a check fails.
"""
from __future__ import annotations

import argparse
import colorsys
import difflib
import itertools
import math
import os
import shutil
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


def check(base: Tree, style: Tree, is_style_branch: bool, compile_animations: bool,
          check_colours: bool = True) -> Report:
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
        if check_colours:
            check_palette(base, style, report)

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


# ------------------------------------------------------------------ palette

# Test wallpapers: a dominant hue each, one of them light.
PROBE_PALETTES = [(8, True), (130, True), (215, True), (285, False)]
# Role groups and how far (OKLab ΔE, averaged over the test palettes) a style
# may pull each of their roles away from the colour main derives from the
# wallpaper.
ROLE_LIMITS = {
    "surfaces": (("base", "layer1", "layer2", "layer3"), 0.04),
    "accents": (("primary", "secondary", "tertiary"), 0.08),
    "text": (("text",), 0.04),
}
# How much of main's change across wallpapers a role must keep to count as
# following the wallpaper.
FOLLOW_MIN = 0.6
# Share of all colour uses in a style that may go to roles which do not follow
# the wallpaper (signature tones such as gold or ember).
SIGNATURE_MAX = 0.2
# Stable on purpose, on main as well: they neither count for nor against.
SEMANTIC = {"danger", "warning", "success", "dangerContainer", "onPrimary", "scrim", "shadow"}


def hsl(h: float, s: float, l: float) -> str:
    r, g, b = colorsys.hls_to_rgb((h % 360) / 360, l, s)
    return "#{:02x}{:02x}{:02x}".format(*(round(c * 255) for c in (r, g, b)))


def probe_palette(hue: float, dark: bool) -> dict:
    bg = hsl(hue, 0.28, 0.09 if dark else 0.92)
    fg = hsl(hue, 0.18, 0.88 if dark else 0.14)
    colors = {"color0": bg, "color7": fg, "color8": hsl(hue, 0.14, 0.32 if dark else 0.7), "color15": fg}
    for i in range(1, 7):
        colors[f"color{i}"] = hsl(hue + (i - 1) * 28, 0.62, 0.56 if dark else 0.42)
        colors[f"color{i + 8}"] = hsl(hue + (i - 1) * 28, 0.66, 0.66 if dark else 0.34)
    return {"special": {"background": bg, "foreground": fg, "cursor": fg}, "colors": colors}


def oklab(hex_color: str) -> tuple:
    value = hex_color.lstrip("#")[-6:]
    rgb = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    r, g, b = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def delta(a: str, b: str) -> float:
    return math.dist(oklab(a), oklab(b))


def checkout(tree: Tree, into: Path, probe_source: str):
    """A copy of `tree` at `into` that quickshell can load, with the probe."""
    head = tree.ref or "HEAD"
    git("worktree", "add", "--quiet", "--detach", str(into), head)
    if tree.ref is None:
        shutil.rmtree(into / "style")
        shutil.copytree(REPO / "style", into / "style")
    (into / "ThemeProbe.qml").write_text(probe_source)


def probe_roles(root: Path, palettes: list[dict], cache: Path) -> list[dict] | None:
    out = []
    for index, palette in enumerate(palettes):
        wal = cache / str(index) / "wal"
        wal.mkdir(parents=True, exist_ok=True)
        (wal / "colors.json").write_text(json.dumps(palette))
        env = {**os.environ, "XDG_CACHE_HOME": str(wal.parent)}
        result = subprocess.run(["quickshell", "-p", str(root / "ThemeProbe.qml")], env=env,
                                capture_output=True, text=True, timeout=60)
        match = re.search(r"THEME_PROBE (\{.*\})", result.stdout + result.stderr)
        if not match:
            return None
        out.append(json.loads(match.group(1)))
    return out


def check_palette(base: Tree, style: Tree, report: Report):
    """Signature tones may colour the style; the wallpaper must still show."""
    probe_source = base.read("ThemeProbe.qml")
    if probe_source is None:
        report.note("palette", "no ThemeProbe.qml on the base, skipped")
        return
    palettes = [probe_palette(h, d) for h, d in PROBE_PALETTES]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        try:
            checkout(base, tmp / "base", probe_source)
            checkout(style, tmp / "style", probe_source)
            main_roles = probe_roles(tmp / "base", palettes, tmp / "cache-base")
            own_roles = probe_roles(tmp / "style", palettes, tmp / "cache-style")
        finally:
            for name in ("base", "style"):
                git("worktree", "remove", "--force", str(tmp / name), check=False)
    if not main_roles or not own_roles:
        report.fail("palette", "Theme could not be probed (does the style compile?)")
        return

    pairs = len(palettes) * (len(palettes) - 1) / 2
    spread = lambda rows, role: sum(delta(a[role], b[role]) for a, b in itertools.combinations(rows, 2)) / pairs
    accents = ROLE_LIMITS["accents"][0]
    reference = sum(spread(main_roles, r) for r in accents) / len(accents)

    for group, (roles, limit) in ROLE_LIMITS.items():
        for role in roles:
            drift = sum(delta(o[role], m[role]) for o, m in zip(own_roles, main_roles)) / len(palettes)
            if drift > limit:
                report.fail("palette", f"`{role}` is {drift:.3f} away from the wallpaper's colour (limit {limit}) – "
                                       "mix the signature tone in more lightly")
        follow = sum(spread(own_roles, r) for r in roles) / max(sum(spread(main_roles, r) for r in roles), 1e-6)
        if follow < FOLLOW_MIN:
            report.fail("palette", f"{group} keep {follow:.0%} of the wallpaper's change (need {FOLLOW_MIN:.0%})")

    # How often the style paints with colours that ignore the wallpaper.
    uses = {}
    for path in style.files("style"):
        if path.endswith(".qml") and not path.startswith("style/theme/"):
            for name in re.findall(r"\bTheme\.(\w+)", style.read(path) or ""):
                if name in own_roles[0] and name not in SEMANTIC:
                    uses[name] = uses.get(name, 0) + 1
    fixed = {r: n for r, n in uses.items() if spread(own_roles, r) / max(reference, 1e-6) < FOLLOW_MIN}
    total = sum(uses.values())
    share = sum(fixed.values()) / total if total else 0.0
    listing = ", ".join(f"{r} ×{n}" for r, n in sorted(fixed.items(), key=lambda kv: -kv[1])) or "none"
    if share > SIGNATURE_MAX:
        report.fail("palette", f"{share:.0%} of colour uses ignore the wallpaper (limit {SIGNATURE_MAX:.0%}): {listing} – "
                               "use the wallpaper roles more, keep signature tones for highlights")
    else:
        report.note("palette", f"{share:.0%} of colour uses are signature tones ({listing})")


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
    parser.add_argument("--no-palette", action="store_true", help="skip probing the Theme's colours")
    args = parser.parse_args()

    base = Tree(args.base)
    if args.contract:
        print(contract(base))
        return 0

    style = Tree(args.ref)
    head = args.ref or git("rev-parse", "--abbrev-ref", "HEAD")
    is_style_branch = git("rev-parse", head, check=False) != git("rev-parse", args.base, check=False) \
        or (args.ref is None and head != args.base)
    report = check(base, style, is_style_branch, not args.no_compile, not args.no_palette)

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
