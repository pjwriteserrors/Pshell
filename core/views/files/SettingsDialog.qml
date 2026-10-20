pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
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
		{ id: "virus", label: "Virus scan", icon: "shield_search" },
		{ id: "pdf", label: "PDF", icon: "file_pdf_box" },
		{ id: "ai", label: "AI search", icon: "creation" },
		{ id: "rules", label: "Rules", icon: "playlist_check" },
		{ id: "vaults", label: "Vaults", icon: "safe_square_outline" },
		{ id: "sharing", label: "Sharing", icon: "link_variant" },
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
		Files.knowAv();
		Files.knowRules();
		Files.knowVaults();
		Files.knowShares();
		Files.knowIndex();
		Files.knowVm();
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
					title: "With the rest of the shell"

					Switch {
						label: "A finished download says so"
						hint: "With what can be done with it: open, show, extract, scan"
						checked: FileLibrary.setting("downloadToast") !== false
						onToggled: on => FileLibrary.set("downloadToast", on)
					}

					Switch {
						label: "Stay awake while a long job runs"
						hint: "Copies, uploads, scans and conversions keep the PC from sleeping"
						checked: FileLibrary.setting("keepAwake") !== false
						onToggled: on => FileLibrary.set("keepAwake", on)
					}

					Switch {
						visible: Lighting.enabled
						label: "The keyboard breathes when a long job is through"
						hint: "Only while the Files window is not in front"
						checked: FileLibrary.setting("ledPulse") !== false
						onToggled: on => FileLibrary.set("ledPulse", on)
					}

					Switch {
						label: "A terminal opens below the Files window"
						hint: "In the same column, instead of a column of its own. A folder with a workspace of its own opens it there."
						checked: FileLibrary.setting("terminalBeside") !== false
						onToggled: on => FileLibrary.set("terminalBeside", on)
					}

					Switch {
						visible: PhoneDrive.enabled
						label: `All places of ${PhoneDrive.name} in the sidebar`
						hint: "Also all pictures, music and documents – not only camera, screenshots, WhatsApp, downloads and videos"
						checked: !!FileLibrary.setting("phoneAll")
						onToggled: on => FileLibrary.set("phoneAll", on)
					}

					Line {
						visible: !!FileLibrary.setting("wallRotation")?.folder
						label: `Wallpapers come from ${Files.pretty(String(FileLibrary.setting("wallRotation")?.folder ?? ""))}`
						icon: "wallpaper"

						TextButton {
							height: 30
							variant: "tonal"
							text: "Stop"
							onClicked: FileLibrary.set("wallRotation", null)
						}
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
						label: "Git status on files"
						hint: "In a repository: what changed shows on the cards, the branch above them"
						checked: FileLibrary.setting("gitBadges") !== false
						onToggled: on => FileLibrary.set("gitBadges", on)
					}

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

				// the Windows VM: a folder both sides see, programs opened in it
				Group {
					shown: root.page === "windows" && Plugins.on("vm-launcher")
					title: `Windows VM (${Files.vmName})`

					Hint {
						text: "“Open in the Windows VM” puts a program into a folder the VM shares with this PC and asks Windows to start it. Setting it up adds that folder to the VM (virtiofs; the VM must be off). In Windows it needs the virtio-win guest tools with VirtIO-FS and WinFsp once, and the watcher script from the folder (pshell-open.ps1) started at logon – it opens what is asked for."
					}

					Line {
						label: Files.vmShare.known === false ? "libvirt does not know this VM" : (Files.vmShare.shared ? `Shares ${Files.pretty(String(Files.vmShare.folder))}` : "No shared folder yet")
						icon: Files.vmShare.shared ? "check_decagram_outline" : "folder_network_outline"
						tint: Files.vmShare.shared ? Theme.success : Theme.textMuted

						TextButton {
							visible: Files.vmShare.known !== false && !Files.vmShare.shared
							height: 30
							variant: "filled"
							text: "Set up"
							enabled: Files.vmShare.state === "shut off"
							onClicked: root.view.ask("Which folder should the VM share?", "Folder", String(Files.vmShare.suggested || `${Files.home}/VM Share`), folder => Files.setupVmShare(folder.replace(/^~/, Files.home)))
						}

						TextButton {
							visible: !!Files.vmShare.shared
							height: 30
							variant: "tonal"
							text: "Open the folder"
							onClicked: {
								root.hide();
								root.view.pane.openFolder(String(Files.vmShare.folder));
							}
						}
					}

					Hint {
						visible: Files.vmShare.known !== false && !Files.vmShare.shared && Files.vmShare.state !== "shut off"
						text: "Shut the VM down first – its setup can only change while it is off."
					}
				}

				// ── the scan on this PC ────────────────────────────────────
				Group {
					shown: root.page === "virus"
					title: "On this PC – nothing leaves it"

					Hint {
						text: "ClamAV with its signatures and the free extra ones of Sanesecurity and URLhaus, and the core rules of YARA Forge. For private files: they are scanned here and never sent anywhere. Right click → “Scan for viruses”."
					}

					Line {
						label: Files.av.clamav ? "ClamAV is installed" : "ClamAV is not installed"
						icon: Files.av.clamav ? "check_decagram_outline" : "alert_circle_outline"
						tint: Files.av.clamav ? Theme.success : Theme.warning

						TextButton {
							visible: !Files.av.clamav
							height: 30
							variant: "filled"
							text: "Install"
							icon: "download"
							onClicked: {
								Files.installAv();
								avRecheck.restart();
							}
						}
					}

					Line {
						visible: !!Files.av.clamav
						label: Files.av.signatures ? `Signatures of ${Files.whenText(Files.av.signatures)}${Files.av.extras ? ` · ${Files.av.extras} extra sets` : ""}` : "No signatures yet"
						icon: "database_outline"
						tint: Files.av.signatures ? Theme.textMuted : Theme.warning

						TextButton {
							height: 30
							variant: Files.av.signatures ? "tonal" : "filled"
							text: Files.av.signatures ? "Update" : "Download (≈ 250 MB)"
							icon: "refresh"
							onClicked: Files.avUpdate(() => Files.knowAv())
						}
					}

					Line {
						visible: !!Files.av.yara
						label: Files.av.rules ? `YARA rules of ${Files.whenText(Files.av.rules)}` : "YARA rules come with the signatures"
						icon: "text_search"
					}

					Switch {
						label: "Also YARA's rules"
						hint: "They find what is new or packed, now and then also something harmless."
						checked: FileLibrary.setting("avYara") !== false
						enabled: !!Files.av.yara
						onToggled: on => FileLibrary.set("avYara", on)
					}

					Switch {
						label: "Scan every finished download here"
						hint: "Signatures older than a day are updated before a scan."
						checked: FileLibrary.setting("avDownloads")
						enabled: !!Files.av.clamav
						onToggled: on => FileLibrary.set("avDownloads", on)
					}

					Timer {
						id: avRecheck

						interval: 3000
						repeat: true
						running: false
						property int left: 60
						onTriggered: Files.knowAv(av => {
							avRecheck.left -= 1;
							if (av.clamav || avRecheck.left <= 0) {
								avRecheck.stop();
								// a fresh install gets its signatures right away
								if (av.clamav && !av.signatures) Files.avUpdate(() => Files.knowAv());
							}
						})
					}
				}

				// ── VirusTotal ─────────────────────────────────────────────
				Group {
					shown: root.page === "virus"
					title: "VirusTotal – API key"

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
					shown: root.page === "virus"
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
					shown: root.page === "virus"
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

				// ── search by meaning ──────────────────────────────────────
				Group {
					shown: root.page === "ai"
					title: "Search by meaning – on this PC"

					Hint {
						text: "Ask in plain words: “the Telekom invoice from the spring”, “photo of the red car”. The files of a few folders are read – their names, their text, the text in pictures and, with a picture model, what pictures show – into an index on this PC. Ollama reads the question; nothing leaves the PC. In the search: “By meaning”. On a file: “Find similar files”."
					}

					Switch {
						label: "Keep the index up to date"
						hint: "Soon after the start, then every four hours"
						checked: !!FileLibrary.setting("aiIndex")
						onToggled: on => {
							FileLibrary.set("aiIndex", on);
							if (on && !Files.index.built) Files.indexNow();
						}
					}

					Line {
						label: Files.index.running ? `Reading ${Files.index.done ?? 0} of ${Files.index.total ?? 0}${Files.index.current ? " · " + Files.index.current : ""}`
							: (Files.index.files ? `${Files.index.files} files · ${Files.index.withText ?? 0} with text · ${Files.index.meanings ?? 0} by meaning · ${Files.index.described ?? 0} pictures described · ${Files.whenText(Files.index.built).toLowerCase()}` : "Nothing indexed yet")
						icon: Files.index.running ? "progress_clock" : "database_search_outline"

						TextButton {
							height: 30
							variant: Files.index.files ? "tonal" : "filled"
							text: Files.index.running ? "Stop" : "Index now"
							icon: Files.index.running ? "close" : "refresh"
							onClicked: Files.index.running ? Files.request("indexstop", {}) : Files.indexNow()
						}
					}

					Hint {
						visible: !!Files.index.error
						text: String(Files.index.error || "")
					}
				}

				Group {
					shown: root.page === "ai"
					title: "Folders"

					Repeater {
						model: FileLibrary.setting("aiFolders").length > 0 ? FileLibrary.setting("aiFolders") : ["Documents", "Downloads", "Desktop", "Pictures"].map(name => `${Files.home}/${name}`)

						delegate: Line {
							required property string modelData

							label: Files.pretty(modelData)
							icon: "folder_outline"

							IconButton {
								visible: FileLibrary.setting("aiFolders").length > 0
								width: 28
								height: 28
								iconSize: 15
								icon: "close"
								onClicked: FileLibrary.set("aiFolders", FileLibrary.setting("aiFolders").filter(path => path !== modelData))
							}
						}
					}

					TextButton {
						Layout.alignment: Qt.AlignLeft
						height: 30
						variant: "tonal"
						icon: "folder_plus_outline"
						text: root.view.pane?.isFolder ? `Add ${Files.pretty(root.view.pane.location.path)}` : "Add a folder…"
						onClicked: {
							const base = FileLibrary.setting("aiFolders").length > 0 ? FileLibrary.setting("aiFolders") : ["Documents", "Downloads", "Desktop", "Pictures"].map(name => `${Files.home}/${name}`);
							const add = path => FileLibrary.set("aiFolders", base.filter(each => each !== path).concat([path]));
							if (root.view.pane?.isFolder) add(root.view.pane.location.path);
							else root.view.ask("Index which folder?", "Folder", Files.home, path => add(path.replace(/^~/, Files.home)));
						}
					}

					Switch {
						label: "Include pictures"
						checked: FileLibrary.setting("aiPictures") !== false
						onToggled: on => {
							FileLibrary.set("aiPictures", on);
							if (FileLibrary.setting("aiIndex")) Qt.callLater(() => Files.indexNow());
						}
					}

					Switch {
						label: "Read the text in pictures and scans (OCR)"
						enabled: FileLibrary.setting("aiPictures") !== false
						hint: "Screenshots and scanned letters become findable by what they say; it takes a while the first time"
						checked: FileLibrary.setting("aiOcr") !== false
						onToggled: on => FileLibrary.set("aiOcr", on)
					}

					Switch {
						label: "Describe pictures with a picture model"
						hint: Files.index.ai?.vision ? `With ${Files.index.ai.vision} – about a second or two per picture` : "Needs a picture model (below)"
						checked: FileLibrary.setting("aiDescribe") !== false
						enabled: !!Files.index.ai?.vision && FileLibrary.setting("aiPictures") !== false
						onToggled: on => FileLibrary.set("aiDescribe", on)
					}
				}

				Group {
					shown: root.page === "ai"
					title: "Models (Ollama)"

					Line {
						visible: !Files.index.ai?.running
						label: "Ollama is not running"
						icon: "alert_circle_outline"
						tint: Theme.warning
					}

					ModelChoice {
						label: "Reading questions"
						key: "understand"
						role: "text"
					}

					ModelChoice {
						label: "Finding by meaning"
						key: "embed"
						role: "embed"
					}

					ModelChoice {
						label: "Describing pictures"
						key: "describe"
						role: "vision"
					}

					ModelChoice {
						label: "Naming pictures by what they show"
						key: "nameVision"
						role: "vision"
					}

					ModelChoice {
						label: "Naming pictures by their text"
						key: "nameText"
						role: "text"
					}

					ModelChoice {
						label: "Translating on this PC"
						key: "translate"
						role: "text"
					}

					Line {
						visible: !Files.index.ai?.embed && !!Files.index.ai?.running
						label: `Search by meaning needs an embedding model: ${Files.index.ai?.suggestedEmbed ?? "nomic-embed-text"} (about 270 MB)`
						icon: "vector_link"

						TextButton {
							height: 30
							variant: "filled"
							icon: "download"
							text: "Download"
							onClicked: Files.pullModel(Files.index.ai?.suggestedEmbed ?? "nomic-embed-text")
						}
					}

					Line {
						visible: !Files.index.ai?.vision && !!Files.index.ai?.running
						label: `Pictures are described with a picture model: ${Files.index.ai?.suggestedVision ?? "moondream"} (about 1.7 GB)`
						icon: "eye_outline"

						TextButton {
							height: 30
							variant: "tonal"
							icon: "download"
							text: "Download"
							onClicked: Files.pullModel(Files.index.ai?.suggestedVision ?? "moondream")
						}
					}
				}

				// ── rules ──────────────────────────────────────────────────
				Group {
					shown: root.page === "rules"
					title: "Rules for folders"

					Hint {
						text: "What happens on its own: new PDFs that mention “Rechnung” go to Documents/Invoices, screenshots older than a month into an archive. A rule only takes files that arrive after it was made – “Run now” takes what is there already. Everything a rule does can be undone (Ctrl+Shift+Z)."
					}

					Repeater {
						model: Files.rules

						delegate: Rectangle {
							id: ruleCard

							required property var modelData

							Layout.fillWidth: true
							implicitHeight: ruleColumn.implicitHeight + 20
							radius: Theme.radius.large
							color: Theme.layer2
							opacity: modelData.enabled === false ? 0.6 : 1

							RowLayout {
								id: ruleColumn

								x: 12
								y: 10
								width: parent.width - 24
								spacing: 10

								Glyph {
									icon: "playlist_check"
									size: 18
									color: Theme.primary
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 2

									StyledText {
										Layout.fillWidth: true
										text: ruleCard.modelData.name || Files.ruleTexts[ruleCard.modelData.id] || "Rule"
										font.weight: Font.DemiBold
										elide: Text.ElideRight
									}

									StyledText {
										Layout.fillWidth: true
										text: `In ${Files.pretty(ruleCard.modelData.folder)}: ${Files.ruleTexts[ruleCard.modelData.id] ?? ""}`
										tone: Theme.textMuted
										font.pixelSize: Theme.size.small
										wrapMode: Text.WordWrap
									}

									StyledText {
										visible: !!ruleCard.modelData.lastRun
										text: `${ruleCard.modelData.count ?? 0} file${(ruleCard.modelData.count ?? 0) === 1 ? "" : "s"} so far · last ${Files.whenText(ruleCard.modelData.lastRun).toLowerCase()}`
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.tiny
									}
								}

								IconButton {
									width: 30
									height: 30
									iconSize: 15
									icon: "play_outline"
									onClicked: Files.runRule(ruleCard.modelData.id)
								}

								IconButton {
									width: 30
									height: 30
									iconSize: 15
									icon: "pencil_outline"
									onClicked: root.view.ruleDialog(ruleCard.modelData, "")
								}

								IconButton {
									width: 30
									height: 30
									iconSize: 15
									icon: "delete_outline"
									onClicked: Files.removeRule(ruleCard.modelData.id)
								}

								Toggle {
									checked: ruleCard.modelData.enabled !== false
									onToggled: on => Files.saveRule(Object.assign({}, ruleCard.modelData, { enabled: on }))
								}
							}
						}
					}

					TextButton {
						Layout.alignment: Qt.AlignLeft
						height: 32
						variant: "tonal"
						icon: "plus"
						text: "New rule"
						onClicked: root.view.ruleDialog(null, Files.home + "/Downloads")
					}
				}

				// ── vaults ─────────────────────────────────────────────────
				Group {
					shown: root.page === "vaults"
					title: "Vaults – encrypted folders"

					Hint {
						text: "A vault keeps its files encrypted on disk (gocryptfs); open, it is a normal folder. Lock it and nothing in it can be read – also not from a backup or a cloud folder it lies in. Make one with a right click on empty space → Look at it → New vault here."
					}

					Line {
						label: Files.vaults.installed ? "gocryptfs is installed" : "gocryptfs is not installed"
						icon: Files.vaults.installed ? "check_decagram_outline" : "alert_circle_outline"
						tint: Files.vaults.installed ? Theme.success : Theme.warning

						TextButton {
							visible: !Files.vaults.installed && !!Files.vaults.install
							height: 30
							variant: "filled"
							text: "Install"
							icon: "download"
							onClicked: {
								Quickshell.execDetached(["kitty", "--title", "Install gocryptfs", "sh", "-c", `${Files.vaults.install}; echo; echo 'Done – this window can close.'; read -r _`]);
								vaultRecheck.restart();
							}
						}
					}

					Line {
						label: Files.vaults.fingerprint ? "Kept passwords open with your finger on the reader" : (Plugins.on("phone-unlock") ? "Kept passwords open with your finger on the phone" : "Kept passwords open without asking while you are logged in")
						icon: Files.vaults.fingerprint || Plugins.on("phone-unlock") ? "fingerprint" : "key_outline"
					}

					Repeater {
						model: Files.vaults.vaults ?? []

						delegate: Line {
							required property var modelData

							label: `${modelData.name} · ${Files.pretty(modelData.mount)}${modelData.keyring ? " · password kept" : ""}`
							icon: modelData.open ? "safe_square_outline" : "lock_outline"
							tint: modelData.open ? Theme.success : Theme.textMuted

							TextButton {
								height: 30
								variant: "tonal"
								text: modelData.open ? "Lock" : "Open"
								onClicked: {
									if (modelData.open) Files.vaultDo({ action: "close", vault: modelData.id });
									else root.view.unlockVault(modelData, path => {
										root.hide();
										root.view.pane.openFolder(path);
									});
								}
							}
						}
					}

					Timer {
						id: vaultRecheck

						interval: 3000
						repeat: true
						property int left: 60
						onTriggered: Files.knowVaults(status => {
							vaultRecheck.left -= 1;
							if (status.installed || vaultRecheck.left <= 0) vaultRecheck.stop();
						})
					}
				}

				// ── sharing ────────────────────────────────────────────────
				Group {
					shown: root.page === "sharing"
					title: "Links to share"

					Hint {
						text: "Right click → Share a link… uploads a file (or a ZIP of several) and puts the link on the clipboard. Litterbox and 0x0.st delete it when the time is up; on your own server it is deleted by this PC once it ran out."
					}

					Choice {
						options: [{ value: "litterbox", label: "Litterbox" }, { value: "0x0", label: "0x0.st" }, { value: "ssh", label: "My server" }]
						value: FileLibrary.setting("shareHost")
						onPicked: value => FileLibrary.set("shareHost", value)
					}
				}

				Group {
					shown: root.page === "sharing"
					title: "My server"

					Hint {
						text: "A folder on a server you reach by SSH that a web server shows, and the address it has there – e.g. /var/www/share and https://example.org/share."
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						Field {
							id: shareHost

							Layout.fillWidth: true
							placeholder: "user@server (or a login of the SSH plugin)"
							text: String(FileLibrary.setting("shareServer")?.server?.address ?? "")
						}
					}

					Field {
						id: shareFolder

						Layout.fillWidth: true
						placeholder: "Folder on the server"
						text: String(FileLibrary.setting("shareServer")?.folder ?? "")
					}

					Field {
						id: shareUrl

						Layout.fillWidth: true
						placeholder: "Its web address"
						text: String(FileLibrary.setting("shareServer")?.url ?? "")
					}

					TextButton {
						Layout.alignment: Qt.AlignRight
						height: 32
						variant: "filled"
						text: "Save"
						enabled: shareHost.text.trim() !== "" && shareFolder.text.trim() !== "" && /^https?:\/\//.test(shareUrl.text.trim())
						onClicked: {
							FileLibrary.set("shareServer", { name: shareHost.text.trim(), server: { address: shareHost.text.trim() }, folder: shareFolder.text.trim(), url: shareUrl.text.trim() });
							Sounds.play("taskDone");
						}
					}
				}

				Group {
					shown: root.page === "sharing"
					title: "Shared lately"

					Hint {
						visible: Files.shares.length === 0
						text: "Nothing shared yet."
					}

					Repeater {
						model: Files.shares.slice(0, 30)

						delegate: Line {
							required property var modelData

							label: `${modelData.name} · ${modelData.expired ? "ran out" : (modelData.expires ? "until " + Qt.formatDateTime(new Date(modelData.expires * 1000), "ddd d MMM HH:mm") : "")}`
							icon: modelData.expired ? "link_variant_off" : "link_variant"
							tint: modelData.expired ? Theme.textSubtle : Theme.primary

							IconButton {
								visible: !modelData.expired
								width: 30
								height: 30
								iconSize: 15
								icon: "content_copy"
								onClicked: Files.copyText(modelData.url, "Link copied")
							}

							IconButton {
								width: 30
								height: 30
								iconSize: 15
								icon: "delete_outline"
								onClicked: Files.unshare(modelData.id)
							}
						}
					}
				}

				// ── storage ────────────────────────────────────────────────
				Group {
					shown: root.page === "storage"
					title: "Thumbnails"

					Line {
						label: root.cache ? `${Format.bytes(root.cache.size)} in ${root.cache.files} pictures (shared with other apps)` : "Measuring…"
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

	// which model a feature uses: one picked, or the one found (ai.py)
	component ModelChoice: RowLayout {
		id: pick

		property string label: ""
		property string key: ""
		// text | vision | embed
		property string role: "text"
		readonly property var ai: Files.index.ai ?? ({})
		readonly property var installed: (pick.ai.models ?? []).filter(name => (pick.role === "embed") === (pick.ai.embedModels ?? []).includes(name))
		readonly property string picked: String((FileLibrary.setting("aiModels") ?? {})[pick.key] ?? "")
		readonly property bool kept: pick.installed.includes(pick.picked)
		readonly property string found: String(pick.ai[pick.role] ?? "")

		Layout.fillWidth: true
		spacing: 10

		Glyph {
			icon: pick.role === "embed" ? "vector_link" : (pick.role === "vision" ? "eye_outline" : "text_box_outline")
			size: 17
			color: Theme.textMuted
		}

		StyledText {
			Layout.fillWidth: true
			text: pick.label
			wrapMode: Text.WordWrap
		}

		TextButton {
			height: 30
			variant: "tonal"
			enabled: pick.installed.length > 0
			text: pick.kept ? pick.picked : (pick.found !== "" ? `Automatic · ${pick.found}` : "None")
			onClicked: models.open()

			PickList {
				id: models

				x: parent ? parent.width - width : 0
				y: parent ? parent.height + 4 : 0
				current: pick.kept ? pick.picked : ""
				entries: [{ value: "", label: "Automatic", detail: pick.found, icon: "auto_fix" }].concat(pick.installed.map(name => ({ value: name, label: name, icon: "robot_outline" })))
				onPicked: value => {
					FileLibrary.set("aiModels", Object.assign({}, FileLibrary.setting("aiModels") ?? {}, { [pick.key]: value }));
					// other vectors: the index is read again
					if (pick.key === "embed" && FileLibrary.setting("aiIndex")) Qt.callLater(() => Files.indexNow());
				}
			}
		}
	}

	component Hint: StyledText {
		Layout.fillWidth: true
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
