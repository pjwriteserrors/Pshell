"""Bigger pictures. The PC's worker sets `ctx.upscaler(source, target,
scale)` (Real-ESRGAN UltraSharp on the Radeon); anywhere else – the Pi, when
the policy says so – Pillow's Lanczos makes it bigger, without inventing
detail, and the result says so."""
import os

from .media import open_picture


def run(ctx, inputs, options):
    scale = int(options.get("scale") or 4)
    upscaler = getattr(ctx, "upscaler", None)
    outputs = []
    for number, item in enumerate(inputs):
        ctx.check()
        source = ctx.fetch(item["path"])
        stem, ext = os.path.splitext(os.path.basename(source))
        target = os.path.join(os.path.dirname(source), f"{stem} (x{scale}){ext if ext.lower() in ('.png', '.jpg', '.jpeg', '.webp') else '.png'}")
        if upscaler:
            upscaler(source, target, scale)
        else:
            from PIL import Image
            image = open_picture(source, 100000)
            image = image.resize((image.width * scale, image.height * scale), Image.Resampling.LANCZOS)
            if target.lower().endswith((".jpg", ".jpeg")):
                image.convert("RGB").save(target, quality=93)
            else:
                image.save(target)
        outputs.append(ctx.put_beside(target, options.get("conflict", "rename")))
        ctx.progress((number + 1) / len(inputs))
    out = {"outputs": [path for path in outputs if path]}
    if not upscaler:
        out["fallback"] = "lanczos"
        out["note"] = "Made bigger with Lanczos on the NAS (no AI); the PC's UltraSharp gives sharper results."
    return out
