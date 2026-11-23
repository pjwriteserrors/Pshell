pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The accelerator picking the fastest connections, while it does: measuring
// every connection, the host's other addresses tried beside them, new
// connections against the slowest (their speed lines against its, and how far
// until it decides), the outcome, or a slow connection's part being taken
// over; and the host's addresses with what each sent.
Item {
	id: root

	// the daemon's job.pick: { on, phase, duels, won, steals, fights, last, lines, progress, addrs }
	property var pick: ({})
	readonly property string phase: root.pick?.phase ?? "idle"
	readonly property bool active: (root.pick?.on ?? false) && root.phase !== "idle"
	// the last fights' lines stay for their outcome
	property var held: []
	readonly property var fights: (root.pick?.fights?.length ?? 0) > 0 ? root.pick.fights : (root.phase === "result" ? root.held : [])
	readonly property var last: root.pick?.last ?? null
	readonly property bool won: root.last?.won ?? false
	readonly property var tints: [Theme.primary, Theme.secondary, Theme.tertiary]

	onPickChanged: if ((root.pick?.fights?.length ?? 0) > 0) root.held = root.pick.fights

	implicitHeight: root.active ? column.implicitHeight : 0
	opacity: root.active ? 1 : 0
	visible: implicitHeight > 0.5 || opacity > 0.01
	clip: true

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.long
		}
	}
	Behavior on opacity {
		Anim {
			duration: Motion.medium
		}
	}

	function short(addr) {
		const text = String(addr || "");
		if (text.includes(":") && text.length > 18) {
			const parts = text.split(":");
			return `${parts.slice(0, 2).join(":")}…${parts[parts.length - 1]}`;
		}
		return text;
	}

	function lastOf(values) {
		const known = (values || []).filter(v => v !== null && v !== undefined);
		return known.length ? known[known.length - 1] : 0;
	}

	function tint(index) {
		return root.fights.length > 1 ? root.tints[index % root.tints.length] : Theme.primary;
	}

	ColumnLayout {
		id: column

		width: parent.width
		spacing: 6

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Glyph {
				id: sign

				icon: ({ measure: "radar", scout: "server_network", duel: "swap_horizontal", result: root.won ? "check_bold" : "undo", steal: "content_cut", fewer: "minus", more: "plus", enough: "check" })[root.phase] ?? "radar"
				size: 14
				color: root.phase === "result" ? (root.won ? Theme.success : Theme.textMuted) : Theme.primary

				SequentialAnimation on opacity {
					running: root.phase === "measure" || root.phase === "duel" || root.phase === "scout" || root.phase === "fewer" || root.phase === "more"
					loops: Animation.Infinite
					onRunningChanged: if (!running) sign.opacity = 1
					NumberAnimation { to: 0.4; duration: 700; easing.type: Easing.InOutSine }
					NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: {
					const count = root.fights.length;
					switch (root.phase) {
					case "measure":
						return `Measuring ${root.pick?.lines?.length ?? 0} connections`;
					case "scout": {
						const scouts = root.fights.filter(fight => fight.why === "scout");
						return scouts.length === 1 ? `Trying ${root.short(scouts[0].addr)}` : `Trying ${scouts.length} other addresses`;
					}
					case "duel":
						return count > 1 ? `${count} new connections against the slowest` : "New connection against the slowest";
					case "result":
						if (!root.won) return "The old connection stays";
						return root.last?.old > 0 ? `New connection kept  ·  ×${(root.last.new / root.last.old).toFixed(1)}` : "New connection kept";
					case "steal":
						return "Taking over from a slow connection";
					case "fewer":
					case "more":
						return `Trying ${root.pick?.step?.to ?? 0} connections instead of ${root.pick?.step?.from ?? 0}`;
					case "enough":
						return `${root.pick?.count ?? 0} connections are as fast`;
					}
					return "";
				}
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tone: root.phase === "result" && root.won ? Theme.success : Theme.textMuted
				elide: Text.ElideRight
			}

			StyledText {
				visible: (root.pick?.duels ?? 0) > 0
				text: `${root.pick?.won ?? 0} of ${root.pick?.duels ?? 0} swapped`
				font.pixelSize: Theme.size.tiny
				tone: Theme.textSubtle
				tabular: true
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 58
			radius: Theme.radius.medium
			color: Qt.alpha(Theme.base, 0.35)
			clip: true

			// the last seconds: every connection, or while new ones are measured only them and the slowest they face
			PickChart {
				anchors.fill: parent
				anchors.topMargin: 8
				anchors.bottomMargin: 2
				slots: 2
				series: {
					const out = [];
					const lines = root.fights.length > 0 ? [] : (root.pick?.lines ?? []);
					const rates = lines.map(line => line.rate);
					const low = Math.min(...rates, Infinity);
					const high = Math.max(...rates, 1);
					for (const line of lines) {
						const slowest = lines.length > 1 && line.rate === low && low < 0.6 * high;
						out.push({ values: line.curve, color: slowest ? Theme.textMuted : Qt.alpha(Theme.primary, 0.3 + 0.6 * line.rate / high), width: 1.5 });
					}
					root.fights.forEach((fight, index) => {
						if ((fight.old?.length ?? 0) > 0) out.push({ values: fight.old, color: Theme.textMuted, width: 2, dot: root.phase !== "result" });
						out.push({ values: fight.new, color: root.tint(index), width: 2.5, fill: root.fights.length === 1, dot: root.phase !== "result" });
					});
					return out;
				}
			}

			// until the connections are judged, or until the new ones are
			Rectangle {
				readonly property real share: root.phase === "measure" ? (root.pick?.progress ?? 0) : ((root.phase === "duel" || root.phase === "scout") && root.fights.length ? root.fights.reduce((sum, fight) => sum + (fight.progress ?? 0), 0) / root.fights.length : ((root.phase === "fewer" || root.phase === "more") ? (root.pick?.step?.progress ?? 0) : 0))

				anchors.bottom: parent.bottom
				height: 2
				width: parent.width * share
				visible: share > 0
				color: Theme.primary

				Behavior on width {
					NumberAnimation {
						duration: 900
					}
				}
			}
		}

		// who is who
		Flow {
			Layout.fillWidth: true
			visible: root.fights.length > 0
			spacing: 14

			Repeater {
				model: {
					const out = [];
					root.fights.forEach((fight, index) => {
						out.push({ label: fight.why === "scout" ? "" : "New", addr: fight.addr, rate: root.lastOf(fight.new), color: root.tint(index), waiting: fight.connecting });
					});
					const old = root.fights.find(fight => (fight.old?.length ?? 0) > 0);
					if (old) out.push({ label: "Slowest", addr: old.oldAddr, rate: root.lastOf(old.old), color: Theme.textMuted, waiting: false });
					return out;
				}

				delegate: RowLayout {
					id: who

					required property var modelData
					spacing: 5

					Rectangle {
						implicitWidth: 8
						implicitHeight: 8
						radius: 4
						color: who.modelData.color
					}

					StyledText {
						visible: text !== ""
						text: who.modelData.label
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
						tone: Theme.textMuted
					}

					StyledText {
						visible: text !== ""
						text: root.short(who.modelData.addr)
						font.pixelSize: Theme.size.tiny
						tone: Theme.textSubtle
					}

					Spinner {
						visible: who.modelData.waiting
						Layout.preferredWidth: 9
						Layout.preferredHeight: 9
						color: who.modelData.color
					}

					StyledText {
						visible: !who.modelData.waiting
						text: Format.rate(who.modelData.rate)
						font.pixelSize: Theme.size.tiny
						tone: who.modelData.color
						tabular: true
					}
				}
			}
		}

		// the host's addresses
		Flow {
			Layout.fillWidth: true
			visible: (root.pick?.addrs?.length ?? 0) > 1
			spacing: 6

			Repeater {
				model: root.pick?.addrs ?? []

				delegate: Rectangle {
					id: chip

					required property var modelData
					readonly property color tint: chip.modelData.state === "lead" ? Theme.primary : (chip.modelData.state === "dead" ? Theme.danger : (chip.modelData.state === "trying" ? Theme.secondary : Theme.textMuted))

					implicitWidth: chipRow.implicitWidth + 14
					implicitHeight: 20
					radius: 10
					color: chip.modelData.state === "lead" ? Qt.alpha(Theme.primary, 0.14) : Theme.layer2
					opacity: chip.modelData.state === "untried" ? 0.6 : 1

					RowLayout {
						id: chipRow

						anchors.centerIn: parent
						spacing: 4

						Glyph {
							icon: chip.modelData.state === "dead" ? "close" : (chip.modelData.state === "lead" ? "check" : "server_network")
							size: 10
							color: chip.tint
						}

						StyledText {
							text: root.short(chip.modelData.addr)
							font.pixelSize: Theme.size.tiny
							tone: chip.tint
						}

						StyledText {
							visible: chip.modelData.speed > 0
							text: Format.rate(chip.modelData.speed)
							font.pixelSize: Theme.size.tiny
							tone: Theme.textSubtle
							tabular: true
						}
					}
				}
			}
		}
	}
}
