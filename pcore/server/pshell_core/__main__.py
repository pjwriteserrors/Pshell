"""python3 -m pshell_core [--dev] [--state DIR] [--port N] [--web DIR]

In the container everything comes from the environment (CORE_STATE=/state,
HOST_PROC, HOST_SYS, CORE_STORAGE, DOCKER_SOCK; see settings.from_env).
`--dev` runs on the PC: user lu with password `devdevdev` when there is no
user yet, the portal from ../web.
"""
import argparse
from pathlib import Path

from aiohttp import web

from .settings import from_env


def main(argv=None):
    parser = argparse.ArgumentParser(prog="pshell_core")
    parser.add_argument("--dev", action="store_true")
    parser.add_argument("--state")
    parser.add_argument("--port", type=int)
    parser.add_argument("--host")
    parser.add_argument("--web")
    args = parser.parse_args(argv)

    from .app import build, default_web
    config = from_env(state=Path(args.state) if args.state else None, port=args.port, host=args.host,
                      web=Path(args.web) if args.web else None, dev=args.dev or None)
    if config.web is None:
        config.web = default_web()
    app = build(config)
    users = app["auth"].users()
    print(f"pshell-core on http://{config.host}:{config.port} state={config.state} web={config.web}"
          + (" (dev: user lu / devdevdev)" if config.dev else "")
          + ("" if users else " – no user yet: python -m pshell_core.ctl adduser NAME --admin"), flush=True)
    web.run_app(app, host=config.host, port=config.port, print=None, access_log=None)


if __name__ == "__main__":
    main()
