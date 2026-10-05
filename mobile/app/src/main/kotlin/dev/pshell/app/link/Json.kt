package dev.pshell.app.link

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

// Topics are read as JSON trees: a field the app does not know is ignored,
// one the PC does not send reads as its default.

operator fun JsonElement?.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)?.takeUnless { it is JsonNull }

operator fun JsonElement?.get(index: Int): JsonElement? = (this as? JsonArray)?.getOrNull(index)?.takeUnless { it is JsonNull }

val JsonElement?.string: String get() = (this as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content ?: ""

val JsonElement?.stringOrNull: String? get() = (this as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content

val JsonElement?.double: Double get() = (this as? JsonPrimitive)?.doubleOrNull ?: 0.0

val JsonElement?.float: Float get() = double.toFloat()

val JsonElement?.long: Long get() = (this as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() } ?: 0L

val JsonElement?.int: Int get() = long.toInt()

val JsonElement?.bool: Boolean get() = (this as? JsonPrimitive)?.booleanOrNull ?: false

val JsonElement?.list: List<JsonElement> get() = (this as? JsonArray) ?: emptyList()

val JsonElement?.map: Map<String, JsonElement> get() = (this as? JsonObject) ?: emptyMap()

val JsonElement?.present: Boolean get() = this != null && this !is JsonNull

fun Any?.toJson(): JsonElement = when (this) {
	null -> JsonNull
	is JsonElement -> this
	is String -> JsonPrimitive(this)
	is Number -> JsonPrimitive(this)
	is Boolean -> JsonPrimitive(this)
	is Map<*, *> -> JsonObject(entries.associate { it.key.toString() to it.value.toJson() })
	is Iterable<*> -> JsonArray(map { it.toJson() })
	else -> JsonPrimitive(toString())
}

fun json(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.associate { it.first to it.second.toJson() })

val NoArgs = JsonObject(emptyMap())
