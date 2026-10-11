"""PDF tools, all on this machine: merge, split, pick and remove pages,
rotate, put in order, compress, to and from pictures, text, page numbers,
a watermark, a signature, passwords on and off, repair, PDF/A, OCR, crop
margins, black out words, compare two, flatten, grayscale, the document's
details, and (with LibreOffice) office files to PDF and back.

Every tool writes new files next to the old ones and never changes a file
in place, so undo only has to put the new ones in the trash.

A tool is `tool(ctx, paths, options) -> [created paths]`; ctx reports
progress and holds or stops between two pages.
"""
import difflib
import io
import os
import re
import shutil
import subprocess
import tempfile
import zlib

import pikepdf

IMAGE = re.compile(r"\.(png|jpe?g|webp|tiff?|bmp|gif|heic|avif)$", re.I)
OFFICE = re.compile(r"\.(docx?|odt|rtf|xlsx?|ods|pptx?|odp|txt|html?)$", re.I)


class ToolError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


# ── helpers ────────────────────────────────────────────────────────────────
def unique(path):
    if not os.path.lexists(path):
        return path
    stem, ext = os.path.splitext(path)
    stem = re.sub(r" \(\d+\)$", "", stem)
    for count in range(2, 10000):
        candidate = f"{stem} ({count}){ext}"
        if not os.path.lexists(candidate):
            return candidate
    raise ToolError("No free name left")


LABELS = re.compile(r" \((compressed|repaired|PDF-A|grayscale|flattened|numbered|watermark|signed|cropped|protected|unlocked|"
                    r"edited|OCR|redacted|rotated|organized|pages removed|pages [^)]*)\)$")


def beside(source, label, ext=".pdf"):
    stem = os.path.splitext(os.path.basename(source))[0]
    # "x (protected)" unlocked is "x (unlocked)", not "x (protected) (unlocked)"
    stem = LABELS.sub("", stem) or stem
    name = f"{stem} ({label}){ext}" if label else f"{stem}{ext}"
    return unique(os.path.join(os.path.dirname(source), name))


def ranges(text, count):
    """ "1-3, 5, 8-" → [0, 1, 2, 4, 7, …]; empty means every page. "last"
    and "-2" (counted from the end) work too."""
    text = str(text or "").strip().lower().replace(" ", "")
    if not text or text == "all":
        return list(range(count))
    out = []

    def number(value, default):
        if value == "":
            return default
        if value in ("last", "end", "n"):
            return count
        n = int(value)
        return count + 1 + n if n < 0 else n

    for part in text.split(","):
        if not part:
            continue
        if re.fullmatch(r"-?\d+|last|end|n", part):
            first = last = number(part, 1)
        else:
            match = re.fullmatch(r"(\d*|last)-(\d*|last|end|n)", part)
            if not match:
                raise ToolError(f"“{part}” is not a page range – write it like 1-3, 5, 8-", "invalid")
            first, last = number(match.group(1), 1), number(match.group(2), count)
        step = 1 if last >= first else -1
        for page in range(first, last + step, step):
            if 1 <= page <= count:
                out.append(page - 1)
    if not out:
        raise ToolError("Those pages are not in the document", "invalid")
    return out


def groups(text, count):
    """ "1-3, 4-6" → [[0,1,2], [3,4,5]] (one file per part)."""
    return [ranges(part, count) for part in str(text).split(",") if part.strip()]


def open_pdf(path, password=""):
    try:
        return pikepdf.open(path, password=password or "")
    except pikepdf.PasswordError:
        raise ToolError(f"{os.path.basename(path)} is locked with a password", "password")
    except pikepdf.PdfError as error:
        raise ToolError(f"{os.path.basename(path)} cannot be read: {error}")


def save(pdf, path, **options):
    pdf.save(path, **options)
    return path


def run(command, ctx=None, timeout=None):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    if ctx is not None:
        ctx.process(process)
    try:
        out, err = process.communicate(timeout=timeout)
    finally:
        if ctx is not None:
            ctx.process(None)
    if ctx is not None:
        ctx.check()
    if process.returncode != 0:
        lines = (err or out or b"").decode("utf-8", "replace").strip().splitlines()
        raise ToolError(lines[-1] if lines else f"{command[0]} failed")
    return out


def need(program, what):
    if not shutil.which(program):
        raise ToolError(f"{what} needs {program}, which is not installed", "missing")


