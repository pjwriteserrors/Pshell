pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The install of one AppImage, a card rising over the list: the download
// (from a link), what it is (its icon, name, version, what it says of
// itself), how it goes in (name, command, one file or unpacked), the steps
// ticking off one by one, and done – or what went wrong.
Item {
	id: root

	readonly property var c: AppImages.candidate
	readonly property bool open: root.c !== null
	readonly property string stage: root.c?.stage ?? ""
	readonly property var look: root.c?.look ?? null
	// what the card last showed, kept while it goes away
	property var shownLook: null
	signal closed

	onLookChanged: if (root.look) root.shownLook = root.look
	// a GitHub project's picture while its AppImage is still on the way
	readonly property string placeholder: {
		const match = /^https?:\/\/(?:www\.)?github\.com\/([^/]+)/i.exec(String(root.c?.url ?? ""));
		return match ? `https://github.com/${match[1]}.png?size=160` : "";
	}
	onStageChanged: {
		if (root.stage === "fetching" || root.stage === "inspecting") root.shownLook = null;
		if (root.stage === "ready") {
			name.text = String(root.c.name || "");
			command.text = String(root.c.command || "");
			Qt.callLater(() => install.forceActiveFocus());
			iconPop.restart();
		}
		if (root.stage === "done") burst.restart();
		if (root.stage === "failed") shake.restart();
		if (root.stage === "") root.closed();
	}

	visible: scrim.opacity > 0
	enabled: root.open
	// the keys come here while it is up (Escape, Enter)
	onOpenChanged: if (root.open) root.forceActiveFocus()

	Keys.onEscapePressed: AppImages.back()
	Keys.onReturnPressed: root.primary()
	Keys.onEnterPressed: root.primary()

	function primary() {
		if (root.stage === "ready" && AppImages.commandCheck.ok !== false) AppImages.confirmInstall();
		else if (root.stage === "done" || root.stage === "failed") AppImages.dismiss();
	}

	// ── the dark behind ────────────────────────────────────────────────────
	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.open ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: root.open ? Motion.long : Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			enabled: root.open
			onClicked: if (root.stage !== "installing") AppImages.dismiss()
		}
	}

	// ── the card ───────────────────────────────────────────────────────────
	Rectangle {
		id: card

		anchors.horizontalCenter: parent.horizontalCenter
		width: Math.min(parent.width - 32, 560)
		height: Math.min(parent.height - 40, content.implicitHeight + 48)
		y: root.open ? (parent.height - height) / 2 : parent.height + 20
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		scale: root.open ? 1 : 0.94
		opacity: root.open ? 1 : 0
		clip: true
		transform: Translate {
			id: shakeShift
		}

		Behavior on y {
			SpatialAnim {
				duration: root.open ? Motion.extraLong : Motion.long
				easing.bezierCurve: root.open ? Motion.spatial : Motion.accel
			}
		}
		Behavior on height {
			SpatialAnim {
				duration: Motion.extraLong
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.extraLong
			}
		}
		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
		}

		// the app's own colour, faint, from the top
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			height: 180
			opacity: root.stage === "done" ? 1 : 0.6
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.alpha(root.stage === "failed" ? Theme.danger : Theme.primary, 0.16)
				}
				GradientStop {
					position: 1
					color: "transparent"
				}
			}

			Behavior on opacity {
				Anim {
					duration: Motion.extraLong
				}
			}
		}

		SequentialAnimation {
			id: shake

			NumberAnimation {
				target: shakeShift
				property: "x"
				to: -10
				duration: 50
			}
			NumberAnimation {
				target: shakeShift
				property: "x"
				to: 9
				duration: 70
			}
			NumberAnimation {
				target: shakeShift
				property: "x"
				to: -5
				duration: 60
			}
			NumberAnimation {
				target: shakeShift
				property: "x"
				to: 0
				duration: 90
			}
		}

		Flickable {
			anchors.fill: parent
			anchors.margins: 24
			contentHeight: content.implicitHeight
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			interactive: contentHeight > height

			ColumnLayout {
				id: content

				width: parent.width
				spacing: 16

				// ── who it is ─────────────────────────────────────────────
				RowLayout {
					Layout.fillWidth: true
					spacing: 16

					Item {
						Layout.preferredWidth: 76
						Layout.preferredHeight: 76

						// going round while it is fetched or looked into
						Ring {
							anchors.fill: parent
							anchors.margins: -6
							visible: opacity > 0
							opacity: ["fetching", "inspecting", "installing"].includes(root.stage) ? 1 : 0
							thickness: 3
							value: root.stage === "fetching" && (root.c?.progress ?? -1) >= 0 ? root.c.progress : (root.stage === "installing" ? root.installProgress : 0.22)
							rotation: (root.stage === "fetching" && (root.c?.progress ?? -1) < 0) || root.stage === "inspecting" ? turn.value : 0

							Behavior on opacity {
								Anim {}
							}

							QtObject {
								id: turn

								property real value: 0

								NumberAnimation on value {
									running: root.open && (root.stage === "fetching" || root.stage === "inspecting")
									from: 0
									to: 360
									duration: 1000
									loops: Animation.Infinite
								}
							}
						}

						AppIcon {
							id: bigIcon

							anchors.fill: parent
							size: 76
							icon: String(root.shownLook?.icon || root.placeholder)
							name: String(root.shownLook?.name || "")
							dim: root.stage === "fetching" || root.stage === "inspecting"
						}

						// the burst when it is in
						Repeater {
							model: 8

							Rectangle {
								id: spark

								required property int index
								property real travel: 0

								x: parent.width / 2 - 3 + Math.cos(spark.index / 8 * Math.PI * 2) * spark.travel
								y: parent.height / 2 - 3 + Math.sin(spark.index / 8 * Math.PI * 2) * spark.travel
								width: 6
								height: 6
								radius: 3
								color: spark.index % 2 === 0 ? Theme.primary : Theme.secondary
								opacity: spark.travel > 0 ? Math.max(0, 1 - (spark.travel - 30) / 30) : 0

								Connections {
									target: burst

									function onStarted() {
										spark.travel = 0;
										fly.restart();
									}
								}

								NumberAnimation {
									id: fly

									target: spark
									property: "travel"
									from: 20
									to: 62
									duration: 700
									easing.type: Easing.OutCubic
								}
							}
						}

						// a tick on the icon
						Rectangle {
							id: tick

							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: -6
							width: 28
							height: 28
							radius: 14
							color: root.stage === "failed" ? Theme.danger : Theme.success
							border.width: 3
							border.color: card.color
							scale: root.stage === "done" || root.stage === "failed" ? 1 : 0
							visible: scale > 0

							Behavior on scale {
								NumberAnimation {
									duration: Motion.extraLong
									easing.type: Easing.OutBack
									easing.overshoot: 2.6
								}
							}

							Glyph {
								anchors.centerIn: parent
								icon: root.stage === "failed" ? "close" : "check"
								size: 16
								color: Theme.bg
							}
						}

						SequentialAnimation {
							id: iconPop

							NumberAnimation {
								target: bigIcon
								property: "scale"
								from: 0.7
								to: 1
								duration: Motion.extraLong
								easing.type: Easing.OutBack
								easing.overshoot: 1.6
							}
						}

						SequentialAnimation {
							id: burst

							NumberAnimation {
								target: bigIcon
								property: "scale"
								from: 1
								to: 1.12
								duration: Motion.short
								easing.type: Easing.OutCubic
							}
							NumberAnimation {
								target: bigIcon
								property: "scale"
								to: 1
								duration: Motion.extraLong
								easing.type: Easing.OutBack
								easing.overshoot: 2
							}
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 3

						StyledText {
							Layout.fillWidth: true
							text: {
								switch (root.stage) {
								case "fetching": return root.c?.step === "resolve" ? "Finding the newest…" : "Downloading…";
								case "inspecting": return "Looking into it…";
								case "installing": return `Installing ${root.c?.name ?? ""}…`;
								case "done": return root.c?.app?.updated ? `${root.c.app.name} is updated` : `${root.c?.app?.name ?? ""} is installed`;
								case "failed": return "That did not work";
								default: return root.shownLook?.name ?? "";
								}
							}
							font.pixelSize: Theme.size.heading
							font.weight: Font.DemiBold
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: {
								const l = root.shownLook;
								if (root.stage === "fetching") {
									const c = root.c;
									if (c?.total > 0) return `${AppImages.sizeText(c.done)} of ${AppImages.sizeText(c.total)}${c.speed > 0 ? `  ·  ${AppImages.sizeText(c.speed)}/s` : ""}`;
									return String(c?.url || "").replace(/^https?:\/\//, "");
								}
								if (root.stage === "failed") return root.c?.error ?? "";
								if (root.stage === "done") return `In the launcher${root.c?.app?.command ? `, and as ${root.c.app.command} in a terminal` : ""}`;
								if (!l) return "";
								return [l.version ? `Version ${l.version}` : "", l.developer, AppImages.sizeText(l.size)].filter(part => part).join("  ·  ");
							}
							tone: root.stage === "failed" ? Theme.danger : Theme.textMuted
							font.pixelSize: Theme.size.small
							wrapMode: Text.Wrap
							maximumLineCount: 3
							elide: Text.ElideRight
						}
					}
				}

				// ── the download ──────────────────────────────────────────
				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: 6
					visible: root.stage === "fetching"
					radius: 3
					color: Theme.layer3

					Rectangle {
						height: parent.height
						radius: 3
						color: Theme.primary
						width: (root.c?.progress ?? -1) >= 0 ? parent.width * root.c.progress : parent.width * 0.3
						x: (root.c?.progress ?? -1) >= 0 ? 0 : (parent.width - width) * sweep.value

						Behavior on width {
							SpatialAnim {}
						}

						QtObject {
							id: sweep

							property real value: 0

							SequentialAnimation on value {
								running: root.stage === "fetching" && (root.c?.progress ?? -1) < 0
								loops: Animation.Infinite

								NumberAnimation {
									to: 1
									duration: 800
									easing.type: Easing.InOutSine
								}
								NumberAnimation {
									to: 0
									duration: 800
									easing.type: Easing.InOutSine
								}
							}
						}
					}
				}

				// ── what it says of itself ───────────────────────────────
				StyledText {
					Layout.fillWidth: true
					visible: root.stage === "ready" && text !== ""
					text: String(root.shownLook?.description || root.shownLook?.comment || "")
					wrapMode: Text.Wrap
					maximumLineCount: descriptionOpen ? 30 : 3
					elide: Text.ElideRight
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					property bool descriptionOpen: false

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: parent.descriptionOpen = !parent.descriptionOpen
					}
				}

				// already there: this one replaces it
				Note {
					visible: root.stage === "ready" && !!root.c?.already
					icon: "arrow_up_bold_circle_outline"
					tone: Theme.primary
					text: root.c?.already ? `${root.c.already.version || "A version"} is installed – this one takes its place, the command and entry stay.` : ""
				}

				Note {
					visible: root.stage === "ready" && root.shownLook?.hasEntry === false
					icon: "information_outline"
					tone: Theme.warning
					text: "It brings no app entry of its own; one is written from its name."
				}

				// ── how it goes in ────────────────────────────────────────
				GridLayout {
					Layout.fillWidth: true
					visible: root.stage === "ready"
					columns: 2
					columnSpacing: 14
					rowSpacing: 10

					StyledText {
						text: "Name"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					Field {
						id: name

						Layout.fillWidth: true
						icon: "pencil_outline"
						placeholder: root.shownLook?.name ?? ""
						onEdited: text => AppImages.change({ name: text })
						onAccepted: root.primary()
						onEscapePressed: AppImages.dismiss()
					}

					StyledText {
						Layout.alignment: Qt.AlignTop
						Layout.topMargin: 10
						text: "Command"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 4

						Field {
							id: command

							Layout.fillWidth: true
							icon: "console"
							placeholder: "None – only in the launcher"
							onEdited: text => {
								AppImages.change({ command: text });
								checkLater.restart();
							}
							onAccepted: root.primary()
							onEscapePressed: AppImages.dismiss()

							Timer {
								id: checkLater

								interval: 220
								onTriggered: AppImages.checkCommand(command.text)
							}
						}

						RowLayout {
							spacing: 6

							Glyph {
								icon: AppImages.commandCheck.ok === false ? "alert_circle_outline" : (command.text.trim() === "" ? "minus_circle_outline" : "check_circle_outline")
								size: 13
								color: AppImages.commandCheck.ok === false ? Theme.danger : (command.text.trim() === "" ? Theme.textSubtle : Theme.success)
							}

							StyledText {
								Layout.fillWidth: true
								text: {
									const check = AppImages.commandCheck;
									const name = command.text.trim();
									if (name === "") return "No command";
									if (check.reason === "invalid") return "Letters, digits and . _ + - only";
									if (check.reason === "taken") return `Taken by ${String(check.path).replace(Paths.home, "~")}`;
									if (check.reason === "app") return `Another AppImage has it (${check.owner})`;
									if (check.reason === "same") return `${name} stays its command`;
									return `${name} starts it in a terminal`;
								}
								tone: AppImages.commandCheck.ok === false ? Theme.danger : Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								elide: Text.ElideRight
							}

							// taken: a name beside it that is free
							Clickable {
								id: freeName

								readonly property string other: `${command.text.trim()}-appimage`

								visible: AppImages.commandCheck.reason === "taken" || AppImages.commandCheck.reason === "app"
								implicitWidth: otherText.implicitWidth + 16
								implicitHeight: 20
								radius: 10
								color: Theme.primarySoft
								onClicked: {
									command.text = freeName.other;
									AppImages.change({ command: freeName.other });
									AppImages.checkCommand(freeName.other);
								}

								StyledText {
									id: otherText

									anchors.centerIn: parent
									text: `Use ${freeName.other}`
									tone: Theme.primary
									font.pixelSize: Theme.size.tiny
									font.weight: Font.DemiBold
								}
							}
						}
					}

					StyledText {
						text: "As"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 4

						Segmented {
							Layout.fillWidth: true
							options: [
								{ value: "file", label: "One file", icon: "file_outline" },
								{ value: "unpacked", label: "Unpacked", icon: "package_variant" }
							]
							current: String(root.c?.mode ?? "file")
							onSelected: value => AppImages.change({ mode: value })
						}

						StyledText {
							Layout.fillWidth: true
							text: root.c?.mode === "unpacked" ? "Unpacked into a folder: starts faster and needs no FUSE, takes more room." : "Kept as it is in ~/Applications and started from there."
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
							wrapMode: Text.Wrap
						}
					}

					StyledText {
						visible: !root.c?.origin
						text: "Original"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					RowLayout {
						visible: !root.c?.origin
						spacing: 10

						Toggle {
							checked: !!root.c?.keep
							onToggled: on => AppImages.change({ keep: on })
						}

						StyledText {
							Layout.fillWidth: true
							text: root.c?.keep ? `Stays in ${String(root.c?.path ?? "").replace(/\/[^/]*$/, "").replace(Paths.home, "~")}` : "Moved, not copied"
							font.pixelSize: Theme.size.small
							elide: Text.ElideMiddle
						}
					}

					StyledText {
						text: "Updates"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					RowLayout {
						spacing: 8

						Glyph {
							icon: root.c?.origin?.kind === "github" ? "github" : (root.c?.origin ? "web" : "update")
							size: 15
							color: root.c?.origin || root.c?.look?.updateInfo ? Theme.primary : Theme.textSubtle
						}

						StyledText {
							Layout.fillWidth: true
							text: {
								if (root.c?.origin) return `Looked for at ${AppImages.originText(root.c.origin)}`;
								const info = String(root.c?.look?.updateInfo ?? "");
								if (info.startsWith("gh-releases")) return `Looked for on GitHub (${info.split("|").slice(1, 3).join("/")}), as it says itself`;
								if (info !== "") return "Looked for where it says itself";
								return "It does not say where – add a download link later";
							}
							font.pixelSize: Theme.size.small
							wrapMode: Text.Wrap
						}
					}
				}

				// ── the steps ─────────────────────────────────────────────
				ColumnLayout {
					Layout.fillWidth: true
					visible: root.stage === "installing" || root.stage === "done"
					spacing: 2

					Repeater {
						model: AppImages.steps.filter(step => step.id !== "download" && (step.id !== "command" || String(root.c?.command ?? "").trim() !== ""))

						StepRow {
							required property var modelData
							required property int index

							Layout.fillWidth: true
							label: modelData.id === "copy" && root.c?.mode === "unpacked" ? "Unpack" : modelData.label
							phase: root.stepState(modelData.id)
							progress: modelData.id === root.c?.step ? (root.c?.progress ?? 0) : 0
							order: index
						}
					}
				}

				// ── the buttons ───────────────────────────────────────────
				RowLayout {
					Layout.fillWidth: true
					Layout.topMargin: 4
					spacing: 8

					StyledText {
						Layout.fillWidth: true
						visible: AppImages.waiting.length > 0
						text: AppImages.waiting.length === 1 ? "1 more waits" : `${AppImages.waiting.length} more wait`
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					Item {
						visible: AppImages.waiting.length === 0
						Layout.fillWidth: true
					}

					TextButton {
						visible: root.stage !== "installing" && root.stage !== "done"
						text: "Cancel"
						variant: "ghost"
						onActivated: AppImages.dismiss()
					}

					TextButton {
						visible: root.stage === "failed" && !!root.c && (root.c.url !== "" || root.c.path !== "")
						text: "Try again"
						icon: "refresh"
						onActivated: {
							const again = root.c.url || root.c.path;
							AppImages.candidate = null;
							AppImages.install(again);
						}
					}

					TextButton {
						visible: root.stage === "done"
						text: "Start it"
						icon: "play"
						onActivated: {
							AppImages.launch(root.c.app);
							AppImages.dismiss();
						}
					}

					TextButton {
						id: install

						visible: root.stage === "ready" || root.stage === "installing" || root.stage === "done"
						text: root.stage === "done" ? (AppImages.waiting.length > 0 ? "Next" : "Done") : (root.c?.already ? "Update" : "Install")
						icon: root.stage === "done" ? "check" : "download"
						variant: "filled"
						busy: root.stage === "installing"
						enabled: root.stage !== "ready" || AppImages.commandCheck.ok !== false
						onActivated: root.primary()
					}
				}
			}
		}
	}

	readonly property real installProgress: {
		const order = ["check", "copy", "icon", "entry", "command"];
		const at = order.indexOf(root.c?.step ?? "check");
		return Math.max(0, Math.min(1, (Math.max(0, at) + (root.c?.progress ?? 0)) / order.length));
	}

	// "waiting" | "working" | "done"
	function stepState(id) {
		if (root.stage === "done") return "done";
		const order = ["check", "copy", "icon", "entry", "command"];
		const now = order.indexOf(root.c?.step ?? "");
		const mine = order.indexOf(id);
		if (mine < now || (mine === now && (root.c?.progress ?? 0) >= 1)) return "done";
		if (mine === now || (now < 0 && mine === 0)) return "working";
		return "waiting";
	}

	component Note: Rectangle {
		id: note

		property string icon: ""
		property string text: ""
		property color tone: Theme.primary

		Layout.fillWidth: true
		implicitHeight: noteText.implicitHeight + 18
		radius: Theme.radius.medium
		color: Qt.alpha(note.tone, 0.1)

		RowLayout {
			anchors.fill: parent
			anchors.margins: 9
			anchors.leftMargin: 12
			spacing: 10

			Glyph {
				icon: note.icon
				size: 16
				color: note.tone
			}

			StyledText {
				id: noteText

				Layout.fillWidth: true
				text: note.text
				wrapMode: Text.Wrap
				font.pixelSize: Theme.size.small
			}
		}
	}
}
