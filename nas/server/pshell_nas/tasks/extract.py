"""Unpacks an archive (the file manager's archives.py) into a folder named
after it, next to it."""
import os
import re

from . import Cancelled, TaskError, files


class Job:
    """What archives.Progress reports into."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.bytes_total = 0
        self.bytes_done = 0
        self.current = ""

    def report(self):
        share = self.bytes_done / self.bytes_total if self.bytes_total else 0
        self.ctx.progress(min(0.99, share), self.current)

    def check(self):
        self.ctx.check()


def run(ctx, inputs, options):
    archives = files("archives")
    outputs = []
    for item in inputs:
        ctx.check()
        local = ctx.fetch(item["path"])
        name = item["path"].rsplit("/", 1)[-1]
        stem = re.sub(r"(\.tar)?\.[A-Za-z0-9]{1,5}$", "", name) or name
        out = os.path.join(ctx.new_folder(f"extract{len(outputs)}"), stem)
        os.makedirs(out)
        try:
            archives.extract(local, out, archives.Progress(Job(ctx)), options.get("password", ""))
        except archives.NeedsPassword:
            raise TaskError("This archive needs a password")
        except Cancelled:
            raise
        except Exception as error:  # noqa: BLE001
            raise TaskError(f"Could not extract {name}: {error}")
        # one folder inside a folder of the same name: no need for both
        inner = os.listdir(out)
        if len(inner) == 1 and inner[0] == stem and os.path.isdir(os.path.join(out, stem)):
            out = os.path.join(out, stem)
        folder = item["path"].rsplit("/", 1)[0] or ""
        outputs.append(ctx.put(out, f"{folder}/{stem}", options.get("conflict", "rename")))
    return {"outputs": [path for path in outputs if path]}
