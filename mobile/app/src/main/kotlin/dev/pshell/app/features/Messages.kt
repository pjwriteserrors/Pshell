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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
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
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
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
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// ── messages: mail as chats ────────────────────────────────────────────────
val MessagesFeature = Feature(
	id = "messages",
	title = "Messages",
	icon = "forum_outline",
	group = Group.Work,
	plugins = listOf("messages", "mail"),
	keywords = listOf("mail", "email", "e-mail", "post", "nachrichten", "inbox", "chats", "outlook", "gmail", "imap", "reply", "antworten"),
	summary = {
		val unread = topic("messages")["unread"].int
		if (unread > 0) "$unread unread" else ""
	},
	card = { open -> MessagesCard(open) },
	screen = { MessagesScreen() },
	page = { id -> ChatPage(id) },
)

/** A moment as the chat list says it: the time today, the day this week, the date otherwise. */
fun whenSaid(epochSeconds: Long): String {
	if (epochSeconds <= 0) return ""
	val date = Date(epochSeconds * 1000)
	val now = Calendar.getInstance()
	val then = Calendar.getInstance().apply { time = date }
	return when {
		now.get(Calendar.YEAR) == then.get(Calendar.YEAR) && now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR) -> SimpleDateFormat("HH:mm", Locale.getDefault()).format(date)
		now.timeInMillis - date.time < 6L * 86400_000 -> SimpleDateFormat("EEE", Locale.getDefault()).format(date)
		now.get(Calendar.YEAR) == then.get(Calendar.YEAR) -> SimpleDateFormat("d MMM", Locale.getDefault()).format(date)
		else -> SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(date)
	}
}

private fun sizeSaid(bytes: Long): String = when {
	bytes >= 1_000_000 -> "%.1f MB".format(bytes / 1_000_000.0)
	bytes >= 1_000 -> "%d kB".format(bytes / 1_000)
	bytes > 0 -> "$bytes B"
	else -> ""
}

/** Who a chat is with, for its title. */
private fun whoOf(chat: JsonElement?): String {
	val people = chat["people"].list.map { it["name"].string.ifEmpty { it["email"].string } }.filter { it.isNotEmpty() }
	return when {
		people.isEmpty() -> chat["subject"].string.ifEmpty { "(no sender)" }
		people.size <= 2 -> people.joinToString(", ")
		else -> "${people.first()} + ${people.size - 1}"
	}
}

private fun initialsOf(name: String): String = name.split(Regex("[\\s@.]+")).filter { it.isNotEmpty() }.take(2).joinToString("") { it.first().uppercaseChar().toString() }.ifEmpty { "?" }

