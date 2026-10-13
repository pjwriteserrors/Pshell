import QtQuick
import Quickshell

// Every topic the shell publishes to the phone; one file each.
Scope {
	id: root

	required property var link

	MediaTopic { link: root.link }
	SoundTopic { link: root.link }
	SystemTopic { link: root.link }
	SessionTopic { link: root.link }
	TimerTopic { link: root.link }
	BreaksTopic { link: root.link }
	AgentsTopic { link: root.link }
	UpdatesTopic { link: root.link }
	NotificationsTopic { link: root.link }
	WindowsTopic { link: root.link }
	AppsTopic { link: root.link }
	RadialTopic { link: root.link }
	QuickTopic { link: root.link }
	NotesTopic { link: root.link }
	SshTopic { link: root.link }
	RecordingTopic { link: root.link }
	SongTopic { link: root.link }
	WeatherTopic { link: root.link }
	CalendarTopic { link: root.link }
	ShelvesTopic { link: root.link }
	TranslateTopic { link: root.link }
	ScreenshotTopic { link: root.link }
	SearchTopic { link: root.link }
	MessagesTopic { link: root.link }
	TrackingTopic { link: root.link }
	DownloadsTopic { link: root.link }
	LibraryTopic { link: root.link }
	LyricsTopic { link: root.link }
	ReaderTopic { link: root.link }
	ConvertTopic { link: root.link }
	ScreentimeTopic { link: root.link }
	ConnectionsTopic { link: root.link }
	AsteroidsTopic { link: root.link }
	FactTopic { link: root.link }
	MachinesTopic { link: root.link }
	LightingTopic { link: root.link }
	SoundsTopic { link: root.link }
	IdentitiesTopic { link: root.link }
	NewslettersTopic { link: root.link }

	Incoming { link: root.link }
}
