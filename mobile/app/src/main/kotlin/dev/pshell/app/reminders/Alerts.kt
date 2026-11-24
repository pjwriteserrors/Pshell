package dev.pshell.app.reminders

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import dev.pshell.app.R
import java.time.Instant
import java.time.format.DateTimeFormatter

/** Notifications, alarms and their buttons for reminders: one channel per level (quiet has none). */
object Alerts {
	const val NORMAL = "reminders"
	const val IMPORTANT = "reminders_important"
	const val ALARM = "reminders_alarm"
	private const val TAG = "reminder"

	const val FIRE = "dev.pshell.app.REMINDER_FIRE"
	const val ESCALATE = "dev.pshell.app.REMINDER_ESCALATE"
	const val DONE = "dev.pshell.app.REMINDER_DONE"
	const val SNOOZE = "dev.pshell.app.REMINDER_SNOOZE"

	private val TIME = DateTimeFormatter.ofPattern("HH:mm")
	private val DAY = DateTimeFormatter.ofPattern("EEE d. MMM HH:mm")

	fun channels(context: Context) {
		val manager = context.getSystemService(NotificationManager::class.java)
		manager.createNotificationChannel(NotificationChannel(NORMAL, "Reminders", NotificationManager.IMPORTANCE_DEFAULT))
		manager.createNotificationChannel(NotificationChannel(IMPORTANT, "Important reminders", NotificationManager.IMPORTANCE_HIGH).apply {
			enableVibration(true)
		})
		manager.createNotificationChannel(NotificationChannel(ALARM, "Reminder alarms", NotificationManager.IMPORTANCE_HIGH).apply {
			setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
			enableVibration(true)
			vibrationPattern = longArrayOf(0, 600, 400, 600, 400, 600)
			setBypassDnd(true)
			lockscreenVisibility = Notification.VISIBILITY_PUBLIC
		})
	}

	/** Whether the phone may put a reminder over the screen (Android 14 asks the user). */
	fun fullScreenAllowed(context: Context): Boolean =
		Build.VERSION.SDK_INT < 34 || context.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()

	fun exactAllowed(context: Context): Boolean =
		Build.VERSION.SDK_INT < 31 || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

	fun notificationsAllowed(context: Context): Boolean = context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()

	private fun code(vararg parts: Any) = parts.joinToString(":").hashCode()

	private fun receiver(context: Context, action: String, id: String, occurrence: Long, fill: Intent.() -> Unit = {}) =
		Intent(context, ReminderReceiver::class.java).setAction(action).putExtra("id", id).putExtra("occurrence", occurrence).apply(fill)

