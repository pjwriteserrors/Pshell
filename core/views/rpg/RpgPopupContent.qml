pragma ComponentBehavior: Bound

import QtQuick
import qs.core.services

Item {
	id: root
	required property var game
	required property color foreground
	required property color background
	required property color accent
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor

	property int tab: 0
	readonly property color gameAccent: root.accent
	readonly property color cosmeticAccent: game.cosmeticColor !== "" ? game.cosmeticColor : root.accent
	readonly property color textMain: root.foreground
	readonly property color textMuted: Qt.alpha(root.foreground, 0.64)
	readonly property color panel: Qt.alpha(root.background, 0.92)
	readonly property var tabs: [
		{ icon: "⚔", label: "Kampf" },
		{ icon: "◈", label: "Relikte" },
		{ icon: "✓", label: "Quests" },
		{ icon: "◆", label: "Shop" },
		{ icon: "∿", label: "Verlauf" }
	]

	function pct(value, target) { return `${Math.min(target, Math.floor(value))} / ${target}`; }
	function questReady(quest) {
		const progress = game.questState(quest.id);
		return quest.kind === "manual" || progress.progress >= quest.target;
	}
	function shopLabel(item) {
		const owned = game.state.purchasedCosmetics.indexOf(item.id) >= 0;
		if (!owned) return `${item.price}`;
		return game.state.equippedCosmetic === item.id ? "Aktiv" : "Anlegen";
	}

	Image {
		anchors.fill: parent
		source: `${Paths.assets}/rpg/archive-battle-v2.png`
		fillMode: Image.PreserveAspectCrop
		smooth: true
		mipmap: true
	}

	Rectangle {
		anchors.fill: parent
		color: root.tab === 0 ? Qt.alpha(root.background, 0.18) : Qt.alpha(root.background, 0.86)
		Behavior on color { ColorAnimation { duration: 180 } }
	}

	// Compact player header, matching the hierarchy of modern mobile RPGs.
	Rectangle {
		id: header
		anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
		height: 70
		color: Qt.alpha(root.background, 0.94)

		Rectangle {
			x: 18; anchors.verticalCenter: parent.verticalCenter
			width: 44; height: 44; radius: 22
			color: root.gameAccent
			border.width: 2
			border.color: root.cosmeticAccent
			Text { anchors.centerIn: parent; color: "white"; font.pixelSize: 14; font.bold: true; text: root.game.level }
		}

		Column {
			x: 74; anchors.verticalCenter: parent.verticalCenter; spacing: 5
			Text { color: root.textMain; font.pixelSize: 16; font.weight: Font.DemiBold; text: "Chronist" }
			Rectangle {
				width: 240; height: 8; radius: 4; color: root.secondaryInsetColor
				Rectangle { width: parent.width * Math.min(1, root.game.xp / Math.max(1, root.game.xpNeeded)); height: parent.height; radius: 4; color: root.gameAccent }
			}
		}

		Text {
			anchors.horizontalCenter: parent.horizontalCenter; anchors.verticalCenter: parent.verticalCenter
			color: root.textMuted; font.pixelSize: 11
			text: `${root.game.xp} / ${root.game.xpNeeded} XP`
		}

		Rectangle {
			anchors.right: parent.right; anchors.rightMargin: 18; anchors.verticalCenter: parent.verticalCenter
			width: 126; height: 38; radius: 19; color: root.secondaryBoxStrongColor
			Text { anchors.centerIn: parent; color: "#ffd26f"; font.pixelSize: 13; font.bold: true; text: `◆  ${root.game.coins}` }
		}

		Rectangle {
			visible: root.game.unseenCount > 0
			anchors.right: parent.right; anchors.rightMargin: 10; anchors.top: parent.top; anchors.topMargin: 7
			width: 20; height: 20; radius: 10; color: "#ff5f75"
			Text { anchors.centerIn: parent; color: "white"; font.pixelSize: 9; font.bold: true; text: root.game.unseenCount }
			MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.game.markAllSeen() }
		}
	}

	// KAMPF: only the information needed while working.
	Item {
		visible: root.tab === 0
		anchors.left: parent.left; anchors.right: parent.right
		anchors.top: header.bottom; anchors.bottom: navigation.top

		Column {
			anchors.top: parent.top; anchors.topMargin: 22; anchors.horizontalCenter: parent.horizontalCenter
			width: 330; spacing: 6
			Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; color: root.textMain; font.pixelSize: 18; font.bold: true; text: root.game.enemyName(root.game.stage) }
			Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; color: root.textMuted; font.pixelSize: 11; text: `Kammer ${root.game.stage}  ·  ${Math.max(0, Math.ceil(root.game.state.enemyHp))} HP` }
			Rectangle {
				width: parent.width; height: 12; radius: 6; color: root.secondaryInsetColor
				Rectangle { width: parent.width * root.game.enemyHpRatio; height: parent.height; radius: 6; gradient: Gradient { GradientStop { position: 0; color: "#c895ff" } GradientStop { position: 1; color: "#7444dc" } } }
			}
		}

		Column {
			anchors.left: parent.left; anchors.leftMargin: 30; anchors.bottom: parent.bottom; anchors.bottomMargin: 22
			spacing: 4
			Text { color: root.textMain; font.pixelSize: 18; font.bold: true; text: root.game.active ? "Expedition läuft" : "Bereit für die Expedition?" }
			Text { width: 360; color: root.textMuted; font.pixelSize: 11; wrapMode: Text.WordWrap; text: root.game.active ? root.game.inputStatus : "Deine Arbeit wird automatisch zu Treffern, Erfahrung und Loot." }
		}

		Row {
			anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: startButton.top; anchors.bottomMargin: 14
			spacing: 28
			Repeater {
				model: [
					{ value: root.game.state.today.hits, label: "Treffer" },
					{ value: root.game.state.today.kills, label: "Siege" },
					{ value: root.game.state.today.minutes, label: "Minuten" }
				]
				Column {
					required property var modelData
					width: 70; spacing: 1
					Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.textMain; font.pixelSize: 17; font.bold: true; text: parent.modelData.value }
					Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.textMuted; font.pixelSize: 10; text: parent.modelData.label }
				}
			}
		}

		RpgButton {
			id: startButton
			anchors.right: parent.right; anchors.rightMargin: 30; anchors.bottom: parent.bottom; anchors.bottomMargin: 22
			width: 270; height: 58
			label: root.game.active ? "Expedition stoppen" : "Expedition starten"
			sublabel: root.game.active ? "Fortschritt wird gespeichert" : `Kammer ${root.game.stage} betreten`
			accent: root.gameAccent; foreground: root.textMain; primary: true; armed: root.game.active
			onClicked: root.game.toggleExpedition()
		}
	}

	// RELIKTE: six items and three combinations are the whole build system.
	Item {
		visible: root.tab === 1
		anchors.left: parent.left; anchors.right: parent.right; anchors.top: header.bottom; anchors.bottom: navigation.top

		Text { x: 30; y: 24; color: root.textMain; font.pixelSize: 24; font.bold: true; text: "Relikte" }
		Text { x: 30; y: 57; color: root.textMuted; font.pixelSize: 12; text: "Finde Duplikate, erhöhe ihre Ränge und aktiviere Kombinationen." }

		Grid {
			x: 30; y: 96; width: parent.width - 60
			columns: 3; columnSpacing: 16; rowSpacing: 16
			Repeater {
				model: root.game.relicCatalog
				Rectangle {
					id: relic
					required property var modelData
					readonly property int rank: root.game.relicRank(modelData.id)
					width: (parent.width - 32) / 3; height: 118; radius: 16
					color: rank > 0 ? root.secondaryBoxStrongColor : Qt.alpha(root.secondaryBoxColor, 0.72); border.width: 1; border.color: rank > 0 ? Qt.alpha(root.gameAccent, 0.55) : Qt.alpha(root.foreground, 0.10)
					Rectangle {
						x: 14; anchors.verticalCenter: parent.verticalCenter; width: 72; height: 72; radius: 18; clip: true
						color: root.secondaryInsetColor; border.width: 1; border.color: relic.rank > 0 ? Qt.alpha(root.gameAccent, 0.65) : Qt.alpha(root.foreground, 0.10)
						Image { anchors.fill: parent; source: relic.modelData.image; fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true; opacity: relic.rank > 0 ? 1 : 0.38 }
					}
					Column { x: 100; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 114; spacing: 5
						Text { width: parent.width; color: relic.rank > 0 ? root.textMain : "#777080"; font.pixelSize: 14; font.bold: true; elide: Text.ElideRight; text: relic.modelData.name }
						Text { color: root.gameAccent; font.pixelSize: 12; text: `Rang ${relic.rank} / 10` }
						Text { width: parent.width; color: root.textMuted; font.pixelSize: 9; wrapMode: Text.WordWrap; text: relic.modelData.stat }
					}
				}
			}
		}

		Rectangle {
			x: 30; anchors.bottom: parent.bottom; anchors.bottomMargin: 20; width: parent.width - 60; height: 72; radius: 16; color: root.secondaryBoxColor
			Row {
				anchors.centerIn: parent; spacing: 26
				Repeater {
					model: [
						{ active: root.game.hasCombo("iron_quill", "archivist_seal"), name: "Chronist", bonus: "+15% XP" },
						{ active: root.game.hasCombo("cursor_fang", "clockwork_heart"), name: "Taktgeber", bonus: "+12% Schaden" },
						{ active: root.game.hasCombo("focus_lens", "ember_core"), name: "Glutblick", bonus: "Starke Krits" }
					]
					Row { id: combo; required property var modelData; spacing: 8; opacity: modelData.active ? 1 : 0.35
						Rectangle { width: 34; height: 34; radius: 17; color: Qt.alpha(root.gameAccent, 0.24); Text { anchors.centerIn: parent; color: root.gameAccent; text: combo.modelData.active ? "✓" : "·" } }
						Column { spacing: 1; Text { color: root.textMain; font.pixelSize: 12; font.bold: true; text: combo.modelData.name } Text { color: root.textMuted; font.pixelSize: 9; text: combo.modelData.bonus } }
					}
				}
			}
		}
	}

	// QUESTS: four clear daily goals.
	Item {
		visible: root.tab === 2
		anchors.left: parent.left; anchors.right: parent.right; anchors.top: header.bottom; anchors.bottom: navigation.top
		Text { x: 30; y: 24; color: root.textMain; font.pixelSize: 24; font.bold: true; text: "Tagesquests" }
		Text { x: 30; y: 57; color: root.textMuted; font.pixelSize: 12; text: "Vier kleine Ziele. Morgen beginnt eine neue Runde." }

		Column {
			x: 30; y: 96; width: parent.width - 60; spacing: 10
			Repeater {
				model: root.game.questCatalog
				Rectangle {
					id: quest
					required property var modelData
					readonly property var progress: root.game.questState(modelData.id)
					readonly property bool ready: root.questReady(modelData)
					width: parent.width; height: 88; radius: 16; color: root.secondaryBoxStrongColor
					Rectangle { x: 16; anchors.verticalCenter: parent.verticalCenter; width: 48; height: 48; radius: 24; color: quest.progress.claimed ? "#3867c88b" : Qt.alpha(root.gameAccent, 0.20); Text { anchors.centerIn: parent; color: quest.progress.claimed ? "#83e5a8" : root.gameAccent; font.pixelSize: 18; font.bold: true; text: quest.progress.claimed ? "✓" : "!" } }
					Column { x: 80; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 290; spacing: 5
						Text { color: root.textMain; font.pixelSize: 14; font.bold: true; text: quest.modelData.name }
						Text { color: root.textMuted; font.pixelSize: 10; text: quest.modelData.detail }
						Rectangle { width: 300; height: 6; radius: 3; color: root.secondaryInsetColor; Rectangle { width: parent.width * Math.min(1, quest.progress.progress / quest.modelData.target); height: parent.height; radius: 3; color: quest.progress.claimed ? "#67c88b" : root.gameAccent } }
					}
					Text { anchors.right: reward.left; anchors.rightMargin: 18; anchors.verticalCenter: parent.verticalCenter; color: "#ffd26f"; font.pixelSize: 12; font.bold: true; text: `◆ ${quest.modelData.coins}` }
					RpgButton { id: reward; anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; width: 120; height: 42; label: quest.progress.claimed ? "Erledigt" : (quest.modelData.kind === "manual" ? "Bestätigen" : (quest.ready ? "Abholen" : root.pct(quest.progress.progress, quest.modelData.target))); accent: root.gameAccent; foreground: root.textMain; buttonEnabled: quest.ready && !quest.progress.claimed; onClicked: root.game.claimQuest(quest.modelData.id) }
				}
			}
		}
	}

	// SHOP: cosmetics only, presented as a single clean collection.
	Item {
		visible: root.tab === 3
		anchors.left: parent.left; anchors.right: parent.right; anchors.top: header.bottom; anchors.bottom: navigation.top
		Text { x: 30; y: 24; color: root.textMain; font.pixelSize: 24; font.bold: true; text: "Kosmetik" }
		Text { x: 30; y: 57; color: root.textMuted; font.pixelSize: 12; text: "Farben verändern dein HUD – ohne spielerischen Vorteil." }

		Row {
			x: 30; y: 105; width: parent.width - 60; spacing: 14
			Repeater {
				model: root.game.shopCatalog
				Rectangle {
					id: product
					required property var modelData
					readonly property bool owned: root.game.state.purchasedCosmetics.indexOf(modelData.id) >= 0
					width: (parent.width - 56) / 5; height: 300; radius: 20; color: root.secondaryBoxStrongColor; border.width: root.game.state.equippedCosmetic === modelData.id ? 2 : 1; border.color: root.game.state.equippedCosmetic === modelData.id ? modelData.swatch : Qt.alpha(root.foreground, 0.10)
					Rectangle {
						anchors.top: parent.top; anchors.topMargin: 20; anchors.horizontalCenter: parent.horizontalCenter; width: 112; height: 112; radius: 18; clip: true
						color: root.secondaryInsetColor; border.width: 2; border.color: product.modelData.swatch
						Image { anchors.fill: parent; source: product.modelData.image; fillMode: Image.PreserveAspectCrop; smooth: true; mipmap: true }
					}
					Text { anchors.top: parent.top; anchors.topMargin: 140; anchors.horizontalCenter: parent.horizontalCenter; width: parent.width - 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; color: root.textMain; font.pixelSize: 13; font.bold: true; text: product.modelData.name }
					Text { anchors.top: parent.top; anchors.topMargin: 205; anchors.horizontalCenter: parent.horizontalCenter; color: product.owned ? "#82dca2" : "#ffd26f"; font.pixelSize: 12; text: product.owned ? "Im Besitz" : `◆ ${product.modelData.price}` }
					RpgButton { anchors.bottom: parent.bottom; anchors.bottomMargin: 16; anchors.horizontalCenter: parent.horizontalCenter; width: parent.width - 28; height: 42; label: root.shopLabel(product.modelData); accent: product.modelData.swatch; foreground: root.textMain; buttonEnabled: product.owned || root.game.coins >= product.modelData.price; onClicked: root.game.buyCosmetic(product.modelData.id) }
				}
			}
		}
	}

	// VERLAUF: stats stay available without cluttering the game screen.
	Item {
		visible: root.tab === 4
		anchors.left: parent.left; anchors.right: parent.right; anchors.top: header.bottom; anchors.bottom: navigation.top
		Text { x: 30; y: 24; color: root.textMain; font.pixelSize: 24; font.bold: true; text: "Heute" }
		Text { x: 30; y: 57; color: root.textMuted; font.pixelSize: 12; text: "Dein Arbeitsrhythmus, nicht nur dein Level." }

		Row {
			x: 30; y: 98; width: parent.width - 60; spacing: 12
			Repeater {
				model: [
					{ value: root.game.state.today.keys, label: "Tasten" }, { value: root.game.state.today.clicks, label: "Klicks" },
					{ value: root.game.state.today.hits, label: "Treffer" }, { value: root.game.state.today.kills, label: "Siege" },
					{ value: root.game.state.today.minutes, label: "Minuten" }, { value: root.game.state.today.coins, label: "Splitter" }
				]
				Column { required property var modelData; width: (parent.width - 60) / 6; spacing: 3
					Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.textMain; font.pixelSize: 22; font.bold: true; text: parent.modelData.value }
					Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.textMuted; font.pixelSize: 10; text: parent.modelData.label }
				}
			}
		}

		Rectangle {
			x: 30; y: 175; width: parent.width - 60; height: 280; radius: 20; color: root.secondaryBoxStrongColor
			Text { x: 20; y: 16; color: root.textMain; font.pixelSize: 14; font.bold: true; text: "Fokus und Gegner-HP" }
			Text { anchors.right: parent.right; anchors.rightMargin: 20; y: 18; color: root.textMuted; font.pixelSize: 10; text: "letzte 180 Minuten" }
			Canvas {
				id: chart
				x: 20; y: 52; width: parent.width - 40; height: 200
				property var samples: root.game.state.today.samples || []
				onSamplesChanged: requestPaint()
				onPaint: {
					const ctx = getContext("2d"); ctx.reset();
					ctx.strokeStyle = Qt.alpha(root.foreground, 0.10); ctx.lineWidth = 1;
					for (let row = 0; row < 5; row++) { ctx.beginPath(); ctx.moveTo(0, row * height / 4); ctx.lineTo(width, row * height / 4); ctx.stroke(); }
					function line(field, color) {
						if (chart.samples.length < 2) return;
						ctx.strokeStyle = color; ctx.lineWidth = 3; ctx.beginPath();
						for (let i = 0; i < chart.samples.length; i++) {
							const x = i * width / Math.max(1, chart.samples.length - 1);
							const y = height * (1 - Math.max(0, Math.min(100, chart.samples[i][field])) / 100);
							if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
						}
						ctx.stroke();
					}
					line("resolve", root.gameAccent); line("enemy", "#ff6e91");
				}
			}
			Text { anchors.centerIn: parent; visible: (root.game.state.today.samples || []).length < 2; color: root.textMuted; font.pixelSize: 12; text: "Der Verlauf erscheint nach zwei Expeditionsminuten." }
		}
	}

	// Large bottom navigation: the only persistent control group.
	Rectangle {
		id: navigation
		anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
		height: 78; color: Qt.alpha(root.background, 0.96)
		Row {
			anchors.centerIn: parent; spacing: 10
			Repeater {
				model: root.tabs
				Item {
					id: navItem
					required property var modelData
					required property int index
					width: 142; height: 62
					Rectangle { anchors.fill: parent; radius: 16; color: root.tab === navItem.index ? Qt.alpha(root.gameAccent, 0.20) : "transparent" }
					Column { anchors.centerIn: parent; spacing: 3
						Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.tab === navItem.index ? root.gameAccent : root.textMuted; font.pixelSize: 19; text: navItem.modelData.icon }
						Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.tab === navItem.index ? root.textMain : root.textMuted; font.pixelSize: 10; font.bold: root.tab === navItem.index; text: navItem.modelData.label }
					}
					MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.tab = navItem.index }
				}
			}
		}
	}
}
