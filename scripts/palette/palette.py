#!/usr/bin/env python3
"""The Pshell palette engine on the command line (engine.py does the colours).

  palette.py get engine|style|mode       what palette.json chose
  palette.py choose [style] [mode]       chooses (what is given), prints both
  palette.py defaults                    the styles and their default tuning
  palette.py path <media> [S M]          where the kept palette of a media is
  palette.py make <media> [S M]          that palette, made if missing; prints
                                         its path (pywal colors.json + roles)
  palette.py apply <scheme> <wallpaper>  the wallust templates from a scheme
  palette.py analyse <media>             the analysis, kept beside the palettes
  palette.py matrix <theme> <media> <preview>
                                         every style × mode of one picture, as
                                         the theme picker reads it
  palette.py matrix-all                  the same for the TSV lines of
                                         theme_catalog.sh's list on stdin
  palette.py prewarm                     every style × mode of the media on
                                         stdin (one a line), the chosen first
  palette.py serve                       JSON lines for the settings' preview:
      in:  {"id", "media", "style", "mode", "params"?}
           {"id", "media", "all": true, "overrides"?: {style: params}}
      out: {"id", "scheme"} | {"id", "cells": [...]} | {"id", "error"}

A palette is kept per media (path and signature, as theme_palette.sh keys
it) and per what makes it (style, mode, their tuning, the engine's version),
under ~/.cache/pshell/palettes/<media key>/: analysis.json and
pshell-<key>.json. An online wallpaper's stay in memory beside it, under
$THEME_ONLINE_DIR/palettes, and go when it is left.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import settings  # noqa: E402
from version import ANALYSIS_VERSION  # noqa: E402

CACHE = Path(os.environ.get("THEME_PALETTE_DIR")
             or Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell/palettes")
ONLINE = Path(os.environ.get("THEME_ONLINE_DIR")
              or Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "pshell/wallpaper-online")
WALLUST_CONFIG = Path(os.environ.get("WALLUST_CONFIG_FILE") or Path.home() / ".config/wallust/wallust.toml")


def media_key(media: Path) -> str:
    real = os.path.realpath(media)
    st = os.stat(real)
    signature = f"{st.st_dev}:{st.st_ino}:{st.st_size}:{int(st.st_mtime)}"
    return hashlib.sha1(f"{real}\n{signature}\n".encode()).hexdigest()[:16]


def media_root(media: Path) -> Path:
    text = str(media)
    worn = str(ONLINE / "worn") + "/"
    if text.startswith(worn):
        stamp = text[len(worn):].split("/", 1)[0]
        return ONLINE / "palettes" / hashlib.sha1(f"{ONLINE}/worn/{stamp}".encode()).hexdigest()
    return CACHE


def media_dir(media: Path) -> Path:
    return media_root(media) / media_key(media)


def _write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(json.dumps(data, separators=(",", ":")) + "\n")
    os.replace(tmp, path)


def analysis_of(media: Path, memo: dict | None = None) -> dict:
    path = media_dir(media) / "analysis.json"
    if memo is not None and str(path) in memo:
        return memo[str(path)]
    try:
        data = json.loads(path.read_text())
        if data.get("version") != ANALYSIS_VERSION:
            raise ValueError
    except (OSError, ValueError):
        import analysis

        data = analysis.analyse(media)
        _write_json(path, data)
    if memo is not None:
        memo[str(path)] = data
    return data


def scheme_file(media: Path, style: str, mode: str, data=None) -> Path:
    return media_dir(media) / f"pshell-{settings.key(style, mode, data)}.json"


def as_pywal(scheme: dict, wallpaper: str) -> dict:
    """The scheme as wallust's colors.json has it, the rest beside."""
    return {
        "wallpaper": wallpaper,
        "alpha": "100",
        "special": {"background": scheme["background"], "foreground": scheme["foreground"], "cursor": scheme["cursor"]},
        "colors": {f"color{i}": c for i, c in enumerate(scheme["colors"])},
        "roles": scheme["roles"],
        "accents": scheme.get("accents", []),
        "mode": scheme["mode"],
    }


