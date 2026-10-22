pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// An identity to sign up with, as a profile: its cover with what it is for,
// its face and name, and under them what a form asks for, each with a
// button to copy it (the picture too). Beside it what its mailbox and number
// receive. The list holds the saved ones. Under the bar (IdentityPanel.qml) or
// in a window of its own (IdentityWindow.qml).
Item {
	id: root

	readonly property var identity: Identities.current
	readonly property bool making: root.identity !== null && Identities.creatingId === root.identity.id
	readonly property bool listed: Identities.view === "list" || root.identity === null && Identities.saved.length > 0 && !Identities.failed

	// which colours its cover wears
	readonly property int shade: {
		let sum = 0;
		for (const letter of root.shownId) sum += letter.charCodeAt(0);
		return sum;
	}
	// "38 · Wegeleben, Germany"
	readonly property string about: {
		if (!root.identity?.birthday) return "";
		const born = new Date(root.identity.birthday);
		const now = new Date();
		const age = now.getFullYear() - born.getFullYear() - (now.getMonth() < born.getMonth() || now.getMonth() === born.getMonth() && now.getDate() < born.getDate() ? 1 : 0);
		return [String(age), [root.identity.city, root.identity.country].filter(part => part).join(", ")].filter(part => part !== "").join(" · ");
	}

	function waits(part) {
		return root.making && Identities.pending[part] === true;
	}

	// another identity: the title is its own, the card comes in anew
	readonly property string shownId: root.identity?.id ?? ""
	onShownIdChanged: {
		title.text = root.identity?.title ?? "";
		arrive.restart();
	}

	Component.onCompleted: title.text = root.identity?.title ?? ""

	RowLayout {
		id: header

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 8

		IconButton {
			icon: root.listed ? "arrow_left" : "account_multiple"
			variant: "tonal"
			visible: root.listed ? root.identity !== null : Identities.saved.length > 0
			onClicked: Identities.view = root.listed ? "card" : "list"
		}

		StyledText {
			Layout.fillWidth: true
			text: root.listed ? "Identities" : ""
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}

		TextButton {
			text: "New"
			icon: "plus"
			variant: "filled"
			busy: Identities.creating
			onActivated: Identities.create()
		}

		// into a window of its own, and back under the bar
		IconButton {
			icon: Identities.windowed ? "arrow_collapse_all" : "open_in_new"
			variant: "tonal"
			onClicked: Identities.windowed ? Identities.dock() : Identities.popOut()
		}
	}

	Item {
		anchors.top: header.bottom
		anchors.topMargin: 14
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		clip: true

		// ── the saved ones ────────────────────────────────────────────────
		IdentityList {
			width: parent.width
			height: parent.height
			visible: opacity > 0.01
			opacity: root.listed ? 1 : 0
			x: root.listed ? 0 : -28

			Behavior on opacity {
				Anim {}
			}
			Behavior on x {
				SpatialAnim {}
			}
		}

		// ── nobody yet ────────────────────────────────────────────────────
		EmptyState {
			anchors.centerIn: parent
			visible: !root.listed && root.identity === null
			icon: Identities.failed ? "alert_circle" : "account_circle"
			title: Identities.failed ? "Could not create an identity" : "No identity"
		}

		// ── one of them ───────────────────────────────────────────────────
		RowLayout {
			id: card

			width: parent.width
			height: parent.height
			spacing: 22
			visible: opacity > 0.01 && root.identity !== null
			opacity: root.listed ? 0 : 1
			x: root.listed ? 28 : 0

			Behavior on opacity {
				Anim {}
			}
			Behavior on x {
				SpatialAnim {}
			}

			ParallelAnimation {
				id: arrive

				Anim {
					target: card
					property: "opacity"
					from: 0
					to: 1
				}
				SpatialAnim {
					target: card
					property: "scale"
					from: 0.97
					to: 1
					duration: Motion.medium
				}
			}

			ColumnLayout {
				Layout.preferredWidth: 360
				Layout.maximumWidth: 360
				Layout.fillHeight: true
				spacing: 6

				// ── who it is ─────────────────────────────────────────────
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 142

					// the cover, in colours of its own for every identity
					Rectangle {
						id: cover

						readonly property var hues: [Theme.primary, Theme.secondary, Theme.tertiary]

						width: parent.width
						height: 92
						radius: Theme.radius.large
						clip: true
						gradient: Gradient {
							orientation: Gradient.Horizontal

							GradientStop {
								position: 0
								color: Qt.tint(Theme.bg, Qt.alpha(cover.hues[root.shade % 3], 0.6))

								Behavior on color {
									ColorAnim {
										duration: Motion.long
									}
								}
							}
							GradientStop {
								position: 1
								color: Qt.tint(Theme.bg, Qt.alpha(cover.hues[(root.shade + 1) % 3], 0.32))

								Behavior on color {
									ColorAnim {
										duration: Motion.long
									}
								}
							}
						}

						Rectangle {
							x: parent.width - 150
							y: -70
							width: 220
							height: 220
							radius: 110
							color: Qt.alpha(Theme.fg, 0.05)
						}

						Rectangle {
							x: parent.width - 250
							y: 30
							width: 130
							height: 130
							radius: 65
							color: Qt.alpha(Theme.fg, 0.04)
						}
					}

					// what it is for; Enter keeps it
					Rectangle {
						x: 10
						y: 10
						width: parent.width - 60
						height: 32
						radius: 16
						color: Qt.alpha(Theme.bg, title.activeFocus ? 0.7 : 0.42)

						Behavior on color {
							ColorAnim {}
						}

						Glyph {
							x: 11
							anchors.verticalCenter: parent.verticalCenter
							icon: "tag_outline"
							size: 15
							color: title.activeFocus ? Theme.primary : Theme.textMuted
						}

						TextInput {
							id: title

							anchors.fill: parent
							anchors.leftMargin: 34
							anchors.rightMargin: 12
							verticalAlignment: TextInput.AlignVCenter
							color: Theme.text
							selectionColor: Qt.alpha(Theme.primary, 0.4)
							selectedTextColor: Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
							selectByMouse: true
							clip: true
							onTextEdited: Identities.setTitle(root.identity.id, text)
							onAccepted: {
								Identities.setSaved(root.identity.id, true);
								title.focus = false;
							}

							StyledText {
								anchors.fill: parent
								visible: title.text === ""
								text: "Title"
								tone: Theme.textSubtle
							}
						}
					}

					IconButton {
						x: parent.width - width - 10
						y: 9
						icon: "bookmark_outline"
						variant: "tonal"
						color: checked ? Theme.primary : Qt.alpha(Theme.bg, 0.42)
						checked: root.identity?.saved === true
						enabled: !root.making
						onClicked: Identities.setSaved(root.identity.id, !checked)
					}

					// the face, half on the cover
					Rectangle {
						x: 14
						y: 48
						width: 92
						height: 92
						radius: 46
						color: Theme.base

						Portrait {
							id: portrait

							property bool copied: false

							anchors.fill: parent
							anchors.margins: 4
							source: root.identity?.picture ?? ""
							name: Identities.name(root.identity)
							pending: root.waits("person")

							Timer {
								id: forget

								interval: 1300
								onTriggered: portrait.copied = false
							}

							// the picture itself goes to the clipboard
							IconButton {
								x: parent.width - width + 4
								y: parent.height - height + 4
								implicitWidth: 28
								implicitHeight: 28
								variant: "tonal"
								color: Theme.layer3
								icon: portrait.copied ? "check" : "content_copy"
								iconSize: 13
								iconColor: portrait.copied ? Theme.success : Theme.text
								visible: portrait.loaded
								onClicked: {
									Identities.copyPicture(root.identity);
									portrait.copied = true;
									forget.restart();
								}
							}
						}
					}

					ColumnLayout {
						x: 120
						y: 97
						width: parent.width - 124
						spacing: 0

						Reveal {
							Layout.fillWidth: true
							text: Identities.name(root.identity)
							pending: root.waits("person")
							placeholder: 170
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
						}

						Reveal {
							Layout.fillWidth: true
							text: root.about
							pending: root.waits("person")
							placeholder: 120
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
						}
					}
				}

				SectionLabel {
					Layout.topMargin: 8
					Layout.leftMargin: 4
					text: "Account"
				}

				DataTile {
					Layout.fillWidth: true
					label: "Email"
					value: root.identity?.mail?.address ?? ""
					pending: root.waits("mail")
					renewable: true
					gone: root.identity?.mail?.gone === true
					renewing: Identities.renewing[`${root.identity?.id}:mail`] === true
					onRenew: Identities.renew(root.identity.id, "mail")
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "Username"
						value: root.identity?.username ?? ""
						pending: root.waits("person")
					}

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "Password"
						value: root.identity?.password ?? ""
						pending: root.waits("person")
						mono: true
					}
				}

				DataTile {
					Layout.fillWidth: true
					label: "Phone"
					value: root.identity?.phone?.number ?? ""
					pending: root.waits("phone")
					renewable: true
					gone: root.identity?.phone?.gone === true
					renewing: Identities.renewing[`${root.identity?.id}:phone`] === true
					onRenew: Identities.renew(root.identity.id, "phone")
				}

				SectionLabel {
					Layout.topMargin: 8
					Layout.leftMargin: 4
					text: "Personal"
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "First name"
						value: root.identity?.first ?? ""
						pending: root.waits("person")
					}

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "Last name"
						value: root.identity?.last ?? ""
						pending: root.waits("person")
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "Birthday"
						value: root.identity?.birthday ? Qt.formatDate(new Date(root.identity.birthday), "dd.MM.yyyy") : ""
						pending: root.waits("person")
					}

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "Street"
						value: root.identity?.street ?? ""
						pending: root.waits("person")
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "Postcode"
						value: root.identity?.postcode ?? ""
						pending: root.waits("person")
					}

					DataTile {
						Layout.fillWidth: true
						Layout.preferredWidth: 1
						label: "City"
						value: root.identity?.city ?? ""
						pending: root.waits("person")
					}
				}

				Item {
					Layout.fillHeight: true
				}
			}

			Inbox {
				Layout.fillWidth: true
				Layout.fillHeight: true
				identity: root.identity
			}
		}
	}
}
