package dev.pshell.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import dev.pshell.app.features.Group
import dev.pshell.app.features.Feature
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.features.feature
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.bool
import dev.pshell.app.link.float
import dev.pshell.app.link.get
import dev.pshell.app.service.LinkService
import dev.pshell.app.ui.theme.PshellTheme
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.EmptyState
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Meter
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun Root(app: App, nav: Nav, activity: MainActivity) {
	val palette by app.palette.collectAsState()
	val state by app.link.state.collectAsState()
	PshellTheme(palette) {
		CompositionLocalProvider(LocalApp provides app, LocalNav provides nav) {
			Box(Modifier.fillMaxSize().background(Theme.colors.bg)) {
				// A pairing link (pshell://pair?…) may come from anywhere, a web page
				// included, so it never pairs by itself: the user sees which PC it
				// names and decides. (A code the user scanned needs no second question.)
				val pending = activity.pendingCode.value
				var message by remember { mutableStateOf("") }
				val scope = androidx.compose.runtime.rememberCoroutineScope()
				if (pending != null) {
					val uri = android.net.Uri.parse(pending)
					dev.pshell.app.ui.widgets.Confirm(
						"Pair with ${uri.getQueryParameter("n") ?: "this PC"}?",
						"A link asks this phone to pair with the PC at ${uri.getQueryParameter("a").orEmpty().replace(",", ", ")}. Afterwards that PC sees this phone's notifications and clipboard and can send it files. Only go on if you just started the pairing on your own PC.",
						confirm = "Pair",
						onDismiss = { activity.pendingCode.value = null },
					) {
						activity.pendingCode.value = null
						scope.launch {
							message = try {
								val pc = app.link.pair(pending)
								LinkService.start(app)
								nav.switchTo("home")
								"Paired with ${pc.name}"
							} catch (error: LinkError) {
								error.message ?: "Pairing failed"
							}
						}
					}
				}
				LaunchedEffect(Unit) { app.link.errors.collect { message = it } }
				LaunchedEffect(message) {
					if (message.isNotEmpty()) {
						delay(3200)
						message = ""
					}
				}

				if (state is LinkState.Unpaired && nav.current != "pairing") {
					Pairing(first = true)
				} else {
					BackHandler(enabled = nav.stack.size > 1) { nav.back() }
					val holder = rememberSaveableStateHolder()
					var depth by remember { mutableStateOf(nav.stack.size) }
					val forward = nav.stack.size >= depth
					val scrolling = remember {
						object : androidx.compose.ui.input.nestedscroll.NestedScrollConnection {
							override fun onPreScroll(available: androidx.compose.ui.geometry.Offset, source: androidx.compose.ui.input.nestedscroll.NestedScrollSource): androidx.compose.ui.geometry.Offset {
								if (available.y < -6f) Chrome.hidden = true else if (available.y > 6f) Chrome.hidden = false
								return androidx.compose.ui.geometry.Offset.Zero
							}
						}
					}
					LaunchedEffect(nav.current) {
						Chrome.hidden = false
						Chrome.expanded = false
					}
					AnimatedContent(
						targetState = nav.current,
						modifier = Modifier.nestedScroll(scrolling),
						transitionSpec = {
							depth = nav.stack.size
							val enter = tween<Float>(Theme.Motion.long, easing = Theme.Motion.decel)
							if (nav.stack.size == 1 && initialState.count { it == '/' } <= 1 && !targetState.startsWith("settings") && initialState in tabRoutes(app))
								(fadeIn(enter) + scaleIn(enter, initialScale = 0.97f)) togetherWith fadeOut(tween(Theme.Motion.short))
							else if (forward)
								(slideInHorizontally(tween(Theme.Motion.long, easing = Theme.Motion.decel)) { it / 5 } + fadeIn(enter)) togetherWith (fadeOut(tween(Theme.Motion.short)) + scaleOut(tween(Theme.Motion.medium), targetScale = 0.97f))
							else
								(fadeIn(enter) + scaleIn(enter, initialScale = 0.97f)) togetherWith (slideOutHorizontally(tween(Theme.Motion.medium, easing = Theme.Motion.accel)) { it / 5 } + fadeOut(tween(Theme.Motion.short)))
						},
						label = "route",
					) { route ->
						holder.SaveableStateProvider(route) { Route(route) }
					}
					AnimatedVisibility(
						nav.stack.size == 1 && !Chrome.hidden,
						Modifier.align(Alignment.BottomCenter),
						enter = slideInVertically(tween(Theme.Motion.long, easing = Theme.Motion.spatial)) { it } + fadeIn(),
						exit = slideOutVertically(tween(Theme.Motion.medium, easing = Theme.Motion.accel)) { it } + fadeOut(),
					) {
						TabBar()
					}
				}

				VolumeOsd(activity.volumeShown.value, Modifier.align(Alignment.TopCenter))
				AskSheet()
				activity.markedText.value?.let { text ->
					dev.pshell.app.features.TextActionSheet(text, onDismiss = { activity.markedText.value = null }) { nav.open("feature/chat") }
				}

				AnimatedVisibility(
					message.isNotEmpty(),
					Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 96.dp, start = 24.dp, end = 24.dp),
					enter = slideInVertically { it / 2 } + fadeIn(),
					exit = fadeOut(),
				) {
					Box(Modifier.shadow(12.dp, CircleShape).clip(CircleShape).background(Theme.colors.layer3).padding(horizontal = 20.dp, vertical = 12.dp)) {
						Label(message, style = Theme.Type.label, maxLines = 3)
					}
				}
			}
		}
	}
}

