package dev.pshell.app.features

import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Ring
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Sparkline
import dev.pshell.app.ui.widgets.Toggle
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonElement
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ── printer: the 3D printer (Kobra S1 and its ACE) ─────────────────────────
val PrinterFeature = Feature(
	id = "printer",
	title = "3D printer",
	icon = "printer_3d",
	group = Group.Pc,
	plugins = listOf("printer"),
	keywords = listOf("drucker", "3d", "kobra", "anycubic", "ace", "filament", "print", "drucken", "slicer"),
	summary = {
		val printer = topic("printer")
		when {
			printer == null -> ""
			printer["printing"].bool -> "${Math.round(printer["progress"].double * 100)} % · ${duration(printer["secondsLeft"].double)} left"
			else -> printer["status"].string
		}
	},
	screen = { PrinterScreen() },
)

private fun duration(seconds: Double): String {
	val total = Math.max(0L, Math.round(seconds / 60))
	val hours = total / 60
	return if (hours > 0) "$hours h ${(total % 60).toString().padStart(2, '0')} min" else "$total min"
}

private fun grams(value: Double): String = if (value >= 1000) String.format(Locale.ROOT, "%.2f kg", value / 1000) else "${Math.round(value)} g"

private fun rgb(color: JsonElement?): Color {
	val c = color.list
	if (c.size < 3) return Color.Gray
	return Color(c[0].int.coerceIn(0, 255), c[1].int.coerceIn(0, 255), c[2].int.coerceIn(0, 255))
}

private val speeds = listOf(1 to "Silent", 2 to "Standard", 3 to "Sport")
private val optionTitles = listOf("leveling" to "Bed levelling", "flow" to "Flow calibration", "vibration" to "Vibration compensation")

@Composable
private fun PrinterScreen() {
	val printer = topic("printer")
	val link = link
	var tab by rememberSaveable { mutableStateOf("print") }
	var watching by remember { mutableStateOf(false) }
	Screen(
		"3D printer",
		subtitle = printer["status"].string + if (printer["firmware"].string.isNotEmpty()) " · ${printer["firmware"].string}" else "",
		actions = {
			if (printer["online"].bool) {
				IconButton(if (printer["light"].bool) "lightbulb_on" else "lightbulb_outline", color = if (printer["light"].bool) Theme.colors.primaryContainer else Theme.colors.layer2) {
					link.run("printer", "light", json("on" to !printer["light"].bool))
				}
				Spacer(Modifier.width(8.dp))
				IconButton("video_outline", color = Theme.colors.layer2) { watching = true }
			}
		},
	) {
		when {
			printer == null -> EmptyState("printer_3d", "Loading…")
			!printer["configured"].bool -> EmptyState("printer_3d", "Not set up", text = "The printer's address is set in its panel on the PC.")
			else -> {
				if (!printer["online"].bool) Panel {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Glyph("lan_disconnect", color = Theme.colors.danger)
						Spacer(Modifier.width(12.dp))
						Label(printer["error"].string.ifEmpty { "Offline" }, Modifier.weight(1f), color = Theme.colors.textMuted, maxLines = 3)
					}
				}
				Segmented(listOf("print" to "Print", "ace" to "ACE", "stats" to "Statistics"), tab, Modifier.fillMaxWidth()) { tab = it }
				when (tab) {
					"print" -> PrintTab(printer)
					"ace" -> AceTab(printer)
					else -> StatsTab(printer)
				}
			}
		}
	}
	if (watching) CameraSheet { watching = false }
}

