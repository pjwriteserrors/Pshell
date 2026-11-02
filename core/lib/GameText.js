.pragma library

// How the game library words things: play time, when a game was played
// last, how it starts.

function kindIcon(game) {
	if (!game) return "gamepad_variant";
	if (game.kind === "steam" || game.kind === "shortcut" || game.runner === "steam") return "steam";
	if (game.runner === "native") return "linux";
	return "microsoft_windows";
}

// "steam" | "proton:<dir>" | "proton" | "wine" | "native" → words
function runnerLabel(game, runners) {
	if (!game) return "";
	if (game.kind === "steam") return "Steam";
	if (game.kind === "shortcut") return "Steam · non-Steam game";
	const runner = String(game.runner || "");
	if (runner === "steam") return "Steam · non-Steam game";
	if (runner === "native") return "Linux";
	if (runner === "wine") return "Wine";
	if (runner.startsWith("proton:")) {
		const found = (runners || []).find(each => each.id === runner);
		return found ? found.name : runner.split("/").pop();
	}
	const best = (runners || []).find(each => each.kind === "proton");
	return best ? `Proton · ${best.name}` : "Proton";
}

function playtime(minutes) {
	const value = Number(minutes || 0);
	if (value <= 0) return "";
	if (value < 60) return `${value} min played`;
	const hours = value / 60;
	if (hours < 10) return `${hours.toFixed(1).replace(/\.0$/, "")} h played`;
	return `${Math.round(hours).toLocaleString()} h played`;
}

function hours(minutes) {
	const value = Number(minutes || 0) / 60;
	return value < 10 ? value.toFixed(1).replace(/\.0$/, "") : String(Math.round(value));
}

function ago(seconds) {
	const value = Number(seconds || 0);
	if (value <= 0) return "";
	const now = Date.now() / 1000;
	const days = Math.floor((startOfDay(now) - startOfDay(value)) / 86400);
	if (now - value < 3600) return "Played just now";
	if (days <= 0) return "Played today";
	if (days === 1) return "Played yesterday";
	if (days < 7) return `Played ${days} days ago`;
	if (days < 30) return `Played ${Math.round(days / 7)} week${Math.round(days / 7) === 1 ? "" : "s"} ago`;
	if (days < 365) return `Played ${Math.round(days / 30)} month${Math.round(days / 30) === 1 ? "" : "s"} ago`;
	return `Played ${new Date(value * 1000).getFullYear()}`;
}

// when, without "Played": "2 days ago", "today", "2024"
function when(seconds) {
	const said = ago(seconds);
	if (said === "") return "";
	const rest = said.replace(/^Played /, "");
	return rest.charAt(0).toUpperCase() + rest.slice(1);
}

// a game's own colours (games.py palette_of): the accent reads on dark, the
// deep one is its mood; the fallback where the picture has none
function accent(game, fallback) {
	return game && game.colors && game.colors.accent ? game.colors.accent : fallback;
}

function deep(game, fallback) {
	return game && game.colors && game.colors.deep ? game.colors.deep : fallback;
}

// black or white on a colour
function onColor(color) {
	let c = color;
	if (typeof color === "string") {
		const hex = color.replace("#", "").slice(-6);
		c = { r: parseInt(hex.slice(0, 2), 16) / 255, g: parseInt(hex.slice(2, 4), 16) / 255, b: parseInt(hex.slice(4, 6), 16) / 255 };
	}
	const lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
	return lum > 0.55 ? "#101114" : "#ffffff";
}

// hours as a short number with its unit: "45 min", "8.2 h", "131 h"
function short(minutes) {
	const value = Number(minutes || 0);
	if (value <= 0) return "–";
	if (value < 60) return `${Math.round(value)} min`;
	const hours = value / 60;
	return hours < 10 ? `${hours.toFixed(1).replace(/\.0$/, "")} h` : `${Math.round(hours).toLocaleString()} h`;
}

// how far along a game is, from its stats (games.py stats) and its play
// time: { share 0…1, label, left (hours to go, -1 unknown), goal } or null
function progress(stats, minutes) {
	if (!stats) return null;
	const goal = stats.goal || "main";
	if (goal === "done") return { share: 1, label: "beaten", left: 0, goal: goal };
	const hltb = stats.hltb;
	const target = hltb ? (hltb[goal] || hltb.main || 0) : 0;
	if (target > 0) {
		const hours = Number(minutes || 0) / 60;
		const labels = { main: "of the story", plus: "with extras", full: "of everything" };
		return { share: Math.min(1, hours / target), label: labels[goal] || labels.main, left: target - hours, goal: goal };
	}
	const trophies = stats.achievements;
	if (trophies && trophies.total > 0) return { share: trophies.got / trophies.total, label: "achievements", left: -1, goal: goal };
	return null;
}

function startOfDay(seconds) {
	const date = new Date(seconds * 1000);
	date.setHours(0, 0, 0, 0);
	return date.getTime() / 1000;
}

// a name for sorting: "The Witcher" with the Ws
function sortName(name) {
	return String(name || "").toLowerCase().replace(/^(the|a|an|der|die|das)\s+/, "").replace(/[^a-z0-9]+/g, " ").trim();
}

// what is typed finds a game by its name, the start of a word, its initials
function matches(game, query) {
	const text = String(query || "").toLowerCase().trim();
	if (text === "") return 1;
	const name = String(game.name || "").toLowerCase();
	if (name.startsWith(text)) return 4;
	const words = name.split(/[^a-z0-9]+/).filter(word => word !== "");
	if (words.some(word => word.startsWith(text))) return 3;
	if (words.map(word => word[0]).join("").startsWith(text.replace(/\s+/g, ""))) return 2;
	if (name.includes(text)) return 1.5;
	return 0;
}
