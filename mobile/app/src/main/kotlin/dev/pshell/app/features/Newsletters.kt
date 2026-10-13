package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.pressable
import kotlinx.serialization.json.JsonElement

// ── newsletters: who sends them, and leaving the ones that are ticked ──────
val NewslettersFeature = Feature(
	id = "newsletters",
	title = "Newsletters",
	icon = "newspaper_variant_outline",
	group = Group.Work,
	plugins = listOf("messages", "mail", "mail-unsubscribe"),
	keywords = listOf("unsubscribe", "abmelden", "abbestellen", "abo", "mail", "spam", "senders", "absender"),
	screen = { NewslettersScreen() },
)

/** How a sender was or is left, as the PC says it. */
private fun howSaid(entry: JsonElement): String = when {
	entry["status"].string == "needs-you" -> "Confirm in the browser on the PC"
	entry["method"].string == "one-click" -> "One click"
	entry["method"].string == "email" -> "By mail"
	entry["method"].string == "page" -> "On its page"
	else -> ""
}

@Composable
private fun NewslettersScreen() {
	val newsletters = topic("newsletters")
	val link = link
	var mode by rememberSaveable { mutableStateOf("senders") }
	// the senders that are ticked; nothing is left before the button says so
	var ticked by remember { mutableStateOf(setOf<String>()) }
	var asking by remember { mutableStateOf(false) }
	val senders = newsletters["senders"].list
	val left = newsletters["left"].list
	val working = newsletters["working"].list.map { it.string }
	val scanning = newsletters["scanning"].bool
	val busy = working.isNotEmpty()
	// what is ticked and still on the list
	val picked = senders.filter { it["id"].string in ticked }
	val scanned = newsletters["at"].long
	Screen("Newsletters", subtitle = if (scanning) "Scanning…" else if (scanned > 0) "Scanned ${whenSaid(scanned)}" else "", scroll = false, actions = {
		IconButton("refresh", color = Theme.colors.layer2, enabled = newsletters != null && !scanning && !busy) { link.run("newsletters", "scan") }
	}) {
		if (scanning) LinearProgressIndicator(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape), color = Theme.colors.primary, trackColor = Theme.colors.layer3)
		Segmented(
			listOf("senders" to if (senders.isNotEmpty()) "Subscribed · ${senders.size}" else "Subscribed", "left" to if (left.isNotEmpty()) "Unsubscribed · ${left.size}" else "Unsubscribed"),
			mode, Modifier.fillMaxWidth(),
		) { mode = it }
		if (newsletters["error"].string.isNotEmpty()) Label(newsletters["error"].string, style = Theme.Type.small, color = Theme.colors.danger, maxLines = 2)
		if (mode == "senders" && senders.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
			IconButton("select_all", color = Theme.colors.layer2, enabled = !busy) {
				ticked = if (senders.all { it["id"].string in ticked }) emptySet() else senders.map { it["id"].string }.toSet()
			}
			Spacer(Modifier.width(8.dp))
			PrimaryButton(
				if (busy) "Unsubscribing · ${working.size}" else if (picked.isNotEmpty()) "Unsubscribe from ${picked.size}" else "Unsubscribe",
				Modifier.weight(1f), icon = "email_open_outline", enabled = picked.isNotEmpty() && !busy,
			) { asking = true }
		}
		val shown = if (mode == "left") left else senders
		if (newsletters == null) EmptyState("newspaper_variant_outline", "Loading…")
		else if (!newsletters["running"].bool) EmptyState("alert_circle_outline", "Mail is not running on the PC")
		else if (shown.isEmpty() && !(scanning && mode == "senders")) EmptyState(if (mode == "left") "email_open_outline" else "newspaper_variant_outline", if (mode == "left") "Nothing unsubscribed" else "No newsletters")
		else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = BottomSpace), verticalArrangement = Arrangement.spacedBy(2.dp)) {
			items(shown, key = { it["id"].string }) { entry ->
				val id = entry["id"].string
				val gone = mode == "left"
				val on = id in ticked
				val leaving = id in working
				Row(
					Modifier.fillMaxWidth().pressable(enabled = !gone && !busy, shape = RoundedCornerShape(Theme.Radius.huge), pressedScale = 0.985f) { ticked = if (on) ticked - id else ticked + id }.padding(horizontal = 10.dp, vertical = 10.dp),
					verticalAlignment = Alignment.CenterVertically,
				) {
					if (!gone) {
						Glyph(if (leaving) "email_open_outline" else if (on) "checkbox_marked" else "checkbox_blank_outline", size = 22.dp, color = if (on || leaving) Theme.colors.primary else Theme.colors.textSubtle)
						Spacer(Modifier.width(12.dp))
					}
					Column(Modifier.weight(1f)) {
						Label(entry["name"].string.ifEmpty { entry["domain"].string }, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
						Label(listOf(entry["mailbox"].string, entry["domain"].string).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textSubtle)
						val about = if (gone) howSaid(entry) else if (leaving) "Unsubscribing…" else entry["subject"].string
						if (about.isNotEmpty()) Label(about, style = Theme.Type.small, color = if (entry["status"].string == "needs-you") Theme.colors.danger else Theme.colors.textMuted)
					}
					Spacer(Modifier.width(8.dp))
					if (gone) Chip(if (entry["status"].string == "needs-you") "Back on the list" else "Subscribe again", icon = "undo") { link.run("newsletters", "resubscribe", json("id" to id)) }
					else Column(horizontalAlignment = Alignment.End) {
						Label("${entry["count"].int}", style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum"))
						Label(whenSaid(entry["last"].long), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
					}
				}
			}
		}
	}
	if (asking) Confirm(
		if (picked.size == 1) "Unsubscribe from 1 sender?" else "Unsubscribe from ${picked.size} senders?",
		picked.take(6).joinToString(", ") { it["name"].string.ifEmpty { it["domain"].string } } + if (picked.size > 6) " + ${picked.size - 6}" else "",
		confirm = "Unsubscribe", danger = true, onDismiss = { asking = false },
	) {
		asking = false
		link.run("newsletters", "unsubscribe", json("ids" to picked.map { it["id"].string }))
		ticked = emptySet()
	}
}
