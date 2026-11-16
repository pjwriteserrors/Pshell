package dev.pshell.app.nas

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dev.pshell.app.features.Feature
import dev.pshell.app.features.Group
import dev.pshell.app.features.bytesSaid
import dev.pshell.app.features.fileIcon
import dev.pshell.app.features.whenSaid
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.LocalApp
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.connected
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.pressable
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import java.io.IOException

// ── the features: a tab of their own ───────────────────────────────────────
val NasFeature = Feature(
	id = "nas",
	plugins = listOf("nas"),
	title = "Files",
	icon = "nas",
	group = Group.Nas,
	keywords = listOf("nas", "netcore", "server", "files", "dateien", "folders", "ordner", "offline", "pins", "upload", "trash", "papierkorb", "wake", "wecken"),
	screen = { NasScreen() },
	page = { arg -> NasPage(arg) },
)

val NasPhotosFeature = Feature(
	id = "nas-photos",
	plugins = listOf("nas"),
	title = "Photo upload",
	icon = "cloud_upload_outline",
	group = Group.Nas,
	keywords = listOf("photos", "fotos", "bilder", "camera", "kamera", "backup", "sicherung", "auto upload", "nas"),
	screen = { PhotosScreen() },
)

val NasMusicFeature = Feature(
	id = "nas-music",
	plugins = listOf("nas"),
	title = "Music",
	icon = "music_box_multiple",
	group = Group.Nas,
	keywords = listOf("music", "musik", "songs", "lieder", "nas", "player"),
	screen = { MusicScreen() },
)

// ── helpers ─────────────────────────────────────────────────────────────────
fun parentOf(path: String): String = path.trimEnd('/').substringBeforeLast('/', "").ifEmpty { "/" }

/** The NAS's mtime, in seconds whatever it sends. */
private fun seconds(value: Long) = if (value > 100_000_000_000L) value / 1000 else value

private fun said(entry: JsonElement, where: Boolean): String = listOf(
	if (where) parentOf(entry["path"].string) else "",
	if (entry["dir"].bool) "" else bytesSaid(entry["size"].long),
	whenSaid(seconds(entry["mtime"].long)),
).filter { it.isNotEmpty() }.joinToString(" · ")

private fun kindOf(entry: JsonElement): String = entry["kind"].string.ifEmpty {
	when (entry["name"].string.substringAfterLast('.', "").lowercase()) {
		"png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "avif", "bmp" -> "image"
		"mp4", "mkv", "webm", "mov", "avi", "m4v" -> "video"
		"mp3", "flac", "ogg", "opus", "wav", "m4a", "aac" -> "audio"
		"pdf" -> "pdf"
		else -> "other"
	}
}

private fun hasThumb(entry: JsonElement) = !entry["dir"].bool && (entry["thumb"].bool || kindOf(entry) in setOf("image", "video", "pdf", "audio"))

private fun iconOf(entry: JsonElement): String = when {
	entry["vault"].bool -> "folder_lock_outline"
	entry["dir"].bool -> "folder"
	else -> when (kindOf(entry)) {
		"image" -> "file_image_outline"
		"video" -> "file_video_outline"
		"audio" -> "file_music_outline"
		"pdf" -> "file_pdf_box"
		else -> fileIcon(entry["name"].string)
	}
}

/** The file's thumbnail on its icon; the icon stays where the NAS has none (yet). */
@Composable
private fun Thumb(entry: JsonElement, size: Dp, radius: Dp = 12.dp, modifier: Modifier = Modifier) {
	val dir = entry["dir"].bool
	Box(
		modifier.size(size).clip(RoundedCornerShape(radius)).background(if (dir) Theme.colors.primaryContainer else Theme.colors.layer3),
		contentAlignment = Alignment.Center,
	) {
		Glyph(iconOf(entry), size = if (size > 60.dp) 34.dp else 20.dp, color = if (dir) Theme.colors.primary else Theme.colors.text)
		if (hasThumb(entry)) {
			// a thumbnail the NAS has not made yet (404, queued) is asked for again a little later
			val context = LocalContext.current
			val url = Nas.thumbUrl(entry["path"].string, if (size > 60.dp) 1024 else 256)
			var attempt by remember(url) { mutableIntStateOf(0) }
			val later = rememberCoroutineScope()
			val request = remember(url, attempt) {
				coil3.request.ImageRequest.Builder(context).data(if (attempt == 0) url else "$url&again=$attempt").memoryCacheKey(url).diskCacheKey(url).build()
			}
			AsyncImage(
				model = request,
				contentDescription = null,
				imageLoader = Nas.images,
				contentScale = ContentScale.Crop,
				modifier = Modifier.fillMaxSize(),
				onError = { if (attempt < 4) later.launch { kotlinx.coroutines.delay(5000L * (attempt + 1)); attempt += 1 } },
			)
		}
	}
}

