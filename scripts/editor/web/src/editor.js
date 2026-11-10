// One CodeMirror view: Markdown (live or source) or code.
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownKeymap, markdownLanguage } from "@codemirror/lang-markdown";
import { bracketMatching, foldGutter, foldKeymap, indentOnInput, indentUnit, LanguageDescription, syntaxHighlighting } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, Prec, Transaction } from "@codemirror/state";
import { crosshairCursor, drawSelection, dropCursor, EditorView, highlightActiveLine, highlightActiveLineGutter, keymap, lineNumbers, rectangularSelection, scrollPastEnd } from "@codemirror/view";
import { classHighlighter } from "@lezer/highlight";
import * as format from "./format.js";
import { livePreview } from "./live.js";
import { slashSource } from "./slash.js";

// a name without an ending is a note as well, unless it names code (Makefile, Dockerfile …)
const CODE_NAMES = /^(GNU)?makefile$|^(PKGBUILD|Jenkinsfile|Vagrantfile|Gemfile|Rakefile|Procfile|Justfile|Containerfile)$/i;
export const isMarkdown = path => {
	if (!path || /\.(md|markdown|mdown|mkd|txt)$/i.test(path)) return true;
	const name = path.replace(/^.*\//, "");
	return !name.includes(".") && !CODE_NAMES.test(name) && !LanguageDescription.matchFilename(languages, name);
};

const mdKeys = [
	{ key: "Mod-b", run: view => format.wrap(view, "**") },
	{ key: "Mod-i", run: view => format.wrap(view, "*") },
	{ key: "Mod-Shift-x", run: view => format.wrap(view, "~~") },
	{ key: "Mod-`", run: view => format.wrap(view, "`") },
	{ key: "Mod-k", run: format.link },
	{ key: "Mod-Shift-t", run: view => format.insertTable(view) },
	{ key: "Mod-Shift-c", run: view => format.insertCode(view) },
	{ key: "Mod-Shift-m", run: view => format.insertColumns(view) },
	{ key: "Mod-Shift-l", run: format.task },
	{ key: "Mod-Shift-u", run: format.bullet },
	{ key: "Mod-Shift-o", run: format.numbered },
	{ key: "Mod-Shift-q", run: format.quote },
	{ key: "Mod-Shift-h", run: view => format.insertRule(view) },
	{ key: "Mod-0", run: view => format.heading(view, 0) },
	...[1, 2, 3, 4, 5, 6].map(level => ({ key: `Mod-${level}`, run: view => format.heading(view, level) })),
	{ key: "Mod-Enter", run: format.toggleTask },
	{ key: "Tab", run: view => format.tableMove(view, "next") },
	{ key: "Shift-Tab", run: view => format.tableMove(view, "previous") },
	{ key: "Enter", run: view => (view.state.selection.main.empty ? format.tableMove(view, "down") : false) },
];

export function createView({ text, path, base, mode, app, parent, onUpdate, restore }) {
	const modeRoom = new Compartment();
	const languageRoom = new Compartment();
	const md = isMarkdown(path);
	const modeExtension = next => (md && next === "live" ? livePreview(base, app.bridge) : []);

	const extensions = [
		history(),
		drawSelection({ cursorBlinkRate: 1100 }),
		dropCursor(),
		rectangularSelection(),
		crosshairCursor(),
		EditorState.allowMultipleSelections.of(true),
		indentOnInput(),
		indentUnit.of(md ? "  " : "\t"),
		EditorState.tabSize.of(4),
		bracketMatching(),
		closeBrackets(),
		highlightSelectionMatches(),
		syntaxHighlighting(classHighlighter),
		search({ top: true }),
		scrollPastEnd(),
		languageRoom.of([]),
		modeRoom.of(modeExtension(mode)),
		EditorView.contentAttributes.of({ spellcheck: md ? "true" : "false", autocorrect: "off", autocapitalize: "off" }),
		EditorView.updateListener.of(update => onUpdate?.(update)),
		EditorView.domEventHandlers(app.domHandlers),
		Prec.high(keymap.of(md ? [...mdKeys, ...markdownKeymap] : [])),
		keymap.of([...closeBracketsKeymap, ...completionKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...defaultKeymap, indentWithTab]),
	];
	if (md) {
		extensions.push(
			EditorView.lineWrapping,
			autocompletion({
				override: [slashSource(app)], activateOnTyping: true, icons: false,
				tooltipClass: () => "slash-menu", optionClass: () => "slash-row",
				addToOptions: [{ render: option => app.slashIcon(option.icon), position: 20 }],
			}),
		);
	} else {
		extensions.push(lineNumbers(), foldGutter(), highlightActiveLine(), highlightActiveLineGutter());
	}
	const state = restore ?? EditorState.create({ doc: text, extensions });
	const view = new EditorView({ state, parent });
	view.peModeRoom = modeRoom;
	view.peSetMode = next => view.dispatch({ effects: modeRoom.reconfigure(modeExtension(next)) });
	view.dom.addEventListener("pe-measure", () => view.requestMeasure());
	view.dom.addEventListener("transitionend", () => view.requestMeasure());

	if (md) {
		view.dispatch({
			effects: languageRoom.reconfigure(markdown({ base: markdownLanguage, codeLanguages: languages, addKeymap: false })),
			annotations: Transaction.addToHistory.of(false),
		});
	} else if (path) {
		const found = LanguageDescription.matchFilename(languages, path);
		found?.load().then(support => view.dispatch({ effects: languageRoom.reconfigure(support) }));
	}
	return view;
}
