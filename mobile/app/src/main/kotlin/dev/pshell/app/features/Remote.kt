package dev.pshell.app.features

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.Link
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.ui.connected
import dev.pshell.app.ui.link
import dev.pshell.app.ui.pluginOn
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.BottomSpace
import dev.pshell.app.ui.widgets.Chip
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.IconButton
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.pressable
import kotlinx.coroutines.launch
import okio.Buffer

val TouchpadFeature = Feature(
	id = "touchpad",
	title = "Touchpad",
	icon = "gesture_tap",
	plugins = listOf("phone-touchpad"),
	tab = 2,
	screen = { TouchpadScreen() },
)

val KeyboardFeature = Feature(
	id = "keyboard",
	title = "Keyboard",
	icon = "keyboard_outline",
	plugins = listOf("phone-keyboard"),
	screen = {
		Screen("Keyboard", subtitle = "Typed here, written on the PC") {
			KeyboardBar(alwaysOpen = true)
		}
	},
)

/** The geometry of the PC's virtual touchpad, as its "open" answers. */
private class Pad(val width: Int, val height: Int, val unitsPerMm: Int, val slots: Int)

/**
 * The phone's glass as a laptop touchpad. Nothing is interpreted here: every
 * finger goes to the PC as it is, and libinput makes pointer motion, taps,
 * scrolling and the compositor's swipes out of it.
 */
