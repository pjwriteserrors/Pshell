#!/usr/bin/env python3
"""Finds places for the launcher's >wp and tells what is known about one.

  places.py suggest TEXT --lat LAT --lon LON
  places.py details OSM_ID --lat LAT --lon LON [--from LAT,LON] [--dark] [--refresh]
  places.py hours "Mo-Fr 09:00-18:00; Sa 10:00-14:00"

--city NAME stands for --lat/--lon when they are not known yet.

Everything comes from open sources, no keys: Photon (komoot) suggests places
near the given point while typing, and a word like "pizza" or "apotheke"
also lists what Overpass finds of that kind around it. A place (OSM_ID as
"N123", "W45", "R6") is read from Nominatim with all its tags, then in
parallel: Wikipedia/Wikidata or the place's own website for what it is and
its logo, Wikimedia Commons and Panoramax for photos, routing.openstreetmap.de
and Transitous for how long it takes to get there, Overpass for what is
around, Open-Meteo for its weather and CARTO tiles for a small map. What
does not change often is kept in ~/.cache/pshell/places for a week.

Prints JSON lines:
  {"type": "suggestions", "items": [place, ...]}
  {"type": "category", "label", "items": [place, ...]}
  {"type": "place", "id", "name", "kind", "kindLabel", "address", "street",
   "postcode", "city", "lat", "lon", "hours": {"week", "raw", "parsed", "always"},
   "phone", "website", "email", "cuisine": [...], "features": [{"id", "label", "state"}],
   "facts": [{"label", "value"}], "tags"}
  {"type": "about", "summary", "source", "url"}
  {"type": "image", "index", "role": "avatar"|"photo", "path", "caption", "credit"}
  {"type": "routes", "walk"|"bike"|"car": {"min", "km"}, "transit": {"min", "depart", "legs"}}
  {"type": "nearby", "similar": [place], "stops": [place], "parking": [place]}
  {"type": "weather", "now": {...}, "hours": [{"time", "temp", "code", "rain"}]}
  {"type": "map", "path", "zoom", "x0", "y0", "width", "height"}
  {"type": "none"} · {"type": "error", "error"} · {"type": "done"}
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import hashlib
import html
import io
import json
import math
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

AGENT = "pshell-places/1.0 (https://github.com/pjwriteserrors/Pshell) python-urllib"
BROWSER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pshell" / "places"
KEEP_DAYS = 7
OVERPASS = [
	"https://overpass-api.de/api/interpreter",
	"https://overpass.private.coffee/api/interpreter",
	"https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
# set when a source could not be asked (not when it simply has no answer):
# an answer with trouble is shown but not kept
TROUBLE = []
_say_lock = threading.Lock()


def say(**message):
	with _say_lock:
		print(json.dumps(message, ensure_ascii=False), flush=True)


def fetch(url, timeout=8, data=None, agent=AGENT, limit=None, headers=None):
	request = urllib.request.Request(url, data=data, headers={"User-Agent": agent, "Accept": "*/*", "Accept-Language": "de,en;q=0.7", **(headers or {})})
	with urllib.request.urlopen(request, timeout=timeout) as response:
		body = response.read(limit) if limit else response.read()
		return body, response.headers.get_content_type(), response.geturl()


def get_json(url, timeout=8, data=None):
	return json.loads(fetch(url, timeout, data)[0].decode("utf-8"))


def quiet(fn, *args, note=True):
	try:
		return fn(*args)
	except urllib.error.HTTPError as error:
		if note and error.code not in (404, 410):
			TROUBLE.append(f"{error.code} {error.reason}")
		return None
	except Exception as error:  # noqa: BLE001 – a source that fails is left out
		if note:
			TROUBLE.append(str(error))
		return None


_nominatim_lock = threading.Lock()
_nominatim_last = [0.0]


def nominatim(path, params, timeout=8):
	"""Nominatim, at most once a second as its policy asks."""
	with _nominatim_lock:
		wait = _nominatim_last[0] + 1.05 - time.monotonic()
		if wait > 0:
			time.sleep(wait)
		try:
			return quiet(get_json, f"https://nominatim.openstreetmap.org/{path}?" + urllib.parse.urlencode(params), timeout)
		finally:
			_nominatim_last[0] = time.monotonic()


def distance(lat1, lon1, lat2, lon2):
	r = 6371000
	p1, p2 = math.radians(lat1), math.radians(lat2)
	dp, dl = p2 - p1, math.radians(lon2 - lon1)
	a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
	return 2 * r * math.asin(math.sqrt(a))


# ── what kind of place, in words ────────────────────────────────────────────

KINDS = {
	"restaurant": "Restaurant", "fast_food": "Imbiss", "cafe": "Café", "bar": "Bar", "pub": "Kneipe",
	"biergarten": "Biergarten", "ice_cream": "Eiscafé", "nightclub": "Club", "pharmacy": "Apotheke",
	"doctors": "Arztpraxis", "dentist": "Zahnarzt", "hospital": "Krankenhaus", "clinic": "Klinik",
	"fuel": "Tankstelle", "charging_station": "Ladestation", "parking": "Parkplatz", "bank": "Bank",
	"atm": "Geldautomat", "post_office": "Post", "library": "Bibliothek", "cinema": "Kino",
	"theatre": "Theater", "school": "Schule", "university": "Universität", "kindergarten": "Kita",
	"place_of_worship": "Kirche", "townhall": "Rathaus", "police": "Polizei", "fire_station": "Feuerwehr",
	"toilets": "Toilette", "marketplace": "Markt", "museum": "Museum", "hotel": "Hotel", "hostel": "Hostel",
	"guest_house": "Pension", "attraction": "Sehenswürdigkeit", "viewpoint": "Aussichtspunkt",
	"artwork": "Kunstwerk", "zoo": "Zoo", "park": "Park", "playground": "Spielplatz",
	"fitness_centre": "Fitnessstudio", "sports_centre": "Sportzentrum", "swimming_pool": "Schwimmbad",
	"stadium": "Stadion", "supermarket": "Supermarkt", "bakery": "Bäckerei", "butcher": "Metzgerei",
	"kiosk": "Kiosk", "convenience": "Laden", "clothes": "Kleidung", "shoes": "Schuhe",
	"hairdresser": "Friseur", "chemist": "Drogerie", "doityourself": "Baumarkt", "hardware": "Eisenwaren",
	"electronics": "Elektronik", "mobile_phone": "Handyladen", "books": "Buchhandlung", "florist": "Blumen",
	"optician": "Optiker", "beverages": "Getränkemarkt", "department_store": "Kaufhaus", "mall": "Einkaufszentrum",
	"car_repair": "Autowerkstatt", "car": "Autohaus", "bicycle": "Fahrradladen", "furniture": "Möbel",
	"jewelry": "Schmuck", "gift": "Geschenke", "toys": "Spielwaren", "pet": "Tierbedarf", "beauty": "Kosmetik",
	"tattoo": "Tattoo", "laundry": "Waschsalon", "dry_cleaning": "Reinigung", "car_wash": "Waschanlage",
	"bus_stop": "Haltestelle", "station": "Bahnhof", "halt": "Haltepunkt", "tram_stop": "Haltestelle",
	"castle": "Burg", "monument": "Denkmal", "memorial": "Gedenkstätte", "ruins": "Ruine", "church": "Kirche",
	"cathedral": "Dom", "house": "Adresse", "street": "Straße", "residential": "Straße", "city": "Stadt",
	"town": "Stadt", "village": "Dorf", "suburb": "Stadtteil", "neighbourhood": "Viertel",
	"water": "Gewässer", "river": "Fluss", "lake": "See", "forest": "Wald", "wood": "Wald",
	"office": "Büro", "company": "Firma", "it": "IT-Firma", "coworking": "Coworking", "veterinary": "Tierarzt",
	"car_rental": "Autovermietung", "bicycle_rental": "Fahrradverleih", "ferry_terminal": "Fähre",
	"events_venue": "Veranstaltungsort", "community_centre": "Gemeinschaftszentrum", "arts_centre": "Kulturzentrum",
	"music_venue": "Musik", "bowling_alley": "Bowling", "escape_game": "Escape Room", "amusement_arcade": "Spielhalle",
	"camp_site": "Camping", "picnic_site": "Picknickplatz", "garden": "Garten", "nature_reserve": "Naturschutzgebiet",
}
CUISINES = {
	"pizza": "Pizza", "italian": "Italienisch", "kebab": "Döner", "burger": "Burger", "sushi": "Sushi",
	"japanese": "Japanisch", "chinese": "Chinesisch", "asian": "Asiatisch", "thai": "Thailändisch",
	"vietnamese": "Vietnamesisch", "indian": "Indisch", "greek": "Griechisch", "turkish": "Türkisch",
	"mexican": "Mexikanisch", "german": "Deutsch", "regional": "Regional", "american": "Amerikanisch",
	"steak_house": "Steakhaus", "chicken": "Hähnchen", "sandwich": "Sandwiches", "ice_cream": "Eis",
	"coffee_shop": "Kaffee", "cake": "Kuchen", "breakfast": "Frühstück", "vegan": "Vegan", "vegetarian": "Vegetarisch",
	"french": "Französisch", "spanish": "Spanisch", "korean": "Koreanisch", "lebanese": "Libanesisch",
	"syrian": "Syrisch", "arab": "Arabisch", "african": "Afrikanisch", "fish": "Fisch", "seafood": "Meeresfrüchte",
	"noodle": "Nudeln", "ramen": "Ramen", "bubble_tea": "Bubble Tea", "donut": "Donuts", "crepe": "Crêpes",
	"falafel": "Falafel", "bagel": "Bagels", "balkan": "Balkan", "polish": "Polnisch", "russian": "Russisch",
	"persian": "Persisch", "portuguese": "Portugiesisch", "tapas": "Tapas", "wings": "Wings", "hot_dog": "Hot Dogs",
	"fries": "Pommes", "friture": "Pommes", "bistro": "Bistro", "international": "International",
}

# what a typed word asks for: Overpass filters for "all of these around me"
CATEGORIES = [
	(("pizza", "pizzeria"), "Pizza", ['nwr["cuisine"~"pizza",i]']),
	(("döner", "doener", "kebab", "dürüm"), "Döner", ['nwr["cuisine"~"kebab",i]']),
	(("burger",), "Burger", ['nwr["cuisine"~"burger",i]']),
	(("sushi",), "Sushi", ['nwr["cuisine"~"sushi",i]']),
	(("italiener", "italienisch", "italian"), "Italienisch", ['nwr["cuisine"~"italian",i]']),
	(("asiatisch", "asia", "asian", "chinese", "chinesisch"), "Asiatisch", ['nwr["cuisine"~"asian|chinese|vietnamese|thai",i]']),
	(("thai",), "Thailändisch", ['nwr["cuisine"~"thai",i]']),
	(("vietnamesisch", "vietnam", "pho"), "Vietnamesisch", ['nwr["cuisine"~"vietnamese",i]']),
	(("indisch", "inder", "indian", "curry"), "Indisch", ['nwr["cuisine"~"indian",i]']),
	(("grieche", "griechisch", "greek"), "Griechisch", ['nwr["cuisine"~"greek",i]']),
	(("mexikanisch", "mexican", "tacos", "burrito"), "Mexikanisch", ['nwr["cuisine"~"mexican",i]']),
	(("steak", "steakhaus"), "Steakhaus", ['nwr["cuisine"~"steak",i]']),
	(("vegan",), "Vegan", ['nwr["diet:vegan"~"yes|only"]["amenity"~"restaurant|fast_food|cafe"]']),
	(("restaurant", "restaurants", "essen"), "Restaurants", ['nwr["amenity"="restaurant"]']),
	(("imbiss", "fastfood", "fast food", "fast_food"), "Imbiss", ['nwr["amenity"="fast_food"]']),
	(("café", "cafe", "cafés", "kaffee", "coffee"), "Cafés", ['nwr["amenity"="cafe"]']),
	(("eis", "eisdiele", "eiscafé", "eiscafe", "ice cream"), "Eis", ['nwr["amenity"="ice_cream"]', 'nwr["cuisine"~"ice_cream"]["amenity"="cafe"]']),
	(("bar", "bars", "kneipe", "pub", "kneipen", "cocktail"), "Bars", ['nwr["amenity"~"^(bar|pub)$"]']),
	(("biergarten",), "Biergärten", ['nwr["amenity"="biergarten"]']),
	(("club", "disco", "nightclub"), "Clubs", ['nwr["amenity"="nightclub"]']),
	(("bäcker", "bäckerei", "baecker", "bakery", "brötchen"), "Bäckereien", ['nwr["shop"="bakery"]']),
	(("supermarkt", "einkaufen", "supermarket", "lebensmittel"), "Supermärkte", ['nwr["shop"="supermarket"]']),
	(("getränke", "getränkemarkt"), "Getränkemärkte", ['nwr["shop"="beverages"]']),
	(("kiosk", "späti", "trinkhalle"), "Kioske", ['nwr["shop"="kiosk"]']),
	(("drogerie", "dm", "rossmann"), "Drogerien", ['nwr["shop"="chemist"]']),
	(("apotheke", "apotheken", "pharmacy"), "Apotheken", ['nwr["amenity"="pharmacy"]']),
	(("arzt", "ärzte", "hausarzt", "doctor"), "Ärzte", ['nwr["amenity"="doctors"]']),
	(("zahnarzt", "dentist"), "Zahnärzte", ['nwr["amenity"="dentist"]']),
	(("tierarzt", "vet"), "Tierärzte", ['nwr["amenity"="veterinary"]']),
	(("krankenhaus", "klinik", "notaufnahme"), "Krankenhäuser", ['nwr["amenity"="hospital"]']),
	(("tankstelle", "tanken", "fuel"), "Tankstellen", ['nwr["amenity"="fuel"]']),
	(("ladestation", "laden", "e-auto", "charging"), "Ladestationen", ['nwr["amenity"="charging_station"]']),
	(("parkplatz", "parken", "parkhaus", "parking"), "Parken", ['nwr["amenity"="parking"]']),
	(("geldautomat", "atm", "bargeld"), "Geldautomaten", ['nwr["amenity"="atm"]', 'nwr["amenity"="bank"]["atm"="yes"]']),
	(("bank", "banken", "sparkasse"), "Banken", ['nwr["amenity"="bank"]']),
	(("post", "postfiliale", "dhl", "packstation"), "Post", ['nwr["amenity"~"post_office|parcel_locker"]']),
	(("kino", "cinema"), "Kinos", ['nwr["amenity"="cinema"]']),
	(("theater",), "Theater", ['nwr["amenity"="theatre"]']),
	(("museum", "museen"), "Museen", ['nwr["tourism"="museum"]']),
	(("sehenswürdigkeit", "sehenswürdigkeiten", "sightseeing"), "Sehenswürdigkeiten", ['nwr["tourism"~"attraction|viewpoint"]', 'nwr["historic"~"castle|monument|memorial"]["name"]']),
	(("park", "parks"), "Parks", ['nwr["leisure"="park"]["name"]']),
	(("spielplatz", "spielplätze"), "Spielplätze", ['nwr["leisure"="playground"]']),
	(("fitness", "gym", "fitnessstudio"), "Fitnessstudios", ['nwr["leisure"="fitness_centre"]']),
	(("schwimmbad", "freibad", "hallenbad", "baden"), "Schwimmbäder", ['nwr["leisure"~"swimming_pool|water_park"]["access"!="private"]["name"]', 'nwr["leisure"="sports_centre"]["sport"="swimming"]']),
	(("friseur", "frisör", "barber", "barbershop"), "Friseure", ['nwr["shop"="hairdresser"]']),
	(("baumarkt",), "Baumärkte", ['nwr["shop"="doityourself"]']),
	(("hotel", "hotels", "übernachten"), "Hotels", ['nwr["tourism"~"hotel|guest_house|hostel"]']),
	(("bibliothek", "bücherei", "library"), "Bibliotheken", ['nwr["amenity"="library"]']),
	(("buchhandlung", "bücher", "books"), "Buchhandlungen", ['nwr["shop"="books"]']),
	(("toilette", "wc", "klo"), "Toiletten", ['nwr["amenity"="toilets"]']),
	(("haltestelle", "bus", "bahnhof"), "Haltestellen", ['node["highway"="bus_stop"]', 'nwr["railway"~"station|halt"]']),
	(("waschanlage", "autowäsche"), "Waschanlagen", ['nwr["amenity"="car_wash"]']),
	(("werkstatt", "autowerkstatt"), "Werkstätten", ['nwr["shop"="car_repair"]']),
	(("fahrrad", "fahrradladen", "bike"), "Fahrradläden", ['nwr["shop"="bicycle"]']),
	(("blumen", "florist"), "Blumenläden", ['nwr["shop"="florist"]']),
	(("optiker",), "Optiker", ['nwr["shop"="optician"]']),
	(("elektronik", "elektromarkt"), "Elektronik", ['nwr["shop"~"electronics|computer"]']),
	(("kirche", "kirchen"), "Kirchen", ['nwr["amenity"="place_of_worship"]["name"]']),
	(("bowling",), "Bowling", ['nwr["leisure"="bowling_alley"]']),
	(("escape", "escape room"), "Escape Rooms", ['nwr["leisure"="escape_game"]']),
]


def category_of(text):
	words = text.lower().strip()
	for names, label, filters in CATEGORIES:
		if words in names:
			return label, filters
	return None


def kind_of(tags):
	for key in ("amenity", "shop", "tourism", "leisure", "historic", "office", "craft", "healthcare", "railway", "highway", "place", "building", "natural", "landuse", "man_made"):
		value = tags.get(key)
		if value and value not in ("yes",):
			return key, value
	return "", ""


def kind_label(key, value, tags=None):
	tags = tags or {}
	if key == "amenity" and value == "place_of_worship":
		religion = tags.get("religion", "")
		return {"christian": "Kirche", "muslim": "Moschee", "jewish": "Synagoge", "buddhist": "Tempel"}.get(religion, "Gotteshaus")
	if key == "highway" and value not in ("bus_stop",):
		return "Straße"
	if key == "shop" and value not in KINDS:
		return value.replace("_", " ").capitalize()
	return KINDS.get(value) or value.replace("_", " ").capitalize()


def cuisines(tags):
	values = [part.strip() for part in re.split(r"[;,]", tags.get("cuisine", "")) if part.strip()]
	return [CUISINES.get(value, value.replace("_", " ").capitalize()) for value in values][:4]


# ── typing: what is meant ───────────────────────────────────────────────────

def from_photon(feature, lat, lon):
	props = feature.get("properties", {})
	coords = feature.get("geometry", {}).get("coordinates", [0, 0])
	osm_type = props.get("osm_type", "")
	osm_id = props.get("osm_id")
	if not osm_type or osm_id is None:
		return None
	key, value = props.get("osm_key", ""), props.get("osm_value", "")
	street = " ".join(part for part in (props.get("street", ""), props.get("housenumber", "")) if part)
	name = props.get("name") or street or props.get("city", "")
	if not name:
		return None
	city = props.get("city") or props.get("town") or props.get("village") or props.get("county", "")
	place = {
		"id": f"{osm_type}{osm_id}",
		"name": name,
		"key": key,
		"kind": value,
		"kindLabel": kind_label(key, value),
		"street": street if street != name else "",
		"postcode": props.get("postcode", ""),
		"city": city,
		"district": props.get("district") or props.get("locality", ""),
		"lat": coords[1],
		"lon": coords[0],
	}
	if math.isfinite(lat) and math.isfinite(lon):
		place["distance"] = round(distance(lat, lon, coords[1], coords[0]))
	return place


def suggest(text, lat, lon):
	params = {"q": text, "limit": 10, "lang": "de"}
	if math.isfinite(lat) and math.isfinite(lon):
		params.update(lat=f"{lat:.5f}", lon=f"{lon:.5f}", zoom=12, location_bias_scale=0.1)
	found = quiet(get_json, "https://photon.komoot.io/api/?" + urllib.parse.urlencode(params), 6)
	if found is None:
		return None
	items, seen = [], set()
	for feature in found.get("features", []):
		place = from_photon(feature, lat, lon)
		if place is None or place["id"] in seen:
			continue
		# the same shop as node and building: one is enough
		twin = f'{place["name"]}|{place["street"]}'
		if twin in seen:
			continue
		seen.update((place["id"], twin))
		items.append(place)
	# what is in reach first, Photon's order otherwise
	items.sort(key=lambda place: place.get("distance", 0) > 60_000)
	return items


def overpass(query, timeout=12):
	body = urllib.parse.urlencode({"data": query}).encode()
	last = None
	for server in OVERPASS:
		try:
			return json.loads(fetch(server, timeout, body)[0].decode("utf-8"))
		except Exception as error:  # noqa: BLE001 – the next server is asked
			last = error
	TROUBLE.append(f"overpass: {last}")
	return None


def element_place(element, lat, lon):
	tags = element.get("tags", {})
	point = element.get("center") or element
	if "lat" not in point:
		return None
	key, value = kind_of(tags)
	street = " ".join(part for part in (tags.get("addr:street", ""), tags.get("addr:housenumber", "")) if part)
	name = tags.get("name") or tags.get("brand") or ""
	if not name:
		return None
	place = {
		"id": element["type"][0].upper() + str(element["id"]),
		"name": name,
		"key": key,
		"kind": value,
		"kindLabel": kind_label(key, value, tags),
		"street": street,
		"postcode": tags.get("addr:postcode", ""),
		"city": tags.get("addr:city", ""),
		"lat": point["lat"],
		"lon": point["lon"],
		"cuisine": cuisines(tags),
	}
	if tags.get("opening_hours"):
		place["hours"] = parse_hours(tags["opening_hours"])
	if math.isfinite(lat) and math.isfinite(lon):
		place["distance"] = round(distance(lat, lon, point["lat"], point["lon"]))
	return place


# Nominatim knows kinds by a word ("Apotheke in …"); a cuisine is looked
# for among restaurants and snack bars
PHRASES = {
	"Restaurants": ["Restaurant"], "Imbiss": ["Imbiss"], "Cafés": ["Café"], "Eis": ["Eisdiele"],
	"Bars": ["Bar", "Kneipe"], "Biergärten": ["Biergarten"], "Clubs": ["Nachtclub"], "Bäckereien": ["Bäckerei"],
	"Supermärkte": ["Supermarkt"], "Getränkemärkte": ["Getränkemarkt"], "Kioske": ["Kiosk"], "Drogerien": ["Drogerie"],
	"Apotheken": ["Apotheke"], "Ärzte": ["Arzt"], "Zahnärzte": ["Zahnarzt"], "Tierärzte": ["Tierarzt"],
	"Krankenhäuser": ["Krankenhaus"], "Tankstellen": ["Tankstelle"], "Ladestationen": ["Ladestation"],
	"Parken": ["Parkplatz", "Parkhaus"], "Geldautomaten": ["Geldautomat"], "Banken": ["Bank"], "Post": ["Post"],
	"Kinos": ["Kino"], "Theater": ["Theater"], "Museen": ["Museum"], "Sehenswürdigkeiten": ["Sehenswürdigkeit", "Denkmal"],
	"Parks": ["Park"], "Spielplätze": ["Spielplatz"], "Fitnessstudios": ["Fitnessstudio"], "Schwimmbäder": ["Schwimmbad"],
	"Friseure": ["Friseur"], "Baumärkte": ["Baumarkt"], "Hotels": ["Hotel"], "Bibliotheken": ["Bibliothek"],
	"Buchhandlungen": ["Buchhandlung"], "Toiletten": ["Toilette"], "Haltestellen": ["Bushaltestelle", "Bahnhof"],
	"Waschanlagen": ["Autowaschanlage"], "Werkstätten": ["Autowerkstatt"], "Fahrradläden": ["Fahrradladen"],
	"Blumenläden": ["Blumenladen"], "Optiker": ["Optiker"], "Elektronik": ["Elektronikgeschäft"], "Kirchen": ["Kirche"],
	"Bowling": ["Bowling"], "Escape Rooms": ["Escape Room"], "Vegan": ["Restaurant", "Imbiss", "Café"],
}


def from_nominatim(row, lat, lon):
	tags = dict(row.get("extratags") or {})
	address = row.get("address") or {}
	name = row.get("name") or tags.get("brand") or ("Parkplatz" if row.get("type") == "parking" else "")
	if not name:
		return None
	key, value = row.get("category", ""), row.get("type", "")
	street = " ".join(part for part in (address.get("road", ""), address.get("house_number", "")) if part)
	place = {
		"id": {"node": "N", "way": "W", "relation": "R"}.get(row.get("osm_type"), "?") + str(row.get("osm_id")),
		"name": name,
		"key": key,
		"kind": value,
		"kindLabel": kind_label(key, value, tags),
		"street": street,
		"postcode": address.get("postcode", ""),
		"city": address.get("city") or address.get("town") or address.get("village", ""),
		"lat": float(row["lat"]),
		"lon": float(row["lon"]),
		"cuisine": cuisines(tags),
		"_cuisine": tags.get("cuisine", ""),
		"_diet": tags.get("diet:vegan", ""),
	}
	if tags.get("opening_hours"):
		place["hours"] = parse_hours(tags["opening_hours"])
	if math.isfinite(lat) and math.isfinite(lon):
		place["distance"] = round(distance(lat, lon, place["lat"], place["lon"]))
	return place


def nominatim_kind(label, filters, lat, lon, span=0.07):
	cuisine = next((re.search(r'"cuisine"~"([^"]+)"', f).group(1) for f in filters if '"cuisine"~' in f), "")
	types = set()
	for flt in filters:
		for match in re.finditer(r'"(?:amenity|shop|tourism|leisure|highway|railway|historic)"(?:=|~)"\^?\(?([^"$)]+)', flt):
			types.update(match.group(1).split("|"))
	phrases = PHRASES.get(label) or (["Restaurant", "Imbiss"] if cuisine else [label])
	viewbox = f"{lon - span * 1.6:.4f},{lat + span:.4f},{lon + span * 1.6:.4f},{lat - span:.4f}"
	items = []
	for phrase in phrases:
		rows = nominatim("search", {"q": phrase, "format": "jsonv2", "extratags": 1, "addressdetails": 1, "limit": 50, "bounded": 1, "viewbox": viewbox, "accept-language": "de"})
		for row in rows or []:
			place = from_nominatim(row, lat, lon)
			if place is None:
				continue
			if cuisine and not re.search(cuisine, place["_cuisine"], re.I) and not re.search(cuisine.replace("kebab", "kebab|döner"), place["name"], re.I):
				continue
			if label == "Vegan" and place["_diet"] not in ("yes", "only"):
				continue
			if types and not cuisine and place["kind"] not in types:
				continue
			items.append(place)
	return items


def tidy(items):
	out, seen = [], set()
	for place in sorted(items, key=lambda place: place.get("distance", 0)):
		twin = f'{place["name"]}|{place["street"]}'
		if place["id"] in seen or twin in seen:
			continue
		seen.update((place["id"], twin))
		out.append({k: v for k, v in place.items() if not k.startswith("_")})
	return out[:40]


def category(label, filters, lat, lon, radius=4000):
	"""Says what Nominatim knows of that kind, then what Overpass knows if
	that is more. Returns whether anything answered."""
	cached = CACHE / f"category-{hashlib.sha1(f'{label}|{lat:.3f}|{lon:.3f}'.encode()).hexdigest()[:16]}.json"
	if cached.exists() and time.time() - cached.stat().st_mtime < 86400:
		try:
			items = json.loads(cached.read_text())
			for place in items:
				if place.get("hours"):
					place["hours"] = parse_hours(place["hours"]["raw"])
			say(type="category", label=label, items=items)
			return True
		except ValueError:
			pass

	def from_overpass():
		parts = "".join(f"{flt}(around:{radius},{lat:.5f},{lon:.5f});" for flt in filters)
		found = overpass(f"[out:json][timeout:10];({parts});out center tags 120;", timeout=10)
		if found is None:
			return None
		return [p for p in (element_place(e, lat, lon) for e in found.get("elements", [])) if p]

	with concurrent.futures.ThreadPoolExecutor(2) as pool:
		slow = pool.submit(from_overpass)
		quick = tidy(nominatim_kind(label, filters, lat, lon))
		if quick:
			say(type="category", label=label, items=quick)
		full = slow.result()
	if full is not None and len(full) > len(quick):
		best = tidy(full + quick)
		say(type="category", label=label, items=best)
		cached.write_text(json.dumps(best, ensure_ascii=False))
	elif quick and full is not None:
		cached.write_text(json.dumps(quick, ensure_ascii=False))
	return bool(quick) or full is not None


# ── opening hours ───────────────────────────────────────────────────────────

DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def _minutes(text):
	hours, minutes = text.split(":")
	return int(hours) * 60 + int(minutes)


def _day_set(selector):
	days = set()
	for part in selector.split(","):
		part = part.strip()
		part = re.sub(r"\[[^\]]*\]", "", part)
		if "-" in part:
			start, end = part.split("-", 1)
			if start not in DAYS or end not in DAYS:
				return None
			i, j = DAYS.index(start), DAYS.index(end)
			days.update(range(i, j + 1) if i <= j else list(range(i, 7)) + list(range(0, j + 1)))
		elif part in DAYS:
			days.add(DAYS.index(part))
		elif part in ("PH", "SH"):
			continue
		else:
			return None
	return days


def _month_on(selector, today):
	month = today.month - 1
	for part in selector.split(","):
		part = part.strip()
		if "-" in part:
			start, end = (re.match(r"[A-Z][a-z]{2}", piece).group(0) for piece in part.split("-", 1))
			i, j = MONTHS.index(start), MONTHS.index(end)
			if (i <= month <= j) if i <= j else (month >= i or month <= j):
				return True
		elif part[:3] in MONTHS and MONTHS.index(part[:3]) == month:
			return True
	return False


def parse_hours(raw, today=None):
	"""OSM opening_hours → seven days (Monday first) of [start, end] minutes;
	a range past midnight goes on into the next day. What it cannot read is
	left out and "parsed" says so."""
	today = today or datetime.date.today()
	text = str(raw or "").strip()
	week = [[] for _ in range(7)]
	result = {"raw": text, "week": week, "parsed": True, "always": False}
	if text == "":
		result["parsed"] = False
		return result
	if text.replace(" ", "") == "24/7":
		result["always"] = True
		for day in week:
			day.append([0, 1440])
		return result
	for rule in re.split(r"\s*(?:;|\|\|)\s*", text):
		rule = re.sub(r'"[^"]*"', "", rule).strip().rstrip(",")
		if rule == "":
			continue
		month = re.match(r"^((?:[A-Z][a-z]{2}(?:\s?\d{1,2})?(?:-[A-Z][a-z]{2}(?:\s?\d{1,2})?)?,?\s*)+)\s+(?=[A-Z][a-z]|\d|off|closed)", rule)
		if month and re.match(r"^[A-Z][a-z]{2}", month.group(1)) and month.group(1)[:3] in MONTHS:
			if not _month_on(month.group(1), today):
				continue
			rule = rule[month.end():]
		if rule.startswith(("PH", "SH")) and not re.match(r"^(PH|SH)\s*,", rule):
			continue
		match = re.match(r"^([A-Za-z,\-\[\]\d\s]*?)\s*((?:\d{1,2}:\d{2}.*)|off|closed|24/7)?$", rule)
		if not match:
			result["parsed"] = False
			continue
		selector, times = (match.group(1) or "").strip(), (match.group(2) or "").strip()
		days = set(range(7)) if selector == "" else _day_set(selector.replace(" ", ""))
		if days is None or (times == "" and selector != ""):
			result["parsed"] = False
			continue
		if times in ("off", "closed"):
			for day in days:
				week[day] = []
			continue
		if times == "24/7":
			for day in days:
				week[day] = [[0, 1440]]
			continue
		ranges = []
		for span in times.split(","):
			span = span.strip()
			m = re.match(r"^(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\+?$", span)
			if m:
				start, end = _minutes(m.group(1)), _minutes(m.group(2))
				if end <= start:
					end += 1440
				ranges.append([start, end])
				continue
			m = re.match(r"^(\d{1,2}:\d{2})\+$", span)
			if m:
				ranges.append([_minutes(m.group(1)), 1440])
				continue
			result["parsed"] = False
		if not ranges:
			continue
		for day in days:
			week[day] = [list(r) for r in ranges]
	# past midnight: the rest belongs to the next morning
	spill = [[] for _ in range(7)]
	for index, day in enumerate(week):
		for span in day:
			if span[1] > 1440:
				spill[(index + 1) % 7].append([0, span[1] - 1440])
				span[1] = 1440
	for index in range(7):
		week[index] = sorted(spill[index] + week[index])
	return result


# ── a place, in full ────────────────────────────────────────────────────────

YES = ("yes", "only", "designated")


def features_of(tags):
	found = []

	def add(fid, label, state):
		found.append({"id": fid, "label": label, "state": state})

	wheelchair = tags.get("wheelchair")
	if wheelchair in ("yes", "designated"):
		add("wheelchair", "Rollstuhlgerecht", "yes")
	elif wheelchair == "limited":
		add("wheelchair", "Teils rollstuhlgerecht", "limited")
	elif wheelchair == "no":
		add("wheelchair", "Nicht rollstuhlgerecht", "no")
	if tags.get("diet:vegan") in YES:
		add("vegan", "Nur vegan" if tags["diet:vegan"] == "only" else "Vegan", "yes")
	if tags.get("diet:vegetarian") in YES:
		add("vegetarian", "Vegetarisch", "yes")
	if tags.get("outdoor_seating") == "yes":
		add("outdoor", "Außenplätze", "yes")
	if tags.get("internet_access") in ("wlan", "yes", "wifi"):
		add("wifi", "Kostenloses WLAN" if tags.get("internet_access:fee") == "no" else "WLAN", "yes")
	if tags.get("takeaway") in YES:
		add("takeaway", "Zum Mitnehmen", "yes")
	if tags.get("delivery") == "yes":
		add("delivery", "Lieferung", "yes")
	if tags.get("drive_through") == "yes":
		add("drive", "Drive-in", "yes")
	if tags.get("dog") in ("yes", "leashed"):
		add("dog", "Hunde erlaubt", "yes")
	elif tags.get("dog") == "no":
		add("dog", "Keine Hunde", "no")
	if tags.get("smoking") in ("no",):
		add("smoking", "Nichtraucher", "yes")
	elif tags.get("smoking") in ("yes", "separated", "isolated"):
		add("smoking", "Raucher", "limited")
	if tags.get("air_conditioning") == "yes":
		add("ac", "Klimaanlage", "yes")
	if tags.get("reservation") in ("yes", "recommended", "required"):
		add("reservation", "Reservierung empfohlen" if tags["reservation"] != "yes" else "Reservierung möglich", "yes")
	if tags.get("toilets:wheelchair") == "yes" or tags.get("toilets") == "yes":
		add("toilets", "Toiletten", "yes")
	if tags.get("changing_table") == "yes":
		add("baby", "Wickeltisch", "yes")
	cards = [name for key, name in (("payment:debit_cards", "EC"), ("payment:girocard", "Girocard"), ("payment:credit_cards", "Kreditkarte"), ("payment:contactless", "Kontaktlos"), ("payment:apple_pay", "Apple Pay"), ("payment:google_pay", "Google Pay"), ("payment:paypal", "PayPal")) if tags.get(key) == "yes"]
	if cards:
		add("cards", " · ".join(cards[:3]), "yes")
	if tags.get("payment:cash") == "yes" and not cards:
		add("cash", "Nur bar", "limited") if tags.get("payment:cards") == "no" or tags.get("payment:debit_cards") == "no" else add("cash", "Bargeld", "yes")
	if tags.get("fee") == "no":
		add("free", "Kostenlos", "yes")
	if tags.get("self_service") == "yes":
		add("self", "Selbstbedienung", "yes")
	return found


def facts_of(tags):
	facts = []

	def add(label, value):
		if value:
			facts.append({"label": label, "value": str(value)})

	since = tags.get("start_date", "")
	if since:
		year = re.match(r"^~?(\d{4})", since)
		add("Seit", year.group(1) if year else since)
	add("Plätze", tags.get("capacity"))
	add("Betreiber", tags.get("operator") if tags.get("operator") != tags.get("name") else "")
	add("Marke", tags.get("brand") if tags.get("brand") != tags.get("name") else "")
	if tags.get("stars"):
		add("Sterne", "★" * int(float(re.sub(r"[^\d.]", "", tags["stars"]) or 0)) or tags["stars"])
	if tags.get("height"):
		add("Höhe", f'{tags["height"]} m' if re.match(r"^[\d.]+$", tags["height"]) else tags["height"])
	if tags.get("building:levels"):
		add("Etagen", tags["building:levels"])
	if tags.get("architect"):
		add("Architekt", tags["architect"])
	if tags.get("denomination"):
		add("Konfession", tags["denomination"].replace("_", " ").capitalize())
	if tags.get("level") and re.match(r"^-?\d+$", tags["level"]):
		level = int(tags["level"])
		add("Etage", "EG" if level == 0 else (f"{level}. OG" if level > 0 else f"{-level}. UG"))
	if tags.get("heritage") or tags.get("heritage:operator"):
		add("Denkmal", "Ja")
	if tags.get("beds"):
		add("Betten", tags["beds"])
	if tags.get("rooms"):
		add("Zimmer", tags["rooms"])
	return facts


def lookup(osm_id):
	params = {"osm_ids": osm_id, "format": "jsonv2", "extratags": 1, "addressdetails": 1, "namedetails": 1, "accept-language": "de"}
	found = nominatim("lookup", params)
	if not found:
		return None
	row = found[0]
	tags = dict(row.get("extratags") or {})
	tags.update({k: v for k, v in (row.get("namedetails") or {}).items() if k == "name"})
	address = row.get("address") or {}
	category, value = row.get("category", ""), row.get("type", "")
	street = " ".join(part for part in (address.get("road", ""), address.get("house_number", "")) if part)
	city = address.get("city") or address.get("town") or address.get("village") or address.get("municipality", "")
	name = row.get("name") or tags.get("brand") or street or city
	lat, lon = float(row["lat"]), float(row["lon"])
	place = {
		"id": osm_id,
		"name": name,
		"key": category,
		"kind": value,
		"kindLabel": kind_label(category, value, tags),
		"street": street,
		"postcode": address.get("postcode", ""),
		"city": city,
		"district": address.get("suburb") or address.get("city_district") or address.get("neighbourhood", ""),
		"address": ", ".join(part for part in (street, " ".join(p for p in (address.get("postcode", ""), city) if p)) if part),
		"lat": lat,
		"lon": lon,
		"cuisine": cuisines(tags),
		"phone": tags.get("phone") or tags.get("contact:phone", ""),
		"website": tags.get("website") or tags.get("contact:website") or tags.get("url", ""),
		"email": tags.get("email") or tags.get("contact:email", ""),
		"instagram": tags.get("contact:instagram", ""),
		"description": tags.get("description:de") or tags.get("description", ""),
		"features": features_of(tags),
		"facts": facts_of(tags),
		"osmUrl": f'https://www.openstreetmap.org/{ {"N": "node", "W": "way", "R": "relation"}[osm_id[0]] }/{osm_id[1:]}',
	}
	if place["website"] and not re.match(r"^https?://", place["website"]):
		place["website"] = "https://" + place["website"]
	if tags.get("opening_hours"):
		place["hours"] = parse_hours(tags["opening_hours"])
	if tags.get("opening_hours:kitchen"):
		place["kitchen"] = parse_hours(tags["opening_hours:kitchen"])
	return place, tags


# ── what it is and what it looks like ───────────────────────────────────────

def wikipedia(lang, title):
	url = f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_"), safe="")
	page = quiet(get_json, url, 8)
	if not page or page.get("type") == "disambiguation":
		return None
	return {
		"summary": page.get("extract", ""),
		"source": "Wikipedia",
		"url": page.get("content_urls", {}).get("desktop", {}).get("page", ""),
		"image": (page.get("originalimage") or page.get("thumbnail") or {}).get("source", ""),
	}


def wikidata(qid):
	entity = quiet(get_json, f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json", 8)
	if not entity:
		return None
	data = entity.get("entities", {}).get(qid) or next(iter(entity.get("entities", {}).values()), {})
	claims = data.get("claims", {})

	def first(prop):
		for claim in claims.get(prop, []):
			value = claim.get("mainsnak", {}).get("datavalue", {}).get("value")
			if value is not None:
				return value
		return None

	inception = first("P571")
	height = first("P2048")
	return {
		"label": (data.get("labels", {}).get("de") or data.get("labels", {}).get("en") or {}).get("value", ""),
		"description": (data.get("descriptions", {}).get("de") or data.get("descriptions", {}).get("en") or {}).get("value", ""),
		"dewiki": data.get("sitelinks", {}).get("dewiki", {}).get("title", ""),
		"enwiki": data.get("sitelinks", {}).get("enwiki", {}).get("title", ""),
		"image": first("P18") or "",
		"logo": first("P154") or "",
		"since": inception.get("time", "")[1:5] if isinstance(inception, dict) else "",
		"height": str(round(float(height["amount"]))) if isinstance(height, dict) and height.get("amount") else "",
		"website": first("P856") or "",
	}


def commons_file_url(name, width=640):
	name = name.replace("File:", "").replace("Datei:", "").strip()
	return f"https://commons.wikimedia.org/wiki/Special:FilePath/{urllib.parse.quote(name.replace(' ', '_'))}?width={width}"


class Page:
	"""A place's own website: what it says about itself, its pictures and icon."""

	def __init__(self, url):
		self.url = url
		self.description = ""
		self.title = ""
		self.image = ""
		self.icons = []
		body = quiet(fetch, url, 7, None, BROWSER_AGENT, 600_000, note=False)
		if not body or not body[1].startswith("text/html"):
			return
		self.url = body[2]
		text = body[0].decode("utf-8", "replace")
		head = text[: text.lower().find("</head>") + 7] if "</head>" in text.lower() else text[:200_000]
		metas = {}
		for tag in re.findall(r"<meta\b[^>]*>", head, re.I):
			key = re.search(r'(?:property|name)\s*=\s*["\']([^"\']+)', tag, re.I)
			value = re.search(r'content\s*=\s*["\']([^"\']*)', tag, re.I)
			if key and value:
				metas.setdefault(key.group(1).lower(), html.unescape(value.group(1)).strip())
		self.description = metas.get("og:description") or metas.get("description") or ""
		self.title = metas.get("og:site_name") or metas.get("og:title") or ""
		image = metas.get("og:image") or metas.get("twitter:image") or ""
		self.image = urllib.parse.urljoin(self.url, image) if image else ""
		for tag in re.findall(r"<link\b[^>]*>", head, re.I):
			rel = re.search(r'rel\s*=\s*["\']([^"\']+)', tag, re.I)
			href = re.search(r'href\s*=\s*["\']([^"\']+)', tag, re.I)
			if not rel or not href or "icon" not in rel.group(1).lower():
				continue
			sizes = re.search(r'sizes\s*=\s*["\'](\d+)', tag, re.I)
			size = int(sizes.group(1)) if sizes else (180 if "apple" in rel.group(1).lower() else 32)
			if href.group(1).lower().endswith(".svg"):
				continue
			self.icons.append((size, urllib.parse.urljoin(self.url, html.unescape(href.group(1)))))
		self.icons.sort(reverse=True)


