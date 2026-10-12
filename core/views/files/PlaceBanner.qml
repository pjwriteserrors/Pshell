pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A line above the files that says what this place is about and what can
// be done with all of it: the copies that were found, a search that can be
// kept, two folders compared side by side.
Item {
	id: root

	required property var pane
	required property var shell

	readonly property string kind: root.pane.location.kind
	readonly property var dupeJob: Files.activeJobs.find(job => job.kind === "dupes") ?? null
	readonly property bool savedSearch: root.kind === "search" && FileLibrary.searches.some(entry => entry.query === root.pane.location.query && entry.path === (root.pane.location.path || Files.home) && !!entry.contents === !!root.pane.location.contents && !!entry.ai === !!root.pane.location.ai)
	readonly property string mode: {
		if (root.kind === "duplicates") return "dupes";
		if (root.pane.compareStates) return "compare";
		if (root.kind === "search" && root.pane.location.ai && String(root.pane.location.query || "").trim() !== "") return "ai";
		if (root.kind === "search" && String(root.pane.location.query || "").trim() !== "") return "search";
		return "";
	}
	readonly property var counts: {
		const states = root.pane.compareStates ?? {};
		const out = { only: 0, newer: 0, older: 0, differs: 0, same: 0 };
		for (const key of Object.keys(states)) out[states[key]] = (out[states[key]] ?? 0) + 1;
		return out;
	}

	implicitHeight: root.mode !== "" ? 44 : 0
	height: implicitHeight
	clip: true

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Rectangle {
		anchors.fill: parent
		anchors.leftMargin: 10
		anchors.rightMargin: 10
		anchors.topMargin: 4
		anchors.bottomMargin: 2
		radius: Theme.radius.large
		color: Qt.tint(Theme.layer1, Qt.alpha(root.mode === "compare" ? Theme.tertiary : Theme.primary, 0.1))
		opacity: root.mode !== "" ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 6
			spacing: 8

			Glyph {
				icon: root.mode === "dupes" ? "content_duplicate" : (root.mode === "compare" ? "file_compare" : (root.mode === "ai" ? "creation" : "magnify"))
				size: 17
				color: root.mode === "compare" ? Theme.tertiary : Theme.primary
			}

			StyledText {
				Layout.fillWidth: true
				elide: Text.ElideRight
				font.pixelSize: Theme.size.small
				text: {
					if (root.mode === "dupes") {
						if (root.dupeJob) return root.dupeJob.current ? `Looking for copies · ${root.dupeJob.current}` : "Looking for copies…";
						const summary = root.pane.dupeSummary;
						if (!summary) return root.pane.searching ? "Looking for copies…" : "No copies found";
						if (summary.groups === 0) return "No copies found – every file is there once";
						return `${summary.groups} group${summary.groups === 1 ? "" : "s"} of copies · ${Files.sizeText(summary.waste)} could go · the oldest of each stays first`;
					}
					if (root.mode === "compare") {
						const parts = [];
						if (root.counts.only) parts.push(`${root.counts.only} only here`);
						if (root.counts.newer) parts.push(`${root.counts.newer} newer here`);
						if (root.counts.older) parts.push(`${root.counts.older} older here`);
						if (root.counts.differs) parts.push(`${root.counts.differs} differ`);
						parts.push(`${root.counts.same} the same`);
						return `Compared with the other side: ${parts.join(" · ")}`;
					}
					if (root.mode === "ai") {
						if (root.pane.searching) return "Reading the question and looking through the index…";
						const found = root.pane.aiRead;
						if (!found) return Files.index.files ? `${Files.index.files} files in the index` : "Nothing is indexed yet – Settings → AI search";
						const parts = [];
						if ((found.words ?? []).length > 0) parts.push(`Looking for ${found.words.slice(0, 5).join(", ")}`);
						const read = found.read ?? {};
						if (read.kind) parts.push(read.kind === "picture" ? "pictures" : `${read.kind}s`);
						if (read.after || read.before) parts.push(`${read.after ? Qt.formatDate(new Date(read.after * 1000), "d MMM yyyy") : "…"} – ${read.before ? Qt.formatDate(new Date(read.before * 1000), "d MMM yyyy") : "now"}`);
						if (found.relaxed) parts.push("none in that time or kind, the closest anyway");
						return parts.join(" · ");
					}
					if (root.mode === "search") return root.savedSearch ? "This search is in the sidebar" : "Keep this search in the sidebar to run it again";
					return "";
				}
			}

			TextButton {
				visible: root.mode === "ai" && !Files.index.files
				height: 30
				text: "Set it up"
				icon: "cog_outline"
				variant: "tonal"
				onClicked: root.shell.openSettings("ai")
			}

			Spinner {
				visible: (root.mode === "dupes" && (!!root.dupeJob || root.pane.searching)) || (root.mode === "ai" && root.pane.searching)
				width: 14
				height: 14
			}

			TextButton {
				visible: root.mode === "dupes" && !root.dupeJob && (root.pane.dupeSummary?.groups ?? 0) > 0
				height: 30
				text: "Pick the extra copies"
				icon: "select_group"
				variant: "tonal"
				onClicked: root.pane.pickCopies()
			}

			TextButton {
				visible: root.mode === "dupes" && !root.dupeJob && root.pane.selectionCount > 0
				height: 30
				text: "Trash the picked"
				icon: "trash_can_outline"
				variant: "danger"
				onClicked: Files.trash(root.pane.selectedPaths())
			}

			IconButton {
				visible: root.mode === "dupes"
				width: 30
				height: 30
				iconSize: 16
				icon: root.dupeJob ? "close" : "refresh"
				onClicked: {
					if (root.dupeJob) {
						Files.cancel(root.dupeJob.id);
						return;
					}
					const path = String(root.pane.location.path);
					const next = Object.assign({}, Files.dupeResults);
					delete next[path];
					Files.dupeResults = next;
					root.pane.reload(true);
				}
			}

			TextButton {
				visible: (root.mode === "search" || root.mode === "ai") && !root.savedSearch
				height: 30
				text: "Keep this search"
				icon: "bookmark_plus_outline"
				variant: "tonal"
				onClicked: root.shell.ask("Keep this search", "Name in the sidebar", String(root.pane.location.query), name => {
					FileLibrary.addSearch(name, root.pane.location.query, root.pane.location.path || Files.home, !!root.pane.location.contents, !!root.pane.location.ai);
					Sounds.play("pinned");
				})
			}

			TextButton {
				visible: root.mode === "compare"
				height: 30
				text: "Sync…"
				icon: "folder_sync_outline"
				variant: "tonal"
				onClicked: root.shell.openSync(root.pane)
			}

			IconButton {
				visible: root.mode === "compare"
				width: 30
				height: 30
				iconSize: 16
				icon: "close"
				onClicked: root.shell.stopComparing()
			}
		}
	}
}
