pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Toasts under the right end of the bar, one card per program: more of the
// same stack up behind it and open with the count. Each stack keeps its own
// countdown, hovering pauses it, dragging sideways throws the stack away.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	anchors {
		top: true
		right: true
	}
	margins.top: Theme.barHeight + 10
	margins.right: 12
	implicitWidth: 392
	implicitHeight: Math.max(1, list.contentHeight + 24)
	exclusiveZone: 0
	color: "transparent"
	visible: Notifs.toasts.length > 0 || list.count > 0
	WlrLayershell.namespace: "shell-toasts"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	// a toast that can be answered takes the keyboard once its field is clicked
	readonly property bool answerable: Notifs.toasts.some(toast => toast.internal ? !!toast.reply : !!toast.notification?.hasInlineReply)
	WlrLayershell.keyboardFocus: root.answerable ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
	mask: Region {
		item: list
	}

	ListView {
		id: list

		x: 6
		width: parent.width - 12
		height: contentHeight
		interactive: false
		spacing: 10
		model: ScriptModel {
			values: Notifs.stacks.map(entry => entry.key)
		}

		add: Transition {
			ParallelAnimation {
				SpatialAnim {
					property: "x"
					from: 380
					to: 0
				}
				Anim {
					property: "opacity"
					from: 0
					to: 1
				}
			}
		}
		displaced: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.medium
			}
		}

		delegate: Item {
			id: stack

			required property string modelData
			readonly property var live: Notifs.stacks.find(entry => entry.key === stack.modelData) ?? null
			// the last state, kept while the stack glides out
			property var held: null
			readonly property var toasts: stack.held?.toasts ?? []
			readonly property var newest: stack.toasts[0] ?? null
			// the one on top: a newcomer waits behind it while it is read or answered
			property var front: null
			readonly property var rest: stack.toasts.filter(toast => toast !== stack.front)
			property int seenId: 0
			property bool expanded: false
			property real remaining: 1
			property bool leaving: false
			readonly property bool typing: top.typing || Array.from(older.children).some(child => !!child.typing)
			readonly property bool reading: top.open || Array.from(older.children).some(child => !!child.open)
			readonly property bool busy: top.typing || top.open
			readonly property int ghosts: stack.expanded ? 0 : Math.max(0, Math.min(2, stack.toasts.length - 1))

			width: ListView.view.width
			height: column.implicitHeight + stack.ghosts * 6

			onLiveChanged: if (stack.live) stack.held = stack.live
			Component.onCompleted: if (stack.live) stack.held = stack.live
			// every stack runs on its own time; only a newcomer winds it up again
			onNewestChanged: {
				if (!stack.newest || stack.newest.toastId <= stack.seenId) return;
				stack.seenId = stack.newest.toastId;
				countdown.duration = stack.newest.duration;
				stack.remaining = 1;
				countdown.restart();
			}
			onToastsChanged: {
				if (stack.toasts.length < 2) stack.expanded = false;
				stack.pickFront();
			}
			onBusyChanged: stack.pickFront()

			function pickFront() {
				if (stack.toasts.length === 0) return;
				// toasts[0], not newest: that binding may not have caught up yet here
				if (!stack.toasts.includes(stack.front) || !stack.busy) stack.front = stack.toasts[0];
			}

			function leave(direction) {
				if (stack.leaving) return;
				stack.leaving = true;
				exit.to = (direction >= 0 ? 1 : -1) * (stack.width + 40);
				exit.start();
			}

			function invoke(entry) {
				if (entry?.internal || !entry?.notification?.actions) return;
				const byDefault = Array.from(entry.notification.actions).find(action => action.identifier === "default");
				if (byDefault) byDefault.invoke();
			}

			// one of several goes alone, the last one takes the stack along
			function drop(entry) {
				if (stack.toasts.length > 1) Notifs.dismissToast(entry);
				else stack.leave(1);
			}

			NumberAnimation {
				id: countdown

				target: stack
				property: "remaining"
				from: 1
				to: 0
				// it stays while it is looked at, dragged, opened or answered
				paused: running && (hover.hovered || drag.active || stack.expanded || stack.typing || stack.reading)
				onFinished: stack.leave(1)
			}

			NumberAnimation {
				id: exit

				target: body
				property: "x"
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.accel
				onFinished: {
					// run out it stays in the centre, closed or thrown away it is gone
					if (stack.remaining > 0) Notifs.dismissStack(stack.modelData);
					else Notifs.removeStack(stack.modelData);
				}
			}

			Item {
				id: body

				width: parent.width
				height: parent.height
				opacity: 1 - Math.min(0.85, Math.abs(x) / width)
				rotation: x / 70

				Behavior on x {
					enabled: !drag.active && !exit.running
					SpatialAnim {
						duration: Motion.medium
					}
				}

				HoverHandler {
					id: hover
				}

				DragHandler {
					id: drag

					target: body
					yAxis.enabled: false
					onActiveChanged: {
						if (active) return;
						if (Math.abs(body.x) > stack.width * 0.3) stack.leave(body.x);
						else body.x = 0;
					}
				}

				// the cards underneath peek out below the top one
				Repeater {
					model: stack.ghosts

					delegate: Rectangle {
						required property int index

						z: -1 - index
						x: (index + 1) * 10
						y: column.implicitHeight - height + (index + 1) * 6
						width: body.width - (index + 1) * 20
						height: 30
						radius: top.radius
						color: Qt.tint(top.color, Qt.alpha(Theme.text, 0.03 * (index + 1)))
						border.width: Math.max(1, top.border.width)
						border.color: top.border.width > 0 ? top.border.color : Theme.outline
						opacity: 1 - index * 0.3
					}
				}

				ColumnLayout {
					id: column

					width: parent.width
					spacing: 6

					ToastCard {
						id: top

						Layout.fillWidth: true
						entry: stack.front
						remaining: stack.remaining
						count: stack.toasts.length
						expanded: stack.expanded
						hovered: hover.hovered
						onCloseClicked: stack.expanded ? stack.drop(stack.front) : stack.leave(1)
						onCountClicked: stack.expanded = !stack.expanded
						onAnswered: stack.drop(top.entry)

						TapHandler {
							onTapped: stack.invoke(stack.front)
						}
					}

					ColumnLayout {
						id: older

						Layout.fillWidth: true
						visible: stack.expanded
						spacing: 6

						// by id, so a card being answered stays when others come or go
						Repeater {
							model: ScriptModel {
								values: stack.expanded ? stack.rest.map(toast => toast.toastId) : []
							}

							delegate: ToastCard {
								id: olderCard

								required property int modelData

								Layout.fillWidth: true
								entry: stack.toasts.find(toast => toast.toastId === olderCard.modelData) ?? null
								hovered: hover.hovered
								onCloseClicked: stack.drop(olderCard.entry)
								onAnswered: stack.drop(olderCard.entry)

								TapHandler {
									onTapped: stack.invoke(olderCard.entry)
								}
							}
						}
					}
				}
			}
		}
	}
}
