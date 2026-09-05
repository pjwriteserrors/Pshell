# Quickshell Rework Plan

> **STATUS (2026-07-11): Umgesetzt.** Phasen 1–6 und der finale Sweep (§7 Schritte 1–6, 8) sind implementiert und laufen live:
> `components/` enthält Motion (Singleton), Anim, CAnim, SpatialAnim, HoverLayer, PopupSurface, ModalSheet.
> Alle 6 Quick-Popups + Tray-Menü nutzen PopupSurface; Power/Launcher/ThemePicker/AnimationPicker nutzen ModalSheet
> (ThemePicker/AnimationPicker haben damit erstmals echte Ein-/Ausblendanimationen; tote sheetOffset-Props entfernt).
> HoverLayer ist in Bar, Replika-Bar und Popup-Rows ausgerollt; QuickLock hat Reveal-Animation; danger-Farbe zentralisiert.
> Die Modal-Fenster haben jetzt explizit `screen: root.primaryBarScreen` (vorher landeten sie auf beliebigen Outputs).
> **Offen:** §7 Schritt 7 (volle Extraktion einer gemeinsamen Bar-Komponente) wurde bewusst auf Drift-Fixes reduziert
> (TopBarReplica hat jetzt Tray-Icon-Normalisierung + HoverLayer); die vollständige Dedupe bleibt als Follow-up.
> Außerdem pre-existing: `root.addThemeTaskPopup()` wird vom themeTask-IpcHandler aufgerufen, existiert aber nicht.
>
> **UPDATE (2. Pass, 2026-07-11): Komplettes Visual-Redesign „Floating Islands".** Keine durchgehende Bar-Fläche mehr —
> jedes Bar-Modul ist eine solide `surface`-Pill (radius = height/2), die mit 6px Top-Margin über dem Wallpaper schwebt;
> Launcher-Pill in `primary`, Power-Pill danger-getönt. Neue Farbrollen: primary (wal color4), secondary (color6),
> accent (color3), surface/surfaceBorder/onPrimary; alle secondaryBox*-Farben sind jetzt primary/secondary-Tints.
> PopupSurface wurde von PopupWindow auf Fullscreen-PanelWindow (WlrKeyboardFocus.OnDemand) umgeschrieben —
> **fixt den Bug, dass Eingabefelder in Popups keine Tastatur bekamen** (mit wtype verifiziert). Popups sind jetzt
> abgelöste schwebende Karten (radius 18, 1px Border, Pop-Entrance: Slide+Scale mit OutBack + Fade); die
> Schulter/Bridge-Verschmelzung mit der Bar ist Geschichte. Schließen von außen läuft über `dismissRequested()`.
>
> **UPDATE (3. Pass, 2026-07-11): Content-Redesign aller Popups.** Clock-Popup in drei eigenständige Popups
> aufgeteilt: Kalender (an der Uhr), Wetter (neue Wetter-Pill mit Temperatur in der Bar) und Notification-Center
> (neue Bell-Pill mit Zähler-Badge, „Clear all"). MediaPopupContent.qml komplett neu um einen 40-Balken-Cava-Hero
> herum (Cover+Titel schweben über dem Spektrum, seekbare Progressbar, Pill-Transportcontrols, Player-Chips;
> der Per-App-Mixer wurde entfernt). Clipboard: Header mit Zähler + Clear-all (cliphist wipe), Pill-Suche,
> Löschen pro Eintrag (cliphist delete), IMG-Badges, Listen-Transitions. Bluetooth: animierter Power-Switch,
> Scan-Zeile mit rotierendem Icon, Gerätetyp-Icons, Batterie-Chips, Primary-Highlight für Verbundenes.
> Resources: animierte 270°-Arc-Gauges (`ArcGauge`-Komponente) für CPU/RAM. Network: Status-Header mit
> Interface/IP + Disconnect-Button. Launcher: Pill-Suchfeld mit Fokusring, App-Rows mit Icon-Chips,
> Accent-Auswahl mit animiertem Indikator. Neuer `panels`-IpcHandler (toggleCalendar/Weather/Notifications/
> Media/Bluetooth/Network/Resources).
>
> **UPDATE (4. Pass, 2026-07-11): Feedback-Runde.** Globaler Radius auf 7px vereinheitlicht (nur echte Kreise
> bleiben rund). Bar auf 34px verdichtet, Pills auf volle Bar-Höhe, Popup-Gap = Top-Margin = 6px. Launcher als
> 5-spaltiges Icon-Grid (40px Icons, Label darunter, Accent-Auswahl). Media-Popup mit integriertem Volume-Slider
> + Output-Sektion (Radio-Rows). Toasts mit Urgency-Stripe, Icon-Chip, Action-Pills und animierter Countdown-Bar.
> Power-Menü als 560×236-Sheet mit User-Panel (Avatar, uptime/kernel-Chips) + 2×2 Action-Tiles.
>
> **UPDATE (5. Pass, 2026-07-12): Zweite Feedback-Runde.** exclusiveZone ohne `+6` (niri addiert die Margin
> selbst — der Abstand unter der Bar war doppelt). NiriTaskbar-Icons vertikal zentriert mit größerer Hover-Fläche.
> Sink-Auswahl im Media-Popup von wpctl auf **pactl** umgestellt (`pactl --format=json list sinks` +
> `set-default-sink <name>`), weil `wpctl set-default` Internal-Sinks wie das EVO4 ablehnt; Rows zeigen jetzt die
> Description. Launcher-Grid: Pfeiltasten Links/Rechts navigieren jetzt (±1), Hoch/Runter (±Spalten).
> **Notification-Design v2** (Toast + Center): urgency-getöntes Header-Band oben (Punkt + APP-NAME in Caps +
> Zeit + ×), darunter Titel/Body links und 52px-Thumbnail rechts (Crop bei echten Bildern), Countdown-Bar unten.

**Audience**: the next LLM/engineer implementing this. This document is a plan, not a diff. It describes what must change, why, and roughly how — read it fully before touching code, then execute it in the phase order given.

## 0. Context you need before starting

- This shell runs on **niri**, not Hyprland. `caelestia/` in this repo is a **reference-only clone of caelestia-shell** (which targets Hyprland) — it exists purely so you can copy its *design language* (motion curves, layout composition, component structure). **Never** wire in `Quickshell.Hyprland` imports or Hyprland IPC calls. Everything niri-specific already works via `NiriState.qml` (polls `niri msg -j workspaces/windows`) and `NiriTaskbar.qml` — preserve and extend that, don't replace it with Hyprland concepts.
- The live shell is almost entirely monolithic: `shell.qml` (5590 lines) inlines the bar, and ~10 popups, each hand-rolled. `AppLauncherPopup.qml`, `ThemePickerPopup.qml`, `AnimationPickerPopup.qml`, `MediaPopupContent.qml`, `QuickLock.qml` are the only split-out pieces, loaded via `Loader`/`sourceComponent` from inside `shell.qml`.
- Colors come from **pywal** (`~/.cache/wal/colors.json`, loaded at shell.qml:1008-1019) exposed as `root.background`, `root.foreground`, `root.accent` (`wal.colors.color3`), `root.tertiary` (`wal.colors.color1`), `root.border` (`wal.colors.color8`), plus derived `secondaryBoxColor`/`secondaryBoxStrongColor`/`secondaryInsetColor`. **Keep this palette as the single source of truth — do not introduce a parallel Material3 palette system like caelestia's `Colours.palette.m3*`.** The rework is about motion and layout, not recoloring. The only color-related fix needed is consolidating the repeated hardcoded `#d95c5c` danger/error red (appears in shell.qml, AppLauncherPopup.qml ×5, QuickLock.qml, AnimationPickerPopup.qml) into one `root.danger` (or `root.error`) property so it can be tinted from the palette later if desired, and doing the same for the two AnimationPickerPopup speed-tier colors (`#f07f86`/`#d7c477`).
- Full current-state catalog (every popup, its trigger, its animation, its layout, its inconsistencies) was produced during planning and is summarized in section 2 below — treat that as ground truth for "what exists today," verified against file:line references.

## 1. Goals, in priority order

1. **Every popup/overlay animates identically at the shell level.** Same easing family, same duration family, same choreography (grow-from-anchor + content fade-in that trails slightly behind the container). Right now 4 different animation systems coexist (openProgress height/radius blend, Translate-based sheet slide, plain opacity+scale, and *no animation at all* for theme/animation picker). This is the #1 complaint to fix.
2. **Bouncy, alive motion**, matching caelestia's feel — achieved via Material-3-style *expressive* bezier curves with overshoot on the way in, and a crisper decelerate-only curve on the way out. Not literal `Easing.OutBack` spring-bounce everywhere (that reads as toy-ish at 90ms durations); bounce comes from the *bezier curve shape* at slightly longer durations (~300-450ms), the same way caelestia does it.
3. **One shared popup "shell" component** (anchor rect, corner radius, shoulder/bridge connector to the bar, backdrop dimming rules, content Loader lifecycle) that every popup instantiates instead of copy-pasting ~70 lines each. This eliminates the six duplicated `openProgress` blocks and fixes the theme-picker/animation-picker dead-animation bug for free.
4. **Consistent layout language** across popups: consistent padding scale, consistent corner radius scale, consistent header treatment (icon + title + close affordance where relevant), consistent use of `ColumnLayout`/`RowLayout` instead of a mix of plain `Column`/`Row` and Layouts.
5. Where a popup's current fixed size is awkward (clock popup's dense two-pane 980×432 fixed block, launcher's fixed 720×430 that doesn't reflect content like the AI chat or file browser tabs, animation picker's cramped 520×430), **resize it** to fit its content better. You're explicitly allowed to do this.
6. Keep pywal colors, keep niri integration, keep all existing functionality (cliphist, bluetoothctl, nmcli, mpris/pipewire media, ollama chat, calculator, file browser, command palette, weather, PAM lock) working exactly as before — this is a motion/layout rework, not a feature rewrite.

## 2. Current-state inventory (verified)

### The shared (broken) animation baseline

Six popups — **clipboard** (shell.qml:1833-2188), **bluetooth** (2188-2736), **network** (2737-3251), **resources** (3252-3451), **media** (4153-4300 + `MediaPopupContent.qml`), **clock** (4300-4429) — each independently declare:

```qml
property real openProgress: root.xPopupOpen ? 1 : 0
Behavior on openProgress {
    NumberAnimation { duration: 90; easing.type: Easing.OutCubic; easing.overshoot: 0 }
}
readonly property real shellRadius: 18 - 10 * openProgress
```
plus a hand-tuned 4-rectangle "shoulder/bridge" fake connector to the bar (magic numbers per popup: shoulderWidth/bridgeInset differ — 92/68, 176/102, 112/86...), plus a content-opacity fade formula `Math.max(0, (openProgress - 0.08) / 0.92)`. 90ms is very fast/snappy, not bouncy, and the "ternary" `root.xPopupOpen ? 90 : 90` in several of these is dead (open/close durations are identical, so it was clearly meant to differ and never got tuned).

The **tray menu popup** (shell.qml:3891-3924) is the one outlier: content-height-scaled duration + `Easing.OutBack`/`overshoot 0.35` on close only. This is actually the closest thing to "bouncy" already in the codebase — worth learning from, not discarding.

The **power popup** (shell.qml:3648-3751) uses a totally different pattern: plain `opacity`/`scale` Behaviors (`scale: open ? 1 : 0.94`), 90ms open / 120ms close, OutCubic, with an animated scrim (`Qt.rgba(0,0,0,0.24)`).

The **launcher** (shell.qml:3502-3596, content in `AppLauncherPopup.qml`) uses yet another pattern: a `Translate` transform driven by `root.launcherSheetOffset` (454→0), animated via a 90ms OutCubic `Behavior on y`, orchestrated by two `Timer`s (`launcherPopupOpenTimer`, `launcherPopupResetTimer`) to sequence visibility→offset-reset→animate. Its backdrop animates `opacity` on an always-`"transparent"` `color`, i.e. is a no-op animation.

**Theme picker** (shell.qml:3452-3500 + `ThemePickerPopup.qml`) and **animation picker** (shell.qml:3598-3646 + `AnimationPickerPopup.qml`) have **no open/close animation whatsoever** — they pop in/out instantly. Their `themePickerSheetOffset`/`animationPickerSheetOffset` properties are dead code (set, never bound to anything visual). Their close timers are unreachable dead code because `visible` is set to false synchronously. **This is the most obviously unfinished part of the current shell and the highest-value fix.**

**QuickLock.qml** (the niri session-lock screen) also has **zero entrance/exit animation** on the whole full-screen surface — it just snaps `visible`. It does have nice micro-polish already (a per-keystroke "type pulse" `ParallelAnimation`, an input-length progress bar with `Behavior on width`) that should be preserved.

### Layout inconsistencies

- Container types are mixed for no functional reason: clipboard is a `PanelWindow` with manual `x`/`y`; bluetooth/network/resources/media/clock/tray are `PopupWindow`s anchored via `anchor{ window; edges; gravity }`; power/theme-picker/animation-picker/launcher are full-screen `PanelWindow`s with `anchors.centerIn` or bottom-pinned content.
- Border/shadow language differs: the "quick" popups (clipboard/bluetooth/network/resources/media/clock/power) are flat, `border.width: 0`, no shadows anywhere in the project (`grep -r shadowEnabled` finds nothing). Theme-picker/animation-picker instead draw visible 1-3px borders and `radius: 18` cards. Pick one language (see §4) and apply it everywhere.
- Layout containers are mixed: clipboard/bluetooth/network/resources/launcher use plain `Column`/`Row`; media popup and clock popup use `QtQuick.Layouts`; theme-picker/animation-picker mix both. Standardize on `ColumnLayout`/`RowLayout` everywhere going forward — plain `Column`/`Row` only for trivial single-axis stacks with no per-item sizing needs.
- `TopBarReplica.qml` (secondary-monitor bar) duplicates ~150 lines of the inline bar markup in shell.qml almost verbatim, and has drifted (missing icon-source normalization, missing right-click tray menu, always-square corners). Should become a genuinely shared `Bar` component parameterized by `screen`/`isPrimary`, not two independently-maintained copies.
- Hover/press feedback is almost entirely absent: `TopBarNetworkButton`, `TopBarResourceBars`, `clockIsland`, `launcherButton`, `powerButton` set `hoverEnabled: true` purely to get a pointing-hand cursor, with **zero visual hover state**. `NiriTaskbar` is the only place with hover/focus color swapping, and even there it's an instant `color:` snap with no `Behavior`. Media pill (`NowPlaying.qml`) resizes its width abruptly when playback starts/stops (no `Behavior on implicitWidth`), while the progress bar inside it does animate — inconsistent.
- No workspace-switcher UI exists at all today (only a flat per-window taskbar row). Out of scope to invent a full workspace pager unless you have appetite, but at minimum give `NiriTaskbar` pills the hover/focus color transition and entrance/exit animation they're missing (see §6).

## 3. Motion system — the foundation everything else builds on

Create a small set of shared animation primitives, mirroring caelestia's `Anim.qml`/`CAnim.qml` pattern, so every popup imports the *same* definitions instead of retyping `NumberAnimation { duration: 90; easing.type: Easing.OutCubic }` from scratch each time.

### 3.1 Curves

Define these as `list<real>` bezier curves (usable with `Easing.BezierSpline`, `easing.bezierCurve:`), or if avoiding a config singleton, as named constants in a small `Anim.qml`/`MotionCurves.qml` you create alongside the popup components:

- **`expressiveDefaultSpatial`** `[0.38, 1.21, 0.22, 1, 1, 1]` — the workhorse "open"/"grow" curve. The `1.21` y-control-point is what gives the gentle overshoot/bounce feel on size and position changes without looking like a literal spring. Use for: popup width/height/scale growing in, sheet slide-in, content reveal, tab switches, workspace pill growth.
- **`expressiveFastSpatial`** `[0.42, 1.67, 0.21, 0.9, 1, 1]` — snappier/more pronounced overshoot, shorter distance. Use for small UI elements: icon toggles, ripple/press feedback, checkbox/switch flips, badge pop-ins.
- **`emphasized`** `[0.05, 0, 2/15, 0.06, 1/6, 0.4, 5/24, 0.82, 0.25, 1, 1, 1]** — no overshoot, decisive accelerate-then-decelerate. Use for **closing**/collapsing (popups should close crisply, not bounce shut — bouncing on exit reads as laggy, not lively).
- **`standard`** `[0.2, 0, 0, 1, 1, 1]` — plain ease, no overshoot. Use for simple opacity/color cross-fades that shouldn't have any spatial bounce (backdrop scrim opacity, text color transitions, hover tints).

You do not have to use `Easing.BezierSpline` if you'd rather keep things simpler/cheaper — `Easing.OutBack` with a tuned `easing.overshoot` (0.15–0.35) plus a longer duration (280-380ms) gets visually close and is one line instead of a curve array. **Recommendation: use `OutBack`/small-overshoot for size/position (the "grow" motion) and `OutCubic` (no overshoot) for opacity/color, and `InCubic`/`OutCubic` for closing** — this gets 90% of caelestia's feel with far less new plumbing than porting the full bezier-curve config system. Pick one approach and apply it uniformly; don't mix bezier-curve popups with OutBack popups.

### 3.2 Durations

Replace the flat 90ms everywhere with a small duration scale:
- `fast` (~120ms) — hover/press color changes, ripple, tiny icon toggles.
- `normal` (~220ms) — default for most content transitions (tab switches, list item add/remove, row expand/collapse).
- `popup` (~320ms open / ~220ms close) — the popup container grow/shrink itself. Slightly longer than content transitions so the container motion reads as the "big" gesture and nested content settles right after it (stagger, see 3.3), matching caelestia's `expressiveDefaultSpatial` duration of 500ms scaled down a bit since this shell's popups are smaller/closer to the bar than caelestia's full dashboard/sidebar panels.
- `large` (~450ms) — full-screen surfaces: lock screen, launcher, power modal, theme/animation picker.

90ms should essentially disappear from the codebase except for the tiniest micro-interactions (ripple radius growth, checkbox tick).

### 3.3 Choreography (the "same animation for every popup" contract)

Every popup, regardless of trigger location, follows this exact sequence — this consistency is the actual deliverable the user asked for, more than any specific curve:

1. **Open**: container scales/grows from its anchor point (typically the triggering bar icon, or top-center/bottom-center of the bar for centered popups) using the "grow" curve+duration from §3.1/3.2. Corner radius interpolates from the anchor-icon's radius (usually the bar's `7px`) down to the popup's own radius (recommend flattening the current `18-10*progress` inverse-scaling formula — see §4) over the same progress.
2. **Content fade-in trails the container by a short delay** (~40-60ms) rather than fading in lock-step with the container growth — this is what makes caelestia's popups feel "alive" instead of just "resized." Implement via a `SequentialAnimation`/`PauseAnimation` on content opacity, or a second `Behavior` with `easing.type` including a slight delay, or simplest: bind content opacity to `Math.max(0, (openProgress - 0.15) / 0.85)` (the codebase already does a version of this per-popup — keep the idea, just standardize the 0.15 threshold and the curve across all popups instead of six slightly different formulas).
3. **Close**: no overshoot, moderately quicker than open, container shrinks back toward the same anchor point while content opacity drops out faster than it faded in (content should basically be gone by ~50% of the close progress, not still fading at the end — closing should feel instant-ish, opening should feel like it blooms).
4. **The shoulder/bridge "visually attached to the bar" connector** (the fake rounded-corner-merge rectangles) should be extracted into the shared popup shell component (§4) as a configurable width and behave identically for every bar-anchored popup — currently each popup hand-tunes its own shoulder/bridge pixel constants; make this a single formula taking the popup's own width as input so it scales automatically instead of needing per-popup magic numbers.
5. Full-screen modal popups (power, theme picker, animation picker, launcher, lock) additionally get a **backdrop scrim** that cross-fades independently using the `standard` (no-bounce) curve — currently only power/theme-picker/animation-picker dim the backdrop and clipboard/bluetooth/network/resources/media/clock/launcher/tray don't; that split is *fine* to keep conceptually (corner popups shouldn't dim the whole screen, full-screen ones should) but the launcher's backdrop opacity currently animates a transparent color (dead code) — either give it a real scrim (small opacity, e.g. 0.15-0.2, so the launcher reads as "modal" against the desktop) or remove the dead Behavior. Recommend giving it a real (subtle) scrim for visual consistency with power/theme/animation pickers, since launcher is conceptually the same class of full-screen modal.

## 4. Shared popup shell component

Build one reusable component — call it `PopupSurface.qml` (or similar) — that every corner-anchored popup (clipboard, bluetooth, network, resources, media, clock, tray menu) wraps its content in. It should own:

- The `PopupWindow`/`PanelWindow` container setup and anchor-to-bar logic (pick **one** container strategy — recommend standardizing all of these on `PopupWindow` anchored via `anchor{ window: barWindow; edges; gravity; onAnchoring }`, since that's what 5 of the 6 already use; migrate clipboard off its bespoke manual-`x`/`y` `PanelWindow` to match).
- `openProgress`, the grow/shrink `Behavior`, corner radius formula, and content-fade formula from §3.3, as internal implementation — popup authors just set `open: bool`, `anchorItem: Item` (the bar icon/island to grow from and to draw the shoulder connector toward) and get correct behavior for free.
- The shoulder/bridge connector, generalized to take the popup's `shellWidth` and the anchor item's geometry and compute shoulder/bridge sizing automatically rather than needing hand-tuned constants per popup.
- A `contentItem`/default property slot for the popup's actual content, so each popup file becomes "just the content" (header + body), not "content + boilerplate open/close/shoulder machinery."
- Sizing modes: `fixedSize` (width/height constants, for popups like today's clock popup that want a stable layout) vs `contentSized` (grows to `content.implicitWidth/Height` with a max-height clamp against screen bounds, closer to how clipboard/bluetooth/resources currently work). Expose both since different popups legitimately want different strategies — but the *animation* stays identical either way.

Apply the **same visual language** to every popup shell: flat, no visible border (`border.width: 0`), `root.background` fill, corner radius scale from §4.1 below, no drop shadows (keep consistent with current no-shadow approach — adding real shadows everywhere is a bigger visual departure than the user asked for; skip unless you want to also propose it as an optional enhancement called out separately, not required).

### 4.1 Corner radius scale (replace ad-hoc `18-10*progress` per popup)

Adopt a 3-step scale similar to caelestia's `Rounding` (`small`/`normal`/`large`): e.g. `small = 8`, `normal = 14`, `large = 20`. Corner-popups (clipboard/bluetooth/network/resources/media/clock/tray) use `normal` at rest; full-screen modal surfaces (theme picker/animation picker/power/launcher sheet) use `large`. Drop the inverse inflate-while-opening formula (`18 - 10*progress`, which shrinks the radius as the popup opens — an odd choice, larger radius when small + collapsed, smaller radius when big + expanded, backwards from typical Material motion) in favor of a constant target radius the whole time, or if you want a "morph from bar pill" effect, radius interpolates from the **bar's own radius (7)** at progress=0 up/down to the popup's resting radius at progress=1 — i.e. radius should converge *toward* its resting value, not away from it.

### 4.2 Theme picker / animation picker specifically

These two currently have zero panel animation and dead offset properties. Fold them into the full-screen-modal animation pattern (scrim backdrop cross-fade + sheet scale/opacity grow from `emphasized`/grow curve, `large` duration) shared with the power popup and launcher sheet — i.e., **four different full-screen surfaces (power, launcher, theme picker, animation picker) should share one "modal sheet" wrapper component**, analogous to `PopupSurface` but for centered/bottom-pinned modal sheets instead of bar-anchored corner popups. Remove the dead `themePickerSheetOffset`/`animationPickerSheetOffset` properties and their unreachable close-timers entirely once the shared component supplies real animation.

Given their content, consider resizing: Animation picker's current 520×430 is cramped for a grid of preview cards with live niri-animation demos — widen it (e.g. ~640×480) so preview cards get breathing room. Theme picker's 1180×780 is reasonable as-is; keep it but make sure the new shared modal-sheet wrapper doesn't fight its internal card-based layout (it already uses radius/border styling closer to what's being standardized in §4, so less content-level rework is needed there than elsewhere — the fix is almost entirely "add the missing entrance/exit animation").

## 5. Per-surface plan

For each surface: current problem → target behavior. Assume all use the shared `PopupSurface`/modal-sheet components from §4 for their open/close animation unless noted; this section is about *content layout* refinement, not re-litigating the animation (already covered).

- **Clipboard**: migrate off manual `PanelWindow` x/y to the shared anchored shell. Layout otherwise fine (search field + list) — convert the plain `Column` to `ColumnLayout` for consistency, no major restructuring needed. Reuse the shared danger-color for any "clear/delete entry" affordance if one exists or is added.
- **Bluetooth / Network**: fine content-wise; adopt shared shell, convert to `ColumnLayout`/`RowLayout`. Consider adding a subtle connecting/scanning state animation (pulsing icon or spinner) using the `fast` duration curve if one doesn't already exist, since these are the two popups most likely to have "loading" states (device scan, connecting).
- **Resources**: adopt shared shell. The per-row `Behavior on width` (180ms OutCubic) for progress bars should be updated to the new `normal` duration + `standard` curve to match the rest of the system rather than being its own one-off value.
- **Media popup**: keep `MediaPopupContent.qml`'s `ColumnLayout`/`RowLayout` structure (already the most "modern" of the bunch) and the `ExternalCava` visualizer. Fix the fixed `anchor.rect.x = 520` hardcoded offset — anchor it relative to the triggering `NowPlaying` bar island like the other corner popups instead of a magic pixel constant, so it stays correctly positioned if the bar layout ever changes.
- **Clock popup**: currently a fixed 980×432 two-pane (calendar + weather) block — the densest "quick" popup. Keep the two-pane idea (it's a reasonable layout) but let each pane's height be content-driven with a shared max rather than one hardcoded 432px total, so it doesn't waste vertical space on lighter weather states and doesn't clip on heavier calendar states. Apply the same shoulder/bridge-to-bar treatment as the other corner popups (it already spans full bar width, keep that but connect it through the shared shell rather than its own bespoke shoulder code).
- **Power popup**: switch from its bespoke opacity+scale Behavior to the shared modal-sheet component (scrim + grow) so it matches theme picker/animation picker/launcher exactly instead of being a fourth slightly-different pattern. Layout (440×112, 4 action buttons) is fine as-is; give each `PowerActionButton` a hover/press state (currently likely just keyboard-navigable with focus ring, confirm and add mouse hover feedback using the `fast` curve if missing).
- **Launcher**: migrate the `Translate`-driven bottom-sheet slide (and its two sequencing `Timer`s) onto the shared modal-sheet component's grow/slide animation — this should let you delete `launcherPopupOpenTimer`/`launcherPopupResetTimer` entirely if the shared component's Loader-lifecycle management (see caelestia's `Wrapper.qml` pattern: a `Timer` unloads inactive content after the close animation finishes, and reloads/activates before the open animation starts) replaces the ad-hoc timer choreography. Fixed 720×430 is limiting for the AI chat/file-browser/calculator tabs — consider a taller resting height (e.g. up to ~560-600px) with the existing `maxHeight`-style clamp against screen bounds (borrow the clamping idea from caelestia's launcher `Wrapper.qml`, which computes `maxHeight` from screen size minus border/dashboard reservations) so tabs with more content (file browser listing, long chat) aren't cramped, while short ones (calculator) don't force full height — i.e. make it `contentSized` per-tab rather than one fixed rect for all tabs, if feasible without deep restructuring of `AppLauncherPopup.qml`'s internal tab-switch logic. If that's too invasive for this pass, at minimum increase the fixed height modestly and note the content-sized version as a follow-up.
- **Tray menu**: already closest to "correct" (content-height-scaled duration, OutBack close). Bring it *in line* with the new shared curve/duration scale (§3) rather than deleting its per-content-height duration scaling — that scaling idea is good and worth generalizing into `PopupSurface` itself (duration proportional to distance traveled is a nice touch, consider lifting it into the shared component as an option).
- **QuickLock**: give the whole lock surface a real entrance (fade+slight scale-up, `large` duration, `standard`/no-bounce curve — a lock screen appearing should feel solid/secure, not springy) and exit (fade out, faster). Add a `Behavior on opacity` to the auth-failure status text (currently an instant snap) using the `fast` curve so error feedback doesn't feel jarringly abrupt compared to the already-smooth per-keystroke pulse effect right above it. Keep all existing PAM/typing-feedback logic untouched.
- **Bar / TopBarReplica**: give every icon button (`TopBarNetworkButton`, `TopBarResourceBars`, `clockIsland`, `launcherButton`, `powerButton`, tray icons) a real hover state — background tint fading in/out with the `fast` curve (borrow the `StateLayer`-style ripple-on-press + hover-tint idea from caelestia's `StateLayer.qml`: a semi-transparent overlay rect whose opacity steps between 0 → hover-alpha → press-alpha, plus an expanding ripple circle from the click point on press). This single component, if built once, can be dropped into every clickable bar element and every popup's clickable rows (list items, device rows, buttons) for one consistent press/hover feel project-wide — treat building this as a prerequisite deliverable, not a per-surface afterthought. Add `Behavior on color` (fast/standard curve) to `NiriTaskbar`'s focused/hover color swap (currently an instant snap) and `Behavior on implicitWidth` (normal curve) to `NowPlaying`'s pill resize when media starts/stops. De-duplicate `TopBarReplica.qml` against the primary bar's inline markup by extracting a single parameterized `Bar` component both the primary `barWindow` and secondary-screen replicas instantiate, so future changes don't need to be made twice (and today's drift — missing tray icon normalization/right-click menu on secondary screens — gets fixed as a side effect).

## 6. Shared component checklist (build once, reuse everywhere)

1. **Motion primitives** (§3): curve constants + duration constants, either as plain QML property groups in a small file or inline conventions documented at the top of `shell.qml` if you decide against a new file. Prefer a new small file (e.g. `Motion.qml` as a QtObject singleton-ish helper, or just plain `Behavior`-returning components like caelestia's `Anim.qml`/`CAnim.qml`) since duplicating bezier arrays or OutBack tuples by hand in 10+ places is exactly the problem being fixed.
2. **`PopupSurface`** (§4): bar-anchored corner popup shell (clipboard, bluetooth, network, resources, media, clock, tray menu).
3. **Modal sheet wrapper** (§4.2): full-screen scrim + centered/bottom-pinned sheet shell (power, launcher, theme picker, animation picker).
4. **Hover/press state layer** (§5, bar section): reusable ripple+hover-tint `MouseArea`-based component for every clickable surface in the bar and inside popups.
5. **Shared `root.danger`/`root.error` color property**, replacing the 7 hardcoded `#d95c5c` occurrences, and folding in `AnimationPickerPopup.qml`'s two hardcoded speed-tier colors as named properties too if they should stay independent of the danger color.

Building these five things first, then migrating each popup onto them one at a time, is the natural execution order — see §7.

## 7. Suggested execution order

1. Land the motion primitives (§3/§6.1) and the shared danger-color property (§6.5) — pure additions, zero visual change yet, low risk.
2. Build `PopupSurface` (§6.2) and migrate the six "quick" popups (clipboard, bluetooth, network, resources, media, clock) one at a time, verifying each still opens/closes/positions correctly against its bar trigger before moving to the next. This is where the biggest line-count reduction happens (removes ~5 duplicated copies of the openProgress/shoulder-bridge block).
3. Migrate the tray menu onto `PopupSurface`, generalizing its content-height-scaled duration into an optional feature of the shared component if you choose to keep that behavior (recommended).
4. Build the modal-sheet wrapper (§6.3) and migrate power, then theme picker, then animation picker (these two are the highest-value fix since they currently have *no* animation at all), then the launcher last (it's the most structurally different today — Translate-based sheet + two Timers — so save it for when the shared component's behavior is well-proven on the simpler cases).
5. Build the hover/press state layer (§6.4) and roll it out across the bar (`TopBarNetworkButton`, `TopBarResourceBars`, `clockIsland`, `launcherButton`, `powerButton`, tray icons, `NiriTaskbar` pills) and then inside popup content (list rows, device rows, buttons) as a second pass.
6. Add the QuickLock entrance/exit animation and the missing `Behavior`s called out in §5 (auth-failure text, NowPlaying pill width).
7. De-duplicate `TopBarReplica.qml` against the primary bar into one parameterized `Bar` component.
8. Final pass: sweep for any remaining flat 90ms `NumberAnimation`s or `Easing.OutCubic`-with-no-overshoot Behaviors that were missed, and confirm every popup's open/close now goes through the shared components from §6 with no bespoke animation code left inline in `shell.qml`.

## 8. Verification

After each phase in §7, actually open every popup via its bar trigger (not just read the code) and check: (a) it grows from the correct anchor point without jumping/flickering, (b) content fades in slightly after the container per §3.3, (c) closing feels crisp/no lingering bounce, (d) the shoulder/bridge connector to the bar still looks seamless at the new corner-radius values, (e) popups still correctly close when another popup opens (mutual-exclusion logic in `shell.qml`'s `closeOtherPopups()` must keep working through the refactor), (f) secondary-monitor bar (`TopBarReplica`) still correctly forwards clicks to primary-screen popups after the de-duplication in step 7. Use the `verify` skill / manually launch quickshell (`qs -c main` or however this shell is normally launched — check for a launch script/systemd unit before assuming) and visually confirm rather than relying on qmllint alone, since this is fundamentally a motion/visual-feel rework that can't be validated by type-checking.
