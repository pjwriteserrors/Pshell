#!/bin/sh
# Starts the WhatsApp bridge for core/services/WhatsApp.qml, building it first
# when its sources are newer than the program (the first time takes a minute
# or two). `run.sh build` only builds; `run.sh update` fetches the newest
# whatsmeow first, which is what helps when WhatsApp asks for a newer client.
here=$(cd "$(dirname "$0")" && pwd)
out="${XDG_CACHE_HOME:-$HOME/.cache}/pshell/whatsapp"
bin="$out/bridge"

say() {
	printf '{"event":"state","state":"%s","error":"%s","qr":"","code":"","syncing":false,"gifs":false}\n' "$1" "$2"
}

go=$(command -v go || true)
[ -z "$go" ] && [ -x /usr/local/go/bin/go ] && go=/usr/local/go/bin/go

stale() {
	[ ! -x "$bin" ] && return 0
	for file in "$here"/*.go "$here/go.mod" "$here/go.sum"; do
		[ "$file" -nt "$bin" ] && return 0
	done
	return 1
}

mkdir -p "$out"
chmod 700 "$out"
if [ "$1" = "update" ]; then
	[ -z "$go" ] && { echo "go is not installed" >&2; exit 1; }
	(cd "$here" && "$go" get go.mau.fi/whatsmeow@latest && "$go" mod tidy) || exit 1
fi
if stale; then
	if [ -z "$go" ]; then
		say missing "Go is needed to build the WhatsApp bridge (pacman -S go)"
		# the shell starts this again once it ended
		sleep 3600
		exit 1
	fi
	say building ""
	if ! problem=$(cd "$here" && "$go" build -trimpath -o "$bin.new" . 2>&1); then
		echo "$problem" >&2
		say missing "The WhatsApp bridge does not build – see the shell's log"
		sleep 600
		exit 1
	fi
	mv "$bin.new" "$bin"
fi
[ "$1" = "build" ] || [ "$1" = "update" ] && exit 0
exec "$bin"
