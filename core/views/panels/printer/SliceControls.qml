pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// How a model is sliced: the profile (Orca's presets, a click opens the
// list), the plate, supports and infill; below, what the slicer is doing.
// Every change slices again (PrintPage).
ColumnLayout {
	id: root

	required property var job
	required property var settings
	signal edit(string key, var value)
	signal openProfiles

	readonly property var profile: Printer.profiles.find(p => p.name === root.settings.process) ?? null
	readonly property var bedNames: ({
		"Cool Plate": "Cool",
		"Engineering Plate": "Engineering",
		"High Temp Plate": "High temp",
		"Textured PEI Plate": "Textured PEI"
	})

	spacing: 10

	RowLayout {
		Layout.fillWidth: true

		SectionLabel {
			Layout.fillWidth: true
			text: "Slicing"
		}

		// what the slicer does right now
		Row {
			spacing: 6

			Spinner {
				anchors.verticalCenter: parent.verticalCenter
				width: 14
				height: 14
				visible: !!root.job?.slicing
			}

			StyledText {
				text: root.job?.slicing ? "Slicing…" : (root.job?.sliceError ? "Failed" : (root.job?.sliceSeconds ? `Sliced in ${root.job.sliceSeconds} s` : ""))
				tone: root.job?.sliceError ? Theme.danger : Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}
	}

	// the profile
	Clickable {
		Layout.fillWidth: true
		Layout.preferredHeight: 46
		radius: Theme.radius.medium
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		onClicked: root.openProfiles()

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 10
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28
				radius: 8
				color: Theme.primarySoft

				Glyph {
					anchors.centerIn: parent
					icon: "tune_variant"
					size: 15
					color: Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					Layout.fillWidth: true
					text: root.settings.process || "Pick a profile"
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.profile ? `${root.profile.layer} mm layers · ${root.profile.user ? "yours" : "Anycubic"}${root.profile.fits ? "" : " · made for another printer"}` : "OrcaSlicer's profiles"
					tone: root.profile && !root.profile.fits ? Theme.warning : Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			Glyph {
				icon: "chevron_down"
				size: 16
				color: Theme.textMuted
			}
		}
	}

	// the plate
	Flow {
		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: Printer.beds

			delegate: Chip {
				required property string modelData

				text: root.bedNames[modelData] ?? modelData
				selected: root.settings.bed === modelData
				onClicked: root.edit("bed", modelData)
			}
		}
	}

	GridLayout {
		Layout.fillWidth: true
		columns: 2
		columnSpacing: 10
		rowSpacing: 8

		StyledText {
			text: "Supports"
			font.pixelSize: Theme.size.label
		}

		Segmented {
			Layout.fillWidth: true
			Layout.preferredHeight: 30
			options: [
				{ value: "profile", label: "Profile" },
				{ value: "on", label: "On" },
				{ value: "off", label: "Off" }
			]
			current: root.settings.supports === null || root.settings.supports === undefined ? "profile" : (root.settings.supports ? "on" : "off")
			onSelected: value => root.edit("supports", value === "profile" ? null : value === "on")
		}

		StyledText {
			text: "Infill"
			font.pixelSize: Theme.size.label
		}

		Segmented {
			Layout.fillWidth: true
			Layout.preferredHeight: 30
			options: [
				{ value: "0", label: "Profile" },
				{ value: "10", label: "10 %" },
				{ value: "15", label: "15 %" },
				{ value: "25", label: "25 %" },
				{ value: "40", label: "40 %" }
			]
			current: String(root.settings.infill ?? 0)
			onSelected: value => root.edit("infill", Number(value) > 0 ? Number(value) : null)
		}

		StyledText {
			text: "Brim"
			font.pixelSize: Theme.size.label
		}

		Segmented {
			Layout.fillWidth: true
			Layout.preferredHeight: 30
			options: [
				{ value: "profile", label: "Profile" },
				{ value: "on", label: "Auto" },
				{ value: "off", label: "None" }
			]
			current: root.settings.brim === null || root.settings.brim === undefined ? "profile" : (root.settings.brim ? "on" : "off")
			onSelected: value => root.edit("brim", value === "profile" ? null : value === "on")
		}
	}

	StyledText {
		Layout.fillWidth: true
		visible: !!root.job?.sliceError
		text: root.job?.sliceError ?? ""
		wrapMode: Text.Wrap
		tone: Theme.danger
		font.pixelSize: Theme.size.small
	}
}
