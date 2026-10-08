import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "Nodes.js" as Nodes
import "NiriColor.js" as NiriColor

// One state of a ring, border or tab (active, inactive, urgent): a solid
// color or a gradient – niri draws the gradient when there is one.
ColumnLayout {
	id: root

	property var section: null
	property string kind: "active"
	property string label: "Active"
	property string fallback: "#7fc8ff"

	property string colorName: `${root.kind}-color`
	property string gradientName: `${root.kind}-gradient`
	readonly property var gradient: Nodes.gradient(root.section, root.gradientName)
	readonly property string color: String(Nodes.arg(root.section, root.colorName, root.fallback))
	readonly property bool modified: Nodes.has(root.section, root.colorName) || !!root.gradient

	signal changed(var section)

	function lighter(css) {
		const c = NiriColor.parse(css) || [0.5, 0.5, 0.5, 1];
		const hsv = NiriColor.toHsv(c);
		return NiriColor.format(NiriColor.fromHsv((hsv[0] + 0.12) % 1, hsv[1], Math.min(1, hsv[2] + 0.15), hsv[3]));
	}

	spacing: 10

	RowLayout {
		Layout.fillWidth: true
		spacing: 12

		StyledText {
			Layout.preferredWidth: 78
			text: root.label
			tone: Theme.textMuted
			font.weight: Font.Medium
		}

		Segmented {
			Layout.preferredWidth: 180
			implicitHeight: 30
			options: [
				{ value: "solid", label: "Solid", icon: "circle" },
				{ value: "gradient", label: "Gradient", icon: "gradient_horizontal" }
			]
			current: root.gradient ? "gradient" : "solid"
			onSelected: value => {
				if (value === "gradient" && !root.gradient)
					root.changed(Nodes.withGradient(root.section, root.gradientName, { from: root.color, to: root.lighter(root.color), angle: 45, relativeTo: "", space: "srgb" }));
				else if (value === "solid" && root.gradient)
					root.changed(Nodes.without(root.section, root.gradientName));
			}
		}

		ColorWell {
			visible: !root.gradient
			value: root.color
			onPicked: css => root.changed(Nodes.withArg(root.section, root.colorName, css))
		}

		Item {
			Layout.fillWidth: true
		}

		ResetPill {
			shown: root.modified
			onClicked: root.changed(Nodes.without(Nodes.without(root.section, root.colorName), root.gradientName))
		}
	}

	// grows open for the gradient
	Item {
		Layout.fillWidth: true
		Layout.preferredHeight: root.gradient ? editor.implicitHeight : 0
		clip: true
		opacity: root.gradient ? 1 : 0

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}

		GradientEditor {
			id: editor

			width: parent.width
			x: 90
			gradient: root.gradient ?? { from: root.color, to: root.lighter(root.color), angle: 45, relativeTo: "", space: "srgb" }
			onEdited: g => root.changed(Nodes.withGradient(root.section, root.gradientName, g))
		}
	}
}
