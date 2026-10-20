pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The slicer profiles to pick from, over the side of the print page: those
// made for this printer first (the user's own, then Anycubic's), then the
// user's made for other printers. The same list picks the filament profile
// (kind "filament"): the user's, then Anycubic's, and "Automatic" – Orca's
// last for this printer. Importing takes a preset or a bundle through the
// file chooser; one dropped into the inbox is imported too.
Item {
	id: root

	property bool open: false
	property string kind: "process"
	property string current: ""
	signal picked(string kind, string name)

	readonly property var groups: (root.kind === "filament" ? [
		{ label: "", items: [{ name: "", label: "Automatic", detail: Printer.defaultFilament || "Anycubic's for the material", auto: true }] },
		{ label: "Yours", items: Printer.filamentProfiles.filter(f => f.user).map(f => ({ name: f.name, detail: f.type, user: true })) },
		{ label: "Anycubic", items: Printer.filamentProfiles.filter(f => !f.user).map(f => ({ name: f.name, detail: f.type, user: false })) }
	] : [
		{ label: "Yours", items: Printer.profiles.filter(p => p.user && p.fits) },
		{ label: "Anycubic", items: Printer.profiles.filter(p => !p.user && p.fits) },
		{ label: "Made for other printers", items: Printer.profiles.filter(p => !p.fits) }
	]).filter(group => group.items.length > 0)

	visible: card.opacity > 0.01

	// a click beside the list closes it
	MouseArea {
		anchors.fill: parent
		enabled: root.open
		onClicked: root.open = false
	}

	Rectangle {
		id: card

		anchors.fill: parent
		radius: Theme.radius.huge
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
		opacity: root.open ? 1 : 0
		scale: root.open ? 1 : 0.96
		transformOrigin: Item.Top

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		// keeps clicks on the card from closing it
		MouseArea {
			anchors.fill: parent
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 12
			spacing: 8

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: root.kind === "filament" ? "Filament profile" : "Slicer profile"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				IconButton {
					icon: "close"
					onClicked: root.open = false
				}
			}

			ListView {
				id: list

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				spacing: 2
				boundsBehavior: Flickable.StopAtBounds
				model: root.groups.reduce((rows, group) => rows.concat(group.label ? [{ header: group.label }] : [], group.items), [])

				delegate: Loader {
					id: row

					required property var modelData
					required property int index

					width: ListView.view.width
					sourceComponent: row.modelData.header !== undefined ? header : entry

					Component {
						id: header

						SectionLabel {
							topPadding: row.index === 0 ? 2 : 10
							bottomPadding: 2
							text: row.modelData.header
						}
					}

					Component {
						id: entry

						Clickable {
							id: item

							readonly property bool chosen: row.modelData.name === root.current

							implicitHeight: 40
							radius: Theme.radius.medium
							color: chosen ? Theme.primarySoft : "transparent"
							onClicked: {
								root.picked(root.kind, row.modelData.name);
								root.open = false;
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 10
								anchors.rightMargin: 10
								spacing: 8

								Glyph {
									icon: item.chosen ? "check" : (row.modelData.auto ? "auto_fix" : (row.modelData.user ? "account_outline" : (root.kind === "filament" ? "printer_3d_nozzle" : "printer_3d")))
									size: 15
									color: item.chosen ? Theme.primary : Theme.textMuted
								}

								StyledText {
									Layout.fillWidth: true
									text: row.modelData.label ?? row.modelData.name
									elide: Text.ElideRight
									font.pixelSize: Theme.size.label
								}

								StyledText {
									Layout.maximumWidth: row.modelData.auto ? item.width * 0.5 : implicitWidth
									text: row.modelData.detail ?? `${row.modelData.layer} mm`
									elide: Text.ElideRight
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
									tabular: true
								}
							}
						}
					}
				}
			}

			TextButton {
				Layout.fillWidth: true
				text: Printer.importing ? "Importing…" : "Import a profile…"
				icon: "file_import_outline"
				busy: Printer.importing
				onActivated: Printer.importProfile()
			}

			StyledText {
				Layout.fillWidth: true
				text: "A .json, .orca_printer, .orca_filament or Bambu bundle – also when it is dropped into the inbox."
				wrapMode: Text.Wrap
				tone: Theme.textFaint
				font.pixelSize: Theme.size.tiny
			}
		}
	}
}
