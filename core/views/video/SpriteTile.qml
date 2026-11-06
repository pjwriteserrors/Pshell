import QtQuick

// One picture of a video's sprite sheet (video.py `sprites`: the tiles
// along the film in one JPEG). Showing another moment only moves the sheet
// behind a clip, so nothing is decoded again – the seek preview, the
// filmstrip and the playlist all draw from the same texture.
Item {
	id: root

	// { file, cols, rows, count, tile_w, tile_h, times }
	property var sheet: null
	property int tile: 0
	// fill the item, cropping the tile's sides (else letterboxed)
	property bool crop: true
	readonly property bool ready: !!root.sheet && picture.status === Image.Ready

	readonly property real tileW: root.sheet?.tile_w ?? 1
	readonly property real tileH: root.sheet?.tile_h ?? 1
	readonly property real fit: root.crop ? Math.max(root.width / root.tileW, root.height / root.tileH) : Math.min(root.width / root.tileW, root.height / root.tileH)
	readonly property int cols: Math.max(1, root.sheet?.cols ?? 1)
	readonly property int shown: Math.max(0, Math.min((root.sheet?.count ?? 1) - 1, root.tile))

	clip: true

	Item {
		id: window

		width: root.tileW * root.fit
		height: root.tileH * root.fit
		anchors.centerIn: parent
		clip: true

		Image {
			id: picture

			source: root.sheet?.file ? "file://" + root.sheet.file : ""
			asynchronous: true
			cache: true
			smooth: true
			width: root.cols * root.tileW * root.fit
			height: Math.max(1, root.sheet?.rows ?? 1) * root.tileH * root.fit
			x: -(root.shown % root.cols) * window.width
			y: -Math.floor(root.shown / root.cols) * window.height
			opacity: picture.status === Image.Ready ? 1 : 0

			Behavior on opacity {
				NumberAnimation {
					duration: 200
				}
			}
		}
	}
}
