package dev.pshell.app.features

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Palette
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

// ── todos: the tasks of Tasks.md on the PC, by group ───────────────────────
val TodosFeature = Feature(
	id = "todos",
	group = Group.Work,
	keywords = listOf("tasks", "aufgaben", "list", "liste", "board"),
	title = "Todos",
	icon = "checkbox_marked_circle_outline",
	plugins = listOf("todos"),
	summary = {
		val groups = topic("todos")["groups"].list
		val open = groups.sumOf { it["open"].int }
		if (groups.isEmpty()) "" else "$open open"
	},
	screen = { TodosScreen() },
)

/** The colour of a task's state, as the shell's Todos.markColor. */
private fun markColor(mark: String, colors: Palette): Color = when (mark) {
	"/" -> colors.warning
	"!" -> colors.danger
	"?" -> colors.secondary
	">" -> colors.tertiary
	"r" -> colors.success
	"x" -> colors.primary
	"-" -> colors.textSubtle
	else -> colors.textMuted
}

private val priorities = listOf(3 to "High", 2 to "Medium", 1 to "Low", 0 to "None")
private val priorityIcons = mapOf(3 to "chevron_double_up", 2 to "chevron_up", 1 to "chevron_down")

private fun priorityColor(level: Int, colors: Palette): Color = when (level) {
	3 -> colors.danger
	2 -> colors.warning
	else -> colors.secondary
}

@Composable
private fun TodosScreen() {
	val todos = topic("todos")
	val groups = todos["groups"].list
	val link = link
	var picked by rememberSaveable { mutableStateOf("") }
	var creating by remember { mutableStateOf(false) }
	var open by remember { mutableStateOf<String?>(null) }
	var showClosed by rememberSaveable { mutableStateOf(false) }
	val group = groups.firstOrNull { it["name"].string == picked } ?: groups.firstOrNull()
	Screen("Todos", actions = { IconButton("folder_plus_outline", color = Theme.colors.layer2) { creating = true } }) {
		if (todos == null) {
			EmptyState("checkbox_marked_circle_outline", "Loading…")
			return@Screen
		}
		Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			for (entry in groups) {
				val name = entry["name"].string
				val count = entry["open"].int
				Chip(if (count > 0) "$name  $count" else name, active = entry == group) { picked = name }
			}
		}
		if (group == null) return@Screen
		val name = group["name"].string
		var adding by remember(name) { mutableStateOf("") }
		Field(adding, placeholder = "Add a task", icon = "plus", onSubmit = {
			if (adding.isNotBlank()) link.run("todos", "add", json("group" to name, "text" to adding))
			adding = ""
		}) { adding = it }
		val tasks = group["tasks"].list
		val active = tasks.filter { !it["closed"].bool }
		val closed = tasks.filter { it["closed"].bool }
		if (tasks.isEmpty()) EmptyState("checkbox_marked_circle_outline", "Nothing to do")
		// without a category first, then the categories in the file's order
		val sections = listOf("") + group["categories"].list.map { it.string }
		for (section in sections) {
			val those = active.filter { it["section"].string == section }
			if (those.isEmpty()) continue
			if (section.isNotEmpty()) SectionLabel(section)
			Panel(padding = PaddingValues(horizontal = 6.dp, vertical = 6.dp)) {
				for (task in those) TaskRow(task) { open = task["key"].string }
			}
		}
		if (closed.isNotEmpty()) {
			Row(
				Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.Radius.medium)).pressable { showClosed = !showClosed }.padding(horizontal = 6.dp, vertical = 6.dp),
				verticalAlignment = Alignment.CenterVertically,
			) {
				Label("Done · ${closed.size}", Modifier.weight(1f), style = Theme.Type.label, color = Theme.colors.textMuted)
				Glyph(if (showClosed) "chevron_up" else "chevron_down", size = 18.dp, color = Theme.colors.textMuted)
			}
			if (showClosed) Panel(padding = PaddingValues(horizontal = 6.dp, vertical = 6.dp)) {
				for (task in closed) TaskRow(task) { open = task["key"].string }
			}
		}
	}
	open?.let { key ->
		val task = groups.flatMap { it["tasks"].list }.firstOrNull { it["key"].string == key }
		if (task != null) TaskSheet(todos, task) { open = null }
	}
	if (creating) {
		var title by remember { mutableStateOf("") }
		Sheet({ creating = false }, "New group") { close ->
			Field(title, placeholder = "Name") { title = it }
			PrimaryButton("Create", Modifier.fillMaxWidth(), enabled = title.isNotBlank()) {
				link.run("todos", "group", json("name" to title))
				picked = title.trim()
				close()
			}
		}
	}
}