// ── print ──────────────────────────────────────────────────────────────────
@Composable
private fun PrintTab(printer: JsonElement) {
	val link = link
	var stopping by remember { mutableStateOf(false) }
	if (printer["printing"].bool) {
		val paused = printer["paused"].bool
		Panel {
			val picture = link.blob(printer["frame"].string) ?: printer["jobs"].list.firstOrNull { it["id"].string == printer["printingJob"].string }?.let { link.blob(it["image"].string) }
			if (picture != null) {
				Box(Modifier.fillMaxWidth().aspectRatio(1.4f).clip(RoundedCornerShape(Theme.Radius.large)).background(Theme.colors.layer2), contentAlignment = Alignment.Center) {
					AsyncImage(model = picture, contentDescription = null, modifier = Modifier.fillMaxSize())
				}
				Spacer(Modifier.height(14.dp))
			}
			Row(verticalAlignment = Alignment.CenterVertically) {
				Ring(printer["progress"].float, size = 64.dp, color = if (paused) Theme.colors.warning else Theme.colors.primary) {
					Label("${Math.round(printer["progress"].double * 100)}%", style = Theme.Type.label)
				}
				Spacer(Modifier.width(14.dp))
				Column(Modifier.weight(1f)) {
					Label(printer["printingTitle"].string, style = Theme.Type.title, maxLines = 2)
					Label(printer["status"].string, style = Theme.Type.small, color = if (paused) Theme.colors.warning else Theme.colors.textMuted)
				}
			}
			Spacer(Modifier.height(14.dp))
			val left = printer["secondsLeft"].double
			val done = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(System.currentTimeMillis() + (left * 1000).toLong()))
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				Fact("Layer", "${printer["layer"].int} / ${printer["layers"].int}", Modifier.weight(1f))
				Fact("Left", duration(left), Modifier.weight(1f))
				Fact("Done at", done, Modifier.weight(1f))
			}
		}
	}
	Panel {
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Fact("Nozzle", heat(printer["nozzle"].double, printer["nozzleTarget"].double), Modifier.weight(1f), icon = "printer_3d_nozzle")
			Fact("Bed", heat(printer["bed"].double, printer["bedTarget"].double), Modifier.weight(1f), icon = "radiator")
		}
		val log = printer["nozzleLog"].list.map { it.float }
		if (log.size > 2) {
			Spacer(Modifier.height(10.dp))
			Sparkline(log, Modifier.fillMaxWidth().height(40.dp), color = Color(0xFFFF8A30), maximum = Math.max(300f, log.max()))
		}
		if (printer["printing"].bool) {
			Spacer(Modifier.height(12.dp))
			Segmented(speeds.map { it.first to it.second }, printer["speed"].int, Modifier.fillMaxWidth()) { link.run("printer", "speed", json("mode" to it)) }
			Spacer(Modifier.height(12.dp))
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				val paused = printer["paused"].bool
				SoftButton(if (paused) "Resume" else "Pause", Modifier.weight(1f), icon = if (paused) "play" else "pause") { link.run("printer", if (paused) "resume" else "pause") }
				SoftButton("Stop", Modifier.weight(1f), icon = "stop", tint = Theme.colors.danger) { stopping = true }
			}
		}
	}
	val jobs = printer["jobs"].list
	if (jobs.isNotEmpty()) {
		SectionLabel("Jobs")
		for (job in jobs) JobCard(printer, job)
	} else if (!printer["printing"].bool) EmptyState("tray_arrow_down", "No jobs", text = "G-code exported into the inbox on the PC shows up here.")
	if (stopping) Confirm("Stop the print", "Stop ${printer["printingTitle"].string}? It cannot be resumed.", confirm = "Stop", danger = true, onDismiss = { stopping = false }) {
		link.run("printer", "stop")
	}
}

private fun heat(now: Double, target: Double): String = if (target > 0) "${Math.round(now)}° / ${Math.round(target)}°" else "${Math.round(now)}°"

@Composable
private fun Fact(title: String, value: String, modifier: Modifier = Modifier, icon: String? = null) {
	Column(modifier.clip(RoundedCornerShape(Theme.Radius.large)).background(Theme.colors.layer2).padding(horizontal = 12.dp, vertical = 10.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			if (icon != null) {
				Glyph(icon, size = 14.dp, color = Theme.colors.textMuted)
				Spacer(Modifier.width(4.dp))
			}
			Label(title, style = Theme.Type.tiny, color = Theme.colors.textMuted)
		}
		Label(value, style = Theme.Type.label.copy(fontFeatureSettings = "tnum"))
	}
}

