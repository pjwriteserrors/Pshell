import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A download link to install from: a GitHub project or release, or any link
// to an AppImage. Its updates are then looked for there. What is typed that
// is no link shakes the field.
Rectangle {
	id: root

	readonly property bool isLink: AppImages.isLink(field.text)
	readonly property string kind: {
		const text = field.text.trim();
		if (!root.isLink) return "";
		if (/^https?:\/\/(www\.)?github\.com\/[^/]+\/[^/]+/i.test(text)) return /\/releases\/(download|latest\/download)\//.test(text) ? "a release of GitHub" : "the newest release on GitHub";
		return "a link, watched for changes";
	}

	function focusInput() {
		field.focusInput();
	}

	function go() {
		if (!root.isLink) {
			shake.restart();
			Sounds.play("error");
			return;
		}
		AppImages.install(field.text.trim());
		field.text = "";
	}

	implicitHeight: 52
	radius: Theme.radius.large
	color: field.focused ? Theme.layer2 : Theme.layer1
	border.width: 1
	border.color: field.focused ? "transparent" : Theme.outline
	transform: Translate {
		id: nudge
	}

	Behavior on color {
		ColorAnim {}
	}
	Behavior on border.color {
		ColorAnim {}
	}

	SequentialAnimation {
		id: shake

		NumberAnimation {
			target: nudge
			property: "x"
			to: -8
			duration: 50
		}
		NumberAnimation {
			target: nudge
			property: "x"
			to: 7
			duration: 70
		}
		NumberAnimation {
			target: nudge
			property: "x"
			to: -4
			duration: 60
		}
		NumberAnimation {
			target: nudge
			property: "x"
			to: 0
			duration: 80
		}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 6
		anchors.rightMargin: 8
		spacing: 6

		Field {
			id: field

			Layout.fillWidth: true
			icon: root.isLink ? "link_variant" : "download_outline"
			placeholder: "Paste a download link – a GitHub project, a release, or any link to an AppImage"
			color: "transparent"
			onAccepted: root.go()
			onEscapePressed: field.text !== "" ? field.text = "" : AppImages.back()
		}

		StyledText {
			visible: opacity > 0
			opacity: root.kind !== "" && root.width > 560 ? 1 : 0
			text: root.kind
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.tiny

			Behavior on opacity {
				Anim {}
			}
		}

		// slides in once there is a link
		Item {
			Layout.preferredWidth: root.isLink ? install.implicitWidth : 0
			Layout.preferredHeight: install.implicitHeight
			clip: true

			Behavior on Layout.preferredWidth {
				SpatialAnim {}
			}

			TextButton {
				id: install

				x: root.isLink ? 0 : 30
				opacity: root.isLink ? 1 : 0
				text: "Get it"
				icon: "download"
				variant: "filled"
				onActivated: root.go()

				Behavior on x {
					SpatialAnim {}
				}
				Behavior on opacity {
					Anim {}
				}
			}
		}
	}
}
