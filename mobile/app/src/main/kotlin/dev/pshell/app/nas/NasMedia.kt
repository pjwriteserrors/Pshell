package dev.pshell.app.nas

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import dev.pshell.app.features.bytesSaid
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
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import java.io.IOException

private fun isImage(entry: JsonElement) = !entry["dir"].bool && (entry["kind"].string == "image" ||
	entry["kind"].string.isEmpty() && entry["name"].string.substringAfterLast('.', "").lowercase() in setOf("png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "avif", "bmp"))

// ── pictures: swipe through the folder, pinch to zoom ──────────────────────
@Composable
fun ImageViewer(path: String) {
	val app = LocalApp.current
	val nav = LocalNav.current
	val scope = rememberCoroutineScope()
	val pc = connected()
	var images by remember { mutableStateOf(listOf(path)) }
	LaunchedEffect(path) {
		runCatching { Nas.list(parentOf(path)).filter { isImage(it) }.map { it["path"].string } }.getOrNull()?.takeIf { path in it }?.let { images = it }
	}
	val pager = rememberPagerState(initialPage = 0) { images.size }
	LaunchedEffect(images) { pager.scrollToPage(images.indexOf(path).coerceAtLeast(0)) }
	var zoomed by remember { mutableStateOf(false) }
	var chrome by remember { mutableStateOf(true) }
	val current = images.getOrElse(pager.currentPage) { path }
	Box(Modifier.fillMaxSize().background(Color.Black)) {
		HorizontalPager(pager, Modifier.fillMaxSize(), userScrollEnabled = !zoomed, key = { images[it] }) { page ->
			Zoomable(images[page], onZoom = { if (page == pager.currentPage) zoomed = it }, onTap = { chrome = !chrome })
		}
		if (chrome) Row(
			Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.45f)).statusBarsPadding().padding(horizontal = 8.dp, vertical = 8.dp),
			verticalAlignment = Alignment.CenterVertically,
		) {
			IconButton("arrow_left", tint = Color.White) { nav.back() }
			Column(Modifier.weight(1f).padding(horizontal = 6.dp)) {
				Label(current.substringAfterLast('/'), color = Color.White)
				Label("${pager.currentPage + 1} of ${images.size}", style = Theme.Type.small, color = Color.White.copy(alpha = 0.7f))
			}
			IconButton("share_variant", tint = Color.White) {
				Nas.scope.launch { runCatching { Nas.share(Nas.local(current)) }.onFailure { app.link.toast(it.message ?: "Could not fetch it") } }
			}
			IconButton("download", tint = Color.White) {
				scope.launch {
					try {
						app.link.toast("Saved to ${Nas.saveToDownloads(current)}")
					} catch (error: Exception) {
						app.link.toast(error.message ?: "Download failed")
					}
				}
			}
			if (pc) IconButton("monitor", tint = Color.White) {
				scope.launch {
					try {
						app.link.call("nas", "open", json("path" to current), timeoutSeconds = 20)
						app.link.toast("Opened on the PC")
					} catch (failure: LinkError) {
						app.link.toast(app.link.describe(failure))
					}
				}
			}
		}
	}
}

