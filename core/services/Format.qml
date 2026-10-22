pragma Singleton

import QtQuick
import Quickshell

// How the shell says sizes, rates, durations and times, the same everywhere,
// and the quoting a command line or a file URI needs. Sizes follow the file
// manager's unit setting (1 KB = 1000 bytes unless it is set to KiB).
Singleton {
	id: root

	readonly property bool iec: Plugins.on("filemanager") && FileLibrary.setting("sizeUnits") === "iec"

	// ── sizes ──────────────────────────────────────────────────────────────
	// 1.2 KB, 15.4 MB, 153 GB; `zero` is what nothing (or no number) reads as
	function bytes(value, zero) {
		const n = Number(value) || 0;
		if (n <= 0) return zero === undefined ? "0 B" : zero;
		const step = root.iec ? 1024 : 1000;
		if (n < step) return `${Math.round(n)} B`;
		const units = root.iec ? ["KiB", "MiB", "GiB", "TiB", "PiB"] : ["KB", "MB", "GB", "TB", "PB"];
		let size = n / step;
		let unit = 0;
		while (size >= step && unit < units.length - 1) {
			size /= step;
			unit += 1;
		}
		// 999.95 would round up to "1000.0"
		const text = size < 99.95 ? size.toFixed(1).replace(/\.0$/, "") : String(Math.round(size));
		return `${text} ${units[unit]}`;
	}

	function rate(bytesPerSecond, zero) {
		const n = Number(bytesPerSecond) || 0;
		if (n <= 0 && zero !== undefined) return zero;
		return `${root.bytes(n)}/s`;
	}

	// ── durations ──────────────────────────────────────────────────────────
	// 42 s, 5 min (5 min 07 s with `withSeconds`), 1 h 05 min, 2 d 3 h;
	// "∞" for what is unknown or never ends
	function duration(seconds, withSeconds) {
		const value = Number(seconds);
		if (!(value >= 0) || !isFinite(value)) return "∞";
		const total = Math.round(value);
		if (total < 60) return `${total} s`;
		if (total < 3600) {
			const minutes = withSeconds ? Math.floor(total / 60) : Math.round(total / 60);
			if (minutes >= 60) return "1 h 00 min";
			return withSeconds && total % 60 ? `${minutes} min ${String(total % 60).padStart(2, "0")} s` : `${minutes} min`;
		}
		if (total < 86400) {
			const minutes = Math.round(total / 60);
			return `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")} min`;
		}
		return `${Math.floor(total / 86400)} d ${Math.floor(total % 86400 / 3600)} h`;
	}

	// a running time as a player shows it: 3:07, 1:02:45; `decimals` adds tenths
	function clock(seconds, decimals) {
		const value = Math.max(0, Number(seconds) || 0);
		const whole = decimals ? Math.floor(value) : Math.round(value);
		const hours = Math.floor(whole / 3600);
		const minutes = Math.floor(whole % 3600 / 60);
		const rest = decimals ? (value - Math.floor(value / 60) * 60).toFixed(decimals).padStart(3 + decimals, "0") : String(whole % 60).padStart(2, "0");
		return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
	}

	// how long ago a moment (ms since the epoch) was: now, 5 min, 3 h, 2 d
	function ago(at, now) {
		const minutes = Math.floor(((now ?? Date.now()) - at) / 60000);
		if (minutes < 1) return "now";
		if (minutes < 60) return `${minutes} min`;
		if (minutes < 1440) return `${Math.floor(minutes / 60)} h`;
		return `${Math.floor(minutes / 1440)} d`;
	}

	// a message's time in a list (seconds since the epoch): 14:05 today, the
	// weekday within a week (`longDay`: Tuesday), else 3 Oct (3 Oct 24)
	function stamp(seconds, longDay) {
		const date = new Date(seconds * 1000);
		const now = new Date();
		if (date.toDateString() === now.toDateString()) return Qt.formatTime(date, "HH:mm");
		if (now - date < 6 * 86400 * 1000 && date <= now) return Qt.formatDate(date, longDay ? "dddd" : "ddd");
		return root.day(seconds);
	}

	// 3 Oct this year, 3 Oct 24 before
	function day(seconds) {
		const date = new Date(seconds * 1000);
		return Qt.formatDate(date, date.getFullYear() === new Date().getFullYear() ? "d MMM" : "d MMM yy");
	}

	// ── quoting ────────────────────────────────────────────────────────────
	// one word for sh, whatever it holds
	function shellQuote(value) {
		return `'${String(value).replace(/'/g, `'"'"'`)}'`;
	}

	// file:///a/b%20c for /a/b c
	function fileUri(path) {
		return "file://" + String(path).split("/").map(part => encodeURIComponent(part).replace(/'/g, "%27")).join("/");
	}
}
