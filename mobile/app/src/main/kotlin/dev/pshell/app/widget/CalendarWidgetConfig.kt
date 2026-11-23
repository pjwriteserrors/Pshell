package dev.pshell.app.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.getAppWidgetState
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.datastore.preferences.core.Preferences
import dev.pshell.app.App
import dev.pshell.app.ui.theme.PshellTheme
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Gap
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.PillSlider
import dev.pshell.app.ui.widgets.PrimaryButton
import kotlinx.coroutines.runBlocking

/** The calendar widget's settings, when it is placed and from the launcher's widget settings: how see-through it is. */
class CalendarWidgetConfig : ComponentActivity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
		setResult(RESULT_CANCELED)
		if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()
		val app = application as App
		val manager = GlanceAppWidgetManager(this)
		val start = runBlocking {
			runCatching {
				getAppWidgetState<Preferences>(this@CalendarWidgetConfig, PreferencesGlanceStateDefinition, manager.getGlanceIdBy(widgetId))[CalendarWidget.OPACITY]
			}.getOrNull() ?: 1f
		}
		setContent {
			val palette by app.palette.collectAsState()
			var opacity by remember { mutableFloatStateOf(start) }
			PshellTheme(palette) {
				Column(Modifier.fillMaxSize().background(Theme.colors.bg).statusBarsPadding().padding(20.dp)) {
					Label("Calendar widget", style = Theme.Type.display)
					Gap(20)
					// how it looks on the wallpaper: the background at this strength
					Box(Modifier.fillMaxWidth().height(90.dp).clip(RoundedCornerShape(26.dp)).background(Theme.colors.primary)) {
						Box(Modifier.fillMaxSize().clip(RoundedCornerShape(26.dp)).background(Theme.colors.bg.copy(alpha = opacity)).padding(16.dp)) {
							Label("Today", color = Theme.colors.text, style = Theme.Type.title)
						}
					}
					Gap(20)
					PillSlider(opacity, icon = "eye_outline", label = "Background ${(opacity * 100).toInt()} %") { opacity = it }
					Gap(20)
					PrimaryButton("Done", Modifier.fillMaxWidth(), icon = "check") { done(widgetId, opacity) }
				}
			}
		}
	}

	private fun done(widgetId: Int, opacity: Float) {
		val manager = GlanceAppWidgetManager(this)
		runBlocking {
			val glanceId = manager.getGlanceIdBy(widgetId)
			updateAppWidgetState(this@CalendarWidgetConfig, PreferencesGlanceStateDefinition, glanceId) { state ->
				state.toMutablePreferences().apply { this[CalendarWidget.OPACITY] = opacity }
			}
			runCatching { CalendarWidget().update(this@CalendarWidgetConfig, glanceId) }
		}
		setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
		finish()
	}
}
