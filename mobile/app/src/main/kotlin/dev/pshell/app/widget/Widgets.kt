package dev.pshell.app.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.res.ResourcesCompat
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.currentState
import dev.pshell.app.link.PcLink
import java.util.concurrent.ConcurrentHashMap
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.R
import dev.pshell.app.link.LinkState
import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.string
import dev.pshell.app.ui.theme.Icons
import dev.pshell.app.ui.theme.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import okhttp3.Request

/**
 * Home screen widgets: the commands as buttons, the PC's player, and a line
 * of status. They show what the app last heard from the PC and are redrawn
 * when that changes; a tap goes through the app's connection, without
 * opening the app.
 */
object Widgets {
	/** the PC a widget shows; unset: the one in front */
	val PC = androidx.datastore.preferences.core.stringPreferencesKey("pc")

	/** the cover of what plays on each PC, fetched once per track; by the PC's id */
	val covers = MutableStateFlow<Map<String, Bitmap>>(emptyMap())
	private val coverUrls = ConcurrentHashMap<String, String>()
	private lateinit var cache: android.content.SharedPreferences

	/** The link a widget uses, by what was chosen for it. */
	fun linkFor(app: App, chosen: String?): PcLink? = app.link.of(chosen)

	private val held = HashSet<String>()

	/**
	 * A topic is kept only while a widget that shows it is on a home screen:
	 * the commands' state commands run on the PC every few seconds otherwise.
	 */
	fun refreshSubscriptions(app: App) {
		app.link.scope.launch {
			val manager = androidx.glance.appwidget.GlanceAppWidgetManager(app)
			val wanted = HashSet<String>()
			runCatching {
				if (manager.getGlanceIds(CommandsWidget::class.java).isNotEmpty()) wanted.add("commands")
				if (manager.getGlanceIds(MediaWidget::class.java).isNotEmpty()) wanted.add("media")
				if (manager.getGlanceIds(StatusWidget::class.java).isNotEmpty()) wanted.addAll(listOf("session", "timer"))
			}
			synchronized(held) {
				for (topic in wanted - held) app.link.acquire(topic)
				for (topic in held - wanted) app.link.release(topic)
				held.clear()
				held.addAll(wanted)
			}
		}
	}

	@OptIn(FlowPreview::class)
	fun install(app: App) {
		val link = app.link
		cache = app.getSharedPreferences("widgets", Context.MODE_PRIVATE)
		refreshSubscriptions(app)
		val watched = HashSet<String>()
		link.scope.launch {
			link.pcs.list.collect { list ->
				for (pc in list) {
					if (!watched.add(pc.id)) continue
					val one = link.of(pc.id) ?: continue
					// the commands are remembered, so a widget has its buttons before the PC answers
					launch { one.topic("commands").collect { if (it != null) cache.edit().putString("commands:${pc.id}", it.toString()).apply() } }
					launch {
						one.topic("media").collect { media ->
							val url = one.blob(media["art"].string)
							if (url == coverUrls[pc.id]) return@collect
							if (url == null) coverUrls.remove(pc.id) else coverUrls[pc.id] = url
							val picture = if (url == null) null else withContext(Dispatchers.IO) {
								runCatching {
									link.http.newCall(Request.Builder().url(url).build()).execute().use { response -> BitmapFactory.decodeStream(response.body.byteStream())?.let(::square) }
								}.getOrNull()
							}
							covers.value = if (picture == null) covers.value - pc.id else covers.value + (pc.id to picture)
							redraw(app)
						}
					}
					launch {
						combine(one.topic("commands"), one.topic("media"), one.topic("session"), one.topic("timer"), one.connection) { values -> values.toList() }
							.debounce(400).collect { redraw(app) }
					}
				}
			}
		}
		link.scope.launch { app.palette.collect { redraw(app) } }
		link.scope.launch { link.pcs.preferredFlow.collect { redraw(app) } }
	}

	private suspend fun redraw(app: App) {
		runCatching {
			CommandsWidget().updateAll(app)
			MediaWidget().updateAll(app)
			StatusWidget().updateAll(app)
		}
	}

