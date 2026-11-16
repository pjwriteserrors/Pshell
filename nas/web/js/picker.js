// A folder chooser (for "Move to…", sync targets): walks the tree with the
// same breadcrumbs, a new folder on the way.
import { h, icon, clear, nameOf, parentOf, join } from "./util.js";
import * as api from "./api.js";
import { openDialog, prompt, errorToast } from "./ui.js";
import { stagger } from "./motion.js";

export function pickFolder({ title = "Pick a folder", start = "/", confirmLabel = "Pick", allowCopy = false } = {}) {
	return new Promise(resolve => {
		let path = start;
		let result = null;
		let copy = false;
		const crumbs = h("div.picker-crumbs");
		const list = h("div.picker-list");
		const body = h("div.picker", crumbs, list);
		const load = async () => {
			clear(crumbs);
			const parts = path.split("/").filter(Boolean);
			const all = [{ label: "NAS", path: "/" }, ...parts.map((p, i) => ({ label: p, path: `/${parts.slice(0, i + 1).join("/")}` }))];
			all.forEach((c, i) => {
				if (i) crumbs.appendChild(icon("chevron_right", "crumb-sep"));
				const b = h("button.crumb", { type: "button" }, c.label);
				b.addEventListener("click", () => {
					path = c.path;
					load();
				});
				crumbs.appendChild(b);
			});
			clear(list).appendChild(h("div.skeleton", { style: { height: "40px" } }));
			try {
				const data = await api.get("/api/ls", { path });
				clear(list);
				const dirs = (data.entries || []).filter(e => e.dir);
				if (path !== "/") {
					const up = h("button.picker-row", { type: "button" }, icon("arrow_up"), h("span", ".."));
					up.addEventListener("click", () => {
						path = parentOf(path);
						load();
					});
					list.appendChild(up);
				}
				for (const d of dirs) {
					const b = h("button.picker-row", { type: "button" }, icon("folder"), h("span.ellipsis", d.name), icon("chevron_right", "tail"));
					b.addEventListener("click", () => {
						path = d.path;
						load();
					});
					list.appendChild(b);
				}
				if (!dirs.length) list.appendChild(h("div.subtle.picker-none", "No folders in here"));
				stagger(list.children, { step: 12, distance: 6 });
			} catch (error) {
				clear(list).appendChild(h("div.subtle", error.message));
			}
		};
		const actions = [
			{ label: "New folder", ghost: true, icon: "folder_plus_outline", run: async () => {
				const name = await prompt({ title: "New folder", label: "Name", value: "New folder", icon: "folder_plus_outline" });
				if (!name) return false;
				try {
					await api.post("/api/mkdir", { path: join(path, name) });
					path = join(path, name);
					load();
				} catch (error) {
					errorToast(error);
				}
				return false;
			} }
		];
		if (allowCopy) actions.push({ label: "Copy here", run: () => {
			result = { path, copy: true };
		} });
		actions.push({ label: confirmLabel, primary: true, run: () => {
			result = { path, copy };
		} });
		openDialog({ title, icon: "folder_move_outline", body, actions, wide: true, onClose: () => resolve(result) });
		load();
	});
}
