package dev.pshell.app.features

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.LocalNav
import dev.pshell.app.ui.link
import dev.pshell.app.ui.theme.Palette
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
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
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement

// ── library: the PC's file manager ─────────────────────────────────────────
val LibraryFeature = Feature(
	id = "library",
	title = "File manager",
	icon = "folder_open",
	group = Group.Pc,
	plugins = listOf("filemanager", "phone-files"),
	keywords = listOf("files", "dateien", "dateimanager", "folders", "ordner", "favorites", "favoriten", "tags", "collections", "sammlungen", "search", "suche", "recent"),
	screen = { LibraryScreen() },
	page = { place -> LibraryPage(place) },
)

/** A tag's colour is a role of the palette, as on the PC. */
private fun tagTint(palette: Palette, role: String): Color = when (role) {
	"primary" -> palette.primary
	"secondary" -> palette.secondary
	"tertiary" -> palette.tertiary
	"success" -> palette.success
	"warning" -> palette.warning
	"danger" -> palette.danger
	else -> palette.fg
}

private fun pretty(path: String, home: String): String = when {
	home.isEmpty() -> path
	path == home -> "~"
	path.startsWith("$home/") -> "~" + path.removePrefix(home)
	else -> path
}

private fun parentOf(path: String): String = path.trimEnd('/').substringBeforeLast('/', "").ifEmpty { "/" }

/** Size and date of an entry, after its folder where the list spans several. */
private fun said(entry: JsonElement, home: String, where: Boolean): String = listOf(
	if (where) pretty(parentOf(entry["path"].string), home) else "",
	if (entry["dir"].bool) "" else bytesSaid(entry["size"].long),
	whenSaid(entry["mtime"].long),
).filter { it.isNotEmpty() }.joinToString(" · ")

@Composable
private fun FileRow(entry: JsonElement, subtitle: String, background: Color = Theme.colors.layer3, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
	val dir = entry["dir"].bool
	ListRow(
		entry["name"].string,
		icon = if (dir) "folder" else fileIcon(entry["name"].string),
		subtitle = subtitle,
		iconBackground = if (dir) Theme.colors.primaryContainer else background,
		iconTint = if (dir) Theme.colors.primary else Theme.colors.text,
		onClick = onClick,
		onLongClick = onLongClick,
	) {
		if (dir) Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
	}
}

/** The file manager's home: favourites, what was opened, tags, collections. */
@Composable
private fun LibraryScreen() {
	val library = topic("library")
	val nav = LocalNav.current
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	val home = library["home"].string
	val open = { place: String -> nav.open("feature/library/${Uri.encode(place)}") }
	val favorites = library["favorites"].list
	val recent = library["recent"].list
	val tags = library["tags"].list.filter { it["count"].long > 0 }
	val collections = library["collections"].list
	Screen("File manager") {
		if (library == null) EmptyState("folder_open", "Loading…")
		else {
			Panel(padding = PaddingValues(6.dp)) {
				ListRow("Home", icon = "home_outline", iconBackground = Theme.colors.primaryContainer, iconTint = Theme.colors.primary, onClick = { open("dir:$home") }) {
					Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
				}
			}
			if (favorites.isNotEmpty()) {
				SectionLabel("Favorites")
				Panel(padding = PaddingValues(6.dp)) {
					for (entry in favorites) FileRow(entry, pretty(parentOf(entry["path"].string), home), onLongClick = { chosen = entry }) { open("dir:${entry["path"].string}") }
				}
			}
			if (tags.isNotEmpty()) {
				SectionLabel("Tags")
				Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
					for (tag in tags) Chip("${tag["name"].string}  ${tag["count"].long}", icon = "tag", tint = tagTint(Theme.colors, tag["color"].string)) { open("tag:${tag["id"].string}") }
				}
			}
			if (collections.isNotEmpty()) {
				SectionLabel("Collections")
				Panel(padding = PaddingValues(6.dp)) {
					for (collection in collections) ListRow(collection["name"].string, icon = "bookmark_box_multiple_outline", onClick = { open("collection:${collection["id"].string}") }) {
						Label("${collection["count"].long}", style = Theme.Type.small.copy(fontFeatureSettings = "tnum"), color = Theme.colors.textMuted)
						Glyph("chevron_right", size = 20.dp, color = Theme.colors.textSubtle)
					}
				}
			}
			if (recent.isNotEmpty()) {
				SectionLabel("Recent")
				Panel(padding = PaddingValues(6.dp)) {
					for (entry in recent) FileRow(entry, listOf(pretty(parentOf(entry["path"].string), home), whenSaid(entry["at"].long)).filter { it.isNotEmpty() }.joinToString(" · ")) { chosen = entry }
				}
			}
		}
	}
	chosen?.let { entry -> FileSheet(entry, library) { chosen = null } }
}