/** A round picture of a person: their avatar from the PC, or their initials. */
@Composable
fun Avatar(name: String, blob: String?, size: Dp = 44.dp, tint: Color = Theme.colors.layer3) {
	val url = link.blob(blob)
	Box(Modifier.size(size).clip(CircleShape).background(tint), contentAlignment = Alignment.Center) {
		if (url != null) AsyncImage(model = url, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
		else Label(initialsOf(name), style = Theme.Type.label.copy(fontWeight = FontWeight.SemiBold), color = Theme.colors.text)
	}
}

/** On the home screen: how much waits, and the newest unread chats. */
@Composable
private fun MessagesCard(open: () -> Unit) {
	val messages = topic("messages") ?: return
	val nav = LocalNav.current
	val unread = messages["unread"].int
	if (unread <= 0) return
	val fresh = messages["chats"].list.filter { it["unread"].int > 0 }.take(3)
	Panel(onClick = open, padding = PaddingValues(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("email_outline", size = 20.dp, color = Theme.colors.primary)
			Spacer(Modifier.width(10.dp))
			Label("$unread unread", style = Theme.Type.title, modifier = Modifier.weight(1f))
			Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
		}
		for (chat in fresh) {
			Spacer(Modifier.height(8.dp))
			Row(Modifier.fillMaxWidth().pressable(shape = RoundedCornerShape(14.dp), pressedScale = 0.98f) { nav.open("feature/messages/${android.net.Uri.encode(chat["id"].string)}") }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
				Avatar(whoOf(chat), chat["avatar"].string, size = 32.dp)
				Spacer(Modifier.width(10.dp))
				Column(Modifier.weight(1f)) {
					Label(whoOf(chat), style = Theme.Type.label)
					Label(chat["subject"].string.ifEmpty { chat["preview"].string }, style = Theme.Type.small, color = Theme.colors.textMuted)
				}
				Label(whenSaid(chat["date"].long), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
			}
		}
	}
}

@Composable
private fun MessagesScreen() {
	val messages = topic("messages")
	val link = link
	val nav = LocalNav.current
	var searching by rememberSaveable { mutableStateOf(false) }
	var query by rememberSaveable { mutableStateOf("") }
	var composing by remember { mutableStateOf(false) }
	var filter by rememberSaveable { mutableStateOf("all") }
	LaunchedEffect(query) {
		delay(350)
		link.run("messages", "search", json("query" to query.trim()))
	}
	Screen("Messages", subtitle = messages["trouble"].string, scroll = false, actions = {
		IconButton(if (searching) "close" else "magnify", color = Theme.colors.layer2) {
			searching = !searching
			if (!searching) query = ""
		}
		Spacer(Modifier.width(6.dp))
		IconButton("pencil_outline", color = Theme.colors.primary, tint = Theme.colors.onPrimary) { composing = true }
	}) {
		val accounts = messages["accounts"].list
		val chats = messages["chats"].list
		val hits = messages["hits"]
		if (searching) Field(query, placeholder = "Search mails", icon = "magnify", action = ImeAction.Search) { query = it }
		if (messages == null) EmptyState("forum_outline", "Loading…")
		else if (!messages["running"].bool) EmptyState("email_off_outline", "Mail is not running on the PC", text = messages["trouble"].string)
		else if (accounts.isEmpty()) EmptyState("email_plus_outline", "No mail account", text = "Add one on the PC: Messages → Settings. Then the chats show up here.")
		else {
			if (!searching) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				Chip("All", active = filter == "all") { filter = "all" }
				val unread = messages["unread"].int
				Chip(if (unread > 0) "Unread · $unread" else "Unread", icon = "email_outline", active = filter == "unread") { filter = "unread" }
				Chip("Flagged", icon = "flag_outline", active = filter == "flagged") { filter = "flagged" }
				Chip("Files", icon = "paperclip", active = filter == "files") { filter = "files" }
				for (account in accounts) if (accounts.size > 1) Chip(account["name"].string.ifEmpty { account["address"].string }, active = filter == "account:${account["id"].string}") { filter = "account:${account["id"].string}" }
			}
			val shown = when {
				searching && query.isNotBlank() -> if (hits.present) chats.filter { chat -> hits.list.any { it.string == chat["id"].string } } else emptyList()
				filter == "unread" -> chats.filter { it["unread"].int > 0 }
				filter == "flagged" -> chats.filter { it["flagged"].bool }
				filter == "files" -> chats.filter { it["attachments"].bool }
				filter.startsWith("account:") -> chats.filter { it["account"].string == filter.removePrefix("account:") }
				else -> chats
			}
			if (shown.isEmpty()) {
				if (searching && messages["searching"].bool) EmptyState("magnify", "Searching…")
				else EmptyState("email_open_outline", if (searching && query.isNotBlank()) "Nothing found" else "No mails here")
			} else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = BottomSpace), verticalArrangement = Arrangement.spacedBy(2.dp)) {
				items(shown, key = { it["id"].string }) { chat -> ChatRow(chat) { nav.open("feature/messages/${android.net.Uri.encode(chat["id"].string)}") } }
				item {
					if (!searching) Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
						SoftButton("Older mails", icon = "history") { link.run("messages", "older") }
					}
				}
			}
		}
	}
	if (composing) ComposeSheet(messages, key = "new", onDismiss = { composing = false })
}

