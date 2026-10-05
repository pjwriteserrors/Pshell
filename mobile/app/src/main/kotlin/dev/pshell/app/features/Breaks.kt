package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.present
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.Ring
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle
import kotlinx.serialization.json.JsonElement

val BreaksFeature = Feature(
	id = "breaks",
	title = "Breaks",
	icon = "cup_water",
	plugins = listOf("breaks"),
	card = { open -> BreaksCard(open) },
	screen = { BreaksScreen() },
)

private fun litres(ml: Int) = if (ml % 100 == 0) "%.1f L".format(ml / 1000f) else "%.2f L".format(ml / 1000f)

private fun duration(seconds: Int): String {
	val minutes = Math.round(seconds / 60f)
	return if (minutes < 60) "$minutes min" else "${minutes / 60} h ${"%02d".format(minutes % 60)}"
}

@Composable
private fun BreaksCard(open: () -> Unit) {
	val breaks = topic("breaks") ?: return
	val water = breaks["water"] ?: return
	val link = link
	Panel(onClick = open, padding = PaddingValues(start = 14.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Ring((water["ml"].float / water["goal"].float.coerceAtLeast(1f)), size = 52.dp, thickness = 5.dp, color = Theme.colors.tertiary) {
				Glyph("cup_water", size = 20.dp, color = Theme.colors.tertiary)
			}
			Spacer(Modifier.width(14.dp))
			Column(Modifier.weight(1f)) {
				Label("${litres(water["ml"].int)} of ${litres(water["goal"].int)}", style = Theme.Type.title)
				Label("${duration(breaks["screen"].int)} at the screen · ${breaks["taken"].int} breaks", style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			IconButton("plus", color = Theme.colors.layer3) { link.run("breaks", "glass") }
		}
	}
}

@Composable
private fun Countdown(icon: String, title: String, entry: JsonElement, color: Color, modifier: Modifier = Modifier) {
	val since = entry["since"].float
	val every = entry["every"].float.coerceAtLeast(1f)
	val left = (every - since).coerceAtLeast(0f)
	Panel(modifier, padding = PaddingValues(14.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Ring(since / every, size = 46.dp, thickness = 5.dp, color = color) { Glyph(icon, size = 18.dp, color = color) }
			Spacer(Modifier.width(12.dp))
			Column {
				Label(title, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
				Label(if (left <= 0f) "due" else "in ${duration(left.toInt())}", style = Theme.Type.small, color = Theme.colors.textMuted)
			}
		}
	}
}

@Composable
private fun BreaksScreen() {
	val breaks = topic("breaks")
	val link = link
	Screen("Breaks", subtitle = "${duration(breaks["screen"].int)} at the screen today", actions = {
		Toggle(breaks["enabled"].bool) { link.run("breaks", "enable", json("on" to it)) }
	}) {
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			breaks["eyes"]?.let { Countdown("eye_outline", "Eyes", it, Theme.colors.primary, Modifier.weight(1f)) }
			breaks["move"]?.let { Countdown("walk", "Stretch", it, Theme.colors.secondary, Modifier.weight(1f)) }
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			if (breaks["eyes"].present) SoftButton("Rest eyes on the PC", Modifier.weight(1f), icon = "eye_outline") { link.run("breaks", "eyeRest") }
			SoftButton("I took a break", Modifier.weight(1f), icon = "check") { link.run("breaks", "took") }
		}

		breaks["water"]?.let { water ->
			SectionLabel("Water")
			Panel {
				Row(verticalAlignment = Alignment.CenterVertically) {
					Ring(water["ml"].float / water["goal"].float.coerceAtLeast(1f), size = 84.dp, thickness = 8.dp, color = Theme.colors.tertiary) {
						Label(litres(water["ml"].int), style = Theme.Type.label)
					}
					Spacer(Modifier.width(16.dp))
					Column(Modifier.weight(1f)) {
						Label("of ${litres(water["goal"].int)} today", style = Theme.Type.title)
						Label("${water["glasses"].int} glasses · by now ${litres(water["pace"].int)}", style = Theme.Type.small, color = Theme.colors.textMuted)
					}
				}
				Spacer(Modifier.height(14.dp))
				Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					SoftButton("Glass", Modifier.weight(1f), icon = "plus") { link.run("breaks", "glass") }
					SoftButton("Take one back", Modifier.weight(1f), icon = "minus") { link.run("breaks", "removeGlass") }
				}
			}
			val size = water["bottle"].float.coerceAtLeast(1f)
			Label("What is left in the bottle", Modifier.padding(start = 6.dp), style = Theme.Type.small, color = Theme.colors.textMuted)
			PillSlider(water["bottleLeft"].float / size, icon = "bottle_soda_outline", label = "${water["bottleLeft"].int} ml", color = Theme.colors.tertiary, onChangeFinished = {
				link.run("breaks", "bottle", json("left" to Math.round(it * size)))
			}) {}
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				Chip("Refill", icon = "refresh") { link.run("breaks", "refill") }
				for (option in water["bottleSizes"].list) Chip("${option.int} ml", active = option.int == water["bottle"].int) { link.run("breaks", "bottleSize", json("ml" to option.int)) }
			}
		}

		breaks["headaches"]?.let { headaches ->
			SectionLabel("Headache")
			Panel(padding = PaddingValues(6.dp)) {
				ListRow("Log a headache", icon = "head_alert_outline", subtitle = if (headaches.list.isEmpty()) "None today" else "${headaches.list.size} today", iconBackground = Theme.colors.dangerContainer, iconTint = Theme.colors.danger, onClick = { link.run("breaks", "headache") })
			}
		}

		val week = breaks["week"].list
		if (week.isNotEmpty()) {
			SectionLabel("This week")
			Panel {
				Row(Modifier.fillMaxWidth().height(96.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Bottom) {
					val goal = breaks["water"]["goal"].float.takeIf { it > 0f } ?: 1500f
					for ((index, day) in week.withIndex()) {
						Column(Modifier.weight(1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
							if (day["headaches"].int > 0) Glyph("head_alert_outline", size = 14.dp, color = Theme.colors.danger)
							Spacer(Modifier.height(4.dp))
							Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.BottomCenter) {
								Box(Modifier.fillMaxWidth().fillMaxHeight((day["ml"].float / goal).coerceIn(0.04f, 1f)).clip(RoundedCornerShape(10.dp)).background(if (day["ahead"].bool) Theme.colors.layer3 else Theme.colors.tertiary))
							}
							Spacer(Modifier.height(6.dp))
							Label(listOf("Mo", "Tu", "We", "Th", "Fr").getOrElse(index) { "" }, style = Theme.Type.tiny, color = Theme.colors.textSubtle, align = TextAlign.Center)
						}
					}
				}
			}
		}
	}
}
