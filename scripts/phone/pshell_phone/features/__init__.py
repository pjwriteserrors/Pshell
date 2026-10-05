"""Every module here has a setup(hub, daemon) that registers its topics."""

import importlib
import pkgutil


def load(hub, daemon):
    for module in sorted(pkgutil.iter_modules(__path__), key=lambda m: m.name):
        importlib.import_module(f"{__name__}.{module.name}").setup(hub, daemon)