def overlay_page(width, height, content, resources):
    """A one-page PDF to lay over another page."""
    pdf = pikepdf.new()
    page = pdf.add_blank_page(page_size=(width, height))
    page.obj.Resources = pdf.make_indirect(pikepdf.Dictionary(resources(pdf)))
    page.obj.Contents = pdf.make_stream(content.encode("latin-1", "replace"))
    return pdf


def font(pdf, bold=False):
    return pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.Type1,
                              BaseFont=pikepdf.Name("/Helvetica-Bold" if bold else "/Helvetica"),
                              Encoding=pikepdf.Name.WinAnsiEncoding)


def text_width(text, size, bold=False):
    """Helvetica's widths, roughly: enough to centre a line."""
    narrow = "ijlI.,:;'|!()[]f t"
    wide = "mwMW@%"
    total = 0.0
    for char in text:
        total += 0.28 if char in narrow else (0.83 if char in wide else (0.56 if char.isdigit() or char.islower() else 0.67))
    return total * size * (1.06 if bold else 1)


def escape(text):
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def box_of(page):
    box = page.obj.get("/CropBox", page.obj.MediaBox)
    x0, y0, x1, y1 = [float(v) for v in box]
    return x0, y0, x1 - x0, y1 - y0


# ── pages ──────────────────────────────────────────────────────────────────
def merge(ctx, paths, options):
    """PDFs (and pictures, made into pages) one after another."""
    if len(paths) < 2:
        raise ToolError("Pick two or more files to merge", "invalid")
    out = pikepdf.new()
    ctx.total(len(paths))
    temp = tempfile.mkdtemp(prefix="pshell-pdf-")
    try:
        for index, path in enumerate(paths):
            ctx.check()
            ctx.name(os.path.basename(path))
            source = path
            if IMAGE.search(path):
                source = os.path.join(temp, f"{index}.pdf")
                images_to_pdf([path], source)
            pdf = open_pdf(source, options.get("password", ""))
            out.pages.extend(pdf.pages)
            ctx.step()
        name = options.get("name") or "Merged"
        target = unique(os.path.join(os.path.dirname(paths[0]), f"{name}.pdf"))
        return [save(out, target)]
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def split(ctx, paths, options):
    """Every page alone, every n pages, or the ranges given, each a file,
    into a folder named after the document."""
    created = []
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        count = len(pdf.pages)
        how = options.get("how", "each")
        if how == "ranges":
            parts = groups(options.get("pages", ""), count)
        else:
            every = max(1, int(options.get("every", 1) or 1)) if how == "every" else 1
            parts = [list(range(start, min(count, start + every))) for start in range(0, count, every)]
        stem = os.path.splitext(os.path.basename(path))[0]
        folder = unique(os.path.join(os.path.dirname(path), f"{stem} (split)"))
        os.mkdir(folder)
        ctx.total(len(parts))
        width = len(str(count))
        for part in parts:
            ctx.check()
            piece = pikepdf.new()
            for index in part:
                piece.pages.append(pdf.pages[index])
            label = f"{part[0] + 1:0{width}d}" if len(part) == 1 else f"{part[0] + 1:0{width}d}-{part[-1] + 1:0{width}d}"
            save(piece, os.path.join(folder, f"{stem} {label}.pdf"))
            ctx.step()
        created.append(folder)
    return created


def extract(ctx, paths, options):
    """The pages asked for, as a new document."""
    created = []
    ctx.total(len(paths))
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        picked = ranges(options.get("pages", ""), len(pdf.pages))
        out = pikepdf.new()
        for index in picked:
            out.pages.append(pdf.pages[index])
        created.append(save(out, beside(path, f"pages {options.get('pages', '').strip() or 'all'}")))
        ctx.step()
    return created


def remove(ctx, paths, options):
    created = []
    ctx.total(len(paths))
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        drop = set(ranges(options.get("pages", ""), len(pdf.pages)))
        if len(drop) >= len(pdf.pages):
            raise ToolError("That would leave no page", "invalid")
        for index in sorted(drop, reverse=True):
            del pdf.pages[index]
        created.append(save(pdf, beside(path, "pages removed")))
        ctx.step()
    return created


def rotate(ctx, paths, options):
    angle = int(options.get("angle", 90)) % 360
    created = []
    ctx.total(len(paths))
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        for index in ranges(options.get("pages", ""), len(pdf.pages)):
            pdf.pages[index].rotate(angle, relative=True)
        created.append(save(pdf, beside(path, "rotated")))
        ctx.step()
    return created


