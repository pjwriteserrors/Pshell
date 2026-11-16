"""What a picture shows, or the answer to a question about a file – a
vision or text model in Ollama (the PC's by default: the Pi has none)."""
import os

from . import TaskError, files, kind_of
from .media import open_picture

PROMPT = ("Describe this picture in two or three sentences: who or what is in it, where it seems to be, "
          "and any text that is visible.")


def run(ctx, inputs, options):
    if getattr(ctx, "ollama", None):
        os.environ.setdefault("OLLAMA_HOST", ctx.ollama)
    ai = files("ai")
    state = ai.status("describe")
    question = (options.get("question") or "").strip()
    answers = {}
    for number, item in enumerate(inputs):
        ctx.check()
        local = ctx.fetch(item["path"])
        kind = kind_of(item["path"])
        try:
            if kind == "image":
                model = state.get("vision")
                if not model:
                    raise TaskError("No vision model in Ollama here")
                small = os.path.join(ctx.new_folder(f"describe{number}"), "small.jpg")
                open_picture(local, 1024).convert("RGB").save(small, quality=88)
                answers[item["path"]] = ai.generate(model, question or PROMPT, images=[small], timeout=300)
            else:
                model = state.get("text")
                if not model:
                    raise TaskError("No text model in Ollama here")
                text = files("translate").text_of(local)[:12000]
                prompt = (question or "Summarise this document in a few sentences.") + "\n\n---\n" + text
                answers[item["path"]] = ai.generate(model, prompt, timeout=300)
        except ai.AiError as error:
            raise TaskError(str(error))
        ctx.progress((number + 1) / len(inputs))
    return {"describe": answers}
