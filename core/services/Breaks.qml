pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Keeps headaches away: screen time is counted while the machine is in use,
// and after a while a toast asks to rest the eyes (20-20-20), to get up, or
// to drink something. Five minutes away from the screen (idle,
// locked, suspended) count as a break. Nothing pops up in fullscreen, while
// sharing the screen or with manual do not disturb; it waits until then.
//
// The eye rest is guided: a calm overlay with a 20 second ring, shown in
// the first pause of typing so no keys get lost.
//
// Water is read off the bottle: its level is set to what is left, the
// difference is what was drunk. Setting it again within two minutes corrects
// that reading instead of adding a new one, and until then the reading can
// be taken as a mere setting ("Don't count"), e.g. for the bottle a day
// starts with. Glasses count on top and can be taken back.
//
// Every day keeps millilitres, screen time, breaks, the air pressure swing and
// logged headaches (breaks.json), so the days with a headache can be told
// apart. A fast pressure fall ahead is announced once a day.
Singleton {
	id: root

	readonly property int sampleSeconds: 30
	readonly property int eyesSeconds: 20 * 60
	readonly property int moveSeconds: 50 * 60
	readonly property int waterSeconds: 45 * 60
	readonly property int awaySeconds: 5 * 60
	readonly property int snoozeSeconds: 10 * 60
	readonly property int bottleSize: 750
	readonly property int glassSize: 250
	readonly property int goalMl: 2250
	readonly property int eyeRestSeconds: 20
	// hPa within six hours that count as a fast fall
	readonly property real pressureFall: 6

	property bool enabled: true
	property real lastTick: Date.now()
	property real idleAt: 0
	property int sinceEyes: 0
	property int sinceMove: 0
	property int sinceWater: 0
	property real eyesDueAt: 0
	property string warnedFallDay: ""
	property int bottleLeft: root.bottleSize
	// the last bottle reading, for two minutes: { at, ml, from }
	property var lastSip: null
	readonly property bool canUncount: root.lastSip !== null && root.lastSip.ml > 0
	readonly property int glasses: root.todayEntry.glasses || 0
	// day (yyyy-MM-dd) → { ml, glasses, screen, breaks, pressure: { mean, swing },
	//   headaches: [ { at, ml, screen, sinceMove, hPa, change3h } ] }
	property var days: ({})
	property string today: root.dayKey(new Date())

	readonly property var todayEntry: root.days[root.today] || root.emptyDay()
	readonly property int waterMl: root.todayEntry.ml
	readonly property int screenSeconds: root.todayEntry.screen
	readonly property bool quiet: Notifs.dndManual || Niri.focusedFullscreen || Notifs.sharing

	// ── air pressure ─────────────────────────────────────────────────────
	readonly property var pressureNow: root.pressureAt(Date.now())
	readonly property real pressureChange3h: {
		const before = root.pressureAt(Date.now() - 3 * 3600 * 1000);
		return root.pressureNow && before ? root.pressureNow.hPa - before.hPa : 0;
	}
	// the steepest fall within the next six hours: { drop, at } or null
	readonly property var pressureFallAhead: {
		const hours = Weather.pressureHours;
		const now = Date.now();
		let best = null;
		for (let i = 0; i < hours.length; i += 1) {
			if (hours[i].at < now - 3600 * 1000 || hours[i].at > now + 6 * 3600 * 1000) continue;
			for (let j = i + 1; j < hours.length && hours[j].at - hours[i].at <= 6 * 3600 * 1000; j += 1) {
				const drop = hours[i].hPa - hours[j].hPa;
				if (!best || drop > best.drop) best = { drop: drop, at: hours[j].at };
			}
		}
		return best && best.drop >= root.pressureFall ? best : null;
	}

	function pressureAt(time) {
		const hours = Weather.pressureHours;
		let best = null;
		for (const hour of hours)
			if (Math.abs(hour.at - time) <= 45 * 60 * 1000 && (!best || Math.abs(hour.at - time) < Math.abs(best.at - time))) best = hour;
		return best;
	}

	function recordPressure() {
		const start = new Date();
		start.setHours(0, 0, 0, 0);
		const end = start.getTime() + 24 * 3600 * 1000;
		const values = Weather.pressureHours.filter(hour => hour.at >= start.getTime() && hour.at < end).map(hour => hour.hPa);
		if (values.length < 12) return;
		const mean = values.reduce((sum, v) => sum + v, 0) / values.length;
		const swing = Math.max(...values) - Math.min(...values);
		root.change(entry => entry.pressure = { mean: Math.round(mean * 10) / 10, swing: Math.round(swing * 10) / 10 });
		root.warnFall();
	}

	function warnFall() {
		const fall = root.pressureFallAhead;
		if (!root.enabled || !fall || root.warnedFallDay === root.today || root.quiet) return;
		root.warnedFallDay = root.today;
		saveDelay.restart();
		Notifs.pushInternal("running", "Air pressure falls", `−${fall.drop.toFixed(0)} hPa until ${Qt.formatTime(new Date(fall.at), "HH:mm")}`, {
			icon: "weather_windy",
			duration: 20000,
			actions: [{ label: "Bottle", icon: "cup_water", run: () => root.openPanel() }]
		});
	}

	Connections {
		target: Weather
		function onPressureHoursChanged() {
			root.recordPressure();
		}
	}
	readonly property var recent: {
		const out = [];
		for (let i = 0; i < 7; i += 1) {
			const date = new Date(Date.now() - i * 24 * 3600 * 1000);
			const key = root.dayKey(date);
			out.push(Object.assign({ key: key, date: date }, root.days[key] || root.emptyDay()));
		}
		return out;
	}

	// averages of the days with a headache next to the other days
	readonly property var insights: {
		const sums = {
			headache: { days: 0, ml: 0, screen: 0, breaks: 0, swing: 0, swingDays: 0 },
			other: { days: 0, ml: 0, screen: 0, breaks: 0, swing: 0, swingDays: 0 }
		};
		for (const key of Object.keys(root.days)) {
			const day = root.days[key];
			const hurt = (day.headaches || []).length > 0;
			// a day barely at the screen says nothing
			if (!hurt && (key === root.today || day.screen < 30 * 60)) continue;
			const side = hurt ? sums.headache : sums.other;
			side.days += 1;
			side.ml += day.ml;
			side.screen += day.screen;
			side.breaks += day.breaks;
			if (day.pressure) {
				side.swing += day.pressure.swing;
				side.swingDays += 1;
			}
		}
		for (const side of [sums.headache, sums.other]) {
			if (side.days === 0) continue;
			side.ml /= side.days;
			side.screen /= side.days;
			side.breaks /= side.days;
			if (side.swingDays > 0) side.swing /= side.swingDays;
		}
		return sums;
	}

	function dayKey(date) {
		return Qt.formatDate(date, "yyyy-MM-dd");
	}

	function emptyDay() {
		return { ml: 0, glasses: 0, screen: 0, breaks: 0, headaches: [] };
	}

	function change(update) {
		const days = Object.assign({}, root.days);
		const entry = Object.assign(root.emptyDay(), days[root.today] || {});
		update(entry);
		days[root.today] = entry;
		// two months are enough to see a pattern
		const cutoff = root.dayKey(new Date(Date.now() - 60 * 24 * 3600 * 1000));
		for (const key of Object.keys(days))
			if (key < cutoff) delete days[key];
		root.days = days;
		saveDelay.restart();
	}

	// ── water ────────────────────────────────────────────────────────────
	function addMl(ml) {
		if (ml === 0) return;
		root.change(entry => entry.ml = Math.max(0, entry.ml + ml));
		if (ml > 0) root.sinceWater = 0;
	}

	function drinkGlass() {
		root.change(entry => entry.glasses += 1);
		root.addMl(root.glassSize);
	}

	function removeGlass() {
		if (root.glasses <= 0) return;
		root.change(entry => entry.glasses -= 1);
		root.addMl(-root.glassSize);
	}

	// the last reading only set the level: nothing was drunk
	function uncount() {
		if (!root.canUncount) return;
		root.addMl(-root.lastSip.ml);
		root.lastSip = { at: Date.now(), ml: 0, from: root.bottleLeft };
		sipWindow.restart();
	}

	// what is left in the bottle now
	function setBottleLevel(left) {
		const level = Math.max(0, Math.min(root.bottleSize, Math.round(left / 25) * 25));
		const now = Date.now();
		const correcting = root.lastSip && now - root.lastSip.at < 2 * 60 * 1000;
		const from = correcting ? root.lastSip.from : root.bottleLeft;
		const drunk = Math.max(0, from - level);
		root.addMl(drunk - (correcting ? root.lastSip.ml : 0));
		root.bottleLeft = level;
		root.lastSip = { at: now, ml: drunk, from: from };
		sipWindow.restart();
		saveDelay.restart();
		return drunk;
	}

	function refill() {
		root.bottleLeft = root.bottleSize;
		root.lastSip = null;
		sipWindow.stop();
		saveDelay.restart();
	}

	function openPanel() {
		Popups.withFocusedScreen(screen => Popups.open("breaks", screen));
	}

	function formatLitres(ml) {
		return `${(ml / 1000).toFixed(ml % 100 === 0 ? 1 : 2)} L`;
	}

	function logHeadache() {
		const since = Math.round(root.sinceMove / 60);
		const hPa = root.pressureNow ? root.pressureNow.hPa : null;
		const change3h = hPa !== null ? Math.round(root.pressureChange3h * 10) / 10 : null;
		root.change(entry => entry.headaches = entry.headaches.concat([{ at: Date.now(), ml: entry.ml, screen: entry.screen, sinceMove: since, hPa: hPa, change3h: change3h }]));
		const pressure = hPa !== null ? ` · ${change3h > 0 ? "+" : ""}${change3h.toFixed(1)} hPa in 3 h` : "";
		Notifs.pushInternal("done", "Headache logged", `${root.formatLitres(root.waterMl)} · ${root.formatDuration(root.screenSeconds)} screen · ${since} min without a break${pressure}`, {
			icon: "head_alert_outline",
			actions: [
				{ label: "Bottle", icon: "cup_water", run: () => root.openPanel() },
				{ label: "Lock screen", icon: "lock", run: () => Session.lock() }
			],
			duration: 12000
		});
	}

	function setEnabled(on) {
		root.enabled = on;
		saveDelay.restart();
	}

	function formatDuration(seconds) {
		const minutes = Math.round(seconds / 60);
		return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")}`;
	}

	function tookBreak() {
		root.sinceEyes = 0;
		root.sinceMove = 0;
		root.change(entry => entry.breaks += 1);
	}

	// ── sampling ─────────────────────────────────────────────────────────
	function tick() {
		const now = Date.now();
		const gap = now - root.lastTick;
		root.lastTick = now;
		const day = root.dayKey(new Date(now));
		if (day !== root.today) {
			root.today = day;
			root.sinceWater = 0;
		}
		// the machine slept
		if (gap > root.awaySeconds * 1000) {
			root.tookBreak();
			return;
		}
		if (Session.locked || idle.isIdle) return;
		root.sinceEyes += root.sampleSeconds;
		root.sinceMove += root.sampleSeconds;
		root.sinceWater += root.sampleSeconds;
		root.change(entry => entry.screen += root.sampleSeconds);
		if (root.eyesDueAt > 0) root.tryEyeRest();
		else if (root.enabled && !root.quiet) root.remind();
	}

	// one toast at a time: moving covers the eyes, too
	function remind() {
		if (root.sinceMove >= root.moveSeconds) {
			root.sinceMove = 0;
			root.sinceEyes = 0;
			Notifs.pushInternal("running", "Time for a break", `${root.formatDuration(root.moveSeconds)} at the screen · get up, stretch, move`, {
				icon: "walk",
				duration: 60000,
				actions: [
					{ label: "Lock screen", icon: "lock", run: () => Session.lock() },
					{ label: "Later", icon: "timer_outline", run: () => root.sinceMove = root.moveSeconds - root.snoozeSeconds }
				]
			});
		} else if (root.sinceWater >= root.waterSeconds) {
			root.sinceWater = 0;
			Notifs.pushInternal("running", "Drink something", `${root.formatLitres(root.waterMl)} / ${root.formatLitres(root.goalMl)} today`, {
				icon: "cup_water",
				duration: 30000,
				actions: [
					{ label: "Bottle", icon: "cup_water", run: () => root.openPanel() },
					{ label: "Glass", icon: "plus", run: () => root.drinkGlass() },
					{ label: "Later", icon: "timer_outline", run: () => root.sinceWater = root.waterSeconds - root.snoozeSeconds }
				]
			});
		} else if (root.sinceEyes >= root.eyesSeconds && root.eyesDueAt === 0) {
			root.eyesDueAt = Date.now();
			root.tryEyeRest();
		}
	}

	// ── guided eye rest ──────────────────────────────────────────────────
	// waits for a pause in typing; after a minute and a half without one it
	// only offers the rest in a toast
	function tryEyeRest() {
		if (root.eyesDueAt === 0) return;
		if (Date.now() - root.eyesDueAt > 90 * 1000 || Popups.modal !== "") {
			root.eyesDueAt = 0;
			root.sinceEyes = 0;
			Notifs.pushInternal("running", "Rest your eyes", `${root.eyeRestSeconds} seconds at something 6 m away`, {
				icon: "eye_outline",
				duration: 20000,
				actions: [{ label: "Start", icon: "play", run: () => root.startEyeRest() }]
			});
		} else if (typingPause.isIdle && !root.quiet && !Session.locked) {
			root.startEyeRest();
		}
	}

	function startEyeRest() {
		root.eyesDueAt = 0;
		root.sinceEyes = 0;
		Popups.withFocusedScreen(screen => Popups.openModal("eyerest", screen));
	}

	function finishEyeRest() {
		if (Popups.modal === "eyerest") Popups.closeModal();
	}

	IdleMonitor {
		id: typingPause

		enabled: root.eyesDueAt > 0
		timeout: 2
		respectInhibitors: false
		onIsIdleChanged: if (isIdle) root.tryEyeRest()
	}

	IdleMonitor {
		id: idle

		timeout: 60
		respectInhibitors: false
		onIsIdleChanged: {
			if (isIdle) root.idleAt = Date.now() - 60 * 1000;
			else if (Date.now() - root.idleAt >= root.awaySeconds * 1000) root.tookBreak();
		}
	}

	Timer {
		running: true
		repeat: true
		interval: root.sampleSeconds * 1000
		onTriggered: root.tick()
	}

	Timer {
		id: sipWindow

		interval: 2 * 60 * 1000
		onTriggered: root.lastSip = null
	}

	Timer {
		id: saveDelay

		interval: 5000
		onTriggered: store.setText(JSON.stringify({ enabled: root.enabled, warnedFallDay: root.warnedFallDay, bottleLeft: root.bottleLeft, days: root.days }))
	}

	FileView {
		id: store

		path: Paths.stateFile("breaks.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				const data = JSON.parse(String(text() || "{}")) || {};
				root.enabled = data.enabled !== false;
				root.warnedFallDay = data.warnedFallDay || "";
				root.bottleLeft = Number.isFinite(data.bottleLeft) ? data.bottleLeft : root.bottleSize;
				// glasses before the bottle counted 250 ml each
				const days = data.days || {};
				for (const key of Object.keys(days)) {
					const day = days[key];
					if (day.ml === undefined) day.ml = (day.water || 0) * 250;
					delete day.water;
					for (const headache of day.headaches || []) {
						if (headache.ml === undefined) headache.ml = (headache.water || 0) * 250;
						delete headache.water;
					}
				}
				root.days = days;
			} catch (error) {}
		}
	}
}