@Composable
private fun EntryRow(entry: JsonElement, where: Boolean, onLongClick: () -> Unit, onClick: () -> Unit) {
	val pins by Pins.pinned.collectAsState()
	val path = entry["path"].string
	Row(
		Modifier.fillMaxWidth()
			.pressable(shape = RoundedCornerShape(Theme.Radius.huge), pressedScale = 0.985f, onLongClick = onLongClick, onClick = onClick)
			.padding(horizontal = 8.dp, vertical = 8.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Thumb(entry, 44.dp)
		Spacer(Modifier.width(12.dp))
		Column(Modifier.weight(1f)) {
			Label(entry["name"].string, style = Theme.Type.body.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold))
			val subtitle = said(entry, where)
			if (subtitle.isNotEmpty()) Label(subtitle, style = Theme.Type.small, color = Theme.colors.textMuted)
		}
		if (path in pins) Glyph("pin", size = 16.dp, color = Theme.colors.primary)
		if (entry["dir"].bool) Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
	}
}

@Composable
private fun EntryTile(entry: JsonElement, onLongClick: () -> Unit, onClick: () -> Unit) {
	Column(Modifier.fillMaxWidth().pressable(shape = RoundedCornerShape(Theme.Radius.large), pressedScale = 0.96f, onLongClick = onLongClick, onClick = onClick).padding(4.dp)) {
		Box(Modifier.fillMaxWidth().aspectRatio(1f)) {
			Thumb(entry, 400.dp, radius = Theme.Radius.large, modifier = Modifier.fillMaxSize())
		}
		Label(entry["name"].string, Modifier.padding(start = 4.dp, top = 4.dp, end = 4.dp), style = Theme.Type.small)
	}
}

/** Where one is on the NAS, a chip per folder. */
@Composable
private fun Crumbs(path: String, onPick: (String) -> Unit) {
	val scroll = rememberScrollState()
	LaunchedEffect(path, scroll.maxValue) { scroll.scrollTo(scroll.maxValue) }
	val parts = path.split('/').filter { it.isNotEmpty() }
	Row(Modifier.fillMaxWidth().horizontalScroll(scroll), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
		Chip("NAS", icon = "nas", active = parts.isEmpty()) { onPick("/") }
		var walked = ""
		for ((index, part) in parts.withIndex()) {
			walked = "$walked/$part"
			val target = walked
			Chip(part, active = index == parts.lastIndex) { onPick(target) }
		}
	}
}

/** Home or VPN, or why not at all. */
@Composable
private fun Reach(onRetry: () -> Unit) {
	val via by Nas.via.collectAsState()
	val base by Nas.base.collectAsState()
	when {
		base != null -> Chip(if (via == "home") "At home" else "Through the VPN", icon = if (via == "home") "home_outline" else "vpn")
		else -> Chip("Offline", icon = "cloud_off_outline", tint = Theme.colors.warning, onClick = onRetry)
	}
}