/** Where one is, a chip per folder; below the home it starts there. */
@Composable
private fun Crumbs(path: String, home: String, onPick: (String) -> Unit) {
	val scroll = rememberScrollState()
	// the folder one is in is the last chip
	LaunchedEffect(path, scroll.maxValue) { scroll.scrollTo(scroll.maxValue) }
	val inHome = home.isNotEmpty() && (path == home || path.startsWith("$home/"))
	val base = if (inHome) home else "/"
	val parts = path.removePrefix(base).split('/').filter { it.isNotEmpty() }
	Row(Modifier.fillMaxWidth().horizontalScroll(scroll), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
		Chip(if (inHome) "Home" else "/", icon = if (inHome) "home_outline" else null, active = parts.isEmpty()) { onPick(base) }
		var walked = base.trimEnd('/')
		for ((index, part) in parts.withIndex()) {
			walked = "$walked/$part"
			val target = walked
			Chip(part, active = index == parts.lastIndex) { onPick(target) }
		}
	}
}

/**
 * A place of the file manager: "dir:<path>" walks through the PC's folders
 * and searches below the one it is in, "tag:<id>" and "collection:<id>" list
 * the files gathered there.
 */
@Composable
private fun LibraryPage(place: String) {
	val kind = place.substringBefore(':')
	val start = place.substringAfter(':', "")
	val folders = kind == "dir"
	val library = topic("library")
	val link = link
	val nav = LocalNav.current
	val home = library["home"].string
	var path by rememberSaveable { mutableStateOf(if (folders) start else "") }
	var query by rememberSaveable { mutableStateOf("") }
	// what is searched for; empty shows the folder
	var asked by rememberSaveable { mutableStateOf("") }
	var listing by remember { mutableStateOf<JsonElement?>(null) }
	var error by remember { mutableStateOf("") }
	var version by remember { mutableIntStateOf(0) }
	var chosen by remember { mutableStateOf<JsonElement?>(null) }
	// a tag or the favourite changed in the sheet: the list is read again
	var stale by remember { mutableStateOf(false) }
	LaunchedEffect(path, asked, version) {
		error = ""
		try {
			listing = when {
				kind == "tag" -> link.call("library", "tagged", json("id" to start))
				kind == "collection" -> link.call("library", "collection", json("id" to start))
				asked.isNotEmpty() -> link.call("library", "search", json("path" to path, "query" to asked), timeoutSeconds = 40)
				else -> link.call("library", "list", json("path" to path))
			}
		} catch (failure: LinkError) {
			error = link.describe(failure)
		}
	}
	val shown = listing["path"].string.ifEmpty { path }
	val go = { target: String ->
		if (target != path || asked.isNotEmpty()) listing = null
		path = target
		query = ""
		asked = ""
	}
	// back walks up to the folder the page was opened on, then leaves
	val below = folders && start.isNotEmpty() && path.startsWith(start.trimEnd('/') + "/")
	BackHandler(enabled = asked.isNotEmpty() || below) { go(if (asked.isNotEmpty()) path else parentOf(path)) }
	val title = when (kind) {
		"tag" -> library["tags"].list.firstOrNull { it["id"].string == start }["name"].string.ifEmpty { listing["name"].string.ifEmpty { "Tag" } }
		"collection" -> library["collections"].list.firstOrNull { it["id"].string == start }["name"].string.ifEmpty { listing["name"].string.ifEmpty { "Collection" } }
		else -> if (shown == "/") "/" else shown.trimEnd('/').substringAfterLast('/').ifEmpty { "File manager" }
	}
	val entries = listing["entries"].list.distinctBy { it["path"].string }
	Screen(title, scroll = false, actions = {
		if (folders) IconButton("arrow_up", color = Theme.colors.layer2, enabled = shown.isNotEmpty() && shown != "/") { go(parentOf(shown)) }
	}) {
		if (folders) {
			if (shown.isNotEmpty()) Crumbs(shown, home) { go(it) }
			Field(query, placeholder = "Search", icon = "magnify", action = ImeAction.Search, onSubmit = {
				if (query.trim() != asked) listing = null
				asked = query.trim()
			}, trailing = {
				if (query.isNotEmpty()) IconButton("close", size = 36.dp, iconSize = 18.dp) { go(path) }
			}) { query = it }
		}
		when {
			error.isNotEmpty() -> EmptyState("alert_circle_outline", if (asked.isNotEmpty()) "Could not search" else "Could not list the files", text = error, action = { SoftButton("Try again", icon = "refresh") { version += 1 } })
			listing == null -> EmptyState(if (asked.isNotEmpty()) "file_search_outline" else "folder_outline", if (asked.isNotEmpty()) "Searching…" else "Loading…")
			entries.isEmpty() -> when {
				asked.isNotEmpty() -> EmptyState("file_search_outline", "Nothing found")
				folders -> EmptyState("folder_open_outline", "Empty folder")
				else -> EmptyState("file_outline", "No files")
			}
			else -> LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = BottomSpace)) {
				items(entries, key = { it["path"].string }) { entry ->
					val dir = entry["dir"].bool
					FileRow(entry, said(entry, home, where = !folders || asked.isNotEmpty()), background = Theme.colors.layer2, onLongClick = { chosen = entry }) {
						when {
							!dir -> chosen = entry
							folders -> go(entry["path"].string)
							else -> nav.open("feature/library/${Uri.encode("dir:${entry["path"].string}")}")
						}
					}
				}
				if (listing["more"].bool) item {
					Label("Only the first ${entries.size} are shown", Modifier.padding(horizontal = 10.dp, vertical = 12.dp), style = Theme.Type.small, color = Theme.colors.textSubtle)
				}
			}
		}
	}
	chosen?.let { entry ->
		FileSheet(entry, library, onChanged = { stale = true }) {
			chosen = null
			if (stale) version += 1
			stale = false
		}
	}
}

