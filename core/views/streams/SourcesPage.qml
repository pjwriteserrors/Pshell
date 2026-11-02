pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// What is followed, as a wall of faces. A link of any kind goes in the one field.
Flickable {
	id: root

	property string adding: ""
	property string addError: ""
	property bool showKeys: false
	// the channel waiting for the one to be merged with
	property string mergingFrom: ""

	function add(text) {
		const value = String(text ?? field.text).trim();
		if (!value || root.adding) return;
		root.adding = value;
		root.addError = "";
		field.text = value;
		Streams.call("add", { input: value }, (data, error) => {
			root.adding = "";
			root.addError = error;
			if (!error) field.text = "";
		});
	}

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	onVisibleChanged: if (visible) sync()
	Component.onCompleted: sync()

	function sync() {
		// merged channels are one card, named like their maker
		const cards = [];
		const seen = {};
		for (const item of Streams.ownSources) {
			if (!item.group) {
				cards.push({ key: item.id, name: item.name, favorite: !!item.favorite });
				continue;
			}
			if (seen[item.group]) continue;
			const members = Streams.ownSources.filter(other => other.group === item.group);
			seen[item.group] = true;
			if (members.length < 2) cards.push({ key: item.id, name: item.name, favorite: !!item.favorite });
			else cards.push({ key: `group:${item.group}`, name: Streams.makerName(members), favorite: members.some(other => other.favorite) });
		}
		cards.sort((a, b) => (b.favorite - a.favorite) || a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
		rows.sync(cards.map(card => ({ key: card.key })));
	}

	function mergeInto(id) {
		Streams.call("mergeSources", { ids: [root.mergingFrom, id] });
		root.mergingFrom = "";
	}

	// channels that look like one maker: the same name written together, or one
	// name the start of the other ("Yumi", "YumiLive"), on different cards
	readonly property var sameMaker: {
		const said = Streams.settings.notSameMaker ?? [];
		const plain = item => String(item.name ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
		const card = item => item.group || item.id;
		const own = Streams.ownSources.filter(item => item.kind === "youtube" || item.kind === "twitch");
		const out = [];
		const offered = {};
		for (let i = 0; i < own.length; i += 1) {
			for (let j = i + 1; j < own.length; j += 1) {
				const a = own[i], b = own[j];
				const x = plain(a), y = plain(b);
				if (card(a) === card(b) || x.length < 4 || y.length < 4 || !(x === y || x.startsWith(y) || y.startsWith(x))) continue;
				const key = [a.id, b.id].sort().join("|");
				const pair = [card(a), card(b)].sort().join("|");
				if (said.includes(key) || offered[pair]) continue;
				offered[pair] = true;
				out.push({ key, a, b });
			}
		}
		return out;
	}

	Connections {
		target: Streams

		function onSourcesChanged() {
			root.sync();
		}
	}

	SyncedModel {
		id: rows
	}

	ColumnLayout {
		id: column

		x: 44
		width: root.width - 88
		spacing: 16

		Item {
			Layout.preferredHeight: 64
		}

		Text {
			text: "Channels"
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: 40
			font.weight: Font.Black
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: field

				Layout.fillWidth: true
				Layout.preferredHeight: 46
				icon: "plus"
				fontSize: Theme.size.title
				placeholder: "youtube.com/@channel, a playlist, a Twitch name or a feed"
				onAccepted: root.add()
			}
			BigButton {
				text: root.adding !== "" ? "Looking…" : "Follow"
				onClicked: root.add()
			}
			BigButton {
				implicitWidth: 46
				icon: "key_outline"
				main: false
				onClicked: root.showKeys = !root.showKeys
			}
			BigButton {
				implicitWidth: 46
				icon: "refresh"
				main: false
				onClicked: Streams.call("refresh", {})
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.addError !== ""
			text: root.addError
			color: Theme.danger
			font.pixelSize: Theme.size.body
			wrapMode: Text.Wrap
		}

		KeysBox {
			Layout.fillWidth: true
			shown: root.showKeys || (!Streams.keys.twitch && root.addError.includes("Twitch"))
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.mergingFrom !== ""
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: `Pick the channel to merge with ${Streams.sourceById[root.mergingFrom]?.name ?? ""}. Series can then come from both.`
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
				elide: Text.ElideRight
			}
			TextButton {
				text: "Cancel"
				variant: "ghost"
				onActivated: root.mergingFrom = ""
			}
		}

		// ── channels that look like one maker ───────────────────────────
		Repeater {
			model: root.mergingFrom === "" ? root.sameMaker : []

			delegate: Rectangle {
				id: hint

				required property var modelData

				Layout.fillWidth: true
				Layout.preferredHeight: 52
				radius: Theme.radius.large
				color: Theme.layer1

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 8
					spacing: 12

					Item {
						Layout.preferredWidth: 50
						Layout.preferredHeight: 30

						Avatar {
							width: 30
							height: 30
							source: hint.modelData.a.avatar ?? ""
							name: hint.modelData.a.name ?? ""
							colors: hint.modelData.a.colors ?? null
						}
						Avatar {
							x: 20
							width: 30
							height: 30
							source: hint.modelData.b.avatar ?? ""
							name: hint.modelData.b.name ?? ""
							colors: hint.modelData.b.colors ?? null
						}
					}
					StyledText {
						Layout.fillWidth: true
						text: `${hint.modelData.a.name} (${Streams.sourceKind(hint.modelData.a).split(" · ")[0]}) and ${hint.modelData.b.name} (${Streams.sourceKind(hint.modelData.b).split(" · ")[0]}) look like one maker`
						elide: Text.ElideRight
					}
					TextButton {
						text: "Not the same"
						variant: "ghost"
						onActivated: Streams.setSetting("notSameMaker", [...(Streams.settings.notSameMaker ?? []), hint.modelData.key])
					}
					TextButton {
						text: "Merge"
						icon: "call_merge"
						onActivated: Streams.call("mergeSources", { ids: [hint.modelData.a.id, hint.modelData.b.id] })
					}
				}
			}
		}

		Flow {
			id: wall

			readonly property int columns: Math.max(2, Math.floor(width / 230))
			readonly property real cellWidth: Math.floor(width / wall.columns)

			Layout.fillWidth: true

			move: Transition {
				SpatialAnim {
					properties: "x,y"
					duration: Motion.long
				}
			}

			Repeater {
				model: rows

				delegate: Loader {
					id: slot

					required property string key
					readonly property bool merged: slot.key.startsWith("group:")

					width: slot.merged ? Math.min(2, wall.columns) * wall.cellWidth : wall.cellWidth
					height: 244
					sourceComponent: slot.merged ? groupCard : channelCard

					Component {
						id: channelCard

						ChannelCard {
							key: slot.key
							page: root
						}
					}
					Component {
						id: groupCard

						ChannelGroup {
							key: slot.key
							page: root
						}
					}
				}
			}
		}

		AiBox {
			Layout.fillWidth: true
			Layout.topMargin: 20
		}

		// ── how it plays ────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			Layout.topMargin: 20
			spacing: 12

			SectionHeading {
				text: "Watching"
			}
			RowLayout {
				Layout.fillWidth: true
				StyledText {
					Layout.fillWidth: true
					text: "Play videos in"
				}
				Segmented {
					Layout.preferredWidth: 330
					Layout.preferredHeight: 32
					options: [{ value: "app", label: "This app" }, { value: "mpv", label: "mpv" }, { value: "browser", label: "The browser" }]
					current: Streams.settings.player ?? "app"
					onSelected: value => Streams.setSetting("player", value)
				}
			}
			RowLayout {
				Layout.fillWidth: true
				StyledText {
					Layout.fillWidth: true
					text: "Go on to the next episode after a countdown"
				}
				Toggle {
					checked: Streams.settings.autoNext ?? true
					onToggled: checked => Streams.setSetting("autoNext", checked)
				}
			}
			RowLayout {
				Layout.fillWidth: true
				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0
					StyledText {
						Layout.fillWidth: true
						text: "Load the next episodes at night"
					}
					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						text: "Between 2 and 7, what you watched in the last three weeks, up to 20 GB. A copy goes once watched, or after a week."
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}
				Toggle {
					checked: Streams.settings.nightLoad ?? false
					onToggled: checked => Streams.setSetting("nightLoad", checked)
				}
			}
			RowLayout {
				Layout.fillWidth: true
				StyledText {
					Layout.fillWidth: true
					text: "Are picture and sound on time?"
				}
				TextButton {
					text: "Test with flash and beep"
					onActivated: Streams.call("syncTest", {})
				}
			}
			RowLayout {
				Layout.fillWidth: true
				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0
					StyledText {
						Layout.fillWidth: true
						text: "Skip sponsor segments"
					}
					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						text: "SponsorBlock's list. It is asked in a way that does not tell which video it is."
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}
				}
				Toggle {
					checked: Streams.settings.sponsorBlock ?? true
					onToggled: checked => Streams.setSetting("sponsorBlock", checked)
				}
			}
		}
	}
}
