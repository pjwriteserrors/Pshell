.pragma library

// The converter of the launcher (>conv): `5 kg in lb`, `72 f c`, `100 usd
// eur`, `1/2 cup ml`, `0xff`, `255 in hex`. Without a target every unit of
// the kind is listed; a target that is no unit (yet) narrows that list.
//
// A unit is [symbol, name, factor to the kind's base, aliases, listed?];
// the symbol and the aliases are what can be typed. Kinds come in the order
// an ambiguous name is tried in, the currencies last.

function linear(factor) {
	return { to: function (v) { return v * factor; }, from: function (v) { return v / factor; }, factor: factor };
}

function unit(spec) {
	const made = typeof spec[2] === "number" ? linear(spec[2]) : spec[2];
	made.symbol = spec[0];
	made.name = spec[1];
	made.names = [spec[0], spec[1]].concat(spec[3] || []);
	made.listed = spec[4] !== false;
	return made;
}

const KINDS = [
	{ id: "length", name: "Length", units: [
		["mm", "millimetre", 1e-3, ["millimeter", "millimeters", "millimetres"]],
		["cm", "centimetre", 1e-2, ["centimeter", "centimeters", "centimetres", "zentimeter"]],
		["m", "metre", 1, ["meter", "meters", "metres"]],
		["km", "kilometre", 1e3, ["kilometer", "kilometers", "kilometres"]],
		["in", "inch", 0.0254, ["inches", "zoll", "\""]],
		["ft", "foot", 0.3048, ["feet", "fuß", "fuss", "'"]],
		["yd", "yard", 0.9144, ["yards"]],
		["mi", "mile", 1609.344, ["miles", "meile", "meilen"]],
		["nmi", "nautical mile", 1852, ["nautical miles", "seemeile", "seemeilen", "sm"], false],
		["dm", "decimetre", 0.1, ["decimeter", "dezimeter"], false],
		["µm", "micrometre", 1e-6, ["um", "micrometer", "micron", "mikrometer"], false],
		["nm", "nanometre", 1e-9, ["nanometer"], false],
		["ly", "light year", 9.4607304725808e15, ["light years", "lightyear", "lichtjahr", "lichtjahre"], false],
		["au", "astronomical unit", 149597870700, ["ae"], false]
	] },
	{ id: "mass", name: "Weight", units: [
		["mg", "milligram", 1e-6, ["milligrams", "milligramm"]],
		["g", "gram", 1e-3, ["grams", "gramm"]],
		["kg", "kilogram", 1, ["kilograms", "kilogramm", "kilo", "kilos"]],
		["t", "tonne", 1e3, ["tonnes", "tonnen", "metric ton", "metric tons"]],
		["oz", "ounce", 0.028349523125, ["ounces", "unze", "unzen"]],
		["lb", "pound", 0.45359237, ["lbs", "pounds"]],
		["st", "stone", 6.35029318, ["stones"]],
		["µg", "microgram", 1e-9, ["ug", "mcg", "mikrogramm"], false],
		["Pfund", "German pound", 0.5, ["pfund"], false],
		["ton", "US ton", 907.18474, ["tons", "short ton", "us ton"], false],
		["ct", "carat", 2e-4, ["carats", "karat"], false]
	] },
	{ id: "volume", name: "Volume", units: [
		["ml", "millilitre", 1e-3, ["milliliter", "milliliters", "millilitres"]],
		["l", "litre", 1, ["liter", "liters", "litres"]],
		["m³", "cubic metre", 1e3, ["m3", "cbm", "kubikmeter", "cubic meter", "cubic meters"]],
		["tsp", "teaspoon", 0.00492892159375, ["teaspoons", "tl", "teelöffel"]],
		["tbsp", "tablespoon", 0.01478676478125, ["tablespoons", "el", "esslöffel"]],
		["cup", "US cup", 0.2365882365, ["cups", "tasse", "tassen"]],
		["fl oz", "US fluid ounce", 0.0295735295625, ["floz", "fluid ounce", "fluid ounces", "oz"]],
		["pt", "US pint", 0.473176473, ["pint", "pints"]],
		["gal", "US gallon", 3.785411784, ["gallon", "gallons", "gallone", "gallonen"]],
		["cl", "centilitre", 1e-2, ["centiliter", "zentiliter"], false],
		["dl", "decilitre", 0.1, ["deciliter", "deziliter"], false],
		["hl", "hectolitre", 100, ["hektoliter", "hectoliter"], false],
		["cm³", "cubic centimetre", 1e-3, ["cm3", "cc", "ccm"], false],
		["qt", "US quart", 0.946352946, ["quart", "quarts"], false],
		["UK pt", "imperial pint", 0.56826125, ["uk pt", "uk pint", "imperial pint"], false],
		["UK gal", "imperial gallon", 4.54609, ["uk gal", "uk gallon", "imperial gallon"], false]
	] },
	{ id: "area", name: "Area", units: [
		["cm²", "square centimetre", 1e-4, ["cm2", "qcm", "sq cm"]],
		["m²", "square metre", 1, ["m2", "qm", "sqm", "sq m", "quadratmeter"]],
		["km²", "square kilometre", 1e6, ["km2", "qkm", "sq km", "quadratkilometer"]],
		["ha", "hectare", 1e4, ["hectares", "hektar"]],
		["ft²", "square foot", 0.09290304, ["ft2", "sqft", "sq ft", "square feet"]],
		["ac", "acre", 4046.8564224, ["acres"]],
		["mi²", "square mile", 2589988.110336, ["mi2", "sqmi", "sq mi", "square miles"]],
		["mm²", "square millimetre", 1e-6, ["mm2", "qmm", "sq mm"], false],
		["in²", "square inch", 0.00064516, ["in2", "sqin", "sq in", "square inches"], false],
		["yd²", "square yard", 0.83612736, ["yd2", "sqyd", "sq yd", "square yards"], false]
	] },
	{ id: "temperature", name: "Temperature", units: [
		["°C", "Celsius", { to: function (v) { return v + 273.15; }, from: function (v) { return v - 273.15; } }, ["c", "grad"]],
		["°F", "Fahrenheit", { to: function (v) { return (v + 459.67) * 5 / 9; }, from: function (v) { return v * 9 / 5 - 459.67; } }, ["f"]],
		["K", "Kelvin", { to: function (v) { return v; }, from: function (v) { return v; } }, []]
	] },
	{ id: "speed", name: "Speed", units: [
		["km/h", "kilometres per hour", 1 / 3.6, ["kmh", "kph", "km per hour"]],
		["m/s", "metres per second", 1, ["mps", "m per second"]],
		["mph", "miles per hour", 0.44704, ["mi/h", "miles per hour"]],
		["kn", "knot", 1852 / 3600, ["knots", "kt", "kts", "knoten"]],
		["ft/s", "feet per second", 0.3048, ["fps"], false],
		["Mach", "Mach", 343, ["mach"], false]
	] },
	{ id: "time", name: "Time", units: [
		["ms", "millisecond", 1e-3, ["milliseconds", "millisekunde", "millisekunden"]],
		["s", "second", 1, ["sec", "secs", "seconds", "sekunde", "sekunden"]],
		["min", "minute", 60, ["mins", "minutes", "minuten"]],
		["h", "hour", 3600, ["hr", "hrs", "hours", "stunde", "stunden", "std"]],
		["d", "day", 86400, ["days", "tag", "tage"]],
		["wk", "week", 604800, ["weeks", "woche", "wochen"]],
		["mo", "month", 2629746, ["months", "monat", "monate"]],
		["yr", "year", 31556952, ["y", "yrs", "years", "jahr", "jahre"]],
		["µs", "microsecond", 1e-6, ["us", "mikrosekunde"], false],
		["ns", "nanosecond", 1e-9, ["nanosekunde"], false]
	] },
	{ id: "data", name: "Data", units: [
		["B", "byte", 1, ["bytes"]],
		["kB", "kilobyte", 1e3, ["KB", "kilobytes"]],
		["MB", "megabyte", 1e6, ["megabytes"]],
		["GB", "gigabyte", 1e9, ["gigabytes"]],
		["TB", "terabyte", 1e12, ["terabytes"]],
		["KiB", "kibibyte", 1024, ["kibibytes"]],
		["MiB", "mebibyte", 1048576, ["mebibytes"]],
		["GiB", "gibibyte", 1073741824, ["gibibytes"]],
		["Mbit", "megabit", 125000, ["Mb", "megabits"]],
		["bit", "bit", 0.125, ["b", "bits"], false],
		["kbit", "kilobit", 125, ["kb", "kilobits"], false],
		["Gbit", "gigabit", 125000000, ["Gb", "gigabits"], false],
		["PB", "petabyte", 1e15, ["petabytes"], false],
		["TiB", "tebibyte", 1099511627776, ["tebibytes"], false]
	] },
	{ id: "pressure", name: "Pressure", units: [
		["bar", "bar", 1e5, []],
		["hPa", "hectopascal", 100, ["mbar", "millibar", "hektopascal"]],
		["kPa", "kilopascal", 1e3, []],
		["psi", "pounds per square inch", 6894.757293168, []],
		["atm", "atmosphere", 101325, ["atmosphäre"]],
		["mmHg", "millimetre of mercury", 133.322387415, ["torr"]],
		["Pa", "pascal", 1, [], false],
		["MPa", "megapascal", 1e6, [], false]
	] },
	{ id: "energy", name: "Energy", units: [
		["J", "joule", 1, ["joules"]],
		["kJ", "kilojoule", 1e3, ["kilojoules"]],
		["cal", "calorie", 4.184, ["calories", "kalorie", "kalorien"]],
		["kcal", "kilocalorie", 4184, ["kilocalories", "kilokalorie", "kilokalorien"]],
		["Wh", "watt hour", 3600, ["wattstunde", "wattstunden"]],
		["kWh", "kilowatt hour", 3.6e6, ["kilowattstunde", "kilowattstunden"]],
		["MJ", "megajoule", 1e6, [], false],
		["MWh", "megawatt hour", 3.6e9, [], false],
		["BTU", "British thermal unit", 1055.05585262, [], false],
		["eV", "electronvolt", 1.602176634e-19, [], false]
	] },
	{ id: "power", name: "Power", units: [
		["W", "watt", 1, ["watts"]],
		["kW", "kilowatt", 1e3, ["kilowatts"]],
		["PS", "metric horsepower", 735.49875, ["ps"]],
		["hp", "horsepower", 745.69987158227, ["horsepower"]],
		["MW", "megawatt", 1e6, ["megawatts"], false]
	] },
	{ id: "angle", name: "Angle", units: [
		["°", "degree", Math.PI / 180, ["deg", "degree", "degrees"]],
		["rad", "radian", 1, ["radians"]],
		["gon", "gradian", Math.PI / 200, ["gradians"]],
		["turn", "turn", 2 * Math.PI, ["turns"]]
	] },
	{ id: "fuel", name: "Fuel", units: [
		["l/100km", "litres per 100 km", { to: function (v) { return 100 / v; }, from: function (v) { return 100 / v; } }, ["l/100 km", "l per 100km"]],
		["km/l", "kilometres per litre", 1, ["kml"]],
		["mpg", "miles per US gallon", 0.425143707, []],
		["UK mpg", "miles per imperial gallon", 0.35400619, ["uk mpg", "mpg uk"]]
	] }
];

