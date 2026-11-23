package dev.pshell.app.widget

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.LocalContext
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.lazy.LazyColumn
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.calendar.Calendars
import dev.pshell.app.calendar.colorOf
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DateText
import java.util.Locale

/**
 * The next days of the Baikal calendar (Calendars.upcoming, kept for it, so it
 * shows also without a connection). How see-through its background is: its
 * own setting, from the launcher's widget settings (CalendarWidgetConfig).
 */
class CalendarWidget : GlanceAppWidget() {
	override val sizeMode = SizeMode.Exact

	companion object {
		/** how solid the background is, 0 … 1 */
		val OPACITY = floatPreferencesKey("opacity")
	}

	override suspend fun provideGlance(context: Context, id: GlanceId) {
		val app = context.applicationContext as App
		provideContent {
			val palette by app.palette.collectAsState()
			val upcoming by Calendars.upcoming.collectAsState()
			val opacity = currentState(OPACITY) ?: 1f
			Content(palette, upcoming, opacity)
		}
	}

	@Composable
	private fun Content(palette: dev.pshell.app.ui.theme.Palette, upcoming: List<Calendars.Upcoming>, opacity: Float) {
		val context = LocalContext.current
		val today = LocalDate.now()
		val now = LocalDateTime.now()
		val open = actionStartActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("route", "feature/baikal"))
		val add = actionStartActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_MULTIPLE_TASK).putExtra("route", "feature/baikal/new:$today"))
		Box(GlanceModifier.fillMaxSize().background(provider(palette.bg.copy(alpha = opacity.coerceIn(0f, 1f)))).cornerRadius(26.dp).padding(14.dp)) {
			Column(GlanceModifier.fillMaxSize()) {
				Row(GlanceModifier.fillMaxWidth().clickable(open), verticalAlignment = Alignment.CenterVertically) {
					Column(GlanceModifier.defaultWeight()) {
						Text(today.dayOfWeek.getDisplayName(DateText.FULL, Locale.getDefault()), style = TextStyle(color = provider(palette.primary), fontSize = 13.sp, fontWeight = FontWeight.Bold))
						Text(today.format(DateTimeFormatter.ofPattern("d. MMMM")), style = TextStyle(color = provider(palette.text), fontSize = 20.sp, fontWeight = FontWeight.Bold))
					}
					Box(GlanceModifier.size(36.dp).background(provider(palette.primaryContainer.copy(alpha = 0.9f))).cornerRadius(18.dp).clickable(add), contentAlignment = Alignment.Center) {
						Image(glyph(context, "plus", 20.dp, palette.text), contentDescription = "New event", modifier = GlanceModifier.size(20.dp))
					}
				}
				Spacer(GlanceModifier.height(8.dp))
				val shown = upcoming.filter { it.end.isAfter(now) }
				if (shown.isEmpty()) {
					Box(GlanceModifier.fillMaxSize().clickable(open), contentAlignment = Alignment.Center) {
						Text("Nothing in the next two weeks", style = TextStyle(color = provider(palette.textMuted), fontSize = 13.sp))
					}
				} else {
					// day headings between the events
					val rows = mutableListOf<Any>()
					var last: LocalDate? = null
					for (event in shown) {
						val day = if (event.start.toLocalDate().isBefore(today)) today else event.start.toLocalDate()
						if (day != last) {
							rows += day
							last = day
						}
						rows += event
					}
					LazyColumn(GlanceModifier.fillMaxSize()) {
						items(rows.size) { index ->
							when (val row = rows[index]) {
								is LocalDate -> Text(
									when (row) {
										today -> "Today"
										today.plusDays(1) -> "Tomorrow"
										else -> row.format(DateTimeFormatter.ofPattern("EEEE, d. MMM"))
									},
									modifier = GlanceModifier.padding(top = if (index == 0) 0.dp else 8.dp, bottom = 3.dp),
									style = TextStyle(color = provider(palette.textMuted), fontSize = 12.sp, fontWeight = FontWeight.Bold),
								)
								is Calendars.Upcoming -> Row(GlanceModifier.fillMaxWidth().padding(vertical = 3.dp).clickable(open), verticalAlignment = Alignment.CenterVertically) {
									Box(GlanceModifier.width(4.dp).height(30.dp).background(provider(colorOf(row.color, palette.secondary))).cornerRadius(2.dp)) {}
									Spacer(GlanceModifier.width(10.dp))
									Column(GlanceModifier.defaultWeight()) {
										Text(row.title, maxLines = 1, style = TextStyle(color = provider(palette.text), fontSize = 14.sp, fontWeight = FontWeight.Medium))
										val time = if (row.allDay) "All day" else "${row.start.format(TIME)} – ${row.end.format(TIME)}"
										Text(listOf(time, row.location).filter { it.isNotEmpty() }.joinToString(" · "), maxLines = 1, style = TextStyle(color = provider(palette.textMuted), fontSize = 12.sp))
									}
								}
								else -> Spacer(GlanceModifier.height(0.dp))
							}
						}
					}
				}
			}
		}
	}

	private val TIME = DateTimeFormatter.ofPattern("HH:mm")
}

class CalendarWidgetReceiver : GlanceAppWidgetReceiver() {
	override val glanceAppWidget: GlanceAppWidget = CalendarWidget()
}
