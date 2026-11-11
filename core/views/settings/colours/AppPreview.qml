pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Look.js" as Look

// The apps that follow the wallpaper, drawn in a scheme the way their themes
// map it (Look.js): the shell, kitty, GTK (libadwaita and the oomox folders),
// Floorp through Pywalfox, Spotify and Discord. Only the apps whose theme
// hook is on are offered.
ColumnLayout {
	id: root

	property var scheme: null
	property string title: ""
	property string mode: "dark"
	property string app: "shell"

	readonly property bool dark: root.mode !== "light"
	readonly property var apps: [
		{ value: "shell", label: "Shell", icon: "dock_window" },
		{ value: "terminal", label: "Terminal", icon: "console", hook: "kitty" },
		{ value: "gtk", label: "GTK", icon: "folder_outline", hook: "oomox" },
		{ value: "browser", label: "Browser", icon: "web", hook: "pywalfox" },
		{ value: "spotify", label: "Spotify", icon: "music", hook: "spicetify" },
		{ value: "discord", label: "Discord", icon: "chat_outline", hook: "betterdiscord" }
	].filter(a => !a.hook || Plugins.on(`hook-${a.hook}`))

	// until the preview is there: a neutral grey, so nothing reads null
	readonly property var shown: root.scheme ?? ({
			background: "#1a1a1a",
			foreground: "#e6e6e6",
			colors: ["#1e1e1e", "#808080", "#808080", "#808080", "#808080", "#808080", "#808080", "#c8c8c8", "#3a3a3a", "#909090", "#909090", "#909090", "#909090", "#909090", "#909090", "#e6e6e6"],
			roles: null
		})
	readonly property var r: Look.roles(root.shown)

	function c(value, alpha) {
		return value ? Look.toColor(value, alpha) : Theme.layer3;
	}
	function slot(i) {
		return Look.parse(root.shown.colors[i]);
	}

	spacing: 12

	Segmented {
		Layout.fillWidth: true
		options: root.apps
		current: root.app
		onSelected: value => root.app = value
	}

	Item {
		Layout.fillWidth: true
		implicitHeight: 260

		Loader {
			anchors.fill: parent
			sourceComponent: ({ shell: shellView, terminal: terminalView, gtk: gtkView, browser: browserView, spotify: spotifyView, discord: discordView })[root.app] ?? shellView
		}
	}

	// ── shell ──────────────────────────────────────────────────────────────
	Component {
		id: shellView

		Rectangle {
			id: shell

			radius: Theme.radius.large
			color: root.c(root.r.bg)

			ColumnLayout {
				anchors.fill: parent
				anchors.margins: 18
				spacing: 14

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Rectangle {
						implicitWidth: 34
						implicitHeight: 34
						radius: 17
						color: root.c(root.r.primary, 0.2)

						Glyph {
							anchors.centerIn: parent
							icon: "palette"
							size: 18
							color: root.c(root.r.primary)
						}
					}

					ColumnLayout {
						spacing: 0

						StyledText {
							text: root.title
							color: root.c(root.r.fg)
							font.weight: Font.Medium
						}

						StyledText {
							text: root.dark ? "Dark" : "Light"
							color: root.c(root.r.fg, 0.64)
							font.pixelSize: Theme.size.small
						}
					}

					Item {
						Layout.fillWidth: true
					}

					Repeater {
						model: ["success", "warning", "danger"]

						delegate: Rectangle {
							required property string modelData

							implicitWidth: 26
							implicitHeight: 26
							radius: 13
							color: root.c(root.r[modelData], 0.18)

							Rectangle {
								anchors.centerIn: parent
								width: 10
								height: 10
								radius: 5
								color: root.c(root.r[parent.modelData])
							}
						}
					}
				}

				Rectangle {
					Layout.fillWidth: true
					implicitHeight: 64
					radius: Theme.radius.medium
					color: root.c(root.r.layer2)

					RowLayout {
						anchors.fill: parent
						anchors.margins: 12
						spacing: 12

						Rectangle {
							implicitWidth: 40
							implicitHeight: 40
							radius: Theme.radius.small
							gradient: Gradient {
								GradientStop { position: 0; color: root.c(root.r.primary) }
								GradientStop { position: 1; color: root.c(root.r.secondary) }
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 6

							StyledText {
								text: "Now playing"
								color: root.c(root.r.fg)
							}

							Rectangle {
								Layout.fillWidth: true
								implicitHeight: 4
								radius: 2
								color: root.c(root.r.layer3)

								Rectangle {
									width: parent.width * 0.42
									height: parent.height
									radius: 2
									color: root.c(root.r.primary)
								}
							}
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					Rectangle {
						implicitWidth: 110
						implicitHeight: 34
						radius: 17
						color: root.c(root.r.primary)

						StyledText {
							anchors.centerIn: parent
							text: "Primary"
							color: root.c(root.r.onPrimary)
							font.weight: Font.Medium
						}
					}

					Repeater {
						model: ["secondary", "tertiary"]

						delegate: Rectangle {
							required property string modelData

							implicitWidth: 110
							implicitHeight: 34
							radius: 17
							color: root.c(root.r[modelData], 0.16)

							StyledText {
								anchors.centerIn: parent
								text: parent.modelData === "secondary" ? "Secondary" : "Tertiary"
								color: root.c(root.r[parent.modelData])
								font.weight: Font.Medium
							}
						}
					}

					Item {
						Layout.fillWidth: true
					}
				}
			}
		}
	}

	// ── kitty ──────────────────────────────────────────────────────────────
	Component {
		id: terminalView

		Rectangle {
			id: term

			readonly property color bg: root.c(Look.parse(root.shown.background))
			readonly property color fg: root.c(Look.parse(root.shown.foreground))
			function k(i) {
				return root.c(root.slot(i));
			}
			function span(text, i, bold) {
				return `<span style="color:${i < 0 ? term.fg : term.k(i)}${bold ? ";font-weight:600" : ""}">${text.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</span>`;
			}

			radius: Theme.radius.large
			color: term.bg
			clip: true

			// tabs: the active one in foreground on background, as the template has it
			Row {
				id: tabs

				x: 0
				y: 0
				Rectangle {
					width: 120
					height: 22
					color: term.fg

					StyledText {
						anchors.centerIn: parent
						text: "pshell"
						color: term.bg
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.small
					}
				}
				Rectangle {
					width: 120
					height: 22
					color: term.bg

					StyledText {
						anchors.centerIn: parent
						text: "htop"
						color: term.fg
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.small
					}
				}
			}

			Text {
				anchors.top: tabs.bottom
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.margins: 12
				textFormat: Text.RichText
				font.family: Theme.monoFamily
				font.pixelSize: 12
				lineHeight: 1.15
				text: [
					term.span("~/shell", 4, true) + " " + term.span("main", 5) + " " + term.span("✓", 2) + "  " + term.span("❯", 2, true) + " " + term.span("ls", -1),
					term.span("core/", 4, true) + "  " + term.span("docs/", 4, true) + "  " + term.span("run.sh", 2, true) + "  " + term.span("shell.qml", -1) + "  " + term.span("archive.tar", 1, true) + "  " + term.span("link", 6),
					term.span("❯", 2, true) + " " + term.span("git status --short", -1),
					term.span(" M", 1) + term.span(" core/Theme.qml", -1) + "    " + term.span("A ", 2) + term.span(" scripts/palette.py", -1),
					term.span("❯", 2, true) + " " + term.span("make test", -1) + "  " + term.span("# 50 tests", 8),
					term.span("error", 1, true) + term.span(": 2 failed", -1) + "   " + term.span("warning", 3, true) + term.span(": deprecated", -1) + "   " + term.span("ok", 2, true) + term.span(" 48 passed", -1),
					term.span("ERROR", 9, true) + " " + term.span("WARN", 11, true) + " " + term.span("INFO", 12, true) + " " + term.span("DEBUG", 13, true) + " " + term.span("TRACE", 14, true) + " " + term.span("dim", 8),
					term.span("❯", 2, true) + " " + term.span("█", -1)
				].join("<br>")
			}

			Row {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 12
				spacing: 3

				Repeater {
					model: 16

					delegate: Rectangle {
						required property int index

						width: (parent.width - 15 * 3) / 16
						height: 14
						radius: 3
						color: term.k(index)
						border.width: 1
						border.color: Qt.alpha(term.fg, 0.1)
					}
				}
			}
		}
	}

	// ── GTK (libadwaita, oomox folders) ────────────────────────────────────
	Component {
		id: gtkView

		Rectangle {
			id: gtk

			readonly property var g: Look.gtk(root.shown)

			radius: Theme.radius.large
			color: root.c(gtk.g.window)
			clip: true

			Rectangle {
				id: header

				width: parent.width
				height: 40
				color: root.c(gtk.g.headerbar)

				StyledText {
					anchors.centerIn: parent
					text: "Pictures"
					color: root.c(gtk.g.text)
					font.weight: Font.Bold
				}

				Row {
					anchors.right: parent.right
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					spacing: 8

					Rectangle {
						width: 76
						height: 26
						radius: 6
						color: root.c(gtk.g.destructive)

						StyledText {
							anchors.centerIn: parent
							text: "Delete"
							color: root.c(gtk.g.text)
							font.pixelSize: Theme.size.small
							font.weight: Font.Bold
						}
					}

					Rectangle {
						width: 76
						height: 26
						radius: 6
						color: root.c(gtk.g.accentBg)

						StyledText {
							anchors.centerIn: parent
							text: "Open"
							color: root.c(gtk.g.accentFg)
							font.pixelSize: Theme.size.small
							font.weight: Font.Bold
						}
					}
				}
			}

			Rectangle {
				id: side

				y: header.height
				width: 150
				height: parent.height - header.height
				color: root.c(gtk.g.sidebar)

				Column {
					anchors.fill: parent
					anchors.margins: 8
					spacing: 2

					Repeater {
						model: ["Home", "Pictures", "Documents", "Downloads"]

						delegate: Rectangle {
							required property string modelData
							required property int index

							width: parent.width
							height: 28
							radius: 6
							color: index === 1 ? root.c(gtk.g.accent, 0.25) : "transparent"

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								x: 10
								text: parent.modelData
								color: root.c(gtk.g.text)
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Grid {
				x: side.width + 16
				y: header.height + 14
				columns: 4
				columnSpacing: 14
				rowSpacing: 10

				Repeater {
					model: 8

					delegate: Column {
						required property int index

						spacing: 4

						Glyph {
							anchors.horizontalCenter: parent.horizontalCenter
							icon: "folder"
							size: 38
							color: root.c(gtk.g.folder)
						}

						Rectangle {
							width: 70
							height: 18
							radius: 4
							color: index === 2 ? root.c(gtk.g.accentBg) : "transparent"

							StyledText {
								anchors.centerIn: parent
								text: ["2024", "2025", "Trips", "Family", "Art", "Scans", "Raw", "Edits"][parent.parent.index]
								color: parent.parent.index === 2 ? root.c(gtk.g.accentFg) : root.c(gtk.g.text)
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Rectangle {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 12
				width: 150
				height: 62
				radius: 10
				color: root.c(gtk.g.popover)

				Column {
					anchors.fill: parent
					anchors.margins: 8
					spacing: 4

					StyledText {
						text: "Open With…"
						color: root.c(gtk.g.text)
						font.pixelSize: Theme.size.small
					}
					StyledText {
						text: "Rename"
						color: root.c(gtk.g.text)
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}

	// ── Floorp through Pywalfox ────────────────────────────────────────────
	Component {
		id: browserView

		Rectangle {
			id: fox

			readonly property var f: Look.floorp(root.shown, root.dark)

			radius: Theme.radius.large
			color: root.c(fox.f.bg)
			clip: true

			Row {
				id: tabRow

				x: 10
				y: 8
				spacing: 6

				Repeater {
					model: ["Pshell", "Docs", "Mail"]

					delegate: Rectangle {
						required property string modelData
						required property int index

						width: 130
						height: 30
						radius: 8
						color: index === 0 ? root.c(fox.f.layer2) : "transparent"

						Row {
							anchors.verticalCenter: parent.verticalCenter
							x: 10
							spacing: 8

							Rectangle {
								width: 12
								height: 12
								radius: 6
								anchors.verticalCenter: parent.verticalCenter
								color: parent.parent.index === 0 ? root.c(fox.f.primary) : root.c(fox.f.fg, 0.4)
							}

							StyledText {
								text: parent.parent.modelData
								color: root.c(fox.f.fg, parent.parent.index === 0 ? 1 : 0.64)
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Rectangle {
				id: urlbar

				x: 10
				y: tabRow.y + tabRow.height + 8
				width: parent.width - 20
				height: 32
				radius: 16
				color: root.c(fox.f.layer2)
				border.width: 2
				border.color: root.c(fox.f.primary)

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					x: 16
					text: "pshell.local/colours"
					color: root.c(fox.f.fg)
					font.pixelSize: Theme.size.small
				}
			}

			Rectangle {
				x: 10
				y: urlbar.y + urlbar.height + 10
				width: parent.width - 20
				height: parent.height - y - 10
				radius: 10
				color: root.dark ? "#1c1c1e" : "#ffffff"

				Column {
					anchors.fill: parent
					anchors.margins: 16
					spacing: 10

					Rectangle {
						width: parent.width * 0.4
						height: 12
						radius: 6
						color: root.dark ? "#3a3a3c" : "#d8d8d8"
					}
					Rectangle {
						width: parent.width * 0.8
						height: 8
						radius: 4
						color: root.dark ? "#2c2c2e" : "#ececec"
					}
					Rectangle {
						width: parent.width * 0.7
						height: 8
						radius: 4
						color: root.dark ? "#2c2c2e" : "#ececec"
					}
				}
			}
		}
	}

	// ── Spotify (dotfiles/spicetify/generate.py) ───────────────────────────
	Component {
		id: spotifyView

		Rectangle {
			id: spot

			radius: Theme.radius.large
			color: root.c(root.r.bg)
			clip: true

			Rectangle {
				id: spotSide

				x: 8
				y: 8
				width: 150
				height: parent.height - 76
				radius: 8
				color: root.c(root.r.layer2)

				Column {
					anchors.fill: parent
					anchors.margins: 10
					spacing: 8

					Repeater {
						model: ["Liked Songs", "Focus", "Evening", "Road trip"]

						delegate: Row {
							required property string modelData
							required property int index

							spacing: 8

							Rectangle {
								width: 26
								height: 26
								radius: 4
								color: root.c([root.r.primary, root.r.secondary, root.r.tertiary, root.r.layer3][index])
							}

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								text: parent.modelData
								color: parent.index === 0 ? root.c(root.r.primary) : root.c(root.r.fg)
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Row {
				x: spotSide.x + spotSide.width + 14
				y: 14
				spacing: 12

				Repeater {
					model: 4

					delegate: Rectangle {
						id: album

						required property int index

						width: 92
						height: 128
						radius: 8
						color: root.c(root.r.layer2)

						Rectangle {
							x: 8
							y: 8
							width: 76
							height: 76
							radius: 4
							gradient: Gradient {
								GradientStop { position: 0; color: root.c([root.r.primary, root.r.secondary, root.r.tertiary, root.r.danger][album.index]) }
								GradientStop { position: 1; color: root.c(root.r.layer3) }
							}
						}

						StyledText {
							x: 8
							y: 92
							text: ["Daily Mix", "Discover", "Release", "Radio"][album.index]
							color: root.c(root.r.fg)
							font.pixelSize: Theme.size.small
						}

						StyledText {
							x: 8
							y: 108
							text: "Playlist"
							color: root.c(root.r.fg, 0.64)
							font.pixelSize: Theme.size.tiny
						}
					}
				}
			}

			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				height: 60
				color: root.c(root.r.bg)

				Rectangle {
					anchors.centerIn: parent
					anchors.verticalCenterOffset: -8
					width: 32
					height: 32
					radius: 16
					color: root.c(root.r.primary)

					Glyph {
						anchors.centerIn: parent
						icon: "play"
						size: 18
						color: root.c(root.r.onPrimary)
					}
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 10
					width: parent.width * 0.5
					height: 4
					radius: 2
					color: root.c(root.r.layer3)

					Rectangle {
						width: parent.width * 0.35
						height: 4
						radius: 2
						color: root.c(root.r.fg)
					}
				}
			}
		}
	}

	// ── Discord (dotfiles/betterdiscord/pshell.theme.css) ──────────────────
	Component {
		id: discordView

		Rectangle {
			id: chat

			radius: Theme.radius.large
			color: root.c(root.r.bg)
			clip: true

			Column {
				id: servers

				x: 8
				y: 10
				spacing: 8

				Repeater {
					model: 5

					delegate: Rectangle {
						required property int index

						width: 40
						height: 40
						radius: index === 0 ? 12 : 20
						color: index === 0 ? root.c(root.r.primary) : root.c(root.r.layer2)

						Rectangle {
							visible: parent.index === 2
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							width: 12
							height: 12
							radius: 6
							color: root.c(root.r.danger)
							border.width: 2
							border.color: chat.color
						}
					}
				}
			}

			Rectangle {
				id: channels

				x: 58
				width: 150
				height: parent.height
				color: root.c(root.r.layer1)

				Column {
					anchors.fill: parent
					anchors.margins: 10
					spacing: 4

					Repeater {
						model: ["# general", "# pshell", "# wallpapers", "🔊 Lounge"]

						delegate: Rectangle {
							required property string modelData
							required property int index

							width: parent.width
							height: 26
							radius: 6
							color: index === 1 ? root.c(root.r.layer3) : "transparent"

							StyledText {
								anchors.verticalCenter: parent.verticalCenter
								x: 8
								text: parent.modelData
								color: root.c(root.r.fg, parent.index === 1 ? 1 : 0.64)
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			Column {
				x: channels.x + channels.width + 14
				y: 14
				width: parent.width - x - 14
				spacing: 12

				Repeater {
					model: [
						{ who: "Mara", text: "new wallpaper looks great", tone: "secondary" },
						{ who: "Jon", text: "@you the colours follow it now?", tone: "tertiary", mention: true },
						{ who: "You", text: "yes – all of them", tone: "primary" }
					]

					delegate: Rectangle {
						required property var modelData

						width: parent.width
						height: 44
						radius: 6
						color: modelData.mention ? root.c(root.r.primary, 0.14) : "transparent"

						Row {
							x: 6
							anchors.verticalCenter: parent.verticalCenter
							spacing: 10

							Rectangle {
								width: 30
								height: 30
								radius: 15
								color: root.c(root.r[parent.parent.modelData.tone])
							}

							Column {
								spacing: 2

								StyledText {
									text: parent.parent.parent.modelData.who
									color: root.c(root.r[parent.parent.parent.modelData.tone])
									font.weight: Font.Medium
									font.pixelSize: Theme.size.small
								}

								StyledText {
									text: parent.parent.parent.modelData.text
									color: root.c(root.r.fg)
									font.pixelSize: Theme.size.small
								}
							}
						}
					}
				}

				Rectangle {
					width: parent.width
					height: 34
					radius: 8
					color: root.c(root.r.layer2)

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						x: 12
						text: "Message #pshell"
						color: root.c(root.r.fg, 0.42)
						font.pixelSize: Theme.size.small
					}

					Rectangle {
						anchors.right: parent.right
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						width: 10
						height: 10
						radius: 5
						color: root.c(root.r.success)
					}
				}
			}
		}
	}
}
