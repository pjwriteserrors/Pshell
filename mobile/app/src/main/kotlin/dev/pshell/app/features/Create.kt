package dev.pshell.app.features

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import dev.pshell.app.ui.theme.Palette
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.int
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.service.Transfers
import dev.pshell.app.ui.connected
import dev.pshell.app.ui.link
import dev.pshell.app.ui.pluginOn
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

// ── capture ────────────────────────────────────────────────────────────────
val CaptureFeature = Feature(
	id = "capture",
	title = "Capture",
	icon = "camera_outline",
	plugins = listOf("screenshot"),
	screen = { CaptureScreen() },
)

@Composable
private fun CaptureScreen() {
	val link = link
	val scope = rememberCoroutineScope()
	var outputs by remember { mutableStateOf<List<JsonElement>>(emptyList()) }
	var shot by remember { mutableStateOf<JsonElement?>(null) }
	var busy by remember { mutableStateOf(false) }
	var error by remember { mutableStateOf("") }
	val recording = if (pluginOn("recording")) topic("recording") else null
	val pcModes = topic("screenshot")
	LaunchedEffect(Unit) { outputs = runCatching { link.call("capture", "outputs")["outputs"].list }.getOrDefault(emptyList()) }

	fun take(output: String) {
		busy = true
		scope.launch {
			try {
				shot = link.call("capture", "screen", json("output" to output), timeoutSeconds = 20)
				error = ""
			} catch (failure: LinkError) {
				error = link.describe(failure)
			}
			busy = false
		}
	}

	Screen("Capture", subtitle = "The PC's screens, as pictures on the phone") {
		SectionLabel("Screenshot")
		Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Chip("All screens", icon = "monitor_multiple") { take("") }
			for (output in outputs) Chip(output["name"].string, icon = "monitor") { take(output["name"].string) }
		}
		if (busy) Label("Capturing…", color = Theme.colors.textMuted)
		if (error.isNotEmpty()) Label(error, color = Theme.colors.danger, maxLines = 3)
		shot?.let { taken ->
			Panel(padding = PaddingValues(8.dp)) {
				AsyncImage(model = link.blob(taken["url"].string), contentDescription = null, modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)), contentScale = ContentScale.FillWidth)
				Spacer(Modifier.height(8.dp))
				PrimaryButton("Save to Downloads", Modifier.fillMaxWidth(), icon = "download") { Transfers.fetch(taken["name"].string, taken["url"].string, taken["size"].long) }
			}
		}
		val modes = pcModes["modes"].list
		if (modes.isNotEmpty()) {
			SectionLabel("Start on the PC")
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (mode in modes) Chip(mode["label"].string, icon = mode["icon"].string.takeIf { dev.pshell.app.ui.theme.Icons.has(it) }) { link.run("screenshot", mode["id"].string) }
			}
			Label("These open the PC's own capture tools, with their picker on the screen there.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 2)
		}
		val history = pcModes["history"].list
		if (history.isNotEmpty()) {
			SectionLabel("Lately on the PC")
			for (row in history.chunked(3)) {
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for (shotItem in row) {
						Box(Modifier.weight(1f).aspectRatio(16f / 10f).clip(RoundedCornerShape(14.dp)).background(Theme.colors.layer2).pressable(shape = RoundedCornerShape(14.dp), onLongClick = {
							link.run("screenshot", "copy", json("id" to shotItem["id"].int))
						}) {
							Transfers.fetch("Screenshot ${shotItem["id"].int}.png", shotItem["image"].string, 0)
							link.toast("Fetching into Downloads")
						}) {
							AsyncImage(model = link.blob(shotItem["image"].string), contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
						}
					}
					repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
				}
			}
			Label("Tap to fetch, hold to copy it on the PC.", style = Theme.Type.small, color = Theme.colors.textSubtle)
		}
		if (recording != null) {
			SectionLabel("Recording")
			if (recording["active"].bool) {
				var now by remember { mutableLongStateOf(link.pcNow()) }
				LaunchedEffect(Unit) {
					while (true) {
						now = link.pcNow()
						delay(1000)
					}
				}
				Panel(color = Theme.colors.dangerContainer) {
					Label("RECORDING", style = Theme.Type.tiny, color = Theme.colors.danger)
					Label(clock(((now - recording["startedAt"].long) / 1000.0).coerceAtLeast(0.0)), style = Theme.Type.display.copy(fontFeatureSettings = "tnum"))
					Spacer(Modifier.height(10.dp))
					PrimaryButton("Stop", Modifier.fillMaxWidth(), icon = "stop", danger = true) { link.run("recording", "stop") }
				}
			} else {
				Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for (output in recording["outputs"].list) Chip("Record ${output.string}", icon = "record_rec") { link.run("recording", "start", json("output" to output.string)) }
				}
				Label("The recording lands in Videos/Recordings on the PC.", style = Theme.Type.small, color = Theme.colors.textSubtle)
			}
		}
	}
}

