// The new tab page: the wallpaper worn, the time, a search that goes through
// the browser's own engine, the most visited sites and what the shell has
// for today (weather, tasks, appointments, pinned notes). The shell's data
// comes from background/bridge.js; the page keeps nothing of it.
//
// data: { palette: { bg, fg, primary, dark }, radius, font, wallpaper (data: url),
//         weather: { temp, text, place, high, low } | null,
//         todos: [{ id, text, due }], events: [{ id, title, when, where }],
//         notes: [{ id, title, text }] }

const $ = id => document.getElementById(id);
const LOCALE = "de-DE";

function tick() {
	const now = new Date();
	$("clock").textContent = now.toLocaleTimeString(LOCALE, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
	$("date").textContent = now.toLocaleDateString(LOCALE, { weekday: "long", day: "numeric", month: "long" });
}
tick();
setInterval(tick, 1000);

// ── search ───────────────────────────────────────────────────────────────────
$("search").addEventListener("submit", event => {
	event.preventDefault();
	const text = $("query").value.trim();
	if (!text) return;
	const address = /^[a-z]+:\/\//i.test(text) ? text : /^[^\s]+\.[a-z]{2,}(\/\S*)?$/i.test(text) ? `https://${text}` : "";
	if (address) location.href = address;
	else browser.search.query({ text, disposition: "CURRENT_TAB" });
});

// ── sites ────────────────────────────────────────────────────────────────────
function fav(url, title) {
	const box = document.createElement("span");
	box.className = "fav";
	box.textContent = (title || "?").trim().charAt(0).toUpperCase();
	return box;
}

browser.topSites.get({ limit: 8, includeFavicon: true, onePerDomain: true }).then(sites => {
	for (const site of sites) {
		const link = document.createElement("a");
		link.href = site.url;
		const icon = fav(site.url, site.title || site.url);
		if (site.favicon) {
			const image = document.createElement("img");
			image.src = site.favicon;
			icon.textContent = "";
			icon.append(image);
		}
		const label = document.createElement("span");
		label.textContent = site.title || new URL(site.url).host.replace(/^www\./, "");
		link.append(icon, label);
		$("sites").append(link);
	}
}).catch(() => {});

// ── the shell's part ────────────────────────────────────────────────────────
function card(title, rows) {
	const box = document.createElement("div");
	box.className = "card";
	const head = document.createElement("h2");
	head.append(document.createElement("i"), title);
	box.append(head, ...rows);
	return box;
}

function row(main, side, open, due) {
	const item = document.createElement("div");
	item.className = due ? "row due" : "row";
	const left = document.createElement("span");
	left.className = "main";
	left.textContent = main;
	item.append(left);
	if (side) {
		const right = document.createElement("span");
		right.className = "side";
		right.textContent = side;
		item.append(right);
	}
	if (open) item.addEventListener("click", open);
	return item;
}

const opener = (what, id) => () => browser.runtime.sendMessage({ pshell: "newtabOpen", what, id });

function show(data) {
	if (!data) return;
	const root = document.documentElement.style;
	const palette = data.palette || {};
	if (palette.bg) root.setProperty("--bg", palette.bg);
	if (palette.fg) root.setProperty("--fg", palette.fg);
	if (palette.primary) root.setProperty("--primary", palette.primary);
	if (data.radius) root.setProperty("--radius", `${data.radius}px`);
	if (data.font) root.setProperty("--font", `"${data.font}", system-ui, sans-serif`);
	document.documentElement.style.colorScheme = palette.dark === false ? "light" : "dark";

	const wall = $("wall");
	if (data.wallpaper && wall.dataset.src !== data.wallpaper.slice(-64)) {
		wall.dataset.src = data.wallpaper.slice(-64);
		const image = new Image();
		image.onload = () => {
			wall.style.backgroundImage = `url("${data.wallpaper}")`;
			wall.classList.add("shown");
		};
		image.src = data.wallpaper;
	}

	const cards = [];
	const weather = data.weather;
	if (weather) {
		const box = document.createElement("div");
		box.className = "weather row";
		box.addEventListener("click", opener("weather"));
		const temp = document.createElement("div");
		temp.className = "temp";
		temp.textContent = `${Math.round(weather.temp)}°`;
		const text = document.createElement("div");
		text.className = "text";
		text.textContent = [weather.text, weather.high !== undefined ? `${Math.round(weather.high)}° / ${Math.round(weather.low)}°` : ""].filter(Boolean).join("\n");
		text.style.whiteSpace = "pre-line";
		box.append(temp, text);
		cards.push(card(weather.place || "Wetter", [box]));
	}
	if (data.events && data.events.length) {
		cards.push(card("Termine", data.events.slice(0, 5).map(event => row(event.title, event.when, opener("event", event.id)))));
	}
	if (data.todos && data.todos.length) {
		cards.push(card("Aufgaben", data.todos.slice(0, 6).map(todo => row(todo.text, todo.due || "", opener("todo", todo.id), !!todo.overdue))));
	}
	for (const note of (data.notes || []).slice(0, 2)) {
		const text = document.createElement("div");
		text.className = "note row";
		text.textContent = note.text;
		text.addEventListener("click", opener("note", note.id));
		cards.push(card(note.title || "Notiz", [text]));
	}
	$("cards").replaceChildren(...cards);
}

browser.runtime.sendMessage({ pshell: "newtab" }).then(show).catch(() => {});
browser.runtime.onMessage.addListener(message => {
	if (message && message.pshell === "newtab") show(message.data);
});
