// Everything the files can do, in one place (Commands.qml): the right-click
// menus, the command palette and the keys all come from here. The compute
// tasks are built from GET /api/tasks/types; the known ones get the file
// manager's wording and menus, unknown ones still show up under "More tasks".
import { h, icon, nameOf, parentOf, join, plural, copyText, extOf, kindOf, size as fmtSize, when, fullDate } from "./util.js";
import * as api from "./api.js";
import { state, setFavorite, rememberTags, setClipboard, setting, isAdmin } from "./store.js";
import { toast, errorToast, confirm, prompt, formDialog, openDialog, choiceValue, choiceLabel } from "./ui.js";
import * as uploads from "./uploads.js";
import * as jobs from "./jobs.js";

const app = () => window.nasApp;

// ── task types ─────────────────────────────────────────────────────────────
const TYPE_ICON = {
	thumb: "image_refresh_outline", preview: "filmstrip", convert: "swap_horizontal", avscan: "shield_search", vtscan: "shield_check_outline",
	pdf: "file_pdf_box", image: "image_edit_outline", tags: "tag_text_outline", compress: "zip_box_outline", extract: "package_variant",
	hash: "pound", embed: "creation", faces: "face_recognition", exif: "map_marker_outline", upscale: "auto_fix", transcode: "movie_open_play_outline",
	translate: "translate", describe: "chat_question_outline"
};

export function typeIcon(type) {
	return TYPE_ICON[type?.type ?? type] || "cog_outline";
}

export function typeOf(name) {
	return state.types.find(t => t.type === name) || null;
}

// does a task type take these rows? kinds [] = everything
function takes(type, rows) {
	if (!type) return false;
	const kinds = type.kinds || [];
	if (!kinds.length || kinds.includes("*") || kinds.includes("any")) return true;
	return rows.length > 0 && rows.every(row => !row.dir && kinds.includes(row.kind));
}

// what one option means for a pdf / picture tool (the file manager's dialogs)
const PDF_TOOLS = {
	merge: { label: n => `Merge ${n} into one…`, icon: "call_merge", opts: ["name"], many: true, group: "Pages" },
	split: { label: "Split…", icon: "call_split", opts: ["pages"], group: "Pages", hint: { pages: "Where to cut, e.g. 3,7 – empty: every page" } },
	extract: { label: "Take pages out…", icon: "file_move_outline", opts: ["pages"], group: "Pages", hint: { pages: "e.g. 1-3,8" } },
	remove: { label: "Remove pages…", icon: "file_remove_outline", opts: ["pages"], group: "Pages", hint: { pages: "e.g. 2,5-6" } },
	rotate: { label: "Rotate…", icon: "rotate_right", opts: ["degrees", "pages"], group: "Pages", hint: { pages: "Empty: all pages" } },
	organize: { label: "Organize pages…", icon: "view_grid_outline", opts: ["pages"], one: true, group: "Pages", hint: { pages: "The new order, e.g. 3,1,2" } },
	pagenumbers: { label: "Page numbers", icon: "format_list_numbered", opts: [], group: "On the pages" },
	watermark: { label: "Watermark…", icon: "water_outline", opts: ["text"], group: "On the pages" },
	crop: { label: "Crop the margins", icon: "crop", opts: [], group: "On the pages" },
	flatten: { label: "Flatten forms and notes", icon: "layers_outline", opts: [], group: "On the pages" },
	grayscale: { label: "Grayscale", icon: "format_color_fill", opts: [], group: "On the pages" },
	toimages: { label: "To pictures", icon: "image_multiple_outline", opts: [], group: "Convert" },
	totext: { label: "To text", icon: "text_box_outline", opts: [], group: "Convert" },
	tooffice: { label: "To Word", icon: "file_word_outline", opts: [], group: "Convert" },
	imagesout: { label: "Take the pictures out", icon: "file_image_outline", opts: [], group: "Convert" },
	pdfa: { label: "To PDF/A (for archiving)", icon: "archive_outline", opts: [], group: "Convert" },
	compress: { label: "Compress…", icon: "arrow_collapse_vertical", opts: ["quality"], group: "Size, safety, repair" },
	protect: { label: "Lock with a password…", icon: "lock_outline", opts: ["password"], group: "Size, safety, repair" },
	unlock: { label: "Remove the password…", icon: "lock_open_variant_outline", opts: ["password"], group: "Size, safety, repair" },
	ocr: { label: "Make the text searchable (OCR)", icon: "text_recognition", opts: [], group: "Size, safety, repair" },
	repair: { label: "Repair", icon: "wrench_outline", opts: [], group: "Size, safety, repair" },
	metadata: { label: "Title and author…", icon: "information_variant", opts: ["text", "name"], one: true, group: "Size, safety, repair", labels: { text: "Title", name: "Author" } },
	compare: { label: "Compare the two", icon: "file_compare", opts: [], two: true, group: "Size, safety, repair" }
};

const IMAGE_TOOLS = [
	{ tool: "resize", label: "Resize…", icon: "resize", opts: ["longest"] },
	{ tool: "rotate", label: "Turn left", icon: "rotate_left", preset: { degrees: 270 }, opts: [] },
	{ tool: "rotate", label: "Turn right", icon: "rotate_right", preset: { degrees: 90 }, opts: [] },
	{ tool: "flip", label: "Mirror", icon: "flip_horizontal", opts: [] },
	{ tool: "crop", label: "Crop…", icon: "crop", opts: null },
	{ tool: "watermark", label: "Watermark…", icon: "water_outline", opts: ["text"] },
	{ tool: "strip", label: "Remove location and camera data", icon: "map_marker_off_outline", opts: [] }
];

const CONVERT_FOR = {
	image: ["jpg", "png", "webp", "avif", "heic", "jxl", "bmp", "tiff", "ico", "pdf"],
	video: ["mp4", "webm", "mkv", "gif", "mp3", "m4a", "ogg", "opus", "flac", "wav"],
	audio: ["mp3", "m4a", "ogg", "opus", "flac", "wav"]
};

