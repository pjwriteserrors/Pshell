package dev.pshell.app.features

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.get
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SoftButton

// ── the useless fact of the day ────────────────────────────────────────────
val FactFeature = Feature(
	id = "fact",
	title = "Useless fact",
	icon = "lightbulb",
	group = Group.Work,
	plugins = listOf("useless-fact"),
	keywords = listOf("fakt", "wissen", "trivia", "fun"),
	screen = { FactScreen() },
)

@Composable
private fun FactScreen() {
	val fact = topic("fact")
	val link = link
	val context = LocalContext.current
	Screen("Useless fact", actions = {
		IconButton("refresh", color = Theme.colors.layer2) { link.run("fact", "refresh") }
	}) {
		if (fact["text"].string.isEmpty()) {
			EmptyState("lightbulb", if (fact == null) "Loading…" else "No fact yet")
			return@Screen
		}
		Panel {
			Label(fact["text"].string, style = Theme.Type.heading.copy(lineHeight = Theme.Type.heading.fontSize * 1.35f), maxLines = 40)
			val source = fact["source"].string
			val url = fact["sourceUrl"].string
			if (source.isNotEmpty() || url.isNotEmpty()) Spacer(Modifier.height(14.dp))
			// the source opens in the phone's browser
			if (url.isNotEmpty()) SoftButton(source.ifEmpty { "Source" }, icon = "open_in_new") {
				runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))) }
			}
			else if (source.isNotEmpty()) Label(source, style = Theme.Type.small, color = Theme.colors.textMuted)
		}
	}
}
