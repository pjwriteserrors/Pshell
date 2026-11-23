pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >wp: places near the weather's city. While typing, what is meant
// (name, street, postcode, town) and, for a word like "pizza", all of that
// kind around; a click opens the place: its picture, whether it is open,
// what it is, how long it takes to get there, its week, its weather, what
// it offers, its photos and map, what is around it, and own stars and a
// note. Reviews open in Google Maps. Places to go to and been to, the ones
// seen lately and up to three to compare wait here when nothing is typed.
// Enter opens the selected place, on a place the reviews; Esc goes back.
Item {
	id: root

	property string argument: ""
	property bool active: false
	signal closeRequested
	signal argumentRequested(string text)

	readonly property string query: String(root.argument || "").trim()
	readonly property bool showingPlace: Places.opening !== null
	readonly property bool comparingOpen: root.compareShown && Places.compare.length > 0
	property bool compareShown: false
	property bool onlyOpen: false
	property int current: 0
	// counts the lists and places shown, so their parts come in again
	property int generation: 0
	property int placeGeneration: 0
	// where the picture of the opened row was, for its flight into the header
	property rect flightFrom: Qt.rect(0, 0, 0, 0)
	property bool flying: false

	readonly property string enterHint: root.showingPlace ? "reviews" : "show"

	readonly property var sections: {
		const out = [];
		const filtered = items => root.onlyOpen ? items.filter(item => Places.openState(item.hours).open === true) : items;
		if (root.query === "") {
			if (Places.wantList.length > 0) out.push({ title: "Want to go", icon: "bookmark", items: Places.wantList });
			if (Places.beenList.length > 0) out.push({ title: "Been there", icon: "check_circle", items: Places.beenList });
			const kept = new Set(Object.keys(Places.saved));
			const recent = Places.history.filter(item => !kept.has(item.id));
			if (recent.length > 0) out.push({ title: "Recent", icon: "history", items: recent });
			return out;
		}
		if (Places.categoryItems.length > 0) out.push({ title: `${Places.categoryLabel} nearby`, icon: "map_marker_radius_outline", items: filtered(Places.categoryItems), filter: true });
		if (Places.suggestions.length > 0) out.push({ title: Places.categoryItems.length > 0 ? "By name" : "Places", icon: "map_marker_outline", items: Places.suggestions });
		return out;
	}
	readonly property var rows: {
		const out = [];
		for (const section of root.sections) for (const item of section.items) out.push(item);
		return out;
	}

	onArgumentChanged: {
		if (!root.active) return;
		if (root.showingPlace) root.back();
		root.compareShown = false;
		root.current = 0;
		// root.query may not have caught up with the argument yet
		Places.request(root.argument);
	}
	onActiveChanged: if (root.active) Places.request(root.argument)
	onRowsChanged: {
		if (root.current >= root.rows.length) root.current = Math.max(0, root.rows.length - 1);
	}

	// ── what the launcher asks of a view ────────────────────────────────

	function move(delta) {
		if (root.showingPlace) {
			detailFlick.flick(0, -delta * 900);
			return;
		}
		if (root.rows.length === 0) return;
		root.current = Math.max(0, Math.min(root.rows.length - 1, root.current + delta));
		listFlick.ensureVisible(root.current);
	}

	function handleKey(event) {
		if (!root.showingPlace || !Places.place) return false;
		if (!(event.modifiers & Qt.ControlModifier)) return false;
		switch (event.key) {
		case Qt.Key_S: Places.toggleList(Places.place, "want"); return true;
		case Qt.Key_B: Places.toggleList(Places.place, "been"); return true;
		case Qt.Key_R: root.reviews(); return true;
		case Qt.Key_O: root.website(); return true;
		case Qt.Key_K: Places.toggleCompare(Places.place); return true;
		}
		return false;
	}

	function cancel() {
		if (root.comparingOpen) {
			root.compareShown = false;
			return true;
		}
		if (root.showingPlace) {
			root.back();
			return true;
		}
		return false;
	}

	function activate(modifiers) {
		if (root.showingPlace) {
			if (Places.place) root.reviews();
			return;
		}
		if (Places.loading && root.rows.length === 0) {
			Places.flush();
			return;
		}
		const item = root.rows[root.current];
		if (item) root.openPlace(item, null);
	}

	// ── doing ───────────────────────────────────────────────────────────

	function openPlace(item, from) {
		if (from) {
			const point = from.mapToItem(root, 0, 0);
			root.flightFrom = Qt.rect(point.x, point.y, from.width, from.height);
			root.flying = true;
		} else {
			root.flying = false;
		}
		root.compareShown = false;
		Places.open(item);
		root.placeGeneration += 1;
		detailFlick.contentY = 0;
		heroFrame.index = 0;
	}

	function back() {
		Places.close();
		root.generation += 1;
	}

	function external(url) {
		if (!url) return;
		root.closeRequested();
		Browser.open(url);
	}

	function reviews() {
		root.external(Places.reviewsUrl(Places.place ?? Places.opening));
	}

	function website() {
		root.external(Places.place?.website ?? "");
	}

	function copy(text) {
		if (!text) return;
		Quickshell.execDetached(["wl-copy", "--", String(text)]);
		Haptics.play("copied");
	}

	function toPhone() {
		const place = Places.place;
		if (!place) return;
		Phone.sendUrl(Places.routeUrl(place), 0, place.name);
	}

	function number() {
		const phone = Places.place?.phone ?? "";
		if (phone === "") return;
		if (Phone.offered && Phone.connected) Phone.sendText(phone);
		else root.copy(phone);
	}

	function toCalendar() {
		const place = Places.place;
		if (!place) return;
		const now = new Date();
		const start = new Date(now.getFullYear(), now.getMonth(), now.getDate(), Math.min(23, now.getHours() + 1), 0);
		NasCalendar.draft = {
			calendar: NasCalendar.defaultCalendar(),
			title: place.name,
			location: [place.name, place.address].filter(part => part).join(", "),
			notes: place.website || "",
			allDay: false,
			start: NasCalendar.wallTime(start),
			end: NasCalendar.wallTime(new Date(start.getTime() + 3600000)),
			repeat: "",
			reminder: 30
		};
		root.closeRequested();
		Popups.withFocusedScreen(screen => Popups.open("today", screen));
	}

	function distanceText(meters) {
		if (meters === undefined || meters === null) return "";
		if (meters < 1000) return `${Math.round(meters / 10) * 10} m`;
		return `${(meters / 1000).toFixed(meters < 10000 ? 1 : 0).replace(".", ",")} km`;
	}

	function addressOf(item) {
		const town = [item?.postcode, item?.city].filter(part => part).join(" ");
		return [item?.street, town].filter(part => part).join(", ");
	}

	function stateText(state) {
		if (!state?.known) return "";
		if (state.always) return "Open 24 hours";
		if (state.open) return state.minutes <= 60 ? `Closes in ${state.minutes} min` : `Open until ${state.until}`;
		if (state.minutes === undefined) return "Closed";
		return state.minutes <= 60 ? `Opens in ${state.minutes} min` : `Closed · opens ${state.until}`;
	}

	function stateColor(state) {
		if (!state?.known) return Theme.textMuted;
		if (state.open) return state.minutes !== undefined && state.minutes <= 30 ? Theme.warning : Theme.success;
		return state.minutes !== undefined && state.minutes <= 30 ? Theme.warning : Theme.danger;
	}

	// ── what kind of place: a glyph and a colour ────────────────────────

	function kindGroup(item) {
		const kind = String(item?.kind ?? "");
		const key = String(item?.key ?? "");
		if (["restaurant", "fast_food", "food_court"].includes(kind)) return "food";
		if (["cafe", "ice_cream", "bakery", "pastry", "confectionery"].includes(kind)) return "cafe";
		if (["bar", "pub", "biergarten", "nightclub"].includes(kind)) return "bar";
		if (["pharmacy", "doctors", "dentist", "hospital", "clinic", "veterinary"].includes(kind) || key === "healthcare") return "health";
		if (["bus_stop", "station", "halt", "tram_stop", "fuel", "charging_station", "parking", "car_wash", "car_rental", "bicycle_rental"].includes(kind) || key === "railway") return "move";
		if (["bank", "atm", "post_office"].includes(kind)) return "money";
		if (["park", "playground", "garden", "nature_reserve", "forest", "wood", "water", "lake", "river", "camp_site", "picnic_site"].includes(kind) || key === "natural") return "green";
		if (["museum", "cinema", "theatre", "arts_centre", "attraction", "viewpoint", "artwork", "castle", "monument", "memorial", "ruins", "place_of_worship", "library", "zoo"].includes(kind) || key === "historic") return "culture";
		if (["hotel", "hostel", "guest_house", "motel", "apartment"].includes(kind)) return "stay";
		if (["fitness_centre", "sports_centre", "swimming_pool", "stadium", "bowling_alley", "escape_game"].includes(kind)) return "sport";
		if (key === "shop") return "shop";
		if (key === "highway" || key === "place" || kind === "house") return "address";
		return "other";
	}

	function kindColor(item) {
		const hues = { food: 0.04, cafe: 0.09, bar: 0.83, health: 0.97, move: 0.55, money: 0.13, green: 0.33, culture: 0.74, stay: 0.64, sport: 0.47, shop: 0.6 };
		const hue = hues[root.kindGroup(item)];
		if (hue === undefined) return Theme.primary;
		return Qt.hsla(hue, 0.62, Theme.dark ? 0.64 : 0.44, 1);
	}

	function kindGlyph(item) {
		const kind = String(item?.kind ?? "");
		// the first cuisine it names decides
		for (const name of (item?.cuisine ?? []).map(c => String(c).toLowerCase())) {
			if (name.includes("pizza") || name.includes("italien")) return "pizza";
			if (name.includes("burger") || name.includes("amerika")) return "hamburger";
			if (["sushi", "asiat", "nudel", "ramen", "vietnam", "chines", "thai", "japan", "korea"].some(word => name.includes(word))) return "noodles";
			if (name.includes("döner") || name.includes("hähnchen") || name.includes("türk")) return "food_drumstick";
			if (name.includes("fisch") || name.includes("meeres")) return "fish";
			if (name.includes("eis")) return "ice_cream";
			if (name.includes("kuchen")) return "cupcake";
		}
		const glyphs = {
			restaurant: "silverware_fork_knife", fast_food: "food", cafe: "coffee", ice_cream: "ice_cream", bakery: "bread_slice",
			bar: "glass_cocktail", pub: "glass_mug_variant", biergarten: "glass_mug_variant", nightclub: "party_popper",
			pharmacy: "pill", doctors: "stethoscope", dentist: "tooth", hospital: "hospital_box", clinic: "hospital_box", veterinary: "paw",
			bus_stop: "bus_stop", station: "train", halt: "train", tram_stop: "tram", fuel: "gas_station", charging_station: "ev_station",
			parking: "parking", bank: "bank", atm: "cash", post_office: "email_outline", supermarket: "cart", convenience: "basket",
			kiosk: "basket", park: "tree", playground: "tree", garden: "flower", museum: "bank_outline", cinema: "movie_open",
			theatre: "drama_masks", place_of_worship: "church", castle: "castle", library: "bookshelf", books: "bookshelf",
			hotel: "bed", hostel: "bed", guest_house: "bed", fitness_centre: "dumbbell", swimming_pool: "swim", sports_centre: "dumbbell",
			hairdresser: "content_cut", florist: "flower", school: "school_outline", university: "school_outline", toilets: "toilet",
			house: "home", clothes: "shopping", shoes: "shopping", bicycle: "bike", car: "car", car_repair: "car"
		};
		if (glyphs[kind]) return glyphs[kind];
		if (item?.key === "shop") return "storefront_outline";
		if (item?.key === "highway") return "road";
		return "map_marker";
	}

	// ── parts used more than once ───────────────────────────────────────

	// a part of the place that comes in after the ones above it
	component Reveal: Item {
		id: reveal

		property int order: 0
		property real rise: 12
		default property alias content: holder.data

		implicitHeight: holder.childrenRect.height
		opacity: 0

		Item {
			id: holder

			width: reveal.width
			height: reveal.height
			transform: Translate {
				id: lift
			}
		}

		Connections {
			target: root

			function onPlaceGenerationChanged() {
				enter.restart();
			}
		}

		Component.onCompleted: enter.restart()

		SequentialAnimation {
			id: enter

			ScriptAction {
				script: {
					reveal.opacity = 0;
					lift.y = reveal.rise;
				}
			}
			PauseAnimation {
				duration: 120 + reveal.order * 60
			}
			ParallelAnimation {
				Anim {
					target: reveal
					property: "opacity"
					to: 1
					duration: Motion.long
				}
				SpatialAnim {
					target: lift
					property: "y"
					to: 0
					duration: Motion.extraLong
				}
			}
		}
	}

	component Shimmer: Rectangle {
		id: shimmer

		radius: Theme.radius.small
		color: Theme.layer2
		clip: true

		Rectangle {
			id: sweep

			width: shimmer.width * 0.6
			height: shimmer.height
			x: -width
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop { position: 0; color: "transparent" }
				GradientStop { position: 0.5; color: Qt.alpha(Theme.text, 0.07) }
				GradientStop { position: 1; color: "transparent" }
			}

			NumberAnimation on x {
				from: -sweep.width
				to: shimmer.width
				duration: 1300
				loops: Animation.Infinite
				running: shimmer.visible
				easing.type: Easing.InOutQuad
			}
		}
	}

	// the round picture of a place: its icon or photo, else its kind
	component Avatar: Item {
		id: avatar

		property var item: null
		property string path: ""
		property real size: 40
		readonly property color tint: root.kindColor(avatar.item)
		readonly property bool hasPicture: picture.status === Image.Ready

		implicitWidth: avatar.size
		implicitHeight: avatar.size

		Rectangle {
			anchors.fill: parent
			radius: width / 2
			color: Qt.alpha(avatar.tint, 0.18)
			border.width: Math.max(1, avatar.size / 40)
			border.color: Qt.alpha(avatar.tint, 0.35)
		}

		Glyph {
			anchors.centerIn: parent
			icon: root.kindGlyph(avatar.item)
			size: Math.round(avatar.size * 0.46)
			color: avatar.tint
			opacity: avatar.hasPicture ? 0 : 1
			animated: false
		}

		ClippingRectangle {
			anchors.fill: parent
			anchors.margins: Math.max(1, avatar.size / 40)
			radius: width / 2
			color: "white"
			opacity: avatar.hasPicture ? 1 : 0

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}

			Image {
				id: picture

				// a wide logo is shown whole, a photo fills the circle
				property bool wide: false

				anchors.fill: parent
				anchors.margins: picture.wide ? parent.width * 0.08 : 0
				source: avatar.path !== "" ? "file://" + avatar.path : ""
				asynchronous: true
				fillMode: picture.wide ? Image.PreserveAspectFit : Image.PreserveAspectCrop
				onStatusChanged: if (status === Image.Ready) picture.wide = implicitWidth / Math.max(1, implicitHeight) > 1.4
				sourceSize.width: Math.round(avatar.size * 2)
				smooth: true
				mipmap: true
			}
		}
	}

	// open or closed, with a dot that breathes while it is open
	component OpenBadge: Rectangle {
		id: badge

		property var hours: null
		property bool large: false
		readonly property var state: Places.openState(badge.hours)
		readonly property color tone: root.stateColor(badge.state)

		visible: badge.state.known === true
		implicitHeight: badge.large ? 28 : 20
		implicitWidth: badgeRow.implicitWidth + (badge.large ? 22 : 14)
		radius: height / 2
		color: Qt.alpha(badge.tone, 0.13)

		RowLayout {
			id: badgeRow

			anchors.centerIn: parent
			spacing: badge.large ? 8 : 6

			Item {
				implicitWidth: badge.large ? 8 : 6
				implicitHeight: implicitWidth

				Rectangle {
					anchors.centerIn: parent
					width: parent.width * 2.4
					height: width
					radius: width / 2
					color: badge.tone
					opacity: 0
					visible: badge.state.open === true

					SequentialAnimation on opacity {
						running: badge.visible && badge.state.open === true && root.active
						loops: Animation.Infinite
						NumberAnimation { from: 0.45; to: 0; duration: 1600; easing.type: Easing.OutCubic }
						PauseAnimation { duration: 500 }
					}
					SequentialAnimation on scale {
						running: badge.visible && badge.state.open === true && root.active
						loops: Animation.Infinite
						NumberAnimation { from: 0.4; to: 1; duration: 1600; easing.type: Easing.OutCubic }
						PauseAnimation { duration: 500 }
					}
				}

				Rectangle {
					anchors.fill: parent
					radius: width / 2
					color: badge.tone
				}
			}

			StyledText {
				text: root.stateText(badge.state)
				tone: badge.tone
				font.pixelSize: badge.large ? Theme.size.label : Theme.size.tiny
				font.weight: Font.DemiBold
			}
		}
	}

	// a number that counts up to its value when it comes in
	component CountUp: StyledText {
		id: counter

		property real value: 0
		property real shown: 0
		property int decimals: 0
		property string suffix: ""

		text: `${counter.decimals > 0 ? counter.shown.toFixed(counter.decimals).replace(".", ",") : Math.round(counter.shown)}${counter.suffix}`
		tabular: true
		onValueChanged: count.restart()
		Component.onCompleted: count.restart()

		NumberAnimation {
			id: count

			target: counter
			property: "shown"
			from: 0
			to: counter.value
			duration: 900
			easing.type: Easing.OutCubic
		}
	}

	component ActionChip: Clickable {
		id: action

		property string icon: ""
		property string text: ""
		property bool lit: false
		property color accent: Theme.primary

		implicitHeight: 32
		implicitWidth: actionRow.implicitWidth + 24
		radius: height / 2
		color: action.lit ? action.accent : Theme.layer2
		tint: action.lit ? Theme.onPrimary : Theme.text
		pressedScale: 0.92

		Behavior on color {
			ColorAnim {}
		}

		RowLayout {
			id: actionRow

			anchors.centerIn: parent
			spacing: 7

			Glyph {
				icon: action.icon
				size: 15
				color: action.lit ? Theme.onPrimary : action.accent
			}

			StyledText {
				visible: action.text !== ""
				text: action.text
				tone: action.lit ? Theme.onPrimary : Theme.text
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}
		}
	}

	component Card: Rectangle {
		radius: Theme.radius.large
		color: Theme.layer1
	}

	// ── nothing typed and nothing kept ──────────────────────────────────
	Item {
		id: welcome

		anchors.fill: parent
		opacity: !root.showingPlace && !root.comparingOpen && root.query === "" && root.rows.length === 0 ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			anchors.centerIn: parent
			spacing: 14

			Item {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 92
				Layout.preferredHeight: 92

				Rectangle {
					anchors.centerIn: parent
					width: 92
					height: 92
					radius: 46
					color: Theme.primarySoft

					SequentialAnimation on scale {
						running: welcome.visible
						loops: Animation.Infinite
						NumberAnimation { to: 1.08; duration: 1800; easing.type: Easing.InOutSine }
						NumberAnimation { to: 1.0; duration: 1800; easing.type: Easing.InOutSine }
					}
				}

				Glyph {
					id: welcomePin

					anchors.centerIn: parent
					icon: "map_marker"
					size: 42
					color: Theme.primary

					SequentialAnimation on anchors.verticalCenterOffset {
						running: welcome.visible
						loops: Animation.Infinite
						NumberAnimation { to: -7; duration: 900; easing.type: Easing.OutQuad }
						NumberAnimation { to: 0; duration: 700; easing.type: Easing.OutBounce }
						PauseAnimation { duration: 1400 }
					}
				}
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: Places.originName !== "" ? `Places in ${Places.originName}` : "Places"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
			}

			Flow {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 380
				Layout.topMargin: 6
				spacing: 6

				Repeater {
					model: ["Café", "Pizza", "Apotheke", "Supermarkt", "Bar", "Park"]

					delegate: Chip {
						id: idea

						required property string modelData
						required property int index

						text: idea.modelData
						opacity: 0
						onClicked: root.argumentRequested(idea.modelData)

						SequentialAnimation on opacity {
							running: welcome.visible
							PauseAnimation { duration: 140 + idea.index * 50 }
							Anim { to: 1; duration: Motion.long }
						}
					}
				}
			}
		}
	}

	// ── looking, the first time ─────────────────────────────────────────
	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 4
		spacing: 10
		opacity: !root.showingPlace && root.query !== "" && root.rows.length === 0 && Places.loading ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {}
		}

		Repeater {
			model: 5

			delegate: RowLayout {
				required property int index

				Layout.fillWidth: true
				spacing: 12

				Shimmer { Layout.preferredWidth: 40; Layout.preferredHeight: 40; radius: 20 }

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 7

					Shimmer { Layout.preferredWidth: 180 + (parent.parent.index % 3) * 40; Layout.preferredHeight: 13 }
					Shimmer { Layout.preferredWidth: 240 - (parent.parent.index % 2) * 60; Layout.preferredHeight: 10 }
				}
			}
		}

		Item {
			Layout.fillHeight: true
		}
	}

	EmptyState {
		anchors.centerIn: parent
		opacity: !root.showingPlace && root.query !== "" && !Places.loading && root.rows.length === 0 && (Places.state === "none" || Places.state === "error") ? 1 : 0
		visible: opacity > 0.01
		icon: Places.state === "error" ? "wifi_off" : "map_marker_outline"
		title: Places.state === "error" ? "No answer" : `Nothing found for „${root.query}“`
		subtitle: Places.state === "error" ? Places.error : ""

		Behavior on opacity {
			Anim {}
		}
	}

	// ── the list: what is meant, or what is kept ────────────────────────
	Item {
		id: listPage

		anchors.fill: parent
		opacity: !root.showingPlace && !root.comparingOpen && root.rows.length > 0 ? 1 : 0
		visible: opacity > 0.01
		enabled: !root.showingPlace && !root.comparingOpen
		transform: Translate {
			x: root.showingPlace ? -40 : 0

			Behavior on x {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Flickable {
			id: listFlick

			anchors.fill: parent
			anchors.bottomMargin: compareTray.visible ? compareTray.height + 10 : 0
			contentHeight: listColumn.implicitHeight + 8
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			opacity: Places.loading && root.query !== "" ? 0.6 : 1
			ScrollBar.vertical: ThinScrollBar {}

			Behavior on opacity {
				Anim {}
			}

			function ensureVisible(index) {
				const row = rowRepeater.itemFor(index);
				if (!row) return;
				const top = row.mapToItem(listColumn, 0, 0).y;
				if (top < listFlick.contentY) listFlick.contentY = Math.max(0, top - 30);
				else if (top + row.height > listFlick.contentY + listFlick.height) listFlick.contentY = top + row.height - listFlick.height + 8;
			}

			Column {
				id: listColumn

				width: listFlick.width - 10
				spacing: 2

				Repeater {
					id: rowRepeater

					property var rowItems: ({})

					function itemFor(index) {
						return rowRepeater.rowItems[index] ?? null;
					}

					model: root.sections

					delegate: Column {
						id: section

						required property var modelData
						required property int index
						readonly property int offset: {
							let count = 0;
							for (let i = 0; i < section.index; i += 1) count += root.sections[i].items.length;
							return count;
						}

						width: listColumn.width
						spacing: 2

						RowLayout {
							width: parent.width
							height: 34

							Glyph {
								icon: section.modelData.icon
								size: 14
								color: Theme.primary
							}

							SectionLabel {
								Layout.fillWidth: true
								text: section.modelData.title
							}

							Chip {
								visible: section.modelData.filter === true
								implicitHeight: 24
								icon: "clock_outline"
								text: "Open now"
								selected: root.onlyOpen
								onClicked: root.onlyOpen = !root.onlyOpen
							}
						}

						Repeater {
							model: section.modelData.items

							delegate: Clickable {
								id: row

								required property var modelData
								required property int index
								readonly property int flat: section.offset + row.index
								readonly property bool selected: row.flat === root.current
								readonly property var kept: Places.saved[row.modelData.id] ?? null

								width: section.width
								height: 58
								radius: Theme.radius.medium
								color: row.selected ? Theme.layer2 : "transparent"
								pressedScale: 0.98
								opacity: 0
								onClicked: root.openPlace(row.modelData, rowAvatar)
								onEntered: if (Pointer.moved(row, 0, 0)) root.current = row.flat
								Component.onCompleted: {
									rowRepeater.rowItems[row.flat] = row;
									comeIn.start();
								}
								Component.onDestruction: if (rowRepeater.rowItems[row.flat] === row) delete rowRepeater.rowItems[row.flat]

								Behavior on color {
									ColorAnim {}
								}

								transform: Translate {
									id: rowLift

									y: 8
								}

								ParallelAnimation {
									id: comeIn

									SequentialAnimation {
										PauseAnimation { duration: Math.min(row.flat, 12) * 28 }
										Anim { target: row; property: "opacity"; to: 1; duration: Motion.long }
									}
									SequentialAnimation {
										PauseAnimation { duration: Math.min(row.flat, 12) * 28 }
										SpatialAnim { target: rowLift; property: "y"; to: 0; duration: Motion.extraLong }
									}
								}

								// the selection's edge
								Rectangle {
									anchors.left: parent.left
									anchors.verticalCenter: parent.verticalCenter
									width: 3
									height: row.selected ? 26 : 0
									radius: 2
									color: Theme.primary

									Behavior on height {
										SpatialAnim {}
									}
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 12
									anchors.rightMargin: 12
									spacing: 12

									Avatar {
										id: rowAvatar

										item: row.modelData
										path: row.modelData.avatar ?? row.kept?.avatar ?? ""
										size: 40
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 2

										RowLayout {
											Layout.fillWidth: true
											spacing: 8

											StyledText {
												Layout.fillWidth: implicitWidth > parent.width - kindPill.implicitWidth - 40
												text: row.modelData.name
												elide: Text.ElideRight
												font.pixelSize: Theme.size.body + 1
												font.weight: Font.DemiBold
											}

											Rectangle {
												id: kindPill

												implicitWidth: kindText.implicitWidth + 14
												implicitHeight: 18
												radius: 9
												color: Qt.alpha(root.kindColor(row.modelData), 0.14)

												StyledText {
													id: kindText

													anchors.centerIn: parent
													text: [row.modelData.kindLabel].concat((row.modelData.cuisine ?? []).slice(0, 2)).filter(part => part).join(" · ")
													tone: root.kindColor(row.modelData)
													font.pixelSize: Theme.size.tiny
													font.weight: Font.DemiBold
												}
											}

											Glyph {
												visible: row.kept?.list === "want" || row.kept?.list === "been"
												icon: row.kept?.list === "been" ? "check_circle" : "bookmark"
												size: 13
												color: Theme.primary
											}

											Row {
												visible: (row.kept?.stars ?? 0) > 0
												spacing: 1

												Repeater {
													model: row.kept?.stars ?? 0

													delegate: Glyph {
														icon: "star"
														size: 11
														color: Theme.warning
													}
												}
											}

											Item {
												Layout.fillWidth: true
											}
										}

										StyledText {
											Layout.fillWidth: true
											text: [root.addressOf(row.modelData), row.modelData.district && row.modelData.district !== row.modelData.city ? row.modelData.district : ""].filter(part => part).join("  ·  ")
											tone: Theme.textMuted
											elide: Text.ElideRight
											font.pixelSize: Theme.size.small
										}
									}

									OpenBadge {
										hours: row.modelData.hours ?? null
									}

									StyledText {
										visible: text !== ""
										text: root.distanceText(row.modelData.distance)
										tone: Theme.textSubtle
										tabular: true
										font.pixelSize: Theme.size.small
										font.weight: Font.DemiBold
									}

									Glyph {
										icon: "chevron_right"
										size: 16
										color: Theme.textSubtle
										opacity: row.selected || row.hovered ? 1 : 0

										Behavior on opacity {
											Anim {}
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	// ── places to compare, waiting at the bottom ────────────────────────
	Rectangle {
		id: compareTray

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: 52
		radius: Theme.radius.large
		color: Theme.layer2
		visible: Places.compare.length > 0 && !root.showingPlace && !root.comparingOpen
		opacity: visible ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 8
			spacing: 8

			Glyph {
				icon: "compare_horizontal"
				size: 16
				color: Theme.primary
			}

			Repeater {
				model: Places.compare

				delegate: Avatar {
					required property var modelData

					item: modelData
					path: modelData.avatar ?? ""
					size: 30
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: Places.compare.map(item => item.name).join("  ·  ")
				elide: Text.ElideRight
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			TextButton {
				text: "Compare"
				enabled: Places.compare.length >= 2
				onActivated: root.compareShown = true
			}

			IconButton {
				width: 30
				height: 30
				icon: "close"
				iconSize: 15
				onClicked: Places.clearCompare()
			}
		}
	}

	// ── a place ─────────────────────────────────────────────────────────
	Item {
		id: placePage

		readonly property var place: Places.place
		readonly property var brief: Places.place ?? Places.opening
		readonly property var kept: Places.saved[placePage.brief?.id ?? ""] ?? null
		readonly property bool hasPhotos: Places.photos.length > 0
		readonly property bool hasMap: Places.map !== null

		anchors.fill: parent
		opacity: root.showingPlace && !root.comparingOpen ? 1 : 0
		visible: opacity > 0.01
		enabled: root.showingPlace && !root.comparingOpen
		transform: Translate {
			id: placeShift

			x: root.showingPlace ? 0 : 50

			Behavior on x {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		RowLayout {
			anchors.fill: parent
			spacing: 18

			Flickable {
				id: detailFlick

				Layout.fillWidth: true
				Layout.fillHeight: true
				contentHeight: detailColumn.implicitHeight + 16
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				ColumnLayout {
					id: detailColumn

					width: detailFlick.width - 12
					spacing: 0

					// ── who it is ──
					RowLayout {
						Layout.fillWidth: true
						spacing: 16

						Item {
							id: headerAvatarSlot

							Layout.preferredWidth: 84
							Layout.preferredHeight: 84
							Layout.alignment: Qt.AlignTop

							Avatar {
								id: headerAvatar

								anchors.fill: parent
								item: placePage.brief
								path: Places.avatar
								size: 84
								opacity: flight.running ? 0 : 1
							}

							// a ring that goes out once when the picture lands
							Rectangle {
								id: landing

								anchors.centerIn: parent
								width: 84
								height: 84
								radius: 42
								color: "transparent"
								border.width: 2
								border.color: root.kindColor(placePage.brief)
								opacity: 0
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							Layout.alignment: Qt.AlignVCenter
							spacing: 4

							Reveal {
								order: 0
								rise: 16
								Layout.fillWidth: true

								StyledText {
									width: parent.width
									text: placePage.brief?.name ?? ""
									wrapMode: Text.Wrap
									maximumLineCount: 2
									elide: Text.ElideRight
									font.pixelSize: text.length > 34 ? 22 : 28
									font.weight: Font.Bold
									font.letterSpacing: -0.5
								}
							}

							Reveal {
								order: 1
								Layout.fillWidth: true

								Flow {
									width: parent.width
									spacing: 6

									Rectangle {
										implicitWidth: kindLabel.implicitWidth + 16
										implicitHeight: 22
										radius: 11
										color: Qt.alpha(root.kindColor(placePage.brief), 0.15)

										StyledText {
											id: kindLabel

											anchors.centerIn: parent
											text: placePage.brief?.kindLabel ?? ""
											tone: root.kindColor(placePage.brief)
											font.pixelSize: Theme.size.small
											font.weight: Font.Bold
										}
									}

									Repeater {
										model: (placePage.brief?.cuisine ?? []).slice(0, 3)

										delegate: Rectangle {
											required property string modelData

											implicitWidth: cuisineText.implicitWidth + 16
											implicitHeight: 22
											radius: 11
											color: Theme.layer2

											StyledText {
												id: cuisineText

												anchors.centerIn: parent
												text: parent.modelData
												tone: Theme.textMuted
												font.pixelSize: Theme.size.small
												font.weight: Font.DemiBold
											}
										}
									}

									OpenBadge {
										hours: placePage.place?.hours ?? placePage.brief?.hours ?? null
										large: false
										implicitHeight: 22
									}
								}
							}

							Reveal {
								order: 2
								Layout.fillWidth: true

								StyledText {
									width: parent.width
									text: placePage.place?.address || root.addressOf(placePage.brief)
									tone: Theme.textMuted
									wrapMode: Text.Wrap
									font.pixelSize: Theme.size.body
								}
							}
						}
					}

					// ── what can be done ──
					Reveal {
						order: 3
						Layout.fillWidth: true
						Layout.topMargin: 16

						Flow {
							width: parent.width
							spacing: 6

							ActionChip {
								icon: "star"
								text: "Reviews"
								lit: true
								accent: Theme.primary
								onClicked: root.reviews()
							}

							ActionChip {
								icon: "navigation_variant"
								text: "Route"
								onClicked: root.external(Places.routeUrl(placePage.brief))
							}

							ActionChip {
								visible: (placePage.place?.website ?? "") !== ""
								icon: "web"
								text: "Website"
								onClicked: root.website()
							}

							ActionChip {
								visible: (placePage.place?.phone ?? "") !== ""
								icon: "phone"
								text: placePage.place?.phone ?? ""
								onClicked: root.number()
							}

							ActionChip {
								visible: Phone.offered && Phone.connected
								icon: "cellphone"
								onClicked: root.toPhone()
							}

							ActionChip {
								visible: NasCalendar.enabled
								icon: "calendar_plus"
								onClicked: root.toCalendar()
							}

							ActionChip {
								icon: "content_copy"
								onClicked: root.copy(placePage.place?.address || root.addressOf(placePage.brief))
							}

							ActionChip {
								icon: "bookmark"
								text: "Want to go"
								lit: placePage.kept?.list === "want"
								onClicked: Places.toggleList(placePage.place ?? placePage.brief, "want")
							}

							ActionChip {
								icon: "check_circle"
								text: "Been there"
								lit: placePage.kept?.list === "been"
								accent: Theme.success
								onClicked: Places.toggleList(placePage.place ?? placePage.brief, "been")
							}

							ActionChip {
								icon: "compare_horizontal"
								text: Places.compare.length > 0 && !Places.comparing(placePage.brief?.id) ? `Compare (${Places.compare.length})` : "Compare"
								lit: Places.comparing(placePage.brief?.id ?? "")
								enabled: placePage.place !== null
								onClicked: Places.toggleCompare(placePage.place)
							}
						}
					}

					// ── loading ──
					ColumnLayout {
						Layout.fillWidth: true
						Layout.topMargin: 22
						visible: placePage.place === null && Places.placeState === "loading"
						spacing: 10

						Shimmer { Layout.fillWidth: true; Layout.preferredHeight: 12 }
						Shimmer { Layout.fillWidth: true; Layout.rightMargin: 60; Layout.preferredHeight: 12 }
						Shimmer { Layout.fillWidth: true; Layout.rightMargin: 140; Layout.preferredHeight: 12 }
						RowLayout {
							Layout.fillWidth: true
							Layout.topMargin: 10
							spacing: 10

							Repeater {
								model: 4

								delegate: Shimmer {
									Layout.fillWidth: true
									Layout.preferredHeight: 74
									radius: Theme.radius.large
								}
							}
						}
					}

					EmptyState {
						Layout.fillWidth: true
						Layout.topMargin: 30
						visible: Places.placeState === "error" || Places.placeState === "none"
						icon: "wifi_off"
						title: "No answer"
						subtitle: Places.placeError
					}

					// ── what it is ──
					Reveal {
						order: 4
						visible: (Places.about?.summary ?? "") !== ""
						Layout.fillWidth: true
						Layout.topMargin: 20

						ColumnLayout {
							width: parent.width
							spacing: 4

							StyledText {
								Layout.fillWidth: true
								text: Places.about?.summary ?? ""
								wrapMode: Text.Wrap
								maximumLineCount: aboutMore.open ? 30 : 4
								elide: Text.ElideRight
								lineHeight: 1.2
								font.pixelSize: Theme.size.body + 1

								TapHandler {
									id: aboutMore

									property bool open: false
									onTapped: aboutMore.open = !aboutMore.open
								}
							}

							StyledText {
								text: Places.about?.source ?? ""
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
								font.weight: Font.DemiBold
								font.capitalization: Font.AllUppercase
								font.letterSpacing: 0.6
							}
						}
					}

					// ── getting there ──
					Reveal {
						order: 5
						visible: Places.routes !== null
						Layout.fillWidth: true
						Layout.topMargin: 22

						ColumnLayout {
							width: parent.width
							spacing: 8

							SectionLabel {
								text: Places.originName !== "" ? `Getting there · from ${Places.originName}` : "Getting there"
							}

							RowLayout {
								Layout.fillWidth: true
								spacing: 8

								Repeater {
									model: [
										{ id: "walk", icon: "walk", label: "Walk" },
										{ id: "bike", icon: "bike", label: "Bike" },
										{ id: "transit", icon: "bus", label: "Bus & train" },
										{ id: "car", icon: "car", label: "Car" }
									].filter(way => Places.routes?.[way.id])

									delegate: Card {
										id: way

										required property var modelData
										required property int index
										readonly property var trip: Places.routes?.[way.modelData.id] ?? null
										readonly property int fastest: Math.min.apply(null, ["walk", "bike", "transit", "car"].map(id => Places.routes?.[id]?.min ?? 1e9))

										Layout.fillWidth: true
										Layout.preferredHeight: 86
										color: way.trip?.min === way.fastest ? Theme.primaryContainer : Theme.layer1
										scale: 0.9
										opacity: 0
										Component.onCompleted: wayIn.start()

										SequentialAnimation {
											id: wayIn

											PauseAnimation { duration: 80 * way.index }
											ParallelAnimation {
												SpatialAnim { target: way; property: "scale"; to: 1; duration: Motion.extraLong }
												Anim { target: way; property: "opacity"; to: 1; duration: Motion.long }
											}
										}

										ColumnLayout {
											anchors.fill: parent
											anchors.margins: 12
											spacing: 0

											RowLayout {
												spacing: 6

												Glyph {
													icon: way.modelData.icon
													size: 15
													color: Theme.primary
												}

												StyledText {
													text: way.modelData.label
													tone: Theme.textMuted
													font.pixelSize: Theme.size.small
													font.weight: Font.DemiBold
												}
											}

											Item {
												Layout.fillHeight: true
											}

											RowLayout {
												spacing: 3

												CountUp {
													Layout.alignment: Qt.AlignBaseline
													value: way.trip?.min ?? 0
													font.pixelSize: 24
													font.weight: Font.Bold
												}

												StyledText {
													Layout.alignment: Qt.AlignBaseline
													text: "min"
													tone: Theme.textMuted
													font.pixelSize: Theme.size.small
													font.weight: Font.DemiBold
												}
											}

											StyledText {
												Layout.fillWidth: true
												text: {
													const trip = way.trip;
													if (!trip) return "";
													if (way.modelData.id !== "transit") return `${String(trip.km).replace(".", ",")} km`;
													const lines = (trip.legs ?? []).filter(leg => leg.mode !== "WALK").map(leg => leg.line || leg.mode.toLowerCase());
													const depart = trip.depart ? new Date(trip.depart) : null;
													const at = depart && !isNaN(depart) ? Qt.formatTime(depart, "hh:mm") : "";
													return [lines.join(" → "), at].filter(part => part).join(" · ");
												}
												elide: Text.ElideRight
												tone: Theme.textSubtle
												font.pixelSize: Theme.size.tiny
											}
										}
									}
								}
							}
						}
					}

					// ── its week ──
					Reveal {
						order: 6
						visible: (placePage.place?.hours?.raw ?? "") !== ""
						Layout.fillWidth: true
						Layout.topMargin: 22

						ColumnLayout {
							id: week

							readonly property var hours: placePage.place?.hours ?? null
							readonly property int today: Places.dayIndex(Places.now)
							readonly property int minute: Places.now.getHours() * 60 + Places.now.getMinutes()

							width: parent.width
							spacing: 6

							SectionLabel {
								text: "Opening hours"
							}

							Repeater {
								model: week.hours?.parsed === false && (week.hours?.week ?? []).every(day => day.length === 0) ? 0 : 7

								delegate: RowLayout {
									id: day

									required property int index
									readonly property var ranges: week.hours?.week?.[day.index] ?? []
									readonly property bool isToday: day.index === week.today

									Layout.fillWidth: true
									spacing: 10

									StyledText {
										Layout.preferredWidth: 34
										text: Places.dayNames[day.index]
										tone: day.isToday ? Theme.primary : Theme.textMuted
										font.pixelSize: Theme.size.small
										font.weight: day.isToday ? Font.Bold : Font.DemiBold
									}

									Rectangle {
										id: track

										Layout.fillWidth: true
										Layout.preferredHeight: day.isToday ? 12 : 8
										radius: height / 2
										color: Theme.layer2

										Repeater {
											model: day.ranges

											delegate: Rectangle {
												id: segment

												required property var modelData
												required property int index

												x: track.width * segment.modelData[0] / 1440
												width: track.width * (segment.modelData[1] - segment.modelData[0]) / 1440 * segment.grow
												height: track.height
												radius: height / 2
												color: day.isToday ? Theme.primary : Qt.alpha(Theme.primary, 0.55)

												property real grow: 0

												SequentialAnimation on grow {
													running: placePage.visible
													PauseAnimation { duration: 350 + day.index * 55 + segment.index * 40 }
													NumberAnimation { to: 1; duration: 700; easing.type: Easing.OutCubic }
												}
											}
										}

										// now
										Rectangle {
											visible: day.isToday
											x: track.width * week.minute / 1440 - 1
											y: -4
											width: 2
											height: track.height + 8
											radius: 1
											color: Theme.text
										}
									}

									StyledText {
										Layout.preferredWidth: 150
										horizontalAlignment: Text.AlignRight
										text: day.ranges.length === 0 ? "Closed" : (day.ranges.length === 1 && day.ranges[0][0] === 0 && day.ranges[0][1] === 1440 ? "24 h" : day.ranges.map(range => `${Places.clock(range[0])}–${range[1] === 1440 ? "24:00" : Places.clock(range[1])}`).join(", "))
										tone: day.ranges.length === 0 ? Theme.textSubtle : (day.isToday ? Theme.text : Theme.textMuted)
										elide: Text.ElideLeft
										tabular: true
										font.pixelSize: Theme.size.small
										font.weight: day.isToday ? Font.DemiBold : Font.Normal
									}
								}
							}

							StyledText {
								Layout.fillWidth: true
								visible: week.hours?.parsed === false
								text: week.hours?.raw ?? ""
								wrapMode: Text.Wrap
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
								font.family: Theme.monoFamily
							}
						}
					}

					// ── its weather ──
					Reveal {
						order: 7
						visible: (Places.weather?.hours ?? []).length > 0
						Layout.fillWidth: true
						Layout.topMargin: 22

						ColumnLayout {
							width: parent.width
							spacing: 8

							SectionLabel {
								text: "Weather there"
							}

							RowLayout {
								Layout.fillWidth: true
								spacing: 4

								Repeater {
									model: (Places.weather?.hours ?? []).slice(0, 10)

									delegate: Card {
										id: hour

										required property var modelData
										required property int index

										Layout.fillWidth: true
										Layout.preferredHeight: 84
										color: hour.index === 0 ? Theme.primaryContainer : Theme.layer1
										opacity: 0
										Component.onCompleted: hourIn.start()

										transform: Translate {
											id: hourLift

											y: 10
										}

										ParallelAnimation {
											id: hourIn

											SequentialAnimation {
												PauseAnimation { duration: 500 + hour.index * 45 }
												Anim { target: hour; property: "opacity"; to: 1; duration: Motion.long }
											}
											SequentialAnimation {
												PauseAnimation { duration: 500 + hour.index * 45 }
												SpatialAnim { target: hourLift; property: "y"; to: 0; duration: Motion.extraLong }
											}
										}

										ColumnLayout {
											anchors.centerIn: parent
											spacing: 3

											StyledText {
												Layout.alignment: Qt.AlignHCenter
												text: hour.index === 0 ? "Now" : hour.modelData.time
												tone: Theme.textMuted
												font.pixelSize: Theme.size.tiny
												font.weight: Font.DemiBold
											}

											Glyph {
												Layout.alignment: Qt.AlignHCenter
												icon: Places.weatherIcon(hour.modelData.code, hour.modelData.day)
												size: 20
												color: Theme.primary
											}

											StyledText {
												Layout.alignment: Qt.AlignHCenter
												text: `${hour.modelData.temp}°`
												font.pixelSize: Theme.size.body
												font.weight: Font.Bold
											}

											StyledText {
												Layout.alignment: Qt.AlignHCenter
												text: `${hour.modelData.rain}%`
												tone: hour.modelData.rain >= 50 ? Theme.primary : Theme.textSubtle
												opacity: hour.modelData.rain >= 10 ? 1 : 0
												font.pixelSize: Theme.size.tiny
											}
										}
									}
								}
							}
						}
					}

					// ── what it offers ──
					Reveal {
						order: 8
						visible: (placePage.place?.features ?? []).length > 0
						Layout.fillWidth: true
						Layout.topMargin: 22

						ColumnLayout {
							width: parent.width
							spacing: 8

							SectionLabel {
								text: "Good to know"
							}

							Flow {
								Layout.fillWidth: true
								spacing: 6

								Repeater {
									model: placePage.place?.features ?? []

									delegate: Rectangle {
										id: feature

										required property var modelData
										required property int index
										readonly property color tone: feature.modelData.state === "yes" ? Theme.success : (feature.modelData.state === "no" ? Theme.danger : Theme.warning)

										implicitWidth: featureRow.implicitWidth + 20
										implicitHeight: 28
										radius: 14
										color: Qt.alpha(feature.tone, 0.12)
										scale: 0.6
										opacity: 0
										Component.onCompleted: featureIn.start()

										SequentialAnimation {
											id: featureIn

											PauseAnimation { duration: 600 + feature.index * 40 }
											ParallelAnimation {
												SpatialAnim { target: feature; property: "scale"; to: 1; duration: Motion.extraLong }
												Anim { target: feature; property: "opacity"; to: 1; duration: Motion.long }
											}
										}

										RowLayout {
											id: featureRow

											anchors.centerIn: parent
											spacing: 6

											Glyph {
												icon: ({ wheelchair: "wheelchair_accessibility", vegan: "leaf", vegetarian: "leaf", outdoor: "seat_outline", wifi: "wifi", takeaway: "shopping", delivery: "truck_delivery_outline", drive: "car", dog: "dog", smoking: feature.modelData.state === "yes" ? "smoking_off" : "smoking", ac: "air_conditioner", reservation: "calendar_check", toilets: "toilet", baby: "baby_carriage", cards: "credit_card", cash: "cash", free: "hand_heart", self: "account_group" })[feature.modelData.id] ?? "check_circle_outline"
												size: 14
												color: feature.tone
											}

											StyledText {
												text: feature.modelData.label
												font.pixelSize: Theme.size.small
												font.weight: Font.DemiBold
											}
										}
									}
								}
							}
						}
					}

					// ── facts ──
					Reveal {
						id: factsReveal

						order: 9
						readonly property var facts: (placePage.place?.facts ?? []).concat((Places.about?.facts ?? []).filter(fact => !(placePage.place?.facts ?? []).some(other => other.label === fact.label)))

						visible: facts.length > 0
						Layout.fillWidth: true
						Layout.topMargin: 22

						Flow {
							width: parent.width
							spacing: 8

							Repeater {
								model: factsReveal.facts

								delegate: Card {
									id: fact

									required property var modelData

									implicitWidth: Math.max(96, factColumn.implicitWidth + 28)
									implicitHeight: factColumn.implicitHeight + 20

									ColumnLayout {
										id: factColumn

										anchors.centerIn: parent
										spacing: 1

										StyledText {
											text: fact.modelData.value
											font.pixelSize: Theme.size.title
											font.weight: Font.Bold
										}

										StyledText {
											text: fact.modelData.label
											tone: Theme.textMuted
											font.pixelSize: Theme.size.tiny
											font.weight: Font.DemiBold
										}
									}
								}
							}
						}
					}

					// ── mine ──
					Reveal {
						order: 10
						visible: placePage.place !== null
						Layout.fillWidth: true
						Layout.topMargin: 22

						ColumnLayout {
							width: parent.width
							spacing: 8

							SectionLabel {
								text: "My rating"
							}

							Row {
								spacing: 4

								Repeater {
									model: 5

									delegate: Clickable {
										id: star

										required property int index
										readonly property int stars: placePage.kept?.stars ?? 0
										readonly property bool lit: star.index < (starHover.hovered >= 0 ? starHover.hovered + 1 : star.stars)

										width: 32
										height: 32
										radius: 16
										color: "transparent"
										sound: "select"
										onClicked: Places.rate(placePage.place, star.index + 1)
										onEntered: starHover.hovered = star.index
										onExited: if (starHover.hovered === star.index) starHover.hovered = -1
										onStarsChanged: if (star.index < star.stars) pop.restart()

										Glyph {
											anchors.centerIn: parent
											icon: star.lit ? "star" : "star_outline"
											size: 24
											color: star.lit ? Theme.warning : Theme.textSubtle
											scale: 1

											SequentialAnimation on scale {
												id: pop

												running: false
												PauseAnimation { duration: star.index * 55 }
												NumberAnimation { to: 1.35; duration: 120; easing.type: Easing.OutQuad }
												NumberAnimation { to: 1; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 3 }
											}
										}
									}
								}

								QtObject {
									id: starHover

									property int hovered: -1
								}
							}

							AreaField {
								id: noteField

								Layout.fillWidth: true
								Layout.preferredHeight: Math.max(64, implicitHeight)
								placeholder: "Note"
								text: placePage.kept?.note ?? ""
								onEdited: text => noteTimer.restart()

								Timer {
									id: noteTimer

									interval: 600
									onTriggered: if (placePage.place) Places.note(placePage.place, noteField.text)
								}
							}
						}
					}

					// ── around it ──
					Reveal {
						order: 11
						visible: (Places.nearby?.similar ?? []).length > 0
						Layout.fillWidth: true
						Layout.topMargin: 22

						ColumnLayout {
							width: parent.width
							spacing: 8

							SectionLabel {
								text: `More ${placePage.brief?.kindLabel ?? ""} nearby`
							}

							ListView {
								id: similarList

								Layout.fillWidth: true
								Layout.preferredHeight: 108
								orientation: ListView.Horizontal
								spacing: 8
								clip: true
								model: Places.nearby?.similar ?? []
								boundsBehavior: Flickable.StopAtBounds

								delegate: Clickable {
									id: similar

									required property var modelData
									required property int index

									width: 168
									height: 108
									radius: Theme.radius.large
									color: Theme.layer1
									opacity: 0
									onClicked: root.openPlace(similar.modelData, similarAvatar)
									Component.onCompleted: similarIn.start()

									transform: Translate {
										id: similarSlide

										x: 30
									}

									ParallelAnimation {
										id: similarIn

										SequentialAnimation {
											PauseAnimation { duration: 650 + similar.index * 60 }
											Anim { target: similar; property: "opacity"; to: 1; duration: Motion.long }
										}
										SequentialAnimation {
											PauseAnimation { duration: 650 + similar.index * 60 }
											SpatialAnim { target: similarSlide; property: "x"; to: 0; duration: Motion.extraLong }
										}
									}

									ColumnLayout {
										anchors.fill: parent
										anchors.margins: 12
										spacing: 4

										Avatar {
											id: similarAvatar

											item: similar.modelData
											path: Places.saved[similar.modelData.id]?.avatar ?? ""
											size: 30
										}

										StyledText {
											Layout.fillWidth: true
											text: similar.modelData.name
											elide: Text.ElideRight
											font.pixelSize: Theme.size.label
											font.weight: Font.DemiBold
										}

										RowLayout {
											Layout.fillWidth: true
											spacing: 6

											StyledText {
												text: root.distanceText(similar.modelData.distance)
												tone: Theme.textSubtle
												font.pixelSize: Theme.size.tiny
											}

											OpenBadge {
												hours: similar.modelData.hours ?? null
											}
										}
									}
								}
							}
						}
					}

					Reveal {
						order: 12
						visible: (Places.nearby?.stops ?? []).length > 0 || (Places.nearby?.parking ?? []).length > 0
						Layout.fillWidth: true
						Layout.topMargin: 16

						Flow {
							width: parent.width
							spacing: 6

							Repeater {
								model: (Places.nearby?.stops ?? []).concat(Places.nearby?.parking ?? [])

								delegate: Rectangle {
									id: stop

									required property var modelData

									implicitWidth: stopRow.implicitWidth + 20
									implicitHeight: 30
									radius: 15
									color: Theme.layer1

									RowLayout {
										id: stopRow

										anchors.centerIn: parent
										spacing: 6

										Glyph {
											icon: stop.modelData.kind === "parking" ? "parking" : (stop.modelData.kindLabel === "Bahnhof" ? "train" : "bus_stop")
											size: 14
											color: Theme.primary
										}

										StyledText {
											text: stop.modelData.name
											font.pixelSize: Theme.size.small
											font.weight: Font.DemiBold
										}

										StyledText {
											text: root.distanceText(stop.modelData.distance)
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.tiny
										}
									}
								}
							}
						}
					}

					// where the facts come from
					StyledText {
						Layout.topMargin: 20
						visible: placePage.place !== null
						text: "© OpenStreetMap contributors"
						tone: Theme.textFaint
						font.pixelSize: Theme.size.tiny
					}
				}
			}

			// ── its photos and its map ──
			ColumnLayout {
				id: side

				property int wanted: placePage.hasPhotos || placePage.hasMap ? Math.round(root.width * 0.38) : 0

				Layout.fillHeight: true
				// its parts fill it, not the row
				Layout.fillWidth: false
				Layout.preferredWidth: side.wanted
				Layout.maximumWidth: side.wanted
				spacing: 10
				clip: true

				Behavior on wanted {
					SpatialAnim {
						duration: Motion.extraLong
					}
				}

				// photos, one fading into the next
				ClippingRectangle {
					id: heroFrame

					property int index: 0
					property bool showingA: true
					readonly property var photo: Places.photos[Math.min(heroFrame.index, Places.photos.length - 1)] ?? null
					property string current: heroFrame.photo?.path ?? ""

					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.preferredHeight: placePage.hasMap ? 3 : 1
					visible: placePage.hasPhotos
					radius: Theme.radius.huge
					color: Theme.layer1

					onCurrentChanged: {
						if (heroFrame.current === "") {
							photoA.source = "";
							photoB.source = "";
							return;
						}
						const next = "file://" + heroFrame.current;
						if (heroFrame.showingA) photoB.source = next;
						else photoA.source = next;
						heroFrame.showingA = !heroFrame.showingA;
					}

					Image {
						id: photoA

						readonly property bool front: heroFrame.showingA
						readonly property bool shown: photoA.front && photoA.status === Image.Ready
						property real settle: photoA.shown ? 1 : 1.12

						anchors.fill: parent
						asynchronous: true
						fillMode: Image.PreserveAspectCrop
						sourceSize.width: 900
						smooth: true
						mipmap: true
						opacity: photoA.shown ? 1 : 0
						scale: photoA.settle * (photoA.front ? drift.zoom : 1)

						Behavior on opacity {
							Anim {
								duration: Motion.extraLong
							}
						}
						Behavior on settle {
							SpatialAnim {
								duration: 1400
							}
						}
					}

					Image {
						id: photoB

						readonly property bool front: !heroFrame.showingA
						readonly property bool shown: photoB.front && photoB.status === Image.Ready
						property real settle: photoB.shown ? 1 : 1.12

						anchors.fill: parent
						asynchronous: true
						fillMode: Image.PreserveAspectCrop
						sourceSize.width: 900
						smooth: true
						mipmap: true
						opacity: photoB.shown ? 1 : 0
						scale: photoB.settle * (photoB.front ? drift.zoom : 1)

						Behavior on opacity {
							Anim {
								duration: Motion.extraLong
							}
						}
						Behavior on settle {
							SpatialAnim {
								duration: 1400
							}
						}
					}

					QtObject {
						id: drift

						property real zoom: 1.0
					}

					SequentialAnimation {
						running: root.active && placePage.visible && placePage.hasPhotos
						loops: Animation.Infinite

						NumberAnimation { target: drift; property: "zoom"; from: 1.0; to: 1.07; duration: 9000; easing.type: Easing.InOutSine }
						NumberAnimation { target: drift; property: "zoom"; from: 1.07; to: 1.0; duration: 9000; easing.type: Easing.InOutSine }
					}

					Rectangle {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						height: creditColumn.implicitHeight + 40
						gradient: Gradient {
							GradientStop { position: 0; color: "transparent" }
							GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.6) }
						}

						ColumnLayout {
							id: creditColumn

							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.margins: 12
							spacing: 1

							StyledText {
								Layout.fillWidth: true
								visible: text !== ""
								text: heroFrame.photo?.caption ?? ""
								surface: "transparent"
								tone: "white"
								elide: Text.ElideRight
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								text: heroFrame.photo?.credit ?? ""
								surface: "transparent"
								tone: Qt.rgba(1, 1, 1, 0.66)
								font.pixelSize: Theme.size.tiny
							}
						}
					}

					Row {
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: 14
						spacing: 4
						visible: Places.photos.length > 1

						Repeater {
							model: Places.photos.length

							delegate: Rectangle {
								required property int index

								width: index === heroFrame.index ? 16 : 6
								height: 6
								radius: 3
								color: index === heroFrame.index ? "white" : Qt.rgba(1, 1, 1, 0.5)

								Behavior on width {
									SpatialAnim {
										duration: Motion.medium
									}
								}
							}
						}
					}

					HoverHandler {
						id: photoHover
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							const paths = Places.photos.map(photo => photo.path);
							if (paths.length === 0) return;
							root.closeRequested();
							viewerLater.path = paths[heroFrame.index];
							viewerLater.list = paths;
							viewerLater.restart();
						}
						onWheel: wheel => {
							const count = Places.photos.length;
							if (count > 1) heroFrame.index = (heroFrame.index + (wheel.angleDelta.y < 0 ? 1 : count - 1)) % count;
						}
					}

					Timer {
						interval: 5500
						repeat: true
						running: root.active && placePage.visible && Places.photos.length > 1 && !photoHover.hovered
						onTriggered: heroFrame.index = (heroFrame.index + 1) % Places.photos.length
					}
				}

				// the map, with a pin that drops in
				ClippingRectangle {
					id: mapFrame

					readonly property var map: Places.map
					readonly property real fit: mapFrame.map ? Math.max(mapFrame.width / mapFrame.map.width, mapFrame.height / mapFrame.map.height) : 1

					function project(lat, lon) {
						const map = mapFrame.map;
						const n = Math.pow(2, map.zoom);
						const x = (lon + 180) / 360 * n * map.tile;
						const rad = lat * Math.PI / 180;
						const y = (1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2 * n * map.tile;
						return Qt.point(mapFrame.width / 2 + (x - map.x0 - map.width / 2) * mapFrame.fit * mapZoom.scale, mapFrame.height / 2 + (y - map.y0 - map.height / 2) * mapFrame.fit * mapZoom.scale);
					}

					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.preferredHeight: placePage.hasPhotos ? 2 : 1
					visible: placePage.hasMap
					radius: Theme.radius.huge
					color: Theme.layer1

					Image {
						id: mapImage

						anchors.centerIn: parent
						width: (mapFrame.map?.width ?? 0) * mapFrame.fit
						height: (mapFrame.map?.height ?? 0) * mapFrame.fit
						source: mapFrame.map ? "file://" + mapFrame.map.path : ""
						asynchronous: true
						smooth: true
						mipmap: true
						opacity: status === Image.Ready ? 1 : 0
						transform: Scale {
							id: mapZoom

							origin.x: mapImage.width / 2
							origin.y: mapImage.height / 2
							xScale: mapZoom.scale
							yScale: mapZoom.scale

							property real scale: 1.25
						}
						onStatusChanged: if (status === Image.Ready) settleMap.restart()

						Behavior on opacity {
							Anim {
								duration: Motion.extraLong
							}
						}

						NumberAnimation {
							id: settleMap

							target: mapZoom
							property: "scale"
							from: 1.25
							to: 1
							duration: 1600
							easing.type: Easing.OutCubic
						}
					}

					// stops and car parks around
					Repeater {
						model: mapFrame.map ? (Places.nearby?.stops ?? []).concat(Places.nearby?.parking ?? []) : []

						delegate: Rectangle {
							id: marker

							required property var modelData
							required property int index
							readonly property point at: mapFrame.project(marker.modelData.lat, marker.modelData.lon)

							x: marker.at.x - width / 2
							y: marker.at.y - height / 2
							width: 22
							height: 22
							radius: 11
							color: Theme.base
							border.width: 2
							border.color: Theme.primary
							visible: marker.at.x > 0 && marker.at.y > 0 && marker.at.x < mapFrame.width && marker.at.y < mapFrame.height
							scale: 0
							Component.onCompleted: markerIn.start()

							SequentialAnimation {
								id: markerIn

								PauseAnimation { duration: 1300 + marker.index * 90 }
								SpatialAnim { target: marker; property: "scale"; to: 1; duration: Motion.extraLong }
							}

							Glyph {
								anchors.centerIn: parent
								icon: marker.modelData.kind === "parking" ? "parking" : (marker.modelData.kindLabel === "Bahnhof" ? "train" : "bus")
								size: 12
								color: Theme.primary
							}
						}
					}

					// the place
					Item {
						id: pin

						readonly property point at: mapFrame.map && placePage.brief ? mapFrame.project(placePage.brief.lat, placePage.brief.lon) : Qt.point(mapFrame.width / 2, mapFrame.height / 2)
						property real drop: -40

						x: pin.at.x
						y: pin.at.y
						visible: mapImage.status === Image.Ready

						onVisibleChanged: if (pin.visible) pinDrop.restart()

						SequentialAnimation {
							id: pinDrop

							PropertyAction { target: pin; property: "drop"; value: -60 }
							PropertyAction { target: pinShape; property: "opacity"; value: 0 }
							PauseAnimation { duration: 700 }
							PropertyAction { target: pinShape; property: "opacity"; value: 1 }
							NumberAnimation { target: pin; property: "drop"; to: 0; duration: 650; easing.type: Easing.OutBounce }
							ScriptAction { script: pulse.restart() }
						}

						Rectangle {
							id: pulseRing

							anchors.centerIn: parent
							width: 16
							height: 16
							radius: width / 2
							color: Qt.alpha(root.kindColor(placePage.brief), 0.35)
							opacity: 0
						}

						SequentialAnimation {
							id: pulse

							loops: Animation.Infinite
							ParallelAnimation {
								NumberAnimation { target: pulseRing; property: "scale"; from: 1; to: 5; duration: 1800; easing.type: Easing.OutCubic }
								NumberAnimation { target: pulseRing; property: "opacity"; from: 0.9; to: 0; duration: 1800; easing.type: Easing.OutCubic }
							}
							PauseAnimation { duration: 400 }
						}

						Item {
							id: pinShape

							x: -width / 2
							y: -height + pin.drop
							width: 36
							height: 44

							Rectangle {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 2
								width: 32
								height: 32
								radius: 16
								color: root.kindColor(placePage.brief)
								border.width: 3
								border.color: "white"
							}

							Rectangle {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 30
								width: 10
								height: 10
								rotation: 45
								color: "white"
								z: -1
							}

							Glyph {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 9
								icon: root.kindGlyph(placePage.brief)
								size: 16
								color: "white"
								surface: root.kindColor(placePage.brief)
							}
						}
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: root.external(Places.osmUrl(placePage.place ?? placePage.brief))
					}

					StyledText {
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 8
						text: "© OpenStreetMap"
						tone: Theme.textMuted
						surface: "transparent"
						font.pixelSize: 9
					}
				}
			}
		}
	}

	// the picture of the opened row, on its way into the header
	Avatar {
		id: flyer

		visible: flight.running
		item: placePage.brief
		path: Places.avatar
		size: 84
		width: 84
		height: 84
	}

	ParallelAnimation {
		id: flight

		property point to: Qt.point(0, 0)

		NumberAnimation { target: flyer; property: "x"; from: root.flightFrom.x + root.flightFrom.width / 2 - 42; to: flight.to.x; duration: 520; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasized }
		NumberAnimation { target: flyer; property: "y"; from: root.flightFrom.y + root.flightFrom.height / 2 - 42; to: flight.to.y; duration: 520; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasized }
		NumberAnimation { target: flyer; property: "scale"; from: Math.max(0.2, root.flightFrom.width / 84); to: 1; duration: 520; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasized }
		onFinished: landed.restart()
	}

	ParallelAnimation {
		id: landed

		NumberAnimation { target: landing; property: "scale"; from: 1; to: 1.5; duration: 700; easing.type: Easing.OutCubic }
		NumberAnimation { target: landing; property: "opacity"; from: 0.8; to: 0; duration: 700; easing.type: Easing.OutCubic }
	}

	Connections {
		target: Places

		function onOpeningChanged() {
			if (Places.opening === null) return;
			if (root.flying) {
				// the header is laid out once the page shows: aim then
				Qt.callLater(() => {
					const point = headerAvatarSlot.mapToItem(root, 0, 0);
					// the page still slides in: aim where it ends up
					flight.to = Qt.point(point.x - placeShift.x, point.y);
					flight.restart();
				});
			} else {
				landed.restart();
			}
		}
	}

	Timer {
		id: viewerLater

		property string path: ""
		property var list: []
		interval: Motion.medium
		onTriggered: Viewer.open(viewerLater.path, { list: viewerLater.list })
	}

	// ── side by side ────────────────────────────────────────────────────
	Item {
		id: comparePage

		readonly property var places: Places.compare
		readonly property var featureIds: {
			const ids = [];
			for (const place of comparePage.places) for (const feature of place.features ?? []) if (!ids.includes(feature.id)) ids.push(feature.id);
			return ids;
		}
		readonly property var labels: {
			const out = {};
			for (const place of comparePage.places) for (const feature of place.features ?? []) out[feature.id] = out[feature.id] ?? feature.label;
			return out;
		}
		readonly property int fastestWalk: Math.min.apply(null, comparePage.places.map(place => place.routes?.walk?.min ?? 1e9))

		anchors.fill: parent
		opacity: root.comparingOpen ? 1 : 0
		visible: opacity > 0.01
		enabled: root.comparingOpen
		scale: root.comparingOpen ? 1 : 0.96

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.extraLong
			}
		}

		RowLayout {
			anchors.fill: parent
			spacing: 10

			Repeater {
				model: comparePage.places

				delegate: Card {
					id: column

					required property var modelData
					required property int index
					readonly property var state: Places.openState(column.modelData.hours)
					readonly property var kept: Places.saved[column.modelData.id] ?? null

					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.preferredWidth: 1
					opacity: 0

					transform: Translate {
						id: columnLift

						y: 24
					}

					Connections {
						target: root

						function onComparingOpenChanged() {
							if (root.comparingOpen) columnIn.restart();
						}
					}

					ParallelAnimation {
						id: columnIn

						SequentialAnimation {
							PauseAnimation { duration: column.index * 90 }
							Anim { target: column; property: "opacity"; from: 0; to: 1; duration: Motion.long }
						}
						SequentialAnimation {
							PauseAnimation { duration: column.index * 90 }
							SpatialAnim { target: columnLift; property: "y"; from: 24; to: 0; duration: Motion.extraLong }
						}
					}

					IconButton {
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: 8
						width: 26
						height: 26
						icon: "close"
						iconSize: 13
						onClicked: Places.toggleCompare(column.modelData)
					}

					ColumnLayout {
						anchors.fill: parent
						anchors.margins: 16
						spacing: 10

						// the head opens the place
						Clickable {
							Layout.fillWidth: true
							Layout.preferredHeight: compareHead.implicitHeight + 12
							radius: Theme.radius.medium
							color: "transparent"
							onClicked: root.openPlace(column.modelData, compareAvatar)

							ColumnLayout {
								id: compareHead

								anchors.centerIn: parent
								width: parent.width - 8
								spacing: 6

								Avatar {
									id: compareAvatar

									Layout.alignment: Qt.AlignHCenter
									item: column.modelData
									path: column.modelData.avatar ?? ""
									size: 56
								}

								StyledText {
									Layout.fillWidth: true
									horizontalAlignment: Text.AlignHCenter
									text: column.modelData.name
									wrapMode: Text.Wrap
									maximumLineCount: 2
									elide: Text.ElideRight
									font.pixelSize: Theme.size.title
									font.weight: Font.Bold
								}
							}
						}

						StyledText {
							Layout.fillWidth: true
							horizontalAlignment: Text.AlignHCenter
							text: [column.modelData.kindLabel].concat(column.modelData.cuisine ?? []).filter(part => part).join(" · ")
							tone: root.kindColor(column.modelData)
							elide: Text.ElideRight
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}

						OpenBadge {
							Layout.alignment: Qt.AlignHCenter
							hours: column.modelData.hours ?? null
						}

						Rectangle {
							Layout.fillWidth: true
							Layout.preferredHeight: 1
							color: Theme.outline
						}

						Repeater {
							model: [
								{ id: "walk", icon: "walk" },
								{ id: "bike", icon: "bike" },
								{ id: "transit", icon: "bus" },
								{ id: "car", icon: "car" }
							]

							delegate: RowLayout {
								id: travel

								required property var modelData
								readonly property var trip: column.modelData.routes?.[travel.modelData.id] ?? null

								Layout.fillWidth: true
								visible: travel.trip !== null
								spacing: 8

								Glyph {
									icon: travel.modelData.icon
									size: 15
									color: Theme.textMuted
								}

								Item {
									Layout.fillWidth: true
								}

								StyledText {
									text: `${travel.trip?.min ?? ""} min`
									tone: travel.modelData.id === "walk" && travel.trip?.min === comparePage.fastestWalk && comparePage.places.length > 1 ? Theme.success : Theme.text
									tabular: true
									font.pixelSize: Theme.size.body
									font.weight: Font.Bold
								}
							}
						}

						Row {
							Layout.alignment: Qt.AlignHCenter
							spacing: 2

							Repeater {
								model: 5

								delegate: Glyph {
									required property int index

									icon: index < (column.kept?.stars ?? 0) ? "star" : "star_outline"
									size: 16
									color: index < (column.kept?.stars ?? 0) ? Theme.warning : Theme.textFaint
								}
							}
						}

						Rectangle {
							Layout.fillWidth: true
							Layout.preferredHeight: 1
							color: Theme.outline
							visible: comparePage.featureIds.length > 0
						}

						Repeater {
							model: comparePage.featureIds.slice(0, 6)

							delegate: RowLayout {
								id: has

								required property string modelData
								readonly property var feature: (column.modelData.features ?? []).find(item => item.id === has.modelData) ?? null

								Layout.fillWidth: true
								spacing: 6

								Glyph {
									icon: has.feature ? (has.feature.state === "no" ? "close" : "check_circle") : "minus"
									size: 14
									color: has.feature ? (has.feature.state === "yes" ? Theme.success : (has.feature.state === "no" ? Theme.danger : Theme.warning)) : Theme.textFaint
								}

								StyledText {
									Layout.fillWidth: true
									text: has.feature?.label ?? comparePage.labels[has.modelData] ?? ""
									tone: has.feature ? Theme.text : Theme.textFaint
									elide: Text.ElideRight
									font.pixelSize: Theme.size.small
								}
							}
						}

						Item {
							Layout.fillHeight: true
						}
					}
				}
			}
		}
	}
}