def organize(ctx, paths, options):
    """The pages in a new order, some turned, some left out (the window's
    page sorter): options.pages = [{ page, rotate }]."""
    path = paths[0]
    pdf = open_pdf(path, options.get("password", ""))
    plan = options.get("pages") or []
    if not plan:
        raise ToolError("No page is left", "invalid")
    out = pikepdf.new()
    ctx.total(len(plan))
    for item in plan:
        ctx.check()
        out.pages.append(pdf.pages[int(item["page"])])
        turn = int(item.get("rotate", 0)) % 360
        if turn:
            out.pages[-1].rotate(turn, relative=True)
        ctx.step()
    return [save(out, beside(path, "organized"))]


# ── size and repair ────────────────────────────────────────────────────────
QUALITY = {"strong": "/screen", "screen": "/screen", "ebook": "/ebook", "recommended": "/ebook", "light": "/printer", "printer": "/printer"}


def compress(ctx, paths, options):
    need("gs", "Compressing")
    level = QUALITY.get(options.get("level", "ebook"), "/ebook")
    created = []
    ctx.total(len(paths))
    for path in paths:
        ctx.name(os.path.basename(path))
        target = beside(path, "compressed")
        run(["gs", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6", f"-dPDFSETTINGS={level}", "-dNOPAUSE", "-dQUIET", "-dBATCH",
             "-dDetectDuplicateImages=true", "-dCompressFonts=true", f"-sOutputFile={target}", path], ctx)
        # a file that did not get smaller is not worth keeping
        if os.path.getsize(target) >= os.path.getsize(path):
            pdf = open_pdf(path, options.get("password", ""))
            pdf.save(target + ".tmp", compress_streams=True, object_stream_mode=pikepdf.ObjectStreamMode.generate, recompress_flate=True)
            os.replace(target + ".tmp", target)
        ctx.report_saving(os.path.getsize(path), os.path.getsize(target))
        created.append(target)
        ctx.step()
    return created


def repair(ctx, paths, options):
    created = []
    ctx.total(len(paths))
    for path in paths:
        target = beside(path, "repaired")
        try:
            pdf = pikepdf.open(path, password=options.get("password", ""), attempt_recovery=True)
            pdf.save(target)
        except (pikepdf.PdfError, OSError):
            need("gs", "Repairing")
            run(["gs", "-o", target, "-sDEVICE=pdfwrite", "-dPDFSETTINGS=/prepress", path], ctx)
        created.append(target)
        ctx.step()
    return created


def pdfa(ctx, paths, options):
    need("gs", "PDF/A")
    created = []
    ctx.total(len(paths))
    for path in paths:
        target = beside(path, "PDF-A")
        run(["gs", "-dPDFA=2", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sColorConversionStrategy=RGB", "-dPDFACompatibilityPolicy=1",
             "-sDEVICE=pdfwrite", f"-sOutputFile={target}", path], ctx)
        created.append(target)
        ctx.step()
    return created


def grayscale(ctx, paths, options):
    need("gs", "Grayscale")
    created = []
    ctx.total(len(paths))
    for path in paths:
        target = beside(path, "grayscale")
        run(["gs", "-sDEVICE=pdfwrite", "-sColorConversionStrategy=Gray", "-dProcessColorModel=/DeviceGray", "-dNOPAUSE",
             "-dBATCH", "-dQUIET", f"-sOutputFile={target}", path], ctx)
        created.append(target)
        ctx.step()
    return created


def flatten(ctx, paths, options):
    """Form fields and notes become part of the page."""
    created = []
    ctx.total(len(paths))
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        pdf.flatten_annotations(mode="all")
        if "/AcroForm" in pdf.Root:
            del pdf.Root.AcroForm
        created.append(save(pdf, beside(path, "flattened")))
        ctx.step()
    return created


# ── to and from other kinds ────────────────────────────────────────────────
def images_to_pdf(images, target):
    """Pictures as pages, each the size it is."""
    from PIL import Image
    if shutil.which("img2pdf") and all(re.search(r"\.(png|jpe?g|tiff?)$", path, re.I) for path in images):
        try:
            run(["img2pdf", "--output", target, *images])
            return target
        except ToolError:
            pass
    pages = []
    for path in images:
        image = Image.open(path)
        image.load()
        if image.mode in ("RGBA", "LA", "P"):
            background = Image.new("RGB", image.size, "white")
            background.paste(image.convert("RGBA"), mask=image.convert("RGBA").split()[-1])
            image = background
        pages.append(image.convert("RGB"))
    pages[0].save(target, "PDF", resolution=150.0, save_all=True, append_images=pages[1:])
    return target