// start a task; with a form first when it has options to ask
export async function runTask(typeName, rows, { preset = {}, ask = null, label, labels = {}, hints = {}, quiet = false } = {}) {
	const type = typeOf(typeName);
	const paths = rows.map(r => (typeof r === "string" ? r : r.path));
	let options = { ...preset };
	const all = (type?.options || []).filter(o => !(o.key in preset));
	const fields = all.filter(o => ask === null || ask.includes(o.key) || (o.key === "conflict" && ask.length > 0))
		.map(o => ({ key: o.key, label: labels[o.key] || o.label, type: o.key === "password" ? "password" : o.type, choices: o.choices, default: o.default, hint: hints[o.key] }));
	// the defaults of what is not asked
	for (const o of type?.options || []) if (!(o.key in options) && o.default !== undefined && o.default !== null && o.default !== "") options[o.key] = o.default;
	if (fields.length) {
		const values = await formDialog({
			title: label || type?.label || typeName,
			icon: typeIcon(typeName),
			subtitle: paths.length === 1 ? nameOf(paths[0]) : plural(paths.length, "item"),
			fields,
			confirmLabel: "Start"
		});
		if (!values) return null;
		options = { ...options, ...values };
	}
	// empty texts are not sent
	for (const [k, v] of Object.entries(options)) if (v === "") delete options[k];
	try {
		const result = await api.post("/api/tasks", { type: typeName, paths, options });
		jobs.addTask({ id: result.id, type: typeName, label: label || type?.label || typeName, state: "queued", paths, progress: 0, icon: typeIcon(typeName) });
		if (!quiet) {
			const where = state.status?.worker?.connected ? "on the PC" : setting("pi_compute", true) === false || type?.policy === "pc" ? "– waits for the PC" : "on the Pi";
			toast(`${label || type?.label || typeName} ${where.startsWith("–") ? where : `started ${where}`}`, { icon: typeIcon(typeName), timeout: 2600, action: { label: "Tasks", run: () => app().go("#/tasks") } });
		}
		return result.id;
	} catch (error) {
		errorToast(error, label || type?.label || typeName);
		return null;
	}
}

function pdfEntries(rows) {
	const type = typeOf("pdf");
	if (!type) return [];
	const pdfs = rows.filter(r => r.kind === "pdf" || r.mime === "application/pdf");
	const mergeable = rows.filter(r => r.kind === "pdf" || r.kind === "image");
	const ops = (type.options.find(o => o.key === "op")?.choices || []).map(choiceValue);
	const out = [];
	let group = "";
	for (const op of ops) {
		const tool = PDF_TOOLS[op];
		if (!tool) continue;
		if (tool.many && mergeable.length < 2) continue;
		if (tool.one && pdfs.length !== 1) continue;
		if (tool.two && pdfs.length !== 2) continue;
		if (!tool.many && !pdfs.length) continue;
		if (tool.group !== group) {
			out.push({ header: tool.group });
			group = tool.group;
		}
		const label = typeof tool.label === "function" ? tool.label(mergeable.length) : tool.label;
		const targets = tool.many ? mergeable : pdfs;
		out.push({ label, icon: tool.icon, run: () => runTask("pdf", targets, { preset: { op }, ask: tool.opts, label: label.replace(/…$/, ""), labels: tool.labels, hints: tool.hint }) });
	}
	// what is not in the table still shows
	const known = new Set(Object.keys(PDF_TOOLS).concat(["fromimages", "officetopdf", "htmltopdf"]));
	const rest = ops.filter(op => !known.has(op));
	if (rest.length && pdfs.length) {
		out.push({ header: "Other" });
		for (const op of rest) out.push({ label: choiceLabel(op), icon: "file_pdf_box", run: () => runTask("pdf", pdfs, { preset: { op }, label: `PDF: ${choiceLabel(op)}` }) });
	}
	return out;
}

function imageEntries(images) {
	const type = typeOf("image");
	const out = [];
	if (type) {
		const tools = (type.options.find(o => o.key === "tool")?.choices || []).map(choiceValue);
		out.push({ header: "Edit" });
		for (const item of IMAGE_TOOLS) {
			if (!tools.includes(item.tool)) continue;
			out.push({ label: item.label, icon: item.icon, run: () => runTask("image", images, { preset: { tool: item.tool, ...(item.preset || {}) }, ask: item.opts, label: item.label.replace(/…$/, "") }) });
		}
		for (const tool of tools.filter(t => !IMAGE_TOOLS.some(i => i.tool === t))) out.push({ label: choiceLabel(tool), icon: "image_edit_outline", run: () => runTask("image", images, { preset: { tool } }) });
	}
	const up = typeOf("upscale");
	if (up) out.push({ label: images.length === 1 ? "Upscale with AI…" : `Upscale ${images.length} with AI…`, icon: "auto_fix", hint: up.policy === "pc" ? "on the PC" : "", run: () => runTask("upscale", images) });
	out.push({ header: "Use" });
	if (typeOf("pdf")) out.push({ label: images.length === 1 ? "Make a PDF of it" : "Make one PDF of them", icon: "file_pdf_box", run: () => runTask("pdf", images, { preset: { op: "fromimages" }, ask: ["name"], label: "Make a PDF" }) });
	if (typeOf("convert")) out.push(convertEntry(images));
	if (typeOf("describe")) out.push({ label: "Ask AI about it…", icon: "creation", enabled: images.length <= 6, run: () => runTask("describe", images, { label: "Ask AI" }) });
	return out;
}

function convertEntry(rows) {
	const type = typeOf("convert");
	if (!type) return null;
	const kinds = [...new Set(rows.map(r => r.kind))];
	const choices = (type.options.find(o => o.key === "format")?.choices || []).map(choiceValue);
	let targets = choices;
	for (const kind of kinds) targets = targets.filter(t => (CONVERT_FOR[kind] || choices).includes(t));
	const own = new Set(rows.map(r => extOf(r.name)));
	targets = targets.filter(t => !own.has(t) || rows.length > 1);
	if (!targets.length) return { label: "Nothing to convert these to", icon: "swap_horizontal", enabled: false };
	return {
		label: "Convert to",
		icon: "swap_horizontal",
		children: targets.map(t => ({ label: t.toUpperCase(), icon: formatIcon(t), run: () => runTask("convert", rows, { preset: { format: t, conflict: "rename" }, ask: [], label: `Convert to ${t.toUpperCase()}` }) }))
	};
}

