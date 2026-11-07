pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The phone as a pen, a camera or a remote: a page the phone opens from the
// code shown here (in the same network, no app needed). What it sends comes
// back through the helper (Pdf.bridgeEvent): a signature, photos of pages,
// the slides' keys.
Rectangle {
	id: root

	property Item dock: null
	// "sign" | "scan" | "remote"
	property string kind: Pdf.bridgeKind || "sign"
	// a signature that came: done(image)
	property var done: null
	property int received: 0

	width: 420
	height: column.implicitHeight + 44
	radius: Theme.radius.huge
	color: Theme.layer1
	border.color: Theme.outline

	MouseArea {
		anchors.fill: parent
	}

	Connections {
		target: Pdf

		function onBridgeSignature(image) {
			if (root.kind !== "sign") return;
			if (root.done) root.done(image);
			Pdf.bridgeStop();
			root.dock?.closeSheet();
		}

		function onBridged(m) {
			if (m?.kind === "scan" && (m.images?.length ?? 0) > 0) root.received += m.images.length;
		}
	}

	Column {
		id: column

		x: 22
		y: 22
		width: parent.width - 44
		spacing: 14

		StyledText {
			text: ({ sign: "Sign on the phone", scan: "Photograph pages with the phone", remote: "The phone as the remote" })[root.kind] ?? "The phone"
			font.pixelSize: Theme.size.heading
			font.weight: Font.Bold
		}

		StyledText {
			width: parent.width
			wrapMode: Text.WordWrap
			tone: Theme.textMuted
			text: ({
				sign: "Point the phone's camera at the code and sign with your finger. The signature comes here when you tap Done.",
				scan: "Point the phone's camera at the code, take photos of the pages and send them. They are straightened, cleaned and put in after this page.",
				remote: "Point the phone's camera at the code: next, back and the laser on the phone."
			})[root.kind] ?? ""
		}

		// the code, popping in when it is there
		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 240
			height: 240
			radius: Theme.radius.large
			color: "white"

			Image {
				id: qr

				anchors.centerIn: parent
				width: 216
				height: 216
				source: Pdf.bridgeQr ? Pdf.fileUrl(Pdf.bridgeQr) : ""
				smooth: false
				fillMode: Image.PreserveAspectFit
				opacity: status === Image.Ready ? 1 : 0
				scale: status === Image.Ready ? 1 : 0.9

				Behavior on opacity {
					Anim {}
				}

				Behavior on scale {
					SpatialAnim {}
				}
			}

			Spinner {
				anchors.centerIn: parent
				width: 36
				height: 36
				visible: qr.status !== Image.Ready
			}
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: Pdf.bridgeUrl || "Starting…"
			font.family: Theme.monoFamily
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			elide: Text.ElideMiddle
			width: Math.min(implicitWidth, parent.width)
		}

		StyledText {
			visible: root.kind === "scan"
			anchors.horizontalCenter: parent.horizontalCenter
			text: Pdf.runningJobs.some(j => j.kind === "scanpages") ? "Making pages of the photos…" : (root.received > 0 ? "Pages put in – send more, or close" : "Waiting for photos")
			tone: Theme.primary
		}

		Row {
			anchors.right: parent.right
			spacing: 8

			TextButton {
				text: "Copy the address"
				icon: "content_copy"
				variant: "ghost"
				enabled: Pdf.bridgeUrl !== ""
				onActivated: Quickshell.execDetached(["wl-copy", "--", Pdf.bridgeUrl])
			}

			TextButton {
				text: root.kind === "remote" ? "Close (stays on)" : "Close"
				variant: "tonal"
				onActivated: {
					if (root.kind !== "remote") Pdf.bridgeStop();
					root.dock?.closeSheet();
				}
			}
		}
	}
}
