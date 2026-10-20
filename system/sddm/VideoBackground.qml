import QtQuick
import QtMultimedia

// Loaded by Main.qml only for video wallpapers; when QtMultimedia is missing
// this file fails to load and the still frame underneath stays.
Video {
	fillMode: VideoOutput.PreserveAspectCrop
	autoPlay: true
	loops: MediaPlayer.Infinite
	muted: true
}