function formatIcon(ext) {
	if (["mp3", "m4a", "ogg", "opus", "flac", "wav"].includes(ext)) return "music_note";
	if (["mp4", "webm", "mkv"].includes(ext)) return "movie_outline";
	if (ext === "gif") return "file_gif_box";
	if (ext === "pdf") return "file_pdf_box";
	return "image_outline";
}

// the one submenu "what this kind of file can do" (kindMenu in Commands.qml)
export function kindMenu(rows) {
	const one = rows.length === 1 ? rows[0] : null;
	const dirs = rows.filter(r => r.dir);
	const files = rows.filter(r => !r.dir);
	const all = test => files.length > 0 && dirs.length === 0 && files.every(test);
	if (one?.dir) return { label: "Folder", icon: "folder_open_outline", entries: folderEntries(one.path) };
	if (all(r => r.kind === "image")) return { label: files.length === 1 ? "Edit the picture" : "Edit the pictures", short: "Edit", icon: "image_edit_outline", entries: imageEntries(files) };
	if (all(r => r.kind === "pdf" || r.kind === "image") && files.some(r => r.kind === "pdf")) return { label: "PDF tools", short: "PDF tools", icon: "file_pdf_box", entries: pdfEntries(files) };
	if (all(r => r.kind === "video")) {
		const entries = [{ header: "Edit" }];
		if (typeOf("transcode")) entries.push({ label: "Stream-friendly copy…", icon: "movie_open_play_outline", run: () => runTask("transcode", files) });
		if (typeOf("convert")) {
			entries.push({ label: "Make a GIF", icon: "file_gif_box", enabled: !!one, run: () => runTask("convert", files, { preset: { format: "gif", conflict: "rename" }, ask: [], label: "Make a GIF" }) });
			entries.push({ label: "Take the sound out", icon: "music_box_outline", run: () => runTask("convert", files, { preset: { format: "m4a", conflict: "rename" }, ask: [], label: "Take the sound out" }) });
			entries.push(convertEntry(files));
		}
		if (typeOf("tags")) entries.push({ label: "Edit the tags…", icon: "tag_text_outline", enabled: !!one, run: () => tagsDialog(one) });
		if (typeOf("preview")) entries.push({ label: "Make the scrub preview", icon: "filmstrip", run: () => runTask("preview", files, { quiet: false }) });
		return { label: files.length === 1 ? "Edit the video" : "Edit the videos", short: "Edit", icon: "filmstrip", entries };
	}
	if (all(r => r.kind === "audio")) {
		const entries = [{ header: "Edit" }];
		if (typeOf("tags")) entries.push({ label: "Edit the tags…", icon: "tag_text_outline", enabled: !!one, run: () => tagsDialog(one) });
		if (typeOf("convert")) entries.push(convertEntry(files));
		return { label: files.length === 1 ? "Edit the song" : "Edit the songs", short: "Edit", icon: "music_note", entries };
	}
	if (all(r => r.kind === "office" || /\.(docx?|odt|rtf|xlsx?|ods|pptx?|odp)$/i.test(r.name)) && typeOf("pdf")) return { label: "Make a PDF", short: "PDF", icon: "file_pdf_box", entries: [{ label: "Make a PDF", icon: "file_pdf_box", run: () => runTask("pdf", files, { preset: { op: "officetopdf" }, ask: [], label: "Make a PDF" }) }] };
	if (all(r => /\.html?$/i.test(r.name)) && typeOf("pdf")) return { label: "Make a PDF", short: "PDF", icon: "file_pdf_box", entries: [{ label: "Make a PDF", icon: "file_pdf_box", run: () => runTask("pdf", files, { preset: { op: "htmltopdf" }, ask: [], label: "Make a PDF" }) }] };
	return null;
}

async function tagsDialog(row) {
	let current = {};
	// the tags as they are: a read task would take a round trip; the stat may carry them
	try {
		const stat = await api.get("/api/stat", { path: row.path });
		current = stat.tags_media || stat.media || {};
	} catch (error) {}
	const type = typeOf("tags");
	const fields = (type.options || []).filter(o => o.key !== "action").map(o => ({ key: o.key, label: o.label, type: o.type, default: current[o.key] ?? "" }));
	const values = await formDialog({ title: "Edit the tags", icon: "tag_text_outline", subtitle: row.name, fields, confirmLabel: "Write" });
	if (!values) return;
	const options = { action: "write" };
	for (const [k, v] of Object.entries(values)) if (v !== "") options[k] = v;
	try {
		const result = await api.post("/api/tasks", { type: "tags", paths: [row.path], options });
		jobs.addTask({ id: result.id, type: "tags", label: "Write the tags", state: "queued", progress: 0 });
		toast("Writing the tags", { icon: "tag_text_outline", timeout: 2000 });
	} catch (error) {
		errorToast(error);
	}
}

function folderEntries(folder) {
	return [
		{ label: "What takes the space", icon: "chart_donut", run: () => app().go(`#/storage?path=${encodeURIComponent(folder)}`) },
		{ label: "Find copies in it", icon: "content_duplicate", run: () => app().go(`#/dupes?path=${encodeURIComponent(folder)}`) },
		{ label: "Upload link to it…", icon: "cloud_upload_outline", shown: setting("upload_links", true) !== false, run: () => shareDialog([{ path: folder, name: nameOf(folder), dir: true }], "upload") },
		{ label: "Read it again (index)", icon: "refresh", run: () => api.post("/api/index/rescan", { path: folder }).then(() => toast("Reading the folder again", { icon: "refresh" })).catch(errorToast) },
		{ label: "Git status", icon: "source_branch", run: () => gitDialog(folder) },
		{ separator: true },
		{ label: "Scan for viruses", icon: "shield_search", shown: !!typeOf("avscan"), run: () => runTask("avscan", [folder], { label: "Virus scan" }) }
	];
}