/**
 * What can be done with a file from here: fetch it, open or show it on the
 * PC, tags; a folder can be a favourite. Nothing that loses a file.
 */
@Composable
private fun FileSheet(entry: JsonElement, library: JsonElement?, onChanged: () -> Unit = {}, onDismiss: () -> Unit) {
	val link = link
	val scope = rememberCoroutineScope()
	val path = entry["path"].string
	val dir = entry["dir"].bool
	val args = json("path" to path)
	var favorite by remember(path) { mutableStateOf(entry["favorite"].bool) }
	var tags by remember(path) { mutableStateOf(entry["tags"].list.map { it.string }) }
	Sheet(onDismiss, entry["name"].string) { close ->
		Label(pretty(path, library["home"].string), style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
		if (!dir) PrimaryButton("To the phone", Modifier.fillMaxWidth(), icon = "cellphone_arrow_down") {
			link.run("library", "send", args)
			link.toast("Fetching ${entry["name"].string}")
			close()
		}
		Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			SoftButton("Open on the PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "open_in_new") { link.run("library", "open", args); close() }
			SoftButton("Show on the PC", Modifier.weight(1f).padding(vertical = 4.dp), icon = "folder_outline") { link.run("library", "reveal", args); close() }
		}
		if (dir) SoftButton(if (favorite) "Remove from favorites" else "Add to favorites", Modifier.fillMaxWidth().padding(vertical = 4.dp), icon = if (favorite) "star" else "star_outline") {
			scope.launch {
				try {
					favorite = link.call("library", "favorite", args)["favorite"].bool
					onChanged()
				} catch (failure: LinkError) {
					link.toast(link.describe(failure))
				}
			}
		}
		val all = library["tags"].list
		if (all.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			for (tag in all) {
				val id = tag["id"].string
				val on = id in tags
				Chip(tag["name"].string, icon = if (on) "check" else "tag", active = on, tint = if (on) null else tagTint(Theme.colors, tag["color"].string)) {
					scope.launch {
						try {
							tags = link.call("library", "tag", json("path" to path, "id" to id))["tags"].list.map { it.string }
							onChanged()
						} catch (failure: LinkError) {
							link.toast(link.describe(failure))
						}
					}
				}
			}
		}
	}
}