	/** The middle of a cover, square, small enough for a widget. */
	private fun square(picture: Bitmap): Bitmap {
		val side = minOf(picture.width, picture.height)
		val cropped = Bitmap.createBitmap(picture, (picture.width - side) / 2, (picture.height - side) / 2, side, side)
		return Bitmap.createScaledBitmap(cropped, 240, 240, true)
	}

	fun commands(one: PcLink?): JsonElement? =
		one?.topic("commands")?.value ?: one?.let { cache.getString("commands:${it.id}", null) }?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }
}

fun provider(color: Color) = ColorProvider(color)

/** An icon of the shell as a picture: widgets cannot use the app's icon font. */
fun glyph(context: Context, name: String, size: Dp, color: Color): ImageProvider {
	val pixels = (size.value * context.resources.displayMetrics.density).toInt().coerceAtLeast(8)
	val bitmap = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888)
	val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
		typeface = ResourcesCompat.getFont(context, R.font.symbols)
		textSize = pixels * 0.92f
		this.color = color.toArgb()
		textAlign = Paint.Align.CENTER
	}
	val metrics = paint.fontMetrics
	Canvas(bitmap).drawText(Icons[name], pixels / 2f, pixels / 2f - (metrics.ascent + metrics.descent) / 2f, paint)
	return ImageProvider(bitmap)
}

private fun label(color: Color, size: Int, bold: Boolean = false) =
	TextStyle(color = provider(color), fontSize = size.sp, fontWeight = if (bold) FontWeight.Bold else FontWeight.Medium)