def from_pywal(data: dict) -> dict:
    special = data.get("special") or {}
    colors = data.get("colors") or {}
    return {
        "background": special.get("background", "#000000"),
        "foreground": special.get("foreground", "#FFFFFF"),
        "cursor": special.get("cursor", special.get("foreground", "#FFFFFF")),
        "colors": [colors.get(f"color{i}", "#000000") for i in range(16)],
        "roles": data.get("roles") or {},
    }


def compose(analysis: dict, style: str, mode: str, data=None, params=None) -> dict:
    import engine

    return engine.compose(analysis, params if params is not None else settings.params(style, data), mode)


def make(media: Path, style: str, mode: str) -> Path:
    data = settings.load()
    path = scheme_file(media, style, mode, data)
    if path.is_file() and path.stat().st_size > 0:
        return path
    scheme = compose(analysis_of(media), style, mode, data)
    _write_json(path, as_pywal(scheme, str(media)))
    return path


def cell(scheme: dict, style: str, mode: str, theme: str, theme_path: str, preview: str) -> dict:
    return {
        "theme": theme,
        "themePath": theme_path,
        "previewPath": preview,
        "backend": "pshell",
        "colorSpace": style,
        "palette": mode,
        "background": scheme["background"],
        "foreground": scheme["foreground"],
        "cursor": scheme["cursor"],
        "colors": {f"color{i}": c for i, c in enumerate(scheme["colors"])},
        "swatches": list(scheme["colors"]),
        "roles": scheme["roles"],
        "generatedAt": int(time.time()),
    }


def matrix(theme: str, theme_path: str, media: Path, preview: str, data=None, memo=None) -> dict:
    data = data if data is not None else settings.load()
    analysis = analysis_of(media, memo)
    items = []
    for mode in settings.MODES:
        for style in settings.STYLES:
            items.append(cell(compose(analysis, style, mode, data), style, mode, theme, theme_path, preview))
    return {
        "theme": theme,
        "themePath": theme_path,
        "previewPath": preview,
        "backend": "pshell",
        "colorSpaces": list(settings.STYLES),
        "palettes": settings.MODES,
        "items": items,
    }


def _analyse_one(media: str) -> str:
    try:
        analysis_of(Path(media))
        return ""
    except Exception as error:  # noqa: BLE001
        return f"{media}: {error}"


