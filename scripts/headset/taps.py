"""Press, double press and hold of the headset's buttons.

The inline remote sends every press as a press and a release 1 ms apart –
also while a button is held: the firmware repeats it 320–400 ms after the
first and then every 100 ms. So a key going up says nothing; what counts is when
the next press comes:

    a second press, then nothing for REPEAT   a double press
    a third press within REPEAT of the second held (the firmware's repeats)
    nothing for QUIET after a press           the presses are over

The firmware's first repeat comes 320–400 ms after the press – as soon as a
quick second tap would –, so only the third press tells the two apart.

`Taps` turns the raw presses of one button into calls of its owner. At the
first press of a burst it asks `owner.waits()`: whether a double press or a
hold is asked for at all.

    waits() False:   tap() at once, repeat() for every further press of the
                     burst (held, or tapped again quickly)
    waits() True:    tap()            one press, over
                     double()         two presses
                     hold_start()     held (from the third press, ~500 ms)
                     repeat()         another firmware repeat while held
                     hold_end()       let go after holding
"""

REPEAT = 0.16  # repeats come every 0.1 s
QUIET = 0.45  # the first repeat comes at most 0.4 s after the press


class Taps:
    def __init__(self, owner, schedule):
        self.owner = owner
        self.schedule = schedule  # schedule(delay_s, fn)
        self.presses = []  # times of this burst's presses
        self.holding = False
        self.fast = None  # None: no burst; True / False: this burst's mode
        self.token = 0

    def press(self, now):
        self.token += 1
        token = self.token
        if self.fast is None:
            self.fast = not self.owner.waits()
            self.presses = [now]
            if self.fast:
                self.owner.tap()
            self.schedule(QUIET + 0.01, lambda: self._quiet(token))
            return
        if self.fast:
            self.presses.append(now)
            self.owner.repeat()
            self.schedule(QUIET + 0.01, lambda: self._quiet(token))
            return
        p = self.presses
        if self.holding:
            p.append(now)
            self.owner.repeat()
        elif len(p) == 1:
            # a second tap – or the firmware's first repeat: the next tells
            p.append(now)
        else:
            # a third press this soon (_quiet would have ended it): held
            p.append(now)
            self.holding = True
            self.owner.hold_start()
        wait = REPEAT if len(p) > 1 else QUIET
        self.schedule(wait + 0.01, lambda: self._quiet(token))

    def release(self, now):
        pass  # the next press (or none) decides

    def _quiet(self, token):
        if token != self.token:
            return
        p, self.presses = self.presses, []
        fast, self.fast = self.fast, None
        if fast:
            return
        if self.holding:
            self.holding = False
            self.owner.hold_end()
        elif len(p) == 1:
            self.owner.tap()
        elif len(p) == 2:
            self.owner.double()

    def reset(self):
        self.token += 1
        if self.holding:
            self.holding = False
            self.owner.hold_end()
        self.presses = []
        self.fast = None