private val openApp = actionStartActivity(Intent(App.instance, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

private fun openRoute(route: String) = actionStartActivity(Intent(App.instance, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("route", route))

/** The widget's own surface: the shell's background, rounded like its panels. */
@Composable
private fun Surface(palette: Palette, content: @Composable () -> Unit) {
	Box(GlanceModifier.fillMaxSize().background(provider(palette.bg)).cornerRadius(26.dp).padding(10.dp)) { content() }
}

// ── commands ───────────────────────────────────────────────────────────────
class CommandsWidget : GlanceAppWidget() {
	override val sizeMode = SizeMode.Exact

	override suspend fun provideGlance(context: Context, id: GlanceId) {
		val app = context.applicationContext as App
		provideContent {
			val palette by app.palette.collectAsState()
			val one = Widgets.linkFor(app, currentState(Widgets.PC))
			val live by (one?.topic("commands") ?: MutableStateFlow(null)).collectAsState()
			val tiles = (live ?: Widgets.commands(one))["tiles"].list
			val size = LocalSize.current
			val columns = (size.width.value / 76).toInt().coerceIn(2, 6)
			val rows = (size.height.value / 70).toInt().coerceIn(1, 6)
			Surface(palette) {
				if (tiles.isEmpty()) {
					Box(GlanceModifier.fillMaxSize().clickable(openRoute("feature/commands")), contentAlignment = Alignment.Center) {
						Text("No commands yet", style = label(palette.textMuted, 13))
					}
				} else Column(GlanceModifier.fillMaxSize()) {
					val shown = tiles.take(columns * rows).chunked(columns)
					shown.forEachIndexed { rowIndex, row ->
						Row(GlanceModifier.fillMaxWidth().defaultWeight()) {
							row.forEachIndexed { index, tile ->
								val accent = when (tile["color"].string) {
									"primary" -> palette.primary
									"secondary" -> palette.secondary
									"tertiary" -> palette.tertiary
									"success" -> palette.success
									"warning" -> palette.warning
									"danger" -> palette.danger
									else -> palette.fg
								}
								val neutral = tile["color"].string.isEmpty()
								val direct = !tile["confirm"].bool && tile["fields"].list.isEmpty() && !tile["output"].bool && !tile["terminal"].bool
								val route = if (tile["terminal"].bool) "terminal/run/${tile["id"].string}" else "feature/commands"
								Column(
									GlanceModifier.defaultWeight().fillMaxHeight()
										.background(provider(if (neutral) palette.layer1 else accent.copy(alpha = 0.18f).compositeOver(palette.bg)))
										.cornerRadius(18.dp)
										.clickable(if (direct) actionRunCallback<RunCommand>(actionParametersOf(RunCommand.id to tile["id"].string, RunCommand.pc to one?.id.orEmpty())) else openRoute(route)),
									horizontalAlignment = Alignment.CenterHorizontally,
									verticalAlignment = Alignment.CenterVertically,
								) {
									Image(glyph(LocalContext.current, tile["icon"].string.ifEmpty { "console" }, 22.dp, if (neutral) palette.text else accent), null, GlanceModifier.size(22.dp))
									Spacer(GlanceModifier.height(3.dp))
									Text(tile["label"].string, style = label(palette.text, 11), maxLines = 1)
								}
								if (index < columns - 1) Spacer(GlanceModifier.width(6.dp))
							}
							// an incomplete last row keeps the tiles' width
							repeat(columns - row.size) { index ->
								Spacer(GlanceModifier.defaultWeight())
								if (row.size + index < columns - 1) Spacer(GlanceModifier.width(6.dp))
							}
						}
						if (rowIndex < shown.lastIndex) Spacer(GlanceModifier.height(6.dp))
					}
				}
			}
		}
	}
}

class RunCommand : ActionCallback {
	override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
		val app = context.applicationContext as App
		app.link.retryNow()
		app.link.of(parameters[pc])?.run("commands", "run", json("id" to (parameters[id] ?: return)))
	}

	companion object {
		val id = ActionParameters.Key<String>("id")
		val pc = ActionParameters.Key<String>("pc")
	}
}

class CommandsWidgetReceiver : GlanceAppWidgetReceiver() {
	override val glanceAppWidget = CommandsWidget()

	override fun onEnabled(context: Context) {
		super.onEnabled(context)
		Widgets.refreshSubscriptions(context.applicationContext as App)
	}

	override fun onDisabled(context: Context) {
		super.onDisabled(context)
		Widgets.refreshSubscriptions(context.applicationContext as App)
	}
}

// ── media ──────────────────────────────────────────────────────────────────
class MediaWidget : GlanceAppWidget() {
	override val sizeMode = SizeMode.Exact

	override suspend fun provideGlance(context: Context, id: GlanceId) {
		val app = context.applicationContext as App
		provideContent {
			val palette by app.palette.collectAsState()
			val one = Widgets.linkFor(app, currentState(Widgets.PC))
			val media by (one?.topic("media") ?: MutableStateFlow(null)).collectAsState()
			val connection by (one?.connection ?: MutableStateFlow(null)).collectAsState()
			val pictures by Widgets.covers.collectAsState()
			val connected = connection != null
			val has = connected && media["has"].bool
			val cover = one?.let { pictures[it.id] }
			val size = LocalSize.current
			// a single row of cells: everything on one line
			val flat = size.height < 100.dp
			val pc = one?.id.orEmpty()
			val title = if (!connected) "PC not reachable" else if (has) media["title"].string else "Nothing playing"
			// three shapes: one line, a card, or a tall one with the cover on top
			val tall = size.height >= 170.dp
			Surface(palette) {
				if (tall) {
					val side = minOf(size.width.value - 20f, size.height.value - 20f - 96f).coerceAtLeast(60f).dp
					Column(GlanceModifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
						Box(GlanceModifier.size(side).background(provider(palette.layer2)).cornerRadius(22.dp).clickable(openRoute("feature/media")), contentAlignment = Alignment.Center) {
							if (has && cover != null) Image(ImageProvider(cover), null, GlanceModifier.fillMaxSize().cornerRadius(22.dp), contentScale = ContentScale.Crop)
							else Image(glyph(LocalContext.current, "music", 40.dp, palette.textSubtle), null, GlanceModifier.size(40.dp))
						}
						Spacer(GlanceModifier.height(10.dp))
						Text(title, style = label(palette.text, 15, bold = true), maxLines = 1)
						Text(if (has && media["artist"].string.isNotEmpty()) media["artist"].string else media["player"].string.ifEmpty { " " }, style = label(palette.textMuted, 12), maxLines = 1)
						Spacer(GlanceModifier.defaultWeight())
						Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally) {
							Control("volume_minus", palette.text, palette.layer1, "volumeDown", pc, 34.dp)
							Spacer(GlanceModifier.width(10.dp))
							Control("skip_previous", palette.text, palette.layer1, "previous", pc)
							Spacer(GlanceModifier.width(10.dp))
							Control(if (media["playing"].bool) "pause" else "play", palette.onPrimary, palette.primary, "playPause", pc, 48.dp)
							Spacer(GlanceModifier.width(10.dp))
							Control("skip_next", palette.text, palette.layer1, "next", pc)
							Spacer(GlanceModifier.width(10.dp))
							Control("volume_plus", palette.text, palette.layer1, "volumeUp", pc, 34.dp)
						}
					}
				} else Row(GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
					val side = if (flat) 36.dp else (size.height.value - 20).coerceIn(44f, 120f).dp
					Box(GlanceModifier.size(side).background(provider(palette.layer2)).cornerRadius(if (flat) 12.dp else 18.dp).clickable(openRoute("feature/media")), contentAlignment = Alignment.Center) {
						if (has && cover != null) Image(ImageProvider(cover), null, GlanceModifier.fillMaxSize().cornerRadius(if (flat) 12.dp else 18.dp), contentScale = ContentScale.Crop)
						else Image(glyph(LocalContext.current, "music", if (flat) 18.dp else 26.dp, palette.textSubtle), null, GlanceModifier.size(if (flat) 18.dp else 26.dp))
					}
					Spacer(GlanceModifier.width(10.dp))
					if (flat) {
						Text(title, GlanceModifier.defaultWeight(), style = label(palette.text, 13, bold = true), maxLines = 1)
						Spacer(GlanceModifier.width(6.dp))
						Control("skip_previous", palette.text, palette.layer1, "previous", pc, 30.dp)
						Spacer(GlanceModifier.width(6.dp))
						Control(if (media["playing"].bool) "pause" else "play", palette.onPrimary, palette.primary, "playPause", pc, 30.dp)
						Spacer(GlanceModifier.width(6.dp))
						Control("skip_next", palette.text, palette.layer1, "next", pc, 30.dp)
					} else Column(GlanceModifier.defaultWeight()) {
						Text(title, style = label(palette.text, 15, bold = true), maxLines = 1)
						if (has && media["artist"].string.isNotEmpty()) Text(media["artist"].string, style = label(palette.textMuted, 12), maxLines = 1)
						Spacer(GlanceModifier.height(8.dp))
						Row(verticalAlignment = Alignment.CenterVertically) {
							Control("skip_previous", palette.text, palette.layer1, "previous", pc)
							Spacer(GlanceModifier.width(8.dp))
							Control(if (media["playing"].bool) "pause" else "play", palette.onPrimary, palette.primary, "playPause", pc)
							Spacer(GlanceModifier.width(8.dp))
							Control("skip_next", palette.text, palette.layer1, "next", pc)
							Spacer(GlanceModifier.defaultWeight())
							Control("volume_minus", palette.text, palette.layer1, "volumeDown", pc)
							Spacer(GlanceModifier.width(8.dp))
							Control("volume_plus", palette.text, palette.layer1, "volumeUp", pc)
						}
					}
				}
			}
		}
	}
}

@Composable
private fun Control(icon: String, tint: Color, background: Color, action: String, pc: String, size: Dp = 38.dp) {
	Box(
		GlanceModifier.size(size).background(provider(background)).cornerRadius(size / 2).clickable(actionRunCallback<MediaAction>(actionParametersOf(MediaAction.name to action, MediaAction.pc to pc))),
		contentAlignment = Alignment.Center,
	) {
		Image(glyph(LocalContext.current, icon, size * 0.53f, tint), null, GlanceModifier.size(size * 0.53f))
	}
}

class MediaAction : ActionCallback {
	override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
		val app = context.applicationContext as App
		val one = app.link.of(parameters[pc]) ?: return
		when (val action = parameters[name] ?: return) {
			"volumeUp", "volumeDown" -> one.run("sound", "adjust", json("delta" to (if (action == "volumeUp") 1 else -1) * app.prefs.volumeStep.value / 100.0))
			"lock" -> one.run("session", "lock")
			"timer" -> one.run("timer", if (one.topic("timer").value["tracking"].bool) "pause" else "resume")
			else -> one.run("media", action)
		}
	}

	companion object {
		val name = ActionParameters.Key<String>("action")
		val pc = ActionParameters.Key<String>("pc")
	}
}

