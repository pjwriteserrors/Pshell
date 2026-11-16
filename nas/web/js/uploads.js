// Resumable, chunked uploads (docs/nas.md › Uploads): start → PUT chunks with
// Upload-Offset → done. What did not finish is remembered in the browser; after
// a reload the same file picked again goes on where it stopped (the server
// resumes the same path + size).
import { h, join, nameOf, plural, size as fmtSize } from "./util.js";
import * as api from "./api.js";
import { toast, openDialog, errorToast } from "./ui.js";
import { icon } from "./util.js";

const CHUNK = 8 * 1024 * 1024;
const PARALLEL = 2;
const items = []; // { key, file, name, path, size, mtime, id, offset, state, error, speed }
const listeners = new Set();
let running = 0;
let app = null;

export function init(theApp) {
	app = theApp;
	// what a reload interrupted
	for (const saved of load()) items.push({ ...saved, file: null, state: "paused", speed: 0 });
	if (items.length) {
		toast(`${plural(items.length, "upload")} did not finish`, {
			icon: "cloud_upload_outline",
			tone: "warn",
			body: "Pick the same files again and they go on where they stopped.",
			timeout: 0,
			action: { label: "Pick", run: () => pickResume() }
		});
	}
	changed();
	addEventListener("beforeunload", event => {
		if (items.some(u => u.state === "running" || u.state === "queued")) {
			event.preventDefault();
			event.returnValue = "";
		}
	});
}

export function onChange(fn) {
	listeners.add(fn);
	return () => listeners.delete(fn);
}

function changed() {
	save();
	listeners.forEach(fn => fn());
}

function load() {
	try {
		return JSON.parse(localStorage.getItem("nas.uploads") || "[]");
	} catch (error) {
		return [];
	}
}

function save() {
	try {
		const keep = items.filter(u => u.state !== "done" && u.state !== "cancelled").map(({ key, name, path, size, mtime, id, offset, conflict }) => ({ key, name, path, size, mtime, id, offset, conflict }));
		localStorage.setItem("nas.uploads", JSON.stringify(keep));
	} catch (error) {}
}

export const all = () => items.slice();
export const active = () => items.filter(u => u.state === "running" || u.state === "queued");

export function speedText(u) {
	if (!u.speed) return u.state === "queued" ? "waiting" : "";
	const left = (u.size - u.offset) / u.speed;
	return `${fmtSize(u.speed)}/s${left > 2 ? ` · ${left > 90 ? `${Math.round(left / 60)} min` : `${Math.round(left)} s`} left` : ""}`;
}

// ── adding ─────────────────────────────────────────────────────────────────
export function pick(folder, directory) {
	const input = h("input", { type: "file", multiple: true, style: { display: "none" } });
	if (directory) {
		input.webkitdirectory = true;
		input.setAttribute("webkitdirectory", "");
	}
	input.addEventListener("change", () => {
		const files = [...input.files].map(file => ({ file, rel: file.webkitRelativePath || file.name }));
		input.remove();
		if (files.length) enqueue(folder, files);
	});
	document.body.appendChild(input);
	input.click();
}

function pickResume() {
	const input = h("input", { type: "file", multiple: true, style: { display: "none" } });
	input.addEventListener("change", () => {
		let matched = 0;
		for (const file of input.files) {
			const u = items.find(item => item.state === "paused" && !item.file && item.name === file.name && item.size === file.size);
			if (u) {
				u.file = file;
				u.state = "queued";
				matched += 1;
			}
		}
		input.remove();
		if (!matched) toast("None of these is an unfinished upload", { icon: "information_outline" });
		changed();
		pump();
	});
	document.body.appendChild(input);
	input.click();
}

// files: [{ file, rel }] (rel = path inside the dropped folder)
export async function enqueue(folder, files, { conflict } = {}) {
	if (!files.length) return;
	let choice = conflict;
	if (!choice) {
		// names already there: keep both, replace or skip (ConflictDialog.qml)
		let existing = [];
		try {
			const listing = await api.get("/api/ls", { path: folder, hidden: 1 });
			existing = (listing.entries || []).map(e => e.name);
		} catch (error) {}
		const tops = [...new Set(files.map(f => f.rel.split("/")[0]))];
		const clashes = tops.filter(name => existing.includes(name));
		if (clashes.length) {
			choice = await askConflict(clashes);
			if (!choice) return;
		}
	}
	for (const { file, rel } of files) {
		// a resumed upload of the same file goes on instead of starting again
		const path = join(folder, rel);
		const same = items.find(u => u.path === path && u.size === file.size && u.state !== "done");
		if (same) {
			same.file = file;
			if (same.state === "paused" || same.state === "failed") same.state = "queued";
			continue;
		}
		items.push({ key: Math.random().toString(36).slice(2), file, name: file.name, path, size: file.size, mtime: file.lastModified / 1000, id: null, offset: 0, state: "queued", conflict: choice || "rename", speed: 0 });
	}
	toast(files.length === 1 ? `Uploading ${files[0].file.name}` : `Uploading ${files.length} files`, { icon: "upload", timeout: 2200 });
	changed();
	pump();
}

