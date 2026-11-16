package dev.pshell.app.nas

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.core.content.ContextCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Music from the NAS, in the background: a media session of its own (the
 * shade, the lock screen, headphones' buttons), streamed with the token.
 * The app talks to it through a MediaController; a song is known by its NAS
 * path (the media id), its URL is made here.
 */
@OptIn(UnstableApi::class)
class MusicService : MediaSessionService() {
	private var session: MediaSession? = null

	override fun onCreate() {
		super.onCreate()
		val player = ExoPlayer.Builder(this)
			.setMediaSourceFactory(DefaultMediaSourceFactory(OkHttpDataSource.Factory(Nas.client)))
			.setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
			.setHandleAudioBecomingNoisy(true)
			.build()
		session = MediaSession.Builder(this, player).setId("nas")
			// the cover (the NAS's thumbnail) comes with the token too
			.setBitmapLoader(androidx.media3.datasource.DataSourceBitmapLoader(androidx.media3.datasource.DataSourceBitmapLoader.DEFAULT_EXECUTOR_SERVICE.get(), OkHttpDataSource.Factory(Nas.client)))
			.setCallback(object : MediaSession.Callback {
			// the controller's items carry their path only: the URL is made here
			override fun onAddMediaItems(mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>): ListenableFuture<MutableList<MediaItem>> =
				Futures.immediateFuture(mediaItems.map { Music.resolved(it) }.toMutableList())
		}).build()
	}

	override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

	override fun onTaskRemoved(rootIntent: android.content.Intent?) {
		val player = session?.player
		if (player == null || !player.playWhenReady || player.mediaItemCount == 0) stopSelf()
	}

	override fun onDestroy() {
		session?.run {
			player.release()
			release()
		}
		session = null
		super.onDestroy()
	}
}

object Music {
	/** what plays: its path, title, whether it plays */
	data class Now(val path: String = "", val title: String = "", val playing: Boolean = false, val index: Int = 0, val count: Int = 0)

	val now = MutableStateFlow(Now())
	private var controller: MediaController? = null
	private var pending: ListenableFuture<MediaController>? = null

	fun item(path: String, title: String = path.substringAfterLast('/').substringBeforeLast('.')): MediaItem =
		MediaItem.Builder().setMediaId(path).setMediaMetadata(
			MediaMetadata.Builder().setTitle(title).setArtist(path.substringBeforeLast('/').substringAfterLast('/')).setArtworkUri(Uri.parse(Nas.thumbUrl(path))).build(),
		).build()

	fun resolved(item: MediaItem): MediaItem = item.buildUpon().setUri(Nas.fileUrl(item.mediaId)).build()

	private fun connect(context: Context, then: (MediaController) -> Unit) {
		controller?.let { return then(it) }
		val future = pending ?: MediaController.Builder(context, SessionToken(context, ComponentName(context, MusicService::class.java))).buildAsync().also { pending = it }
		future.addListener({
			val ready = runCatching { future.get() }.getOrNull() ?: return@addListener
			if (controller == null) {
				controller = ready
				ready.addListener(object : Player.Listener {
					override fun onEvents(player: Player, events: Player.Events) = publish(player)
				})
			}
			then(ready)
		}, ContextCompat.getMainExecutor(context))
	}

	private fun publish(player: Player) {
		val item = player.currentMediaItem
		now.value = Now(item?.mediaId.orEmpty(), item?.mediaMetadata?.title?.toString().orEmpty(), player.isPlaying, player.currentMediaItemIndex, player.mediaItemCount)
	}

	/** Plays [paths] from [start] on. */
	fun play(context: Context, paths: List<String>, start: Int) = connect(context.applicationContext) { player ->
		player.setMediaItems(paths.map { item(it) }, start, 0)
		player.prepare()
		player.play()
	}

	fun toggle(context: Context) = connect(context.applicationContext) { if (it.isPlaying) it.pause() else it.play() }
	fun next(context: Context) = connect(context.applicationContext) { it.seekToNextMediaItem() }
	fun previous(context: Context) = connect(context.applicationContext) { it.seekToPreviousMediaItem() }
	fun stop(context: Context) = connect(context.applicationContext) {
		it.stop()
		it.clearMediaItems()
	}
}