def from_images(ctx, paths, options):
    images = [path for path in paths if IMAGE.search(path)]
    if not images:
        raise ToolError("Pick pictures to make a PDF of", "invalid")
    ctx.total(1)
    name = options.get("name") or (os.path.splitext(os.path.basename(images[0]))[0] if len(images) == 1 else "Pictures")
    target = unique(os.path.join(os.path.dirname(images[0]), f"{name}.pdf"))
    return [images_to_pdf(images, target)]


def to_images(ctx, paths, options):
    need("pdftoppm", "Pictures from a PDF")
    kind = options.get("format", "jpg")
    dpi = int(options.get("dpi", 150) or 150)
    created = []
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        count = len(pdf.pages)
        stem = os.path.splitext(os.path.basename(path))[0]
        folder = unique(os.path.join(os.path.dirname(path), f"{stem} (pictures)"))
        os.mkdir(folder)
        ctx.total(count)
        for page in range(1, count + 1):
            ctx.check()
            run(["pdftoppm", "-jpeg" if kind == "jpg" else "-png", "-r", str(dpi), "-f", str(page), "-l", str(page), "-singlefile",
                 *(["-upw", options["password"]] if options.get("password") else []), path, os.path.join(folder, f"{stem} {page:0{len(str(count))}d}")], ctx)
            ctx.step()
        created.append(folder)
    return created


def to_text(ctx, paths, options):
    need("pdftotext", "Text from a PDF")
    created = []
    ctx.total(len(paths))
    for path in paths:
        target = beside(path, "", ".txt")
        run(["pdftotext", "-layout", path, target], ctx)
        created.append(target)
        ctx.step()
    return created


def images_out(ctx, paths, options):
    need("pdfimages", "Taking the pictures out")
    created = []
    ctx.total(len(paths))
    for path in paths:
        stem = os.path.splitext(os.path.basename(path))[0]
        folder = unique(os.path.join(os.path.dirname(path), f"{stem} (images)"))
        os.mkdir(folder)
        run(["pdfimages", "-all", path, os.path.join(folder, "image")], ctx)
        created.append(folder)
        ctx.step()
    return created


def soffice():
    return shutil.which("soffice") or shutil.which("libreoffice") or ""


def office_to_pdf(ctx, paths, options):
    program = soffice()
    if not program:
        raise ToolError("Office files to PDF needs LibreOffice", "missing")
    created = []
    ctx.total(len(paths))
    for path in paths:
        ctx.name(os.path.basename(path))
        with tempfile.TemporaryDirectory(prefix="pshell-office-") as temp:
            run([program, "--headless", "--convert-to", "pdf", "--outdir", temp, path], ctx, timeout=300)
            made = [name for name in os.listdir(temp) if name.endswith(".pdf")]
            if not made:
                raise ToolError(f"LibreOffice made nothing of {os.path.basename(path)}")
            target = beside(path, "", ".pdf")
            shutil.move(os.path.join(temp, made[0]), target)
        created.append(target)
        ctx.step()
    return created


def pdf_to_office(ctx, paths, options):
    program = soffice()
    if not program:
        raise ToolError("PDF to Word needs LibreOffice", "missing")
    kind = options.get("format", "docx")
    created = []
    ctx.total(len(paths))
    for path in paths:
        with tempfile.TemporaryDirectory(prefix="pshell-office-") as temp:
            run([program, "--headless", "--infilter=writer_pdf_import", "--convert-to", kind, "--outdir", temp, path], ctx, timeout=300)
            made = [name for name in os.listdir(temp) if name.endswith("." + kind)]
            if not made:
                raise ToolError("LibreOffice made nothing of it")
            target = beside(path, "", "." + kind)
            shutil.move(os.path.join(temp, made[0]), target)
        created.append(target)
        ctx.step()
    return created


def browser():
    for name in ("chromium", "google-chrome-stable", "google-chrome", "brave", "vivaldi", "microsoft-edge-stable"):
        if shutil.which(name):
            return shutil.which(name)
    return ""


def html_to_pdf(ctx, paths, options):
    program = browser()
    if not program:
        raise ToolError("Web pages to PDF needs Chromium (or another Chrome)", "missing")
    created = []
    ctx.total(len(paths))
    for path in paths:
        target = beside(path, "", ".pdf")
        source = path if re.match(r"^https?://", path) else "file://" + path
        run([program, "--headless=new", "--disable-gpu", "--no-pdf-header-footer", f"--print-to-pdf={target}", source], ctx, timeout=120)
        created.append(target)
        ctx.step()
    return created


