pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// "Open with" for every app (the portal's AppChooser, scripts/files/portal.py):
// the programs the file's type knows, the one used last first, a search over
// all of them, and "always" to make the pick the type's default.
FloatingWindow {
	id: root

	readonly property var entry: Files.appChoosing
	readonly property string fileName: {
		const e = root.entry;
		if (!e) return "";
		if (e.filename) return Files.nameOf(e.filename);
		if (e.uri) return decodeURIComponent(e.uri.split("/").pop() || e.uri);
		return "";
	}
	property bool always: false
	property int current: 0

	// the offered programs: [{ id, name, icon, detail }]
	readonly property var apps: {
		const e = root.entry;
		if (!e) return [];
		const query = search.text.trim().toLowerCase();
		const offered = (e.choices ?? []).map(id => String(id).replace(/\.desktop$/, ""));
		if (e.lastChoice && !offered.includes(e.lastChoice.replace(/\.desktop$/, ""))) offered.unshift(e.lastChoice.replace(/\.desktop$/, ""));
		const last = e.lastChoice.replace(/\.desktop$/, "");
		const known = offered.map(id => ({ id: id, app: DesktopEntries.heuristicLookup(id) })).filter(each => each.app);
		known.sort((a, b) => (b.id === last) - (a.id === last));
		let out = known.map(each => ({ id: each.id, name: String(each.app.name), icon: String(each.app.icon || ""), detail: each.id === last ? "Used last time" : String(each.app.genericName || each.app.comment || ""), offered: true }));
		if (query !== "") {
			out = out.filter(each => `${each.name} ${each.id}`.toLowerCase().includes(query));
			const more = DesktopEntries.applications.values
				.filter(app => !app.noDisplay && !offered.includes(String(app.id).replace(/\.desktop$/, "")) && `${app.name} ${app.id} ${app.genericName ?? ""}`.toLowerCase().includes(query))
				.slice(0, 30)
				.map(app => ({ id: String(app.id).replace(/\.desktop$/, ""), name: String(app.name), icon: String(app.icon || ""), detail: "Not one the file's type names", offered: false }));
			out = out.concat(more);
		}
		return out;
	}

	title: "Open with"
	visible: root.entry !== null
	implicitWidth: 520
	implicitHeight: 620
	minimumSize: Qt.size(420, 420)
	color: Theme.base

	onEntryChanged: {
		search.text = "";
		root.current = 0;
		root.always = false;
		if (root.entry) Qt.callLater(() => search.focusInput());
	}

	onVisibleChanged: {
		// closed with the compositor's own means: nothing was chosen
		if (!root.visible && root.entry) Files.finishChoose(root.entry, { response: 1 });
		if (root.visible) Sounds.play("open");
	}

	function choose(app) {
		const e = root.entry;
		if (!e || !app) return;
		if (root.always && e.contentType !== "") {
			Quickshell.execDetached(["xdg-mime", "default", `${app.id}.desktop`, e.contentType]);
			Files.say(`${app.name} opens ${e.contentType} from now on`, "check");
		}
		Sounds.play("confirm");
		Files.finishChoose(e, { response: 0, choice: app.id });
	}

	Rectangle {
		anchors.fill: parent
		color: Theme.base

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 16
			spacing: 12

			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				Rectangle {
					Layout.preferredWidth: 44
					Layout.preferredHeight: 44
					radius: Theme.radius.medium
					color: Theme.primaryContainer

					Glyph {
						anchors.centerIn: parent
						icon: "open_in_app"
						color: Theme.primary
						size: 22
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: root.fileName !== "" ? `Open ${root.fileName} with` : "Open with"
						font.pixelSize: Theme.size.title
						font.weight: Font.DemiBold
						elide: Text.ElideMiddle
					}

					StyledText {
						Layout.fillWidth: true
						visible: text !== ""
						text: [root.entry?.contentType ?? "", root.entry?.appName ? `${root.entry.appName} asks` : ""].filter(part => part !== "").join(" · ")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}
			}

			Field {
				id: search

				Layout.fillWidth: true
				icon: "magnify"
				placeholder: "Search every program"
				onAccepted: root.choose(root.apps[root.current])
				onEscapePressed: if (root.entry) Files.finishChoose(root.entry, { response: 1 })
				onDownPressed: root.current = Math.min(root.apps.length - 1, root.current + 1)
				onUpPressed: root.current = Math.max(0, root.current - 1)
				onEdited: root.current = 0
			}

			ListView {
				id: list

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				spacing: 4
				model: root.apps
				currentIndex: root.current
				onCurrentIndexChanged: list.positionViewAtIndex(root.current, ListView.Contain)

				delegate: Clickable {
					id: row

					required property var modelData
					required property int index

					width: list.width
					height: 56
					radius: Theme.radius.medium
					color: row.index === root.current ? Theme.layer2 : "transparent"
					onClicked: root.choose(row.modelData)
					onEntered: root.current = row.index

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 12
						anchors.rightMargin: 12
						spacing: 12

						Image {
							id: appIcon

							Layout.preferredWidth: 32
							Layout.preferredHeight: 32
							source: row.modelData.icon !== "" ? Quickshell.iconPath(row.modelData.icon, true) : ""
							sourceSize: Qt.size(64, 64)
							asynchronous: true
							visible: status === Image.Ready
						}

						Glyph {
							Layout.preferredWidth: 32
							visible: !appIcon.visible
							icon: "application_outline"
							size: 24
							color: Theme.textMuted
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: row.modelData.name
								font.weight: Font.DemiBold
								elide: Text.ElideRight
							}

							StyledText {
								Layout.fillWidth: true
								visible: text !== ""
								text: row.modelData.detail
								tone: row.modelData.offered ? Theme.textMuted : Theme.warning
								font.pixelSize: Theme.size.small
								elide: Text.ElideRight
							}
						}
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.apps.length === 0
					icon: "application_outline"
					title: search.text === "" ? "No program names this type" : "Nothing found"
					subtitle: search.text === "" ? "Search every program above" : ""
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Toggle {
					visible: (root.entry?.contentType ?? "") !== ""
					checked: root.always
					onToggled: on => root.always = on
				}

				StyledText {
					visible: (root.entry?.contentType ?? "") !== ""
					Layout.fillWidth: true
					text: "Always open this type with it"
					font.pixelSize: Theme.size.small
				}

				Item {
					visible: (root.entry?.contentType ?? "") === ""
					Layout.fillWidth: true
				}

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: if (root.entry) Files.finishChoose(root.entry, { response: 1 })
				}

				TextButton {
					text: "Open"
					variant: "filled"
					enabled: root.apps.length > 0
					onActivated: root.choose(root.apps[root.current])
				}
			}
		}
	}
}
