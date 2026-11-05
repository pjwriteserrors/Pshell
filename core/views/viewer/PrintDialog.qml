pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Printing the result on paper through CUPS (`lp`): the printer, how many,
// the paper, fitted or filling the page. The shell's own "printer" plugin
// is the 3D printer; this is the one for paper.
Item {
	id: root

	property bool open: false
	property var printers: []
	property string printer: ""
	property int copies: 1
	property string paper: "A4"
	property bool fill: false
	property bool loading: false

	function show() {
		root.open = true;
		root.loading = true;
		list.running = true;
	}

	function close() {
		root.open = false;
	}

	Process {
		id: list

		command: ["sh", "-c", "lpstat -e 2>/dev/null; echo '--'; lpstat -d 2>/dev/null"]
		stdout: StdioCollector {
			onStreamFinished: {
				const [names, def] = text.split("--");
				root.printers = names.split("\n").map(v => v.trim()).filter(v => v);
				const fallback = (def.match(/destination:\s*(\S+)/) ?? [])[1] ?? "";
				if (!root.printers.includes(root.printer)) root.printer = root.printers.includes(fallback) ? fallback : (root.printers[0] ?? "");
				root.loading = false;
			}
		}
	}

	function send() {
		const printer = root.printer, copies = root.copies, paper = root.paper, fill = root.fill;
		root.close();
		Viewer.renderTemp("print", path => {
			Quickshell.execDetached(["lp", "-d", printer, "-n", String(copies), "-o", `media=${paper}`, "-o", fill ? "fill" : "fit-to-page", path]);
			Viewer.say(`Printing on ${printer}`, "printer_outline");
		});
	}

	visible: root.open || card.opacity > 0

	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: root.open ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.close()
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: 420
		height: form.implicitHeight + 40
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		opacity: root.open ? 1 : 0
		scale: root.open ? 1 : 0.94

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		MouseArea {
			anchors.fill: parent
		}

		Column {
			id: form

			x: 20
			y: 20
			width: parent.width - 40
			spacing: 14

			StyledText {
				text: "Print"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
			}

			StyledText {
				visible: !root.loading && root.printers.length === 0
				width: parent.width
				wrapMode: Text.Wrap
				text: "No printer is set up yet. Add one in the printer settings of the system (CUPS), then it is here."
				tone: Theme.textMuted
			}

			TextButton {
				visible: !root.loading && root.printers.length === 0
				text: "Printer settings"
				icon: "cog_outline"
				variant: "tonal"
				onActivated: {
					Quickshell.execDetached(["sh", "-c", "command -v system-config-printer >/dev/null && exec system-config-printer || exec xdg-open http://localhost:631/admin"]);
					root.close();
				}
			}

			Flow {
				width: parent.width
				spacing: 6
				visible: root.printers.length > 0

				Repeater {
					model: root.printers

					delegate: Chip {
						required property string modelData

						text: modelData
						icon: "printer_outline"
						selected: root.printer === modelData
						onClicked: root.printer = modelData
					}
				}
			}

			Segmented {
				width: parent.width
				height: 34
				visible: root.printers.length > 0
				options: [{ value: "A4", label: "A4" }, { value: "A5", label: "A5" }, { value: "Letter", label: "Letter" }, { value: "4x6", label: "10 × 15" }]
				current: root.paper
				onSelected: value => root.paper = value
			}

			Segmented {
				width: parent.width
				height: 34
				visible: root.printers.length > 0
				options: [{ value: "fit", label: "All of it on the page" }, { value: "fill", label: "Filling the page" }]
				current: root.fill ? "fill" : "fit"
				onSelected: value => root.fill = value === "fill"
			}

			Row {
				spacing: 10
				visible: root.printers.length > 0

				IconButton {
					width: 32
					height: 32
					icon: "minus"
					onClicked: root.copies = Math.max(1, root.copies - 1)
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: root.copies === 1 ? "One copy" : `${root.copies} copies`
					tabular: true
				}

				IconButton {
					width: 32
					height: 32
					icon: "plus"
					onClicked: root.copies = Math.min(99, root.copies + 1)
				}
			}

			Row {
				anchors.right: parent.right
				spacing: 8

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: root.close()
				}

				TextButton {
					text: "Print"
					icon: "printer_outline"
					variant: "filled"
					enabled: root.printer !== ""
					onActivated: root.send()
				}
			}
		}
	}
}