/** One picture: the large thumbnail at once, the file over it; two fingers zoom, a double tap too. */
@Composable
private fun Zoomable(path: String, onZoom: (Boolean) -> Unit, onTap: () -> Unit) {
	var scale by remember { mutableFloatStateOf(1f) }
	var offset by remember { mutableStateOf(Offset.Zero) }
	Box(
		Modifier.fillMaxSize()
			.pointerInput(path) {
				detectTapGestures(onTap = { onTap() }, onDoubleTap = { at ->
					if (scale > 1.01f) {
						scale = 1f
						offset = Offset.Zero
					} else {
						scale = 2.5f
						offset = (Offset(size.width / 2f, size.height / 2f) - at) * 1.5f
					}
					onZoom(scale > 1.01f)
				})
			}
			.pointerInput(path) {
				awaitEachGesture {
					awaitFirstDown(requireUnconsumed = false)
					do {
						val event = awaitPointerEvent()
						val fingers = event.changes.count { it.pressed }
						// one finger at scale 1 belongs to the pager
						if (fingers >= 2 || scale > 1.01f) {
							val zoom = event.calculateZoom()
							val pan = event.calculatePan()
							scale = (scale * zoom).coerceIn(1f, 8f)
							val limit = Offset(size.width * (scale - 1) / 2f, size.height * (scale - 1) / 2f)
							offset = if (scale <= 1.01f) Offset.Zero else Offset((offset.x + pan.x).coerceIn(-limit.x, limit.x), (offset.y + pan.y).coerceIn(-limit.y, limit.y))
							onZoom(scale > 1.01f)
							event.changes.forEach { if (it.positionChanged()) it.consume() }
						}
					} while (event.changes.any { it.pressed })
				}
			}
			.graphicsLayer {
				scaleX = scale
				scaleY = scale
				translationX = offset.x
				translationY = offset.y
			},
	) {
		AsyncImage(Nas.thumbUrl(path, 1024), null, imageLoader = Nas.images, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
		AsyncImage(Nas.fileUrl(path), null, imageLoader = Nas.images, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
	}
}

private fun androidx.compose.ui.input.pointer.PointerInputChange.positionChanged() = position != previousPosition

// ── a video, streamed with the token ──────────────────────────────────────
@OptIn(UnstableApi::class)
@Composable
fun VideoPlayer(path: String) {
	val context = LocalContext.current
	val nav = LocalNav.current
	val player = remember {
		ExoPlayer.Builder(context).build().apply {
			setMediaSource(ProgressiveMediaSource.Factory(OkHttpDataSource.Factory(Nas.client)).createMediaSource(MediaItem.fromUri(Nas.fileUrl(path))))
			prepare()
			playWhenReady = true
		}
	}
	DisposableEffect(Unit) { onDispose { player.release() } }
	Box(Modifier.fillMaxSize().background(Color.Black)) {
		AndroidView(factory = { PlayerView(it).apply { this.player = player } }, modifier = Modifier.fillMaxSize())
		Row(Modifier.statusBarsPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
			IconButton("arrow_left", tint = Color.White, color = Color.Black.copy(alpha = 0.4f)) { nav.back() }
			Spacer(Modifier.width(8.dp))
			Label(path.substringAfterLast('/'), color = Color.White)
		}
	}
}

// ── photo auto upload ──────────────────────────────────────────────────────
@Composable
fun PhotosScreen() {
	val app = LocalApp.current
	val context = LocalContext.current
	val scope = rememberCoroutineScope()
	val on by app.prefs.nasAutoUpload.flow.collectAsState()
	val wifi by app.prefs.nasWifiOnly.flow.collectAsState()
	val charging by app.prefs.nasChargingOnly.flow.collectAsState()
	val deleteAfter by app.prefs.nasDeleteAfter.flow.collectAsState()
	val status by PhotoUpload.status.collectAsState()
	val account by Nas.account.collectAsState()
	var allowed by remember { mutableStateOf(PhotoUpload.mayRead(context)) }
	var starting by remember { mutableStateOf(false) }
	var warning by remember { mutableStateOf(false) }
	var freeable by remember { mutableStateOf<List<PhotoUpload.Item>?>(null) }
	var checking by remember { mutableStateOf(false) }
	var version by remember { mutableIntStateOf(0) }
	val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { allowed = PhotoUpload.mayRead(context) }
	val deleter = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
		val items = freeable.orEmpty()
		if (result.resultCode == Activity.RESULT_OK) {
			PhotoUpload.forgetDeleted(context, items)
			app.link.toast("${items.size} removed from the phone")
		}
		freeable = null
		version += 1
	}
	val waiting = remember(on, version, status.last, allowed) {
		if (!allowed) 0 else runCatching {
			val done = PhotoUpload.state(context)
			PhotoUpload.items(context, app.prefs.nasUploadSince.value.toLongOrNull() ?: 0).count { done.getString(it.key, null) == null }
		}.getOrDefault(0)
	}
	val apply = { PhotoUpload.schedule(app) }
	Screen("Photo upload", subtitle = "Pictures and videos to /Phone photos on the NAS") {
		if (account == null) Panel { Label("No NAS token yet: it comes from the PC the next time the phone connects to it.", color = Theme.colors.textMuted, maxLines = 3) }
		if (!allowed) Panel {
			Label("The app may not read the photos yet.", maxLines = 2)
			Spacer(Modifier.width(8.dp))
			PrimaryButton("Allow", Modifier.fillMaxWidth().padding(top = 8.dp), icon = "image_multiple") { ask.launch(PhotoUpload.permissions()) }
		}
		Panel {
			Setting("Upload automatically", "New pictures and videos, in the background", on) { next ->
				if (next) {
					if (!allowed) ask.launch(PhotoUpload.permissions())
					starting = true
				} else {
					app.prefs.nasAutoUpload.value = false
					apply()
				}
			}
			Setting("Only on Wi-Fi", "No mobile data for it", wifi) { app.prefs.nasWifiOnly.value = it; apply() }
			Setting("Only while charging", "Waits for the charger", charging) { app.prefs.nasChargingOnly.value = it; apply() }
			Setting("Offer to delete from the phone", "After the NAS confirmed a photo; Android asks first", deleteAfter) { next ->
				if (next) warning = true else app.prefs.nasDeleteAfter.value = false
			}
		}
		SectionLabel("Status")
		Panel {
			when {
				status.running -> {
					Label("Uploading ${status.done + 1} of ${status.total}", style = Theme.Type.title)
					Label(status.current, style = Theme.Type.small, color = Theme.colors.textMuted)
					Meter(if (status.total > 0) status.done.toFloat() / status.total else 0f, Modifier.fillMaxWidth().padding(top = 8.dp))
				}
				else -> {
					Label(if (waiting == 0) "Everything is on the NAS" else "$waiting waiting", style = Theme.Type.title)
					val last = if (status.last > 0) "Last run ${whenSaid(status.last / 1000)}" else "Never ran yet"
					Label("$last · ${status.uploaded} uploaded so far", style = Theme.Type.small, color = Theme.colors.textMuted)
					if (status.error.isNotEmpty()) Label(status.error, style = Theme.Type.small, color = Theme.colors.warning, maxLines = 3)
				}
			}
			Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton("Upload now", Modifier.weight(1f).padding(vertical = 4.dp), icon = "cloud_upload_outline") {
					PhotoUpload.now(app)
					app.link.toast(if (wifi) "Starts once the phone is on Wi-Fi" else "Starting")
				}
				if (deleteAfter) SoftButton(if (checking) "Checking…" else "Free up space", Modifier.weight(1f).padding(vertical = 4.dp), icon = "broom") {
					if (checking) return@SoftButton
					checking = true
					scope.launch {
						// only what the NAS confirmed with the same size, checked once more where it can be
						val items = withContext(Dispatchers.IO) {
							PhotoUpload.freeable(context).filter { item ->
								val record = PhotoUpload.state(context).getString(item.key, "").orEmpty()
								val there = runCatching { Nas.stat(record.substringAfter('|').ifEmpty { PhotoUpload.target(item) }) }
								there.isFailure || there.getOrNull()?.get("size")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull() } == item.size
							}
						}
						checking = false
						if (items.isEmpty()) app.link.toast("Nothing to remove: no photo the NAS confirmed is still on the phone")
						else {
							freeable = items
							deleter.launch(IntentSenderRequest.Builder(PhotoUpload.deleteRequest(context, items).intentSender).build())
						}
					}
				}
			}
		}
		Label("The originals go up with their place (EXIF), named as on the phone, in a folder per year and month. A photo already there with the same size is not sent again.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 4)
	}
	if (starting) Sheet({ starting = false }, "Which photos?") { close ->
		Label("New ones go up as they are taken. The photos already on the phone can go too – the first run then takes a while.", color = Theme.colors.textMuted, maxLines = 4)
		PrimaryButton("Only new ones from now on", Modifier.fillMaxWidth(), icon = "camera") {
			app.prefs.nasUploadSince.value = (System.currentTimeMillis() / 1000).toString()
			app.prefs.nasAutoUpload.value = true
			apply()
			close()
		}
		SoftButton("All photos on the phone", Modifier.fillMaxWidth().padding(vertical = 4.dp), icon = "image_multiple") {
			app.prefs.nasUploadSince.value = "0"
			app.prefs.nasAutoUpload.value = true
			apply()
			close()
		}
	}
	if (warning) Confirm(
		"Delete photos from the phone?",
		"After a photo is on the NAS (confirmed by its size there), the app offers to remove it from the phone, to free space. Android asks before anything is deleted, and only photos the NAS confirmed are offered – but then the NAS holds the only copy: keep its backup on.",
		confirm = "Offer it", danger = true, onDismiss = { warning = false },
	) { app.prefs.nasDeleteAfter.value = true }
}

