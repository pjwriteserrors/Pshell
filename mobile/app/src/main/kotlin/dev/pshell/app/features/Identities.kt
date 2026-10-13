package dev.pshell.app.features

import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.connected
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
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
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

// ── identities: made-up people to sign up with ─────────────────────────────
val IdentitiesFeature = Feature(
	id = "identities",
	title = "Identities",
	icon = "account_circle",
	group = Group.Work,
	plugins = listOf("identities"),
	keywords = listOf("fake", "identity", "identität", "sign up", "anmelden", "account", "konto", "mail", "sms", "temporary", "wegwerf"),
	screen = { IdentitiesScreen() },
	page = { id -> IdentityPage(id) },
)

private val Urls = Regex("https?://[^\\s<>\"')\\]]+")

/** The face of an identity, or its initials until the picture is there. */
@Composable
private fun Face(identity: JsonElement?, size: Dp = 44.dp) {
	val name = identity["name"].string
	Box(Modifier.size(size).clip(CircleShape).background(Theme.colors.layer3), contentAlignment = Alignment.Center) {
		Label(name.split(' ').filter { it.isNotEmpty() }.take(2).joinToString("") { it.first().uppercaseChar().toString() }.ifEmpty { "?" }, style = Theme.Type.label.copy(fontWeight = FontWeight.SemiBold))
		if (identity["picture"].string.isNotEmpty()) AsyncImage(model = identity["picture"].string, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
	}
}

@Composable
private fun IdentitiesScreen() {
	val identities = topic("identities")
	val link = link
	val nav = LocalNav.current
	val scope = rememberCoroutineScope()
	val all = identities["identities"].list
	val creating = identities["creating"].bool
	val create: () -> Unit = {
		scope.launch {
			try {
				val made = link.call("identities", "create")
				nav.open("feature/identities/${android.net.Uri.encode(made["id"].string)}")
			} catch (error: LinkError) {
				link.toast(link.describe(error))
			}
		}
	}
	Screen("Identities", actions = {
		IconButton("plus", color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = identities != null && !creating, onClick = create)
	}) {
		if (identities["failed"].bool) Label("Could not create an identity", color = Theme.colors.danger)
		if (identities == null) EmptyState("account_circle", "Loading…")
		else if (all.isEmpty()) EmptyState("account_circle", "No identity")
		for ((title, shown) in listOf("Draft" to all.filter { !it["saved"].bool }, "Saved" to all.filter { it["saved"].bool })) {
			if (shown.isEmpty()) continue
			SectionLabel(title)
			Panel(padding = PaddingValues(6.dp)) {
				for (identity in shown) IdentityRow(identity) { nav.open("feature/identities/${android.net.Uri.encode(identity["id"].string)}") }
			}
		}
	}
}

/** One identity: what it is for, who it is, and whether something of it is gone or unread. */
@Composable
private fun IdentityRow(identity: JsonElement, onClick: () -> Unit) {
	val unread = identity["unread"].int
	Row(
		Modifier.fillMaxWidth().pressable(shape = RoundedCornerShape(Theme.Radius.huge), pressedScale = 0.985f, onClick = onClick).padding(horizontal = 10.dp, vertical = 8.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Face(identity)
		Spacer(Modifier.width(12.dp))
		Column(Modifier.weight(1f)) {
			Label(identity["label"].string.ifEmpty { "…" }, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
			val about = listOf(if (identity["title"].string.isNotEmpty()) identity["name"].string else "", identity["mail"]["address"].string).filter { it.isNotEmpty() }.joinToString(" · ")
			if (about.isNotEmpty()) Label(about, style = Theme.Type.small, color = Theme.colors.textMuted)
		}
		if (identity["mail"]["gone"].bool || identity["phone"]["gone"].bool) Glyph("alert_outline", Modifier.padding(start = 6.dp), size = 16.dp, color = Theme.colors.danger)
		if (unread > 0) Box(Modifier.padding(start = 6.dp).size(20.dp).clip(CircleShape).background(Theme.colors.primary), contentAlignment = Alignment.Center) {
			Label("$unread", style = Theme.Type.tiny.copy(fontWeight = FontWeight.Bold), color = Theme.colors.onPrimary)
		}
		Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
	}
}

/** One identity: what a form asks for, each to be copied with a tap, and what its mailbox and number received. */
@Composable
private fun IdentityPage(id: String) {
	val identities = topic("identities")
	val link = link
	val nav = LocalNav.current
	val scope = rememberCoroutineScope()
	val clipboard = LocalClipboardManager.current
	val uris = LocalUriHandler.current
	val up = connected()
	val identity = identities["identities"].list.firstOrNull { it["id"].string == id }
	val inbox = identities["inbox"].takeIf { it["id"].string == id }
	var tab by rememberSaveable { mutableStateOf("mail") }
	var open by remember { mutableStateOf("") }
	var fetching by remember { mutableStateOf("") }
	val bodies = remember { mutableStateMapOf<String, String>() }
	var saving by remember { mutableStateOf(false) }
	var removing by remember { mutableStateOf(false) }
	// the PC reads the inboxes of the identity that is looked at; told again after a reconnect
	DisposableEffect(id, up) {
		if (up) link.run("identities", "look", json("id" to id))
		onDispose { if (link.state.value is LinkState.Connected) link.run("identities", "look", json("id" to "")) }
	}
	val copy: (String) -> Unit = { text ->
		clipboard.setText(AnnotatedString(text))
		link.toast("Copied")
	}
	val pending = identity["pending"].list.map { it.string }
	val reading = identities["reading"].string == id
	Screen(identity["label"].string.ifEmpty { "Identity" }, subtitle = if (identity["title"].string.isNotEmpty()) identity["name"].string else "", actions = {
		IconButton("refresh", color = Theme.colors.layer2, enabled = identity != null && !reading && pending.isEmpty()) { link.run("identities", "check", json("id" to id)) }
	}) {
		if (identities == null) EmptyState("account_circle", "Loading…")
		else if (identity == null) EmptyState("account_circle", "No identity")
		else {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Face(identity, size = 64.dp)
				Spacer(Modifier.width(14.dp))
				Column(Modifier.weight(1f)) {
					Label(identity["name"].string.ifEmpty { "…" }, style = Theme.Type.heading)
					Label(listOf(identity["city"].string, identity["country"].string).filter { it.isNotEmpty() }.joinToString(", "), style = Theme.Type.small, color = Theme.colors.textMuted)
				}
			}
			SectionLabel("Account")
			Panel(padding = PaddingValues(6.dp)) {
				for ((kind, label, icon) in listOf(Triple("mail", "Email", "email_outline"), Triple("phone", "Phone", "phone"))) {
					val box = identity[kind]
					val value = box[if (kind == "mail") "address" else "number"].string
					val waits = kind in pending
					val gone = box["gone"].bool
					if (kind == "phone") {
						DataRow("Username", identity["username"].string, "account_outline", "person" in pending, copy)
						DataRow("Password", identity["password"].string, "key_outline", "person" in pending, copy)
					}
					ListRow(
						value.ifEmpty { if (waits) "…" else "None" },
						icon = icon,
						subtitle = if (gone) "$label · gone" else label,
						iconTint = if (gone) Theme.colors.danger else Theme.colors.text,
						onClick = if (value.isNotEmpty()) ({ copy(value) }) else null,
					) {
						// a new one for one that is gone or never came
						if (box["renewing"].bool) Label("Renewing…", style = Theme.Type.small, color = Theme.colors.textMuted)
						else if (!waits && (gone || !box.present)) Chip("Renew", icon = "refresh") { link.run("identities", "renew", json("id" to id, "kind" to kind)) }
						else if (value.isNotEmpty()) Glyph("content_copy", size = 16.dp, color = Theme.colors.textSubtle)
					}
				}
			}
			SectionLabel("Personal")
			Panel(padding = PaddingValues(6.dp)) {
				val waits = "person" in pending
				DataRow("First name", identity["first"].string, "account_outline", waits, copy)
				DataRow("Last name", identity["last"].string, "account_outline", waits, copy)
				DataRow("Birthday", identity["birthday"].string, "calendar_outline", waits, copy)
				DataRow("Street", identity["street"].string, "home_outline", waits, copy)
				DataRow("Postcode", identity["postcode"].string, "map_marker", waits, copy)
				DataRow("City", identity["city"].string, "map_marker", waits, copy)
				DataRow("State", identity["state"].string, "map_marker", waits, copy)
				DataRow("Country", identity["country"].string, "earth", waits, copy)
			}
			val unread = identity["unread"].int
			Segmented(listOf("mail" to if (unread > 0) "Mail · $unread" else "Mail", "sms" to "SMS"), tab, Modifier.fillMaxWidth()) { tab = it }
			val messages = inbox[if (tab == "mail") "mails" else "sms"].list
			if (messages.isEmpty()) EmptyState(if (tab == "mail") "email_open_outline" else "message_outline", if (tab == "mail") "No mail yet" else "No SMS yet")
			else Panel(padding = PaddingValues(6.dp)) {
				for (message in messages) {
					val mid = message["id"].string
					val mail = tab == "mail"
					val expanded = mail && open == mid
					val code = message["code"].string
					Column(
						Modifier.fillMaxWidth().pressable(enabled = mail, shape = RoundedCornerShape(Theme.Radius.huge), pressedScale = 0.985f) {
							open = if (expanded) "" else mid
							// a mail that is opened is read, and its whole text fetched once
							if (open.isNotEmpty() && mid !in bodies) scope.launch {
								fetching = mid
								try {
									bodies[mid] = link.call("identities", "read", json("id" to id, "mail" to mid))["body"].string
								} catch (error: LinkError) {
									link.toast(link.describe(error))
								}
								if (fetching == mid) fetching = ""
							}
						}.padding(horizontal = 10.dp, vertical = 10.dp),
						verticalArrangement = Arrangement.spacedBy(2.dp),
					) {
						val unseen = mail && !message["seen"].bool
						Row(verticalAlignment = Alignment.CenterVertically) {
							if (unseen) Box(Modifier.padding(end = 8.dp).size(7.dp).clip(CircleShape).background(Theme.colors.primary))
							Label(message["from"].string, Modifier.weight(1f), style = Theme.Type.body.copy(fontWeight = if (unseen) FontWeight.Bold else FontWeight.SemiBold))
							Label(whenSaid(message["at"].long / 1000), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
						}
						Row(verticalAlignment = Alignment.CenterVertically) {
							Column(Modifier.weight(1f)) {
								if (message["subject"].string.isNotEmpty()) Label(message["subject"].string, style = Theme.Type.small, maxLines = if (expanded) 4 else 1)
								val body = bodies[mid]
								if (expanded && body != null) Label(body.trim(), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 400)
								else Label(message["text"].string, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = if (mail) 2 else 5)
							}
							// the code it is about
							if (code.isNotEmpty()) Chip(code, Modifier.padding(start = 8.dp), icon = "content_copy", tint = Theme.colors.primary) { copy(code) }
						}
						if (expanded && fetching == mid) Label("Loading…", style = Theme.Type.tiny, color = Theme.colors.textSubtle)
						// the links of a mail, since confirming an address is a tap on one
						if (expanded) for (url in Urls.findAll(bodies[mid] ?: "").map { it.value }.distinct().take(6)) {
							Chip(url.removePrefix("https://").removePrefix("http://").take(44), Modifier.padding(top = 4.dp), icon = "open_in_new") { runCatching { uris.openUri(url) } }
						}
					}
				}
			}
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton(if (identity["saved"].bool) "Rename" else "Save", Modifier.weight(1f), icon = "bookmark_outline") { saving = true }
				SoftButton("Remove", Modifier.weight(1f), icon = "delete_outline", tint = Theme.colors.danger) { removing = true }
			}
			Spacer(Modifier.height(4.dp))
		}
	}
	if (saving) {
		var title by remember { mutableStateOf(identity["title"].string) }
		Sheet({ saving = false }, if (identity["saved"].bool) "Rename" else "Save") { close ->
			val save = {
				link.run("identities", "save", json("id" to id, "title" to title.trim()))
				close()
			}
			Field(title, placeholder = "Title", icon = "tag_outline", onSubmit = save) { title = it }
			PrimaryButton("Save", Modifier.fillMaxWidth(), icon = "bookmark_outline", onClick = save)
		}
	}
	if (removing) Confirm("Remove this identity?", identity["label"].string, confirm = "Remove", danger = true, onDismiss = { removing = false }) {
		removing = false
		link.run("identities", "remove", json("id" to id))
		nav.back()
	}
}

/** One thing a form asks for; a tap copies it. */
@Composable
private fun DataRow(label: String, value: String, icon: String, waits: Boolean, copy: (String) -> Unit) {
	if (value.isEmpty() && !waits) return
	ListRow(value.ifEmpty { "…" }, icon = icon, subtitle = label, onClick = if (value.isNotEmpty()) ({ copy(value) }) else null) {
		if (value.isNotEmpty()) Glyph("content_copy", size = 16.dp, color = Theme.colors.textSubtle)
	}
}
