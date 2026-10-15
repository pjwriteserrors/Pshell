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

function startOfDay(seconds) {
	const date = new Date(seconds * 1000);
	date.setHours(0, 0, 0, 0);
	return date.getTime() / 1000;
}

function size(bytes) {
	const value = Number(bytes || 0);
	if (value <= 0) return "";
	const gb = value / 1e9;
	if (gb >= 1) return `${gb >= 10 ? Math.round(gb) : gb.toFixed(1)} GB`;
	return `${Math.round(value / 1e6)} MB`;
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
