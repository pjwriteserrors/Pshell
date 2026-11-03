package dev.pshell.app.features

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Ring
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.zepp.WatchLink
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

// ── what the watch measured: sleep, heart, activity, stress, blood oxygen ─────
// From the phone's own store (fetched over its link to the watch), with what
// the PC fetched when it is connected (the topic "health").
val HealthFeature = Feature(
	id = "health",
	title = "Health",
	icon = "heart_pulse",
	group = Group.Link,
	keywords = listOf("gesundheit", "schlaf", "sleep", "puls", "heart", "schritte", "steps", "stress", "spo2", "amazfit", "watch"),
	screen = { HealthScreen() },
)

private val stageColors = mapOf("deep" to Color(0xFF3F51B5), "light" to Color(0xFF7986CB), "rem" to Color(0xFF26A69A), "wake" to Color(0xFFFFB74D))

@Composable
private fun HealthScreen() {
	val context = LocalContext.current
	val state by WatchLink.flow.collectAsState()
	val pc = topic("health")
	val store = remember { WatchLink.store(context) }
	var version by remember { mutableIntStateOf(0) }
	LaunchedEffect(pc) { if (pc != null) { store.merge(JSONObject(pc.toString())); version++ } }
	LaunchedEffect(state.fetchedAt) { version++ }
	val scope = rememberCoroutineScope()
	var note by remember { mutableStateOf("") }
	val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
		if (uri == null) return@rememberLauncherForActivityResult
		scope.launch {
			note = "Importing …"
			note = withContext(Dispatchers.IO) {
				runCatching {
					val copy = java.io.File(context.cacheDir, "gadgetbridge.db")
					context.contentResolver.openInputStream(uri)!!.use { i -> copy.outputStream().use { i.copyTo(it) } }
					val dates = store.importGadgetbridge(copy.path)
					val (days, nights) = store.build(dates)
					store.save()
					copy.delete()
					dev.pshell.app.zepp.WatchPhone.health(context, days, nights, null)
					"${days.size} days and ${nights.size} nights from Gadgetbridge"
				}.getOrElse { "Could not read it: ${it.message}" }
			}
			version++
		}
	}
	val days = remember(version) { store.days.values.toList() }
	val nights = remember(version) { store.nights.values.toList() }

	Screen("Health", subtitle = when {
		state.fetching -> "Fetching from the watch …"
		state.fetchedAt > 0 -> "Fetched " + java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(state.fetchedAt))
		else -> "From the watch"
	}) {
		if (days.isEmpty() && nights.isEmpty()) {
			EmptyState("heart_pulse", "Nothing measured yet", text = "Keep the watch connected (Watch → Instead of Gadgetbridge), or import Gadgetbridge's database export for the history.") {
				SoftButton("Import from Gadgetbridge", icon = "database_import") { pick.launch(arrayOf("*/*")) }
			}
			if (note.isNotEmpty()) Label(note, color = Theme.colors.textMuted)
			return@Screen
		}
		val night = nights.lastOrNull()
		if (night != null) NightCard(night)
		if (nights.size > 1) {
			SectionLabel("Nights")
			Panel { NightBars(nights.takeLast(14)) }
		}
		val today = days.lastOrNull()
		if (today != null) {
			SectionLabel(if (today.getString("date") == LocalDate.now().toString()) "Today" else today.getString("date"))
			DayCard(today)
			today.optJSONArray("heart")?.let { h -> SectionLabel("Heart rate"); Panel { Line(h, Color(0xFFEF5350), "bpm") } }
			today.optJSONArray("stress")?.let { h -> SectionLabel("Stress by the hour"); Panel { Bars(h, 100.0, Color(0xFFFFA726)) } }
			today.optJSONArray("oxygen")?.let { h -> SectionLabel("Blood oxygen by the hour"); Panel { Bars(h, 100.0, Color(0xFF42A5F5), low = 80.0) } }
			today.optJSONArray("temperature")?.let { h -> if ((0 until h.length()).any { h.getDouble(it) > 0 }) { SectionLabel("Skin temperature"); Panel { Line(h, Color(0xFFAB47BC), "°C") } } }
		}
		if (days.size > 1) {
			SectionLabel("Steps, the last 14 days")
			Panel { StepBars(days.takeLast(14)) }
		}
		Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			SoftButton("Fetch now", icon = "download") { WatchLink.fetchNow() }
			SoftButton("Import from Gadgetbridge", icon = "database_import") { pick.launch(arrayOf("*/*")) }
		}
		if (note.isNotEmpty()) Label(note, color = Theme.colors.textMuted)
	}
}

