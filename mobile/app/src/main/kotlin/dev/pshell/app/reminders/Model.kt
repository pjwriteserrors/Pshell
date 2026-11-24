package dev.pshell.app.reminders

import dev.pshell.app.link.bool
import dev.pshell.app.link.get
import dev.pshell.app.link.int
import dev.pshell.app.link.list
import dev.pshell.app.link.long
import dev.pshell.app.link.map
import dev.pshell.app.link.present
import dev.pshell.app.link.string
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** The reminders of pshell-core (docs/core.md "Reminders") as the phone keeps them. */
data class Repeat(val every: String, val n: Int = 1, val days: List<Int> = emptyList(), val until: Long? = null) {
	fun toJson(): JsonObject = JsonObject(buildMap {
		put("every", JsonPrimitive(every))
		put("n", JsonPrimitive(n))
		if (every == "week" && days.isNotEmpty()) put("days", JsonArray(days.map { JsonPrimitive(it) }))
		if (until != null) put("until", JsonPrimitive(until))
	})

	companion object {
		fun of(data: JsonElement?): Repeat? {
			val every = data["every"].string
			if (every !in EVERY) return null
			return Repeat(every, data["n"].int.coerceAtLeast(1), data["days"].list.map { it.int }.filter { it in 1..7 }.distinct().sorted(), data["until"].takeIf { it.present }?.long)
		}

		val EVERY = listOf("day", "week", "month", "year")
	}
}

data class Reminder(
	val id: String,
	val title: String,
	val note: String = "",
	/** epoch seconds; null for one that only a trigger fires */
	val at: Long? = null,
	val allDay: Boolean = false,
	val repeat: Repeat? = null,
	val level: String = "normal",
	val escalateMin: Int = 10,
	val trigger: String = "time",
	val state: String = "open",
	val snoozedUntil: Long? = null,
	val next: Long? = null,
	/** fired and not acknowledged */
	val pending: List<Long> = emptyList(),
	val updated: Long = 0,
) {
	val open get() = state == "open"

	fun toJson(): JsonObject = JsonObject(mapOf(
		"id" to JsonPrimitive(id), "title" to JsonPrimitive(title), "note" to JsonPrimitive(note),
		"at" to (at?.let { JsonPrimitive(it) } ?: JsonNull), "all_day" to JsonPrimitive(allDay),
		"repeat" to (repeat?.toJson() ?: JsonNull), "level" to JsonPrimitive(level), "escalate_min" to JsonPrimitive(escalateMin),
		"trigger" to JsonPrimitive(trigger), "state" to JsonPrimitive(state),
		"snoozed_until" to (snoozedUntil?.let { JsonPrimitive(it) } ?: JsonNull), "next" to (next?.let { JsonPrimitive(it) } ?: JsonNull),
		"pending" to JsonArray(pending.map { JsonPrimitive(it) }), "updated" to JsonPrimitive(updated),
	))

	companion object {
		fun of(data: JsonElement?): Reminder? {
			val id = data["id"].string
			if (id.isEmpty()) return null
			return Reminder(
				id = id,
				title = data["title"].string,
				note = data["note"].string,
				at = data["at"].takeIf { it.present }?.long,
				allDay = data["all_day"].bool,
				repeat = Repeat.of(data["repeat"]),
				level = data["level"].string.takeIf { it in LEVELS } ?: "normal",
				escalateMin = if (data["escalate_min"].present) data["escalate_min"].int else 10,
				trigger = data["trigger"].string.ifEmpty { "time" },
				state = data["state"].string.ifEmpty { "open" },
				snoozedUntil = data["snoozed_until"].takeIf { it.present }?.long,
				next = data["next"].takeIf { it.present }?.long,
				pending = data["pending"].list.map { it.long }.filter { it > 0 },
				updated = data["updated"].long,
			)
		}
	}
}

/** Something core knows that reminds by itself: a calendar alarm, an expense due. Read only. */
data class SourceItem(val source: String, val key: String, val title: String, val at: Long, val level: String, val url: String) {
	fun toJson(): JsonObject = JsonObject(mapOf(
		"source" to JsonPrimitive(source), "key" to JsonPrimitive(key), "title" to JsonPrimitive(title),
		"at" to JsonPrimitive(at), "level" to JsonPrimitive(level), "url" to JsonPrimitive(url),
	))

	companion object {
		fun of(data: JsonElement?) = SourceItem(data["source"].string, data["key"].string, data["title"].string, data["at"].long, data["level"].string.ifEmpty { "normal" }, data["url"].string)
	}
}

/** What `GET /api/reminders` answers. */
data class Snapshot(val reminders: List<Reminder> = emptyList(), val sources: List<SourceItem> = emptyList(), val levels: Map<String, String> = emptyMap()) {
	fun toJson(): JsonObject = JsonObject(mapOf(
		"reminders" to JsonArray(reminders.map { it.toJson() }),
		"sources" to JsonArray(sources.map { it.toJson() }),
		"levels" to JsonObject(levels.mapValues { JsonPrimitive(it.value) }),
	))

	companion object {
		fun of(data: JsonElement?) = Snapshot(
			data["reminders"].list.mapNotNull { Reminder.of(it) },
			data["sources"].list.map { SourceItem.of(it) },
			data["levels"].map.mapValues { it.value.string },
		)
	}
}

/** What `POST /api/reminders/parse` makes of a line. */
/** [level] null: none was asked for, core takes the member's level for own reminders. */
data class Parsed(val title: String, val at: Long?, val allDay: Boolean, val repeat: Repeat?, val level: String?, val trigger: String) {
	fun body(): JsonObject = JsonObject(buildMap {
		put("title", JsonPrimitive(title))
		put("at", at?.let { JsonPrimitive(it) } ?: JsonNull)
		put("all_day", JsonPrimitive(allDay))
		put("repeat", repeat?.toJson() ?: JsonNull)
		if (level != null) put("level", JsonPrimitive(level))
		put("trigger", JsonPrimitive(trigger))
	})

	companion object {
		fun of(data: JsonElement?) = Parsed(
			data["title"].string, data["at"].takeIf { it.present }?.long, data["all_day"].bool, Repeat.of(data["repeat"]),
			data["level"].string.takeIf { it in LEVELS }, data["trigger"].string.ifEmpty { "time" },
		)
	}
}

val LEVELS = listOf("quiet", "normal", "important", "fullscreen")
val TRIGGERS = listOf("time", "unlock", "leave_home", "arrive_home", "washer_done", "qtrack_stop", "game_end")
