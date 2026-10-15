"""Turns presses and movement of the diverted controls into what the rules
say: a click, a double click, holding, a swipe while held (up, down, left,
right), the wheel or the thumb wheel turned while held, the thumb wheel
alone.

A rule is
    {id, control, trigger, app: "" | app id, mods: [ctrl, shift, alt, super],
     action: {...}, feel: "" | waveform, repeat: bool, on: bool}
and the most specific one wins for each trigger: one for the app and the
held modifiers before one for the app before one for the modifiers before
one for everywhere.

Everything runs on the daemon's one worker thread; `schedule(delay, fn)`
comes from there. Nothing here talks to the device or the desktop itself:
`fire(rule, control, trigger, phase)` does (phase "tap", or "start"/"end" for
an action that lasts while the button is down) and `native(control, phase)`
what the control does on its own.
"""

import math

CONTROLS = {0x52: "middle", 0x53: "back", 0x56: "forward", 0xC3: "gesture", 0xC4: "shift", 0x1A0: "haptic"}
CIDS = {name: cid for cid, name in CONTROLS.items()}

SWIPES = ("up", "down", "left", "right")
CHORDS = ("wheel-up", "wheel-down", "thumb-left", "thumb-right")
TRIGGERS = ("click", "double", "hold") + SWIPES + CHORDS
# the thumb wheel on its own
THUMB_TRIGGERS = ("left", "right")

# actions that last as long as the button is held
LASTING = {("mouse", "dpi-shift")}


def lasting(action):
    if not action:
        return False
    kind = action.get("kind")
    if kind == "keys" and action.get("sustain"):
        return True
    if kind == "button" and action.get("sustain", True):
        return True
    return (kind, action.get("op")) in LASTING


class Held:
    def __init__(self, control, now, rules):
        self.control = control
        self.t0 = now
        self.rules = rules
        self.dx = 0.0
        self.dy = 0.0
        self.travel = 0.0
        self.swiped = False  # a swipe or a chord fired: no click on release
        self.held = None  # the hold rule that fired
        self.passing = False  # the press went straight through (native or sustained)
        self.done_swipe = False
        self.wheel = 0.0
        self.thumb = 0.0
        self.token = 0