function moreEntries(rows) {
	const one = rows.length === 1 ? rows[0] : null;
	const files = rows.filter(r => !r.dir);
	const out = [];
	const describe = typeOf("describe");
	if (describe && files.length && files.length <= 6 && takes(describe, files)) out.push({ label: files.length === 1 ? "Ask AI about it…" : "Ask AI about them…", icon: "creation", hint: describe.policy === "pc" ? "on the PC" : "", run: () => runTask("describe", files, { label: "Ask AI" }) });
	const translate = typeOf("translate");
	if (translate && files.length && takes(translate, files)) out.push({ label: "Translate…", icon: "translate", run: () => runTask("translate", files) });
	if (out.length) out.push({ separator: true });
	if (one && !one.dir) out.push({ label: "Earlier versions", icon: "history", run: () => versionsDialog(one) });
	if (one && !one.dir) out.push({ label: "Find similar files", icon: "approximately_equal", run: () => app().go(`#/dupes?mode=similar&path=${encodeURIComponent(one.path)}`) });
	if (one && !one.dir) out.push({ label: "Copy the download link", icon: "link_variant", run: () => copyText(new URL(api.fileUrl(one.path, true), location.href).href).then(() => toast("Link copied (works while you are logged in)", { icon: "link_variant" })) });
	out.push({ separator: true });
	if (typeOf("avscan")) out.push({ label: "Scan for viruses", icon: "shield_search", run: () => runTask("avscan", rows, { label: "Virus scan" }) });
	if (typeOf("vtscan") && files.length && files.length <= 20 && files.length === rows.length) out.push({ label: "Check with VirusTotal", icon: "shield_check_outline", hint: setting("vt_upload", false) ? "may upload" : "hash only", run: () => runTask("vtscan", files, { label: "VirusTotal", preset: { upload: !!setting("vt_upload", false) }, ask: [] }) });
	if (typeOf("hash")) out.push({ label: "Checksums", icon: "pound", run: () => runTask("hash", rows, { label: "Checksums" }) });
	// what the index makes by itself, again on request
	const again = ["thumb", "preview", "exif", "faces", "embed"].map(typeOf).filter(t => t && takes(t, rows));
	if (again.length) out.push({ label: "Make again", icon: "image_refresh_outline", children: again.map(t => ({ label: t.label, icon: typeIcon(t.type), run: () => runTask(t.type, rows, { ask: [] }) })) });
	// task types this page does not know yet
	const known = new Set(["thumb", "preview", "convert", "avscan", "vtscan", "pdf", "image", "tags", "compress", "extract", "hash", "embed", "faces", "exif", "upscale", "transcode", "translate", "describe"]);
	const unknown = state.types.filter(t => !known.has(t.type) && takes(t, rows));
	if (unknown.length) out.push({ label: "More tasks", icon: "cog_transfer_outline", children: unknown.map(t => ({ label: `${t.label}…`, icon: typeIcon(t.type), run: () => runTask(t.type, rows) })) });
	return out;
}

function tagEntries(rows) {
	const paths = rows.map(r => r.path);
	const has = tag => rows.every(r => (r.tags || []).includes(tag));
	const out = state.tags.map(tag => ({ label: tag, icon: "tag_outline", checked: has(tag), run: () => toggleTag(rows, tag, !has(tag)) }));
	if (out.length) out.push({ separator: true });
	out.push({ label: "New tag…", icon: "tag_plus_outline", run: async () => {
		const name = await prompt({ title: "New tag", label: "Name of the tag", icon: "tag_plus_outline" });
		if (name) toggleTag(rows, name, true);
	} });
	return out;
}

async function toggleTag(rows, tag, on) {
	try {
		for (const row of rows) {
			const before = row.tags || [];
			const tags = new Set(before);
			if (on) tags.add(tag);
			else tags.delete(tag);
			row.tags = [...tags];
			await api.put("/api/meta", { path: row.path, tags: row.tags });
		}
		if (on) rememberTags([tag]);
		toast(on ? `Tagged “${tag}”` : `“${tag}” taken off`, { icon: "tag_outline", timeout: 1800 });
	} catch (error) {
		errorToast(error);
	}
}

export async function noteDialog(row) {
	const values = await formDialog({ title: "Note", icon: "note_edit_outline", subtitle: row.name, fields: [{ key: "note", label: "", type: "textarea", default: row.note || "", placeholder: "What is it, what is to do with it…" }], confirmLabel: "Save" });
	if (!values) return;
	try {
		await api.put("/api/meta", { path: row.path, note: values.note });
		row.note = values.note;
		toast(values.note ? "Note saved" : "Note removed", { icon: "note_outline", timeout: 1600 });
	} catch (error) {
		errorToast(error);
	}
}

