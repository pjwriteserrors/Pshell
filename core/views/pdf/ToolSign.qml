pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"
import "Edit.js" as Edit

// Signing: a signature of yours – drawn here, typed, a picture of one, or
// signed with a finger on the phone – kept for next time and put on the page
// with a click (then moved and resized like any mark). Beside it the date.
// And a real digital signature with a certificate, which shows anyone that
// the file was not changed since; the signatures a file has are checked here.
PaneFrame {
	id: root

	property Item dock: null
	readonly property var saved: Pdf.setting("signatures", []) || []
	property var status: ({ installed: false, installing: false, cert: "" })
	property var existing: []
	property string certName: ""
	property string certMail: ""
	property string certPassword: ""
	property string reason: "I agree with this document"
	property string where: ""

	title: "Sign"
	subtitle: root.saved.length > 0 ? "Click one, then click on the page where it goes" : "Make your signature once – it is kept"
	onClose: Pdf.tool = ""

	Component.onCompleted: {
		root.refresh();
		if ((Pdf.meta?.signatures ?? 0) > 0) Pdf.request("sigs", { path: Pdf.path }, data => root.existing = data?.signatures ?? []);
	}

	function refresh() {
		Pdf.request("sigstatus", {}, data => {
			if (data) root.status = data;
		});
	}

	// on the page with the next click, sized for a signature line
	function place(image, w, h) {
		const width = 150, height = h > 0 && w > 0 ? Math.max(16, width * h / w) : 50;
		Pdf.placing = { kind: "signature", image: image, w: width, h: Math.round(height) };
		Pdf.say("Click where it goes – Escape lets it be", "draw_pen");
	}

	function placeDate() {
		const p = Pdf.pages[Pdf.page];
		if (!p) return;
		const size = Pdf.baseSize(p);
		Pdf.addItem({ kind: "textbox", page: p.id, rect: [size.width * 0.62, size.height * 0.86, 120, 18], text: Edit.today(), size: 11, color: "#000000", fill: "", font: "Helvetica", align: "left" }, "Date written");
		Pdf.draw = "select";
	}

	// ── yours ──────────────────────────────────────────────────────────────
	Flow {
		width: parent.width
		spacing: 8

		Repeater {
			model: root.saved

			delegate: Rectangle {
				id: sig

				required property var modelData
				required property int index
				readonly property bool placing: Pdf.placing?.image === sig.modelData.image

				width: (root.bodyWidth - 8) / 2
				height: 70
				radius: Theme.radius.medium
				color: "white"
				border.color: sig.placing ? Theme.primary : (sigMouse.containsMouse ? Theme.textFaint : Theme.outline)
				border.width: sig.placing ? 2.5 : 1
				scale: sigMouse.pressed ? 0.96 : 1

				Behavior on scale {
					SpatialAnim {}
				}

				Image {
					anchors.fill: parent
					anchors.margins: 8
					source: Pdf.fileUrl(sig.modelData.image)
					fillMode: Image.PreserveAspectFit
					asynchronous: true
					mipmap: true
				}

				MouseArea {
					id: sigMouse

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.place(sig.modelData.image, sig.modelData.w, sig.modelData.h)
				}

				IconButton {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 2
					implicitWidth: 26
					implicitHeight: 26
					iconSize: 14
					visible: sigMouse.containsMouse || hovered
					icon: "close"
					onClicked: Pdf.setSetting("signatures", root.saved.filter((s, i) => i !== sig.index))
				}
			}
		}
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Draw"
			icon: "draw"
			variant: root.saved.length === 0 ? "filled" : "tonal"
			onActivated: root.dock?.sheet("SignaturePad.qml", { mode: "draw", done: (image, w, h) => root.place(image, w, h) })
		}

		TextButton {
			text: "Type"
			icon: "keyboard_outline"
			onActivated: root.dock?.sheet("SignaturePad.qml", { mode: "type", done: (image, w, h) => root.place(image, w, h) })
		}

		TextButton {
			text: "Initials"
			icon: "alphabetical"
			onActivated: root.dock?.sheet("SignaturePad.qml", { mode: "draw", purpose: "Initials", done: (image, w, h) => root.place(image, w * 0.5, h * 0.5) })
		}

		TextButton {
			text: "With the phone"
			icon: "cellphone"
			onActivated: {
				Pdf.bridgeStart("sign");
				root.dock?.sheet("BridgeSheet.qml", { kind: "sign", done: image => {
					const list = root.saved.concat([{ image: image, w: 300, h: 100, name: "Signature", at: Date.now() }]);
					Pdf.setSetting("signatures", list);
					root.place(image, 300, 100);
				} });
			}
		}

		TextButton {
			text: "A picture…"
			icon: "image_outline"
			onActivated: Files.pick({ title: "A picture of your signature", filters: ["*.png", "*.jpg", "*.jpeg", "*.webp"] }, paths => {
				if (!paths || paths.length === 0) return;
				Pdf.setSetting("signatures", root.saved.concat([{ image: paths[0], w: 300, h: 100, name: "Signature", at: Date.now() }]));
				root.place(paths[0], 300, 100);
			})
		}

		TextButton {
			text: "Today's date"
			icon: "calendar_today"
			onActivated: root.placeDate()
		}
	}

	// ── with a certificate ─────────────────────────────────────────────────
	SectionLabel {
		text: "Digital signature"
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
		text: "Signed with your certificate when it is saved – anyone can then see that nothing was changed after. Do it last: a later change breaks it."
	}

	TextButton {
		visible: !root.status.installed
		text: root.status.installing || Pdf.runningJobs.some(j => j.kind === "sigsetup") ? "Setting up…" : "Set it up (installs pyHanko)"
		icon: "download_outline"
		busy: root.status.installing || Pdf.runningJobs.some(j => j.kind === "sigsetup")
		onActivated: Pdf.startJob("sigsetup", {}, "Setting up signing", () => root.refresh())
	}

	Column {
		width: parent.width
		spacing: 6
		visible: root.status.installed && !root.status.cert

		StyledText {
			text: "A certificate of your own"
			font.weight: Font.DemiBold
		}

		Field {
			width: parent.width
			height: 36
			placeholder: "Your name"
			onEdited: value => root.certName = value
		}

		Field {
			width: parent.width
			height: 36
			placeholder: "Your mail"
			onEdited: value => root.certMail = value
		}

		Field {
			width: parent.width
			height: 36
			password: true
			placeholder: "A password for it"
			onEdited: value => root.certPassword = value
		}

		TextButton {
			text: "Make it"
			icon: "certificate_outline"
			enabled: root.certName.trim() !== "" && root.certPassword !== ""
			onActivated: Pdf.request("certmake", { name: root.certName, email: root.certMail, password: root.certPassword }, data => {
				if (data?.cert) {
					root.refresh();
					Pdf.say("Your certificate is made", "certificate_outline");
				}
			})
		}
	}

	Column {
		width: parent.width
		spacing: 8
		visible: root.status.installed && !!root.status.cert

		Field {
			width: parent.width
			height: 36
			placeholder: "Why (reason)"
			text: root.reason
			onEdited: value => root.reason = value
		}

		Field {
			width: parent.width
			height: 36
			placeholder: "Where (place)"
			onEdited: value => root.where = value
		}

		Field {
			id: certPass

			width: parent.width
			height: 36
			password: true
			placeholder: "The certificate's password"
		}

		PaneLine {
			label: "Sign when saving"
			detail: Pdf.recipe.finish?.sign ? `On page ${(Pdf.recipe.finish.sign.pageIndex ?? Pdf.pageCount - 1) + 1}${Pdf.recipe.finish.sign.rect ? ", in the chosen signature's box" : ", not shown on the page"}` : "Choose your signature on the page first to show it there"

			Toggle {
				checked: !!Pdf.recipe.finish?.sign
				onToggled: on => {
					if (!on) return Pdf.setFinish("sign", null, "Not signed digitally");
					const chosen = Pdf.selected.map(id => Pdf.itemById(id)).find(item => item && item.kind === "signature");
					Pdf.setFinish("sign", { cert: root.status.cert, password: certPass.text, reason: root.reason, location: root.where,
						pageIndex: chosen ? Pdf.indexOf(chosen.page) : Pdf.page, rect: chosen ? chosen.rect : null, field: "Signature" }, "Signed digitally when saved");
				}
			}
		}
	}

	// ── what the file has ──────────────────────────────────────────────────
	SectionLabel {
		visible: root.existing.length > 0
		text: "Signed already"
	}

	Repeater {
		model: root.existing

		delegate: Row {
			required property var modelData

			spacing: 10
			width: parent.width

			Glyph {
				icon: modelData.valid ? "check_decagram" : "alert_decagram_outline"
				size: 20
				color: modelData.valid ? Theme.success : Theme.danger
			}

			Column {
				width: parent.width - 30

				StyledText {
					text: modelData.signer || "Someone"
					font.weight: Font.DemiBold
				}

				StyledText {
					width: parent.width
					text: `${modelData.time || ""} · ${modelData.text || (modelData.valid ? "valid" : "not valid")}`
					wrapMode: Text.WordWrap
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}
			}
		}
	}
}
