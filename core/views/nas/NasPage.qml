pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// Pshell settings › NAS (docs/nas.md): how this PC reaches netcore and
// mounts it, what it computes for it, every setting of the server, the
// sync pairs, the backups, game saves, the devices, where downloads go, the
// shelf and Streams sync and the Baikal calendar. Server settings go through
// the daemon (`set`), this PC's through `setlocal` (nas.json). What can
// expose or lose files says so in a warning line and asks before it is
// switched on.
SettingsPage {
	id: root

	title: "NAS"
	description: "netcore: the files at home, from here, the laptop and the phone."

	onActiveChanged: if (root.active) root.load()

	function load() {
		Nas.loadSettings();
		Nas.loadLocal();
		Nas.loadDevices();
		if (Plugins.on("nas-saves")) Nas.saves("list", "", (data, error) => root.games = error ? [] : (data?.hosts?.[data.host] ?? []));
		// the old filebrowser container, while it is there
		Nas.api("GET", "/api/health", null, (data, error) => root.filebrowser = error ? null : ((data?.containers ?? []).find(c => /filebrowser/i.test(String(c.name))) ?? null));
	}

	property var filebrowser: null

	property string adminPassword: ""
	property bool adminShown: false
	property var minted: null
	property var games: []
	// the Baikal calendar whose members show (sharing)
	property string sharingCalendar: ""
	// the versions of a picked file: { path, list }
	property var versionsOf: null

	readonly property var types: [
		{ type: "thumb", label: "Thumbnails", fallback: "pc_or_pi" },
		{ type: "preview", label: "Video scrub previews", fallback: "pc_or_pi" },
		{ type: "convert", label: "Conversions", fallback: "pc_or_pi" },
		{ type: "avscan", label: "Virus scan (ClamAV)", fallback: "pc_or_pi" },
		{ type: "vtscan", label: "VirusTotal", fallback: "pc_or_pi" },
		{ type: "pdf", label: "PDF tools", fallback: "pc_or_pi" },
		{ type: "image", label: "Picture edits", fallback: "pc_or_pi" },
		{ type: "tags", label: "Media tags", fallback: "pc_or_pi" },
		{ type: "compress", label: "Packing archives", fallback: "pc_or_pi" },
		{ type: "extract", label: "Unpacking archives", fallback: "pc_or_pi" },
		{ type: "hash", label: "Hashes, duplicates", fallback: "pc_or_pi" },
		{ type: "embed", label: "Semantic index", fallback: "pc_or_pi" },
		{ type: "faces", label: "Faces", fallback: "pc_or_pi" },
		{ type: "exif", label: "Photo dates and places", fallback: "pc_or_pi" },
		{ type: "upscale", label: "AI upscaling", fallback: "pc" },
		{ type: "transcode", label: "Stream-friendly copies", fallback: "pc_or_pi" },
		{ type: "translate", label: "Translations", fallback: "pc_or_pi" },
		{ type: "describe", label: "AI descriptions", fallback: "pc" }
	]

	function policyOf(type, fallback) {
		return String(Nas.settings[`policy.${type}`] ?? Nas.settings.policy?.[type] ?? fallback);
	}

	function home(path) {
		return String(path).replace(Paths.home, "~");
	}

	function pairsLocal() {
		return Array.isArray(Nas.local.sync) ? Nas.local.sync : [];
	}

	function setPair(id, changes) {
		Nas.setLocal("sync", root.pairsLocal().map(pair => pair.id === id ? Object.assign({}, pair, changes) : pair));
	}

	function pairState(id) {
		return Nas.pairs.find(pair => pair.id === id) ?? Nas.syncs[id] ?? null;
	}

	readonly property var backupLocal: Object.assign({ on: false, schedule: "daily", sets: [] }, Nas.local.backup ?? {})

	function setBackup(changes) {
		Nas.setLocal("backup", Object.assign({}, root.backupLocal, changes));
	}


	// ── pieces ───────────────────────────────────────────────────────────
	component Line: RowLayout {
		id: row

		property string text: ""
		property string hint: ""
		default property alias trailing: holder.data

		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.rightMargin: 12
		spacing: 12

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: row.text
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				visible: row.hint !== ""
				text: row.hint
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.Wrap
			}
		}

		RowLayout {
			id: holder

			spacing: 8
		}
	}

	// a switch that can expose or lose files: a warning line, and switching
	// it to the risky side asks first
	component Risky: ColumnLayout {
		id: risky

		property string title: ""
		property string subtitle: ""
		property string icon: "shield_alert_outline"
		property string warning: ""
		property bool checked: false
		// which side is the risky one
		property bool riskyOn: true
		property bool asking: false
		signal toggled(bool on)

		Layout.fillWidth: true
		spacing: 4

		FlagRow {
			Layout.fillWidth: true
			title: risky.title
			subtitle: risky.subtitle
			icon: risky.icon
			checked: risky.checked
			onToggled: on => {
				if (on === risky.riskyOn) risky.asking = true;
				else risky.toggled(on);
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			spacing: 8

			Glyph {
				Layout.alignment: Qt.AlignTop
				icon: "alert_outline"
				size: 15
				color: Theme.warning
			}

			StyledText {
				Layout.fillWidth: true
				text: risky.warning
				tone: Theme.warning
				font.pixelSize: Theme.size.small
				wrapMode: Text.Wrap
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			Layout.topMargin: 4
			visible: risky.asking
			implicitHeight: askRow.implicitHeight + 20
			radius: Theme.radius.large
			color: Theme.dangerContainer

			RowLayout {
				id: askRow

				anchors.fill: parent
				anchors.margins: 10
				spacing: 8

				StyledText {
					Layout.fillWidth: true
					text: `${risky.riskyOn ? "Switch on" : "Switch off"} “${risky.title}”?`
					font.weight: Font.DemiBold
					wrapMode: Text.Wrap
				}

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: risky.asking = false
				}

				TextButton {
					text: risky.riskyOn ? "Switch on" : "Switch off"
					icon: "alert_outline"
					variant: "danger"
					onActivated: {
						risky.asking = false;
						risky.toggled(risky.riskyOn);
					}
				}
			}
		}
	}

	// a number of the server, sent a moment after the slider stops
	component Amount: ValueSlider {
		id: amount

		required property string key
		property real fallback: 0

		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.rightMargin: 12
		value: Number(Nas.setting(amount.key, amount.fallback))
		onMoved: v => {
			amount.pending = v;
			send.restart();
		}

		property real pending: 0

		Timer {
			id: send

			interval: 500
			onTriggered: Nas.set(amount.key, amount.pending)
		}
	}

	component Note: StyledText {
		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.rightMargin: 12
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		wrapMode: Text.Wrap
	}

	component Head: StyledText {
		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.topMargin: 8
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		font.weight: Font.Bold
	}

	// ── connection ───────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-connection"
		title: !Nas.connected ? "Starting the NAS daemon …" : (!Nas.configured ? "Not set up yet" : (Nas.online ? `Connected · ${Nas.viaText}` : "Not reachable"))
		subtitle: !Nas.connected ? "scripts/nas/nas.py daemon" : (!Nas.configured ? "Run `python3 scripts/nas/setup.py` once: it pairs this PC with netcore" : [Nas.address, Nas.status.server_id ? `server ${String(Nas.status.server_id).slice(0, 8)}` : ""].filter(s => s).join(" · "))
		icon: Nas.online ? "server_network" : "lan"

		// the disk
		ColumnLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			visible: Nas.online && Nas.total > 0
			spacing: 6

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: `${Format.bytes(Nas.free)} free of ${Format.bytes(Nas.total)}`
					font.weight: Font.DemiBold
				}

				StyledText {
					text: Nas.health.temp ? `${Math.round(Nas.health.temp)} °C` : ""
					tone: Theme.textMuted
					tabular: true
				}
			}

			Rectangle {
				Layout.fillWidth: true
				implicitHeight: 8
				radius: 4
				color: Theme.layer3

				Rectangle {
					width: parent.width * Math.max(0, Nas.fill)
					height: parent.height
					radius: parent.radius
					color: Nas.fill > Number(Nas.setting("disk_warn", 90)) / 100 ? Theme.warning : Theme.primary

					Behavior on width {
						SpatialAnim {
							duration: Motion.long
						}
					}
				}
			}

			Repeater {
				model: Nas.warnings

				delegate: StyledText {
					required property var modelData

					Layout.fillWidth: true
					text: `⚠ ${modelData}`
					tone: Theme.warning
					font.pixelSize: Theme.size.small
					wrapMode: Text.Wrap
				}
			}
		}

		FlagRow {
			Layout.fillWidth: true
			title: "Mount the NAS"
			subtitle: Nas.mounted ? `At ${root.home(Nas.mountPath)} – files open from there like any folder` : `At ${root.home(Nas.mountPath)} while the NAS is reachable (rclone)`
			icon: "folder_network_outline"
			checked: !!Nas.localOf("mount", true)
			onToggled: on => {
				Nas.setLocal("mount", on);
				Nas.mount(on);
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			spacing: 8

			TextButton {
				text: "Open the web interface"
				icon: "open_in_new"
				onActivated: Nas.openWeb()
			}

			TextButton {
				visible: Nas.mounted && Plugins.on("filemanager")
				text: "Open in Files"
				icon: "folder_open"
				onActivated: Files.open(Nas.mountPath)
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				visible: Nas.configured
				text: Nas.mounted ? "Unmount" : "Mount now"
				icon: Nas.mounted ? "eject" : "folder_network_outline"
				variant: "ghost"
				onActivated: Nas.mount(!Nas.mounted)
			}
		}

		Line {
			text: "Admin password of the web interface"
			hint: "User lu. Kept by the setup in ~/.local/state/pshell/nas-admin.txt; change it in the web settings."

			StyledText {
				visible: root.adminShown
				text: root.adminPassword || "—"
				font.family: Theme.monoFamily
				font.weight: Font.DemiBold
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: root.adminShown ? "eye_off_outline" : "eye_outline"
				onClicked: {
					if (root.adminShown) {
						root.adminShown = false;
						root.adminPassword = "";
						return;
					}
					Nas.readAdmin(text => {
						root.adminPassword = text;
						root.adminShown = true;
						hideAdmin.restart();
					});
				}
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: "content_copy"
				onClicked: Nas.readAdmin(text => {
					if (text === "") return;
					Quickshell.execDetached(["wl-copy", "--", text]);
					Notifs.pushInternal("done", "Password copied", "NAS admin", { icon: "key_variant", app: "NAS" });
				})
			}

			Timer {
				id: hideAdmin

				interval: 20000
				onTriggered: {
					root.adminShown = false;
					root.adminPassword = "";
				}
			}
		}
	}

	// ── worker ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-worker"
		title: "Computing for the NAS"
		subtitle: Nas.worker.connected ? (Nas.computing ? `${Nas.current.length} ${Nas.current.length === 1 ? "task" : "tasks"} running here` : "Connected as the worker, waiting for tasks") : "Thumbnails, conversions, scans and AI run here while this PC is connected; without it the Pi does them"
		icon: "chip"

		FlagRow {
			Layout.fillWidth: true
			title: "Compute here"
			subtitle: "This PC is the NAS's worker whenever it is connected"
			icon: "cpu_64_bit"
			checked: !!Nas.localOf("worker", true)
			onToggled: on => Nas.setLocal("worker", on)
		}

		FlagRow {
			Layout.fillWidth: true
			title: "Pause computing in games"
			subtitle: GameMode.enabled ? "While game mode is on the tasks go back to the queue (or to the Pi)" : "Needs game mode (Pshell settings › Desktop)"
			icon: "gamepad_variant"
			checked: Nas.pauseInGames
			onToggled: on => Nas.setLocal("pause_in_games", on)
		}

		FlagRow {
			Layout.fillWidth: true
			title: "Paused now"
			subtitle: Nas.pausedForGame ? "Because a game runs" : "Nothing is taken until it is switched off"
			icon: "pause"
			checked: !!Nas.localOf("worker_paused", false)
			onToggled: on => {
				Nas.pausedForGame = false;
				Nas.setLocal("worker_paused", on);
			}
		}

		Note {
			text: `${Nas.running} running, ${Nas.queued} waiting on the NAS`
		}

		Repeater {
			model: Nas.current

			delegate: RowLayout {
				id: task

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				Layout.rightMargin: 12
				spacing: 10

				Glyph {
					icon: "chip"
					size: 16
					color: Theme.primary
				}

				StyledText {
					Layout.fillWidth: true
					text: `${task.modelData.label || task.modelData.type}${task.modelData.text ? " · " + task.modelData.text : ""}`
					elide: Text.ElideRight
				}

				Rectangle {
					implicitWidth: 90
					implicitHeight: 4
					radius: 2
					color: Theme.layer3

					Rectangle {
						width: parent.width * Math.max(0, Math.min(1, Number(task.modelData.progress) || 0))
						height: parent.height
						radius: 2
						color: Theme.primary
					}
				}
			}
		}
	}

	// ── server ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-server"
		title: "Server"
		subtitle: Nas.settingsLoaded ? "Settings of netcore itself; the web interface shows the same" : (Nas.online ? "Reading the settings …" : "Shown once the NAS is reachable")
		icon: "server"

		ColumnLayout {
			Layout.fillWidth: true
			enabled: Nas.settingsLoaded
			opacity: Nas.settingsLoaded ? 1 : 0.45
			spacing: 4

			Head {
				text: "Sharing"
			}

			Risky {
				title: "Links reachable from the internet"
				subtitle: "Share pages at netcore-iseeu.duckdns.org (only /s/ and /u/ are passed on)"
				icon: "web"
				warning: "Anyone with a link can reach those files from anywhere. The router's port forward (443 → netcore) is your step."
				checked: !!Nas.setting("public_shares", false)
				onToggled: on => Nas.set("public_shares", on)
			}

			FlagRow {
				Layout.fillWidth: true
				title: "Upload-only links"
				subtitle: "Links others drop files through; they never see what is there"
				icon: "upload"
				checked: !!Nas.setting("upload_links", true)
				onToggled: on => Nas.set("upload_links", on)
			}

			Head {
				text: "Deleting"
			}

			Risky {
				title: "Delete without the trash"
				subtitle: "Offers deleting for good beside moving to the trash"
				icon: "delete_outline"
				warning: "What is deleted that way is gone; only snapshots may still hold it."
				checked: !!Nas.setting("permanent_delete", false)
				onToggled: on => Nas.set("permanent_delete", on)
			}

			Amount {
				key: "trash_days"
				fallback: 30
				label: "Keep the trash"
				icon: "trash_can_outline"
				from: 1
				to: 120
				step: 1
				unit: " days"
			}

			FlagRow {
				Layout.fillWidth: true
				title: "Snapshots"
				subtitle: "Hard-link copies of the whole tree (cost no space until files change)"
				icon: "history"
				checked: Nas.setting("snapshots", {}).on !== false
				onToggled: on => Nas.set("snapshots", Object.assign({ every: "daily", keep: 7 }, Nas.setting("snapshots", {}), { on: on }))
			}

			RowLayout {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				Layout.rightMargin: 12
				visible: Nas.setting("snapshots", {}).on !== false
				spacing: 12

				Segmented {
					implicitWidth: 260
					options: [{ value: "hourly", label: "Hourly" }, { value: "daily", label: "Daily" }, { value: "weekly", label: "Weekly" }]
					current: String(Nas.setting("snapshots", {}).every ?? "daily")
					onSelected: value => Nas.set("snapshots", Object.assign({ on: true, keep: 7 }, Nas.setting("snapshots", {}), { every: value }))
				}

				ValueSlider {
					id: keepSlider

					Layout.fillWidth: true
					label: "Keep"
					from: 1
					to: 60
					step: 1
					value: Number(Nas.setting("snapshots", {}).keep ?? 7)
					onMoved: v => {
						keepSlider.pending = v;
						keepSend.restart();
					}

					property real pending: 0

					Timer {
						id: keepSend

						interval: 500
						onTriggered: Nas.set("snapshots", Object.assign({ on: true, every: "daily" }, Nas.setting("snapshots", {}), { keep: keepSlider.pending }))
					}
				}
			}

			Head {
				text: "Computing"
			}

			Risky {
				title: "The Pi computes when the PC is not there"
				subtitle: "Off: every task waits for this PC"
				icon: "chip"
				riskyOn: false
				warning: "Off, thumbnails, scans and the photo index wait until this PC connects again."
				checked: Nas.setting("pi_compute", true) !== false
				onToggled: on => Nas.set("pi_compute", on)
			}

			Risky {
				title: "AI on the Pi"
				subtitle: "An Ollama container with nomic-embed-text for the semantic search"
				icon: "memory"
				riskyOn: true
				warning: "Takes about 1 GB of the Pi's memory and makes it warm while it indexes."
				checked: Nas.setting("pi_ai", false) === true
				onToggled: on => Nas.set("pi_ai", on)
			}

			Amount {
				key: "pi_jobs"
				fallback: 1
				label: "Tasks at once on the Pi"
				icon: "chip"
				from: 1
				to: 4
				step: 1
			}

			Line {
				text: "Where each task runs"
				hint: "PC: waits for this PC · Either: the PC when connected, else the Pi · Pi: always on the Pi"
			}

			Rectangle {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				Layout.rightMargin: 12
				implicitHeight: 34
				radius: Theme.radius.medium
				color: "transparent"
				border.width: 1
				border.color: Theme.outline

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 12

					Glyph {
						icon: "alert_outline"
						size: 15
						color: Theme.warning
					}

					StyledText {
						Layout.fillWidth: true
						text: "“Pi” for heavy tasks makes it slow for everyone; “PC” makes them wait while this PC is off."
						tone: Theme.warning
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}
			}

			GridLayout {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				Layout.rightMargin: 12
				columns: 2
				columnSpacing: 16
				rowSpacing: 6

				Repeater {
					model: root.types

					delegate: RowLayout {
						id: policy

						required property var modelData
						property string pendingValue: ""

						Layout.fillWidth: true
						spacing: 8

						StyledText {
							Layout.fillWidth: true
							text: policy.modelData.label
							elide: Text.ElideRight
						}

						Segmented {
							implicitWidth: 190
							implicitHeight: 30
							options: [{ value: "pc", label: "PC" }, { value: "pc_or_pi", label: "Either" }, { value: "pi", label: "Pi" }]
							current: root.policyOf(policy.modelData.type, policy.modelData.fallback)
							onSelected: value => Nas.set(`policy.${policy.modelData.type}`, value)
						}
					}
				}
			}

			Head {
				text: "VirusTotal"
			}

			Risky {
				title: "Upload unknown files to VirusTotal"
				subtitle: "Else only their hash is looked up"
				icon: "shield_alert_outline"
				warning: "Uploaded files can be seen by VirusTotal's partners. Never for private documents."
				checked: !!Nas.setting("vt_upload", false)
				onToggled: on => Nas.set("vt_upload", on)
			}

			Line {
				text: "VirusTotal API key"
				hint: Nas.setting("vt_key", "") !== "" ? "Set" : "Not set: no VirusTotal scans"

				Field {
					id: vtKey

					implicitWidth: 280
					password: true
					placeholder: "Paste the key, Enter"
					onAccepted: {
						Nas.set("vt_key", vtKey.text.trim());
						vtKey.text = "";
					}
				}
			}

			Head {
				text: "Photos and the index"
			}

			FlagRow {
				Layout.fillWidth: true
				title: "Group faces"
				subtitle: "Finds people in the photos (on the PC or the Pi, never online)"
				icon: "account"
				checked: Nas.setting("faces", true) !== false
				onToggled: on => Nas.set("faces", on)
			}

			FlagRow {
				Layout.fillWidth: true
				title: "Index hidden files"
				icon: "eye_outline"
				checked: !!Nas.setting("index_hidden", false)
				onToggled: on => Nas.set("index_hidden", on)
			}

			Line {
				text: "Where photos are looked for"
				hint: "Folders of the NAS, separated by commas"

				Field {
					id: photoFolders

					implicitWidth: 300
					text: (Nas.setting("photo_folders", ["/Phone photos", "/"]) ?? []).join(", ")
					onAccepted: Nas.set("photo_folders", photoFolders.text.split(",").map(s => s.trim()).filter(s => s !== ""))
				}
			}

			Head {
				text: "Access and health"
			}

			FlagRow {
				Layout.fillWidth: true
				title: "Wake devices through the NAS"
				subtitle: "A magic packet from netcore wakes this PC from the phone or from away"
				icon: "power"
				checked: Nas.setting("wake", true) !== false
				onToggled: on => Nas.set("wake", on)
			}

			// with pshell-core the sign-in settings are core's (Pshell settings › Server)
			Line {
				visible: Netcore.online
				text: "Sign-ins are kept by pshell-core"
				hint: "Two-factor, how long a sign-in lasts, users and sessions: Pshell settings › Server"

				TextButton {
					text: "Server page"
					icon: "server"
					onActivated: Netcore.openSettings()
				}
			}

			FlagRow {
				Layout.fillWidth: true
				visible: !Netcore.online
				title: "Two-factor login for everyone"
				subtitle: "Web logins need a TOTP code"
				icon: "lock_outline"
				checked: !!Nas.setting("totp_required", false)
				onToggled: on => Nas.set("totp_required", on)
			}

			Amount {
				visible: !Netcore.online
				key: "session_days"
				fallback: 30
				label: "Stay logged in"
				icon: "key_variant"
				from: 1
				to: 90
				step: 1
				unit: " days"
			}

			Amount {
				key: "disk_warn"
				fallback: 90
				label: "Warn when the disk is fuller than"
				icon: "harddisk"
				from: 50
				to: 99
				step: 1
				unit: " %"
			}

			Head {
				visible: root.filebrowser !== null
				text: "filebrowser"
			}

			Line {
				visible: root.filebrowser !== null
				text: `The old filebrowser container · ${root.filebrowser?.state ?? ""}`
				hint: "⚠ Stopping it ends its links and logins; removing it cannot be undone (its files stay)."

				TextButton {
					text: "Stop"
					icon: "pause"
					variant: "ghost"
					confirm: true
					confirmText: "Stop it?"
					onActivated: Nas.api("POST", "/api/filebrowser", { action: "stop" }, (data, error) => {
						Nas.report(error, "filebrowser stopped");
						root.load();
					})
				}

				TextButton {
					text: "Remove"
					icon: "delete_outline"
					variant: "danger"
					confirm: true
					confirmText: "Remove for good?"
					onActivated: Nas.api("POST", "/api/filebrowser", { action: "remove" }, (data, error) => {
						Nas.report(error, "filebrowser removed");
						root.load();
					})
				}
			}
		}
	}

	// ── sync pairs ───────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-sync"
		visible: Plugins.on("nas-sync")
		title: "Folder sync"
		subtitle: root.pairsLocal().length === 0 ? "Folders of this PC kept the same as folders of the NAS" : `${root.pairsLocal().length} ${root.pairsLocal().length === 1 ? "pair" : "pairs"}${Nas.conflicts > 0 ? ` · ${Nas.conflicts} ${Nas.conflicts === 1 ? "conflict" : "conflicts"}` : ""}`
		icon: "folder_sync_outline"

		Repeater {
			model: root.pairsLocal()

			delegate: Rectangle {
				id: pair

				required property var modelData
				readonly property var live: root.pairState(pair.modelData.id)
				readonly property var conflictList: Array.isArray(pair.live?.conflicts) ? pair.live.conflicts : []

				Layout.fillWidth: true
				implicitHeight: pairColumn.implicitHeight + 24
				radius: Theme.radius.large
				color: Theme.layer2

				ColumnLayout {
					id: pairColumn

					x: 12
					y: 12
					width: parent.width - 24
					spacing: 8

					RowLayout {
						Layout.fillWidth: true
						spacing: 10

						Glyph {
							icon: "folder_outline"
							size: 18
							color: Theme.primary
						}

						StyledText {
							Layout.fillWidth: true
							text: `${root.home(pair.modelData.local)}  ⇄  NAS ${pair.modelData.remote}`
							font.weight: Font.DemiBold
							elide: Text.ElideMiddle
						}

						StyledText {
							text: pair.live ? `${pair.live.state || ""}${pair.live.last ? " · " + Nas.ago(pair.live.last) : ""}` : ""
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}

						IconButton {
							implicitWidth: 30
							implicitHeight: 30
							icon: "sync"
							onClicked: Nas.syncNow(pair.modelData.id)
						}

						IconButton {
							implicitWidth: 30
							implicitHeight: 30
							icon: "delete_outline"
							onClicked: Nas.setLocal("sync", root.pairsLocal().filter(other => other.id !== pair.modelData.id))
						}
					}

					Segmented {
						Layout.fillWidth: true
						options: [{ value: "twoway", label: "Both ways" }, { value: "upload", label: "Only up" }, { value: "mirror", label: "Mirror this PC" }]
						current: String(pair.modelData.mode || "twoway")
						onSelected: value => root.setPair(pair.modelData.id, { mode: value })
					}

					Risky {
						visible: pair.modelData.mode === "mirror"
						title: "Deletes reach the NAS"
						subtitle: "What is deleted here is deleted on the NAS too (to its trash)"
						icon: "delete_outline"
						warning: "Off, a mirror never deletes on the NAS. On, a folder emptied here by mistake empties the NAS's copy too."
						checked: !!pair.modelData.mirror_deletes
						onToggled: on => root.setPair(pair.modelData.id, { mirror_deletes: on })
					}

					Repeater {
						model: pair.conflictList

						delegate: RowLayout {
							id: conflict

							required property var modelData

							Layout.fillWidth: true
							spacing: 8

							Glyph {
								icon: "alert_outline"
								size: 14
								color: Theme.warning
							}

							StyledText {
								Layout.fillWidth: true
								text: `${conflict.modelData.path ?? conflict.modelData} → kept both, the other as ${conflict.modelData.copy ?? "a copy"}`
								font.pixelSize: Theme.size.small
								elide: Text.ElideMiddle
							}

							IconButton {
								visible: !!conflict.modelData.copy
								implicitWidth: 26
								implicitHeight: 26
								icon: "folder_open"
								onClicked: Files.reveal([`${Nas.expand(pair.modelData.local).replace(/\/$/, "")}/${conflict.modelData.copy}`])
							}
						}
					}
				}
			}
		}

		// a new pair
		RowLayout {
			id: adder

			property string localFolder: ""

			Layout.fillWidth: true
			spacing: 8

			TextButton {
				text: adder.localFolder !== "" ? root.home(adder.localFolder) : "Folder here…"
				icon: "folder_outline"
				variant: "ghost"
				onActivated: Files.pick({ directory: true, title: "Folder of this PC to sync", folder: Paths.home }, paths => {
					if (paths.length > 0) adder.localFolder = String(paths[0]);
				})
			}

			StyledText {
				text: "⇄"
				tone: Theme.textMuted
			}

			Field {
				id: remoteField

				Layout.fillWidth: true
				icon: "server_network"
				placeholder: "Folder on the NAS, e.g. /Documents"
			}

			IconButton {
				visible: Nas.mounted
				implicitWidth: 32
				implicitHeight: 32
				icon: "folder_search_outline"
				onClicked: Files.pick({ directory: true, title: "Folder on the NAS", folder: Nas.mountPath }, paths => {
					const nas = paths.length > 0 ? Nas.nasPathOf(paths[0]) : "";
					if (nas !== "") remoteField.text = nas;
				})
			}

			TextButton {
				text: "Add"
				icon: "plus"
				variant: "filled"
				enabled: adder.localFolder !== "" && remoteField.text.trim().startsWith("/")
				onActivated: {
					const id = `pair-${Date.now().toString(36)}`;
					Nas.setLocal("sync", root.pairsLocal().concat([{ id: id, local: root.home(adder.localFolder), remote: remoteField.text.trim(), mode: "twoway", mirror_deletes: false }]));
					adder.localFolder = "";
					remoteField.text = "";
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.pairsLocal().length > 0

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "Sync all now"
				icon: "sync"
				onActivated: Nas.syncNow("")
			}
		}
	}

	// ── backups ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-backup"
		visible: Plugins.on("nas-backup")
		title: "Backups"
		subtitle: Nas.backup.running ? "Backing up now …" : (Nas.backupLast > 0 ? `Last ${Format.ago(Nas.backupLast * 1000)} ago${Nas.backupOk ? "" : " – failed"}${Nas.backup.next ? ` · next in ${Format.duration(Math.max(0, Nas.seconds(Nas.backup.next) - Date.now() / 1000))}` : ""}` : "restic to the NAS: versions of your folders, shown in Files › Earlier versions")
		icon: "backup_restore"

		FlagRow {
			Layout.fillWidth: true
			title: "Back up on a schedule"
			icon: "backup_restore"
			checked: !!root.backupLocal.on
			onToggled: on => root.setBackup({ on: on })
		}

		Line {
			text: "How often"

			Segmented {
				implicitWidth: 260
				options: [{ value: "hourly", label: "Hourly" }, { value: "daily", label: "Daily" }, { value: "weekly", label: "Weekly" }]
				current: String(root.backupLocal.schedule || "daily")
				onSelected: value => root.setBackup({ schedule: value })
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: !!Nas.backup.error
			text: String(Nas.backup.error || "")
			tone: Theme.danger
			font.pixelSize: Theme.size.small
			wrapMode: Text.Wrap
		}

		Repeater {
			model: root.backupLocal.sets ?? []

			delegate: Rectangle {
				id: set

				required property var modelData
				required property int index

				Layout.fillWidth: true
				implicitHeight: setColumn.implicitHeight + 20
				radius: Theme.radius.large
				color: Theme.layer2

				ColumnLayout {
					id: setColumn

					x: 12
					y: 10
					width: parent.width - 24
					spacing: 6

					RowLayout {
						Layout.fillWidth: true

						Toggle {
							checked: set.modelData.on !== false
							onToggled: on => root.setBackup({ sets: root.backupLocal.sets.map((other, i) => i === set.index ? Object.assign({}, other, { on: on }) : other) })
						}

						StyledText {
							Layout.fillWidth: true
							text: set.modelData.name || set.modelData.id
							font.weight: Font.DemiBold
						}

						TextButton {
							text: "Add folder"
							icon: "plus"
							variant: "ghost"
							onActivated: Files.pick({ directory: true, title: `Folder for ${set.modelData.name || "the backup"}`, folder: Paths.home }, paths => {
								if (paths.length === 0) return;
								root.setBackup({ sets: root.backupLocal.sets.map((other, i) => i === set.index ? Object.assign({}, other, { paths: (other.paths ?? []).concat([root.home(paths[0])]) }) : other) });
							})
						}

						IconButton {
							implicitWidth: 30
							implicitHeight: 30
							icon: "backup_restore"
							onClicked: Nas.backupNow(set.modelData.id)
						}

						IconButton {
							implicitWidth: 30
							implicitHeight: 30
							icon: "delete_outline"
							onClicked: root.setBackup({ sets: root.backupLocal.sets.filter((other, i) => i !== set.index) })
						}
					}

					Flow {
						Layout.fillWidth: true
						spacing: 6

						Repeater {
							model: set.modelData.paths ?? []

							delegate: Chip {
								required property string modelData

								text: modelData
								icon: "close"
								onClicked: root.setBackup({ sets: root.backupLocal.sets.map((other, i) => i === set.index ? Object.assign({}, other, { paths: (other.paths ?? []).filter(path => path !== modelData) }) : other) })
							}
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: setName

				Layout.fillWidth: true
				icon: "plus"
				placeholder: "New set, e.g. Documents"
				onAccepted: {
					if (setName.text.trim() === "") return;
					const id = setName.text.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-");
					root.setBackup({ sets: (root.backupLocal.sets ?? []).concat([{ id: id, name: setName.text.trim(), paths: [], on: true }]) });
					setName.text = "";
				}
			}

			TextButton {
				text: "Restore a file…"
				icon: "restore"
				variant: "ghost"
				onActivated: Files.pick({ title: "Which file to bring back", folder: Paths.home }, paths => {
					if (paths.length === 0) return;
					const path = String(paths[0]);
					root.versionsOf = { path: path, list: null };
					Nas.versions(path, (list, error) => root.versionsOf = { path: path, list: list, error: error });
				})
			}

			TextButton {
				text: "Back up now"
				icon: "backup_restore"
				busy: !!Nas.backup.running
				onActivated: Nas.backupNow("")
			}
		}

		// the versions of the file picked for restoring
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.versionsOf !== null
			spacing: 4

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: root.versionsOf ? `Versions of ${root.home(root.versionsOf.path)}` : ""
					font.weight: Font.DemiBold
					elide: Text.ElideMiddle
				}

				Spinner {
					visible: root.versionsOf !== null && root.versionsOf.list === null
					Layout.preferredWidth: 14
					Layout.preferredHeight: 14
				}

				IconButton {
					implicitWidth: 28
					implicitHeight: 28
					icon: "close"
					onClicked: root.versionsOf = null
				}
			}

			Note {
				visible: root.versionsOf?.list?.length === 0
				text: root.versionsOf?.error ? String(root.versionsOf.error) : "No earlier version of it on the NAS"
			}

			Repeater {
				model: root.versionsOf?.list ?? []

				delegate: ListItem {
					id: version

					required property var modelData

					Layout.fillWidth: true
					icon: version.modelData.source === "nas-trash" ? "trash_can_outline" : (version.modelData.source === "backup" ? "backup_restore" : "history")
					title: version.modelData.when ? Qt.formatDateTime(new Date(Nas.seconds(version.modelData.when) * 1000), "d MMM yyyy, HH:mm") : String(version.modelData.title ?? version.modelData.id)
					subtitle: [String(version.modelData.detail || version.modelData.title || ""), version.modelData.size ? Format.bytes(version.modelData.size) : ""].filter(s => s).join(" · ")

					TextButton {
						text: "Beside it"
						variant: "ghost"
						onActivated: Nas.restore(root.versionsOf.path, version.modelData.id, "beside")
					}

					TextButton {
						text: "Replace"
						variant: "danger"
						confirm: true
						onActivated: Nas.restore(root.versionsOf.path, version.modelData.id, "replace")
					}
				}
			}
		}
	}

	// ── game saves ───────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-saves"
		visible: Plugins.on("nas-saves")
		title: "Game saves"
		subtitle: "ludusavi keeps the saves of your games in /Game saves/" + Host.hostname
		icon: "content_save_cog_outline"

		FlagRow {
			Layout.fillWidth: true
			title: "Back up game saves"
			subtitle: "After a game closes, and with the backups"
			icon: "gamepad_variant"
			checked: !!(Nas.local.saves?.on)
			onToggled: on => Nas.setLocal("saves", Object.assign({}, Nas.local.saves ?? {}, { on: on }))
		}

		Repeater {
			model: root.games.slice(0, 30)

			delegate: ListItem {
				id: game

				required property var modelData
				readonly property string name: String(game.modelData.name ?? game.modelData)

				Layout.fillWidth: true
				icon: "gamepad_variant"
				title: game.name
				subtitle: "On the NAS"

				TextButton {
					text: "Restore"
					variant: "ghost"
					confirm: true
					confirmText: "Overwrite the saves here?"
					onActivated: Nas.saves("restore", game.name)
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "Back up saves now"
				icon: "content_save_outline"
				onActivated: Nas.saves("backup", "")
			}
		}
	}

	// ── devices ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-devices"
		title: "Devices"
		subtitle: Netcore.online ? "Wake one from here; what each may do is kept by pshell-core" : "Who may use the NAS; wake one from here"
		icon: "devices"

		Line {
			visible: Netcore.online
			text: "Devices are kept by pshell-core"
			hint: "Renaming, what each may do, new tokens and revoking – for the NAS and every other service – are on the Server page"

			TextButton {
				text: "Server page"
				icon: "server"
				onActivated: Netcore.openSettings()
			}
		}

		Repeater {
			model: Nas.devices

			delegate: ListItem {
				id: device

				required property var modelData

				Layout.fillWidth: true
				icon: ({ phone: "cellphone", laptop: "laptop", pc: "monitor" })[device.modelData.kind] ?? "devices"
				title: String(device.modelData.name ?? device.modelData.id)
				subtitle: [String(device.modelData.kind ?? ""), (device.modelData.caps ?? []).join(", "), device.modelData.last_seen ? `seen ${Nas.ago(device.modelData.last_seen)}` : ""].filter(s => s).join(" · ")

				TextButton {
					visible: !!device.modelData.mac
					text: "Wake"
					icon: "power"
					variant: "ghost"
					onActivated: Nas.wake(device.modelData.id ?? device.modelData.name)
				}
			}
		}

		Note {
			visible: Nas.devices.length === 0
			text: Nas.online ? "The daemon did not list the devices" : "Shown once the NAS is reachable"
		}

		Line {
			text: "Add a laptop or a phone"
			hint: "Makes a token for it; the phone gets its own through the phone link by itself"

			Field {
				id: deviceName

				implicitWidth: 180
				placeholder: "Name"
			}

			Segmented {
				id: deviceKind

				implicitWidth: 170
				options: [{ value: "laptop", label: "Laptop" }, { value: "phone", label: "Phone" }]
				current: "laptop"
				onSelected: value => deviceKind.current = value
			}

			TextButton {
				text: "Make token"
				icon: "key_variant"
				variant: "filled"
				enabled: deviceName.text.trim() !== "" && Nas.online
				onActivated: Nas.mint(deviceName.text.trim(), deviceKind.current, (data, error) => {
					if (error) return;
					root.minted = data;
					deviceName.text = "";
					Nas.loadDevices();
				})
			}
		}

		Rectangle {
			Layout.fillWidth: true
			visible: root.minted !== null
			implicitHeight: mintColumn.implicitHeight + 24
			radius: Theme.radius.large
			color: Theme.primaryContainer

			ColumnLayout {
				id: mintColumn

				x: 12
				y: 12
				width: parent.width - 24
				spacing: 6

				StyledText {
					Layout.fillWidth: true
					text: "Shown once – put it into the device now"
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.minted ? `device ${root.minted.id}\ntoken ${root.minted.token}\nserver ${root.minted.server_id}\n${Object.entries(root.minted.addresses ?? {}).map(([k, v]) => `${k} ${v}`).join("\n")}` : ""
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.small
					wrapMode: Text.WrapAnywhere
				}

				RowLayout {
					Layout.fillWidth: true

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						text: "Copy as JSON"
						icon: "content_copy"
						onActivated: Quickshell.execDetached(["wl-copy", "--", JSON.stringify(root.minted)])
					}

					TextButton {
						text: "Done"
						variant: "ghost"
						onActivated: root.minted = null
					}
				}
			}
		}
	}

	// ── what else goes to the NAS ────────────────────────────────────────
	SettingCard {
		anchor: "nas-more"
		title: "What else goes there"
		subtitle: "Downloads, the shelves, what you watch, the phone's photos"
		icon: "cloud_upload"

		FlagRow {
			Layout.fillWidth: true
			visible: Plugins.on("downloads")
			title: "Finished downloads go to the NAS"
			subtitle: `Into ${Nas.downloadsFolder}`
			icon: "download"
			checked: Nas.downloadsToNas
			onToggled: on => Nas.setLocal("downloads_to_nas", on)
		}

		FlagRow {
			Layout.fillWidth: true
			visible: Plugins.on("torrents")
			title: "Finished torrents go to the NAS"
			subtitle: `A copy into ${String(Nas.localOf("torrents_folder", Nas.downloadsFolder))}; they keep seeding from here`
			icon: "download_outline"
			checked: Nas.torrentsToNas
			onToggled: on => Nas.setLocal("torrents_to_nas", on)
		}

		Line {
			visible: Plugins.on("downloads") || Plugins.on("torrents")
			text: "Folder on the NAS for them"

			Field {
				id: downloadsFolder

				implicitWidth: 240
				text: Nas.downloadsFolder
				onAccepted: if (downloadsFolder.text.trim().startsWith("/")) Nas.setLocal("downloads_folder", downloadsFolder.text.trim())
			}
		}

		FlagRow {
			Layout.fillWidth: true
			visible: Plugins.on("shelves")
			title: "Sync the shelves"
			subtitle: "Files put on a shelf go to /Shelf; what other devices put there shows up on a shelf here"
			icon: "tray_full"
			checked: !!Nas.localOf("shelf_sync", false)
			onToggled: on => Nas.setLocal("shelf_sync", on)
		}

		FlagRow {
			Layout.fillWidth: true
			visible: Plugins.on("streams")
			title: "Share how far you watched"
			subtitle: "Streams: what was watched on the laptop counts here too"
			icon: "play"
			checked: !!Nas.localOf("streams_sync", false)
			onToggled: on => Nas.setLocal("streams_sync", on)
		}

		Head {
			text: "The phone's photos"
		}

		Note {
			text: "Set on the phone itself: NAS › Photo upload (Wi-Fi only, while charging, offer to delete after upload). It uploads straight to the NAS, also while this PC is off."
		}
	}

	// ── Baikal ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "nas-calendar"
		visible: Plugins.on("nas-calendar")
		title: "Baikal calendar"
		subtitle: NasCalendar.error !== "" ? NasCalendar.error : (NasCalendar.active ? (NasCalendar.calendars.length > 0 ? `${NasCalendar.calendars.map(c => c.name).join(", ")} – in the calendar beside Microsoft` : "Connected") : "CalDAV on netcore; its events show in the calendar")
		icon: "calendar_month"

		Line {
			text: "Address"

			Field {
				id: calUrl

				implicitWidth: 340
				text: NasCalendar.url
				onAccepted: NasCalendar.setAccount(calUrl.text, calUser.text)
			}
		}

		Line {
			text: "User"

			Field {
				id: calUser

				implicitWidth: 340
				text: NasCalendar.user
				onAccepted: NasCalendar.setAccount(calUrl.text, calUser.text)
			}
		}

		Line {
			text: "Password"
			hint: NasCalendar.hasPassword ? "In the keyring" : "Kept in the keyring (secret-tool), never in a file"

			Field {
				id: calPassword

				implicitWidth: 340
				password: true
				placeholder: NasCalendar.hasPassword ? "••••••  (Enter a new one to change it)" : "Password, Enter"
				onAccepted: {
					if (calUrl.text !== NasCalendar.url || calUser.text !== NasCalendar.user) NasCalendar.setAccount(calUrl.text, calUser.text);
					const password = calPassword.text;
					calPassword.text = "";
					Qt.callLater(() => NasCalendar.setPassword(password, error => {
						if (error) Notifs.pushInternal("error", "Baikal", error, { app: "NAS" });
					}));
				}
			}
		}

		Head {
			visible: NasCalendar.active
			text: "Calendars"
		}

		Line {
			visible: NasCalendar.coreNeedsPassword
			text: "For pshell-core"

			Field {
				id: corePassword

				implicitWidth: 340
				password: true
				placeholder: "Baikal password, Enter"
				onAccepted: {
					const password = corePassword.text;
					corePassword.text = "";
					NasCalendar.giveCorePassword(password, error => {
						if (error) Notifs.pushInternal("error", "Baikal", error, { app: "NAS" });
					});
				}
			}
		}

		Repeater {
			model: NasCalendar.active ? NasCalendar.calendars : []

			delegate: ColumnLayout {
				id: calRow

				required property var modelData
				readonly property bool mine: calRow.modelData.access === "" || calRow.modelData.access === "owner"
				readonly property var share: NasCalendar.shares[calRow.modelData.href] ?? null
				// on the page: the list is made anew after every change
				readonly property bool sharing: root.sharingCalendar === calRow.modelData.href

				Layout.fillWidth: true
				spacing: 6

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					ColorWell {
						value: calRow.modelData.color !== "" ? calRow.modelData.color : Theme.secondary
						alpha: false
						showHex: false
						size: 22
						onPicked: css => NasCalendar.changeCalendar(calRow.modelData.href, { color: css })
					}

					Field {
						Layout.fillWidth: true
						text: calRow.modelData.name
						clearable: false
						onAccepted: if (text.trim() !== "" && text.trim() !== calRow.modelData.name) NasCalendar.changeCalendar(calRow.modelData.href, { name: text.trim() })
					}

					StyledText {
						visible: !calRow.mine
						text: calRow.modelData.access === "read" ? "Shared with you · read" : "Shared with you"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}

					StyledText {
						visible: calRow.mine && (calRow.share?.sharees.length ?? 0) > 0
						text: `Shared · ${calRow.share?.sharees.length ?? 0}`
						tone: Theme.primary
						font.pixelSize: Theme.size.small
					}

					IconButton {
						visible: calRow.mine && Netcore.active
						implicitWidth: 30
						implicitHeight: 30
						icon: "account_multiple_plus"
						onClicked: {
							root.sharingCalendar = calRow.sharing ? "" : calRow.modelData.href;
							if (calRow.sharing) {
								NasCalendar.loadMembers();
								NasCalendar.loadShares(calRow.modelData.href);
							}
						}
					}

					TextButton {
						text: calRow.mine ? "Delete" : "Leave"
						icon: calRow.mine ? "delete_outline" : "logout"
						variant: "ghost"
						confirm: true
						confirmText: calRow.mine ? "With all events?" : "Sure?"
						onActivated: NasCalendar.deleteCalendar(calRow.modelData.href)
					}
				}

				// who of core's members has it
				Repeater {
					model: calRow.sharing ? NasCalendar.members : []

					delegate: RowLayout {
						id: memberRow

						required property var modelData
						readonly property var entry: (calRow.share?.sharees ?? []).find(s => s.email.toLowerCase() === String(memberRow.modelData.email).toLowerCase()) ?? null

						Layout.fillWidth: true
						Layout.leftMargin: 34
						spacing: 8

						Glyph {
							icon: "account_outline"
							size: 16
							color: Theme.textMuted
						}

						StyledText {
							Layout.fillWidth: true
							text: memberRow.modelData.display || memberRow.modelData.name
						}

						Segmented {
							implicitWidth: 240
							implicitHeight: 30
							options: [{ value: "", label: "No" }, { value: "read", label: "Read" }, { value: "write", label: "Read & write" }]
							current: memberRow.entry ? (memberRow.entry.write ? "write" : "read") : ""
							onSelected: value => NasCalendar.share(calRow.modelData.href, memberRow.modelData, value)
						}
					}
				}

				StyledText {
					visible: calRow.sharing && NasCalendar.members.length === 0
					Layout.leftMargin: 34
					text: "No other members in pshell-core"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}

		RowLayout {
			visible: NasCalendar.active
			Layout.fillWidth: true
			spacing: 8

			ColorWell {
				id: newCalColor

				value: "#4f8ef7"
				alpha: false
				showHex: false
				size: 22
				onPicked: css => newCalColor.value = css
			}

			Field {
				id: newCalName

				Layout.fillWidth: true
				placeholder: "New calendar"
				onAccepted: newCalAdd.activated()
			}

			TextButton {
				id: newCalAdd

				text: "Add"
				icon: "plus"
				enabled: newCalName.text.trim() !== ""
				onActivated: {
					if (newCalName.text.trim() === "") return;
					NasCalendar.createCalendar(newCalName.text.trim(), newCalColor.value, reply => {
						if (!reply.error) newCalName.text = "";
					});
				}
			}
		}

		Head {
			visible: NasCalendar.active
			text: "Tasks"
		}

		FlagRow {
			visible: NasCalendar.active
			title: "Tasks.md with Baikal"
			subtitle: BaikalTodos.error !== "" ? BaikalTodos.error : (BaikalTodos.syncedAt > 0 ? `Synced ${Qt.formatTime(new Date(BaikalTodos.syncedAt), "HH:mm")}` : "")
			icon: "checkbox_marked_circle_outline"
			checked: !!BaikalTodos.settings.on
			onToggled: on => BaikalTodos.setTodos({ on: on })
		}

		Flow {
			visible: NasCalendar.active && !!BaikalTodos.settings.on && NasCalendar.writable.length > 1
			Layout.fillWidth: true
			Layout.leftMargin: 34
			spacing: 6

			Repeater {
				model: NasCalendar.writable

				delegate: Chip {
					required property var modelData

					text: modelData.name
					icon: "circle"
					accent: modelData.color !== "" ? modelData.color : Theme.secondary
					selected: BaikalTodos.calendar === modelData.href
					onClicked: BaikalTodos.setTodos({ calendar: modelData.href })
				}
			}
		}

		Line {
			visible: NasCalendar.active && Netcore.active
			text: "Copies"

			StyledText {
				text: NasCalendar.copy.error ? NasCalendar.copy.error : (NasCalendar.copy.kept ? `${String(NasCalendar.copy.kept).slice(3, 11).replace(/(\d{4})(\d{2})(\d{2})/, "$3.$2.$1")} · ${NasCalendar.copy.count} on this PC` : "–")
				tone: NasCalendar.copy.error ? Theme.danger : Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		RowLayout {
			Layout.fillWidth: true

			Spinner {
				visible: NasCalendar.loading
				Layout.preferredWidth: 14
				Layout.preferredHeight: 14
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "Load again"
				icon: "refresh"
				enabled: NasCalendar.active
				onActivated: NasCalendar.refresh()
			}
		}
	}
}