@Composable
private fun JobCard(printer: JsonElement, job: JsonElement) {
	val link = link
	val id = job["id"].string
	val slots = printer["slots"].list
	// tool → slot; the PC's suggestion until one is picked here
	val picks = remember(id) { mutableStateMapOf<Int, Int>() }
	LaunchedEffect(id, job["suggested"].toString()) {
		for (pick in job["suggested"].list) if (!picks.containsKey(pick["tool"].int)) picks[pick["tool"].int] = pick["slot"].int
	}
	var choosing by remember { mutableStateOf<Int?>(null) }
	var starting by remember { mutableStateOf(false) }
	var forgetting by remember { mutableStateOf(false) }
	val onPrinter = printer["printingJob"].string == id
	val filaments = job["filaments"].list
	Panel {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Box(Modifier.size(64.dp).clip(RoundedCornerShape(Theme.Radius.medium)).background(Theme.colors.layer2), contentAlignment = Alignment.Center) {
				val image = link.blob(job["image"].string) ?: link.blob(job["thumb"].string)
				if (image != null) AsyncImage(model = image, contentDescription = null, modifier = Modifier.fillMaxSize())
				else Glyph("cube_outline", color = Theme.colors.textMuted)
			}
			Spacer(Modifier.width(12.dp))
			Column(Modifier.weight(1f)) {
				Label(job["title"].string, style = Theme.Type.title, maxLines = 2)
				val facts = listOf(
					if (job["seconds"].double > 0) duration(job["seconds"].double) else "",
					if (job["grams"].double > 0) grams(job["grams"].double) else "",
					if (job["layers"].int > 0) "${job["layers"].int} layers" else "",
				).filter { it.isNotEmpty() }.joinToString(" · ")
				if (facts.isNotEmpty()) Label(facts, style = Theme.Type.small, color = Theme.colors.textMuted)
				val state = when {
					onPrinter -> "Printing"
					job["sending"].bool -> "Sending to the printer"
					job["rendering"].bool -> "Reading the G-code"
					job["status"].string == "failed" -> "The last try failed"
					job["status"].string == "sent" -> "Sent " + SimpleDateFormat("d MMM, HH:mm", Locale.getDefault()).format(Date(job["printed"].long))
					else -> ""
				}
				if (state.isNotEmpty()) Label(state, style = Theme.Type.small, color = if (job["status"].string == "failed") Theme.colors.danger else Theme.colors.primary)
			}
		}
		if (!onPrinter && filaments.isNotEmpty()) {
			Spacer(Modifier.height(12.dp))
			for (filament in filaments) {
				val tool = filament["tool"].int
				val slot = slots.firstOrNull { it["slot"].int == (picks[tool] ?: -1) }
				Row(
					Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.Radius.medium)).background(Theme.colors.layer2).padding(horizontal = 12.dp, vertical = 10.dp),
					verticalAlignment = Alignment.CenterVertically,
				) {
					Swatch(rgb(filament["color"]))
					Spacer(Modifier.width(10.dp))
					Label("${filament["type"].string.ifEmpty { "Filament" }} · ${grams(filament["grams"].double)}", Modifier.weight(1f), style = Theme.Type.small)
					Glyph("arrow_left", size = 16.dp, color = Theme.colors.textSubtle)
					Spacer(Modifier.width(8.dp))
					Chip(if (slot != null) "Slot ${slot["slot"].int + 1}" else "Pick a slot", icon = null, active = slot == null, tint = if (slot == null) null else rgb(slot["color"]).takeIf { slot["type"].string.isNotEmpty() }) { choosing = tool }
				}
				Spacer(Modifier.height(6.dp))
			}
		}
		if (!onPrinter) {
			Spacer(Modifier.height(8.dp))
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
				SoftButton("Forget", Modifier.weight(1f), icon = "delete_outline") { forgetting = true }
				val ready = filaments.isNotEmpty() && filaments.all { f -> slots.any { it["slot"].int == (picks[f["tool"].int] ?: -1) } }
				PrimaryButton("Print", Modifier.weight(1f), icon = "printer_3d", enabled = ready && printer["online"].bool && !printer["printing"].bool && !job["sending"].bool && !job["rendering"].bool) { starting = true }
			}
		}
	}
	choosing?.let { tool ->
		Sheet({ choosing = null }, "Slot for filament ${tool + 1}") { close ->
			for (slot in slots) {
				val empty = slot["type"].string.isEmpty()
				Row(
					Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.Radius.large))
						.background(if (picks[tool] == slot["slot"].int) Theme.colors.primaryContainer else Theme.colors.layer2)
						.padding(horizontal = 14.dp, vertical = 12.dp),
					verticalAlignment = Alignment.CenterVertically,
				) {
					Swatch(if (empty) Theme.colors.layer3 else rgb(slot["color"]))
					Spacer(Modifier.width(12.dp))
					Label("Slot ${slot["slot"].int + 1}", Modifier.weight(1f), style = Theme.Type.label)
					Label(if (empty) "Empty" else "${slot["type"].string} · ${slot["percent"].int} %", style = Theme.Type.small, color = Theme.colors.textMuted)
					Spacer(Modifier.width(8.dp))
					if (!empty) SoftButton("Use") {
						picks[tool] = slot["slot"].int
						close()
					}
				}
			}
		}
	}
	if (starting) {
		Sheet({ starting = false }, "Print ${job["title"].string}") { close ->
			val options = printer["options"]
			for ((key, title) in optionTitles) {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Label(title, Modifier.weight(1f))
					Toggle(options[key].bool) { link.run("printer", "option", json("key" to key, "value" to it)) }
				}
			}
			Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
				SoftButton("Cancel", Modifier.weight(1f).padding(vertical = 4.dp), onClick = close)
				PrimaryButton("Print", Modifier.weight(1f), icon = "printer_3d") {
					link.run("printer", "print", json("id" to id, "mapping" to filaments.map { json("tool" to it["tool"].int, "slot" to (picks[it["tool"].int] ?: -1)) }))
					close()
				}
			}
		}
	}
	if (forgetting) Confirm("Forget the job", "Remove ${job["title"].string} and its folder?", confirm = "Forget", danger = true, onDismiss = { forgetting = false }) {
		link.run("printer", "forget", json("id" to id))
	}
}

