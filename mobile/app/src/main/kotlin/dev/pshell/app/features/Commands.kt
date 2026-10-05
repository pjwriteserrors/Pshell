package dev.pshell.app.features

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Palette
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Field
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Segmented
import dev.pshell.app.ui.widgets.Sheet
import dev.pshell.app.ui.widgets.SoftButton
import dev.pshell.app.ui.widgets.Toggle
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

val CommandsFeature = Feature(
	id = "commands",
	title = "Commands",
	icon = "console",
	plugins = listOf("phone-commands"),
	tab = 3,
	screen = { CommandsScreen() },
)

/** A tile as it is edited; the PC's commands.json holds the same keys. */
private data class Tile(
	val id: String,
	val label: String = "",
	val icon: String = "console",
	val color: String = "",
	val w: Int = 1,
	val h: Int = 1,
	val command: String = "",
	val confirm: Boolean = false,
	val output: Boolean = false,
	val state: String = "",
	val fields: List<JsonElement> = emptyList(),
	val terminal: Boolean = false,
) {
	fun toJson(): JsonObject = json(
		"id" to id, "label" to label, "icon" to icon, "color" to color, "w" to w, "h" to h, "command" to command,
		"confirm" to confirm, "output" to output, "state" to state, "fields" to fields, "terminal" to terminal,
	)

	companion object {
		fun from(element: JsonElement) = Tile(
			id = element["id"].string, label = element["label"].string, icon = element["icon"].string.ifEmpty { "console" },
			color = element["color"].string, w = element["w"].int.coerceIn(1, 4), h = element["h"].int.coerceIn(1, 2),
			command = element["command"].string, confirm = element["confirm"].bool, output = element["output"].bool,
			state = element["state"].string, fields = element["fields"].list, terminal = element["terminal"].bool,
		)
	}
}

private val tileColors = listOf("", "primary", "secondary", "tertiary", "success", "warning", "danger")

private fun tint(palette: Palette, name: String): Color = when (name) {
	"primary" -> palette.primary
	"secondary" -> palette.secondary
	"tertiary" -> palette.tertiary
	"success" -> palette.success
	"warning" -> palette.warning
	"danger" -> palette.danger
	else -> palette.fg
}

/** Tiles of different sizes packed into a grid of [columns], row by row, first fit. */
@Composable
private fun TileGrid(columns: Int, spans: List<Pair<Int, Int>>, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
	Layout(content, modifier) { measurables, constraints ->
		val gap = 10.dp.roundToPx()
		val cell = (constraints.maxWidth - gap * (columns - 1)) / columns
		val taken = ArrayList<BooleanArray>()
		fun free(row: Int, column: Int, w: Int, h: Int): Boolean {
			if (column + w > columns) return false
			for (r in row until row + h) for (c in column until column + w) if (taken.getOrNull(r)?.get(c) == true) return false
			return true
		}
		val places = measurables.mapIndexed { index, measurable ->
			val w = spans[index].first.coerceAtMost(columns)
			val h = spans[index].second
			var row = 0
			var column = 0
			search@ while (true) {
				for (c in 0 until columns) if (free(row, c, w, h)) {
					column = c
					break@search
				}
				row += 1
			}
			while (taken.size < row + h) taken.add(BooleanArray(columns))
			for (r in row until row + h) for (c in column until column + w) taken[r][c] = true
			val width = cell * w + gap * (w - 1)
			val height = cell * h + gap * (h - 1)
			Triple(measurable.measure(Constraints.fixed(width, height)), column * (cell + gap), row * (cell + gap))
		}
		val height = if (taken.isEmpty()) 0 else taken.size * cell + (taken.size - 1) * gap
		layout(constraints.maxWidth, height) { places.forEach { (placeable, x, y) -> placeable.place(x, y) } }
	}
}

