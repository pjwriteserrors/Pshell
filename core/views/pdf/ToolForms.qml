pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Forms: the file's fields are typed in right on the page (in reading too);
// here they are listed with their values, filled from your own details in
// one go, emptied, or made fixed for good. New fields are drawn on the page:
// text, a box to tick, a list to choose from, a place for a signature.
PaneFrame {
	id: root

	property Item dock: null
	property bool editingDetails: false

	readonly property var fileFields: Pdf.fields
	readonly property var newFields: Pdf.items.filter(item => item.kind === "field")
	readonly property var valueOf: name => Pdf.recipe.forms?.[name] ?? (root.fileFields.find(f => f.name === name)?.value ?? "")
	readonly property var detailKeys: [
		{ key: "first", label: "First name", match: /(^|[^a-z])(vorname|first.?name|given)/i },
		{ key: "last", label: "Last name", match: /(nachname|last.?name|surname|family|familienname)/i },
		{ key: "name", label: "Full name", match: /(^|[^a-z])(name|full.?name|vollst.ndiger name|antragsteller|unterzeichner)([^a-z]|$)/i },
		{ key: "street", label: "Street and number", match: /(stra(ss|ß)e|street|address.?1|anschrift|adresse)/i },
		{ key: "postcode", label: "Postcode", match: /(plz|postleitzahl|post.?code|zip)/i },
		{ key: "city", label: "City", match: /(^|[^a-z])(ort|stadt|city|wohnort|town)([^a-z]|$)/i },
		{ key: "country", label: "Country", match: /(land|country|staat)/i },
		{ key: "email", label: "Mail", match: /(e-?mail|mail)/i },
		{ key: "phone", label: "Phone", match: /(telefon|phone|tel\.?|mobil|handy)/i },
		{ key: "birthday", label: "Date of birth", match: /(geburts|birth|dob)/i },
		{ key: "iban", label: "IBAN", match: /iban/i },
		{ key: "company", label: "Company", match: /(firma|company|unternehmen|organi[sz]ation)/i },
		{ key: "taxid", label: "Tax number", match: /(steuer|tax)/i }
	]

	title: "Forms"
	subtitle: root.fileFields.length > 0 ? `${root.fileFields.length} ${root.fileFields.length === 1 ? "field" : "fields"} – type in them on the page` : "This file has no form – draw new fields below"
	onClose: Pdf.tool = ""

	Component.onCompleted: Pdf.readOutline()

	// the fields whose names say what they want, filled from `values` ({ key: value })
	function fill(values) {
		const next = Pdf.clone(Pdf.recipe);
		let count = 0;
		const full = values.name || [values.first, values.last].filter(v => v).join(" ");
		for (const f of root.fileFields) {
			if (f.type !== "text" || f.readonly) continue;
			let key = "";
			for (const d of root.detailKeys)
				if (d.match.test(f.name)) {
					key = d.key;
					break;
				}
			const value = key === "name" ? full : (values[key] ?? "");
			if (key && value) {
				next.forms[f.name] = String(value);
				count += 1;
			}
		}
		if (count === 0) return Pdf.say("No field names here that say what they want", "information_outline");
		Pdf.commit(next, `${count} fields filled`);
		Pdf.say(`${count} ${count === 1 ? "field" : "fields"} filled – look them over`, "form_textbox");
	}

	function identityValues(identity) {
		return { first: identity.first, last: identity.last, street: identity.street, postcode: identity.postcode, city: identity.city, country: identity.country,
			email: identity.mail?.address ?? "", phone: identity.phone?.number ?? "", birthday: identity.birthday };
	}

	// ── fill ───────────────────────────────────────────────────────────────
	Flow {
		width: parent.width
		spacing: 6
		visible: root.fileFields.length > 0

		TextButton {
			text: "Fill from my details"
			icon: "account_box_outline"
			variant: "filled"
			onActivated: Object.keys(Pdf.details).length === 0 ? root.editingDetails = true : root.fill(Pdf.details)
		}

		TextButton {
			text: root.editingDetails ? "Done" : "My details…"
			icon: "account_edit_outline"
			onActivated: root.editingDetails = !root.editingDetails
		}

		TextButton {
			text: "Empty all"
			icon: "form_textbox"
			confirm: true
			onActivated: {
				const next = Pdf.clone(Pdf.recipe);
				for (const f of root.fileFields) next.forms[f.name] = f.type === "check" ? false : "";
				Pdf.commit(next, "Form emptied");
			}
		}
	}

	// an identity of the identities plugin, for forms nobody needs the real you in
	Flow {
		width: parent.width
		spacing: 6
		visible: root.fileFields.length > 0 && Identities.enabled && Identities.saved.length > 0

		StyledText {
			text: "As"
			height: 30
			verticalAlignment: Text.AlignVCenter
			tone: Theme.textMuted
		}

		Repeater {
			model: Identities.saved.slice(0, 6)

			delegate: Chip {
				required property var modelData

				text: Identities.name(modelData)
				icon: "incognito"
				onClicked: root.fill(root.identityValues(modelData))
			}
		}
	}

	// your details, kept in pdf.json
	Column {
		width: parent.width
		spacing: 6
		visible: root.editingDetails

		Repeater {
			model: root.detailKeys

			delegate: Field {
				required property var modelData

				width: parent.width
				height: 36
				placeholder: modelData.label
				text: Pdf.details[modelData.key] ?? ""
				onEdited: value => Pdf.setSetting("details", Object.assign({}, Pdf.details, { [modelData.key]: value }))
			}
		}
	}

	// ── the file's fields ──────────────────────────────────────────────────
	SectionLabel {
		visible: root.fileFields.length > 0
		text: "Fields"
	}

	Repeater {
		model: root.fileFields.slice(0, 300)

		delegate: Item {
			id: line

			required property var modelData
			readonly property var f: line.modelData
			readonly property var value: root.valueOf(line.f.name)

			width: parent.width
			height: line.f.type === "text" ? 58 : 40

			StyledText {
				id: name

				width: parent.width - 30
				text: `${line.f.name}${line.f.required ? " *" : ""} · p. ${(Pdf.pages.findIndex(p => p.src === "a" && p.n === line.f.page)) + 1}`
				elide: Text.ElideMiddle
				font.pixelSize: Theme.size.small
				tone: line.f.required && !line.value ? Theme.danger : Theme.textMuted

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						const i = Pdf.pages.findIndex(p => p.src === "a" && p.n === line.f.page);
						if (i >= 0) Pdf.goTo(i, Math.max(0, line.f.rect[1] - 80));
					}
				}
			}

			Field {
				anchors.top: name.bottom
				anchors.topMargin: 4
				width: parent.width
				height: 34
				visible: line.f.type === "text"
				enabled: !line.f.readonly
				placeholder: line.f.readonly ? "Fixed" : "Empty"
				text: String(line.value ?? "")
				onAccepted: Pdf.setForm(line.f.name, text)
				onFocusedChanged: if (!focused && text !== String(line.value ?? "")) Pdf.setForm(line.f.name, text)
			}

			Toggle {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				visible: line.f.type === "check"
				checked: !!line.value
				onToggled: on => Pdf.setForm(line.f.name, on)
			}

			Flow {
				anchors.top: name.bottom
				anchors.topMargin: 4
				width: parent.width
				spacing: 4
				visible: line.f.type === "choice" || line.f.type === "radio"

				Repeater {
					model: line.f.type === "radio" ? [line.f.on] : (line.f.options ?? [])

					delegate: Chip {
						required property var modelData

						text: String(modelData)
						selected: String(line.value) === String(modelData)
						onClicked: Pdf.setForm(line.f.name, String(modelData))
					}
				}
			}
		}
	}

	PaneLine {
		visible: root.fileFields.length > 0
		label: "Fixed for good"
		detail: "When saved, the fields become part of the page and can't be changed any more"

		Toggle {
			checked: !!Pdf.recipe.finish?.flatten
			onToggled: on => Pdf.setFinish("flatten", on, on ? "Fields made fixed" : "Fields left open")
		}
	}

	// ── new fields ─────────────────────────────────────────────────────────
	SectionLabel {
		text: "Make new fields"
	}

	Row {
		width: parent.width
		spacing: 6

		Repeater {
			model: [{ id: "text", label: "Text", icon: "form_textbox" }, { id: "check", label: "Tick box", icon: "checkbox_marked_outline" }, { id: "choice", label: "List", icon: "form_dropdown" }, { id: "signature", label: "Signature", icon: "draw_pen" }]

			delegate: Clickable {
				id: kind

				required property var modelData
				readonly property bool current: Pdf.draw === "field" && Pdf.fieldType === kind.modelData.id

				width: (parent.width - 18) / 4
				height: 56
				radius: Theme.radius.medium
				color: kind.current ? Theme.primarySoft : (kind.hovered ? Theme.layer3 : Theme.layer2)
				onClicked: {
					Pdf.fieldType = kind.modelData.id;
					Pdf.draw = kind.current ? "select" : "field";
				}

				Column {
					anchors.centerIn: parent
					spacing: 3

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: kind.modelData.icon
						size: 20
						color: kind.current ? Theme.primary : Theme.text
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: kind.modelData.label
						font.pixelSize: 9
					}
				}
			}
		}
	}

	StyledText {
		width: parent.width
		visible: Pdf.draw === "field"
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "Drag the field's box on the page (a click makes one of a usual size). Double-click it to name it."
	}

	Repeater {
		model: root.newFields

		delegate: Clickable {
			id: made

			required property var modelData

			width: parent.width
			height: 38
			radius: Theme.radius.small
			color: Pdf.selected.includes(made.modelData.id) ? Theme.primarySoft : (made.hovered ? Theme.layer2 : "transparent")
			onClicked: {
				Pdf.goTo(Pdf.indexOf(made.modelData.page), Math.max(0, made.modelData.rect[1] - 80));
				Pdf.draw = "select";
				Pdf.selected = [made.modelData.id];
			}

			Row {
				x: 10
				anchors.verticalCenter: parent.verticalCenter
				spacing: 10

				Glyph {
					icon: ({ check: "checkbox_marked_outline", choice: "form_dropdown", signature: "draw_pen" })[made.modelData.type] ?? "form_textbox"
					size: 16
				}

				StyledText {
					text: `${made.modelData.name} · page ${Pdf.indexOf(made.modelData.page) + 1}${made.modelData.options?.length ? " · " + made.modelData.options.join(", ") : ""}`
					elide: Text.ElideRight
					width: root.bodyWidth - 70
				}
			}
		}
	}
}
