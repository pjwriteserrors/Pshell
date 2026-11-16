"""Into another format, with the file manager's own convert.py."""
from . import FakeJob, TaskError, files


def run(ctx, inputs, options):
    convert = files("convert")
    fmt = str(options.get("format") or "").lower().lstrip(".")
    if not fmt:
        raise TaskError("Pick a format")
    outputs = []
    for number, item in enumerate(inputs):
        ctx.check()
        source = ctx.fetch(item["path"])

        def report(share, number=number):
            ctx.progress((number + share) / len(inputs))
        try:
            target = convert.convert(FakeJob(ctx), source, fmt, report)
        except convert.ConvertError as error:
            raise TaskError(str(error))
        outputs.append(ctx.put_beside(target, options.get("conflict", "rename")))
    return {"outputs": [path for path in outputs if path]}
