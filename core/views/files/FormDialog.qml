pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A dialog of a few questions, drawn from a list of fields: the size of a
// picture, the text of a watermark, a rule, a commit, a share, a vault.
//
//   open({ title, subtitle, icon, accent, action, note, fields, check(values) → problem }, done(values))
//
// A field is { key, type, label, value, placeholder, options, required, when(values), min, max, unit, hint }:
// text, password, area (several lines), choice (a few, side by side),
// menu (many, a row of chips), switch, slider (min … max, unit), path
// (a folder, with the one that is open offered), info (a line to read).
DialogFrame {
	id: root

	property var spec: ({ fields: [] })
	property var values: ({})
	property var done: null
	readonly property var shownFields: (root.spec.fields ?? []).filter(field => !field.when || field.when(root.values))
	readonly property string problem: {
		for (const field of root.shownFields)
			if (field.required && String(root.values[field.key] ?? "").trim() === "") return field.type === "password" ? "Type a password" : `${field.label} is needed`;
		return typeof root.spec.check === "function" ? String(root.spec.check(root.values) || "") : "";
	}
	readonly property color accent: root.spec.accent ?? Theme.primary
	// the folder that is open, for path fields
	property string here: ""

	function open(spec, done) {
		root.spec = spec;
		root.done = done;
		const values = {};
		for (const field of spec.fields ?? []) if (field.value !== undefined) values[field.key] = field.value;
		root.values = values;
		root.cardWidth = spec.width ?? 460;
		root.show();
		Qt.callLater(() => {
			if (root.firstField) root.firstField.focusInput();
			else keys.forceActiveFocus();
		});
	}

	// a form that learns more after it opened (tags read from the file)
	function merge(changes) {
		root.values = Object.assign({}, root.values, changes);
	}

	property var firstField: null

	function setValue(key, value) {
		root.values = Object.assign({}, root.values, { [key]: value });
	}

	function run() {
		if (root.problem !== "") {
			Sounds.play("error");
			return;
		}
		const done = root.done;
		const values = Object.assign({}, root.values);
		root.hide();
		if (done) done(values);
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
				color: Qt.tint(Theme.layer2, Qt.alpha(root.accent, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: String(root.spec.icon || "tune_variant")
					size: 20
					color: root.accent
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: String(root.spec.title || "")
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					visible: text !== ""
					text: String(root.spec.subtitle || "")
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		Flickable {
			id: scroller

			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(fields.implicitHeight, Math.max(160, root.height - 260))
			contentHeight: fields.implicitHeight
			clip: true
			interactive: contentHeight > height
			boundsBehavior: Flickable.StopAtBounds

			ColumnLayout {
				id: fields

				width: scroller.width
				spacing: 12

				// every field stays made (a field typed in keeps its keys); the ones not asked now hide
				Repeater {
					model: root.spec.fields ?? []

					delegate: ColumnLayout {
						id: fieldItem

						required property var modelData
						required property int index
						readonly property string type: String(fieldItem.modelData.type || "text")
						readonly property var value: root.values[fieldItem.modelData.key]

						Layout.fillWidth: true
						// modelData is a copy: the field's own condition is asked again
						visible: !fieldItem.modelData.when || fieldItem.modelData.when(root.values)
						spacing: 6

						StyledText {
							visible: fieldItem.type !== "switch" && fieldItem.type !== "info" && !!fieldItem.modelData.label
							text: String(fieldItem.modelData.label || "")
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						Field {
							visible: fieldItem.type === "text" || fieldItem.type === "password" || fieldItem.type === "path"
							Layout.fillWidth: true
							password: fieldItem.type === "password"
							icon: fieldItem.type === "path" ? "folder_outline" : ""
							placeholder: String(fieldItem.modelData.placeholder || "")
							readonly property bool mine: fieldItem.type === "text" || fieldItem.type === "password" || fieldItem.type === "path"

							// the card is layer1 already: the field stands out from it
							color: focused ? Theme.layer3 : Theme.layer2
							text: mine ? String(fieldItem.value ?? "") : ""
							onTextChanged: if (mine && text !== String(fieldItem.value ?? "")) root.setValue(fieldItem.modelData.key, text)
							onAccepted: root.run()
							onEscapePressed: root.hide()
							Component.onCompleted: if (!root.firstField && (fieldItem.type === "text" || fieldItem.type === "password")) root.firstField = this
							Component.onDestruction: if (root.firstField === this) root.firstField = null
						}

						// the folder that is open, a click away
						Flow {
							visible: fieldItem.type === "path" && (fieldItem.modelData.offers ?? []).length > 0
							Layout.fillWidth: true
							spacing: 6

							Repeater {
								model: fieldItem.type === "path" ? (fieldItem.modelData.offers ?? []) : []

								delegate: Chip {
									required property var modelData

									height: 26
									icon: "folder_outline"
									text: Files.pretty(modelData)
									selected: String(fieldItem.value ?? "") === modelData
									onClicked: root.setValue(fieldItem.modelData.key, modelData)
								}
							}
						}

						AreaField {
							visible: fieldItem.type === "area"
							Layout.fillWidth: true
							Layout.preferredHeight: 96
							placeholder: String(fieldItem.modelData.placeholder || "")
							color: focused ? Theme.layer3 : Theme.layer2
							text: fieldItem.type === "area" ? String(fieldItem.value ?? "") : ""
							onEdited: text => {
								if (fieldItem.type === "area" && text !== String(fieldItem.value ?? "")) root.setValue(fieldItem.modelData.key, text);
							}
							Keys.onEscapePressed: root.hide()
							Component.onCompleted: if (fieldItem.type === "area" && !root.firstField) root.firstField = this
							Component.onDestruction: if (root.firstField === this) root.firstField = null
						}

						Segmented {
							visible: fieldItem.type === "choice"
							Layout.fillWidth: true
							height: 32
							options: fieldItem.type === "choice" ? (fieldItem.modelData.options ?? []) : []
							current: String(fieldItem.value ?? "")
							onSelected: value => {
								Sounds.play("select");
								root.setValue(fieldItem.modelData.key, value);
							}
						}

						Flow {
							visible: fieldItem.type === "menu"
							Layout.fillWidth: true
							spacing: 6

							Repeater {
								model: fieldItem.type === "menu" ? (fieldItem.modelData.options ?? []) : []

								delegate: Chip {
									required property var modelData

									height: 30
									icon: String(modelData.icon || "")
									text: String(modelData.label)
									selected: String(fieldItem.value ?? "") === String(modelData.value)
									onClicked: {
										Sounds.play("select");
										root.setValue(fieldItem.modelData.key, modelData.value);
									}
								}
							}
						}

						PillSlider {
							readonly property real low: Number(fieldItem.modelData.min ?? 0)
							readonly property real high: Number(fieldItem.modelData.max ?? 1)

							visible: fieldItem.type === "slider"
							Layout.fillWidth: true
							height: 26
							stepSize: Number(fieldItem.modelData.step ?? 0.01) / Math.max(0.0001, high - low)
							value: (Number(fieldItem.value ?? low) - low) / Math.max(0.0001, high - low)
							valueText: {
								const value = Number(fieldItem.value ?? low);
								const unit = String(fieldItem.modelData.unit ?? "");
								return unit === "%" ? `${Math.round(value * (high <= 1 ? 100 : 1))} %` : `${Math.round(value)}${unit ? " " + unit : ""}`;
							}
							onMoved: v => {
								const step = Number(fieldItem.modelData.step ?? 0.01);
								root.setValue(fieldItem.modelData.key, Math.round((low + v * (high - low)) / step) * step);
							}
						}

						RowLayout {
							visible: fieldItem.type === "switch"
							Layout.fillWidth: true
							spacing: 10

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 1

								StyledText {
									Layout.fillWidth: true
									text: String(fieldItem.modelData.label || "")
									wrapMode: Text.WordWrap
								}

								StyledText {
									Layout.fillWidth: true
									visible: text !== ""
									text: String(fieldItem.modelData.hint || "")
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.small
									wrapMode: Text.WordWrap
								}
							}

							Toggle {
								checked: !!fieldItem.value
								onToggled: on => root.setValue(fieldItem.modelData.key, on)
							}
						}

						// a line to read: a warning, what a rule would take
						Rectangle {
							visible: fieldItem.type === "info"
							Layout.fillWidth: true
							implicitHeight: infoText.implicitHeight + 18
							radius: Theme.radius.medium
							color: Qt.tint(Theme.layer2, Qt.alpha(fieldItem.modelData.tone === "warning" ? Theme.warning : root.accent, 0.12))

							Glyph {
								id: infoGlyph

								x: 10
								y: 9
								icon: String(fieldItem.modelData.icon || (fieldItem.modelData.tone === "warning" ? "alert_outline" : "information_outline"))
								size: 16
								color: fieldItem.modelData.tone === "warning" ? Theme.warning : root.accent
							}

							StyledText {
								id: infoText

								x: 34
								y: 9
								width: parent.width - 44
								text: typeof fieldItem.modelData.text === "function" ? String(fieldItem.modelData.text(root.values)) : String(fieldItem.modelData.text || fieldItem.modelData.label || "")
								font.pixelSize: Theme.size.small
								wrapMode: Text.WordWrap
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
				text: String(root.spec.action || "OK")
				variant: "filled"
				icon: String(root.spec.actionIcon || "check")
				enabled: root.problem === ""
				opacity: enabled ? 1 : 0.5
				onClicked: root.run()
			}
		}
	}
}
