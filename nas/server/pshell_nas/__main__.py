"""python3 -m pshell_nas [--dev] [--data DIR] [--state DIR] [--port N] [--area /X=DIR …]

In the container: areas from NAS_AREAS (`/=/storage/filerise/uploads;/Obsidian=/storage/obsidian-vault`)
and the state in NAS_STATE. `--dev` runs on the PC without docker: user lu with password `dev`,
the web interface from ../web, missing tools only switch their features off.
"""
import argparse
import os
import sys
from pathlib import Path

from aiohttp import web

from .config import Config


def parse_areas(items):
    areas = {}
    for item in items:
        prefix, _, real = item.partition("=")
        if not real:
            raise SystemExit(f"--area wants /PREFIX=DIR, not {item}")
        areas[prefix] = real
    return areas


def main(argv=None):
    parser = argparse.ArgumentParser(prog="pshell_nas")
    parser.add_argument("--dev", action="store_true")
    parser.add_argument("--data", help="folder behind /")
    parser.add_argument("--state", default=os.environ.get("NAS_STATE"))
    parser.add_argument("--area", action="append", default=[])
    parser.add_argument("--port", type=int, default=int(os.environ.get("NAS_PORT", "8096")))
    parser.add_argument("--host", default=os.environ.get("NAS_HOST", "0.0.0.0"))
    parser.add_argument("--web", default=os.environ.get("NAS_WEB"))
    parser.add_argument("--name", default=os.environ.get("NAS_NAME", "netcore"))
    args = parser.parse_args(argv)

    from .app import build, default_files, default_web
    areas = {}
    env = os.environ.get("NAS_AREAS", "")
    if env:
        areas = parse_areas([item for item in env.split(";") if item.strip()])
    if args.data:
        areas["/"] = args.data
    areas.update(parse_areas(args.area))
    if "/" not in areas:
        raise SystemExit("No folder for / (give --data DIR or NAS_AREAS)")
    if not args.state:
        raise SystemExit("No state folder (give --state DIR or NAS_STATE)")
    for real in areas.values():
        os.makedirs(real, exist_ok=True)
    state = Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    files = default_files()
    if files and str(files) not in sys.path:
        os.environ.setdefault("NAS_FILES", str(files))
    config = Config(areas=areas, state=state, port=args.port, host=args.host, dev=args.dev,
                    web=Path(args.web) if args.web else default_web(), files=files,
                    models=Path(os.environ.get("NAS_MODELS") or state / "models"), name=args.name)
    app = build(config)
    print(f"pshell-nas on http://{args.host}:{args.port} areas={areas} state={state} web={config.web}"
          + (" (dev: user lu / dev)" if args.dev else ""), flush=True)
    web.run_app(app, host=args.host, port=args.port, print=None, access_log=None)


if __name__ == "__main__":
    main()