private fun hm(minutes: Int) = "${minutes / 60} h ${"%02d".format(minutes % 60)}"
private fun clock(t: Long) = Instant.ofEpochSecond(t).atZone(ZoneId.systemDefault()).toLocalTime().toString().take(5)

@Composable
private fun NightCard(n: JSONObject) {
	val grow = remember(n.getString("date")) { Animatable(0f) }
	LaunchedEffect(n.getString("date")) { grow.animateTo(1f, tween(900)) }
	Panel {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Column(Modifier.weight(1f)) {
				Label("Last night", color = Theme.colors.textMuted, style = Theme.Type.small)
				Label(hm((n.getInt("total") * grow.value).toInt()), style = Theme.Type.heading)
				Label("${clock(n.getLong("bed"))} – ${clock(n.getLong("wake"))}" + (if (n.optBoolean("estimated")) " · estimated" else ""), color = Theme.colors.textMuted)
			}
			val score = n.optInt("score")
			if (score > 0) Ring(score / 100f * grow.value, modifier = Modifier.size(64.dp))
			if (score > 0) Label("$score", modifier = Modifier.padding(start = 8.dp), style = Theme.Type.heading)
		}
		Spacer(Modifier.height(12.dp))
		Hypnogram(n.getJSONArray("stages"), n.getInt("total") + n.optInt("awake"), grow.value)
		Spacer(Modifier.height(8.dp))
		Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
			for ((k, name) in listOf("deep" to "Deep", "light" to "Light", "rem" to "REM", "awake" to "Awake")) {
				Column {
					Label(name, color = stageColors[if (k == "awake") "wake" else k]!!, style = Theme.Type.small)
					Label(hm(n.optInt(k)))
				}
			}
		}
		val extra = listOfNotNull(n.optInt("avgHr").takeIf { it > 0 }?.let { "♥ $it bpm" }, n.optDouble("breathing", 0.0).takeIf { it > 0 }?.let { "$it breaths/min" })
		if (extra.isNotEmpty()) Label(extra.joinToString(" · "), color = Theme.colors.textMuted, modifier = Modifier.padding(top = 6.dp))
	}
}

@Composable
private fun Hypnogram(stages: JSONArray, length: Int, grow: Float) {
	val levels = mapOf("wake" to 0, "rem" to 1, "light" to 2, "deep" to 3)
	Canvas(Modifier.fillMaxWidth().height(90.dp)) {
		val total = maxOf(1, length).toFloat()
		val row = size.height / 4
		for (i in 0 until stages.length()) {
			val s = stages.getJSONArray(i)
			val x0 = s.getInt(1) / total * size.width
			val x1 = s.getInt(2) / total * size.width
			if (x0 > size.width * grow) continue
			val level = levels[s.getString(0)] ?: 2
			drawRoundRect(stageColors[s.getString(0)] ?: Color.Gray, Offset(x0, level * row + 2), Size(maxOf(2f, minOf(x1, size.width * grow) - x0), row - 4), CornerRadius(4f, 4f))
		}
	}
}