@Composable
private fun TaskRow(task: JsonElement, onOpen: () -> Unit) {
	val link = link
	val mark = task["mark"].string
	val closed = task["closed"].bool
	val icon = topic("todos")["states"].list.firstOrNull { it["mark"].string == mark }?.get("icon").string.ifEmpty { "checkbox_blank_outline" }
	Row(
		Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.Radius.large)).pressable(pressedScale = 0.99f, onClick = onOpen)
			.padding(start = (6 + task["indent"].int * 18).dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Box(
			Modifier.size(40.dp).clip(CircleShape).pressable(haptic = true) {
				link.run("todos", "toggle", json("key" to task["key"].string))
			},
			contentAlignment = Alignment.Center,
		) {
			Glyph(icon, size = 22.dp, color = markColor(mark, Theme.colors))
		}
		Spacer(Modifier.width(6.dp))
		Column(Modifier.weight(1f)) {
			Label(
				task["text"].string,
				style = Theme.Type.body.copy(textDecoration = if (closed) TextDecoration.LineThrough else null),
				color = if (closed) Theme.colors.textSubtle else Theme.colors.text,
				maxLines = 3,
			)
			val extra = listOfNotNull(
				task["note"].string.lineSequence().firstOrNull()?.takeIf { it.isNotBlank() },
				task["notes"].list.takeIf { it.isNotEmpty() }?.joinToString(", ") { it.string },
			)
			if (extra.isNotEmpty()) Label(extra.joinToString(" · "), style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 1)
		}
		val priority = task["priority"].int
		if (priority > 0 && !closed) Glyph(priorityIcons[priority] ?: "chevron_up", size = 18.dp, color = priorityColor(priority, Theme.colors))
		if (task["classifying"].bool) Glyph("dots_horizontal", size = 18.dp, color = Theme.colors.textSubtle)
	}
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TaskSheet(todos: JsonElement?, task: JsonElement, onDismiss: () -> Unit) {
	val link = link
	val scope = rememberCoroutineScope()
	val key = task["key"].string
	var title by remember(key) { mutableStateOf(task["text"].string) }
	var description by remember(key) { mutableStateOf(task["note"].string) }
	var deleting by remember { mutableStateOf(false) }
	var reading by remember { mutableStateOf<Pair<String, String>?>(null) }
	val group = todos["groups"].list.firstOrNull { g -> g["tasks"].list.any { it["key"].string == key } }
	Sheet(onDismiss) { close ->
		Field(title, placeholder = "Title", singleLine = false) { title = it }
		Field(description, placeholder = "Description", singleLine = false) { description = it }
		if (title.trim() != task["text"].string || description.trim() != task["note"].string.trim())
			PrimaryButton("Save", Modifier.fillMaxWidth(), icon = "check", enabled = title.isNotBlank()) {
				link.run("todos", "edit", json("key" to key, "title" to title.trim(), "description" to description.trim()))
				close()
			}
		Label("State", style = Theme.Type.small, color = Theme.colors.textMuted)
		FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
			for (state in todos["states"].list) {
				val mark = state["mark"].string
				Chip(state["name"].string, icon = state["icon"].string, active = task["mark"].string == mark) {
					link.run("todos", "mark", json("key" to key, "mark" to mark))
				}
			}
		}
		Label("Priority", style = Theme.Type.small, color = Theme.colors.textMuted)
		FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
			for ((level, name) in priorities) Chip(name, icon = priorityIcons[level], active = task["priority"].int == level) {
				link.run("todos", "priority", json("key" to key, "level" to level))
			}
		}
		val categories = group["categories"].list.map { it.string }
		if (categories.isNotEmpty()) {
			Label("Category", style = Theme.Type.small, color = Theme.colors.textMuted)
			FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
				Chip("None", active = task["section"].string.isEmpty()) { link.run("todos", "category", json("key" to key, "category" to "")) }
				for (category in categories) Chip(category, active = task["section"].string == category) {
					link.run("todos", "category", json("key" to key, "category" to category))
				}
			}
		}
		val groups = todos["groups"].list.map { it["name"].string }
		if (groups.size > 1) {
			Label("Group", style = Theme.Type.small, color = Theme.colors.textMuted)
			FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
				for (name in groups) Chip(name, active = group["name"].string == name) {
					if (group["name"].string != name) {
						link.run("todos", "move", json("key" to key, "group" to name))
						close()
					}
				}
			}
		}
		val notes = task["notes"].list.map { it.string }
		if (notes.isNotEmpty()) {
			Label("Notes", style = Theme.Type.small, color = Theme.colors.textMuted)
			FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
				for (name in notes) Chip(name, icon = "note_text_outline") {
					scope.launch {
						reading = try {
							name to link.call("todos", "note", json("name" to name))["text"].string
						} catch (error: LinkError) {
							name to link.describe(error)
						}
					}
				}
			}
		}
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
			SoftButton("Delete", Modifier.weight(1f).padding(vertical = 4.dp), icon = "delete_outline", tint = Theme.colors.danger) { deleting = true }
			SoftButton("Show on the PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "monitor_share") {
				link.run("todos", "show", json("key" to key))
				close()
			}
		}
	}
	reading?.let { (name, text) ->
		Sheet({ reading = null }, name) {
			Label(text.trim().ifEmpty { "Empty" }, color = if (text.isBlank()) Theme.colors.textMuted else Theme.colors.text, maxLines = 400)
		}
	}
	if (deleting) Confirm("Delete the task", "Delete \"${task["text"].string}\" and its description?", confirm = "Delete", danger = true, onDismiss = { deleting = false }) {
		link.run("todos", "delete", json("key" to key))
		onDismiss()
	}
}