/** One chat: who, subject, the beginning of the last mail, when, and what is unread. */
@Composable
private fun ChatRow(chat: JsonElement, onClick: () -> Unit) {
	val unread = chat["unread"].int
	val who = whoOf(chat)
	Row(
		Modifier.fillMaxWidth().pressable(shape = RoundedCornerShape(Theme.Radius.huge), pressedScale = 0.985f, onClick = onClick).padding(horizontal = 10.dp, vertical = 10.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Avatar(who, chat["avatar"].string, tint = if (unread > 0) Theme.colors.primaryContainer else Theme.colors.layer3)
		Spacer(Modifier.width(12.dp))
		Column(Modifier.weight(1f)) {
			Row(verticalAlignment = Alignment.CenterVertically) {
				Label(who, Modifier.weight(1f), style = Theme.Type.body.copy(fontWeight = if (unread > 0) FontWeight.Bold else FontWeight.SemiBold))
				Label(whenSaid(chat["date"].long), style = Theme.Type.tiny, color = if (unread > 0) Theme.colors.primary else Theme.colors.textSubtle)
			}
			if (chat["subject"].string.isNotEmpty() && chat["people"].list.isNotEmpty()) Label(chat["subject"].string, style = Theme.Type.small.copy(fontWeight = if (unread > 0) FontWeight.SemiBold else FontWeight.Normal), color = Theme.colors.text)
			Row(verticalAlignment = Alignment.CenterVertically) {
				val lead = if (chat["mine"].bool) "You: " else if (chat["group"].bool && chat["sender"].string.isNotEmpty()) "${chat["sender"].string}: " else ""
				Label(lead + chat["preview"].string, Modifier.weight(1f), style = Theme.Type.small, color = Theme.colors.textMuted)
				if (chat["attachments"].bool) Glyph("paperclip", size = 14.dp, color = Theme.colors.textSubtle)
				if (chat["flagged"].bool) Glyph("flag", size = 14.dp, color = Theme.colors.warning)
				if (chat["snoozed"].bool) Glyph("alarm", size = 14.dp, color = Theme.colors.textSubtle)
				if (unread > 0) Box(Modifier.padding(start = 6.dp).size(20.dp).clip(CircleShape).background(Theme.colors.primary), contentAlignment = Alignment.Center) {
					Label("$unread", style = Theme.Type.tiny.copy(fontWeight = FontWeight.Bold), color = Theme.colors.onPrimary)
				}
			}
		}
	}
}

/** One chat: its mails as bubbles, a reply at the bottom. Opening it marks it read on the PC. */
@Composable
private fun ChatPage(id: String) {
	val messages = topic("messages")
	val link = link
	val nav = LocalNav.current
	val scope = rememberCoroutineScope()
	val clipboard = LocalClipboardManager.current
	val chat = messages["chats"].list.firstOrNull { it["id"].string == id }
	val open = messages["open"].takeIf { it["id"].string == id }
	var menu by remember { mutableStateOf(false) }
	var deleting by remember { mutableStateOf(false) }
	var replying by remember { mutableStateOf(false) }
	var assisting by remember { mutableStateOf(false) }
	var attachment by remember { mutableStateOf<Pair<JsonElement, JsonElement>?>(null) }
	DisposableEffect(id) {
		link.run("messages", "open", json("id" to id))
		onDispose { link.run("messages", "close") }
	}
	val list = open["messages"].list
	val state = rememberLazyListState()
	LaunchedEffect(list.size) { if (list.isNotEmpty()) state.scrollToItem(list.size - 1) }
	val who = whoOf(chat)
	Screen(who, subtitle = chat["subject"].string, scroll = false, actions = {
		IconButton("dots_vertical", color = Theme.colors.layer2) { menu = true }
	}) {
		Column(Modifier.fillMaxSize().imePadding()) {
			Box(Modifier.weight(1f)) {
				if (open == null || (open["loading"].bool && list.isEmpty())) EmptyState("email_open_outline", "Loading…")
				else if (list.isEmpty()) EmptyState("email_open_outline", "Nothing in this chat")
				else LazyColumn(Modifier.fillMaxSize(), state = state, verticalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 8.dp)) {
					items(list, key = { it["id"].string }) { message ->
						Bubble(message, group = chat["group"].bool, onAttachment = { attachment = message to it }, onCopy = { clipboard.setText(AnnotatedString(message["text"].string)) })
					}
					for (entry in messages["outbox"].list.filter { it["key"].string == id }) item(key = "outbox-${entry["id"].string}") {
						OutboxRow(entry)
					}
				}
			}
			// the reply, written here: one line opens the whole composer
			Row(Modifier.fillMaxWidth().padding(top = 6.dp).navigationBarsPadding(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				if (open["assistant"].present) IconButton("creation", color = Theme.colors.layer2) { assisting = true }
				Row(Modifier.weight(1f).height(48.dp).pressable(shape = CircleShape, pressedScale = 0.98f) { replying = true }.background(Theme.colors.layer1).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
					Glyph("reply", size = 18.dp, color = Theme.colors.textSubtle)
					Spacer(Modifier.width(10.dp))
					Label("Reply to all", color = Theme.colors.textSubtle)
				}
			}
		}
	}
	if (replying) ComposeSheet(messages, key = id, chat = chat, last = list.lastOrNull { !it["mine"].bool } ?: list.lastOrNull(), onDismiss = { replying = false })
	if (assisting) AssistantSheet(open, onDismiss = { assisting = false })
	attachment?.let { (message, file) ->
		Sheet({ attachment = null }, file["name"].string) { close ->
			Label(listOf(sizeSaid(file["size"].long), file["type"].string).filter { it.isNotEmpty() }.joinToString(" · "), color = Theme.colors.textMuted)
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton("Open on the PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "monitor") {
					link.run("messages", "openAttachment", json("chat" to id, "message" to message["id"].string, "attachment" to file["id"].string))
					close()
				}
				PrimaryButton("To the phone", Modifier.weight(1f), icon = "download") {
					scope.launch {
						try {
							link.call("messages", "attachment", json("chat" to id, "message" to message["id"].string, "attachment" to file["id"].string), timeoutSeconds = 60)
							link.toast("Fetching ${file["name"].string}")
						} catch (error: LinkError) {
							link.toast(link.describe(error))
						}
					}
					close()
				}
			}
		}
	}
	if (menu) Sheet({ menu = false }, who) { close ->
		Panel(padding = PaddingValues(6.dp)) {
			ListRow(if (chat["flagged"].bool) "Remove the flag" else "Flag", icon = if (chat["flagged"].bool) "flag_off_outline" else "flag_outline", onClick = { link.run("messages", "flag", json("id" to id, "value" to !chat["flagged"].bool)); close() })
			ListRow("Mark unread", icon = "email_mark_as_unread", onClick = { link.run("messages", "read", json("id" to id, "value" to false)); close(); nav.back() })
			ListRow("Snooze until tomorrow", icon = "alarm", subtitle = "Back in the list at 8 in the morning", onClick = {
				val until = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 1); set(Calendar.HOUR_OF_DAY, 8); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0) }.timeInMillis
				link.run("messages", "snooze", json("id" to id, "until" to until)); close(); nav.back()
			})
			ListRow("Archive", icon = "archive_outline", onClick = { link.run("messages", "archive", json("id" to id)); close(); nav.back() })
			ListRow("Delete", icon = "delete_outline", iconTint = Theme.colors.danger, onClick = { close(); deleting = true })
		}
	}
	if (deleting) Confirm("Delete this chat?", "Every mail in it goes to the trash of its account.", confirm = "Delete", danger = true, onDismiss = { deleting = false }) {
		deleting = false
		link.run("messages", "remove", json("id" to id))
		nav.back()
	}
}