@Composable
private fun NightBars(nights: List<JSONObject>) {
	val most = maxOf(480, nights.maxOf { it.getInt("total") })
	Canvas(Modifier.fillMaxWidth().height(110.dp)) {
		val w = size.width / nights.size
		nights.forEachIndexed { i, n ->
			var y = size.height
			for (k in listOf("deep", "light", "rem")) {
				val h = n.optInt(k) / most.toFloat() * size.height
				drawRoundRect(stageColors[k]!!, Offset(i * w + w * 0.15f, y - h), Size(w * 0.7f, h), CornerRadius(3f, 3f))
				y -= h
			}
		}
	}
}

@Composable
private fun DayCard(d: JSONObject) {
	Panel {
		Row(horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
			Ring(minOf(1f, d.optInt("steps") / 8000f), modifier = Modifier.size(56.dp))
			Column(Modifier.weight(1f)) {
				Label("${d.optInt("steps")} steps", style = Theme.Type.heading)
				Label(listOfNotNull(
					d.optInt("resting").takeIf { it > 0 }?.let { "resting ♥ $it" },
					d.optInt("max").takeIf { it > 0 }?.let { "max $it" },
					d.optInt("stressDay").takeIf { it > 0 }?.let { "stress $it" },
					d.optInt("oxygenNow").takeIf { it > 0 }?.let { "SpO₂ $it %" },
					d.optInt("hrv").takeIf { it > 0 }?.let { "HRV $it ms" },
					d.optInt("pai").takeIf { it > 0 }?.let { "PAI ${d.optInt("pai")}" },
				).joinToString(" · "), color = Theme.colors.textMuted, maxLines = 3)
			}
		}
	}
}

@Composable
private fun Line(values: JSONArray, color: Color, unit: String) {
	val v = (0 until values.length()).map { values.getDouble(it) }
	val shown = v.filter { it > 0 }
	if (shown.isEmpty()) return Label("Nothing yet", color = Theme.colors.textMuted)
	val lo = shown.min() - 2; val hi = shown.max() + 2
	Label("%.0f – %.0f %s".format(shown.min(), shown.max(), unit), color = Theme.colors.textMuted, style = Theme.Type.small)
	Canvas(Modifier.fillMaxWidth().height(100.dp).padding(top = 6.dp)) {
		val path = Path()
		var started = false
		v.forEachIndexed { i, x ->
			if (x <= 0) { started = false; return@forEachIndexed }
			val px = i / (v.size - 1f) * size.width
			val py = size.height - ((x - lo) / (hi - lo)).toFloat() * size.height
			if (!started) path.moveTo(px, py) else path.lineTo(px, py)
			started = true
		}
		drawPath(path, color, style = Stroke(width = 4f, cap = StrokeCap.Round))
	}
}

@Composable
private fun Bars(values: JSONArray, max: Double, color: Color, low: Double = 0.0) {
	val v = (0 until values.length()).map { values.getDouble(it) }
	Canvas(Modifier.fillMaxWidth().height(80.dp)) {
		val w = size.width / v.size
		v.forEachIndexed { i, x ->
			if (x <= 0) return@forEachIndexed
			val h = ((x - low) / (max - low)).coerceIn(0.05, 1.0).toFloat() * size.height
			drawRoundRect(color, Offset(i * w + w * 0.15f, size.height - h), Size(w * 0.7f, h), CornerRadius(3f, 3f))
		}
	}
}

@Composable
private fun StepBars(days: List<JSONObject>) {
	val most = maxOf(8000, days.maxOf { it.optInt("steps") })
	val color = Theme.colors.primary
	Canvas(Modifier.fillMaxWidth().height(90.dp)) {
		val w = size.width / days.size
		days.forEachIndexed { i, d ->
			val h = d.optInt("steps") / most.toFloat() * size.height
			drawRoundRect(color, Offset(i * w + w * 0.15f, size.height - h), Size(w * 0.7f, maxOf(2f, h)), CornerRadius(3f, 3f))
		}
	}
}
