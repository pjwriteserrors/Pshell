# PDF

`pdf` is the shell's PDF viewer and editor, a window of its own
(`core/services/Pdf.qml`, `core/views/pdf/`, `scripts/pdf/`).
`pdf-default` makes it what PDFs open in everywhere: the desktop entry
"Pshell PDF" (`de.pshell.Pdf.desktop`, `default.py on`) takes
`application/pdf` from the app that had it (remembered in
`~/.local/state/pshell/pdf-default.json`, given back by `default.py off`);
without a running shell `default.py open` starts what was remembered.

    scripts/ipc.sh pdf open <paths, one per line> | page <path> <n> | edit <path> <tool>
                       | search <path> <text> | start | window | close | go <n>
                       | next | previous | save | present | act <name>
                       | set <name> <json> | recipe | state

`edit` takes a tool: annotate, pages, text, forms, sign, redact, stamp,
layout, crop, export, security, info, compare, scan, ai (or "" for none).
`act` does what a key of the window does: edit, read, search, sidebar,
outline, pages, night, layout, fit-width, fit-page, zoom-in, zoom-out,
present, undo, redo, save, tool-<name>, draw-<name>, rotate, delete-page.
Every `: void` function of the `pdf` target can be put on a key in Pshell
settings › Keybinds.

## How it draws

QtQuick.Pdf (PDFium, it comes with qt6-webengine) draws the pages inside the
shell's scene: only the views import it, and the window is loaded by URL, so
a machine without it only misses this window. A page shows a small picture
at once and the sharp one when it is ready; deep zoom asks the helper for a
tile of what is seen (`render`, pdftoppm with a clip). The window is built a
few seconds after the shell starts and kept when it closes, so a document
opens at once; it floats (`dotfiles/niri/pshell.kdl`, title "<name> – PDF").

Everything heavy is `scripts/pdf/pdf.py`, lines of JSON over stdin like the
video's helper: reading a file (`probe`, fast on 500 pages), taking its
annotations out of the copy that is drawn (`strip`, so they become editable
items), words with their boxes, fonts and colours under a spot, tiles,
finding (presets: IBAN, e-mail, phone, date, amount, names), text, invoices,
tables, blank and skewed pages, attachments, signatures, and writing the
recipe (`apply`). It uses pikepdf, poppler, qpdf, Ghostscript, Tesseract,
img2pdf, PIL, numpy and OpenCV; the file manager's tools
(`scripts/files/pdftools.py`) are used as they are. Tests:
`scripts/tests/test_pdf.py`.

## The recipe

What is done to a document is data, shown by the window at once and written
only on saving: the pages in order (each from a source page, a blank page or
a picture, turned and cropped), the items on them, form values, the outline,
the details, attachments, what goes on every page (watermark, numbers,
header, footer, Bates numbers) and the finish (grayscale, flatten,
compress, PDF/A, sanitize, password, OCR, a digital signature). Coordinates
are "page space": points from the top left of the page as it is shown,
before the recipe's own turn, so an item turns and moves with its page.

Items: highlight, underline, strike, squiggly, ink, rect, ellipse, line,
arrow, note, textbox, stamp, link and new form fields are written as real
annotations with their own appearance (every viewer shows them, they stay
editable; flattened only when asked). text (a word or line corrected: the old
one covered, the new one set in a standard font), whiteout, image,
signature and redact are burnt into the page; a black-out makes its page a
picture with black boxes, so nothing is left under them; its other marks and
form fields stay as they were, those lying under a box go with what they hide.

Undo goes back over every step (300). What is left unsaved is kept per file
(`~/.local/state/pshell/pdf-files.json`, with where it was read, the zoom and
the night mode) and comes back when the file is opened again unchanged.
Saving replaces the file (the old one is kept among its versions in
`~/.local/state/pshell/pdf-versions/`, 20 per file) or writes a copy beside
it (setting `saveMode`). Several PDFs opened at once are put together in the
editor; pictures and office files dropped in become pages.

## With the rest of the shell

- **Files**: PDFs open here (Enter, double-click) growing out of their card,
  with the folder's other PDFs to walk; Quick Look hands over the page it
  shows (the window opens there, out of that page), E goes straight into
  the editor. The PDF tools menu starts with "In the PDF editor" (open,
  edit, mark and comment, fill in and sign, black out, pages, present; put
  several together; compare two). Tiles show how far a PDF was read.
- **Launcher `>pdf`** (`>pdfs`, `>docs`): the open one, those half read, the
  folder, the recent ones with their first page; typing looks through the
  names, the open PDF's text (each place with its page) and the text of every
  PDF the file index has read; `12` or `p12` goes to that page. Enter opens
  (at the place found), Ctrl+Enter in the editor, Shift+Enter at page one.
- **Radial menu**: PDF – the window, edit or read, present, night, save.
- **Shelf**: PDFs open here; one can be edited or signed, several are put
  together into one; pages of a document go on the shelf as a PDF or as
  pictures (kept in `~/.cache/pshell/pdf-shelf/`).
- **Downloads**: a downloaded PDF opens here, the toast and the row offer
  Sign.
- **Mail**: a PDF attachment opens here knowing its mail; "Reply with it"
  puts the edited (filled, signed) PDF into the answer of that chat, not sent.
  Send by mail, to a chat, the phone or another PC from the window's share
  menu (ShareTargets, the edited state written first).
- **Selected text**: copy, translate, explain (the local model, the answer in
  the window), ask in the launcher's chat, read aloud, keep as a note, add as
  a task, search the web. Notes and tasks carry a link back to the page
  (`file:///….pdf#page=3`, opened here by Notes and Todos).
- **AI**: ask about the whole document or summarize it in the launcher's
  chat; a file name from what it says (Info, `scripts/files/ai_ask.py` with
  Ollama).
- **Invoices**: a PDF that reads like one gets a chip with the amount, the
  due date and the IBAN (copy each), a task to pay it, and filing a copy in
  `~/Documents/Invoices/<customer or sender>/` (a customer of the mail panel
  when the sender matches one).
- **Tables** of a page as CSV and XLSX beside the PDF.
- **Reading aloud** with speech-dispatcher or espeak-ng.
- **Phone bridge**: a QR code opens a page on the phone (same network, a
  token in the link, closed after ten minutes) to sign with a finger, to
  photograph pages (straightened and cleaned into the document) or to steer
  slides (next, previous, laser, end, the pointer as a touchpad via ydotool).
- **Screentime** counts reading per document ("Reading") while its window is
  the one looked at.
- **Accent**: with `shellAccent` the shell takes the strongest colour of the
  first page while the window is open.
- Window rules know the window as "PDF" (Settings › Window rules).

## What needs what

Rendering: qt6-webengine (QtQuick.Pdf). Compress, PDF/A, grayscale, crop
margins: Ghostscript. OCR: Tesseract (+ its languages). Office files to PDF
and back: LibreOffice. Digital signatures: pyHanko, set up from the window
into `~/.local/share/pshell/pdf-venv`. QR codes: qrencode. AI: Ollama.
