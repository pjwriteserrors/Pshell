pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Pending Arch updates, hidden behind a right click on the launcher button.
// Checking runs in the background, installing always opens a terminal: the
// whole list with "Update all", only the system group, or a single package
// by clicking its row.
//
// What matters before updating sits above the list: a reboot banner when the
// running kernel is outdated and Arch news since the last full upgrade (click
// opens it in the browser and marks it read). The wrench in the header slides
// to the maintenance page – config files, orphans, package cache – whose
// actions run in a terminal as well; its badge counts what needs attention.
Drawer {
	id: root

	panelId: "updates"
	panelWidth: 470
	contentHeight: pages.implicitHeight

	property string page: "main"
	property bool systemOpen: false
	property bool orphansOpen: false
	readonly property var apps: Updates.packages.filter(p => !root.isSystem(p))
	readonly property var system: Updates.packages.filter(p => root.isSystem(p))

	function ago(stamp) {
		if (!stamp) return "never checked";
		const minutes = Math.floor((Date.now() - stamp) / 60000);
		if (minutes < 1) return "checked just now";
		if (minutes < 60) return `checked ${minutes} min ago`;
		const hours = Math.floor(minutes / 60);
		if (hours < 24) return `checked ${hours} h ago`;
		return `checked ${Math.floor(hours / 24)} d ago`;
	}

	// package names are usually icon names too; strip the usual AUR suffixes
	function iconFor(name) {
		const base = String(name).replace(/-(git|bin|appimage|electron|beta|dev)$/i, "");
		for (const candidate of [name, base]) {
			const papirus = AppIcons.papirus(candidate);
			if (papirus !== "") return papirus;
			const themed = Quickshell.iconPath(candidate, true);
			if (themed !== "") return themed;
		}
		return "";
	}

	// repo packages without an app icon are folded into the "System" group
	function isSystem(pkg) {
		return pkg.source !== "aur" && root.iconFor(pkg.name) === "";
	}

	onPanelOpened: {
		root.page = Popups.page !== "" ? Popups.page : "main";
		Updates.clear();
		if (Date.now() - Updates.lastScan > 30000) Updates.scan();
		root.autoCheckOnOpen();
	}

	Connections {
		target: Popups
		function onPageChanged() {
			if (root.shown && Popups.page !== "") root.page = Popups.page;
		}
	}

	function autoCheckOnOpen() {
		if (!Updates.running && Updates.count === 0 && !Updates.checking) Updates.check();
	}

	PageView {
		id: pages

		anchors.left: parent.left
		anchors.right: parent.right
		current: root.page

		// ── main ──────────────────────────────────────────────────────────
		Page {
			pageName: "main"

			ColumnLayout {
				width: parent.width
				spacing: 14

				// ── header ────────────────────────────────────────────────────────
				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Glyph {
						icon: "package_variant"
						size: 20
						color: Updates.count > 0 ? Theme.primary : Theme.textMuted
					}

					StyledText {
						text: Words.of("updates.title", "Updates")
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}

					Badge {
						count: Updates.count
					}

					Item {
						Layout.fillWidth: true
					}

					StyledText {
						text: Updates.checking ? "checking…" : (Updates.error !== "" ? Updates.error : root.ago(Updates.lastCheck))
						tone: Updates.error !== "" ? Theme.danger : Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					IconButton {
						icon: "wrench"
						iconSize: 17
						onClicked: root.page = "maintenance"

						Badge {
							z: 11
							anchors.right: parent.right
							anchors.top: parent.top
							anchors.rightMargin: -3
							anchors.topMargin: -3
							count: Updates.attention
						}
					}

					IconButton {
						id: refreshButton

						icon: "refresh"
						iconSize: 17
						enabled: !Updates.checking && !Updates.running
						onClicked: Updates.check(true)

						RotationAnimation on rotation {
							running: Updates.checking
							loops: Animation.Infinite
							from: 0
							to: 360
							duration: 1400
							onRunningChanged: if (!running) refreshButton.rotation = 0
						}
					}
				}

				// ── reboot ────────────────────────────────────────────────────────
				Rectangle {
					Layout.fillWidth: true
					visible: Updates.rebootNeeded
					implicitHeight: 54
					radius: Theme.radius.large
					color: Qt.alpha(Theme.warning, 0.12)

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 10
						spacing: 12

						Glyph {
							icon: "restart_alert"
							size: 20
							color: Theme.warning
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 1

							StyledText {
								text: "Reboot required"
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								text: `${Updates.runningKernel} → ${Updates.installedKernel}`
								elide: Text.ElideRight
								tone: Theme.textMuted
								font.family: Theme.monoFamily
								font.pixelSize: Theme.size.tiny
							}
						}

						TextButton {
							text: "Reboot"
							icon: "restart"
							onActivated: Popups.openModal("power", root.targetScreen)
						}
					}
				}

				// ── Arch news since the last full upgrade ─────────────────────────
				Rectangle {
					Layout.fillWidth: true
					visible: Updates.unreadNews.length > 0
					implicitHeight: newsColumn.implicitHeight + 12
					radius: Theme.radius.large
					color: Qt.alpha(Theme.primary, 0.08)

					ColumnLayout {
						id: newsColumn

						x: 6
						y: 6
						width: parent.width - 12
						spacing: 2

						RowLayout {
							Layout.fillWidth: true
							Layout.leftMargin: 8
							Layout.topMargin: 2
							spacing: 8

							Glyph {
								icon: "newspaper_variant_outline"
								size: 15
								color: Theme.primary
							}

							SectionLabel {
								Layout.fillWidth: true
								text: Words.of("updates.news", "Arch news")
								tone: Theme.primary
							}

							IconButton {
								implicitWidth: 26
								implicitHeight: 26
								visible: Updates.unreadNews.length > 1
								icon: "check_all"
								iconSize: 15
								onClicked: Updates.markAllRead()
							}
						}

						Repeater {
							model: Updates.unreadNews

							delegate: NewsRow {}
						}
					}
				}

				// ── progress while a terminal update runs ─────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					visible: Updates.running || Updates.result !== ""
					spacing: 6

					RowLayout {
						Layout.alignment: Qt.AlignHCenter
						spacing: 8

						Glyph {
							icon: Updates.result === "failed" ? "close_circle" : (Updates.result === "ok" ? "shield_check" : "update")
							size: 15
							color: Updates.result === "failed" ? Theme.danger : Theme.primary
						}

						StyledText {
							Layout.maximumWidth: Math.min(implicitWidth, root.innerWidth - 30)
							text: Updates.progressLabel
							elide: Text.ElideRight
							horizontalAlignment: Text.AlignHCenter
							tone: Updates.result === "failed" ? Theme.danger : Theme.text
							font.pixelSize: Theme.size.small
						}
					}

					// determinate as soon as pacman reports (x/y), a sweep before that
					Rectangle {
						id: track

						Layout.fillWidth: true
						implicitHeight: 6
						radius: 3
						color: Theme.layer2
						clip: true

						Rectangle {
							id: bar

							property real sweep: -track.width * 0.35

							x: Updates.progress > 0 ? 0 : bar.sweep
							width: track.width * (Updates.progress > 0 ? Updates.progress : 0.35)
							height: parent.height
							radius: parent.radius
							color: Updates.result === "failed" ? Theme.danger : Theme.primary

							Behavior on width {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							NumberAnimation on sweep {
								running: Updates.running && Updates.progress <= 0
								loops: Animation.Infinite
								from: -track.width * 0.35
								to: track.width
								duration: 1400
								easing.type: Easing.InOutSine
							}
						}
					}
				}

				// ── list ──────────────────────────────────────────────────────────
				EmptyState {
					Layout.alignment: Qt.AlignHCenter
					Layout.topMargin: 10
					Layout.bottomMargin: 10
					visible: Updates.count === 0
					icon: Updates.checking ? "sync" : "shield_check"
					title: Updates.checking ? "Looking for updates" : "Everything up to date"
					subtitle: Updates.checking ? "" : root.ago(Updates.lastCheck)
				}

				Flickable {
					id: list

					Layout.fillWidth: true
					Layout.preferredHeight: Math.min(contentHeight, 360)
					visible: Updates.count > 0
					contentHeight: rows.implicitHeight
					clip: true
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					Column {
						id: rows

						width: list.width
						spacing: 2

						Repeater {
							model: root.apps

							delegate: PackageRow {
								id: appRow

								iconSource: root.iconFor(appRow.modelData.name)
							}
						}

						// everything without an app icon (libraries, system tools)
						Clickable {
							id: systemHeader

							readonly property bool busy: Updates.running && root.system.length > 0 && root.system.every(p => Updates.runningNames.includes(p.name))

							width: rows.width
							implicitHeight: 46
							visible: root.system.length > 0
							radius: Theme.radius.medium
							color: systemHeader.busy ? Qt.alpha(Theme.primary, 0.14) : (systemHeader.hovered || root.systemOpen ? Theme.layer1 : "transparent")
							onClicked: root.systemOpen = !root.systemOpen

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 10
								anchors.rightMargin: 46
								spacing: 10

								Rectangle {
									Layout.preferredWidth: 26
									Layout.preferredHeight: 26
									radius: Theme.radius.small
									color: Theme.layer2

									Glyph {
										anchors.centerIn: parent
										icon: "package_variant"
										size: 15
										color: Theme.textMuted
									}
								}

								StyledText {
									text: "System"
									font.pixelSize: Theme.size.label
									font.weight: Font.DemiBold
								}

								StyledText {
									text: root.system.length
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.small
								}

								Glyph {
									icon: "chevron_down"
									size: 15
									color: Theme.textSubtle
									rotation: root.systemOpen ? 180 : 0

									Behavior on rotation {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}

								Item {
									Layout.fillWidth: true
								}

								Spinner {
									visible: systemHeader.busy
									running: systemHeader.busy
								}
							}

							// sits above the header's own click layer
							IconButton {
								z: 20
								anchors.right: parent.right
								anchors.rightMargin: 6
								anchors.verticalCenter: parent.verticalCenter
								implicitWidth: 32
								implicitHeight: 32
								visible: !systemHeader.busy
								icon: "package_up"
								iconSize: 17
								iconColor: Theme.primary
								enabled: !Updates.busy
								onClicked: Updates.updateSome(root.system.map(p => p.name))
							}
						}

						Item {
							width: rows.width
							height: root.systemOpen ? systemRows.implicitHeight : 0
							visible: height > 0
							clip: true

							Behavior on height {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Column {
								id: systemRows

								width: parent.width
								spacing: 2

								Repeater {
									model: root.system

									delegate: PackageRow {
										id: systemRow

										iconSource: root.iconFor(systemRow.modelData.name)
									}
								}
							}
						}
					}
				}

				// ── actions ───────────────────────────────────────────────────────
				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					TextButton {
						Layout.fillWidth: true
						text: Updates.running ? "Update running…" : (Updates.count > 0 ? `Update all (${Updates.count})` : "Run yay -Syu")
						icon: "update"
						variant: "filled"
						enabled: !Updates.busy
						busy: Updates.running
						onClicked: Updates.updateAll()
					}
				}

				Rectangle {
					Layout.fillWidth: true
					implicitHeight: 1
					color: Theme.outline
				}

				// ── settings ──────────────────────────────────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					spacing: 10

					RowLayout {
						Layout.fillWidth: true
						spacing: 10

						StyledText {
							Layout.fillWidth: true
							text: "Check automatically"
							font.pixelSize: Theme.size.label
							font.weight: Font.Medium
						}

						Toggle {
							checked: Updates.autoCheck
							onToggled: on => Updates.setAutoCheck(on)
						}
					}

					Segmented {
						Layout.fillWidth: true
						enabled: Updates.autoCheck
						opacity: Updates.autoCheck ? 1 : 0.4
						options: [
							{ value: "1", label: "1 h" },
							{ value: "6", label: "6 h" },
							{ value: "12", label: "12 h" },
							{ value: "24", label: "1 d" }
						]
						current: String(Updates.intervalHours)
						onSelected: value => Updates.setInterval(Number(value))
					}
				}
			}
		}

		// ── maintenance ───────────────────────────────────────────────────
		Page {
			pageName: "maintenance"

			ColumnLayout {
				width: parent.width
				spacing: 12

				PageHeader {
					Layout.fillWidth: true
					title: Words.of("updates.maintenance", "Maintenance")
					onBack: root.page = "main"

					IconButton {
						id: rescanButton

						icon: "refresh"
						iconSize: 17
						enabled: !Updates.scanning
						onClicked: Updates.scan()

						RotationAnimation on rotation {
							running: Updates.scanning
							loops: Animation.Infinite
							from: 0
							to: 360
							duration: 1400
							onRunningChanged: if (!running) rescanButton.rotation = 0
						}
					}
				}

				// .pacnew / .pacsave
				Card {
					CardHeader {
						icon: "file_compare"
						title: "Config files"
						detail: Updates.pacnew.length > 0 ? `${Updates.pacnew.length} .pacnew / .pacsave` : "None"
						attention: Updates.pacnew.length > 0

						TextButton {
							visible: Updates.pacnew.length > 0
							text: "Merge"
							icon: "file_compare"
							enabled: !Updates.busy
							busy: Updates.task === "pacnew"
							onActivated: Updates.runTask("pacnew")
						}
					}

					Flickable {
						id: pacnewList

						Layout.fillWidth: true
						Layout.leftMargin: 42
						Layout.preferredHeight: Math.min(contentHeight, 120)
						visible: Updates.pacnew.length > 0
						contentHeight: pacnewColumn.implicitHeight
						clip: true
						boundsBehavior: Flickable.StopAtBounds
						ScrollBar.vertical: ThinScrollBar {}

						Column {
							id: pacnewColumn

							width: pacnewList.width
							spacing: 3

							Repeater {
								model: Updates.pacnew

								delegate: StyledText {
									required property string modelData

									width: pacnewColumn.width
									text: modelData
									elide: Text.ElideMiddle
									tone: Theme.textMuted
									font.family: Theme.monoFamily
									font.pixelSize: Theme.size.tiny
								}
							}
						}
					}
				}

				// orphaned packages
				Card {
					CardHeader {
						icon: "package_variant_remove"
						title: "Orphans"
						detail: Updates.orphans.length > 0 ? `${Updates.orphans.length} ${Updates.orphans.length === 1 ? "package" : "packages"}` : "None"
						attention: Updates.orphans.length > 0

						TextButton {
							visible: Updates.orphans.length > 0
							text: "Remove"
							icon: "package_variant_remove"
							variant: "danger"
							enabled: !Updates.busy
							busy: Updates.task === "orphans"
							onActivated: Updates.runTask("orphans")
						}
					}

					StyledText {
						Layout.fillWidth: true
						Layout.leftMargin: 42
						visible: Updates.orphans.length > 0
						text: Updates.orphans.join("  ·  ")
						wrapMode: Text.WordWrap
						maximumLineCount: root.orphansOpen ? 1000 : 3
						elide: Text.ElideRight
						tone: Theme.textMuted
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
						lineHeight: 1.25

						MouseArea {
							anchors.fill: parent
							cursorShape: Qt.PointingHandCursor
							onClicked: root.orphansOpen = !root.orphansOpen
						}
					}
				}

				// pacman + yay cache
				Card {
					CardHeader {
						icon: "harddisk"
						title: "Package cache"
						detail: `pacman ${Updates.formatBytes(Updates.pacmanCache)}  ·  yay ${Updates.formatBytes(Updates.yayCache)}`
						attention: Updates.cacheLarge

						TextButton {
							visible: Updates.hasPaccache && Updates.pacmanCache > 0
							text: "Keep latest"
							enabled: !Updates.busy
							busy: Updates.task === "paccache"
							onActivated: Updates.runTask("paccache")
						}

						TextButton {
							visible: Updates.cacheSize > 0
							text: "Clear"
							icon: "broom"
							enabled: !Updates.busy
							busy: Updates.task === "cache"
							onActivated: Updates.runTask("cache")
						}
					}
				}
			}
		}
	}

	component NewsRow: Clickable {
		id: news

		required property var modelData

		Layout.fillWidth: true
		implicitHeight: newsText.implicitHeight + 16
		radius: Theme.radius.medium
		color: news.hovered ? Qt.alpha(Theme.primary, 0.1) : "transparent"
		onClicked: Updates.openNews(news.modelData)

		ColumnLayout {
			id: newsText

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.leftMargin: 10
			anchors.rightMargin: 42
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			StyledText {
				Layout.fillWidth: true
				text: news.modelData.title
				wrapMode: Text.WordWrap
				maximumLineCount: 2
				elide: Text.ElideRight
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}

			StyledText {
				text: Qt.formatDate(new Date(news.modelData.date), "d MMM yyyy")
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.tiny
			}
		}

		// sits above the row's own click layer
		IconButton {
			z: 20
			anchors.right: parent.right
			anchors.rightMargin: 4
			anchors.verticalCenter: parent.verticalCenter
			implicitWidth: 30
			implicitHeight: 30
			icon: "check"
			iconSize: 16
			iconColor: Theme.textMuted
			onClicked: Updates.markRead(news.modelData.link)
		}
	}

	component Card: Rectangle {
		id: card

		default property alias content: cardColumn.data

		Layout.fillWidth: true
		implicitHeight: cardColumn.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: cardColumn

			x: 12
			y: 12
			width: card.width - 24
			spacing: 10
		}
	}

	component CardHeader: RowLayout {
		id: header

		property string icon: ""
		property string title: ""
		property string detail: ""
		property bool attention: false
		default property alias trailing: headerActions.data

		Layout.fillWidth: true
		spacing: 10

		Rectangle {
			Layout.preferredWidth: 32
			Layout.preferredHeight: 32
			radius: 16
			color: header.attention ? Qt.alpha(Theme.warning, 0.16) : Theme.layer2

			Glyph {
				anchors.centerIn: parent
				icon: header.icon
				size: 16
				color: header.attention ? Theme.warning : Theme.textMuted
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: header.title
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				text: header.detail
				elide: Text.ElideRight
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		RowLayout {
			id: headerActions

			spacing: 6
		}
	}

	component PackageRow: Clickable {
		id: entry

		required property var modelData
		property string iconSource: ""
		readonly property bool busy: Updates.isRunning(entry.modelData.name)

		width: parent ? parent.width : 0
		implicitHeight: 46
		radius: Theme.radius.medium
		color: entry.busy ? Qt.alpha(Theme.primary, 0.14) : (entry.hovered ? Theme.layer1 : "transparent")
		enabled: !Updates.busy
		onClicked: Updates.updateOne(entry.modelData.name)

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 10
			anchors.rightMargin: 8
			spacing: 10

			Item {
				Layout.preferredWidth: 26
				Layout.preferredHeight: 26

				Image {
					id: pkgIcon

					anchors.fill: parent
					source: entry.iconSource
					sourceSize: Qt.size(52, 52)
					fillMode: Image.PreserveAspectFit
					asynchronous: true
					smooth: true
					mipmap: true
					visible: entry.iconSource !== "" && status === Image.Ready
				}

				Rectangle {
					anchors.fill: parent
					visible: !pkgIcon.visible
					radius: Theme.radius.small
					color: entry.modelData.source === "aur" ? Qt.alpha(Theme.tertiary, 0.18) : Theme.layer2

					Glyph {
						anchors.centerIn: parent
						icon: entry.modelData.source === "aur" ? "source_branch" : "package_variant"
						size: 15
						color: entry.modelData.source === "aur" ? Theme.tertiary : Theme.textMuted
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					StyledText {
						Layout.maximumWidth: 230
						text: entry.modelData.name
						elide: Text.ElideRight
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}

					Rectangle {
						visible: entry.modelData.source === "aur"
						implicitWidth: aurLabel.implicitWidth + 10
						implicitHeight: 15
						radius: 7.5
						color: Qt.alpha(Theme.tertiary, 0.2)

						StyledText {
							id: aurLabel

							anchors.centerIn: parent
							text: "AUR"
							tone: Theme.tertiary
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
						}
					}

					Item {
						Layout.fillWidth: true
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 5

					StyledText {
						text: entry.modelData.current
						tone: Theme.textFaint
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
					}

					Glyph {
						icon: "arrow_right"
						size: 11
						color: Theme.textFaint
					}

					StyledText {
						Layout.fillWidth: true
						text: entry.modelData.next
						elide: Text.ElideRight
						tone: Theme.primary
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
					}
				}
			}

			Spinner {
				visible: entry.busy
				running: entry.busy
			}

			Glyph {
				visible: !entry.busy && entry.hovered
				icon: "package_up"
				size: 17
				color: Theme.primary
			}
		}
	}
}
