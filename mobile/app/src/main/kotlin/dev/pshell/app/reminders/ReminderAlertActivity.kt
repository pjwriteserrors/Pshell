package dev.pshell.app.reminders

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.pshell.app.App
import dev.pshell.app.ui.theme.PshellTheme
import dev.pshell.app.ui.theme.Theme
import dev.pshell.app.ui.widgets.Glyph
import dev.pshell.app.ui.widgets.Label
import dev.pshell.app.ui.widgets.PrimaryButton
import dev.pshell.app.ui.widgets.SoftButton

/** A reminder over everything, also over the lock screen: Done or Snooze close it. */
class ReminderAlertActivity : ComponentActivity() {
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		setShowWhenLocked(true)
		setTurnScreenOn(true)
		enableEdgeToEdge(SystemBarStyle.dark(0), SystemBarStyle.dark(0))
		val app = application as App
		setContent {
			val palette by app.palette.collectAsState()
			PshellTheme(palette) { Alert() }
		}
	}

	override fun onNewIntent(intent: android.content.Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		recreate()
	}

	/** Gone, or on to the next one that waits for the whole screen. */
	private fun close() {
		val next = Reminders.nextFullscreen()
		if (next == null) return finish()
		intent = Alerts.alertIntent(this, next.id, next.occurrence)
		recreate()
	}

	@androidx.compose.runtime.Composable
	private fun Alert() {
		val id = intent.getStringExtra("id").orEmpty()
		val occurrence = intent.getLongExtra("occurrence", 0)
		val snapshot by Reminders.snapshot.collectAsState()
		val showing by Reminders.showing.collectAsState()
		val reminder = snapshot.reminders.firstOrNull { it.id == id }
		val wasShown = remember { showing.containsKey(id) }
		// acknowledged or snoozed elsewhere
		LaunchedEffect(showing) { if (wasShown && !showing.containsKey(id)) close() }
		val level = showing[id]?.level ?: reminder?.level ?: "normal"
		Box(Modifier.fillMaxSize().background(Theme.colors.bg).padding(WindowInsets.safeDrawing.asPaddingValues()).padding(24.dp)) {
			Column(Modifier.align(Alignment.Center).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
				Box(Modifier.size(96.dp).clip(CircleShape).background(if (level == "fullscreen") Theme.colors.danger else Theme.colors.primaryContainer), contentAlignment = Alignment.Center) {
					Glyph(if (level == "fullscreen") "alarm" else "bell_ring_outline", size = 48.dp, color = if (level == "fullscreen") Theme.colors.bg else Theme.colors.text)
				}
				Spacer(Modifier.height(24.dp))
				Label(reminder?.title ?: "Reminder", style = Theme.Type.display.copy(fontSize = 30.sp), align = TextAlign.Center, maxLines = 4)
				if (occurrence > 0 && (reminder == null || reminder.trigger == "time")) {
					Spacer(Modifier.height(6.dp))
					Label(Alerts.when_(reminder ?: Reminder(id, ""), occurrence), style = Theme.Type.title, color = Theme.colors.textMuted, align = TextAlign.Center)
				}
				if (!reminder?.note.isNullOrEmpty()) {
					Spacer(Modifier.height(12.dp))
					Label(reminder!!.note, color = Theme.colors.textMuted, align = TextAlign.Center, maxLines = 8)
				}
			}
			Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
				for (pair in Reminders.Snooze.entries.chunked(2)) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
					for (snooze in pair) SoftButton(snooze.label, Modifier.weight(1f).height(52.dp), icon = if (snooze == Reminders.Snooze.Pc) "monitor" else "alarm_snooze") {
						Reminders.snooze(id, snooze)
						close()
					}
				}
				PrimaryButton("Done", Modifier.fillMaxWidth().height(64.dp), icon = "check") {
					Reminders.ack(id, occurrence.takeIf { it > 0 })
					close()
				}
			}
		}
	}
}
