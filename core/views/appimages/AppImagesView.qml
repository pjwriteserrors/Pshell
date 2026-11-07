pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// What the AppImages' window shows: a link field and the list – installed,
// set up by another tool, lying around – with the install as a sheet over
// it. Everything dropped on it (a file, a link) is installed.
FocusScope {
	id: root

	property bool shown: false
	readonly property bool sheetOpen: AppImages.candidate !== null
	readonly property bool narrow: root.width < 680

	// one list for all three, with their headings as rows, so whatever
	// changes glides instead of the list being built again
	readonly property var items: {
		const out = [];
		const query = search.text.trim().toLowerCase();
		const fits = item => query === "" || `${item.name} ${item.command ?? ""} ${item.comment ?? ""}`.toLowerCase().includes(query);
		const installed = AppImages.installed.filter(fits);
		const foreign = AppImages.foreign.filter(fits);
		const loose = AppImages.loose.filter(fits);
		if (installed.length > 0) {
			out.push({ key: "h:installed", kind: "header", title: "Installed", detail: `${installed.length} · ${AppImages.sizeText(installed.reduce((sum, app) => sum + (app.size || 0), 0))}` });
			for (const app of installed) out.push({ key: `i:${app.id}`, kind: "installed", app: app });
		}
		if (foreign.length > 0) {
			out.push({ key: "h:foreign", kind: "header", title: "Set up by another tool", detail: String(foreign.length) });
			for (const app of foreign) out.push({ key: `f:${app.file}`, kind: "foreign", app: app });
		}
		if (loose.length > 0) {
			out.push({ key: "h:loose", kind: "header", title: "Not installed yet", detail: String(loose.length) });
			for (const app of loose) out.push({ key: `l:${app.file}`, kind: "loose", app: app });
		}
		return out;
	}

	onItemsChanged: rows.sync(root.items)
	Component.onCompleted: {
		rows.sync(root.items);
		root.takeFocus();
	}
	onShownChanged: if (root.shown) {
		intro.restart();
		root.takeFocus();
	}

	function takeFocus() {
		if (!root.sheetOpen) search.focusInput();
	}

	SyncedModel {
		id: rows
	}

	Keys.onEscapePressed: AppImages.back()

	Shortcut {
		sequences: ["Ctrl+O"]
		enabled: root.shown && !root.sheetOpen
		onActivated: AppImages.pickFile()
	}

	Shortcut {
		sequences: ["Ctrl+L"]
		enabled: root.shown && !root.sheetOpen
		onActivated: link.focusInput()
	}

	Shortcut {
		sequences: ["Ctrl+R", "F5"]
		enabled: root.shown && !root.sheetOpen
		onActivated: AppImages.check("")
	}

	Rectangle {
		anchors.fill: parent
		color: Theme.base
	}

	// a soft light of the accent, drifting slowly behind everything
	Item {
		anchors.fill: parent
		clip: true
		opacity: Theme.dark ? 0.5 : 0.35

		Rectangle {
			id: glow

			width: Math.max(root.width, root.height) * 0.9
			height: width
			radius: width / 2
			x: -width * 0.35 + drift.value * root.width * 0.12
			y: -height * 0.55 + drift.value * 40
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.alpha(Theme.primary, 0.18)
				}
				GradientStop {
					position: 0.6
					color: Qt.alpha(Theme.primary, 0.0)
				}
			}
			rotation: 45
		}

		QtObject {
			id: drift

			property real value: 0

			SequentialAnimation on value {
				running: root.shown
				loops: Animation.Infinite

				NumberAnimation {
					to: 1
					duration: 14000
					easing.type: Easing.InOutSine
				}
				NumberAnimation {
					to: 0
					duration: 14000
					easing.type: Easing.InOutSine
				}
			}
		}
	}

	// the first look: the header settles, the rows follow it
	ParallelAnimation {
		id: intro

		NumberAnimation {
			target: header
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.long
		}
		SpatialAnim {
			target: headerShift
			property: "y"
			from: -14
			to: 0
			duration: Motion.extraLong
		}
		SequentialAnimation {
			PauseAnimation {
				duration: 60
			}
			ParallelAnimation {
				NumberAnimation {
					target: body
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.long
				}
				SpatialAnim {
					target: bodyShift
					property: "y"
					from: 22
					to: 0
					duration: Motion.extraLong
				}
			}
		}
	}

	ColumnLayout {
		id: page

		anchors.fill: parent
		anchors.margins: root.narrow ? 14 : 22
		spacing: 14
		enabled: !root.sheetOpen
		// the list steps back while the sheet is over it
		scale: root.sheetOpen ? 0.97 : 1
		opacity: root.sheetOpen ? 0.5 : 1

		Behavior on scale {
			SpatialAnim {
				duration: Motion.extraLong
			}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		// ── the head ──────────────────────────────────────────────────────
		RowLayout {
			id: header

			Layout.fillWidth: true
			spacing: 14
			transform: Translate {
				id: headerShift
			}

			Rectangle {
				Layout.preferredWidth: 46
				Layout.preferredHeight: 46
				radius: Theme.radius.large
				color: Theme.primaryContainer

				Glyph {
					anchors.centerIn: parent
					anchors.verticalCenterOffset: bob.value
					icon: AppImages.updateCount > 0 ? "package_up" : "package_variant"
					size: 24
					color: Theme.primary
				}

				QtObject {
					id: bob

					property real value: 0

					SequentialAnimation on value {
						running: root.shown && (AppImages.checking || AppImages.updateCount > 0)
						loops: Animation.Infinite
						onRunningChanged: if (!running) bob.value = 0

						NumberAnimation {
							to: -2.5
							duration: 700
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 0
							duration: 700
							easing.type: Easing.InOutSine
						}
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "AppImages"
					font.pixelSize: Theme.size.heading
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						const parts = [];
						const count = AppImages.installed.length;
						parts.push(count === 0 ? "None installed" : `${count} installed · ${AppImages.sizeText(AppImages.totalSize)}`);
						if (AppImages.updateCount > 0) parts.push(AppImages.updateCount === 1 ? "1 update" : `${AppImages.updateCount} updates`);
						if (AppImages.checking) parts.push("looking for updates…");
						else if (AppImages.setting("lastCheck", 0) > 0) parts.push(`looked ${AppImages.ago(AppImages.setting("lastCheck", 0) / 1000)}`);
						return parts.join("  ·  ");
					}
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			Field {
				id: search

				visible: !root.narrow && (AppImages.installed.length + AppImages.foreign.length + AppImages.loose.length) > 4
				Layout.preferredWidth: 200
				icon: "magnify"
				placeholder: "Find"
				onEscapePressed: search.text !== "" ? search.text = "" : AppImages.back()
			}

			IconButton {
				icon: "refresh"
				enabled: !AppImages.checking
				rotation: AppImages.checking ? spinAngle.value : 0
				onClicked: AppImages.check("")

				QtObject {
					id: spinAngle

					property real value: 0

					NumberAnimation on value {
						running: AppImages.checking
						from: 0
						to: 360
						duration: 900
						loops: Animation.Infinite
					}
				}
			}

			TextButton {
				visible: AppImages.updateCount > 0
				text: root.narrow ? `${AppImages.updateCount}` : (AppImages.updateCount === 1 ? "Update" : `Update all ${AppImages.updateCount}`)
				icon: "arrow_up_bold_circle_outline"
				variant: "tonal"
				onActivated: AppImages.updateAll()
			}

			TextButton {
				text: root.narrow ? "" : "Install file"
				icon: "plus"
				variant: "filled"
				onActivated: AppImages.pickFile()
			}
		}

		ColumnLayout {
			id: body

			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 12
			transform: Translate {
				id: bodyShift
			}

			// ── a link ────────────────────────────────────────────────────
			LinkField {
				id: link

				Layout.fillWidth: true
			}

			// ~/.local/bin is not where the shell looks for commands
			Rectangle {
				Layout.fillWidth: true
				visible: AppImages.loaded && !AppImages.binOnPath
				implicitHeight: warnRow.implicitHeight + 18
				radius: Theme.radius.medium
				color: Qt.alpha(Theme.warning, 0.12)

				RowLayout {
					id: warnRow

					anchors.fill: parent
					anchors.margins: 9
					anchors.leftMargin: 12
					spacing: 10

					Glyph {
						icon: "alert_outline"
						color: Theme.warning
					}

					StyledText {
						Layout.fillWidth: true
						text: "~/.local/bin is not on your PATH, so the commands are not found in a terminal. Add it in your shell's profile."
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.small
					}
				}
			}

			// ── the list ──────────────────────────────────────────────────
			ListView {
				id: list

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				spacing: 8
				model: rows
				boundsBehavior: Flickable.StopAtBounds
				cacheBuffer: 600
				ThinScrollBar.vertical: ThinScrollBar {}

				delegate: Loader {
					id: row

					required property string key
					required property string json
					required property int index
					readonly property var item: JSON.parse(row.json)

					width: list.width
					sourceComponent: row.item.kind === "header" ? headerRow : appRow

					Component {
						id: headerRow

						RowLayout {
							spacing: 8

							Item {
								Layout.preferredWidth: 4
							}

							SectionLabel {
								Layout.topMargin: row.index === 0 ? 2 : 14
								Layout.bottomMargin: 2
								text: row.item.title
							}

							StyledText {
								Layout.topMargin: row.index === 0 ? 2 : 14
								Layout.bottomMargin: 2
								text: row.item.detail
								tone: Theme.textFaint
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
							}

							Item {
								Layout.fillWidth: true
							}
						}
					}

					Component {
						id: appRow

						AppRow {
							kind: row.item.kind
							app: row.item.app
						}
					}
				}

				add: Transition {
					ParallelAnimation {
						NumberAnimation {
							property: "opacity"
							from: 0
							to: 1
							duration: Motion.long
						}
						NumberAnimation {
							property: "scale"
							from: 0.94
							to: 1
							duration: Motion.extraLong
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatial
						}
					}
				}

				remove: Transition {
					ParallelAnimation {
						NumberAnimation {
							property: "opacity"
							to: 0
							duration: Motion.long
						}
						NumberAnimation {
							property: "x"
							to: 60
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.accel
						}
						NumberAnimation {
							property: "scale"
							to: 0.92
							duration: Motion.long
						}
					}
				}

				displaced: Transition {
					NumberAnimation {
						properties: "x,y"
						duration: Motion.extraLong
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
					NumberAnimation {
						properties: "opacity,scale"
						to: 1
						duration: Motion.medium
					}
				}

				// nothing anywhere yet
				Item {
					anchors.fill: parent
					visible: AppImages.loaded && rows.count === 0
					opacity: visible ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.long
						}
					}

					ColumnLayout {
						anchors.centerIn: parent
						spacing: 14

						Item {
							Layout.alignment: Qt.AlignHCenter
							Layout.preferredWidth: 120
							Layout.preferredHeight: 120

							// rings going out from the box, as if it waits for something
							Repeater {
								model: 3

								Rectangle {
									id: ripple

									required property int index

									anchors.centerIn: parent
									width: 64
									height: 64
									radius: width / 2
									color: "transparent"
									border.width: 2
									border.color: Theme.primary
									opacity: 0

									SequentialAnimation {
										running: root.shown && rows.count === 0
										loops: Animation.Infinite

										PauseAnimation {
											duration: ripple.index * 700
										}
										ParallelAnimation {
											NumberAnimation {
												target: ripple
												property: "scale"
												from: 0.8
												to: 1.9
												duration: 2100
												easing.type: Easing.OutCubic
											}
											NumberAnimation {
												target: ripple
												property: "opacity"
												from: 0.45
												to: 0
												duration: 2100
											}
										}
										PauseAnimation {
											duration: (2 - ripple.index) * 700
										}
									}
								}
							}

							Rectangle {
								anchors.centerIn: parent
								width: 72
								height: 72
								radius: 22
								color: Theme.primaryContainer

								Glyph {
									anchors.centerIn: parent
									icon: "package_variant"
									size: 34
									color: Theme.primary
								}
							}
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: search.text !== "" ? "Nothing found" : "No AppImages yet"
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							Layout.maximumWidth: 360
							horizontalAlignment: Text.AlignHCenter
							wrapMode: Text.Wrap
							visible: search.text === ""
							text: "Drop one here, open one in Files, or paste a download link above – it becomes an app in the launcher and a command in the terminal."
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}
					}
				}
			}

			// ── how updates are looked for ────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				Toggle {
					checked: AppImages.setting("autoCheck", true)
					onToggled: on => AppImages.keep("autoCheck", on)
				}

				StyledText {
					text: "Look for updates"
					font.pixelSize: Theme.size.small
				}

				Segmented {
					Layout.preferredWidth: root.narrow ? 180 : 240
					implicitHeight: 28
					opacity: AppImages.setting("autoCheck", true) ? 1 : 0.4
					enabled: AppImages.setting("autoCheck", true)
					options: [
						{ value: "1", label: "Hourly" },
						{ value: "6", label: "6 h" },
						{ value: "24", label: "Daily" },
						{ value: "168", label: "Weekly" }
					]
					current: String(AppImages.setting("everyHours", 6))
					onSelected: value => AppImages.keep("everyHours", Number(value))

					Behavior on opacity {
						Anim {}
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Toggle {
					visible: !root.narrow
					checked: AppImages.setting("notify", true)
					onToggled: on => AppImages.keep("notify", on)
				}

				StyledText {
					visible: !root.narrow
					text: "Notify me"
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	// ── dropping a file or a link ──────────────────────────────────────────
	DropArea {
		id: drop

		anchors.fill: parent
		keys: ["text/uri-list", "text/plain"]
		readonly property bool fits: drop.containsDrag && !root.sheetOpen
		onDropped: event => {
			const urls = (event.urls ?? []).map(url => String(url));
			const text = String(event.text || "").trim();
			const picked = urls.length > 0 ? urls : (text !== "" ? text.split(/\s+/) : []);
			for (const each of picked) AppImages.install(each);
			event.acceptProposedAction();
		}
	}

	Item {
		anchors.fill: parent
		visible: opacity > 0
		opacity: drop.fits ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}

		Rectangle {
			anchors.fill: parent
			color: Qt.alpha(Theme.base, 0.82)
		}

		Rectangle {
			id: dropFrame

			anchors.fill: parent
			anchors.margins: 18
			radius: Theme.radius.huge
			color: Qt.alpha(Theme.primary, 0.06)
			border.width: 2
			border.color: Qt.alpha(Theme.primary, 0.4 + 0.4 * pulse.value)
			scale: drop.fits ? 1 : 1.03

			Behavior on scale {
				SpatialAnim {}
			}

			QtObject {
				id: pulse

				property real value: 0

				SequentialAnimation on value {
					running: drop.fits
					loops: Animation.Infinite

					NumberAnimation {
						to: 1
						duration: 650
						easing.type: Easing.InOutSine
					}
					NumberAnimation {
						to: 0
						duration: 650
						easing.type: Easing.InOutSine
					}
				}
			}

			ColumnLayout {
				anchors.centerIn: parent
				spacing: 12

				Rectangle {
					Layout.alignment: Qt.AlignHCenter
					Layout.preferredWidth: 84
					Layout.preferredHeight: 84
					radius: 26
					color: Theme.primary
					scale: drop.fits ? 1 + 0.05 * pulse.value : 0.6

					Behavior on scale {
						SpatialAnim {
							duration: Motion.extraLong
						}
					}

					Glyph {
						anchors.centerIn: parent
						anchors.verticalCenterOffset: -3 + 6 * pulse.value
						icon: "tray_arrow_down"
						size: 40
						color: Theme.onPrimary
					}
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: "Drop to install"
					font.pixelSize: Theme.size.heading
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: "An AppImage, or a link to one"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	// ── the install, over everything ───────────────────────────────────────
	InstallSheet {
		anchors.fill: parent
		onClosed: root.takeFocus()
	}

	// ── what just happened ─────────────────────────────────────────────────
	Toast {
		id: toast

		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 64
	}

	Connections {
		target: AppImages

		function onRemoved(name, freed) {
			toast.say(`${name || "It"} is gone`, freed > 0 ? `${AppImages.sizeText(freed)} freed` : "", "delete_sweep_outline");
		}

		function onUpdated(name, version) {
			toast.say(`${name} is up to date`, version ? `Now ${version}` : "", "arrow_up_bold_circle_outline");
		}

		function onErrorChanged() {
			if (AppImages.error !== "") {
				toast.say(AppImages.error, "", "alert_circle_outline");
				AppImages.error = "";
			}
		}
	}
}
