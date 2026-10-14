.pragma library

// Which AI feature a sentence asks for, found by its words (German and
// English) – the AI lines of the launcher (>ai) and of the file manager.
//
// An intent: { id, label, icon, words, group, shown, fallback, run(rest, prompt) }
// - words: stems; a stem takes every word that starts with it ("übersetz"
//   takes "übersetze", "übersetzen"), a stem with a space is a phrase
// - hints: stems that point to it a little but stay in the rest ("Rechnung"
//   asks for a search and is also what is searched for)
// - label: a string, or (rest, prompt) => string
// - fallback: offered for every sentence, after what matched; `instead`
//   names an intent it stands in for, and it goes when that one matched
// - rest: the sentence without the words that matched and without filler –
//   what to search for, what to translate
// The words of a language ("englisch", "into french") are left out of the
// rest; language(prompt) tells which one was meant.

const FILLER = new Set(("bitte mal mir mich ich du kannst könntest kann soll sollst will möchte würdest die der das den dem des ein eine einen "
	+ "einem einer und oder von vom zu zum zur mit aus auf in im ins an am es sie diese dieser dieses diesen alle alles mein meine meinen "
	+ "nach für über the a an to of for me please can you could would my it them these those this that all into in on with i want").split(" "));

const LANGUAGES = [
	["en", ["englisch", "english"]],
	["de", ["deutsch", "german"]],
	["fr", ["französisch", "franzoesisch", "french"]],
	["es", ["spanisch", "spanish"]],
	["it", ["italienisch", "italian"]],
	["nl", ["niederländisch", "holländisch", "dutch"]],
	["pl", ["polnisch", "polish"]],
	["tr", ["türkisch", "turkish"]],
	["uk", ["ukrainisch", "ukrainian"]],
	["ru", ["russisch", "russian"]],
	["ja", ["japanisch", "japanese"]],
	["zh", ["chinesisch", "chinese"]]
];

function bare(word) {
	return String(word).toLowerCase().replace(/[^a-z0-9äöüß\-]/g, "");
}

function takes(stem, word) {
	return word.length >= Math.min(stem.length, 3) && word.startsWith(stem);
}

function isLanguage(word) {
	return LANGUAGES.some(entry => entry[1].some(name => takes(name, word)));
}

// the language a sentence names ("ins Englische", "into French"), or ""
function language(prompt) {
	for (const word of String(prompt || "").split(/\s+/).map(bare)) {
		for (const entry of LANGUAGES) {
			if (entry[1].some(name => takes(name, word))) return entry[0];
		}
	}
	return "";
}

function score(intent, prompt, parts) {
	const text = ` ${parts.map(part => part.bare).join(" ")} `;
	let total = 0;
	const used = new Set();
	for (const stem of intent.words || []) {
		if (stem.includes(" ")) {
			if (text.includes(` ${stem}`)) {
				total += 2;
				for (const word of stem.split(" ")) used.add(word);
			}
			continue;
		}
		const hit = parts.find(part => !used.has(part.bare) && takes(stem, part.bare));
		if (!hit) continue;
		used.add(hit.bare);
		total += hit.bare === stem ? 1.5 : 1;
	}
	for (const stem of intent.hints || []) {
		if (parts.some(part => !used.has(part.bare) && takes(stem, part.bare))) total += 0.5;
	}
	return { score: total, used: used };
}

function restOf(parts, used) {
	return parts.filter(part => part.bare !== "" && !used.has(part.bare) && !FILLER.has(part.bare) && !isLanguage(part.bare))
		.map(part => part.word.replace(/^[„“"'«»]+|[„“"'«»?!.,:;]+$/g, ""))
		.filter(word => word !== "")
		.join(" ");
}

// the intents that fit the sentence, best first, then the fallbacks; with
// nothing typed every intent that is shown, in its order
function rank(prompt, intents) {
	const sentence = String(prompt || "").trim();
	const shown = (intents || []).filter(intent => intent && intent.shown !== false);
	const make = (intent, rest, value) => Object.assign({}, intent, {
		label: typeof intent.label === "function" ? intent.label(rest, sentence) : intent.label,
		score: value,
		rest: rest,
		run: () => intent.run(rest, sentence)
	});
	if (sentence === "") return shown.filter(intent => !intent.fallback || intent.empty).map(intent => make(intent, "", 0));
	const parts = sentence.split(/\s+/).map(word => ({ word: word, bare: bare(word) }));
	const found = [];
	const fallbacks = [];
	for (const intent of shown) {
		if (intent.fallback) {
			fallbacks.push(make(intent, sentence, 0));
			continue;
		}
		const result = score(intent, sentence, parts);
		if (result.score > 0) found.push(make(intent, restOf(parts, result.used), result.score));
	}
	found.sort((a, b) => b.score - a.score);
	return found.concat(fallbacks.filter(fallback => !found.some(entry => entry.id === fallback.instead)));
}
