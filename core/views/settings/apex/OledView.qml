import QtQuick
import qs.style.theme

// The Apex's 128×40 OLED: a frame as the keyboard takes it (640 bytes as
// hex: five pages of 128 columns, bit 0 on top), white pixels on black.
Canvas {
	id: root

	property string frame: ""
	// small, inside the drawn keyboard: no grid, softer white
	property bool dim: false

	onFrameChanged: root.requestPaint()
	onWidthChanged: root.requestPaint()
	onHeightChanged: root.requestPaint()

	onPaint: {
		const ctx = root.getContext("2d");
		ctx.reset();
		ctx.fillStyle = "#05070a";
		ctx.fillRect(0, 0, root.width, root.height);
		if (root.frame.length < 1280) return;
		const px = Math.min(root.width / 128, root.height / 40);
		const ox = (root.width - px * 128) / 2;
		const oy = (root.height - px * 40) / 2;
		ctx.fillStyle = root.dim ? "#cfd8e3" : "#eef4ff";
		const gap = !root.dim && px >= 3 ? 0.6 : 0;
		for (let page = 0; page < 5; page += 1) {
			for (let x = 0; x < 128; x += 1) {
				const at = (page * 128 + x) * 2;
				const byte = parseInt(root.frame.substr(at, 2), 16);
				if (!byte) continue;
				for (let bit = 0; bit < 8; bit += 1)
					if (byte & (1 << bit))
						ctx.fillRect(ox + x * px, oy + (page * 8 + bit) * px, px - gap, px - gap);
			}
		}
	}
}
