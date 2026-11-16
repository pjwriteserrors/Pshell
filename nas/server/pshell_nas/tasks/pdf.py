"""PDF tools: the file manager's pdftools.py, its results put next to the
first input on the NAS."""
import os

from . import PdfCtx, TaskError, files


def run(ctx, inputs, options):
    pdftools = files("pdftools")
    op = options.get("op") or ""
    tool = pdftools.TOOLS.get(op)
    if tool is None:
        raise TaskError(f"Unknown PDF tool {op}")
    local = [ctx.fetch(item["path"]) for item in inputs]
    pctx = PdfCtx(ctx)
    try:
        created = tool(pctx, local, dict(options)) or []
    except pdftools.ToolError as error:
        raise TaskError(str(error))
    outputs = []
    conflict = options.get("conflict", "rename")
    for path in created:
        if os.path.exists(path):
            outputs.append(ctx.put_beside(path, conflict))
    ctx.progress(1.0)
    out = {"outputs": [path for path in outputs if path]}
    if pctx.data:
        out["data"] = pctx.data
    return out
