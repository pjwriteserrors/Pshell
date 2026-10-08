pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Where the connections go (core/services/Outbound.qml): the globe, and
// under it the apps or the places, the busiest first. Pointing at a row
// lets its arcs stand out, a click keeps it that way and turns the globe to
// them; a click on a place of the globe picks it in the list.
Rectangle {
	id: root

	// the section is on the screen
	property bool shown: false
	// "apps" | "places"
	property string mode: "apps"
	// what was clicked, and what the pointer is on in the list
	property string picked: ""
	property string pointed: ""
	property bool watching: false

	readonly property bool byApp: root.mode === "apps"
	readonly property string current: root.pointed !== "" ? root.pointed : root.picked
	readonly property var rows: root.byApp ? Outbound.apps.map(app => app.id) : Outbound.places.map(place => place.key)
	readonly property int rowHeight: 40

	function keys(name) {
		const out = {};
		if (!root.byApp) out[name] = true;
		else (Outbound.appTable[name]?.places ?? []).forEach(key => out[key] = true);
		return out;
	}

	function rate(down, up, conns) {
		if (down >= 1024 && down >= up) return Network.formatSpeed(down);
		if (up >= 1024) return Network.formatSpeed(up);
		return String(conns);
	}

	function follow() {
		const wanted = root.shown && Outbound.enabled;
		if (wanted === root.watching) return;
		root.watching = wanted;
		Outbound.watch(wanted);
	}

	implicitHeight: body.implicitHeight
	radius: Theme.radius.large
	color: Theme.layer1

	onShownChanged: {
		root.follow();
		if (!root.shown) {
			root.picked = "";
			root.pointed = "";
		}
	}
	onRowsChanged: {
		// what was picked is gone
		if (root.picked !== "" && !root.rows.includes(root.picked)) root.picked = "";
		if (root.pointed !== "" && !root.rows.includes(root.pointed)) root.pointed = "";
	}
	Component.onCompleted: root.follow()
	Component.onDestruction: if (root.watching) Outbound.watch(false)

	ColumnLayout {
		id: body

		width: parent.width
		spacing: 0

		Item {
			Layout.fillWidth: true
			implicitHeight: 290

			Globe {
				id: globe

				anchors.fill: parent
				anchors.topMargin: 42
				anchors.leftMargin: 6
				anchors.rightMargin: 6
				shown: root.shown
				places: Outbound.places
				origin: Outbound.origin
				lit: globe.hovered !== "" ? ({ [globe.hovered]: true }) : (root.current !== "" ? root.keys(root.current) : null)
				aimed: root.picked !== "" ? root.keys(root.picked) : null
				app: root.byApp ? root.current : ""
				pinned: root.byApp ? "" : root.current
				onPicked: key => {
					root.mode = key !== "" ? "places" : root.mode;
					root.picked = key;
				}
			}

			SectionLabel {
				x: 14
				y: 14
				text: "Connections"
			}

			Segmented {
				anchors.right: parent.right
				anchors.rightMargin: 10
				y: 8
				implicitWidth: 140
				implicitHeight: 28
				color: Theme.layer2
				options: [{ value: "apps", label: "Apps" }, { value: "places", label: "Places" }]
				current: root.mode
				onSelected: value => {
					if (value === root.mode) return;
					root.picked = "";
					root.pointed = "";
					root.mode = value;
				}
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 8
				visible: Outbound.ready && Outbound.geo !== "ready"
				text: Outbound.geo === "failed" ? "No location data" : `Loading locations  ·  ${Math.round(Outbound.progress * 100)}%`
				tabular: true
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		ListView {
			id: list

			Layout.fillWidth: true
			Layout.leftMargin: 6
			Layout.rightMargin: 6
			Layout.bottomMargin: 6
			implicitHeight: Math.min(5, list.count) * root.rowHeight
			clip: true
			interactive: list.count > 5
			boundsBehavior: Flickable.StopAtBounds
			model: ScriptModel {
				values: root.rows
			}

			Behavior on implicitHeight {
				SpatialAnim {}
			}

			add: Transition {
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}
			}
			remove: Transition {
				Anim {
					property: "opacity"
					to: 0
					duration: Motion.short
				}
			}
			displaced: Transition {
				SpatialAnim {
					properties: "y"
				}
				Anim {
					property: "opacity"
					to: 1
				}
			}

			delegate: Clickable {
				id: row

				required property string modelData
				readonly property var app: root.byApp ? (Outbound.appTable[row.modelData] ?? null) : null
				readonly property var place: root.byApp ? null : (Outbound.placeTable[row.modelData] ?? null)
				readonly property var entry: row.app ?? row.place
				readonly property real down: row.entry?.down ?? 0
				readonly property real up: row.entry?.up ?? 0
				readonly property bool busy: row.down >= 1024 || row.up >= 1024
				readonly property bool chosen: root.picked === row.modelData
				// the towns an app talks to, the apps a town is talked to by
				readonly property var others: {
					if (row.place) return row.place.apps.map(app => app.id);
					const towns = [];
					(row.app?.places ?? []).forEach(key => {
						const place = Outbound.placeTable[key];
						const town = place ? (place.city || place.country) : "";
						if (town !== "" && !towns.includes(town)) towns.push(town);
					});
					return towns;
				}

				width: list.width
				height: root.rowHeight
				radius: Theme.radius.medium
				color: row.chosen ? Theme.primarySoft : "transparent"
				pressedScale: 0.985
				onClicked: root.picked = row.chosen ? "" : row.modelData
				onHoveredChanged: {
					if (row.hovered) root.pointed = row.modelData;
					else if (root.pointed === row.modelData) root.pointed = "";
				}

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 12
					spacing: 10

					Item {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 22

						Image {
							id: picture

							anchors.fill: parent
							visible: row.app !== null && picture.status === Image.Ready
							source: row.app ? Outbound.icon(row.app.id) : ""
							sourceSize.width: 44
							sourceSize.height: 44
							asynchronous: true
						}

						Glyph {
							anchors.centerIn: parent
							visible: !picture.visible
							icon: row.place ? "map_marker" : (row.modelData === "System" ? "server" : "application")
							size: 18
							color: row.chosen ? Theme.primary : Theme.textMuted
						}
					}

					StyledText {
						Layout.maximumWidth: 170
						text: row.app ? Outbound.title(row.app.id) : (row.place ? (row.place.city || row.place.country || "Unknown") : "")
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						visible: row.app !== null
						text: row.others.length > 2 ? `${row.others.slice(0, 2).join(", ")} +${row.others.length - 2}` : row.others.join(", ")
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.label
					}

					StyledText {
						Layout.fillWidth: true
						visible: row.place !== null
						text: row.place?.city ? row.place.country : ""
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.label
					}

					Row {
						visible: row.place !== null
						spacing: -4

						Repeater {
							model: row.place ? row.others.slice(0, 4) : []

							delegate: Image {
								required property string modelData

								width: 18
								height: 18
								visible: status === Image.Ready
								source: Outbound.icon(modelData)
								sourceSize.width: 36
								sourceSize.height: 36
								asynchronous: true
							}
						}
					}

					Glyph {
						visible: row.busy
						icon: row.down >= row.up ? "arrow_down" : "arrow_up"
						size: 13
						color: row.down >= row.up ? Theme.primary : Theme.secondary
					}

					StyledText {
						Layout.leftMargin: row.busy ? -6 : 0
						text: root.rate(row.down, row.up, row.entry?.conns ?? 0)
						tabular: true
						tone: row.busy ? (row.down >= row.up ? Theme.primary : Theme.secondary) : Theme.textMuted
						font.pixelSize: Theme.size.label
						font.weight: row.busy ? Font.Bold : Font.Medium
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.bottomMargin: 16
			visible: Outbound.ready && list.count === 0 && Outbound.geo === "ready"
			horizontalAlignment: Text.AlignHCenter
			text: "No connections"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
		}
	}
}