// ── the menu of picked rows (forRows) ─────────────────────────────────────
export function forRows(ctx) {
	const rows = ctx.rows;
	if (!rows.length) return forPlace(ctx);
	const one = rows.length === 1 ? rows[0] : null;
	const dirs = rows.filter(r => r.dir);
	const files = rows.filter(r => !r.dir);
	const paths = rows.map(r => r.path);
	const view = ctx.view;
	const out = [];

	// open
	out.push({ label: one ? "Open" : `Open ${rows.length} items`, icon: "open_in_app", shortcut: "Enter", run: () => view.open(rows) });
	if (one?.dir) out.push({ label: "Open in a new browser tab", icon: "tab_plus", run: () => window.open(`#/files${encodePathLocal(one.path)}`, "_blank") });
	if (one && !one.dir && ["image", "video", "audio", "text", "code"].includes(one.kind)) out.push({ label: "Open in a new browser tab", icon: "open_in_new", run: () => window.open(api.fileUrl(one.path), "_blank") });
	if (ctx.virtual && one) out.push({ label: "Show in its folder", icon: "folder_search_outline", run: () => app().go(`#/files${encodePathLocal(parentOf(one.path))}?select=${encodeURIComponent(one.name)}`) });
	out.push({ label: "Quick look", icon: "eye_outline", shortcut: "Space", run: () => view.quickLook(rows[0]) });
	out.push({ label: rows.length === 1 && !one.dir ? "Download" : "Download as ZIP", icon: "download_outline", run: () => download(rows) });

	// the clipboard and the name
	out.push({ separator: true });
	out.push({ label: "Cut", icon: "content_cut", shortcut: "Ctrl+X", run: () => cut(rows) });
	out.push({ label: "Copy", icon: "content_copy", shortcut: "Ctrl+C", run: () => copy(rows) });
	if (one?.dir && state.clipboard.paths.length) out.push({ label: "Paste into it", icon: "content_paste", run: () => paste(one.path) });
	out.push({ label: "Copy path", icon: "clipboard_text_outline", shortcut: "Ctrl+Shift+C", run: () => copyText(paths.join("\n")).then(() => toast(rows.length === 1 ? "Path copied" : `${rows.length} paths copied`, { icon: "clipboard_text_outline", timeout: 1600 })) });
	out.push({ label: "Duplicate", icon: "content_duplicate", run: () => duplicate(rows) });
	out.push({ label: rows.length === 1 ? "Rename" : `Rename ${rows.length} items`, icon: "form_textbox", shortcut: "F2", run: () => view.rename(rows) });

	// what this kind of file can do
	out.push({ separator: true });
	const own = kindMenu(rows);
	if (own && own.entries.filter(e => !e.header && !e.separator).length) out.push(own.entries.length === 1 ? own.entries[0] : { label: own.label, icon: own.icon, children: own.entries });
	else if (files.length && !dirs.length && typeOf("convert") && takes(typeOf("convert"), files)) out.push(convertEntry(files));
	if (one && one.kind === "archive" && typeOf("extract")) out.push({ label: "Extract here", icon: "package_variant", run: () => runTask("extract", [one], { ask: [], label: "Extract" }) });
	if (typeOf("compress")) out.push({ label: one?.dir ? `Pack “${one.name}” as ZIP…` : "Pack as ZIP…", icon: "zip_box_outline", run: () => runTask("compress", rows, { ask: ["format", "name", "password"], label: "Pack" }) });

	// sorting it away
	out.push({ separator: true });
	if (one) {
		const fav = !!one.favorite || state.favorites.includes(one.path);
		out.push({ label: fav ? "Remove from favorites" : "Add to favorites", icon: fav ? "star_off_outline" : "star_outline", shortcut: "Ctrl+D", run: () => toggleFavorite(one) });
	}
	out.push({ label: "Tags", icon: "tag_outline", children: () => tagEntries(rows) });
	if (one) out.push({ label: one.note ? "Edit the note…" : "Add a note…", icon: "note_edit_outline", run: () => noteDialog(one) });

	// elsewhere
	out.push({ label: "Share", icon: "share_variant_outline", children: [
		{ label: "Download link…", icon: "link_variant", run: () => shareDialog(rows, "download") },
		{ label: "Upload link to it…", icon: "cloud_upload_outline", shown: !!one?.dir && setting("upload_links", true) !== false, run: () => shareDialog(rows, "upload") }
	] });

	const more = moreEntries(rows);
	if (more.length) out.push({ label: "More", icon: "dots_horizontal", children: more });

	out.push({ separator: true });
	out.push({ label: "Move to the trash", icon: "trash_can_outline", danger: true, shortcut: "Del", run: () => trash(rows) });
	if (setting("permanent_delete", false)) out.push({ label: "Delete for good…", icon: "delete_forever_outline", danger: true, shortcut: "Shift+Del", run: () => deleteForGood(rows) });
	out.push({ label: "Properties", icon: "information_outline", shortcut: "Alt+Enter", run: () => view.details?.(rows[0]) });
	return out;
}

// a right click on the empty space of a folder (forPlace)
export function forPlace(ctx) {
	const folder = ctx.folder;
	const view = ctx.view;
	const out = [];
	if (folder && !ctx.virtual) {
		out.push({ label: "New folder", icon: "folder_plus_outline", shortcut: "Ctrl+Shift+N", run: () => newFolder(folder, view) });
		out.push({ label: "New file", icon: "file_plus_outline", children: [
			{ label: "Text file", icon: "text_box_outline", run: () => newFile(folder, "New file.txt", "") },
			{ label: "Markdown note", icon: "language_markdown_outline", run: () => newFile(folder, "Note.md", "# Note\n\n") },
			{ label: "Shell script", icon: "console", run: () => newFile(folder, "script.sh", "#!/usr/bin/env bash\nset -euo pipefail\n\n") }
		] });
		out.push({ label: "Upload files…", icon: "upload_outline", shortcut: "U", run: () => uploads.pick(folder, false) });
		out.push({ label: "Upload a folder…", icon: "folder_arrow_down_outline", run: () => uploads.pick(folder, true) });
		if (state.clipboard.paths.length) out.push({ label: state.clipboard.cut ? `Move ${plural(state.clipboard.paths.length, "item")} here` : `Paste ${plural(state.clipboard.paths.length, "item")}`, icon: "content_paste", shortcut: "Ctrl+V", run: () => paste(folder) });
		out.push({ separator: true });
	}
	if (view.count?.() > 0) out.push({ label: "Pick all", icon: "select_all", shortcut: "Ctrl+A", run: () => view.selectAll() });
	out.push({ label: "View", icon: "eye_outline", children: () => viewEntries(view) });
	if (folder && !ctx.virtual) {
		out.push({ separator: true });
		const fav = state.favorites.includes(folder);
		if (folder !== "/") out.push({ label: fav ? "Remove from favorites" : "Add to favorites", icon: fav ? "star_off_outline" : "star_outline", shortcut: "Ctrl+D", run: () => toggleFavorite({ path: folder, dir: true, favorite: fav }) });
		out.push({ label: "Copy the path", icon: "clipboard_text_outline", run: () => copyText(folder).then(() => toast("Path copied", { icon: "clipboard_text_outline", timeout: 1500 })) });
		out.push({ label: "Download as ZIP", icon: "download_outline", run: () => download([{ path: folder, dir: true, name: nameOf(folder) }]) });
		out.push({ label: "This folder", icon: "folder_open_outline", children: folderEntries(folder) });
	}
	out.push({ separator: true });
	out.push({ label: "Read again", icon: "refresh", shortcut: "Ctrl+R", run: () => view.reload() });
	return out;
}