# ── on the pages ───────────────────────────────────────────────────────────
POSITIONS = {
    "bottom": ("center", "bottom"), "bottom-right": ("right", "bottom"), "bottom-left": ("left", "bottom"),
    "top": ("center", "top"), "top-right": ("right", "top"), "top-left": ("left", "top"),
}


def page_numbers(ctx, paths, options):
    where = POSITIONS.get(options.get("position", "bottom"), ("center", "bottom"))
    size = float(options.get("size", 10) or 10)
    start = int(options.get("start", 1) or 1)
    pattern = options.get("format", "{n}")
    margin = 28
    created = []
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        count = len(pdf.pages)
        picked = set(ranges(options.get("pages", ""), count))
        ctx.total(count)
        for index, page in enumerate(pdf.pages):
            ctx.check()
            if index in picked:
                x0, y0, width, height = box_of(page)
                text = pattern.replace("{n}", str(index + start)).replace("{total}", str(count + start - 1))
                w = text_width(text, size)
                x = {"left": margin, "center": (width - w) / 2, "right": width - margin - w}[where[0]]
                y = margin if where[1] == "bottom" else height - margin - size
                stamp = overlay_page(width, height, f"q BT /F1 {size} Tf 0.2 0.2 0.2 rg {x:.2f} {y:.2f} Td ({escape(text)}) Tj ET Q",
                                     lambda doc: {"/Font": pikepdf.Dictionary(F1=font(doc))})
                page.add_overlay(stamp.pages[0], pikepdf.Rectangle(x0, y0, x0 + width, y0 + height))
            ctx.step()
        created.append(save(pdf, beside(path, "numbered")))
    return created


def watermark(ctx, paths, options):
    text = str(options.get("text") or "").strip()
    if not text:
        raise ToolError("Type the watermark's text", "invalid")
    opacity = max(0.05, min(1, float(options.get("opacity", 0.18) or 0.18)))
    diagonal = options.get("layout", "diagonal") == "diagonal"
    created = []
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        count = len(pdf.pages)
        ctx.total(count)
        for page in pdf.pages:
            ctx.check()
            x0, y0, width, height = box_of(page)
            if diagonal:
                size = min(140, (width ** 2 + height ** 2) ** 0.5 * 0.75 / max(1, text_width(text, 1, True)))
                w = text_width(text, size, True)
                angle = __import__("math").atan2(height, width)
                cos, sin = __import__("math").cos(angle), __import__("math").sin(angle)
                cx, cy = width / 2, height / 2
                tx = cx - (w / 2) * cos + (size * 0.35) * sin
                ty = cy - (w / 2) * sin - (size * 0.35) * cos
                content = f"q /GS1 gs BT /F1 {size:.1f} Tf 0.5 0.5 0.5 rg {cos:.4f} {sin:.4f} {-sin:.4f} {cos:.4f} {tx:.2f} {ty:.2f} Tm ({escape(text)}) Tj ET Q"
            else:
                size = float(options.get("size", 28) or 28)
                w = text_width(text, size, True)
                content = f"q /GS1 gs BT /F1 {size:.1f} Tf 0.5 0.5 0.5 rg {(width - w) / 2:.2f} {(height - size) / 2:.2f} Td ({escape(text)}) Tj ET Q"
            stamp = overlay_page(width, height, content, lambda doc: {
                "/Font": pikepdf.Dictionary(F1=font(doc, True)),
                "/ExtGState": pikepdf.Dictionary(GS1=pikepdf.Dictionary(Type=pikepdf.Name.ExtGState, ca=opacity, CA=opacity)),
            })
            page.add_overlay(stamp.pages[0], pikepdf.Rectangle(x0, y0, x0 + width, y0 + height))
            ctx.step()
        created.append(save(pdf, beside(path, "watermark")))
    return created