class MediaWidgetReceiver : GlanceAppWidgetReceiver() {
	override val glanceAppWidget = MediaWidget()

	override fun onEnabled(context: Context) {
		super.onEnabled(context)
		Widgets.refreshSubscriptions(context.applicationContext as App)
	}

	override fun onDisabled(context: Context) {
		super.onDisabled(context)
		Widgets.refreshSubscriptions(context.applicationContext as App)
	}
}

// ── status ─────────────────────────────────────────────────────────────────
class StatusWidget : GlanceAppWidget() {
	override val sizeMode = SizeMode.Exact

	override suspend fun provideGlance(context: Context, id: GlanceId) {
		val app = context.applicationContext as App
		provideContent {
			val palette by app.palette.collectAsState()
			val one = Widgets.linkFor(app, currentState(Widgets.PC))
			val connected by (one?.connection ?: MutableStateFlow(null)).collectAsState()
			val session by (one?.topic("session") ?: MutableStateFlow(null)).collectAsState()
			val timer by (one?.topic("timer") ?: MutableStateFlow(null)).collectAsState()
			val name = one?.pc?.name ?: "PC"
			val tracking = connected != null && app.on("qtrack") && timer["tracking"].bool
			val pc = one?.id.orEmpty()
			Surface(palette) {
				Row(GlanceModifier.fillMaxSize().clickable(openApp), verticalAlignment = Alignment.CenterVertically) {
					Box(GlanceModifier.size(10.dp).background(provider(if (connected != null) palette.success else palette.textSubtle)).cornerRadius(5.dp)) {}
					Spacer(GlanceModifier.width(10.dp))
					Column(GlanceModifier.defaultWeight()) {
						Text(name, style = label(palette.text, 16, bold = true), maxLines = 1)
						Text(
							when {
								connected == null -> "Not reachable"
								tracking -> "Tracking since ${java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(timer["startedAt"].long - (one?.clockOffset ?: 0L)))} · ${timer["description"].string}"
								session["locked"].bool -> "Locked"
								else -> "Connected"
							},
							style = label(palette.textMuted, 12), maxLines = 1,
						)
					}
					if (connected != null) {
						if (app.on("qtrack") && (tracking || timer["canResume"].bool || timer["paused"].bool)) {
							Control(if (tracking) "pause" else "timer_outline", palette.text, palette.layer1, "timer", pc)
							Spacer(GlanceModifier.width(8.dp))
						}
						// locked: the fingerprint; otherwise the lock
						if (session["locked"].bool && app.on("phone-unlock")) Box(
							GlanceModifier.size(38.dp).background(provider(palette.primary)).cornerRadius(19.dp).clickable(actionStartActivity(dev.pshell.app.service.Unlocks.intent(app, pc))),
							contentAlignment = Alignment.Center,
						) {
							Image(glyph(LocalContext.current, "fingerprint", 20.dp, palette.onPrimary), null, GlanceModifier.size(20.dp))
						} else if (session["canLock"].bool) Control("lock", if (session["locked"].bool) palette.onPrimary else palette.text, if (session["locked"].bool) palette.primary else palette.layer1, "lock", pc)
					}
				}
			}
		}
	}
}

class StatusWidgetReceiver : GlanceAppWidgetReceiver() {
	override val glanceAppWidget = StatusWidget()

	override fun onEnabled(context: Context) {
		super.onEnabled(context)
		Widgets.refreshSubscriptions(context.applicationContext as App)
	}

	override fun onDisabled(context: Context) {
		super.onDisabled(context)
		Widgets.refreshSubscriptions(context.applicationContext as App)
	}
}
