package dev.pshell.app.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The shell's colours (style/theme/Theme.qml), derived the same way: instead
 * of hard-wiring one palette entry as the accent, the most vivid one that
 * still reads on the background is chosen; elevation is a tint of the
 * foreground over the background, never a border.
 */
data class Palette(
	val bg: Color,
	val fg: Color,
	val primary: Color,
	val secondary: Color,
	val tertiary: Color,
	val onPrimary: Color,
	val danger: Color,
	val warning: Color,
	val success: Color,
	val dark: Boolean,
) {
	val layer1 = fg.copy(alpha = 0.045f).compositeOver(bg)
	val layer2 = fg.copy(alpha = 0.085f).compositeOver(bg)
	val layer3 = fg.copy(alpha = 0.13f).compositeOver(bg)
	val primaryContainer = primary.copy(alpha = 0.2f).compositeOver(bg)
	val primarySoft = primary.copy(alpha = 0.14f)
	val dangerContainer = danger.copy(alpha = 0.2f).compositeOver(bg)
	val scrim = Color.Black.copy(alpha = if (dark) 0.42f else 0.28f)
	val text = fg
	val textMuted = fg.copy(alpha = 0.64f)
	val textSubtle = fg.copy(alpha = 0.42f)
	val textFaint = fg.copy(alpha = 0.24f)
	val outline = fg.copy(alpha = 0.08f)

	fun mix(other: Palette, t: Float) = Palette(
		lerp(bg, other.bg, t), lerp(fg, other.fg, t), lerp(primary, other.primary, t), lerp(secondary, other.secondary, t),
		lerp(tertiary, other.tertiary, t), lerp(onPrimary, other.onPrimary, t), lerp(danger, other.danger, t),
		lerp(warning, other.warning, t), lerp(success, other.success, t), if (t < 0.5f) dark else other.dark,
	)

	companion object {
		/** The look without a wallpaper: the shell's own fallback palette. */
		val Default: Palette = derive(
			Color(0xFF151312), Color(0xFFEAE3D9),
			listOf(0xFF151312, 0xFFE07A5F, 0xFF8FB573, 0xFFE0A458, 0xFF6F9FD8, 0xFFB58BD6, 0xFF5FB3B3, 0xFFEAE3D9).map { Color(it) },
		)

		fun parse(hex: String): Color? = runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrNull()

		/** [colors] are wallust's color0…color15; 1…6 are the accent candidates. */
		fun derive(bg: Color, fg: Color, colors: List<Color>): Palette {
			val dark = bg.luminance() < 0.35f

			fun legible(color: Color, minimum: Float): Color {
				var out = color
				var step = 0
				while (step < 12 && contrast(out, bg) < minimum) {
					out = if (dark) lighter(out, 1.12f) else darker(out, 1.12f)
					step += 1
				}
				return out
			}

			val ranked = (1..6).mapNotNull { colors.getOrNull(it) }.ifEmpty { listOf(fg) }
				.map { it to saturation(it) * 1.1f + ((contrast(it, bg) - 1.6f) / 4.5f).coerceIn(0f, 1f) * 1.3f }
				.sortedByDescending { it.second }
				.map { it.first }

			fun distinct(reference: Float, offset: Int): Color {
				for (index in offset until ranked.size) {
					val hue = hue(ranked[index])
					val distance = min(abs(hue - reference), 1f - abs(hue - reference))
					if (reference < 0f || hue < 0f || distance > 0.06f) return ranked[index]
				}
				return ranked[min(offset, ranked.size - 1)]
			}

			val primary = legible(ranked[0], 3.2f)
			val secondary = legible(distinct(hue(ranked[0]), 1), 3.0f)
			val tertiary = legible(distinct(hue(secondary), 2), 3.0f)
			return Palette(
				bg = bg,
				fg = fg,
				primary = primary,
				secondary = secondary,
				tertiary = tertiary,
				onPrimary = if (contrast(primary, bg) >= contrast(primary, fg)) bg else fg,
				danger = legible(primary.copy(alpha = 0.12f).compositeOver(Color(0xFFE5484D)), 3.4f),
				warning = legible(primary.copy(alpha = 0.1f).compositeOver(Color(0xFFF5A524)), 3.4f),
				success = legible(primary.copy(alpha = 0.1f).compositeOver(Color(0xFF46A758)), 3.4f),
				dark = dark,
			)
		}

		fun contrast(a: Color, b: Color): Float {
			val la = a.luminance()
			val lb = b.luminance()
			return (max(la, lb) + 0.05f) / (min(la, lb) + 0.05f)
		}

		private fun hsv(color: Color) = FloatArray(3).also { android.graphics.Color.colorToHSV(color.toArgb(), it) }

		private fun saturation(color: Color) = hsv(color)[1]

		/** 0…1, or -1 for a grey, like QColor::hsvHueF */
		private fun hue(color: Color) = hsv(color).let { if (it[1] == 0f) -1f else it[0] / 360f }

		// QColor::lighter and ::darker
		private fun lighter(color: Color, factor: Float): Color {
			val value = hsv(color)
			value[2] *= factor
			if (value[2] > 1f) {
				value[1] = (value[1] - (value[2] - 1f)).coerceAtLeast(0f)
				value[2] = 1f
			}
			return Color(android.graphics.Color.HSVToColor(value))
		}

		private fun darker(color: Color, factor: Float): Color {
			val value = hsv(color)
			value[2] /= factor
			return Color(android.graphics.Color.HSVToColor(value))
		}
	}
}
