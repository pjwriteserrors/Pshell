#!/usr/bin/env bash
# Helpers for the in-shell screenshot suite (services/Screenshot.qml).
# Everything temporary lives in $XDG_RUNTIME_DIR (tmpfs) and is removed by
# the shell as soon as it is not needed any more.
#
#   freeze <tag> <output>...     grim every output into <dir>/frozen-<tag>-<output>.ppm
#   window <tag> <id>            niri renders one window into <dir>/window-<tag>.png
#   copy <file>                  put a PNG on the clipboard (wl-copy keeps it in memory)
#   text <text>                  put text on the clipboard
#   ocr-check                    exit 127 unless tesseract with deu+eng is installed
#   ocr <file> [x y w h]         crop (optional) and print the recognised text
#   ocr-tsv <file> x y w h scale  word boxes (tesseract TSV) of the scaled crop
#   swatch <hex> <file>          small colour strip for the toast
#   crop <in> <x> <y> <w> <h> <out>  cut a region out of a frozen frame (pins)
#   unpin-all                    drop the images of pinned screenshots (and live pins)
#   clean [keep-tag]             drop frozen frames of other sessions
#   qr <file> [x y w h]          crop (optional) and print the decoded QR/barcodes
#   palette <file> x y w h <out> print the dominant colours (hex, most common
#                                first) and draw them as a strip into <out>
#   history-add <src> <dest>     keep a copy of a capture in the session history
#   history-reset                drop the capture history (shell start)
#   scroll-capture <tag> <geom>  grab <geom> (grim -g) every 0.3 s into
#                                <dir>/scroll-<tag>/ until a "stop" file appears
#   scroll-stitch <tag> <out>    stitch those frames into <out>, drop the frames
#   scroll-drop <tag>            drop the frames of an abandoned scroll capture
set -u

dir="${XDG_RUNTIME_DIR:-/tmp}/qs-screenshot"
mkdir -p "$dir"
chmod 700 "$dir" 2>/dev/null

case "${1:-}" in
freeze)
	tag="$2"
	shift 2
	pids=()
	for output in "$@"; do
		grim -t ppm -o "$output" "$dir/frozen-$tag-$output.ppm" &
		pids+=("$!")
	done
	status=0
	for pid in "${pids[@]}"; do
		wait "$pid" || status=1
	done
	exit "$status"
	;;
window)
	file="$dir/window-$2.png"
	clip="$dir/clip-$2"
	rm -f "$file"
	# niri also puts the shot on the clipboard: keep what was there before
	types=$(wl-paste --list-types 2>/dev/null)
	type=""
	for candidate in "text/plain;charset=utf-8" "text/plain" "image/png"; do
		grep -qxF "$candidate" <<<"$types" && { type="$candidate"; break; }
	done
	[[ -z "$type" && -n "$types" ]] && type=$(head -n1 <<<"$types")
	[[ -n "$type" ]] && wl-paste --no-newline --type "$type" >"$clip" 2>/dev/null
	restore() {
		sleep 0.15
		if [[ -n "$type" && -s "$clip" ]]; then
			wl-copy --type "$type" <"$clip"
		else
			wl-copy --clear
		fi
		rm -f "$clip"
	}
	niri msg action screenshot-window --id "$3" --write-to-disk true --path "$file" >/dev/null || { rm -f "$clip"; exit 1; }
	# niri writes the file asynchronously: wait until it exists and stops growing
	last=-1
	for _ in $(seq 60); do
		if [[ -s "$file" ]]; then
			size=$(stat -c %s "$file")
			if [[ "$size" == "$last" ]]; then
				restore
				printf '%s' "$file"
				exit 0
			fi
			last="$size"
		fi
		sleep 0.05
	done
	restore
	exit 1
	;;
copy)
	wl-copy --type image/png <"$2"
	;;
text)
	printf '%s' "$2" | wl-copy
	;;
ocr-check)
	command -v tesseract >/dev/null || exit 127
	langs=$(tesseract --list-langs 2>/dev/null)
	grep -qx deu <<<"$langs" && grep -qx eng <<<"$langs" || exit 127
	;;
