package dev.pshell.app.zepp

import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * The watch's raw samples on the phone (fetched, or imported from a Gadgetbridge
 * database export), and the days and nights built from them – the same as
 * scripts/amazfit/zepp/healthbuild.py, in the format of the PC's health history.
 */
class HealthStore(private val file: File) {
	private val kinds = HashMap<String, java.util.TreeMap<Long, JSONObject>>()
	val since = HashMap<String, Long>()
	// what was built: by date
	val days = java.util.TreeMap<String, JSONObject>()
	val nights = java.util.TreeMap<String, JSONObject>()

	init {
		runCatching {
			val o = JSONObject(file.readText())
			o.optJSONObject("kinds")?.let { k -> for (kind in k.keys()) { val a = k.getJSONArray(kind); val m = java.util.TreeMap<Long, JSONObject>(); for (i in 0 until a.length()) a.getJSONObject(i).let { m[it.getLong("t")] = it }; kinds[kind] = m } }
			o.optJSONObject("since")?.let { s -> for (k in s.keys()) since[k] = s.getLong(k) }
			o.optJSONObject("days")?.let { d -> for (k in d.keys()) days[k] = d.getJSONObject(k) }
			o.optJSONObject("nights")?.let { d -> for (k in d.keys()) nights[k] = d.getJSONObject(k) }
		}
	}

	private val zone get() = ZoneId.systemDefault()
	private fun dayOf(t: Long) = Instant.ofEpochSecond(t).atZone(zone).toLocalDate().toString()
	private fun midnight(key: String) = LocalDate.parse(key).atStartOfDay(zone).toEpochSecond()

	fun add(kind: String, samples: List<JSONObject>): Set<String> {
		val m = kinds.getOrPut(kind) { java.util.TreeMap() }
		val dates = HashSet<String>()
		for (s in samples) {
			val t = s.getLong("t")
			m[t] = s
			dates.add(dayOf(s.optLong("wake", t)))
			if (kind == "sleep") dates.add(dayOf(s.optLong("bed", t)))
		}
		samples.maxOfOrNull { it.getLong("t") }?.let { since[kind] = maxOf(since[kind] ?: 0, it + 60) }
		return dates
	}

	fun save() {
		val oldest = System.currentTimeMillis() / 1000 - KEEP_DAYS * 86400L
		val k = JSONObject()
		for ((kind, m) in kinds) { m.headMap(oldest).clear(); k.put(kind, JSONArray(m.values)) }
		val cut = LocalDate.now().minusDays(KEEP_DAYS.toLong()).toString()
		days.headMap(cut).clear(); nights.headMap(cut).clear()
		val tmp = File(file.path + ".tmp")
		tmp.writeText(JSONObject().put("kinds", k).put("since", JSONObject(since as Map<*, *>)).put("days", JSONObject(days as Map<*, *>)).put("nights", JSONObject(nights as Map<*, *>)).toString())
		tmp.renameTo(file)
	}

	private fun between(kind: String, start: Long, end: Long): List<JSONObject> = kinds[kind]?.subMap(start, end)?.values?.toList() ?: emptyList()

	private fun means(samples: List<JSONObject>, start: Long, slot: Int, count: Int, value: (JSONObject) -> Double?, keep: (JSONObject) -> Boolean = { true }): JSONArray {
		val sums = DoubleArray(count); val ns = IntArray(count)
		for (s in samples) {
			val i = ((s.getLong("t") - start) / slot).toInt()
			val v = value(s)
			if (i in 0 until count && v != null && keep(s)) { sums[i] += v; ns[i]++ }
		}
		return JSONArray((0 until count).map { if (ns[it] > 0) Math.round(sums[it] / ns[it] * 10) / 10.0 else 0 })
	}