def matrix_all(lines) -> dict:
    rows = []
    for line in lines:
        fields = line.rstrip("\n").split("\t")
        if len(fields) >= 4 and fields[1]:
            rows.append(fields)
    missing = []
    for fields in rows:
        try:
            if not (media_dir(Path(fields[2])) / "analysis.json").is_file():
                missing.append(fields[2])
        except OSError:
            pass
    if len(missing) > 1:
        from concurrent.futures import ProcessPoolExecutor

        with ProcessPoolExecutor(max_workers=min(len(missing), max(1, (os.cpu_count() or 4) // 2))) as pool:
            for error in pool.map(_analyse_one, missing):
                if error:
                    print(error, file=sys.stderr)
    data = settings.load()
    memo = {}
    matrices = []
    for name, theme_path, media, preview, *_ in rows:
        try:
            matrices.append(matrix(name, theme_path, Path(media), preview, data, memo))
        except Exception as error:  # noqa: BLE001
            print(f"{media}: {error}", file=sys.stderr)
    return {"backend": "pshell", "matrices": matrices}


def prewarm(lines) -> int:
    medias = [Path(line.strip()) for line in lines if line.strip()]
    missing = [str(m) for m in medias if m.exists() and not (media_dir(m) / "analysis.json").is_file()]
    if missing:
        from concurrent.futures import ProcessPoolExecutor

        with ProcessPoolExecutor(max_workers=max(1, min(len(missing), (os.cpu_count() or 4) // 4))) as pool:
            for error in pool.map(_analyse_one, missing):
                if error:
                    print(error, file=sys.stderr)
    data = settings.load()
    chosen = settings.chosen(data)
    cells = [chosen] + [(s, m) for m in settings.MODES for s in settings.STYLES if (s, m) != chosen]
    made = 0
    for style, mode in cells:
        for media in medias:
            try:
                path = scheme_file(media, style, mode, data)
                if not path.is_file():
                    make(media, style, mode)
                    made += 1
            except (OSError, ValueError) as error:
                print(f"{media}: {error}", file=sys.stderr)
    # what an earlier tuning made is not wanted again
    keep = {f"pshell-{settings.key(s, m, data)}.json" for s in settings.STYLES for m in settings.MODES}
    for media in medias:
        try:
            for old in media_dir(media).glob("pshell-*.json"):
                if old.name not in keep:
                    old.unlink(missing_ok=True)
        except OSError:
            pass
    return made


def choose(style: str | None, mode: str | None) -> tuple[str, str]:
    data = settings.load()
    if style in settings.STYLES:
        data["style"] = style
    if mode in settings.MODES:
        data["mode"] = mode
    if style or mode:
        settings.SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = settings.SETTINGS_FILE.with_name(f".{settings.SETTINGS_FILE.name}.{os.getpid()}")
        tmp.write_text(json.dumps(data, indent="\t") + "\n")
        os.replace(tmp, settings.SETTINGS_FILE)
    return settings.chosen(data)


def write_roles_css(scheme: dict, written: list) -> None:
    """pshell-roles.css beside colors.json: the roles as CSS custom
    properties, for sheets that cannot read JSON (Floorp's pshell.css); empty
    for a wallust palette, whose sheets keep their own way."""
    folder = next((p.parent for p in written if p.name == "colors.json"), None)
    if folder is None:
        return
    roles = scheme.get("roles") or {}
    text = ""
    if roles:
        lines = [f"\t--pshell-{name.replace('_', '-')}: {value};" for name, value in sorted(roles.items())]
        text = "/* the Pshell palette engine's roles (scripts/palette) */\n:root {\n" + "\n".join(lines) + "\n}\n"
    path = folder / "pshell-roles.css"
    tmp = path.with_name(f".{path.name}.{os.getpid()}")
    tmp.write_text(text)
    os.replace(tmp, path)


def serve() -> None:
    memo = {}
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        reply = {}
        try:
            request = json.loads(line)
            reply["id"] = request.get("id")
            media = Path(request["media"])
            analysis = analysis_of(media, memo)
            if request.get("all"):
                overrides = request.get("overrides") or {}
                cells = []
                for mode in settings.MODES:
                    for style in settings.STYLES:
                        params = settings.params(style)
                        params.update(overrides.get(style) or {})
                        scheme = compose(analysis, style, mode, params=params)
                        cells.append({"style": style, "mode": mode, **scheme})
                reply["cells"] = cells
            else:
                style = request.get("style") or "vivid"
                params = settings.params(style)
                params.update(request.get("params") or {})
                reply["scheme"] = compose(analysis, style, request.get("mode") or "dark", params=params)
                reply["scheme"]["style"] = style
        except Exception as error:  # noqa: BLE001
            reply["error"] = str(error)
        sys.stdout.write(json.dumps(reply, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    command, args = argv[0], argv[1:]
    data = settings.load()
    style, mode = settings.chosen(data)
    if command == "get":
        what = args[0] if args else "engine"
        print({"engine": settings.engine_name(data), "style": style, "mode": mode}.get(what, ""))
    elif command == "defaults":
        print(json.dumps({"styles": settings.STYLES, "modes": settings.MODES, "engines": settings.ENGINES}))
    elif command == "choose":
        print(*choose(args[0] if args else None, args[1] if len(args) > 1 else None))
    elif command in ("path", "make"):
        media = Path(args[0])
        # what is not a style or mode of this engine (a wallust name an
        # older caller passes) is the chosen one
        if len(args) >= 2 and args[1] in settings.STYLES:
            style = args[1]
        if len(args) >= 3 and args[2] in settings.MODES:
            mode = args[2]
        print(scheme_file(media, style, mode, data) if command == "path" else make(media, style, mode))
    elif command == "apply":
        import templates

        scheme = from_pywal(json.loads(Path(args[0]).read_text()))
        written = templates.write(scheme, args[1] if len(args) > 1 else "", WALLUST_CONFIG)
        write_roles_css(scheme, written)
    elif command == "analyse":
        print(json.dumps(analysis_of(Path(args[0])), indent=1))
    elif command == "matrix":
        print(json.dumps(matrix(args[0] if args[0] else Path(args[1]).stem, args[0], Path(args[1]), args[2]),
                         separators=(",", ":")))
    elif command == "matrix-all":
        print(json.dumps(matrix_all(sys.stdin), separators=(",", ":")))
    elif command == "prewarm":
        prewarm(sys.stdin)
    elif command == "serve":
        serve()
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
