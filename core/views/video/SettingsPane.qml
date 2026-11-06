pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// How the player behaves: going on where a video was left, the next
// episode, the intro; how it looks; and how it gets on with the rest of the
// shell – the music, breaks, games, the accent, the lights.
PaneFrame {
	id: root

	title: "Settings"

	SectionLabel {
		text: "Watching"
	}

	PaneLine {
		label: "Go on where it was left"
		detail: "A chip offers the start instead"

		Toggle {
			checked: Video.setting("resume", true)
			onToggled: checked => Video.setSetting("resume", checked)
		}
	}

	PaneLine {
		label: "The next episode by itself"
		detail: "At the end, or ten seconds into the credits"

		Toggle {
			checked: Video.setting("autoNext", true)
			onToggled: checked => Video.setSetting("autoNext", checked)
		}
	}

	PaneLine {
		label: "The intro"
		detail: "Found where the episodes of a folder start the same"

		Segmented {
			width: 200
			options: [{ value: "ask", label: "Offer" }, { value: "auto", label: "Skip" }, { value: "off", label: "Play" }]
			current: Video.setting("skipIntro", "ask")
			onSelected: value => Video.setSetting("skipIntro", value)
		}
	}

	PaneLine {
		label: "Picture in picture"
		detail: "The corner it sits in"

		Segmented {
			width: 200
			options: [{ value: "tl", label: "↖" }, { value: "tr", label: "↗" }, { value: "bl", label: "↙" }, { value: "br", label: "↘" }]
			current: Video.pipCorner
			onSelected: value => Video.pipTo(value)
		}
	}

	PaneLine {
		label: "Languages"
		detail: "Sound and subtitles to pick first (de, en …)"

		Row {
			spacing: 6

			Field {
				width: 64
				height: 34
				placeholder: "Sound"
				text: Video.setting("audioLang", "")
				onEdited: text => Video.setSetting("audioLang", text.trim())
			}

			Field {
				width: 64
				height: 34
				placeholder: "Subs"
				text: Video.setting("subLang", "")
				onEdited: text => Video.setSetting("subLang", text.trim())
			}
		}
	}

	SectionLabel {
		text: "Looks"
	}

	PaneLine {
		label: "The film's glow"
		detail: "Its colours softly around it in the window"

		Toggle {
			checked: Video.setting("ambient", true)
			onToggled: checked => Video.setSetting("ambient", checked)
		}
	}

	PaneLine {
		label: "Moving pictures in Files"
		detail: "Resting on a video plays through it"

		Toggle {
			checked: Video.setting("hoverPreview", true)
			onToggled: checked => Video.setSetting("hoverPreview", checked)
		}
	}

	PaneLine {
		label: "The film's colour for the shell"
		detail: "The accent follows the picture while it plays"

		Toggle {
			checked: Video.setting("shellAccent", false)
			onToggled: checked => Video.setSetting("shellAccent", checked)
		}
	}

	PaneLine {
		visible: Plugins.on("lighting")
		label: "The lights follow the picture"
		detail: "Keyboard and case take its colours, every few seconds"

		Toggle {
			checked: Video.setting("lighting", false)
			onToggled: checked => Video.setSetting("lighting", checked)
		}
	}

	SectionLabel {
		text: "With the rest"
	}

	PaneLine {
		label: "The music waits"
		detail: "Paused while a video plays, on again after"

		Toggle {
			checked: Video.setting("pauseMusic", true)
			onToggled: checked => Video.setSetting("pauseMusic", checked)
		}
	}

	PaneLine {
		label: "Paused for breaks"
		detail: "Stretching and resting the eyes"

		Toggle {
			checked: Video.setting("breaks", true)
			onToggled: checked => Video.setSetting("breaks", checked)
		}
	}

	PaneLine {
		label: "Paused when a game starts"
		detail: "Not in picture in picture"

		Toggle {
			checked: Video.setting("games", true)
			onToggled: checked => Video.setSetting("games", checked)
		}
	}

	PaneLine {
		visible: Plugins.on("video")
		label: "Recordings into the editor"
		detail: "A screen recording opens here when it stops"

		Toggle {
			checked: Video.setting("openRecordings", false)
			onToggled: checked => Video.setSetting("openRecordings", checked)
		}
	}

	PaneLine {
		label: "What videos open in"
		detail: Video.isDefault ? "This player, everywhere" : "Another app; Files and the shell still use this one"

		Toggle {
			checked: Video.isDefault
			onToggled: checked => Plugins.set("video-default", checked)
		}
	}

	SectionLabel {
		text: "Subtitles"
	}

	PaneLine {
		label: "Whisper"
		detail: "Larger writes better and takes longer"

		Segmented {
			width: 200
			options: [{ value: "base", label: "Quick" }, { value: "small", label: "Good" }, { value: "medium", label: "Best" }]
			current: Video.setting("whisperModel", "small")
			onSelected: value => Video.setSetting("whisperModel", value)
		}
	}

	Column {
		width: root.bodyWidth
		spacing: 6

		StyledText {
			text: "OpenSubtitles key"
			font.weight: Font.DemiBold
		}

		Field {
			width: parent.width
			height: 36
			password: true
			placeholder: "From opensubtitles.com › API consumers"
			text: Video.setting("opensubtitlesKey", "")
			onEdited: text => Video.setSetting("opensubtitlesKey", text.trim())
		}
	}
}
