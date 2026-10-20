pragma Singleton

import QtQuick
import Quickshell

// Arithmetic for the launcher (>c), previews and shelves, worked out here:
// numbers (1.5 or 1,5), + - * / × ÷ : ^ **, mod, a % after a number (15% is
// 0.15, 200 + 10% is 220), ! (factorial), parentheses, π and e, and sqrt cbrt
// sin cos tan asin acos atan (degrees) log (base 10) ln exp abs round floor
// ceil. No eval, no process.
Singleton {
	id: root

	readonly property var functions: ({
		sqrt: Math.sqrt,
		cbrt: Math.cbrt,
		sin: x => Math.sin(x * Math.PI / 180),
		cos: x => Math.cos(x * Math.PI / 180),
		tan: x => Math.tan(x * Math.PI / 180),
		asin: x => Math.asin(x) * 180 / Math.PI,
		acos: x => Math.acos(x) * 180 / Math.PI,
		atan: x => Math.atan(x) * 180 / Math.PI,
		log: Math.log10,
		ln: Math.log,
		exp: Math.exp,
		abs: Math.abs,
		round: Math.round,
		floor: Math.floor,
		ceil: Math.ceil
	})
	readonly property var constants: ({ pi: Math.PI, "π": Math.PI, e: Math.E })

	// { ok, value, text, error }: text is the value as it is shown
	function evaluate(expression) {
		const source = String(expression ?? "").trim();
		if (source === "") return { ok: false, value: NaN, text: "", error: "empty" };
		try {
			const tokens = root.tokens(source);
			const state = { tokens: tokens, at: 0 };
			const value = root.sum(state);
			if (state.at < tokens.length) throw new Error(`unexpected ${tokens[state.at].text}`);
			if (!Number.isFinite(value)) return { ok: false, value: value, text: "", error: "no finite result" };
			return { ok: true, value: value, text: root.show(value), error: "" };
		} catch (error) {
			return { ok: false, value: NaN, text: "", error: String(error.message ?? error) };
		}
	}

	// 0.1 + 0.2 reads 0.3
	function show(value) {
		if (Number.isInteger(value) && Math.abs(value) < 1e21) return String(value);
		return String(Number(value.toPrecision(12)));
	}

	function tokens(source) {
		const out = [];
		let i = 0;
		while (i < source.length) {
			const c = source[i];
			if (/\s/.test(c)) {
				i += 1;
				continue;
			}
			const number = /^(\d+(?:[.,]\d+)?|[.,]\d+)(?:e[+-]?\d+)?/i.exec(source.slice(i));
			if (number) {
				out.push({ kind: "num", value: Number(number[0].replace(",", ".")), text: number[0] });
				i += number[0].length;
				continue;
			}
			const word = /^[a-zπ]+/i.exec(source.slice(i));
			if (word) {
				const name = word[0].toLowerCase();
				out.push(name === "mod" ? { kind: "op", text: "mod" } : { kind: "word", text: name });
				i += word[0].length;
				continue;
			}
			if (source.startsWith("**", i)) {
				out.push({ kind: "op", text: "^" });
				i += 2;
				continue;
			}
			const op = { "×": "*", "·": "*", "÷": "/", ":": "/", "−": "-" }[c] ?? c;
			if (!"+-*/^%!()".includes(op)) throw new Error(`unknown ${c}`);
			out.push({ kind: "op", text: op });
			i += 1;
		}
		return out;
	}

	function peek(state) {
		return state.tokens[state.at] ?? null;
	}

	function isOp(token, text) {
		return token !== null && token.kind === "op" && token.text === text;
	}

	// a % that ends an operand (15%, before ) or an operator or the end)
	function percentAt(state) {
		const next = state.tokens[state.at + 1] ?? null;
		return root.isOp(root.peek(state), "%") && (next === null || (next.kind === "op" && next.text !== "(" && next.text !== "-"));
	}

	function sum(state) {
		let value = root.product(state);
		while (root.isOp(root.peek(state), "+") || root.isOp(root.peek(state), "-")) {
			const op = state.tokens[state.at++].text;
			const start = state.at;
			let right = root.product(state);
			// 200 + 10% is 200 plus a tenth of it
			if (state.tokens[state.at - 1]?.percent && state.at - start === 2) right = value * right;
			value = op === "+" ? value + right : value - right;
		}
		return value;
	}

	function product(state) {
		let value = root.unary(state);
		for (;;) {
			const token = root.peek(state);
			if (root.isOp(token, "*") || root.isOp(token, "/") || root.isOp(token, "mod") || (root.isOp(token, "%") && !root.percentAt(state))) {
				state.at += 1;
				const right = root.unary(state);
				if (token.text === "*") value *= right;
				else if (token.text === "/") value /= right;
				else value = ((value % right) + right) % right;
			} else if (token !== null && (token.kind === "num" || token.kind === "word" || root.isOp(token, "("))) {
				// 2π, 3(4 + 1)
				value *= root.unary(state);
			} else {
				return value;
			}
		}
	}

	function unary(state) {
		if (root.isOp(root.peek(state), "-")) {
			state.at += 1;
			return -root.unary(state);
		}
		if (root.isOp(root.peek(state), "+")) {
			state.at += 1;
			return root.unary(state);
		}
		return root.power(state);
	}

	function power(state) {
		const base = root.postfix(state);
		if (root.isOp(root.peek(state), "^")) {
			state.at += 1;
			return Math.pow(base, root.unary(state));
		}
		return base;
	}

	function postfix(state) {
		let value = root.atom(state);
		for (;;) {
			if (root.isOp(root.peek(state), "!")) {
				state.at += 1;
				if (value < 0 || !Number.isInteger(value) || value > 170) throw new Error("factorial of a whole number up to 170");
				let result = 1;
				for (let n = 2; n <= value; n += 1) result *= n;
				value = result;
			} else if (root.percentAt(state)) {
				state.tokens[state.at].percent = true;
				state.at += 1;
				value /= 100;
			} else {
				return value;
			}
		}
	}

	function atom(state) {
		const token = state.tokens[state.at++];
		if (!token) throw new Error("incomplete");
		if (token.kind === "num") return token.value;
		if (root.isOp(token, "(")) {
			const value = root.sum(state);
			if (!root.isOp(root.peek(state), ")")) throw new Error("missing )");
			state.at += 1;
			return value;
		}
		if (token.kind === "word") {
			if (token.text in root.constants) return root.constants[token.text];
			const fn = root.functions[token.text];
			if (!fn) throw new Error(`unknown ${token.text}`);
			return fn(root.postfix(state));
		}
		throw new Error(`unexpected ${token.text}`);
	}
}
