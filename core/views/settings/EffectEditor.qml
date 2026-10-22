import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "Nodes.js" as Nodes

// background-effect: blur behind it, the cheap "xray" blur, noise and
// saturation – with a glass pane over the wallpaper showing it.
RowLayout {
	id: root

	property var section: null

	signal changed(var section)

	readonly property bool blur: Nodes.arg(root.section, "blur", false) === true
	readonly property bool xray: Nodes.arg(root.section, "xray", true) !== false
	readonly property real noise: Number(Nodes.arg(root.section, "noise", 0.02))
	readonly property real saturation: Number(Nodes.arg(root.section, "saturation", 1.5))

	spacing: 14

	GlassSample {
		Layout.preferredWidth: 130
		Layout.preferredHeight: 90
		blur: root.blur ? 1 : 0
		saturation: root.saturation
		noise: root.noise
	}

	ColumnLayout {
		Layout.fillWidth: true
		spacing: 8

		RowLayout {
			spacing: 8

			Chip {
				text: root.blur ? "Blurred behind" : "Not blurred"
				icon: "blur"
				selected: root.blur
				onClicked: root.changed(Nodes.withArg(root.section ?? Nodes.make("background-effect", [], {}, []), "blur", !root.blur))
			}

			Chip {
				text: root.xray ? "Xray (fast)" : "Real blur"
				icon: "layers_outline"
				selected: root.xray
				onClicked: root.changed(Nodes.withArg(root.section ?? Nodes.make("background-effect", [], {}, []), "xray", !root.xray))
			}
		}

		ValueSlider {
			from: 0
			to: 0.3
			step: 0.01
			decimals: 2
			label: "Noise"
			value: root.noise
			onMoved: v => root.changed(Nodes.withArg(root.section, "noise", v))
		}

		ValueSlider {
			from: 0
			to: 3
			step: 0.05
			decimals: 2
			label: "Saturation"
			value: root.saturation
			format: v => `${Math.round(v * 100)}%`
			onMoved: v => root.changed(Nodes.withArg(root.section, "saturation", v))
		}
	}
}
