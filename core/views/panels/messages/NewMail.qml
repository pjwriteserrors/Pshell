pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A new chat: who it goes to, what it is about and the first message. People
// that are known are offered while an address is typed; the eye shows the
// mail as it would arrive.
Item {
	id: root

	property string account: Mail.accounts[0]?.id ?? ""
	property bool more: false
	property string error: ""
	// the recipient field that is typed in
	property var active: to
	readonly property string token: String(root.active?.text ?? "").split(/[,;]\s*/).pop().trim().toLowerCase()
	readonly property var offers: root.token.length < 2 ? [] : Mail.people.filter(person => person.name.toLowerCase().includes(root.token) || person.email.includes(root.token)).slice(0, 5)

	signal done

	// a fresh one to `recipient`, or – without one – what was being written
	function start(recipient) {
		const kept = recipient ? null : (Mail.drafts["new"] ?? null);
		to.text = recipient ? `${recipient}, ` : (kept?.to ?? "");
		cc.text = kept?.cc ?? "";
		bcc.text = kept?.bcc ?? "";
		subject.text = kept?.subject ?? "";
		composer.restore(kept);
		root.error = "";
		root.more = cc.text !== "" || bcc.text !== "";
		preview.close();
		if (kept?.account && Mail.account(kept.account)) root.account = kept.account;
		if (!Mail.account(root.account)) root.account = Mail.accounts[0]?.id ?? "";
		Qt.callLater(() => (to.text !== "" ? (subject.text !== "" ? composer : subject) : to).focusInput());
	}

	// what the fields hold, to be put back; null when nothing is written
	function written() {
		if (composer.blank && to.text.trim() === "" && subject.text.trim() === "") return null;
		return Object.assign({ html: "", files: [] }, composer.written() ?? {}, { to: to.text, cc: cc.text, bcc: bcc.text, subject: subject.text, account: root.account });
	}

	function addresses(text) {
		return String(text).split(/[\s,;]+/).map(entry => entry.replace(/^<|>$/g, "")).filter(entry => entry.includes("@"));
	}

	function take(email) {
		const field = root.active;
		const parts = String(field.text).split(/([,;]\s*)/);
		parts[parts.length - 1] = `${email}, `;
		field.text = parts.join("");
		field.focusInput();
	}

	// what is written as a draft, or null while nobody is named
	function draft() {
		const recipients = root.addresses(to.text);
		if (recipients.length === 0) {
			root.error = "No recipient";
			to.focusInput();
			return null;
		}
		root.error = "";
		return {
			account: root.account,
			mode: "new",
			to: recipients,
			cc: root.addresses(cc.text),
			bcc: root.addresses(bcc.text),
			subject: subject.text.trim(),
			text: composer.words(),
			html: composer.markup(),
			files: composer.files
		};
	}

	// into the outbox: it leaves after a moment in which it can be taken back
	function send() {
		const draft = root.draft();
		if (!draft) return;
		Mail.post("new", draft, root.written(), draft.subject || composer.words().slice(0, 200));
		preview.close();
		root.done();
	}

	// what is written is kept once the typing rests
	Timer {
		id: keeping

		interval: 700
		onTriggered: if (root.visible) Mail.keep("new", root.written())
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			IconButton {
				icon: "arrow_left"
				variant: "tonal"
				onClicked: root.done()
			}

			StyledText {
				Layout.fillWidth: true
				text: "New chat"
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			Segmented {
				visible: Mail.accounts.length > 1
				Layout.preferredWidth: Math.min(420, Mail.accounts.length * 170)
				implicitHeight: 34
				current: root.account
				options: Mail.accounts.map(account => ({ value: account.id, label: account.address }))
				onSelected: value => root.account = value
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: to

				Layout.fillWidth: true
				icon: "account"
				placeholder: "To"
				onFocusedChanged: if (focused) root.active = to
				onEdited: keeping.restart()
				onAccepted: subject.focusInput()
			}

			TextButton {
				text: "Cc"
				variant: root.more ? "filled" : "tonal"
				onActivated: root.more = !root.more
			}
		}

		Field {
			id: cc

			Layout.fillWidth: true
			visible: root.more
			icon: "account_multiple"
			placeholder: "Cc"
			onFocusedChanged: if (focused) root.active = cc
		}

		Field {
			id: bcc

			Layout.fillWidth: true
			visible: root.more
			icon: "eye_off"
			placeholder: "Bcc"
			onFocusedChanged: if (focused) root.active = bcc
		}

		Flow {
			Layout.fillWidth: true
			visible: root.offers.length > 0
			spacing: 6

			Repeater {
				model: root.offers

				delegate: Chip {
					required property var modelData

					icon: "account"
					text: modelData.name === modelData.email ? modelData.email : `${modelData.name} · ${modelData.email}`
					onClicked: root.take(modelData.email)
				}
			}
		}

		Field {
			id: subject

			Layout.fillWidth: true
			icon: "text_short"
			placeholder: "Subject"
			autocorrect: true
			onEdited: keeping.restart()
			onAccepted: composer.focusInput()
		}

		Item {
			Layout.fillHeight: true
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.error !== ""
			text: root.error
			tone: Theme.danger
			wrapMode: Text.Wrap
			font.pixelSize: Theme.size.small
		}

		Composer {
			id: composer

			Layout.fillWidth: true
			maxHeight: 360
			people: root.addresses(to.text).map(email => ({ email: email, name: Mail.nameOf(email) }))
			onEdited: keeping.restart()
			onSubmit: root.send()
			onPreview: {
				const draft = root.draft();
				if (draft) preview.show(draft);
			}
		}
	}

	DropZone {
		anchors.fill: parent
		enabled: !preview.open
		onFiles: paths => {
			composer.add(paths);
			composer.focusInput();
		}
	}

	Preview {
		id: preview

		anchors.fill: parent
		onSend: root.send()
	}
}