ocr)
	"$0" ocr-check || exit 127
	src="$2"
	if [[ $# -ge 6 ]]; then
		src="$dir/ocr-$$.png"
		# upscaling UI-sized text helps tesseract a lot
		resize=()
		(( $5 < 1600 )) && resize=(-resize '200%')
		magick "$2" -crop "${5}x${6}+${3}+${4}" +repage "${resize[@]}" "$src" || exit 1
	fi
	tesseract "$src" - -l deu+eng 2>/dev/null
	status=$?
	[[ "$src" != "$2" ]] && rm -f "$src"
	exit "$status"
	;;
swatch)
	magick -size 720x96 "xc:$2" "$3"
	;;
crop)
	magick "$2" -crop "${5}x${6}+${3}+${4}" +repage "$7"
	;;
unpin-all)
	rm -rf "$dir"/pin-*
	;;
ocr-tsv)
	# ocr-tsv <file> <x> <y> <w> <h> <scale>: word boxes as tesseract TSV,
	# measured in the <scale>× enlarged crop
	"$0" ocr-check || exit 127
	src="$dir/ocr-tsv-$$.png"
	magick "$2" -crop "${5}x${6}+${3}+${4}" +repage -resize "$(( ${7:-1} * 100 ))%" "$src" || exit 1
	tesseract "$src" - -l deu+eng tsv 2>/dev/null
	status=$?
	rm -f "$src"
	exit "$status"
	;;
clean)
	find "$dir" -maxdepth 1 \( -name 'copy-*' -o -name 'swatch-*' -o -name 'palette-*' -o -name 'qr-*' -o -name 'ocr-*' -o -name 'export-*' \) -mmin +10 -delete
	keep="${2:-}"
	for file in "$dir"/frozen-* "$dir"/window-* "$dir"/clip-*; do
		[[ -e "$file" ]] || continue
		[[ -n "$keep" && "$file" == *"-$keep-"* ]] && continue
		[[ -n "$keep" && "$file" == *"-$keep.png" ]] && continue
		rm -f "$file"
	done
	;;
qr)
	"$0" qr-check || exit 127
	src="$2"
	if [[ $# -ge 6 ]]; then
		src="$dir/qr-$$.png"
		# small codes decode far better a bit enlarged
		resize=()
		(( $5 < 800 && $6 < 800 )) && resize=(-resize '200%')
		magick "$2" -crop "${5}x${6}+${3}+${4}" +repage "${resize[@]}" "$src" || exit 1
	fi
	zbarimg --raw -q "$src"
	status=$?
	[[ "$src" != "$2" ]] && rm -f "$src"
	exit "$status"
	;;
qr-check)
	command -v zbarimg >/dev/null || exit 127
	;;
palette)
	colors=$(magick "$2" -crop "${5}x${6}+${3}+${4}" +repage -resize '256x256>' -kmeans 6 -format %c histogram:info:- 2>/dev/null |
		sort -rn | grep -o '#[0-9A-Fa-f]\{6\}' | head -n 6)
	[[ -n "$colors" ]] || exit 1
	args=()
	for color in $colors; do args+=("xc:$color"); done
	magick -size 120x96 "${args[@]}" +append +repage "$7" || exit 1
	printf '%s\n' "$colors"
	;;
history-add)
	mkdir -p "$dir/history"
	cp "$2" "$3"
	;;
history-reset)
	rm -rf "$dir/history"
	mkdir -p "$dir/history"
	;;
scroll-capture)
	frames="$dir/scroll-$2"
	rm -rf "$frames"
	mkdir -p "$frames"
	# let the selection overlay leave the screen first
	sleep 0.4
	n=0
	prev=""
	while [[ ! -e "$frames/stop" ]] && (( n < 400 )); do
		file="$frames/$(printf '%04d' "$n").png"
		grim -l 1 -g "$3" "$file" || exit 1
		# a frame without movement is dropped right away
		if [[ -n "$prev" ]] && cmp -s "$prev" "$file"; then
			rm -f "$file"
		else
			prev="$file"
			n=$((n + 1))
		fi
		sleep 0.3
	done
	;;
scroll-stitch)
	frames="$dir/scroll-$2"
	python3 "$(dirname "$0")/scroll_stitch.py" "$frames" "$3" >/dev/null
	status=$?
	rm -rf "$frames"
	exit "$status"
	;;
scroll-drop)
	rm -rf "$dir/scroll-$2"
	;;
*)
	exit 2
	;;
esac
