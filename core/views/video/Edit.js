.pragma library

// What the editor's panels share: times written for cutting, ids, what is
// shown at a moment, and whether a recipe can be cut without re-encoding.
// Kept here (a library, one for the whole shell), the scene changes found
// stay found while the panels come and go.

// minutes, seconds and tenths ("1:02.4")
function time(t) {
	const s = Math.max(0, Number(t) || 0);
	const tenths = Math.floor((s % 1) * 10 + 1e-6);
	const whole = Math.floor(s);
	const h = Math.floor(whole / 3600), m = Math.floor(whole / 60) % 60, sec = whole % 60;
	const ss = (sec < 10 ? "0" : "") + sec;
	return (h > 0 ? `${h}:${m < 10 ? "0" : ""}${m}` : `${m}`) + `:${ss}.${tenths}`;
}

// a length in words ("2.4 s", "1 min 12 s")
function length(t) {
	const s = Math.max(0, Number(t) || 0);
	if (s < 60) return `${Math.round(s * 10) / 10} s`;
	return `${Math.floor(s / 60)} min ${Math.round(s % 60)} s`;
}

// "1:02.4" or "62.4" or "1:02:03.5" back to seconds (NaN when it is no time)
function parse(text) {
	const parts = String(text).trim().replace(",", ".").split(":");
	if (parts.length === 0 || parts.length > 3 || parts.some(p => p === "" || isNaN(Number(p)))) return NaN;
	return parts.reduce((total, p) => total * 60 + Number(p), 0);
}

function uid(prefix) {
	return prefix + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
}

function copy(value) {
	return JSON.parse(JSON.stringify(value));
}

// how strongly an item with a fade shows at t (0..1)
function presence(item, t) {
	if (!item || t < item.a || t >= item.b) return 0;
	const fade = Number(item.fade) || 0;
	if (fade <= 0) return 1;
	return Math.max(0, Math.min(1, (t - item.a) / fade, (item.b - t) / fade));
}

// the found scene changes per file (source seconds)
var scenes = ({});

// everything left as it came except the cuts: then the parts can be copied
// as they are (fast, no loss – the cuts land on keyframes)
function cutOnly(recipe, clips) {
	const r = recipe || {};
	const g = r.geometry || {};
	const c = g.crop || { x: 0, y: 0, w: 1, h: 1 };
	const geometryPlain = !(g.rot % 4) && !g.flip && !Math.abs(g.angle || 0) && !Math.abs(g.vertical || 0) && !Math.abs(g.horizontal || 0) && !g.quad && !g.pad
		&& c.x < 1e-5 && c.y < 1e-5 && c.w > 1 - 1e-5 && c.h > 1 - 1e-5;
	const colourPlain = Object.values(r.adjust || {}).every(v => Math.abs(Number(v) || 0) < 1e-4)
		&& Object.values(r.curves || {}).every(p => !p || p.every(q => Math.abs(q[0] - q[1]) < 1e-4))
		&& !(Number(r.tones?.shadowAmount) > 0) && !(Number(r.tones?.highlightAmount) > 0);
	const a = r.audio || {};
	const soundPlain = !a.gain && !a.fadeIn && !a.fadeOut && !a.denoise && !a.normalize && !a.mute && !a.replace && !a.music?.path && !(a.keys?.length > 0);
	const clipsPlain = (clips || []).every(k => (k.speed || 1) === 1 && !k.reverse && !(k.hold > 0) && (k.volume ?? 1) === 1);
	return geometryPlain && colourPlain && soundPlain && clipsPlain && !(r.stabilize > 0) && !(r.texts?.length > 0) && !(r.blurs?.length > 0) && !r.faces && !r.subtitles?.burn;
}

// what keeps it from a plain cut, in words
function cutOnlyBlockers(recipe, clips) {
	const r = recipe || {};
	const out = [];
	if ((clips || []).some(k => (k.speed || 1) !== 1 || k.reverse || k.hold > 0 || (k.volume ?? 1) !== 1)) out.push("speed or sound of a clip");
	if (!cutOnly(Object.assign({}, r, { adjust: {}, curves: {}, tones: {}, audio: {}, stabilize: 0, texts: [], blurs: [], faces: false, subtitles: {} }), [])) out.push("the frame");
	if (!cutOnly(Object.assign({}, r, { geometry: {}, audio: {}, stabilize: 0, texts: [], blurs: [], faces: false, subtitles: {} }), [])) out.push("the colours");
	if (!cutOnly(Object.assign({}, r, { geometry: {}, adjust: {}, curves: {}, tones: {}, stabilize: 0, texts: [], blurs: [], faces: false, subtitles: {} }), [])) out.push("the sound");
	if (r.stabilize > 0) out.push("steadying");
	if (r.texts?.length > 0) out.push("texts");
	if (r.blurs?.length > 0 || r.faces) out.push("blurs");
	if (r.subtitles?.burn) out.push("burnt-in subtitles");
	return out;
}
