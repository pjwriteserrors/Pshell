"""Weather for the watch's weather app: open-meteo (as the shell's Weather
service) turned into the JSON Zepp OS's /weather/… requests expect (the
shape Gadgetbridge's ZeppOsWeatherHandler answers with)."""

import json
import time
import urllib.parse
import urllib.request

# WMO weather code → Zepp OS weather code
WMO = {0: 0, 1: 1, 2: 1, 3: 2, 45: 18, 48: 32, 51: 7, 53: 7, 55: 8, 56: 19, 57: 19, 61: 7, 63: 8, 65: 9,
       66: 19, 67: 19, 71: 14, 73: 15, 75: 16, 77: 14, 80: 3, 81: 8, 82: 10, 85: 13, 86: 16, 95: 4, 96: 5, 99: 5}

def _dumps(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


_cache = {"at": 0.0, "key": None, "data": None}


def zepp_code(wmo):
    return str(WMO.get(int(wmo or 0), 2))


def fetch(lat, lon, max_age=1800):
    key = (round(lat, 3), round(lon, 3))
    if _cache["key"] == key and time.time() - _cache["at"] < max_age and _cache["data"]:
        return _cache["data"]
    q = urllib.parse.urlencode({
        "latitude": lat, "longitude": lon, "timezone": "auto", "forecast_days": 10,
        "current": "temperature_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m,weather_code,visibility,uv_index",
        "hourly": "temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,wind_speed_10m_max,wind_direction_10m_dominant,relative_humidity_2m_mean,uv_index_max",
    })
    with urllib.request.urlopen("https://api.open-meteo.com/v1/forecast?" + q, timeout=15) as r:
        data = json.loads(r.read())
    _cache.update(at=time.time(), key=key, data=data)
    return data


def _stamp(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))


def _local(iso):
    # open-meteo's local "2026-11-03T07:21" → "2026-11-03 07:21:00"
    return (iso or "").replace("T", " ") + ":00" if iso and len(iso) == 16 else iso or ""


def _beaufort(kmh):
    limits = (1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118)
    return next((i for i, v in enumerate(limits) if kmh < v), 12)


def answer(path, query, lat, lon):
    """(status, JSON text) for one of the watch's weather requests."""
    try:
        d = fetch(lat, lon)
    except (OSError, ValueError):
        return 404, _dumps({"errorCode": -2001, "message": "Not found"})
    cur, day, hour = d.get("current", {}), d.get("daily", {}), d.get("hourly", {})
    now = _stamp()
    if path == "/weather/current":
        return 200, _dumps({
            "currentWeatherModel": {
                "humidity": {"unit": "%", "value": str(round(cur.get("relative_humidity_2m", 0)))},
                "pressure": {"unit": "mb", "value": str(round(cur.get("pressure_msl", 0)))},
                "pubTime": now,
                "temperature": {"unit": "℃", "value": str(round(cur.get("temperature_2m", 0)))},
                "uvIndex": str(round(cur.get("uv_index") or 0)),
                "visibility": {"unit": "km", "value": str(round((cur.get("visibility") or 0) / 1000))},
                "weather": zepp_code(cur.get("weather_code")),
                "wind": {"direction": {"unit": "°", "value": str(round(cur.get("wind_direction_10m", 0)))},
                         "speed": {"unit": "km/h", "value": str(round(cur.get("wind_speed_10m", 0)))}},
            },
            "aqiModel": {},
        })
    if path == "/weather/v2/forecast":
        days = min(int(query.get("days", 10)), len(day.get("time", [])))
        r = lambda a, b: {"from": str(a), "to": str(b)}
        out = {"pubTime": now, "humidity": [], "temperature": [], "weather": [], "windDirection": [],
               "sunRiseSet": [], "windSpeed": [], "moonRiseSet": {"moonPhaseValue": [], "moonRise": []}, "airQualities": []}
        for i in range(days):
            code = zepp_code(day["weather_code"][i])
            out["humidity"].append(str(round((day.get("relative_humidity_2m_mean") or [0] * days)[i] or 0)))
            out["temperature"].append(r(round(day["temperature_2m_min"][i]), round(day["temperature_2m_max"][i])))
            out["weather"].append(r(code, code))
            wd = round((day.get("wind_direction_10m_dominant") or [0] * days)[i] or 0)
            ws = round((day.get("wind_speed_10m_max") or [0] * days)[i] or 0)
            out["windDirection"].append(r(wd, wd))
            out["windSpeed"].append(r(ws, ws))
            out["sunRiseSet"].append(r(_local(day["sunrise"][i]), _local(day["sunset"][i])))
        return 200, _dumps(out)
    if path == "/weather/forecast/hourly":
        n = int(query.get("hours", query.get("hourly", 72)))
        times = hour.get("time", [])
        start = next((i for i, t in enumerate(times) if time.mktime(time.strptime(t, "%Y-%m-%dT%H:%M")) >= time.time() - 3600), 0)
        idx = range(start, min(len(times), start + n))
        return 200, _dumps({
            "pubTime": now,
            "weather": [zepp_code(hour["weather_code"][i]) for i in idx],
            "temperature": [str(round(hour["temperature_2m"][i])) for i in idx],
            "humidity": [str(round(hour["relative_humidity_2m"][i])) for i in idx],
            "fxTime": [_stamp(time.mktime(time.strptime(times[i], "%Y-%m-%dT%H:%M"))) for i in idx],
            "windDirection": [str(round(hour["wind_direction_10m"][i])) for i in idx],
            "windSpeed": [str(round(hour["wind_speed_10m"][i])) for i in idx],
            "windScale": [f"{_beaufort(hour['wind_speed_10m'][i])}-{_beaufort(hour['wind_speed_10m'][i])}" for i in idx],
        })
    if path == "/weather/index":
        days = min(int(query.get("days", 3)), len(day.get("time", [])))
        return 200, _dumps({"pubTime": now, "dataList": [
            {"date": day["time"][i], "osi": "0", "uvi": str(round((day.get("uv_index_max") or [0] * days)[i] or 0)),
             "pai": None, "cwi": "0", "fi": "0"} for i in range(days)]})
    if path == "/weather/alerts":
        return 200, _dumps({"alerts": []})
    if path == "/weather/tide":
        return 200, _dumps({"pubTime": now, "poiName": "", "poiKey": "", "tideData": []})
    return 404, _dumps({"errorCode": -2001, "message": "Not found"})


def handle(url, lat, lon):
    parts = urllib.parse.urlsplit(url)
    query = dict(urllib.parse.parse_qsl(parts.query))
    return answer(parts.path, query, lat, lon)