/** One mail: mine on the right in the accent, theirs on the left. Long text folds. */
@Composable
private fun Bubble(message: JsonElement, group: Boolean, onAttachment: (JsonElement) -> Unit, onCopy: () -> Unit) {
	val mine = message["mine"].bool
	var expanded by remember(message["id"].string) { mutableStateOf(false) }
	var quoted by remember(message["id"].string) { mutableStateOf(false) }
	val text = message["text"].string.trim()
	val long = text.length > 700
	Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
		if (!mine) {
			Avatar(message["from"]["name"].string.ifEmpty { message["from"]["email"].string }, message["avatar"].string, size = 30.dp)
			Spacer(Modifier.width(8.dp))
		}
		Column(
			Modifier
				.widthIn(max = 320.dp)
				.clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp, bottomStart = if (mine) 20.dp else 6.dp, bottomEnd = if (mine) 6.dp else 20.dp))
				.background(if (mine) Theme.colors.primaryContainer else Theme.colors.layer1)
				.pressable(shape = RoundedCornerShape(20.dp), pressedScale = 0.99f, onLongClick = onCopy) { if (long) expanded = !expanded }
				.padding(horizontal = 14.dp, vertical = 10.dp),
		) {
			if (!mine && group) Label(message["from"]["name"].string.ifEmpty { message["from"]["email"].string }, style = Theme.Type.tiny.copy(fontWeight = FontWeight.SemiBold), color = Theme.colors.primary)
			if (message["subject"].string.isNotEmpty()) Label(message["subject"].string, style = Theme.Type.label, maxLines = 2)
			if (message["importance"].string == "high") Label("Important", style = Theme.Type.tiny, color = Theme.colors.warning)
			if (message["invite"].bool) Label("Meeting invitation", style = Theme.Type.tiny, color = Theme.colors.primary)
			Label(if (long && !expanded) text.take(700).trimEnd() + " …" else text.ifEmpty { "(no text)" }, maxLines = 400, color = if (text.isEmpty()) Theme.colors.textSubtle else Theme.colors.text)
			if (long) Label(if (expanded) "Less" else "Read all", style = Theme.Type.tiny.copy(fontWeight = FontWeight.SemiBold), color = Theme.colors.primary)
			val attachments = message["attachments"].list
			if (attachments.isNotEmpty()) Row(Modifier.padding(top = 6.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
				for (file in attachments) Chip(file["name"].string.take(28) + if (file["size"].long > 0) " · ${sizeSaid(file["size"].long)}" else "", icon = "paperclip") { onAttachment(file) }
			}
			if (message["quote"].string.isNotBlank()) {
				Label(if (quoted) "Hide the quoted mail" else "Quoted mail", Modifier.padding(top = 6.dp).pressable(shape = CircleShape) { quoted = !quoted }, style = Theme.Type.tiny.copy(fontWeight = FontWeight.SemiBold), color = Theme.colors.textMuted)
				if (quoted) Label(message["quote"].string.trim(), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 200)
			}
			Row(Modifier.padding(top = 4.dp).fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
				if (message["flagged"].bool) Glyph("flag", size = 12.dp, color = Theme.colors.warning)
				Label(whenSaid(message["date"].long), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
			}
		}
	}
}

