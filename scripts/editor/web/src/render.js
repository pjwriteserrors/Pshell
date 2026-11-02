// Markdown to HTML for what is shown rendered: tables, columns, the reader.
// Raw HTML stays text here; only a code block's own preview runs it, sandboxed.
import MarkdownIt from "markdown-it";
import { LanguageDescription } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { highlightTree, classHighlighter } from "@lezer/highlight";

const md = new MarkdownIt({ html: false, linkify: true, typographer: false });

md.inline.ruler.before("link", "wikilink", (state, silent) => {
	const src = state.src.slice(state.pos);
	const match = src.match(/^\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]/);
	if (!match) return false;
	if (!silent) {
		const open = state.push("wiki_open", "a", 1);
		open.attrSet("data-wiki", match[1]);
		open.attrSet("class", "md-wiki");
		state.push("text", "", 0).content = match[2] || match[1];
		state.push("wiki_close", "a", -1);
	}
	state.pos += match[0].length;
	return true;
});

export function fileUrl(src, base) {
	if (/^(https?:|data:)/.test(src)) return src;
	const decoded = decodeURI(src);
	const path = decoded.startsWith("/") ? decoded : `${base || ""}/${decoded}`;
	return `pe://file${path.split("/").map(encodeURIComponent).join("/")}`;
}

// ::: columns … ||| … :::
export function render(text, base) {
	let out = "";
	let at = 0;
	const pattern = /^:::\s*columns[^\n]*\n([\s\S]*?)^:::\s*$/gm;
	for (const match of text.matchAll(pattern)) {
		out += renderPlain(text.slice(at, match.index), base);
		const parts = match[1].split(/^\|\|\|\s*$/m);
		out += `<div class="md-columns" style="--columns:${parts.length}">${parts.map(part => `<div class="md-column md-rendered">${renderPlain(part.trim(), base)}</div>`).join("")}</div>`;
		at = match.index + match[0].length;
	}
	return out + renderPlain(text.slice(at), base);
}

function renderPlain(text, base) {
	const env = { base };
	const tokens = md.parse(text, env);
	const walk = list => {
		for (const token of list) {
			if (token.type === "image") token.attrSet("src", fileUrl(token.attrGet("src"), base));
			if (token.children) walk(token.children);
		}
	};
	walk(tokens);
	let html = md.renderer.render(tokens, md.options, env);
	html = html.replace(/<li>(<p>)?\[( |x|X)\]\s/g, (_, p, mark) =>
		`<li class="md-task${mark === " " ? "" : " done"}">${p || ""}<span class="md-check${mark === " " ? "" : " on"}"></span>`);
	html = html.replace(/<blockquote>\s*<p>\[!(\w+)\]\s*/g, (_, kind) => {
		const name = kind.toLowerCase();
		return `<blockquote class="md-callout md-callout-${name}"><div class="md-callout-title">${name[0].toUpperCase()}${name.slice(1)}</div><p>`;
	});
	return html;
}

const loaded = new Map();
export async function parserFor(name) {
	if (!name) return null;
	if (loaded.has(name)) return loaded.get(name);
	const found = LanguageDescription.matchLanguageName(languages, name, true);
	const support = found ? await found.load() : null;
	const parser = support ? support.language.parser : null;
	loaded.set(name, parser);
	return parser;
}

export async function highlightInto(element, code, name) {
	const parser = await parserFor(name);
	if (!parser) {
		element.textContent = code;
		return;
	}
	const out = document.createDocumentFragment();
	let at = 0;
	highlightTree(parser.parse(code), classHighlighter, (from, to, classes) => {
		if (from > at) out.append(code.slice(at, from));
		const span = document.createElement("span");
		span.className = classes;
		span.textContent = code.slice(from, to);
		out.append(span);
		at = to;
	});
	if (at < code.length) out.append(code.slice(at));
	element.replaceChildren(out);
}

// after setting rendered HTML: its code blocks get their colours
export function hydrate(root) {
	for (const code of root.querySelectorAll("pre code")) {
		const name = [...code.classList].find(each => each.startsWith("language-"))?.slice(9);
		if (name) highlightInto(code, code.textContent, name);
		code.parentElement.classList.add("md-pre");
	}
}
