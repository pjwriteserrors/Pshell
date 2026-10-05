package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import dev.pshell.app.link.LinkError
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import kotlinx.serialization.json.JsonElement

val AgentsFeature = Feature(
	id = "agents",
	title = "Agents",
	icon = "robot",
	plugins = listOf("agents"),
	card = { open -> AgentsCard(open) },
	screen = { AgentsScreen() },
)

@Composable
private fun since(agent: JsonElement): String {
	val started = agent["since"].long
	if (started <= 0) return ""
	val minutes = ((link.pcNow() - started) / 60000).coerceAtLeast(0)
	return if (minutes < 1) "just started" else "$minutes min"
}

@Composable
private fun AgentsCard(open: () -> Unit) {
	val agents = topic("agents")["agents"].list
	if (agents.isEmpty()) return
	val waiting = agents.count { it["state"].string == "waiting" }
	val busy = agents.size - waiting
	Panel(onClick = open, color = if (waiting > 0) Theme.colors.primaryContainer else Theme.colors.layer1, padding = PaddingValues(14.dp)) {
		Row(verticalAlignment = Alignment.CenterVertically) {
			Glyph("robot", size = 24.dp, color = if (waiting > 0) Theme.colors.primary else Theme.colors.textMuted)
			Spacer(Modifier.width(14.dp))
			Column(Modifier.weight(1f)) {
				Label(listOfNotNull(if (waiting > 0) "$waiting waiting for you" else null, if (busy > 0) "$busy working" else null).joinToString(" · "), style = Theme.Type.title)
				Label(agents.joinToString(" · ") { it["topic"].string.ifEmpty { it["agent"].string } }, style = Theme.Type.small, color = Theme.colors.textMuted)
			}
			Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
		}
	}
}

@Composable
private fun AgentsScreen() {
	val agents = topic("agents")["agents"].list
	val link = link
	var answering by remember { mutableStateOf<JsonElement?>(null) }
	var reading by remember { mutableStateOf<JsonElement?>(null) }
	val context = androidx.compose.ui.platform.LocalContext.current
	val nav = dev.pshell.app.ui.LocalNav.current
	var transcript by remember { mutableStateOf<JsonElement?>(null) }
	val scope = androidx.compose.runtime.rememberCoroutineScope()
	Screen("Agents", subtitle = if (agents.isEmpty()) "" else "${agents.size} in terminals") {
		if (agents.isEmpty()) EmptyState("robot", "No agents", text = "Coding agents that run in a terminal on the PC show up here: working, or waiting for an answer.")
		for (agent in agents) {
			val waiting = agent["state"].string == "waiting"
			Panel(color = if (waiting) Theme.colors.primaryContainer else Theme.colors.layer1, padding = PaddingValues(6.dp)) {
				ListRow(
					agent["topic"].string.ifEmpty { agent["agent"].string },
					icon = if (waiting) "message_reply_text_outline" else "progress_clock",
					subtitle = listOf(agent["agent"].string, if (waiting) "waits for you" else "working", since(agent)).filter { it.isNotEmpty() }.joinToString(" · "),
					iconBackground = if (waiting) Theme.colors.primary else Theme.colors.layer3,
					iconTint = if (waiting) Theme.colors.onPrimary else Theme.colors.text,
				)
				Row(Modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					Spacer(Modifier.width(2.dp))
					SoftButton("Answer", icon = "send") { answering = agent }
					SoftButton("Last answer", icon = "text_box_outline") {
						reading = agent
						transcript = null
						scope.launch {
							transcript = try {
								link.call("transcript", "last", json("topic" to agent["topic"].string, "agent" to agent["agent"].string), timeoutSeconds = 30)
							} catch (failure: LinkError) {
								json("error" to link.describe(failure))
							}
						}
					}
					SoftButton("Show on the PC", icon = "monitor") { link.run("agents", "focus", json("window" to agent["window"].int)) }
				}
				Spacer(Modifier.width(6.dp))
			}
		}
	}
	// what the agent said last, read from its transcript on the PC
	reading?.let { agent ->
		Sheet({ reading = null }, transcript["title"].string.ifEmpty { agent["topic"].string.ifEmpty { "Last answer" } }) { _ ->
			val found = transcript
			when {
				found == null -> Label("Reading the transcript…", color = Theme.colors.textMuted)
				found["error"].string.isNotEmpty() -> Label(found["error"].string, color = Theme.colors.danger, maxLines = 3)
				else -> {
					Label(listOf(found["agent"].string, found["at"].string.replace('T', ' ').take(16), found["cwd"].string.substringAfterLast('/')).filter { it.isNotEmpty() }.joinToString(" · "), style = Theme.Type.tiny, color = Theme.colors.textSubtle)
					Box(Modifier.fillMaxWidth().heightIn(max = 460.dp).verticalScroll(rememberScrollState())) {
						Label(found["text"].string, maxLines = 4000)
					}
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						SoftButton("Copy", icon = "content_copy") {
							context.getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("Agent", found["text"].string))
						}
						if (dev.pshell.app.ui.pluginOn("chat")) SoftButton("To the chat", icon = "creation") {
							Chat.clear()
							Chat.messages.add(ChatMessage("assistant", found["text"].string))
							nav.open("feature/chat")
						}
					}
				}
			}
		}
	}

	answering?.let { agent ->
		var text by remember { mutableStateOf("") }
		Sheet({ answering = null }, agent["topic"].string.ifEmpty { "Answer" }) { close ->
			Label("Typed into the agent's terminal on the PC and sent.", style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
			Field(text, placeholder = "Your answer", singleLine = false, trailing = {
				IconButton("send", size = 40.dp, color = Theme.colors.primary, tint = Theme.colors.onPrimary, enabled = text.isNotBlank()) {
					link.run("agents", "reply", json("window" to agent["window"].int, "text" to text))
					close()
				}
			}) { text = it }
		}
	}
}