private fun tabRoutes(app: App): List<String> = listOf("home") + dev.pshell.app.features.Group.entries.filter { it.tab }.map { "hub/${it.id}" }

@Composable
private fun Route(route: String) {
	when {
		route == "home" -> Home()
		route == "settings" -> Settings()
		route == "pairing" -> Pairing(first = false)
		// a group's tab: its chips above the feature that is picked
		route.startsWith("hub/") -> Hub(route.removePrefix("hub/"))
		// terminal/run/<tile id> types a command of the grid, terminal/cmd/<base64> one as it is
		route.startsWith("terminal/") -> {
			if (!pluginOn("phone-terminal")) Screen("Terminal") { EmptyState("toggle_switch_off_outline", "Switched off", text = "The terminal is off on this PC. Switch it on in >plugins.") }
			else {
				val part = route.removePrefix("terminal/")
				if (part.startsWith("run/")) dev.pshell.app.features.TerminalScreen(part.removePrefix("run/"), null)
				else dev.pshell.app.features.TerminalScreen(null, String(android.util.Base64.decode(part.removePrefix("cmd/"), android.util.Base64.URL_SAFE)))
			}
		}
		route.startsWith("feature/") -> {
			val rest = route.removePrefix("feature/")
			val found = feature(rest.substringBefore('/'))
			val arg = rest.substringAfter('/', "")
			if (found == null) Screen("Unknown") { EmptyState("help_circle_outline", "Nothing here") }
			else if (!pluginOn(*found.plugins.toTypedArray())) Screen(found.title) {
				EmptyState("toggle_switch_off_outline", "Switched off", text = "${found.title} is off on this PC. Switch it on in >plugins.")
			}
			else if (arg.isNotEmpty() && found.page != null) found.page.invoke(android.net.Uri.decode(arg))
			else found.screen()
		}
	}
}

/**
 * The floating bar at the bottom: home and the features that are tabs, like
 * the shell's bar. On the touchpad it is a handle that opens on a tap, so
 * the surface reaches down to the edge.
 */
@Composable
private fun TabBar() {
	val nav = LocalNav.current
	val enabled = enabledFeatures()
	val tabs = enabled.filter { it.group.tab }
	if (tabs.isEmpty()) return
	val shown = Chrome.featureOf(nav.current) { group -> tabs.firstOrNull { it.group.id == group }?.id }
	val compact = shown in Chrome.compactFeatures && !Chrome.expanded
	LaunchedEffect(Chrome.expanded) {
		if (Chrome.expanded) {
			delay(3500)
			Chrome.expanded = false
		}
	}
	if (compact) {
		Box(
			Modifier.navigationBarsPadding().padding(bottom = 4.dp).width(120.dp).height(22.dp).pressable(shape = CircleShape, pressedScale = 0.9f) { Chrome.expanded = true },
			contentAlignment = Alignment.Center,
		) {
			Box(Modifier.width(44.dp).height(5.dp).clip(CircleShape).background(Theme.colors.textSubtle))
		}
		return
	}
	val groups = Group.entries.filter { group -> group.tab && tabs.any { it.group == group } }
	val entries = listOf(Triple("home", "home_variant", "Home")) + groups.map { Triple("hub/${it.id}", it.icon, it.title) }
	Row(
		Modifier
			.navigationBarsPadding()
			.padding(bottom = 14.dp)
			.shadow(18.dp, CircleShape, ambientColor = Theme.colors.scrim, spotColor = Theme.colors.scrim)
			.clip(CircleShape)
			.background(Theme.colors.layer2)
			.padding(6.dp),
		horizontalArrangement = Arrangement.spacedBy(4.dp),
	) {
		for ((route, icon, title) in entries) {
			val active = nav.current == route
			val background by animateColorAsState(if (active) Theme.colors.primary else Theme.colors.layer2, label = "tab")
			val tint = if (active) Theme.colors.onPrimary else Theme.colors.textMuted
			Row(
				Modifier
					.height(52.dp)
					.pressable(shape = CircleShape, pressedScale = 0.92f, haptic = true) { nav.switchTo(route) }
					.background(background)
					.padding(horizontal = if (active) 20.dp else 16.dp),
				verticalAlignment = Alignment.CenterVertically,
			) {
				Glyph(icon, size = 24.dp, color = tint)
				AnimatedVisibility(active) {
					Row {
						Spacer(Modifier.width(8.dp))
						Label(title, style = Theme.Type.label, color = tint)
					}
				}
			}
		}
	}
}

/** The first feature of a group that is switched on: what its tab opens with. */
@Composable
private fun firstEnabled(group: Group): Feature? = enabledFeatures().firstOrNull { it.group == group }

