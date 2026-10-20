.pragma library

// What each of the mouse's haptic waveforms feels like, drawn: n samples
// in -1…1. Made up from how they feel, not read from the firmware.

var names = {
	"SHARP STATE CHANGE": "Sharp step", "DAMP STATE CHANGE": "Soft step", "SHARP COLLISION": "Hard bump",
	"DAMP COLLISION": "Soft bump", "SUBTLE COLLISION": "Tick", "WHISPER COLLISION": "Whisper",
	"HAPPY ALERT": "Happy", "ANGRY ALERT": "Angry", "COMPLETED": "Done", "SQUARE": "Square",
	"WAVE": "Wave", "FIREWORK": "Firework", "MAD": "Mad", "KNOCK": "Knock", "JINGLE": "Jingle", "RINGING": "Ringing"
};

function pulse(t, at, width, freq, decay) {
	if (t < at) return 0;
	var x = t - at;
	if (x > width) return 0;
	return Math.sin(x * freq * Math.PI * 2) * Math.exp(-x * decay);
}

function sample(name, n) {
	var out = [];
	for (var i = 0; i < n; i += 1) {
		var t = i / (n - 1);
		var y = 0;
		switch (name) {
		case "SHARP STATE CHANGE": y = pulse(t, 0.2, 0.25, 6, 18); break;
		case "DAMP STATE CHANGE": y = pulse(t, 0.15, 0.5, 3, 7) * 0.8; break;
		case "SHARP COLLISION": y = pulse(t, 0.1, 0.5, 12, 10); break;
		case "DAMP COLLISION": y = pulse(t, 0.1, 0.7, 6, 5) * 0.8; break;
		case "SUBTLE COLLISION": y = pulse(t, 0.3, 0.2, 8, 20) * 0.45; break;
		case "WHISPER COLLISION": y = pulse(t, 0.3, 0.2, 9, 22) * 0.22; break;
		case "HAPPY ALERT": y = pulse(t, 0.1, 0.25, 8, 8) * 0.6 + pulse(t, 0.5, 0.3, 10, 6); break;
		case "ANGRY ALERT":
			for (var k = 0; k < 4; k += 1) y += pulse(t, 0.05 + k * 0.23, 0.16, 16, 4);
			break;
		case "COMPLETED": y = pulse(t, 0.12, 0.2, 9, 12) * 0.7 + pulse(t, 0.45, 0.4, 7, 6); break;
		case "SQUARE": y = (Math.floor(t * 6) % 2 === 0 ? 0.8 : -0.8) * (t > 0.05 && t < 0.95 ? 1 : 0); break;
		case "WAVE": y = Math.sin(t * Math.PI * 6) * Math.sin(t * Math.PI); break;
		case "FIREWORK":
			for (var f = 0; f < 7; f += 1) y += pulse(t, 0.08 + f * 0.12, 0.08, 20, 30) * (0.4 + f * 0.1);
			break;
		case "MAD": y = Math.sin(t * 91) * Math.sin(t * 37) * (t > 0.05 && t < 0.95 ? 1 : 0); break;
		case "KNOCK": y = pulse(t, 0.15, 0.2, 7, 14) + pulse(t, 0.45, 0.2, 7, 14); break;
		case "JINGLE": y = pulse(t, 0.08, 0.25, 14, 9) * 0.7 + pulse(t, 0.35, 0.25, 18, 9) * 0.8 + pulse(t, 0.62, 0.3, 22, 7); break;
		case "RINGING": y = Math.sin(t * Math.PI * 28) * (0.3 + 0.7 * Math.abs(Math.sin(t * Math.PI * 3))) * (t > 0.04 ? 1 : 0); break;
		default: y = pulse(t, 0.2, 0.3, 8, 10);
		}
		out.push(Math.max(-1, Math.min(1, y)));
	}
	return out;
}
