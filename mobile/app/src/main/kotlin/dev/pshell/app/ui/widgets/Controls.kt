package dev.pshell.app.ui.widgets

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.pshell.app.ui.theme.Theme

/**
 * The shell's quick settings tile: a pill that fills with the accent and
 * squares its corners while it is active.
 */
@Composable
fun Tile(
	icon: String,
	title: String,
	modifier: Modifier = Modifier,
	subtitle: String = "",
	active: Boolean = false,
	enabled: Boolean = true,
	onLongClick: (() -> Unit)? = null,
	onClick: () -> Unit,
) {
	val radius = animatedRadius(active, 34.dp, Theme.Radius.large)
	val background by animateColorAsState(if (active) Theme.colors.primaryContainer else Theme.colors.layer1, label = "tile")
	val circle by animateColorAsState(if (active) Theme.colors.primary else Theme.colors.layer3, label = "tileIcon")
	Row(
		modifier
			.height(68.dp)
			.pressable(enabled = enabled, shape = RoundedCornerShape(radius), pressedScale = 0.96f, haptic = true, onLongClick = onLongClick, onClick = onClick)
			.background(background)
			.padding(start = 12.dp, end = 14.dp),
		verticalAlignment = Alignment.CenterVertically,
	) {
		Box(Modifier.size(44.dp).clip(CircleShape).background(circle), contentAlignment = Alignment.Center) {
			Glyph(icon, size = 22.dp, color = if (active) Theme.colors.onPrimary else Theme.colors.text)
		}
		Spacer(Modifier.width(10.dp))
		Column(Modifier.weight(1f)) {
			Label(title, style = Theme.Type.body.copy(fontWeight = FontWeight.SemiBold))
			if (subtitle.isNotEmpty()) Label(subtitle, style = Theme.Type.small, color = Theme.colors.textMuted)
		}
	}
}

/**
 * The shell's PillSlider: the whole pill is the slider, filled up to the
 * value, with a thin handle at its end. Drag anywhere, or tap.
 */
@Composable
fun PillSlider(
	value: Float,
	modifier: Modifier = Modifier,
	icon: String? = null,
	label: String? = null,
	height: Dp = 52.dp,
	color: Color = Theme.colors.primary,
	onChangeFinished: (Float) -> Unit = {},
	onChange: (Float) -> Unit,
) {
	var width by remember { mutableFloatStateOf(1f) }
	var dragging by remember { mutableStateOf(false) }
	var local by remember { mutableFloatStateOf(value) }
	val shown by animateFloatAsState(if (dragging) local else value, if (dragging) tween(0) else spring(dampingRatio = 0.8f, stiffness = 300f), label = "slider")
	val change by rememberUpdatedState(onChange)
	val finished by rememberUpdatedState(onChangeFinished)
	val current by rememberUpdatedState(value)
	val feedback = LocalHapticFeedback.current
	val foreground = Theme.colors.onPrimary
	val muted = Theme.colors.textMuted
	Box(
		modifier
			.fillMaxWidth()
			.height(height)
			.clip(CircleShape)
			.background(Theme.colors.layer1)
			.onSizeChanged { width = it.width.toFloat().coerceAtLeast(1f) }
			.pointerInput(Unit) {
				detectTapGestures { offset ->
					val next = (offset.x / width).coerceIn(0f, 1f)
					change(next)
					finished(next)
				}
			}
			.pointerInput(Unit) {
				detectHorizontalDragGestures(
					onDragStart = {
						local = current
						dragging = true
					},
					onDragEnd = {
						dragging = false
						finished(local)
					},
					onDragCancel = { dragging = false },
				) { input, amount ->
					input.consume()
					val before = local
					local = (local + amount / width).coerceIn(0f, 1f)
					if ((before > 0f && local == 0f) || (before < 1f && local == 1f)) feedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
					change(local)
				}
			},
	) {
		val fraction = shown.coerceIn(0f, 1f)
		Canvas(Modifier.fillMaxSize()) {
			val fill = (size.width * fraction).coerceAtLeast(size.height * 0.5f)
			drawRoundRect(color, size = Size(fill, size.height), cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2))
			// the handle: a short bar just inside the fill
			val handleX = (fill - 14.dp.toPx()).coerceAtLeast(size.height * 0.5f - 8.dp.toPx())
			if (fraction > 0.06f) drawLine(foreground.copy(alpha = 0.75f), Offset(handleX, size.height * 0.3f), Offset(handleX, size.height * 0.7f), strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round)
		}
		Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
			if (icon != null) Glyph(icon, size = 20.dp, color = if (fraction > 0.12f) foreground else muted)
			Spacer(Modifier.weight(1f))
			if (label != null) Label(label, style = Theme.Type.label, color = if (fraction > 0.9f) foreground else muted)
		}
	}
}

