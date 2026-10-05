package dev.pshell.app.features

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.pshell.app.App
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.service.Transfers
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.pressable
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.launch

val ChatFeature = Feature(
	id = "chat",
	title = "AI chat",
	icon = "creation",
	plugins = listOf("chat"),
	screen = { ChatScreen() },
)

/** Something sent along with a message: a picture the model looks at, or a text file it reads. */
class Attachment(val name: String, val text: String = "", val image: String = "", val preview: Bitmap? = null)

class ChatMessage(val role: String, text: String, val attachments: List<Attachment> = emptyList()) {
	var text by mutableStateOf(text)
}

/** What to do with a piece of text that was marked somewhere on the phone. */
enum class TextAction(val label: String, val icon: String, val prompt: String) {
	Explain("Explain", "lightbulb_on_outline", "Explain this, briefly and clearly:"),
	Summarise("Summarise", "text_short", "Summarise this in a few sentences:"),
	Translate("Translate", "translate", "Translate this into German. If it is German already, translate it into English. Answer with the translation only:"),
	Improve("Improve the wording", "auto_fix", "Improve the wording of this. Keep its meaning and its language. Answer with the improved text only:"),
}

/**
 * The conversation with a model on the PC. It lives outside the screen, so
 * an answer keeps arriving while another screen is open, and a text marked
 * in another app can start one.
 */
object Chat {
	val messages = mutableStateListOf<ChatMessage>()
	var models by mutableStateOf<List<String>>(emptyList())
	var model by mutableStateOf("")
	var running by mutableStateOf("")
	var error by mutableStateOf("")
	val pending = mutableStateListOf<Attachment>()
	private lateinit var app: App

	fun install(app: App) {
		this.app = app
		app.link.scope.launch {
			app.link.events.collect { event ->
				if (event.topic != "chat" || event.data["id"].string != running) return@collect
				when (event.name) {
					"delta" -> messages.lastOrNull()?.let { it.text += event.data["text"].string }
					"done" -> {
						if (event.data["error"].string.isNotEmpty()) error = event.data["error"].string
						running = ""
					}
				}
			}
		}
	}

	suspend fun loadModels() {
		if (models.isNotEmpty()) return
		try {
			models = app.link.call("chat", "models")["models"].list.map { it["name"].string }
			if (model.isEmpty()) model = app.prefs.chatModel.value.takeIf { it in models } ?: models.firstOrNull().orEmpty()
		} catch (failure: LinkError) {
			error = app.link.describe(failure)
		}
	}

	fun choose(name: String) {
		model = name
		app.prefs.chatModel.value = name
	}

	fun stop() {
		if (running.isNotEmpty()) app.link.run("chat", "stop", json("id" to running))
	}

	fun clear() {
		stop()
		messages.clear()
		error = ""
	}

	/** Sends the conversation as it stands and waits for the answer to stream in. */
	private fun answer() {
		error = ""
		val id = "c${System.currentTimeMillis()}"
		val history = messages.map { message ->
			val files = message.attachments.filter { it.text.isNotEmpty() }.joinToString("") { "\n\n[${it.name}]\n```\n${it.text}\n```" }
			val images = message.attachments.filter { it.image.isNotEmpty() }.map { it.image }
			if (images.isEmpty()) json("role" to message.role, "content" to message.text + files)
			else json("role" to message.role, "content" to message.text + files, "images" to images)
		}
		messages.add(ChatMessage("assistant", ""))
		running = id
		app.link.scope.launch {
			loadModels()
			try {
				if (model.isEmpty()) throw LinkError("no-model", error.ifEmpty { "No model on the PC" })
				app.link.call("chat", "send", json("id" to id, "model" to model, "messages" to history))
			} catch (failure: LinkError) {
				error = app.link.describe(failure)
				running = ""
			}
		}
	}

	fun send(text: String) {
		if (running.isNotEmpty() || (text.isBlank() && pending.isEmpty())) return
		messages.add(ChatMessage("user", text.trim(), pending.toList()))
		pending.clear()
		answer()
	}

	/** The message at [index] is rewritten; what came after it is dropped and answered anew. */
	fun edit(index: Int, text: String) {
		if (running.isNotEmpty() || index !in messages.indices) return
		val old = messages[index]
		while (messages.size > index) messages.removeAt(messages.lastIndex)
		messages.add(ChatMessage("user", text.trim(), old.attachments))
		answer()
	}

