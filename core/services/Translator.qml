pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Text translation for the launcher (>t). Google's dict-chrome-ex endpoint
// first, MyMemory as fallback. "auto" translates German to English and
// everything else to German: the text is translated to German first and,
// when the detected source already is German, again to English.
// Requests are debounced; stale answers are dropped by sequence number.
Singleton {
	id: root

	readonly property var languages: [
		{ code: "auto", label: "Auto", name: "Auto" },
		{ code: "de", label: "DE", name: "German" },
		{ code: "en", label: "EN", name: "English" },
		{ code: "fr", label: "FR", name: "French" },
		{ code: "es", label: "ES", name: "Spanish" },
		{ code: "it", label: "IT", name: "Italian" },
		{ code: "pt", label: "PT", name: "Portuguese" },
		{ code: "nl", label: "NL", name: "Dutch" },
		{ code: "pl", label: "PL", name: "Polish" },
		{ code: "tr", label: "TR", name: "Turkish" },
		{ code: "ru", label: "RU", name: "Russian" },
		{ code: "ja", label: "JA", name: "Japanese" },
		{ code: "zh", label: "ZH", name: "Chinese" }
	]
	readonly property var extraNames: ({
		ar: "Arabic", cs: "Czech", da: "Danish", el: "Greek", fi: "Finnish", hu: "Hungarian",
		ko: "Korean", no: "Norwegian", ro: "Romanian", sv: "Swedish", uk: "Ukrainian", hr: "Croatian",
		sk: "Slovak", sl: "Slovenian", bg: "Bulgarian", id: "Indonesian", hi: "Hindi", vi: "Vietnamese",
		th: "Thai", he: "Hebrew", iw: "Hebrew", la: "Latin", ca: "Catalan", et: "Estonian", lt: "Lithuanian", lv: "Latvian"
	})

	// chip selection in the launcher; "auto" applies the DE ↔ EN rule
	property string target: "auto"

	// state of the last finished request
	property string input: ""
	property string result: ""
	property string source: ""
	property string resultTarget: ""
	property bool loading: false
	property string error: ""
	// true while a newer request than the shown result is pending
	readonly property bool pending: debounce.running || root.loading

	property string _text: ""
	property string _target: "auto"
	property int _seq: 0
	property string _lastKey: ""

	signal finished

	function languageName(code) {
		const value = String(code || "").toLowerCase().split(/[-_]/)[0];
		const known = root.languages.find(language => language.code === value);
		if (known && value !== "auto") return known.name;
		return root.extraNames[value] || value.toUpperCase();
	}

	function isLanguageCode(code) {
		const value = String(code || "").toLowerCase();
		return value !== "auto" && (root.languages.some(language => language.code === value) || root.extraNames[value] !== undefined);
	}

	// debounced: the last call within 350 ms wins
	function request(text, target) {
		root._text = String(text || "").trim();
		root._target = String(target || "auto");
		if (root._text === "") {
			root._seq += 1;
			debounce.stop();
			root.clear();
			return;
		}
		const key = `${root._target}\n${root._text}`;
		if (key === root._lastKey) return;
		root._lastKey = key;
		debounce.restart();
	}

	function clear() {
		root._lastKey = "";
		root.input = "";
		root.result = "";
		root.source = "";
		root.resultTarget = "";
		root.loading = false;
		root.error = "";
	}

	function start() {
		root._seq += 1;
		const explicit = root._target !== "auto" && root._target !== "";
		root.loading = true;
		root.error = "";
		root.fetch({
			seq: root._seq,
			text: root._text,
			target: explicit ? root._target : "de",
			auto: !explicit,
			provider: "google"
		});
	}

	function fetch(job) {
		const q = encodeURIComponent(job.text);
		const url = job.provider === "google"
			? `https://translate.googleapis.com/translate_a/single?client=dict-chrome-ex&sl=auto&tl=${job.target}&dt=t&q=${q}`
			: `https://api.mymemory.translated.net/get?q=${q}&langpair=Autodetect|${job.target}`;
		const proc = fetcher.createObject(root, { job });
		proc.command = ["curl", "-sS", "--fail", "-m", "8", url];
		proc.running = true;
	}

	function parse(job, raw) {
		const data = JSON.parse(String(raw || ""));
		if (job.provider === "google") {
			const segments = Array.isArray(data?.[0]) ? data[0] : [];
			const text = segments.map(segment => Array.isArray(segment) && typeof segment[0] === "string" ? segment[0] : "").join("");
			if (text === "") throw new Error("empty");
			return { text, source: String(data?.[2] || "") };
		}
		const text = String(data?.responseData?.translatedText || "");
		if (text === "" || Number(data?.responseStatus || 0) !== 200) throw new Error("empty");
		return { text, source: String(data?.responseData?.detectedLanguage || "") };
	}

	function handle(job, exitCode, raw) {
		if (job.seq !== root._seq) return;
		let parsed = null;
		if (exitCode === 0) {
			try {
				parsed = root.parse(job, raw);
			} catch (error) {
				parsed = null;
			}
		}
		if (!parsed) {
			if (job.provider === "google") {
				root.fetch(Object.assign({}, job, { provider: "mymemory" }));
				return;
			}
			root.loading = false;
			root.error = "Translation failed";
			root._lastKey = "";
			return;
		}
		const source = parsed.source.toLowerCase().split(/[-_]/)[0];
		// auto: German input goes to English instead
		if (job.auto && job.target === "de" && source === "de") {
			root.fetch(Object.assign({}, job, { target: "en" }));
			return;
		}
		root.input = job.text;
		root.result = parsed.text;
		root.source = source;
		root.resultTarget = job.target;
		root.loading = false;
		root.error = "";
		root.finished();
	}

	Timer {
		id: debounce

		interval: 350
		onTriggered: root.start()
	}

	Component {
		id: fetcher

		Process {
			id: proc

			property var job: ({})
			property int exitCode: -1
			property bool streamDone: false

			function finish() {
				if (!proc.streamDone || proc.exitCode < 0) return;
				root.handle(proc.job, proc.exitCode, out.text);
				proc.destroy();
			}

			stdout: StdioCollector {
				id: out

				onStreamFinished: {
					proc.streamDone = true;
					proc.finish();
				}
			}
			onExited: exitCode => {
				proc.exitCode = exitCode;
				proc.finish();
			}
		}
	}
}
