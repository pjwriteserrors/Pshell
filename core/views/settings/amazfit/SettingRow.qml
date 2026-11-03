pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// One Zepp OS setting as the watch reported it, edited by its type: a switch,
// choices (from the catalogue, narrowed to what the watch allows), a slider
// within the watch's min/max, a time, text, or a list. `entry` is the
// daemon's { code, type, value, min, max, allowed, maxLength, key }.
ColumnLayout {
	id: row

	required property string group
	required property var entry
	readonly property var arg: Amazfit.argOf(row.group, row.entry.code)
	readonly property string label: row.arg?.label ?? `Setting 0x${Number(row.entry.code).toString(16).padStart(2, "0")}`
	readonly property string unit: row.arg?.unit ?? ""
	readonly property string type: row.entry.type ?? ""
	readonly property bool hidden: !row.arg
	// choices: { value, label } – the catalogue's names, else the raw values the watch allows
	readonly property var choices: {
		const named = row.arg?.options ?? null;
		const allowed = row.entry.allowed?.length ? row.entry.allowed : null;
		if (row.arg?.choices === "languages") {
			const out = [];
			for (const [code, id] of Object.entries(Amazfit.catalog.languages ?? {}))
				if (!allowed || allowed.includes(id)) out.push({ value: id, label: code.replace("_", "-") });
			return out;
		}
		if (row.arg?.choices === "menu") {
			return (allowed ?? []).map(id => ({ value: id, label: Amazfit.itemName("menu", id) }));
		}
		if (row.type === "strings") return (allowed ?? []).map(v => ({ value: v, label: v }));
		if (!named && !allowed) return null;
		const values = allowed ?? Object.keys(named).map(Number);
		return values.map(v => ({ value: v, label: named?.[String(v)] ?? String(v) }));
	}
	readonly property string hint: [
		row.hidden ? `hidden · ${row.type}` : "",
		row.entry.min !== undefined && row.type !== "shorts" ? `${row.entry.min}–${row.entry.max}${row.unit ? " " + row.unit : ""}` : "",
		row.entry.maxLength ? `up to ${row.entry.maxLength} characters` : ""
	].filter(s => s).join(" · ")

	function set(value) {
		Amazfit.setSetting(row.group, row.entry.code, value);
	}

	Layout.fillWidth: true
	spacing: 4

	FlagRow {
		visible: row.type === "bool"
		Layout.fillWidth: true
		icon: row.hidden ? "eye_off_outline" : ""
		title: row.label
		subtitle: row.hint
		checked: row.entry.value === true
		onToggled: on => row.set(on)
	}

	RowLayout {
		visible: row.type !== "bool"
		Layout.fillWidth: true
		Layout.leftMargin: 12
		spacing: 12

		ColumnLayout {
			Layout.preferredWidth: 230
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: row.label
				elide: Text.ElideRight
			}

			StyledText {
				Layout.fillWidth: true
				visible: row.hint !== ""
				text: row.hint
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}
		}

		// choices: segments when few, a list when many
		Segmented {
			visible: (row.type === "byte" || row.type === "strings") && !!row.choices && row.choices.length > 0 && row.choices.length <= 4
			Layout.fillWidth: true
			options: (row.choices ?? []).map(c => ({ value: String(c.value), label: c.label }))
			current: String(row.entry.value)
			onSelected: value => row.set(row.type === "byte" ? Number(value) : value)
		}

		TextButton {
			id: many

			visible: (row.type === "byte" || row.type === "strings") && !!row.choices && row.choices.length > 4
			Layout.fillWidth: true
			variant: "tonal"
			icon: "chevron_down"
			text: (row.choices ?? []).find(c => String(c.value) === String(row.entry.value))?.label ?? String(row.entry.value)
			onActivated: list.open()

			PickList {
				id: list

				current: String(row.entry.value)
				entries: (row.choices ?? []).map(c => ({ value: String(c.value), label: c.label }))
				onPicked: value => row.set(row.type === "byte" ? Number(value) : value)
			}
		}

		// numbers in the watch's range; a byte without names too
		ValueSlider {
			visible: ["short", "int"].includes(row.type) || (row.type === "byte" && !row.choices)
			Layout.fillWidth: true
			from: row.entry.min ?? 0
			to: row.entry.max ?? (row.type === "byte" ? 255 : Math.max(100, Number(row.entry.value) * 2))
			step: (row.entry.max ?? 100) - (row.entry.min ?? 0) > 2000 ? 100 : 1
			unit: row.unit
			value: Number(row.entry.value ?? 0)
			onMoved: v => commitNumber.later(Math.round(v))
		}

		Field {
			id: textField

			visible: ["string", "hhmm", "shorts"].includes(row.type) || (row.type === "strings" && !row.choices?.length)
			Layout.fillWidth: true
			text: Array.isArray(row.entry.value) ? row.entry.value.join(", ") : String(row.entry.value ?? "")
			placeholder: row.type === "hhmm" ? "HH:MM" : ""
			password: row.arg?.key === "password"
			clearable: false
			onAccepted: {
				const t = textField.text.trim();
				if (row.type === "hhmm" && !/^\d{1,2}:\d{2}$/.test(t)) return;
				if (row.type === "shorts") row.set(t.split(/[,\s]+/).filter(s => s).map(Number));
				else row.set(row.type === "hhmm" ? t.padStart(5, "0") : t);
			}
		}

		// read only: timestamps and raw words
		StyledText {
			visible: ["millis", "intu"].includes(row.type) || row.type === undefined || row.type === null || row.type === ""
			Layout.fillWidth: true
			text: row.type === "millis" ? (Number(row.entry.value) > 0 ? new Date(Number(row.entry.value)).toLocaleString(Qt.locale(), Locale.ShortFormat) : "—")
				: row.type === "intu" ? `0x${Number(row.entry.value).toString(16).padStart(8, "0")}` : (row.entry.raw ?? "")
			tone: Theme.textMuted
			font.family: Theme.monoFamily
		}
	}

	// a set of choices (workouts to detect)
	Flow {
		visible: row.type === "bytes"
		Layout.fillWidth: true
		Layout.leftMargin: 12
		spacing: 6

		Repeater {
			model: row.type === "bytes" ? (row.choices ?? []) : []

			delegate: Chip {
				required property var modelData

				text: modelData.label
				selected: (row.entry.value ?? []).includes(modelData.value)
				onClicked: {
					const now = (row.entry.value ?? []).slice();
					const at = now.indexOf(modelData.value);
					if (at >= 0) now.splice(at, 1);
					else now.push(modelData.value);
					row.set(now);
				}
			}
		}
	}

	Timer {
		id: commitNumber

		property int value: 0

		function later(v) {
			commitNumber.value = v;
			commitNumber.restart();
		}

		interval: 350
		onTriggered: row.set(commitNumber.value)
	}
}
