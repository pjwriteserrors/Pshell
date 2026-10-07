package dev.pshell.app.features

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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.service.Transfers
import dev.pshell.app.ui.link
import dev.pshell.app.ui.pluginOn
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Ring
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Tile
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

// ── song detection ─────────────────────────────────────────────────────────
val SongFeature = Feature(
	id = "song",
	group = Group.Media,
	keywords = listOf("shazam", "detect", "erkennen", "song"),
	title = "What plays?",
	icon = "waveform",
	plugins = listOf("song-detection", "media"),
	screen = { SongScreen() },
)

@Composable
private fun SongScreen() {
	val song = topic("song")
	val link = link
	val listening = song["listening"].bool
	var now by remember { mutableLongStateOf(link.pcNow()) }
	LaunchedEffect(listening) {
		while (listening) {
			now = link.pcNow()
			delay(250)
		}
	}
	Screen("What plays?", subtitle = "The PC listens to what it plays and names it") {
		val progress = if (listening) ((now - song["startedAt"].long) / 1000f / song["seconds"].int.coerceAtLeast(1)).coerceIn(0f, 1f) else 0f
		Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
			Ring(progress, size = 148.dp, thickness = 8.dp) {
				Box(
					Modifier.size(112.dp).clip(RoundedCornerShape(56.dp)).pressable(shape = RoundedCornerShape(56.dp), pressedScale = 0.92f, haptic = true) {
						link.run("song", if (listening) "cancel" else "detect")
					}.background(if (listening) Theme.colors.primaryContainer else Theme.colors.primary),
					contentAlignment = Alignment.Center,
				) {
					Glyph(if (listening) "stop" else "waveform", size = 44.dp, color = if (listening) Theme.colors.primary else Theme.colors.onPrimary)
				}
			}
		}
		Label(
			when {
				listening -> "Listening…"
				song["state"].string == "found" -> "Found"
				song["message"].string.isNotEmpty() -> song["message"].string
				else -> "Tap to listen"
			},
			Modifier.fillMaxWidth(), color = Theme.colors.textMuted, align = TextAlign.Center,
		)
		song["song"]?.let { found ->
			Panel(padding = PaddingValues(12.dp)) {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Box(Modifier.size(72.dp).clip(RoundedCornerShape(20.dp)).background(Theme.colors.layer3), contentAlignment = Alignment.Center) {
						val cover = link.blob(found["cover"].string)
						if (cover != null) AsyncImage(model = cover, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
						else Glyph("music", size = 28.dp, color = Theme.colors.textSubtle)
					}
					Spacer(Modifier.width(14.dp))
					Column(Modifier.weight(1f)) {
						Label(found["title"].string, style = Theme.Type.title, maxLines = 2)
						Label(listOf(found["artist"].string, found["album"].string).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
					}
				}
				val links = found["links"].list
				if (links.isNotEmpty()) {
					Spacer(Modifier.height(10.dp))
					Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						val context = LocalContext.current
						for (item in links) Chip(item["label"].string, icon = "open_in_new") {
							runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(item["url"].string))) }
						}
					}
				}
			}
		}
	}
}

// ── weather ────────────────────────────────────────────────────────────────
val WeatherFeature = Feature(
	id = "weather",
	group = Group.Work,
	keywords = listOf("wetter", "forecast", "temperature"),
	title = "Weather",
	icon = "weather_partly_cloudy",
	plugins = listOf("weather"),
	summary = { topic("weather").let { if (it["available"].bool) "${it["temperature"].int}°" else "" } },
	screen = { WeatherScreen() },
)

