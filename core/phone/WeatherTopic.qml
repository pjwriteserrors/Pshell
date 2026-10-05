import QtQuick
import Quickshell
import qs.core.services

// weather: what the Today panel shows for the host profile's city.
Topic {
	id: topic

	name: "weather"

	data: topic.wanted ? ({
		available: Weather.available,
		city: Weather.city,
		location: Weather.location,
		temperature: Weather.temperatureValue,
		icon: Weather.icon,
		description: Weather.description,
		feelsLike: Weather.feelsLike,
		humidity: Weather.humidity,
		wind: Weather.wind,
		precipitation: Weather.precipitation,
		pressure: Weather.pressure,
		sunrise: Weather.sunrise,
		sunset: Weather.sunset,
		hourly: Weather.hourly,
		daily: Weather.daily
	}) : null

	function call(action, args, done) {
		if (action !== "refresh") throw new Error("unknown-action");
		Weather.refresh();
		return {};
	}
}
