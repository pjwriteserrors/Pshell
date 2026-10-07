package dev.pshell.app.features

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.string
import dev.pshell.app.ui.link
import dev.pshell.app.ui.topic
import dev.pshell.app.ui.widgets.Confirm
import dev.pshell.app.ui.widgets.Screen
import dev.pshell.app.ui.widgets.SectionLabel
import dev.pshell.app.ui.widgets.Tile

val SessionFeature = Feature(
	id = "session",
	group = Group.Pc,
	keywords = listOf("lock", "sperren", "suspend", "shutdown", "herunterfahren", "reboot", "neustart", "logout", "power"),
	title = "Session",
	icon = "power",
	summary = { if (topic("session")["locked"].bool) "Locked" else "" },
	screen = { SessionScreen() },
)

private class PowerAction(val id: String, val icon: String, val title: String, val question: String)

private val powerActions = listOf(
	PowerAction("suspend", "power_sleep", "Suspend", "Put the PC to sleep?"),
	PowerAction("logout", "logout", "Log out", "End the session? Open programs are closed."),
	PowerAction("reboot", "restart", "Restart", "Restart the PC? Open programs are closed."),
	PowerAction("shutdown", "power", "Shut down", "Shut the PC down? Open programs are closed."),
)

@Composable
private fun SessionScreen() {
	val session = topic("session")
	val link = link
	var asking by remember { mutableStateOf<PowerAction?>(null) }
	Screen("Session", subtitle = session["host"].string) {
		if (session["canLock"].bool) {
			Tile("lock", if (session["locked"].bool) "Locked" else "Lock", Modifier.fillMaxWidth(), subtitle = if (session["locked"].bool) "The lock screen is up" else "Show the lock screen", active = session["locked"].bool) {
				link.run("session", "lock")
			}
		}
		if (session["canPower"].bool) {
			SectionLabel("Power")
			Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
				for (pair in powerActions.chunked(2)) {
					Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
						for (action in pair) Tile(action.icon, action.title, Modifier.weight(1f)) { asking = action }
					}
				}
			}
		}
	}
	asking?.let { action ->
		Confirm(action.title, action.question, confirm = action.title, danger = action.id != "suspend", onDismiss = { asking = null }) {
			link.run("session", action.id)
		}
	}
}
