"""Music tags with the file manager's mediatags.py: read them, or write the
fields given (the old file goes to the trash, so it is a version)."""
from . import TaskError, files

FIELDS = ("title", "artist", "album", "album_artist", "date", "track", "disc", "genre", "composer", "comment")


def run(ctx, inputs, options):
    mediatags = files("mediatags")
    action = options.get("action", "read")
    found = {}
    outputs = []
    for number, item in enumerate(inputs):
        ctx.check()
        local = ctx.fetch(item["path"])
        try:
            if action == "write":
                tags = {key: str(options[key]) for key in FIELDS if options.get(key) not in (None, "")}
                if not tags:
                    raise TaskError("No tags given")
                written = mediatags.write(local, tags)
                outputs.append(ctx.put(written, item["path"], "overwrite"))
            found[item["path"]] = mediatags.read(local)
        except mediatags.TagError as error:
            raise TaskError(str(error))
        ctx.progress((number + 1) / len(inputs))
    return {"tags": found, "outputs": [path for path in outputs if path]}
