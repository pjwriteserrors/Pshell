// bun build.mjs [--watch]: src/ → dist/ (committed, so a machine needs no node)
import * as esbuild from "esbuild";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";

// the icons the page uses, by name, from the shell's own table
const wanted = readFileSync("src/icons.txt", "utf8").split(/\s+/).filter(Boolean);
const table = readFileSync("../../../style/theme/Icons.qml", "utf8");
const icons = {};
// Icons.qml keeps what the shell draws; these only the editor does (md- glyphs of the same font)
const extra = { format_strikethrough: 0xf0280, code_tags: 0xf0174, table: 0xf04eb, checkbox_marked_outline: 0xf0135, format_quote_close: 0xf027e, format_header_1: 0xf026b, format_header_2: 0xf026c, format_header_3: 0xf026d, minus_thick: 0xf1639, view_column: 0xf056d, book_open_outline: 0xf0b63, play_circle_outline: 0xf040d, split_horizontal: 0xf0bcb, table_row_plus_after: 0xf04f3, table_column_plus_after: 0xf04f0, window_minimize: 0xf05b0 };
for (const name of wanted) {
	const match = table.match(new RegExp(`"${name}":\\s*"([^"]+)"`));
	if (extra[name]) icons[name] = String.fromCodePoint(extra[name]);
	else if (!match) console.warn("icon not in Icons.qml:", name);
	else icons[name] = match[1];
}
mkdirSync("dist", { recursive: true });
writeFileSync("src/icons.gen.js", `export default ${JSON.stringify(icons)};\n`);
copyFileSync("src/index.html", "dist/index.html");

const options = {
	entryPoints: ["src/main.js"],
	bundle: true,
	format: "esm",
	splitting: true,
	outdir: "dist",
	minify: !process.argv.includes("--watch"),
	target: "safari17",
	loader: { ".css": "css" },
	logLevel: "info",
};
if (process.argv.includes("--watch")) await (await esbuild.context(options)).watch();
else await esbuild.build(options);