@Composable
private fun Setting(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
	Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
		Column(Modifier.weight(1f)) {
			Label(title, style = Theme.Type.body.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold))
			Label(subtitle, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
		}
		Spacer(Modifier.width(12.dp))
		Toggle(checked, onChange = onChange)
	}
}

// ── music ──────────────────────────────────────────────────────────────────
@Composable
fun MusicScreen() {
	val app = LocalApp.current
	val context = LocalContext.current
	val account by Nas.account.collectAsState()
	val now by Music.now.collectAsState()
	var folder by rememberSaveable { mutableStateOf("/Songs") }
	var query by rememberSaveable { mutableStateOf("") }
	var asked by rememberSaveable { mutableStateOf("") }
	var entries by remember { mutableStateOf<List<JsonElement>?>(null) }
	var error by remember { mutableStateOf("") }
	var version by remember { mutableIntStateOf(0) }
	LaunchedEffect(account, folder, asked, version) {
		if (account == null) return@LaunchedEffect
		error = ""
		entries = try {
			if (asked.isNotEmpty()) Nas.search(asked, kind = "audio", limit = 300)
			else Nas.list(folder).filter { it["dir"].bool || it["kind"].string == "audio" || it["name"].string.substringAfterLast('.', "").lowercase() in setOf("mp3", "flac", "ogg", "opus", "m4a", "wav", "aac") }
		} catch (failure: IOException) {
			// no /Songs: everything the NAS knows as audio
			if (failure is NasError && failure.status == 404 && folder == "/Songs") runCatching { Nas.search("", kind = "audio", limit = 500) }.getOrElse { error = it.message ?: ""; null }
			else {
				error = failure.message ?: "The NAS did not answer"
				null
			}
		}
	}
	androidx.activity.compose.BackHandler(enabled = asked.isNotEmpty() || folder != "/Songs") {
		if (asked.isNotEmpty()) {
			asked = ""
			query = ""
		} else folder = parentOf(folder)
	}
	Screen("Music", scroll = false) {
		if (account == null) {
			EmptyState("music_box_multiple", "No NAS yet", text = "The key to the NAS comes from the PC.")
			return@Screen
		}
		if (now.path.isNotEmpty()) Panel {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Glyph("music", size = 22.dp, color = Theme.colors.primary)
				Spacer(Modifier.width(10.dp))
				Column(Modifier.weight(1f)) {
					Label(now.title.ifEmpty { now.path.substringAfterLast('/') }, style = Theme.Type.title)
					Label("${now.index + 1} of ${now.count} · ${parentOf(now.path)}", style = Theme.Type.small, color = Theme.colors.textMuted)
				}
				IconButton("skip_previous") { Music.previous(context) }
				IconButton(if (now.playing) "pause" else "play", color = Theme.colors.primary, tint = Theme.colors.onPrimary) { Music.toggle(context) }
				IconButton("skip_next") { Music.next(context) }
			}
		}
		Field(query, placeholder = "Search songs", icon = "magnify", action = ImeAction.Search, onSubmit = { asked = query.trim() }, trailing = {
			if (query.isNotEmpty()) IconButton("close", size = 36.dp, iconSize = 18.dp) { query = ""; asked = "" }
		}) { query = it }
		if (asked.isEmpty() && folder != "/Songs") Chip(folder.removePrefix("/Songs").ifEmpty { "Songs" }, icon = "arrow_up") { folder = parentOf(folder) }
		val list = entries
		when {
			error.isNotEmpty() -> EmptyState("cloud_off_outline", "No music", text = error, action = { SoftButton("Try again", icon = "refresh") { Nas.base.value = null; version += 1 } })
			list == null -> EmptyState("music_box_multiple", "Loading…")
			list.isEmpty() -> EmptyState("music_off", if (asked.isNotEmpty()) "Nothing found" else "No songs here")
			else -> {
				val songs = list.filter { !it["dir"].bool }.map { it["path"].string }
				LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = BottomSpace)) {
					items(list, key = { it["path"].string }) { entry ->
						val path = entry["path"].string
						val dir = entry["dir"].bool
						ListRow(
							entry["name"].string.let { if (dir) it else it.substringBeforeLast('.') },
							icon = if (dir) "folder" else if (now.path == path && now.playing) "volume_high" else "music_note",
							iconBackground = if (dir) Theme.colors.primaryContainer else Theme.colors.layer2,
							iconTint = if (dir || now.path == path) Theme.colors.primary else Theme.colors.text,
							subtitle = if (dir) "" else listOf(if (asked.isNotEmpty()) parentOf(path) else "", bytesSaid(entry["size"].long)).filter { it.isNotEmpty() }.joinToString(" · "),
							onClick = {
								if (dir) folder = path
								else Music.play(context, songs, songs.indexOf(path).coerceAtLeast(0))
							},
						)
					}
				}
			}
		}
	}
}
