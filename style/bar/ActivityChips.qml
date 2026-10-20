import QtQuick
import qs.style.widgets

// What runs for a while and is worth seeing: a screen recording, browser
// downloads, the file manager's copies, unpacking and uploads. Nothing
// while nothing runs.
Row {
	id: root

	required property var bar

	spacing: 4
	// no visible binding here: the chips hide themselves, and a hidden row would hide them for good

	RecordingChip {
		id: recording

		bar: root.bar
	}

	DownloadChip {
		id: download

		bar: root.bar
	}

	FileJobChip {
		id: fileJob

		bar: root.bar
	}
}