	private fun buildDay(key: String): JSONObject? {
		val start = midnight(key)
		val end = start + 86400
		val act = between("activity", start, end)
		val worn = act.filter { it.getInt("k") != 115 && it.getInt("k") != 118 }.map { it.getLong("t") / 60 }.toHashSet()
		val hr = { s: JSONObject -> s.getInt("h").takeIf { it in 1..254 }?.toDouble() }
		val day = JSONObject().put("date", key)
		if (act.isNotEmpty()) {
			day.put("steps", act.sumOf { it.getInt("s") })
			day.put("heart", means(act, start, 600, 144, hr))
			val beats = act.filter { hr(it) != null }
			beats.maxByOrNull { it.getInt("h") }?.let { day.put("max", it.getInt("h")).put("maxAt", it.getLong("t")) }
			beats.lastOrNull()?.let { day.put("last", it.getInt("h")) }
			day.put("active", act.count { it.getInt("s") > 0 }).put("worn", worn.size)
		}
		val resting = between("resting", start, end)
		if (resting.isNotEmpty()) day.put("resting", resting.last().getInt("v"))
		else day.optJSONArray("heart")?.let { h -> val v = (0 until h.length()).map { h.getDouble(it) }.filter { it > 0 }.sorted(); if (v.isNotEmpty()) day.put("resting", Math.round(v[v.size / 10])) }
		val stress = between("stress", start, end)
		if (stress.isNotEmpty()) day.put("stress", means(stress, start, 3600, 24, { it.getDouble("v") })).put("stressNow", stress.last().getInt("v")).put("stressDay", Math.round(stress.sumOf { it.getDouble("v") } / stress.size))
		val spo2 = between("spo2", start, end)
		if (spo2.isNotEmpty()) day.put("oxygen", means(spo2, start, 3600, 24, { it.getDouble("v") })).put("oxygenNow", spo2.last().getInt("v"))
		val temp = between("temperature", start, end)
		if (temp.isNotEmpty()) day.put("temperature", means(temp, start, 1800, 48, { it.getDouble("v") }) { it.getLong("t") / 60 in worn })
		val pai = between("pai", start, end + 3600)
		if (pai.isNotEmpty()) pai.last().let { day.put("pai", Math.round(it.getDouble("total"))).put("paiToday", Math.round(it.getDouble("today"))).put("paiDay", Math.round(it.getDouble("total"))) }
		val hrv = between("hrv", start, end)
		if (hrv.isNotEmpty()) day.put("hrv", Math.round(hrv.sumOf { it.getDouble("v") } / hrv.size))
		day.put("at", System.currentTimeMillis() / 1000)
		return if (day.length() > 2) day else null
	}

	private fun nightOf(s: JSONObject): JSONObject {
		val bed = s.getLong("bed"); val wake = s.getLong("wake")
		val st = s.getJSONArray("stages")
		val stages = JSONArray((0 until st.length()).map { st.getJSONArray(it) }.sortedBy { it.getLong(1) }.map { JSONArray().put(it.getString(0)).put(Math.round((it.getLong(1) - bed) / 60.0)).put(Math.round((it.getLong(2) - bed) / 60.0)) })
		val br = between("breathing", bed, wake)
		val total = s.getInt("light") + s.getInt("deep") + s.getInt("rem")
		return JSONObject().put("date", dayOf(wake)).put("bed", bed).put("wake", wake).put("total", if (total > 0) total else ((wake - bed) / 60 - s.getInt("awake")).toInt())
			.put("score", s.getInt("score")).put("deep", s.getInt("deep")).put("light", s.getInt("light")).put("rem", s.getInt("rem")).put("awake", s.getInt("awake"))
			.put("stages", stages).put("naps", JSONArray()).put("avgHr", s.getInt("avgHr"))
			.put("breathing", if (br.isNotEmpty()) Math.round(br.sumOf { it.getDouble("v") } / br.size * 10) / 10.0 else 0)
	}

	private fun nightsFromActivity(start: Long, end: Long): List<JSONObject> {
		val act = between("activity", start, end).filter { it.getInt("k") == 120 }
		val runs = ArrayList<MutableList<JSONObject>>()
		for (s in act) { if (runs.isEmpty() || s.getLong("t") - runs.last().last().getLong("t") > 1800) runs.add(ArrayList()); runs.last().add(s) }
		return runs.filter { it.size >= 90 }.map { run ->
			val bed = run.first().getLong("t"); val wake = run.last().getLong("t") + 60
			val sums = HashMap<String, Int>()
			val stages = JSONArray()
			var last: JSONArray? = null
			for (s in run) {
				val kind = if (s.getInt("r") and 127 > 55) "rem" else if (s.getInt("d") and 127 > 42) "deep" else "light"
				val m = ((s.getLong("t") - bed) / 60).toInt()
				sums[kind] = (sums[kind] ?: 0) + 1
				if (last != null && last.getString(0) == kind && last.getInt(2) == m) last.put(2, m + 1) else { last = JSONArray().put(kind).put(m).put(m + 1); stages.put(last) }
			}
			JSONObject().put("date", dayOf(wake)).put("bed", bed).put("wake", wake).put("total", (sums["light"] ?: 0) + (sums["deep"] ?: 0) + (sums["rem"] ?: 0)).put("score", 0)
				.put("deep", sums["deep"] ?: 0).put("light", sums["light"] ?: 0).put("rem", sums["rem"] ?: 0).put("awake", 0).put("stages", stages).put("naps", JSONArray()).put("estimated", true)
		}
	}

