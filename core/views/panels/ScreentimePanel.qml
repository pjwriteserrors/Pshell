pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.screentime

// Where the time at the screen went. The ring is the picked day, cut by
// apps, windows, workspaces or the pages of the browser, its biggest six
// beside it (the pointer on one singles it out). Below, the week of that
// day – a click on a bar picks the day, the arrows turn the weeks – and
// what stands out: the top app, the day against the one before, the
// busiest day and the average of the week, the longest stretch.
Drawer {
	id: root

	panelId: "screentime"
	panelWidth: 600
	centered: true
	contentHeight: layout.implicitHeight

	property string selected: Screentime.today
	property string kind: "apps"
	property int pointed: -1
	// winds the ring up when the panel opens
	property real intro: 0

	readonly property bool onToday: root.selected === Screentime.today
	readonly property var day: Screentime.day(root.selected)
	readonly property var rows: Screentime.rows(root.selected, root.kind)
	// two hues, each as it is, lighter and darker: six that never look alike
	readonly property var shades: [
		Theme.primary, Theme.secondary,
		Qt.tint(Theme.primary, Qt.alpha(Theme.fg, 0.5)), Qt.tint(Theme.secondary, Qt.alpha(Theme.bg, 0.45)),
		Qt.tint(Theme.primary, Qt.alpha(Theme.bg, 0.5)), Qt.tint(Theme.secondary, Qt.alpha(Theme.fg, 0.5))
	]
	// the biggest six, or five and the rest in one
	readonly property var legend: {
		const top = root.rows.slice(0, root.rows.length > 6 ? 5 : 6).map((row, index) => Object.assign({ color: root.shades[index] }, row));
		if (root.rows.length > 6)
			top.push({ key: "", label: "Other", detail: "", appId: "", icon: "dots_horizontal", color: Theme.textFaint, seconds: root.rows.slice(5).reduce((sum, row) => sum + row.seconds, 0) });
		return top;
	}
	readonly property var week: Screentime.week(root.selected)
	readonly property var counted: root.week.filter(day => day.total >= 60)
	readonly property real weekTotal: root.week.reduce((sum, day) => sum + day.total, 0)
	readonly property real weekAverage: root.counted.length > 0 ? root.weekTotal / root.counted.length : 0
	readonly property bool earlier: Object.keys(Screentime.days).some(key => key < root.week[0].key)
	readonly property bool later: root.week[6].key < Screentime.today

	readonly property var insights: {
		const out = [];
		const apps = Screentime.rows(root.selected, "apps");
		if (apps.length > 0 && root.day.total > 0)
			out.push({ icon: "star", color: Theme.primary, label: "Top app", value: `${apps[0].label} · ${Math.round(100 * apps[0].seconds / root.day.total)} % · ${Screentime.format(apps[0].seconds)}` });
		const versus = Screentime.versus(root.selected);
		if (versus) {
			const more = versus.seconds >= 60;
			const less = versus.seconds <= -60;
			const tone = more ? Theme.warning : (less ? Theme.success : Theme.textMuted);
			out.push({
				icon: more ? "arrow_top_right" : (less ? "arrow_bottom_right" : "arrow_right"), color: tone, valueColor: tone,
				label: root.onToday ? `vs yesterday by ${Qt.formatTime(new Date(), "HH:mm")}` : "vs the day before",
				value: more || less ? `${more ? "+" : "−"} ${Screentime.format(Math.abs(versus.seconds))} · ${Math.round(Math.abs(versus.ratio) * 100)} %` : "the same"
			});
		}
		if (root.counted.length > 1) {
			const busiest = root.counted.reduce((best, day) => day.total > best.total ? day : best);
			out.push({ icon: "fire", color: Theme.tertiary, label: "Busiest day", value: `${Qt.formatDate(busiest.date, "dddd")} · ${Screentime.format(busiest.total)}` });
			out.push({ icon: "sigma", color: Theme.secondary, label: "Daily average", value: Screentime.format(root.weekAverage) });
		}
		if (root.day.longest >= 60)
			out.push({ icon: "timer_outline", color: Theme.textMuted, label: "Longest stretch", value: `${Screentime.format(root.day.longest)} · until ${Qt.formatTime(new Date(root.day.longestEnd), "HH:mm")}` });
		return out;
	}

	function isoWeek(date) {
		const thursday = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 3 - (date.getDay() + 6) % 7);
		const first = new Date(thursday.getFullYear(), 0, 4);
		return 1 + Math.round(((thursday - first) / 86400000 - 3 + (first.getDay() + 6) % 7) / 7);
	}

	function turn(weeks) {
		const key = Screentime.shifted(root.selected, weeks * 7);
		root.selected = key > Screentime.today ? Screentime.today : key;
		bars.play();
	}

	onKindChanged: root.pointed = -1
	onSelectedChanged: root.pointed = -1
	onPanelOpened: {
		root.selected = Screentime.today;
		root.intro = 0;
		wind.restart();
		bars.play();
	}

	NumberAnimation {
		id: wind

		target: root
		property: "intro"
		to: 1
		duration: Motion.extraLong * 2
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 18

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			ColumnLayout {
				spacing: 0

				StyledText {
					text: Words.of("screentime.title", "Screen time")
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				StyledText {
					text: root.onToday ? "Today" : Qt.formatDate(Screentime.dateOf(root.selected), "dddd, d MMMM")
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Segmented {
				implicitWidth: 336
				Layout.preferredHeight: 30
				current: root.kind
				options: Screentime.kinds
				onSelected: value => root.kind = value
			}
		}

		// ── the day ───────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 24

			Donut {
				id: ring

				readonly property var row: root.legend[root.pointed] || null
				property real shownSeconds: root.shown ? (ring.row ? ring.row.seconds : root.day.total) : 0

				slices: root.day.total > 0 ? root.legend.map(row => ({ share: row.seconds / root.day.total, color: row.color })) : []
				highlighted: root.pointed
				grow: root.intro

				Behavior on shownSeconds {
					Anim {
						duration: Motion.extraLong * 1.6
						easing.bezierCurve: Motion.decel
					}
				}

				Column {
					anchors.centerIn: parent
					width: parent.width
					spacing: 0

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: Screentime.format(ring.shownSeconds)
						font.pixelSize: 26
						font.weight: Font.Bold
						tabular: true
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						width: Math.min(implicitWidth, parent.width)
						text: ring.row ? `${Math.round(100 * ring.row.seconds / Math.max(1, root.day.total))} %` : Qt.formatDate(Screentime.dateOf(root.selected), "d MMM")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
						tabular: true
					}
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: 6 * 29

				EmptyState {
					anchors.centerIn: parent
					visible: root.legend.length === 0
					icon: root.kind === "links" && !Screentime.browserLinked ? "link_variant_off" : "progress_clock"
					title: root.kind === "links" && !Screentime.browserLinked ? "No browser linked" : "Nothing counted"
					subtitle: root.kind === "links" && !Screentime.browserLinked ? "scripts/downloads_host.py install" : ""
				}

				Column {
					anchors.fill: parent

					Repeater {
						model: 6

						delegate: Item {
							id: entry

							required property int index

							readonly property var row: root.legend[entry.index] || null
							// keeps what it showed while it fades away
							property var last: ({ label: "", detail: "", appId: "", icon: "", color: "transparent", seconds: 0 })
							readonly property bool on: entry.row !== null && root.intro * 9 > entry.index + 1

							onRowChanged: if (entry.row) entry.last = entry.row

							width: parent.width
							height: 29
							opacity: entry.on ? (root.pointed < 0 || root.pointed === entry.index ? 1 : 0.45) : 0

							Behavior on opacity {
								Anim {}
							}

							transform: Translate {
								x: entry.on ? 0 : 14

								Behavior on x {
									SpatialAnim {}
								}
							}

							HoverHandler {
								enabled: entry.row !== null
								onHoveredChanged: {
									if (hovered) root.pointed = entry.index;
									else if (root.pointed === entry.index) root.pointed = -1;
								}
							}

							Rectangle {
								anchors.fill: parent
								anchors.leftMargin: -8
								anchors.rightMargin: -8
								radius: Theme.radius.small
								color: root.pointed === entry.index ? Theme.layer1 : "transparent"

								Behavior on color {
									ColorAnim {}
								}
							}

							RowLayout {
								anchors.fill: parent
								spacing: 9

								Rectangle {
									Layout.preferredWidth: 8
									Layout.preferredHeight: 8
									radius: 4
									color: entry.last.color

									Behavior on color {
										ColorAnim {}
									}
								}

								Item {
									Layout.preferredWidth: 18
									Layout.preferredHeight: 18

									Image {
										anchors.fill: parent
										visible: entry.last.icon === ""
										source: entry.last.icon === "" && entry.last.label !== "" ? AppIcons.forAppId(entry.last.appId) : ""
										sourceSize: Qt.size(36, 36)
										fillMode: Image.PreserveAspectFit
										asynchronous: true
									}

									Glyph {
										anchors.centerIn: parent
										visible: entry.last.icon !== ""
										icon: entry.last.icon
										size: 16
										color: Theme.textMuted
										animated: false
									}
								}

								StyledText {
									Layout.maximumWidth: entry.last.detail !== "" ? Math.max(90, parent.width * 0.5) : parent.width
									text: entry.last.label
									font.weight: Font.Medium
								}

								StyledText {
									Layout.fillWidth: true
									text: entry.last.detail
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.label
								}

								StyledText {
									text: Screentime.format(entry.last.seconds)
									tone: Theme.textMuted
									tabular: true
								}
							}
						}
					}
				}
			}
		}

		// ── its week ──────────────────────────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: weekLayout.implicitHeight + 24
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: weekLayout

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 12
				spacing: 4

				RowLayout {
					Layout.fillWidth: true
					spacing: 2

					IconButton {
						implicitWidth: 26
						implicitHeight: 26
						icon: "chevron_left"
						enabled: root.earlier
						onClicked: root.turn(-1)
					}

					StyledText {
						text: `${Qt.formatDate(root.week[0].date, root.week[0].date.getMonth() === root.week[6].date.getMonth() ? "d" : "d MMM")} – ${Qt.formatDate(root.week[6].date, "d MMM")} · W${root.isoWeek(root.week[0].date)}`
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
						tabular: true
					}

					IconButton {
						implicitWidth: 26
						implicitHeight: 26
						icon: "chevron_right"
						enabled: root.later
						onClicked: root.turn(1)
					}

					Item {
						Layout.fillWidth: true
					}

					StyledText {
						Layout.rightMargin: 4
						text: Screentime.format(root.weekTotal)
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
						tabular: true
					}
				}

				WeekBars {
					id: bars

					Layout.fillWidth: true
					days: root.week
					selected: root.selected
					average: root.counted.length > 1 ? root.weekAverage : 0
					onPicked: key => root.selected = key
				}
			}
		}

		// ── what stands out ───────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 4
			Layout.rightMargin: 4
			visible: root.insights.length > 0
			spacing: 9

			Repeater {
				model: root.insights

				delegate: RowLayout {
					id: insight

					required property var modelData

					Layout.fillWidth: true
					spacing: 10

					Glyph {
						icon: insight.modelData.icon
						size: 17
						color: insight.modelData.color
					}

					StyledText {
						text: insight.modelData.label
						tone: Theme.textMuted
					}

					StyledText {
						Layout.fillWidth: true
						horizontalAlignment: Text.AlignRight
						text: insight.modelData.value
						tone: insight.modelData.valueColor ?? Theme.text
						font.weight: Font.Medium
						tabular: true
					}
				}
			}
		}
	}
}
