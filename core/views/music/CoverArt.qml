pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The cover of the song that plays. A new one slides in from the side the
// queue went to while the old one slides out (two slots, the next decoded
// before it moves); a song of the same album only nods. Paused, it sits
// back a little. Without a cover: the accent with a note.
Item {
	id: root

	property string art: Music.art
	property color accent: Theme.primary
	property real corner: Theme.radius.huge
	// the shadow below it (off in the small window)
	property bool lifted: true

	// slot a or b is in front
	property bool aFront: true
	property string shownArt: ""
	readonly property real pausedScale: Music.playing ? 1 : 0.94

	function place(source) {
		const back = root.aFront ? slotB : slotA;
		if (source === root.shownArt) {
			nod.restart();
			return;
		}
		back.pending = true;
		back.source = source ? "file://" + source : "";
		if (!source || back.status === Image.Ready) root.swap();
	}

	function swap() {
		const front = root.aFront ? slotA : slotB;
		const back = root.aFront ? slotB : slotA;
		back.pending = false;
		root.shownArt = String(back.source).replace(/^file:\/\//, "");
		root.aFront = !root.aFront;
		const d = Music.direction || 1;
		back.enter(d);
		front.leave(d);
	}

	onArtChanged: root.place(root.art)

	Connections {
		target: Music

		// a new song with the same picture: a small nod
		function onPathChanged() {
			if (Music.art === root.shownArt && Music.path) nod.restart();
		}
	}

	SequentialAnimation {
		id: nod

		NumberAnimation {
			target: holder
			property: "scale"
			to: 0.97
			duration: Motion.short
			easing.type: Easing.OutQuad
		}
		NumberAnimation {
			target: holder
			property: "scale"
			to: 1
			duration: Motion.long
			easing.type: Easing.OutBack
		}
	}

	// the shadow follows the cover in front
	RectangularShadow {
		anchors.fill: holder
		anchors.margins: 6
		scale: holder.scale * root.pausedScale
		radius: root.corner
		blur: 36
		offset.y: 14
		color: Qt.alpha("#000000", Theme.dark ? 0.55 : 0.3)
		visible: root.lifted
		opacity: Music.playing ? 1 : 0.6

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
	}

	Item {
		id: holder

		anchors.fill: parent
		scale: 1

		Item {
			anchors.fill: parent
			scale: root.pausedScale

			Behavior on scale {
				NumberAnimation {
					duration: Motion.extraLong
					easing.type: Easing.OutBack
					easing.overshoot: 1.2
				}
			}

			// nothing to show: the accent and a note
			Rectangle {
				anchors.fill: parent
				radius: root.corner
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Qt.tint(Theme.layer2, Qt.alpha(root.accent, 0.35))
					}
					GradientStop {
						position: 1
						color: Qt.tint(Theme.layer1, Qt.alpha(root.accent, 0.12))
					}
				}
				opacity: root.shownArt === "" ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "music_note"
					size: parent.width * 0.32
					color: Qt.alpha(root.accent, 0.8)
				}
			}

			CoverSlot {
				id: slotA

				corner: root.corner
				onReady: if (slotA.pending) root.swap()
			}

			CoverSlot {
				id: slotB

				corner: root.corner
				onReady: if (slotB.pending) root.swap()
			}
		}
	}

	component CoverSlot: Item {
		id: slot

		property alias source: image.source
		readonly property int status: image.status
		property bool pending: false
		property real corner: 0
		signal ready

		function enter(d) {
			slot.z = 2;
			move.stop();
			slot.x = d * root.width * 0.18;
			slot.opacity = 0;
			slot.scale = 0.9;
			toX.to = 0;
			toOpacity.to = 1;
			toScale.to = 1;
			move.start();
		}

		function leave(d) {
			slot.z = 1;
			move.stop();
			toX.to = -d * root.width * 0.12;
			toOpacity.to = 0;
			toScale.to = 0.92;
			move.start();
		}

		width: root.width
		height: root.height
		opacity: 0

		ParallelAnimation {
			id: move

			NumberAnimation {
				id: toX

				target: slot
				property: "x"
				duration: Motion.extraLong
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
			NumberAnimation {
				id: toOpacity

				target: slot
				property: "opacity"
				duration: Motion.long
			}
			NumberAnimation {
				id: toScale

				target: slot
				property: "scale"
				duration: Motion.extraLong
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		Image {
			id: image

			anchors.fill: parent
			sourceSize: Qt.size(720, 720)
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			cache: false
			visible: false
			onStatusChanged: if (image.status === Image.Ready || image.status === Image.Error) slot.ready()
		}

		MultiEffect {
			anchors.fill: parent
			source: image
			maskEnabled: true
			maskSource: mask
			maskThresholdMin: 0.5
			maskSpreadAtMin: 1
		}

		Item {
			id: mask

			anchors.fill: parent
			layer.enabled: true
			layer.smooth: true
			visible: false

			Rectangle {
				anchors.fill: parent
				radius: slot.corner
			}
		}
	}
}