function viewEntries(view) {
	const v = state.view;
	const set = patch => view.setView(patch);
	return [
		{ header: "Show as" },
		{ label: "Cards", icon: "view_grid_outline", checked: v.mode === "grid", run: () => set({ mode: "grid" }) },
		{ label: "List", icon: "view_list_outline", checked: v.mode === "list", run: () => set({ mode: "list" }) },
		{ header: "Sort by" },
		...[["name", "Name"], ["mtime", "Modified"], ["size", "Size"], ["kind", "Kind"]].map(([key, label]) => ({ label, icon: "sort", checked: v.sort === key, run: () => set({ sort: key }) })),
		{ label: v.desc ? "Descending" : "Ascending", icon: v.desc ? "sort_descending" : "sort_ascending", run: () => set({ desc: !v.desc }) },
		{ header: "Group by" },
		...[["none", "Nothing"], ["kind", "Kind"], ["date", "Date"]].map(([key, label]) => ({ label, icon: "group", checked: v.group === key, run: () => set({ group: key }) })),
		{ separator: true },
		{ label: "Folders first", icon: "folder_outline", checked: v.foldersFirst, run: () => set({ foldersFirst: !v.foldersFirst }) },
		{ label: "Hidden files", icon: "file_hidden", checked: v.hidden, run: () => set({ hidden: !v.hidden }) },
		{ label: "Details panel", icon: "dock_right", checked: v.details, run: () => set({ details: !v.details }) }
	];
}

function encodePathLocal(path) {
	return String(path || "/").split("/").map(encodeURIComponent).join("/").replace(/^\/?/, "/");
}

// ── operations ─────────────────────────────────────────────────────────────
export function download(rows) {
	const one = rows.length === 1 ? rows[0] : null;
	const url = one && !one.dir ? api.fileUrl(one.path, true) : api.zipUrl(rows.map(r => r.path));
	const a = h("a", { href: url, download: one && !one.dir ? one.name : "" });
	document.body.appendChild(a);
	a.click();
	a.remove();
	toast(one && !one.dir ? `Downloading ${one.name}` : "Packing a ZIP while it downloads", { icon: "download_outline", timeout: 2200 });
}

export function copy(rows) {
	setClipboard(rows.map(r => r.path), false);
	toast(rows.length === 1 ? `“${rows[0].name}” copied` : `${rows.length} items copied`, { icon: "content_copy", timeout: 1600 });
}

export function cut(rows) {
	setClipboard(rows.map(r => r.path), true);
	toast(rows.length === 1 ? `“${rows[0].name}” cut` : `${rows.length} items cut`, { icon: "content_cut", timeout: 1600 });
}

export async function paste(folder) {
	const { paths, cut: isCut } = state.clipboard;
	if (!paths.length) return;
	const ok = await transfer(paths, folder, isCut ? "move" : "copy");
	if (ok && isCut) setClipboard([], false);
}

async function namesIn(folder) {
	try {
		const listing = await api.get("/api/ls", { path: folder, hidden: 1 });
		return (listing.entries || []).map(e => e.name);
	} catch (error) {
		return [];
	}
}

// copy or move with the conflict asked first (ConflictDialog.qml)
export async function transfer(paths, to, op = "move", { undoable = true } = {}) {
	paths = paths.filter(p => p !== to && !to.startsWith(`${p}/`) && (op === "copy" || parentOf(p) !== to));
	if (!paths.length) return false;
	let conflict = "rename";
	const existing = await namesIn(to);
	const clashes = paths.map(nameOf).filter(n => existing.includes(n));
	if (clashes.length) {
		conflict = await askConflict(clashes, op);
		if (!conflict) return false;
	}
	try {
		const { job } = await api.post(`/api/${op}`, { paths, to, conflict });
		const label = paths.length === 1 ? `“${nameOf(paths[0])}”` : plural(paths.length, "item");
		jobs.track(job, done => {
			if (done.error) {
				toast(`${op === "move" ? "Moving" : "Copying"} failed`, { tone: "bad", icon: "alert_circle_outline", body: done.error });
				return;
			}
			const from = parentOf(paths[0]);
			const sameFolder = paths.every(p => parentOf(p) === from);
			toast(`${op === "move" ? "Moved" : "Copied"} ${label} to ${to === "/" ? "the top" : nameOf(to)}`, {
				icon: op === "move" ? "folder_move_outline" : "content_copy",
				tone: "good",
				action: op === "move" && undoable && sameFolder && conflict !== "overwrite"
					? { label: "Undo", run: () => transfer(paths.map(p => join(to, nameOf(p))), from, "move", { undoable: false }) }
					: { label: "Show", run: () => app().openFolder(to) }
			});
		});
		return true;
	} catch (error) {
		errorToast(error);
		return false;
	}
}

export function askConflict(names, op = "copy") {
	return new Promise(resolve => {
		let choice = null;
		const body = h("div.conflict",
			h("p", names.length === 1 ? `“${names[0]}” is already there.` : `${names.length} names are already there.`),
			names.length > 1 ? h("ul.confirm-list", names.slice(0, 6).map(n => h("li.ellipsis", n)), names.length > 6 ? h("li.subtle", `and ${names.length - 6} more`) : null) : null);
		openDialog({
			title: op === "move" ? "Move – already there" : "Already there",
			icon: "file_replace_outline",
			tone: "var(--warning)",
			body,
			actions: [
				{ label: "Skip", ghost: true, run: () => { choice = "skip"; } },
				{ label: "Replace", danger: true, run: () => { choice = "overwrite"; } },
				{ label: "Keep both", primary: true, run: () => { choice = "rename"; } }
			],
			onClose: () => resolve(choice)
		});
	});
}

export async function duplicate(rows) {
	const folder = parentOf(rows[0].path);
	try {
		const { job } = await api.post("/api/copy", { paths: rows.map(r => r.path), to: folder, conflict: "rename" });
		jobs.track(job, done => !done.error && toast(rows.length === 1 ? `“${rows[0].name}” duplicated` : `${rows.length} items duplicated`, { icon: "content_duplicate", timeout: 2000 }));
	} catch (error) {
		errorToast(error);
	}
}

export async function rename(row, name) {
	if (!name || name === row.name) return null;
	if (/[/\\]/.test(name)) {
		toast("A name cannot contain a slash", { tone: "bad", icon: "alert_circle_outline" });
		return null;
	}
	try {
		const result = await api.post("/api/rename", { path: row.path, name });
		const old = row.name;
		toast(`Renamed to “${name}”`, { icon: "form_textbox", timeout: 3600, action: { label: "Undo", run: () => api.post("/api/rename", { path: join(parentOf(row.path), name), name: old }).catch(errorToast) } });
		return result;
	} catch (error) {
		errorToast(error, "Rename");
		return null;
	}
}

