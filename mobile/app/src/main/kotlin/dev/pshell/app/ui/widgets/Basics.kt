package dev.pshell.app.ui.widgets

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Theme
import kotlinx.coroutines.launch

/** Text in the shell's type. */
@Composable
fun Label(
	text: String,
	modifier: Modifier = Modifier,
	style: TextStyle = Theme.Type.body,
	color: Color = Theme.colors.text,
	maxLines: Int = 1,
	align: TextAlign? = null,
) {
	BasicText(
		text = text,
		modifier = modifier,
		style = style.copy(color = color, textAlign = align ?: TextAlign.Unspecified),
		maxLines = maxLines,
		overflow = TextOverflow.Ellipsis,
	)
}

/** An icon of the shell, by its name in style/theme/Icons.qml. */
@Composable
fun Glyph(icon: String, modifier: Modifier = Modifier, size: Dp = 22.dp, color: Color = Theme.colors.text) {
	val fontSize = with(LocalDensity.current) { size.toSp() }
	Box(modifier.size(size), contentAlignment = Alignment.Center) {
		BasicText(
			text = Icons[icon],
			style = TextStyle(fontFamily = Theme.symbols, fontSize = fontSize, color = color, lineHeight = fontSize, textAlign = TextAlign.Center),
			maxLines = 1,
			softWrap = false,
		)
	}
}

/** UPPERCASE CAPTION above a group, like the shell's SectionLabel. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
	Label(
		text.uppercase(),
		modifier.padding(start = 6.dp, top = 6.dp, bottom = 2.dp),
		style = Theme.Type.tiny.copy(letterSpacing = 1.1.sp),
		color = Theme.colors.textSubtle,
	)
}

/**
 * Makes anything pressable the way the shell's Clickable is: it shrinks a
 * little under the finger and springs back, with a tint while pressed.
 */
@Composable
fun Modifier.pressable(
	enabled: Boolean = true,
	shape: Shape = RoundedCornerShape(Theme.Radius.large),
	pressedScale: Float = 0.97f,
	haptic: Boolean = false,
	onLongClick: (() -> Unit)? = null,
	onClick: () -> Unit,
): Modifier {
	val scale = remember { Animatable(1f) }
	val layer = remember { Animatable(0f) }
	val scope = rememberCoroutineScope()
	val click by rememberUpdatedState(onClick)
	val longClick by rememberUpdatedState(onLongClick)
	val feedback = LocalHapticFeedback.current
	val tint = Theme.colors.fg
	return this
		.graphicsLayer {
			scaleX = scale.value
			scaleY = scale.value
		}
		.clip(shape)
		.drawWithContent {
			drawContent()
			if (layer.value > 0f) drawRect(tint.copy(alpha = 0.09f * layer.value))
		}
		.semantics {
			role = Role.Button
			onClick { click(); true }
		}
		.pointerInput(enabled, onLongClick != null) {
			if (!enabled) return@pointerInput
			awaitEachGesture {
				val down = awaitFirstDown()
				scope.launch { scale.animateTo(pressedScale, tween(Theme.Motion.micro, easing = Theme.Motion.standard)) }
				scope.launch { layer.animateTo(1f, tween(Theme.Motion.micro)) }
				var long = false
				val up = if (longClick != null) {
					val quick = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) { waitForUpOrCancellation() }
					if (quick == null && currentEvent.changes.any { it.pressed }) {
						long = true
						feedback.performHapticFeedback(HapticFeedbackType.LongPress)
						longClick?.invoke()
						waitForUpOrCancellation()
					} else quick
				} else waitForUpOrCancellation()
				scope.launch { scale.animateTo(1f, spring(dampingRatio = 0.45f, stiffness = 420f)) }
				scope.launch { layer.animateTo(0f, tween(Theme.Motion.medium)) }
				if (up != null && !long) {
					down.consume()
					up.consume()
					if (haptic) feedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
					click()
				}
			}
		}
}

