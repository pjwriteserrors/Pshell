package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.double
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.pressable
import kotlinx.serialization.json.JsonElement
import kotlin.math.abs
import kotlin.math.roundToInt

// ── screen time: where the time at the PC's screen went ────────────────────
val ScreentimeFeature = Feature(
	id = "screentime",
	title = "Screen time",
	icon = "progress_clock",
	group = Group.Pc,
	plugins = listOf("screentime"),
	keywords = listOf("bildschirmzeit", "usage", "nutzung", "apps", "week", "woche"),
	summary = { topic("screentime")["total"].long.let { if (it > 0) screenTime(it) else "" } },
	screen = { ScreentimeScreen() },
)

/** Seconds as the shell's panel says them: "42 min", "5 h 07". */
private fun screenTime(seconds: Long): String {
	val minutes = (seconds / 60.0).roundToInt()
	if (seconds > 0 && minutes == 0) return "<1 min"
	return if (minutes < 60) "$minutes min" else "%d h %02d".format(minutes / 60, minutes % 60)
}

@Composable
private fun ScreentimeScreen() {
	val today = topic("screentime")
	val link = link
	// an earlier day and what the PC answered for it; the topic itself is always today
	var picked by remember { mutableStateOf<String?>(null) }
	var earlier by remember { mutableStateOf<JsonElement?>(null) }
	var kind by remember { mutableStateOf("apps") }
	LaunchedEffect(picked) {
		val key = picked ?: return@LaunchedEffect
		try {
			earlier = link.call("screentime", "day", json("key" to key))
		} catch (error: LinkError) {
			link.toast(link.describe(error))
			picked = null
		}
	}
	// the day shown last stays until the picked one has arrived
	val day = if (picked == null) today else earlier ?: today
	val onToday = day["day"].string == today["today"].string
	fun pick(key: String) {
		picked = key.takeIf { it != today["today"].string }
	}
	fun step(days: Long) {
		runCatching { java.time.LocalDate.parse(day["day"].string).plusDays(days).toString() }.getOrNull()?.let { pick(it) }
	}
	Screen("Screen time", subtitle = if (onToday) "Today" else day["label"].string, actions = {
		IconButton("chevron_left", color = Theme.colors.layer2, enabled = day["earlier"].bool) { step(-1) }
		IconButton("chevron_right", color = Theme.colors.layer2, enabled = day.present && !onToday) { step(1) }
	}) {
		if (day == null) {
			EmptyState("progress_clock", "Loading…")
			return@Screen
		}
		Panel {
			Label(screenTime(day["total"].long), style = Theme.Type.hero.copy(fontFeatureSettings = "tnum"))
			day["versus"]?.let { versus ->
				val seconds = versus["seconds"].long
				val more = seconds >= 60
				val less = seconds <= -60
				val tone = if (more) Theme.colors.warning else if (less) Theme.colors.success else Theme.colors.textMuted
				Row(verticalAlignment = Alignment.CenterVertically) {
					Glyph(if (more) "arrow_top_right" else if (less) "arrow_bottom_right" else "arrow_right", size = 16.dp, color = tone)
					Spacer(Modifier.width(6.dp))
					Label(
						(if (more || less) "${if (more) "+" else "−"} ${screenTime(abs(seconds))} · ${(abs(versus["ratio"].double) * 100).roundToInt()} %" else "The same") +
							if (onToday) " vs yesterday by now" else " vs the day before",
						style = Theme.Type.small, color = tone,
					)
				}
			}
			if (day["longest"].long >= 60) {
				Spacer(Modifier.height(4.dp))
				Label("Longest stretch ${screenTime(day["longest"].long)} · until ${day["longestEnd"].string}", style = Theme.Type.small, color = Theme.colors.textSubtle)
			}
		}
		val week = day["week"].list
		SectionLabel("Week")
		Panel {
			val most = week.maxOfOrNull { it["total"].long }?.coerceAtLeast(1) ?: 1
			Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
				for (each in week) {
					val chosen = each["key"].string == day["day"].string
					val ahead = each["ahead"].bool
					Column(
						Modifier.weight(1f).pressable(enabled = !ahead, shape = RoundedCornerShape(Theme.Radius.medium)) { pick(each["key"].string) },
						horizontalAlignment = Alignment.CenterHorizontally,
					) {
						Label(if (each["total"].long >= 60) hours(each["total"].long) else "", style = Theme.Type.tiny.copy(fontFeatureSettings = "tnum"), color = if (chosen) Theme.colors.text else Theme.colors.textSubtle)
						Spacer(Modifier.height(4.dp))
						Box(Modifier.height(96.dp).fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
							Box(
								Modifier
									.fillMaxWidth(0.62f)
									.height((92f * each["total"].long / most).dp + 4.dp)
									.clip(RoundedCornerShape(Theme.Radius.small))
									.background(if (chosen) Theme.colors.primary else Theme.colors.layer3),
							)
						}
						Spacer(Modifier.height(6.dp))
						Label(each["label"].string, style = Theme.Type.tiny, color = if (chosen) Theme.colors.primary else if (ahead) Theme.colors.textFaint else Theme.colors.textMuted)
					}
				}
			}
		}
		val kinds = day["kinds"].list.map { it["value"].string to it["label"].string }
		if (kinds.isNotEmpty()) Segmented(kinds, kind, Modifier.fillMaxWidth()) { kind = it }
		val rows = day["rows"][kind].list
		if (rows.isEmpty()) {
			val unlinked = kind == "links" && !day["browserLinked"].bool
			EmptyState(if (unlinked) "link_variant_off" else "progress_clock", if (unlinked) "No browser linked" else "Nothing counted")
		} else Panel(padding = PaddingValues(6.dp)) {
			for (row in rows) ListRow(
				row["label"].string,
				icon = row["icon"].string.takeIf { Icons.has(it) } ?: "application",
				subtitle = row["detail"].string,
				iconBackground = Theme.colors.layer2,
			) {
				Spacer(Modifier.width(10.dp))
				Label(screenTime(row["seconds"].long), style = Theme.Type.label.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
			}
		}
	}
}

/** 5:42, over a bar of the week. */
private fun hours(seconds: Long): String {
	val minutes = (seconds / 60.0).roundToInt()
	return "%d:%02d".format(minutes / 60, minutes % 60)
}