@Composable
private fun TouchpadScreen() {
	val link = link
	val connected = connected()
	val view = LocalView.current
	val metrics = LocalContext.current.resources.displayMetrics
	var pad by remember { mutableStateOf<Pad?>(null) }
	var error by remember { mutableStateOf("") }
	var size by remember { mutableStateOf(IntSize.Zero) }
	val fingers = remember { mutableStateMapOf<Int, Offset>() }
	var typing by remember { mutableStateOf(false) }

	// the virtual touchpad exists on the PC only while this screen is open
	LaunchedEffect(connected) {
		pad = null
		if (!connected) return@LaunchedEffect
		try {
			val answer = link.call("touchpad", "open")
			pad = Pad(answer["width"].int, answer["height"].int, answer["unitsPerMm"].int, answer["slots"].int)
			error = ""
		} catch (failure: LinkError) {
			error = link.describe(failure)
		}
	}
	DisposableEffect(Unit) {
		view.keepScreenOn = true
		onDispose {
			view.keepScreenOn = false
			link.run("touchpad", "close")
		}
	}

	Column(Modifier.fillMaxSize().padding(WindowInsets.statusBars.asPaddingValues()).imePadding().padding(start = 12.dp, end = 12.dp, top = 12.dp)) {
		val primary = Theme.colors.primary
		val dots = Theme.colors.textFaint
		Box(
			Modifier
				.weight(1f)
				.fillMaxWidth()
				.clip(RoundedCornerShape(36.dp))
				.background(Theme.colors.layer1)
				.onSizeChanged { size = it }
				.pointerInput(pad) {
					val geometry = pad ?: return@pointerInput
					val slots = HashMap<PointerId, Int>()
					// the phone's surface, in the PC's units, centred on the virtual pad
					val perPixelX = 25.4f / metrics.xdpi * geometry.unitsPerMm
					val perPixelY = 25.4f / metrics.ydpi * geometry.unitsPerMm
					awaitPointerEventScope {
						while (true) {
							val event = awaitPointerEvent()
							val offsetX = (geometry.width - this.size.width * perPixelX) / 2
							val offsetY = (geometry.height - this.size.height * perPixelY) / 2
							val frame = Buffer()
							var count = 0
							for (change in event.changes) {
								val known = slots[change.id]
								if (change.pressed) {
									val slot = known ?: (0 until geometry.slots).firstOrNull { it !in slots.values } ?: continue
									slots[change.id] = slot
									fingers[slot] = change.position
									frame.writeByte(slot).writeByte(1)
										.writeShort((change.position.x * perPixelX + offsetX).toInt().coerceIn(0, geometry.width))
										.writeShort((change.position.y * perPixelY + offsetY).toInt().coerceIn(0, geometry.height))
									count += 1
								} else if (known != null) {
									slots.remove(change.id)
									fingers.remove(known)
									frame.writeByte(known).writeByte(0).writeShort(0).writeShort(0)
									count += 1
								}
								change.consume()
							}
							if (count > 0) link.sendBytes(Buffer().writeByte(1).writeByte(count).apply { writeAll(frame) }.readByteString())
						}
					}
				},
		) {
			Canvas(Modifier.fillMaxSize()) {
				// a quiet dot grid, so the surface reads as one
				val step = 28.dp.toPx()
				var y = step
				while (y < this.size.height) {
					var x = step
					while (x < this.size.width) {
						drawCircle(dots, 1.2.dp.toPx(), Offset(x, y), alpha = 0.5f)
						x += step
					}
					y += step
				}
				for (finger in fingers.values) {
					drawCircle(Brush.radialGradient(listOf(primary.copy(alpha = 0.45f), primary.copy(alpha = 0f)), finger, 56.dp.toPx()), 56.dp.toPx(), finger)
					drawCircle(primary.copy(alpha = 0.8f), 5.dp.toPx(), finger)
				}
			}
			if (fingers.isEmpty()) {
				Column(Modifier.align(Alignment.Center).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
					Glyph(if (pad != null) "gesture_tap" else "lan_disconnect", size = 40.dp, color = Theme.colors.textFaint)
					Spacer(Modifier.height(12.dp))
					Label(
						when {
							error.isNotEmpty() -> error
							pad == null -> "Waiting for the PC"
							else -> "One finger moves, two scroll, three and four swipe"
						},
						style = Theme.Type.small, color = Theme.colors.textSubtle, maxLines = 3, align = TextAlign.Center,
					)
				}
			}
		}
		Spacer(Modifier.height(8.dp))
		Row(Modifier.fillMaxWidth().height(60.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
			SuperKey(Modifier.weight(1f), link)
			MouseButton(0, Modifier.weight(1.4f), link)
			MouseButton(2, Modifier.weight(0.7f), link)
			MouseButton(1, Modifier.weight(1.4f), link)
			if (pluginOn("phone-keyboard")) {
				Box(
					Modifier.width(60.dp).height(60.dp).pressable(shape = RoundedCornerShape(22.dp)) { typing = !typing }.background(if (typing) Theme.colors.primary else Theme.colors.layer2),
					contentAlignment = Alignment.Center,
				) {
					Glyph("keyboard_outline", size = 24.dp, color = if (typing) Theme.colors.onPrimary else Theme.colors.text)
				}
			}
		}
		AnimatedVisibility(typing && pluginOn("phone-keyboard")) {
			Column {
				Spacer(Modifier.height(8.dp))
				KeyboardBar(alwaysOpen = false)
			}
		}
		// below it only the tab bar's handle, or the whole bar while it is opened
		val keyboardUp = WindowInsets.ime.getBottom(LocalDensity.current) > 0
		Spacer(Modifier.height(if (keyboardUp) 8.dp else if (dev.pshell.app.ui.Chrome.expanded) BottomSpace - 6.dp else 30.dp))
	}
}

/** Tells the PC to hold a modifier down or let it go: 0 Super, 1 Ctrl, 2 Alt, 3 Shift. */
fun holdModifier(link: Link, index: Int, down: Boolean) {
	link.sendBytes(Buffer().writeByte(3).writeByte(index).writeByte(if (down) 1 else 0).readByteString())
}

/**
 * Super, next to the mouse buttons: down for as long as a finger rests on
 * it, so another finger can drag a window (Mod+drag in niri) or swipe. A
 * short tap latches it until the next tap.
 */
@Composable
private fun SuperKey(modifier: Modifier, link: Link) {
	var held by remember { mutableStateOf(false) }
	var latched by remember { mutableStateOf(false) }
	val feedback = LocalHapticFeedback.current
	DisposableEffect(Unit) { onDispose { holdModifier(link, 0, false) } }
	Box(
		modifier
			.height(60.dp)
			.clip(RoundedCornerShape(22.dp))
			.background(if (latched) Theme.colors.primary else if (held) Theme.colors.primaryContainer else Theme.colors.layer2)
			.pointerInput(Unit) {
				awaitEachGesture {
					val started = System.currentTimeMillis()
					awaitFirstDown().consume()
					held = true
					feedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
					if (!latched) holdModifier(link, 0, true)
					waitForUpOrCancellation()
					held = false
					val short = System.currentTimeMillis() - started < 220
					latched = short && !latched
					if (!latched) holdModifier(link, 0, false)
				}
			},
		contentAlignment = Alignment.Center,
	) {
		Label("Super", style = Theme.Type.label, color = if (latched) Theme.colors.onPrimary else Theme.colors.text)
	}
}

/** A mouse button below the pad: held as long as the finger is on it. */
@Composable
private fun MouseButton(index: Int, modifier: Modifier, link: Link) {
	var held by remember { mutableStateOf(false) }
	val feedback = LocalHapticFeedback.current
	Box(
		modifier
			.height(60.dp)
			.clip(RoundedCornerShape(22.dp))
			.background(if (held) Theme.colors.primaryContainer else Theme.colors.layer2)
			.pointerInput(index) {
				awaitEachGesture {
					awaitFirstDown().consume()
					held = true
					feedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
					link.sendBytes(Buffer().writeByte(2).writeByte(index).writeByte(1).readByteString())
					waitForUpOrCancellation()
					held = false
					link.sendBytes(Buffer().writeByte(2).writeByte(index).writeByte(0).readByteString())
				}
			},
		contentAlignment = Alignment.Center,
	) {
		Label(listOf("L", "R", "M")[index], style = Theme.Type.tiny, color = Theme.colors.textFaint)
	}
}

private val specialKeys = listOf(
	"Esc" to "Escape", "Tab" to "Tab", "⌫" to "BackSpace", "Del" to "Delete", "←" to "Left", "↓" to "Down", "↑" to "Up", "→" to "Right",
	"Home" to "Home", "End" to "End", "PgUp" to "Prior", "PgDn" to "Next", "⏎" to "Return",
) + (1..12).map { "F$it" to "F$it" }

private val modifierKeys = listOf("Ctrl" to "ctrl", "Alt" to "alt", "Shift" to "shift", "Super" to "logo")

/**
 * Typing on the PC with the phone's keyboard: every change of the field is
 * sent as it happens (what autocorrect takes back is taken back there too).
 * Modifiers stick for the next key.
 */
@Composable
fun KeyboardBar(alwaysOpen: Boolean) {
	val link = link
	var field by remember { mutableStateOf(TextFieldValue("")) }
	var modifiers by remember { mutableStateOf(setOf<String>()) }
	val focus = remember { FocusRequester() }
	val keyboard = LocalSoftwareKeyboardController.current

	val indexOf = mapOf("logo" to 0, "ctrl" to 1, "alt" to 2, "shift" to 3)

	// a modifier is really down on the PC from the tap on its chip until the
	// next key (or a second tap): Super then also works with the mouse
	fun release() {
		for (name in modifiers) indexOf[name]?.let { holdModifier(link, it, false) }
		modifiers = emptySet()
	}

	fun key(name: String) {
		link.run("keyboard", "key", json("key" to name, "mods" to emptyList<String>()))
		if (modifiers.isNotEmpty()) link.scope.launch {
			kotlinx.coroutines.delay(120)
			release()
		}
	}

	DisposableEffect(Unit) { onDispose { for (index in indexOf.values) holdModifier(link, index, false) } }

	fun typed(next: TextFieldValue) {
		val before = field.text
		val after = next.text
		val common = before.commonPrefixWith(after).length
		repeat(before.length - common) { link.run("keyboard", "key", json("key" to "BackSpace", "mods" to emptyList<String>())) }
		val added = after.substring(common)
		if (added.isNotEmpty()) {
			if (modifiers.isNotEmpty() && added.length == 1) key(added) else link.run("keyboard", "text", json("text" to added))
		}
		// the field only has to remember enough for the keyboard to correct a word
		field = if (after.length > 200) TextFieldValue(after.takeLast(40), TextRange(40)) else next
	}

	LaunchedEffect(Unit) {
		focus.requestFocus()
		keyboard?.show()
	}

	Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
		Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
			for ((label, name) in modifierKeys) Chip(label, active = name in modifiers) {
				val down = name !in modifiers
				indexOf[name]?.let { holdModifier(link, it, down) }
				modifiers = if (down) modifiers + name else modifiers - name
			}
			for ((label, name) in specialKeys) Chip(label) { key(name) }
		}
		Row(Modifier.fillMaxWidth().clip(CircleShape).background(Theme.colors.layer1).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
			Glyph("keyboard_outline", size = 20.dp, color = Theme.colors.textSubtle)
			Spacer(Modifier.width(10.dp))
			Box(Modifier.weight(1f).height(52.dp), contentAlignment = Alignment.CenterStart) {
				if (field.text.isEmpty()) Label("Type here", color = Theme.colors.textSubtle)
				BasicTextField(
					value = field,
					onValueChange = ::typed,
					modifier = Modifier.fillMaxWidth().focusRequester(focus),
					singleLine = true,
					textStyle = Theme.Type.body.copy(color = Theme.colors.text),
					cursorBrush = SolidColor(Theme.colors.primary),
					keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Send),
					keyboardActions = KeyboardActions(onAny = {
						key("Return")
						field = TextFieldValue("")
					}),
				)
			}
			if (field.text.isNotEmpty()) IconButton("close", size = 36.dp, iconSize = 18.dp) { field = TextFieldValue("") }
		}
	}
}
