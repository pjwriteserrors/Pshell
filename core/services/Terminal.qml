pragma Singleton

import QtQuick
import Quickshell

// The terminal the shell opens things in: the host profile's `terminal`,
// else $TERMINAL, else kitty. command() builds its command line, whichever
// of the known ones it is, so callers only say what they want.
Singleton {
	id: root

	readonly property string program: String(Host.profile.terminal || Quickshell.env("TERMINAL") || "kitty")
	readonly property string kind: root.program.split("/").pop()
	// the user's shell, for what runs as if typed into one
	readonly property string shell: Quickshell.env("SHELL") || "sh"

	// options: { title, appId, dir, columns, rows }; args: what runs in it
	// ([] for the shell)
	function command(options, args) {
		const o = options ?? {};
		const run = args ?? [];
		const out = [root.program];
		switch (root.kind) {
		case "kitty":
			if (o.title) out.push("--title", String(o.title));
			if (o.appId) out.push("--class", String(o.appId));
			if (o.dir) out.push("--directory", String(o.dir));
			if (o.columns) out.push("-o", `initial_window_width=${o.columns}c`, "-o", `initial_window_height=${o.rows ?? 24}c`);
			return out.concat(run);
		case "foot":
			if (o.title) out.push("--title", String(o.title));
			if (o.appId) out.push("--app-id", String(o.appId));
			if (o.dir) out.push("--working-directory", String(o.dir));
			if (o.columns) out.push("--window-size-chars", `${o.columns}x${o.rows ?? 24}`);
			return out.concat(run);
		case "alacritty":
			if (o.title) out.push("--title", String(o.title));
			if (o.appId) out.push("--class", String(o.appId));
			if (o.dir) out.push("--working-directory", String(o.dir));
			if (o.columns) out.push("-o", `window.dimensions.columns=${o.columns}`, "-o", `window.dimensions.lines=${o.rows ?? 24}`);
			return run.length > 0 ? out.concat(["-e"], run) : out;
		case "ghostty":
			if (o.title) out.push(`--title=${o.title}`);
			if (o.appId) out.push(`--class=${o.appId}`);
			if (o.dir) out.push(`--working-directory=${o.dir}`);
			return run.length > 0 ? out.concat(["-e"], run) : out;
		case "wezterm":
			out.push("start");
			if (o.appId) out.push("--class", String(o.appId));
			if (o.dir) out.push("--cwd", String(o.dir));
			return run.length > 0 ? out.concat(["--"], run) : out;
		}
		// any other: what they mostly understand
		return run.length > 0 ? out.concat(["-e"], run) : out;
	}

	// a line of shell, run in an interactive shell of the user's so it looks
	// and behaves like one typed in
	function shellCommand(options, line) {
		return root.command(options, [root.shell, "-i", "-c", String(line)]);
	}
}
