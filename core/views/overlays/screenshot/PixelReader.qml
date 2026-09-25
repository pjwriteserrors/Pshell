import QtQuick

// Reads single pixels of an image file: set `px`/`py` (native pixels) and
// `color` follows. A 1×1 canvas draws just that pixel and reads it back.
Canvas {
	id: root

	property string source: ""
	property int px: 0
	property int py: 0
	property color color: "transparent"
	property string loaded: ""

	width: 1
	height: 1
	canvasSize: Qt.size(1, 1)

	onSourceChanged: {
		if (root.loaded !== "") root.unloadImage(root.loaded);
		root.loaded = root.source;
		if (root.source !== "") root.loadImage(root.source);
	}
	onImageLoaded: root.requestPaint()
	onPxChanged: root.requestPaint()
	onPyChanged: root.requestPaint()

	onPaint: {
		if (root.source === "" || !root.isImageLoaded(root.source)) return;
		const ctx = root.getContext("2d");
		ctx.clearRect(0, 0, 1, 1);
		ctx.drawImage(root.source, root.px, root.py, 1, 1, 0, 0, 1, 1);
		const d = ctx.getImageData(0, 0, 1, 1).data;
		root.color = Qt.rgba(d[0] / 255, d[1] / 255, d[2] / 255, 1);
	}

	Component.onDestruction: if (root.loaded !== "") root.unloadImage(root.loaded)
}