// code, name, what else it is called, listed without a target
const CURRENCIES = [
	["eur", "Euro", ["euro", "euros", "€"], true],
	["usd", "US dollar", ["dollar", "dollars", "us dollar", "us dollars", "$"], true],
	["gbp", "Pound sterling", ["pound", "pounds", "pound sterling", "pfund sterling", "quid", "£"], true],
	["chf", "Swiss franc", ["franc", "francs", "franken"], true],
	["jpy", "Japanese yen", ["yen", "¥"], true],
	["cad", "Canadian dollar", [], true],
	["aud", "Australian dollar", [], true],
	["cny", "Chinese yuan", ["yuan", "rmb", "renminbi"], true],
	["sek", "Swedish krona", [], true],
	["nok", "Norwegian krone", [], true],
	["dkk", "Danish krone", [], true],
	["pln", "Polish złoty", ["zloty", "złoty"], true],
	["czk", "Czech koruna", [], true],
	["try", "Turkish lira", ["lira"], true],
	["inr", "Indian rupee", ["rupee", "rupees", "₹"], true],
	["btc", "Bitcoin", ["bitcoin", "bitcoins", "₿"], true],
	["eth", "Ether", ["ether", "ethereum"], false],
	["nzd", "New Zealand dollar", [], false],
	["huf", "Hungarian forint", ["forint"], false],
	["ron", "Romanian leu", [], false],
	["bgn", "Bulgarian lev", [], false],
	["isk", "Icelandic króna", [], false],
	["rub", "Russian rouble", ["rouble", "ruble", "rubel", "₽"], false],
	["uah", "Ukrainian hryvnia", ["hryvnia", "₴"], false],
	["krw", "South Korean won", ["won", "₩"], false],
	["brl", "Brazilian real", ["real"], false],
	["mxn", "Mexican peso", [], false],
	["zar", "South African rand", ["rand"], false],
	["hkd", "Hong Kong dollar", [], false],
	["sgd", "Singapore dollar", [], false],
	["thb", "Thai baht", ["baht", "฿"], false],
	["idr", "Indonesian rupiah", ["rupiah"], false],
	["php", "Philippine peso", ["₱"], false],
	["myr", "Malaysian ringgit", ["ringgit"], false],
	["vnd", "Vietnamese đồng", ["dong", "₫"], false],
	["ils", "Israeli shekel", ["shekel", "₪"], false],
	["aed", "UAE dirham", ["dirham"], false],
	["sar", "Saudi riyal", ["riyal"], false],
	["egp", "Egyptian pound", [], false],
	["ltc", "Litecoin", ["litecoin"], false],
	["xmr", "Monero", ["monero"], false],
	["sol", "Solana", ["solana"], false],
	["doge", "Dogecoin", ["dogecoin"], false]
];
const SIGNS = { "$": "usd", "€": "eur", "£": "gbp", "¥": "jpy", "₹": "inr", "₿": "btc", "₽": "rub", "₩": "krw", "₪": "ils", "₴": "uah", "฿": "thb", "₱": "php", "₫": "vnd" };
const BASES = { hex: 16, dec: 10, oct: 8, bin: 2 };
const JOINS = ["in", "to", "as", "into", "nach", "zu", "auf", "="];