@Composable
private fun Swatch(color: Color) {
	Box(Modifier.size(22.dp).clip(CircleShape).background(color))
}

// ── ACE ────────────────────────────────────────────────────────────────────
@Composable
private fun AceTab(printer: JsonElement) {
	val link = link
	val ace = printer["ace"]
	if (!ace.present) {
		EmptyState("printer_3d", "No ACE")
		return
	}
	val loaded = ace["loaded"].int
	Panel {
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Fact("Humidity", if (ace["humidity"].double > 0) "${Math.round(ace["humidity"].double)} %" else "–", Modifier.weight(1f), icon = "water_percent")
			Fact("Temperature", "${Math.round(ace["temp"].double)} °C", Modifier.weight(1f), icon = "thermometer")
		}
		Spacer(Modifier.height(12.dp))
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			for (slot in printer["slots"].list) {
				val empty = slot["type"].string.isEmpty()
				val feeding = slot["index"].int == loaded && printer["printing"].bool
				Column(
					Modifier.weight(1f).clip(RoundedCornerShape(Theme.Radius.large)).background(if (feeding) Theme.colors.primaryContainer else Theme.colors.layer2).padding(vertical = 12.dp),
					horizontalAlignment = Alignment.CenterHorizontally,
				) {
					Box(Modifier.size(38.dp).clip(CircleShape).background(if (empty) Theme.colors.layer3 else rgb(slot["color"])), contentAlignment = Alignment.Center) {
						if (feeding) Glyph("arrow_down", size = 18.dp, color = Color.White)
					}
					Spacer(Modifier.height(6.dp))
					Label(if (empty) "Empty" else slot["type"].string, style = Theme.Type.label)
					Label("Slot ${slot["slot"].int + 1}", style = Theme.Type.tiny, color = Theme.colors.textMuted)
					if (!empty) {
						Spacer(Modifier.height(6.dp))
						Box(Modifier.padding(horizontal = 10.dp)) { Meter(slot["percent"].float / 100f, height = 4.dp) }
					}
				}
			}
		}
	}
	var preset by rememberSaveable { mutableStateOf("PLA") }
	var asking by remember { mutableStateOf(false) }
	Panel {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("fan", color = if (ace["drying"].bool) Theme.colors.primary else Theme.colors.textMuted)
			Spacer(Modifier.width(10.dp))
			Label("Drying", Modifier.weight(1f), style = Theme.Type.title)
		}
		Spacer(Modifier.height(12.dp))
		if (ace["drying"].bool) {
			val total = ace["dryDuration"].double
			val left = ace["dryLeft"].double
			Label("${Math.round(ace["dryTarget"].double)}° · ${duration(left * 60)} left", color = Theme.colors.textMuted)
			Spacer(Modifier.height(8.dp))
			Meter(if (total > 0) (1 - left / total).toFloat() else 0f)
			Spacer(Modifier.height(12.dp))
			SoftButton("Stop drying", Modifier.fillMaxWidth(), icon = "stop", tint = Theme.colors.danger) { asking = true }
		} else {
			val presets = printer["dryPresets"].list
			Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				for (entry in presets) Chip(entry["label"].string, active = entry["label"].string == preset) { preset = entry["label"].string }
			}
			presets.firstOrNull { it["label"].string == preset }?.let {
				Spacer(Modifier.height(8.dp))
				Label("${it["temp"].int}° · ${it["minutes"].int / 60} h", style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			Spacer(Modifier.height(12.dp))
			PrimaryButton("Start drying", Modifier.fillMaxWidth(), icon = "fan", enabled = printer["online"].bool) { asking = true }
		}
	}
	if (asking) {
		val drying = ace["drying"].bool
		Confirm(
			if (drying) "Stop drying" else "Dry the filament",
			if (drying) "Stop drying now?" else "Dry at the $preset preset?",
			confirm = if (drying) "Stop" else "Start",
			danger = drying,
			onDismiss = { asking = false },
		) {
			if (drying) link.run("printer", "dry", json("on" to false)) else link.run("printer", "dry", json("on" to true, "preset" to preset))
		}
	}
}

