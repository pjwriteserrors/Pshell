package dev.pshell.app.features

import androidx.compose.runtime.Composable

/**
 * The groups the features fall into. Each group with something switched on
 * is a tab of the bar: it opens on the group's first feature, the rest of
 * the group sits in a row of chips at the top. The home screen lists every
 * group under its own heading, so a feature is found by its kind.
 */
enum class Group(val id: String, val title: String, val icon: String, val blurb: String, val tab: Boolean = true) {
	Remote("remote", "Remote", "gesture_tap", "Steer the PC: touchpad, keyboard, commands, terminal, windows"),
	Media("media", "Media", "music", "What plays on the PC, sound, lyrics"),
	Work("work", "Work", "briefcase_outline", "Mail, time, agents, notes, downloads, reading"),
	Pc("pc", "PC", "monitor", "System, updates, settings, capture, Studio"),
	Link("link", "Phone & PC", "cellphone_link", "How the phone and the PC talk: notifications, clipboard, files, calls", tab = false),
}

/**
 * One thing the app can do. It is offered only while every plugin it names
 * is switched on at the PC (and "phone" itself); the PC refuses the rest
 * anyway. [card] is its live summary on the home screen, [screen] the whole.
 * [keywords] find it in the home screen's search, next to its title.
 */
class Feature(
	val id: String,
	val title: String,
	val icon: String,
	val group: Group,
	val plugins: List<String> = emptyList(),
	val keywords: List<String> = emptyList(),
	/** draws its own surface edge to edge, no page header (touchpad, terminal) */
	val bare: Boolean = false,
	/** the tile's second line, if it is cheap to know */
	val summary: @Composable () -> String = { "" },
	val card: (@Composable (open: () -> Unit) -> Unit)? = null,
	val screen: @Composable () -> Unit,
	/** a page below the screen, by an argument: route "feature/<id>/<arg>" */
	val page: (@Composable (arg: String) -> Unit)? = null,
) {
	/** what the search matches, lower case */
	val terms: List<String> = (listOf(title, group.title) + keywords).map { it.lowercase() }
}

/** Everything, grouped; within a group in the order of the home grid and the chips. */
val Features: List<Feature> = listOf(
	// remote
	TouchpadFeature,
	KeyboardFeature,
	CommandsFeature,
	TerminalFeature,
	WindowsFeature,
	AppsFeature,
	RadialFeature,
	ScreenFeature,
	// media
	MediaFeature,
	SoundFeature,
	LyricsFeature,
	SongFeature,
	HandoffFeature,
	// work
	MessagesFeature,
	TimerFeature,
	TrackingFeature,
	AgentsFeature,
	TodosFeature,
	NotesFeature,
	CalendarFeature,
	ShelvesFeature,
	DownloadsFeature,
	ReaderFeature,
	ChatFeature,
	TranslateFeature,
	ConvertFeature,
	BreaksFeature,
	WeatherFeature,
	// pc
	UnlockFeature,
	SystemFeature,
	UpdatesFeature,
	QuickFeature,
	CaptureFeature,
	StudioFeature,
	DisplayFeature,
	SshFeature,
	PcFilesFeature,
	RpgFeature,
	SessionFeature,
	// phone & pc
	NotificationsFeature,
	ClipboardFeature,
	FilesFeature,
	CallsFeature,
	FindFeature,
)

fun feature(id: String): Feature? = Features.firstOrNull { it.id == id }

/** The features of a group, in order. */
fun featuresOf(group: Group): List<Feature> = Features.filter { it.group == group }
