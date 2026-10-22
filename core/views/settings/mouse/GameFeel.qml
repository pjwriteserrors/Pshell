pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// Game haptics (scripts/mouse/gamefeel.py). By itself: a virtual
// controller the game rumbles with the haptics its makers designed, and
// the game's own sound – each new sound right after a press of yours (a
// bullet going in, a block breaking, a spell), and blasts whoever caused
// them. Or by hand: bound presses (TriggerBinds), or every onset of the
// sound. Shows what is live, what was felt, and the sound's meter.
ColumnLayout {
	id: root

	readonly property string source: {
		const value = Mouse.option("rumbleSource", "auto");
		return value === "both" ? "auto" : value;
	}
	readonly property bool on: Mouse.option("rumble", "off") !== "off"
	readonly property bool automatic: root.on && root.source === "auto"
	readonly property bool sound: root.on && root.source !== "input"
	readonly property bool padWanted: Mouse.option("rumblePad", true) !== false
	readonly property bool soundWanted: Mouse.option("rumbleSound", true) !== false
	// what was felt lately: [{source, kind, strength, label, at}]
	property var recent: []

	spacing: 12

	function sourceIcon(source) {
		return source === "pad" ? "gamepad_variant" : (source === "sound" ? "volume_high" : "keyboard");
	}

	function kindName(kind, label) {
		return { rumble: "Rumble", tick: "Tick", thud: "Thud", blast: "Blast", press: label || "Press" }[kind] ?? label;
	}

	Connections {
		target: Mouse

		function onFelt(source, kind, strength, wave, label) {
			const list = root.recent.slice(0, 7);
			list.unshift({ source, kind, strength, label, wave, at: Date.now() });
			root.recent = list;
			prune.restart();
		}
	}

	// what was felt fades out again
	Timer {
		id: prune

		interval: 1000
		repeat: true
		onTriggered: {
			const now = Date.now();
			const list = root.recent.filter(f => now - f.at < 9000);
			if (list.length !== root.recent.length) root.recent = list;
			if (list.length === 0) prune.stop();
		}
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 14

		Rectangle {
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36
			radius: Theme.radius.medium
			color: Mouse.rumbling || Mouse.triggering || Mouse.padOn ? Theme.primary : Theme.primarySoft

			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "gamepad_variant"
				size: 18
				color: Mouse.rumbling || Mouse.triggering || Mouse.padOn ? Theme.onPrimary : Theme.primary
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				text: "Game haptics"
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				text: {
					if (!root.on) return "Reloads, shots, blasts and hits, felt under the thumb";
					if (Mouse.padOn || Mouse.rumbling) {
						const parts = [];
						if (Mouse.padOn) parts.push("the controller is plugged in");
						if (Mouse.rumbling) parts.push(Mouse.hearing.length > 0 ? `hearing ${Mouse.hearing.join(", ")}` : "waiting for the game's sound");
						if (Mouse.triggering && root.source === "input") parts.push("reading your presses");
						return "Live – " + parts.join(", ");
					}
					if (Mouse.triggering) return "On – your bound presses are felt";
					if (Mouse.option("rumble", "off") === "games") return Plugins.on("games") ? "While a game has the focus, whatever started it" : "Needs the Games plugin to know when you play";
					return "Always on – also outside games";
				}
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		Segmented {
			Layout.preferredWidth: 300
			options: [{ value: "off", label: "Off" }, { value: "games", label: "In games", icon: "gamepad_variant" }, { value: "always", label: "Always" }]
			current: Mouse.option("rumble", "off")
			onSelected: value => Mouse.setOption("rumble", value)
		}
	}

	RowLayout {
		Layout.fillWidth: true
		visible: root.on
		spacing: 14

		StyledText {
			Layout.fillWidth: true
			text: root.source === "auto" ? "Nothing to set up: the game's own controller haptics, else its sound after your presses – every bullet of a slow reload, one clack of a magazine, the swing and the break – and blasts and hits from anywhere." : (root.source === "sound" ? "Every new sound of the game that stands out – also what others do. Only the game's own stream, never voices or music." : "Only what you press, as bound below – exact, the same in every game.")
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		Segmented {
			Layout.preferredWidth: 300
			options: [{ value: "auto", label: "By itself", icon: "auto_fix" }, { value: "input", label: "Presses", icon: "mouse" }, { value: "sound", label: "Sound", icon: "volume_high" }]
			current: root.source
			onSelected: value => Mouse.setOption("rumbleSource", value)
		}
	}

	// the two things that need no setting up, each with what it is doing
	Repeater {
		model: root.automatic ? [{
				id: "pad",
				icon: "gamepad_variant",
				label: "The game's own haptics",
				on: root.padWanted,
				live: Mouse.padOn,
				text: !root.padWanted ? "A virtual controller the game can rumble – off" : (Mouse.padOn ? (Mouse.padPulses > 0 ? `Plugged in – the game rumbled it ${Mouse.padPulses} times` : "Plugged in, nothing felt yet – not every game rumbles while you play with the mouse") : (Mouse.padBlocked ? `Your ${Mouse.padBlocked} is on: the game rumbles that one` : "A virtual controller, plugged in while a game runs; most games rumble it even when you play with the mouse"))
			}, {
				id: "sound",
				icon: "volume_high",
				label: "The game's sound",
				on: root.soundWanted,
				live: Mouse.rumbling,
				text: !root.soundWanted ? "What starts in the game's sound – off" : (Mouse.rumbling ? (Mouse.hearing.length > 0 ? `Hearing ${Mouse.hearing.join(", ")} – your actions, and blasts` : "Waiting for the game to make a sound") : "Only the game's stream: a new sound right after your press is yours; a blast counts from anywhere")
			}] : []

		delegate: RowLayout {
			id: lane

			required property var modelData

			Layout.fillWidth: true
			Layout.leftMargin: 10
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28
				radius: Theme.radius.small
				color: lane.modelData.live && lane.modelData.on ? Theme.primary : Theme.layer2

				Behavior on color {
					ColorAnim {}
				}

				Glyph {
					anchors.centerIn: parent
					icon: lane.modelData.icon
					size: 15
					color: lane.modelData.live && lane.modelData.on ? Theme.onPrimary : Theme.textSubtle
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					text: lane.modelData.label
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: lane.modelData.text
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Toggle {
				checked: lane.modelData.on
				onToggled: on => Mouse.setOption(lane.modelData.id === "pad" ? "rumblePad" : "rumbleSound", on)
			}
		}
	}

	// what was felt lately, newest first
	Flow {
		Layout.fillWidth: true
		Layout.leftMargin: 10
		visible: root.on && root.recent.length > 0
		spacing: 6

		Repeater {
			model: root.recent

			delegate: Rectangle {
				id: chip

				required property var modelData
				required property int index

				width: chipRow.implicitWidth + 18
				height: 26
				radius: 13
				color: chip.modelData.kind === "blast" ? Theme.primary : Theme.layer2
				opacity: 1 - chip.index * 0.11
				scale: 1
				Component.onCompleted: pop.start()

				Behavior on opacity {
					Anim {}
				}

				SequentialAnimation {
					id: pop

					NumberAnimation {
						target: chip
						property: "scale"
						from: 0.6
						to: 1
						duration: 260
						easing.type: Easing.OutBack
					}
				}

				RowLayout {
					id: chipRow

					anchors.centerIn: parent
					spacing: 6

					Glyph {
						icon: root.sourceIcon(chip.modelData.source)
						size: 13
						color: chip.modelData.kind === "blast" ? Theme.onPrimary : Theme.textSubtle
					}

					StyledText {
						text: root.kindName(chip.modelData.kind, chip.modelData.label)
						font.pixelSize: Theme.size.small
						color: chip.modelData.kind === "blast" ? Theme.onPrimary : Theme.text
					}

					// how hard it was
					Rectangle {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 4
						radius: 2
						color: Qt.alpha(chip.modelData.kind === "blast" ? Theme.onPrimary : Theme.primary, 0.25)

						Rectangle {
							width: parent.width * Math.max(0.1, Math.min(1, chip.modelData.strength))
							height: parent.height
							radius: 2
							color: chip.modelData.kind === "blast" ? Theme.onPrimary : Theme.primary
						}
					}
				}
			}
		}
	}

	// bound presses: everything in Presses, on top of the rest otherwise
	ColumnLayout {
		Layout.fillWidth: true
		visible: root.on && root.source !== "sound"
		spacing: 6

		StyledText {
			visible: root.automatic
			Layout.leftMargin: 10
			text: "Presses of your own on top"
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
			tone: Theme.textSubtle
		}

		TriggerBinds {
			Layout.fillWidth: true
			automatic: root.automatic
		}
	}

	// what it hears: how far the last moment stands out, the line to cross
	Rectangle {
		id: meter

		property real flash: 0

		Layout.fillWidth: true
		// opens when it starts listening, closes when it stops
		Layout.preferredHeight: Mouse.rumbling ? 46 : 0
		radius: Theme.radius.large
		color: Theme.layer1
		opacity: Mouse.rumbling ? 1 : 0
		visible: Layout.preferredHeight > 0.5
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}

		Connections {
			target: Mouse

			function onHit(strength) {
				meter.flash = 0.3 + strength * 0.7;
				fade.restart();
				spark.createObject(meter, { x: 14 + Mouse.bass * (meter.width - 28), strength });
			}
		}

		NumberAnimation {
			id: fade

			target: meter
			property: "flash"
			to: 0
			duration: 420
			easing.type: Easing.OutCubic
		}

		Rectangle {
			anchors.fill: parent
			radius: parent.radius
			color: Theme.primary
			opacity: meter.flash * 0.25
		}

		Rectangle {
			x: 14
			anchors.verticalCenter: parent.verticalCenter
			height: 10
			radius: 5
			width: Math.max(10, Mouse.bass * (parent.width - 28))
			color: Qt.alpha(Theme.primary, 0.6)

			Behavior on width {
				Anim {
					duration: 70
				}
			}
		}

		// the line to cross
		Rectangle {
			x: 14 + Mouse.bassThreshold * (parent.width - 28)
			anchors.verticalCenter: parent.verticalCenter
			width: 2
			height: 24
			radius: 1
			color: Theme.text
			opacity: 0.5

			Behavior on x {
				Anim {
					duration: 200
				}
			}
		}

		Component {
			id: spark

			Rectangle {
				id: s

				property real strength: 0.5

				y: meter.height / 2 - height / 2
				width: 10 + s.strength * 14
				height: width
				radius: width / 2
				color: Theme.primary
				Component.onCompleted: burst.start()

				ParallelAnimation {
					id: burst

					NumberAnimation {
						target: s
						property: "scale"
						from: 0.4
						to: 2.2
						duration: 520
						easing.type: Easing.OutCubic
					}
					NumberAnimation {
						target: s
						property: "opacity"
						from: 0.9
						to: 0
						duration: 520
						easing.type: Easing.OutCubic
					}
					onFinished: s.destroy()
				}
			}
		}
	}

	ValueSlider {
		visible: root.sound
		from: 0
		to: 100
		step: 5
		unit: " %"
		icon: "tune_variant"
		label: "Sensitivity"
		value: Mouse.option("rumbleSensitivity", 60)
		onMoved: v => Mouse.setOption("rumbleSensitivity", Math.round(v))
	}

	ValueSlider {
		visible: root.sound
		from: 40
		to: 300
		step: 10
		unit: " ms"
		icon: "timer_outline"
		label: "At most every"
		value: Mouse.option("rumbleGap", 70)
		onMoved: v => Mouse.setOption("rumbleGap", Math.round(v))
	}

	StyledText {
		Layout.fillWidth: true
		visible: root.sound
		text: root.automatic ? "The sound is the game's own stream at 16 kHz (about 2 % of one core while a game runs). A new sound is yours when a key or button of yours is fresh – movement keys, modifiers and Tab, Esc, Enter open nothing – and plays as a tick or a bump by what it sounds like, harder for louder. A blast is felt whoever caused it. While the game rumbles the controller its sound stays quiet." : "The sound is the game's own stream at 16 kHz, about 2 % of one core. Every new sound that stands out plays – a tick for a click, a bump for a thud, harder for louder."
		tone: Theme.textFaint
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
