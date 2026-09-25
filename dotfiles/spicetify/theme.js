// Live palette reload.
//
// generate.py rewrites color.ini and runs `spicetify refresh`, which only
// replaces colors.css / user.css inside Spotify's app folder. The running
// client never re-reads them on its own, so this polls both files and swaps
// the stylesheet in place when its content changes — no restart, no reload.
(function quickshellLiveTheme() {
	const FILES = ["colors.css", "user.css"];
	const INTERVAL = 1500;
	const FADE = 600;
	const known = new Map();
	let busy = false;
	let fadeTimer = 0;

	async function read(file) {
		try {
			const response = await fetch(`/${file}`, { cache: "no-store" });
			return response.ok ? await response.text() : null;
		} catch {
			return null;
		}
	}

	function sheetFor(file) {
		const id = `qs-live-${file.replace(/\W/g, "-")}`;
		let style = document.getElementById(id);
		if (style) return style;

		style = document.createElement("style");
		style.id = id;
		const link = document.querySelector(`link.userCSS[href$="${file}"]`);
		if (link) link.replaceWith(style);
		else document.head.appendChild(style);
		return style;
	}

	function fade() {
		const root = document.documentElement;
		root.classList.add("qs-palette-fade");
		clearTimeout(fadeTimer);
		fadeTimer = setTimeout(() => root.classList.remove("qs-palette-fade"), FADE);
	}

	async function check() {
		if (busy || document.hidden) return;
		busy = true;
		try {
			let changed = false;
			for (const file of FILES) {
				const text = await read(file);
				if (text === null) continue;
				if (!known.has(file)) {
					known.set(file, text);
					continue;
				}
				if (known.get(file) === text) continue;
				known.set(file, text);
				sheetFor(file).textContent = text;
				changed = true;
			}
			if (changed) fade();
		} finally {
			busy = false;
		}
	}

	check();
	setInterval(check, INTERVAL);
	document.addEventListener("visibilitychange", check);
	window.addEventListener("focus", check);
})();
