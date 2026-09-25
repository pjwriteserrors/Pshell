// qtrack day board for Obsidian session notes (x Other/Sessions/YYYY-MM-DD.md).
// Loaded by export-qtrack-session-notes.py via dataviewjs: render(dv, { day }).

function normalizeDayValue(value) {
  if (!value) return "today";
  if (typeof value?.toISODate === "function") {
    const isoDate = value.toISODate();
    if (isoDate) return String(isoDate);
  }
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return value.toISOString().slice(0, 10);
  }
  const text = String(value).trim();
  const isoDateMatch = text.match(/^(\d{4}-\d{2}-\d{2})/);
  return isoDateMatch ? isoDateMatch[1] : (text || "today");
}

const day = normalizeDayValue(input?.day || dv.current()?.qtrackDay || "today");
// notes written before the rebuild do not pass `root`
const QTRACK_ROOT = input?.root || `${window?.require?.("os")?.homedir?.() ?? ""}/.config/quickshell/shell/scripts/qtrack`;
const QTRACK_SCRIPT = `${QTRACK_ROOT}/qtrack-local`;
const PYTHON_BIN = "python3";
const STYLE_ID = "qtrack-day-board-style";
const LEGACY_STYLE_IDS = ["qtrack-obsidian-day-board-style"];
const WORKDAY_MINUTES = 8 * 60;

const nodeRequire =
  app?.plugins?.plugins?.dataview?.api?.nodeRequire ||
  window?.require ||
  null;

const ICONS = {
  clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
  refresh: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
  send: '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
  chevron: '<path d="m9 18 6-6-6-6"/>',
  left: '<path d="m15 18-6-6 6-6"/>',
  updown: '<path d="m7 15 5 5 5-5"/><path d="m7 9 5-5 5 5"/>',
  minus: '<path d="M5 12h14"/>',
  plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
};

