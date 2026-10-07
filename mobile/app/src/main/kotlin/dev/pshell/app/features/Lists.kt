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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
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
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Ring
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.pressable
import kotlinx.serialization.json.JsonElement

// ── todos ──────────────────────────────────────────────────────────────────
val TodosFeature = Feature(
	id = "todos",
	group = Group.Work,
	keywords = listOf("tasks", "aufgaben", "list", "liste"),
	title = "Todos",
	icon = "checkbox_marked_circle_outline",
	plugins = listOf("todos"),
	summary = {
		val lists = topic("todos")["lists"].list
		val open = lists.sumOf { it["total"].int - it["done"].int }
		if (lists.isEmpty()) "" else "$open open"
	},
	screen = { TodosScreen() },
)

@Composable
private fun TodosScreen() {
	val lists = topic("todos")["lists"].list
	val link = link
	var creating by remember { mutableStateOf(false) }
	Screen("Todos", actions = { IconButton("plus", color = Theme.colors.layer2) { creating = true } }) {
		if (lists.isEmpty()) EmptyState("checkbox_marked_circle_outline", "No lists", text = "Markdown files in ~/todo on the PC.")
		for (list in lists) {
			var adding by remember(list["path"].string) { mutableStateOf("") }
			Panel(padding = PaddingValues(start = 6.dp, end = 6.dp, top = 12.dp, bottom = 8.dp)) {
				Row(Modifier.padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
					Label(list["name"].string.replaceFirstChar { it.uppercase() }, Modifier.weight(1f), style = Theme.Type.title)
					Label("${list["done"].int}/${list["total"].int}", style = Theme.Type.label.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
				}
				if (list["total"].int > 0) Meter(list["done"].float / list["total"].float, Modifier.padding(horizontal = 10.dp, vertical = 8.dp), height = 4.dp)
				for (item in list["items"].list) {
					if (item["kind"].string == "heading") {
						if (item["level"].int > 1) SectionLabel(item["text"].string, Modifier.padding(start = 6.dp))
						continue
					}
					val done = item["done"].bool
					Row(
						Modifier
							.fillMaxWidth()
							.pressable(pressedScale = 0.99f, haptic = true) {
								link.run("todos", "toggle", json("path" to list["path"].string, "line" to item["line"].int, "text" to item["text"].string))
							}
							.padding(start = (10 + item["indent"].int * 18).dp, end = 10.dp, top = 9.dp, bottom = 9.dp),
						verticalAlignment = Alignment.CenterVertically,
					) {
						Box(Modifier.size(24.dp).clip(CircleShape).background(if (done) Theme.colors.primary else Theme.colors.layer3), contentAlignment = Alignment.Center) {
							if (done) Glyph("check", size = 15.dp, color = Theme.colors.onPrimary)
						}
						Spacer(Modifier.width(12.dp))
						Label(item["text"].string, Modifier.weight(1f), style = Theme.Type.body.copy(textDecoration = if (done) TextDecoration.LineThrough else null), color = if (done) Theme.colors.textSubtle else Theme.colors.text, maxLines = 4)
					}
				}
				Spacer(Modifier.height(4.dp))
				Field(adding, placeholder = "Add a task", icon = "plus", onSubmit = {
					if (adding.isNotBlank()) link.run("todos", "add", json("path" to list["path"].string, "text" to adding))
					adding = ""
				}) { adding = it }
			}
		}
	}
	if (creating) {
		var name by remember { mutableStateOf("") }
		Sheet({ creating = false }, "New list") { close ->
			Field(name, placeholder = "Name") { name = it }
			PrimaryButton("Create", Modifier.fillMaxWidth(), enabled = name.isNotBlank()) {
				link.run("todos", "create", json("name" to name))
				close()
			}
		}
	}
}

// ── notes ──────────────────────────────────────────────────────────────────
val NotesFeature = Feature(
	id = "notes",
	group = Group.Work,
	keywords = listOf("notizen", "memo"),
	title = "Notes",
	icon = "note_text_outline",
	plugins = listOf("notes"),
	screen = { NotesScreen() },
)

@Composable
private fun NotesScreen() {
	val notes = topic("notes")["notes"].list
	val link = link
	var editing by remember { mutableStateOf<JsonElement?>(null) }
	var creating by remember { mutableStateOf(false) }
	Screen("Notes", actions = { IconButton("plus", color = Theme.colors.layer2) { creating = true } }) {
		if (notes.isEmpty()) EmptyState("note_text_outline", "No notes")
		for (note in notes) {
			Panel(onClick = { editing = note }) {
				Label(note["title"].string, style = Theme.Type.title)
				val body = note["body"].string.trim()
				if (body.isNotEmpty() && body != note["title"].string) Label(body, color = Theme.colors.textMuted, maxLines = 5)
			}
		}
	}
	if (creating || editing != null) {
		val note = editing
		var title by remember(note) { mutableStateOf(note["ownTitle"].string) }
		var body by remember(note) { mutableStateOf(note["body"].string) }
		Sheet({ editing = null; creating = false }, if (note == null) "New note" else "Note") { close ->
			Field(title, placeholder = "Title") { title = it }
			Field(body, placeholder = "Text", singleLine = false) { body = it }
			Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				if (note != null) SoftButton("Delete", Modifier.weight(1f).padding(vertical = 4.dp), icon = "delete_outline", tint = Theme.colors.danger) {
					link.run("notes", "remove", json("id" to note["id"].string))
					close()
				}
				PrimaryButton("Save", Modifier.weight(1f), enabled = title.isNotBlank() || body.isNotBlank()) {
					link.run("notes", "save", json("id" to note["id"].string, "title" to title, "body" to body))
					close()
				}
			}
		}
	}
}

// ── rpg ────────────────────────────────────────────────────────────────────
val RpgFeature = Feature(
	id = "rpg",
	group = Group.Pc,
	keywords = listOf("game", "spiel", "level", "xp"),
	title = "RPG",
	icon = "sword_cross",
	plugins = listOf("rpg"),
	screen = {
		val rpg = topic("rpg")
		Screen("Productivity RPG") {
			if (rpg == null) EmptyState("sword_cross", "No game yet")
			else {
				Panel {
					Row(verticalAlignment = Alignment.CenterVertically) {
						Ring(1f - (rpg["enemyHp"].float / rpg["enemyMaxHp"].float.coerceAtLeast(1f)), size = 84.dp, thickness = 8.dp, color = Theme.colors.danger) {
							Label("${rpg["level"].int}", style = Theme.Type.heading)
						}
						Spacer(Modifier.width(16.dp))
						Column {
							Label("Level ${rpg["level"].int} · Stage ${rpg["stage"].int}", style = Theme.Type.title)
							Label("${rpg["xp"].int} XP · ${rpg["coins"].int} coins", color = Theme.colors.textMuted)
							if (rpg["enemyName"].string.isNotEmpty()) Label("Fighting ${rpg["enemyName"].string}", style = Theme.Type.small, color = Theme.colors.textSubtle)
						}
					}
				}
				val events = rpg["events"].list.reversed()
				if (events.isNotEmpty()) {
					SectionLabel("Lately")
					Panel(padding = PaddingValues(6.dp)) {
						for (event in events) ListRow(event["title"].string.ifEmpty { event["text"].string }, icon = "star_four_points_outline", subtitle = if (event["title"].string.isNotEmpty()) event["text"].string else "")
					}
				}
			}
		}
	},
)
