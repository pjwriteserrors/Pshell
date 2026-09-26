import os
import re

# Input CSS file (from pywal)
css_file = os.path.expanduser("~/.cache/wal/colors.css")
# Output Spicetify ini
spiceFile = os.path.expanduser("~/.config/spicetify/Themes/custom/color.ini")

def hex_to_rgb(hexcode):
    hexcode = hexcode.lstrip("#")
    return tuple(int(hexcode[i:i+2], 16) for i in (0, 2, 4))

def rgb_to_hex(r, g, b):
    return "#{:02X}{:02X}{:02X}".format(r, g, b)

def to_hex_nohash(r, g, b):
    return "{:02X}{:02X}{:02X}".format(r, g, b)

def adjust_color(r, g, b, amount):
    r = max(0, min(255, r + amount))
    g = max(0, min(255, g + amount))
    b = max(0, min(255, b + amount))
    return r, g, b

def lighter(r, g, b, amount):
    return adjust_color(r, g, b, amount)

def darker(r, g, b, amount):
    return adjust_color(r, g, b, -amount)

def ensure_readable(r, g, b):
    brightness = (r*299 + g*587 + b*114) / 1000
    if brightness < 128:
        return min(r+80, 255), min(g+80, 255), min(b+80, 255)
    return r, g, b

# Extract hex colors from CSS
with open(css_file, "r") as f:
    css_content = f.read()

hex_codes = re.findall(r"#([0-9A-Fa-f]{6})", css_content)
colors = ["#" + c for c in hex_codes]

# Defensive: make sure we got enough colors
if len(colors) < 6:
    raise ValueError("Not enough colors found in CSS file!")

# Pick base colors
bg = colors[0]
fg = colors[1]
accent = colors[4]

fg_r, fg_g, fg_b = hex_to_rgb(fg)
fg_r, fg_g, fg_b = ensure_readable(fg_r, fg_g, fg_b)
fg_hex = rgb_to_hex(fg_r, fg_g, fg_b)

mapping = {
    "topbar": bg,
    "topbar-text": fg_hex,
    "topbar-subtext": colors[2],
    "tab-active": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),
    "tab-active-text": fg_hex,
    "tab-hover": rgb_to_hex(*lighter(*hex_to_rgb(bg), 20)),
    "topbar-border": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),

    "sidebar": bg,
    "sidebar-text": fg_hex,
    "link-hover-text": rgb_to_hex(*lighter(*hex_to_rgb(colors[5]), 30)),
    "link-active": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),
    "link-active-text": fg_hex,
    "sidebar-border": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),

    "main": bg,
    "text": fg_hex,
    "subtext": colors[3],
    "selected-row": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),

    "player": rgb_to_hex(*lighter(*hex_to_rgb(bg), 10)),
    "player-text": fg_hex,
    "player-subtext": colors[3],
    "player-selected-row": rgb_to_hex(*lighter(*hex_to_rgb(colors[5]), 20)),
    "player-border": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),

    "button": accent,
    "button-active": rgb_to_hex(*lighter(*hex_to_rgb(accent), 20)),
    "button-disabled": rgb_to_hex(*darker(*hex_to_rgb(colors[2]), 20)),

    "scrollbar": rgb_to_hex(*darker(*hex_to_rgb(bg), 10)),
    "scrollbar-hover": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),

    "context-menu": bg,
    "context-menu-text": fg_hex,
    "context-menu-hover": rgb_to_hex(*darker(*hex_to_rgb(bg), 20)),

    "card": rgb_to_hex(*lighter(*hex_to_rgb(bg), 5)),
    "shadow": rgb_to_hex(*darker(*hex_to_rgb(bg), 40)),
    "notification": accent,
    "notification-error": to_hex_nohash(204, 36, 29),
    "misc": rgb_to_hex(*lighter(*hex_to_rgb(colors[3]), 10)),

    "main-elevated": rgb_to_hex(*lighter(*hex_to_rgb(colors[3]), 40)),
    "highlight-elevated": rgb_to_hex(*lighter(*hex_to_rgb(colors[5]), 40)),
    "highlight": rgb_to_hex(*lighter(*hex_to_rgb(accent), 40))
}

with open(spiceFile, "w") as spice:
    spice.write("[Base]\n")
    for key, value in mapping.items():
        if value.startswith("#"):
            r, g, b = hex_to_rgb(value)
        else:
            r, g, b = hex_to_rgb("#" + value)
        if "text" in key or "subtext" in key:
            r, g, b = ensure_readable(r, g, b)
        spice.write(f"{key} = {to_hex_nohash(r, g, b)}\n")

print(f"Spicetify theme written to {spiceFile}")
