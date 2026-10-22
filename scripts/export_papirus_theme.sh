#!/usr/bin/env bash

set -euo pipefail

OOMOX_PAPIRUS_DIR="${OOMOX_PAPIRUS_DIR:-/opt/oomox/plugins/icons_papirus}"
TEMPLATE_DIR="$OOMOX_PAPIRUS_DIR/papirus-icon-theme/Papirus"

if (($# != 3)); then
	echo "usage: $0 <preset> <theme-name> <destination>" >&2
	exit 2
fi

PRESET_FILE="$1"
THEME_NAME="$2"
DESTINATION="$3"

[[ -f "$PRESET_FILE" ]] || { echo "Oomox preset not found: $PRESET_FILE" >&2; exit 1; }
[[ -d "$TEMPLATE_DIR" ]] || { echo "Oomox Papirus template not found: $TEMPLATE_DIR" >&2; exit 1; }
[[ -n "$THEME_NAME" && "$THEME_NAME" != */* ]] || { echo "invalid theme name: $THEME_NAME" >&2; exit 2; }
[[ -n "$DESTINATION" && "$DESTINATION" != / && "$DESTINATION" != "$HOME" ]] || { echo "unsafe destination: $DESTINATION" >&2; exit 2; }

# Oomox presets are shell-style KEY=VALUE files.
# shellcheck source=/dev/null
source "$PRESET_FILE"

ICONS_LIGHT_FOLDER="${ICONS_LIGHT_FOLDER:-${SEL_BG:?SEL_BG is missing from the Oomox preset}}"
ICONS_MEDIUM="${ICONS_MEDIUM:-$ICONS_LIGHT_FOLDER}"
ICONS_DARK="${ICONS_DARK:-$ICONS_MEDIUM}"
ICONS_SYMBOLIC_ACTION="${ICONS_SYMBOLIC_ACTION:-${MENU_FG:-}}"
ICONS_SYMBOLIC_PANEL="${ICONS_SYMBOLIC_PANEL:-${FG:-}}"

for color in "$ICONS_LIGHT_FOLDER" "$ICONS_MEDIUM" "$ICONS_DARK" \
	"$ICONS_SYMBOLIC_ACTION" "$ICONS_SYMBOLIC_PANEL"; do
	[[ -z "$color" || "$color" =~ ^[[:xdigit:]]{6}$ ]] || { echo "invalid icon colour: $color" >&2; exit 2; }
done

# the colours and the template the theme on disk was made from; the same
# palette again (a theme re-applied, a wallpaper with the same accent) is a
# no-op instead of ten seconds of copying and recolouring
STAMP="$THEME_NAME $ICONS_LIGHT_FOLDER $ICONS_MEDIUM $ICONS_DARK $ICONS_SYMBOLIC_ACTION $ICONS_SYMBOLIC_PANEL $(stat -c %Y -- "$TEMPLATE_DIR/index.theme")"
if [[ -f "$DESTINATION/index.theme" && -f "$DESTINATION/.pshell-stamp" && "$(<"$DESTINATION/.pshell-stamp")" == "$STAMP" ]]; then
	echo "Papirus theme unchanged in $DESTINATION"
	exit 0
fi

# A copy of the template of our own beside the destination, its files read
# only: a build is hard links to it (the template is root's, and protected
# hardlinks refuse links to another user's files), and only the icons that
# are recoloured become files of their own. Writing those always replaces the
# link (sed -i, rm before >), so the copy stays as it came; read only, a slip
# fails instead of recolouring every build at once.
PARENT_DIR="$(dirname -- "$DESTINATION")"
PRISTINE_DIR="$PARENT_DIR/.template"
mkdir -p -- "$PARENT_DIR"
TEMPLATE_STAMP="$TEMPLATE_DIR $(stat -c %Y -- "$TEMPLATE_DIR/index.theme")"
(
	exec 8>"$PARENT_DIR/.template.lock"
	flock 8
	[[ -f "$PRISTINE_DIR/.pshell-template" && "$(<"$PRISTINE_DIR/.pshell-template")" == "$TEMPLATE_STAMP" ]] && exit 0
	rm -rf -- "$PRISTINE_DIR.new"
	cp -a -- "$TEMPLATE_DIR" "$PRISTINE_DIR.new"
	find "$PRISTINE_DIR.new" -type f -exec chmod a-w {} +
	printf '%s\n' "$TEMPLATE_STAMP" >"$PRISTINE_DIR.new/.pshell-template"
	rm -rf -- "$PRISTINE_DIR"
	mv -T -- "$PRISTINE_DIR.new" "$PRISTINE_DIR"
)

# built beside the destination: the move at the end is a rename
WORK_DIR="$(mktemp -d "$PARENT_DIR/.build.XXXXXX")"
BACKUP_DIR="${DESTINATION}.old.$$"
cleanup() {
	rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

cp -al -- "$PRISTINE_DIR" "$WORK_DIR/Papirus"
rm -f -- "$WORK_DIR/Papirus/.pshell-template" "$WORK_DIR/Papirus/.pshell-stamp" "$WORK_DIR/Papirus/icon-theme.cache"

for size in 22x22 24x24 32x32 48x48 64x64; do
	for icon_path in "$WORK_DIR/Papirus/$size/places"/folder-red{-*,}.svg \
		"$WORK_DIR/Papirus/$size/places"/user-red{-*,}.svg; do
		if [[ -f "$icon_path" && ! -L "$icon_path" ]]; then printf "%s\0" "$icon_path"; fi
	done
done | perl -0 -e '
	# folder-red-x.svg recoloured into folder-oomox-x.svg, and folder-x.svg
	# pointed at it; one process for the few hundred of them
	my ($light, $medium, $dark) = @ARGV;
	while (my $path = <STDIN>) {
		chomp $path;
		my ($dir, $name) = $path =~ m{^(.*)/([^/]+)$};
		(my $new = $name) =~ s/-red/-oomox/;
		(my $link = $new) =~ s/-oomox//;
		open(my $in, "<", $path) or die "$path: $!";
		local $/;
		my $svg = <$in>;
		close $in;
		$svg =~ s/#e25252/#$light/g;
		$svg =~ s/#bf4b4b/#$medium/g;
		$svg =~ s/#4f1d1d/#$dark/g;
		unlink "$dir/$new";
		open(my $out, ">", "$dir/$new") or die "$dir/$new: $!";
		print $out $svg;
		close $out or die "$dir/$new: $!";
		unlink "$dir/$link";
		symlink($new, "$dir/$link") or die "$dir/$link: $!";
	}
' "$ICONS_LIGHT_FOLDER" "$ICONS_MEDIUM" "$ICONS_DARK"

# one sed per few hundred files, on every core: the seven thousand icons
# took a sed each before, ten seconds of forking; only the files holding the
# colour, the others stay links to the template
replace_in_tree() {
	local old_color="$1"
	local new_color="$2"
	shift 2
	local -a trees=()
	[[ -n "$new_color" ]] || return 0
	for tree in "$@"; do
		[[ -d "$tree" ]] && trees+=("$tree")
	done
	(( ${#trees[@]} )) || return 0
	find "${trees[@]}" -type f -name '*.svg' -print0 \
		| xargs -0 -r grep -lZF -- "$old_color" \
		| xargs -0 -r -P "$(nproc)" -n 200 sed -i "s/$old_color/$new_color/g"
}

replace_in_tree 444444 "$ICONS_SYMBOLIC_ACTION" \
	"$WORK_DIR/Papirus/16x16/actions" "$WORK_DIR/Papirus/22x22/actions" \
	"$WORK_DIR/Papirus/24x24/actions" "$WORK_DIR/Papirus/16x16/devices" \
	"$WORK_DIR/Papirus/16x16/places" "$WORK_DIR/Papirus/symbolic"
replace_in_tree dfdfdf "$ICONS_SYMBOLIC_PANEL" \
	"$WORK_DIR/Papirus/16x16/panel" "$WORK_DIR/Papirus/22x22/panel" \
	"$WORK_DIR/Papirus/24x24/panel" "$WORK_DIR/Papirus/22x22/animations" \
	"$WORK_DIR/Papirus/24x24/animations"

sed -i "s/^Name=Papirus$/Name=$THEME_NAME/" "$WORK_DIR/Papirus/index.theme"
printf '%s\n' "$STAMP" >"$WORK_DIR/Papirus/.pshell-stamp"
mkdir -p -- "$(dirname "$DESTINATION")"
[[ ! -e "$BACKUP_DIR" ]] || { echo "backup destination already exists: $BACKUP_DIR" >&2; exit 1; }

if [[ -e "$DESTINATION" ]]; then
	mv -T -- "$DESTINATION" "$BACKUP_DIR"
fi
if mv -T -- "$WORK_DIR/Papirus" "$DESTINATION"; then
	rm -rf -- "$BACKUP_DIR"
else
	[[ ! -e "$BACKUP_DIR" ]] || mv -T -- "$BACKUP_DIR" "$DESTINATION"
	exit 1
fi

echo "Papirus theme generated in $DESTINATION"
