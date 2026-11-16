"""Translation with the file manager's translate.py (Google, or a local
model through Ollama), the result next to the original."""
import os

from . import TaskError, files


def unique(path):
    from ..areas import unique as next_free
    return next_free(path)


def run(ctx, inputs, options):
    if getattr(ctx, "ollama", None):
        os.environ.setdefault("OLLAMA_HOST", ctx.ollama)
    translate = files("translate")
    target = options.get("target", "en")
    engine = options.get("engine", "google")
    outputs = []
    for number, item in enumerate(inputs):
        ctx.check()

        def report(share, number=number):
            ctx.progress((number + share) / len(inputs))
        try:
            made = translate.translate(ctx.fetch(item["path"]), target, engine, unique, report, ctx.check)
        except translate.TranslateError as error:
            raise TaskError(str(error))
        outputs.append(ctx.put_beside(made, options.get("conflict", "rename")))
    return {"outputs": [path for path in outputs if path]}