// ── statistics ─────────────────────────────────────────────────────────────
@Composable
private fun StatsTab(printer: JsonElement) {
	val stats = printer["stats"]
	if (stats["count"].int == 0) {
		EmptyState("chart_bar", "No prints yet")
		return
	}
	Panel {
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Fact("Prints", "${stats["count"].int}", Modifier.weight(1f))
			Fact("Success", "${Math.round(stats["rate"].double * 100)} %", Modifier.weight(1f))
		}
		Spacer(Modifier.height(8.dp))
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Fact("Hours", String.format(Locale.ROOT, "%.1f", stats["minutes"].double / 60), Modifier.weight(1f))
			Fact("Filament", grams(stats["grams"].double), Modifier.weight(1f))
		}
		val days = stats["days"].list
		if (days.isNotEmpty()) {
			Spacer(Modifier.height(16.dp))
			Label("Last two weeks", style = Theme.Type.small, color = Theme.colors.textMuted)
			Spacer(Modifier.height(8.dp))
			val most = Math.max(1.0, days.maxOf { it["minutes"].double })
			Row(Modifier.fillMaxWidth().height(72.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
				for (day in days) {
					val share = (day["minutes"].double / most).toFloat()
					Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
						Box(
							Modifier.fillMaxWidth().fillMaxHeight(Math.max(0.04f, share)).clip(RoundedCornerShape(4.dp))
								.background(if (day["failed"].int > 0) Theme.colors.danger else if (day["count"].int > 0) Theme.colors.primary else Theme.colors.layer3),
						)
					}
				}
			}
		}
		val colours = stats["colours"].list
		if (colours.isNotEmpty()) {
			Spacer(Modifier.height(16.dp))
			Label("Filament by colour", style = Theme.Type.small, color = Theme.colors.textMuted)
			Spacer(Modifier.height(8.dp))
			for (entry in colours) {
				Row(Modifier.padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
					Swatch(rgb(entry["color"]))
					Spacer(Modifier.width(10.dp))
					Label(entry["type"].string.ifEmpty { "Filament" }, Modifier.weight(1f), style = Theme.Type.small)
					Label(grams(entry["grams"].double), style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
				}
			}
		}
	}
	val history = printer["history"].list
	if (history.isNotEmpty()) {
		SectionLabel("Last prints")
		Panel(padding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
			for (item in history) {
				val finished = item["result"].string == "finished"
				Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
					Glyph(if (finished) "check_circle_outline" else "close_circle_outline", size = 18.dp, color = if (finished) Theme.colors.success else Theme.colors.danger)
					Spacer(Modifier.width(10.dp))
					Column(Modifier.weight(1f)) {
						Label(item["title"].string, style = Theme.Type.label)
						val ended = item["ended"].long
						val when_ = if (ended > 0) SimpleDateFormat("d MMM, HH:mm", Locale.getDefault()).format(Date(ended)) else ""
						Label(
							listOf(when_, duration(item["minutes"].double * 60), if (!finished) "at ${item["progress"].int} %" else "").filter { it.isNotEmpty() }.joinToString(" · "),
							style = Theme.Type.tiny, color = Theme.colors.textMuted,
						)
					}
					if (item["grams"].double > 0) Label(grams(item["grams"].double), style = Theme.Type.small, color = Theme.colors.textMuted)
				}
			}
		}
	}
}

