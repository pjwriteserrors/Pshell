// Activity: who did what, a timeline by day; more as you scroll.
import { h, icon, clear, nameOf, parentOf, dayLabel, toDate, debounce } from "../util.js";
import * as api from "../api.js";
import { stagger } from "../motion.js";
import { segmented } from "../ui.js";
import { activityIcon } from "../details.js";
import { describe } from "./home.js";
import { encodePath } from "../app.js";

const GROUPS = {
	all: null,
	files: ["upload", "delete", "move", "copy", "rename", "restore"],
	shares: ["share"],
	logins: ["login", "login_failed"],
	system: ["task", "setting"]
};

export default function activity(route, app) {
	let items = [];
	let done = false;
	let loading = false;
	let group = "all";
	const path = route.query.path || "";
	const timeline = h("div.timeline");
	const more = h("div.load-more");
	const seg = segmented([
		{ value: "all", label: "All" },
		{ value: "files", label: "Files" },
		{ value: "shares", label: "Links" },
		{ value: "logins", label: "Logins" },
		{ value: "system", label: "System" }
	], group, value => {
		group = value;
		render(true);
	});
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Activity"), h("div.subtle", path ? `Around ${path}` : "Uploads, moves, deletes, links, logins and settings – everything is written down.")), h("div.page-tools", seg)),
		timeline,
		more);
	const root = h("div.page-scroll", page);

	async function load() {
		if (loading || done) return;
		loading = true;
		more.replaceChildren(h("div.spinner"));
		try {
			const before = items.length ? items[items.length - 1].at : undefined;
			const batch = await api.get("/api/activity", { limit: 120, before, path: path || undefined });
			if (!batch?.length || batch.length < 120) done = true;
			const first = !items.length;
			items = items.concat(batch || []);
			render(first);
		} catch (error) {
			more.replaceChildren(h("span.subtle", error.message));
		} finally {
			loading = false;
			if (done) more.replaceChildren(items.length ? h("span.subtle", "That is all") : "");
			else more.replaceChildren(h("button.btn.small.ghost", { onclick: load }, "More"));
		}
	}

	function render(animateIn) {
		clear(timeline);
		const allowed = GROUPS[group];
		const list = allowed ? items.filter(i => allowed.includes(i.what)) : items;
		if (!list.length && done) {
			timeline.appendChild(h("div.empty", icon("chart_timeline_variant"), h("h3", "Nothing yet"), h("p", "What happens on the NAS shows up here.")));
			return;
		}
		let day = "";
		const rows = [];
		for (const item of list) {
			const d = toDate(item.at);
			const label = dayLabel(d);
			if (label !== day) {
				day = label;
				timeline.appendChild(h("div.day-head", label));
			}
			const tone = item.what === "login_failed" ? "bad" : item.what === "upload" || item.what === "restore" ? "good" : item.what === "share" ? "accent" : "";
			const target = item.to || item.path;
			const link = target && target.startsWith("/") && !["login", "login_failed", "setting"].includes(item.what)
				? h("a.subtle", { href: `#/files${encodePath(parentOf(target))}?select=${encodeURIComponent(nameOf(target))}` }, target)
				: h("span.subtle", detailText(item));
			const row = h(`div.event-row${tone ? "." + tone : ""}`,
				h("span.event-time", d ? d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" }) : ""),
				h("div.event-dot", icon(activityIcon(item.what))),
				h("div.event-main", h("div.ellipsis", h("strong", item.who || "?"), " ", lower(describe(item))), h("div.ellipsis", link)));
			timeline.appendChild(row);
			rows.push(row);
		}
		if (animateIn) stagger(rows.slice(0, 40), { step: 14, distance: 8 });
	}

	root.addEventListener("scroll", debounce(() => {
		if (root.scrollTop + root.clientHeight > root.scrollHeight - 400) load();
	}, 100), { passive: true });

	const off = api.on("changed", debounce(() => {
		items = [];
		done = false;
		load();
	}, 1500));
	load();
	return { el: root, title: "Activity", icon: "chart_timeline_variant", unmount: off };
}

function lower(text) {
	return text.charAt(0).toLowerCase() + text.slice(1);
}

function detailText(item) {
	let detail = item.detail;
	try {
		detail = typeof detail === "string" && detail.startsWith("{") ? JSON.parse(detail) : detail;
	} catch (error) {}
	if (detail && typeof detail === "object") return Object.entries(detail).map(([k, v]) => `${k} ${typeof v === "object" ? JSON.stringify(v) : v}`).join(" · ");
	return String(detail || item.path || "");
}
