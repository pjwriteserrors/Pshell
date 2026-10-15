import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets

// A game's cover, 2:3. Without a cover of its own the wide header stands
// on a blur of itself with the name under it; without any picture the
// name is set on colours of its own, the same for a name every time.
Item {
	id: root

	property var game: null
	property real radius: Theme.radius.medium
	// where a light falls on it, -1…1 (follows the pointer on a tilted card)
	property point light: Qt.point(0, -1)
	property real sheen: 0

	readonly property string cover: root.game?.art?.cover ?? ""
	readonly property string header: root.game?.art?.header ?? ""
	readonly property string name: root.game?.name ?? ""
	readonly property real hue: {
		let hash = 0;
		for (let i = 0; i < root.name.length; i++) hash = (hash * 31 + root.name.charCodeAt(i)) % 3600;
		return hash / 3600;
	}
	readonly property bool ready: coverImage.status === Image.Ready || (root.cover === "" && (root.header === "" || headerImage.status === Image.Ready))

	function fileUrl(path) {
		return path ? (path.startsWith("/") ? `file://${path}` : path) : "";
	}

	Rounded {
		anchors.fill: parent
		radius: root.radius

		// the name's own colours, under everything (and while a picture loads)
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.hsva(root.hue, 0.55, 0.42, 1)
				}
				GradientStop {
					position: 1
					color: Qt.hsva((root.hue + 0.12) % 1, 0.7, 0.16, 1)
				}
			}
		}

		// ── no picture at all ──────────────────────────────────────────────
		Item {
			anchors.fill: parent
			visible: root.cover === "" && root.header === ""

			StyledText {
				anchors.centerIn: parent
				anchors.verticalCenterOffset: -parent.height * 0.08
				text: root.name.split(/\s+/).filter(word => /^[A-Za-z0-9]/.test(word)).slice(0, 2).map(word => word[0].toUpperCase()).join("")
				tone: Qt.rgba(1, 1, 1, 0.16)
				surface: "transparent"
				font.pixelSize: parent.width * 0.42
				font.weight: Font.Black
			}

			StyledText {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: parent.width * 0.08
				text: root.name
				tone: "white"
				surface: "transparent"
				wrapMode: Text.WordWrap
				maximumLineCount: 3
				elide: Text.ElideRight
				font.pixelSize: Math.max(12, parent.width * 0.09)
				font.weight: Font.Bold
			}
		}

		// ── only a wide picture ────────────────────────────────────────────
		Item {
			anchors.fill: parent
			visible: root.cover === "" && root.header !== ""

			Image {
				id: headerBlur

				anchors.fill: parent
				source: headerImage.source
				fillMode: Image.PreserveAspectCrop
				asynchronous: true
				sourceSize.height: 120
				visible: false
			}

			MultiEffect {
				anchors.fill: parent
				source: headerBlur
				blurEnabled: true
				blurMax: 48
				blur: 1
				brightness: -0.2
				saturation: 0.2
			}

			Image {
				id: headerImage

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: -parent.height * 0.08
				height: width * 215 / 460
				source: root.cover === "" ? root.fileUrl(root.header) : ""
				fillMode: Image.PreserveAspectCrop
				asynchronous: true
				sourceSize.width: 460
				opacity: status === Image.Ready ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}
			}

			StyledText {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: parent.width * 0.08
				text: root.name
				tone: "white"
				surface: "transparent"
				wrapMode: Text.WordWrap
				maximumLineCount: 2
				elide: Text.ElideRight
				font.pixelSize: Math.max(12, parent.width * 0.08)
				font.weight: Font.Bold
			}
		}

		// ── the cover ──────────────────────────────────────────────────────
		Image {
			id: coverImage

			anchors.fill: parent
			source: root.fileUrl(root.cover)
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			cache: true
			sourceSize.width: 600
			opacity: status === Image.Ready ? 1 : 0
			scale: status === Image.Ready ? 1 : 1.06

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}
			Behavior on scale {
				Anim {
					duration: Motion.extraLong
				}
			}
		}

		// a soft light that follows the tilt
		Rectangle {
			anchors.fill: parent
			opacity: root.sheen
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: Math.max(0, Math.min(0.9, 0.5 + root.light.x * 0.45 - 0.35))
					color: Qt.rgba(1, 1, 1, 0)
				}
				GradientStop {
					position: Math.max(0.05, Math.min(0.95, 0.5 + root.light.x * 0.45))
					color: Qt.rgba(1, 1, 1, 0.22)
				}
				GradientStop {
					position: Math.max(0.1, Math.min(1, 0.5 + root.light.x * 0.45 + 0.35))
					color: Qt.rgba(1, 1, 1, 0)
				}
			}
		}

		// a hairline that keeps dark covers apart from a dark backdrop
		Rectangle {
			anchors.fill: parent
			color: "transparent"
			radius: root.radius
			border.width: 1
			border.color: Qt.rgba(1, 1, 1, 0.08)
		}
	}
}