	/** Builds the given dates again; → (days, nights) that changed, for the PC. */
	fun build(dates: Set<String>): Pair<List<JSONObject>, List<JSONObject>> {
		val newDays = ArrayList<JSONObject>(); val newNights = ArrayList<JSONObject>()
		for (key in dates.sorted()) {
			buildDay(key)?.let { days[key] = it; newDays.add(it) }
			val start = midnight(key) - 12 * 3600; val end = midnight(key) + 18 * 3600
			val sessions = kinds["sleep"]?.values?.filter { it.getLong("wake") in start until end } ?: emptyList()
			val night = sessions.maxByOrNull { it.getInt("light") + it.getInt("deep") + it.getInt("rem") }?.let(::nightOf)
				?: nightsFromActivity(start, end).filter { it.getString("date") == key }.maxByOrNull { it.getInt("total") }
			if (night != null) { nights[key] = night; newNights.add(night) }
		}
		return newDays to newNights
	}

	/** Days and nights from the PC (the topic "health"): taken where newer. */
	fun merge(view: JSONObject) {
		view.optJSONArray("nights")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { n -> val old = nights[n.getString("date")]; if (old == null || !(n.optBoolean("estimated") && !old.optBoolean("estimated"))) nights[n.getString("date")] = n } }
		val today = view.optJSONObject("today")
		if (today != null && today.has("date")) { val old = days[today.getString("date")]; if (old == null || today.optLong("at") >= old.optLong("at")) days[today.getString("date")] = today }
	}

	/** Reads a Gadgetbridge database export (read only); → the dates it brought. */
	fun importGadgetbridge(path: String): Set<String> {
		val db = SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.OPEN_READONLY)
		val dates = HashSet<String>()
		db.use {
			val ids = it.rawQuery("SELECT _id FROM DEVICE WHERE NAME LIKE '%Active%' OR NAME LIKE 'Amazfit%'", null).use { c -> buildList { while (c.moveToNext()) add(c.getLong(0)) } }
			if (ids.isEmpty()) return dates
			val inIds = ids.joinToString(",")
			fun rows(sql: String, conv: (android.database.Cursor) -> JSONObject) = runCatching { it.rawQuery(sql, null).use { c -> buildList { while (c.moveToNext()) add(conv(c)) } } }.getOrDefault(emptyList())
			fun o(vararg p: Pair<String, Any>) = JSONObject().apply { p.forEach { x -> put(x.first, x.second) } }
			dates += add("activity", rows("SELECT TIMESTAMP, RAW_KIND, RAW_INTENSITY, STEPS, HEART_RATE, SLEEP, DEEP_SLEEP, REM_SLEEP FROM HUAMI_EXTENDED_ACTIVITY_SAMPLE WHERE DEVICE_ID IN ($inIds)") { c ->
				o("t" to c.getLong(0), "k" to c.getInt(1), "i" to c.getInt(2), "s" to c.getInt(3), "h" to c.getInt(4), "sl" to c.getInt(5), "d" to c.getInt(6), "r" to c.getInt(7)) })
			for ((kind, sql) in listOf(
				"stress" to "SELECT TIMESTAMP, STRESS FROM HUAMI_STRESS_SAMPLE", "spo2" to "SELECT TIMESTAMP, SPO2 FROM HUAMI_SPO2_SAMPLE",
				"resting" to "SELECT TIMESTAMP, HEART_RATE FROM HUAMI_HEART_RATE_RESTING_SAMPLE", "hrv" to "SELECT TIMESTAMP, VALUE FROM GENERIC_HRV_VALUE_SAMPLE",
				"breathing" to "SELECT TIMESTAMP, RATE FROM HUAMI_SLEEP_RESPIRATORY_RATE_SAMPLE", "temperature" to "SELECT TIMESTAMP, TEMPERATURE FROM GENERIC_TEMPERATURE_SAMPLE",
			)) dates += add(kind, rows("$sql WHERE DEVICE_ID IN ($inIds)") { c -> o("t" to c.getLong(0) / 1000, "v" to c.getDouble(1)) })
			dates += add("pai", rows("SELECT TIMESTAMP, PAI_LOW, PAI_MODERATE, PAI_HIGH, TIME_LOW, TIME_MODERATE, TIME_HIGH, PAI_TODAY, PAI_TOTAL FROM HUAMI_PAI_SAMPLE WHERE DEVICE_ID IN ($inIds)") { c ->
				o("t" to c.getLong(0) / 1000, "low" to c.getDouble(1), "mod" to c.getDouble(2), "high" to c.getDouble(3), "minLow" to c.getInt(4), "minMod" to c.getInt(5), "minHigh" to c.getInt(6), "today" to c.getDouble(7), "total" to c.getDouble(8)) })
			dates += add("sleep", rows("SELECT DATA FROM HUAMI_SLEEP_SESSION_SAMPLE WHERE DEVICE_ID IN ($inIds)") { c -> c.getBlob(0).let { b -> if (b != null && b.size >= 594) Fetcher.sleepSession(b.copyOf(594)) else JSONObject() } }.filter { it.has("t") })
		}
		val cut = LocalDate.now().minusDays(KEEP_DAYS.toLong()).toString()
		return dates.filter { it >= cut }.toSet()
	}

	companion object {
		const val KEEP_DAYS = 120
	}
}
