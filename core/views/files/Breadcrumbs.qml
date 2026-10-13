pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Where a pane is, as steps from the home folder (or the root) that grow
// and shrink as one goes in and out. A click on a step goes there, files
// dropped on a step go into it, a click beside the steps (or Ctrl+L) turns
// them into a field to type a path in, with folders offered as you type.
Item {
	id: root

	required property var pane
	property bool editing: false
	readonly property bool virtual: !root.pane.isFolder

	implicitHeight: 34

	// [{ name, path, icon }]
	readonly property var steps: {
		const loc = root.pane.location;
		if (loc.kind !== "dir") {
			const out = [{ name: root.pane.title, path: "", icon: root.pane.icon }];
			if (loc.kind === "search" && loc.path) out.unshift({ name: Files.nameOf(loc.path) || "/", path: loc.path, icon: "folder_outline" });
			return out;
		}
		const path = String(loc.path);
		const home = Files.home;
		const out = [];
		let rest;
		if (path === home || path.startsWith(home + "/")) {
			out.push({ name: "Home", path: home, icon: "home_outline" });
			rest = path.slice(home.length);
			let current = home;
			for (const part of rest.split("/").filter(p => p !== "")) {
				current += "/" + part;
				out.push({ name: part, path: current, icon: "" });
			}
		} else {
			out.push({ name: "", path: "/", icon: "harddisk" });
			let current = "";
			for (const part of path.split("/").filter(p => p !== "")) {
				current += "/" + part;
				out.push({ name: part, path: current, icon: "" });
			}
		}
		return out;
	}

	// the model follows the steps by changes only: steps slide in and out
	ListModel {
		id: stepModel
	}

	onStepsChanged: {
		let same = 0;
		while (same < stepModel.count && same < root.steps.length && stepModel.get(same).path === root.steps[same].path && stepModel.get(same).name === root.steps[same].name) same += 1;
		if (stepModel.count > same) stepModel.remove(same, stepModel.count - same);
		for (let i = same; i < root.steps.length; i += 1) stepModel.append(root.steps[i]);
		Qt.callLater(() => crumbs.positionViewAtEnd());
	}

	function edit() {
		if (root.virtual && root.pane.location.kind !== "search") return;
		root.editing = true;
		field.text = Files.pretty(root.pane.folder) + (root.pane.folder === "/" ? "" : "/");
		field.forceActiveFocus();
		field.cursorPosition = field.text.length;
		root.suggest();
	}

	function finish(go) {
		if (!root.editing) return;
		root.editing = false;
		suggestions.model = [];
		if (!go) return;
		// pasted from elsewhere it may be quoted, or a file:// link
		let path = field.text.trim().replace(/^(["'])(.*)\1$/, "$2");
		if (path.startsWith("file://")) path = decodeURIComponent(path.slice(7));
		if (path.startsWith("~")) path = Files.home + path.slice(1);
		if (!path.startsWith("/")) path = root.pane.folder + "/" + path;
		path = path.replace(/\/+$/, "") || "/";
		root.arrive(path);
	}

	// a folder opens; a file shows in its folder, picked
	function arrive(path) {
		Files.request("describe", { paths: [path] }, data => {
			const entry = data?.entries?.[0];
			if (entry && !entry.dir) root.pane.go({ kind: "dir", path: Files.parentOf(path) }, { select: [path] });
			else root.pane.openFolder(path);
		});
	}

	// folders and files below what is typed
	function suggest() {
		let text = field.text;
		if (text.startsWith("~")) text = Files.home + text.slice(1);
		const slash = text.lastIndexOf("/");
		if (slash < 0) return;
		const folder = text.slice(0, slash) || "/";
		const prefix = text.slice(slash + 1).toLowerCase();
		Files.request("list", { path: folder }, data => {
			if (!root.editing) return;
			const fits = (data?.entries ?? []).filter(entry => (prefix.startsWith(".") || !entry.hidden) && entry.name.toLowerCase().startsWith(prefix))
				.sort((a, b) => (b.dir - a.dir) || (a.key < b.key ? -1 : 1)).slice(0, 8);
			suggestions.model = fits.map(entry => ({ name: entry.name, path: entry.path, dir: !!entry.dir }));
			suggestions.currentIndex = fits.length > 0 ? 0 : -1;
		});
	}

	function complete() {
		const pick = suggestions.model[Math.max(0, suggestions.currentIndex)];
		if (!pick) return;
		field.text = Files.pretty(pick.path) + (pick.dir ? "/" : "");
		field.cursorPosition = field.text.length;
		if (pick.dir) root.suggest();
		else suggestions.model = [];
	}

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.medium
		color: root.editing ? Theme.layer2 : Qt.alpha(Theme.layer1, empty.containsMouse ? 1 : 0)
		border.width: root.editing ? 1.5 : 0
		border.color: Qt.alpha(Theme.primary, 0.8)

		Behavior on color {
			ColorAnim {}
		}
	}

	MouseArea {
		id: empty

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.IBeamCursor
		onClicked: root.edit()
	}

	ListView {
		id: crumbs

		visible: !root.editing
		anchors.fill: parent
		anchors.leftMargin: 2
		orientation: ListView.Horizontal
		interactive: contentWidth > width
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		spacing: 0
		model: stepModel

		add: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.medium
				}
				NumberAnimation {
					property: "scale"
					from: 0.7
					to: 1
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}
		remove: Transition {
			NumberAnimation {
				property: "opacity"
				to: 0
				duration: Motion.short
			}
		}
		displaced: Transition {
			NumberAnimation {
				property: "x"
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		delegate: Item {
			id: step

			required property int index
			required property string name
			required property string path
			required property string icon
			readonly property bool last: step.index === stepModel.count - 1

			width: chevron.width + chip.width
			height: crumbs.height

			Glyph {
				id: chevron

				visible: step.index > 0
				width: step.index > 0 ? 16 : 0
				anchors.verticalCenter: parent.verticalCenter
				icon: "chevron_right"
				size: 15
				color: Theme.textFaint
				animated: false
			}

			Clickable {
				id: chip

				anchors.left: chevron.right
				anchors.verticalCenter: parent.verticalCenter
				height: 28
				width: label.implicitWidth + (step.icon !== "" ? 20 : 0) + (label.text !== "" ? 18 : 12)
				radius: Theme.radius.small
				interactive: step.path !== ""
				color: drop.containsDrag ? Theme.primarySoft : (step.last ? Theme.layer2 : "transparent")
				sound: ""
				onClicked: root.pane.openFolder(step.path)
				onRightClicked: mouse => root.pane.openFolder(step.path)

				Row {
					anchors.centerIn: parent
					spacing: 5

					Glyph {
						visible: step.icon !== ""
						anchors.verticalCenter: parent.verticalCenter
						icon: step.icon
						size: 15
						color: step.last ? Theme.primary : Theme.textMuted
						animated: false
					}

					Text {
						id: label

						anchors.verticalCenter: parent.verticalCenter
						text: step.name
						color: step.last ? Theme.text : Theme.textMuted
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
						font.weight: step.last ? Font.DemiBold : Font.Normal
					}
				}

				DropArea {
					id: drop

					anchors.fill: parent
					enabled: step.path !== "" && !step.last
					onDropped: event => {
						event.acceptProposedAction();
						Files.dropInto(step.path, event, "auto");
					}
				}
			}
		}
	}

	TextInput {
		id: field

		visible: root.editing
		anchors.fill: parent
		anchors.leftMargin: 12
		anchors.rightMargin: 12
		verticalAlignment: TextInput.AlignVCenter
		color: Theme.text
		selectionColor: Qt.alpha(Theme.primary, 0.4)
		font.family: Theme.monoFamily
		font.pixelSize: Theme.size.body
		clip: true
		selectByMouse: true

		onTextEdited: root.suggest()
		onActiveFocusChanged: if (!activeFocus) root.finish(false)
		Keys.onReturnPressed: root.finish(true)
		Keys.onEnterPressed: root.finish(true)
		Keys.onEscapePressed: root.finish(false)
		Keys.onTabPressed: root.complete()
		Keys.onDownPressed: suggestions.currentIndex = Math.min(suggestions.count - 1, suggestions.currentIndex + 1)
		Keys.onUpPressed: suggestions.currentIndex = Math.max(0, suggestions.currentIndex - 1)
	}

	// folders that fit what is typed, under the field
	Rectangle {
		visible: root.editing && suggestions.count > 0
		anchors.top: parent.bottom
		anchors.topMargin: 6
		anchors.left: parent.left
		width: Math.min(parent.width, 420)
		height: suggestions.contentHeight + 12
		radius: Theme.radius.medium
		color: Theme.layer2
		z: 50

		ListView {
			id: suggestions

			anchors.fill: parent
			anchors.margins: 6
			interactive: false
			model: []

			delegate: Rectangle {
				id: option

				required property var modelData
				required property int index

				width: suggestions.width
				height: 30
				radius: Theme.radius.small
				color: option.index === suggestions.currentIndex ? Theme.primarySoft : "transparent"

				Row {
					anchors.verticalCenter: parent.verticalCenter
					x: 8
					spacing: 8

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: option.modelData.dir ? "folder_outline" : "file_outline"
						size: 15
						color: option.modelData.dir ? Theme.primary : Theme.textMuted
						animated: false
					}

					Text {
						anchors.verticalCenter: parent.verticalCenter
						text: option.modelData.name
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
					}
				}

				MouseArea {
					anchors.fill: parent
					onPressed: mouse => {
						mouse.accepted = true;
						root.editing = false;
						suggestions.model = [];
						root.arrive(option.modelData.path);
					}
				}
			}
		}
	}
}
