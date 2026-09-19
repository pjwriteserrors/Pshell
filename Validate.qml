import QtQuick
import Quickshell
import Quickshell.Io

// The check every style has to pass before it is merged:
//
//   1. the shell and everything it pulls in compiles,
//   2. Studio still has all of its pages, and the scripts behind them are
//      still there.
//
// (2) exists because a style is a rewrite of the whole shell, and it is very
// easy to rewrite a page out of existence. Studio is how the desktop is
// changed at all — wallpaper, colours, motion, icons, pointer, style branch
// and saved combinations — so a style that ships without one of those pages
// leaves whatever it controls unreachable until someone notices. See
// STUDIO.md.
//
// Run: quickshell -p ./Validate.qml
Scope {
	id: harness

	readonly property var requiredPages: [
		"wallpaper",
		"motion",
		"dress",
		"styles",
		"combinations"
	]

	// The page components Studio loads, and the scripts they cannot work
	// without. A style may rewrite any of these files; it may not drop one.
	readonly property var requiredFiles: [
		"Studio.qml",
		"ThemePickerPopup.qml",
		"AnimationPickerPopup.qml",
		"DressPicker.qml",
		"BranchStylePicker.qml",
		"CombinationPicker.qml",
		"components/AnimationStage.qml",
		"scripts/apply_theme_selection.sh",
		"scripts/apply_niri_animation.sh",
		"scripts/appearance_themes.py",
		"scripts/combinations.py",
		"scripts/branch_styles.py",
		"scripts/build_animation_preview.py"
	]

	property int failures: 0

	function fail(message) {
		harness.failures += 1;
		console.error(`STYLE: ${message}`);
	}

	function checkStudio() {
		const studio = Qt.createComponent("Studio.qml", Component.PreferSynchronous);
		if (studio.status === Component.Error) {
			harness.fail(`Studio.qml does not compile: ${studio.errorString()}`);
			return;
		}

		const instance = studio.createObject(null, {
			foreground: "#ffffff",
			background: "#000000",
			secondaryBoxColor: "#111111",
			secondaryBoxStrongColor: "#222222",
			secondaryInsetColor: "#0a0a0a",
			barColor: "#ff0000",
			danger: "#ff0000"
		});

		if (!instance) {
			harness.fail("Studio.qml could not be instantiated");
			return;
		}

		const pages = (instance.pages || []).map(page => String(page.id || ""));
		for (const required of harness.requiredPages) {
			if (pages.indexOf(required) < 0)
				harness.fail(`Studio is missing its "${required}" page — see STUDIO.md`);
		}

		instance.destroy();
	}

	Process {
		id: fileCheck

		command: ["sh", "-c", `cd "${Quickshell.shellDir}" && for f in ${harness.requiredFiles.join(" ")}; do [ -e "$f" ] || echo "$f"; done`]

		stdout: StdioCollector {
			onStreamFinished: {
				const missing = String(text || "").trim();
				if (missing !== "") {
					for (const file of missing.split("\n"))
						harness.fail(`missing file this style still needs: ${file} — see STUDIO.md`);
				}

				if (harness.failures === 0)
					console.log("STYLE: complete shell and dependencies compiled successfully");
				else
					console.error(`STYLE: ${harness.failures} problem(s) found`);

				Qt.quit();
			}
		}
	}

	Timer {
		running: true
		interval: 20

		onTriggered: {
			const component = Qt.createComponent("shell.qml", Component.PreferSynchronous);
			if (component.status === Component.Error) {
				console.error(component.errorString());
				Qt.quit();
				return;
			}
			if (component.status !== Component.Ready) {
				console.error("Shell did not compile synchronously");
				Qt.quit();
				return;
			}

			harness.checkStudio();
			fileCheck.running = true;
		}
	}
}
