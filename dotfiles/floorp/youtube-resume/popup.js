const api = typeof browser !== "undefined" ? browser : chrome;
const SHOWN = 40;

function clock(seconds) {
	const s = Math.floor(seconds);
	const h = Math.floor(s / 3600);
	const m = Math.floor((s % 3600) / 60);
	const pad = n => String(n).padStart(2, "0");
	return h > 0 ? `${h}:${pad(m)}:${pad(s % 60)}` : `${m}:${pad(s % 60)}`;
}

function openVideo(id) {
	api.tabs.create({ url: `https://www.youtube.com/watch?v=${id}` });
}

function row(id, title, kept, onForget) {
	const li = document.createElement("li");
	const text = document.createElement("div");
	text.className = "text";
	const name = document.createElement("div");
	name.className = "title";
	name.textContent = title || id;
	name.title = title || id;
	text.append(name);
	if (kept) {
		const meta = document.createElement("div");
		meta.className = "meta";
		const bar = document.createElement("div");
		bar.className = "bar";
		const fill = document.createElement("div");
		fill.style.width = `${Math.min(100, (kept.t / kept.d) * 100)}%`;
		bar.append(fill);
		const time = document.createElement("span");
		time.textContent = `${clock(kept.t)} / ${clock(kept.d)}`;
		meta.append(bar, time);
		text.append(meta);
	}
	li.append(text);
	if (onForget) {
		const forget = document.createElement("button");
		forget.className = "forget";
		forget.textContent = "Forget";
		forget.addEventListener("click", event => {
			event.stopPropagation();
			onForget();
			li.remove();
		});
		li.append(forget);
	}
	li.addEventListener("click", () => openVideo(id));
	return li;
}

async function show() {
	const all = await api.storage.local.get(null);
	const kept = id => all[`v:${id}`] ?? null;

	const session = all.session?.tabs ?? [];
	if (session.length > 0) {
		document.getElementById("session").hidden = false;
		const list = document.getElementById("sessionList");
		for (const tab of session) list.append(row(tab.id, kept(tab.id)?.title || tab.title, kept(tab.id)));
		document.getElementById("openAll").addEventListener("click", () => {
			for (const tab of session) openVideo(tab.id);
			window.close();
		});
	}

	const recent = Object.entries(all)
		.filter(([key]) => key.startsWith("v:"))
		.map(([key, value]) => ({ id: key.slice(2), ...value }))
		.sort((a, b) => b.at - a.at)
		.slice(0, SHOWN);
	const list = document.getElementById("recentList");
	for (const entry of recent) list.append(row(entry.id, entry.title, entry, () => api.storage.local.remove(`v:${entry.id}`)));
	document.getElementById("empty").hidden = recent.length > 0;
}

show();
