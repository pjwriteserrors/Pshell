pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The file manager's settings (Ctrl+,): what is not in reach while
// browsing – how the window starts, how dates and sizes read, previews,
// archives, Windows programs, VirusTotal, PDFs and the caches. Pages on
// the left; a change applies at once.
DialogFrame {
	id: root

	required property var view
	property string page: "general"
	property var cache: null
	property string keyText: ""
	property string keyError: ""
	property bool keyBusy: false

	readonly property var pages: [
		{ id: "general", label: "General", icon: "tune_variant" },
		{ id: "browsing", label: "Browsing", icon: "folder_outline" },
		{ id: "previews", label: "Previews", icon: "image_outline" },
		{ id: "archives", label: "Archives", icon: "package_variant" },
		{ id: "windows", label: "Windows programs", icon: "microsoft_windows" },
		{ id: "virustotal", label: "VirusTotal", icon: "shield_search" },
		{ id: "pdf", label: "PDF", icon: "file_pdf_box" },
		{ id: "storage", label: "Storage", icon: "harddisk" }
	]

	function open(page) {
		root.page = page && root.pages.some(entry => entry.id === page) ? page : root.page;
		root.keyText = "";
		root.keyError = "";
		root.show();
		Files.knowRunners();
		Files.knowVtKey();
		Files.knowPdfTools();
		Files.request("thumbcache", {}, data => root.cache = data);
		keys.forceActiveFocus();
	}

	function saveKey(value) {
		root.keyBusy = true;
		root.keyError = "";
		Files.request("vtkey", { value: value }, (data, error) => {
			root.keyBusy = false;
			if (error) {
				root.keyError = error;
				Sounds.play("error");
				return;
			}
			Files.vtKeySet = !!data?.set;
			root.keyText = "";
			Sounds.play(Files.vtKeySet ? "taskDone" : "toggleOff");
		});
	}

	cardWidth: 820
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onUpPressed: {
			const at = root.pages.findIndex(entry => entry.id === root.page);
			root.page = root.pages[Math.max(0, at - 1)].id;
		}
		Keys.onDownPressed: {
			const at = root.pages.findIndex(entry => entry.id === root.page);
			root.page = root.pages[Math.min(root.pages.length - 1, at + 1)].id;
		}
	}

	RowLayout {
		width: parent.width
		height: Math.min(560, root.height - 120)
		spacing: 18

		// ── the pages ──────────────────────────────────────────────────────
		ColumnLayout {
			Layout.preferredWidth: 200
			Layout.maximumWidth: 200
			Layout.fillWidth: false
			Layout.fillHeight: true
			spacing: 2

			StyledText {
				Layout.bottomMargin: 10
				text: "Settings"
				font.pixelSize: Theme.size.title + 2
				font.weight: Font.Bold
			}

			Repeater {
				model: root.pages

				delegate: SideItem {
					required property var modelData

					Layout.preferredWidth: 200
					implicitWidth: 200
					icon: modelData.icon
					label: modelData.label
					active: root.page === modelData.id
					onClicked: root.page = modelData.id
				}
			}

			Item {
				Layout.fillHeight: true
			}

			TextButton {
				Layout.preferredWidth: 200
				height: 30
				variant: "ghost"
				text: "Reset all settings"
				icon: "restore"
				confirm: true
				onActivated: FileLibrary.resetSettings()
			}
		}

		Rectangle {
			Layout.fillHeight: true
			width: 1
			color: Theme.outline
		}

		// ── what is on the page ────────────────────────────────────────────
		Flickable {
			id: flick

			Layout.fillWidth: true
			Layout.preferredWidth: 560
			Layout.fillHeight: true
			contentHeight: content.implicitHeight + 8
			clip: true
			boundsBehavior: Flickable.StopAtBounds

			ScrollBar.vertical: ThinScrollBar {}

			ColumnLayout {
				id: content

				width: flick.width - 12
				spacing: 18

				// a new page fades in from a little below
				property string shownPage: root.page
				onShownPageChanged: pageIn.restart()

				ParallelAnimation {
					id: pageIn

					NumberAnimation {
						target: content
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
					NumberAnimation {
						target: content
						property: "y"
						from: 10
						to: 0
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.decel
					}
				}

				// ── general ────────────────────────────────────────────────
				Group {
					shown: root.page === "general"
					title: "When the window opens"

					Choice {
						options: [{ value: "restore", label: "The last tabs" }, { value: "home", label: "Home" }, { value: "folder", label: "A folder" }]
						value: FileLibrary.setting("startPage")
						onPicked: value => FileLibrary.set("startPage", value)
					}

					Field {
						Layout.fillWidth: true
						visible: FileLibrary.setting("startPage") === "folder"
						placeholder: "/home/you/Projects"
						text: FileLibrary.setting("startFolder")
						onEdited: text => FileLibrary.set("startFolder", text.trim())
					}
				}

				Group {
					shown: root.page === "general"
					title: "Behaviour"

					Switch {
						label: "Open with a single click"
						hint: "Instead of a double click. Ctrl and Shift still pick."
						checked: FileLibrary.setting("singleClick")
						onToggled: on => FileLibrary.set("singleClick", on)
					}

					Switch {
						label: "Ask before moving to the trash"
						hint: "Delete for good always asks."
						checked: FileLibrary.setting("confirmTrash")
						onToggled: on => FileLibrary.set("confirmTrash", on)
					}

					Switch {
						label: "Default file manager"
						hint: "Folders other apps open, and their “Show in folder”, come here."
						checked: Plugins.on("files-default")
						onToggled: on => Plugins.set("files-default", on)
					}
				}

				// ── browsing ───────────────────────────────────────────────
				Group {
					shown: root.page === "browsing"
					title: "Dates"

					Choice {
						options: [{ value: "relative", label: "12 min ago, Yesterday" }, { value: "absolute", label: "11.10.2026 14:03" }]
						value: FileLibrary.setting("dateStyle")
						onPicked: value => FileLibrary.set("dateStyle", value)
					}
				}

				Group {
					shown: root.page === "browsing"
					title: "Sizes"

					Choice {
						options: [{ value: "si", label: "1 KB = 1000 bytes" }, { value: "iec", label: "1 KiB = 1024 bytes" }]
						value: FileLibrary.setting("sizeUnits")
						onPicked: value => FileLibrary.set("sizeUnits", value)
					}
				}

				Group {
					shown: root.page === "browsing"
					title: "Everywhere"

					Switch {
						label: "Hidden files"
						hint: "Ctrl+H"
						checked: !!FileLibrary.view.hidden
						onToggled: on => FileLibrary.setView("", { hidden: on })
					}

					Switch {
						label: "Folders before files"
						checked: FileLibrary.view.foldersFirst !== false
						onToggled: on => FileLibrary.setView("", { foldersFirst: on })
					}

					Switch {
						label: "The sidebar"
						hint: "Ctrl+B"
						checked: FileLibrary.view.sidebar !== false
						onToggled: on => FileLibrary.setView("", { sidebar: on })
					}

					Line {
						label: FileLibrary.ownViews === 0 ? "No folder keeps a view of its own" : (FileLibrary.ownViews === 1 ? "1 folder keeps its own layout, order or groups" : `${FileLibrary.ownViews} folders keep their own layout, order or groups`)

						TextButton {
							visible: FileLibrary.ownViews > 0
							height: 30
							variant: "tonal"
							text: "Let them all go"
							confirm: true
							onActivated: FileLibrary.forgetFolderViews()
						}
					}
				}

				// ── previews ───────────────────────────────────────────────
				Group {
					shown: root.page === "previews"
					title: "On the cards"

					Switch {
						label: "First lines of texts and code"
						checked: FileLibrary.setting("textPreviews")
						onToggled: on => FileLibrary.set("textPreviews", on)
					}

					Switch {
						label: "Pictures peeking out of folders"
						checked: FileLibrary.setting("folderPeeks")
						onToggled: on => FileLibrary.set("folderPeeks", on)
					}

					Switch {
						label: "Thumbnails on network drives"
						hint: "Slow connections load every file once for it."
						checked: FileLibrary.setting("remoteThumbs")
						onToggled: on => FileLibrary.set("remoteThumbs", on)
					}
				}

				Group {
					shown: root.page === "previews"
					title: "Thumbnails for files up to"

					Choice {
						options: [{ value: 50, label: "50 MB" }, { value: 300, label: "300 MB" }, { value: 2000, label: "2 GB" }, { value: 0, label: "Any size" }]
						value: String(FileLibrary.setting("thumbLimit"))
						onPicked: value => FileLibrary.set("thumbLimit", Number(value))
					}
				}

				// ── archives ───────────────────────────────────────────────
				Group {
					shown: root.page === "archives"
					title: "A double click on an archive"

					Choice {
						options: [{ value: "extract", label: "Extracts it here" }, { value: "open", label: "Opens it in its app" }]
						value: FileLibrary.setting("archiveOpen")
						onPicked: value => FileLibrary.set("archiveOpen", value)
					}

					Switch {
						label: "Move the archive to the trash once it is out"
						checked: FileLibrary.setting("trashArchive")
						onToggled: on => FileLibrary.set("trashArchive", on)
					}

					Hint {
						text: "An archive of one folder becomes that folder; one of many files gets a folder named after it. Extracting can be paused and stopped from the job's card."
					}
				}

				// ── Windows programs ───────────────────────────────────────
				Group {
					shown: root.page === "windows"
					title: "Run .exe and .msi with"

					Choice {
						options: [{ value: "auto", label: "The best there is" }, { value: "proton", label: "Proton" }, { value: "wine", label: "Wine" }]
						value: FileLibrary.setting("windowsRunner")
						onPicked: value => FileLibrary.set("windowsRunner", value)
					}

					Hint {
						text: Files.runners.length === 0 ? "Neither Proton nor Wine is installed." : "The best there is: the newest GE-Proton, then Proton Experimental, then Wine. Proton keeps its Windows in ~/.local/share/pshell/proton."
					}
				}

				Group {
					shown: root.page === "windows" && Files.runners.some(runner => runner.kind === "proton")
					title: "Proton version (also for Steam)"

					Flow {
						Layout.fillWidth: true
						spacing: 6

						Chip {
							height: 30
							text: "Newest"
							selected: FileLibrary.setting("protonVersion") === ""
							onClicked: FileLibrary.set("protonVersion", "")
						}

						Repeater {
							model: Files.runners.filter(runner => runner.kind === "proton")

							delegate: Chip {
								required property var modelData

								height: 30
								text: modelData.name
								selected: FileLibrary.setting("protonVersion") === modelData.id
								onClicked: FileLibrary.set("protonVersion", modelData.id)
							}
						}
					}
				}

				Group {
					shown: root.page === "windows"
					title: "Steam"

					Hint {
						text: Files.steam ? "“Add to Steam…” in a program's menu puts it in the library as a non-Steam game, set to run with Proton. Steam is restarted for it when it runs." : "Steam is not installed."
					}
				}

				// ── VirusTotal ─────────────────────────────────────────────
				Group {
					shown: root.page === "virustotal"
					title: "API key"

					Line {
						label: Files.vtKeySet ? "A key is kept in the keyring" : "No key yet"
						icon: Files.vtKeySet ? "check_decagram_outline" : "key_outline"
						tint: Files.vtKeySet ? Theme.success : Theme.textMuted

						TextButton {
							visible: Files.vtKeySet
							height: 30
							variant: "ghost"
							text: "Remove"
							confirm: true
							onActivated: root.saveKey("")
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						Field {
							id: keyField

							Layout.fillWidth: true
							password: true
							placeholder: Files.vtKeySet ? "Paste a new key to replace it" : "Paste your API key"
							text: root.keyText
							onEdited: text => root.keyText = text
							onAccepted: if (root.keyText.trim() !== "") root.saveKey(root.keyText)
						}

						TextButton {
							height: 36
							variant: "filled"
							text: "Save"
							busy: root.keyBusy
							enabled: root.keyText.trim() !== "" && !root.keyBusy
							onClicked: root.saveKey(root.keyText)
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: root.keyError !== ""
						text: root.keyError
						tone: Theme.danger
						font.pixelSize: Theme.size.small
						wrapMode: Text.WordWrap
					}

					Line {
						label: "A free key comes with a VirusTotal account."

						TextButton {
							height: 30
							variant: "ghost"
							text: "Get one"
							icon: "open_in_new"
							onClicked: Qt.openUrlExternally("https://www.virustotal.com/gui/my-apikey")
						}
					}
				}

				Group {
					shown: root.page === "virustotal"
					title: "Files VirusTotal has never seen"

					Choice {
						options: [{ value: "ask", label: "Offer to upload" }, { value: "always", label: "Upload them" }, { value: "never", label: "Never upload" }]
						value: FileLibrary.setting("vtUpload")
						onPicked: value => FileLibrary.set("vtUpload", value)
					}

					Hint {
						text: "A check sends only the file's fingerprint (SHA-256). An upload sends the file itself, and VirusTotal shares it with its partners – never upload anything private."
					}
				}

				Group {
					shown: root.page === "virustotal"
					title: "Downloads"

					Switch {
						label: "Check every finished download"
						hint: "By its fingerprint only; a word comes only when scanners flag it."
						enabled: Files.vtKeySet
						checked: FileLibrary.setting("vtDownloads")
						onToggled: on => FileLibrary.set("vtDownloads", on)
					}
				}

				// ── PDF ────────────────────────────────────────────────────
				Group {
					shown: root.page === "pdf"
					title: "Compress PDFs"

					Choice {
						options: [{ value: "screen", label: "Strong" }, { value: "ebook", label: "Recommended" }, { value: "printer", label: "Light" }]
						value: FileLibrary.setting("pdfQuality")
						onPicked: value => FileLibrary.set("pdfQuality", value)
					}
				}

				Group {
					shown: root.page === "pdf"
					title: "Tools"

					Hint {
						text: "Merge, split, pages out and in, rotate, organize, page numbers, watermark, sign, black out, crop, flatten, grayscale, to pictures and text, PDF/A, compress, passwords, OCR, repair, details and compare – in a PDF's menu under “PDF tools”. Every tool makes a new file; the old one stays."
					}

					Line {
						label: Files.ocrLanguages.length > 0 ? `OCR reads ${Files.ocrLanguages.filter(lang => lang !== "osd").join(", ")}` : "OCR needs Tesseract"
						icon: "text_recognition"
					}

					Repeater {
						model: Array.from(new Set(Object.values(Files.pdfMissing)))

						delegate: Line {
							required property string modelData

							label: modelData === "LibreOffice" ? "Office files to PDF and PDF to Word need LibreOffice" : `Some tools need ${modelData}`
							icon: "alert_circle_outline"
							tint: Theme.warning
						}
					}
				}

				// ── storage ────────────────────────────────────────────────
				Group {
					shown: root.page === "storage"
					title: "Thumbnails"

					Line {
						label: root.cache ? `${Files.sizeText(root.cache.size)} in ${root.cache.files} pictures (shared with other apps)` : "Measuring…"
						icon: "image_multiple_outline"

						TextButton {
							height: 30
							variant: "tonal"
							text: "Clear"
							confirm: true
							onActivated: Files.request("thumbcache", { clear: true }, data => {
								root.cache = data;
								Files.thumbMap = {};
								Files.askedThumbs = {};
								Files.thumbTick += 1;
							})
						}
					}
				}

				Group {
					shown: root.page === "storage"
					title: "History"

					Line {
						label: `${FileLibrary.opened.length} files opened from here are remembered for Recent`
						icon: "history"

						TextButton {
							visible: FileLibrary.opened.length > 0
							height: 30
							variant: "tonal"
							text: "Forget"
							confirm: true
							onActivated: FileLibrary.forgetOpened()
						}
					}
				}
			}
		}
	}

	// ── the parts the pages are made of ────────────────────────────────────
	component Group: ColumnLayout {
		id: group

		property bool shown: true
		property string title: ""
		default property alias content: inner.data

		visible: group.shown
		Layout.fillWidth: true
		spacing: 8

		StyledText {
			text: group.title
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		ColumnLayout {
			id: inner

			Layout.fillWidth: true
			spacing: 10
		}
	}

	component Choice: Segmented {
		id: choice

		property var value: ""
		signal picked(var value)

		Layout.fillWidth: true
		height: 34
		current: String(choice.value)
		onSelected: chosen => {
			Sounds.play("select");
			const option = choice.options.find(each => String(each.value) === chosen);
			choice.picked(option ? option.value : chosen);
		}
	}

	component Switch: RowLayout {
		id: line

		property string label: ""
		property string hint: ""
		property bool checked: false
		signal toggled(bool on)

		Layout.fillWidth: true
		spacing: 12
		opacity: line.enabled ? 1 : 0.5

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: line.label
				wrapMode: Text.WordWrap
			}

			StyledText {
				Layout.fillWidth: true
				visible: line.hint !== ""
				text: line.hint
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		Toggle {
			checked: line.checked
			onToggled: on => line.toggled(on)
		}
	}

	component Line: RowLayout {
		id: row

		property string label: ""
		property string icon: ""
		property color tint: Theme.textMuted
		default property alias trailing: tail.data

		Layout.fillWidth: true
		spacing: 10

		Glyph {
			visible: row.icon !== ""
			icon: row.icon
			size: 17
			color: row.tint
		}

		StyledText {
			Layout.fillWidth: true
			text: row.label
			wrapMode: Text.WordWrap
		}

		RowLayout {
			id: tail

			spacing: 6
		}
	}

	component Hint: StyledText {
		Layout.fillWidth: true
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
