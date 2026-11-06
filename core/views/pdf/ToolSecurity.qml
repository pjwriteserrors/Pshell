pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Locks: a password to open it, what may be done with it (print, copy),
// the password taken off again; and cleaning what is hidden in a file –
// its details, scripts, attachments, earlier versions inside it.
// All of it happens when the file is saved.
PaneFrame {
	id: root

	property Item dock: null
	property string userPassword: Pdf.recipe.finish?.protect?.user ?? ""
	property string ownerPassword: Pdf.recipe.finish?.protect?.owner ?? ""
	property bool allowPrint: Pdf.recipe.finish?.protect?.print ?? true
	property bool allowCopy: Pdf.recipe.finish?.protect?.copy ?? true
	readonly property var finish: Pdf.recipe.finish ?? ({})

	title: "Lock"
	subtitle: Pdf.meta?.encrypted ? "This file is locked" : (root.finish.protect ? "Locked when saved" : "Not locked")
	onClose: Pdf.tool = ""

	function apply() {
		if (root.userPassword === "" && root.ownerPassword === "") return Pdf.say("Give it a password first", "lock_outline");
		Pdf.setFinish("protect", { user: root.userPassword, owner: root.ownerPassword || root.userPassword, print: root.allowPrint, copy: root.allowCopy }, "Locked when saved");
	}

	// ── a password ─────────────────────────────────────────────────────────
	SectionLabel {
		text: "A password"
	}

	Field {
		width: parent.width
		height: 36
		password: true
		icon: "lock_outline"
		placeholder: "To open it"
		text: root.userPassword
		onEdited: value => root.userPassword = value
	}

	Field {
		width: parent.width
		height: 36
		password: true
		icon: "key_outline"
		placeholder: "To change what is allowed (optional)"
		text: root.ownerPassword
		onEdited: value => root.ownerPassword = value
	}

	PaneLine {
		label: "May be printed"

		Toggle {
			checked: root.allowPrint
			onToggled: on => root.allowPrint = on
		}
	}

	PaneLine {
		label: "Text may be copied"

		Toggle {
			checked: root.allowCopy
			onToggled: on => root.allowCopy = on
		}
	}

	Row {
		spacing: 6

		TextButton {
			text: root.finish.protect ? "Change the lock" : "Lock it when saved"
			icon: "lock_outline"
			variant: "filled"
			onActivated: root.apply()
		}

		TextButton {
			visible: !!root.finish.protect
			text: "No lock"
			variant: "ghost"
			onActivated: Pdf.setFinish("protect", null, "Not locked")
		}
	}

	StyledText {
		width: parent.width
		visible: !!root.finish.protect
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.warning
		text: "Keep the password somewhere – without it the file can't be opened."
	}

	// ── unlocked ───────────────────────────────────────────────────────────
	PaneLine {
		visible: !!Pdf.meta?.encrypted
		label: "Take the password off"
		detail: "Saved without a lock (you opened it with the password)"

		Toggle {
			checked: !!root.finish.unlock
			onToggled: on => Pdf.setFinish("unlock", on, on ? "Unlocked when saved" : "Lock kept")
		}
	}

	// ── hidden things ──────────────────────────────────────────────────────
	SectionLabel {
		text: "Hidden in it"
	}

	PaneLine {
		label: "Clean it"
		detail: "Details, who made it with what, scripts, attachments and older versions inside the file go"

		Toggle {
			checked: !!root.finish.sanitize
			onToggled: on => Pdf.setFinish("sanitize", on, on ? "Cleaned when saved" : "Not cleaned")
		}
	}

	TextButton {
		text: "Empty the details only"
		icon: "card_account_details_outline"
		onActivated: Pdf.setMeta({ title: "", author: "", subject: "", keywords: "" })
	}

	StyledText {
		width: parent.width
		visible: (Pdf.meta?.attachments?.length ?? 0) > 0 || !!Pdf.meta?.author
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: [Pdf.meta?.author ? `It says it is by ${Pdf.meta.author}.` : "", Pdf.meta?.creator ? `Made with ${Pdf.meta.creator}.` : "", (Pdf.meta?.attachments?.length ?? 0) > 0 ? `${Pdf.meta.attachments.length} files are attached.` : ""].filter(t => t).join(" ")
	}
}