/** A mail on its way: it waits a few seconds and can be taken back. */
@Composable
private fun OutboxRow(entry: JsonElement) {
	val link = link
	val state = entry["state"].string
	var now by remember { mutableStateOf(System.currentTimeMillis()) }
	LaunchedEffect(entry["id"].string, state) {
		while (state == "waiting") {
			now = System.currentTimeMillis()
			delay(250)
		}
	}
	val left = ((entry["at"].long + entry["grace"].long + link.clockOffset - now) / 1000).coerceAtLeast(0)
	Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
		Column(Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(20.dp)).background(Theme.colors.layer2).padding(horizontal = 14.dp, vertical = 10.dp)) {
			Label(entry["text"].string, color = Theme.colors.textMuted, maxLines = 3)
			Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				when (state) {
					"waiting" -> {
						Label("Sending in $left s", style = Theme.Type.tiny, color = Theme.colors.textSubtle)
						Chip("Undo", icon = "undo") { link.run("messages", "undo", json("id" to entry["id"].string)) }
						Chip("Now", icon = "send") { link.run("messages", "dispatch", json("id" to entry["id"].string)) }
					}
					"sending" -> Label("Sending…", style = Theme.Type.tiny, color = Theme.colors.textSubtle)
					"sent" -> Label("Sent", style = Theme.Type.tiny, color = Theme.colors.success)
					else -> {
						Label(entry["error"].string.ifEmpty { "Not sent" }, Modifier.weight(1f), style = Theme.Type.tiny, color = Theme.colors.danger, maxLines = 2)
						Chip("Retry", icon = "refresh") { link.run("messages", "dispatch", json("id" to entry["id"].string)) }
						Chip("Drop", icon = "close") { link.run("messages", "forget", json("id" to entry["id"].string)) }
					}
				}
			}
		}
	}
}

/**
 * Writing a mail: a reply to all in a chat, or a new one. Plain text; the
 * PC adds the account's signature and sends it after its grace period.
 */