/** A surface one step above the background; the shell's cards have no border. */
@Composable
fun Panel(
	modifier: Modifier = Modifier.fillMaxWidth(),
	color: Color = if (LocalRaised.current) Theme.colors.layer2 else Theme.colors.layer1,
	radius: Dp = Theme.Radius.card,
	padding: PaddingValues = PaddingValues(16.dp),
	onClick: (() -> Unit)? = null,
	content: @Composable ColumnScope.() -> Unit,
) {
	val shape = RoundedCornerShape(radius)
	Column(
		modifier
			.then(if (onClick != null) Modifier.pressable(shape = shape, pressedScale = 0.985f, onClick = onClick) else Modifier.clip(shape))
			.background(color)
			.padding(padding),
		content = content,
	)
}

/** A round button with one icon. */
@Composable
fun IconButton(
	icon: String,
	modifier: Modifier = Modifier,
	size: Dp = 44.dp,
	iconSize: Dp = 22.dp,
	color: Color = Color.Transparent,
	tint: Color = Theme.colors.text,
	enabled: Boolean = true,
	onLongClick: (() -> Unit)? = null,
	onClick: () -> Unit,
) {
	Box(
		modifier
			.size(size)
			.graphicsLayer { alpha = if (enabled) 1f else 0.35f }
			.pressable(enabled = enabled, shape = CircleShape, pressedScale = 0.88f, onLongClick = onLongClick, onClick = onClick)
			.background(color),
		contentAlignment = Alignment.Center,
	) {
		Glyph(icon, size = iconSize, color = tint)
	}
}

/** The one filled button of a screen. */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, icon: String? = null, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) {
	val background = if (danger) Theme.colors.danger else Theme.colors.primary
	val foreground = if (danger) Theme.colors.bg else Theme.colors.onPrimary
	Row(
		modifier
			.graphicsLayer { alpha = if (enabled) 1f else 0.4f }
			.heightIn(min = 52.dp)
			.pressable(enabled = enabled, shape = CircleShape, haptic = true, onClick = onClick)
			.background(background)
			.padding(horizontal = 22.dp),
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.Center,
	) {
		if (icon != null) {
			Glyph(icon, size = 20.dp, color = foreground)
			Spacer(Modifier.width(8.dp))
		}
		Label(text, style = Theme.Type.label.copy(fontSize = 15.sp), color = foreground)
	}
}

/** A quiet button: a tinted pill. */
@Composable
fun SoftButton(text: String, modifier: Modifier = Modifier, icon: String? = null, tint: Color = Theme.colors.text, onClick: () -> Unit) {
	Row(
		modifier
			.heightIn(min = 44.dp)
			.pressable(shape = CircleShape, onClick = onClick)
			.background(Theme.colors.layer2)
			.padding(horizontal = 18.dp),
		verticalAlignment = Alignment.CenterVertically,
		horizontalArrangement = Arrangement.Center,
	) {
		if (icon != null) {
			Glyph(icon, size = 18.dp, color = tint)
			Spacer(Modifier.width(8.dp))
		}
		Label(text, style = Theme.Type.label, color = tint)
	}
}

/** A small pill that states something or filters. */
@Composable
fun Chip(text: String, modifier: Modifier = Modifier, icon: String? = null, active: Boolean = false, tint: Color? = null, onClick: (() -> Unit)? = null) {
	val background by animateColorAsState(if (active) Theme.colors.primary else Theme.colors.layer2, label = "chip")
	val foreground = tint ?: if (active) Theme.colors.onPrimary else Theme.colors.textMuted
	Row(
		modifier
			.height(32.dp)
			.then(if (onClick != null) Modifier.pressable(shape = CircleShape, pressedScale = 0.94f, onClick = onClick) else Modifier.clip(CircleShape))
			.background(background)
			.padding(horizontal = 12.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		if (icon != null) {
			Glyph(icon, size = 15.dp, color = foreground)
			Spacer(Modifier.width(6.dp))
		}
		Label(text, style = Theme.Type.small.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), color = foreground)
	}
}

