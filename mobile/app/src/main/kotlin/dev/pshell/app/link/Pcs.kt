package dev.pshell.app.link

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray

/** A paired PC: [id] is the fingerprint of its certificate, the only thing trusted. */
data class Pc(
	val id: String,
	val name: String,
	val port: Int,
	/** where it was when it was paired */
	val addresses: List<String>,
	/** entered by hand: a VPN name, a fixed address */
	val manual: List<String> = emptyList(),
	/** where it answered last */
	val last: String = "",
	/** its network cards, to wake it over the LAN */
	val mac: List<String> = emptyList(),
) {
	fun toJson() = json("id" to id, "name" to name, "port" to port, "addresses" to addresses, "manual" to manual, "last" to last, "mac" to mac)

	companion object {
		fun from(element: kotlinx.serialization.json.JsonElement) = Pc(
			id = element["id"].string,
			name = element["name"].string,
			port = element["port"].int,
			addresses = element["addresses"].list.map { it.string },
			manual = element["manual"].list.map { it.string },
			last = element["last"].string,
			mac = element["mac"].list.map { it.string },
		)
	}
}

/** The paired PCs, kept in the app's private preferences. */
class Pcs(context: Context) {
	private val prefs = context.getSharedPreferences("pcs", Context.MODE_PRIVATE)
	private val state = MutableStateFlow(load())
	val list: StateFlow<List<Pc>> = state

	/** the PC the app shows while it is connected */
	val preferredFlow = MutableStateFlow(prefs.getString("preferred", "") ?: "")
	var preferred: String
		get() = preferredFlow.value
		set(value) {
			preferredFlow.value = value
			prefs.edit().putString("preferred", value).apply()
		}

	private fun load(): List<Pc> = runCatching {
		Json.parseToJsonElement(prefs.getString("list", "[]") ?: "[]").list.map(Pc::from).filter { it.id.isNotEmpty() }
	}.getOrDefault(emptyList())

	@Synchronized
	fun put(pc: Pc) {
		state.value = state.value.filter { it.id != pc.id } + pc
		persist()
	}

	@Synchronized
	fun update(id: String, change: (Pc) -> Pc) {
		state.value = state.value.map { if (it.id == id) change(it) else it }
		persist()
	}

	@Synchronized
	fun remove(id: String) {
		state.value = state.value.filter { it.id != id }
		persist()
	}

	private fun persist() {
		prefs.edit().putString("list", JsonArray(state.value.map { it.toJson() }).toString()).apply()
	}

	/** preferred first */
	fun ordered(): List<Pc> = state.value.sortedByDescending { it.id == preferred }
}
