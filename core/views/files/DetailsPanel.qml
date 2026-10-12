pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// Beside the files: the picked one large, with everything known about it
// (dimensions, camera, length, pages, lines), its tags and what can be done
// with it; several picked: how many and how big together; nothing picked:
// the folder itself.
Rectangle {
	id: root

	property var pane: null
	required property var view

	readonly property var picked: {
		root.pane?.selectionTick;
		return root.pane ? root.pane.targets() : [];
	}
	readonly property var subject: root.picked.length === 1 ? root.picked[0] : null
	// nothing picked in a folder: the folder
	readonly property string path: root.subject ? root.subject.path : (root.picked.length === 0 && root.pane?.isFolder ? root.pane.location.path : "")
	property var info: null
	// earlier versions of the picked file, once asked for
	property var versions: null
	property bool versionsLoading: false

	function loadVersions() {
		const path = root.path;
		if (path === "" || root.versionsLoading) return;
		root.versionsLoading = true;
		Files.versionsOf(path, list => {
			root.versionsLoading = false;
			if (path === root.path) root.versions = list;
		});
	}

	radius: Theme.radius.huge
	color: Theme.layer1
	clip: true

	onPathChanged: infoTimer.restart()

	Timer {
		id: infoTimer

		interval: 90
		onTriggered: {
			const path = root.path;
			if (path === "" || !root.visible) {
				root.info = null;
				return;
			}
			Files.request("info", { path: path }, (data, error) => {
				if (path === root.path) root.info = error ? null : data;
			});
		}
	}

	onVisibleChanged: if (visible) infoTimer.restart()

	readonly property var entry: root.info ?? root.subject ?? null
	readonly property string kind: Kinds.kindOf(root.entry)

	Flickable {
		anchors.fill: parent
		anchors.margins: 16
		contentHeight: body.implicitHeight + 20
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: body

			width: parent.width
			spacing: 14

			// ── the picture ────────────────────────────────────────────────
			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.round(width * 0.78)
				radius: Theme.radius.large
				color: Theme.layer2

				// one file or the folder
				FileThumb {
					id: big

					visible: root.picked.length <= 1 && !!root.entry
					anchors.centerIn: parent
					width: parent.width - (root.kind === "image" || root.kind === "video" ? 0 : 40)
					height: parent.height - (root.kind === "image" || root.kind === "video" ? 0 : 30)
					radius: Theme.radius.large
					size: "x-large"
					path: String(root.entry?.path ?? "")
					name: String(root.entry?.name ?? "")
					mime: String(root.entry?.mime ?? "")
					dir: !!root.entry?.dir
					kind: root.kind
					thumb: String(root.entry?.thumb ?? "")
					canThumb: !!root.entry?.canThumb || (!root.entry?.thumb && !!root.subject?.canThumb)
					isText: !!root.entry?.text
					hovered: preview.containsMouse
				}

				// several: a fanned stack
				Repeater {
					model: root.picked.length > 1 ? root.picked.slice(0, 4) : []

					delegate: Rectangle {
						id: sheet

						required property var modelData
						required property int index
						readonly property real spread: sheet.index - (Math.min(4, root.picked.length) - 1) / 2

						anchors.centerIn: parent
						anchors.horizontalCenterOffset: sheet.spread * 26
						width: parent.width * 0.42
						height: width
						radius: 16
						rotation: sheet.spread * 8
						color: Theme.layer3
						border.width: 2
						border.color: Theme.layer1

						FileThumb {
							anchors.fill: parent
							anchors.margins: 8
							compact: true
							radius: 10
							path: sheet.modelData.path
							name: sheet.modelData.name
							mime: sheet.modelData.mime
							dir: sheet.modelData.dir
							kind: sheet.modelData.kind
							thumb: sheet.modelData.thumb
							canThumb: sheet.modelData.canThumb
						}
					}
				}

				MouseArea {
					id: preview

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: root.subject ? Qt.PointingHandCursor : Qt.ArrowCursor
					onClicked: if (root.subject && root.pane) root.view.quickLook(root.pane)
				}
			}

			// ── the name ───────────────────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 3

				StyledText {
					Layout.fillWidth: true
					text: root.picked.length > 1 ? `${root.picked.length} items` : String(root.entry?.name ?? root.pane?.title ?? "")
					font.pixelSize: Theme.size.heading
					font.weight: Font.DemiBold
					wrapMode: Text.WrapAtWordBoundaryOrAnywhere
					maximumLineCount: 3
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					tone: Theme.textMuted
					text: {
						if (root.picked.length > 1) {
							const kinds = {};
							for (const row of root.picked) kinds[row.kind] = (kinds[row.kind] ?? 0) + 1;
							const parts = Object.keys(kinds).map(kind => `${kinds[kind]} ${Kinds.kindLabel(kind).toLowerCase()}`);
							return parts.join(", ");
						}
						if (!root.entry) return "";
						if (root.entry.dir) return root.info?.items !== undefined ? `Folder · ${root.info.items} items` : "Folder";
						return `${root.info?.kind ?? Kinds.kindLabel(root.kind)} · ${Files.sizeText(root.entry.size)}`;
					}
					wrapMode: Text.WordWrap
				}
			}

			// ── quick actions ──────────────────────────────────────────────
			Flow {
				Layout.fillWidth: true
				spacing: 6
				visible: root.picked.length > 0

				TextButton {
					text: "Open"
					icon: "open_in_app"
					variant: "filled"
					height: 32
					onClicked: root.view.openRows(root.pane, root.picked, false)
				}

				IconButton {
					width: 32
					height: 32
					iconSize: 16
					variant: "tonal"
					icon: "dots_horizontal"
					onClicked: {
						const at = mapToItem(root.view, 0, height + 4);
						root.view.showRowsMenu(root.pane, root.picked, at.x, at.y);
					}
				}

				IconButton {
					visible: Plugins.on("shelves")
					width: 32
					height: 32
					iconSize: 16
					variant: "tonal"
					icon: "tray_arrow_down"
					onClicked: root.view.toShelf(root.picked)
				}

				IconButton {
					visible: Phone.available
					width: 32
					height: 32
					iconSize: 16
					variant: "tonal"
					icon: "cellphone_arrow_down"
					onClicked: root.picked.filter(row => !row.dir).forEach(row => Phone.shareFile(row.path))
				}

				IconButton {
					width: 32
					height: 32
					iconSize: 16
					variant: "danger"
					icon: "trash_can_outline"
					onClicked: Files.trash(root.picked.map(row => row.path))
				}
			}

			// ── what is known ──────────────────────────────────────────────
			GridLayout {
				Layout.fillWidth: true
				columns: 2
				columnSpacing: 12
				rowSpacing: 7
				visible: root.picked.length <= 1 && !!root.entry

				Repeater {
					model: {
						const out = [];
						const info = root.info;
						if (!info) return out;
						for (const fact of info.facts ?? []) out.push({ label: fact[0], value: fact[1] });
						out.push({ label: "Modified", value: Qt.formatDateTime(new Date(info.mtime * 1000), "d MMM yyyy, HH:mm") });
						if (info.created) out.push({ label: "Created", value: Qt.formatDateTime(new Date(info.created * 1000), "d MMM yyyy, HH:mm") });
						if (info.orig) out.push({ label: "Was in", value: Files.pretty(Files.parentOf(info.orig)) });
						out.push({ label: "Where", value: Files.pretty(Files.parentOf(info.path)), link: Files.parentOf(info.path) });
						if (info.link) out.push({ label: "Link to", value: "a symbolic link" });
						if (info.mode) out.push({ label: "Access", value: `${info.owner} · ${info.mode}` });
						// a label and its value, side by side in the grid
						const cells = [];
						for (const fact of out) cells.push({ fact: fact, value: false }, { fact: fact, value: true });
						return cells;
					}

					delegate: Text {
						required property var modelData

						Layout.fillWidth: modelData.value
						Layout.alignment: Qt.AlignTop
						text: modelData.value ? String(modelData.fact.value) : modelData.fact.label
						color: modelData.value ? (modelData.fact.link ? Theme.primary : Theme.text) : Theme.textSubtle
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.label
						wrapMode: modelData.value ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
						font.underline: !!modelData.fact.link && link.containsMouse

						MouseArea {
							id: link

							anchors.fill: parent
							enabled: parent.modelData.value && !!parent.modelData.fact.link
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.pane.go({ kind: "dir", path: parent.modelData.fact.link }, { select: [root.info.path] })
						}
					}
				}
			}

			// a folder's size, worked out when asked
			RowLayout {
				Layout.fillWidth: true
				visible: !!root.entry?.dir && root.picked.length <= 1
				spacing: 8

				readonly property var size: Files.sizes[root.path] ?? null

				StyledText {
					Layout.fillWidth: true
					text: parent.size ? `${Files.sizeText(parent.size.size)} in ${parent.size.files} files` + (parent.size.done ? "" : " (stopped)") : "Size not worked out yet"
					tone: parent.size ? Theme.text : Theme.textSubtle
					font.pixelSize: Theme.size.label
				}

				TextButton {
					height: 28
					variant: "ghost"
					text: "Work it out"
					icon: "scale_balance"
					visible: !parent.size
					onClicked: Files.measure(root.path)
				}
			}

			// what an archive holds
			ColumnLayout {
				Layout.fillWidth: true
				visible: (root.info?.listing ?? []).length > 0
				spacing: 3

				SectionLabel {
					text: "Inside"
				}

				Repeater {
					model: root.info?.listing ?? []

					delegate: StyledText {
						required property string modelData

						Layout.fillWidth: true
						text: modelData
						tone: Theme.textMuted
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.small
						elide: Text.ElideMiddle
					}
				}
			}

			// ── tags ───────────────────────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				visible: root.picked.length > 0
				spacing: 8

				SectionLabel {
					text: "Tags"
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: FileLibrary.tags

						delegate: Chip {
							required property var modelData
							readonly property bool on: {
								FileLibrary.tagged;
								return root.picked.length > 0 && root.picked.every(row => FileLibrary.hasTag(row.path, modelData.id));
							}

							height: 28
							text: modelData.name
							icon: on ? "check" : "circle"
							selected: on
							accent: FileLibrary.colorOf(modelData.color)
							onClicked: FileLibrary.toggleTag(root.picked.map(row => row.path), modelData.id)
						}
					}

					Chip {
						height: 28
						icon: "plus"
						text: "New"
						onClicked: root.view.ask("New tag", "Name of the tag", "", name => {
							const id = FileLibrary.addTag(name);
							if (id) FileLibrary.toggleTag(root.picked.map(row => row.path), id);
						})
					}
				}
			}

			// ── a note stuck to it ─────────────────────────────────────────
			ColumnLayout {
				id: noteBox

				readonly property string saved: {
					FileLibrary.notes;
					return FileLibrary.noteOf(root.path);
				}

				Layout.fillWidth: true
				visible: root.path !== "" && root.picked.length <= 1
				spacing: 8

				SectionLabel {
					text: "Note"
				}

				AreaField {
					id: noteField

					property string forPath: ""

					Layout.fillWidth: true
					Layout.preferredHeight: Math.max(64, Math.min(180, area.contentHeight + 28))
					placeholder: root.entry?.dir ? "What is this folder for? Shown on its card." : "A note for this file – shown on its card."
					onEdited: noteSave.restart()
					onFocusedChanged: if (!focused) noteSave.save()

					Timer {
						id: noteSave

						function save() {
							if (noteField.forPath !== "" && noteField.text.trim() !== FileLibrary.noteOf(noteField.forPath)) FileLibrary.setNote(noteField.forPath, noteField.text);
						}

						interval: 700
						onTriggered: noteSave.save()
					}
				}

				// another file picked: its note comes in (what was typed for the last one is kept first)
				Connections {
					target: root

					function onPathChanged() {
						noteSave.save();
						noteField.forPath = root.path;
						noteField.text = FileLibrary.noteOf(root.path);
						root.versions = null;
					}
				}

				Component.onCompleted: {
					noteField.forPath = root.path;
					noteField.text = FileLibrary.noteOf(root.path);
				}
			}

			// ── earlier versions ───────────────────────────────────────────
			ColumnLayout {
				Layout.fillWidth: true
				visible: !!root.subject && !root.subject.dir && root.pane?.location.kind !== "trash"
				spacing: 6

				SectionLabel {
					text: "Earlier versions"
				}

				TextButton {
					visible: root.versions === null
					height: 30
					variant: "ghost"
					icon: "history"
					text: root.versionsLoading ? "Looking…" : "Look for earlier versions"
					onClicked: root.loadVersions()
				}

				StyledText {
					Layout.fillWidth: true
					visible: root.versions !== null && root.versions.length === 0
					text: "None found: no snapshots, no git history and nothing of it in the trash."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				Repeater {
					model: root.versions ?? []

					delegate: Rectangle {
						id: version

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 48
						radius: Theme.radius.medium
						color: Qt.alpha(Theme.layer2, versionMouse.containsMouse ? 1 : 0.55)

						Behavior on color {
							ColorAnim {}
						}

						MouseArea {
							id: versionMouse

							anchors.fill: parent
							hoverEnabled: true
							acceptedButtons: Qt.NoButton
						}

						Glyph {
							x: 10
							anchors.verticalCenter: parent.verticalCenter
							icon: ({ git: "source_commit", trash: "trash_can_outline" })[version.modelData.source] ?? "camera_timer"
							size: 16
							color: Theme.textMuted
						}

						Column {
							x: 34
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 34 - versionButtons.width - 8

							StyledText {
								width: parent.width
								text: Files.whenText(version.modelData.when)
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
								elide: Text.ElideRight
							}

							StyledText {
								width: parent.width
								text: `${version.modelData.title}${version.modelData.size !== undefined ? " · " + Files.sizeText(version.modelData.size) : ""}`
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								elide: Text.ElideRight
							}
						}

						Row {
							id: versionButtons

							anchors.right: parent.right
							anchors.rightMargin: 4
							anchors.verticalCenter: parent.verticalCenter
							opacity: versionMouse.containsMouse ? 1 : 0.6

							// a copy beside it
							IconButton {
								width: 28
								height: 28
								iconSize: 15
								icon: "content_copy"
								onClicked: Files.restoreVersion(root.path, version.modelData.id, "beside")
							}

							// in its place
							IconButton {
								width: 28
								height: 28
								iconSize: 15
								icon: "restore"
								onClicked: Files.confirmRequested({
									title: "Put this version in its place?",
									detail: "The file as it is now goes to the trash, so this can be undone.",
									confirm: "Bring it back",
									danger: false,
									run: () => Files.restoreVersion(root.path, version.modelData.id, "replace")
								})
							}
						}
					}
				}
			}
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: !root.entry && root.picked.length === 0
		icon: "information_outline"
		title: "Nothing picked"
		subtitle: "Pick a file to see what it is."
	}
}
