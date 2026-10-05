pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A new chat: who it goes to, what it is about and the first message. People
// that are known are offered while an address is typed.
ColumnLayout {
	id: root

	property string account: Mail.accounts[0]?.id ?? ""
	property bool more: false
	property string error: ""
	property int pending: 0
	// the recipient field that is typed in
	property var active: to
	readonly property string token: String(root.active?.text ?? "").split(/[,;]\s*/).pop().trim().toLowerCase()
	readonly property var offers: root.token.length < 2 ? [] : Mail.people.filter(person => person.name.toLowerCase().includes(root.token) || person.email.includes(root.token)).slice(0, 5)

	signal done

	function start(recipient) {
		to.text = recipient ? `${recipient}, ` : "";
		cc.text = "";
		bcc.text = "";
		subject.text = "";
		composer.clear();
		root.error = "";
		root.more = false;
		if (!Mail.account(root.account)) root.account = Mail.accounts[0]?.id ?? "";
		Qt.callLater(() => (recipient ? subject : to).focusInput());
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

	function send() {
		const recipients = root.addresses(to.text);
		if (recipients.length === 0) {
			root.error = "No recipient";
			return;
		}
		root.error = "";
		root.pending = Mail.send({
			account: root.account,
			mode: "new",
			to: recipients,
			cc: root.addresses(cc.text),
			bcc: root.addresses(bcc.text),
			subject: subject.text.trim(),
			text: composer.text,
			files: composer.files
		});
	}

	spacing: 8

	Connections {
		target: Mail
		function onSent(request, ok, error) {
			if (request !== root.pending) return;
			root.pending = 0;
			if (ok) root.done();
			else root.error = error;
		}
	}

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
		busy: Mail.sending
		onSubmit: root.send()
	}
}
