package dev.pshell.app.features

import androidx.compose.runtime.Composable

/**
 * One thing the app can do. It is offered only while every plugin it names
 * is switched on at the PC (and "phone" itself); the PC refuses the rest
 * anyway. [card] is its live summary on the home screen, [screen] the whole.
 */
class Feature(
	val id: String,
	val title: String,
	val icon: String,
	val plugins: List<String> = emptyList(),
	/** shown in the tab bar, in this order (0: not a tab) */
	val tab: Int = 0,
	/** the tile's second line, if it is cheap to know */
	val summary: @Composable () -> String = { "" },
	val card: (@Composable (open: () -> Unit) -> Unit)? = null,
	val screen: @Composable () -> Unit,
)

/** Everything, in the order of the home grid. */
val Features: List<Feature> = listOf(
	UnlockFeature,
	MediaFeature,
	TouchpadFeature,
	CommandsFeature,
	TerminalFeature,
	KeyboardFeature,
	TimerFeature,
	AgentsFeature,
	BreaksFeature,
	SystemFeature,
	SoundFeature,
	UpdatesFeature,
	TodosFeature,
	NotesFeature,
	WindowsFeature,
	AppsFeature,
	RadialFeature,
	QuickFeature,
	CaptureFeature,
	ScreenFeature,
	StudioFeature,
	SongFeature,
	WeatherFeature,
	CalendarFeature,
	ShelvesFeature,
	TranslateFeature,
	DisplayFeature,
	ChatFeature,
	SshFeature,
	RpgFeature,
	NotificationsFeature,
	ClipboardFeature,
	FilesFeature,
	PcFilesFeature,
	HandoffFeature,
	CallsFeature,
	FindFeature,
	SessionFeature,
)

fun feature(id: String): Feature? = Features.firstOrNull { it.id == id }