@Composable
private fun CommandsScreen() {
	val commands = topic("commands")
	val link = link
	val nav = dev.pshell.app.ui.LocalNav.current
	val scope = rememberCoroutineScope()
	val columns = commands["columns"].int.coerceIn(2, 6).takeIf { commands != null } ?: 4
	val tiles = commands["tiles"].list.map(Tile::from)
	var editing by remember { mutableStateOf(false) }
	var edited by remember { mutableStateOf<Tile?>(null) }
	var asking by remember { mutableStateOf<Tile?>(null) }
	var result by remember { mutableStateOf<Pair<String, String>?>(null) }
	val running = remember { mutableStateMapOf<String, Boolean>() }

	fun save(next: List<Tile>) = link.run("commands", "save", json("columns" to columns, "tiles" to next.map { it.toJson() }))

	fun run(tile: Tile, values: Map<String, String> = emptyMap()) {
		running[tile.id] = true
		scope.launch {
			try {
				val answer = link.call("commands", "run", json("id" to tile.id, "values" to values), timeoutSeconds = 70)
				if (tile.output) result = tile.label to (answer["output"].string.ifBlank { if (answer["running"].bool) "Still running on the PC." else "Done, without output." } + (answer["code"].int.takeIf { it != 0 }?.let { "\n\nexit code $it" } ?: ""))
			} catch (error: LinkError) {
				result = tile.label to link.describe(error)
			} finally {
				running.remove(tile.id)
			}
		}
	}

	Screen("Commands", subtitle = if (editing) "Tap a tile to change it" else "", actions = {
		if (commands["editable"].bool) {
			if (editing) IconButton("plus", color = Theme.colors.layer2) { edited = Tile(id = "t${System.currentTimeMillis().toString(36)}", label = "New") }
			Spacer(Modifier.size(8.dp))
			IconButton(if (editing) "check" else "pencil", color = if (editing) Theme.colors.primary else Theme.colors.layer2, tint = if (editing) Theme.colors.onPrimary else Theme.colors.text) { editing = !editing }
		}
	}) {
		if (commands["error"].present) Label(commands["error"].string, color = Theme.colors.danger, maxLines = 3)
		if (tiles.isEmpty() && commands != null) {
			EmptyState("console", "No commands yet", text = "Add tiles with the pencil, or write ~/.config/pshell/commands.json on the PC.")
		}
		TileGrid(columns, tiles.map { it.w to it.h }, Modifier.fillMaxWidth()) {
			for (tile in tiles) {
				val state = commands["states"][tile.id]
				val on = state["on"].bool
				val accent = tint(Theme.colors, tile.color)
				val neutral = tile.color.isEmpty()
				val background by animateColorAsState(
					when {
						on -> accent
						neutral -> Theme.colors.layer1
						else -> accent.copy(alpha = 0.18f).compositeOver(Theme.colors.bg)
					},
					label = "tile",
				)
				val foreground = if (on) (if (Palette.contrast(accent, Theme.colors.bg) >= Palette.contrast(accent, Theme.colors.fg)) Theme.colors.bg else Theme.colors.fg) else Theme.colors.text
				val iconTint = if (on) foreground else if (neutral) Theme.colors.text else accent
				Box(
					Modifier
						.pressable(shape = RoundedCornerShape(26.dp), pressedScale = 0.94f, haptic = true) {
							when {
								editing -> edited = tile
								tile.terminal -> nav.open("terminal/run/${tile.id}")
								tile.confirm || tile.fields.isNotEmpty() -> asking = tile
								else -> run(tile)
							}
						}
						.background(background)
						.padding(12.dp),
				) {
					val wide = tile.w >= 2 && tile.h == 1
					if (wide) {
						Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
							Glyph(if (running[tile.id] == true) "progress_clock" else tile.icon, size = 28.dp, color = iconTint)
							Spacer(Modifier.size(10.dp))
							Column {
								Label(tile.label, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold), color = foreground, maxLines = 2)
								if (state["text"].string.isNotEmpty()) Label(state["text"].string, style = Theme.Type.small, color = foreground.copy(alpha = 0.7f))
							}
						}
					} else {
						Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.SpaceBetween) {
							Glyph(if (running[tile.id] == true) "progress_clock" else tile.icon, size = if (tile.h >= 2) 36.dp else 26.dp, color = iconTint)
							Column {
								Label(tile.label, style = Theme.Type.small.copy(fontWeight = FontWeight.SemiBold), color = foreground, maxLines = 2)
								if (tile.h >= 2 && state["text"].string.isNotEmpty()) Label(state["text"].string, style = Theme.Type.small, color = foreground.copy(alpha = 0.7f))
							}
						}
					}
					if (editing) Box(Modifier.align(Alignment.TopEnd).size(22.dp).clip(CircleShape).background(Theme.colors.layer3), contentAlignment = Alignment.Center) {
						Glyph("pencil", size = 12.dp, color = Theme.colors.textMuted)
					}
				}
			}
		}
	}

	asking?.let { tile -> RunSheet(tile, onDismiss = { asking = null }) { values -> run(tile, values) } }
	result?.let { (title, text) ->
		Sheet({ result = null }, title) {
			Box(Modifier.fillMaxWidth().heightIn(max = 420.dp).clip(RoundedCornerShape(Theme.Radius.large)).background(Theme.colors.bg).verticalScroll(rememberScrollState()).padding(14.dp)) {
				Label(text.trimEnd(), style = Theme.Type.small.copy(fontFamily = Theme.mono), maxLines = 400)
			}
		}
	}
	edited?.let { tile ->
		EditSheet(
			tile,
			isNew = tiles.none { it.id == tile.id },
			onDismiss = { edited = null },
			onSave = { next -> save(if (tiles.any { it.id == next.id }) tiles.map { if (it.id == next.id) next else it } else tiles + next) },
			onDelete = { save(tiles.filter { it.id != tile.id }) },
			onMove = { delta ->
				val index = tiles.indexOfFirst { it.id == tile.id }
				val target = (index + delta).coerceIn(0, tiles.lastIndex)
				if (index >= 0 && target != index) save(tiles.toMutableList().apply { add(target, removeAt(index)) })
			},
		)
	}
}

