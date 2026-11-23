pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A track's effects, top to bottom as they are played: each one on or off,
// its settings, moved up or down; chains kept as presets or read from FL
// Studio (.fst).
Rectangle {
	id: panel

	property string track: ""
	readonly property var entry: Rhymes.tracks.find(t => t.id === panel.track) ?? null
	// the chain as edited; sent a moment after the last change
	property var chain: []
	property bool naming: false

	signal closeRequested

	onEntryChanged: if (!sendTimer.running) panel.chain = JSON.parse(JSON.stringify(panel.entry?.fx ?? []))

	function change(index, fx) {
		const next = panel.chain.slice();
		next[index] = fx;
		panel.chain = next;
		sendTimer.restart();
	}

	function setParam(index, key, value) {
		const fx = Object.assign({}, panel.chain[index]);
		fx.params = Object.assign({}, fx.params, { [key]: value });
		panel.change(index, fx);
	}

	function move(index, by) {
		const next = panel.chain.slice();
		const [fx] = next.splice(index, 1);
		next.splice(Math.max(0, Math.min(next.length, index + by)), 0, fx);
		panel.chain = next;
		sendTimer.restart();
	}

	function remove(index) {
		panel.chain = panel.chain.filter((_, i) => i !== index);
		sendTimer.restart();
	}

	function add(fx) {
		panel.chain = panel.chain.concat(Array.isArray(fx) ? fx : [fx]);
		sendTimer.restart();
	}

	Timer {
		id: sendTimer

		interval: 350
		onTriggered: if (panel.track !== "") Rhymes.setChain(panel.track, panel.chain)
	}

	radius: Theme.radius.huge
	color: Theme.layer1
	border.width: 1
	border.color: Theme.outline

	// clicks stay here
	MouseArea {
		anchors.fill: parent
	}

	Item {
		id: header

		width: parent.width
		height: 52

		StyledText {
			x: 18
			anchors.verticalCenter: parent.verticalCenter
			width: parent.width - 80
			text: panel.entry?.name ?? ""
			elide: Text.ElideRight
			font.pixelSize: Theme.size.title ?? 18
			font.weight: Font.DemiBold
		}

		IconButton {
			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			width: 34
			height: 34
			icon: "close"
			onClicked: panel.closeRequested()
		}
	}

	Flickable {
		id: flick

		anchors.top: header.bottom
		anchors.bottom: footer.top
		width: parent.width
		contentHeight: list.implicitHeight + 16
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		Column {
			id: list

			x: 12
			width: flick.width - 24
			spacing: 10

			EmptyState {
				width: parent.width
				height: 160
				visible: panel.chain.length === 0
				icon: "tune_vertical"
				title: "No effects"
			}

			Repeater {
				model: panel.chain

				EffectCard {}
			}
		}
	}

	Column {
		id: footer

		anchors.bottom: parent.bottom
		anchors.bottomMargin: 12
		x: 12
		width: parent.width - 24
		spacing: 8

		Row {
			width: parent.width
			spacing: 8
			visible: panel.naming

			Field {
				id: presetName

				width: parent.width - 52
				placeholder: "Preset name"
				onAccepted: save.clicked()
				onEscapePressed: panel.naming = false
			}

			IconButton {
				id: save

				width: 40
				height: 40
				icon: "check"
				variant: "filled"
				onClicked: {
					if (presetName.text.trim() === "") return;
					Rhymes.savePreset(presetName.text.trim(), panel.chain);
					panel.naming = false;
					presetName.text = "";
				}
			}
		}

		Row {
			spacing: 8

			TextButton {
				icon: "plus"
				text: "Effect"
				variant: "tonal"
				onClicked: {
					const kinds = Rhymes.studio.kinds || {};
					const entries = Object.keys(kinds).filter(k => Rhymes.studio.available?.[k] !== false).map(k => ({ text: kinds[k].name, icon: "tune_vertical", action: () => panel.add(Rhymes.newEffect(k)) }));
					for (const preset of Rhymes.presets)
						entries.push({ text: preset.name, icon: "playlist_music", action: () => panel.add(JSON.parse(JSON.stringify(preset.chain))) });
					entries.push({ text: "FL Studio state…", icon: "file_import_outline", action: () => Rhymes.importChain(panel.track) });
					addMenu.entries = entries;
					addMenu.show(this, 0, -addMenu.implicitHeight - 6);
				}
			}

			IconButton {
				width: 40
				height: 40
				icon: "content_save_outline"
				visible: panel.chain.length > 0
				onClicked: {
					panel.naming = true;
					presetName.focusInput();
				}
			}

			IconButton {
				width: 40
				height: 40
				icon: "delete_outline"
				visible: Rhymes.presets.length > 0
				onClicked: {
					dropMenu.entries = Rhymes.presets.map(p => ({ text: p.name, icon: "delete_outline", danger: true, action: () => Rhymes.dropPreset(p.name) }));
					dropMenu.show(this, 0, -dropMenu.implicitHeight - 6);
				}
			}
		}
	}

	SmallMenu {
		id: addMenu
	}

	SmallMenu {
		id: dropMenu
	}

	SmallMenu {
		id: typeMenu
	}

	// ── one effect ───────────────────────────────────────────────────────
	component EffectCard: Rectangle {
		id: card

		required property var modelData
		required property int index
		readonly property var kind: Rhymes.studio.kinds?.[card.modelData.kind] ?? null
		readonly property bool on: card.modelData.on !== false
		property bool open: true

		width: list.width
		height: cardColumn.implicitHeight + 20
		radius: Theme.radius.large
		color: Theme.layer2
		opacity: card.on ? 1 : 0.6

		Behavior on height {
			SpatialAnim {}
		}

		Column {
			id: cardColumn

			x: 12
			y: 10
			width: parent.width - 24
			spacing: 8

			Row {
				width: parent.width
				spacing: 6

				Toggle {
					anchors.verticalCenter: parent.verticalCenter
					checked: card.on
					onToggled: checked => panel.change(card.index, Object.assign({}, card.modelData, { on: checked }))
				}

				Clickable {
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width - 150
					height: 30
					radius: Theme.radius.medium
					color: "transparent"
					onClicked: card.open = !card.open

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						x: 4
						width: parent.width - 8
						text: card.modelData.name || card.kind?.name || card.modelData.kind
						elide: Text.ElideRight
						font.weight: Font.Medium
					}
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 28
					height: 28
					icon: "arrow_up"
					enabled: card.index > 0
					opacity: enabled ? 1 : 0.3
					onClicked: panel.move(card.index, -1)
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 28
					height: 28
					icon: "arrow_down"
					enabled: card.index < panel.chain.length - 1
					opacity: enabled ? 1 : 0.3
					onClicked: panel.move(card.index, 1)
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 28
					height: 28
					icon: "delete_outline"
					onClicked: panel.remove(card.index)
				}
			}

			// the settings of the kind
			Repeater {
				model: card.open && card.modelData.kind !== "eq" ? (card.kind?.params ?? []) : []

				ParamSlider {
					required property var modelData

					width: cardColumn.width
					spec: modelData
					amount: card.modelData.params?.[modelData.key] ?? modelData.default
					onChangedTo: amount => panel.setParam(card.index, modelData.key, amount)
				}
			}

			// the bands of an EQ
			Repeater {
				model: card.open && card.modelData.kind === "eq" ? (card.modelData.params?.bands ?? []) : []

				Band {
					fxIndex: card.index
					fx: card.modelData
				}
			}

			TextButton {
				visible: card.open && card.modelData.kind === "eq" && (card.modelData.params?.bands ?? []).length < 8
				icon: "plus"
				text: "Band"
				variant: "ghost"
				onClicked: {
					const bands = (card.modelData.params?.bands ?? []).concat([{ type: "bell", freq: 1000, gain: 0, q: 1 }]);
					panel.setParam(card.index, "bands", bands);
				}
			}
		}
	}

	// ── one band of an EQ ────────────────────────────────────────────────
	component Band: Column {
		id: band

		required property var modelData
		required property int index
		property int fxIndex: 0
		property var fx: null
		readonly property var names: ({ bell: "Bell", lowcut: "Low cut", highcut: "High cut", lowshelf: "Low shelf", highshelf: "High shelf" })

		width: cardColumn.width
		spacing: 2

		function set(changes) {
			const bands = (band.fx.params?.bands ?? []).map((b, i) => i === band.index ? Object.assign({}, b, changes) : b);
			panel.setParam(band.fxIndex, "bands", bands);
		}

		Row {
			spacing: 6

			Clickable {
				width: 110
				height: 28
				radius: 14
				color: Theme.layer1
				onClicked: {
					typeMenu.entries = Object.keys(band.names).map(k => ({ text: band.names[k], icon: k === band.modelData.type ? "check" : "", action: () => band.set({ type: k }) }));
					typeMenu.show(this, 0, height);
				}

				StyledText {
					anchors.centerIn: parent
					text: band.names[band.modelData.type] ?? band.modelData.type
					font.pixelSize: Theme.size.small
				}
			}

			IconButton {
				width: 28
				height: 28
				icon: "close"
				onClicked: panel.setParam(band.fxIndex, "bands", (band.fx.params?.bands ?? []).filter((_, i) => i !== band.index))
			}
		}

		ParamSlider {
			width: parent.width
			spec: ({ label: "Frequency", from: 20, to: 20000, unit: "Hz", step: 1, log: true })
			amount: band.modelData.freq
			onChangedTo: amount => band.set({ freq: amount })
		}

		ParamSlider {
			width: parent.width
			visible: band.modelData.type !== "lowcut" && band.modelData.type !== "highcut"
			spec: ({ label: "Gain", from: -24, to: 24, unit: "dB", step: 0.1 })
			amount: band.modelData.gain
			onChangedTo: amount => band.set({ gain: amount })
		}

		ParamSlider {
			width: parent.width
			spec: ({ label: "Q", from: 0.1, to: 10, unit: "", step: 0.01, log: true })
			amount: band.modelData.q
			onChangedTo: amount => band.set({ q: amount })
		}
	}

	// a setting along a pill, in its own units (logarithmic where it says so)
	component ParamSlider: PillSlider {
		id: slider

		property var spec: ({})
		// the setting in its own units
		property real amount: 0
		readonly property bool log: slider.spec.log === true && slider.spec.from > 0

		signal changedTo(real amount)

		function toUnit(v) {
			const a = slider.spec.from, b = slider.spec.to;
			const raw = slider.log ? a * Math.pow(b / a, v) : a + v * (b - a);
			const step = slider.spec.step || 0.01;
			return Math.round(raw / step) * step;
		}

		function fromUnit(x) {
			const a = slider.spec.from, b = slider.spec.to;
			const v = slider.log ? Math.log(Math.max(a, x) / a) / Math.log(b / a) : (x - a) / (b - a);
			return Math.max(0, Math.min(1, v));
		}

		height: 28
		wheelEnabled: false
		label: slider.spec.label ?? ""
		stepSize: 0.005
		value: slider.fromUnit(slider.amount)
		valueText: {
			const v = slider.toUnit(slider.display);
			if (Math.abs(v) >= 1000) return `${(v / 1000).toFixed(v >= 10000 ? 1 : 2)} k${slider.spec.unit}`;
			const shown = slider.spec.step >= 1 ? String(Math.round(v)) : v.toFixed(slider.spec.step >= 0.1 ? 1 : 2);
			return `${shown}${slider.spec.unit ? " " + slider.spec.unit : ""}`;
		}
		onMoved: v => slider.changedTo(slider.toUnit(v))
	}
}