// ── camera ─────────────────────────────────────────────────────────────────
/** The printer's stream, through the PC; it runs while the sheet is open. */
@OptIn(UnstableApi::class)
@Composable
private fun CameraSheet(onDismiss: () -> Unit) {
	val link = link
	val context = LocalContext.current
	var playing by remember { mutableStateOf(false) }
	var failed by remember { mutableStateOf(0) }
	val player = remember {
		ExoPlayer.Builder(context).build().apply {
			volume = 0f
			playWhenReady = true
		}
	}
	fun load() {
		val source = ProgressiveMediaSource.Factory(OkHttpDataSource.Factory(link.http)).createMediaSource(MediaItem.fromUri("https://pc.pshell/stream/printer"))
		player.setMediaSource(source)
		player.prepare()
	}
	DisposableEffect(Unit) {
		link.run("printer", "camera", json("on" to true))
		val listener = object : Player.Listener {
			override fun onIsPlayingChanged(isPlaying: Boolean) {
				playing = isPlaying
			}

			override fun onPlayerError(error: PlaybackException) {
				failed += 1
			}
		}
		player.addListener(listener)
		onDispose {
			player.removeListener(listener)
			player.release()
			link.run("printer", "camera", json("on" to false))
		}
	}
	// the printer needs a moment before its stream answers
	LaunchedEffect(failed) {
		delay(if (failed == 0) 1500L else 2500L)
		if (failed < 12) load()
	}
	Sheet(onDismiss, "Camera") {
		Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(Theme.Radius.large)).background(Color.Black), contentAlignment = Alignment.Center) {
			AndroidView(
				factory = {
					PlayerView(it).apply {
						useController = false
						resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
						this.player = player
					}
				},
				modifier = Modifier.fillMaxSize(),
			)
			if (!playing) Label(if (failed >= 12) "The camera does not answer" else "Waking the camera", color = Color.White.copy(alpha = 0.7f), style = Theme.Type.small)
		}
	}
}