// ── studio ─────────────────────────────────────────────────────────────────
val StudioFeature = Feature(
	id = "studio",
	title = "Studio",
	icon = "palette_outline",
	plugins = listOf("studio-wallpaper"),
	screen = { StudioScreen() },
)

/**
 * The shell in miniature over a wallpaper, drawn in a palette: the bar with
 * its workspaces and clock, a panel hanging from it with tiles and a slider.
 * What Studio shows on the desktop before a theme is applied.
 */
@Composable
fun ShellPreview(palette: Palette, wallpaper: String?, modifier: Modifier = Modifier, radius: Dp = 22.dp) {
	Box(modifier.aspectRatio(16f / 10f).clip(RoundedCornerShape(radius)).background(palette.bg)) {
		if (wallpaper != null) AsyncImage(model = wallpaper, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
		Canvas(Modifier.fillMaxSize()) {
			val w = size.width
			val h = size.height
			val bar = h * 0.085f
			val round = CornerRadius(h * 0.03f)
			// the bar: see-through, as on the desktop
			drawRect(palette.bg.copy(alpha = 0.8f), size = Size(w, bar))
			for (index in 0 until 4) {
				drawRoundRect(if (index == 1) palette.primary else palette.fg.copy(alpha = 0.3f), Offset(w * 0.03f + index * bar * 0.62f, bar * 0.36f), Size(if (index == 1) bar * 0.9f else bar * 0.3f, bar * 0.28f), CornerRadius(bar))
			}
			drawRoundRect(palette.fg.copy(alpha = 0.75f), Offset(w * 0.46f, bar * 0.36f), Size(w * 0.08f, bar * 0.28f), CornerRadius(bar))
			for (index in 0 until 3) drawCircle(palette.fg.copy(alpha = 0.6f), bar * 0.16f, Offset(w * 0.97f - index * bar * 0.55f, bar * 0.5f))
			// the panel under the bar's right end
			val pw = w * 0.36f
			val ph = h * 0.6f
			val px = w - pw - w * 0.02f
			drawRoundRect(palette.bg, Offset(px, bar), Size(pw, ph), round)
			val pad = pw * 0.07f
			val tile = Size((pw - pad * 3) / 2, ph * 0.17f)
			for (row in 0 until 2) for (column in 0 until 2) {
				val active = row == 0
				val origin = Offset(px + pad + column * (tile.width + pad), bar + pad + row * (tile.height + pad * 0.7f))
				drawRoundRect(if (active) palette.primaryContainer else palette.layer1, origin, tile, CornerRadius(if (active) tile.height * 0.3f else tile.height / 2))
				drawCircle(if (active) palette.primary else palette.layer3, tile.height * 0.3f, Offset(origin.x + tile.height * 0.5f, origin.y + tile.height / 2))
				drawRoundRect(palette.fg.copy(alpha = 0.7f), Offset(origin.x + tile.height * 0.95f, origin.y + tile.height * 0.38f), Size(tile.width * 0.36f, tile.height * 0.2f), CornerRadius(tile.height))
			}
			val sliderY = bar + pad + 2 * (tile.height + pad * 0.7f) + pad * 0.3f
			drawRoundRect(palette.layer1, Offset(px + pad, sliderY), Size(pw - pad * 2, ph * 0.13f), CornerRadius(ph))
			drawRoundRect(palette.primary, Offset(px + pad, sliderY), Size((pw - pad * 2) * 0.62f, ph * 0.13f), CornerRadius(ph))
			val ringY = sliderY + ph * 0.13f + pad
			drawRoundRect(palette.layer1, Offset(px + pad, ringY), Size(pw - pad * 2, ph - (ringY - bar) - pad), round)
			drawCircle(palette.secondary, ph * 0.055f, Offset(px + pad * 2.4f, ringY + (ph - (ringY - bar) - pad) / 2), style = Stroke(ph * 0.022f))
			drawCircle(palette.tertiary, ph * 0.055f, Offset(px + pad * 5.2f, ringY + (ph - (ringY - bar) - pad) / 2), style = Stroke(ph * 0.022f))
			// a window, to see the background colour against the wallpaper
			drawRoundRect(palette.bg.copy(alpha = 0.92f), Offset(w * 0.04f, bar + h * 0.08f), Size(w * 0.5f, h * 0.62f), round)
			for (index in 0 until 4) {
				drawRoundRect(palette.fg.copy(alpha = if (index == 0) 0.8f else 0.32f), Offset(w * 0.07f, bar + h * (0.14f + index * 0.085f)), Size(w * (if (index == 0) 0.2f else 0.4f - index * 0.04f), h * 0.03f), CornerRadius(h))
			}
			drawRoundRect(palette.primary, Offset(w * 0.07f, bar + h * 0.52f), Size(w * 0.13f, h * 0.075f), CornerRadius(h))
		}
	}
}

private fun paletteOf(entry: JsonElement?): Palette? {
	val bg = Palette.parse(entry["background"].string) ?: return null
	val fg = Palette.parse(entry["foreground"].string) ?: return null
	return Palette.derive(bg, fg, entry["colors"].list.map { Palette.parse(it.string) ?: fg })
}

/**
 * Studio: pick a wallpaper, see the shell in each palette wallust makes of
 * it (kmeans, salience, ansi; dark and light), apply the one that looks right.
 */
@Composable
private fun StudioScreen() {
	val link = link
	val scope = rememberCoroutineScope()
	val current = Theme.colors
	var themes by remember { mutableStateOf<List<JsonElement>>(emptyList()) }
	var active by remember { mutableStateOf("") }
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	var palettes by remember { mutableStateOf<List<JsonElement>>(emptyList()) }
	var picked by remember { mutableStateOf<JsonElement?>(null) }
	var loading by remember { mutableStateOf(false) }
	var applying by remember { mutableStateOf(false) }
	var styles by remember { mutableStateOf<JsonElement?>(null) }
	var motions by remember { mutableStateOf<JsonElement?>(null) }
	var combinations by remember { mutableStateOf<JsonElement?>(null) }
	var dress by remember { mutableStateOf<JsonElement?>(null) }
	var message by remember { mutableStateOf("") }
	var daily by remember { mutableStateOf<JsonElement?>(null) }
	var fetching by remember { mutableStateOf("") }
	val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
		if (uri != null) {
			Transfers.upload(listOf(uri), endpoint = "wallpaper")
			message = "Sent. The PC puts it on and recolours itself."
		}
	}
	LaunchedEffect(Unit) {
		runCatching { link.call("studio", "themes", timeoutSeconds = 40) }.onSuccess {
			themes = it["themes"].list
			active = it["current"].string
			daily = it["daily"]
			chosen = themes.firstOrNull { theme -> theme["path"].string == active } ?: themes.firstOrNull()
		}
		if (dev.pshell.app.App.instance.on("studio-styles")) styles = runCatching { link.call("studio", "styles") }.getOrNull()
		if (dev.pshell.app.App.instance.on("studio-motion")) motions = runCatching { link.call("studio", "motions") }.getOrNull()
		if (dev.pshell.app.App.instance.on("studio-combinations")) combinations = runCatching { link.call("studio", "combinations") }.getOrNull()
		if (dev.pshell.app.App.instance.on("studio-dress")) dress = runCatching { link.call("studio", "dress", timeoutSeconds = 60) }.getOrNull()
	}
	LaunchedEffect(chosen) {
		val theme = chosen ?: return@LaunchedEffect
		palettes = emptyList()
		picked = null
		loading = true
		palettes = runCatching { link.call("studio", "palettes", json("path" to theme["path"].string), timeoutSeconds = 120)["palettes"].list }.getOrDefault(emptyList())
		loading = false
	}

	Screen("Studio", subtitle = "Wallpaper, colours and style of the PC", actions = {
		IconButton("image_plus", color = Theme.colors.layer2) { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
	}) {
		val wallpaper = link.blob(chosen["preview"].string)
		ShellPreview(paletteOf(picked) ?: current, wallpaper, Modifier.fillMaxWidth(), radius = 28.dp)
		Row(verticalAlignment = Alignment.CenterVertically) {
			Column(Modifier.weight(1f)) {
				Label(chosen["name"].string.ifEmpty { "Wallpaper" }, style = Theme.Type.title)
				Label(
					when {
						applying -> "Applying…"
						picked != null -> "${picked["palette"].string} · ${picked["style"].string}"
						loading -> "Making the palettes…"
						else -> "Pick a palette below, or apply as it is"
					},
					style = Theme.Type.small, color = Theme.colors.textMuted,
				)
			}
			PrimaryButton("Apply", icon = "check", enabled = chosen != null && !applying) {
				val theme = chosen ?: return@PrimaryButton
				applying = true
				scope.launch {
					message = try {
						link.call("studio", "apply", json("path" to theme["path"].string, "palette" to picked["palette"].string, "style" to picked["style"].string), timeoutSeconds = 180)
						active = theme["path"].string
						""
					} catch (failure: LinkError) {
						link.describe(failure)
					}
					applying = false
				}
			}
		}
		if (message.isNotEmpty()) Label(message, color = Theme.colors.textMuted, maxLines = 3)

		if (palettes.isNotEmpty()) {
			for (style in listOf("dark", "light")) {
				SectionLabel(style)
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for (entry in palettes.filter { it["style"].string == style }) {
						val palette = paletteOf(entry) ?: continue
						val selected = picked === entry
						Column(Modifier.weight(1f).pressable(shape = RoundedCornerShape(16.dp), pressedScale = 0.95f, haptic = true) { picked = if (selected) null else entry }, horizontalAlignment = Alignment.CenterHorizontally) {
							Box(Modifier.clip(RoundedCornerShape(16.dp)).background(if (selected) Theme.colors.primary else Theme.colors.layer1).padding(3.dp)) {
								ShellPreview(palette, wallpaper, radius = 13.dp)
							}
							Spacer(Modifier.height(4.dp))
							Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
								for (color in listOf(palette.primary, palette.secondary, palette.tertiary)) Box(Modifier.size(8.dp).clip(RoundedCornerShape(50)).background(color))
							}
							Label(entry["palette"].string, style = Theme.Type.tiny, color = if (selected) Theme.colors.primary else Theme.colors.textSubtle)
						}
					}
				}
			}
		}

		// today's picture from Bing, Wallhaven or MoeWalls, as Studio on the desktop offers it
		SectionLabel("Wallpaper of the day")
		Panel(padding = PaddingValues(10.dp)) {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Box(Modifier.width(112.dp).aspectRatio(16f / 10f).clip(RoundedCornerShape(16.dp)).background(Theme.colors.layer3), contentAlignment = Alignment.Center) {
					val picture = link.blob(daily["picture"].string)
					if (picture != null) AsyncImage(model = picture, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
					else Glyph("image_outline", size = 24.dp, color = Theme.colors.textSubtle)
				}
				Spacer(Modifier.width(12.dp))
				Column(Modifier.weight(1f)) {
					Label(daily["title"].string.ifEmpty { "Nothing fetched yet" }, style = Theme.Type.body.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), maxLines = 2)
					val detail = listOf(daily["detail"].string.takeIf { it != daily["title"].string }.orEmpty(), daily["date"].string).filter { it.isNotEmpty() }.joinToString(" · ")
					if (detail.isNotEmpty()) Label(detail, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 3)
				}
			}
			Spacer(Modifier.height(10.dp))
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for ((source, name) in listOf("bing" to "Bing", "wallhaven" to "Wallhaven", "moewalls" to "MoeWalls")) {
					Chip(if (fetching == source) "Loading…" else name, icon = "download", active = daily["provider"].string == source) {
						if (fetching.isNotEmpty()) return@Chip
						fetching = source
						scope.launch {
							message = try {
								daily = link.call("studio", "daily", json("provider" to source), timeoutSeconds = 200)
								active = daily["path"].string.substringBeforeLast('/')
								""
							} catch (failure: LinkError) {
								link.describe(failure)
							}
							fetching = ""
						}
					}
				}
			}
			Label("Tap a source to fetch today's picture and put it on.", Modifier.padding(top = 6.dp), style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 2)
		}

		SectionLabel("Wallpapers")
		for (row in themes.chunked(3)) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (theme in row) {
					val path = theme["path"].string
					val selected = chosen["path"].string == path
					Box(
						Modifier
							.weight(1f)
							.aspectRatio(16f / 10f)
							.pressable(shape = RoundedCornerShape(16.dp), pressedScale = 0.94f) { chosen = theme }
							.background(if (selected) Theme.colors.primary else Theme.colors.layer2)
							.padding(if (selected) 3.dp else 0.dp),
					) {
						AsyncImage(model = link.blob(theme["preview"].string), contentDescription = null, modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(if (selected) 13.dp else 16.dp)), contentScale = ContentScale.Crop)
						if (path == active) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(18.dp).clip(RoundedCornerShape(50)).background(Theme.colors.primary), contentAlignment = Alignment.Center) {
							Glyph("check", size = 12.dp, color = Theme.colors.onPrimary)
						}
					}
				}
				repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
			}
		}

		// a whole look, saved on the PC: wallpaper, palette, motion, dress and style at once
		val saved = combinations["combinations"].list
		if (saved.isNotEmpty()) {
			SectionLabel("Combinations")
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (combo in saved) {
					Column(Modifier.width(132.dp).pressable(shape = RoundedCornerShape(18.dp), pressedScale = 0.95f, haptic = true) {
						scope.launch {
							message = try {
								link.call("studio", "combination", json("name" to combo["name"].string), timeoutSeconds = 300)
								"Wearing ${combo["name"].string}."
							} catch (failure: LinkError) {
								link.describe(failure)
							}
						}
					}) {
						Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f).clip(RoundedCornerShape(18.dp)).background(Theme.colors.layer2)) {
							AsyncImage(model = link.blob(combo["preview"].string), contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
						}
						Label(combo["name"].string, Modifier.padding(start = 4.dp, top = 4.dp), style = Theme.Type.small.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold))
						Label(listOf(combo["palette"].string, combo["animation"].string.substringAfter(':')).filter { it.isNotEmpty() }.joinToString(" · "), Modifier.padding(start = 4.dp), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
					}
				}
			}
		}
		val animations = motions["motions"].list.map { it.string }
		if (animations.isNotEmpty()) {
			SectionLabel("Window animation")
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (animation in animations) Chip(animation.substringAfter(':'), icon = when (animation.substringBefore(':')) { "style" -> "palette_swatch_outline"; "shader" -> "blur"; else -> "animation_outline" }, active = animation == motions["current"].string) {
					scope.launch {
						message = try {
							link.call("studio", "motion", json("id" to animation), timeoutSeconds = 60)
							motions = runCatching { link.call("studio", "motions") }.getOrNull()
							""
						} catch (failure: LinkError) {
							link.describe(failure)
						}
					}
				}
			}
		}
		val icons = dress["icons"].list
		val cursors = dress["cursors"].list
		if (icons.isNotEmpty() || cursors.isNotEmpty()) {
			SectionLabel("Icons and pointer")
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (theme in icons) {
					val active = theme["id"].string == dress["current"]["icon"].string
					Column(Modifier.width(96.dp).pressable(shape = RoundedCornerShape(16.dp), pressedScale = 0.95f) {
						scope.launch { runCatching { link.call("studio", "wear", json("icons" to theme["id"].string), timeoutSeconds = 120) }.onFailure { message = "Icons could not be applied" } }
					}.background(if (active) Theme.colors.primaryContainer else Theme.colors.layer1).padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
						Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
							for (sample in theme["samples"].list.take(3)) AsyncImage(model = link.blob(sample.string), contentDescription = null, modifier = Modifier.size(22.dp))
						}
						Label(theme["name"].string, Modifier.padding(top = 6.dp), style = Theme.Type.tiny, maxLines = 1)
					}
				}
			}
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (theme in cursors) {
					val active = theme["id"].string == dress["current"]["cursor"].string
					Column(Modifier.width(96.dp).pressable(shape = RoundedCornerShape(16.dp), pressedScale = 0.95f) {
						scope.launch { runCatching { link.call("studio", "wear", json("cursor" to theme["id"].string), timeoutSeconds = 120) }.onFailure { message = "The pointer could not be applied" } }
					}.background(if (active) Theme.colors.primaryContainer else Theme.colors.layer1).padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
						val preview = link.blob(theme["preview"].string)
						if (preview != null) AsyncImage(model = preview, contentDescription = null, modifier = Modifier.size(28.dp)) else Glyph("cursor_default_outline", size = 24.dp)
						Label(theme["name"].string, Modifier.padding(top = 6.dp), style = Theme.Type.tiny, maxLines = 1)
					}
				}
			}
		}
		val branches = styles["branches"].list.filter { it["compatible"].bool }.distinctBy { it["name"].string }
		if (branches.isNotEmpty()) {
			SectionLabel("Style")
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (branch in branches) Chip(branch["name"].string, active = branch["current"].bool) {
					scope.launch {
						message = try {
							link.call("studio", "style", json("branch" to branch["branch"].string), timeoutSeconds = 60)
							"Switched to ${branch["name"].string}."
						} catch (failure: LinkError) {
							link.describe(failure)
						}
					}
				}
			}
		}
	}
}

