.pragma library

// Finds sensitive tokens in tesseract TSV output and returns their boxes in
// the coordinates of the OCR'd image: [{ x, y, w, h, kind }], one per match.
// Words of a line are joined with single spaces, the patterns run over the
// line text and every match covers the (partial) boxes of the words it spans.

function luhn(digits) {
	let sum = 0;
	for (let i = 0; i < digits.length; i += 1) {
		let d = Number(digits[digits.length - 1 - i]);
		if (i % 2 === 1) {
			d *= 2;
			if (d > 9) d -= 9;
		}
		sum += d;
	}
	return sum % 10 === 0;
}

function digitCount(s) {
	return (s.match(/\d/g) || []).length;
}

// token that looks random: long, mixes digits with letters (or is pure hex)
function looksRandom(s) {
	const t = s.replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9=]+$/g, "");
	if (t.length < 20) return false;
	if (/^[0-9a-fA-F]+$/.test(t)) return t.length >= 24 && /[a-fA-F]/.test(t) && /\d/.test(t);
	if (!/\d/.test(t) || !/[A-Za-z]/.test(t)) return false;
	const classes = [/[a-z]/, /[A-Z]/, /\d/, /[_\-+/=]/].filter(r => r.test(t)).length;
	return classes >= 3 || t.length >= 32;
}

const patterns = [
	{ kind: "email", re: /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/g },
	// URLs carrying credentials or tokens
	{ kind: "url", re: /\b(?:https?|ftp):\/\/\S+/gi, check: m => /[?&#;](?:[a-z_]*(?:token|key|secret|sig|signature|auth|session|sid|code|pass(?:word)?|pwd|credential)[a-z_]*)=/i.test(m) || /\/\/[^/\s:@]+:[^/\s@]+@/.test(m) },
	{ kind: "jwt", re: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g },
	{ kind: "key", re: /\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{16,}/g },
	{ kind: "key", re: /\b(?:ghp|gho|ghu|ghs|ghr|github_pat|glpat|xox[abprs])[-_][A-Za-z0-9_-]{16,}/g },
	{ kind: "key", re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g },
	{ kind: "key", re: /\bAIza[0-9A-Za-z_-]{30,}/g },
	// "password: hunter2", "api_key=…": the value only
	{ kind: "secret", re: /\b(?:pass(?:wor[dt])?|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|client[_-]?secret|private[_-]?key|auth)\b\s*[:=]\s*("?)([^\s"]{4,})\1/gi, group: 2 },
	{ kind: "iban", re: /\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b/g, check: m => {
		const n = m.replace(/\s/g, "").length;
		return n >= 15 && n <= 34 && digitCount(m) >= 10;
	} },
	{ kind: "card", re: /\b\d{4}(?:[ -]?\d{4}){2}[ -]?\d{1,7}\b/g, check: m => {
		const d = m.replace(/\D/g, "");
		return d.length >= 13 && d.length <= 19 && (luhn(d) || /^\d{4}([ -])\d{4}\1\d{4}\1\d{4}$/.test(m));
	} },
	{ kind: "ip", re: /\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?::\d{1,5})?\b/g },
	// international (+49 …, 0049 …) and national (030 …, 0170 …) numbers
	{ kind: "phone", re: /(?:\+|\b00)\d{1,3}[\s./-]?(?:\(0\)[\s]?)?(?:\(?\d{1,5}\)?[\s./-]?){1,5}\d{2,}/g, check: m => {
		const n = digitCount(m);
		return n >= 8 && n <= 16;
	} },
	{ kind: "phone", re: /\b0\d{2,5}(?:\s?[/-]\s?|\s)?\d{3,}(?:[\s-]\d{2,6}){0,2}\b/g, check: m => {
		const n = digitCount(m);
		return n >= 7 && n <= 14 && !/^0\d{3}$/.test(m);
	} },
	{ kind: "token", re: /[A-Za-z0-9_\-+/=]{20,}/g, check: looksRandom }
];

// [{ text, start, end }] matches in one line of text, overlaps merged
function findInText(text) {
	const found = [];
	for (const p of patterns) {
		p.re.lastIndex = 0;
		let m;
		while ((m = p.re.exec(text)) !== null) {
			if (m[0].length === 0) {
				p.re.lastIndex += 1;
				continue;
			}
			if (p.check && !p.check(m[0])) continue;
			let start = m.index;
			let value = m[0];
			if (p.group) {
				value = m[p.group];
				start = m.index + m[0].lastIndexOf(value);
			}
			found.push({ kind: p.kind, start: start, end: start + value.length, text: value });
		}
	}
	found.sort((a, b) => a.start - b.start);
	const merged = [];
	for (const f of found) {
		const last = merged[merged.length - 1];
		if (last && f.start < last.end) {
			if (f.end > last.end) {
				last.end = f.end;
				last.text = text.slice(last.start, last.end);
			}
			continue;
		}
		merged.push(Object.assign({}, f));
	}
	return merged;
}

function parseTsv(tsv) {
	const lines = new Map();
	for (const row of String(tsv || "").split("\n")) {
		const c = row.split("\t");
		if (c.length < 12 || c[0] !== "5") continue;
		const word = c.slice(11).join("\t").trim();
		if (word === "") continue;
		const key = `${c[1]}.${c[2]}.${c[3]}.${c[4]}`;
		if (!lines.has(key)) lines.set(key, []);
		lines.get(key).push({ x: Number(c[6]), y: Number(c[7]), w: Number(c[8]), h: Number(c[9]), text: word });
	}
	return Array.from(lines.values());
}

function find(tsv) {
	const boxes = [];
	for (const words of parseTsv(tsv)) {
		let text = "";
		const spans = words.map(w => {
			if (text !== "") text += " ";
			const start = text.length;
			text += w.text;
			return { start: start, end: text.length, word: w };
		});
		for (const match of findInText(text)) {
			let x1 = Infinity;
			let y1 = Infinity;
			let x2 = -Infinity;
			let y2 = -Infinity;
			for (const s of spans) {
				if (s.end <= match.start || s.start >= match.end) continue;
				// partial words: cut the box by the share of characters
				const len = Math.max(1, s.end - s.start);
				const from = Math.max(0, match.start - s.start) / len;
				const to = Math.min(len, match.end - s.start) / len;
				x1 = Math.min(x1, s.word.x + s.word.w * from);
				x2 = Math.max(x2, s.word.x + s.word.w * to);
				y1 = Math.min(y1, s.word.y);
				y2 = Math.max(y2, s.word.y + s.word.h);
			}
			if (x2 > x1 && y2 > y1) boxes.push({ x: x1, y: y1, w: x2 - x1, h: y2 - y1, kind: match.kind, text: match.text });
		}
	}
	return boxes;
}
