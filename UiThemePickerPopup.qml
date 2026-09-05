pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import "components"

Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor

	property string selectedThemeId: ThemeEngine.currentThemeId
	property int selectedIndex: 0
	property real previewPulse: 0
	readonly property var themeOptions: ThemeEngine.availableThemes
	readonly property int columns: Math.max(1, Math.min(4, root.themeOptions.length))
	readonly property int rows: Math.max(1, Math.ceil(root.themeOptions.length / root.columns))
	readonly property real gap: 18
	readonly property real cardWidth: (themeGrid.width - root.gap * (root.columns - 1)) / root.columns

	function syncSelection() {
		for (let index = 0; index < root.themeOptions.length; index += 1) {
			if (String(root.themeOptions[index].id || "") === root.selectedThemeId) {
				root.selectedIndex = index;
				return;
			}
		}
		root.selectedIndex = 0;
	}

	function selectIndex(index) {
		if (root.themeOptions.length === 0) return;
		root.selectedIndex = Math.max(0, Math.min(root.themeOptions.length - 1, index));
		root.selectedThemeId = String(root.themeOptions[root.selectedIndex].id || "default");
	}

	function applySelection() {
		if (ThemeEngine.selectTheme(root.selectedThemeId)) root.closeRequested();
	}

	focus: true
	Component.onCompleted: {
		root.selectedThemeId = ThemeEngine.currentThemeId;
		root.syncSelection();
		root.forceActiveFocus();
	}
	onThemeOptionsChanged: root.syncSelection()
	Keys.onEscapePressed: root.closeRequested()
	Keys.onLeftPressed: root.selectIndex(root.selectedIndex - 1)
	Keys.onRightPressed: root.selectIndex(root.selectedIndex + 1)
	Keys.onUpPressed: root.selectIndex(root.selectedIndex - root.columns)
	Keys.onDownPressed: root.selectIndex(root.selectedIndex + root.columns)
	Keys.onReturnPressed: root.applySelection()
	Keys.onEnterPressed: root.applySelection()

	SequentialAnimation on previewPulse {
		running: root.visible
		loops: Animation.Infinite
		NumberAnimation { from: 0; to: 1; duration: ThemeEngine.duration(1500); easing.type: Easing.InOutSine }
		NumberAnimation { from: 1; to: 0; duration: ThemeEngine.duration(1500); easing.type: Easing.InOutSine }
	}

	NeumorphicShadow {
		anchors.fill: panel
		surfaceColor: panel.color
		cornerRadius: panel.radius
		depth: 1.15
	}

	Rectangle {
		id: panel
		anchors.fill: parent
		radius: ThemeEngine.radiusLarge
		color: Qt.alpha(root.secondaryInsetColor, 0.96)
		border.width: 1
		border.color: Qt.alpha(root.barColor, 0.34)

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 24
			spacing: 16

			RowLayout {
				Layout.fillWidth: true
				Layout.preferredHeight: 48
				spacing: 12

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					Text {
						color: root.foreground
						font.pixelSize: 22
						font.weight: Font.DemiBold
						text: "Interface theme"
					}

					Text {
						color: Qt.alpha(root.foreground, 0.66)
						font.pixelSize: 11
						text: "Shell shapes, Niri window borders and shadows — your palette stays unchanged"
					}
				}

				Rectangle {
					Layout.preferredWidth: 108
					Layout.preferredHeight: 40
					radius: ThemeEngine.radiusMedium
					color: Qt.alpha(root.barColor, 0.28)
					border.width: 1
					border.color: Qt.alpha(root.barColor, 0.52)

					HoverLayer {
						tint: root.foreground
						onClicked: root.applySelection()
					}

					Text {
						anchors.centerIn: parent
						color: root.foreground
						font.pixelSize: 12
						font.weight: Font.DemiBold
						text: root.selectedThemeId === ThemeEngine.currentThemeId ? "Selected" : "Apply"
					}
				}
			}

			Grid {
				id: themeGrid
				Layout.fillWidth: true
				Layout.fillHeight: true
				columns: root.columns
				columnSpacing: root.gap
				rowSpacing: root.gap

				Repeater {
					model: root.themeOptions

					delegate: Item {
						id: themeCard
						required property var modelData
						required property int index
						readonly property bool selected: root.selectedThemeId === String(modelData.id || "")
						readonly property bool neumorphic: String(modelData.preview || "") === "neumorphism"
						readonly property bool brutalist: String(modelData.preview || "") === "neo-brutalism"
						readonly property bool fantasy: String(modelData.preview || "") === "fantasy"
						width: root.cardWidth
						height: Math.min(300,
							(themeGrid.height - root.gap * (root.rows - 1)) / root.rows)

						RectangularShadow {
							anchors.fill: cardBody
							visible: themeCard.neumorphic
							radius: cardBody.radius
							blur: 22
							spread: -2
							offset: Qt.vector2d(7, 7)
							color: Qt.alpha(Qt.darker(root.secondaryBoxColor, 1.7), 0.36)
						}

						Rectangle {
							visible: themeCard.brutalist
							x: cardBody.x + 7
							y: cardBody.y + 7
							width: cardBody.width
							height: cardBody.height
							radius: 4
							color: ThemeEngine.contrastEdge(root.secondaryBoxColor, 0.9)
						}

						RectangularShadow {
							anchors.fill: cardBody
							visible: themeCard.neumorphic
							radius: cardBody.radius
							blur: 22
							spread: -2
							offset: Qt.vector2d(-7, -7)
							color: Qt.alpha(Qt.lighter(root.secondaryBoxColor, 1.7), 0.2)
						}

						Rectangle {
							id: cardBody
							anchors.fill: parent
							radius: themeCard.neumorphic ? 22 : themeCard.brutalist ? 4 : themeCard.fantasy ? 5 : 7
							color: root.secondaryBoxColor
							border.width: themeCard.brutalist ? 2 : themeCard.selected ? 2 : 1
							border.color: themeCard.selected ? root.barColor
								: themeCard.brutalist ? ThemeEngine.contrastEdge(root.secondaryBoxColor, 0.9)
								: Qt.alpha(root.foreground, 0.14)
							scale: cardMouse.pressed ? (themeCard.neumorphic ? 0.975 : themeCard.brutalist ? 0.985 : 0.99)
								: cardMouse.containsMouse ? (themeCard.neumorphic ? 1.018 : themeCard.brutalist ? 1.012 : 1.006) : 1

							Behavior on scale {
								NumberAnimation { duration: themeCard.neumorphic ? 280 : themeCard.brutalist ? 90 : 160; easing.type: themeCard.neumorphic ? Easing.OutQuart : ThemeEngine.standardEasing }
							}

							ThemeOrnament {
								anchors.fill: parent
								visible: themeCard.fantasy
								surfaceColor: cardBody.color
								ornamentStyle: "arcane"
								ornamentOpacity: 0.78
								lineWidth: 1
								frameInset: 4
								cornerLength: 18
								notchSize: 4
								doubleLine: true
								centerMarks: true
							}

							Column {
								anchors.fill: parent
								anchors.margins: 16
								spacing: 12

								Item {
									width: parent.width
									height: 170

									Rectangle {
										anchors.fill: parent
										radius: themeCard.neumorphic ? 16 : themeCard.brutalist ? 2 : 6
										border.width: themeCard.brutalist ? 2 : 0
										border.color: ThemeEngine.contrastEdge(root.background, 0.9)
										color: root.background
										clip: true

										Rectangle {
											x: 12; y: 12; width: parent.width - 24; height: 24
											radius: themeCard.neumorphic ? 12 : themeCard.brutalist ? 1 : 5
											border.width: themeCard.brutalist ? 2 : 0
											border.color: ThemeEngine.contrastEdge(root.secondaryBoxStrongColor, 0.9)
											color: root.secondaryBoxStrongColor
										}

										Row {
											x: 14; y: 52; spacing: 10
											Repeater {
												model: 3
												Rectangle {
													width: (cardBody.width - 58) / 3
													height: 72 + (index === 1 ? root.previewPulse * 12 : 0)
													radius: themeCard.neumorphic ? 14 : themeCard.brutalist ? 2 : 5
													border.width: themeCard.brutalist ? 2 : 0
													border.color: ThemeEngine.contrastEdge(color, 0.9)
													color: index === 1 ? Qt.alpha(root.barColor, 0.34) : root.secondaryBoxColor
												}
											}
										}

										Rectangle {
											x: 14; y: 140; width: (parent.width - 38) * (0.55 + root.previewPulse * 0.25); height: 8
											radius: themeCard.neumorphic ? 4 : themeCard.brutalist ? 0 : 2
											color: root.barColor
										}

										ThemeOrnament {
											anchors.fill: parent
											visible: themeCard.fantasy
											surfaceColor: parent.color
											ornamentStyle: "arcane"
											ornamentOpacity: 0.72
											lineWidth: 1
											frameInset: 4
											cornerLength: 15
											notchSize: 4
											doubleLine: true
											centerMarks: true
										}
									}
								}

								Text {
									width: parent.width
									color: root.foreground
									font.pixelSize: 17
									font.weight: Font.DemiBold
									text: String(themeCard.modelData.name || themeCard.modelData.id || "Theme")
								}

								Text {
									width: parent.width
									color: Qt.alpha(root.foreground, 0.65)
									font.pixelSize: 11
									wrapMode: Text.WordWrap
									text: String(themeCard.modelData.description || "")
								}
							}

							MouseArea {
								id: cardMouse
								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: root.selectIndex(themeCard.index)
								onDoubleClicked: {
									root.selectIndex(themeCard.index);
									root.applySelection();
								}
							}
						}
					}
				}
			}

			Text {
				Layout.fillWidth: true
				visible: ThemeEngine.error !== ""
				color: root.foreground
				font.pixelSize: 11
				text: ThemeEngine.error
			}
		}
	}
}
