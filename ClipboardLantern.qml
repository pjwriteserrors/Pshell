pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "components"

// The clipboard as a thread of everything that was ever copied: the search
// is a piece of filament at the top, and every entry hangs from one vertical
// thread below it. Text hangs as one line of ink, an image as a small plane
// that grows when the cursor rests on it. Choosing an entry copies it and
// sends a spark up the thread to the bead before the lantern folds.
Item {
	id: page

	property real reveal: 1
	property bool active: false

	signal closeRequested()
	signal copied()

	property var entries: []
	property string searchText: ""
	property int selectedIndex: 0
	property bool loaded: false
	readonly property var filteredEntries: {
		const query = searchText.trim().toLowerCase();
		if (query === "") return entries;
		return entries.filter(entry => String(entry.preview || "").toLowerCase().includes(query));
	}
	readonly property real threadX: 8

	function shellEscape(value) {
		return String(value).replace(/'/g, `'"'"'`);
	}

	function imageExtension(preview) {
		const text = String(preview || "").toLowerCase();
		if (text.includes(" png ")) return "png";
		if (text.includes(" jpeg ") || text.includes(" jpg ")) return "jpg";
		if (text.includes(" webp ")) return "webp";
		if (text.includes(" gif ")) return "gif";
		return "";
	}

	function refresh() {
		listProcess.running = true;
		Qt.callLater(function() {
			page.selectedIndex = 0;
			search.take();
		});
	}

	function parseEntries(raw) {
		const lines = String(raw || "").split("\n").filter(line => line.trim() !== "");
		const next = [];
		for (const line of lines) {
			const match = line.match(/^(\d+)\s+(.*)$/);
			if (!match) continue;
			const preview = match[2];
			const extension = imageExtension(preview);
			const isImage = preview.startsWith("[[ binary data") && extension !== "";
			next.push({
				id: match[1],
				preview: preview,
				raw: line,
				isImage: isImage,
				extension: extension,
				previewPath: isImage ? `/tmp/qs-cliphist-preview-${match[1]}.${extension}` : ""
			});
		}
		page.entries = next;
		page.loaded = true;
		clampSelectedIndex();
	}

	function clampSelectedIndex() {
		selectedIndex = Math.max(0, Math.min(selectedIndex, filteredEntries.length - 1));
	}

	function moveSelection(delta) {
		if (filteredEntries.length === 0) return;
		selectedIndex = Math.max(0, Math.min(selectedIndex + delta, filteredEntries.length - 1));
		list.positionViewAtIndex(selectedIndex, ListView.Contain);
	}

	function activateSelection() {
		if (filteredEntries.length === 0) return;
		clampSelectedIndex();
		selectEntry(filteredEntries[selectedIndex], selectedIndex);
	}

	function selectEntry(entry, index) {
		if (!entry?.raw) return;
		Quickshell.execDetached([
			"sh", "-lc",
			`printf '%s\n' '${shellEscape(entry.raw)}' | cliphist decode | wl-copy`
		]);
		// The spark leaves the row's knot and climbs the thread to the bead.
		const item = list.itemAtIndex(index);
		const fromY = item ? list.y + item.y - list.contentY + item.height / 2 : list.y;
		travel.launch(fromY);
	}

	function deleteEntry(entry) {
		if (!entry?.raw) return;
		Quickshell.execDetached([
			"sh", "-lc",
			`printf '%s\n' '${shellEscape(entry.raw)}' | cliphist delete`
		]);
		page.entries = page.entries.filter(e => e.raw !== entry.raw);
		clampSelectedIndex();
	}

	function deleteSelection() {
		if (filteredEntries.length === 0) return;
		clampSelectedIndex();
		deleteEntry(filteredEntries[selectedIndex]);
	}

	function wipe() {
		Quickshell.execDetached(["sh", "-lc", "cliphist wipe"]);
		page.entries = [];
		page.selectedIndex = 0;
	}

	onActiveChanged: {
		if (active) {
			refresh();
		} else {
			travel.stop();
			spark.visible = false;
		}
	}

	Process {
		id: listProcess
		command: ["sh", "-lc", "cliphist list"]
		stdout: StdioCollector {
			onStreamFinished: page.parseEntries(text)
		}
	}

	// ------------------------------------------------------------ the search
	Band {
		id: head
		reveal: page.reveal; order: 0
		width: parent.width; height: 34

		FField {
			id: search
			anchors.left: parent.left
			anchors.right: count.left
			anchors.rightMargin: 12
			y: 0
			icon: "/usr/share/icons/Adwaita/symbolic/actions/edit-find-symbolic.svg"
			placeholder: "search the clipboard"
			fontSize: Filament.textMd
			onTextChanged: {
				page.searchText = text;
				page.selectedIndex = 0;
				if (page.filteredEntries.length > 0) list.positionViewAtIndex(0, ListView.Beginning);
			}
			onAccepted: page.activateSelection()
			onEscaped: page.closeRequested()
			Keys.onDownPressed: event => { event.accepted = true; page.moveSelection(1); }
			Keys.onUpPressed: event => { event.accepted = true; page.moveSelection(-1); }
			Keys.onPressed: event => {
				if (event.key === Qt.Key_Delete && (event.modifiers & Qt.ShiftModifier)) { event.accepted = true; page.deleteSelection(); }
				else if (event.key === Qt.Key_PageDown) { event.accepted = true; page.moveSelection(6); }
				else if (event.key === Qt.Key_PageUp) { event.accepted = true; page.moveSelection(-6); }
			}
		}

		Chip {
			id: count
			anchors.right: parent.right
			anchors.verticalCenter: search.verticalCenter
			text: page.searchText.trim() !== "" ? `${page.filteredEntries.length} / ${page.entries.length}` : `${page.entries.length}`
			lit: page.searchText.trim() !== "" && page.filteredEntries.length > 0
		}
	}

	// ------------------------------------------------------------- the empty
	Item {
		anchors.left: parent.left
		anchors.right: parent.right
		y: head.height + 12
		height: list.height
		visible: page.loaded && page.filteredEntries.length === 0
		opacity: Filament.band(page.reveal, 1)

		Wire {
			vertical: true
			x: page.threadX - 1; y: 0; width: 2; height: parent.height * 0.42
			cold: Filament.wireDim
			lit: 0.18; litFrom: 0.82; hot: Filament.charge; animateLit: false
		}
		Spark { x: page.threadX - 4; y: parent.height * 0.42 - 4; size: 7; breathing: true }
		FText {
			x: page.threadX + 16; y: parent.height * 0.42 - 8
			text: page.searchText.trim() !== "" ? "No matches" : "Clipboard is empty"
			tone: "mute"
			font.pixelSize: Filament.textSm
		}
		FText {
			x: page.threadX + 16; y: parent.height * 0.42 + 10
			text: page.searchText.trim() !== "" ? "nothing on the thread says that" : "what you copy will hang here"
			tone: "faint"
			font.pixelSize: Filament.textXs
		}
	}

	// ------------------------------------------------------------ the thread
	ThreadLine {
		x: page.threadX - 1
		y: list.y
		height: list.height
		litY: list.currentItem ? list.currentItem.y - list.contentY + list.currentItem.height / 2 : -1
		litLength: list.currentItem ? Math.min(48, list.currentItem.height) : 24
		visible: page.filteredEntries.length > 0
		opacity: Filament.band(page.reveal, 1)
	}

	ListView {
		id: list
		x: page.threadX
		y: head.height + 12
		width: parent.width - page.threadX
		height: parent.height - y - foot.height - 10
		clip: true
		spacing: 2
		model: page.filteredEntries
		currentIndex: page.filteredEntries.length > 0 ? page.selectedIndex : -1
		boundsBehavior: Flickable.StopAtBounds
		visible: page.filteredEntries.length > 0
		highlightFollowsCurrentItem: false
		keyNavigationEnabled: false

		delegate: ThreadRow {
			id: row
			required property var modelData
			required property int index
			readonly property bool isImage: modelData?.isImage ?? false
			readonly property bool current: index === page.selectedIndex

			width: ListView.view.width
			height: isImage ? 62 : 32
			inset: 16
			selected: current
			opacity: Filament.band(page.reveal, 1 + Math.min(index, 7))
			z: hovered ? 5 : 0

			onEntered: page.selectedIndex = index
			onClicked: page.selectEntry(modelData, index)

			Component.onCompleted: {
				if (isImage) decode.running = true;
			}

			// An image hangs as a small plane; the cursor resting on it lets it grow.
			ClippingRectangle {
				id: plane
				visible: row.isImage
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: 54; height: 54
				radius: Filament.radiusSmall
				color: Filament.well
				transformOrigin: Item.Left
				scale: row.hovered ? 1.8 : 1
				Behavior on scale { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.005 } }

				Image {
					id: preview
					anchors.fill: parent
					source: ""
					fillMode: Image.PreserveAspectCrop
					smooth: true
					mipmap: true
					cache: false
					asynchronous: true
				}
				FIcon {
					anchors.centerIn: parent
					visible: preview.status !== Image.Ready
					name: "/usr/share/icons/Adwaita/symbolic/mimetypes/image-x-generic-symbolic.svg"
					size: 18
					color: Filament.inkFaint
				}
			}

			Process {
				id: decode
				command: [
					"sh", "-lc",
					`printf '%s\n' '${page.shellEscape(row.modelData?.raw ?? "")}' | cliphist decode > '${page.shellEscape(row.modelData?.previewPath ?? "/tmp/qs-cliphist-preview-none")}'`
				]
				onExited: preview.source = `${row.modelData?.previewPath ?? ""}?t=${Date.now()}`
			}

			Column {
				visible: row.isImage
				anchors.left: plane.right
				anchors.leftMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				spacing: 4
				Chip { text: String(row.modelData?.extension ?? "").toUpperCase(); lit: row.current }
				FText {
					text: {
						const m = String(row.modelData?.preview ?? "").match(/binary data\s+(\S+\s+\S+)\s+\S+\s+(\d+x\d+)/);
						return m ? `${m[1]}  ·  ${m[2]}` : "image";
					}
					mono: true
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}

			FText {
				visible: !row.isImage
				anchors.left: parent.left
				anchors.right: remove.left
				anchors.rightMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				text: String(row.modelData?.preview ?? "").replace(/\s+/g, " ")
				font.pixelSize: Filament.textSm
				color: row.current ? Filament.ink : Filament.inkSoft
				Behavior on color { ColorAnimation { duration: Filament.quick } }
			}

			FButton {
				id: remove
				anchors.right: parent.right
				anchors.rightMargin: 4
				anchors.verticalCenter: parent.verticalCenter
				icon: "window-close-symbolic"
				kind: "ghost"
				square: true
				compact: true
				iconSize: 11
				opacity: row.hovered || row.current ? (hovered ? 1 : 0.5) : 0
				Behavior on opacity { NumberAnimation { duration: Filament.quick } }
				onClicked: page.deleteEntry(row.modelData)
			}
		}
	}

	// The spark that carries a chosen entry up the thread to the bead.
	Spark {
		id: spark
		x: page.threadX - size / 2
		size: 9
		visible: false
		intensity: 1
	}

	SequentialAnimation {
		id: travel
		property real fromY: 0
		function launch(y) {
			stop();
			fromY = y;
			start();
		}
		ScriptAction { script: { spark.y = travel.fromY - spark.size / 2; spark.visible = true; } }
		NumberAnimation {
			target: spark; property: "y"; to: -spark.size / 2
			duration: Filament.travelTime(travel.fromY + 40)
			easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeTravel
		}
		ScriptAction { script: { spark.visible = false; page.copied(); page.closeRequested(); } }
	}

	// --------------------------------------------------------------- the foot
	Band {
		id: foot
		reveal: page.reveal; order: 2
		width: parent.width
		anchors.bottom: parent.bottom
		height: 30

		FText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: page.entries.length > 0 ? "Enter copies  ·  ⇧Del removes" : ""
			tone: "faint"
			font.pixelSize: Filament.textXs
		}

		HoldButton {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: "wipe"
			icon: "user-trash-symbolic"
			holdTime: 650
			implicitHeight: 28
			visible: page.entries.length > 0
			onHeld: page.wipe()
		}
	}
}