/**
 * A group's tab: a row of chips, one per feature of the group that is on,
 * above the feature picked. Features that draw their own surface (touchpad,
 * terminal) get the chips above them; the others draw them in their header.
 */
@Composable
private fun Hub(groupId: String) {
	val group = Group.entries.firstOrNull { it.id == groupId }
	val features = enabledFeatures().filter { it.group == group }
	if (group == null || features.isEmpty()) {
		Screen(group?.title ?: "Nothing here") { EmptyState("toggle_switch_off_outline", "Nothing switched on", text = "Every feature of this group is off on the PC. Switch them on in >plugins.") }
		return
	}
	val picked = features.firstOrNull { it.id == Chrome.hubSelection[groupId] } ?: features.first()
	val chips: @Composable () -> Unit = {
		val scroll = rememberScrollState()
		Row(Modifier.horizontalScroll(scroll).padding(end = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
			for (feature in features) {
				val active = feature.id == picked.id
				val background by animateColorAsState(if (active) Theme.colors.primary else Theme.colors.layer1, label = "hubChip")
				Row(
					Modifier.height(40.dp).pressable(shape = CircleShape, pressedScale = 0.94f, haptic = true) { Chrome.hubSelection[groupId] = feature.id }.background(background).padding(horizontal = if (active) 14.dp else 12.dp),
					verticalAlignment = Alignment.CenterVertically,
				) {
					Glyph(feature.icon, size = 18.dp, color = if (active) Theme.colors.onPrimary else Theme.colors.textMuted)
					if (active) {
						Spacer(Modifier.width(6.dp))
						Label(feature.title, style = Theme.Type.label, color = Theme.colors.onPrimary)
					}
				}
			}
		}
	}
	val holder = rememberSaveableStateHolder()
	if (picked.bare) Column(Modifier.fillMaxSize()) {
		Box(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 8.dp, top = 10.dp, bottom = 6.dp)) { chips() }
		Box(Modifier.weight(1f)) { holder.SaveableStateProvider("hub/${picked.id}") { picked.screen() } }
	} else CompositionLocalProvider(LocalHubChips provides chips) {
		holder.SaveableStateProvider("hub/${picked.id}") { picked.screen() }
	}
}

/** The PC's volume, shown for a moment after a volume key. */
@Composable
private fun VolumeOsd(raised: Long, modifier: Modifier) {
	var visible by remember { mutableStateOf(false) }
	LaunchedEffect(raised) {
		if (raised == 0L) return@LaunchedEffect
		visible = true
		delay(1400)
		visible = false
	}
	AnimatedVisibility(visible, modifier.statusBarsPadding().padding(top = 10.dp), enter = slideInVertically { -it } + fadeIn(), exit = slideOutVertically { -it } + fadeOut()) {
		val sound = topic("sound")
		val level = if (sound["muted"].bool) 0f else sound["volume"].float
		Row(
			Modifier.shadow(14.dp, CircleShape).clip(CircleShape).background(Theme.colors.layer2).padding(horizontal = 18.dp, vertical = 12.dp).widthIn(max = 260.dp).fillMaxWidth(),
			verticalAlignment = Alignment.CenterVertically,
		) {
			Glyph(if (level <= 0.001f) "volume_off" else "volume_high", size = 20.dp)
			Spacer(Modifier.width(12.dp))
			Meter(level, Modifier.weight(1f))
			Spacer(Modifier.width(12.dp))
			Label("${Math.round(level * 100)}", style = Theme.Type.label.copy(fontFeatureSettings = "tnum"))
		}
	}
}

/** A question of the PC (scripts/phone/ask), answered in the app: its fields and its buttons. */
@Composable
private fun AskSheet() {
	val open by dev.pshell.app.service.Asks.open.collectAsState()
	val ask = open.lastOrNull() ?: return
	val values = remember(ask.id) { androidx.compose.runtime.mutableStateMapOf<String, String>() }
	dev.pshell.app.ui.widgets.Sheet({ dev.pshell.app.service.Asks.dismiss(ask.id) }, ask.title.ifEmpty { "Question from the PC" }) { _ ->
		if (ask.body.isNotEmpty()) Label(ask.body, color = Theme.colors.textMuted, maxLines = 12)
		dev.pshell.app.features.FormFields(ask.fields, values)
		val actions = ask.actions.ifEmpty { listOf(dev.pshell.app.link.json("id" to "ok", "label" to "Send")) }
		Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			actions.forEachIndexed { index, action ->
				val id = action["id"].let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content ?: "" }
				val label = action["label"].let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content ?: id }
				if (index == 0) dev.pshell.app.ui.widgets.PrimaryButton(label, Modifier.weight(1f)) { dev.pshell.app.service.Asks.answer(ask.id, action = id, values = values.toMap()) }
				else dev.pshell.app.ui.widgets.SoftButton(label, Modifier.weight(1f).padding(vertical = 4.dp)) { dev.pshell.app.service.Asks.answer(ask.id, action = id, values = values.toMap()) }
			}
		}
	}
}