/** Before a command that asks first: its fields, and the button. */
@Composable
private fun RunSheet(tile: Tile, onDismiss: () -> Unit, onRun: (Map<String, String>) -> Unit) {
	val values = remember { mutableStateMapOf<String, String>() }
	Sheet(onDismiss, tile.label) { close ->
		FormFields(tile.fields, values)
		PrimaryButton("Run", Modifier.fillMaxWidth(), icon = "play") {
			onRun(values.toMap())
			close()
		}
	}
}

/** The fields of a form: text, a choice of options, a switch. Also used by the PC's questions. */
@Composable
fun FormFields(fields: List<JsonElement>, values: MutableMap<String, String>) {
	for (field in fields) {
		val id = field["id"].string
		val label = field["label"].string.ifEmpty { id }
		val options = field["options"].list.map { it.string }
		when {
			field["type"].string == "toggle" -> ListRow(label) {
				Toggle(values[id] == "true") { values[id] = it.toString() }
			}
			options.isNotEmpty() -> {
				SectionLabel(label)
				Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
					for (option in options) Chip(option, active = values[id] == option) { values[id] = option }
				}
			}
			else -> Field(
				values[id] ?: field["default"].string.also { if (it.isNotEmpty()) values[id] = it },
				placeholder = field["placeholder"].string.ifEmpty { label },
				keyboard = if (field["type"].string == "number") androidx.compose.ui.text.input.KeyboardType.Number else androidx.compose.ui.text.input.KeyboardType.Text,
				singleLine = field["type"].string != "area",
			) { values[id] = it }
		}
	}
}

