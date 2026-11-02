// The / menu: a command at the start of a word.
import * as format from "./format.js";

export function slashItems(app) {
	const block = (label, icon, detail, apply) => ({ label, icon, detail, section: "Markdown", run: apply });
	const shell = (label, icon, detail, apply) => ({ label, icon, detail, section: "Shell", run: apply });
	const line = fn => (view, from, to) => {
		view.dispatch({ changes: { from, to } });
		fn(view);
	};
	const text = producer => async (view, from, to) => {
		view.dispatch({ changes: { from, to } });
		await producer(view, from);
	};
	return [
		block("h1", "format_header_1", "Heading 1", line(view => format.heading(view, 1))),
		block("h2", "format_header_2", "Heading 2", line(view => format.heading(view, 2))),
		block("h3", "format_header_3", "Heading 3", line(view => format.heading(view, 3))),
		block("table", "table", "Table", (view, from, to) => format.insertTable(view, from, to)),
		block("code", "code_tags", "Code block", (view, from, to) => format.insertCode(view, from, to)),
		block("web", "code_braces", "HTML, CSS, JS", (view, from, to) => format.insertWeb(view, from, to)),
		block("columns", "view_column", "Columns", (view, from, to) => format.insertColumns(view, from, to)),
		block("task", "checkbox_marked_outline", "Task", line(format.task)),
		block("list", "format_list_bulleted", "List", line(format.bullet)),
		block("numbered", "format_list_numbered", "Numbered list", line(format.numbered)),
		block("quote", "format_quote_close", "Quote", line(format.quote)),
		block("note", "information_outline", "Callout", (view, from, to) => format.insertCallout(view, "note", from, to)),
		block("warning", "alert_outline", "Warning", (view, from, to) => format.insertCallout(view, "warning", from, to)),
		block("divider", "minus_thick", "Divider", (view, from, to) => format.insertRule(view, from, to)),
		block("link", "link_variant", "Link", line(format.link)),
		block("date", "calendar_today", "Today", text(view => app.insert(view, new Date().toISOString().slice(0, 10)))),
		block("time", "clock_outline", "Now", text(view => app.insert(view, new Date().toTimeString().slice(0, 5)))),
		shell("ai", "robot_outline", "Ask the AI", text(view => app.askAi(view))),
		shell("screenshot", "monitor_screenshot", "Screenshot", text(view => app.screenshot(view))),
		shell("clip", "clipboard_text_outline", "Clipboard history", text(view => app.pickClip(view))),
		shell("calc", "calculator", "Calculate", text(view => app.askCalc(view))),
		shell("translate", "translate", "Translate", text(view => app.askTranslate(view))),
		shell("todo", "format_list_checks", "Add to tasks", text(view => app.askTask(view))),
		shell("emoji", "emoticon_outline", "Emoji", text(view => app.pickEmoji(view))),
		shell("wiki", "note_outline", "Link a note", text(view => app.pickNote(view))),
	];
}

export function slashSource(app) {
	const items = slashItems(app);
	return context => {
		const word = context.matchBefore(/(^|\s)\/[\w-]*$/);
		if (!word) return null;
		const slash = word.text.indexOf("/");
		const from = word.from + slash;
		// not inside code
		const inside = context.state.sliceDoc(context.state.doc.lineAt(from).from, from);
		if (/^\s*(`{3}|~{3})/.test(inside)) return null;
		if (context.tokenBefore?.(["CodeText", "InlineCode"])) return null;
		return {
			from,
			validFor: /^\/[\w-]*$/,
			options: items.map(item => ({
				label: `/${item.label}`,
				displayLabel: item.detail,
				detail: `/${item.label}`,
				icon: item.icon,
				boost: item.section === "Markdown" ? 1 : 0,
				section: item.section,
				apply: (view, _completion, start, end) => item.run(view, start, end),
			})),
		};
	};
}