/** The shell's switch: a pill whose knob stretches while it travels. */
@Composable
fun Toggle(checked: Boolean, modifier: Modifier = Modifier, onChange: (Boolean) -> Unit) {
	val position by animateFloatAsState(if (checked) 1f else 0f, spring(dampingRatio = 0.6f, stiffness = 500f), label = "toggle")
	val track by animateColorAsState(if (checked) Theme.colors.primary else Theme.colors.layer3, label = "track")
	val knob = if (checked) Theme.colors.onPrimary else Theme.colors.textMuted
	Box(
		modifier
			.size(52.dp, 30.dp)
			.pressable(shape = CircleShape, pressedScale = 0.94f, haptic = true) { onChange(!checked) }
			.background(track),
	) {
		Box(
			Modifier
				.padding(4.dp)
				.graphicsLayer { translationX = position * 22.dp.toPx() }
				.size(22.dp)
				.clip(CircleShape)
				.background(knob),
		)
	}
}

/** One line of a list: icon, title, subtitle, something at the end. */
@Composable
fun ListRow(
	title: String,
	modifier: Modifier = Modifier,
	icon: String? = null,
	subtitle: String = "",
	iconTint: Color = Theme.colors.text,
	iconBackground: Color = Theme.colors.layer3,
	onClick: (() -> Unit)? = null,
	onLongClick: (() -> Unit)? = null,
	trailing: @Composable RowScope.() -> Unit = {},
) {
	val shape = RoundedCornerShape(Theme.Radius.huge)
	Row(
		modifier
			.fillMaxWidth()
			.heightIn(min = 60.dp)
			.then(if (onClick != null) Modifier.pressable(shape = shape, pressedScale = 0.985f, onLongClick = onLongClick, onClick = onClick) else Modifier.clip(shape))
			.padding(horizontal = 10.dp, vertical = 8.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		if (icon != null) {
			Box(Modifier.size(40.dp).clip(CircleShape).background(iconBackground), contentAlignment = Alignment.Center) {
				Glyph(icon, size = 20.dp, color = iconTint)
			}
			Spacer(Modifier.width(12.dp))
		}
		Column(Modifier.weight(1f)) {
			Label(title, style = Theme.Type.body.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold))
			if (subtitle.isNotEmpty()) Label(subtitle, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 2)
		}
		trailing()
	}
}

/** What a screen shows when it has nothing to show. */
@Composable
fun EmptyState(icon: String, title: String, modifier: Modifier = Modifier, text: String = "", action: @Composable () -> Unit = {}) {
	Column(modifier.fillMaxWidth().padding(vertical = 40.dp, horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
		Box(Modifier.size(72.dp).clip(CircleShape).background(Theme.colors.layer1), contentAlignment = Alignment.Center) {
			Glyph(icon, size = 32.dp, color = Theme.colors.textSubtle)
		}
		Spacer(Modifier.height(16.dp))
		Label(title, style = Theme.Type.title, align = TextAlign.Center)
		if (text.isNotEmpty()) {
			Spacer(Modifier.height(4.dp))
			Label(text, style = Theme.Type.small, color = Theme.colors.textMuted, maxLines = 4, align = TextAlign.Center)
		}
		Spacer(Modifier.height(16.dp))
		action()
	}
}

/** Picks one of a few: the shell's Segmented. */
@Composable
fun <T> Segmented(options: List<Pair<T, String>>, selected: T, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
	Row(modifier.clip(CircleShape).background(Theme.colors.layer1).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
		for ((value, label) in options) {
			val active = value == selected
			val background by animateColorAsState(if (active) Theme.colors.primary else Color.Transparent, label = "segment")
			Box(
				Modifier
					.weight(1f)
					.height(38.dp)
					.pressable(shape = CircleShape, pressedScale = 0.95f) { onSelect(value) }
					.background(background),
				contentAlignment = Alignment.Center,
			) {
				Label(label, style = Theme.Type.label, color = if (active) Theme.colors.onPrimary else Theme.colors.textMuted)
			}
		}
	}
}

@Composable
fun animatedRadius(active: Boolean, inactive: Dp, activeRadius: Dp): Dp =
	animateDpAsState(if (active) activeRadius else inactive, tween(Theme.Motion.medium, easing = Theme.Motion.spatial), label = "radius").value

@Composable
fun BoxScope.Centered(content: @Composable () -> Unit) = Box(Modifier.align(Alignment.Center)) { content() }