function icon(el, name) {
  el.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[name]}</svg>`;
  return el;
}

function ensureStyles() {
  LEGACY_STYLE_IDS.forEach(id => document.getElementById(id)?.remove());
  const style = document.getElementById(STYLE_ID) || document.head.createEl("style", { attr: { id: STYLE_ID } });
  style.textContent = `
    .qd {
      --qd-page: var(--background-primary);
      --qd-card: var(--background-secondary);
      --qd-raised: color-mix(in srgb, var(--background-secondary) 88%, var(--text-normal));
      --qd-line: color-mix(in srgb, var(--text-normal) 9%, transparent);
      --qd-hover: color-mix(in srgb, var(--text-normal) 6%, transparent);
      --qd-accent: var(--interactive-accent);
      --qd-accent-soft: color-mix(in srgb, var(--interactive-accent) 16%, transparent);
      --qd-radius: 16px;
      box-sizing: border-box;
      width: 100%;
      max-width: 1180px;
      margin: 0 auto !important;
      padding: clamp(1.1rem, 3vw, 2.25rem) clamp(0.85rem, 4vw, 3rem) 2.5rem !important;
      container-type: inline-size;
      color: var(--text-normal);
      font-family: var(--font-interface);
    }
    .qd *, .qd *::before, .qd *::after { box-sizing: border-box; }
    .qd button { box-shadow: none; font-family: inherit; }
    .qd svg { width: 16px; height: 16px; flex: none; }
    .qd-eyebrow { color: var(--text-faint); font-size: 0.68rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; }

    .qd-header { display: flex; align-items: center; justify-content: space-between; gap: 1rem; flex-wrap: wrap; margin-bottom: 1.25rem; }
    .qd-heading { display: flex; align-items: center; gap: 0.85rem; min-width: 0; }
    .qd-badge { display: flex; align-items: center; justify-content: center; width: 2.6rem; height: 2.6rem; border-radius: 12px; background: var(--qd-accent-soft); color: var(--text-accent); }
    .qd-badge svg { width: 20px; height: 20px; }
    .qd-title { font-size: 1.55rem; font-weight: 750; line-height: 1.15; letter-spacing: -0.02em; color: var(--text-normal); }
    .qd-subtitle { margin-top: 0.15rem; color: var(--text-muted); font-size: 0.85rem; }
    .qd-status.is-error { color: var(--text-error); }

    .qd-actions { display: flex; align-items: center; gap: 0.5rem; }
    .qd-nav { display: inline-flex; gap: 2px; padding: 3px; border-radius: 12px; background: var(--qd-card); }
    .qd-nav .qd-btn { height: 2.1rem; background: transparent; }
    .qd-nav .qd-btn:hover { background: var(--qd-hover); }
    .qd-btn { display: inline-flex; align-items: center; justify-content: center; gap: 0.45rem; height: 2.4rem; padding: 0 1rem; border: 0; border-radius: 11px; background: var(--qd-card); color: var(--text-normal); font-size: 0.86rem; font-weight: 650; cursor: pointer; }
    .qd-btn:hover { background: var(--qd-raised); }
    .qd-btn:disabled { opacity: 0.4; cursor: default; }
    .qd-btn.is-primary { background: var(--qd-accent); color: var(--text-on-accent); }
    .qd-btn.is-primary:hover { background: var(--interactive-accent-hover); }
    .qd-btn.is-icon { width: 2.4rem; padding: 0; }
    .qd-nav .qd-btn.is-icon { width: 2.1rem; }
    .qd-btn.is-small { height: 1.85rem; padding: 0 0.7rem; border-radius: 8px; font-size: 0.78rem; background: transparent; }
    .qd-btn.is-small:hover { background: var(--qd-hover); }
    .qd-btn.is-small.is-icon { width: 1.85rem; padding: 0; }
    .qd-btn.is-small svg { width: 14px; height: 14px; }
    .qd-count { min-width: 1.35rem; padding: 0 0.35rem; border-radius: 999px; background: color-mix(in srgb, var(--text-on-accent) 22%, transparent); font-size: 0.72rem; line-height: 1.35rem; text-align: center; }
    .is-spinning svg { animation: qd-spin 900ms linear infinite; }
    @keyframes qd-spin { to { transform: rotate(360deg); } }

    .qd-stats { margin-bottom: 1.5rem; padding: 1.1rem 1.25rem 1.2rem; border-radius: var(--qd-radius); background: var(--qd-card); }
    .qd-stats-row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 1rem; }
    .qd-stat-value { margin-top: 0.3rem; color: var(--text-normal); font-size: 1.6rem; font-weight: 750; line-height: 1.1; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .qd-stat-hint { margin-top: 0.2rem; color: var(--text-faint); font-size: 0.74rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .qd-bar { margin-top: 1rem; }
    .qd-bar + .qd-bar { margin-top: 0.6rem; }
    .qd-bar-labels { display: flex; justify-content: space-between; gap: 0.5rem; margin-bottom: 0.3rem; color: var(--text-muted); font-size: 0.74rem; }
    .qd-bar-value { color: var(--text-normal); font-weight: 650; font-variant-numeric: tabular-nums; }
    .qd-bar.is-billable .qd-bar-value { color: var(--text-success); }
    .qd-progress { height: 6px; border-radius: 999px; background: var(--qd-line); overflow: hidden; }
    .qd-bar.is-billable .qd-progress-fill { background: var(--text-success); }
    .qd-progress-fill { height: 100%; border-radius: 999px; background: var(--qd-accent); }

    .qd-section-label { margin: 0 0 0.7rem 0.25rem; }
    .qd-list { display: flex; flex-direction: column; gap: 0.85rem; }
    .qd-empty { padding: 3rem 1rem; border-radius: var(--qd-radius); background: var(--qd-card); color: var(--text-muted); text-align: center; }
    .qd-empty.is-error { color: var(--text-error); }

    .qd-group { padding: 0.4rem; border-radius: var(--qd-radius); background: var(--qd-card); }
    .qd-group-head { display: flex; align-items: center; gap: 0.75rem; padding: 0.6rem 0.65rem; border-radius: 12px; cursor: pointer; }
    .qd-group-head:hover { background: var(--qd-hover); }
    .qd-group-icon { display: flex; align-items: center; justify-content: center; width: 2.2rem; height: 2.2rem; border-radius: 10px; background: var(--qd-hover); color: var(--text-muted); }
    .qd-group.is-done .qd-group-icon { background: var(--qd-accent-soft); color: var(--text-accent); }
    .qd-group-name { flex: 1; min-width: 0; }
    .qd-kicker { color: var(--text-faint); font-size: 0.74rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .qd-name { color: var(--text-normal); font-size: 1.02rem; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .qd-pill { padding: 0 0.55rem; border-radius: 999px; background: var(--qd-hover); color: var(--text-muted); font-size: 0.72rem; font-weight: 650; line-height: 1.45rem; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .qd-pill.is-accent { background: var(--qd-accent-soft); color: var(--text-accent); }
    .qd-group-total { min-width: 4.2rem; color: var(--text-normal); font-size: 1.05rem; font-weight: 800; text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .qd-chevron { display: flex; color: var(--text-faint); transition: transform 150ms ease; }
    .qd-group:not(.is-collapsed) .qd-chevron { transform: rotate(90deg); }

    .qd-entries { display: flex; flex-direction: column; gap: 2px; margin: 0.15rem 0.1rem 0.1rem; padding: 0.3rem; border-radius: 12px; background: color-mix(in srgb, var(--qd-page) 55%, var(--qd-card)); }
    .qd-entry { border-radius: 10px; }
    .qd-entry.is-pending { opacity: 0.55; pointer-events: none; }
    .qd-entry.is-open { margin: 0.25rem 0; background: var(--qd-page); box-shadow: inset 0 0 0 1px var(--qd-line); }
    .qd-entry.is-open:first-child { margin-top: 0; }
    .qd-entry.is-open:last-child { margin-bottom: 0; }
    .qd-entry-line { display: grid; grid-template-columns: 1.35rem minmax(0, 1fr) auto auto; align-items: center; gap: 0.8rem; padding: 0.55rem 0.65rem; border-radius: 10px; cursor: pointer; }
    .qd-entry:not(.is-open) .qd-entry-line:hover { background: var(--qd-hover); }
    .qd-entry.is-open .qd-entry-line { padding: 0.85rem 1.1rem 0.5rem; }
    .qd-check { display: flex; align-items: center; justify-content: center; }
    .qd-entry-text { min-width: 0; color: var(--text-muted); font-size: 0.9rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .qd-entry.is-open .qd-entry-text { color: var(--text-normal); white-space: normal; overflow-wrap: anywhere; font-weight: 600; }
    .qd-tag { margin-left: 0.5rem; padding: 0 0.45rem; border-radius: 999px; background: var(--qd-hover); color: var(--text-muted); font-size: 0.68rem; font-weight: 650; line-height: 1.3rem; }
    .qd-tag.is-live { background: var(--qd-accent-soft); color: var(--text-accent); }
    .qd-tag.is-synced { color: var(--text-success); }
    .qd-entry-time { color: var(--text-faint); font-size: 0.8rem; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .qd-entry-dur { min-width: 3.6rem; color: var(--text-muted); font-size: 0.86rem; font-weight: 600; text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }

    .qd-detail { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 1rem 1.1rem; margin: 0.35rem 1.1rem 0 3.25rem; padding: 0.95rem 0 1.15rem; border-top: 1px solid var(--qd-line); }
    .qd-field { display: flex; flex-direction: column; gap: 0.35rem; min-width: 0; }
    .qd-field.is-wide { grid-column: 1 / -1; }
    .qd-input { width: 100%; height: 2.3rem; padding: 0 0.75rem; border: 1px solid transparent; border-radius: 9px; background: var(--qd-card); color: var(--text-normal); font-size: 0.88rem; box-shadow: none; }
    .qd-input:focus { outline: none; border-color: var(--qd-accent); }
    .qd-input:disabled { opacity: 0.6; }

    .qd-picker { position: relative; }
    .qd-picker-btn { width: 100%; height: 2.3rem; justify-content: space-between; padding: 0 0.75rem; border-radius: 9px; font-weight: 500; text-align: left; }
    .qd-picker-text { min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .qd-picker-btn svg { color: var(--text-faint); }
    .qd-menu { position: absolute; z-index: 30; top: calc(100% + 6px); left: 0; right: 0; display: flex; flex-direction: column; gap: 0.35rem; padding: 0.45rem; border: 1px solid var(--qd-line); border-radius: 12px; background: var(--background-secondary); box-shadow: var(--shadow-l); }
    .qd-menu .qd-input { background: var(--qd-page); }
    .qd-menu-list { display: flex; flex-direction: column; gap: 2px; max-height: 17rem; overflow-y: auto; }
    .qd-option { display: flex; flex-direction: column; align-items: flex-start; gap: 0.05rem; height: auto; padding: 0.45rem 0.6rem; border: 0; border-radius: 8px; background: transparent; color: var(--text-normal); font-size: 0.85rem; text-align: left; white-space: normal; cursor: pointer; }
    .qd-option:hover { background: var(--qd-hover); }
    .qd-option.is-selected { background: var(--qd-accent-soft); }
    .qd-option-kicker { color: var(--text-faint); font-size: 0.72rem; }
    .qd-option-empty { padding: 0.7rem; color: var(--text-muted); font-size: 0.82rem; }

    .qd-times { display: flex; flex-wrap: wrap; gap: 0.5rem; }
    .qd-stepper { display: inline-flex; align-items: center; gap: 0.15rem; padding: 0.2rem; border-radius: 10px; background: var(--qd-card); }
    .qd-stepper-value { display: flex; flex-direction: column; align-items: center; min-width: 3.4rem; line-height: 1.1; }
    .qd-stepper-label { color: var(--text-faint); font-size: 0.62rem; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; }
    .qd-stepper-time { color: var(--text-normal); font-family: var(--font-monospace); font-size: 0.9rem; font-weight: 600; }
    .qd-stepper-time.is-shifted { color: var(--text-accent); }
    .qd-footer { grid-column: 1 / -1; display: flex; align-items: center; gap: 1.25rem; flex-wrap: wrap; }
    .qd-toggle { display: inline-flex; align-items: center; gap: 0.5rem; color: var(--text-normal); font-size: 0.85rem; cursor: pointer; }
    .qd-toggle input { margin: 0; }
    .qd-toggle.is-disabled { opacity: 0.55; cursor: default; }
    .qd-footer-note { margin-left: auto; color: var(--text-faint); font-size: 0.78rem; }

    .qd-native-ul, .qd-native-li { margin: 0 !important; padding: 0 !important; list-style: none !important; }
    .qd-native-li::marker { content: ""; }
    .qd-native-li input.task-list-item-checkbox { margin: 0 !important; cursor: pointer; }

    @container (max-width: 720px) {
      .qd-stats-row { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .qd-detail { grid-template-columns: minmax(0, 1fr); margin-left: 1.1rem; }
      .qd-group .qd-pill, .qd-entry-time { display: none; }
    }
  `;
}

function createCheckbox(parent, checked) {
  const status = checked ? "x" : " ";
  const li = parent
    .createEl("ul", { cls: "contains-task-list qd-native-ul" })
    .createEl("li", { cls: "task-list-item qd-native-li", attr: { "data-task": status } });
  li.toggleClass("is-checked", checked);
  const cb = li.createEl("input", { type: "checkbox", cls: "task-list-item-checkbox", attr: { "data-task": status } });
  cb.checked = checked;
  return cb;
}

ensureStyles();
const root = dv.el("div", "", { cls: "qd markdown-rendered" });

// Obsidian attaches the code block to the page after this script starts running,
// so "not connected yet" must not be treated as "note was closed".
const createdAt = Date.now();
let wasConnected = false;
function isAlive() {
  if (root.isConnected) {
    wasConnected = true;
    return true;
  }
  return !wasConnected && Date.now() - createdAt < 60000;
}

if (!nodeRequire) {
  root.createDiv({ cls: "qd-empty", text: "This session note needs Obsidian desktop (Node access)." });
  return;
}

const { execFile } = nodeRequire("node:child_process");
const { promisify } = nodeRequire("node:util");
const execFileAsync = promisify(execFile);

// ─── Layout ──────────────────────────────────────────────────────────────────

const dayDate = /^\d{4}-\d{2}-\d{2}$/.test(day) ? new Date(`${day}T00:00:00`) : new Date();

const header = root.createDiv({ cls: "qd-header" });
const heading = header.createDiv({ cls: "qd-heading" });
icon(heading.createDiv({ cls: "qd-badge" }), "clock");
const headingText = heading.createDiv();
headingText.createDiv({
  cls: "qd-title",
  text: dayDate.toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" }),
});
const subtitle = headingText.createDiv({ cls: "qd-subtitle" });
subtitle.createSpan({ text: `Time tracking · ${dayDate.getFullYear()}` });
const statusEl = subtitle.createSpan({ cls: "qd-status" });

const actions = header.createDiv({ cls: "qd-actions" });
const nav = actions.createDiv({ cls: "qd-nav" });
const prevBtn = icon(nav.createEl("button", { cls: "qd-btn is-icon", attr: { type: "button" } }), "left");
const nextBtn = icon(nav.createEl("button", { cls: "qd-btn is-icon", attr: { type: "button" } }), "chevron");
const refreshBtn = icon(actions.createEl("button", {
  cls: "qd-btn is-icon",
  attr: { type: "button", title: "Refresh qtrack and Teamwork tickets", "aria-label": "Refresh" },
}), "refresh");
const sendBtn = actions.createEl("button", {
  cls: "qd-btn is-primary",
  attr: { type: "button", title: "Send all queued entries of this day to Teamwork" },
});

const statsWrap = root.createDiv();
const listWrap = root.createDiv({ cls: "qd-list" });

let payload = null;
let teamworkTasks = [];
let refreshCounter = 0;
const pendingKeys = new Set();
const collapsedProjects = new Set();
const openEntries = new Set();
const closedRunningEntries = new Set();
let openPicker = null;

// ─── Helpers ─────────────────────────────────────────────────────────────────

function setStatus(text, isError = false) {
  statusEl.setText(text ? ` · ${text}` : "");
  statusEl.toggleClass("is-error", !!isError);
}

function errorText(error) {
  return String(error?.stderr || error?.message || error || "").trim().replace(/\s+/g, " ");
}

function timeLabel(date = new Date()) {
  return date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });
}

function splitProject(name) {
  const text = String(name || "No project");
  const index = text.indexOf(" / ");
  return index >= 0
    ? { kicker: text.slice(0, index).trim(), title: text.slice(index + 3).trim() }
    : { kicker: "", title: text };
}

function formatMinutes(totalMinutes) {
  const minutes = Math.max(0, Number(totalMinutes) || 0);
  const h = Math.floor(minutes / 60);
  return h > 0 ? `${h}h ${String(minutes % 60).padStart(2, "0")}m` : `${minutes}m`;
}

function entryKey(entry) {
  return `${String(entry.project || "")}${String(entry.description || "")}`;
}

function entryMinutes(entry) {
  const minutes = Number(entry?.tracking_minutes);
  return Number.isFinite(minutes) ? Math.max(0, minutes) : 0;
}

function isRunningEntry(entry) {
  const session = payload?.session;
  return !!entry?.is_running || (!!session && session.state === "active" && entryKey(session) === entryKey(entry));
}

function taskIdOf(task) {
  return String(task?.task_id || task?.id || "");
}

function taskParts(task) {
  const label = String(task?.label || task?.task_name || task?.name || "Teamwork ticket");
  const slash = label.indexOf("/");
  const kicker = slash >= 0 ? label.slice(0, slash).trim() : String(task?.project_name || "Teamwork");
  const title = slash >= 0 ? label.slice(slash + 1).trim() : String(task?.task_name || task?.name || label);
  return {
    kicker,
    title,
    search: [label, task?.project_name, task?.tasklist_name, task?.task_name, taskIdOf(task)].filter(Boolean).join(" ").toLowerCase(),
  };
}

function onDocumentPointer(e) {
  if (!isAlive()) {
    document.removeEventListener("pointerdown", onDocumentPointer, true);
    return;
  }
  if (openPicker && !openPicker.contains(e.target)) closePicker();
}
document.addEventListener("pointerdown", onDocumentPointer, true);

// ─── Day navigation ──────────────────────────────────────────────────────────

function neighbourNote(direction) {
  const current = dv.current()?.file?.path;
  if (!current || typeof app.vault.getMarkdownFiles !== "function") return null;
  const folder = current.split("/").slice(0, -1).join("/");
  const days = app.vault.getMarkdownFiles()
    .filter(file => file.parent?.path === folder && /^\d{4}-\d{2}-\d{2}$/.test(file.basename))
    .sort((a, b) => a.basename.localeCompare(b.basename));
  const index = days.findIndex(file => file.path === current);
  return index < 0 ? null : days[index + direction] || null;
}

for (const [button, direction, label] of [[prevBtn, -1, "Previous day"], [nextBtn, 1, "Next day"]]) {
  const target = neighbourNote(direction);
  button.disabled = !target;
  button.title = target ? `${label}: ${target.basename}` : `${label}: none`;
  button.setAttr("aria-label", label);
  button.addEventListener("click", () => {
    if (target) app.workspace.getLeaf(false).openFile(target);
  });
}

// ─── qtrack ──────────────────────────────────────────────────────────────────

async function runQtrack(args) {
  const result = await execFileAsync(PYTHON_BIN, [QTRACK_SCRIPT, ...args], {
    cwd: QTRACK_ROOT,
    maxBuffer: 4 * 1024 * 1024,
  });
  return String(result.stdout || "").trim();
}

async function loadTeamworkTasks() {
  const parsed = JSON.parse((await runQtrack(["teamwork-tasks", "--json"])) || "{}");
  teamworkTasks = Array.isArray(parsed.entries) ? parsed.entries : [];
}

async function refreshBoard({ quiet = false } = {}) {
  if (!isAlive()) return;
  const runId = ++refreshCounter;
  try {
    const next = JSON.parse(await runQtrack(["report", "--json", "--day", day]));
    if (!isAlive() || runId !== refreshCounter) return;
    payload = next;
    renderBoard();
    if (!quiet) setStatus(`updated ${timeLabel()}`);
  } catch (error) {
    if (!isAlive() || runId !== refreshCounter) return;
    setStatus(errorText(error) || "Could not load qtrack.", true);
    if (!payload) renderBoard(errorText(error) || "Could not load qtrack.");
  }
}

async function refreshAll() {
  refreshBtn.disabled = true;
  refreshBtn.addClass("is-spinning");
  setStatus("refreshing …");

  const teamwork = loadTeamworkTasks().then(() => "", error => errorText(error) || "Teamwork is unreachable.");
  await refreshBoard();
  const teamworkError = await teamwork;
  if (!isAlive()) return;

  renderBoard();
  if (teamworkError) setStatus(`Teamwork: ${teamworkError}`, true);
  refreshBtn.disabled = false;
  refreshBtn.removeClass("is-spinning");
}

async function runAction({ entry, args, success, failure, onSuccess }) {
  const key = entryKey(entry);
  if (pendingKeys.has(key)) return;

  pendingKeys.add(key);
  renderBoard();
  try {
    await runQtrack(args);
    onSuccess?.();
    setStatus(success);
    await refreshBoard({ quiet: true });
  } catch (error) {
    setStatus(errorText(error) || failure, true);
  } finally {
    pendingKeys.delete(key);
    renderBoard();
  }
}

const entryArgs = (command, entry, extra = []) =>
  [command, String(entry.entry_number), "--day", day, ...extra, "--json"];

const toggleEntry = entry => runAction({
  entry,
  args: entryArgs("toggle", entry),
  success: entry.checked ? "removed from queue" : "queued for Teamwork",
  failure: "Could not update the entry.",
});

const editDescription = (entry, description) => runAction({
  entry,
  args: entryArgs("edit-description", entry, ["--new-description", description]),
  success: "description saved",
  failure: "Could not save the description.",
});

const setBillable = (entry, billable) => runAction({
  entry,
  args: entryArgs("set-billable", entry, [billable ? "--billable" : "--non-billable"]),
  success: billable ? "marked billable" : "marked non-billable",
  failure: "Could not change billable state.",
});

const shiftTime = (entry, edge, minutes) => runAction({
  entry,
  args: entryArgs("shift-time", entry, ["--edge", edge, "--minutes", String(minutes)]),
  success: `${edge} ${minutes > 0 ? "+" : ""}${minutes} min`,
  failure: "Could not shift the time.",
});

function assignTicket(entry, task) {
  if (!taskIdOf(task) || !task.project_id) {
    setStatus("The ticket has no project id.", true);
    return;
  }
  const targetProject = task.project_name && task.task_name
    ? `${task.project_name} / ${task.task_name}`
    : String(entry.project || "");
  const moved = targetProject !== String(entry.project || "");
  const wasOpen = openEntries.has(entryKey(entry));
  const move = () => {
    if (wasOpen) openEntries.add(entryKey({ project: targetProject, description: entry.description }));
  };
  return runAction({
    entry,
    args: entryArgs("assign-teamwork", entry, [
      "--teamwork-task-id", taskIdOf(task),
      "--teamwork-project-id", String(task.project_id),
      "--teamwork-task-name", String(task.task_name || ""),
      "--teamwork-project-name", String(task.project_name || ""),
      "--teamwork-task-url", String(task.url || ""),
    ]),
    success: moved ? `moved to ${taskParts(task).title}` : `ticket set: ${taskParts(task).title}`,
    onSuccess: move,
    failure: "Could not assign the ticket.",
  });
}

async function sendToTeamwork() {
  sendBtn.disabled = true;
  setStatus("sending to Teamwork …");
  try {
    let result = {};
    try { result = JSON.parse((await runQtrack(["sync-teamwork", "--json", "--day", day])) || "{}"); } catch (_) { result = {}; }
    setStatus(String(result.message || "sent to Teamwork"));
    await refreshBoard({ quiet: true });
  } catch (error) {
    setStatus(errorText(error) || "Sending to Teamwork failed.", true);
  } finally {
    sendBtn.disabled = false;
  }
}

// ─── Components ──────────────────────────────────────────────────────────────

function closePicker() {
  openPicker?.querySelector(".qd-menu")?.remove();
  openPicker = null;
}

function createTicketPicker(entry, parent, pending) {
  const picker = parent.createDiv({ cls: "qd-picker" });
  const currentId = String(entry.teamwork_task_id || "");
  const known = teamworkTasks.find(task => taskIdOf(task) === currentId);
  const label = currentId
    ? (known ? taskParts(known).title : entry.teamwork_task_name || `Ticket ${currentId}`)
    : "Choose a ticket …";

  const button = picker.createEl("button", { cls: "qd-btn qd-picker-btn", attr: { type: "button" } });
  button.createSpan({ cls: "qd-picker-text", text: label });
  icon(button.createSpan({ attr: { style: "display:flex" } }), "updown");
  button.disabled = pending || !!entry.teamwork_synced || teamworkTasks.length === 0;
  if (!entry.teamwork_synced && teamworkTasks.length === 0) {
    button.title = "No Teamwork tickets loaded – refresh first.";
  }

  button.addEventListener("click", e => {
    e.stopPropagation();
    if (openPicker === picker) return closePicker();
    closePicker();
    openPicker = picker;

    const menu = picker.createDiv({ cls: "qd-menu" });
    const search = menu.createEl("input", { cls: "qd-input", attr: { type: "text", placeholder: "Search tickets …" } });
    const options = menu.createDiv({ cls: "qd-menu-list" });

    const renderOptions = () => {
      const query = search.value.trim().toLowerCase();
      const matches = teamworkTasks.filter(task => !query || taskParts(task).search.includes(query)).slice(0, 80);
      options.empty();
      if (!matches.length) options.createDiv({ cls: "qd-option-empty", text: "No ticket found." });
      for (const task of matches) {
        const parts = taskParts(task);
        const option = options.createEl("button", { cls: "qd-option", attr: { type: "button" } });
        option.toggleClass("is-selected", taskIdOf(task) === currentId);
        option.createSpan({ cls: "qd-option-kicker", text: parts.kicker });
        option.createSpan({ text: parts.title });
        option.addEventListener("click", () => {
          closePicker();
          assignTicket(entry, task);
        });
      }
      return matches;
    };

    search.addEventListener("input", renderOptions);
    search.addEventListener("keydown", evt => {
      if (evt.key === "Escape") closePicker();
      if (evt.key === "Enter") {
        const [first] = renderOptions();
        if (first) {
          closePicker();
          assignTicket(entry, first);
        }
      }
    });
    renderOptions();
    search.focus();
  });
}

function createStepper(parent, entry, edge, pending) {
  const label = edge === "start" ? "Start" : "End";
  const value = edge === "start"
    ? entry.rounded_started_label || entry.first_started_label
    : entry.rounded_ended_label || entry.last_ended_label;
  const offset = Number(entry[`manual_time_${edge}_offset_minutes`] || 0);

  const wrap = parent.createDiv({ cls: "qd-stepper" });
  const earlier = icon(wrap.createEl("button", {
    cls: "qd-btn is-small is-icon",
    attr: { type: "button", title: `${label} 15 min earlier`, "aria-label": `${label} 15 min earlier` },
  }), "minus");

  const valueEl = wrap.createDiv({ cls: "qd-stepper-value" });
  valueEl.createSpan({ cls: "qd-stepper-label", text: label });
  const time = valueEl.createSpan({ cls: "qd-stepper-time", text: value || "--" });
  if (offset !== 0) {
    time.addClass("is-shifted");
    time.title = `Shifted manually: ${offset > 0 ? "+" : ""}${offset} min`;
  }

  const later = icon(wrap.createEl("button", {
    cls: "qd-btn is-small is-icon",
    attr: { type: "button", title: `${label} 15 min later`, "aria-label": `${label} 15 min later` },
  }), "plus");

  earlier.disabled = later.disabled = pending;
  earlier.addEventListener("click", () => shiftTime(entry, edge, -15));
  later.addEventListener("click", () => shiftTime(entry, edge, 15));
}

function renderEntry(entry, container) {
  const key = entryKey(entry);
  const pending = pendingKeys.has(key);
  const running = isRunningEntry(entry);
  const open = running ? !closedRunningEntries.has(key) : openEntries.has(key);
  const synced = !!entry.teamwork_synced;

  const el = container.createDiv({ cls: "qd-entry" });
  el.toggleClass("is-open", open);
  el.toggleClass("is-pending", pending);

  const line = el.createDiv({ cls: "qd-entry-line", attr: { title: open ? "Click to close" : "Click to edit" } });
  line.addEventListener("click", () => {
    const toggled = running ? closedRunningEntries : openEntries;
    toggled.has(key) ? toggled.delete(key) : toggled.add(key);
    renderBoard();
  });

  const check = line.createDiv({ cls: "qd-check", attr: { title: "Queue for Teamwork" } });
  check.addEventListener("click", e => e.stopPropagation());
  const cb = createCheckbox(check, !!entry.checked);
  cb.addEventListener("click", e => {
    e.preventDefault();
    toggleEntry(entry);
  });

  const text = line.createDiv({ cls: "qd-entry-text" });
  text.createSpan({ text: String(entry.description || "No description") });
  if (running) text.createSpan({ cls: "qd-tag is-live", text: "running" });
  if (synced) text.createSpan({ cls: "qd-tag is-synced", text: "sent" });

  const start = entry.rounded_started_label || entry.first_started_label || "--";
  const end = entry.rounded_ended_label || entry.last_ended_label || "--";
  line.createSpan({
    cls: "qd-entry-time",
    text: `${start} – ${end}`,
    attr: { title: String(entry.rounded_range_label || entry.range_label || "") },
  });
  line.createSpan({
    cls: "qd-entry-dur",
    text: formatMinutes(entryMinutes(entry)),
    attr: { title: `Rounded · actual ${entry.duration_label || "--"}` },
  });

  if (!open) return;

  const detail = el.createDiv({ cls: "qd-detail" });

  const descField = detail.createDiv({ cls: "qd-field is-wide" });
  descField.createSpan({ cls: "qd-eyebrow", text: "Description" });
  const descInput = descField.createEl("input", { cls: "qd-input", attr: { type: "text", placeholder: "What did you work on?" } });
  descInput.value = String(entry.description || "");
  descInput.disabled = pending || synced;
  const saveDescription = () => {
    const next = descInput.value.trim();
    if (next && next !== String(entry.description || "").trim()) editDescription(entry, next);
  };
  descInput.addEventListener("keydown", e => {
    if (e.key === "Enter") {
      e.preventDefault();
      saveDescription();
    }
    if (e.key === "Escape") {
      descInput.value = String(entry.description || "");
      descInput.blur();
    }
  });
  descInput.addEventListener("change", saveDescription);

  const ticketField = detail.createDiv({ cls: "qd-field" });
  ticketField.createSpan({ cls: "qd-eyebrow", text: "Teamwork ticket" });
  createTicketPicker(entry, ticketField, pending);

  const timeField = detail.createDiv({ cls: "qd-field" });
  timeField.createSpan({ cls: "qd-eyebrow", text: "Time" });
  const times = timeField.createDiv({ cls: "qd-times" });
  createStepper(times, entry, "start", pending);
  createStepper(times, entry, "end", pending);

  const footer = detail.createDiv({ cls: "qd-footer" });
  const billable = footer.createEl("label", { cls: "qd-toggle" });
  billable.toggleClass("is-disabled", pending || synced);
  const billableInput = billable.createEl("input", { type: "checkbox" });
  billableInput.checked = entry.teamwork_billable !== false;
  billableInput.disabled = pending || synced;
  billable.createSpan({ text: "Billable" });
  billableInput.addEventListener("change", () => setBillable(entry, billableInput.checked));

  footer.createSpan({
    cls: "qd-footer-note",
    text: `Actual ${entry.duration_label || "--"} · ${entry.range_label || "--"}`,
  });
}

function renderGroup(group) {
  const entries = Array.isArray(group.entries) ? group.entries : [];
  const key = String(group.project || "");
  const collapsed = collapsedProjects.has(key);
  const queued = entries.filter(entry => entry.checked).length;
  const minutes = entries.reduce((sum, entry) => sum + entryMinutes(entry), 0);

  const el = listWrap.createDiv({ cls: "qd-group" });
  el.toggleClass("is-collapsed", collapsed);
  el.toggleClass("is-done", entries.length > 0 && entries.every(entry => entry.teamwork_synced));

  const head = el.createDiv({ cls: "qd-group-head" });
  head.addEventListener("click", () => {
    collapsed ? collapsedProjects.delete(key) : collapsedProjects.add(key);
    renderBoard();
  });

  icon(head.createDiv({ cls: "qd-group-icon" }), "folder");
  const parts = splitProject(group.project);
  const name = head.createDiv({ cls: "qd-group-name", attr: { title: key } });
  if (parts.kicker) name.createDiv({ cls: "qd-kicker", text: parts.kicker });
  name.createDiv({ cls: "qd-name", text: parts.title });

  head.createSpan({ cls: `qd-pill${queued ? " is-accent" : ""}`, text: `${queued}/${entries.length} queued` });
  head.createSpan({
    cls: "qd-group-total",
    text: formatMinutes(minutes),
    attr: { title: `Rounded · actual ${group.duration_label || "--"}` },
  });
  icon(head.createSpan({ cls: "qd-chevron" }), "chevron");

  if (collapsed) return;
  const list = el.createDiv({ cls: "qd-entries" });
  entries.forEach(entry => renderEntry(entry, list));
}

function renderSendButton(queued) {
  sendBtn.empty();
  icon(sendBtn.createSpan({ attr: { style: "display:flex" } }), "send");
  sendBtn.createSpan({ text: "Send to Teamwork" });
  if (queued) sendBtn.createSpan({ cls: "qd-count", text: String(queued) });
}

function renderBoard(errorMessage = "") {
  closePicker();
  statsWrap.empty();
  listWrap.empty();

  const today = payload?.today;
  if (!today) {
    renderSendButton(0);
    listWrap.createDiv({ cls: `qd-empty${errorMessage ? " is-error" : ""}`, text: errorMessage || "Loading qtrack …" });
    return;
  }

  const entries = Array.isArray(today.entries) ? today.entries : [];
  const total = entries.reduce((sum, entry) => sum + entryMinutes(entry), 0);
  const queued = entries.filter(entry => entry.checked && !entry.teamwork_synced).length;
  const sent = entries.filter(entry => entry.teamwork_synced).length;

  const stats = statsWrap.createDiv({ cls: "qd-stats" });
  const row = stats.createDiv({ cls: "qd-stats-row" });
  const stat = (label, value, hint) => {
    const cell = row.createDiv();
    cell.createDiv({ cls: "qd-eyebrow", text: label });
    cell.createDiv({ cls: "qd-stat-value", text: value });
    cell.createDiv({ cls: "qd-stat-hint", text: hint });
  };
  stat("Tracked", formatMinutes(total), `actual ${today.total_label || "--"}`);
  stat("Of 8h day", `${Math.round((total / WORKDAY_MINUTES) * 100)}%`, total >= WORKDAY_MINUTES ? "day complete" : `${formatMinutes(WORKDAY_MINUTES - total)} missing`);
  stat("Entries", String(entries.length), `${Number(today.project_count || 0)} projects`);
  stat("Teamwork", `${sent}/${entries.length}`, queued ? `${queued} queued` : (sent === entries.length && entries.length ? "all sent" : "sent"));
  const billable = entries
    .filter(entry => entry.teamwork_billable !== false)
    .reduce((sum, entry) => sum + entryMinutes(entry), 0);
  const bar = (label, minutes, variant = "") => {
    const percent = Math.round((minutes / WORKDAY_MINUTES) * 100);
    const wrap = stats.createDiv({ cls: `qd-bar${variant ? ` is-${variant}` : ""}`, attr: { title: `${percent}% of 8h` } });
    const labels = wrap.createDiv({ cls: "qd-bar-labels" });
    labels.createSpan({ text: label });
    labels.createSpan({ cls: "qd-bar-value", text: `${formatMinutes(minutes)} / 8h` });
    const track = wrap.createDiv({ cls: "qd-progress" });
    track.createDiv({ cls: "qd-progress-fill", attr: { style: `width: ${Math.min(100, percent)}%` } });
  };
  bar("Tracked", total);
  bar("Billable", billable, "billable");

  renderSendButton(queued);

  const groups = Array.isArray(today.project_groups) ? today.project_groups : [];
  if (!groups.length) {
    listWrap.createDiv({ cls: "qd-empty", text: "Nothing tracked on this day." });
    return;
  }
  listWrap.createDiv({ cls: "qd-eyebrow qd-section-label", text: `Projects · ${groups.length}` });
  groups.forEach(renderGroup);
}

refreshBtn.addEventListener("click", () => refreshAll());
sendBtn.addEventListener("click", () => sendToTeamwork());

renderBoard();
await refreshAll();