	fun alertIntent(context: Context, id: String, occurrence: Long): Intent =
		Intent(context, ReminderAlertActivity::class.java)
			.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION or Intent.FLAG_ACTIVITY_CLEAR_TOP)
			.putExtra("id", id).putExtra("occurrence", occurrence)

	fun when_(reminder: Reminder, occurrence: Long): String {
		val time = Instant.ofEpochSecond(occurrence).atZone(Reminders.zone)
		return if (time.toLocalDate() == java.time.LocalDate.now(Reminders.zone)) time.format(TIME) else time.format(DAY)
	}

	fun show(context: Context, reminder: Reminder, shown: Dedupe.Shown, alert: Boolean) {
		val level = shown.level
		if (level == "quiet") return
		val manager = context.getSystemService(NotificationManager::class.java)
		val id = reminder.id
		val occurrence = shown.occurrence
		val open = PendingIntent.getActivity(context, code("open", id), alertIntent(context, id, occurrence), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
		fun action(label: String, action: String, snooze: String = "") = Notification.Action.Builder(
			Icon.createWithResource(context, R.drawable.ic_stat), label,
			PendingIntent.getBroadcast(context, code(action, id, snooze), receiver(context, action, id, occurrence) { putExtra("snooze", snooze) }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
		).build()
		val channel = when (level) { "fullscreen" -> ALARM; "important" -> IMPORTANT; else -> NORMAL }
		val text = listOf(if (reminder.trigger == "time" || shown.escalated) when_(reminder, occurrence) else "", reminder.note).filter { it.isNotEmpty() }.joinToString(" · ")
		val builder = Notification.Builder(context, channel)
			.setSmallIcon(R.drawable.ic_stat)
			.setContentTitle(reminder.title)
			.setContentText(text)
			.setStyle(Notification.BigTextStyle().bigText(text))
			.setWhen(occurrence * 1000)
			.setShowWhen(true)
			.setContentIntent(open)
			.setOnlyAlertOnce(!alert)
			.setCategory(if (level == "fullscreen") Notification.CATEGORY_ALARM else Notification.CATEGORY_REMINDER)
			.addAction(action("Done", DONE))
			.addAction(action(Reminders.Snooze.Minutes5.label, SNOOZE, Reminders.Snooze.Minutes5.name))
			.addAction(action(Reminders.Snooze.Hour.label, SNOOZE, Reminders.Snooze.Hour.name))
		when (level) {
			"normal" -> builder.setAutoCancel(true)
			"important" -> builder.setOngoing(true)
			"fullscreen" -> builder.setOngoing(true).setFullScreenIntent(open, true).setVisibility(Notification.VISIBILITY_PUBLIC)
		}
		manager.notify(TAG, id.hashCode(), builder.build())
		// over the screen at once while the phone is in use; the full-screen intent covers the rest
		if (level == "fullscreen" && alert) runCatching { context.startActivity(alertIntent(context, id, occurrence)) }
	}

	fun cancel(context: Context, id: String) {
		context.getSystemService(NotificationManager::class.java).cancel(TAG, id.hashCode())
	}

	// ── alarms ─────────────────────────────────────────────────────────────
	private fun firePending(context: Context, id: String, occurrence: Long, flags: Int) =
		PendingIntent.getBroadcast(context, code("fire", id), receiver(context, FIRE, id, occurrence), PendingIntent.FLAG_IMMUTABLE or flags)

	fun setAlarm(context: Context, due: Schedule.Due, level: String) {
		val alarms = context.getSystemService(AlarmManager::class.java)
		val pending = firePending(context, due.id, due.occurrence, PendingIntent.FLAG_UPDATE_CURRENT)
		val at = due.at * 1000
		if (!exactAllowed(context)) return alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
		if (level == "fullscreen") {
			val show = PendingIntent.getActivity(context, code("show", due.id), alertIntent(context, due.id, due.occurrence), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
			alarms.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), pending)
		} else alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
	}

	fun unsetAlarm(context: Context, id: String) {
		firePending(context, id, 0, PendingIntent.FLAG_NO_CREATE)?.let { context.getSystemService(AlarmManager::class.java).cancel(it) }
	}

	fun setEscalation(context: Context, id: String, occurrence: Long, at: Long) {
		val alarms = context.getSystemService(AlarmManager::class.java)
		val pending = PendingIntent.getBroadcast(context, code("escalate", id), receiver(context, ESCALATE, id, occurrence), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
		if (exactAllowed(context)) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at * 1000, pending)
		else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at * 1000, pending)
	}

	fun unsetEscalation(context: Context, id: String) {
		PendingIntent.getBroadcast(context, code("escalate", id), receiver(context, ESCALATE, id, 0), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE)
			?.let { context.getSystemService(AlarmManager::class.java).cancel(it) }
	}
}

/** Alarms, notification buttons, and what makes the alarms be set again (boot, update, time zone, the exact alarm permission). */
class ReminderReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		val id = intent.getStringExtra("id").orEmpty()
		val occurrence = intent.getLongExtra("occurrence", 0)
		when (intent.action) {
			Alerts.FIRE -> Reminders.alarm(id, occurrence)
			Alerts.ESCALATE -> Reminders.escalate(id, occurrence)
			Alerts.DONE -> Reminders.ack(id, occurrence)
			Alerts.SNOOZE -> Reminders.snooze(id, runCatching { Reminders.Snooze.valueOf(intent.getStringExtra("snooze").orEmpty()) }.getOrDefault(Reminders.Snooze.Minutes5))
			else -> Reminders.reschedule() // boot, package replaced, time zone, clock, exact alarms allowed
		}
	}
}
