"""Picture tools: the file manager's imagetools.py (resize, crop, rotate,
flip, watermark, strip the location)."""
from . import TaskError, files


def unique(path):
    from ..areas import unique as next_free
    return next_free(path)


def run(ctx, inputs, options):
    imagetools = files("imagetools")
    tool = options.get("tool") or "resize"
    outputs = []
    for number, item in enumerate(inputs):
        ctx.check()
        try:
            made = imagetools.edit(tool, ctx.fetch(item["path"]), dict(options), unique)
        except imagetools.ImageError as error:
            raise TaskError(str(error))
        outputs.append(ctx.put_beside(made, options.get("conflict", "rename")))
        ctx.progress((number + 1) / len(inputs))
    return {"outputs": [path for path in outputs if path]}
