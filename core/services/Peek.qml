pragma Singleton

import QtQuick
import Quickshell
import qs.style.theme

// What a piece of text or a file is, for previews: a colour, a calculation,
// a LaTeX formula, code (with its language) or plain text; files by type.
// Code is highlighted and formulas are set as rich text right here, in the
// theme's colours.
Singleton {
	id: root

	// ── colours ──────────────────────────────────────────────────────────
	// "#abc", "#aabbcc", "#aabbccdd" (CSS order), rgb()/rgba(), hsl()/hsla()
	function colorOf(text) {
		const value = String(text).trim();
		let m = value.match(/^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i);
		if (m) {
			let hex = m[1];
			if (hex.length <= 4) hex = hex.split("").map(c => c + c).join("");
			const alpha = hex.length === 8 ? parseInt(hex.slice(6), 16) / 255 : 1;
			return Qt.rgba(parseInt(hex.slice(0, 2), 16) / 255, parseInt(hex.slice(2, 4), 16) / 255, parseInt(hex.slice(4, 6), 16) / 255, alpha);
		}
		const number = "([\\d.]+%?)";
		const sep = "\\s*[,\\s]\\s*";
		const alpha = `(?:\\s*[,/]\\s*${number})?`;
		m = value.match(new RegExp(`^rgba?\\(\\s*${number}${sep}${number}${sep}${number}${alpha}\\s*\\)$`, "i"));
		if (m) {
			const channel = v => v.endsWith("%") ? parseFloat(v) / 100 : parseFloat(v) / 255;
			const values = [channel(m[1]), channel(m[2]), channel(m[3])];
			if (values.some(v => isNaN(v) || v > 1)) return null;
			return Qt.rgba(values[0], values[1], values[2], root.alphaOf(m[4]));
		}
		m = value.match(new RegExp(`^hsla?\\(\\s*([\\d.]+)(?:deg)?${sep}${number}${sep}${number}${alpha}\\s*\\)$`, "i"));
		if (m) {
			const s = parseFloat(m[2]) / 100;
			const l = parseFloat(m[3]) / 100;
			if (isNaN(s) || isNaN(l) || s > 1 || l > 1) return null;
			return Qt.hsla((parseFloat(m[1]) % 360) / 360, s, l, root.alphaOf(m[4]));
		}
		return null;
	}

	function alphaOf(value) {
		if (value === undefined) return 1;
		const a = String(value).endsWith("%") ? parseFloat(value) / 100 : parseFloat(value);
		return isNaN(a) ? 1 : Math.max(0, Math.min(1, a));
	}

	function hexOf(color) {
		const part = v => Math.round(v * 255).toString(16).padStart(2, "0");
		return `#${part(color.r)}${part(color.g)}${part(color.b)}${color.a < 1 ? part(color.a) : ""}`.toUpperCase();
	}

	function notationsOf(color) {
		const r = Math.round(color.r * 255);
		const g = Math.round(color.g * 255);
		const b = Math.round(color.b * 255);
		const alpha = color.a < 1 ? `, ${Math.round(color.a * 100) / 100}` : "";
		const h = Math.round(Math.max(0, color.hslHue) * 360);
		const s = Math.round(color.hslSaturation * 100);
		const l = Math.round(color.hslLightness * 100);
		return [root.hexOf(color), `rgb${alpha ? "a" : ""}(${r}, ${g}, ${b}${alpha})`, `hsl${alpha ? "a" : ""}(${h}, ${s}%, ${l}%${alpha})`];
	}

	// ── what a text is ───────────────────────────────────────────────────
	// { type: "color", color } | { type: "math" } | { type: "latex" }
	// | { type: "code", lang } | { type: "text" }
	function kindOfText(text) {
		const value = String(text ?? "");
		const trimmed = value.trim();
		const color = root.colorOf(trimmed);
		if (color) return { type: "color", color: color };
		if (root.isMath(trimmed)) return { type: "math" };
		if (root.isLatex(trimmed)) return { type: "latex" };
		const lang = root.guessLang(value);
		if (lang !== "") return { type: "code", lang: lang };
		return { type: "text" };
	}

	readonly property var mathWords: ["sqrt", "cbrt", "sin", "cos", "tan", "asin", "acos", "atan", "log", "ln", "exp", "abs", "round", "floor", "ceil", "pi", "e", "mod"]

	// arithmetic that qalc can work out: numbers, operators, a few functions.
	// Dates, versions, phone numbers and ranges ("10-20") are no sums.
	function isMath(text) {
		if (text.length > 160 || text.includes("\n") || !/\d/.test(text)) return false;
		if (!/^[\d\s.,+\-*/^()%×÷π!a-z]+$/i.test(text)) return false;
		const words = text.toLowerCase().match(/[a-z]+/g) ?? [];
		if (words.some(word => !root.mathWords.includes(word))) return false;
		if (/^\+[\d\s\-/()]+$/.test(text)) return false;
		const call = /\b[a-z]+\(\s*[\d.π]/i.test(text);
		const operation = /[\d).π]\s*(\*\*|[+*^×÷%])\s*[\d(.a-zπ]/i.test(text) || /[\d)]\s*[-/]\s*\(/.test(text) || /\)\s*[-/]\s*\d/.test(text);
		return call || operation;
	}

	function isLatex(text) {
		if (text.length > 2000) return false;
		if (/^\$\$?[\s\S]+\$\$?$/.test(text) && /[\\^_{]/.test(text)) return true;
		if (/^\\\[[\s\S]+\\\]$/.test(text) || /^\\\([\s\S]+\\\)$/.test(text)) return true;
		const commands = text.match(/\\(frac|sqrt|sum|prod|int|oint|lim|alpha|beta|gamma|delta|epsilon|theta|lambda|mu|pi|sigma|omega|phi|cdot|times|leq|geq|neq|approx|infty|partial|nabla|mathbb|mathrm|left|right|begin|vec|hat|pm|to|rightarrow|in|forall|exists)\b/g) ?? [];
		return commands.length >= 1 && !/\b(function|return|const|def|import|class)\b/.test(text) && text.split("\n").length <= 12;
	}

	// ── languages ────────────────────────────────────────────────────────
	readonly property var langNames: ({
		json: "JSON", python: "Python", js: "JavaScript", ts: "TypeScript", qml: "QML", shell: "Shell", sql: "SQL",
		html: "HTML", xml: "XML", css: "CSS", rust: "Rust", go: "Go", c: "C", cpp: "C++", java: "Java", csharp: "C#",
		php: "PHP", yaml: "YAML", toml: "TOML", diff: "Diff", kotlin: "Kotlin", swift: "Swift", ruby: "Ruby",
		lua: "Lua", markdown: "Markdown", ini: "INI", dockerfile: "Dockerfile", nix: "Nix", kdl: "KDL", code: "Code"
	})

	readonly property var extensions: ({
		json: "json", jsonc: "json", py: "python", js: "js", mjs: "js", cjs: "js", jsx: "js", ts: "ts", tsx: "ts",
		qml: "qml", sh: "shell", bash: "shell", zsh: "shell", fish: "shell", sql: "sql", html: "html", htm: "html",
		vue: "html", svelte: "html", xml: "xml", svg: "xml", css: "css", scss: "css", less: "css", rs: "rust", go: "go",
		c: "c", h: "c", cc: "cpp", cpp: "cpp", cxx: "cpp", hpp: "cpp", java: "java", cs: "csharp", php: "php",
		yml: "yaml", yaml: "yaml", toml: "toml", diff: "diff", patch: "diff", kt: "kotlin", swift: "swift",
		rb: "ruby", lua: "lua", md: "markdown", ini: "ini", conf: "ini", cfg: "ini", nix: "nix", kdl: "kdl",
		twig: "html", glsl: "c", frag: "c", vert: "c"
	})

	function langOfPath(path) {
		const name = String(path).split("/").pop();
		if (/^(Dockerfile|Containerfile)$/i.test(name)) return "dockerfile";
		if (/^(Makefile|\.?\w*rc|\.env.*)$/.test(name)) return "shell";
		const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
		return root.extensions[ext] ?? "";
	}

	function langName(lang) {
		return root.langNames[lang] ?? lang;
	}

	// a language for pasted text, "" when it reads like prose
	function guessLang(text) {
		const value = String(text).trim();
		if (value.length < 8 || value.length > 200000) return "";
		const lines = value.split("\n");
		if (/^[{\[]/.test(value)) {
			try {
				const parsed = JSON.parse(value);
				if (typeof parsed === "object" && parsed !== null) return "json";
			} catch (error) {}
		}
		if (/^#!.*\b(ba|z|fi)?sh\b/.test(value)) return "shell";
		if (/^#!.*python/.test(value)) return "python";
		if (/^#!.*node/.test(value)) return "js";
		if (/^<\?php/.test(value)) return "php";
		if (/^(diff --git|--- \S|@@ -\d)/m.test(value) && lines.filter(l => /^[+\-@ ]/.test(l)).length > lines.length * 0.7) return "diff";
		if (/^<\?xml|^<(svg|feed|rss|project)\b/i.test(value)) return "xml";
		if (/^<(!doctype|html|div|span|template|head|body|section|a|p|ul|table|button|script|style)\b/i.test(value)) return "html";
		if (/^import (QtQuick|Quickshell)/m.test(value) || /^\s*(readonly )?property (var|int|bool|string|real|color|list)\b/m.test(value)) return "qml";
		if (/^\s*(SELECT\s[\s\S]+\sFROM|INSERT INTO|UPDATE \w+ SET|DELETE FROM|CREATE (TABLE|INDEX|VIEW)|ALTER TABLE|WITH \w+ AS \()/i.test(value)) return "sql";
		if (/^\s*(def |class \w+(\(.*\))?:|from [\w.]+ import |import \w+$|if __name__|elif |async def )/m.test(value) || /\bself\.\w+/.test(value) && /:\s*$/m.test(value)) return "python";
		if (/^\s*(fn |pub (fn|struct|enum)|impl |use \w+::|let mut )/m.test(value)) return "rust";
		if (/^package \w+$/m.test(value) || /^\s*func (\(\w+ \*?\w+\) )?\w+\(/m.test(value)) return "go";
		if (/^\s*#include\s*[<"]/m.test(value)) return /\b(std::|class |template|namespace)\b/.test(value) ? "cpp" : "c";
		if (/^\s*(public |private |protected )?(static )?(class|interface) \w+/m.test(value) && /;\s*$/m.test(value)) return /\bSystem\.out\b|\bimport java\./.test(value) ? "java" : (/\busing System\b|\bnamespace\b/.test(value) ? "csharp" : "java");
		if (/\b(interface \w+ \{|type \w+ = |: (string|number|boolean)\b|as const\b)/.test(value) && /\b(const|let|function|=>|export)\b/.test(value)) return "ts";
		if (/^\s*(const|let|var) \w+\s*=|^\s*(export )?(default )?(async )?function\b|=>\s*[{(]|\bconsole\.\w+\(|\bdocument\.\w+|^\s*import .+ from ['"]|\brequire\(['"]/m.test(value)) return "js";
		if (/^\s*[.#]?[\w\-\s,:>.#\[\]="*]+\{\s*$/m.test(value) && /^\s*[\w-]+\s*:\s*[^;]+;\s*$/m.test(value)) return "css";
		if (/^\s*(FROM|RUN|COPY|WORKDIR|ENTRYPOINT|CMD) /m.test(value) && /^FROM /m.test(value)) return "dockerfile";
		if (/^\s*(\$ |sudo |apt |pacman |yay |git |cd |ls |echo |export \w+=|curl |npm |pnpm |docker |systemctl |journalctl |chmod |mkdir )/m.test(value) || /\s\|\s*(grep|awk|sed|xargs|head|tail|sort|wc)\b/.test(value) || /\s&&\s/.test(value) && lines.length <= 3) return "shell";
		if (/^\[[\w.\-]+\]\s*$/m.test(value) && /^\s*[\w.\-]+\s*=\s*.+$/m.test(value)) return "toml";
		if (lines.length >= 3 && lines.filter(l => /^\s*(- )?[\w\-"]+:(\s|$)/.test(l) || /^\s*- /.test(l) || /^\s*(#.*)?$/.test(l)).length === lines.length && lines.some(l => /^\s+\S/.test(l))) return "yaml";
		// generic code: symbols and indentation where prose has words
		if (lines.length >= 2) {
			const symbols = (value.match(/[{}();=<>\[\]]/g) ?? []).length;
			const endings = lines.filter(l => /[;{}]\s*$/.test(l)).length;
			if (symbols / value.length > 0.04 && endings >= Math.max(2, lines.length * 0.3)) return "code";
		}
		return "";
	}

	// ── highlighting ─────────────────────────────────────────────────────
	readonly property var keywords: ({
		clike: "if else for while do switch case default break continue return function const let var new delete typeof instanceof in of class extends super this import export from as async await yield try catch finally throw void null undefined true false static public private protected interface enum type struct fn let mut impl trait pub use mod match loop where self Self package func go defer chan map range select var int float double char bool boolean string long short unsigned signed auto namespace template typename using virtual override final abstract sealed readonly property signal required pragma alias component nullptr true false nil val when object fun is",
		python: "def class if elif else for while in not and or is return import from as with try except finally raise pass break continue lambda yield global nonlocal assert del async await True False None self match case",
		shell: "if then else elif fi for in do done while until case esac function return local export readonly declare unset source exit echo cd sudo set shift",
		sql: "select from where and or not insert into values update set delete create table index view drop alter add join left right inner outer full on group by order having limit offset as distinct union all null is in like between exists case when then else end primary key foreign references default begin commit rollback with returning asc desc count sum avg min max",
		yaml: "true false null yes no on off",
		ruby: "def end class module if elsif else unless while until for in do return yield begin rescue ensure raise nil true false self require attr_accessor",
		lua: "function end local if then elseif else for in do while repeat until return nil true false and or not",
		dockerfile: "FROM RUN CMD COPY ADD WORKDIR ENV ARG EXPOSE ENTRYPOINT VOLUME USER LABEL AS"
	})

	readonly property var keywordSets: {
		const sets = {};
		for (const family of Object.keys(root.keywords)) {
			const set = {};
			for (const word of root.keywords[family].split(" ")) set[family === "sql" ? word.toLowerCase() : word] = true;
			sets[family] = set;
		}
		return sets;
	}

	function familyOf(lang) {
		if (["python", "shell", "yaml", "toml", "ini", "ruby", "nix", "dockerfile"].includes(lang)) return { comment: "#", family: ["python", "shell", "ruby", "dockerfile"].includes(lang) ? lang : "yaml" };
		if (lang === "sql") return { comment: "--", block: true, family: "sql" };
		if (lang === "lua") return { comment: "--", family: "lua" };
		return { comment: "//", block: true, family: "clike" };
	}

	readonly property var palette: ({
		keyword: root.solid(Theme.primary),
		string: root.solid(Theme.success),
		number: root.solid(Theme.warning),
		comment: root.solid(Theme.textSubtle),
		func: root.solid(Theme.secondary),
		type: root.solid(Theme.tertiary),
		punct: root.solid(Theme.textMuted),
		added: root.solid(Theme.success),
		removed: root.solid(Theme.danger)
	})

	function solid(color) {
		return root.hexOf(Qt.tint(Theme.base, color)).slice(0, 7);
	}

	function escaped(text) {
		return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
	}

	function span(text, role) {
		const safe = root.escaped(text);
		return role ? `<span style="color:${root.palette[role]}">${safe}</span>` : safe;
	}

	// rich text of `text` in `lang`; `limit` characters at most
	function highlight(text, lang, limit) {
		let source = String(text ?? "").replace(/\t/g, "    ");
		if (limit && source.length > limit) source = source.slice(0, limit);
		let body = "";
		if (lang === "markdown" || lang === "") body = root.escaped(source);
		else if (lang === "diff") body = root.highlightDiff(source);
		else if (lang === "html" || lang === "xml") body = root.highlightMarkup(source);
		else if (lang === "json") body = root.highlightJson(source);
		else body = root.highlightCode(source, lang);
		return `<div style="white-space:pre-wrap">${body}</div>`;
	}

	function highlightCode(source, lang) {
		const style = root.familyOf(lang);
		const words = root.keywordSets[style.family] ?? {};
		const line = style.comment.replace(/[/\\^$*+?.()|[\]{}]/g, "\\$&") + ".*";
		const comment = style.block ? `${line}|\\/\\*[\\s\\S]*?(?:\\*\\/|$)` : line;
		const strings = lang === "rust" ? `"(?:\\\\.|[^"\\\\])*"?` : "\"(?:\\\\.|[^\"\\\\\\n])*\"?|'(?:\\\\.|[^'\\\\\\n])*'?|`(?:\\\\.|[^`\\\\])*`?";
		const pattern = new RegExp(`(${comment})|(${strings})|(\\b(?:0x[\\da-fA-F]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b)|([A-Za-z_$@][\\w$]*)|([{}()\\[\\];,.:=<>+\\-*/!&|?%^~]+)|(\\s+|.)`, "g");
		let out = "";
		let match;
		while ((match = pattern.exec(source)) !== null) {
			if (match[1]) out += root.span(match[1], "comment");
			else if (match[2]) out += root.span(match[2], "string");
			else if (match[3]) out += root.span(match[3], "number");
			else if (match[4]) {
				const word = match[4];
				const key = style.family === "sql" ? word.toLowerCase() : word;
				const next = source.slice(pattern.lastIndex).match(/^\s*\(/);
				if (words[key]) out += root.span(word, "keyword");
				else if (next) out += root.span(word, "func");
				else if (/^[A-Z][a-z]/.test(word) && style.family !== "sql") out += root.span(word, "type");
				else out += root.span(word, "");
			} else if (match[5]) out += root.span(match[5], "punct");
			else out += root.escaped(match[0]);
		}
		return out;
	}

	function highlightJson(source) {
		const pattern = /("(?:\\.|[^"\\])*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b|([{}\[\],:]+)|(\s+|.)/g;
		let out = "";
		let match;
		while ((match = pattern.exec(source)) !== null) {
			if (match[1]) out += root.span(match[1], match[2] ? "func" : "string") + (match[2] ? root.span(match[2], "punct") : "");
			else if (match[3]) out += root.span(match[3], "number");
			else if (match[4]) out += root.span(match[4], "keyword");
			else if (match[5]) out += root.span(match[5], "punct");
			else out += root.escaped(match[0]);
		}
		return out;
	}

	function highlightMarkup(source) {
		const pattern = /(<!--[\s\S]*?(?:-->|$))|(<\/?[\w:.\-]+)|(\/?>)|([\w:\-@.#]+)(?==)|("[^"]*"?|'[^']*'?)|(&\w+;)|([^<>"'&=\w]+|[\s\S])/g;
		let out = "";
		let inTag = false;
		let match;
		while ((match = pattern.exec(source)) !== null) {
			if (match[1]) out += root.span(match[1], "comment");
			else if (match[2]) {
				inTag = true;
				out += root.span(match[2], "keyword");
			} else if (match[3]) {
				inTag = false;
				out += root.span(match[3], "keyword");
			} else if (match[4] && inTag) out += root.span(match[4], "func");
			else if (match[5] && inTag) out += root.span(match[5], "string");
			else if (match[6]) out += root.span(match[6], "number");
			else out += root.escaped(match[0]);
		}
		return out;
	}

	function highlightDiff(source) {
		return source.split("\n").map(line => {
			if (/^(\+\+\+|---|diff |index )/.test(line)) return root.span(line, "comment");
			if (line.startsWith("+")) return root.span(line, "added");
			if (line.startsWith("-")) return root.span(line, "removed");
			if (line.startsWith("@@")) return root.span(line, "keyword");
			return root.escaped(line);
		}).join("\n");
	}

	// ── LaTeX as rich text ───────────────────────────────────────────────
	readonly property var symbols: ({
		alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", varepsilon: "ε", zeta: "ζ", eta: "η", theta: "θ",
		vartheta: "ϑ", iota: "ι", kappa: "κ", lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", pi: "π", varpi: "ϖ", rho: "ρ",
		sigma: "σ", varsigma: "ς", tau: "τ", upsilon: "υ", phi: "φ", varphi: "φ", chi: "χ", psi: "ψ", omega: "ω",
		Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π", Sigma: "Σ", Upsilon: "Υ", Phi: "Φ", Psi: "Ψ", Omega: "Ω",
		cdot: "⋅", times: "×", div: "÷", pm: "±", mp: "∓", leq: "≤", le: "≤", geq: "≥", ge: "≥", neq: "≠", ne: "≠",
		approx: "≈", equiv: "≡", sim: "∼", simeq: "≃", propto: "∝", infty: "∞", partial: "∂", nabla: "∇",
		sum: "∑", prod: "∏", int: "∫", iint: "∬", oint: "∮", to: "→", rightarrow: "→", leftarrow: "←",
		Rightarrow: "⇒", Leftarrow: "⇐", Leftrightarrow: "⇔", leftrightarrow: "↔", mapsto: "↦", implies: "⟹", iff: "⟺",
		in: "∈", notin: "∉", subset: "⊂", subseteq: "⊆", supset: "⊃", supseteq: "⊇", cup: "∪", cap: "∩",
		emptyset: "∅", varnothing: "∅", forall: "∀", exists: "∃", neg: "¬", land: "∧", lor: "∨", wedge: "∧", vee: "∨",
		ldots: "…", cdots: "⋯", dots: "…", vdots: "⋮", ddots: "⋱", circ: "∘", bullet: "∙", star: "⋆", ast: "∗",
		langle: "⟨", rangle: "⟩", lfloor: "⌊", rfloor: "⌋", lceil: "⌈", rceil: "⌉", degree: "°", prime: "′",
		hbar: "ℏ", ell: "ℓ", Re: "ℜ", Im: "ℑ", aleph: "ℵ", angle: "∠", perp: "⊥", parallel: "∥", mid: "∣",
		quad: "  ", qquad: "    ", ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "{": "{", "}": "}", "\\": "<br>",
		sin: "sin", cos: "cos", tan: "tan", log: "log", ln: "ln", exp: "exp", lim: "lim", max: "max", min: "min", det: "det"
	})

	readonly property var doubleStruck: ({ R: "ℝ", N: "ℕ", Z: "ℤ", Q: "ℚ", C: "ℂ", P: "ℙ", H: "ℍ" })

	function latex(text) {
		let source = String(text).trim()
			.replace(/^\$\$?|\$\$?$/g, "")
			.replace(/^\\\[|\\\]$/g, "")
			.replace(/^\\\(|\\\)$/g, "")
			.replace(/\\begin\{[a-z*]+\}|\\end\{[a-z*]+\}/g, "")
			.replace(/&/g, " ");
		const state = { source: source, at: 0, upright: 0 };
		return root.latexGroup(state, "");
	}

	// reads until `end` (a closing brace or the end of the text)
	function latexGroup(state, end) {
		let out = "";
		while (state.at < state.source.length) {
			const c = state.source[state.at];
			if (c === end) {
				state.at += 1;
				return out;
			}
			out += root.latexAtom(state);
		}
		return out;
	}

	function latexArg(state) {
		while (state.source[state.at] === " ") state.at += 1;
		if (state.source[state.at] === "{") {
			state.at += 1;
			return root.latexGroup(state, "}");
		}
		return state.at < state.source.length ? root.latexAtom(state) : "";
	}

	function latexAtom(state) {
		const c = state.source[state.at];
		if (c === "{") {
			state.at += 1;
			return root.latexGroup(state, "}");
		}
		if (c === "^" || c === "_") {
			state.at += 1;
			const tag = c === "^" ? "sup" : "sub";
			return `<${tag}>${root.latexArg(state)}</${tag}>`;
		}
		if (c === "\\") {
			const m = state.source.slice(state.at + 1).match(/^([A-Za-z]+|.)/);
			const name = m ? m[1] : "";
			state.at += 1 + name.length;
			if (name === "frac" || name === "dfrac" || name === "tfrac") {
				const top = root.latexArg(state);
				const bottom = root.latexArg(state);
				return `<sup>${top}</sup>⁄<sub>${bottom}</sub>`;
			}
			if (name === "sqrt") {
				let index = "";
				if (state.source[state.at] === "[") {
					const close = state.source.indexOf("]", state.at);
					if (close < 0) return "√";
					index = `<sup>${root.escaped(state.source.slice(state.at + 1, close))}</sup>`;
					state.at = close + 1;
				}
				const arg = root.latexArg(state);
				return `${index}√${arg.replace(/<[^>]+>/g, "").length > 1 ? `(${arg})` : arg}`;
			}
			if (["mathbb", "text", "mathrm", "operatorname", "textrm", "mbox"].includes(name)) {
				state.upright += 1;
				const arg = root.latexArg(state);
				state.upright -= 1;
				return name === "mathbb" ? (root.doubleStruck[arg] ?? arg) : arg;
			}
			if (["mathbf", "textbf", "boldsymbol"].includes(name)) return `<b>${root.latexArg(state)}</b>`;
			if (["mathit", "textit"].includes(name)) return `<i>${root.latexArg(state)}</i>`;
			if (["overline", "bar"].includes(name)) return `<span style="text-decoration:overline">${root.latexArg(state)}</span>`;
			if (name === "vec") return `${root.latexArg(state)}\u20d7`;
			if (name === "hat") return `${root.latexArg(state)}\u0302`;
			if (name === "dot") return `${root.latexArg(state)}\u0307`;
			if (name === "tilde") return `${root.latexArg(state)}\u0303`;
			if (["left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "limits", "nolimits"].includes(name)) return "";
			if (name in root.symbols) return root.symbols[name];
			return root.escaped(name);
		}
		state.at += 1;
		if (/[a-zA-Z]/.test(c) && state.upright === 0) return `<i>${c}</i>`;
		if (c === "<" || c === ">" || c === "&") return root.escaped(c);
		return c === "~" ? " " : c;
	}

	// ── files ────────────────────────────────────────────────────────────
	// "gif" | "image" | "pdf" | "video" | "audio" | "code" | "thumb" | ""
	function kindOfFile(item) {
		if (!item || item.kind !== "file" || item.dir) return "";
		const mime = String(item.mime);
		if (mime === "image/gif") return "gif";
		if (mime.startsWith("image/")) return "image";
		if (mime === "application/pdf") return "pdf";
		if (mime.startsWith("video/")) return "video";
		if (mime.startsWith("audio/")) return "audio";
		if (root.langOfPath(item.path) !== "" || mime.startsWith("text/") || /json|xml|javascript|x-sh|x-python|yaml|toml/.test(mime)) return "code";
		return "thumb";
	}
}
