package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonElement

// ── converter ──────────────────────────────────────────────────────────────
val ConvertFeature = Feature(
	id = "convert",
	title = "Converter",
	icon = "swap_horizontal",
	group = Group.Work,
	plugins = listOf("converter"),
	keywords = listOf("umrechnen", "units", "einheiten", "currency", "währung", "euro", "dollar", "hex", "temperature", "kg", "lb", "miles", "km"),
	screen = { ConvertScreen() },
)

/**
 * The PC's answer to a conversion, asked a moment after the last keystroke.
 * Null until there is one; an error becomes `{ ok: false, message }`.
 */
@Composable
fun rememberConversion(query: String): JsonElement? {
	val link = link
	var result by remember { mutableStateOf<JsonElement?>(null) }
	LaunchedEffect(query) {
		if (query.isBlank()) {
			result = null
			return@LaunchedEffect
		}
		delay(250)
		result = try {
			link.call("convert", "convert", json("query" to query), timeoutSeconds = 20)
		} catch (error: LinkError) {
			json("ok" to false, "message" to link.describe(error))
		}
	}
	return result
}

private val examples = listOf("5 kg in lb", "72 f c", "100 usd eur", "10 km mi", "1/2 cup ml", "0xff", "255 in hex", "3 h in min")

/** The answer: what was understood, the value asked for big, the other units smaller. */
@Composable
fun ConversionCard(result: JsonElement, compact: Boolean = false) {
	val clipboard = LocalClipboardManager.current
	if (!result["ok"].bool) {
		val message = result["message"].string
		if (message.isNotEmpty() && !compact) Label(message, Modifier.padding(horizontal = 6.dp), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 3)
		return
	}
	val rows = result["rows"].list
	val first = rows.firstOrNull() ?: return
	Panel(color = Theme.colors.primaryContainer) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("swap_horizontal", size = 18.dp, color = Theme.colors.primary)
			Spacer(Modifier.width(8.dp))
			Label("${result["input"].string} ${result["from"]["symbol"].string} · ${result["kind"].string}", style = Theme.Type.small, color = Theme.colors.textMuted)
		}
		Spacer(Modifier.height(6.dp))
		Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			Label(first["text"].string, style = Theme.Type.display.copy(fontFeatureSettings = "tnum"))
			Label(first["symbol"].string, Modifier.padding(bottom = 6.dp), style = Theme.Type.title, color = Theme.colors.primary)
		}
		Label(first["name"].string, style = Theme.Type.small, color = Theme.colors.textMuted)
		if (result["note"].string.isNotEmpty()) Label(result["note"].string, style = Theme.Type.tiny, color = Theme.colors.textSubtle)
		val others = rows.drop(1).take(if (compact) 4 else 12)
		if (others.isNotEmpty()) {
			Spacer(Modifier.height(10.dp))
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				for (row in others) Chip("${row["text"].string} ${row["symbol"].string}") { clipboard.setText(AnnotatedString(row["plain"].string)) }
			}
		}
	}
}

@Composable
private fun ConvertScreen() {
	var query by rememberSaveable { mutableStateOf("") }
	val result = rememberConversion(query)
	Screen("Converter", subtitle = "Units, temperatures, number bases, money at the PC's rates") {
		Field(query, placeholder = "5 kg in lb", icon = "swap_horizontal", action = ImeAction.Done) { query = it }
		if (result != null) ConversionCard(result)
		else if (query.isBlank()) {
			SectionLabel("Try")
			Panel(padding = PaddingValues(6.dp)) {
				for (example in examples) ListRow(example, icon = "arrow_right", onClick = { query = example })
			}
		}
		if (result != null && !result["ok"].bool && result["message"].string.isEmpty()) EmptyState("swap_horizontal", "Nothing to convert")
	}
}