@Composable
private fun ComposeSheet(messages: JsonElement?, key: String, chat: JsonElement? = null, last: JsonElement? = null, onDismiss: () -> Unit) {
	val link = link
	val scope = rememberCoroutineScope()
	val accounts = messages["accounts"].list
	val reply = chat != null
	var account by remember { mutableStateOf(chat["account"].string.ifEmpty { accounts.firstOrNull()["id"].string }) }
	var to by remember { mutableStateOf(if (reply) chat["people"].list.joinToString(", ") { it["email"].string } else "") }
	var subject by remember { mutableStateOf(if (reply) chat["subject"].string else "") }
	var text by remember { mutableStateOf("") }
	var snippets by remember { mutableStateOf(false) }
	var error by remember { mutableStateOf("") }
	Sheet(onDismiss, if (reply) "Reply to all" else "New mail") { close ->
		if (!reply && accounts.size > 1) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			for (entry in accounts) Chip(entry["name"].string.ifEmpty { entry["address"].string }, active = entry["id"].string == account) { account = entry["id"].string }
		}
		Field(to, placeholder = "To (addresses, separated by commas)", icon = "account_outline", keyboard = KeyboardType.Email) { to = it }
		if (!reply) Field(subject, placeholder = "Subject", icon = "text_short") { subject = it }
		Field(text, placeholder = if (reply) "Your answer" else "Your mail", singleLine = false) { text = it }
		if (error.isNotEmpty()) Label(error, color = Theme.colors.danger, maxLines = 3)
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
			if (messages["snippets"].list.isNotEmpty()) SoftButton("Snippet", Modifier.padding(vertical = 4.dp), icon = "text_box_multiple_outline") { snippets = true }
			Spacer(Modifier.weight(1f))
			PrimaryButton("Send", icon = "send", enabled = text.isNotBlank() && to.isNotBlank()) {
				scope.launch {
					try {
						link.call("messages", "send", json(
							"key" to key, "account" to account, "mode" to if (reply) "replyAll" else "new",
							"reply" to (last["id"].string), "to" to to, "subject" to subject, "text" to text,
						))
						link.toast(if (reply) "Answer on its way" else "Mail on its way")
						close()
					} catch (failure: LinkError) {
						error = link.describe(failure)
					}
				}
			}
		}
	}
	if (snippets) Sheet({ snippets = false }, "Snippets") { closeSnippets ->
		val firstName = chat["people"].list.firstOrNull()["name"].string.substringBefore(' ')
		Panel(padding = PaddingValues(6.dp)) {
			for (snippet in messages["snippets"].list) ListRow(snippet["name"].string, icon = "text_box_outline", subtitle = snippet["text"].string.replace("{name}", firstName), onClick = {
				val filled = snippet["text"].string.replace("{name}", firstName)
				text = if (text.isBlank()) filled else "${text.trimEnd()}\n$filled"
				closeSnippets()
			})
		}
	}
}

/** The mail assistant of the PC (Ollama): asked about the open chat, it drafts or explains. */
@Composable
private fun AssistantSheet(open: JsonElement?, onDismiss: () -> Unit) {
	val link = link
	val clipboard = LocalClipboardManager.current
	var question by remember { mutableStateOf("") }
	val assistant = open["assistant"]
	Sheet(onDismiss, "Mail assistant") { _ ->
		val said = assistant["said"].list
		if (said.isEmpty()) Label("Ask for a draft, a summary or a translation of this chat. The model runs on the PC.", color = Theme.colors.textMuted, maxLines = 3)
		for (entry in said) {
			val user = entry["role"].string == "user"
			Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (user) Theme.colors.layer3 else Theme.colors.layer2).pressable(shape = RoundedCornerShape(16.dp), onLongClick = { clipboard.setText(AnnotatedString(entry["text"].string)) }) {}.padding(12.dp)) {
				Label(if (user) "You" else "Assistant", style = Theme.Type.tiny, color = Theme.colors.textSubtle)
				Label(entry["text"].string, maxLines = 60)
			}
		}
		if (assistant["writing"].bool) Label("Writing…", style = Theme.Type.small, color = Theme.colors.primary)
		if (assistant["error"].string.isNotEmpty()) Label(assistant["error"].string, style = Theme.Type.small, color = Theme.colors.danger, maxLines = 3)
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			Chip("Draft a reply") { link.run("messages", "ask", json("text" to "Draft a short, friendly reply to the last mail.")) }
			Chip("Summarise") { link.run("messages", "ask", json("text" to "Summarise this conversation in three sentences.")) }
			if (said.isNotEmpty()) Chip("Clear", icon = "delete_outline") { link.run("messages", "forgetAssistant") }
		}
		Field(question, placeholder = "Ask the assistant", action = ImeAction.Send, onSubmit = {
			if (question.isNotBlank()) link.run("messages", "ask", json("text" to question))
			question = ""
		}, trailing = {
			IconButton("send", size = 40.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = question.isNotBlank() && !assistant["writing"].bool) {
				link.run("messages", "ask", json("text" to question))
				question = ""
			}
		}) { question = it }
	}
}
