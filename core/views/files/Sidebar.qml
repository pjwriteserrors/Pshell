pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The places: home and recent, the folders everyone has, favourites, the
// shelves of the desktop, tags, collections, drives and the network, the
// trash at the bottom. Every one takes files dropped on it.
Rectangle {
	id: root

	required property var view
	property var pane: null

	readonly property var loc: root.pane?.location ?? ({ kind: "home" })
	readonly property var standard: ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music"].map(name => `${Files.home}/${name}`)
	property var existing: []

	radius: Theme.radius.huge
	color: Theme.layer1
	clip: true

	Component.onCompleted: Files.request("describe", { paths: root.standard }, data => root.existing = (data?.entries ?? []).filter(entry => entry.dir).map(entry => entry.path))

	function isAt(kind, value) {
		if (root.loc.kind !== kind) return false;
		if (kind === "dir") return root.loc.path === value;
		if (kind === "tag" || kind === "collection" || kind === "shelf") return root.loc.id === value;
		return true;
	}

	function go(location) {
		root.pane?.go(location);
		root.view.takeFocus();
	}

	function glyphFor(path) {
		switch (Files.nameOf(path)) {
		case "Desktop": return "monitor";
		case "Documents": return "file_document_outline";
		case "Downloads": return "download";
		case "Pictures": return "image_outline";
		case "Videos": return "filmstrip";
		case "Music": return "music_note";
		default: return "folder_outline";
		}
	}

	function menuAt(item, x, y, entries) {
		const at = item.mapToItem(root.view, x, y);
		root.view.menuFromSidebar(entries, at.x, at.y);
	}

	// ── title ──────────────────────────────────────────────────────────────
	Item {
		id: head

		x: 14
		y: 12
		width: parent.width - 28
		height: 40

		Rectangle {
			id: mark

			anchors.verticalCenter: parent.verticalCenter
			width: 32
			height: 32
			radius: 11
			color: Theme.primary

			Glyph {
				anchors.centerIn: parent
				icon: "folder_open"
				size: 18
				color: Theme.onPrimary
				surface: Theme.primary
			}
		}

		Text {
			anchors.left: mark.right
			anchors.leftMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			text: "Files"
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}

		IconButton {
			id: hide

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			width: 30
			height: 30
			iconSize: 16
			icon: "dock_left"
			onClicked: FileLibrary.setView("", { sidebar: false })
		}

		IconButton {
			anchors.right: hide.left
			anchors.verticalCenter: parent.verticalCenter
			width: 30
			height: 30
			iconSize: 16
			icon: "cog_outline"
			onClicked: root.view.openSettings("")
		}
	}

	Flickable {
		id: flick

		anchors.top: head.bottom
		anchors.topMargin: 8
		anchors.bottom: trash.top
		anchors.bottomMargin: 6
		x: 8
		width: parent.width - 16
		contentHeight: sections.implicitHeight + 10
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: sections

			width: flick.width
			spacing: 14

			Column {
				width: parent.width
				spacing: 1

				SideItem {
					width: parent.width
					icon: "home_variant_outline"
					label: "Home"
					active: root.isAt("home")
					onClicked: root.go({ kind: "home" })
				}

				SideItem {
					width: parent.width
					icon: "history"
					label: "Recent"
					active: root.isAt("recent")
					onClicked: root.go({ kind: "recent" })
				}
			}

			SideSection {
				width: parent.width
				title: "Places"

				SideItem {
					width: parent.width
					icon: "home_outline"
					label: Files.nameOf(Files.home)
					active: root.isAt("dir", Files.home)
					dropEnabled: true
					onClicked: root.go({ kind: "dir", path: Files.home })
					onDropped: drop => Files.dropInto(Files.home, drop, "auto")
				}

				Repeater {
					model: root.existing

					delegate: SideItem {
						id: placeItem

						required property string modelData

						width: parent.width
						icon: root.glyphFor(modelData)
						label: Files.nameOf(modelData)
						active: root.isAt("dir", modelData)
						dropEnabled: true
						onClicked: root.go({ kind: "dir", path: modelData })
						onDropped: drop => Files.dropInto(modelData, drop, "auto")
						onMenu: (x, y) => root.menuAt(placeItem, x, y, [
							{ label: "Open in a new tab", icon: "tab_plus", run: () => root.view.newTab({ kind: "dir", path: placeItem.modelData }, true) },
							{ label: "Open a terminal here", icon: "console", run: () => Files.terminal(placeItem.modelData) }
						])
					}
				}
			}

			// folders dropped on the section (not on one of its folders) become favourites
			SideSection {
				width: parent.width
				title: "Favorites"
				dropEnabled: true
				onDropped: drop => root.addFavorites(drop)

				Repeater {
					model: FileLibrary.favorites

					delegate: SideItem {
						id: favoriteItem

						required property string modelData
						required property int index

						width: parent.width
						icon: "star_outline"
						iconColor: Theme.warning
						label: Files.nameOf(modelData)
						active: root.isAt("dir", modelData)
						dropEnabled: true
						onClicked: root.go({ kind: "dir", path: modelData })
						onDropped: drop => Files.dropInto(modelData, drop, "auto")
						onMenu: (x, y) => root.menuAt(favoriteItem, x, y, [
							{ label: "Open in a new tab", icon: "tab_plus", run: () => root.view.newTab({ kind: "dir", path: favoriteItem.modelData }, true) },
							{ label: "Move up", icon: "arrow_up", enabled: index > 0, run: () => FileLibrary.moveFavorite(index, index - 1) },
							{ label: "Move down", icon: "arrow_down", enabled: index < FileLibrary.favorites.length - 1, run: () => FileLibrary.moveFavorite(index, index + 1) },
							{ separator: true },
							{ label: "Remove from favorites", icon: "star_off_outline", run: () => FileLibrary.toggleFavorite(modelData) }
						])
					}
				}

				Text {
					visible: FileLibrary.favorites.length === 0
					x: 12
					width: parent.width - 24
					height: implicitHeight + 6
					text: "Drop folders here to keep them at hand."
					color: Theme.textFaint
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			SideSection {
				width: parent.width
				title: "Shelves"
				visible: Plugins.on("shelves") && Shelf.shelves.length > 0

				Repeater {
					model: Plugins.on("shelves") ? Shelf.shelves : []

					delegate: SideItem {
						required property var modelData

						width: parent.width
						icon: "tray_arrow_down"
						label: Shelf.titleOf(modelData)
						detail: String((modelData.items ?? []).length)
						active: root.isAt("shelf", modelData.id)
						dropEnabled: true
						onClicked: root.go({ kind: "shelf", id: modelData.id })
						onDropped: drop => {
							Shelf.addDrop(modelData.id, drop);
							Sounds.play("pinned");
						}
					}
				}
			}

			SideSection {
				width: parent.width
				title: "Tags"
				action: "plus"
				onActionClicked: root.view.ask("New tag", "Name of the tag", "", name => FileLibrary.addTag(name))

				Repeater {
					model: FileLibrary.tags

					delegate: SideItem {
						id: tagItem

						required property var modelData

						width: parent.width
						icon: "circle"
						iconColor: FileLibrary.colorOf(modelData.color)
						label: modelData.name
						detail: {
							const count = FileLibrary.countOf(modelData.id);
							return count > 0 ? String(count) : "";
						}
						active: root.isAt("tag", modelData.id)
						dropEnabled: true
						onClicked: root.go({ kind: "tag", id: modelData.id })
						onDropped: drop => {
							const paths = (drop.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
							if (paths.length > 0 && !paths.every(path => FileLibrary.hasTag(path, modelData.id))) FileLibrary.toggleTag(paths, modelData.id);
						}
						onMenu: (x, y) => root.menuAt(tagItem, x, y, [
							{ label: "Rename…", icon: "form_textbox", run: () => root.view.ask("Rename the tag", "Name", modelData.name, name => FileLibrary.renameTag(modelData.id, name)) },
							{ label: "Colour", icon: "palette_outline", children: FileLibrary.tagColors.map(color => ({ label: color.charAt(0).toUpperCase() + color.slice(1), icon: "circle", checked: modelData.color === color, run: () => FileLibrary.recolorTag(modelData.id, color) })) },
							{ separator: true },
							{ label: "Delete the tag", icon: "delete_outline", danger: true, run: () => FileLibrary.removeTag(modelData.id) }
						])
					}
				}
			}

			SideSection {
				width: parent.width
				title: "Collections"
				action: "plus"
				// files dropped beside the collections start a new one
				dropEnabled: true
				onDropped: drop => {
					const paths = root.pathsOf(drop);
					if (paths.length === 0) return;
					root.view.ask("New collection", "Name of the collection", "", name => {
						FileLibrary.newCollection(name, paths);
						Sounds.play("pinned");
					});
				}
				onActionClicked: root.view.ask("New collection", "Name of the collection", "", name => {
					const id = FileLibrary.newCollection(name, []);
					root.go({ kind: "collection", id: id });
				})

				Repeater {
					model: FileLibrary.collections

					delegate: SideItem {
						id: collectionItem

						required property var modelData

						width: parent.width
						icon: "bookmark_box_multiple_outline"
						label: modelData.name
						detail: modelData.paths.length > 0 ? String(modelData.paths.length) : ""
						active: root.isAt("collection", modelData.id)
						dropEnabled: true
						onClicked: root.go({ kind: "collection", id: modelData.id })
						onDropped: drop => {
							const paths = (drop.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
							if (paths.length > 0) FileLibrary.addToCollection(modelData.id, paths);
						}
						onMenu: (x, y) => root.menuAt(collectionItem, x, y, [
							{ label: "Rename…", icon: "form_textbox", run: () => root.view.ask("Rename the collection", "Name", modelData.name, name => FileLibrary.renameCollection(modelData.id, name)) },
							{ label: "Delete the collection", icon: "delete_outline", danger: true, run: () => FileLibrary.removeCollection(modelData.id) }
						])
					}
				}

				Text {
					visible: FileLibrary.collections.length === 0
					x: 12
					width: parent.width - 24
					text: "Gather files from anywhere without moving them."
					color: Theme.textFaint
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			SideSection {
				width: parent.width
				title: "Drives"
				visible: Files.drives.length > 0

				Repeater {
					model: Files.drives

					delegate: SideItem {
						id: drive

						required property var modelData
						property bool mounting: false

						width: parent.width
						icon: ({ system: "harddisk", removable: "usb_flash_drive_outline", phone: "cellphone", drive: "harddisk" })[modelData.kind] ?? "harddisk"
						label: modelData.name
						fill: modelData.total > 0 ? 1 - modelData.free / modelData.total : -1
						active: modelData.path !== "" && root.isAt("dir", modelData.path)
						opacity: modelData.mounted ? 1 : 0.65
						dropEnabled: modelData.mounted && modelData.path !== ""
						busy: drive.mounting
						trailing: modelData.canEject || modelData.canUnmount ? "eject" : ""
						onTrailingClicked: Files.unmount(modelData, !!modelData.canEject)
						onClicked: {
							if (!modelData.mounted) drive.mounting = true;
							root.view.openPlace(root.pane, modelData);
						}
						onDropped: drop => Files.dropInto(modelData.path, drop, "auto")

						Connections {
							target: Files

							function onPlacesChanged() {
								drive.mounting = false;
							}
						}
					}
				}
			}

			SideSection {
				width: parent.width
				title: "Network"
				visible: Files.network.length > 0 || (Plugins.on("ssh") && Ssh.recent.length > 0)

				Repeater {
					model: Files.network

					delegate: SideItem {
						required property var modelData

						width: parent.width
						icon: "server_network"
						label: modelData.name
						active: modelData.path !== "" && root.isAt("dir", modelData.path)
						dropEnabled: modelData.path !== ""
						trailing: "eject"
						onTrailingClicked: Files.unmount(modelData, false)
						onClicked: root.view.openPlace(root.pane, modelData)
						onDropped: drop => Files.dropInto(modelData.path, drop, "auto")
					}
				}

				// the hosts of the SSH plugin that are not mounted yet
				Repeater {
					model: Plugins.on("ssh") ? Ssh.recent.slice(0, 6).filter(entry => !Files.network.some(place => place.uri.startsWith(Files.hostUri(entry)))) : []

					delegate: SideItem {
						id: host

						required property var modelData
						property bool mounting: false

						width: parent.width
						icon: "console_network_outline"
						label: String(modelData.display_name || modelData.host || modelData.target || "")
						opacity: 0.75
						busy: host.mounting
						onClicked: {
							host.mounting = true;
							root.view.openPlace(root.pane, { mounted: false, name: host.label, uri: Files.hostUri(modelData), id: Files.hostUri(modelData) });
							resetTimer.restart();
						}

						Timer {
							id: resetTimer

							interval: 8000
							onTriggered: host.mounting = false
						}

						Connections {
							target: Files

							function onPlacesChanged() {
								host.mounting = false;
							}
						}
					}
				}
			}
		}
	}

	function pathsOf(drop) {
		return (drop.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
	}

	function addFavorites(drop) {
		const dirs = root.pathsOf(drop);
		Files.request("describe", { paths: dirs }, data => {
			for (const entry of data?.entries ?? []) if (entry.dir && !FileLibrary.isFavorite(entry.path)) FileLibrary.toggleFavorite(entry.path);
		});
	}

	SideItem {
		id: trash

		anchors.bottom: parent.bottom
		anchors.bottomMargin: 10
		x: 8
		width: parent.width - 16
		icon: trash.dropping ? "trash_can" : "trash_can_outline"
		label: "Trash"
		active: root.isAt("trash")
		dropEnabled: true
		onClicked: root.go({ kind: "trash" })
		onDropped: drop => {
			const paths = (drop.urls ?? []).map(url => String(url)).filter(url => url.startsWith("file://")).map(url => decodeURIComponent(url.slice(7)));
			Files.trash(paths);
		}
		onMenu: (x, y) => root.menuAt(trash, x, y, [{ label: "Empty the trash", icon: "delete_sweep_outline", danger: true, run: () => Files.emptyTrash() }])
	}
}
