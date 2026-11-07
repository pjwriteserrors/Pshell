pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One AppImage of the list: installed (start, update, where updates come
// from, remove), set up by another tool (take over, remove) or lying around
// (install). Removing opens below it what goes with it – the app, its entry,
// icon and command for sure, its settings and caches as you choose – and the
// row slides away once it is gone.
Item {
	id: root

	// "installed" | "foreign" | "loose"
	property string kind: "installed"
	property var app: ({})

	readonly property string target: root.kind === "installed" ? String(root.app.id) : String(root.app.file)
	readonly property bool going: !!AppImages.removing[root.target]
	readonly property var removal: AppImages.removal?.target === root.target ? AppImages.removal : null
	readonly property var progress: root.kind === "installed" ? (AppImages.updating[root.app.id] ?? null) : null
	readonly property bool missing: root.app.present === false
	property bool details: false
	property bool editingOrigin: false
	// paths of the data a removal leaves (unticked)
	property var spared: ({})

	implicitHeight: card.height
	height: implicitHeight
	opacity: root.going ? 0.45 : 1
	scale: root.going ? 0.98 : 1

	Behavior on opacity {
		Anim {}
	}
	Behavior on scale {
		SpatialAnim {}
	}

	onRemovalChanged: if (!root.removal) root.spared = ({})

	Rectangle {
		id: card

		width: parent.width
		height: column.implicitHeight
		radius: Theme.radius.large
		color: root.removal ? Qt.tint(Theme.layer1, Qt.alpha(Theme.danger, 0.06)) : (top.hovered || root.details ? Theme.layer2 : Theme.layer1)
		border.width: 1
		border.color: root.removal ? Qt.alpha(Theme.danger, 0.35) : (root.app.update ? Qt.alpha(Theme.primary, 0.35) : Theme.outline)
		clip: true

		Behavior on color {
			ColorAnim {}
		}
		Behavior on border.color {
			ColorAnim {}
		}

		// an update under way runs along the bottom
		Rectangle {
			anchors.bottom: parent.bottom
			anchors.left: parent.left
			height: 3
			radius: 1.5
			visible: root.progress !== null
			color: root.progress?.step === "failed" ? Theme.danger : Theme.primary
			width: parent.width * Math.max(0.02, root.progress && root.progress.progress >= 0 ? (root.progress.step === "download" ? root.progress.progress * 0.8 : 0.85 + 0.15 * root.progress.progress) : 0.1)

			Behavior on width {
				SpatialAnim {}
			}
		}

		ColumnLayout {
			id: column

			width: parent.width
			spacing: 0

			// ── the row itself ────────────────────────────────────────────
			Clickable {
				id: top

				Layout.fillWidth: true
				Layout.preferredHeight: 74
				radius: Theme.radius.large
				pressedScale: 0.99
				sound: root.kind === "installed" ? "click" : ""
				onClicked: if (root.kind === "installed") root.details = !root.details

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 14
					anchors.rightMargin: 12
					spacing: 14

					Item {
						Layout.preferredWidth: 46
						Layout.preferredHeight: 46

						AppIcon {
							anchors.fill: parent
							size: 46
							icon: String(root.app.icon || "")
							name: String(root.app.name || "")
							dim: root.missing || root.kind === "loose" || root.progress !== null
						}

						// a little arrow on the icon when there is a newer one
						Rectangle {
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: -4
							width: 20
							height: 20
							radius: 10
							color: Theme.primary
							border.width: 2
							border.color: card.color
							scale: root.app.update && root.progress === null ? 1 : 0
							visible: scale > 0

							Behavior on scale {
								NumberAnimation {
									duration: Motion.extraLong
									easing.type: Easing.OutBack
									easing.overshoot: 2.4
								}
							}

							Glyph {
								anchors.centerIn: parent
								icon: "arrow_up"
								size: 12
								color: Theme.onPrimary
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 3

						RowLayout {
							Layout.fillWidth: true
							spacing: 8

							StyledText {
								Layout.fillWidth: false
								Layout.maximumWidth: top.width * 0.45
								text: String(root.app.name || "")
								font.pixelSize: Theme.size.title
								font.weight: Font.DemiBold
								elide: Text.ElideRight
							}

							StyledText {
								visible: String(root.app.version || "") !== ""
								text: String(root.app.version || "")
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}

							Item {
								Layout.fillWidth: true
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: {
								if (root.progress) {
									const p = root.progress;
									if (p.step === "failed") return p.error || "The update failed";
									if (p.step === "download") {
										if (p.total > 0) return `Downloading ${AppImages.sizeText(p.done)} of ${AppImages.sizeText(p.total)}${p.speed > 0 ? ` · ${AppImages.sizeText(p.speed)}/s` : ""}`;
										return "Getting the update…";
									}
									return "Putting the new one in place…";
								}
								if (root.going) return "Removing…";
								if (root.missing) return "Its file is gone – remove what is left";
								if (root.kind === "foreign") return root.app.present ? "Set up by another tool" : "Set up by another tool – its file is gone";
								if (root.kind === "loose" && root.app.upgrade) return `Newer than the installed ${root.app.upgrade} · in ${String(root.app.folder || "").replace(Paths.home, "~")}`;
								if (root.kind === "loose") return [String(root.app.comment || ""), `in ${String(root.app.folder || "").replace(Paths.home, "~")}`].filter(part => part !== "").join(" · ");
								if (root.app.update) return `${root.app.update.version && root.app.update.version !== "new" ? root.app.update.version : "A new version"} is out${root.app.update.size ? ` · ${AppImages.sizeText(root.app.update.size)}` : ""}`;
								return String(root.app.comment || "");
							}
							tone: root.progress?.step === "failed" || root.missing ? Theme.danger : (root.app.update && !root.progress ? Theme.primary : Theme.textMuted)
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}

						// what is to know at a glance
						Flow {
							Layout.fillWidth: true
							spacing: 6
							visible: root.kind === "installed" || root.kind === "foreign"

							Tag {
								visible: !!root.app.command && root.app.commandPresent !== false
								icon: copied.running ? "check" : "console"
								text: String(root.app.command || "")
								mono: true
								onActivated: {
									AppImages.copyCommand(root.app.command);
									copied.restart();
								}

								Timer {
									id: copied

									interval: 1400
								}
							}

							Tag {
								visible: AppImages.originText(root.app.origin) !== ""
								icon: root.app.origin?.kind === "github" ? "github" : "web"
								text: AppImages.originText(root.app.origin)
							}

							Tag {
								visible: root.app.mode === "unpacked"
								icon: "package_variant"
								text: "Unpacked"
							}

							Tag {
								visible: (root.app.size || 0) > 0
								icon: "harddisk"
								text: AppImages.sizeText(root.app.size)
							}

							Tag {
								visible: !!root.app.running
								icon: "circle_medium"
								text: "Running"
								accent: Theme.success
							}
						}
					}

					// ── what can be done ──────────────────────────────────
					RowLayout {
						spacing: 4

						Item {
							visible: root.progress !== null && root.progress.step !== "failed"
							Layout.preferredWidth: 34
							Layout.preferredHeight: 34

							Ring {
								anchors.fill: parent
								thickness: 3
								value: root.progress && root.progress.progress >= 0 ? root.progress.progress : 0.25
								rotation: root.progress && root.progress.progress < 0 ? spin.value : 0

								QtObject {
									id: spin

									property real value: 0

									NumberAnimation on value {
										running: root.progress !== null && root.progress.progress < 0
										from: 0
										to: 360
										duration: 1100
										loops: Animation.Infinite
									}
								}
							}
						}

						TextButton {
							visible: root.kind === "installed" && !!root.app.update && root.progress === null
							text: "Update"
							icon: "arrow_up_bold_circle_outline"
							variant: "filled"
							onActivated: AppImages.update(root.app.id)
						}

						TextButton {
							visible: root.progress?.step === "failed"
							text: "Try again"
							icon: "refresh"
							onActivated: AppImages.update(root.app.id)
						}

						TextButton {
							visible: root.kind === "loose"
							text: root.app.upgrade ? "Update" : "Install"
							icon: "plus"
							variant: "tonal"
							onActivated: AppImages.install(root.app.file)
						}

						TextButton {
							visible: root.kind === "foreign" && root.app.present === true
							text: "Take over"
							icon: "swap_horizontal"
							variant: "tonal"
							onActivated: AppImages.install(root.app.file)
						}

						IconButton {
							visible: (root.kind === "installed" && !root.missing) || (root.kind === "foreign" && root.app.present)
							icon: "play"
							variant: "tonal"
							onClicked: AppImages.launch(root.kind === "installed" ? root.app : { file: root.app.file, entry: (root.app.entries ?? [])[0] ?? "" })
						}

						IconButton {
							visible: root.kind !== "loose" && root.width > 560
							icon: "folder_outline"
							opacity: top.hovered ? 1 : 0.5
							onClicked: AppImages.reveal(String(root.app.file))

							Behavior on opacity {
								Anim {}
							}
						}

						IconButton {
							icon: "delete_outline"
							variant: root.removal ? "danger" : "ghost"
							checked: !!root.removal
							enabled: !root.going
							opacity: top.hovered || root.removal ? 1 : 0.5
							onClicked: AppImages.askRemove(root.target)

							Behavior on opacity {
								Anim {}
							}
						}
					}
				}
			}

			// ── more of an installed one ──────────────────────────────────
			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: root.details && !root.removal ? more.implicitHeight + 14 : 0
				clip: true
				opacity: root.details && !root.removal ? 1 : 0

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.extraLong
					}
				}
				Behavior on opacity {
					Anim {}
				}

				ColumnLayout {
					id: more

					x: 74
					width: parent.width - 74 - 16
					spacing: 8

					Detail {
						label: "File"
						value: String(root.app.file || "").replace(Paths.home, "~")
					}

					Detail {
						visible: String(root.app.developer || "") !== ""
						label: "Made by"
						value: String(root.app.developer || "")
					}

					Detail {
						label: "Installed"
						value: `${AppImages.ago(root.app.firstInstalledAt || root.app.installedAt)}${root.app.updatedAt ? ` · updated ${AppImages.ago(root.app.updatedAt)}` : ""}`
					}

					Detail {
						label: "Updates"
						value: {
							if (!root.app.origin?.kind) return "Nowhere to look – add a download link";
							const when = root.app.checkedAt ? `looked ${AppImages.ago(root.app.checkedAt)}` : "not looked yet";
							return root.app.checkError ? `${root.app.checkError} (${when})` : `from ${AppImages.originText(root.app.origin)} · ${when}`;
						}
						tone: root.app.checkError ? Theme.warning : Theme.text
					}

					// where its updates come from
					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						Field {
							id: originField

							visible: root.editingOrigin
							Layout.fillWidth: true
							icon: "link_variant"
							placeholder: "A GitHub project or a link to the AppImage"
							onAccepted: {
								AppImages.setOrigin(root.app.id, originField.text.trim());
								root.editingOrigin = false;
							}
							onEscapePressed: root.editingOrigin = false
						}

						TextButton {
							visible: !root.editingOrigin
							text: root.app.origin?.kind ? "Other download link" : "Add a download link"
							icon: "link_variant"
							variant: "ghost"
							onActivated: {
								root.editingOrigin = true;
								originField.text = String(root.app.origin?.url || "");
								originField.focusInput();
							}
						}

						TextButton {
							visible: !root.editingOrigin && !!root.app.origin?.kind
							text: "Look now"
							icon: "refresh"
							variant: "ghost"
							enabled: !AppImages.checking
							onActivated: AppImages.check(root.app.id)
						}

						TextButton {
							visible: root.editingOrigin
							text: "Save"
							variant: "filled"
							onActivated: {
								AppImages.setOrigin(root.app.id, originField.text.trim());
								root.editingOrigin = false;
							}
						}

						Item {
							Layout.fillWidth: !root.editingOrigin
						}
					}
				}
			}

			// ── what removing takes with it ───────────────────────────────
			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: root.removal ? gone.implicitHeight + 16 : 0
				clip: true
				opacity: root.removal ? 1 : 0

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.extraLong
					}
				}
				Behavior on opacity {
					Anim {}
				}

				ColumnLayout {
					id: gone

					x: 16
					width: parent.width - 32
					spacing: 4

					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 1
						color: Theme.outline
						Layout.bottomMargin: 6
					}

					RowLayout {
						visible: root.removal?.loading === true
						spacing: 10

						Spinner {
							Layout.preferredWidth: 16
							Layout.preferredHeight: 16
						}

						StyledText {
							text: "Looking for everything it left…"
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}
					}

					StyledText {
						visible: root.removal && !root.removal.loading
						text: "This goes for good:"
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					Repeater {
						model: root.removal?.items ?? []

						LeftoverRow {
							required property var modelData
							required property int index

							Layout.fillWidth: true
							item: modelData
							order: index
							ticked: modelData.fixed || !root.spared[modelData.path]
							onToggle: {
								const next = Object.assign({}, root.spared);
								if (next[modelData.path]) delete next[modelData.path];
								else next[modelData.path] = true;
								root.spared = next;
							}
						}
					}

					Rectangle {
						visible: (root.removal?.running ?? []).length > 0
						Layout.fillWidth: true
						Layout.topMargin: 4
						implicitHeight: 34
						radius: Theme.radius.medium
						color: Qt.alpha(Theme.warning, 0.12)

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							spacing: 8

							Glyph {
								icon: "alert_outline"
								size: 15
								color: Theme.warning
							}

							StyledText {
								Layout.fillWidth: true
								text: "It is running – it is closed first."
								font.pixelSize: Theme.size.small
							}
						}
					}

					RowLayout {
						Layout.fillWidth: true
						Layout.topMargin: 6
						spacing: 8

						StyledText {
							Layout.fillWidth: true
							visible: root.removal && !root.removal.loading
							text: {
								const items = root.removal?.items ?? [];
								const freed = items.filter(item => item.fixed || !root.spared[item.path]).reduce((sum, item) => sum + (item.size || 0), 0);
								return `Frees ${AppImages.sizeText(freed)}`;
							}
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}

						TextButton {
							text: "Keep it"
							variant: "ghost"
							onActivated: AppImages.cancelRemove()
						}

						TextButton {
							text: "Remove for good"
							icon: "delete_forever_outline"
							variant: "danger"
							confirm: true
							confirmText: "Really remove?"
							enabled: root.removal && !root.removal.loading && !root.removal.error
							onActivated: {
								const data = (root.removal?.items ?? []).filter(item => !item.fixed && !root.spared[item.path]).map(item => item.path);
								AppImages.remove(root.target, data, (root.removal?.running ?? []).length > 0, root.app.name);
							}
						}
					}
				}
			}
		}
	}

	// a small fact on the row
	component Tag: Clickable {
		id: tag

		property string text: ""
		property string icon: ""
		property bool mono: false
		property color accent: Theme.textMuted
		signal activated

		implicitWidth: tagRow.implicitWidth + 14
		implicitHeight: 22
		radius: 11
		color: Qt.alpha(Theme.text, tag.hovered && tag.mono ? 0.1 : 0.05)
		interactive: tag.mono
		sound: ""
		onClicked: tag.activated()

		RowLayout {
			id: tagRow

			anchors.centerIn: parent
			spacing: 5

			Glyph {
				icon: tag.icon
				size: 12
				color: tag.accent
			}

			StyledText {
				text: tag.text
				tone: tag.accent === Theme.textMuted ? Theme.textMuted : tag.accent
				font.pixelSize: Theme.size.tiny
				font.family: tag.mono ? Theme.monoFamily : Theme.fontFamily
			}
		}
	}

	component Detail: RowLayout {
		id: detail

		property string label: ""
		property string value: ""
		property color tone: Theme.text

		Layout.fillWidth: true
		spacing: 12

		StyledText {
			Layout.preferredWidth: 82
			text: detail.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}

		StyledText {
			Layout.fillWidth: true
			text: detail.value
			tone: detail.tone
			font.pixelSize: Theme.size.small
			elide: Text.ElideMiddle
		}
	}
}