/** What runs: uploads from the phone into the NAS. */
@Composable
private fun UploadsPanel() {
	val uploads by Uploads.active.collectAsState()
	if (uploads.isEmpty()) return
	Panel {
		for (upload in uploads) {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Glyph(if (upload.error.isEmpty()) "upload" else "alert_circle_outline", size = 18.dp, color = if (upload.error.isEmpty()) Theme.colors.text else Theme.colors.danger)
				Spacer(Modifier.width(8.dp))
				Label(upload.name, Modifier.weight(1f), style = Theme.Type.small)
				Label(if (upload.error.isNotEmpty()) upload.error else "${bytesSaid(upload.done)} / ${bytesSaid(upload.size)}", style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			if (upload.error.isEmpty()) Meter(if (upload.size > 0) upload.done.toFloat() / upload.size else 0f, Modifier.fillMaxWidth().padding(top = 6.dp, bottom = 6.dp))
		}
	}
}

// ── the files ───────────────────────────────────────────────────────────────
@Composable
private fun NasScreen() {
	val app = LocalApp.current
	val nav = LocalNav.current
	val context = LocalContext.current
	val scope = rememberCoroutineScope()
	val account by Nas.account.collectAsState()
	val base by Nas.base.collectAsState()
	val problem by Nas.problem.collectAsState()
	val changed by Nas.changed.collectAsState()
	val pins by Pins.pinned.collectAsState()
	val grid by app.prefs.nasGrid.flow.collectAsState()
	var path by rememberSaveable { mutableStateOf("/") }
	var query by rememberSaveable { mutableStateOf("") }
	var asked by rememberSaveable { mutableStateOf("") }
	var entries by remember { mutableStateOf<List<JsonElement>?>(null) }
	var error by remember { mutableStateOf("") }
	var version by remember { mutableIntStateOf(0) }
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	var waking by remember { mutableStateOf(false) }
	var naming by remember { mutableStateOf(false) }
	var showPins by rememberSaveable { mutableStateOf(false) }
	val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
		if (uris.isNotEmpty()) Uploads.start(context, uris, path)
	}
	LaunchedEffect(account, path, asked, version, changed) {
		if (account == null) return@LaunchedEffect
		error = ""
		try {
			entries = if (asked.isNotEmpty()) Nas.search(asked, path = path.takeIf { it != "/" }.orEmpty()) else Nas.list(path)
		} catch (failure: IOException) {
			error = failure.message ?: "The NAS did not answer"
		}
	}
	val go = { target: String ->
		if (target != path || asked.isNotEmpty()) entries = null
		path = target
		query = ""
		asked = ""
		showPins = false
	}
	BackHandler(enabled = asked.isNotEmpty() || path != "/" || showPins) {
		when {
			showPins -> showPins = false
			asked.isNotEmpty() -> go(path)
			else -> go(parentOf(path))
		}
	}
	val open = { entry: JsonElement ->
		val target = entry["path"].string
		when {
			entry["dir"].bool -> go(target)
			kindOf(entry) == "image" -> nav.open("feature/nas/${Uri.encode("view:$target")}")
			kindOf(entry) == "video" -> nav.open("feature/nas/${Uri.encode("play:$target")}")
			kindOf(entry) == "audio" -> {
				val songs = entries.orEmpty().filter { !it["dir"].bool && kindOf(it) == "audio" }.map { it["path"].string }
				Music.play(context, songs, songs.indexOf(target).coerceAtLeast(0))
				link_toast(app, "Playing ${entry["name"].string}")
			}
			else -> scope.launch { openExternally(app, target) }
		}
	}
	Screen("NAS", scroll = false, actions = {
		IconButton(if (grid) "view_list" else "view_grid", color = Theme.colors.layer2) { app.prefs.nasGrid.value = !grid }
		Spacer(Modifier.width(6.dp))
		IconButton("folder_plus_outline", color = Theme.colors.layer2) { naming = true }
	}) {
		if (account == null) {
			EmptyState("nas", "No NAS yet", text = problem.ifEmpty { "This phone gets its key to the NAS from the PC. Connect to the PC once – the PC needs the NAS set up." }, action = {
				SoftButton("Ask the PC", icon = "refresh") { scope.launch { if (!Nas.ask()) app.link.toast(Nas.problem.value.ifEmpty { "The PC gave no token" }) } }
			})
			return@Screen
		}
		Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically, modifier = Modifier.horizontalScroll(rememberScrollState())) {
			Reach { scope.launch { Nas.base.value = null; Nas.resolve(); version += 1 } }
			if (pins.isNotEmpty()) Chip("Offline ${pins.size}", icon = "pin_outline", active = showPins) { showPins = !showPins }
			Chip("Upload", icon = "upload") { picker.launch(arrayOf("*/*")) }
			Chip("Wake PC", icon = "power") { waking = true }
			Chip("Trash", icon = "trash_can_outline") { nav.open("feature/nas/trash") }
		}
		if (!showPins) {
			Crumbs(path) { go(it) }
			Field(query, placeholder = "Search the NAS", icon = "magnify", action = ImeAction.Search, onSubmit = {
				if (query.trim() != asked) entries = null
				asked = query.trim()
			}, trailing = {
				if (query.isNotEmpty()) IconButton("close", size = 36.dp, iconSize = 18.dp) { go(path) }
			}) { query = it }
		}
		UploadsPanel()
		val shown = if (showPins) pins.values.sortedBy { it.path.lowercase() }.map { json("name" to it.path.substringAfterLast('/'), "path" to it.path, "size" to it.size, "mtime" to it.mtime, "dir" to false) } else entries
		LaunchedEffect(showPins) { if (showPins) Pins.syncAll() }
		when {
			!showPins && error.isNotEmpty() -> EmptyState("cloud_off_outline", if (base == null) "The NAS is not reachable" else "Could not list the files", text = error, action = {
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					SoftButton("Try again", icon = "refresh") { Nas.base.value = null; version += 1 }
					if (pins.isNotEmpty()) SoftButton("Offline files", icon = "pin_outline") { showPins = true }
				}
			})
			shown == null -> EmptyState(if (asked.isNotEmpty()) "file_search_outline" else "folder_outline", if (asked.isNotEmpty()) "Searching…" else "Loading…")
			shown.isEmpty() -> EmptyState(if (asked.isNotEmpty()) "file_search_outline" else "folder_open_outline", if (asked.isNotEmpty()) "Nothing found" else "Empty folder")
			grid -> LazyVerticalGrid(GridCells.Adaptive(108.dp), Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = BottomSpace)) {
				items(shown, key = { it["path"].string }) { entry -> EntryTile(entry, onLongClick = { chosen = entry }) { if (showPins) chosen = entry else open(entry) } }
			}
			else -> LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = BottomSpace)) {
				items(shown, key = { it["path"].string }) { entry ->
					EntryRow(entry, where = asked.isNotEmpty() || showPins, onLongClick = { chosen = entry }) { if (showPins) chosen = entry else open(entry) }
				}
			}
		}
	}
	chosen?.let { entry -> EntrySheet(entry, onOpen = { open(entry) }) { chosen = null } }
	if (waking) WakeSheet { waking = false }
	if (naming) FolderSheet(path, onReload = { version += 1 }) { naming = false }
}