@Composable
private fun WeatherScreen() {
	val weather = topic("weather")
	val link = link
	Screen("Weather", subtitle = weather["location"].string.ifEmpty { weather["city"].string }, actions = {
		IconButton("refresh", color = Theme.colors.layer2) { link.run("weather", "refresh") }
	}) {
		if (!weather["available"].bool) {
			EmptyState("weather_cloudy", weather["description"].string.ifEmpty { "No weather yet" })
			return@Screen
		}
		Panel {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Glyph(weather["icon"].string.takeIf { Icons.has(it) } ?: "weather_cloudy", size = 56.dp, color = Theme.colors.primary)
				Spacer(Modifier.width(16.dp))
				Column(Modifier.weight(1f)) {
					Label("${weather["temperature"].int}°", style = Theme.Type.hero)
					Label(weather["description"].string, style = Theme.Type.body, color = Theme.colors.textMuted)
					Label("Feels like ${weather["feelsLike"].string}", style = Theme.Type.small, color = Theme.colors.textSubtle)
				}
			}
			Spacer(Modifier.height(14.dp))
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for ((icon, value) in listOf("water_percent" to weather["humidity"].string, "weather_windy" to weather["wind"].string, "weather_pouring" to weather["precipitation"].string, "gauge" to weather["pressure"].string)) {
					Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
						Glyph(icon, size = 18.dp, color = Theme.colors.textMuted)
						Label(value, style = Theme.Type.small, color = Theme.colors.textMuted)
					}
				}
			}
		}
		val hourly = weather["hourly"].list
		if (hourly.isNotEmpty()) {
			SectionLabel("Next hours")
			Panel {
				Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
					for (hour in hourly) Column(horizontalAlignment = Alignment.CenterHorizontally) {
						Label(hour["label"].string, style = Theme.Type.tiny, color = Theme.colors.textSubtle)
						Spacer(Modifier.height(6.dp))
						Glyph(hour["icon"].string.takeIf { Icons.has(it) } ?: "weather_cloudy", size = 22.dp)
						Spacer(Modifier.height(6.dp))
						Label("${hour["temp"].int}°", style = Theme.Type.label)
						if (hour["rain"].int > 0) Label("${hour["rain"].int}%", style = Theme.Type.tiny, color = Theme.colors.tertiary)
					}
				}
			}
		}
		val daily = weather["daily"].list
		if (daily.isNotEmpty()) {
			SectionLabel("Week")
			Panel(padding = PaddingValues(6.dp)) {
				for (day in daily) ListRow(day["label"].string, icon = day["icon"].string.takeIf { Icons.has(it) } ?: "weather_cloudy", iconBackground = Theme.colors.layer2) {
					Label("${day["max"].int}°", style = Theme.Type.label)
					Spacer(Modifier.width(10.dp))
					Label("${day["min"].int}°", style = Theme.Type.label, color = Theme.colors.textSubtle)
				}
			}
		}
		Label("Sunrise ${weather["sunrise"].string} · Sunset ${weather["sunset"].string}", Modifier.fillMaxWidth(), style = Theme.Type.small, color = Theme.colors.textSubtle, align = TextAlign.Center)
	}
}

// ── calendar ───────────────────────────────────────────────────────────────
val CalendarFeature = Feature(
	id = "calendar",
	group = Group.Work,
	keywords = listOf("kalender", "meetings", "termine", "events"),
	title = "Calendar",
	icon = "calendar_month_outline",
	plugins = listOf("calendar"),
	screen = { CalendarScreen() },
)

private fun timeOf(iso: String): String = Regex("""T(\d\d:\d\d)""").find(iso)?.groupValues?.get(1) ?: ""

