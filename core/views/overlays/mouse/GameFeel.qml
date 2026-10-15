pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.niri

// Game haptics: the low end of what plays (a shot, an explosion, a kick
// drum) felt under the thumb. When, how easily it fires, and a meter that
// shows what it hears and each hit as it lands.
ColumnLayout {
	id: root

	spacing: 12

	RowLayout {
		Layout.fillWidth: true
		spacing: 14

		Rectangle {
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36
			radius: Theme.radius.medium
			color: Mouse.rumbling ? Theme.primary : Theme.primarySoft

			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "gamepad_variant"
				size: 18
				color: Mouse.rumbling ? Theme.onPrimary : Theme.primary
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
				text: Mouse.rumbling ? "Listening – every hit of the bass is felt" : (Mouse.option("rumble", "off") === "games" ? (Plugins.on("games") ? "Starts with a game from the library and stops with it" : "Needs the Games plugin to know when you play") : "The bass of what plays, felt under the thumb")
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

	// what it hears: the bass, the line a hit has to cross, the hits
	Rectangle {
		id: meter

		property real flash: 0

		Layout.fillWidth: true
		Layout.preferredHeight: 46
		radius: Theme.radius.large
		color: Theme.layer1
		visible: Mouse.rumbling
		clip: true

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
		visible: Mouse.option("rumble", "off") !== "off"
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
		visible: Mouse.option("rumble", "off") !== "off"
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
		visible: Mouse.option("rumble", "off") !== "off"
		text: "It listens to the default output (its monitor) at 8 kHz, about 1 % of one core, and only while it is on. Strong hits play a hard bump, weaker ones a soft bump or a tick."
		tone: Theme.textFaint
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
