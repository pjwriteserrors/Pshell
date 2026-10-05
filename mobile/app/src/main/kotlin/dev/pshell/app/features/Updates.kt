package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel

val UpdatesFeature = Feature(
	id = "updates",
	title = "Updates",
	icon = "package_up",
	plugins = listOf("updates"),
	summary = {
		val updates = topic("updates")
		when {
			updates["running"].bool -> "Updating…"
			updates["count"].int > 0 -> "${updates["count"].int} waiting"
			updates == null -> ""
			else -> "Up to date"
		}
	},
	screen = { UpdatesScreen() },
)

@Composable
private fun UpdatesScreen() {
	val updates = topic("updates")
	val link = link
	val running = updates["running"].bool
	val count = updates["count"].int
	Screen("Updates", subtitle = if (updates["checking"].bool) "Checking…" else if (count == 0) "Up to date" else "$count packages", actions = {
		IconButton("refresh", enabled = !running) { link.run("updates", "check") }
	}) {
		if (running) {
			Panel(color = Theme.colors.primaryContainer) {
				Label("Updating", style = Theme.Type.title)
				Label(updates["progressLabel"].string, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
				Spacer(Modifier.height(12.dp))
				Meter(updates["progress"].float)
			}
		} else if (count > 0) {
			PrimaryButton("Update all", Modifier.fillMaxWidth(), icon = "package_up") { link.run("updates", "updateAll") }
			if (dev.pshell.app.ui.pluginOn("phone-terminal")) {
				val nav = dev.pshell.app.ui.LocalNav.current
				dev.pshell.app.ui.widgets.SoftButton("Update here, in a terminal", Modifier.fillMaxWidth(), icon = "console_line") {
					val command = android.util.Base64.encodeToString("yay -Syu".toByteArray(), android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP)
					nav.open("terminal/cmd/$command")
				}
				Label("The one above runs in a window on the PC and asks for the password there; this one asks you here.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 3)
			}
		}
		if (updates["rebootNeeded"].bool) Chip("A restart is needed for the new kernel", icon = "restart", tint = Theme.colors.warning)
		if (updates["error"].string.isNotEmpty()) Label(updates["error"].string, color = Theme.colors.danger, maxLines = 3)
		if (updates["result"].string.isNotEmpty() && !running) Label(updates["result"].string, color = Theme.colors.textMuted, maxLines = 3)

		val packages = updates["packages"].list
		if (packages.isEmpty() && !running) EmptyState("check_circle_outline", "Nothing to update")
		if (packages.isNotEmpty()) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				Chip("${updates["repo"].int} repo")
				Chip("${updates["aur"].int} AUR")
			}
			Panel(padding = PaddingValues(6.dp)) {
				val busy = updates["runningNames"].list.map { it.string }
				for (item in packages) {
					ListRow(
						item["name"].string,
						icon = if (item["source"].string == "aur") "package_variant" else "package_variant_closed",
						subtitle = "${item["current"].string} → ${item["next"].string}",
					) {
						if (item["name"].string in busy) Label("…", color = Theme.colors.textMuted)
						else IconButton("download", size = 40.dp, enabled = !running) { link.run("updates", "update", json("name" to item["name"].string)) }
					}
				}
			}
		}
		val news = updates["news"].list
		if (news.isNotEmpty()) {
			SectionLabel("News")
			Panel(padding = PaddingValues(6.dp)) {
				for (item in news) ListRow(item["title"].string, icon = "newspaper_variant_outline")
				ListRow("Mark as read", icon = "check", onClick = { link.run("updates", "readNews") })
			}
		}
	}
}
