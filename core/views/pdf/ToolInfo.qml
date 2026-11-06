pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// About the file: its details (title, author …), a name for it from its
// content, the contents (bookmarks) to change, the files attached to it, and
// its earlier saves to go back to.
PaneFrame {
	id: root

	property Item dock: null
	property string suggested: ""
	property bool suggesting: false
	readonly property var meta: Pdf.recipe.meta ?? { title: Pdf.meta?.title ?? "", author: Pdf.meta?.author ?? "", subject: Pdf.meta?.subject ?? "", keywords: Pdf.meta?.keywords ?? "" }
	readonly property var attach: Pdf.recipe.attach ?? { add: [], remove: [] }
	readonly property var attachments: (Pdf.meta?.attachments ?? []).filter(a => !root.attach.remove.includes(a.name)).map(a => Object.assign({ kept: true }, a)).concat(root.attach.add.map(p => ({ name: p.slice(p.lastIndexOf("/") + 1), path: p, kept: false })))
	// the outline as rows: { title, page, y, depth }
	readonly property var rows: root.flatten(Pdf.outlineNow, 0)
	property int editing: -1

	title: "Info"
	subtitle: Pdf.meta ? `${Pdf.pageCount} pages · ${Pdf.formatBytes(Pdf.meta.bytes)}` : ""
	onClose: Pdf.tool = ""

	Component.onCompleted: {
		Pdf.readOutline();
		Pdf.loadVersions();
	}

	function flatten(list, depth) {
		let out = [];
		for (const e of list || []) {
			out.push({ title: e.title, page: e.page, y: e.y ?? 0, depth: depth });
			out = out.concat(root.flatten(e.children, depth + 1));
		}
		return out;
	}

	function tree(rows) {
		const top = [];
		const stack = [];
		for (const r of rows) {
			const node = { title: r.title, page: r.page, y: r.y ?? 0, children: [] };
			const depth = Math.min(r.depth, stack.length);
			stack.length = depth;
			if (depth === 0) top.push(node);
			else stack[depth - 1].children.push(node);
			stack.push(node);
		}
		return top;
	}

	function change(rows, label) {
		Pdf.setOutline(root.tree(rows), label);
	}

	function setMeta(key, value) {
		if ((root.meta[key] ?? "") === value) return;
		Pdf.setMeta(Object.assign({}, root.meta, { [key]: value }));
	}

	// ── details ────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Details"
	}

	Repeater {
		model: [{ key: "title", label: "Title" }, { key: "author", label: "Author" }, { key: "subject", label: "Subject" }, { key: "keywords", label: "Keywords" }]

		delegate: Field {
			required property var modelData

			width: parent.width
			height: 36
			placeholder: modelData.label
			text: root.meta[modelData.key] ?? ""
			onAccepted: root.setMeta(modelData.key, text)
			onFocusedChanged: if (!focused) root.setMeta(modelData.key, text)
		}
	}

	Grid {
		width: parent.width
		columns: 2
		columnSpacing: 12
		rowSpacing: 4

		Repeater {
			model: [
				["Pages", String(Pdf.pageCount)], ["Size", Pdf.formatBytes(Pdf.meta?.bytes ?? 0)], ["PDF", String(Pdf.meta?.version ?? "")],
				["Made", String(Pdf.meta?.created ?? "").slice(0, 16).replace("T", " ")], ["Changed", String(Pdf.meta?.modified ?? "").slice(0, 16).replace("T", " ")],
				["Made with", [Pdf.meta?.creator, Pdf.meta?.producer].filter(v => v).join(" · ")], ["Form fields", String(Pdf.meta?.forms ?? 0)],
				["Marks", String(Pdf.items.length)], ["Signed", String(Pdf.meta?.signatures ?? 0)], ["Scanned", Pdf.meta?.scanned ? "yes, no text" : "no"],
				["Tagged", Pdf.meta?.tagged ? "yes" : "no"], ["Locked", Pdf.meta?.encrypted ? "yes" : "no"]
			].filter(r => r[1] !== "" && r[1] !== "0")

			delegate: StyledText {
				required property var modelData
				required property int index

				width: (root.bodyWidth - 12) / 2
				text: `${modelData[0]}: ${modelData[1]}`
				elide: Text.ElideRight
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}
		}
	}

	// ── a name ─────────────────────────────────────────────────────────────
	Row {
		width: parent.width
		spacing: 6
		visible: typeof Pdf.suggestName === "function"

		TextButton {
			text: root.suggesting ? "Reading…" : "Suggest a name"
			icon: "creation"
			busy: root.suggesting
			onActivated: {
				root.suggesting = true;
				Pdf.suggestName(name => {
					root.suggesting = false;
					root.suggested = name || "";
				});
			}
		}
	}

	Row {
		width: parent.width
		spacing: 6
		visible: root.suggested !== ""

		Field {
			id: newName

			width: parent.width - renameButton.width - 6
			height: 36
			text: root.suggested
		}

		TextButton {
			id: renameButton

			text: "Rename"
			icon: "rename_box"
			variant: "filled"
			onActivated: {
				Pdf.renameTo(newName.text.trim());
				root.suggested = "";
			}
		}
	}

	// ── contents ───────────────────────────────────────────────────────────
	SectionLabel {
		text: `Contents · ${root.rows.length}`
	}

	Row {
		width: parent.width
		spacing: 6

		Field {
			id: newEntry

			width: parent.width - addEntry.width - 6
			height: 36
			placeholder: `A bookmark for page ${Pdf.page + 1}`
			onAccepted: addEntry.activated()
		}

		TextButton {
			id: addEntry

			text: "Add"
			icon: "bookmark_plus_outline"
			onActivated: {
				const title = newEntry.text.trim() || `Page ${Pdf.page + 1}`;
				const page = Pdf.pages[Pdf.page]?.id ?? "";
				const rows = root.rows.slice();
				// in page order
				let at = rows.findIndex(r => Pdf.indexOf(r.page) > Pdf.page);
				if (at < 0) at = rows.length;
				rows.splice(at, 0, { title: title, page: page, y: 0, depth: at > 0 ? rows[at - 1].depth : 0 });
				root.change(rows, "Bookmark added");
				newEntry.text = "";
			}
		}
	}

	Repeater {
		model: root.rows

		delegate: Clickable {
			id: entry

			required property var modelData
			required property int index

			width: parent.width
			height: 36
			radius: Theme.radius.small
			color: entry.hovered ? Theme.layer2 : "transparent"
			onClicked: Pdf.goTo(Pdf.indexOf(entry.modelData.page), entry.modelData.y)

			StyledText {
				x: 10 + entry.modelData.depth * 16
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width - x - (entry.hovered ? 150 : 40)
				visible: root.editing !== entry.index
				text: entry.modelData.title
				elide: Text.ElideRight
				font.weight: entry.modelData.depth === 0 ? Font.DemiBold : Font.Normal
			}

			Field {
				x: 6 + entry.modelData.depth * 16
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width - x - 8
				height: 32
				visible: root.editing === entry.index
				text: entry.modelData.title
				onVisibleChanged: if (visible) focusInput()
				onAccepted: {
					const rows = root.rows.slice();
					rows[entry.index] = Object.assign({}, rows[entry.index], { title: text.trim() || rows[entry.index].title });
					root.editing = -1;
					root.change(rows, "Bookmark renamed");
				}
				onEscapePressed: root.editing = -1
			}

			StyledText {
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				visible: !entry.hovered && root.editing !== entry.index
				text: String(Pdf.indexOf(entry.modelData.page) + 1)
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			Row {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				visible: entry.hovered && root.editing !== entry.index

				Repeater {
					model: [
						{ icon: "pencil_outline", run: () => root.editing = entry.index },
						{ icon: "format_indent_decrease", run: () => {
							const rows = root.rows.slice();
							rows[entry.index] = Object.assign({}, rows[entry.index], { depth: Math.max(0, entry.modelData.depth - 1) });
							root.change(rows, "Bookmark moved out");
						} },
						{ icon: "format_indent_increase", run: () => {
							const rows = root.rows.slice();
							const most = entry.index > 0 ? rows[entry.index - 1].depth + 1 : 0;
							rows[entry.index] = Object.assign({}, rows[entry.index], { depth: Math.min(most, entry.modelData.depth + 1) });
							root.change(rows, "Bookmark moved in");
						} },
						{ icon: "arrow_up", run: () => {
							if (entry.index === 0) return;
							const rows = root.rows.slice();
							[rows[entry.index - 1], rows[entry.index]] = [rows[entry.index], rows[entry.index - 1]];
							root.change(rows, "Bookmark moved");
						} },
						{ icon: "delete_outline", run: () => root.change(root.rows.filter((r, i) => i !== entry.index), "Bookmark removed") }
					]

					delegate: IconButton {
						required property var modelData

						implicitWidth: 28
						implicitHeight: 28
						iconSize: 15
						icon: modelData.icon
						onClicked: modelData.run()
					}
				}
			}
		}
	}

	TextButton {
		visible: Pdf.recipe.outline !== null && Pdf.recipe.outline !== undefined
		text: "The file's own contents again"
		icon: "restore"
		variant: "ghost"
		onActivated: Pdf.setOutline(null, "Contents as they were")
	}

	// ── attached ───────────────────────────────────────────────────────────
	SectionLabel {
		text: `Attached · ${root.attachments.length}`
	}

	Repeater {
		model: root.attachments

		delegate: Item {
			id: file

			required property var modelData

			width: parent.width
			height: 38

			Glyph {
				id: fileIcon

				x: 6
				anchors.verticalCenter: parent.verticalCenter
				icon: file.modelData.kept ? "paperclip" : "paperclip_plus"
				size: 16
			}

			StyledText {
				anchors.left: fileIcon.right
				anchors.leftMargin: 8
				anchors.right: fileKeys.left
				anchors.verticalCenter: parent.verticalCenter
				text: `${file.modelData.name}${file.modelData.bytes ? " · " + Pdf.formatBytes(file.modelData.bytes) : ""}${file.modelData.kept ? "" : " · when saved"}`
				elide: Text.ElideMiddle
			}

			Row {
				id: fileKeys

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter

				IconButton {
					visible: file.modelData.kept
					implicitWidth: 30
					implicitHeight: 30
					iconSize: 16
					icon: "tray_arrow_down"
					onClicked: Pdf.request("detach", { path: Pdf.path, name: file.modelData.name, out: `${Pdf.folderOf(Pdf.path)}/${file.modelData.name}`, password: Pdf.password }, data => {
						if (data?.path) Pdf.tellMade(data.path, "Taken out of the PDF");
					})
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					iconSize: 16
					icon: "close"
					onClicked: {
						if (file.modelData.kept) Pdf.setAttachments({ add: root.attach.add, remove: root.attach.remove.concat([file.modelData.name]) }, "Attachment removed");
						else Pdf.setAttachments({ add: root.attach.add.filter(p => p !== file.modelData.path), remove: root.attach.remove }, "Attachment left out");
					}
				}
			}
		}
	}

	TextButton {
		text: "Attach files…"
		icon: "paperclip_plus"
		onActivated: Files.pick({ title: "Attach to the PDF", multiple: true }, paths => {
			if (paths?.length) Pdf.setAttachments({ add: root.attach.add.concat(paths), remove: root.attach.remove }, paths.length === 1 ? "File attached" : `${paths.length} files attached`);
		})
	}

	// ── earlier saves ──────────────────────────────────────────────────────
	SectionLabel {
		visible: Pdf.versionList.length > 0
		text: "Earlier saves"
	}

	Repeater {
		model: Pdf.versionList

		delegate: Clickable {
			id: version

			required property var modelData

			width: parent.width
			height: 38
			radius: Theme.radius.small
			color: version.hovered ? Theme.layer2 : "transparent"
			onClicked: Pdf.open(version.modelData.path)

			Glyph {
				id: clock

				x: 8
				anchors.verticalCenter: parent.verticalCenter
				icon: "history"
				size: 16
			}

			StyledText {
				anchors.left: clock.right
				anchors.leftMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				text: `${String(version.modelData.stamp).replace("T", " ").slice(0, 16)} · ${Pdf.formatBytes(version.modelData.bytes)}`
			}

			IconButton {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				implicitWidth: 30
				implicitHeight: 30
				iconSize: 15
				icon: "folder_open_outline"
				onClicked: Files.reveal(version.modelData.path)
			}
		}
	}
}
