package dev.pshell.app.ui.theme

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.R

private val LocalPalette = staticCompositionLocalOf { Palette.Default }

/** Colours, type, metrics and motion of the shell, on a phone. */
object Theme {
	val colors: Palette
		@Composable @ReadOnlyComposable get() = LocalPalette.current

	private fun sans(weight: Int) = Font(R.font.adwaita_sans, FontWeight(weight), variationSettings = FontVariation.Settings(FontVariation.weight(weight)))

	val sans = FontFamily(sans(400), sans(500), sans(600), sans(700), sans(800))
	val mono = FontFamily(Font(R.font.adwaita_mono))
	val symbols = FontFamily(Font(R.font.symbols))

	// the shell's sizes are for a desktop at arm's length; a phone is read closer
	object Type {
		val tiny = style(11, 600)
		val small = style(12, 500)
		val label = style(13, 600)
		val body = style(15, 500)
		val title = style(17, 600)
		val heading = style(21, 700)
		val display = style(32, 700)
		val hero = style(52, 700)

		private fun style(size: Int, weight: Int) = TextStyle(fontFamily = sans, fontSize = size.sp, fontWeight = FontWeight(weight), letterSpacing = if (size >= 20) (-0.3).sp else 0.sp)
	}

	object Radius {
		val small = 8.dp
		val medium = 12.dp
		val large = 16.dp
		val huge = 22.dp
		val card = 26.dp
	}

	object Gap {
		val xs = 4.dp
		val sm = 8.dp
		val md = 12.dp
		val lg = 16.dp
		val xl = 24.dp
	}

	/** The shell's motion language (style/theme/Motion.qml). */
	object Motion {
		val spatial = CubicBezierEasing(0.38f, 1.21f, 0.22f, 1.0f)
		val spatialFast = CubicBezierEasing(0.42f, 1.67f, 0.21f, 0.9f)
		val decel = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1.0f)
		val accel = CubicBezierEasing(0.3f, 0.0f, 0.8f, 0.15f)
		val standard = CubicBezierEasing(0.2f, 0.0f, 0.0f, 1.0f)
		const val micro = 100
		const val short = 160
		const val medium = 250
		const val long = 360
		const val extraLong = 500
	}
}

/** Provides the palette; a new one (a new wallpaper on the PC) fades in. */
@Composable
fun PshellTheme(target: Palette, content: @Composable () -> Unit) {
	var shown by remember { mutableStateOf(target) }
	var from by remember { mutableStateOf(target) }
	val progress = remember { Animatable(1f) }
	LaunchedEffect(target) {
		if (target == shown) return@LaunchedEffect
		from = shown
		progress.snapTo(0f)
		progress.animateTo(1f, tween(Theme.Motion.extraLong, easing = Theme.Motion.standard)) { shown = from.mix(target, value) }
		shown = target
	}
	val palette = shown
	val scheme = (if (palette.dark) darkColorScheme() else lightColorScheme()).copy(
		primary = palette.primary, onPrimary = palette.onPrimary, primaryContainer = palette.primaryContainer, onPrimaryContainer = palette.text,
		secondary = palette.secondary, tertiary = palette.tertiary, background = palette.bg, onBackground = palette.text,
		surface = palette.bg, onSurface = palette.text, surfaceVariant = palette.layer2, onSurfaceVariant = palette.textMuted,
		surfaceContainer = palette.layer1, surfaceContainerHigh = palette.layer2, surfaceContainerHighest = palette.layer3,
		surfaceContainerLow = palette.layer1, error = palette.danger, outline = palette.textSubtle, outlineVariant = palette.outline,
		scrim = palette.scrim,
	)
	MaterialTheme(colorScheme = scheme) {
		CompositionLocalProvider(
			LocalPalette provides palette,
			LocalTextSelectionColors provides TextSelectionColors(palette.primary, palette.primary.copy(alpha = 0.3f)),
			content = content,
		)
	}
}