function askConflict(names) {
	return new Promise(resolve => {
		let choice = null;
		const body = h("div.conflict",
			h("p", names.length === 1 ? `“${names[0]}” is already there.` : `${names.length} names are already there.`),
			names.length > 1 ? h("ul.confirm-list", names.slice(0, 6).map(n => h("li.ellipsis", n))) : null);
		openDialog({
			title: "Already there",
			icon: "file_replace_outline",
			tone: "var(--warning)",
			body,
			actions: [
				{ label: "Skip", ghost: true, run: () => {
					choice = "skip";
				} },
				{ label: "Replace", danger: true, run: () => {
					choice = "overwrite";
				} },
				{ label: "Keep both", primary: true, run: () => {
					choice = "rename";
				} }
			],
			onClose: () => resolve(choice)
		});
	});
}

export function cancel(key) {
	const u = items.find(item => item.key === key);
	if (!u) return;
	u.state = "cancelled";
	u.xhr?.abort();
	if (u.id) api.del(`/api/upload/${u.id}`).catch(() => {});
	items.splice(items.indexOf(u), 1);
	changed();
	pump();
}

// ── running ────────────────────────────────────────────────────────────────
function pump() {
	while (running < PARALLEL) {
		const next = items.find(u => u.state === "queued" && u.file);
		if (!next) break;
		running += 1;
		next.state = "running";
		run(next).finally(() => {
			running -= 1;
			changed();
			pump();
			finishedBatch();
		});
	}
}

let batchDone = 0;
function finishedBatch() {
	if (items.some(u => u.state === "running" || u.state === "queued")) return;
	const done = items.filter(u => u.state === "done");
	if (!done.length) return;
	batchDone += done.length;
	toast(done.length === 1 ? `${done[0].name} is on the NAS` : `${done.length} files are on the NAS`, { icon: "cloud_upload_outline", tone: "good" });
	// the finished ones leave the tray after a moment
	setTimeout(() => {
		for (const u of done) {
			const i = items.indexOf(u);
			if (i >= 0 && u.state === "done") items.splice(i, 1);
		}
		changed();
	}, 3500);
}

async function run(u) {
	try {
		const started = await api.post("/api/upload", { path: u.path, size: u.size, mtime: u.mtime, conflict: u.conflict });
		u.id = started.id;
		u.offset = started.offset || 0;
		changed();
		let windowStart = performance.now();
		let windowBytes = 0;
		while (u.offset < u.size) {
			if (u.state !== "running") return;
			const end = Math.min(u.size, u.offset + CHUNK);
			const blob = u.file.slice(u.offset, end);
			let result;
			try {
				result = await putChunk(u, blob, sent => {
					const now = performance.now();
					const dt = (now - windowStart) / 1000;
					if (dt > 0.5) {
						u.speed = (windowBytes + sent) / dt;
					}
					u.shown = u.offset + sent;
					changed();
				});
			} catch (error) {
				if (error.status === 409 && error.offset !== undefined) {
					u.offset = error.offset;
					continue;
				}
				throw error;
			}
			windowBytes += end - u.offset;
			const dt = (performance.now() - windowStart) / 1000;
			if (dt > 0) u.speed = windowBytes / dt;
			if (dt > 4) {
				windowStart = performance.now();
				windowBytes = 0;
			}
			u.offset = result.offset ?? end;
			changed();
		}
		await api.post(`/api/upload/${u.id}/done`, { conflict: u.conflict });
		u.state = "done";
		u.file = null;
	} catch (error) {
		if (u.state === "cancelled") return;
		u.state = "failed";
		u.error = error.message;
		errorToast(error, `Upload of ${u.name}`);
	}
}

// XHR for the progress of a chunk
function putChunk(u, blob, onProgress) {
	return new Promise((resolve, reject) => {
		const xhr = new XMLHttpRequest();
		u.xhr = xhr;
		xhr.open("PUT", `/api/upload/${u.id}`);
		xhr.setRequestHeader("Upload-Offset", String(u.offset));
		xhr.setRequestHeader("X-Pshell", "1");
		xhr.setRequestHeader("Content-Type", "application/offset+octet-stream");
		xhr.upload.onprogress = event => onProgress(event.loaded);
		xhr.onload = () => {
			let data = null;
			try {
				data = JSON.parse(xhr.responseText);
			} catch (error) {}
			if (xhr.status >= 200 && xhr.status < 300) resolve(data || {});
			else {
				const error = new Error(data?.error || `Upload failed (${xhr.status})`);
				error.status = xhr.status;
				error.offset = data?.offset;
				reject(error);
			}
		};
		xhr.onerror = () => reject(new Error("The connection dropped"));
		xhr.onabort = () => reject(new Error("Cancelled"));
		xhr.send(blob);
	});
}

// ── drops from the desktop (folders too) ───────────────────────────────────
export async function filesFromDrop(dataTransfer) {
	const out = [];
	const entries = [...(dataTransfer.items || [])].map(item => item.webkitGetAsEntry?.()).filter(Boolean);
	if (!entries.length) {
		for (const file of dataTransfer.files || []) out.push({ file, rel: file.name });
		return out;
	}
	const walk = async (entry, prefix) => {
		if (entry.isFile) {
			const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
			out.push({ file, rel: prefix + file.name });
		} else if (entry.isDirectory) {
			const reader = entry.createReader();
			let batch;
			do {
				batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
				for (const child of batch) await walk(child, `${prefix}${entry.name}/`);
			} while (batch.length);
		}
	};
	for (const entry of entries) await walk(entry, "");
	return out;
}

export function isFileDrag(event) {
	return [...(event.dataTransfer?.types || [])].includes("Files");
}
