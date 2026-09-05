#!/usr/bin/env python3
"""Small dependency-free catalog/validation helper for UI shape themes."""

from __future__ import annotations

import json
import sys
from pathlib import Path


REQUIRED_TOKENS = {
    "radiusTiny", "radiusSmall", "radiusMedium", "radiusLarge",
    "fast", "normal", "popupOpen", "popupClose", "large", "largeClose",
    "standardEasing", "emphasizedEasing", "popupOpenEasing",
    "modalOpenEasing", "exitEasing", "elasticAmplitude", "elasticPeriod",
    "popupOvershoot", "sheetOvershoot", "smallOvershoot", "popupStartScale",
    "popupTravel", "popupContentRevealStart", "popupOpacityMultiplier",
    "popupShadowDepth",
    "modalStartScale", "modalBottomTravelFactor", "modalShadowDepth",
    "controlDepth", "controlHoverDepth", "controlPressedDepth",
    "bevelOpacity", "insetOpacity", "controlEffectsEnabled",
    "shadowEnabled", "shadowBlur",
    "shadowOffset", "shadowSpread", "darkShadowOpacity",
    "lightShadowOpacity", "hoverScale", "pressedScale",
    "outlineWidth", "outlineOpacity", "hardShadow", "pressTravel",
    "hoverLift", "rippleEnabled", "hoverTintOpacity", "pressedTintOpacity",
    "toastStartScale", "toastTravel", "toastRotation", "toastOpen",
    "solidSurfaces",
	"ornamentStyle", "ornamentOpacity", "ornamentLineWidth",
	"ornamentInset", "ornamentCornerLength", "ornamentNotchSize",
	"ornamentDoubleLine", "ornamentCenterMarks", "ornamentTrackCaps",
	"ornamentGlowOpacity", "ornamentPulseDuration",
	"dialogueNotifications",
}


def load_catalog(root: Path) -> list[dict]:
    entries: list[dict] = []
    for path in sorted(root.glob("*/theme.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        missing = REQUIRED_TOKENS.difference(data.get("tokens", {}))
        if not data.get("id") or not data.get("name") or missing:
            raise ValueError(f"{path}: invalid theme; missing {sorted(missing)}")
        data["manifestPath"] = str(path)
        entries.append(data)
    return entries


def main() -> int:
    themes_dir = Path(__file__).resolve().parent.parent / "themes"
    try:
        catalog = load_catalog(themes_dir)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    print(json.dumps(catalog, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
