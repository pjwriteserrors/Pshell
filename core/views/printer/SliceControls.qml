pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// How a model is sliced: the profile and the filament profile (Orca's
// presets, a click opens the list), the plate, supports and infill; below,
// what the slicer is doing. A preset saved in Orca slices again by itself
// (printer.py Slicing.stale).
// Every change slices again (PrintPage).
ColumnLayout {
	id: root

	required property var job
	required property var settings
	// "main": the profiles and what the slicer does; "more": the plate, supports, infill, brim
	property string part: "main"
	signal edit(string key, var value)
	signal openProfiles(string kind)

	readonly property var profile: Printer.profiles.find(p => p.name === root.settings.process) ?? null
	readonly property var filament: Printer.filamentProfiles.find(f => f.name === root.settings.filament) ?? null
	readonly property var bedNames: ({
		"Cool Plate": "Cool",
		"Engineering Plate": "Engineering",
		"High Temp Plate": "High temp",
		"Textured PEI Plate": "Textured PEI"
	})

	spacing: 10

	RowLayout {
		Layout.fillWidth: true
		visible: root.part === "main"

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
		id: processButton

		Layout.fillWidth: true
		visible: root.part === "main"
		Layout.preferredHeight: 54
		radius: Theme.radius.large
		color: processButton.hovered ? Theme.layer2 : Theme.layer1
		onClicked: root.openProfiles("process")

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 10
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 34
				Layout.preferredHeight: 34
				radius: 17
				color: Theme.primary

				Glyph {
					anchors.centerIn: parent
					icon: "tune_variant"
					size: 17
					color: Theme.onPrimary
					rotation: processButton.hovered ? 90 : 0

					Behavior on rotation {
						SpatialAnim {}
					}
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

	// the filament profile – one for every filament of its material
	Clickable {
		id: filamentButton

		Layout.fillWidth: true
		visible: root.part === "main"
		Layout.preferredHeight: 42
		Layout.topMargin: -4
		radius: Theme.radius.large
		color: filamentButton.hovered ? Theme.layer2 : Theme.layer1
		onClicked: root.openProfiles("filament")

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 10
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 34
				Layout.preferredHeight: 26
				radius: 13
				color: root.filament?.user ? Theme.primarySoft : Theme.layer3

				Glyph {
					anchors.centerIn: parent
					icon: "printer_3d_nozzle"
					size: 14
					color: root.filament?.user ? Theme.primary : Theme.textMuted
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: root.settings.filament || "Filament: automatic"
				elide: Text.ElideRight
				font.pixelSize: Theme.size.label
			}

			StyledText {
				text: root.filament ? (root.filament.user ? `yours · ${root.filament.type}` : root.filament.type) : "Orca's last"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
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
		visible: root.part === "more"
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
		visible: root.part === "more"
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
		visible: root.part === "main" && !!root.job?.sliceError
		text: root.job?.sliceError ?? ""
		wrapMode: Text.Wrap
		tone: Theme.danger
		font.pixelSize: Theme.size.small
	}
}