/** A ring that fills clockwise from the top, with anything in its middle. */
@Composable
fun Ring(
	value: Float,
	modifier: Modifier = Modifier,
	size: Dp = 56.dp,
	thickness: Dp = 6.dp,
	color: Color = Theme.colors.primary,
	content: @Composable () -> Unit = {},
) {
	val shown by animateFloatAsState(value.coerceIn(0f, 1f), spring(dampingRatio = 0.9f, stiffness = 120f), label = "ring")
	val track = Theme.colors.layer3
	Box(modifier.size(size), contentAlignment = Alignment.Center) {
		Canvas(Modifier.fillMaxSize()) {
			val stroke = thickness.toPx()
			val inset = stroke / 2
			val arc = Size(this.size.width - stroke, this.size.height - stroke)
			drawArc(track, 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(stroke))
			if (shown > 0.001f) drawArc(color, -90f, 360f * shown, false, Offset(inset, inset), arc, style = Stroke(stroke, cap = StrokeCap.Round))
		}
		content()
	}
}

/** A history as a smooth line with a soft fill below, newest value right. */
@Composable
fun Sparkline(values: List<Float>, modifier: Modifier = Modifier, color: Color = Theme.colors.primary, maximum: Float = 1f) {
	Canvas(modifier) {
		if (values.size < 2) return@Canvas
		val step = size.width / (values.size - 1)
		val top = 3.dp.toPx()
		fun y(value: Float) = top + (size.height - top) * (1f - (value / maximum).coerceIn(0f, 1f))
		val line = Path().apply {
			moveTo(0f, y(values[0]))
			for (index in 1 until values.size) {
				val x0 = (index - 1) * step
				val x1 = index * step
				cubicTo(x0 + step / 2, y(values[index - 1]), x1 - step / 2, y(values[index]), x1, y(values[index]))
			}
		}
		val area = Path().apply {
			addPath(line)
			lineTo(size.width, size.height)
			lineTo(0f, size.height)
			close()
		}
		drawPath(area, Brush.verticalGradient(listOf(color.copy(alpha = 0.28f), color.copy(alpha = 0f))))
		drawPath(line, color, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
		drawCircle(color, 3.5.dp.toPx(), Offset(size.width - 3.5.dp.toPx(), y(values.last())))
	}
}

/** A thin bar for how full something is. */
@Composable
fun Meter(value: Float, modifier: Modifier = Modifier, color: Color = Theme.colors.primary, height: Dp = 6.dp) {
	val shown by animateFloatAsState(value.coerceIn(0f, 1f), spring(dampingRatio = 0.9f, stiffness = 120f), label = "meter")
	Box(modifier.fillMaxWidth().height(height).clip(CircleShape).background(Theme.colors.layer3)) {
		Box(Modifier.fillMaxHeight().fillMaxWidth(shown).clip(CircleShape).background(color))
	}
}

/** True inside a sheet: its surface is already one step up, so what lies on it goes one further. */
val LocalRaised = androidx.compose.runtime.compositionLocalOf { false }

/** A text field as a pill, with an icon in front. */
@Composable
fun Field(
	value: String,
	modifier: Modifier = Modifier,
	placeholder: String = "",
	icon: String? = null,
	singleLine: Boolean = true,
	keyboard: KeyboardType = KeyboardType.Text,
	action: ImeAction = ImeAction.Done,
	onSubmit: (() -> Unit)? = null,
	trailing: @Composable () -> Unit = {},
	onChange: (String) -> Unit,
) {
	Row(
		modifier
			.fillMaxWidth()
			.clip(RoundedCornerShape(if (singleLine) 26.dp else Theme.Radius.huge))
			.background(if (LocalRaised.current) Theme.colors.layer3 else Theme.colors.layer1)
			.padding(horizontal = 16.dp, vertical = if (singleLine) 0.dp else 12.dp),
		verticalAlignment = if (singleLine) Alignment.CenterVertically else Alignment.Top,
	) {
		if (icon != null) {
			Glyph(icon, size = 20.dp, color = Theme.colors.textSubtle)
			Spacer(Modifier.width(10.dp))
		}
		Box(Modifier.weight(1f).then(if (singleLine) Modifier.height(52.dp) else Modifier), contentAlignment = Alignment.CenterStart) {
			if (value.isEmpty()) Label(placeholder, color = Theme.colors.textSubtle)
			BasicTextField(
				value = value,
				onValueChange = onChange,
				modifier = Modifier.fillMaxWidth(),
				singleLine = singleLine,
				textStyle = Theme.Type.body.copy(color = Theme.colors.text),
				cursorBrush = SolidColor(Theme.colors.primary),
				keyboardOptions = KeyboardOptions(keyboardType = keyboard, imeAction = action),
				keyboardActions = KeyboardActions(onAny = { onSubmit?.invoke() }),
			)
		}
		trailing()
	}
}
