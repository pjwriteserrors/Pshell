package dev.pshell.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.R
import dev.pshell.app.link.LinkState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Keeps the app alive while a PC is paired, so the connection survives the
 * screen going off. Everything that works without the app being open hangs
 * here: the media controls, the phone's status, and what later steps add.
 */
class LinkService : Service() {
	private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
	private lateinit var media: MediaControls
	private lateinit var status: PhoneStatus

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onCreate() {
		super.onCreate()
		val app = application as App
		val manager = getSystemService(NotificationManager::class.java)
		manager.createNotificationChannel(NotificationChannel(CHANNEL, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
			description = "Shown while the app stays connected to the PC"
			setShowBadge(false)
		})
		startForeground(ID, notification(app.link.state.value), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
		scope.launch {
			app.link.state.collect { state ->
				if (state is LinkState.Unpaired) stopSelf() else manager.notify(ID, notification(state))
			}
		}
		media = MediaControls(this, app, scope).also { it.start() }
		status = PhoneStatus(this, app).also { it.start() }
	}

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		intent?.action?.let { media.onAction(it) }
		return START_STICKY
	}

	override fun onDestroy() {
		media.stop()
		status.stop()
		scope.cancel()
		super.onDestroy()
	}

	private fun notification(state: LinkState): Notification {
		val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
		val text = when (state) {
			is LinkState.Connected -> "Connected to ${state.pc.name}"
			else -> "Looking for the PC"
		}
		return Notification.Builder(this, CHANNEL)
			.setSmallIcon(R.drawable.ic_stat)
			.setContentTitle(text)
			.setContentIntent(open)
			.setOngoing(true)
			.setShowWhen(false)
			.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
			.build()
	}

	companion object {
		private const val CHANNEL = "link"
		private const val ID = 1

		fun start(context: Context) {
			val app = context.applicationContext as App
			if (app.link.pcs.list.value.isEmpty()) return
			runCatching { context.startForegroundService(Intent(context, LinkService::class.java)) }
		}
	}
}

/** After a restart of the phone or an update of the app, the link comes back by itself. */
class BootReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) = LinkService.start(context)
}