// several at once: a pattern with {n} and {name} (BatchRename.qml, simple)
export async function batchRename(rows) {
	const values = await formDialog({
		title: `Rename ${rows.length} items`,
		icon: "rename_box",
		fields: [
			{ key: "pattern", label: "New names", type: "text", default: "{name}", hint: "{name} the old name, {n} a running number, {ext} the ending" },
			{ key: "start", label: "First number", type: "number", default: 1 },
			{ key: "find", label: "Find (optional)", type: "text", default: "" },
			{ key: "replace", label: "Replace with", type: "text", default: "" }
		],
		confirmLabel: "Rename"
	});
	if (!values) return;
	const pad = String(rows.length + Number(values.start || 1)).length;
	let n = Number(values.start || 1);
	let done = 0;
	for (const row of rows) {
		const dot = row.dir ? -1 : row.name.lastIndexOf(".");
		const base = dot > 0 ? row.name.slice(0, dot) : row.name;
		const ext = dot > 0 ? row.name.slice(dot + 1) : "";
		let name = String(values.pattern || "{name}").replaceAll("{name}", base).replaceAll("{n}", String(n).padStart(pad, "0")).replaceAll("{ext}", ext);
		if (values.find) name = name.split(values.find).join(values.replace || "");
		if (ext && !values.pattern.includes("{ext}")) name = `${name}.${ext}`;
		n += 1;
		if (name === row.name) continue;
		try {
			await api.post("/api/rename", { path: row.path, name });
			done += 1;
		} catch (error) {
			errorToast(error, row.name);
		}
	}
	toast(`Renamed ${plural(done, "item")}`, { icon: "rename_box", timeout: 2000 });
}

export async function newFolder(folder, view) {
	const name = await prompt({ title: "New folder", label: "Name", value: "New folder", icon: "folder_plus_outline", confirmLabel: "Make" });
	if (!name) return;
	try {
		await api.post("/api/mkdir", { path: join(folder, name) });
		view?.reveal?.(name);
	} catch (error) {
		errorToast(error, "New folder");
	}
}

export async function newFile(folder, name, content) {
	const chosen = await prompt({ title: "New file", label: "Name", value: name, icon: "file_plus_outline", confirmLabel: "Make", selectBase: true });
	if (!chosen) return;
	const file = new File([content], chosen, { type: "text/plain" });
	uploads.enqueue(folder, [{ file, rel: chosen }], { conflict: "rename" });
}

export async function trash(rows) {
	const paths = rows.map(r => r.path);
	try {
		const { job } = await api.post("/api/delete", { paths });
		const label = rows.length === 1 ? `“${rows[0].name}”` : plural(rows.length, "item");
		jobs.track(job, done => {
			if (done.error) {
				toast("Moving to the trash failed", { tone: "bad", icon: "alert_circle_outline", body: done.error });
				return;
			}
			toast(`${label} in the trash`, {
				icon: "trash_can_outline",
				timeout: 6000,
				action: { label: "Undo", run: () => undoTrash(paths) }
			});
		});
	} catch (error) {
		errorToast(error);
	}
}

async function undoTrash(paths) {
	try {
		const list = await api.get("/api/trash");
		const items = Array.isArray(list) ? list : list.items || [];
		const ids = [];
		for (const path of paths) {
			const hit = items.filter(t => t.path === path).sort((a, b) => (b.deleted || 0) - (a.deleted || 0))[0];
			if (hit) ids.push(hit.id);
		}
		if (!ids.length) return;
		const { job } = await api.post("/api/trash/restore", { ids });
		jobs.track(job, done => !done.error && toast("Back where it was", { icon: "restore", tone: "good", timeout: 1800 }));
	} catch (error) {
		errorToast(error);
	}
}

export async function deleteForGood(rows) {
	if (!setting("permanent_delete", false)) {
		toast("Deleting for good is off in the settings", { icon: "information_outline", tone: "warn" });
		return;
	}
	const ok = await confirm({
		title: rows.length === 1 ? `Delete “${rows[0].name}” for good?` : `Delete ${rows.length} items for good?`,
		body: "They do not go to the trash. Snapshots may still hold older copies.",
		details: rows.map(r => r.name),
		confirmLabel: "Delete for good",
		danger: true,
		icon: "delete_forever_outline"
	});
	if (!ok) return;
	try {
		const { job } = await api.post("/api/delete", { paths: rows.map(r => r.path), permanent: true });
		jobs.track(job, done => !done.error && toast("Deleted for good", { icon: "delete_forever_outline", timeout: 2000 }));
	} catch (error) {
		errorToast(error);
	}
}

export async function toggleFavorite(row) {
	const fav = !!row.favorite || state.favorites.includes(row.path);
	try {
		await setFavorite(row.path, !fav);
		row.favorite = !fav;
		toast(!fav ? `“${nameOf(row.path)}” is a favorite` : "No longer a favorite", { icon: !fav ? "star" : "star_off_outline", timeout: 1600 });
	} catch (error) {
		errorToast(error);
	}
}

// drop on a folder: files from the desktop upload, rows from here move (Ctrl: copy)
export async function dropOn(folder, event) {
	const dt = event.dataTransfer;
	const internal = dt.getData("application/x-nas-paths");
	if (internal) {
		let paths = [];
		try {
			paths = JSON.parse(internal);
		} catch (error) {}
		const op = event.ctrlKey || event.altKey || dt.dropEffect === "copy" && event.ctrlKey ? "copy" : "move";
		return transfer(paths, folder, op);
	}
	if (uploads.isFileDrag(event)) {
		const files = await uploads.filesFromDrop(dt);
		return uploads.enqueue(folder, files);
	}
}