private fun link_toast(app: dev.pshell.app.App, text: String) = app.link.toast(text)

/** Anything the app does not show itself opens in another app, from a local copy. */
private suspend fun openExternally(app: dev.pshell.app.App, path: String) {
	app.link.toast("Opening ${path.substringAfterLast('/')}…")
	try {
		Nas.openWith(Nas.local(path))
	} catch (error: Exception) {
		app.link.toast(error.message ?: "Could not open it")
	}
}

/** What can be done with one file or folder. */
@Composable
private fun EntrySheet(entry: JsonElement, onOpen: () -> Unit, onDismiss: () -> Unit) {
	val app = LocalApp.current
	val link = link
	val pcConnected = connected()
	val scope = rememberCoroutineScope()
	val pins by Pins.pinned.collectAsState()
	val busy by Pins.busy.collectAsState()
	val path = entry["path"].string
	val dir = entry["dir"].bool
	var deleting by remember { mutableStateOf(false) }
	Sheet(onDismiss, entry["name"].string) { close ->
		Label(listOf(parentOf(path), said(entry, false)).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
		PrimaryButton(if (dir) "Open" else "Open here", Modifier.fillMaxWidth(), icon = if (dir) "folder_open" else "open_in_app") { close(); onOpen() }
		if (!dir) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			SoftButton("Download", Modifier.weight(1f).padding(vertical = 4.dp), icon = "download") {
				close()
				scope.launch {
					app.link.toast("Downloading ${entry["name"].string}")
					try {
						app.link.toast("Saved to ${Nas.saveToDownloads(path)}")
					} catch (error: Exception) {
						app.link.toast(error.message ?: "Download failed")
					}
				}
			}
			SoftButton("Share", Modifier.weight(1f).padding(vertical = 4.dp), icon = "share_variant") {
				close()
				Nas.scope.launch {
					try {
						Nas.share(Nas.local(path))
					} catch (error: Exception) {
						app.link.toast(error.message ?: "Could not fetch it")
					}
				}
			}
		}
		if (!dir) {
			val pinned = path in pins
			SoftButton(
				when {
					path in busy -> "Keeping it on the phone…"
					pinned -> "Remove from the phone"
					else -> "Keep on the phone (offline)"
				},
				Modifier.fillMaxWidth().padding(vertical = 4.dp), icon = if (pinned) "pin_off_outline" else "pin_outline",
			) {
				if (pinned) Pins.unpin(path)
				else Nas.scope.launch {
					try {
						Pins.pin(entry)
						app.link.toast("${entry["name"].string} is on the phone")
					} catch (error: Exception) {
						app.link.toast(error.message ?: "Could not fetch it")
					}
				}
			}
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			if (pcConnected) SoftButton("Open on PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "monitor") {
				close()
				scope.launch {
					try {
						link.call("nas", "open", json("path" to path), timeoutSeconds = 20)
						app.link.toast("Opened on the PC")
					} catch (failure: LinkError) {
						app.link.toast(link.describe(failure))
					}
				}
			}
			SoftButton("To the trash", Modifier.weight(1f).padding(vertical = 4.dp), icon = "trash_can_outline", tint = Theme.colors.danger) { deleting = true }
		}
	}
	if (deleting) Confirm("Move to the trash?", "${entry["name"].string} goes to the NAS's trash; it can be restored from there for a while.", confirm = "To the trash", danger = true, onDismiss = { deleting = false }) {
		scope.launch {
			try {
				Nas.delete(listOf(path))
				Pins.unpin(path)
				onDismiss()
			} catch (error: IOException) {
				app.link.toast(error.message ?: "Could not delete it")
			}
		}
	}
}

