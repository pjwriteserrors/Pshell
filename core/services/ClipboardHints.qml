pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Offers other forms of what was just copied: a Unix time as a date, a JWT
// or Base64 decoded, URL-encoded text decoded, one-line JSON formatted, a
// link without tracking parameters, a Teamwork link as its task ID, a colour
// in the other notation. Only offers: the clipboard itself is never changed
// until one of the toast's buttons is clicked. Copies from password
// managers are not looked at.
Singleton {
	id: root

	property string ownCopy: ""
	// what was last looked at, and when
	property string lastText: ""
	property real lastAt: 0
	// wl-paste reports the clipboard it finds at start, which nobody just copied
	readonly property real startedAt: Date.now()
	readonly property bool wanted: Plugins.on("clipboard-hints")

	onWantedChanged: watcher.running = root.wanted
	Component.onCompleted: watcher.running = root.wanted

	// Base64 (also the URL-safe kind) → byte array, null when it is none
	function bytes(text) {
		const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		const clean = String(text).replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
		if (clean.length % 4 === 1) return null;
		const out = [];
		let buffer = 0;
		let bits = 0;
		for (let i = 0; i < clean.length; i += 1) {
			const value = alphabet.indexOf(clean[i]);
			if (value < 0) return null;
			buffer = (buffer << 6) | value;
			bits += 6;
			if (bits >= 8) {
				bits -= 8;
				out.push((buffer >> bits) & 255);
			}
		}
		return out;
	}

	// UTF-8 bytes → text, null when they are not valid UTF-8
	function utf8(bytes) {
		if (!bytes) return null;
		let out = "";
		for (let i = 0; i < bytes.length;) {
			const b = bytes[i];
			const extra = b < 0x80 ? 0 : (b >> 5) === 6 ? 1 : (b >> 4) === 14 ? 2 : (b >> 3) === 30 ? 3 : -1;
			if (extra < 0 || i + extra >= bytes.length) return null;
			let code = extra === 0 ? b : b & (0x3f >> extra);
			for (let k = 1; k <= extra; k += 1) {
				const next = bytes[i + k];
				if ((next & 0xc0) !== 0x80) return null;
				code = (code << 6) | (next & 0x3f);
			}
			out += String.fromCodePoint(code);
			i += extra + 1;
		}
		return out;
	}

	function base64(text) {
		return root.utf8(root.bytes(text));
	}

	function printable(text) {
		return text !== null && text.length > 0 && !/[\u0000-\u0008\u000e-\u001f\ufffd]/.test(text);
	}

	function pad(v) {
		return (v < 10 ? "0" : "") + v;
	}

	function dateText(date) {
		return Qt.formatDateTime(date, "yyyy-MM-dd HH:mm:ss");
	}

	// [{ label, value }] for one piece of text
	function options(raw) {
		const text = String(raw || "").trim();
		const out = [];
		if (text === "" || text.length > 20000) return out;

		if (/^\d{10}(\d{3})?$/.test(text)) {
			const ms = text.length === 13 ? Number(text) : Number(text) * 1000;
			if (ms > Date.UTC(2001, 0, 1) && ms < Date.UTC(2100, 0, 1)) out.push({ label: "Date", value: root.dateText(new Date(ms)) });
		}

		if (/^\d{4}-\d\d-\d\d[T ]\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d:?\d\d)?$/.test(text)) {
			const ms = Date.parse(text.replace(" ", "T"));
			if (!isNaN(ms)) out.push({ label: "Unix time", value: String(Math.floor(ms / 1000)) });
		}

		const jwt = text.match(/^([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]*$/);
		if (jwt) {
			try {
				const header = JSON.parse(root.base64(jwt[1]));
				const payload = JSON.parse(root.base64(jwt[2]));
				if (header && header.alg) {
					out.push({ label: "JWT", value: JSON.stringify({ header: header, payload: payload }, null, 2) });
					if (payload.exp) out.push({ label: "Expires", value: root.dateText(new Date(payload.exp * 1000)) });
				}
			} catch (error) {}
		}

		if (!jwt && text.length >= 12 && /^[A-Za-z0-9+/_-]+={0,2}$/.test(text) && !/^[a-z]+$|^[A-Z]+$|^\d+$/.test(text)) {
			const decoded = root.base64(text);
			if (root.printable(decoded) && decoded.length >= 4) out.push({ label: "Base64 decoded", value: decoded });
		}

		if (/%[0-9A-Fa-f]{2}/.test(text)) {
			try {
				const decoded = decodeURIComponent(text.replace(/\+/g, " "));
				if (decoded !== text) out.push({ label: "URL decoded", value: decoded });
			} catch (error) {}
		}

		if (/^[\[{]/.test(text) && text.indexOf("\n") < 0 && text.length > 60) {
			try {
				out.push({ label: "Formatted JSON", value: JSON.stringify(JSON.parse(text), null, 2) });
			} catch (error) {}
		}

		const link = text.match(/^https?:\/\/\S+$/);
		if (link) {
			const query = text.indexOf("?");
			if (query > 0) {
				const hash = text.indexOf("#", query);
				const params = text.slice(query + 1, hash > 0 ? hash : undefined).split("&");
				const kept = params.filter(p => !/^(utm_[a-z_]+|fbclid|gclid|dclid|gbraid|wbraid|msclkid|mc_eid|mc_cid|igshid|_hsenc|_hsmi|ref_src|si|spm|yclid)=/i.test(p));
				if (kept.length !== params.length)
					out.push({ label: "Without tracking", value: text.slice(0, query) + (kept.length ? `?${kept.join("&")}` : "") + (hash > 0 ? text.slice(hash) : "") });
			}
			const task = text.match(/teamwork\.com\/.*tasks?\/(\d+)/);
			if (task) out.push({ label: "Task ID", value: task[1] });
		}

		const hex = text.match(/^#?([0-9a-fA-F]{6})$/);
		if (hex && (text.startsWith("#") || /[a-fA-F]/.test(hex[1]))) {
			const v = parseInt(hex[1], 16);
			out.push({ label: "RGB", value: `rgb(${v >> 16 & 255}, ${v >> 8 & 255}, ${v & 255})` });
		}
		const rgb = text.match(/^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(,\s*[\d.]+\s*)?\)$/i);
		if (rgb) {
			const hexOf = n => Math.max(0, Math.min(255, Number(n))).toString(16).padStart(2, "0");
			out.push({ label: "Hex", value: `#${hexOf(rgb[1])}${hexOf(rgb[2])}${hexOf(rgb[3])}` });
		}
		return out;
	}

	function copy(value) {
		root.ownCopy = value;
		Quickshell.execDetached(["wl-copy", "--", value]);
	}

	function preview(value) {
		const oneLine = String(value).replace(/\s+/g, " ");
		return oneLine.length > 90 ? `${oneLine.slice(0, 89)}…` : oneLine;
	}

	function offer(encoded) {
		const text = root.base64(encoded);
		if (text === null) return;
		// what Multicursor reads out of a text field is not a copy
		if (Multicursor.available && Multicursor.quiet()) return;
		if (text === root.ownCopy) {
			root.ownCopy = "";
			return;
		}
		// browsers set the clipboard twice for one copy
		const now = Date.now();
		const again = text === root.lastText && now - root.lastAt < 2000;
		root.lastText = text;
		root.lastAt = now;
		if (again) return;
		const options = root.options(text);
		if (options.length === 0 || Notifs.dnd) return;
		Notifs.pushInternal("done", options[0].label, root.preview(options[0].value), {
			icon: "clipboard_text",
			duration: 7000,
			actions: options.slice(0, 3).map(option => ({ label: option.label, icon: "content_copy", run: () => root.copy(option.value) }))
		});
	}

	Process {
		id: watcher

		// one line per copy: the text as Base64 (it may span lines)
		command: ["wl-paste", "--type", "text/plain;charset=utf-8", "--watch", "sh", "-c",
			"wl-paste --list-types | grep -q passwordManagerHint && exit 0; head -c 20001 | base64 -w0; echo"]
		stdout: SplitParser {
			onRead: line => {
				if (line !== "" && Date.now() - root.startedAt > 3000) root.offer(line);
			}
		}
		onExited: if (root.wanted) restart.restart()
	}

	Timer {
		id: restart

		interval: 5000
		onTriggered: watcher.running = root.wanted
	}
}
