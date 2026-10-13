import QtQuick
import Quickshell
import qs.core.services

// connections: where the PC's connections go, app by app and place by
// place. The service samples only while somebody watches, and a phone that
// looks counts as one view.
Topic {
	id: topic

	name: "connections"
	// a new sample every second
	throttle: 1000

	property bool watching: false

	function follow() {
		if (topic.wanted === topic.watching) return;
		topic.watching = topic.wanted;
		Outbound.watch(topic.wanted);
	}

	data: topic.wanted ? ({
		ready: Outbound.ready,
		geo: Outbound.geo,
		progress: Math.round(Outbound.progress * 100) / 100,
		apps: Outbound.apps.map(app => ({
			id: String(app.id),
			title: Outbound.title(app.id),
			conns: Number(app.conns) || 0,
			down: Math.round(Number(app.down) || 0),
			up: Math.round(Number(app.up) || 0),
			places: app.places || []
		})),
		// without the coordinates: there is no globe on the phone
		places: Outbound.places.map(place => ({
			key: String(place.key),
			city: String(place.city || ""),
			country: String(place.country || ""),
			cc: String(place.cc || ""),
			conns: Number(place.conns) || 0,
			down: Math.round(Number(place.down) || 0),
			up: Math.round(Number(place.up) || 0),
			apps: (place.apps || []).map(app => ({
				id: String(app.id),
				title: Outbound.title(app.id),
				conns: Number(app.conns) || 0,
				down: Math.round(Number(app.down) || 0),
				up: Math.round(Number(app.up) || 0)
			}))
		}))
	}) : null

	onWantedChanged: topic.follow()
	Component.onCompleted: topic.follow()
	Component.onDestruction: if (topic.watching) Outbound.watch(false)
}