def sign(ctx, paths, options):
    """A picture of a signature (drawn in the window, or a file) on a page:
    options.image, options.page (1 = first, -1 = last), options.position, options.width (points)."""
    from PIL import Image
    image_path = options.get("image", "")
    if not image_path or not os.path.isfile(image_path):
        raise ToolError("There is no signature to put on", "invalid")
    path = paths[0]
    pdf = open_pdf(path, options.get("password", ""))
    count = len(pdf.pages)
    target_pages = ranges(str(options.get("page", "last")), count) if str(options.get("page", "last")) != "all" else list(range(count))
    picture = Image.open(image_path).convert("RGBA")
    rgb = picture.convert("RGB")
    alpha = picture.split()[-1]
    ctx.total(len(target_pages))
    for index in target_pages:
        ctx.check()
        page = pdf.pages[index]
        x0, y0, width, height = box_of(page)
        w = float(options.get("width", 0) or width * 0.28)
        h = w * picture.height / max(1, picture.width)
        where = POSITIONS.get(options.get("position", "bottom-right"), ("right", "bottom"))
        margin = 42
        x = {"left": margin, "center": (width - w) / 2, "right": width - margin - w}[where[0]]
        y = margin if where[1] == "bottom" else height - margin - h

        def resources(doc):
            mask = pikepdf.Stream(doc, zlib.compress(alpha.tobytes()))
            mask.Type, mask.Subtype = pikepdf.Name.XObject, pikepdf.Name.Image
            mask.Width, mask.Height, mask.ColorSpace, mask.BitsPerComponent = picture.width, picture.height, pikepdf.Name.DeviceGray, 8
            mask.Filter = pikepdf.Name.FlateDecode
            image = pikepdf.Stream(doc, zlib.compress(rgb.tobytes()))
            image.Type, image.Subtype = pikepdf.Name.XObject, pikepdf.Name.Image
            image.Width, image.Height, image.ColorSpace, image.BitsPerComponent = picture.width, picture.height, pikepdf.Name.DeviceRGB, 8
            image.Filter = pikepdf.Name.FlateDecode
            image.SMask = mask
            return {"/XObject": pikepdf.Dictionary(Sig=image)}

        stamp = overlay_page(width, height, f"q {w:.2f} 0 0 {h:.2f} {x:.2f} {y:.2f} cm /Sig Do Q", resources)
        page.add_overlay(stamp.pages[0], pikepdf.Rectangle(x0, y0, x0 + width, y0 + height))
        ctx.step()
    return [save(pdf, beside(path, "signed"))]


def crop(ctx, paths, options):
    """Cuts the empty margins away, page by page (what Ghostscript finds
    drawn on each, plus a little room)."""
    need("gs", "Cropping margins")
    room = float(options.get("margin", 12) or 12)
    created = []
    for path in paths:
        ctx.name(os.path.basename(path))
        out = subprocess.run(["gs", "-q", "-dSAFER", "-dNOPAUSE", "-dBATCH", "-sDEVICE=bbox", path], capture_output=True, text=True, timeout=600)
        boxes = [tuple(float(v) for v in match.groups()) for match in re.finditer(r"%%HiResBoundingBox: ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", out.stderr)]
        pdf = open_pdf(path, options.get("password", ""))
        ctx.total(len(pdf.pages))
        for page, box in zip(pdf.pages, boxes):
            ctx.check()
            media = [float(v) for v in page.obj.MediaBox]
            if box[2] - box[0] < 4 or box[3] - box[1] < 4:
                ctx.step()
                continue
            # the box is measured from the page's corner
            left, bottom = media[0] + box[0] - room, media[1] + box[1] - room
            right, top = media[0] + box[2] + room, media[1] + box[3] + room
            page.obj.CropBox = pikepdf.Array([max(media[0], left), max(media[1], bottom), min(media[2], right), min(media[3], top)])
            ctx.step()
        created.append(save(pdf, beside(path, "cropped")))
    return created


# ── passwords ──────────────────────────────────────────────────────────────
def protect(ctx, paths, options):
    password = str(options.get("newPassword") or "")
    if len(password) < 1:
        raise ToolError("Type a password", "invalid")
    created = []
    ctx.total(len(paths))
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        permissions = pikepdf.Permissions(extract=not options.get("noCopy"), print_highres=not options.get("noPrint"),
                                          print_lowres=not options.get("noPrint"), modify_other=not options.get("noEdit"))
        created.append(save(pdf, beside(path, "protected"), encryption=pikepdf.Encryption(user=password, owner=password, aes=True, R=6, allow=permissions)))
        ctx.step()
    return created


def unlock(ctx, paths, options):
    created = []
    ctx.total(len(paths))
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        created.append(save(pdf, beside(path, "unlocked")))
        ctx.step()
    return created


def metadata(ctx, paths, options):
    path = paths[0]
    pdf = open_pdf(path, options.get("password", ""))
    with pdf.open_metadata() as meta:
        for key, field in (("title", "dc:title"), ("author", "dc:creator"), ("subject", "dc:description"), ("keywords", "pdf:Keywords")):
            if key in options:
                value = str(options[key]).strip()
                if field == "dc:creator":
                    meta[field] = [value] if value else []
                else:
                    meta[field] = value
    ctx.total(1)
    return [save(pdf, beside(path, "edited"))]


