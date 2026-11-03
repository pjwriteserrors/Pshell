package dev.pshell.app.zepp

import org.json.JSONArray
import org.json.JSONObject
import java.net.URL
import java.net.URLDecoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** The watch's weather app asks over Zepp OS's HTTP endpoint; answered from open-meteo (scripts/amazfit/weather.py on the PC). */
object WeatherZepp {
	private val WMO = mapOf(0 to 0, 1 to 1, 2 to 1, 3 to 2, 45 to 18, 48 to 32, 51 to 7, 53 to 7, 55 to 8, 56 to 19, 57 to 19, 61 to 7, 63 to 8, 65 to 9,
		66 to 19, 67 to 19, 71 to 14, 73 to 15, 75 to 16, 77 to 14, 80 to 3, 81 to 8, 82 to 10, 85 to 13, 86 to 16, 95 to 4, 96 to 5, 99 to 5)
	private var cache: Triple<Long, String, JSONObject>? = null
	private fun code(w: Int) = (WMO[w] ?: 2).toString()
	private fun stamp(t: Long = System.currentTimeMillis()) = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.ROOT).format(Date(t))
	private fun local(iso: String) = if (iso.length == 16) iso.replace("T", " ") + ":00" else iso
	private fun range(a: Any, b: Any) = JSONObject().put("from", a.toString()).put("to", b.toString())
	private fun r(v: Double) = Math.round(v).toString()

	private fun fetch(lat: Double, lon: Double): JSONObject {
		val key = "%.3f,%.3f".format(Locale.ROOT, lat, lon)
		cache?.let { if (it.second == key && System.currentTimeMillis() - it.first < 30 * 60_000) return it.third }
		val q = "latitude=$lat&longitude=$lon&timezone=auto&forecast_days=10" +
			"&current=temperature_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m,weather_code,visibility,uv_index" +
			"&hourly=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m" +
			"&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,wind_speed_10m_max,wind_direction_10m_dominant,relative_humidity_2m_mean,uv_index_max"
		val data = JSONObject(URL("https://api.open-meteo.com/v1/forecast?$q").readText())
		cache = Triple(System.currentTimeMillis(), key, data)
		return data
	}

	fun answer(url: String, lat: Double, lon: Double): Pair<Int, String> {
		val path = url.substringBefore('?')
		val query = url.substringAfter('?', "").split('&').mapNotNull { it.split('=', limit = 2).takeIf { p -> p.size == 2 }?.let { p -> p[0] to URLDecoder.decode(p[1], "UTF-8") } }.toMap()
		val d = fetch(lat, lon)
		val cur = d.getJSONObject("current"); val day = d.getJSONObject("daily"); val hour = d.getJSONObject("hourly")
		val now = stamp()
		val unit = { u: String, v: String -> JSONObject().put("unit", u).put("value", v) }
		return 200 to when (path) {
			"/weather/current" -> JSONObject().put("currentWeatherModel", JSONObject()
				.put("humidity", unit("%", r(cur.optDouble("relative_humidity_2m")))).put("pressure", unit("mb", r(cur.optDouble("pressure_msl"))))
				.put("pubTime", now).put("temperature", unit("℃", r(cur.optDouble("temperature_2m")))).put("uvIndex", r(cur.optDouble("uv_index", 0.0)))
				.put("visibility", unit("km", r(cur.optDouble("visibility", 0.0) / 1000))).put("weather", code(cur.optInt("weather_code")))
				.put("wind", JSONObject().put("direction", unit("°", r(cur.optDouble("wind_direction_10m")))).put("speed", unit("km/h", r(cur.optDouble("wind_speed_10m"))))))
				.put("aqiModel", JSONObject()).toString()
			"/weather/v2/forecast" -> {
				val n = minOf(query["days"]?.toIntOrNull() ?: 10, day.getJSONArray("time").length())
				val out = JSONObject().put("pubTime", now)
				val keys = listOf("humidity", "temperature", "weather", "windDirection", "sunRiseSet", "windSpeed", "airQualities")
				val lists = keys.associateWith { JSONArray() }
				for (i in 0 until n) {
					val c = code(day.getJSONArray("weather_code").getInt(i))
					lists["humidity"]!!.put(r(day.optJSONArray("relative_humidity_2m_mean")?.optDouble(i, 0.0) ?: 0.0))
					lists["temperature"]!!.put(range(r(day.getJSONArray("temperature_2m_min").getDouble(i)), r(day.getJSONArray("temperature_2m_max").getDouble(i))))
					lists["weather"]!!.put(range(c, c))
					val wd = r(day.optJSONArray("wind_direction_10m_dominant")?.optDouble(i, 0.0) ?: 0.0)
					val ws = r(day.optJSONArray("wind_speed_10m_max")?.optDouble(i, 0.0) ?: 0.0)
					lists["windDirection"]!!.put(range(wd, wd)); lists["windSpeed"]!!.put(range(ws, ws))
					lists["sunRiseSet"]!!.put(range(local(day.getJSONArray("sunrise").getString(i)), local(day.getJSONArray("sunset").getString(i))))
				}
				lists.forEach { (k, v) -> out.put(k, v) }
				out.put("moonRiseSet", JSONObject().put("moonPhaseValue", JSONArray()).put("moonRise", JSONArray())).toString()
			}
			"/weather/forecast/hourly" -> {
				val times = hour.getJSONArray("time")
				val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.ROOT)
				val start = (0 until times.length()).firstOrNull { fmt.parse(times.getString(it))!!.time >= System.currentTimeMillis() - 3_600_000 } ?: 0
				val idx = start until minOf(times.length(), start + (query["hours"]?.toIntOrNull() ?: 72))
				val w = { name: String, f: (Int) -> String -> JSONArray(idx.map(f)) }
				JSONObject().put("pubTime", now)
					.put("weather", w("w") { code(hour.getJSONArray("weather_code").getInt(it)) })
					.put("temperature", w("t") { r(hour.getJSONArray("temperature_2m").getDouble(it)) })
					.put("humidity", w("h") { r(hour.getJSONArray("relative_humidity_2m").getDouble(it)) })
					.put("fxTime", w("f") { stamp(fmt.parse(times.getString(it))!!.time) })
					.put("windDirection", w("d") { r(hour.getJSONArray("wind_direction_10m").getDouble(it)) })
					.put("windSpeed", w("s") { r(hour.getJSONArray("wind_speed_10m").getDouble(it)) })
					.put("windScale", w("b") { "1-2" }).toString()
			}
			"/weather/index" -> JSONObject().put("pubTime", now).put("dataList", JSONArray((0 until minOf(3, day.getJSONArray("time").length())).map {
				JSONObject().put("date", day.getJSONArray("time").getString(it)).put("osi", "0").put("uvi", r(day.optJSONArray("uv_index_max")?.optDouble(it, 0.0) ?: 0.0)).put("cwi", "0").put("fi", "0") })).toString()
			"/weather/alerts" -> JSONObject().put("alerts", JSONArray()).toString()
			else -> return 404 to JSONObject().put("errorCode", -2001).put("message", "Not found").toString()
		}
	}
}
