# Quickshell UI theme engine

UI themes in this setup are deliberately separate from wallpaper/color themes and from Niri window animations. A UI theme changes geometry, depth, shell motion and the matching Niri window frame. All colors continue to come from the existing wallust palette.

## Using the picker

Open the launcher and choose **Interface Theme** (or type `>style`). The picker provides live previews for **Default**, **Neumorphism**, **Neo Brutalism**, and **Arcane Fantasy**. Click a card and press **Apply**, double-click it, or use the arrow keys and Enter.

The same picker is exposed through Quickshell IPC:

```sh
qs -p ~/.config/quickshell/main ipc call uiTheme toggle
qs -p ~/.config/quickshell/main ipc call uiTheme select neumorphism
qs -p ~/.config/quickshell/main ipc call uiTheme select neo-brutalism
qs -p ~/.config/quickshell/main ipc call uiTheme select fantasy
qs -p ~/.config/quickshell/main ipc call uiTheme select default
qs -p ~/.config/quickshell/main ipc call uiTheme current
```

The selected ID is persisted in `ui-theme.json` and restored when Quickshell starts.

## Adding another theme

Create `themes/<id>/theme.json` by copying `themes/default/theme.json`, then change its metadata and tokens. No existing QML component should be redesigned or copied. The engine discovers manifests dynamically through `scripts/theme_engine.py`; use `qs -p ~/.config/quickshell/main ipc call uiTheme reload` after adding one.

Every manifest must provide these groups:

- `radiusTiny`, `radiusSmall`, `radiusMedium`, `radiusLarge`: semantic corner radii. Existing circles continue to use `width / 2` or `height / 2` and are not altered.
- `fast`, `normal`, `popupOpen`, `popupClose`, `large`, `largeClose`: shared durations in milliseconds. Explicit legacy durations are scaled through `ThemeEngine.duration(...)`, so the theme remains internally consistent.
- `standardEasing`, `emphasizedEasing`, `popupOpenEasing`, `modalOpenEasing`, `exitEasing`: supported values are `outCubic`, `outQuart`, `outQuint`, `outExpo`, `outBack`, `outElastic`, `inCubic`, and `inQuart`.
- `elasticAmplitude`, `elasticPeriod`: tune the soft spring used by elastic theme entrances.
- `popupOvershoot`, `sheetOvershoot`, `smallOvershoot`: easing overshoot values.
- `popupStartScale`, `popupTravel`, `popupContentRevealStart`, `popupShadowDepth`: the entrance pose, content reveal and elevation of bar-attached popups.
- `modalStartScale`, `modalBottomTravelFactor`, `modalShadowDepth`: the corresponding choreography for centered and bottom modal sheets.
- `shadowEnabled`, `shadowBlur`, `shadowOffset`, `shadowSpread`, `darkShadowOpacity`, `lightShadowOpacity`: depth language. Shadows derive their light/dark tones from the existing surface color; they do not introduce a new palette.
- `controlEffectsEnabled`, `controlDepth`, `controlHoverDepth`, `controlPressedDepth`: enable and tune the material depth used by cards, buttons and popup content.
- `bevelOpacity`, `insetOpacity`: control raised edge highlights and recessed inner edges.
- `hoverScale`, `pressedScale`: reserved tactile state tokens for components that opt into scale feedback.
- `outlineWidth`, `outlineOpacity`, `hardShadow`: hard keylines and offset block-shadow rendering. Their tones are derived from the active wallust surface colors.

- `pressTravel`, `hoverLift`, `rippleEnabled`, `hoverTintOpacity`, `pressedTintOpacity`: physical button travel and pointer feedback.
- `toastStartScale`, `toastTravel`, `toastRotation`, `toastOpen`: notification entrance pose and timing.
- `solidSurfaces`: makes structural cards and controls opaque without changing their RGB palette roles; flat fills and overlays retain their authored alpha.
- `ornamentStyle`, `ornamentOpacity`, `ornamentLineWidth`, `ornamentInset`, `ornamentCornerLength`, `ornamentNotchSize`: enable and size a palette-derived decorative frame.
- `ornamentDoubleLine`, `ornamentCenterMarks`, `ornamentTrackCaps`: add engraved inner corners, diamond center marks, and jeweled caps to thin tracks such as sliders and progress bars.
- `ornamentGlowOpacity`, `ornamentPulseDuration`: tune the hover/press shimmer of ornamental controls.
- `dialogueNotifications`: replaces the standard notification body with an RPG dialogue panel and letter-by-letter reveal when enabled.

The stable runtime API is the `ThemeEngine` singleton from `components`. Components should consume semantic properties such as `ThemeEngine.radiusMedium`, `Motion.normal`, `ThemeEngine.standardEasing`, and `ThemedRectangle`. `ThemedRectangle` accepts `themeStyle: "raised"`, `"inset"`, `"flat"`, or `"auto"`; use explicit roles for tracks, inputs and slider fills. Components must not branch on a concrete theme ID. This keeps future themes manifest-only unless they introduce a genuinely new reusable rendering primitive.

Validate all manifests with:

```sh
python3 scripts/theme_engine.py | python3 -m json.tool
```

`Default` contains the original values, so selecting it restores the former geometry and motion without touching wallpaper, colors or application state.
