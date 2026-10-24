pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.hud

// HUD haptics, a workbench over the whole page (gamefeel.Eyes; the model
// lives in Mouse.qml – hudScenes, hudZones, hudPresets): the game's scenes
// along the top, the chosen one's picture with its zones in the middle, the
// chosen zone (or the scene) on the right, the kept sequences underneath.
// Things are carried between them: a sequence or a reaction onto a zone, a
// scene or into a zone's list, a reaction onto the shelf to keep it.
FocusScope {
	id: root

	property string title: "HUD haptics"
	property bool active: false
	// a key is being recorded: niri hands over its shortcuts
	readonly property bool recording: root.recordingKey >= 0

	readonly property string game: Mouse.gameKey
	readonly property int window: Mouse.gameWindow
	readonly property var scenes: Mouse.hudScenes
	readonly property var scene: Mouse.hudScene
	readonly property string sceneId: root.scene?.id ?? ""
	readonly property var allZones: Mouse.hudZones
	readonly property var zones: root.allZones.filter(z => (z.scene ?? "") === root.sceneId || (!z.scene && root.scenes.length <= 1))
	readonly property var live: Mouse.eyes?.latest?.zones ?? ({})
	readonly property bool watching: Mouse.eyes?.on === true
	readonly property var liveScenes: Mouse.hudLiveScenes
	readonly property var scores: Mouse.hudScores
	readonly property var alike: Mouse.hudAlike
	readonly property string shotDir: `${Paths.runtime}/hud`
	readonly property string picture: String(root.scene?.picture ?? "")
	property bool shooting: false

	// the zone chosen (its id), the one pointed at in a list, which fired last
	property string selected: ""
	// several chosen together (ids, the last one is `selected`); [] for one
	property var multi: []
	readonly property var chosenIds: root.multi.length > 1 ? root.multi : (root.selected !== "" ? [root.selected] : [])
	// do the chosen ones react the same, and are they linked for good
	readonly property bool sameReactions: {
		if (root.multi.length < 2) return true;
		const first = JSON.stringify(Mouse.hudTriggers(root.allZones.find(z => z.id === root.multi[0])));
		return root.multi.every(id => JSON.stringify(Mouse.hudTriggers(root.allZones.find(z => z.id === id))) === first);
	}
	readonly property bool linkedAll: {
		if (root.multi.length < 2) return false;
		const group = root.allZones.find(z => z.id === root.multi[0])?.group ?? "";
		return group !== "" && root.multi.every(id => (root.allZones.find(z => z.id === id)?.group ?? "") === group);
	}
	// drag on the picture picks zones instead of drawing one
	property bool picking: false
	property string pointed: ""
	property string fired: ""
	readonly property var zone: root.allZones.find(z => z.id === root.selected) ?? null
	// how much the chosen zone changed, the last few seconds
	property var activity: []

	// the boxes found on the picture (fractions) and the suggested ones
	property var boxes: []
	property var suggested: []
	property bool suggesting: false
	property bool guessing: false
	property string guessedFor: ""

	// what is carried under the pointer: {type: preset|kind|reaction, label, icon, …}
	property var carry: null
	property bool took: false
	// a sequence just kept or used, one being renamed
	property string presetFlash: ""
	property string renamingPreset: ""
	// the reaction whose key is recorded (its index, -1 none)
	property int recordingKey: -1

	// something landed somewhere: (kind, id) – the target bursts
	signal landed(string kind, string id)

	// ── words and colours ──────────────────────────────────────────────
	readonly property var clickKeys: [{ value: "", label: "any button" }, { value: "BTN_LEFT", label: "left button" }, { value: "BTN_RIGHT", label: "right button" }, { value: "BTN_MIDDLE", label: "middle button" }]
	readonly property var pressKeys: [{ value: "", label: "any press" }, { value: "BTN_LEFT", label: "left click" }, { value: "BTN_RIGHT", label: "right click" }]
	readonly property var unlessEntries: [
		{ value: "", label: "always", icon: "check" },
		{ value: "hover", label: "unless hovered", icon: "cursor_default_outline", detail: "a highlight is no change" },
		{ value: "click", label: "unless just clicked", icon: "cursor_default_click_outline", detail: "for 1.5 s" },
		{ value: "both", label: "unless hovered or clicked", icon: "gesture_tap" }
	]

	function kindOf(kind) {
		return Mouse.hudKinds.find(k => k.value === kind) ?? Mouse.hudKinds[0];
	}

	function kindColor(kind) {
		switch (kind) {
		case "press": return Theme.secondary;
		case "click": return Theme.tertiary;
		case "hover": return Qt.tint(Theme.secondary, Qt.alpha(Theme.tertiary, 0.5));
		case "red": return Theme.danger;
		case "bright": return Theme.warning;
		case "dark": return Theme.textMuted;
		default: return Theme.primary;
		}
	}

	function keyLabel(trigger) {
		const key = trigger?.key ?? "";
		if (key === "" || key === null) return trigger?.kind === "click" ? "any button" : "any press";
		if (trigger.keyName) return trigger.keyName;
		const names = { BTN_LEFT: "left click", BTN_RIGHT: "right click", BTN_MIDDLE: "middle click", BTN_SIDE: "back button", BTN_EXTRA: "forward button" };
		return names[key] ?? String(key).replace(/^KEY_/, "");
	}

	// a press reaction may listen for a key of the keyboard too
	function keyEntries(trigger, recordingIt) {
		if (trigger?.kind === "click") return root.clickKeys;
		const list = root.pressKeys.slice();
		if (typeof trigger?.key === "number") list.push({ value: String(trigger.key), label: root.keyLabel(trigger), icon: "keyboard_outline" });
		list.push({ value: "record", label: recordingIt ? "press a key…" : "a key…", icon: "record_rec", detail: "press it next" });
		return list;
	}

	// times to pick from; a value set otherwise is offered too
	function timeEntries(choices, current, prefix) {
		const list = choices.includes(current) ? choices : choices.concat([current]).sort((a, b) => a - b);
		return list.map(ms => ({ value: String(ms), label: `${prefix}${ms >= 1000 ? `${ms / 1000} s` : `${ms} ms`}` }));
	}
	function withinEntries(step) {
		return root.timeEntries([1000, 2000, 3000, 5000, 8000, 10000, 15000], Number(step?.within ?? 5000), "within ");
	}
	function delayEntries(step) {
		return root.timeEntries([100, 200, 300, 500, 800, 1000, 1500, 2000, 3000], Number(step?.delay ?? 500), "after ");
	}

	function sceneName(id) {
		return root.scenes.find(s => s.id === id)?.name ?? "Scene";
	}

	// what a sequence does, in a few words
	function presetSummary(preset) {
		const list = Mouse.hudList(preset?.triggers) ?? [];
		return list.map(t => {
			const steps = Mouse.hudStepsOf(t).length;
			return root.kindOf(t.kind).label.toLowerCase() + (steps > 0 ? ` → ${steps} more` : "");
		}).join(", ") || "nothing";
	}

	// fires now: its scene is shown and nothing shown with it quiets it (gamefeel.live_zones)
	function zoneAwake(zone) {
		if (!zone) return false;
		const up = root.liveScenes;
		const scene = root.scenes.find(s => s.id === zone.scene);
		if (scene && scene.picture && !up.includes(scene.id)) return false;
		if ((Mouse.hudList(scene?.quiet) ?? []).some(id => up.includes(id))) return false;
		return !(Mouse.hudList(zone.unless) ?? []).some(id => up.includes(id));
	}

	// a size in the game's pixels
	function pixels(fw, fh) {
		const rect = root.window > 0 ? Mouse.hudWindowRect() : null;
		if (!rect || rect.width <= 0) return `${Math.round(fw * 100)} × ${Math.round(fh * 100)} %`;
		return `${Math.round(fw * rect.width)} × ${Math.round(fh * rect.height)}`;
	}

	// ── choosing ───────────────────────────────────────────────────────
	function isChosen(id) {
		return root.chosenIds.includes(id);
	}

	// the zones linked with this one (itself too)
	function groupOf(zone) {
		if (!zone?.group) return zone ? [zone.id] : [];
		return root.allZones.filter(z => z.group === zone.group).map(z => z.id);
	}

	// one more chosen, or one less (Ctrl/Shift+click)
	function toggle(id) {
		let list = root.chosenIds.slice();
		if (list.includes(id)) list = list.filter(x => x !== id);
		else list.push(id);
		root.selectMany(list);
	}

	function selectMany(ids) {
		const list = ids.filter((id, i) => ids.indexOf(id) === i);
		if (list.length <= 1) {
			root.select(list[0] ?? "");
			return;
		}
		root.multi = list;
		root.selected = list[list.length - 1];
		root.activity = [];
		root.recordingKey = -1;
	}

	function link() {
		if (root.linkedAll) Mouse.hudUnlinkZones(root.multi);
		else {
			Mouse.hudLinkZones(root.multi, root.selected);
			root.toast(`${root.multi.length} zones linked`);
		}
	}

	function select(id) {
		root.multi = [];
		root.selected = id;
		root.activity = [];
		root.recordingKey = -1;
	}

	function chooseScene(id) {
		if (Mouse.hudSceneId !== id || root.selected !== "") {
			Mouse.hudSceneId = id;
			root.select("");
		}
	}

	function takeFocus() {
		root.forceActiveFocus();
	}

	function renameZone(id) {
		root.select(id);
		Qt.callLater(() => inspector.focusName());
	}

	function recordKey(zoneId, index) {
		root.recordingKey = index;
		if (index >= 0) catcher.forceActiveFocus();
	}

	// ── zones ──────────────────────────────────────────────────────────
	function add(rect, values) {
		root.select(Mouse.hudAddZone(rect, values));
		root.takeFocus();
	}

	// the smallest found box under a point of the picture (fractions)
	function boxAt(fx, fy) {
		let best = null;
		for (const b of root.boxes) {
			if (fx >= b[0] && fx <= b[0] + b[2] && fy >= b[1] && fy <= b[1] + b[3]) {
				if (!best || b[2] * b[3] < best[2] * best[3]) best = b;
			}
		}
		return best;
	}

	function takeSuggestion(s) {
		root.add({ x: s.x, y: s.y, w: s.w, h: s.h }, { name: s.name, when: s.when });
		root.suggested = root.suggested.filter(x => x !== s);
		if (root.suggested.length === 0) root.suggesting = false;
	}

	function takeSuggestions() {
		const n = root.suggested.length;
		for (const s of root.suggested) Mouse.hudAddZone({ x: s.x, y: s.y, w: s.w, h: s.h }, { name: s.name, when: s.when });
		root.suggested = [];
		root.suggesting = false;
		root.toast(`${n} zones added`);
	}

	function zoneAction(id, action) {
		const zone = root.allZones.find(z => z.id === id);
		if (!zone) return;
		switch (action) {
		case "rename":
			root.renameZone(id);
			break;
		case "duplicate":
			root.select(Mouse.hudDuplicateZone(id));
			break;
		case "copy":
			Mouse.hudCopyTriggers(id, -1);
			root.toast(`${Mouse.hudClipboard.length} reaction${Mouse.hudClipboard.length === 1 ? "" : "s"} of ${zone.name} copied`, false);
			break;
		case "paste":
			Mouse.hudPasteTriggers(id, false);
			root.landed("zone", id);
			break;
		case "keep":
			root.keepZone(id, -1);
			break;
		case "delete":
			if (root.multi.length > 1 && root.multi.includes(id)) {
				const ids = root.multi;
				root.select("");
				Mouse.hudRemoveZones(ids);
				root.toast(`${ids.length} zones deleted`);
				break;
			}
			if (root.selected === id) root.select("");
			Mouse.hudRemoveZone(id);
			root.toast(`${zone.name} deleted`);
			break;
		}
	}

	function reactionAction(zoneId, index, action) {
		const zone = root.allZones.find(z => z.id === zoneId);
		const trigger = zone ? Mouse.hudTriggers(zone)[index] : null;
		if (!trigger) return;
		switch (action) {
		case "copy":
			Mouse.hudCopyTriggers(zoneId, index);
			root.toast(`${root.kindOf(trigger.kind).label} copied`, false);
			break;
		case "duplicate":
			Mouse.hudInsertTriggers(zoneId, index + 1, [trigger], "a reaction duplicated");
			break;
		case "keep":
			root.keepZone(zoneId, index);
			break;
		case "remove":
			Mouse.hudRemoveTrigger(zoneId, index);
			root.toast(`${root.kindOf(trigger.kind).label} removed`);
			break;
		}
	}

	// ── scenes ─────────────────────────────────────────────────────────
	// a new scene is a picture of what the game shows now
	function newScene() {
		Mouse.hudAddScene("");
		root.select("");
		if (root.window > 0) root.shoot();
	}

	function sceneAction(id, action) {
		const name = root.sceneName(id);
		switch (action) {
		case "shoot":
			root.chooseScene(id);
			root.shoot();
			break;
		case "paste":
			Mouse.hudPasteIntoScene(id, false);
			root.toast(`Pasted into every zone of ${name}`);
			break;
		case "remove":
			root.select("");
			Mouse.hudRemoveScene(id);
			root.toast(`${name} removed`);
			break;
		}
	}

	function tool(id) {
		if (id === "suggest") {
			if (root.suggesting) {
				root.suggesting = false;
				return;
			}
			root.suggesting = true;
			if (root.guessedFor !== root.picture) root.guess();
		} else if (id === "shoot") root.shoot();
		else if (id === "screen") Mouse.hudDraw();
	}

	// a picture of the game's window into the scene, once
	function shoot() {
		if (root.window <= 0 || root.shooting) return;
		Mouse.hudSceneForDrawing();
		root.shooting = true;
		shots.running = false;
		shots.running = true;
		giveUp.restart();
	}

	// the boxes on the scene's picture
	function guess() {
		if (root.picture === "" || root.guessing) return;
		root.guessing = true;
		guesser.running = false;
		guesser.command = ["python3", `${Paths.scripts}/mouse/hud_guess.py`, root.picture, JSON.stringify({ grid: Mouse.eyes?.grid ?? [], yours: Mouse.eyes?.hud?.yours ?? [] })];
		guesser.running = true;
	}

	function pictureReady() {
		if (root.guessedFor !== root.picture && root.picture !== "") root.guess();
	}

	// ── sequences ──────────────────────────────────────────────────────
	// a zone's reactions (or one: index ≥ 0) onto the shelf, named at once
	function keepZone(zoneId, index) {
		const zone = root.allZones.find(z => z.id === zoneId);
		if (!zone) return;
		const trigger = index >= 0 ? Mouse.hudTriggers(zone)[index] : null;
		const id = Mouse.hudSavePreset(trigger ? `${zone.name} · ${root.kindOf(trigger.kind).label}` : zone.name, zoneId, index);
		if (id === "") return;
		root.presetFlash = id;
		root.renamingPreset = id;
	}

	function replaceWithPreset(presetId) {
		if (!root.zone) return;
		Mouse.hudApplyPreset(root.zone.id, presetId, true);
		root.presetFlash = presetId;
		root.landed("zone", root.zone.id);
		root.toast(`${root.zone.name} now does ${Mouse.hudPreset(presetId)?.name ?? ""}`);
	}

	function removePreset(presetId) {
		const name = Mouse.hudPreset(presetId)?.name ?? "";
		Mouse.hudRemovePreset(presetId);
		root.toast(`${name} removed`);
	}

	// ── carrying ───────────────────────────────────────────────────────
	// the reactions a carried thing stands for
	function triggersOf(c) {
		if (c.type === "preset") return Mouse.hudPresetTriggers(Mouse.hudPreset(c.presetId));
		if (c.type === "kind") return [Mouse.hudTrigger(c.kind)];
		if (c.type === "reaction") {
			const zone = root.allZones.find(z => z.id === c.zoneId);
			const t = zone ? Mouse.hudTriggers(zone)[c.index] : null;
			return t ? [JSON.parse(JSON.stringify(t))] : [];
		}
		return [];
	}

	function dropOnZone(zoneId, c) {
		const zone = root.allZones.find(z => z.id === zoneId);
		const list = root.triggersOf(c);
		if (!zone || list.length === 0) return false;
		Mouse.hudInsertTriggers(zoneId, -1, list, c.type === "preset" ? "a sequence used" : "a reaction added");
		if (c.type === "preset") root.presetFlash = c.presetId;
		root.landed("zone", zoneId);
		if (zoneId !== root.selected) root.toast(`${c.label} → ${zone.name}`);
		return true;
	}

	function dropOnScene(sceneId, c) {
		const list = root.triggersOf(c);
		const count = root.allZones.filter(z => z.scene === sceneId).length;
		if (list.length === 0 || count === 0) return false;
		Mouse.hudAddTriggersToScene(sceneId, list, c.type === "preset" ? "a sequence given to the scene" : "reactions given to the scene");
		if (c.type === "preset") root.presetFlash = c.presetId;
		root.landed("scene", sceneId);
		root.toast(`${c.label} → ${count} zone${count === 1 ? "" : "s"} of ${root.sceneName(sceneId)}`);
		return true;
	}

	// let go over a target: kind zone | scene | list (a zone's, at a place) | shelf | bin
	function dropOn(kind, id, at) {
		const c = root.carry;
		if (!c) return;
		let took = false;
		if (kind === "zone") took = root.dropOnZone(id, c);
		else if (kind === "scene") took = root.dropOnScene(id, c);
		else if (kind === "list") {
			if (c.type === "reaction" && c.zoneId === id) {
				const to = at < 0 ? Mouse.hudTriggers(root.zone).length - 1 : (at > c.index ? at - 1 : at);
				if (to !== c.index) Mouse.hudMoveTrigger(id, c.index, to);
				took = true;
			} else {
				const list = root.triggersOf(c);
				if (list.length > 0) {
					Mouse.hudInsertTriggers(id, at, list, c.type === "preset" ? "a sequence used" : "a reaction added");
					if (c.type === "preset") root.presetFlash = c.presetId;
					took = true;
				}
			}
		} else if (kind === "shelf" && c.type === "reaction") {
			root.keepZone(c.zoneId, c.index);
			took = true;
		} else if (kind === "bin") {
			if (c.type === "preset") root.removePreset(c.presetId);
			took = c.type === "preset";
		}
		root.took = took;
	}

	function lift(item, mouse, what) {
		const p = item.mapToItem(root, mouse.x, mouse.y);
		ghostBack.stop();
		ghostGone.stop();
		root.carryFrom = Qt.point(p.x, p.y);
		ghost.x = p.x;
		ghost.y = p.y;
		ghost.opacity = 1;
		ghost.lift = 0;
		root.took = false;
		root.carry = what;
		ghostUp.restart();
	}

	function haul(item, mouse) {
		const p = item.mapToItem(root, mouse.x, mouse.y);
		ghost.x = p.x;
		ghost.y = p.y;
	}

	function land() {
		if (!root.carry) return;
		root.took = false;
		ghost.Drag.drop();
		const took = root.took;
		root.carry = null;
		if (took) ghostGone.restart();
		else ghostBack.restart();
	}

	property point carryFrom: Qt.point(0, 0)

	// ── a word after a change, with a way back ─────────────────────────
	function toast(text, undoable) {
		toastBox.text = text;
		toastBox.undoable = undoable !== false;
		toastBox.up = true;
		toastOff.restart();
	}

	function reveal(anchor) {}

	// an edit of the chosen one is an edit of all chosen
	Binding {
		target: Mouse
		property: "hudMirror"
		value: root.multi
		when: root.active
	}

	onActiveChanged: {
		Mouse.watching = root.active;
		if (root.active && root.picture === "" && root.scenes.length === 0 && root.window > 0) root.shoot();
		if (root.active) root.takeFocus();
	}
	Component.onDestruction: Mouse.watching = false

	onPictureChanged: {
		root.boxes = [];
		root.suggested = [];
		root.suggesting = false;
	}

	Connections {
		target: Mouse

		function onHudPictureRevChanged() {
			root.guessedFor = "";
		}

		function onFelt(source, kind, strength, wave, label, cluster) {
			if (source !== "eyes" || kind !== "zone") return;
			const hit = root.allZones.find(z => z.name === label);
			if (!hit) return;
			root.fired = hit.id;
			firedOff.restart();
		}
	}

	Timer {
		id: firedOff

		interval: 380
		onTriggered: root.fired = ""
	}

	// the chosen zone's change over time, for its little chart
	Timer {
		interval: 120
		repeat: true
		running: root.active && root.watching && !!root.zone
		onTriggered: {
			const v = root.live[root.selected];
			const heat = v ? Math.max(0, Math.min(1, Math.max(v[0], Math.abs(v[1]), Math.abs(v[2])) / 40)) : 0;
			root.activity = root.activity.concat([heat]).slice(-48);
		}
	}

	Timer {
		id: giveUp

		interval: 8000
		onTriggered: {
			root.shooting = false;
			shots.running = false;
		}
	}

	Process {
		id: shots

		command: ["python3", `${Paths.scripts}/window_shots.py`, root.shotDir, "1280", "0"]
		stdinEnabled: true
		onStarted: {
			const raw = Niri.windowMap?.[String(root.window)] ?? Niri.windowMap?.[root.window];
			const size = raw?.layout?.window_size ?? [1920, 1080];
			shots.write(`${root.window}:${Math.round(Number(size[0]) || 1920)}:${Math.round(Number(size[1]) || 1080)}\n`);
		}
		onExited: root.shooting = false
		stdout: SplitParser {
			onRead: line => {
				let data = null;
				try {
					data = JSON.parse(line);
				} catch (error) {
					return;
				}
				if (Number(data.id) !== root.window) return;
				const scene = Mouse.hudSceneForDrawing();
				if (scene?.picture) {
					copier.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && cp -f "$1" "$2"', "sh", String(data.file), String(scene.picture)];
					copier.running = true;
				}
				root.shooting = false;
				shots.running = false;
			}
		}
	}

	Process {
		id: copier

		onExited: Mouse.hudPictureRev += 1
	}

	Process {
		id: guesser

		stdout: StdioCollector {
			onStreamFinished: {
				root.guessing = false;
				let data = null;
				try {
					data = JSON.parse(this.text);
				} catch (error) {
					return;
				}
				root.guessedFor = root.picture;
				root.boxes = Array.isArray(data?.boxes) ? data.boxes : [];
				root.suggested = Array.isArray(data?.suggested) ? data.suggested : [];
			}
		}
		onExited: root.guessing = false
	}

	// ── keys ───────────────────────────────────────────────────────────
	Shortcut {
		sequences: [StandardKey.Undo]
		enabled: root.active && !root.recording
		onActivated: Mouse.hudUndo()
	}

	Shortcut {
		sequences: [StandardKey.Redo, "Ctrl+Y"]
		enabled: root.active && !root.recording
		onActivated: Mouse.hudRedo()
	}

	Keys.onPressed: event => {
		const ctrl = event.modifiers & Qt.ControlModifier;
		const zone = root.zone;
		if (event.key === Qt.Key_Escape && (zone || root.suggesting || root.picking)) {
			if (root.suggesting) root.suggesting = false;
			else if (root.picking) root.picking = false;
			else root.select("");
			event.accepted = true;
		} else if (ctrl && event.key === Qt.Key_A) {
			root.selectMany(root.zones.map(z => z.id));
			event.accepted = true;
		} else if (!zone) {
			return;
		} else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
			root.zoneAction(zone.id, "delete");
			event.accepted = true;
		} else if (ctrl && event.key === Qt.Key_D) {
			root.zoneAction(zone.id, "duplicate");
			event.accepted = true;
		} else if (ctrl && event.key === Qt.Key_C) {
			root.zoneAction(zone.id, "copy");
			event.accepted = true;
		} else if (ctrl && event.key === Qt.Key_V) {
			root.zoneAction(zone.id, "paste");
			event.accepted = true;
		} else if (event.key === Qt.Key_F2) {
			root.renameZone(zone.id);
			event.accepted = true;
		} else if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].includes(event.key)) {
			// nudged: a pixel of the picture, ten with Shift
			const n = event.modifiers & Qt.ShiftModifier ? 10 : 1;
			const dx = (event.key === Qt.Key_Left ? -n : (event.key === Qt.Key_Right ? n : 0)) / Math.max(100, board.pictureWidth);
			const dy = (event.key === Qt.Key_Up ? -n : (event.key === Qt.Key_Down ? n : 0)) / Math.max(60, board.pictureHeight);
			Mouse.hudMoveZones(root.chosenIds, dx, dy);
			event.accepted = true;
		}
	}

	// takes the key while a reaction records one
	Item {
		id: catcher

		Keys.onPressed: event => {
			event.accepted = true;
			const zone = root.zone;
			if (!zone || root.recordingKey < 0) return;
			if (event.key === Qt.Key_Escape) {
				root.recordingKey = -1;
				root.takeFocus();
				return;
			}
			const code = event.nativeScanCode - 8;
			if (code <= 0) return;
			let name = event.text && event.text.trim().length === 1 ? event.text.toUpperCase() : "";
			if (!name) name = { [Qt.Key_Space]: "Space", [Qt.Key_Shift]: "Shift", [Qt.Key_Control]: "Ctrl", [Qt.Key_Alt]: "Alt", [Qt.Key_Tab]: "Tab" }[event.key] ?? `Key ${code}`;
			Mouse.hudChangeTrigger(zone.id, root.recordingKey, { key: code, keyName: name }, "the reaction's key");
			root.recordingKey = -1;
			root.takeFocus();
		}
		onActiveFocusChanged: if (!activeFocus) root.recordingKey = -1
	}

	// ── the workbench ──────────────────────────────────────────────────
	ColumnLayout {
		anchors.fill: parent
		anchors.leftMargin: 28
		anchors.rightMargin: 28
		anchors.topMargin: 24
		anchors.bottomMargin: 24
		spacing: 16

		// title · undo
		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			ColumnLayout {
				spacing: 2

				StyledText {
					text: root.title
					font.pixelSize: 26
					font.weight: Font.Bold
				}

				RowLayout {
					spacing: 6

					Glyph {
						icon: root.game !== "" ? "gamepad_variant" : "sleep"
						size: 14
						color: root.game !== "" ? Theme.primary : Theme.textFaint
					}

					StyledText {
						text: root.game !== "" ? root.game : "No game running – start one and its picture comes here"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}

			// undo and redo, naming the step
			Rectangle {
				Layout.preferredHeight: 38
				Layout.preferredWidth: undoRow.implicitWidth + 8
				radius: 19
				color: Theme.layer1
				clip: true

				Behavior on Layout.preferredWidth {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				RowLayout {
					id: undoRow

					anchors.centerIn: parent
					spacing: 2

					Clickable {
						implicitHeight: 30
						implicitWidth: undoInner.implicitWidth + 22
						radius: 15
						enabled: Mouse.hudUndoLabel !== ""
						opacity: enabled ? 1 : 0.4
						onClicked: Mouse.hudUndo()

						RowLayout {
							id: undoInner

							anchors.centerIn: parent
							spacing: 6

							Glyph {
								icon: "undo"
								size: 16
								color: Theme.text
							}

							StyledText {
								text: Mouse.hudUndoLabel !== "" ? `Undo ${Mouse.hudUndoLabel}` : "Undo"
								font.pixelSize: Theme.size.label
								font.weight: Font.Medium
							}
						}

						Tip {
							below: true
							text: "Ctrl+Z"
						}
					}

					IconButton {
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						icon: "redo"
						enabled: Mouse.hudRedoLabel !== ""
						opacity: enabled ? 1 : 0.4

						onClicked: Mouse.hudRedo()

						Tip {
							below: true
							text: Mouse.hudRedoLabel !== "" ? `Redo ${Mouse.hudRedoLabel} · Ctrl+Shift+Z` : "Redo"
						}
					}
				}
			}
		}

		SceneStrip {
			Layout.fillWidth: true
			page: root
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 16

			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 12

				Board {
					id: board

					Layout.fillWidth: true
					Layout.fillHeight: true
					page: root
				}

				Dock {
					Layout.fillWidth: true
					page: root
				}
			}

			Inspector {
				id: inspector

				Layout.fillHeight: true
				Layout.preferredWidth: Math.round(Math.max(340, Math.min(470, root.width * 0.27)))
				page: root
			}
		}
	}

	// ── what is carried, under the pointer ─────────────────────────────
	Item {
		id: ghost

		property real lift: 0

		width: 1
		height: 1
		z: 1000
		visible: root.carry !== null || ghostBack.running || ghostGone.running
		Drag.active: root.carry !== null
		Drag.keys: ["hud"]
		Drag.hotSpot.x: 0
		Drag.hotSpot.y: 0

		Rectangle {
			id: pill

			readonly property bool over: ghost.Drag.target !== null

			x: 12
			y: -height - 4
			width: pillRow.implicitWidth + 24
			height: 36
			radius: 18
			color: pill.over ? Theme.primary : Theme.layer3
			border.width: 1
			border.color: Qt.alpha(Theme.primary, 0.6)
			rotation: pill.over ? 0 : -4 * ghost.lift
			scale: (0.6 + 0.4 * ghost.lift) * (pill.over ? 0.92 : 1.04)
			transformOrigin: Item.BottomLeft

			Behavior on color {
				ColorAnim {}
			}
			Behavior on rotation {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			// a soft shadow
			Rectangle {
				anchors.fill: parent
				anchors.topMargin: 6
				anchors.bottomMargin: -6
				z: -1
				radius: 18
				color: Theme.shadow
				opacity: 0.5
			}

			RowLayout {
				id: pillRow

				anchors.centerIn: parent
				spacing: 7

				Glyph {
					icon: pill.over ? "plus" : (ghost.shown?.icon ?? "drag")
					size: 15
					color: pill.over ? Theme.onPrimary : Theme.primary
				}

				StyledText {
					text: ghost.shown?.label ?? ""
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
					tone: pill.over ? Theme.onPrimary : Theme.text
				}
			}
		}

		// what it was, still shown while it flies back or vanishes
		property var shown: null

		Connections {
			target: root

			function onCarryChanged() {
				if (root.carry) ghost.shown = root.carry;
			}
		}

		NumberAnimation {
			id: ghostUp

			target: ghost
			property: "lift"
			to: 1
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatialFast
		}

		// let go over nothing: back where it came from
		ParallelAnimation {
			id: ghostBack

			NumberAnimation {
				target: ghost
				property: "x"
				to: root.carryFrom.x
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.emphasized
			}
			NumberAnimation {
				target: ghost
				property: "y"
				to: root.carryFrom.y
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.emphasized
			}
			NumberAnimation {
				target: ghost
				property: "opacity"
				to: 0
				duration: Motion.long
				easing.type: Easing.InQuad
			}
		}

		// taken: it sinks in
		ParallelAnimation {
			id: ghostGone

			NumberAnimation {
				target: ghost
				property: "lift"
				to: 0
				duration: Motion.medium
				easing.type: Easing.InBack
			}
			NumberAnimation {
				target: ghost
				property: "opacity"
				to: 0
				duration: Motion.medium
			}
		}
	}

	// ── the word after a change ────────────────────────────────────────
	Rectangle {
		id: toastBox

		property string text: ""
		property bool undoable: true
		property bool up: false

		anchors.horizontalCenter: parent.horizontalCenter
		y: toastBox.up ? root.height - height - 104 : root.height + 10
		z: 900
		width: toastRow.implicitWidth + 28
		height: 44
		radius: 22
		color: Theme.layer3
		border.width: 1
		border.color: Theme.outline
		opacity: toastBox.up ? 1 : 0
		visible: opacity > 0.01

		Behavior on y {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {}
		}
		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		HoverHandler {
			id: toastHover

			onHoveredChanged: if (!hovered) toastOff.restart()
		}

		Timer {
			id: toastOff

			interval: 3800
			onTriggered: {
				if (toastHover.hovered) return;
				toastBox.up = false;
			}
		}

		RowLayout {
			id: toastRow

			anchors.centerIn: parent
			spacing: 12

			Glyph {
				icon: "check_circle_outline"
				size: 17
				color: Theme.primary
			}

			StyledText {
				text: toastBox.text
				font.weight: Font.Medium
			}

			TextButton {
				visible: toastBox.undoable
				implicitHeight: 30
				text: "Undo"
				icon: "undo"
				variant: "ghost"
				onActivated: {
					Mouse.hudUndo();
					toastBox.up = false;
				}
			}
		}
	}
}