// ── the PC's screen ────────────────────────────────────────────────────────
val ScreenFeature = Feature(
	id = "screen",
	title = "Screen",
	icon = "monitor_eye",
	plugins = listOf("phone-screen"),
	screen = { ScreenScreen() },
)

/** One of the PC's outputs as it is now, a few pictures a second. Pinch to zoom. */
@Composable
fun ScreenView(output: String, modifier: Modifier = Modifier) {
	val link = link
	val connected = connected()
	var frame by remember { mutableStateOf<ImageBitmap?>(null) }
	var scale by remember { mutableFloatStateOf(1f) }
	var offset by remember { mutableStateOf(Offset.Zero) }
	DisposableEffect(output, connected) {
		val socket = if (!connected) null else link.socket("stream/screen?output=$output&scale=0.6&quality=55", object : WebSocketListener() {
			override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
				val data = bytes.toByteArray()
				BitmapFactory.decodeByteArray(data, 0, data.size)?.let { frame = it.asImageBitmap() }
			}

			override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {}
		})
		onDispose { socket?.cancel() }
	}
	Box(
		modifier.clip(RoundedCornerShape(22.dp)).background(Theme.colors.layer1).pointerInput(Unit) {
			detectTransformGestures { _, pan, zoom, _ ->
				scale = (scale * zoom).coerceIn(1f, 6f)
				offset = if (scale == 1f) Offset.Zero else offset + pan
			}
		},
		contentAlignment = Alignment.Center,
	) {
		val shown = frame
		if (shown == null) Label("Waiting for the first picture", color = Theme.colors.textSubtle)
		else Image(shown, null, Modifier.fillMaxWidth().graphicsLayer {
			scaleX = scale
			scaleY = scale
			translationX = offset.x
			translationY = offset.y
		}, contentScale = ContentScale.FillWidth)
	}
}

@Composable
private fun ScreenScreen() {
	val link = link
	val view = LocalView.current
	var outputs by remember { mutableStateOf<List<String>>(emptyList()) }
	var output by remember { mutableStateOf("") }
	LaunchedEffect(Unit) {
		outputs = runCatching { link.call("capture", "outputs")["outputs"].list.map { it["name"].string } }.getOrDefault(emptyList())
		output = outputs.firstOrNull().orEmpty()
	}
	DisposableEffect(Unit) {
		view.keepScreenOn = true
		onDispose { view.keepScreenOn = false }
	}
	Screen("Screen", subtitle = "A look at the PC, a few pictures a second") {
		Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			for (name in outputs) Chip(name, icon = "monitor", active = name == output) { output = name }
		}
		if (output.isNotEmpty()) ScreenView(output, Modifier.fillMaxWidth())
		Label("Pinch to zoom, drag to move. It is not a video: enough to see what happens, or where the pointer is while the phone is the touchpad.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 4)
	}
}
