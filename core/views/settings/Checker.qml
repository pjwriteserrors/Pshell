import QtQuick

// The checkerboard behind see-through colors.
Canvas {
	id: root

	property real cell: 6
	property color light: "#cfcfcf"
	property color dark: "#8a8a8a"

	onWidthChanged: requestPaint()
	onHeightChanged: requestPaint()
	onPaint: {
		const ctx = getContext("2d");
		ctx.fillStyle = root.light;
		ctx.fillRect(0, 0, width, height);
		ctx.fillStyle = root.dark;
		for (let y = 0; y < height; y += root.cell)
			for (let x = (Math.floor(y / root.cell) % 2) * root.cell; x < width; x += root.cell * 2)
				ctx.fillRect(x, y, root.cell, root.cell);
	}
}
