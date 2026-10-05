package dev.pshell.app.service

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import dev.pshell.app.App
import dev.pshell.app.MainActivity
import dev.pshell.app.link.LinkError
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.json
import dev.pshell.app.link.list
import dev.pshell.app.link.string
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Questions the PC asks the phone (scripts/phone/ask): a title, a text,
 * buttons, and fields to fill in. A question with only buttons, or with one
 * text field, is answered inside the notification; a larger form opens in
 * the app. The answer is { action, values }.
 */
object Asks {
	class Ask(val id: String, val request: JsonElement?) {
		val answer = CompletableDeferred<JsonObject>()
		val title get() = request["title"].string
		val body get() = request["body"].string
		val fields get() = request["fields"].list
		val actions get() = request["actions"].list
	}

	/** open questions, newest last; the app shows the form of the last one */
	val open = MutableStateFlow<List<Ask>>(emptyList())
	private var counter = 0
	private lateinit var app: App

	fun install(app: App) {
		this.app = app
		app.link.handle("phone.ask", "ask") { request -> ask(request) }
	}

	private suspend fun ask(request: JsonElement?): JsonElement {
		val ask = Ask("a${++counter}", request)
		open.value = open.value + ask
		notify(ask)
		val seconds = request["timeout"].int.takeIf { it > 0 } ?: 600
		try {
			return withTimeoutOrNull(seconds * 1000L) { ask.answer.await() } ?: throw LinkError("timeout", "Nobody answered")
		} finally {
			open.value = open.value - ask
			app.getSystemService(NotificationManager::class.java).cancel("ask", ask.id.hashCode())
		}
	}

	fun answer(id: String, action: String? = null, text: String? = null, values: Map<String, Any?> = emptyMap()) {
		val ask = open.value.firstOrNull { it.id == id } ?: return
		val filled = values.toMutableMap()
		// the notification's reply field answers the only text field
		if (text != null) ask.fields.firstOrNull()?.let { filled[it["id"].string] = text }
		ask.answer.complete(json("action" to (action ?: ask.actions.firstOrNull()?.get("id").string.ifEmpty { "ok" }), "values" to filled))
	}

	fun dismiss(id: String) {
		open.value.firstOrNull { it.id == id }?.answer?.completeExceptionally(LinkError("dismissed", "Dismissed on the phone"))
	}

	private fun notify(ask: Ask) {
		val code = ask.id.hashCode()
		val builder = Channels.builder(app, Channels.ASK)
			.setContentTitle(ask.title.ifEmpty { "Question from the PC" })
			.setContentText(ask.body)
			.setStyle(Notification.BigTextStyle().bigText(ask.body))
			.setCategory(Notification.CATEGORY_MESSAGE)
			.setOngoing(false)
			.setContentIntent(PendingIntent.getActivity(app, code, Intent(app, MainActivity::class.java).putExtra("ask", ask.id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
			.setDeleteIntent(Channels.action(app, Actions.ASK_DISMISS, code) { putExtra("ask", ask.id) })
		val fields = ask.fields
		val single = fields.size == 1 && fields[0]["type"].string.let { it == "text" || it.isEmpty() }
		when {
			fields.isEmpty() -> ask.actions.take(3).forEachIndexed { index, action ->
				builder.addAction(Notification.Action.Builder(null, action["label"].string, Channels.action(app, Actions.ASK_ANSWER, code + 1 + index) {
					putExtra("ask", ask.id)
					putExtra("action", action["id"].string)
				}).build())
			}
			single -> {
				val label = fields[0]["label"].string.ifEmpty { "Answer" }
				builder.addAction(
					Notification.Action.Builder(null, label, Channels.action(app, Actions.ASK_ANSWER, code + 1) { putExtra("ask", ask.id) })
						.addRemoteInput(RemoteInput.Builder("text").setLabel(label).build())
						.build(),
				)
			}
			else -> builder.addAction(Notification.Action.Builder(null, "Answer", PendingIntent.getActivity(app, code + 1, Intent(app, MainActivity::class.java).putExtra("ask", ask.id), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build())
		}
		app.getSystemService(NotificationManager::class.java).notify("ask", code, builder.build())
	}
}
