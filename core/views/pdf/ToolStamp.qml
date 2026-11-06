pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Stamps: a word in a frame with the day under it – Paid, Approved, Draft …
// or words of your own, or a picture (a company stamp) – real stamp
// annotations. One click picks it, the next puts it on the page.
PaneFrame {
	id: root

	property Item dock: null
	property bool withDate: true
	property bool keep: false
	readonly property var own: Pdf.setting("stamps", []) || []
	readonly property var chosen: Pdf.selected.map(id => Pdf.itemById(id)).find(item => item && item.kind === "stamp") ?? null

	readonly property var builtIn: [
		{ label: "Paid", color: "#2e7d32" }, { label: "Approved", color: "#2e7d32" }, { label: "Received", color: "#1565c0" },
		{ label: "Draft", color: "#616161" }, { label: "Confidential", color: "#c62828" }, { label: "Rejected", color: "#c62828" },
		{ label: "Copy", color: "#6a1b9a" }, { label: "Bezahlt", color: "#2e7d32" }, { label: "Geprüft", color: "#2e7d32" },
		{ label: "Erhalten", color: "#1565c0" }, { label: "Entwurf", color: "#616161" }, { label: "Vertraulich", color: "#c62828" }
	]

	title: "Stamp"
	subtitle: Pdf.placing?.kind === "stamp" ? "Click on the page where it goes" : "Pick one, then click on the page"
	onClose: {
		if (Pdf.placing?.kind === "stamp") Pdf.placing = null;
		Pdf.tool = "";
	}

	function pick(stamp) {
		const w = Math.max(90, Math.min(220, String(stamp.label ?? "").length * 13 + 40));
		Pdf.placing = stamp.image ? { kind: "stamp", image: stamp.image, w: stamp.w || 140, h: stamp.h || 70, keep: root.keep } : { kind: "stamp", label: stamp.label, color: stamp.color, date: root.withDate, w: w, h: root.withDate ? 52 : 40, keep: root.keep };
	}

	Grid {
		width: parent.width
		columns: 2
		spacing: 8

		Repeater {
			model: root.builtIn

			delegate: Rectangle {
				id: stamp

				required property var modelData
				readonly property bool current: Pdf.placing?.kind === "stamp" && Pdf.placing?.label === stamp.modelData.label

				width: (root.bodyWidth - 8) / 2
				height: 58
				radius: Theme.radius.medium
				color: stamp.current ? Theme.primarySoft : (stampMouse.containsMouse ? Theme.layer3 : Theme.layer2)
				scale: stampMouse.pressed ? 0.95 : 1

				Behavior on scale {
					SpatialAnim {}
				}

				Rectangle {
					anchors.centerIn: parent
					width: parent.width - 30
					height: parent.height - 18
					radius: 6
					color: "transparent"
					border.color: stamp.modelData.color
					border.width: 2
					rotation: stampMouse.containsMouse ? -3 : 0

					Behavior on rotation {
						SpatialAnim {}
					}

					Column {
						anchors.centerIn: parent

						Text {
							anchors.horizontalCenter: parent.horizontalCenter
							text: stamp.modelData.label.toUpperCase()
							color: stamp.modelData.color
							font.family: "Nimbus Sans"
							font.bold: true
							font.pixelSize: 13
						}

						Text {
							anchors.horizontalCenter: parent.horizontalCenter
							visible: root.withDate
							text: new Date().toLocaleDateString(Qt.locale(), "dd.MM.yyyy")
							color: stamp.modelData.color
							font.family: "Nimbus Sans"
							font.pixelSize: 8
						}
					}
				}

				MouseArea {
					id: stampMouse

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.pick(stamp.modelData)
				}
			}
		}
	}

	PaneLine {
		label: "With the date"

		Toggle {
			checked: root.withDate
			onToggled: on => root.withDate = on
		}
	}

	PaneLine {
		label: "Several in a row"
		detail: "Stays picked after each click"

		Toggle {
			checked: root.keep
			onToggled: on => {
				root.keep = on;
				if (Pdf.placing) Pdf.placing = Object.assign({}, Pdf.placing, { keep: on });
			}
		}
	}

	// ── own ────────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Your own"
	}

	Row {
		width: parent.width
		spacing: 6

		Field {
			id: ownWords

			width: parent.width - colorPick.width - 6
			height: 36
			placeholder: "Words for a stamp"
			onAccepted: if (text.trim()) root.pick({ label: text.trim(), color: colorPick.current })
		}

		Segmented {
			id: colorPick

			width: 120
			options: [{ value: "#c62828", label: "Red" }, { value: "#2e7d32", label: "Green" }, { value: "#1565c0", label: "Blue" }]
			current: "#c62828"
			onSelected: value => colorPick.current = value
		}
	}

	Flow {
		width: parent.width
		spacing: 8

		Repeater {
			model: root.own

			delegate: Rectangle {
				id: pic

				required property var modelData
				required property int index

				width: 92
				height: 64
				radius: Theme.radius.small
				color: "white"
				border.color: Pdf.placing?.image === pic.modelData.image ? Theme.primary : Theme.outline
				border.width: Pdf.placing?.image === pic.modelData.image ? 2 : 1

				Image {
					anchors.fill: parent
					anchors.margins: 6
					source: Pdf.fileUrl(pic.modelData.image)
					fillMode: Image.PreserveAspectFit
					asynchronous: true
				}

				MouseArea {
					anchors.fill: parent
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					cursorShape: Qt.PointingHandCursor
					onClicked: mouse => {
						if (mouse.button === Qt.RightButton) Pdf.setSetting("stamps", root.own.filter((s, i) => i !== pic.index));
						else root.pick(pic.modelData);
					}
				}
			}
		}
	}

	TextButton {
		text: "A picture as a stamp…"
		icon: "image_plus"
		onActivated: Files.pick({ title: "A picture for a stamp", filters: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.svg"] }, paths => {
			if (!paths || paths.length === 0) return;
			Pdf.setSetting("stamps", root.own.concat([{ image: paths[0], w: 140, h: 70 }]));
			root.pick({ image: paths[0], w: 140, h: 70 });
		})
	}

	// the chosen stamp where it is, on every page
	TextButton {
		visible: !!root.chosen
		text: "Put the chosen stamp on every page"
		icon: "content_duplicate"
		onActivated: {
			const next = Pdf.clone(Pdf.recipe);
			for (const p of next.pages) {
				if (p.id === root.chosen.page) continue;
				const copy = Pdf.clone(root.chosen);
				copy.id = Pdf.newId(next, "i");
				copy.page = p.id;
				next.items.push(copy);
			}
			Pdf.commit(next, "Stamped on every page");
		}
	}
}
