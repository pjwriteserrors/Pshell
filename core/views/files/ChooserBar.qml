pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The chooser's own part, under the files: who asks and what, the filter
// and the app's options, the name to save as, and the way out. It answers
// every question an app can ask through the portal:
//   OpenFile    one file, many files, one folder or many folders
//   SaveFile    a name in a folder (an existing one is replaced only when agreed)
//   SaveFiles   a folder for files the app names (those already there are agreed to)
Rectangle {
	id: root

	property var entry: null
	property var pane: null
	property var view: null

	// the filter shown: an index into entry.filters, -1 for every file
	property int filterIndex: -1
	// the app's own options: { id: value }; a check box is "true" or "false"
	property var choiceValues: ({})
	// files made ready before the app gets them (chooser.py prepare)
	property var prep: ({ convert: "", longest: 0, quality: 0, strip: false })
	readonly property bool prepping: root.prep.convert !== "" || root.prep.longest > 0 || root.prep.quality > 0 || root.prep.strip
	// what happens once the app wrote a saved file: [{ kind, id, path, label }]
	property var after: []
	// busy getting files ready or over from elsewhere
	property bool working: false
	// lately made files to take at once (chooser.py recent)
	property var recent: []
	// what the chosen pictures tell: { path: { location, camera, … } }
	property var photo: ({})
	// the routine kept for this site or app, and what it would do now
	readonly property string routineKey: Files.routineKey(root.entry)
	readonly property var routine: root.saving && FileLibrary.setting("chooserRoutines") !== "off" ? (FileLibrary.chooser.routines?.[root.routineKey] ?? null) : null
	property var routinePlan: null
	readonly property bool routineAuto: !!FileLibrary.chooser.auto?.[root.routineKey]
	// the auto routine waits this long (ms) for a key or a click that stops it
	property int countdown: 0

	readonly property string method: root.entry?.method ?? "OpenFile"
	readonly property bool saving: root.method === "SaveFile"
	readonly property bool savingMany: root.method === "SaveFiles"
	readonly property bool folders: !!root.entry?.directory && root.method === "OpenFile"
	readonly property bool many: !!root.entry?.multiple
	readonly property string folder: root.pane && root.pane.isFolder ? String(root.pane.location.path) : ""
	readonly property var filters: root.entry?.filters ?? []
	readonly property var choices: root.entry?.choices ?? []
	readonly property int waiting: Math.max(0, Files.chooseQueue.filter(each => each.method !== "ChooseApplication").length - 1)

	readonly property string heading: {
		const title = root.entry?.title ?? "";
		if (title !== "") return title;
		if (root.saving) return "Save";
		if (root.savingMany) return "Choose where the files go";
		if (root.folders) return root.many ? "Choose folders" : "Choose a folder";
		return root.many ? "Open files" : "Open a file";
	}

	readonly property string acceptText: {
		const label = root.entry?.acceptLabel ?? "";
		if (label !== "") return label;
		if (root.saving || root.savingMany) return "Save";
		return root.folders ? "Choose" : "Open";
	}

	// what an open would answer now: rows (a folder of its own is { path, dir })
	readonly property var chosenRows: {
		root.pane?.selectionTick;
		if (!root.entry || !root.pane || root.saving || root.savingMany) return [];
		const rows = root.pane.selectedRows();
		if (root.folders) {
			const dirs = rows.filter(row => row.dir);
			if (dirs.length > 0) return root.many ? dirs : dirs.slice(0, 1);
			return root.folder !== "" ? [{ path: root.folder, name: Files.nameOf(root.folder), dir: true }] : [];
		}
		const filter = root.filterIndex >= 0 ? root.filters[root.filterIndex] : null;
		const files = rows.filter(row => !row.dir && Files.filterTakes(filter, row));
		return root.many ? files : files.slice(0, 1);
	}
	readonly property var chosen: root.chosenRows.map(row => row.path)
	readonly property bool showPrep: !root.saving && !root.savingMany && !root.folders && root.chosenRows.length > 0
	readonly property bool chosenPictures: root.chosenRows.some(row => Files.kindOfName(row.name || row.path) === "image")
	readonly property bool chosenLocation: root.chosen.some(path => root.photo[path]?.location)
	readonly property bool chosenMetadata: root.chosen.some(path => !!root.photo[path])
	// the app asked for kinds the chosen files are not: they can become one
	readonly property string wantedFormat: {
		if (root.filterIndex < 0 && root.filters.length > 0 && root.chosenRows.length > 0) {
			const takes = root.chosenRows.every(row => root.filters.some(filter => Files.filterTakes(filter, row)));
			if (!takes) return root.formatOf(root.filters[root.entry?.filter >= 0 ? root.entry.filter : 0]);
		}
		return "";
	}

	readonly property real chosenSize: {
		root.pane?.selectionTick;
		if (!root.pane || root.folders) return 0;
		return root.pane.selectedRows().filter(row => root.chosen.includes(row.path)).reduce((sum, row) => sum + (row.size || 0), 0);
	}

	readonly property bool canAccept: {
		if (!root.entry) return false;
		if (root.saving) return root.folder !== "" && nameField.text.trim() !== "";
		if (root.savingMany) return root.savingFolder() !== "";
		return root.chosen.length > 0;
	}

	implicitHeight: column.implicitHeight + 24
	height: root.implicitHeight
	radius: Theme.radius.large
	color: Theme.layer1
	border.width: 1
	border.color: Theme.outline

	// ── a new question ────────────────────────────────────────────────────
	function reset(entry) {
		root.filterIndex = entry.filter ?? -1;
		root.prep = { convert: "", longest: 0, quality: 0, strip: false };
		root.after = [];
		root.working = false;
		root.recent = [];
		root.photo = {};
		root.routinePlan = null;
		root.countdown = 0;
		if (entry.method === "OpenFile" && !entry.directory && FileLibrary.setting("chooserRecent") !== false) {
			Files.request("chooserrecent", { limit: 4 }, data => {
				if (root.entry?.token !== entry.token) return;
				root.recent = (data?.entries ?? []).filter(row => root.filters.length === 0 || root.filters.some(filter => Files.filterTakes(filter, row))).slice(0, 8);
			});
		}
		Qt.callLater(() => root.planRoutine());
		const values = {};
		for (const choice of entry.choices ?? []) values[choice.id] = choice.default !== "" ? choice.default : (choice.options.length > 0 ? String(choice.options[0][0]) : "false");
		root.choiceValues = values;
		const file = entry.method === "SaveFile" ? entry.currentFile : "";
		nameField.text = file !== "" ? Files.nameOf(file) : (entry.currentName || "");
	}

	function takeFocus() {
		if (root.saving) {
			nameField.focusInput();
			// the name without its ending is what one usually changes
			const name = nameField.text;
			const dot = name.lastIndexOf(".");
			nameField.input.select(0, dot > 0 ? dot : name.length);
		} else if (root.view) {
			root.view.focusFiles();
		}
	}

	// ── the answers ───────────────────────────────────────────────────────
	function cancel() {
		if (root.entry) Files.finishChoose(root.entry, { response: 1 });
	}

	// the answer goes out: an open's files come over first (phone, other PC)
	// and are made ready when asked; a save is learned from
	function finish(paths, rows) {
		if (!root.entry || paths.length === 0 || root.working) return;
		const entry = root.entry;
		if (root.saving || root.savingMany) {
			// the bar moves on to the next question with the answer: learn first
			if (root.saving && FileLibrary.setting("chooserRoutines") !== "off") root.learn(entry, paths[0]);
			root.answer(entry, paths);
			return;
		}
		root.working = true;
		Files.fetchForChooser(rows ?? paths.map(path => ({ path: path, name: Files.nameOf(path) })), fetched => {
			if (root.entry?.token !== entry.token) return;
			if (fetched.length === 0) {
				root.working = false;
				Files.fail("Nothing came over");
				return;
			}
			const steps = Object.assign({}, root.prep, { convert: root.prep.convert || root.wantedFormat });
			const changes = steps.convert !== "" || steps.longest > 0 || steps.quality > 0 || steps.strip;
			if (!changes || root.folders) {
				root.working = false;
				root.answer(entry, fetched);
				return;
			}
			Files.request("chooserprep", { paths: fetched, steps: steps }, (data, error) => {
				root.working = false;
				if (root.entry?.token !== entry.token) return;
				if (error || !data) {
					Files.fail(error || "The files could not be made ready");
					return;
				}
				for (const note of data.notes ?? []) Files.say(note, "alert_circle_outline");
				root.answer(entry, data.paths);
			});
		});
	}

	function answer(entry, paths) {
		Sounds.play("confirm");
		Files.finishChoose(entry, {
			response: 0,
			paths: paths,
			choices: Object.keys(root.choiceValues).map(id => [id, String(root.choiceValues[id])]),
			filter: root.filterIndex,
			mode: root.pane?.mode ?? "",
			after: root.after
		});
	}

	// ── routines: what was done before saving, done again ─────────────────
	function learn(entry, path) {
		const key = Files.routineKey(entry);
		Files.request("routinelearn", { routine: FileLibrary.chooser.routines?.[key] ?? null, path: path, source: entry.currentName || Files.nameOf(entry.currentFile || ""), since: entry.at / 1000 }, data => {
			if (data?.routine) FileLibrary.chooserSet("routines", key, data.routine);
		});
	}

	function planRoutine() {
		const entry = root.entry;
		if (!entry || !root.routine) return;
		Files.request("routineplan", { routine: root.routine, source: entry.currentName || Files.nameOf(entry.currentFile || ""), context: { app: entry.appName, site: entry.site } }, data => {
			if (root.entry?.token !== entry.token || !data) return;
			root.routinePlan = data;
			if (root.routineAuto) root.countdown = 2400;
		});
	}

	function runRoutine() {
		const plan = root.routinePlan;
		if (!plan) return;
		root.countdown = 0;
		Files.request("routinemake", { make: plan.make }, (data, error) => {
			if (error) {
				Files.fail(error);
				return;
			}
			root.saveTo([plan.path]);
		});
	}

	function forgetRoutine() {
		FileLibrary.chooserSet("routines", root.routineKey, undefined);
		FileLibrary.chooserSet("auto", root.routineKey, undefined);
		root.routinePlan = null;
		root.countdown = 0;
	}

	Timer {
		running: root.countdown > 0 && root.visible
		interval: 100
		repeat: true
		onTriggered: {
			root.countdown = Math.max(0, root.countdown - 100);
			if (root.countdown === 0) root.runRoutine();
		}
	}

	Shortcut {
		sequences: ["Ctrl+Shift+Return", "Ctrl+Shift+Enter"]
		enabled: root.visible && root.routinePlan !== null
		onActivated: root.runRoutine()
	}

	// any key or click while it counts stops the routine
	function stopCountdown() {
		root.countdown = 0;
	}

	// ── names from patterns ───────────────────────────────────────────────
	readonly property var patterns: [
		{ value: "like", label: "Like the newest file here", detail: "Its number one up, its date today", icon: "file_replace_outline" },
		{ value: "{date} {name}{ext}", label: "Date first", detail: "{date} {name}{ext}", icon: "calendar_today" },
		{ value: "{name} {n}{ext}", label: "Numbered", detail: "{name} {n}{ext}", icon: "numeric" },
		{ value: "{name|normal}{ext}", label: "Normal case", detail: "{name|normal}{ext}", icon: "format_letter_case" },
		{ value: "{site} {date}{ext}", label: "Site and date", detail: "{site} {date}{ext}", icon: "web" }
	].concat((FileLibrary.chooser.templates ?? []).map(template => ({ value: template, label: template, detail: "Kept pattern", icon: "bookmark_outline" })))

	function usePattern(value) {
		const entry = root.entry;
		if (!entry || root.folder === "") return;
		const source = entry.currentName || nameField.text;
		const args = value === "like" ? { like: true } : { template: value };
		Files.request("namefor", Object.assign({ folder: root.folder, source: source, context: { app: entry.appName, site: entry.site } }, args), data => {
			if (data?.name) {
				nameField.text = data.name;
				root.takeFocus();
			} else if (value === "like") {
				Files.say("Nothing here to follow", "information_outline");
			}
		});
	}

	function keepPattern() {
		const text = nameField.text.trim();
		if (!text.includes("{")) return;
		FileLibrary.chooserSet("templates", null, [text].concat((FileLibrary.chooser.templates ?? []).filter(each => each !== text)).slice(0, 12));
		Files.say("Pattern kept", "bookmark_outline");
	}

	// ── after the save ────────────────────────────────────────────────────
	readonly property var destinations: {
		const out = [];
		if (Phone.reachable) out.push({ kind: "phone", id: "phone", label: "To the phone", icon: "cellphone_arrow_down" });
		for (const device of Pcs.reachable) out.push({ kind: "pc", id: device.id, label: `To ${device.name}`, icon: "laptop" });
		out.push({ kind: "link", id: "link", label: "Share a link", icon: "link_variant" });
		for (const vault of (Files.vaults.vaults ?? []).filter(vault => vault.open && vault.mount)) out.push({ kind: "vault", id: vault.id, path: vault.mount, label: `Into ${vault.name || "the vault"}`, icon: "safe" });
		return out;
	}

	function toggleAfter(target) {
		const has = root.after.some(each => each.kind === target.kind && each.id === target.id);
		root.after = has ? root.after.filter(each => !(each.kind === target.kind && each.id === target.id)) : root.after.concat([target]);
	}

	// ── what the chosen pictures tell, the format they may become ─────────
	onChosenChanged: photoTimer.restart()

	Timer {
		id: photoTimer

		interval: 250
		onTriggered: {
			const paths = root.chosen.filter(path => path.startsWith("/") && Files.kindOfName(path) === "image");
			if (paths.length === 0 || FileLibrary.setting("chooserPrivacy") === false) {
				root.photo = {};
				return;
			}
			Files.request("photoinfo", { paths: paths }, data => {
				root.photo = data?.info ?? {};
				// where a picture was taken stays home unless asked otherwise
				if (root.chosenLocation && !root.prep.strip) root.prep = Object.assign({}, root.prep, { strip: true });
			});
		}
	}

	// the first ending a filter names ("png" of *.png or image/png)
	function formatOf(filter) {
		if (!filter) return "";
		for (const rule of filter.rules ?? []) {
			const text = String(rule[1]).toLowerCase();
			const glob = /^\*\.([a-z0-9]+)$/.exec(text);
			if (Number(rule[0]) === 0 && glob) return glob[1] === "jpeg" ? "jpg" : glob[1];
			const mime = /^image\/(png|jpeg|webp|avif|gif|bmp|tiff|heic)$/.exec(text);
			if (Number(rule[0]) === 1 && mime) return mime[1] === "jpeg" ? "jpg" : mime[1];
		}
		return "";
	}

	// files dropped on the window answer an open; a folder dropped is where a save goes
	function dropped(paths) {
		if (!root.entry || paths.length === 0) return;
		if (root.saving || root.savingMany || root.folders) {
			Files.request("describe", { paths: paths.slice(0, 1) }, data => {
				const first = data?.entries?.[0];
				if (!first) return;
				if (first.dir) root.pane.openFolder(first.path);
				else if (root.saving) root.pane.openFolder(Files.parentOf(first.path));
			});
			return;
		}
		root.finish(root.many ? paths : paths.slice(0, 1));
	}

	function savingFolder() {
		if (!root.pane) return "";
		const rows = root.pane.selectedRows();
		if (rows.length === 1 && rows[0].dir) return rows[0].path;
		return root.folder;
	}

	// what the name field means: a name here, a path of its own, a folder to step into
	function targetOf(text) {
		const name = text.trim();
		if (name.startsWith("~/")) return Files.home + name.slice(1);
		if (name.startsWith("/")) return name;
		return `${root.folder === "/" ? "" : root.folder}/${name}`;
	}

	function accept() {
		if (!root.entry || !root.pane) return;
		if (root.saving) {
			const name = nameField.text.trim();
			if (name === "" || root.folder === "") return;
			if (name === "..") {
				nameField.text = "";
				root.pane.goUp();
				return;
			}
			// a folder's name steps into it, as in every chooser
			const into = root.pane.rows.find(row => row.dir && row.name === name);
			if (into) {
				nameField.text = "";
				root.pane.openFolder(into.path);
				return;
			}
			const path = root.targetOf(name);
			if (name.endsWith("/")) {
				root.pane.openFolder(path.replace(/\/+$/, ""));
				nameField.text = "";
				return;
			}
			// a pattern ({date}, {n}, …) becomes the name first
			if (name.includes("{")) {
				Files.request("namefor", { folder: path.slice(0, path.lastIndexOf("/")) || "/", template: Files.nameOf(path), source: root.entry.currentName || "", context: { app: root.entry.appName, site: root.entry.site } }, data => {
					if (data?.name) root.saveTo([`${path.slice(0, path.lastIndexOf("/"))}/${data.name}`]);
				});
				return;
			}
			root.saveTo([path]);
			return;
		}
		if (root.savingMany) {
			const target = root.savingFolder();
			if (target === "") return;
			root.saveTo((root.entry.files ?? []).map(name => `${target === "/" ? "" : target}/${name}`));
			return;
		}
		// a file asked for while a folder is picked: the folder opens
		if (!root.folders && root.chosen.length === 0) {
			const current = root.pane.currentRow;
			if (current?.dir) root.pane.openFolder(current.path);
			return;
		}
		root.finish(root.chosen, root.chosenRows);
	}

	// saving over what is there is agreed to first
	function saveTo(paths) {
		Files.request("describe", { paths: paths }, data => {
			const there = (data?.entries ?? []).map(entry => String(entry.path));
			const dirs = (data?.entries ?? []).filter(entry => entry.dir).map(entry => String(entry.path));
			if (dirs.length > 0) {
				Files.say(`${Files.nameOf(dirs[0])} is a folder`, "folder_alert_outline");
				return;
			}
			if (there.length === 0) {
				root.finish(paths);
				return;
			}
			root.view?.askConfirm({
				title: there.length === 1 ? `Replace ${Files.nameOf(there[0])}?` : `Replace ${there.length} files?`,
				detail: there.length === 1 ? `It is already in ${Files.nameOf(Files.parentOf(there[0])) || "/"}; saving writes over it.` : there.map(path => Files.nameOf(path)).join(", "),
				confirm: "Replace",
				danger: true,
				run: () => root.finish(paths)
			});
		});
	}

	// a file opened (double click, Enter) in the files
	function openedFiles(rows) {
		if (root.saving) {
			if (rows.length > 0) {
				nameField.text = rows[0].name;
				root.accept();
			}
			return;
		}
		if (root.folders || root.savingMany) return;
		const filter = root.filterIndex >= 0 ? root.filters[root.filterIndex] : null;
		const taken = rows.filter(row => Files.filterTakes(filter, row));
		const some = root.many ? taken : taken.slice(0, 1);
		if (some.length > 0) root.finish(some.map(row => row.path), some);
	}

	// another filter: a name to save takes its ending
	function pickFilter(index) {
		root.filterIndex = index;
		if (!root.saving || index < 0) return;
		const glob = (root.filters[index]?.rules ?? []).map(rule => String(rule[1])).find(pattern => /^\*\.[A-Za-z0-9]+$/.test(pattern));
		const name = nameField.text;
		if (!glob || name === "") return;
		const dot = name.lastIndexOf(".");
		nameField.text = `${dot > 0 ? name.slice(0, dot) : name}${glob.slice(1)}`;
	}

	// a file clicked while saving: its name is the one to save as
	Connections {
		target: root.pane
		ignoreUnknownSignals: true

		function onSelectionTickChanged() {
			if (!root.saving || !root.pane) return;
			const rows = root.pane.selectedRows();
			if (rows.length === 1 && !rows[0].dir) nameField.text = rows[0].name;
		}
	}

	// ── the bar ───────────────────────────────────────────────────────────
	ColumnLayout {
		id: column

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		spacing: 10

		// what was done last time here, offered (or done by itself)
		Rectangle {
			id: routineBanner

			visible: root.routinePlan !== null
			Layout.fillWidth: true
			Layout.preferredHeight: routineRow.implicitHeight + 16
			radius: Theme.radius.medium
			color: Theme.primaryContainer
			clip: true

			// the countdown of a routine done without asking
			Rectangle {
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				width: root.countdown > 0 ? parent.width * (1 - root.countdown / 2400) : 0
				color: Theme.primary
				opacity: 0.18
			}

			RowLayout {
				id: routineRow

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				anchors.leftMargin: 12
				anchors.rightMargin: 8
				spacing: 10

				Glyph {
					icon: "auto_fix"
					color: Theme.text
					size: 18
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: `Like last time${root.entry?.site ? ` on ${root.entry.site}` : (root.entry?.appName ? ` in ${root.entry.appName}` : "")}${(root.routine?.count ?? 0) > 1 ? ` (${root.routine.count}×)` : ""}`
						tone: Theme.text
						font.weight: Font.DemiBold
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							const steps = root.routinePlan?.steps ?? [];
							const text = steps.join(", then ");
							return text.charAt(0).toUpperCase() + text.slice(1) + (root.countdown > 0 ? " – in a moment, any key stops it" : "");
						}
						tone: Theme.text
						font.pixelSize: Theme.size.small
						elide: Text.ElideMiddle
					}
				}

				StyledText {
					text: "Always"
					tone: Theme.text
					font.pixelSize: Theme.size.small
				}

				Toggle {
					checked: root.routineAuto
					onToggled: on => FileLibrary.chooserSet("auto", root.routineKey, on ? true : undefined)
				}

				IconButton {
					width: 32
					height: 32
					iconSize: 16
					icon: "close"
					onClicked: root.countdown > 0 ? root.stopCountdown() : root.forgetRoutine()
				}

				TextButton {
					text: root.countdown > 0 ? "Now" : "Do it  ⌃⇧↵"
					variant: "filled"
					onActivated: root.runRoutine()
				}
			}
		}

		// lately made: a screenshot, a download, the clipboard – one click takes it
		Flickable {
			visible: root.recent.length > 0 && !root.saving && !root.savingMany && !root.folders
			Layout.fillWidth: true
			Layout.preferredHeight: 52
			contentWidth: recentRow.implicitWidth
			flickableDirection: Flickable.HorizontalFlick
			clip: true

			Row {
				id: recentRow

				spacing: 8

				StyledText {
					height: 52
					verticalAlignment: Text.AlignVCenter
					text: "Lately"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}

				Repeater {
					model: root.recent

					delegate: Clickable {
						id: recentCard

						required property var modelData

						width: Math.min(240, recentInner.implicitWidth + 16)
						height: 52
						radius: Theme.radius.medium
						color: Theme.layer2
						onClicked: root.finish([recentCard.modelData.path], [recentCard.modelData])

						Component.onCompleted: if (Files.kindOfName(recentCard.modelData.name) === "image") Files.wantThumb(recentCard.modelData.path, recentCard.modelData.mime, "normal")

						RowLayout {
							id: recentInner

							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							anchors.leftMargin: 8
							spacing: 8

							Rectangle {
								Layout.preferredWidth: 36
								Layout.preferredHeight: 36
								radius: 6
								color: Theme.layer3
								clip: true

								Image {
									id: recentThumb

									anchors.fill: parent
									source: Files.thumbOf(recentCard.modelData.path) !== "" ? `file://${Files.thumbOf(recentCard.modelData.path)}` : ""
									fillMode: Image.PreserveAspectCrop
									asynchronous: true
									visible: status === Image.Ready
								}

								Glyph {
									anchors.centerIn: parent
									visible: !recentThumb.visible
									icon: recentCard.modelData.source === "capture" ? "monitor_screenshot" : (recentCard.modelData.source === "clip" ? "clipboard_outline" : "download")
									size: 18
									color: Theme.textMuted
								}
							}

							ColumnLayout {
								spacing: 0

								StyledText {
									Layout.maximumWidth: 170
									text: recentCard.modelData.name
									font.pixelSize: Theme.size.small
									elide: Text.ElideMiddle
								}

								StyledText {
									text: `${recentCard.modelData.sourceLabel} · ${Files.whenText(recentCard.modelData.mtime)}`
									tone: Theme.textMuted
									font.pixelSize: Theme.size.tiny
								}
							}
						}
					}
				}
			}
		}

		// who asks, what for, and the app's options
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Item {
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28

				Image {
					id: appIcon

					anchors.fill: parent
					source: root.entry?.appIcon ? Quickshell.iconPath(root.entry.appIcon, true) : ""
					sourceSize: Qt.size(56, 56)
					visible: status === Image.Ready
					asynchronous: true
				}

				Glyph {
					anchors.centerIn: parent
					visible: !appIcon.visible
					icon: root.saving || root.savingMany ? "content_save_outline" : (root.folders ? "folder_outline" : "file_outline")
					color: Theme.primary
					size: 22
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					Layout.fillWidth: true
					text: root.heading
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					visible: text !== ""
					text: {
						const app = root.entry?.appName ?? "";
						const what = root.savingMany ? `${(root.entry?.files ?? []).length} files: ${(root.entry?.files ?? []).join(", ")}` : "";
						return [app !== "" ? `${app} asks` : "", what, root.waiting > 0 ? `${root.waiting} more waiting` : ""].filter(part => part !== "").join(" · ");
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			// the app's own options: a check box, or one of a few
			Repeater {
				model: root.choices

				delegate: Item {
					id: choice

					required property var modelData
					readonly property bool check: (choice.modelData.options ?? []).length === 0
					readonly property string value: String(root.choiceValues[choice.modelData.id] ?? "")

					Layout.preferredWidth: choice.check ? checkRow.implicitWidth : choiceButton.implicitWidth
					Layout.preferredHeight: 36

					RowLayout {
						id: checkRow

						visible: choice.check
						anchors.verticalCenter: parent.verticalCenter
						spacing: 8

						StyledText {
							text: choice.modelData.label
							font.pixelSize: Theme.size.small
						}

						Toggle {
							checked: choice.value === "true"
							onToggled: on => root.choiceValues = Object.assign({}, root.choiceValues, { [choice.modelData.id]: on ? "true" : "false" })
						}
					}

					TextButton {
						id: choiceButton

						visible: !choice.check
						anchors.verticalCenter: parent.verticalCenter
						variant: "tonal"
						icon: "chevron_down"
						text: {
							const option = (choice.modelData.options ?? []).find(each => String(each[0]) === choice.value);
							return `${choice.modelData.label}: ${option ? option[1] : choice.value}`;
						}
						onActivated: choiceList.open()

						PickList {
							id: choiceList

							y: -height - 6
							current: choice.value
							entries: (choice.modelData.options ?? []).map(each => ({ value: String(each[0]), label: String(each[1]) }))
							onPicked: value => root.choiceValues = Object.assign({}, root.choiceValues, { [choice.modelData.id]: String(value) })
						}
					}
				}
			}

			TextButton {
				id: filterButton

				visible: root.filters.length > 0 && !root.savingMany && !root.folders
				variant: "tonal"
				icon: "filter_variant"
				text: root.filterIndex >= 0 ? (root.filters[root.filterIndex]?.name ?? "") : "All files"
				onActivated: filterList.open()

				PickList {
					id: filterList

					y: -height - 6
					x: filterButton.width - width
					current: String(root.filterIndex)
					entries: root.filters.map((filter, index) => ({
						value: String(index),
						label: filter.name,
						detail: (filter.rules ?? []).map(rule => String(rule[1])).join(" "),
						icon: "filter_variant"
					})).concat([{ value: "-1", label: "All files", detail: "Everything, whatever the app asked for", icon: "file_multiple_outline" }])
					onPicked: value => root.pickFilter(Number(value))
				}
			}
		}

		// made ready before the app gets them, where a save goes on to, name patterns
		Flow {
			id: tools

			// not by the rows' own visibility: that is false while this is hidden
			visible: root.showPrep || root.saving || root.savingMany
			Layout.fillWidth: true
			spacing: 8

			// pictures and other files on their way to an app
			Row {
				id: prepTools

				visible: root.showPrep
				spacing: 8

				Chip {
					visible: root.wantedFormat !== "" || root.prep.convert !== ""
					text: root.prep.convert !== "" ? `As ${root.prep.convert.toUpperCase()}` : `Becomes ${root.wantedFormat.toUpperCase()} for the app`
					icon: "swap_horizontal"
					selected: true
					onClicked: formatList.open()

					PickList {
						id: formatList

						y: -height - 6
						current: root.prep.convert
						entries: [{ value: "", label: "As it is", icon: "file_outline" }].concat(["png", "jpg", "webp", "avif", "pdf"].map(format => ({ value: format, label: format.toUpperCase(), icon: "swap_horizontal" })))
						onPicked: value => root.prep = Object.assign({}, root.prep, { convert: String(value) })
					}
				}

				Chip {
					visible: root.chosenPictures
					text: "Smaller"
					icon: "image_size_select_small"
					selected: root.prep.longest > 0
					onClicked: root.prep = Object.assign({}, root.prep, { longest: root.prep.longest > 0 ? 0 : 1920 })
				}

				Chip {
					visible: root.chosenPictures
					text: "Lighter"
					icon: "zip_box_outline"
					selected: root.prep.quality > 0
					onClicked: root.prep = Object.assign({}, root.prep, { quality: root.prep.quality > 0 ? 0 : 72 })
				}

				Chip {
					visible: root.chosenPictures
					text: root.chosenLocation ? "Where it was taken: removed" : (root.chosenMetadata ? "Without metadata" : "Without metadata")
					icon: root.chosenLocation ? "map_marker_off_outline" : "shield_outline"
					selected: root.prep.strip
					accent: root.chosenLocation ? Theme.warning : Theme.primary
					onClicked: root.prep = Object.assign({}, root.prep, { strip: !root.prep.strip })
				}

				Chip {
					visible: !root.chosenPictures && root.wantedFormat === "" && root.prep.convert === ""
					text: "Another format"
					icon: "swap_horizontal"
					onClicked: formatList.open()
				}

				StyledText {
					visible: root.chosenLocation && !root.prep.strip
					height: 30
					verticalAlignment: Text.AlignVCenter
					text: "This picture says where it was taken"
					tone: Theme.warning
					font.pixelSize: Theme.size.small
				}
			}

			// once the app wrote the file
			Row {
				id: afterTools

				visible: root.saving || root.savingMany
				spacing: 8

				Chip {
					text: "Pattern"
					icon: "form_textbox"
					visible: root.saving
					onClicked: patternList.open()

					PickList {
						id: patternList

						y: -height - 6
						entries: root.patterns.concat(nameField.text.includes("{") ? [{ value: "keep", label: "Keep this pattern", detail: nameField.text, icon: "bookmark_plus_outline" }] : [])
						onPicked: value => value === "keep" ? root.keepPattern() : root.usePattern(String(value))
					}
				}

				Repeater {
					model: root.destinations

					delegate: Chip {
						id: target

						required property var modelData

						text: target.modelData.label
						icon: target.modelData.icon
						selected: root.after.some(each => each.kind === target.modelData.kind && each.id === target.modelData.id)
						onClicked: root.toggleAfter(target.modelData)
					}
				}
			}
		}

		// the name, or what is chosen; and the buttons
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Field {
				id: nameField

				visible: root.saving
				Layout.fillWidth: true
				icon: "form_textbox"
				placeholder: "Name"
				clearable: true
				onAccepted: root.accept()
				onEscapePressed: root.countdown > 0 ? root.stopCountdown() : root.cancel()
				onEdited: root.stopCountdown()
				onDownPressed: root.view?.focusFiles()
			}

			StyledText {
				visible: !root.saving
				Layout.fillWidth: true
				text: {
					if (root.savingMany) {
						const target = root.savingFolder();
						return target === "" ? "Open a folder to save in" : `Into ${Files.nameOf(target) || "/"}`;
					}
					if (root.chosen.length === 0) return root.folders ? "Open the folder to choose" : (root.many ? "Pick one file or more, or drop them here" : "Pick a file, or drop one here");
					if (root.chosen.length === 1) return Files.nameOf(root.chosen[0]) || root.chosen[0];
					return `${root.chosen.length} ${root.folders ? "folders" : "files"}${root.chosenSize > 0 ? ` · ${Format.bytes(root.chosenSize)}` : ""}`;
				}
				tone: root.chosen.length > 0 || root.savingMany ? Theme.text : Theme.textMuted
				elide: Text.ElideMiddle
			}

			StyledText {
				visible: root.saving
				Layout.maximumWidth: 260
				text: root.folder !== "" ? `in ${Files.nameOf(root.folder) || "/"}` : "Open a folder to save in"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				elide: Text.ElideMiddle
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onActivated: root.cancel()
			}

			TextButton {
				text: root.working ? "Getting it ready…" : root.acceptText
				variant: "filled"
				busy: root.working
				enabled: root.canAccept && !root.working
				onActivated: root.accept()
			}
		}
	}
}