class Engine:
    def __init__(self, fire, native, schedule, live=None):
        self.fire_cb = fire
        self.native_cb = native
        self.schedule = schedule
        self.live = live or (lambda *a, **k: None)
        self.rules = []
        self.options = {}
        self.app = ""
        self.mods = set()
        self.held = {}
        self.order = []  # held controls, the last pressed last
        self.pending = None  # (control, rules, token) waiting for a second click
        self.token = 0
        self.thumb_acc = 0.0

    # ── setup ───────────────────────────────────────────────────────────
    def configure(self, rules, options):
        self.rules = [r for r in rules or [] if r.get("on", True) and r.get("control") and r.get("trigger")]
        self.options = options or {}

    @property
    def hold_ms(self):
        return float(self.options.get("holdMs", 420))

    @property
    def double_ms(self):
        return float(self.options.get("doubleMs", 260))

    @property
    def swipe_distance(self):
        return float(self.options.get("swipeDistance", 70))

    @property
    def thumb_step(self):
        return float(self.options.get("thumbStep", 18))

    def wants(self):
        """What the device must report: {control: {divert, rawxy}}, thumb, chord wheel."""
        out = {}
        thumb = False
        for rule in self.rules:
            control, trigger = rule["control"], rule["trigger"]
            if control == "thumb":
                thumb = True
                continue
            if control not in CIDS:
                continue
            need = out.setdefault(control, {"divert": True, "rawxy": False})
            if trigger in SWIPES:
                need["rawxy"] = True
            if trigger in ("thumb-left", "thumb-right"):
                thumb = True
        return out, thumb

    def needs_wheel(self, control):
        return any(r["control"] == control and r["trigger"] in ("wheel-up", "wheel-down") for r in self.rules)

    # ── rules ───────────────────────────────────────────────────────────
    def resolve(self, control):
        """trigger -> the rule that applies now."""
        best = {}
        app = (self.app or "").lower()
        for rule in self.rules:
            if rule["control"] != control:
                continue
            rule_app = str(rule.get("app") or "").lower()
            if rule_app and rule_app != app:
                continue
            mods = set(rule.get("mods") or [])
            if mods and not mods <= self.mods:
                continue
            if not mods and rule.get("exactMods") and self.mods:
                continue
            score = (2 if rule_app else 0) + (1 if mods else 0) + len(mods) * 0.01
            trigger = rule["trigger"]
            if trigger not in best or score > best[trigger][0]:
                best[trigger] = (score, rule)
        return {trigger: rule for trigger, (score, rule) in best.items()}

    def _fire(self, rule, control, trigger, phase="tap"):
        action = rule.get("action") or {"kind": "default"}
        if action.get("kind") == "default":
            self.native_cb(control, phase if phase != "tap" else "tap")
        elif action.get("kind") != "none":
            self.fire_cb(rule, control, trigger, phase)
        if phase in ("tap", "start"):
            self.live("fired", rule=rule.get("id", ""), control=control, trigger=trigger)

    # ── presses ─────────────────────────────────────────────────────────
    def down(self, control, now):
        rules = self.resolve(control)
        pending = self.pending
        if pending and pending[0] == control and "double" in pending[1]:
            self.pending = None
            state = Held(control, now, rules)
            state.swiped = True  # the second press is the double click, its release nothing
            self.held[control] = state
            self.order.append(control)
            self._fire(pending[1]["double"], control, "double")
            return
        if pending:
            self._flush_pending()

        state = Held(control, now, rules)
        self.held[control] = state
        self.order.append(control)
        self.token += 1
        state.token = self.token

        others = set(rules) - {"click"}
        click = rules.get("click")
        if not others:
            # nothing to wait for: the press goes through as it happens
            if click is None or (click.get("action") or {}).get("kind") == "default":
                if self.native_cb(control, "start"):
                    state.passing = True
                    return
                state.passing = False
                return
            if lasting(click.get("action")):
                state.passing = True
                self._fire(click, control, "click", "start")
                return
        if "hold" in rules:
            token = state.token
            self.schedule(self.hold_ms / 1000.0, lambda: self._hold(control, token))

    def _hold(self, control, token):
        state = self.held.get(control)
        if not state or state.token != token or state.swiped or state.travel > self.swipe_distance * 0.35:
            return
        rule = state.rules.get("hold")
        if not rule:
            return
        state.held = rule
        if lasting(rule.get("action")):
            self._fire(rule, control, "hold", "start")
        else:
            self._fire(rule, control, "hold")

    def up(self, control, now):
        state = self.held.pop(control, None)
        if control in self.order:
            self.order.remove(control)
        if state is None:
            return
        if state.passing:
            click = state.rules.get("click")
            if click and (click.get("action") or {}).get("kind") != "default":
                self._fire(click, control, "click", "end")
            else:
                self.native_cb(control, "end")
            return
        if state.held:
            if lasting(state.held.get("action")):
                self._fire(state.held, control, "hold", "end")
            return
        if state.swiped or state.travel > self.swipe_distance:
            return
        if "double" in state.rules:
            self.token += 1
            token = self.token
            self.pending = (control, state.rules, token)
            self.schedule(self.double_ms / 1000.0, lambda: self._expire_pending(token))
            return
        self._click(control, state.rules)

    def _click(self, control, rules):
        click = rules.get("click")
        if click is None:
            self.native_cb(control, "tap")
        else:
            self._fire(click, control, "click")

    def _expire_pending(self, token):
        if self.pending and self.pending[2] == token:
            self._flush_pending()

    def _flush_pending(self):
        control, rules, _token = self.pending
        self.pending = None
        self._click(control, rules)

    def release_all(self):
        for control in list(self.held):
            self.up(control, 0)
        self.pending = None

    # ── movement ────────────────────────────────────────────────────────
    def top(self):
        return self.held[self.order[-1]] if self.order else None

    def move(self, dx, dy):
        state = self.top()
        if state is None:
            return
        state.dx += dx
        state.dy += dy
        state.travel = max(state.travel, math.hypot(state.dx, state.dy))
        self.live("move", control=state.control, dx=state.dx, dy=state.dy)
        if state.done_swipe or state.held:
            return
        distance = self.swipe_distance
        if abs(state.dx) < distance and abs(state.dy) < distance:
            return
        if abs(state.dx) >= abs(state.dy):
            direction = "right" if state.dx > 0 else "left"
        else:
            direction = "down" if state.dy > 0 else "up"
        rule = state.rules.get(direction)
        if rule is None:
            # moved too far for a click, but there is nothing to swipe to
            state.swiped = True
            return
        state.swiped = True
        self._fire(rule, state.control, direction)
        if rule.get("repeat"):
            state.dx = 0.0
            state.dy = 0.0
        else:
            state.done_swipe = True

    def wheel(self, delta, notch=1.0):
        """The main wheel while it is diverted (a chord is held)."""
        state = self.top()
        if state is None:
            return False
        state.wheel += delta
        fired = False
        while abs(state.wheel) >= notch:
            trigger = "wheel-up" if state.wheel > 0 else "wheel-down"
            state.wheel -= notch if state.wheel > 0 else -notch
            rule = state.rules.get(trigger)
            if rule:
                state.swiped = True
                self._fire(rule, state.control, trigger)
                fired = True
        return fired

    def thumb(self, delta):
        """The thumb wheel (diverted). True when a rule took it; otherwise
        the caller scrolls sideways as the wheel would on its own."""
        state = self.top()
        step = self.thumb_step
        if state is not None and any(t in state.rules for t in ("thumb-left", "thumb-right")):
            state.thumb += delta
            while abs(state.thumb) >= step:
                trigger = "thumb-right" if state.thumb > 0 else "thumb-left"
                state.thumb -= step if state.thumb > 0 else -step
                rule = state.rules.get(trigger)
                if rule:
                    state.swiped = True
                    self._fire(rule, state.control, trigger)
            return True
        rules = self.resolve("thumb")
        if ("right" if delta > 0 else "left") not in rules:
            self.thumb_acc = 0.0
            return False
        self.thumb_acc += delta
        while abs(self.thumb_acc) >= step:
            trigger = "right" if self.thumb_acc > 0 else "left"
            self.thumb_acc -= step if self.thumb_acc > 0 else -step
            rule = rules.get(trigger)
            if rule:
                self._fire(rule, "thumb", trigger)
        return True

    def thumb_stop(self):
        self.thumb_acc = 0.0