def picture_file(url, folder, name, min_side=0, agent=BROWSER_AGENT):
	"""Downloads a picture (and makes it a PNG/JPEG Qt reads), or None."""
	target = folder / name
	for existing in folder.glob(name + ".*"):
		return existing
	got = quiet(fetch, url, 10, None, agent, 12_000_000, note=False)
	if not got or not (got[1].startswith("image/") or url.lower().split("?")[0].endswith((".jpg", ".jpeg", ".png", ".webp", ".ico"))):
		return None
	data = got[0]
	try:
		from PIL import Image
		picture = Image.open(io.BytesIO(data))
		if getattr(picture, "n_frames", 1) > 1:
			picture.seek(0)
		if min(picture.size) < min_side:
			return None
		if picture.mode in ("P", "LA", "RGBA") or got[1] in ("image/x-icon", "image/vnd.microsoft.icon", "image/png"):
			path = target.with_suffix(".png")
			picture.convert("RGBA").save(path)
		else:
			picture = picture.convert("RGB")
			if max(picture.size) > 1400:
				picture.thumbnail((1400, 1400))
			path = target.with_suffix(".jpg")
			picture.save(path, quality=88)
		return path
	except Exception:  # noqa: BLE001 – not a picture after all
		return None


def panoramax(lat, lon):
	params = {"place_position": f"{lon:.6f},{lat:.6f}", "place_distance": "0-35", "place_fov_tolerance": 40, "limit": 3}
	found = quiet(get_json, "https://api.panoramax.xyz/api/search?" + urllib.parse.urlencode(params), 8, note=False)
	pictures = []
	for feature in (found or {}).get("features", []):
		assets = feature.get("assets", {})
		href = (assets.get("sd") or assets.get("hd") or {}).get("href")
		if href:
			when = feature.get("properties", {}).get("datetime", "")[:4]
			pictures.append({"url": href, "credit": f"Panoramax{' · ' + when if when else ''}", "caption": ""})
	return pictures


