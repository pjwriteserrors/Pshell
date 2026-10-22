import QtQuick
import qs.style.theme
import qs.style.widgets

// Files dragged over a chat: the whole pane takes them and says so.
DropArea {
	id: root

	signal files(var paths)

	keys: ["text/uri-list"]
	onDropped: event => {
		root.files(event.urls.map(url => String(url)));
		event.accept();
	}

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		color: Qt.alpha(Theme.primary, 0.1)
		border.width: 2
		border.color: Theme.primary
		opacity: root.containsDrag ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		Rectangle {
			anchors.centerIn: parent
			width: 64
			height: 64
			radius: 32
			color: Theme.primary
			scale: root.containsDrag ? 1 : 0.6

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "tray_arrow_down"
				size: 28
				color: Theme.onPrimary
			}
		}
	}
}