/** A new folder here. */
@Composable
private fun FolderSheet(path: String, onReload: () -> Unit, onDismiss: () -> Unit) {
	val app = LocalApp.current
	val scope = rememberCoroutineScope()
	var name by remember { mutableStateOf("") }
	Sheet(onDismiss, "New folder") { close ->
		Label("In ${if (path == "/") "the NAS" else path}", style = Theme.Type.small, color = Theme.colors.textMuted)
		Field(name, placeholder = "Name", icon = "folder_plus_outline", onSubmit = null) { name = it.replace("/", "") }
		PrimaryButton("Make it", Modifier.fillMaxWidth(), enabled = name.isNotBlank()) {
			scope.launch {
				try {
					Nas.mkdir(path.trimEnd('/') + "/" + name.trim())
					onReload()
					close()
				} catch (error: IOException) {
					app.link.toast(error.message ?: "Could not make it")
				}
			}
		}
	}
}

/** The PCs and laptops the NAS knows, to wake from here (also away from home). */
@Composable
private fun WakeSheet(onDismiss: () -> Unit) {
	val app = LocalApp.current
	val scope = rememberCoroutineScope()
	var devices by remember { mutableStateOf<List<JsonElement>?>(null) }
	var error by remember { mutableStateOf("") }
	LaunchedEffect(Unit) {
		try {
			devices = Nas.wakeable()
		} catch (failure: IOException) {
			error = if (failure is NasError && failure.status == 403) "The NAS does not let this phone see its devices" else failure.message ?: "The NAS did not answer"
		}
	}
	Sheet(onDismiss, "Wake a PC") { close ->
		Label("The NAS sends the magic packet in the home network – it works from anywhere.", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 3)
		when {
			error.isNotEmpty() -> Label(error, color = Theme.colors.danger, maxLines = 3)
			devices == null -> Label("Asking the NAS…", color = Theme.colors.textMuted)
			devices!!.isEmpty() -> Label("The NAS knows no PC with a network address to wake", color = Theme.colors.textMuted, maxLines = 2)
			else -> for (device in devices!!) {
				ListRow(device["name"].string, icon = if (device["kind"].string == "laptop") "laptop" else "desktop_tower_monitor", subtitle = device["last_seen"].long.let { if (it > 0) "Last seen ${whenSaid(seconds(it))}" else "" }, onClick = {
					scope.launch {
						try {
							Nas.wake(device["id"].string)
							app.link.toast("Waking ${device["name"].string}")
							close()
						} catch (failure: IOException) {
							app.link.toast(if (failure is NasError && failure.status == 403) "The NAS does not let this phone wake devices" else failure.message ?: "Could not wake it")
						}
					}
				}) { Glyph("power", size = 20.dp, color = Theme.colors.primary) }
			}
		}
	}
}