def commons_near(lat, lon, radius=60):
	params = {"action": "query", "format": "json", "list": "geosearch", "gscoord": f"{lat}|{lon}", "gsradius": radius, "gsnamespace": 6, "gslimit": 6}
	found = quiet(get_json, "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params), 8, note=False)
	pictures = []
	for item in (found or {}).get("query", {}).get("geosearch", []):
		title = item.get("title", "")
		if re.search(r"\.(jpe?g|png|webp)$", title, re.I):
			pictures.append({"url": commons_file_url(title, 900), "credit": "Wikimedia Commons", "caption": re.sub(r"\.\w+$", "", title.replace("File:", "")).replace("_", " ")})
	return pictures


SIGHTS = ("tourism", "historic", "leisure", "building", "natural", "man_made")


def about_and_pictures(place, tags, folder, cached_ok):
	"""Emits "about" and the pictures as they come."""
	wiki = None
	qid = tags.get("wikidata", "")
	brand_qid = tags.get("brand:wikidata", "")
	data = wikidata(qid) if qid else None
	brand = wikidata(brand_qid) if brand_qid and not qid else None
	title = tags.get("wikipedia", "")
	if title and ":" in title:
		lang, name = title.split(":", 1)
		wiki = wikipedia(lang, name)
	elif data and (data["dewiki"] or data["enwiki"]):
		wiki = wikipedia("de", data["dewiki"]) if data["dewiki"] else wikipedia("en", data["enwiki"])
	site = Page(place["website"]) if place.get("website") else None

	summary, source, url = "", "", ""
	if wiki and wiki["summary"]:
		summary, source, url = wiki["summary"], "Wikipedia", wiki["url"]
	elif place.get("description"):
		summary, source = place["description"], "OpenStreetMap"
	elif site and site.description and len(site.description) > 30:
		summary, source, url = site.description, re.sub(r"^www\.", "", urllib.parse.urlparse(site.url).netloc), site.url
	elif data and data["description"]:
		summary, source = data["description"], "Wikidata"
	elif brand and brand["description"]:
		summary, source = f'{brand["label"]}: {brand["description"]}', "Wikidata"
	facts = []
	if data:
		if data["since"]:
			facts.append({"label": "Seit", "value": data["since"]})
		if data["height"]:
			facts.append({"label": "Höhe", "value": f'{data["height"]} m'})
	say(type="about", summary=summary[:900], source=source, url=url, facts=facts)

	# the round picture: its icon or logo, else its first photo
	avatar = None
	candidates = []
	if site:
		candidates += [icon for size, icon in site.icons if size >= 96]
	for logo in (data or {}).get("logo", ""), (brand or {}).get("logo", ""):
		if logo:
			candidates.append(commons_file_url(logo, 256))
	if site:
		candidates += [icon for size, icon in site.icons if 48 <= size < 96]
	for index, candidate in enumerate(candidates[:5]):
		path = picture_file(candidate, folder, f"avatar-{index}", 48)
		if path:
			avatar = path
			say(type="image", index=0, role="avatar", path=str(path), caption="", credit="")
			break

	photos = []
	if tags.get("image", "").startswith("http"):
		image = tags["image"]
		if "commons.wikimedia.org/wiki/File:" in image:
			image = commons_file_url(image.split("File:", 1)[1], 1200)
		photos.append({"url": image, "credit": "OpenStreetMap", "caption": ""})
	if tags.get("wikimedia_commons", "").startswith("File:"):
		photos.append({"url": commons_file_url(tags["wikimedia_commons"], 1200), "credit": "Wikimedia Commons", "caption": ""})
	if data and data["image"]:
		photos.append({"url": commons_file_url(data["image"], 1200), "credit": "Wikimedia Commons", "caption": data["label"]})
	elif wiki and wiki["image"]:
		photos.append({"url": wiki["image"], "credit": "Wikipedia", "caption": ""})
	if site and site.image:
		photos.append({"url": site.image, "credit": re.sub(r"^www\.", "", urllib.parse.urlparse(site.url).netloc), "caption": ""})
	photos += panoramax(place["lat"], place["lon"])
	if place["key"] in SIGHTS or qid:
		photos += commons_near(place["lat"], place["lon"])

	seen, index = set(), 1
	with concurrent.futures.ThreadPoolExecutor(4) as pool:
		jobs = []
		for number, photo in enumerate(photos[:8]):
			if photo["url"] in seen:
				continue
			seen.add(photo["url"])
			jobs.append((photo, pool.submit(picture_file, photo["url"], folder, f"photo-{hashlib.sha1(photo['url'].encode()).hexdigest()[:12]}", 200)))
		for photo, job in jobs:
			path = job.result()
			if not path:
				continue
			if avatar is None:
				avatar = path
				say(type="image", index=0, role="avatar", path=str(path), caption="", credit="")
			say(type="image", index=index, role="photo", path=str(path), caption=photo["caption"], credit=photo["credit"])
			index += 1


# ── getting there ───────────────────────────────────────────────────────────

def route(profile, start, end):
	url = f"https://routing.openstreetmap.de/routed-{profile}/route/v1/driving/{start[1]:.6f},{start[0]:.6f};{end[1]:.6f},{end[0]:.6f}?overview=false"
	found = quiet(get_json, url, 8)
	if not found or found.get("code") != "Ok" or not found.get("routes"):
		return None
	best = found["routes"][0]
	return {"min": max(1, round(best["duration"] / 60)), "km": round(best["distance"] / 1000, 1)}


def transit(start, end):
	params = {"fromPlace": f"{start[0]:.6f},{start[1]:.6f}", "toPlace": f"{end[0]:.6f},{end[1]:.6f}", "numItineraries": 1}
	found = quiet(get_json, "https://api.transitous.org/api/v1/plan?" + urllib.parse.urlencode(params), 10)
	if not found or not found.get("itineraries"):
		return None
	trip = found["itineraries"][0]
	legs = [{"mode": leg.get("mode", ""), "line": leg.get("routeShortName", ""), "min": round(leg.get("duration", 0) / 60)} for leg in trip.get("legs", [])]
	if not any(leg["mode"] != "WALK" for leg in legs):
		return None
	return {"min": round(trip["duration"] / 60), "depart": trip.get("startTime", ""), "arrive": trip.get("endTime", ""), "transfers": trip.get("transfers", 0), "legs": legs}


def routes(start, end):
	if distance(start[0], start[1], end[0], end[1]) > 300_000:
		return
	with concurrent.futures.ThreadPoolExecutor(4) as pool:
		jobs = {name: pool.submit(route, profile, start, end) for name, profile in (("walk", "foot"), ("bike", "bike"), ("car", "car"))}
		jobs["transit"] = pool.submit(transit, start, end)
		answer = {name: job.result() for name, job in jobs.items()}
	if distance(start[0], start[1], end[0], end[1]) > 25_000:
		answer["walk"] = None
	say(type="routes", **{k: v for k, v in answer.items() if v})


# ── around it ───────────────────────────────────────────────────────────────

def nearby(place, tags):
	"""Others of its kind around it, the stops and a car park, from Nominatim
	(Overpass is too often too busy to wait for)."""
	lat, lon = place["lat"], place["lon"]

	def around(phrase, span, kinds):
		viewbox = f"{lon - span * 1.6:.5f},{lat + span:.5f},{lon + span * 1.6:.5f},{lat - span:.5f}"
		rows = nominatim("search", {"q": phrase, "format": "jsonv2", "extratags": 1, "addressdetails": 1, "limit": 40, "bounded": 1, "viewbox": viewbox, "accept-language": "de"})
		found = [p for p in (from_nominatim(row, lat, lon) for row in rows or []) if p and p["id"] != place["id"]]
		return [p for p in found if not kinds or p["kind"] in kinds]

	similar = []
	phrase = KINDS.get(place["kind"]) if place["key"] in ("amenity", "shop", "tourism", "leisure") else None
	if phrase:
		similar = [p for p in around(phrase, 0.009, {place["kind"]}) if p["name"] != place["name"]]
	stops = around("Bushaltestelle", 0.005, {"bus_stop", "platform", "stop_position"}) + around("Bahnhof", 0.008, {"station", "halt", "stop"})
	parking = around("Parkplatz", 0.005, {"parking"})
	for item in stops:
		item["kindLabel"] = "Haltestelle" if item["kind"] in ("bus_stop", "platform", "stop_position") else "Bahnhof"
	for item in parking:
		if not item["name"] or item["name"] == item["street"]:
			item["name"] = "Parkplatz"
	if not similar and not stops and not parking and TROUBLE:
		return False
	stops = tidy([dict(item, street=item["name"]) for item in stops])
	say(type="nearby", similar=tidy(similar)[:10], stops=stops[:3], parking=tidy(parking)[:2])
	return True


# ── its weather ─────────────────────────────────────────────────────────────

def weather(lat, lon):
	params = {"latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}", "current": "temperature_2m,weather_code,is_day,wind_speed_10m",
		"hourly": "temperature_2m,weather_code,precipitation_probability,is_day", "forecast_hours": 12, "timezone": "auto"}
	found = quiet(get_json, "https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(params), 8)
	if not found:
		return
	hourly = found.get("hourly", {})
	hours = [{"time": t[-5:], "temp": round(temp), "code": code, "rain": rain or 0, "day": day}
		for t, temp, code, rain, day in zip(hourly.get("time", []), hourly.get("temperature_2m", []), hourly.get("weather_code", []), hourly.get("precipitation_probability", []), hourly.get("is_day", []))]
	now = found.get("current", {})
	say(type="weather", now={"temp": round(now.get("temperature_2m", 0)), "code": now.get("weather_code", 0), "day": now.get("is_day", 1), "wind": round(now.get("wind_speed_10m", 0))}, hours=hours)


# ── a small map ─────────────────────────────────────────────────────────────

def tile_xy(lat, lon, zoom):
	n = 2 ** zoom
	x = (lon + 180) / 360 * n
	y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
	return x, y


def make_map(lat, lon, folder, dark, zoom=16, width=720, height=520):
	"""OpenStreetMap's own tiles around the place, in one picture; at night
	turned dark (inverted, with the colours turned back)."""
	path = folder / f"map-{'dark' if dark else 'light'}-{zoom}.png"
	tile = 256
	x, y = tile_xy(lat, lon, zoom)
	px, py = x * tile, y * tile
	x0, y0 = px - width / 2, py - height / 2
	if not path.exists():
		try:
			from PIL import Image, ImageOps
		except ImportError:
			return
		canvas = Image.new("RGB", (width, height))
		jobs = []
		with concurrent.futures.ThreadPoolExecutor(4) as pool:
			for tx in range(int(x0 // tile), int((x0 + width) // tile) + 1):
				for ty in range(int(y0 // tile), int((y0 + height) // tile) + 1):
					url = f"https://tile.openstreetmap.org/{zoom}/{tx}/{ty}.png"
					jobs.append((tx, ty, pool.submit(quiet, fetch, url, 8, None, AGENT)))
			for tx, ty, job in jobs:
				got = job.result()
				if not got:
					return
				canvas.paste(Image.open(io.BytesIO(got[0])).convert("RGB"), (int(tx * tile - x0), int(ty * tile - y0)))
		if dark:
			hsv = ImageOps.invert(canvas).convert("HSV")
			h, sat, v = hsv.split()
			h = h.point(lambda value: (value + 128) % 256)
			sat = sat.point(lambda value: int(value * 0.55))
			v = v.point(lambda value: int(18 + value * 0.78))
			canvas = Image.merge("HSV", (h, sat, v)).convert("RGB")
		canvas.save(path)
	say(type="map", path=str(path), zoom=zoom, tile=tile, x0=x0, y0=y0, width=width, height=height)


# ── main ────────────────────────────────────────────────────────────────────

class Recorder:
	"""Keeps what is said, to say it again from the cache next time."""

	def __init__(self):
		self.lines = []

	def __call__(self, **message):
		self.lines.append(message)
		with _say_lock:
			print(json.dumps(message, ensure_ascii=False), flush=True)


def details(osm_id, lat, lon, start, dark, refresh):
	global say
	folder = CACHE / re.sub(r"[^A-Za-z0-9]", "", osm_id)
	folder.mkdir(parents=True, exist_ok=True)
	saved = folder / "details.json"
	cached = None
	if not refresh and saved.exists() and time.time() - saved.stat().st_mtime < KEEP_DAYS * 86400:
		try:
			cached = json.loads(saved.read_text())
		except ValueError:
			cached = None
	if cached:
		place = None
		for message in cached:
			if message["type"] == "place" and message.get("hours"):
				message["hours"] = parse_hours(message["hours"]["raw"])
			if message["type"] == "image" and not Path(message["path"]).exists():
				continue
			if message["type"] == "map" and not Path(message["path"]).exists():
				continue
			say(**message)
			if message["type"] == "place":
				place = message
		if place:
			with concurrent.futures.ThreadPoolExecutor(3) as pool:
				live = [pool.submit(weather, place["lat"], place["lon"])]
				if start:
					live.append(pool.submit(routes, start, (place["lat"], place["lon"])))
				if not any(m["type"] == "map" for m in cached):
					live.append(pool.submit(make_map, place["lat"], place["lon"], folder, dark))
				for job in live:
					job.result()
			say(type="done")
			return

	found = lookup(osm_id)
	if found is None:
		say(type="error", error="; ".join(TROUBLE)) if TROUBLE else say(type="none")
		return
	place, tags = found
	record = Recorder()
	say = record
	say(type="place", **place)
	with concurrent.futures.ThreadPoolExecutor(6) as pool:
		jobs = [
			pool.submit(about_and_pictures, place, tags, folder, True),
			pool.submit(nearby, place, tags),
			pool.submit(make_map, place["lat"], place["lon"], folder, dark),
			pool.submit(weather, place["lat"], place["lon"]),
		]
		if start:
			jobs.append(pool.submit(routes, start, (place["lat"], place["lon"])))
		for job in jobs:
			job.result()
	if not TROUBLE:
		saved.write_text(json.dumps([m for m in record.lines if m["type"] not in ("weather", "routes")], ensure_ascii=False))
	say(type="done")


def main():
	parser = argparse.ArgumentParser()
	parser.add_argument("action", choices=("suggest", "details", "hours"))
	parser.add_argument("text")
	parser.add_argument("--lat", type=float, default=float("nan"))
	parser.add_argument("--lon", type=float, default=float("nan"))
	parser.add_argument("--city", default="")
	parser.add_argument("--from", dest="start", default="")
	parser.add_argument("--dark", action="store_true")
	parser.add_argument("--refresh", action="store_true")
	args = parser.parse_args()
	CACHE.mkdir(parents=True, exist_ok=True)
	if not math.isfinite(args.lat) and args.city:
		found = quiet(get_json, "https://geocoding-api.open-meteo.com/v1/search?" + urllib.parse.urlencode({"name": args.city, "count": 1, "language": "de"}), 6) or {}
		if found.get("results"):
			args.lat, args.lon = found["results"][0]["latitude"], found["results"][0]["longitude"]

	if args.action == "hours":
		say(type="hours", **parse_hours(args.text))
		return
	if args.action == "suggest":
		text = args.text.strip()
		wanted = category_of(text)
		with concurrent.futures.ThreadPoolExecutor(2) as pool:
			names = pool.submit(suggest, text, args.lat, args.lon)
			kinds = pool.submit(category, wanted[0], wanted[1], args.lat, args.lon) if wanted and math.isfinite(args.lat) else None
			items = names.result()
			if items is not None:
				say(type="suggestions", items=items)
			answered = kinds.result() if kinds else False
		if items is None and not answered:
			say(type="error", error="; ".join(TROUBLE) or "No answer")
		say(type="done")
		return
	start = None
	if args.start:
		try:
			lat, lon = (float(part) for part in args.start.split(","))
			start = (lat, lon)
		except ValueError:
			start = None
	elif math.isfinite(args.lat):
		start = (args.lat, args.lon)
	details(args.text, args.lat, args.lon, start, args.dark, args.refresh)


if __name__ == "__main__":
	try:
		main()
	except (KeyboardInterrupt, BrokenPipeError):
		os._exit(1)
