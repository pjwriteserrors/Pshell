// The jobs tray (JobsTray.qml): uploads, file operations on the Pi and
// compute tasks in one list, each with its ring, where it runs and a cancel.
import { h, icon, clear, plural, when } from "./util.js";
import * as api from "./api.js";
import { ring, animate, EASE, stagger } from "./motion.js";
import { popover, toast } from "./ui.js";
import * as uploads from "./uploads.js";

const jobs = new Map(); // id → job
const tasks = new Map(); // id → task
const waiting = new Map(); // job id → [callbacks]
const mine = new Set(); // tasks started from this page: only they toast
const summaryListeners = new Set();
let trayEl = null;
let app = null;

export function init(theApp) {
	app = theApp;
	api.on("job", data => onJob(data.job || data));
	api.on("task", data => onTask(data.task || data));
	uploads.onChange(() => {
		renderTray();
		summarize();
	});
	api.get("/api/tasks", { state: "running" }, { quiet: true }).then(list => (list || []).forEach(t => tasks.set(t.id, t))).catch(() => {});
	api.get("/api/tasks", { state: "queued" }, { quiet: true }).then(list => {
		(list || []).forEach(t => tasks.set(t.id, t));
		summarize();
	}).catch(() => {});
	api.get("/api/jobs", null, { quiet: true }).then(list => {
		(list || []).filter(j => !j.done).forEach(j => jobs.set(j.id, j));
		summarize();
	}).catch(() => {});
}

export function onSummary(fn) {
	summaryListeners.add(fn);
	summarize();
	return () => summaryListeners.delete(fn);
}

function activeTasks() {
	return [...tasks.values()].filter(t => ["queued", "running", "waiting_pc"].includes(t.state));
}

function summarize() {
	const items = [...jobs.values()].filter(j => !j.done).map(j => j.progress || 0)
		.concat(activeTasks().map(t => t.progress || 0))
		.concat(uploads.active().map(u => (u.size ? (u.shown ?? u.offset) / u.size : 0)));
	const active = items.length;
	const progress = active ? items.reduce((a, b) => a + b, 0) / active : 0;
	summaryListeners.forEach(fn => fn({ active, progress }));
}

function onJob(job) {
	if (!job?.id) return;
	const before = jobs.get(job.id);
	jobs.set(job.id, { ...before, ...job });
	if (job.done) {
		const callbacks = waiting.get(job.id) || [];
		waiting.delete(job.id);
		callbacks.forEach(fn => fn(job));
		if (job.error && !callbacks.length) toast(job.text || "A file operation failed", { tone: "bad", icon: "alert_circle_outline", body: job.error });
		setTimeout(() => {
			jobs.delete(job.id);
			renderTray();
			summarize();
		}, 4000);
	}
	renderTray();
	summarize();
}

function onTask(task) {
	if (!task?.id) return;
	// background work (thumbnails of new files …) stays out of the tray
	if (task.auto && !mine.has(task.id)) return;
	const before = tasks.get(task.id);
	tasks.set(task.id, { ...before, ...task });
	if (before && before.state !== task.state && mine.has(task.id)) {
		if (task.state === "done") {
			toast(`${task.label || task.type} finished`, {
				icon: "check_circle_outline",
				tone: "good",
				body: resultLine(task),
				action: task.type === "avscan" || task.type === "vtscan" || task.result ? { label: "Show", run: () => app.go(`#/tasks?open=${task.id}`) } : undefined
			});
		}
		if (task.state === "failed") toast(`${task.label || task.type} failed`, { icon: "alert_circle_outline", tone: "bad", body: task.error });
	}
	if (["done", "failed", "cancelled"].includes(task.state)) setTimeout(() => {
		tasks.delete(task.id);
		renderTray();
		summarize();
	}, 6000);
	renderTray();
	summarize();
}

function resultLine(task) {
	const r = task.result;
	if (!r) return task.text || "";
	if (typeof r === "string") return r;
	if (r.infected !== undefined) return r.infected ? `${plural(r.infected, "threat")} found` : "Nothing found";
	if (r.text) return String(r.text);
	if (r.outputs?.length) return `Made ${r.outputs.map(o => o.path?.split("/").pop()).join(", ")}`;
	return task.text || "";
}

// wait for a job's end
export function track(jobId, done) {
	if (!jobId) return;
	const known = jobs.get(jobId);
	if (known?.done) {
		done(known);
		return;
	}
	if (!waiting.has(jobId)) waiting.set(jobId, []);
	waiting.get(jobId).push(done);
	if (!known) jobs.set(jobId, { id: jobId, progress: 0, done: false, text: "Working…" });
	summarize();
	// the event may have come before the call returned
	api.get(`/api/jobs/${jobId}`, null, { quiet: true }).then(job => job && onJob(job)).catch(() => {});
}