// ── shares (download and upload links) ────────────────────────────────────
export async function shareDialog(rows, kind = "download") {
	const upload = kind === "upload";
	const values = await formDialog({
		title: upload ? "Upload link" : rows.length === 1 ? `Share “${rows[0].name}”` : `Share ${rows.length} items`,
		icon: upload ? "cloud_upload_outline" : "link_variant",
		intro: upload
			? "Whoever has the link can drop files into a fresh folder under /Uploads – they never see anything that is there."
			: setting("public_shares", false) ? "The link also works from the internet (public links are on)." : "The link works at home and over the VPN (public links are off).",
		fields: [
			{ key: "expires", label: "Expires", type: "choice", select: true, default: 168, choices: [{ value: 1, label: "In an hour" }, { value: 24, label: "In a day" }, { value: 168, label: "In a week" }, { value: 720, label: "In 30 days" }, { value: 0, label: "Never" }] },
			{ key: "password", label: "Password (optional)", type: "password", default: "" },
			...(upload ? [] : [{ key: "max_downloads", label: "Most downloads (0 = no limit)", type: "number", default: 0, min: 0 }]),
			{ key: "note", label: upload ? "Name of the folder it drops into" : "Note (for you)", type: "text", default: "" }
		],
		confirmLabel: "Make the link"
	});
	if (!values) return;
	const body = { paths: rows.map(r => r.path), kind, expires: Number(values.expires) };
	if (values.password) body.password = values.password;
	if (values.max_downloads) body.max_downloads = Number(values.max_downloads);
	if (values.note) body.note = values.note;
	try {
		const share = await api.post("/api/shares", body);
		showShareLink(share, rows, kind);
	} catch (error) {
		errorToast(error, "Share");
	}
}

export async function showShareLink(share, rows, kind) {
	const { qrSvg } = await import("../vendor/qrcode.js");
	const url = absolute(share.url_public || share.url);
	const local = share.url_public && share.url ? absolute(share.url) : null;
	const qr = h("div.qr", { html: qrSvg(url) });
	const field = h("input", { value: url, readonly: true });
	const copyBtn = h("button.btn.primary", icon("content_copy"), "Copy");
	copyBtn.addEventListener("click", () => copyText(url).then(() => {
		copyBtn.lastChild.textContent = "Copied";
		toast("Link copied", { icon: "link_variant", timeout: 1600 });
	}));
	const body = h("div.share-result",
		qr,
		h("div.share-side",
			h("div.field.share-url", icon("link_variant"), field),
			copyBtn,
			local ? h("div.form-hint", "At home: ", h("a", { href: local, target: "_blank" }, local)) : null,
			h("div.form-hint", kind === "upload" ? "Upload only – nothing is listed." : rows?.length ? (rows.length === 1 ? rows[0].name : plural(rows.length, "item")) : "")));
	openDialog({ title: kind === "upload" ? "Upload link ready" : "Link ready", icon: "check_circle_outline", tone: "var(--success)", body, actions: [{ label: "Done", primary: true }] });
	setTimeout(() => field.select(), 50);
}

function absolute(url) {
	if (!url) return "";
	try {
		return new URL(url, location.origin).href;
	} catch (error) {
		return url;
	}
}

// ── versions (snapshots and trash copies) ─────────────────────────────────
export async function versionsDialog(row) {
	const list = h("div.versions", h("div.skeleton", { style: { height: "52px" } }), h("div.skeleton", { style: { height: "52px", marginTop: "8px" } }));
	const dialog = openDialog({ title: "Earlier versions", subtitle: row.name, icon: "history", body: list, wide: true });
	try {
		const data = await api.get("/api/versions", { path: row.path });
		const versions = Array.isArray(data) ? data : data.versions || [];
		list.textContent = "";
		if (!versions.length) {
			list.appendChild(h("div.empty", icon("history"), h("h3", "No earlier versions"), h("p", "Snapshots and the trash hold none of this file.")));
			return;
		}
		for (const v of versions) {
			const restore = mode => async () => {
				try {
					const result = await api.post("/api/versions/restore", { path: row.path, id: v.id, mode });
					if (result?.job) await jobs.jobPromise(result.job);
					toast(mode === "replace" ? "The earlier version is back" : "The earlier version lies beside it", { icon: "restore", tone: "good" });
					dialog.close();
				} catch (error) {
					errorToast(error);
				}
			};
			list.appendChild(h("div.version-row",
				icon(v.source === "trash" || v.kind === "trash" ? "trash_can_outline" : v.source === "backup" ? "backup_restore" : "history"),
				h("div.version-text", h("div", fullDate(v.at || v.mtime || v.time || v.date)), h("div.subtle", [v.source === "trash" ? `deleted${v.by ? ` by ${v.by}` : ""}` : v.source === "snapshot" ? `snapshot · changed ${fullDate(v.mtime)}` : v.source || "snapshot", v.size !== undefined ? fmtSize(v.size) : ""].filter(Boolean).join(" · "))),
				h("button.btn.small.ghost", { onclick: restore("beside") }, "Beside it"),
				h("button.btn.small.soft", { onclick: restore("replace") }, "Restore")));
		}
	} catch (error) {
		list.textContent = "";
		list.appendChild(h("div.empty", icon("history"), h("h3", "No versions"), h("p", error.status === 404 ? "This NAS does not keep versions yet." : error.message)));
	}
}

async function gitDialog(folder) {
	const body = h("div", h("div.skeleton", { style: { height: "60px" } }));
	openDialog({ title: "Git", subtitle: folder, icon: "source_branch", body });
	try {
		const info = await api.get("/api/git", { path: folder });
		body.textContent = "";
		if (!info || info.repo === false || (!info.branch && !info.dirty)) {
			body.appendChild(h("div.empty", icon("source_branch"), h("h3", "Not a repository"), h("p", "This folder is not in a git repository.")));
			return;
		}
		const files = info.dirty || info.files || [];
		body.appendChild(h("div.git-head", h("span.chip.accent", icon("source_branch"), info.branch || "detached"), h("span.subtle", files.length ? `${plural(Array.isArray(files) ? files.length : Object.keys(files).length, "changed file")}` : "Clean")));
		const listFiles = Array.isArray(files) ? files : Object.entries(files).map(([path, st]) => ({ path, state: st }));
		body.appendChild(h("div.git-files", listFiles.slice(0, 200).map(f => h("div.git-file", h("span.mono.git-state", typeof f === "string" ? "M" : f.state || f.status || "M"), h("span.ellipsis", typeof f === "string" ? f : f.path)))));
	} catch (error) {
		body.textContent = "";
		body.appendChild(h("div.empty", icon("source_branch"), h("h3", "No git here"), h("p", error.message)));
	}
}

export function isAdminUser() {
	return isAdmin();
}
