#!/usr/bin/env bash

set -u

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

parse_volume_value() {
	local raw="$1"
	local volume="0"

	if [[ "$raw" =~ Volume:[[:space:]]*([0-9]+([.][0-9]+)?) ]]; then
		volume="${BASH_REMATCH[1]}"
	elif [[ "$raw" =~ /[[:space:]]*([0-9]+)% ]]; then
		local percent="${BASH_REMATCH[1]}"
		volume="$(printf '%d.%02d' "$((percent / 100))" "$((percent % 100))")"
	fi

	printf '%s' "$volume"
}

parse_muted_value() {
	local raw="$1"
	local muted="0"

	[[ "$raw" == *MUTED* || "$raw" == *"Mute: yes"* ]] && muted="1"

	printf '%s' "$muted"
}

parse_volume() {
	local raw="$1"
	printf '%s\t%s' "$(parse_volume_value "$raw")" "$(parse_muted_value "$raw")"
}

default_sink=""
default_volume=""
default_mute=""
pactl_info="$(pactl info 2>/dev/null || true)"
pactl_sinks="$(pactl list sinks 2>/dev/null || true)"

while IFS= read -r line; do
	if [[ "$line" =~ ^Default[[:space:]]Sink:[[:space:]](.+)$ ]]; then
		default_sink="$(trim "${BASH_REMATCH[1]}")"
		break
	fi
done <<< "$pactl_info"

if [[ -n "$default_sink" ]]; then
	default_volume="$(pactl get-sink-volume "$default_sink" 2>/dev/null || true)"
	default_mute="$(pactl get-sink-mute "$default_sink" 2>/dev/null || true)"
fi

if [[ -z "$default_volume" ]]; then
	default_volume="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
fi

printf 'DEFAULT\t%s\t%s\n' "$(parse_volume_value "$default_volume")" "$(parse_muted_value "$default_volume $default_mute")"

current_sink_name=""
current_sink_description=""
current_sink_volume=""
current_sink_mute=""
current_sink_object_id=""

flush_sink() {
	[[ -n "$current_sink_name" ]] || return 0

	local id="${current_sink_object_id:-$current_sink_name}"
	local active="0"
	local display_name="${current_sink_description:-$current_sink_name}"

	[[ -n "$default_sink" && "$current_sink_name" == "$default_sink" ]] && active="1"

	printf 'SINK\t%s\t%s\t%s\t%s\t%s\n' \
		"$id" \
		"$active" \
		"$(parse_volume_value "$current_sink_volume")" \
		"$(parse_muted_value "$current_sink_mute")" \
		"$display_name"
}

while IFS= read -r line; do
	if [[ "$line" =~ ^Sink[[:space:]]+\# ]]; then
		flush_sink
		current_sink_name=""
		current_sink_description=""
		current_sink_volume=""
		current_sink_mute=""
		current_sink_object_id=""
		continue
	fi

	if [[ "$line" =~ ^[[:space:]]*Name:[[:space:]](.+)$ ]]; then
		current_sink_name="$(trim "${BASH_REMATCH[1]}")"
	elif [[ "$line" =~ ^[[:space:]]*Description:[[:space:]](.+)$ ]]; then
		current_sink_description="$(trim "${BASH_REMATCH[1]}")"
	elif [[ "$line" =~ ^[[:space:]]*Mute:[[:space:]](.+)$ ]]; then
		current_sink_mute="$line"
	elif [[ -z "$current_sink_volume" && "$line" =~ ^[[:space:]]*Volume:[[:space:]](.+)$ ]]; then
		current_sink_volume="$line"
	elif [[ "$line" =~ ^[[:space:]]*object\.id[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
		current_sink_object_id="${BASH_REMATCH[1]}"
	fi
done <<< "$pactl_sinks"

flush_sink

status="$(wpctl status 2>/dev/null || true)"

section=""
current_stream_id=""
current_stream_name=""
current_stream_active="0"
current_stream_output="0"

flush_stream() {
	[[ -n "$current_stream_id" ]] || return 0
	[[ "$current_stream_output" == "1" && "$current_stream_active" == "1" ]] || return 0

	local volume_line
	volume_line="$(wpctl get-volume "$current_stream_id" 2>/dev/null || true)"
	printf 'STREAM\t%s\t%s\t%s\n' "$current_stream_id" "$(parse_volume "$volume_line")" "$current_stream_name"
}

while IFS= read -r line; do
	case "$line" in
		Audio*) section="audio" ;;
		Video*|Settings*) flush_stream; section=""; current_stream_id="";;
		*"├─ Sinks:"*|*"├─ Sources:"*|*"├─ Filters:"*) section="audio" ;;
		*"└─ Streams:"*) flush_stream; section="streams"; current_stream_id=""; current_stream_name=""; current_stream_active="0"; current_stream_output="0" ;;
	esac

	if [[ "$section" == "streams" ]]; then
		if [[ "$line" =~ ^[[:space:]]{8}([0-9]+)\.[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
			flush_stream
			current_stream_id="${BASH_REMATCH[1]}"
			current_stream_name="$(trim "${BASH_REMATCH[2]}")"
			current_stream_active="0"
			current_stream_output="0"
		elif [[ -n "$current_stream_id" && "$line" == *"output_"* && "$line" == *" > "* ]]; then
			current_stream_output="1"
			[[ "$line" == *"[active]"* ]] && current_stream_active="1"
		fi
	fi
done <<< "$status"

flush_stream
