pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds
import "Treemap.js" as Treemap

// What takes the space of a folder or a drive: a map of boxes as big as
// what they hold, a click goes into a folder, the biggest things listed
// beside it, and – for the home or a whole drive – what could go.
Item {
	id: root

	required property var pane
	required property var shell

	readonly property string scanRoot: String(root.pane.location.path || Files.home)
	readonly property string at: String(root.pane.location.at || root.scanRoot)
	readonly property bool running: !!Files.storageRunning[root.scanRoot]
	readonly property var job: Files.activeJobs.find(job => job.kind === "storage") ?? null
	property var tree: null
	property var cleanup: []
	property bool cleanupLoading: false
	property int hovered: -1

	function load() {
		Files.storageTree(root.scanRoot, root.at, tree => {
			root.tree = tree;
			if (!tree && !root.running && !Files.storageScanned[root.scanRoot]) Files.measureStorage(root.scanRoot);
		});
	}

	function loadCleanup() {
		if (root.at !== Files.home && root.at !== "/" && root.scanRoot !== root.at) return;
		root.cleanupLoading = true;
		Files.request("cleanup", {}, data => {
			root.cleanup = data?.items ?? [];
			root.cleanupLoading = false;
		});
	}

	Component.onCompleted: {
		root.load();
		if (root.scanRoot === Files.home || root.scanRoot === "/") root.loadCleanup();
	}
	onAtChanged: root.load()

	Connections {
		target: Files

		function onStorageScannedChanged() {
			root.load();
		}
		function onJobFinished(job) {
			if (["trash", "delete", "emptytrash", "move"].includes(job.kind) && job.state === "done") {
				refresh.restart();
			}
		}
	}

	// after something was thrown away, the scan is made again (it is quick the second time)
	Timer {
		id: refresh

		interval: 600
		onTriggered: {
			Files.measureStorage(root.scanRoot);
			if (root.cleanup.length > 0) root.loadCleanup();
		}
	}

	function go(path) {
		root.pane.go({ kind: "storage", path: root.scanRoot, at: path });
	}

	function guessMime(name) {
		const ext = String(name).toLowerCase().split(".").pop();
		if (["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "avif", "svg", "tif", "tiff", "raw", "dng"].includes(ext)) return "image/x";
		if (["mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "mpg", "ts"].includes(ext)) return "video/x";
		if (["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac"].includes(ext)) return "audio/x";
		if (ext === "pdf") return "application/pdf";
		return "";
	}

	function colorOf(node) {
		if (node.others) return Theme.textFaint;
		const role = Kinds.toneOf({ name: node.name, dir: node.dir, mime: root.guessMime(node.name) });
		return FileLibrary.colorOf(role === "textMuted" ? "text" : role);
	}

	readonly property var tiles: {
		if (!root.tree?.children) return [];
		return Treemap.layout(root.tree.children.map((child, index) => Object.assign({}, child, { index: index })), 0, 0, map.width, map.height);
	}

	// ── the head ───────────────────────────────────────────────────────────
	RowLayout {
		id: head

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.leftMargin: 18
		anchors.rightMargin: 14
		height: 54
		spacing: 10

		IconButton {
			visible: root.at !== root.scanRoot
			width: 32
			height: 32
			icon: "arrow_up"
			iconSize: 17
			onClicked: root.go(Files.parentOf(root.at))
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: root.tree ? `${Format.bytes(root.tree.size)} in ${Files.pretty(root.at)}` : (root.running ? "Measuring…" : "Not measured yet")
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
				elide: Text.ElideMiddle
			}

			StyledText {
				Layout.fillWidth: true
				text: {
					if (root.running) return root.job?.current ? `${root.job.files.toLocaleString()} files so far · ${root.job.current}` : "Reading every folder";
					if (!root.tree) return "";
					const disk = root.tree.disk;
					const parts = [`${Number(root.tree.files).toLocaleString()} files`];
					if (disk?.total) parts.push(`${Format.bytes(disk.free)} of ${Format.bytes(disk.total)} free on the drive`);
					if (root.tree.scanned) parts.push(`measured ${Files.whenText(root.tree.scanned).toLowerCase()}`);
					return parts.join(" · ");
				}
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}
		}

		Spinner {
			visible: root.running
			width: 16
			height: 16
		}

		TextButton {
			text: root.running ? "Stop" : "Measure again"
			icon: root.running ? "close" : "refresh"
			variant: "tonal"
			height: 32
			onClicked: {
				if (root.running && root.job) Files.cancel(root.job.id);
				else Files.measureStorage(root.scanRoot);
			}
		}
	}

	// the drive: used and free
	Rectangle {
		id: diskBar

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: head.bottom
		anchors.leftMargin: 18
		anchors.rightMargin: 18
		height: root.tree?.disk?.total ? 8 : 0
		radius: 4
		color: Theme.layer2
		visible: height > 0

		Rectangle {
			width: parent.width * (1 - (root.tree?.disk?.free ?? 0) / Math.max(1, root.tree?.disk?.total ?? 1))
			height: parent.height
			radius: 4
			color: Theme.primary
			opacity: 0.45
		}

		Rectangle {
			width: parent.width * (root.tree?.size ?? 0) / Math.max(1, root.tree?.disk?.total ?? 1)
			height: parent.height
			radius: 4
			color: Theme.primary
		}
	}

	// ── the map ────────────────────────────────────────────────────────────
	Item {
		id: map

		anchors.left: parent.left
		anchors.top: diskBar.bottom
		anchors.topMargin: 12
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 12
		anchors.leftMargin: 18
		width: Math.max(200, root.width - side.width - 54)

		Repeater {
			model: root.tiles

			delegate: Item {
				id: tile

				required property var modelData
				required property int index
				readonly property bool big: tile.width > 70 && tile.height > 42
				readonly property bool lit: root.hovered === tile.index
				readonly property color tone: root.colorOf(tile.modelData)

				x: tile.modelData.x
				y: tile.modelData.y
				width: tile.modelData.w
				height: tile.modelData.h
				opacity: 0
				scale: 0.94

				Component.onCompleted: appear.start()

				ParallelAnimation {
					id: appear

					NumberAnimation {
						target: tile
						property: "opacity"
						to: 1
						duration: Motion.medium
					}
					NumberAnimation {
						target: tile
						property: "scale"
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: 2
					radius: Math.min(Theme.radius.large, Math.min(width, height) / 3)
					color: Qt.tint(Theme.layer1, Qt.alpha(tile.tone, tile.lit ? 0.3 : (tile.modelData.dir ? 0.16 : 0.22)))
					border.width: tile.lit ? 1.5 : 0
					border.color: tile.tone
					clip: true

					Behavior on color {
						ColorAnim {}
					}

					// what is inside a folder, faintly
					Repeater {
						model: tile.modelData.dir && tile.big && tile.height > 80 ? Treemap.layout(tile.modelData.children ?? [], 6, 40, tile.width - 16, tile.height - 46) : []

						delegate: Rectangle {
							id: inner

							required property var modelData

							x: inner.modelData.x
							y: inner.modelData.y
							width: Math.max(0, inner.modelData.w - 3)
							height: Math.max(0, inner.modelData.h - 3)
							radius: Math.min(8, Math.min(width, height) / 3)
							color: Qt.tint(Theme.layer2, Qt.alpha(root.colorOf(inner.modelData), 0.3))

							Text {
								visible: inner.width > 54 && inner.height > 22
								x: 6
								y: 4
								width: parent.width - 12
								text: inner.modelData.name
								color: Theme.textMuted
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.tiny
								elide: Text.ElideMiddle
							}
						}
					}

					StyledText {
						visible: tile.big
						x: 9
						y: 6
						width: parent.width - 18
						text: tile.modelData.name
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
						elide: Text.ElideMiddle
					}

					StyledText {
						visible: tile.big && tile.height > 58
						x: 9
						y: 22
						width: parent.width - 18
						text: Format.bytes(tile.modelData.size)
						tone: Theme.textMuted
						font.pixelSize: Theme.size.tiny
					}
				}

				MouseArea {
					anchors.fill: parent
					hoverEnabled: true
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					cursorShape: tile.modelData.dir ? Qt.PointingHandCursor : Qt.ArrowCursor
					onEntered: root.hovered = tile.index
					onExited: if (root.hovered === tile.index) root.hovered = -1
					onClicked: mouse => {
						if (mouse.button === Qt.RightButton) {
							root.menuFor(tile.modelData, tile, mouse.x, mouse.y);
							return;
						}
						if (tile.modelData.dir) {
							Sounds.play("select");
							root.go(tile.modelData.path);
						}
					}
					onDoubleClicked: if (!tile.modelData.dir && tile.modelData.path) Files.reveal([tile.modelData.path])
				}
			}
		}

		// the one under the pointer, in words
		Rectangle {
			readonly property var node: root.hovered >= 0 ? root.tiles[root.hovered] ?? null : null

			visible: !!node && !(node.w > 70 && node.h > 58)
			x: Math.min(map.width - width, Math.max(0, (node?.x ?? 0) + (node?.w ?? 0) / 2 - width / 2))
			y: Math.max(0, (node?.y ?? 0) - height - 4)
			width: tip.implicitWidth + 18
			height: 26
			radius: 13
			color: Theme.layer3
			z: 5

			StyledText {
				id: tip

				anchors.centerIn: parent
				text: parent.node ? `${parent.node.name} · ${Format.bytes(parent.node.size)}` : ""
				font.pixelSize: Theme.size.small
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: !root.tree && !root.running
			icon: "chart_donut"
			title: "Not measured yet"
			subtitle: "Measure to see what takes the space"
		}

		Spinner {
			anchors.centerIn: parent
			visible: !root.tree && root.running
			width: 26
			height: 26
		}
	}

	function menuFor(node, item, x, y) {
		const at = item.mapToItem(root.shell, x, y);
		const entries = [];
		if (node.others) return;
		if (node.dir) {
			entries.push({ label: "Look inside", icon: "magnify_plus_outline", run: () => root.go(node.path) });
			entries.push({ label: "Open the folder", icon: "folder_open_outline", run: () => root.pane.openFolder(node.path) });
			entries.push({ label: "Find copies in it", icon: "content_duplicate", run: () => root.pane.go({ kind: "duplicates", path: node.path }) });
		} else {
			entries.push({ label: "Show in its folder", icon: "folder_search_outline", run: () => Files.reveal([node.path]) });
		}
		entries.push({ separator: true });
		entries.push({ label: "Move to the trash", icon: "trash_can_outline", danger: true, run: () => Files.trash([node.path]) });
		root.shell.menuFromSidebar(entries, at.x, at.y);
	}

	// ── beside the map: the biggest, and what could go ─────────────────────
	Flickable {
		id: side

		anchors.right: parent.right
		anchors.top: diskBar.bottom
		anchors.topMargin: 12
		anchors.bottom: parent.bottom
		anchors.rightMargin: 14
		width: root.width > 900 ? 300 : 0
		visible: width > 0
		contentHeight: sideColumn.implicitHeight
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: sideColumn

			width: side.width
			spacing: 6

			// what could go: big old downloads, the trash, thumbnails, caches
			StyledText {
				visible: root.cleanup.length > 0
				text: "Could go"
				font.weight: Font.DemiBold
			}

			Repeater {
				model: root.cleanup

				delegate: Rectangle {
					id: suggestion

					required property var modelData

					Layout.fillWidth: true
					implicitHeight: suggestionColumn.implicitHeight + 20
					radius: Theme.radius.large
					color: Theme.layer2

					ColumnLayout {
						id: suggestionColumn

						x: 12
						y: 10
						width: parent.width - 24
						spacing: 4

						RowLayout {
							Layout.fillWidth: true

							StyledText {
								Layout.fillWidth: true
								text: suggestion.modelData.title
								font.weight: Font.DemiBold
							}

							StyledText {
								text: Format.bytes(suggestion.modelData.size)
								tone: Theme.primary
								font.weight: Font.DemiBold
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: suggestion.modelData.detail
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							wrapMode: Text.WordWrap
						}

						TextButton {
							Layout.alignment: Qt.AlignRight
							height: 28
							variant: suggestion.modelData.action === "emptytrash" ? "danger" : "tonal"
							text: ({ trash: "Look at them", emptytrash: "Empty the trash", thumbcache: "Clear them", show: "Show them" })[suggestion.modelData.action] ?? "Show"
							onClicked: {
								const item = suggestion.modelData;
								if (item.action === "emptytrash") Files.emptyTrash();
								else if (item.action === "thumbcache") Files.request("thumbcache", { clear: true }, () => root.loadCleanup());
								else if (item.action === "trash") root.pane.go({ kind: "search", path: Files.parentOf(item.paths[0].path).split("/").slice(0, 4).join("/"), query: "size>50MB older:60d" });
								else if (item.action === "show") root.pane.go({ kind: "storage", path: Files.parentOf(item.paths[0].path), at: Files.parentOf(item.paths[0].path) });
							}
						}
					}
				}
			}

			Item {
				visible: root.cleanup.length > 0
				Layout.preferredHeight: 8
			}

			StyledText {
				visible: (root.tree?.children ?? []).length > 0
				text: "Biggest here"
				font.weight: Font.DemiBold
			}

			Repeater {
				model: (root.tree?.children ?? []).filter(child => !child.others).slice(0, 14)

				delegate: Item {
					id: biggest

					required property var modelData
					required property int index

					Layout.fillWidth: true
					implicitHeight: 40

					Rectangle {
						anchors.fill: parent
						radius: Theme.radius.medium
						color: Qt.alpha(Theme.layer2, biggestMouse.containsMouse ? 1 : 0)

						Behavior on color {
							ColorAnim {}
						}
					}

					Glyph {
						x: 8
						anchors.verticalCenter: parent.verticalCenter
						icon: Kinds.glyphOf({ name: biggest.modelData.name, dir: biggest.modelData.dir, mime: root.guessMime(biggest.modelData.name) })
						size: 17
						color: root.colorOf(biggest.modelData)
					}

					StyledText {
						x: 34
						y: 4
						width: parent.width - 110
						text: biggest.modelData.name
						font.pixelSize: Theme.size.small
						elide: Text.ElideMiddle
					}

					Rectangle {
						x: 34
						y: 26
						width: (parent.width - 110) * biggest.modelData.size / Math.max(1, root.tree?.size ?? 1)
						height: 4
						radius: 2
						color: root.colorOf(biggest.modelData)
					}

					StyledText {
						anchors.right: parent.right
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						text: Format.bytes(biggest.modelData.size)
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					MouseArea {
						id: biggestMouse

						anchors.fill: parent
						hoverEnabled: true
						acceptedButtons: Qt.LeftButton | Qt.RightButton
						onEntered: root.hovered = root.tiles.findIndex(tile => tile.path === biggest.modelData.path)
						onExited: root.hovered = -1
						onClicked: mouse => {
							if (mouse.button === Qt.RightButton) root.menuFor(biggest.modelData, biggest, mouse.x, mouse.y);
							else if (biggest.modelData.dir) root.go(biggest.modelData.path);
							else Files.reveal([biggest.modelData.path]);
						}
					}
				}
			}
		}
	}
}
