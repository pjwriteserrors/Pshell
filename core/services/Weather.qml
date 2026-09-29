pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Open-Meteo weather for a fixed city: current conditions, the next hours
// and a five day outlook. Refreshes every five minutes.
Singleton {
	id: root

	property string city: Host.profile.weather?.city ?? ""
	property string location: ""
	property string temperature: "--"
	property int temperatureValue: 0
	property bool available: false
	property string icon: "weather_cloudy"
	property string description: "Loading weather..."
	property string feelsLike: "--"
	property string humidity: "--"
	property string wind: "--"
	property string precipitation: "--"
	property string pressure: "--"
	property string sunrise: "--"
	property string sunset: "--"
	property string observationTime: ""
	property var hourly: []
	property var daily: []
	// hourly sea-level pressure from today 00:00 on: [{ at (ms), hPa }]
	property var pressureHours: []
	property real latitude: Number.NaN
	property real longitude: Number.NaN
	property string requestKind: ""

	function describe(code) {
		if (code === 0) return "Clear sky";
		if (code === 1) return "Mainly clear";
		if (code === 2) return "Partly cloudy";
		if (code === 3) return "Overcast";
		if ([45, 48].includes(code)) return "Fog";
		if ([51, 53, 55, 56, 57].includes(code)) return "Drizzle";
		if ([61, 63, 65, 66, 67, 80, 81, 82].includes(code)) return "Rain";
		if ([71, 73, 75, 77, 85, 86].includes(code)) return "Snow";
		if ([95, 96, 99].includes(code)) return "Thunderstorm";
		return "Unavailable";
	}

	function iconFor(code, isDay = true) {
		const value = Number(code);
		if (value === 0) return isDay ? "weather_sunny" : "weather_night";
		if (value === 1 || value === 2) return isDay ? "weather_partly_cloudy" : "weather_night_partly_cloudy";
		if (value === 3) return "weather_cloudy";
		if ([45, 48].includes(value)) return "weather_fog";
		if ([51, 53, 55, 56, 57, 61, 80].includes(value)) return "weather_rainy";
		if ([63, 65, 66, 67, 81, 82].includes(value)) return "weather_pouring";
		if ([71, 73, 75, 77, 85, 86].includes(value)) return "weather_snowy";
		if ([95, 96, 99].includes(value)) return "weather_lightning";
		return "weather_cloudy";
	}

	function geocodeUrl() {
		return `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(root.city)}&count=1&language=en&format=json`;
	}

	function forecastUrl() {
		return "https://api.open-meteo.com/v1/forecast?latitude=" + root.latitude
			+ "&longitude=" + root.longitude
			+ "&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,pressure_msl,wind_speed_10m,weather_code,is_day"
			+ "&hourly=temperature_2m,weather_code,is_day,precipitation_probability,pressure_msl"
			+ "&daily=sunrise,sunset,weather_code,temperature_2m_max,temperature_2m_min"
			+ "&timezone=auto&forecast_days=5";
	}

	function refresh() {
		if (isFinite(root.latitude) && isFinite(root.longitude)) {
			root.requestKind = "forecast";
			weatherProcess.exec(["curl", "-fsSL", root.forecastUrl()]);
			return;
		}
		root.requestKind = "geocode";
		weatherProcess.exec(["curl", "-fsSL", root.geocodeUrl()]);
	}

	function resetUnavailable() {
		root.available = false;
		root.location = root.city;
		root.temperature = "--";
		root.icon = "alert";
		root.description = "Weather unavailable";
		root.feelsLike = "--";
		root.humidity = "--";
		root.wind = "--";
		root.precipitation = "--";
		root.pressure = "--";
		root.sunrise = "--";
		root.sunset = "--";
		root.observationTime = "";
		root.hourly = [];
		root.daily = [];
		root.pressureHours = [];
	}

	function applyForecast(raw) {
		try {
			const parsed = JSON.parse(raw);
			const current = parsed.current;
			const daily = parsed.daily;
			const hourly = parsed.hourly;
			if (!current) throw new Error("missing current weather");
			const code = Number(current.weather_code);
			const isDay = Number(current.is_day || 0) === 1;
			root.available = true;
			root.temperatureValue = Math.round(Number(current.temperature_2m));
			root.temperature = `${root.temperatureValue}°`;
			root.icon = root.iconFor(code, isDay);
			root.description = root.describe(code);
			root.feelsLike = current.apparent_temperature !== undefined ? `${Math.round(Number(current.apparent_temperature))}°` : "--";
			root.humidity = current.relative_humidity_2m !== undefined ? `${Math.round(Number(current.relative_humidity_2m))}%` : "--";
			root.wind = current.wind_speed_10m !== undefined ? `${Math.round(Number(current.wind_speed_10m))} km/h` : "--";
			root.precipitation = current.precipitation !== undefined ? `${Number(current.precipitation).toFixed(1)} mm` : "--";
			root.pressure = current.pressure_msl !== undefined ? `${Math.round(Number(current.pressure_msl))} hPa` : "--";
			root.sunrise = daily?.sunrise?.[0] ? Qt.formatDateTime(new Date(daily.sunrise[0]), "HH:mm") : "--";
			root.sunset = daily?.sunset?.[0] ? Qt.formatDateTime(new Date(daily.sunset[0]), "HH:mm") : "--";
			root.observationTime = current.time || "";

			const hours = [];
			if (hourly?.time) {
				const now = Date.now();
				for (let i = 0; i < hourly.time.length && hours.length < 6; i += 1) {
					const time = new Date(hourly.time[i]);
					if (time.getTime() < now - 3600000) continue;
					hours.push({
						label: hours.length === 0 ? "Now" : Qt.formatDateTime(time, "HH"),
						temp: Math.round(Number(hourly.temperature_2m[i])),
						icon: root.iconFor(hourly.weather_code[i], Number(hourly.is_day?.[i] ?? 1) === 1),
						rain: Number(hourly.precipitation_probability?.[i] ?? 0)
					});
				}
			}
			root.hourly = hours;

			const pressure = [];
			for (let i = 0; i < (hourly?.time?.length ?? 0); i += 1) {
				const value = Number(hourly.pressure_msl?.[i]);
				if (isFinite(value)) pressure.push({ at: new Date(hourly.time[i]).getTime(), hPa: value });
			}
			root.pressureHours = pressure;

			const days = [];
			if (daily?.time) {
				for (let i = 0; i < daily.time.length; i += 1) {
					days.push({
						label: i === 0 ? "Today" : Qt.formatDateTime(new Date(daily.time[i]), "ddd"),
						icon: root.iconFor(daily.weather_code?.[i], true),
						max: Math.round(Number(daily.temperature_2m_max?.[i])),
						min: Math.round(Number(daily.temperature_2m_min?.[i]))
					});
				}
			}
			root.daily = days;
		} catch (error) {
			root.resetUnavailable();
		}
	}

	function applyGeocode(raw) {
		try {
			const result = JSON.parse(raw).results?.[0];
			if (!result) throw new Error("missing geocode result");
			root.latitude = Number(result.latitude);
			root.longitude = Number(result.longitude);
			const name = result.name || root.city;
			const admin = result.admin1 || result.country || "";
			root.location = admin !== "" ? `${name}, ${admin}` : name;
			root.requestKind = "forecast";
			weatherProcess.exec(["curl", "-fsSL", root.forecastUrl()]);
		} catch (error) {
			root.resetUnavailable();
		}
	}

	Process {
		id: weatherProcess
		stdout: StdioCollector {
			onStreamFinished: {
				if (root.requestKind === "geocode") root.applyGeocode(text);
				else root.applyForecast(text);
			}
		}
		onExited: exitCode => {
			if (exitCode !== 0 && root.observationTime === "" && root.temperature === "--")
				root.resetUnavailable();
		}
	}

	Timer {
		running: true
		repeat: true
		interval: 300000
		triggeredOnStart: true
		onTriggered: root.refresh()
	}
}
