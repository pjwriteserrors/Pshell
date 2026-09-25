#!/usr/bin/env bash
# Spotify. hookConfig.spicetify.generator writes the colour scheme;
# refresh: true re-patches the client afterwards.
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
generator="$(hook_config generator)" || skip "no generator configured"
[[ -f "$generator" ]] || skip "generator missing: $generator"
python3 "$generator"
if [[ "$(hook_config refresh)" == "true" ]]; then
	spicetify config current_theme custom color_scheme Base >/dev/null 2>&1 || true
	# after a Spotify update this fails until `spicetify backup apply` is run
	spicetify refresh || spicetify apply || echo "spicetify could not re-patch Spotify; run: spicetify backup apply"
fi