@Composable
private fun CalendarScreen() {
	val calendar = topic("calendar")
	val link = link
	val context = LocalContext.current
	Screen("Calendar", subtitle = calendar["account"].string, actions = {
		if (calendar["signedIn"].bool) IconButton("refresh", color = Theme.colors.layer2) { link.run("calendar", "refresh") }
	}) {
		if (!calendar["microsoft"].bool) {
			EmptyState("calendar_month_outline", "Only the calendar", text = "The Microsoft 365 calendar is off on the PC; its events would show here.")
			return@Screen
		}
		if (!calendar["signedIn"].bool) {
			if (calendar["loginCode"].string.isNotEmpty()) {
				Panel(color = Theme.colors.primaryContainer) {
					Label("Sign in on the PC or here", style = Theme.Type.title)
					Label("Open the Microsoft page and enter this code:", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
					Spacer(Modifier.height(8.dp))
					Label(calendar["loginCode"].string, style = Theme.Type.display.copy(fontFamily = Theme.mono, letterSpacing = 2.sp))
					Spacer(Modifier.height(10.dp))
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						PrimaryButton("Open the page", icon = "open_in_new") {
							runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(calendar["loginUrl"].string.ifEmpty { "https://microsoft.com/devicelogin" }))) }
						}
						SoftButton("Cancel") { link.run("calendar", "cancelSignIn") }
					}
				}
			} else {
				EmptyState("calendar_month_outline", "Not signed in", text = calendar["error"].string) {
					PrimaryButton("Sign in to Microsoft 365", icon = "microsoft") { link.run("calendar", "signIn") }
				}
			}
			return@Screen
		}
		if (calendar["error"].string.isNotEmpty()) Label(calendar["error"].string, color = Theme.colors.danger, maxLines = 3)
		val events = calendar["events"].list
		if (events.isEmpty()) EmptyState("calendar_check_outline", if (calendar["loading"].bool) "Loading…" else "Nothing in the next two weeks")
		for ((day, list) in events.groupBy { it["day"].string }) {
			val date = runCatching { java.time.LocalDate.parse(day) }.getOrNull()
			SectionLabel(
				when (date) {
					java.time.LocalDate.now() -> "Today"
					java.time.LocalDate.now().plusDays(1) -> "Tomorrow"
					null -> day
					else -> date.format(java.time.format.DateTimeFormatter.ofPattern("EEEE, d MMMM"))
				},
			)
			Panel(padding = PaddingValues(6.dp)) {
				for (event in list) {
					ListRow(
						event["subject"].string,
						icon = if (event["join"].string.isNotEmpty()) "video_outline" else "calendar_blank_outline",
						subtitle = listOf(if (event["allDay"].bool) "All day" else "${timeOf(event["start"].string)} – ${timeOf(event["end"].string)}", event["location"].string).filter { it.isNotEmpty() }.joinToString(" · "),
						iconBackground = if (event["running"].bool) Theme.colors.primary else Theme.colors.layer3,
						iconTint = if (event["running"].bool) Theme.colors.onPrimary else Theme.colors.text,
						onClick = (event["join"].string.ifEmpty { event["link"].string }).takeIf { it.isNotEmpty() }?.let { url -> { runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))) } } },
					) {
						if (event["join"].string.isNotEmpty()) IconButton("monitor", size = 36.dp, iconSize = 18.dp) { link.run("calendar", "open", json("url" to event["join"].string)) }
					}
				}
			}
		}
		SoftButton("Sign out", icon = "logout") { link.run("calendar", "signOut") }
	}
}

// ── shelves ────────────────────────────────────────────────────────────────
val ShelvesFeature = Feature(
	id = "shelves",
	group = Group.Work,
	keywords = listOf("ablage", "stash", "drop", "files"),
	title = "Shelves",
	icon = "tray_full",
	plugins = listOf("shelves"),
	summary = { topic("shelves")["shelves"].list.sumOf { it["items"].list.size }.takeIf { it > 0 }?.let { "$it things" } ?: "" },
	screen = { ShelvesScreen() },
)

@Composable
private fun ShelvesScreen() {
	val state = topic("shelves")
	val link = link
	val scope = rememberCoroutineScope()
	val shelves = state["shelves"].list
	var target by remember { mutableStateOf<String?>(null) }
	val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
		if (uris.isNotEmpty()) Transfers.upload(uris, query = "?shelf=${target ?: "new"}")
	}
	Screen("Shelves", subtitle = "The stashes on the desktop", actions = {
		IconButton("tray_plus", color = Theme.colors.layer2) {
			target = null
			picker.launch(arrayOf("*/*"))
		}
	}) {
		if (shelves.isEmpty()) EmptyState("tray_full", "No shelf is open", text = "Shake the pointer on the PC, or send files here: they open a new shelf.")
		for (shelf in shelves) {
			val id = shelf["id"].string
			Panel(padding = PaddingValues(start = 6.dp, end = 6.dp, top = 10.dp, bottom = 6.dp)) {
				Row(Modifier.padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
					Label(shelf["name"].string, Modifier.weight(1f), style = Theme.Type.title)
					IconButton("tray_arrow_down", size = 36.dp, iconSize = 18.dp) {
						target = id
						picker.launch(arrayOf("*/*"))
					}
					IconButton("cellphone_arrow_down", size = 36.dp, iconSize = 18.dp) { link.run("shelves", "sendAll", json("id" to id)) }
					IconButton("close", size = 36.dp, iconSize = 18.dp) { link.run("shelves", "close", json("id" to id)) }
				}
				for (item in shelf["items"].list) {
					Row(verticalAlignment = Alignment.CenterVertically) {
						val image = link.blob(item["image"].string)
						if (image != null) AsyncImage(model = image, contentDescription = null, modifier = Modifier.padding(start = 10.dp).size(40.dp).clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Crop)
						Box(Modifier.weight(1f)) {
							ListRow(
								item["name"].string,
								icon = if (image == null) item["icon"].string.takeIf { Icons.has(it) } ?: "file" else null,
								subtitle = if (item["kind"].string == "file" && item["size"].long > 0) "${item["size"].long / 1024} KB" else item["url"].string,
								onClick = { link.run("shelves", "send", json("id" to id, "item" to item["id"].string)) },
							)
						}
						IconButton("close", size = 36.dp, iconSize = 16.dp) { link.run("shelves", "remove", json("id" to id, "item" to item["id"].string)) }
					}
				}
				Label("Tap a thing to get it on the phone", Modifier.padding(start = 10.dp, top = 4.dp), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
			}
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Chip("PC clipboard onto a shelf", icon = "content_paste") { link.run("shelves", "clipboard") }
		}
		val recent = state["recent"].list
		if (recent.isNotEmpty()) {
			SectionLabel("Closed lately")
			Panel(padding = PaddingValues(6.dp)) {
				for (shelf in recent) ListRow(shelf["name"].string, icon = "tray", subtitle = "${shelf["count"].int} things", onClick = { link.run("shelves", "reopen", json("id" to shelf["id"].string)) }) {
					IconButton("close", size = 36.dp, iconSize = 16.dp) { link.run("shelves", "forget", json("id" to shelf["id"].string)) }
				}
			}
		}
	}
}