function build(kind) {
	const exact = {};
	const loose = {};
	const units = kind.units.map(unit);
	// what is listed wins a name another unit of the kind also goes by
	units.forEach(function (made) {
		made.kind = kind.id;
		made.names.forEach(function (name) {
			if (exact[name] === undefined) exact[name] = made;
			if (loose[name.toLowerCase()] === undefined) loose[name.toLowerCase()] = made;
		});
	});
	return { id: kind.id, name: kind.name, units: units, exact: exact, loose: loose };
}

const kinds = KINDS.map(build);

// rates: { code: units of it per euro }
function money(rates) {
	const known = {};
	const units = [];
	CURRENCIES.forEach(function (spec) {
		if (!(rates[spec[0]] > 0)) return;
		known[spec[0]] = true;
		units.push([spec[0].toUpperCase(), spec[1], 1 / rates[spec[0]], [spec[0]].concat(spec[2]), spec[3]]);
	});
	for (const code in rates)
		if (!known[code] && rates[code] > 0 && /^[a-z]{3,5}$/.test(code)) units.push([code.toUpperCase(), code.toUpperCase(), 1 / rates[code], [], false]);
	return build({ id: "currency", name: "Currency", units: units });
}

function isMoney(name) {
	const wanted = clean(name).toLowerCase();
	return CURRENCIES.some(function (spec) {
		return spec[0] === wanted || spec[2].indexOf(wanted) >= 0;
	});
}

