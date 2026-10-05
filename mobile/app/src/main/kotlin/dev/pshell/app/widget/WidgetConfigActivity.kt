package dev.pshell.app.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.datastore.preferences.core.Preferences
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.state.PreferencesGlanceStateDefinition
import dev.pshell.app.App
import dev.pshell.app.ui.theme.PshellTheme
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.ListRow
import dev.pshell.app.ui.widgets.Panel
import dev.pshell.app.ui.widgets.SectionLabel
import kotlinx.coroutines.runBlocking

/** Asked when a widget is placed, and from its settings: which PC should it show? */
class WidgetConfigActivity : ComponentActivity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
		setResult(RESULT_CANCELED)
		if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()
		val app = application as App
		setContent {
			val palette by app.palette.collectAsState()
			val pcs by app.link.pcs.list.collectAsState()
			PshellTheme(palette) {
				Column(Modifier.fillMaxSize().background(Theme.colors.bg).statusBarsPadding().padding(20.dp)) {
					Label("Which PC?", style = Theme.Type.display)
					Label("What this widget shows and steers.", style = Theme.Type.small, color = Theme.colors.textMuted)
					SectionLabel("PCs")
					Panel(padding = PaddingValues(6.dp)) {
						ListRow("Whichever is in front", icon = "swap_horizontal", subtitle = "The preferred PC while it is connected, otherwise any that is", onClick = { choose(widgetId, "") })
						for (pc in pcs) ListRow(pc.name, icon = "monitor", subtitle = pc.id.take(16), onClick = { choose(widgetId, pc.id) })
					}
				}
			}
		}
	}

	private fun choose(widgetId: Int, pc: String) {
		val manager = GlanceAppWidgetManager(this)
		runBlocking {
			val glanceId = manager.getGlanceIdBy(widgetId)
			updateAppWidgetState(this@WidgetConfigActivity, PreferencesGlanceStateDefinition, glanceId) { state ->
				state.toMutablePreferences().apply { if (pc.isEmpty()) remove(Widgets.PC) else this[Widgets.PC] = pc }
			}
			val provider = AppWidgetManager.getInstance(this@WidgetConfigActivity).getAppWidgetInfo(widgetId)?.provider?.className.orEmpty()
			val widget = when {
				provider.endsWith("MediaWidgetReceiver") -> MediaWidget()
				provider.endsWith("StatusWidgetReceiver") -> StatusWidget()
				else -> CommandsWidget()
			}
			runCatching { widget.update(this@WidgetConfigActivity, glanceId) }
		}
		setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
		finish()
	}
}