def read_metadata(path):
    try:
        with pikepdf.open(path) as pdf:
            info = pdf.docinfo
            return {
                "title": str(info.get("/Title", "")), "author": str(info.get("/Author", "")),
                "subject": str(info.get("/Subject", "")), "keywords": str(info.get("/Keywords", "")),
                "pages": len(pdf.pages), "encrypted": pdf.is_encrypted,
            }
    except pikepdf.PasswordError:
        return {"encrypted": True, "locked": True}
    except Exception as error:
        return {"error": str(error)}


# ── reading the text ───────────────────────────────────────────────────────
def ocr(ctx, paths, options):
    """Makes scanned pages searchable: Tesseract reads each page and its
    text is laid, invisible, over the page as it was."""
    need("tesseract", "OCR")
    need("pdftoppm", "OCR")
    languages = options.get("languages") or "+".join(lang for lang in ("deu", "eng") if lang in tesseract_languages()) or "eng"
    created = []
    for path in paths:
        pdf = open_pdf(path, options.get("password", ""))
        count = len(pdf.pages)
        ctx.total(count)
        with tempfile.TemporaryDirectory(prefix="pshell-ocr-") as temp:
            for index, page in enumerate(pdf.pages):
                ctx.check()
                ctx.name(f"Page {index + 1} of {count}")
                # a page that has its text already keeps it as it is
                known = run(["pdftotext", "-f", str(index + 1), "-l", str(index + 1), path, "-"], ctx).decode("utf-8", "replace")
                if len(known.strip()) > 40 and not options.get("force"):
                    ctx.step()
                    continue
                picture = os.path.join(temp, f"p{index}")
                run(["pdftoppm", "-r", "300", "-gray", "-png", "-f", str(index + 1), "-l", str(index + 1), "-singlefile", path, picture], ctx)
                run(["tesseract", picture + ".png", picture, "-l", languages, "--dpi", "300", "-c", "textonly_pdf=1", "pdf"], ctx)
                layer = pikepdf.open(picture + ".pdf")
                x0, y0, width, height = box_of(page)
                media = [float(v) for v in page.obj.MediaBox]
                page.add_overlay(layer.pages[0], pikepdf.Rectangle(media[0], media[1], media[2], media[3]))
                ctx.step()
            created.append(save(pdf, beside(path, "OCR")))
    return created


def tesseract_languages():
    try:
        out = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True, timeout=5).stdout
        return [line.strip() for line in out.splitlines()[1:] if line.strip()]
    except (OSError, subprocess.SubprocessError):
        return []


