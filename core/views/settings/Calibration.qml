pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// libinput's calibration matrix: the six numbers, what they do to the
// surface (the square on the left bends with them), and the usual turns
// and flips one click away.
RowLayout {
	id: root

	// [a, b, c, d, e, f]: x' = a·x + b·y + c, y' = d·x + e·y + f; [] = none
	property var matrix: []
	readonly property var m: root.matrix.length === 6 ? root.matrix.map(Number) : [1, 0, 0, 0, 1, 0]
	readonly property bool identity: root.matrix.length !== 6

	signal edited(var matrix)

	readonly property var presets: [
		{ label: "None", m: null, icon: "crop_square" },
		{ label: "Turn right", m: [0, -1, 1, 1, 0, 0], icon: "rotate_right" },
		{ label: "Upside down", m: [-1, 0, 1, 0, -1, 1], icon: "rotate_3d_variant" },
		{ label: "Turn left", m: [0, 1, 0, -1, 0, 1], icon: "rotate_left" },
		{ label: "Mirror", m: [-1, 0, 1, 0, 1, 0], icon: "flip_horizontal" }
	]

	spacing: 18

	// the surface, bent by the matrix
	Item {
		Layout.preferredWidth: 110
		Layout.preferredHeight: 110

		Rectangle {
			anchors.fill: parent
			radius: 8
			color: Theme.layer2
		}

		Canvas {
			id: shape

			anchors.fill: parent
			anchors.margins: 22
			property var mm: root.m
			onMmChanged: requestPaint()
			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const w = width, h = height;
				const map = (x, y) => [(mm[0] * x + mm[1] * y + mm[2]) * w, (mm[3] * x + mm[4] * y + mm[5]) * h];
				const corners = [map(0, 0), map(1, 0), map(1, 1), map(0, 1)];
				ctx.fillStyle = Qt.alpha(Theme.primary, 0.3);
				ctx.strokeStyle = Theme.primary;
				ctx.lineWidth = 2;
				ctx.beginPath();
				ctx.moveTo(corners[0][0], corners[0][1]);
				for (let i = 1; i < 4; i++) ctx.lineTo(corners[i][0], corners[i][1]);
				ctx.closePath();
				ctx.fill();
				ctx.stroke();
				// the top-left corner, to see turns
				ctx.fillStyle = Theme.text;
				ctx.beginPath();
				ctx.arc(corners[0][0], corners[0][1], 4, 0, Math.PI * 2);
				ctx.fill();
			}
		}
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 8

		RowLayout {
			spacing: 8

			StyledText {
				text: "Calibration"
				font.weight: Font.DemiBold
			}

			StyledText {
				text: root.identity ? "none" : "set"
				tone: root.identity ? Theme.textSubtle : Theme.primary
				font.pixelSize: Theme.size.small
			}
		}

		GridLayout {
			columns: 3
			columnSpacing: 6
			rowSpacing: 6

			Repeater {
				model: 6

				delegate: NumberScrub {
					required property int index

					value: root.m[index]
					from: -4
					to: 4
					step: 0.01
					decimals: 2
					speed: 0.005
					onMoved: v => {
						const next = root.m.slice();
						next[index] = v;
						root.edited(next);
					}
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: root.presets

				delegate: Chip {
					required property var modelData

					text: modelData.label
					icon: modelData.icon
					selected: modelData.m ? JSON.stringify(modelData.m) === JSON.stringify(root.m) && !root.identity : root.identity
					onClicked: root.edited(modelData.m)
				}
			}
		}
	}
}