export function jobPromise(jobId) {
	return new Promise((resolve, reject) => track(jobId, job => (job.error ? reject(new Error(job.error)) : resolve(job))));
}

export function addTask(task) {
	if (!task?.id) return;
	mine.add(task.id);
	onTask(task);
}

// ── the tray ───────────────────────────────────────────────────────────────
export function showTray(anchor) {
	const content = h("div.tray");
	trayEl = content;
	renderTray(true);
	popover(anchor, content, { className: "tray-pop", onClose: () => (trayEl = null) });
}

function row({ iconName, title, sub, progress, where, onCancel, tone, state }) {
	const r = ring(progress, { size: 34, stroke: 3.5, tone: tone || "var(--primary)" });
	const el = h("div.tray-row", { class: state || "" },
		h("div.tray-icon", r, icon(iconName)),
		h("div.tray-text", h("div.tray-title.ellipsis", title), h("div.tray-sub.ellipsis", sub)),
		where ? h(`span.chip.${where}`, where === "pc" ? "PC" : "Pi") : null,
		onCancel ? h("button.icon-btn.small", { title: "Cancel", onclick: onCancel }, icon("close")) : null);
	return el;
}

function renderTray(first) {
	if (!trayEl) return;
	clear(trayEl);
	const ups = uploads.all();
	const fileJobs = [...jobs.values()];
	const running = [...tasks.values()];
	trayEl.appendChild(h("div.tray-head", h("strong", "Transfers and tasks"), h("a.btn.small.ghost", { href: "#/tasks" }, "All tasks")));
	if (!ups.length && !fileJobs.length && !running.length) {
		trayEl.appendChild(h("div.tray-empty", icon("check_all"), h("div", "Nothing running")));
		return;
	}
	const list = h("div.tray-list");
	for (const u of ups) {
		const p = u.size ? (u.shown ?? u.offset) / u.size : 0;
		list.appendChild(row({
			iconName: u.state === "paused" ? "pause" : u.state === "failed" ? "alert_circle_outline" : u.state === "done" ? "check" : "upload",
			title: u.name,
			sub: u.state === "paused" ? "Paused – pick the file again to go on" : u.state === "failed" ? u.error || "Failed" : u.state === "done" ? "Uploaded" : `${Math.round(p * 100)} % · ${uploads.speedText(u)}`,
			progress: u.state === "done" ? 1 : p,
			tone: u.state === "failed" ? "var(--danger)" : u.state === "done" ? "var(--success)" : undefined,
			onCancel: u.state !== "done" ? () => uploads.cancel(u.key) : null,
			state: u.state
		}));
	}
	for (const j of fileJobs) {
		list.appendChild(row({
			iconName: { copy: "content_copy", move: "folder_move_outline", delete: "trash_can_outline", restore: "restore", zip: "zip_box_outline", snapshot: "history" }[j.kind] || "cog_outline",
			title: j.text || j.kind,
			sub: j.error ? j.error : j.done ? "Done" : `${Math.round((j.progress || 0) * 100)} %`,
			progress: j.done ? 1 : j.progress || null,
			tone: j.error ? "var(--danger)" : j.done ? "var(--success)" : undefined,
			onCancel: j.done ? null : () => api.del(`/api/jobs/${j.id}`).catch(() => {})
		}));
	}
	for (const t of running) {
		list.appendChild(row({
			iconName: t.icon || "cog_outline",
			title: t.label || t.type,
			sub: t.state === "waiting_pc" ? "Waits for the PC" : t.state === "queued" ? "Queued" : t.state === "done" ? "Done" : t.state === "failed" ? t.error || "Failed" : t.text || `${Math.round((t.progress || 0) * 100)} %`,
			progress: t.state === "running" ? (t.progress || null) : t.state === "done" ? 1 : 0,
			where: t.where,
			tone: t.state === "failed" ? "var(--danger)" : t.state === "done" ? "var(--success)" : t.where === "pc" ? "var(--secondary)" : "var(--tertiary)",
			onCancel: ["queued", "running", "waiting_pc"].includes(t.state) ? () => api.del(`/api/tasks/${t.id}`).catch(() => {}) : null
		}));
	}
	trayEl.appendChild(list);
	if (first) stagger(list.children, { step: 30, distance: 8 });
}
