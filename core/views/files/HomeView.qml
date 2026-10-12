pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Listing.js" as Listing

// The home page: the places everyone has, what just arrived (downloads that
// still run among them), what was opened lately, favourites, screenshots
// and recordings, the newest pictures, videos and documents, collections and
// drives. A click opens, a right click offers what the files can do.
Item {
	id: root

	required property var pane
	required property var shell

	property var feed: ({})
	property bool loaded: false
	property var recent: []
	readonly property var dirs: root.feed.dirs ?? {}
	readonly property real wide: root.width - 48

	function refresh() {
		Files.request("home", { watch: Shelf.watchDirs }, (data, error) => {
			if (error || !root) return;
			root.feed = data;
			root.loaded = true;
			// the folders on the page, for their menus
			Files.request("describe", { paths: Object.values(data.dirs ?? {}).concat(FileLibrary.favorites) }, described => {
				if (!root) return;
				const byPath = {};
				for (const entry of described?.entries ?? []) byPath[entry.path] = entry;
				root.folders = byPath;
			});
		});
		Files.request("recent", { limit: 24 }, data => {
			if (!root) return;
			const own = FileLibrary.opened.slice(0, 24).map(entry => entry.path);
			Files.request("describe", { paths: own }, described => {
				if (!root) return;
				const byPath = {};
				for (const entry of data?.entries ?? []) byPath[entry.path] = entry;
				for (const entry of described?.entries ?? []) {
					if (entry.dir) continue;
					const at = FileLibrary.opened.find(item => item.path === entry.path)?.at ?? 0;
					if (!byPath[entry.path] || (byPath[entry.path].used ?? 0) < at) byPath[entry.path] = Object.assign(entry, { used: at });
				}
				// what just arrived is shown above already
				const arrived = (root.feed.arrivals ?? []).map(entry => entry.path);
				root.recent = Object.values(byPath).filter(entry => !arrived.includes(entry.path)).sort((a, b) => (b.used ?? 0) - (a.used ?? 0)).slice(0, 18);
			});
		});
	}

	property var folders: ({})

	Component.onCompleted: {
		root.refresh();
		PhoneDrive.checkFresh();
	}
	onVisibleChanged: if (root.visible) {
		root.refresh();
		PhoneDrive.checkFresh();
	}

	Connections {
		target: root.pane

		function onResetsChanged() {
			root.refresh();
			intro.restart();
		}
	}

	// new files in the watched folders show up while the page is open
	Instantiator {
		model: root.visible ? Shelf.watchDirs : []

		delegate: QtObject {
			required property string modelData
			required property int index

			Component.onCompleted: Files.watch(`home-${index}`, modelData)
			Component.onDestruction: Files.watch(`home-${index}`, "")
		}
	}

	Connections {
		target: Files

		function onFolderChanged(path) {
			if (Shelf.watchDirs.includes(path)) refreshTimer.restart();
		}
		function onJobFinished(job) {
			refreshTimer.restart();
		}
	}

	Timer {
		id: refreshTimer

		interval: 400
		onTriggered: root.refresh()
	}

	function rowOf(entry) {
		return Listing.row(entry, "", Files.home);
	}

	function openEntry(entry) {
		root.shell.openRow(root.pane, root.rowOf(entry), false);
	}

	function menuFor(entry, item, x, y) {
		const at = item.mapToItem(root.shell, x, y);
		root.shell.showRowsMenu(root.pane, [root.rowOf(entry)], at.x, at.y);
	}

	// ── the page ───────────────────────────────────────────────────────────
	Flickable {
		id: flick

		anchors.fill: parent
		contentWidth: width
		contentHeight: page.implicitHeight + 120
		interactive: false
		clip: true
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.NoButton
			onWheel: wheel => {
				const max = Math.max(0, flick.contentHeight - flick.height);
				if (wheel.pixelDelta.y !== 0) {
					scroll.stop();
					flick.contentY = Math.max(0, Math.min(max, flick.contentY - wheel.pixelDelta.y));
					return;
				}
				scroll.to = Math.max(0, Math.min(max, (scroll.running ? scroll.to : flick.contentY) - wheel.angleDelta.y / 120 * 110));
				scroll.restart();
			}
		}

		NumberAnimation {
			id: scroll

			target: flick
			property: "contentY"
			duration: 280
			easing.type: Easing.OutCubic
		}

		Column {
			id: page

			x: 24
			y: 4
			width: root.wide
			spacing: 26

			// ── greeting ───────────────────────────────────────────────────
			HomeSection {
				order: 0
				title: ""

				Row {
					spacing: 14

					Column {
						spacing: 2

						Text {
							text: {
								const hour = new Date().getHours();
								return hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
							}
							color: Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.display
							font.weight: Font.Bold
						}

						Text {
							text: {
								const arrived = (root.feed.arrivals ?? []).length;
								const running = Downloads.active.length;
								const parts = [Qt.formatDate(new Date(), "dddd, d MMMM")];
								if (running > 0) parts.push(`${running} download${running === 1 ? "" : "s"} running`);
								else if (arrived > 0) parts.push(`${arrived} new file${arrived === 1 ? "" : "s"} lately`);
								return parts.join("  ·  ");
							}
							color: Theme.textMuted
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.body
						}
					}
				}
			}

			// ── places ─────────────────────────────────────────────────────
			HomeSection {
				order: 1
				title: "Places"

				Flow {
					width: root.wide
					spacing: 12

					Repeater {
						model: ["home", "desktop", "documents", "downloads", "pictures", "videos", "music"].filter(key => root.dirs[key])

						delegate: PlaceTile {
							required property string modelData

							width: Math.floor((root.wide - 12 * (Math.max(1, Math.floor(root.wide / 170)) - 1)) / Math.max(1, Math.floor(root.wide / 170)))
							path: root.dirs[modelData]
							name: modelData === "home" ? "Home" : Files.nameOf(root.dirs[modelData])
							onActivated: root.pane.openFolder(path)
							onMenu: (item, x, y) => {
								const entry = root.folders[path];
								if (entry) root.menuFor(entry, item, x, y);
							}
						}
					}
				}
			}

			// ── what just arrived ──────────────────────────────────────────
			HomeSection {
				order: 2
				title: "Just arrived"
				subtitle: "Downloads, screenshots and recordings of the last days"
				visible: Downloads.active.length > 0 || (root.feed.arrivals ?? []).length > 0

				Strip {
					width: root.wide

					Repeater {
						model: Downloads.active

						delegate: DownloadCard {
							required property var modelData

							item: modelData
						}
					}

					Repeater {
						model: root.feed.arrivals ?? []

						delegate: HomeCard {
							required property var modelData

							entry: modelData
							onActivated: root.openEntry(modelData)
							onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
							onReveal: Files.reveal([modelData.path])
						}
					}
				}
			}

			// ── new on the phone ───────────────────────────────────────────
			HomeSection {
				order: 2
				title: `New on ${PhoneDrive.name}`
				subtitle: "Photos since the last import"
				visible: PhoneDrive.reachable && PhoneDrive.fresh.length > 0
				action: `Import all ${PhoneDrive.fresh.length}`
				onActionClicked: PhoneDrive.importEntries(PhoneDrive.fresh)

				Strip {
					width: root.wide

					Repeater {
						model: PhoneDrive.fresh

						delegate: HomeCard {
							required property var modelData

							entry: Object.assign({}, modelData, { thumb: (PhoneDrive.thumbTick, PhoneDrive.thumbs[modelData.phoneId] ?? "") })
							onActivated: PhoneDrive.open(modelData)
							onMenu: (item, x, y) => {
								const at = item.mapToItem(root.shell, x, y);
								root.shell.menuFromSidebar([
									{ label: "Open", icon: "open_in_app", run: () => PhoneDrive.open(modelData) },
									{ label: `Import to ${Files.pretty(PhoneDrive.importFolder())}`, icon: "cellphone_arrow_down", run: () => PhoneDrive.importEntries([modelData]) },
									{ label: `All of ${PhoneDrive.name}'s camera`, icon: "camera_outline", run: () => root.pane.go({ kind: "phone", id: "camera" }) }
								], at.x, at.y);
							}
							onReveal: root.pane.go({ kind: "phone", id: "camera" })
						}
					}
				}
			}

			// ── recent ─────────────────────────────────────────────────────
			HomeSection {
				order: 3
				title: "Recent"
				action: "Show all"
				onActionClicked: root.pane.go({ kind: "recent" })
				visible: root.recent.length > 0

				Strip {
					width: root.wide

					Repeater {
						model: root.recent

						delegate: HomeCard {
							required property var modelData

							entry: modelData
							when: modelData.used ?? modelData.mtime
							onActivated: root.openEntry(modelData)
							onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
							onReveal: Files.reveal([modelData.path])
						}
					}
				}
			}

			// ── the day: files made or changed, the meetings between them ───
			HomeSection {
				id: day

				// 0 today, 1 yesterday
				property int back: 0
				property var files: []
				readonly property var events: {
					Outlook.byDay;
					if (!Outlook.enabled || !Outlook.signedIn) return [];
					const date = new Date();
					date.setDate(date.getDate() - day.back);
					return Outlook.eventsOn(date).filter(event => !event.allDay && Outlook.active(event));
				}
				// files and meetings in one line of time, newest first
				readonly property var line: {
					const out = day.files.slice(0, 14).map(entry => ({ kind: "file", at: entry.mtime, entry: entry }));
					for (const event of day.events) out.push({ kind: "event", at: new Date(event.start).getTime() / 1000, event: event });
					return out.sort((a, b) => b.at - a.at);
				}

				function load() {
					const start = new Date();
					start.setHours(0, 0, 0, 0);
					start.setDate(start.getDate() - day.back);
					const end = new Date(start.getTime() + 86400000);
					Files.request("dayfiles", { start: start.getTime() / 1000, end: end.getTime() / 1000, limit: 40 }, data => day.files = data?.entries ?? []);
					if (Outlook.enabled) Outlook.ensure(start);
				}

				order: 3
				title: day.back === 0 ? "Your day" : "Yesterday"
				subtitle: Outlook.enabled && Outlook.signedIn ? "What you saved, and the meetings around it" : "What you saved"
				visible: day.line.length > 0
				action: day.back === 0 ? "Yesterday" : "Today"
				onActionClicked: {
					day.back = 1 - day.back;
					day.load();
				}
				Component.onCompleted: day.load()

				Connections {
					target: root

					function onFeedChanged() {
						day.load();
					}
				}

				Column {
					width: root.wide
					spacing: 2

					Repeater {
						model: day.line

						delegate: Item {
							id: moment

							required property var modelData

							width: root.wide
							height: moment.modelData.kind === "event" ? 40 : 50

							Text {
								id: clock

								width: 52
								anchors.verticalCenter: parent.verticalCenter
								text: Qt.formatTime(new Date(moment.modelData.at * 1000), "HH:mm")
								color: moment.modelData.kind === "event" ? Theme.primary : Theme.textSubtle
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.small
								font.weight: Font.DemiBold
							}

							// the line the moments hang on
							Rectangle {
								x: 58
								width: 2
								height: parent.height
								color: Theme.layer2
							}

							Rectangle {
								x: 54
								anchors.verticalCenter: parent.verticalCenter
								width: 10
								height: 10
								radius: 5
								color: moment.modelData.kind === "event" ? Theme.primary : Theme.layer3
								border.width: 2
								border.color: Theme.base
							}

							Rectangle {
								visible: moment.modelData.kind === "event"
								x: 76
								anchors.verticalCenter: parent.verticalCenter
								width: Math.min(parent.width - 80, eventText.implicitWidth + 40)
								height: 32
								radius: 16
								color: Theme.primarySoft

								Glyph {
									x: 10
									anchors.verticalCenter: parent.verticalCenter
									icon: moment.modelData.event?.online ? "video_outline" : "calendar_outline"
									size: 15
									color: Theme.primary
								}

								Text {
									id: eventText

									x: 32
									anchors.verticalCenter: parent.verticalCenter
									width: parent.width - 40
									text: String(moment.modelData.event?.subject ?? "")
									color: Theme.primary
									font.family: Theme.fontFamily
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
									elide: Text.ElideRight
								}
							}

							HomeRow {
								visible: moment.modelData.kind === "file"
								x: 70
								width: parent.width - 70
								anchors.verticalCenter: parent.verticalCenter
								entry: moment.modelData.entry ?? ({})
								onActivated: root.openEntry(moment.modelData.entry)
								onMenu: (item, x, y) => root.menuFor(moment.modelData.entry, item, x, y)
								onReveal: Files.reveal([moment.modelData.entry.path])
							}
						}
					}
				}
			}

			// ── favourites ─────────────────────────────────────────────────
			HomeSection {
				order: 4
				title: "Favorites"
				visible: FileLibrary.favorites.length > 0

				Flow {
					width: root.wide
					spacing: 12

					Repeater {
						model: FileLibrary.favorites

						delegate: PlaceTile {
							required property string modelData

							width: Math.floor((root.wide - 12 * (Math.max(1, Math.floor(root.wide / 170)) - 1)) / Math.max(1, Math.floor(root.wide / 170)))
							path: modelData
							name: Files.nameOf(modelData)
							onActivated: root.pane.openFolder(path)
							onMenu: (item, x, y) => {
								const entry = root.folders[path];
								if (entry) root.menuFor(entry, item, x, y);
							}
						}
					}
				}
			}

			// ── where the week went (screentime) ───────────────────────────
			HomeSection {
				id: busy

				property var folders: []

				order: 5
				title: "Worked on this week"
				subtitle: "By the time windows named these folders"
				visible: Plugins.on("screentime") && busy.folders.length > 0
				Component.onCompleted: busy.folders = Files.busyFolders()

				Connections {
					target: root

					function onFeedChanged() {
						busy.folders = Files.busyFolders();
					}
				}

				Column {
					width: Math.min(root.wide, 640)
					spacing: 4

					Repeater {
						model: busy.folders

						delegate: Item {
							id: project

							required property var modelData

							width: parent.width
							height: 34

							Glyph {
								anchors.verticalCenter: parent.verticalCenter
								icon: "folder_outline"
								size: 17
								color: Theme.primary
							}

							Text {
								x: 28
								width: 170
								anchors.verticalCenter: parent.verticalCenter
								text: Files.nameOf(project.modelData.path)
								color: Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.body
								elide: Text.ElideRight
							}

							Rectangle {
								x: 206
								anchors.verticalCenter: parent.verticalCenter
								width: (parent.width - 290) * project.modelData.seconds / Math.max(1, busy.folders[0].seconds)
								height: 8
								radius: 4
								color: Theme.primary
							}

							Text {
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								text: Screentime.format(project.modelData.seconds)
								color: Theme.textMuted
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.small
							}

							MouseArea {
								anchors.fill: parent
								cursorShape: Qt.PointingHandCursor
								onClicked: root.pane.openFolder(project.modelData.path)
							}
						}
					}
				}
			}

			// ── screenshots and recordings ─────────────────────────────────
			HomeSection {
				order: 5
				title: "Captures"
				subtitle: "Screenshots and screen recordings"
				visible: (root.feed.captures ?? []).length > 0
				action: "Show all"
				onActionClicked: root.pane.go({ kind: "captures" })

				Strip {
					width: root.wide

					Repeater {
						model: root.feed.captures ?? []

						delegate: HomeCard {
							required property var modelData

							entry: modelData
							wide: true
							onActivated: root.openEntry(modelData)
							onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
							onReveal: Files.reveal([modelData.path])
						}
					}
				}
			}

			// ── pictures, videos, documents ────────────────────────────────
			Row {
				id: media

				readonly property bool both: (root.feed.images ?? []).length > 0 && (root.feed.documents ?? []).length > 0
				readonly property real half: media.both && root.wide > 760 ? (root.wide - 24) / 2 : root.wide

				spacing: 24
				visible: (root.feed.images ?? []).length > 0 || (root.feed.documents ?? []).length > 0

				HomeSection {
					order: 6
					width: media.half
					title: "Pictures"
					visible: (root.feed.images ?? []).length > 0
					action: root.dirs.pictures ? "Open folder" : ""
					onActionClicked: root.pane.openFolder(root.dirs.pictures)

					Grid {
						id: mosaic

						readonly property int count: Math.max(2, Math.floor(media.half / 130))
						columns: mosaic.count
						spacing: 8

						Repeater {
							model: (root.feed.images ?? []).slice(0, mosaic.count * 2)

							delegate: HomeCard {
								required property var modelData

								width: (media.half - 8 * (mosaic.count - 1)) / mosaic.count
								entry: modelData
								bare: true
								onActivated: root.openEntry(modelData)
								onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
								onReveal: Files.reveal([modelData.path])
							}
						}
					}
				}

				HomeSection {
					order: 7
					width: media.half
					title: "Documents"
					visible: (root.feed.documents ?? []).length > 0 && media.both && root.wide > 760

					Column {
						width: media.half
						spacing: 2

						Repeater {
							model: (root.feed.documents ?? []).slice(0, 7)

							delegate: HomeRow {
								required property var modelData

								width: media.half
								entry: modelData
								onActivated: root.openEntry(modelData)
								onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
								onReveal: Files.reveal([modelData.path])
							}
						}
					}
				}
			}

			HomeSection {
				order: 7
				title: "Documents"
				visible: (root.feed.documents ?? []).length > 0 && !(media.both && root.wide > 760)

				Strip {
					width: root.wide

					Repeater {
						model: root.feed.documents ?? []

						delegate: HomeCard {
							required property var modelData

							entry: modelData
							onActivated: root.openEntry(modelData)
							onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
							onReveal: Files.reveal([modelData.path])
						}
					}
				}
			}

			HomeSection {
				order: 8
				title: "Videos"
				visible: (root.feed.videos ?? []).length > 0
				action: root.dirs.videos ? "Open folder" : ""
				onActionClicked: root.pane.openFolder(root.dirs.videos)

				Strip {
					width: root.wide

					Repeater {
						model: root.feed.videos ?? []

						delegate: HomeCard {
							required property var modelData

							entry: modelData
							wide: true
							onActivated: root.openEntry(modelData)
							onMenu: (item, x, y) => root.menuFor(modelData, item, x, y)
							onReveal: Files.reveal([modelData.path])
						}
					}
				}
			}

			// ── collections and tags ───────────────────────────────────────
			HomeSection {
				order: 9
				title: "Collections and tags"
				visible: FileLibrary.collections.length > 0 || FileLibrary.tags.some(tag => FileLibrary.countOf(tag.id) > 0)

				Flow {
					width: root.wide
					spacing: 8

					Repeater {
						model: FileLibrary.collections

						delegate: Chip {
							required property var modelData

							height: 34
							icon: "bookmark_box_multiple_outline"
							text: `${modelData.name}  ${modelData.paths.length}`
							onClicked: root.pane.go({ kind: "collection", id: modelData.id })
						}
					}

					Repeater {
						model: FileLibrary.tags.filter(tag => FileLibrary.countOf(tag.id) > 0)

						delegate: Chip {
							required property var modelData

							height: 34
							icon: "tag"
							accent: FileLibrary.colorOf(modelData.color)
							text: `${modelData.name}  ${FileLibrary.countOf(modelData.id)}`
							onClicked: root.pane.go({ kind: "tag", id: modelData.id })
						}
					}
				}
			}

			// ── drives ─────────────────────────────────────────────────────
			HomeSection {
				order: 10
				title: "Drives"
				visible: Files.drives.length > 0

				Flow {
					width: root.wide
					spacing: 12

					Repeater {
						model: Files.drives

						delegate: DriveTile {
							required property var modelData

							width: Math.min(300, Math.floor((root.wide - 12 * (Math.max(1, Math.floor(root.wide / 260)) - 1)) / Math.max(1, Math.floor(root.wide / 260))))
							place: modelData
							onActivated: root.shell.openPlace(root.pane, modelData)
						}
					}
				}
			}
		}
	}

	// sections rise in one after another
	property int introStep: 99

	SequentialAnimation {
		id: intro

		PropertyAction {
			target: root
			property: "introStep"
			value: -1
		}
		NumberAnimation {
			target: root
			property: "introStep"
			from: -1
			to: 12
			duration: 520
		}
	}

	Component.onDestruction: {
		for (let i = 0; i < Shelf.watchDirs.length; i += 1) Files.watch(`home-${i}`, "");
	}
}
