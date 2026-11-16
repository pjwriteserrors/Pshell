pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >server: the services of netcore (pshell-core) with their state;
// typing narrows them. Enter opens one in the browser, Shift+Enter opens
// the Server page at it. Below them the portal and the Server page.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0

	readonly property string words: root.argument.trim().toLowerCase()

	readonly property var rows: {
		const services = Netcore.services.filter(service => root.words === "" || `${service.title ?? ""} ${service.name ?? ""} ${service.description ?? ""}`.toLowerCase().includes(root.words)).map(service => ({ kind: "service", service: service }));
		const actions = [
			{ kind: "action", id: "page", title: "Server settings", subtitle: Netcore.summary, icon: "server", words: "settings page server devices sessions users log guard health" },
			{ kind: "action", id: "portal", title: "Open the portal", subtitle: Netcore.portalUrl, icon: "web", words: "portal web browser login" }
		].filter(action => root.words === "" || `${action.title} ${action.words}`.toLowerCase().includes(root.words));
		return services.concat(actions);
	}

	signal closeRequested

	onActiveChanged: {
		if (root.active) {
			root.currentIndex = 0;
			Netcore.refresh(true);
		}
	}
	onRowsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.rows.length - 1))

	function move(delta) {
		root.select(root.currentIndex + delta);
	}

	function select(index) {
		if (root.rows.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.rows.length - 1, index));
		list.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const row = root.rows[root.currentIndex];
		if (!row) return;
		root.run(row, (modifiers & Qt.ShiftModifier) !== 0);
	}

	function run(row, toPage) {
		root.closeRequested();
		later.row = row;
		later.toPage = toPage;
		later.restart();
	}

	// once the launcher has gone, the window that opens takes the keyboard
	Timer {
		id: later

		property var row: null
		property bool toPage: false
		interval: Motion.medium
		onTriggered: {
			const row = later.row;
			if (!row) return;
			if (row.kind === "service") {
				if (later.toPage || String(row.service.url ?? "") === "") Netcore.openSettings();
				else Netcore.openService(row.service);
				return;
			}
			if (row.id === "portal") Netcore.openPortal("/");
			else Netcore.openSettings();
		}
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 6
			Layout.rightMargin: 6
			spacing: 8

			Glyph {
				icon: Netcore.online ? "server" : "lan_disconnect"
				size: 16
				color: Netcore.online ? Netcore.levelColor(Netcore.level || "ok") : Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: Netcore.online ? `netcore · ${Netcore.summary}` : Netcore.summary
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}

			StyledText {
				visible: Netcore.online && Netcore.memTotal > 0
				text: `${Math.round(Netcore.memFill * 100)} % memory${Netcore.temp > 0 ? ` · ${Math.round(Netcore.temp)} °C` : ""}`
				tone: Netcore.guardOk ? Theme.textSubtle : Netcore.levelColor(Netcore.level)
				font.pixelSize: Theme.size.small
				tabular: true
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			EmptyState {
				anchors.centerIn: parent
				visible: root.rows.length === 0
				icon: Netcore.online ? "magnify" : "lan_disconnect"
				title: Netcore.online ? "No service is called that" : "Core is not reachable"
				subtitle: Netcore.online ? "Services of netcore, the portal, the Server page" : (Netcore.error || "Pshell settings › Server")
			}

			ListView {
				id: list

				anchors.fill: parent
				visible: root.rows.length > 0
				clip: true
				spacing: 2
				model: root.rows
				currentIndex: root.currentIndex
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				delegate: ListItem {
					id: row

					required property var modelData
					required property int index

					readonly property var service: row.modelData.service ?? null
					readonly property string status: String(row.service?.state ?? "")

					width: list.width
					selected: root.currentIndex === row.index
					icon: row.service ? Netcore.iconOf(row.service) : row.modelData.icon
					title: row.service ? String(row.service.title ?? row.service.name) : row.modelData.title
					subtitle: {
						if (!row.service) return row.modelData.subtitle;
						const c = row.service.container ?? {};
						const parts = [Netcore.stateText(row.status)];
						if (Number(c.mem) > 0) parts.push(Number(c.mem_limit) > 0 ? `${Format.bytes(c.mem)} of ${Format.bytes(c.mem_limit)}` : Format.bytes(c.mem));
						if (row.service.description) parts.push(String(row.service.description));
						return parts.join(" · ");
					}
					onPointed: root.currentIndex = row.index
					onClicked: root.run(row.modelData, false)

					Rectangle {
						visible: row.service !== null
						implicitWidth: stateText.implicitWidth + 20
						implicitHeight: 24
						radius: 12
						color: Qt.alpha(Netcore.stateColor(row.status), 0.14)

						Behavior on color {
							ColorAnim {}
						}

						StyledText {
							id: stateText

							anchors.centerIn: parent
							text: Netcore.stateText(row.status)
							tone: Netcore.stateColor(row.status)
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}
					}

					IconButton {
						visible: row.service !== null && (row.selected || row.hovered)
						implicitWidth: 28
						implicitHeight: 28
						icon: "cog_outline"
						onClicked: root.run(row.modelData, true)
					}
				}
			}
		}
	}
}
