.pragma library

// What a file is, by its type: a kind for grouping and filters, a glyph,
// a colour role of the theme and a short label for cards.

const CODE = /\.(c|h|cc|cpp|hpp|rs|go|py|js|mjs|ts|tsx|jsx|qml|java|kt|kts|swift|rb|php|lua|sh|bash|zsh|fish|pl|r|scala|cs|dart|zig|nim|hs|ml|ex|exs|clj|el|vim|sql|css|scss|sass|less|html|htm|xml|json|jsonc|yaml|yml|toml|ini|conf|cfg|kdl|nix|cmake|mk|gradle|vue|svelte|astro|glsl|frag|vert|wgsl|diff|patch)$/i;
const ARCHIVE = /\.(zip|tar|tgz|gz|xz|zst|bz2|7z|rar|lz|lzma|cab|deb|rpm|apk|jar|txz|tbz2)$/i;
const DISK = /\.(iso|img|qcow2|vdi|vmdk|vhdx?|dmg)$/i;
const APP = /\.(appimage|desktop|exe|msi|run|flatpakref)$/i;
const WEBLINK = /\.(url|webloc)$/i;
const WINDOWS = /\.(exe|msi|msix|appx|com|scr)$/i;
const BOOK = /\.(epub|mobi|azw3|fb2|djvu|cbz|cbr)$/i;
const SHEET = /\.(xlsx?|ods|csv|tsv)$/i;
const SLIDES = /\.(pptx?|odp|key)$/i;

function kindOf(entry) {
	if (!entry) return "other";
	if (entry.dir) return "folder";
	const mime = String(entry.mime || "");
	const name = String(entry.name || "");
	if (mime.startsWith("image/")) return "image";
	if (mime.startsWith("video/")) return "video";
	if (mime.startsWith("audio/")) return "audio";
	if (mime === "application/pdf" || BOOK.test(name)) return "document";
	if (SHEET.test(name) || SLIDES.test(name) || /officedocument|opendocument|msword|ms-excel|ms-powerpoint|rtf/.test(mime)) return "document";
	if (ARCHIVE.test(name) || /zip|tar|compressed|archive|x-7z|rar/.test(mime)) return "archive";
	if (DISK.test(name)) return "disk";
	if (WEBLINK.test(name) || mime === "application/x-mswinurl") return "weblink";
	if (APP.test(name) || entry.exec) return "app";
	if (mime.startsWith("font/") || /font/.test(mime)) return "font";
	if (CODE.test(name)) return "code";
	if (mime.startsWith("text/") || entry.text) return /markdown/.test(mime) || /\.(md|markdown|txt|org|rst|log)$/i.test(name) ? "text" : "code";
	return "other";
}

const LABELS = {
	folder: "Folders", image: "Images", video: "Videos", audio: "Music", document: "Documents",
	text: "Text", code: "Code", archive: "Archives", disk: "Disk images", app: "Apps", font: "Fonts", weblink: "Links", other: "Other"
};
const ORDER = ["folder", "image", "video", "audio", "document", "text", "code", "weblink", "archive", "app", "disk", "font", "other"];

function kindLabel(kind) {
	return LABELS[kind] || "Other";
}

function kindRank(kind) {
	const index = ORDER.indexOf(kind);
	return index < 0 ? ORDER.length : index;
}

function glyphOf(entry) {
	const kind = kindOf(entry);
	const name = String(entry?.name || "");
	switch (kind) {
	case "folder": return entry.link ? "folder_arrow_right_outline" : "folder";
	case "image": return "image_outline";
	case "video": return "filmstrip";
	case "audio": return "music_note";
	case "document":
		if (/\.pdf$/i.test(name) || entry.mime === "application/pdf") return "file_pdf_box";
		if (SHEET.test(name)) return "file_table_outline";
		if (SLIDES.test(name)) return "file_presentation_box";
		if (BOOK.test(name)) return "book_open_page_variant_outline";
		return "file_document_outline";
	case "text": return /\.(md|markdown)$/i.test(name) ? "language_markdown_outline" : "text_box_outline";
	case "code": return "code_braces";
	case "archive": return "package_variant_closed";
	case "disk": return "disc";
	case "app": return WINDOWS.test(name) ? "microsoft_windows" : "application_brackets_outline";
	case "weblink": return "link_variant";
	case "font": return "format_font";
	default: return entry?.broken ? "link_variant_off" : "file_outline";
	}
}

// a role of the theme (Theme.<role>)
function toneOf(entry) {
	switch (kindOf(entry)) {
	case "folder": return "primary";
	case "image": return "tertiary";
	case "video": return "danger";
	case "audio": return "warning";
	case "document": return "secondary";
	case "archive": return "warning";
	case "code": return "success";
	case "text": return "secondary";
	case "app": return "primary";
	case "disk": return "tertiary";
	case "weblink": return "primary";
	default: return "textMuted";
	}
}

// a program for Windows (Wine or Proton runs it)
function isWindows(entry) {
	return !!entry && !entry.dir && WINDOWS.test(String(entry.name || ""));
}

function isWeblink(entry) {
	return !!entry && !entry.dir && (WEBLINK.test(String(entry.name || "")) || entry.mime === "application/x-mswinurl");
}

// "PDF", "PNG", "MP4" … for the corner of a card
function badgeOf(entry) {
	if (!entry || entry.dir) return "";
	const name = String(entry.name || "");
	const dot = name.lastIndexOf(".");
	if (dot <= 0 || dot === name.length - 1) return "";
	const ext = name.slice(dot + 1);
	return ext.length <= 5 ? ext.toUpperCase() : "";
}