	/** The last answer is thrown away and asked for again. */
	fun regenerate() {
		if (running.isNotEmpty() || messages.lastOrNull()?.role != "assistant") return
		messages.removeAt(messages.lastIndex)
		answer()
	}

	/** A new conversation about a text marked elsewhere. */
	fun ask(action: TextAction, text: String) {
		clear()
		messages.add(ChatMessage("user", "${action.prompt}\n\n$text"))
		answer()
	}

	/** Reads what was picked: pictures are made small enough to send, text files are read. */
	fun attach(context: Context, uris: List<Uri>) {
		for (uri in uris) {
			val (name, _) = Transfers.nameOf(context, uri)
			val type = context.contentResolver.getType(uri).orEmpty()
			try {
				if (type.startsWith("image/")) {
					val full = context.contentResolver.openInputStream(uri)!!.use { BitmapFactory.decodeStream(it) } ?: throw java.io.IOException("Not a picture")
					val scale = 1280f / maxOf(full.width, full.height).coerceAtLeast(1280)
					val small = Bitmap.createScaledBitmap(full, (full.width * scale).toInt().coerceAtLeast(1), (full.height * scale).toInt().coerceAtLeast(1), true)
					val bytes = ByteArrayOutputStream().also { small.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
					pending.add(Attachment(name, image = Base64.encodeToString(bytes, Base64.NO_WRAP), preview = Bitmap.createScaledBitmap(small, 160, (160f * small.height / small.width).toInt().coerceAtLeast(1), true)))
				} else {
					val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readNBytes(200 * 1024) }
					val text = bytes.toString(Charsets.UTF_8)
					if (text.count { it == '�' || it == '\u0000' } > text.length / 50) throw java.io.IOException("Only pictures and text files can be attached")
					pending.add(Attachment(name, text = text))
				}
			} catch (failure: Exception) {
				error = "$name: ${failure.message ?: "could not be read"}"
			}
		}
	}
}

@Composable
private fun AttachmentChip(attachment: Attachment, onRemove: (() -> Unit)? = null) {
	Row(Modifier.clip(RoundedCornerShape(14.dp)).background(Theme.colors.layer3).padding(end = 10.dp), verticalAlignment = Alignment.CenterVertically) {
		val preview = attachment.preview
		if (preview != null) Image(preview.asImageBitmap(), null, Modifier.size(40.dp).clip(RoundedCornerShape(14.dp)), contentScale = ContentScale.Crop)
		else Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) { Glyph("file_document_outline", size = 20.dp, color = Theme.colors.textMuted) }
		Spacer(Modifier.width(8.dp))
		Label(attachment.name, Modifier.widthIn(max = 140.dp), style = Theme.Type.small)
		if (onRemove != null) {
			Spacer(Modifier.width(4.dp))
			IconButton("close", size = 28.dp, iconSize = 14.dp, onClick = onRemove)
		}
	}
}

