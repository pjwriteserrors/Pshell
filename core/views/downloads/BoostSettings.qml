pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the downloads panel's tune button folds out: the accelerator (on for
// browser downloads, how many connections, from which size), the panel
// opening by itself, what the bar shows, the file manager, and starting the
// statistics anew.
Rectangle {
	id: root

	implicitHeight: options.implicitHeight + 28
	radius: Theme.radius.large
	color: Theme.layer1

	component Line: RowLayout {
		id: line

		property string title: ""
		property string subtitle: ""
		property bool checked: false
		property bool available: true
		signal toggled(bool checked)

		Layout.fillWidth: true
		spacing: 12
		opacity: line.available ? 1 : 0.5

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				text: line.title
				font.pixelSize: Theme.size.body
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				visible: line.subtitle !== ""
				text: line.subtitle
				wrapMode: Text.Wrap
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}
		}

		Toggle {
			enabled: line.available
			checked: line.checked
			onToggled: checked => line.toggled(checked)
		}
	}

	ColumnLayout {
		id: options

		x: 14
		y: 14
		width: parent.width - 28
		spacing: 12

		SectionLabel {
			text: "Accelerator"
		}

		Line {
			title: "Speed up browser downloads"
			subtitle: Boost.enabled ? "Asks the server for parts of the file over several connections at once. Where the server can't, the browser downloads as always." : "Switch on the Download accelerator plugin (Pshell settings → Plugins)."
			available: Boost.enabled
			checked: Boost.enabled && Downloads.boost
			onToggled: checked => Downloads.set("boost", checked)
		}

		// an extension that never offers anything is the old one
		RowLayout {
			Layout.fillWidth: true
			visible: Boost.enabled && Downloads.connected && !Downloads.offering
			spacing: 8

			Glyph {
				icon: "information_outline"
				size: 14
				color: Theme.warning
			}

			StyledText {
				Layout.fillWidth: true
				wrapMode: Text.Wrap
				text: "No download from the browser has been offered yet. If one started and this stays, update the extension: scripts/downloads_host.py install, then install pshell-downloads.xpi again (about:addons)."
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 6
			opacity: Boost.enabled ? 1 : 0.5
			enabled: Boost.enabled

			StyledText {
				text: "Connections per download"
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [2, 4, 8, 12, 16]

					delegate: Chip {
						required property int modelData
						text: String(modelData)
						selected: Boost.settings.connections === modelData
						onClicked: Boost.setSetting("connections", modelData)
					}
				}
			}

			StyledText {
				Layout.topMargin: 4
				text: "Only files from"
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [{ size: 1048576, label: "1 MB" }, { size: 4194304, label: "4 MB" }, { size: 16777216, label: "16 MB" }, { size: 67108864, label: "64 MB" }]

					delegate: Chip {
						required property var modelData
						text: modelData.label
						selected: Boost.settings.minSize === modelData.size
						onClicked: Boost.setSetting("minSize", modelData.size)
					}
				}
			}
		}

		Rectangle {
			Layout.fillWidth: true
			implicitHeight: 1
			color: Theme.outline
		}

		Line {
			title: "Open when a download starts"
			subtitle: "This panel comes down by itself for every new download."
			checked: Downloads.popOnStart
			onToggled: checked => Downloads.set("popOnStart", checked)
		}

		SectionLabel {
			Layout.topMargin: 4
			text: "Bar"
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: [
					{ name: "hideWhenIdle", label: "Hide when idle", on: Downloads.hideWhenIdle },
					{ name: "showPercent", label: "Percentage", on: Downloads.showPercent },
					{ name: "showSpeed", label: "Speed", on: Downloads.showSpeed }
				]

				delegate: Chip {
					required property var modelData
					text: modelData.label
					icon: modelData.on ? "check_bold" : ""
					selected: modelData.on
					onClicked: Downloads.set(modelData.name, !modelData.on)
				}
			}
		}

		SectionLabel {
			text: "File manager"
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: ["auto"].concat(Downloads.managers)

				delegate: Chip {
					required property string modelData
					text: modelData === "auto" ? "Auto" : modelData.charAt(0).toUpperCase() + modelData.slice(1)
					selected: (Downloads.managers.includes(Downloads.fileManager) ? Downloads.fileManager : "auto") === modelData
					onClicked: Downloads.set("fileManager", modelData)
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				Layout.fillWidth: true
				text: "Statistics"
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			TextButton {
				text: "Start anew"
				icon: "broom"
				variant: "danger"
				confirm: true
				confirmText: "Forget all figures?"
				onActivated: Downloads.resetStats()
			}
		}
	}
}