function clean(name) {
	return String(name || "").trim().replace(/\s+/g, " ").replace(/\^([23])$/, "$1").replace(/\.$/, "");
}

function lookup(kind, name) {
	const wanted = clean(name);
	if (wanted === "") return null;
	if (kind.exact[wanted]) return kind.exact[wanted];
	const lower = wanted.toLowerCase();
	const forms = [lower, lower.replace("²", "2").replace("³", "3"), lower.replace(/s$/, ""), lower.replace(/e?n$/, "")];
	for (let index = 0; index < forms.length; index += 1)
		if (kind.loose[forms[index]]) return kind.loose[forms[index]];
	return null;
}

function number(text) {
	let value = text.replace(/[' _]/g, "");
	const comma = value.lastIndexOf(",");
	const dot = value.lastIndexOf(".");
	if (comma >= 0 && dot >= 0)
		value = comma > dot ? value.replace(/\./g, "").replace(",", ".") : value.replace(/,/g, "");
	else if (comma >= 0)
		value = value.indexOf(",") === comma ? value.replace(",", ".") : value.replace(/,/g, "");
	else if (dot >= 0 && value.indexOf(".") !== dot)
		value = value.replace(/\./g, "");
	return Number(value);
}

// 1234567.891 → "1 234 567.891" (narrow spaces)
function grouped(text) {
	const parts = text.split(".");
	if (/e/.test(text) || parts[0].replace("-", "").length < 5) return text;
	parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, " ");
	return parts.join(".");
}

function plain(value, kind) {
	if (!isFinite(value)) return "";
	if (kind === "currency" && Math.abs(value) >= 1 && Math.abs(value) < 1e15) return value.toFixed(2);
	return String(Number(value.toPrecision(kind === "currency" ? 4 : 7)));
}

function row(value, made) {
	const text = plain(value, made.kind);
	return { value: value, plain: text, text: grouped(text), symbol: made.symbol, name: made.name };
}

// `0xff`, `255 in hex`, `1010 bin dec`
function based(text) {
	const lower = text.toLowerCase().trim();
	let match = /^(0x[0-9a-f]+|0b[01]+|0o[0-7]+)(?:\s+(?:(?:in|to|as)\s+)?(hex|dec|oct|bin))?$/.exec(lower);
	let from = "";
	let digits = "";
	let target = "";
	if (match) {
		from = { x: "hex", b: "bin", o: "oct" }[match[1][1]];
		digits = match[1].slice(2);
		target = match[2] || "";
	} else if ((match = /^([0-9a-f]+)\s+(hex|dec|oct|bin)(?:\s+(?:(?:in|to|as)\s+)?(hex|dec|oct|bin))?$/.exec(lower))) {
		from = match[2];
		digits = match[1];
		target = match[3] || "";
	} else if ((match = /^(\d+)\s+(?:in|to|as)\s+(hex|oct|bin)$/.exec(lower))) {
		from = "dec";
		digits = match[1];
		target = match[2];
	} else {
		return null;
	}
	const value = parseInt(digits, BASES[from]);
	if (!new RegExp("^[" + "0123456789abcdef".slice(0, BASES[from]) + "]+$").test(digits) || !(value <= Number.MAX_SAFE_INTEGER))
		return { ok: false, message: digits + " is no " + from + " number" };
	const names = { hex: "Hexadecimal", dec: "Decimal", oct: "Octal", bin: "Binary" };
	const rows = ["dec", "hex", "bin", "oct"].filter(function (base) { return base !== from; }).map(function (base) {
		const written = value.toString(BASES[base]);
		return { value: value, plain: written, text: written, symbol: base, name: names[base] };
	});
	rows.sort(function (a, b) { return (b.symbol === target) - (a.symbol === target); });
	return { ok: true, kind: "Number", input: digits, from: { symbol: from, name: names[from] }, exact: target !== "", rows: rows, note: "" };
}

// rates: { code: units per euro } or null while there are none.
// → { ok, kind, input, from, exact, rows: [{ text, plain, symbol, name }], note }
//   exact: the first row is the target that was asked for
// or { ok: false, message, money: it waits for rates }
function convert(query, rates) {
	let text = String(query || "").trim();
	if (text === "") return { ok: false, message: "" };
	const numbers = based(text);
	if (numbers) return numbers;

	// $100 → 100 usd, 100€ → 100 eur
	text = text.replace(/([$€£¥₹₿₽₩₪₴฿₱₫])\s*([-+]?[\d.,']+)/, function (all, sign, amount) { return amount + " " + SIGNS[sign]; })
		.replace(/[$€£¥₹₿₽₩₪₴฿₱₫]/g, function (sign) { return " " + SIGNS[sign] + " "; })
		.replace(/→|->|=>/g, " to ").trim();

	let amount = 1;
	const match = /^([-+]?(?:\d[\d.,']*|[.,]\d+)(?:e[-+]?\d+)?)(?:\s*\/\s*(\d+(?:[.,]\d+)?))?\s*([\s\S]*)$/i.exec(text);
	if (match) {
		amount = number(match[1]) / (match[2] ? number(match[2]) : 1);
		text = match[3].trim();
	}
	if (!isFinite(amount)) return { ok: false, message: "No number" };
	const words = text.split(/\s+/).filter(function (word) { return word !== ""; });
	if (words.length === 0) return { ok: false, message: "" };

	const all = rates ? kinds.concat([money(rates)]) : kinds;
	let found = null;
	let waits = false;
	for (let split = words.length; split >= 1 && !(found && found.to); split -= 1) {
		const source = words.slice(0, split).join(" ");
		let rest = words.slice(split);
		if (rest.length > 1 && JOINS.indexOf(rest[0].toLowerCase()) >= 0) rest = rest.slice(1);
		const target = rest.join(" ");
		if (!rates && isMoney(source) && (target === "" || isMoney(target))) waits = true;
		for (let index = 0; index < all.length; index += 1) {
			const from = lookup(all[index], source);
			if (!from) continue;
			const to = target === "" ? null : lookup(all[index], target);
			if (to && to !== from) {
				found = { kind: all[index], from: from, to: to, filter: "" };
				break;
			}
			// the longest source, in the first kind that knows it
			if (!found) {
				const typed = rest.length === 1 && JOINS.indexOf(target.toLowerCase()) >= 0 ? "" : target;
				found = { kind: all[index], from: from, to: null, filter: typed };
			}
		}
	}
	// a currency whose rates are not here yet
	if (!rates && (found ? !found.to && isMoney(found.filter) : waits)) return { ok: false, message: "", money: true };
	if (!found) return { ok: false, message: "Unknown unit: " + words[0] };

	const base = found.from.to(amount);
	let units = found.kind.units.filter(function (made) { return made !== found.from; });
	if (found.to) {
		units = [found.to].concat(units.filter(function (made) { return made !== found.to && made.listed; }));
	} else {
		const filter = clean(found.filter).toLowerCase();
		const narrowed = filter === "" ? [] : units.filter(function (made) {
			return made.names.some(function (name) { return name.toLowerCase().indexOf(filter) === 0; });
		});
		units = narrowed.length > 0 ? narrowed : units.filter(function (made) { return made.listed; });
	}
	let rows = units.map(function (made) { return row(made.from(base), made); }).filter(function (made) { return made.plain !== ""; });
	// numbers one can read first: 11 lb before 5 000 000 mg
	if (found.kind.id !== "currency") {
		const handy = function (made) { return made.value === 0 ? 0 : Math.abs(Math.log(Math.abs(made.value)) / Math.LN10 - 1); };
		const rest = rows.slice(found.to ? 1 : 0).sort(function (a, b) { return handy(a) - handy(b); });
		rows = (found.to ? [rows[0]] : []).concat(rest);
	}
	if (rows.length === 0) return { ok: false, message: "No result" };

	// what one of the source is in the target
	const note = found.to && found.from.factor && found.to.factor
		? "1 " + found.from.symbol + " = " + grouped(plain(found.from.factor / found.to.factor, "rate")) + " " + found.to.symbol
		: "";
	return {
		ok: true, kind: found.kind.name, money: found.kind.id === "currency",
		input: grouped(String(Number(amount.toPrecision(12)))),
		from: { symbol: found.from.symbol, name: found.from.name },
		exact: !!found.to, rows: rows, note: note
	};
}