// ── translate ──────────────────────────────────────────────────────────────
val TranslateFeature = Feature(
	id = "translate",
	group = Group.Work,
	keywords = listOf("übersetzen", "language", "sprache"),
	title = "Translate",
	icon = "translate",
	plugins = listOf("translate"),
	screen = { TranslateScreen() },
)

@Composable
private fun TranslateScreen() {
	val state = topic("translate")
	val link = link
	val scope = rememberCoroutineScope()
	val context = LocalContext.current
	var text by remember { mutableStateOf("") }
	var target by remember { mutableStateOf("auto") }
	var result by remember { mutableStateOf<JsonElement?>(null) }
	var busy by remember { mutableStateOf(false) }
	var error by remember { mutableStateOf("") }
	fun go() {
		if (text.isBlank()) return
		busy = true
		scope.launch {
			try {
				result = link.call("translate", "translate", json("text" to text, "target" to target), timeoutSeconds = 20)
				error = ""
			} catch (failure: LinkError) {
				error = link.describe(failure)
			}
			busy = false
		}
	}
	Screen("Translate", subtitle = "The PC's translator, with its services") {
		Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			for (language in state["languages"].list) Chip(language["label"].string, active = language["code"].string == target) { target = language["code"].string }
		}
		Field(text, placeholder = "Text", singleLine = false, trailing = {
			IconButton("send", size = 40.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = text.isNotBlank() && !busy) { go() }
		}) { text = it }
		if (busy) Label("Translating…", color = Theme.colors.textMuted)
		if (error.isNotEmpty()) Label(error, color = Theme.colors.danger, maxLines = 3)
		result?.let { found ->
			Panel(onClick = { context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("Translation", found["text"].string)) }) {
				Label("${found["source"].string.uppercase()} → ${found["target"].string.uppercase()}", style = Theme.Type.tiny, color = Theme.colors.textSubtle)
				Spacer(Modifier.height(4.dp))
				Label(found["text"].string, maxLines = 40)
				Label("Tap to copy", Modifier.padding(top = 6.dp), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
			}
		}
	}
}

// ── display profiles ───────────────────────────────────────────────────────
val DisplayFeature = Feature(
	id = "display",
	group = Group.Pc,
	keywords = listOf("monitors", "bildschirme", "layout", "profiles"),
	title = "Displays",
	icon = "monitor_multiple",
	plugins = listOf("display-profiles"),
	summary = { topic("display")["current"].string },
	screen = {
		val display = topic("display")
		val link = link
		Screen("Displays", subtitle = "The desk setups of the PC") {
			val profiles = display["profiles"].list
			if (profiles.isEmpty()) EmptyState("monitor_multiple", "No profiles", text = "Profiles live in scripts/display-profiles on the PC.")
			for (pair in profiles.chunked(2)) {
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for (profile in pair) {
						val name = profile.string
						Tile("monitor_multiple", name.replaceFirstChar { it.uppercase() }, Modifier.weight(1f), subtitle = if (name == display["current"].string) "Active" else "", active = name == display["current"].string) {
							link.run("display", "apply", json("name" to name))
						}
					}
					if (pair.size == 1) Spacer(Modifier.weight(1f))
				}
			}
		}
	},
)