@Composable
private fun EditSheet(tile: Tile, isNew: Boolean, onDismiss: () -> Unit, onSave: (Tile) -> Unit, onDelete: () -> Unit, onMove: (Int) -> Unit) {
	var draft by remember { mutableStateOf(tile) }
	var picking by remember { mutableStateOf(false) }
	var fieldsText by remember { mutableStateOf(tile.fields.joinToString(", ") { "${it["id"].string}:${it["label"].string}" }) }
	Sheet(onDismiss, if (isNew) "New command" else "Edit command") { close ->
		Column(Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
			Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
				Box(Modifier.size(52.dp).pressable(shape = RoundedCornerShape(18.dp)) { picking = true }.background(Theme.colors.layer3), contentAlignment = Alignment.Center) {
					Glyph(draft.icon, size = 26.dp, color = tint(Theme.colors, draft.color))
				}
				Field(draft.label, Modifier.weight(1f), placeholder = "Label") { draft = draft.copy(label = it) }
			}
			Field(draft.command, placeholder = "Command (sh)", singleLine = false) { draft = draft.copy(command = it) }
			Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				for (name in tileColors) {
					val color = if (name.isEmpty()) Theme.colors.layer3 else tint(Theme.colors, name)
					Box(Modifier.size(36.dp).pressable(shape = CircleShape) { draft = draft.copy(color = name) }.background(color), contentAlignment = Alignment.Center) {
						if (draft.color == name) Glyph("check", size = 18.dp, color = if (name.isEmpty()) Theme.colors.text else Theme.colors.bg)
					}
				}
			}
			Segmented(listOf((1 to 1) to "1×1", (2 to 1) to "2×1", (2 to 2) to "2×2", (4 to 1) to "4×1"), draft.w to draft.h, Modifier.fillMaxWidth()) { (w, h) -> draft = draft.copy(w = w, h = h) }
			ListRow("Ask before it runs", icon = "help_circle_outline") { Toggle(draft.confirm) { draft = draft.copy(confirm = it) } }
			ListRow("Show what it prints", icon = "text_box_outline") { Toggle(draft.output) { draft = draft.copy(output = it) } }
			if (dev.pshell.app.ui.pluginOn("phone-terminal")) ListRow("Open in the terminal", icon = "console_line", subtitle = "To type along, a password say") { Toggle(draft.terminal) { draft = draft.copy(terminal = it) } }
			Field(draft.state, placeholder = "State command (exit 0 lights the tile)") { draft = draft.copy(state = it) }
			Field(fieldsText, placeholder = "Fields to ask for: TAG:Tag, MSG:Message") { fieldsText = it }
			Label("A field's answer is in \$PSHELL_<ID> when the command runs.", style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 2)
			if (!isNew) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
				SoftButton("Earlier", Modifier.weight(1f), icon = "arrow_left") { onMove(-1) }
				SoftButton("Later", Modifier.weight(1f), icon = "arrow_right") { onMove(1) }
				SoftButton("Delete", Modifier.weight(1f), icon = "delete_outline", tint = Theme.colors.danger) {
					onDelete()
					close()
				}
			}
			PrimaryButton("Save", Modifier.fillMaxWidth(), enabled = draft.command.isNotBlank()) {
				val fields = fieldsText.split(',').mapNotNull { part ->
					val id = part.substringBefore(':').trim().uppercase().filter { it.isLetterOrDigit() || it == '_' }
					if (id.isEmpty()) null else json("id" to id, "label" to part.substringAfter(':', id).trim(), "type" to "text")
				}
				onSave(draft.copy(fields = fields))
				close()
			}
		}
	}
	if (picking) IconPicker({ picking = false }) { draft = draft.copy(icon = it) }
}

/** Every icon the shell's font has, to search through. */
@Composable
fun IconPicker(onDismiss: () -> Unit, onPick: (String) -> Unit) {
	var search by remember { mutableStateOf("") }
	val all = remember { Icons.names }
	val words = search.trim().lowercase().split(' ').filter { it.isNotEmpty() }
	val matches = remember(search) { if (words.isEmpty()) all else all.filter { name -> words.all { name.contains(it) } } }
	Sheet(onDismiss, "Icon") { close ->
		Field(search, placeholder = "Search ${all.size} icons", icon = "magnify") { search = it }
		LazyVerticalGrid(GridCells.Adaptive(52.dp), Modifier.fillMaxWidth().height(380.dp), verticalArrangement = Arrangement.spacedBy(6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			items(matches, key = { it }) { name ->
				Box(Modifier.size(52.dp).pressable(shape = RoundedCornerShape(16.dp)) {
					onPick(name)
					close()
				}.background(Theme.colors.layer2), contentAlignment = Alignment.Center) {
					Glyph(name, size = 24.dp)
				}
			}
		}
	}
}
