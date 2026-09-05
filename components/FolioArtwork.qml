pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: root
    property color tint: Atelier.sage
    property string motif: "orbit"
    opacity: 0.9
    Canvas {
        id: drawing
        anchors.fill: parent
        Connections {
            target: root
            function onTintChanged() { drawing.requestPaint(); }
            function onMotifChanged() { drawing.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const c = getContext("2d"); c.reset();
            if (width <= 0 || height <= 0) return;
            const cx = width / 2, cy = height / 2, r = Math.min(width, height) * 0.34;
            c.strokeStyle = root.tint; c.fillStyle = root.tint;
            c.lineWidth = 1;
            if (root.motif === "signal") {
                for (let i = 0; i < 21; i++) {
                    const x = width * 0.08 + i * width * 0.042;
                    const h = (0.22 + 0.65 * Math.abs(Math.sin(i * 0.38))) * height;
                    c.beginPath(); c.moveTo(x, cy - h / 2); c.lineTo(x, cy + h / 2); c.stroke();
                }
            } else {
                for (let i = 0; i < 4; i++) {
                    c.beginPath(); c.arc(cx, cy, r * (0.5 + i * 0.23), 0, Math.PI * 2); c.stroke();
                }
                c.beginPath(); c.arc(cx + r * 0.72, cy - r * 0.7, r * 0.22, 0, Math.PI * 2); c.fill();
                c.beginPath(); c.moveTo(cx - r * 1.45, cy); c.lineTo(cx + r * 1.45, cy); c.stroke();
                c.beginPath(); c.moveTo(cx, cy - r * 1.45); c.lineTo(cx, cy + r * 1.45); c.stroke();
            }
        }
    }
}
