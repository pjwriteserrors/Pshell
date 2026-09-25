pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
	id: root

	required property string statePath
	required property string monitorPath

	signal notificationRequested(string title, string body)

	property var state: defaultState()
	property string inputStatus: "Bereit"
	property bool loaded: false
	property bool minuteHadActivity: false
	property int pendingKeys: 0
	property int pendingClicks: 0

	readonly property bool active: !!state.active
	readonly property int level: Number(state.level || 1)
	readonly property int coins: Number(state.coins || 0)
	readonly property int stage: Number(state.stage || 1)
	readonly property int xp: Number(state.xp || 0)
	readonly property int xpNeeded: xpForLevel(level)
	readonly property real enemyHpRatio: Math.max(0, Math.min(1, Number(state.enemyHp || 0) / Math.max(1, Number(state.enemyMaxHp || 1))))
	readonly property int unseenCount: (state.events || []).filter(event => event.isNew).length
	readonly property string cosmeticColor: {
		for (const item of shopCatalog) if (item.id === state.equippedCosmetic) return item.swatch;
		return "";
	}
	readonly property var relicCatalog: [
		{ id: "iron_quill", name: "Eisenfeder", image: `${Quickshell.shellDir}/assets/rpg/icons/iron-quill.png`, stat: "Tasten-Hits +4% je Rang", set: "Chronist" },
		{ id: "archivist_seal", name: "Archivarsiegel", image: `${Quickshell.shellDir}/assets/rpg/icons/archivist-seal.png`, stat: "XP +3% je Rang", set: "Chronist" },
		{ id: "cursor_fang", name: "Cursorzahn", image: `${Quickshell.shellDir}/assets/rpg/icons/cursor-fang.png`, stat: "Klick-Hits +6% je Rang", set: "Taktgeber" },
		{ id: "clockwork_heart", name: "Uhrwerkherz", image: `${Quickshell.shellDir}/assets/rpg/icons/clockwork-heart.png`, stat: "Fokus-Schaden −4% je Rang", set: "Taktgeber" },
		{ id: "focus_lens", name: "Fokuslinse", image: `${Quickshell.shellDir}/assets/rpg/icons/focus-lens.png`, stat: "Streak-Bonus +3% je Rang", set: "Glutkern" },
		{ id: "ember_core", name: "Glutkern", image: `${Quickshell.shellDir}/assets/rpg/icons/ember-core.png`, stat: "Krit-Chance +2% je Rang", set: "Glutkern" }
	]
	readonly property var shopCatalog: [
		{ id: "copper", name: "Kupferne Namensrune", price: 60, swatch: "#b87333", image: `${Quickshell.shellDir}/assets/rpg/icons/copper-rune.png` },
		{ id: "moss", name: "Moosgrüner Rahmen", price: 220, swatch: "#6f9b62", image: `${Quickshell.shellDir}/assets/rpg/icons/moss-frame.png` },
		{ id: "moon", name: "Mondstaub-Aura", price: 750, swatch: "#91a7d0", image: `${Quickshell.shellDir}/assets/rpg/icons/moondust-aura.png` },
		{ id: "royal", name: "Königspurpur-Siegel", price: 2600, swatch: "#9b70cf", image: `${Quickshell.shellDir}/assets/rpg/icons/royal-seal.png` },
		{ id: "void", name: "Krone der Leerenwacht", price: 9000, swatch: "#d8b4fe", image: `${Quickshell.shellDir}/assets/rpg/icons/void-crown.png` }
	]
	readonly property var questCatalog: [
		{ id: "first_blood", name: "Schlagfolge", detail: "Lande 500 Hits", kind: "hits", target: 500, coins: 35, xp: 60 },
		{ id: "deep_work", name: "Tiefe Wacht", detail: "Bleibe 25 aktive Minuten auf Expedition", kind: "minutes", target: 25, coins: 55, xp: 90 },
		{ id: "room_clear", name: "Kammerjäger", detail: "Besiege 5 Gegner", kind: "kills", target: 5, coins: 45, xp: 75 },
		{ id: "water", name: "Brunnenpause", detail: "Trink ein Glas Wasser (manuell bestätigen)", kind: "manual", target: 1, coins: 20, xp: 30 }
	]

	function defaultState() {
		const maxHp = enemyHpForStage(1);
		return {
			version: 1,
			active: false,
			level: 1,
			xp: 0,
			coins: 0,
			stage: 1,
			enemyHp: maxHp,
			enemyMaxHp: maxHp,
			resolve: 100,
			streak: 0,
			bestStreak: 0,
			totals: { keys: 0, clicks: 0, hits: 0, kills: 0, minutes: 0, expeditions: 0 },
			today: blankDay(dayKey()),
			relics: ({}),
			pity: 0,
			quests: ({}),
			purchasedCosmetics: [],
			equippedCosmetic: "",
			events: [],
			storyUnlocked: [1],
			sessionStarted: 0
		};
	}

	function blankDay(date) {
		return { date: date, keys: 0, clicks: 0, hits: 0, kills: 0, minutes: 0, coins: 0, samples: [] };
	}

	function dayKey() {
		return Qt.formatDateTime(new Date(), "yyyy-MM-dd");
	}

	function enemyHpForStage(value) {
		const room = (Math.max(1, value) - 1) % 10;
		const depth = Math.floor((Math.max(1, value) - 1) / 10);
		const boss = room === 9 ? 1.8 : 1;
		return Math.round((190 + room * 38) * (1 + depth * 0.28) * boss);
	}

	function enemyName(value) {
		const names = ["Staubling", "Tintenkriecher", "Flüsterwisp", "Ablenkungsmime", "Fristenwolf", "Tab-Chimäre", "Nebelschreiber", "Echohüter", "Fokusbrecher"];
		if (value % 10 === 0) return `Torwächter ${Math.ceil(value / 10)}`;
		return names[(value - 1) % names.length];
	}

	function xpForLevel(value) {
		return Math.round(150 + Math.pow(Math.max(1, value), 1.42) * 65);
	}

	function relicById(id) {
		for (const relic of relicCatalog) if (relic.id === id) return relic;
		return null;
	}

	function relicRank(id) {
		return Math.max(0, Number(state.relics?.[id] || 0));
	}

	function hasCombo(first, second) {
		return relicRank(first) > 0 && relicRank(second) > 0;
	}

	function activeCombos() {
		const result = [];
		if (hasCombo("iron_quill", "archivist_seal")) result.push("Chronistenbund: +15% XP");
		if (hasCombo("cursor_fang", "clockwork_heart")) result.push("Taktgeber: +12% Schaden bei gemischter Eingabe");
		if (hasCombo("focus_lens", "ember_core")) result.push("Glutblick: Krits verursachen 2,25× Schaden");
		return result;
	}

	function ensureDay() {
		if (!state.today || state.today.date !== dayKey()) state.today = blankDay(dayKey());
		for (const quest of questCatalog) {
			const progress = state.quests?.[quest.id];
			if (!progress || progress.date !== dayKey()) state.quests[quest.id] = { date: dayKey(), progress: 0, claimed: false };
		}
	}

	function normalize(raw) {
		const defaults = defaultState();
		const next = Object.assign({}, defaults, raw || {});
		next.totals = Object.assign({}, defaults.totals, raw?.totals || {});
		next.relics = Object.assign({}, raw?.relics || {});
		next.quests = Object.assign({}, raw?.quests || {});
		next.events = Array.isArray(raw?.events) ? raw.events.slice(0, 80) : [];
		next.purchasedCosmetics = Array.isArray(raw?.purchasedCosmetics) ? raw.purchasedCosmetics : [];
		next.storyUnlocked = Array.isArray(raw?.storyUnlocked) ? raw.storyUnlocked : [1];
		delete next.statPoints;
		delete next.stats;
		next.active = false;
		return next;
	}

	function loadState(raw) {
		try {
			state = normalize(JSON.parse(String(raw || "{}")));
		} catch (error) {
			state = defaultState();
		}
		ensureDay();
		loaded = true;
		touch(false);
	}

	function touch(saveSoon = true) {
		state = Object.assign({}, state);
		if (saveSoon) saveDebounce.restart();
	}

	function save() {
		if (!loaded) return;
		stateFile.setText(JSON.stringify(state, null, 2));
	}

	function addEvent(title, detail, important = false) {
		state.events = [{ id: `${Date.now()}-${Math.floor(Math.random() * 10000)}`, title: title, detail: detail, time: Date.now(), isNew: true }].concat(state.events || []).slice(0, 80);
		if (important) root.notificationRequested(title, detail);
	}

	function markAllSeen() {
		state.events = (state.events || []).map(event => Object.assign({}, event, { isNew: false }));
		touch();
	}

	function startExpedition() {
		if (state.active) return;
		ensureDay();
		state.active = true;
		state.sessionStarted = Date.now();
		state.totals.expeditions += 1;
		inputStatus = "Verbinde Eingabegeräte …";
		addEvent("Expedition begonnen", `Kammer ${state.stage}: ${enemyName(state.stage)}`);
		touch();
	}

	function stopExpedition() {
		if (!state.active) return;
		state.active = false;
		state.sessionStarted = 0;
		inputStatus = "Pausiert";
		addEvent("Expedition beendet", `${state.today.hits} Hits heute · ${state.today.coins} Splitter gefunden`);
		touch();
		save();
	}

	function toggleExpedition() {
		if (state.active) stopExpedition(); else startExpedition();
	}

	function ingestInput(line) {
		let packet;
		try { packet = JSON.parse(String(line).trim()); } catch (error) { return; }
		if (packet.type === "ready") {
			inputStatus = `${packet.devices} Eingabegeräte · lokal & anonym`;
			return;
		}
		if (packet.type === "error") {
			inputStatus = packet.reason === "permission"
				? "Keine Leserechte – scripts/setup-rpg-input-access.sh ausführen"
				: "Keine Tastatur/Maus unter /dev/input/by-id gefunden";
			root.notificationRequested("RPG-Eingabe nicht verfügbar", inputStatus);
			return;
		}
		if (packet.type !== "activity" || !state.active) return;
		applyActivity(Math.max(0, Number(packet.keys || 0)), Math.max(0, Number(packet.clicks || 0)));
	}

	function applyActivity(rawKeys, rawClicks) {
		ensureDay();
		const keys = Math.min(rawKeys, 120);
		const clicks = Math.min(rawClicks, 35);
		if (keys + clicks <= 0) return;
		minuteHadActivity = true;
		pendingKeys += keys;
		pendingClicks += clicks;
		state.totals.keys += keys;
		state.totals.clicks += clicks;
		state.today.keys += keys;
		state.today.clicks += clicks;
		state.streak = Math.min(100, Number(state.streak || 0) + 1);
		state.bestStreak = Math.max(state.bestStreak, state.streak);

		const levelPower = 1 + Math.min(0.75, (state.level - 1) * 0.025);
		const keyPower = (keys / 9) * levelPower * (1 + relicRank("iron_quill") * 0.04);
		const clickPower = (clicks / 2.5) * levelPower * (1 + relicRank("cursor_fang") * 0.06);
		const streakBonus = 1 + Math.min(0.35, state.streak * 0.004 * (1 + relicRank("focus_lens") * 0.08));
		const mixedBonus = keys > 0 && clicks > 0 && hasCombo("cursor_fang", "clockwork_heart") ? 1.12 : 1;
		const critChance = Math.min(0.30, 0.04 + relicRank("ember_core") * 0.02);
		const critical = Math.random() < critChance;
		const critDamage = critical ? (hasCombo("focus_lens", "ember_core") ? 2.25 : 1.75) : 1;
		const damage = Math.max(1, (keyPower + clickPower) * streakBonus * mixedBonus * critDamage);
		const hits = Math.max(1, Math.round(keys / 9 + clicks / 2.5));
		state.enemyHp -= damage;
		state.totals.hits += hits;
		state.today.hits += hits;
		state.resolve = Math.min(100, state.resolve + Math.min(3, hits * 0.12));
		addXp(Math.max(1, Math.floor(damage * 0.22)));
		advanceQuest("hits", hits);
		while (state.enemyHp <= 0) defeatEnemy();
		touch();
	}

	function addXp(amount) {
		const relicBonus = 1 + relicRank("archivist_seal") * 0.03;
		const comboBonus = hasCombo("iron_quill", "archivist_seal") ? 1.15 : 1;
		state.xp += Math.max(0, Math.round(amount * relicBonus * comboBonus));
		while (state.xp >= xpForLevel(state.level)) {
			state.xp -= xpForLevel(state.level);
			state.level += 1;
			state.resolve = 100;
			addEvent("Stufenaufstieg", `Stufe ${state.level} · Deine Grundstärke ist gestiegen`, true);
		}
	}

	function defeatEnemy() {
		const defeatedStage = state.stage;
		const boss = defeatedStage % 10 === 0;
		const reward = Math.round(5 + Math.sqrt(defeatedStage) * 2 + (boss ? 18 : 0));
		state.coins += reward;
		state.today.coins += reward;
		state.totals.kills += 1;
		state.today.kills += 1;
		addXp(28 + defeatedStage * 2 + (boss ? 70 : 0));
		advanceQuest("kills", 1);
		state.pity += 1;
		if (Math.random() < (boss ? 0.75 : 0.18) || state.pity >= 6) dropRelic(boss);
		if (boss) addEvent("Torwächter bezwungen", `Ebene ${Math.ceil(defeatedStage / 10)} gesichert · +${reward} Splitter`, true);
		state.stage += 1;
		unlockStory();
		state.enemyMaxHp = enemyHpForStage(state.stage);
		state.enemyHp = state.enemyMaxHp;
	}

	function dropRelic(boss) {
		const relic = relicCatalog[Math.floor(Math.random() * relicCatalog.length)];
		const oldRank = relicRank(relic.id);
		if (oldRank >= 10) {
			const salvage = boss ? 35 : 12;
			state.coins += salvage;
			addEvent("Relikt verwertet", `${relic.name} ist maximal · +${salvage} Splitter`, true);
		} else {
			state.relics[relic.id] = oldRank + 1;
			addEvent(oldRank === 0 ? "Neues Relikt" : "Relikt verstärkt", `${relic.icon} ${relic.name} · Rang ${oldRank + 1}`, true);
		}
		state.pity = 0;
	}

	function unlockStory() {
		const gates = [1, 5, 10, 20, 35, 50];
		for (const gate of gates) {
			if (state.stage >= gate && state.storyUnlocked.indexOf(gate) < 0) {
				state.storyUnlocked.push(gate);
				addEvent("Chronik erweitert", storyText(gate), true);
			}
		}
	}

	function storyText(gate) {
		const stories = ({
			1: "Du betrittst das Archiv der verlorenen Stunden.",
			5: "Zwischen den Regalen findest du Spuren der Leerenwacht.",
			10: "Der erste Torwächter fällt. Jemand hat deine Arbeit erwartet.",
			20: "Die Tinte in den Chroniken reagiert auf deinen Rhythmus.",
			35: "Das Archiv nennt dich nun Hüter der ungebrochenen Folge.",
			50: "Hinter dem letzten bekannten Tor wartet eine ungeschriebene Seite."
		});
		return stories[gate] || "Ein neues Kapitel beginnt.";
	}

	function advanceQuest(kind, amount) {
		for (const quest of questCatalog) {
			if (quest.kind !== kind) continue;
			const progress = state.quests[quest.id];
			if (!progress.claimed) progress.progress = Math.min(quest.target, progress.progress + amount);
		}
	}

	function questState(id) {
		return state.quests?.[id] || { progress: 0, claimed: false };
	}

	function claimQuest(id) {
		const quest = questCatalog.find(item => item.id === id);
		const progress = questState(id);
		if (!quest || progress.claimed) return;
		if (quest.kind === "manual") progress.progress = quest.target;
		if (progress.progress < quest.target) return;
		progress.claimed = true;
		state.coins += quest.coins;
		state.today.coins += quest.coins;
		addXp(quest.xp);
		addEvent("Quest erfüllt", `${quest.name} · +${quest.coins} Splitter`, true);
		touch();
	}

	function buyCosmetic(id) {
		const item = shopCatalog.find(entry => entry.id === id);
		if (!item) return;
		if (state.purchasedCosmetics.indexOf(id) >= 0) {
			state.equippedCosmetic = state.equippedCosmetic === id ? "" : id;
			addEvent("Aussehen geändert", state.equippedCosmetic === id ? item.name : "Standard-Aussehen");
			touch();
			return;
		}
		if (state.coins < item.price) return;
		state.coins -= item.price;
		state.purchasedCosmetics.push(id);
		state.equippedCosmetic = id;
		addEvent("Kosmetik freigeschaltet", item.name, true);
		touch();
	}

	function minuteTick() {
		if (!state.active) return;
		ensureDay();
		state.totals.minutes += 1;
		state.today.minutes += 1;
		advanceQuest("minutes", 1);
		if (minuteHadActivity) {
			const reduction = Math.min(0.60, relicRank("clockwork_heart") * 0.04);
			state.resolve = Math.max(1, state.resolve - 2.5 * (1 - reduction));
		} else {
			state.streak = Math.max(0, state.streak - 8);
		}
		state.today.samples.push({
			time: Qt.formatDateTime(new Date(), "HH:mm"),
			resolve: Math.round(state.resolve),
			enemy: Math.round(enemyHpRatio * 100),
			keys: pendingKeys,
			clicks: pendingClicks
		});
		state.today.samples = state.today.samples.slice(-180);
		minuteHadActivity = false;
		pendingKeys = 0;
		pendingClicks = 0;
		touch();
	}

	FileView {
		id: stateFile
		path: root.statePath
		blockLoading: true
		onLoaded: root.loadState(text())
	}

	Process {
		id: inputMonitor
		running: root.active
		command: ["python3", "-u", root.monitorPath, "--interval", "2"]
		stdout: SplitParser { onRead: data => root.ingestInput(data) }
	}

	Timer {
		id: minuteTimer
		interval: 60000
		repeat: true
		running: root.active
		onTriggered: root.minuteTick()
	}

	Timer {
		id: saveDebounce
		interval: 1200
		repeat: false
		onTriggered: root.save()
	}

	Timer {
		interval: 15000
		repeat: true
		running: root.active
		onTriggered: root.save()
	}

	Component.onCompleted: {
		if (!root.loaded) {
			const existing = String(stateFile.text() || "");
			if (existing.trim() !== "") root.loadState(existing);
			else {
				root.state = root.defaultState();
				root.ensureDay();
				root.loaded = true;
				root.save();
			}
		}
	}
}
