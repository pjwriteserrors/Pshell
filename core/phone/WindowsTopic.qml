import QtQuick
import Quickshell
import qs.core.services

// windows: what is open on which workspace, to focus, close and move.
Topic {
	id: topic

	name: "windows"
	throttle: 250

	function iconOf(appId) {
		const path = AppIcons.forAppId(appId);
		return String(path).startsWith("/") ? { "$blob": path } : null;
	}

	data: topic.wanted ? ({
		// where the monitors stand, as niri arranges them
		outputs: Quickshell.screens.map(screen => ({ name: String(screen.name), x: screen.x, y: screen.y, width: screen.width, height: screen.height })),
		workspaces: Niri.workspaces.slice().sort((a, b) => Niri.outputOrder(a.output) - Niri.outputOrder(b.output) || a.idx - b.idx).map(ws => ({
			id: ws.id,
			idx: ws.idx,
			name: ws.name || "",
			output: String(ws.output || ""),
			active: !!ws.is_active,
			focused: !!ws.is_focused
		})),
		windows: Niri.windows.map(window => ({
			id: Number(window.id),
			title: String(window.title || ""),
			app: String(window.app_id || ""),
			icon: topic.iconOf(window.app_id),
			workspace: window.workspace_id,
			focused: !!window.is_focused,
			urgent: !!window.is_urgent,
			floating: !!window.is_floating,
			// where the tile sits in its workspace's strip: column and row, and its size
			column: Niri.layoutPositionValue(window)[0],
			row: Niri.layoutPositionValue(window)[1],
			width: Number(window.layout?.tile_size?.[0] ?? 0),
			height: Number(window.layout?.tile_size?.[1] ?? 0)
		}))
	}) : null

	function call(action, args, done) {
		const workspace = () => {
			const found = Niri.workspaces.find(ws => ws.id === Number(args.workspace));
			if (!found) throw new Error("That workspace is gone");
			return found;
		};
		switch (action) {
		case "focus":
			Niri.focusWindow(Number(args.id));
			return {};
		case "close":
			Niri.closeWindow(Number(args.id));
			return {};
		case "move":
			Niri.moveWindow(Number(args.id), workspace());
			return {};
		case "workspace":
			Niri.focusWorkspace(workspace());
			return {};
		case "overview":
			Quickshell.execDetached(["niri", "msg", "action", "toggle-overview"]);
			return {};
		}
		throw new Error("unknown-action");
	}
}