@Composable
private fun ChatScreen() {
	val context = LocalContext.current
	var draft by remember { mutableStateOf("") }
	var editing by remember { mutableStateOf(-1) }
	val listState = rememberLazyListState()
	val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> Chat.attach(context, uris) }

	LaunchedEffect(Unit) { Chat.loadModels() }
	LaunchedEffect(Chat.messages.size, Chat.messages.lastOrNull()?.text?.length) {
		if (Chat.messages.isNotEmpty()) listState.scrollToItem(Chat.messages.lastIndex, Int.MAX_VALUE)
	}

	Screen("AI chat", subtitle = Chat.model.ifEmpty { "The model runs on the PC" }, scroll = false, actions = {
		if (Chat.messages.isNotEmpty()) IconButton("plus", color = Theme.colors.layer2) { Chat.clear() }
	}) {
		if (Chat.models.size > 1) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			for (name in Chat.models) Chip(name, active = name == Chat.model) { Chat.choose(name) }
		}
		if (Chat.error.isNotEmpty()) Label(Chat.error, color = Theme.colors.danger, maxLines = 3)
		LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = listState, verticalArrangement = Arrangement.spacedBy(8.dp)) {
			if (Chat.messages.isEmpty()) item { EmptyState("creation", "Ask something", text = "Attach pictures or text files with the clip. Hold a message of yours to change it.") }
			itemsIndexed(Chat.messages) { index, message ->
				val mine = message.role == "user"
				Column(Modifier.fillMaxWidth(), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
					if (message.attachments.isNotEmpty()) Row(Modifier.padding(bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
						for (attachment in message.attachments) AttachmentChip(attachment)
					}
					Box(
						Modifier
							.widthIn(max = 330.dp)
							.pressable(shape = RoundedCornerShape(22.dp), pressedScale = 0.99f, onLongClick = {
								if (mine && Chat.running.isEmpty()) editing = index
								else context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("AI", message.text))
							}) {}
							.background(if (mine) Theme.colors.primary else Theme.colors.layer1)
							.padding(horizontal = 14.dp, vertical = 10.dp),
					) {
						Label(message.text.ifEmpty { if (Chat.running.isNotEmpty()) "…" else "" }, color = if (mine) Theme.colors.onPrimary else Theme.colors.text, maxLines = 4000)
					}
					// under the last answer: again, or take it along
					if (!mine && index == Chat.messages.lastIndex && Chat.running.isEmpty() && message.text.isNotEmpty()) {
						Row(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
							Chip("Again", icon = "refresh") { Chat.regenerate() }
							Chip("Copy", icon = "content_copy") { context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("AI", message.text)) }
							if (dev.pshell.app.ui.pluginOn("phone-clipboard")) Chip("To the PC", icon = "monitor") { App.instance.link.run("clipboard", "set", json("text" to message.text)) }
						}
					}
				}
			}
		}
		if (Chat.pending.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			for (attachment in Chat.pending) AttachmentChip(attachment) { Chat.pending.remove(attachment) }
		}
		Row(Modifier.padding(bottom = 12.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			IconButton("paperclip", size = 52.dp, color = Theme.colors.layer1) { picker.launch(arrayOf("image/*", "text/*", "application/json", "application/xml", "application/x-sh", "application/octet-stream")) }
			Field(draft, Modifier.weight(1f), placeholder = "Message", singleLine = false, trailing = {
				if (Chat.running.isNotEmpty()) IconButton("stop", size = 40.dp, color = Theme.colors.layer3) { Chat.stop() }
				else IconButton("send", size = 40.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = draft.isNotBlank() || Chat.pending.isNotEmpty()) {
					Chat.send(draft)
					draft = ""
				}
			}) { draft = it }
		}
	}

	if (editing in Chat.messages.indices) {
		var text by remember(editing) { mutableStateOf(Chat.messages[editing].text) }
		Sheet({ editing = -1 }, "Change the message") { close ->
			Field(text, placeholder = "Message", singleLine = false) { text = it }
			Label("What came after it is dropped and answered anew.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 2)
			PrimaryButton("Send again", Modifier.fillMaxWidth(), icon = "send", enabled = text.isNotBlank()) {
				Chat.edit(editing, text)
				close()
			}
		}
	}
}

/** Asked when a marked text arrives through "Ask AI": what should the model do with it? */
@Composable
fun TextActionSheet(text: String, onDismiss: () -> Unit, onChosen: () -> Unit) {
	var question by remember { mutableStateOf("") }
	Sheet(onDismiss, "Ask AI") { close ->
		Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.colors.layer2).padding(12.dp)) {
			Label(text, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 5)
		}
		for (pair in TextAction.entries.chunked(2)) {
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (action in pair) {
					Row(
						Modifier.weight(1f).height(52.dp).pressable(shape = RoundedCornerShape(26.dp), haptic = true) {
							Chat.ask(action, text)
							onChosen()
							close()
						}.background(Theme.colors.layer3).padding(horizontal = 14.dp),
						verticalAlignment = Alignment.CenterVertically,
					) {
						Glyph(action.icon, size = 20.dp, color = Theme.colors.primary)
						Spacer(Modifier.width(8.dp))
						Label(action.label, style = Theme.Type.label)
					}
				}
			}
		}
		Field(question, placeholder = "Or ask something about it", trailing = {
			IconButton("send", size = 40.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = question.isNotBlank()) {
				Chat.clear()
				Chat.send("${question.trim()}\n\n$text")
				onChosen()
				close()
			}
		}) { question = it }
	}
}
