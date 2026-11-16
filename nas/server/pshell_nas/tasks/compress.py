"""Packs the inputs into one archive next to the first of them."""
import os
import shutil
import tarfile
import zipfile

from . import TaskError
from .media import run as tool


def run(ctx, inputs, options):
    fmt = options.get("format", "zip")
    local = [ctx.fetch(item["path"]) for item in inputs]
    first = inputs[0]["path"].rsplit("/", 1)[-1]
    name = (options.get("name") or (os.path.splitext(first)[0] if len(inputs) == 1 else "Archive")).strip("/ ")
    out_dir = ctx.new_folder("archive")
    extension = {"zip": ".zip", "7z": ".7z", "tar.gz": ".tar.gz"}.get(fmt)
    if not extension:
        raise TaskError(f"Unknown format {fmt}")
    target = os.path.join(out_dir, name + extension)
    total = sum(tree_size(path) for path in local) or 1
    done = [0]

    def count(size):
        done[0] += size
        ctx.progress(min(0.99, done[0] / total))

    if fmt == "zip":
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            for path in local:
                for full, arc in walk(path):
                    ctx.check()
                    archive.write(full, arc)
                    count(os.path.getsize(full))
    elif fmt == "tar.gz":
        with tarfile.open(target, "w:gz") as archive:
            for path in local:
                for full, arc in walk(path):
                    ctx.check()
                    archive.add(full, arc, recursive=False)
                    count(os.path.getsize(full))
    else:
        seven = shutil.which("7z") or shutil.which("7za")
        if not seven:
            raise TaskError("7z is not installed")
        command = [seven, "a", "-bd", "-y", "-l", target, *local]
        if options.get("password"):
            command.insert(2, f"-p{options['password']}")
            command.insert(3, "-mhe=on")
        tool(command, ctx, 24 * 3600)
    folder = inputs[0]["path"].rsplit("/", 1)[0] or ""
    landed = ctx.put(target, f"{folder}/{os.path.basename(target)}", options.get("conflict", "rename"))
    return {"outputs": [landed] if landed else []}


def walk(path):
    base = os.path.basename(path)
    if not os.path.isdir(path):
        yield path, base
        return
    for folder, dirs, files in os.walk(path, followlinks=True):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(folder, name)
            yield full, os.path.join(base, os.path.relpath(full, path))


def tree_size(path):
    if not os.path.isdir(path):
        return os.path.getsize(path)
    return sum(os.path.getsize(full) for full, _ in walk(path))
