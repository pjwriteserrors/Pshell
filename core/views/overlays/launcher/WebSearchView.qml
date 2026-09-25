pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >w: Enter searches the query in a new Floorp tab with its default
// engine; Ctrl+Enter lists DuckDuckGo results here (Brave when DuckDuckGo
// answers with its bot challenge), Enter opens the selected one.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	readonly property string query: String(root.argument || "").trim()
	property var results: []
	property string resultsQuery: ""
	property bool loading: false
	property string error: ""
	readonly property bool showingResults: root.resultsQuery !== "" && root.resultsQuery === root.query
	readonly property string userAgent: "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

	signal closeRequested

	spacing: 10

	function move(delta) {
		if (!root.showingResults || root.results.length === 0) return;
		resultList.currentIndex = Math.max(0, Math.min(root.results.length - 1, resultList.currentIndex + delta));
		resultList.positionViewAtIndex(resultList.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		if (root.query === "") return;
		if (modifiers & Qt.ControlModifier) {
			root.fetch();
			return;
		}
		if (root.showingResults && resultList.currentIndex >= 0 && resultList.currentIndex < root.results.length) {
			root.openUrl(root.results[resultList.currentIndex].url);
			return;
		}
		root.closeRequested();
		Quickshell.execDetached(["floorp", "--search", root.query]);
	}

	function openUrl(url) {
		if (!url) return;
		root.closeRequested();
		Quickshell.execDetached(["floorp", "--new-tab", String(url)]);
	}

	function fetch() {
		if (root.query === "" || search.running) return;
		root.loading = true;
		root.error = "";
		search.target = root.query;
		search.run("duckduckgo");
	}

	function decodeEntities(text) {
		const named = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", hellip: "…", mdash: "—", ndash: "–", laquo: "«", raquo: "»" };
		return String(text || "").replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity) => {
			if (entity[0] === "#") {
				const code = entity[1] === "x" || entity[1] === "X" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
				return Number.isFinite(code) ? String.fromCodePoint(code) : match;
			}
			return named[entity.toLowerCase()] ?? match;
		});
	}

	function plain(html) {
		return root.decodeEntities(String(html || "").replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
	}

	function domainOf(url) {
		const match = /^[a-z]+:\/\/([^/?#]+)/i.exec(String(url || ""));
		return match ? match[1].replace(/^www\./, "") : "";
	}

	function parse(html) {
		const results = [];
		const anchor = /<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g;
		const anchors = [];
		let match = null;
		while ((match = anchor.exec(html)) !== null)
			anchors.push({ index: match.index, end: anchor.lastIndex, href: match[1], title: match[2] });
		for (let i = 0; i < anchors.length; i += 1) {
			const block = html.slice(anchors[i].end, i + 1 < anchors.length ? anchors[i + 1].index : html.length);
			const href = root.decodeEntities(anchors[i].href);
			const target = /[?&]uddg=([^&]+)/.exec(href);
			let url = target ? decodeURIComponent(target[1]) : (href.startsWith("//") ? `https:${href}` : href);
			if (url === "" || /duckduckgo\.com\/y\.js/.test(url)) continue;
			const snippet = /class="result__snippet"[^>]*>([\s\S]*?)<\/a>/.exec(block);
			results.push({
				url,
				title: root.plain(anchors[i].title),
				snippet: snippet ? root.plain(snippet[1]) : "",
				domain: root.domainOf(url)
			});
		}
		return results;
	}

	function parseBrave(html) {
		const results = [];
		const blocks = String(html).split(/data-type="web"/).slice(1);
		for (const block of blocks) {
			const link = /<a href="(https?:\/\/[^"]+)"/.exec(block);
			if (!link) continue;
			const url = root.decodeEntities(link[1]);
			const title = /class="title search-snippet-title[^"]*"[^>]*>([\s\S]*?)<\/div>/.exec(block);
			const snippet = /class="content [^"]*"[^>]*>([\s\S]*?)<\/div>/.exec(block);
			results.push({
				url,
				title: title ? root.plain(title[1]) : root.domainOf(url),
				snippet: snippet ? root.plain(snippet[1].replace(/^\s*(<!--[\s\S]*?-->)*\s*<span class="t-secondary">[\s\S]*?<\/span>/, "")) : "",
				domain: root.domainOf(url)
			});
		}
		return results;
	}

	Process {
		id: search

		property string target: ""
		property string engine: ""
		property int exitCode: -1
		property bool streamDone: false

		function run(engine) {
			search.engine = engine;
			search.exitCode = -1;
			search.streamDone = false;
			const q = encodeURIComponent(search.target);
			const url = engine === "brave" ? `https://search.brave.com/search?q=${q}&source=web` : `https://html.duckduckgo.com/html/?q=${q}`;
			search.exec(["curl", "-sS", "-m", "10", "-A", root.userAgent, url]);
		}

		function finish() {
			if (!search.streamDone || search.exitCode < 0) return;
			const exitCode = search.exitCode;
			search.exitCode = -1;
			search.streamDone = false;
			const html = searchOut.text;
			if (search.engine === "duckduckgo" && search.target === root.query && (exitCode !== 0 || /anomaly/.test(html))) {
				Qt.callLater(() => search.run("brave"));
				return;
			}
			root.loading = false;
			if (search.target !== root.query) return;
			const results = exitCode === 0 ? (search.engine === "brave" ? root.parseBrave(html) : root.parse(html)) : [];
			root.results = results;
			root.resultsQuery = search.target;
			root.error = exitCode !== 0 ? "Search failed" : (results.length === 0 ? "No results" : "");
			resultList.currentIndex = results.length > 0 ? 0 : -1;
		}

		stdout: StdioCollector {
			id: searchOut

			onStreamFinished: {
				search.streamDone = true;
				search.finish();
			}
		}
		onExited: exitCode => {
			search.exitCode = exitCode;
			search.finish();
		}
	}

	// the plain search row
	Clickable {
		Layout.fillWidth: true
		visible: root.query !== "" && !root.showingResults
		implicitHeight: 60
		radius: Theme.radius.large
		color: Theme.primaryContainer
		pressedScale: 0.98
		onClicked: root.activate(0)

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 10
			anchors.rightMargin: 16
			spacing: 14

			Rectangle {
				Layout.preferredWidth: 42
				Layout.preferredHeight: 42
				radius: Theme.radius.medium
				color: Theme.primary

				Glyph {
					anchors.centerIn: parent
					icon: "search_web"
					size: 20
					color: Theme.onPrimary
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: root.query
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			Spinner {
				Layout.preferredWidth: 16
				Layout.preferredHeight: 16
				visible: root.loading
			}

			TextButton {
				visible: !root.loading
				implicitHeight: 30
				text: "Results"
				icon: "format_list_bulleted"
				onActivated: root.fetch()
			}
		}
	}

	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true

		ListView {
			id: resultList

			anchors.fill: parent
			visible: root.showingResults
			clip: true
			spacing: 2
			model: root.showingResults ? root.results : []
			currentIndex: -1
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: Clickable {
				id: resultRow

				required property var modelData
				required property int index
				readonly property bool picked: resultList.currentIndex === resultRow.index

				width: resultList.width
				implicitHeight: resultColumn.implicitHeight + 18
				radius: Theme.radius.large
				pressedScale: 0.98
				showHover: false
				color: resultRow.picked ? Theme.primaryContainer : (resultRow.hovered ? Theme.layer1 : "transparent")
				onEntered: resultList.currentIndex = resultRow.index
				onClicked: root.openUrl(resultRow.modelData.url)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 14
					spacing: 12

					ClippingRectangle {
						Layout.alignment: Qt.AlignTop
						Layout.topMargin: 9
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						radius: Theme.radius.small
						color: Theme.layer2

						Glyph {
							anchors.centerIn: parent
							visible: favicon.status !== Image.Ready
							icon: "web"
							size: 16
							color: Theme.textMuted
						}

						Image {
							id: favicon

							anchors.centerIn: parent
							width: 18
							height: 18
							source: resultRow.modelData.domain !== "" ? `https://icons.duckduckgo.com/ip3/${resultRow.modelData.domain}.ico` : ""
							sourceSize: Qt.size(36, 36)
							asynchronous: true
							cache: true
						}
					}

					ColumnLayout {
						id: resultColumn

						Layout.fillWidth: true
						spacing: 2

						StyledText {
							Layout.fillWidth: true
							text: resultRow.modelData.title
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: resultRow.modelData.domain
							tone: Theme.primary
							font.pixelSize: Theme.size.small
						}

						StyledText {
							Layout.fillWidth: true
							visible: text !== ""
							text: resultRow.modelData.snippet
							tone: Theme.textMuted
							wrapMode: Text.Wrap
							maximumLineCount: 2
							font.pixelSize: Theme.size.small
						}
					}
				}
			}
		}

		Spinner {
			anchors.centerIn: parent
			width: 26
			height: 26
			visible: root.loading && root.showingResults
		}

		EmptyState {
			anchors.centerIn: parent
			visible: root.query === "" || (root.showingResults && root.error !== "")
			icon: root.error !== "" && root.query !== "" ? "alert_circle" : "web"
			title: root.query !== "" ? root.error : ""
		}
	}
}