def redact(ctx, paths, options):
    """Blacks words out for good: the pages they are on become pictures
    with black boxes where the words were, so nothing is left under them."""
    need("pdftotext", "Blacking out")
    need("pdftoppm", "Blacking out")
    from PIL import Image, ImageDraw
    words = [word.strip().casefold() for word in re.split(r"[,\n]", str(options.get("words", ""))) if word.strip()]
    if not words:
        raise ToolError("Type the words to black out", "invalid")
    created = []
    for path in paths:
        html = run(["pdftotext", "-bbox", path, "-"]).decode("utf-8", "replace")
        hits = {}
        for number, page_html in enumerate(re.findall(r"<page[^>]*>(.*?)</page>", html, re.S)):
            tokens = [(float(a), float(b), float(c), float(d), unescape(text)) for a, b, c, d, text in
                      re.findall(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>', page_html)]
            for phrase in words:
                parts = phrase.split()
                for start in range(len(tokens)):
                    window = tokens[start:start + len(parts)]
                    if len(window) < len(parts):
                        break
                    if all(part in token[4].casefold() if len(parts) == 1 else token[4].casefold().strip(".,;:!?()\"'") == part
                           for part, token in zip(parts, window)):
                        hits.setdefault(number, []).extend(window)
        pdf = open_pdf(path, options.get("password", ""))
        if not hits:
            raise ToolError("None of those words is in the text (scanned pages need OCR first)", "nothing")
        ctx.total(len(hits))
        with tempfile.TemporaryDirectory(prefix="pshell-redact-") as temp:
            for number, boxes in sorted(hits.items()):
                ctx.check()
                page = pdf.pages[number]
                media = [float(v) for v in page.obj.MediaBox]
                picture = os.path.join(temp, f"p{number}")
                dpi = 200
                run(["pdftoppm", "-r", str(dpi), "-png", "-f", str(number + 1), "-l", str(number + 1), "-singlefile", path, picture], ctx)
                image = Image.open(picture + ".png").convert("RGB")
                scale = dpi / 72
                draw = ImageDraw.Draw(image)
                for x1, y1, x2, y2, _ in boxes:
                    draw.rectangle([x1 * scale - 2, y1 * scale - 2, x2 * scale + 2, y2 * scale + 2], fill="black")
                buffer = io.BytesIO()
                image.save(buffer, "PDF", resolution=dpi)
                flat = pikepdf.open(io.BytesIO(buffer.getvalue()))
                replacement = flat.pages[0]
                replacement.obj.MediaBox = pikepdf.Array(media)
                pdf.pages.insert(number, replacement)
                del pdf.pages[number + 1]
                ctx.step()
            created.append(save(pdf, beside(path, "redacted")))
    return created


def unescape(text):
    return text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'")


def compare(ctx, paths, options):
    """What changed between two PDFs, page by page, in their text."""
    if len(paths) != 2:
        raise ToolError("Pick exactly two PDFs to compare", "invalid")
    need("pdftotext", "Comparing")
    texts = [run(["pdftotext", "-layout", path, "-"]).decode("utf-8", "replace").rstrip("\f\n ").split("\f") for path in paths]
    pages = max(len(texts[0]), len(texts[1]))
    ctx.total(pages)
    changes = []
    for index in range(pages):
        ctx.check()
        a = (texts[0][index] if index < len(texts[0]) else "").splitlines()
        b = (texts[1][index] if index < len(texts[1]) else "").splitlines()
        lines = []
        for line in difflib.unified_diff([line.rstrip() for line in a], [line.rstrip() for line in b], lineterm="", n=0):
            if line.startswith(("---", "+++", "@@")):
                continue
            if line[1:].strip():
                lines.append({"kind": "added" if line[0] == "+" else "removed", "text": line[1:].strip()[:200]})
        if lines:
            changes.append({"page": index + 1, "lines": lines[:60]})
        ctx.step()
    ctx.result({"compare": {"a": os.path.basename(paths[0]), "b": os.path.basename(paths[1]), "pages": pages, "changes": changes[:200]}})
    return []


TOOLS = {
    "merge": merge, "split": split, "extract": extract, "remove": remove, "rotate": rotate, "organize": organize,
    "compress": compress, "repair": repair, "pdfa": pdfa, "grayscale": grayscale, "flatten": flatten,
    "fromimages": from_images, "toimages": to_images, "totext": to_text, "imagesout": images_out,
    "officetopdf": office_to_pdf, "tooffice": pdf_to_office, "htmltopdf": html_to_pdf,
    "pagenumbers": page_numbers, "watermark": watermark, "sign": sign, "crop": crop,
    "protect": protect, "unlock": unlock, "metadata": metadata, "ocr": ocr, "redact": redact, "compare": compare,
}

TITLES = {
    "merge": "Merging", "split": "Splitting", "extract": "Taking pages out of", "remove": "Removing pages of",
    "rotate": "Rotating", "organize": "Putting in order", "compress": "Compressing", "repair": "Repairing",
    "pdfa": "Making PDF/A of", "grayscale": "Making grayscale", "flatten": "Flattening", "fromimages": "Making a PDF of",
    "toimages": "Making pictures of", "totext": "Taking the text of", "imagesout": "Taking pictures out of",
    "officetopdf": "Making a PDF of", "tooffice": "Converting", "htmltopdf": "Making a PDF of",
    "pagenumbers": "Numbering", "watermark": "Watermarking", "sign": "Signing", "crop": "Cropping",
    "protect": "Locking", "unlock": "Unlocking", "metadata": "Editing", "ocr": "Reading the text of",
    "redact": "Blacking out", "compare": "Comparing",
}


def available():
    """Which tools work here, and what the others lack."""
    missing = {}
    if not soffice():
        missing.update({"officetopdf": "LibreOffice", "tooffice": "LibreOffice"})
    if not browser():
        missing["htmltopdf"] = "Chromium"
    if not shutil.which("gs"):
        missing.update({"compress": "Ghostscript", "pdfa": "Ghostscript", "grayscale": "Ghostscript", "crop": "Ghostscript"})
    if not shutil.which("tesseract"):
        missing["ocr"] = "Tesseract"
    if not shutil.which("pdftoppm"):
        missing.update({"toimages": "poppler", "ocr": "poppler", "redact": "poppler"})
    return {"missing": missing, "languages": tesseract_languages()}