// ── pages: a picture, a video, the trash ───────────────────────────────────
@Composable
private fun NasPage(arg: String) {
	when {
		arg.startsWith("view:") -> ImageViewer(arg.removePrefix("view:"))
		arg.startsWith("play:") -> VideoPlayer(arg.removePrefix("play:"))
		arg == "trash" -> TrashScreen()
		else -> Screen("NAS") { EmptyState("help_circle_outline", "Nothing here") }
	}
}

@Composable
private fun TrashScreen() {
	val app = LocalApp.current
	val scope = rememberCoroutineScope()
	var items by remember { mutableStateOf<List<JsonElement>?>(null) }
	var error by remember { mutableStateOf("") }
	var version by remember { mutableIntStateOf(0) }
	LaunchedEffect(version) {
		try {
			items = Nas.trash()
			error = ""
		} catch (failure: IOException) {
			error = failure.message ?: "The NAS did not answer"
		}
	}
	Screen("Trash", subtitle = "Deleted on the NAS, kept for a while", scroll = false) {
		when {
			error.isNotEmpty() -> EmptyState("cloud_off_outline", "Could not read the trash", text = error, action = { SoftButton("Try again", icon = "refresh") { version += 1 } })
			items == null -> EmptyState("trash_can_outline", "Loading…")
			items!!.isEmpty() -> EmptyState("trash_can_outline", "The trash is empty")
			else -> LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = BottomSpace)) {
				items(items!!, key = { it["id"].string }) { item ->
					ListRow(
						item["name"].string.ifEmpty { item["path"].string.substringAfterLast('/') },
						icon = fileIcon(item["name"].string),
						subtitle = listOf(parentOf(item["path"].string), bytesSaid(item["size"].long), whenSaid(seconds(item["deleted"].long)), item["by"].string).filter { it.isNotEmpty() }.joinToString(" · "),
					) {
						IconButton("delete_restore", color = Theme.colors.layer2) {
							scope.launch {
								try {
									Nas.restore(listOf(item["id"].string))
									app.link.toast("Restored to ${item["path"].string}")
									version += 1
								} catch (failure: IOException) {
									app.link.toast(failure.message ?: "Could not restore it")
								}
							}
						}
					}
				}
			}
		}
	}
}

/** Uploads from the phone into a NAS folder (the screen's Upload), with their progress. */
object Uploads {
	data class Upload(val id: Int, val name: String, val size: Long, val done: Long = 0, val error: String = "")

	val active = kotlinx.coroutines.flow.MutableStateFlow<List<Upload>>(emptyList())
	private var count = 0

	private fun update(id: Int, change: (Upload) -> Upload?) {
		active.value = active.value.mapNotNull { if (it.id == id) change(it) else it }
	}

	fun start(context: android.content.Context, uris: List<Uri>, folder: String) {
		val resolver = context.contentResolver
		for (uri in uris) {
			var name = "file"
			var size = -1L
			resolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE), null, null, null)?.use {
				if (it.moveToFirst()) {
					name = it.getString(0) ?: name
					size = if (it.isNull(1)) -1 else it.getLong(1)
				}
			}
			if (size < 0) size = runCatching { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1
			val id = ++count
			active.value += Upload(id, name, size.coerceAtLeast(0))
			Nas.scope.launch {
				try {
					if (size < 0) throw IOException("The size of $name is unknown")
					Nas.upload({ resolver.openInputStream(uri) ?: throw IOException("$name is gone") }, size, folder.trimEnd('/') + "/" + name.replace('/', '_'), conflict = "rename") { done ->
						update(id) { it.copy(done = done) }
					}
					update(id) { null }
					dev.pshell.app.App.instance.link.toast("$name is on the NAS")
				} catch (error: Exception) {
					update(id) { it.copy(error = error.message ?: "failed") }
					kotlinx.coroutines.delay(8000)
					update(id) { null }
				}
			}
		}
	}
}
