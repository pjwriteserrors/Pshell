import QtQuick
import Quickshell
import qs.core.services

// asteroids: the ones that pass the earth this week and when one of them
// can be seen. Without the paths of the radar, which are large.
Topic {
	id: topic

	name: "asteroids"

	function moment(time) {
		return Qt.formatDateTime(new Date(time), "ddd HH:mm");
	}

	data: topic.wanted ? ({
		ready: Asteroids.ready,
		next: Asteroids.next ? String(Asteroids.next.des) : "",
		objects: Asteroids.ready ? Asteroids.objects.map(object => ({
			des: String(object.des),
			name: String(object.name || object.des),
			at: Number(object.at),
			when: Asteroids.when(object.at, Asteroids.clock),
			moment: topic.moment(object.at),
			passed: object.at < Asteroids.clock,
			distance: Asteroids.distance(Number(object.dist)),
			speed: `${Number(object.speed).toFixed(1)} km/s`,
			size: Asteroids.size(object)
		})) : [],
		// what is over is left out
		sightings: Asteroids.sightings.filter(sighting => sighting.end > Asteroids.clock).map(sighting => ({
			des: String(sighting.des),
			name: String(sighting.name || sighting.des),
			start: Number(sighting.start),
			end: Number(sighting.end),
			now: sighting.start <= Asteroids.clock,
			from: topic.moment(sighting.start),
			until: Qt.formatTime(new Date(sighting.end), "HH:mm"),
			mag: Number(sighting.mag),
			alt: Number(sighting.alt),
			look: Asteroids.compass(Number(sighting.az)),
			moves: Asteroids.compass(Number(sighting.to ?? sighting.az))
		}))
	}) : null
}
