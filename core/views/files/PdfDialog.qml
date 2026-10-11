pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The questions a PDF tool has before it starts: which pages, how strong,
// what text, which password. Each tool lists its fields; the dialog draws
// them, keeps what was typed and hands it all to the daemon.
DialogFrame {
	id: root

	required property var view
	property string tool: ""
	property var rows: []
	property var values: ({})
	// the order of the files to merge
	property var order: []

	readonly property var specs: ({
		merge: { title: "Merge into one PDF", icon: "call_merge", action: "Merge", fields: [
			{ key: "order", type: "order", label: "In this order" },
			{ key: "name", type: "text", label: "Name of the new PDF", value: "Merged" }
		] },
		split: { title: "Split", icon: "call_split", action: "Split", fields: [
			{ key: "how", type: "choice", label: "Into", value: "each", options: [{ value: "each", label: "Single pages" }, { value: "every", label: "Every few pages" }, { value: "ranges", label: "Ranges" }] },
			{ key: "every", type: "text", label: "Pages per file", value: "2", when: values => values.how === "every" },
			{ key: "pages", type: "text", label: "One file per range", placeholder: "1-3, 4-8, 9-", when: values => values.how === "ranges" }
		], note: "The parts go into a new folder beside the document." },
		extract: { title: "Take pages out", icon: "file_move_outline", action: "Take out", fields: [
			{ key: "pages", type: "text", label: "Pages", placeholder: "1-3, 5, 8-", required: true }
		], note: "They become a new PDF; the document stays as it is." },
		remove: { title: "Remove pages", icon: "file_remove_outline", action: "Remove", fields: [
			{ key: "pages", type: "text", label: "Pages to remove", placeholder: "2, 4-6", required: true }
		], note: "A copy without them is made; the document stays as it is." },
		rotate: { title: "Rotate", icon: "rotate_right", action: "Rotate", fields: [
			{ key: "angle", type: "choice", label: "Turn", value: "90", options: [{ value: "270", label: "Left" }, { value: "180", label: "Upside down" }, { value: "90", label: "Right" }] },
			{ key: "pages", type: "text", label: "Pages", placeholder: "All of them" }
		] },
		compress: { title: "Compress", icon: "arrow_collapse_vertical", action: "Compress", fields: [
			{ key: "level", type: "choice", label: "How much", value: "ebook", options: [{ value: "screen", label: "Strong" }, { value: "ebook", label: "Recommended" }, { value: "printer", label: "Light" }] }
		], note: "Strong makes pictures rough; light keeps them fit to print." },
		toimages: { title: "To pictures", icon: "image_multiple_outline", action: "Make pictures", fields: [
			{ key: "format", type: "choice", label: "As", value: "jpg", options: [{ value: "jpg", label: "JPG" }, { value: "png", label: "PNG" }] },
			{ key: "dpi", type: "choice", label: "Sharpness", value: "150", options: [{ value: "72", label: "Screen" }, { value: "150", label: "Good" }, { value: "300", label: "Print" }] }
		], note: "Every page becomes a picture in a new folder." },
		pagenumbers: { title: "Page numbers", icon: "format_list_numbered", action: "Number", fields: [
			{ key: "position", type: "choice", label: "Where", value: "bottom", options: [{ value: "bottom-left", label: "Left" }, { value: "bottom", label: "Middle" }, { value: "bottom-right", label: "Right" }] },
			{ key: "edge", type: "choice", label: "At the", value: "bottom", options: [{ value: "bottom", label: "Bottom" }, { value: "top", label: "Top" }] },
			{ key: "format", type: "choice", label: "Looks like", value: "{n}", options: [{ value: "{n}", label: "1" }, { value: "{n} / {total}", label: "1 / 9" }, { value: "Page {n} of {total}", label: "Page 1 of 9" }] },
			{ key: "start", type: "text", label: "First number", value: "1" },
			{ key: "pages", type: "text", label: "On the pages", placeholder: "All of them" }
		] },
		watermark: { title: "Watermark", icon: "water_outline", action: "Put it on", fields: [
			{ key: "text", type: "text", label: "Text", placeholder: "CONFIDENTIAL", required: true },
			{ key: "layout", type: "choice", label: "Lies", value: "diagonal", options: [{ value: "diagonal", label: "Across" }, { value: "center", label: "In the middle" }] },
			{ key: "opacity", type: "slider", label: "Strength", value: 0.18 }
		] },
		protect: { title: "Lock with a password", icon: "lock_outline", action: "Lock", fields: [
			{ key: "newPassword", type: "password", label: "Password", required: true },
			{ key: "repeat", type: "password", label: "Once more", required: true },
			{ key: "noCopy", type: "switch", label: "No copying of text", value: false },
			{ key: "noPrint", type: "switch", label: "No printing", value: false },
			{ key: "noEdit", type: "switch", label: "No changes", value: false }
		], note: "Locked with AES-256; without the password it cannot be opened." },
		unlock: { title: "Remove the password", icon: "lock_open_variant_outline", action: "Unlock", fields: [
			{ key: "password", type: "password", label: "Its password" }
		], note: "A copy without a password is made." },
		metadata: { title: "Title and author", icon: "information_variant", action: "Save", fields: [
			{ key: "title", type: "text", label: "Title" },
			{ key: "author", type: "text", label: "Author" },
			{ key: "subject", type: "text", label: "Subject" },
			{ key: "keywords", type: "text", label: "Keywords" }
		] },
		redact: { title: "Black out words", icon: "eye_off_outline", action: "Black out", fields: [
			{ key: "words", type: "text", label: "Words or phrases, with commas between", placeholder: "Max Mustermann, IBAN, 0171", required: true }
		], note: "Pages with them become pictures, so nothing is left under the black. Scanned pages need OCR first." },
		tooffice: { title: "To Word", icon: "file_word_outline", action: "Convert", fields: [
			{ key: "format", type: "choice", label: "As", value: "docx", options: [{ value: "docx", label: "Word (.docx)" }, { value: "odt", label: "OpenDocument (.odt)" }] }
		], note: "Layouts with many columns may come out rough." }
	})
	readonly property var spec: root.specs[root.tool] ?? ({ title: "", fields: [] })
	readonly property var shownFields: (root.spec.fields ?? []).filter(field => !field.when || field.when(root.values))
	readonly property string problem: {
		for (const field of root.shownFields)
			if (field.required && String(root.values[field.key] ?? "").trim() === "") return field.type === "password" ? "Type a password" : `${field.label} is needed`;
		if (root.tool === "protect" && root.values.newPassword !== root.values.repeat) return "The passwords are not the same";
		return "";
	}

	function needsAsking(tool) {
		return !!root.specs[tool];
	}

	function open(tool, rows) {
		root.tool = tool;
		root.rows = rows;
		root.order = rows.slice();
		const values = {};
		for (const field of root.specs[tool].fields) if (field.value !== undefined) values[field.key] = field.value;
		if (tool === "compress") values.level = FileLibrary.setting("pdfQuality");
		root.values = values;
		root.show();
		// what the document says about itself comes in for editing
		if (tool === "metadata") Files.request("pdfmeta", { path: rows[0].path }, data => {
			if (data && root.tool === "metadata") root.values = Object.assign({}, root.values, { title: data.title ?? "", author: data.author ?? "", subject: data.subject ?? "", keywords: data.keywords ?? "" });
		});
		// a dialog with something to type starts in it
		Qt.callLater(() => {
			if (root.firstField) root.firstField.focusInput();
			else keys.forceActiveFocus();
		});
	}

	// the first field to type in, if there is one
	property var firstField: null

	function setValue(key, value) {
		root.values = Object.assign({}, root.values, { [key]: value });
	}

	function move(index, by) {
		const next = root.order.slice();
		const target = index + by;
		if (target < 0 || target >= next.length) return;
		const [item] = next.splice(index, 1);
		next.splice(target, 0, item);
		root.order = next;
		Sounds.play("select");
	}

	function run() {
		if (root.problem !== "") {
			Sounds.play("error");
			return;
		}
		const options = Object.assign({}, root.values);
		let paths = root.rows.map(row => row.path);
		if (root.tool === "merge") paths = root.order.map(row => row.path);
		if (root.tool === "pagenumbers") options.position = options.edge === "top" ? options.position.replace("bottom", "top") : options.position;
		if (root.tool === "rotate") options.angle = Number(options.angle);
		delete options.order;
		delete options.repeat;
		Files.pdfTool(root.tool, paths, options);
		root.hide();
	}

	cardWidth: 460
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onReturnPressed: root.run()
		Keys.onEnterPressed: root.run()
	}

	ColumnLayout {
		width: parent.width
		spacing: 14

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.danger, 0.18))

				Glyph {
					anchors.centerIn: parent
					icon: String(root.spec.icon || "file_pdf_box")
					size: 20
					color: Theme.danger
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: String(root.spec.title || "")
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.rows.length === 1 ? root.rows[0].name : `${root.rows.length} files`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		Repeater {
			model: root.shownFields

			delegate: ColumnLayout {
				id: fieldItem

				required property var modelData
				required property int index

				Layout.fillWidth: true
				spacing: 6

				StyledText {
					visible: fieldItem.modelData.type !== "switch"
					text: fieldItem.modelData.label
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				// typed: pages, names, passwords
				Field {
					visible: fieldItem.modelData.type === "text" || fieldItem.modelData.type === "password"
					Layout.fillWidth: true
					password: fieldItem.modelData.type === "password"
					placeholder: String(fieldItem.modelData.placeholder || "")
					text: String(root.values[fieldItem.modelData.key] ?? "")
					onTextChanged: if (text !== String(root.values[fieldItem.modelData.key] ?? "")) root.setValue(fieldItem.modelData.key, text)
					onAccepted: root.run()
					onEscapePressed: root.hide()
					Component.onCompleted: if (fieldItem.index === 0 && (fieldItem.modelData.type === "text" || fieldItem.modelData.type === "password")) root.firstField = this
					Component.onDestruction: if (root.firstField === this) root.firstField = null
				}

				Segmented {
					visible: fieldItem.modelData.type === "choice"
					Layout.fillWidth: true
					height: 32
					options: fieldItem.modelData.options ?? []
					current: String(root.values[fieldItem.modelData.key] ?? "")
					onSelected: value => {
						Sounds.play("select");
						root.setValue(fieldItem.modelData.key, value);
					}
				}

				PillSlider {
					visible: fieldItem.modelData.type === "slider"
					Layout.fillWidth: true
					height: 26
					value: Number(root.values[fieldItem.modelData.key] ?? 0.2) / 0.6
					valueText: `${Math.round(Number(root.values[fieldItem.modelData.key] ?? 0.2) * 100)} %`
					onMoved: v => root.setValue(fieldItem.modelData.key, Math.max(0.05, Math.round(v * 0.6 * 100) / 100))
				}

				RowLayout {
					visible: fieldItem.modelData.type === "switch"
					Layout.fillWidth: true

					StyledText {
						Layout.fillWidth: true
						text: fieldItem.modelData.label
					}

					Toggle {
						checked: !!root.values[fieldItem.modelData.key]
						onToggled: on => root.setValue(fieldItem.modelData.key, on)
					}
				}

				// the files to merge, in the order they go in
				Rectangle {
					visible: fieldItem.modelData.type === "order"
					Layout.fillWidth: true
					Layout.preferredHeight: Math.min(240, orderColumn.implicitHeight + 8)
					radius: Theme.radius.medium
					color: Theme.layer2
					clip: true

					Flickable {
						anchors.fill: parent
						anchors.margins: 4
						contentHeight: orderColumn.implicitHeight
						boundsBehavior: Flickable.StopAtBounds

						Column {
							id: orderColumn

							width: parent.width
							spacing: 2

							move: Transition {
								NumberAnimation {
									property: "y"
									duration: Motion.medium
									easing.type: Easing.BezierSpline
									easing.bezierCurve: Motion.spatial
								}
							}

							Repeater {
								model: root.order

								delegate: Rectangle {
									id: orderRow

									required property var modelData
									required property int index

									width: orderColumn.width
									height: 34
									radius: Theme.radius.small
									color: Qt.alpha(Theme.layer3, orderMouse.containsMouse ? 1 : 0)

									MouseArea {
										id: orderMouse

										anchors.fill: parent
										hoverEnabled: true
										acceptedButtons: Qt.NoButton
									}

									StyledText {
										x: 10
										anchors.verticalCenter: parent.verticalCenter
										width: parent.width - 90
										text: `${orderRow.index + 1}.  ${orderRow.modelData.name}`
										elide: Text.ElideMiddle
									}

									Row {
										anchors.right: parent.right
										anchors.rightMargin: 4
										anchors.verticalCenter: parent.verticalCenter

										IconButton {
											width: 28
											height: 28
											iconSize: 15
											icon: "arrow_up"
											enabled: orderRow.index > 0
											onClicked: root.move(orderRow.index, -1)
										}
										IconButton {
											width: 28
											height: 28
											iconSize: 15
											icon: "arrow_down"
											enabled: orderRow.index < root.order.length - 1
											onClicked: root.move(orderRow.index, 1)
										}
									}
								}
							}
						}
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: !!root.spec.note
			text: String(root.spec.note || "")
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: root.problem
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
				opacity: root.problem !== "" ? 1 : 0

				Behavior on opacity {
					Anim {}
				}
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: String(root.spec.action || "Start")
				variant: "filled"
				icon: "check"
				enabled: root.problem === ""
				opacity: enabled ? 1 : 0.5
				onClicked: root.run()
			}
		}
	}
}
