pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// Game haptics: what is pressed in a game (the button that shoots, the key
// that reloads – TriggerBinds), or the low end of what plays (a shot, an
// explosion, a kick drum), or both, felt under the thumb. When, from what,
// and for the sound a meter that shows what it hears and each hit.
ColumnLayout {
	id: root

	readonly property string source: Mouse.option("rumbleSource", "input")
	readonly property bool on: Mouse.option("rumble", "off") !== "off"
	readonly property bool sound: root.on && root.source !== "input"

	spacing: 12

	RowLayout {
		Layout.fillWidth: true
		spacing: 14

		Rectangle {
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36
			radius: Theme.radius.medium
			color: Mouse.rumbling || Mouse.triggering ? Theme.primary : Theme.primarySoft

			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "gamepad_variant"
				size: 18
				color: Mouse.rumbling || Mouse.triggering ? Theme.onPrimary : Theme.primary
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
				text: Mouse.triggering || Mouse.rumbling ? (Mouse.triggering ? "On – the game's presses are felt" : "Listening – every hit of the bass is felt") : (Mouse.option("rumble", "off") === "games" ? (Plugins.on("games") ? "While a game has the focus, whatever started it" : "Needs the Games plugin to know when you play") : "Shots, reloads and hits, felt under the thumb")
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
			text: root.source === "sound" ? "The sound fires on anything loud enough – voices and music too." : (root.source === "both" ? "Presses, and the bass of the sound on top." : "Only what you press – exact, whatever the game, silent when people talk.")
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		Segmented {
			Layout.preferredWidth: 300
			options: [{ value: "input", label: "Presses", icon: "mouse" }, { value: "sound", label: "Sound", icon: "volume_high" }, { value: "both", label: "Both" }]
			current: root.source
			onSelected: value => Mouse.setOption("rumbleSource", value)
		}
	}

	TriggerBinds {
		Layout.fillWidth: true
		visible: root.on && root.source !== "sound"
	}

	// what it hears: the bass, the line a hit has to cross, the hits
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
				const dot = spark.createObject(meter, { x: 14 + Mouse.bass * (meter.width - 28), strength });
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
		from: 60
		to: 400
		step: 10
		unit: " ms"
		icon: "timer_outline"
		label: "At most every"
		value: Mouse.option("rumbleGap", 110)
		onMoved: v => Mouse.setOption("rumbleGap", Math.round(v))
	}

	StyledText {
		Layout.fillWidth: true
		visible: root.sound
		text: "It listens to the default output (its monitor) at 8 kHz, about 1 % of one core, and only while it is on. Strong hits play a hard bump, weaker ones a soft bump or a tick."
		tone: Theme.textFaint
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
