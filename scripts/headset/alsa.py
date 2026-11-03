"""The headset's mixer through libasound's control interface (ctypes; no
alsa-utils needed): the elements by name, their values in steps and dB,
writes, and a file descriptor that becomes readable when any of them
changes (PipeWire setting the volume, another mixer, a write of ours)."""

import ctypes
import ctypes.util
import os

_lib = None
P = ctypes.c_void_p


def lib():
    global _lib
    if _lib is not None:
        return _lib
    l = ctypes.CDLL(ctypes.util.find_library("asound") or "libasound.so.2")
    for name, args, res in [
        ("snd_ctl_open", [ctypes.POINTER(P), ctypes.c_char_p, ctypes.c_int], ctypes.c_int),
        ("snd_ctl_close", [P], ctypes.c_int),
        ("snd_ctl_nonblock", [P, ctypes.c_int], ctypes.c_int),
        ("snd_ctl_subscribe_events", [P, ctypes.c_int], ctypes.c_int),
        ("snd_ctl_poll_descriptors_count", [P], ctypes.c_int),
        ("snd_ctl_poll_descriptors", [P, P, ctypes.c_uint], ctypes.c_int),
        ("snd_ctl_read", [P, P], ctypes.c_int),
        ("snd_ctl_event_malloc", [ctypes.POINTER(P)], ctypes.c_int),
        ("snd_ctl_event_free", [P], None),
        ("snd_ctl_elem_list_malloc", [ctypes.POINTER(P)], ctypes.c_int),
        ("snd_ctl_elem_list_free", [P], None),
        ("snd_ctl_elem_list", [P, P], ctypes.c_int),
        ("snd_ctl_elem_list_alloc_space", [P, ctypes.c_uint], ctypes.c_int),
        ("snd_ctl_elem_list_free_space", [P], None),
        ("snd_ctl_elem_list_get_count", [P], ctypes.c_uint),
        ("snd_ctl_elem_list_get_used", [P], ctypes.c_uint),
        ("snd_ctl_elem_list_get_numid", [P, ctypes.c_uint], ctypes.c_uint),
        ("snd_ctl_elem_list_get_name", [P, ctypes.c_uint], ctypes.c_char_p),
        ("snd_ctl_elem_info_malloc", [ctypes.POINTER(P)], ctypes.c_int),
        ("snd_ctl_elem_info_free", [P], None),
        ("snd_ctl_elem_info_set_numid", [P, ctypes.c_uint], None),
        ("snd_ctl_elem_info", [P, P], ctypes.c_int),
        ("snd_ctl_elem_info_get_type", [P], ctypes.c_int),
        ("snd_ctl_elem_info_get_count", [P], ctypes.c_uint),
        ("snd_ctl_elem_info_get_min", [P], ctypes.c_long),
        ("snd_ctl_elem_info_get_max", [P], ctypes.c_long),
        ("snd_ctl_elem_info_get_id", [P, P], None),
        ("snd_ctl_elem_id_malloc", [ctypes.POINTER(P)], ctypes.c_int),
        ("snd_ctl_elem_id_free", [P], None),
        ("snd_ctl_elem_value_malloc", [ctypes.POINTER(P)], ctypes.c_int),
        ("snd_ctl_elem_value_free", [P], None),
        ("snd_ctl_elem_value_set_numid", [P, ctypes.c_uint], None),
        ("snd_ctl_elem_read", [P, P], ctypes.c_int),
        ("snd_ctl_elem_write", [P, P], ctypes.c_int),
        ("snd_ctl_elem_value_get_integer", [P, ctypes.c_uint], ctypes.c_long),
        ("snd_ctl_elem_value_set_integer", [P, ctypes.c_uint, ctypes.c_long], None),
        ("snd_ctl_elem_value_get_boolean", [P, ctypes.c_uint], ctypes.c_int),
        ("snd_ctl_elem_value_set_boolean", [P, ctypes.c_uint, ctypes.c_long], None),
        ("snd_ctl_convert_to_dB", [P, P, ctypes.c_long, ctypes.POINTER(ctypes.c_long)], ctypes.c_int),
    ]:
        f = getattr(l, name)
        f.argtypes = args
        f.restype = res
    _lib = l
    return l


BOOLEAN, INTEGER = 1, 2


class Gone(Exception):
    """The card is not there (any more)."""


def find_card(vendor, product):
    """The ALSA card number of a USB device, or None."""
    want = f"{vendor:04x}:{product:04x}"
    try:
        names = os.listdir("/proc/asound")
    except OSError:
        return None
    for name in names:
        if not name.startswith("card") or not name[4:].isdigit():
            continue
        try:
            with open(f"/proc/asound/{name}/usbid") as f:
                if f.read().strip().lower() == want:
                    return int(name[4:])
        except OSError:
            continue
    return None


class Mixer:
    def __init__(self, card):
        l = lib()
        self.card = card
        self.ctl = P()
        if l.snd_ctl_open(ctypes.byref(self.ctl), f"hw:{card}".encode(), 0) < 0:
            raise Gone(f"hw:{card}")
        self.info = P()
        self.value = P()
        self.eid = P()
        self.event = P()
        l.snd_ctl_elem_info_malloc(ctypes.byref(self.info))
        l.snd_ctl_elem_value_malloc(ctypes.byref(self.value))
        l.snd_ctl_elem_id_malloc(ctypes.byref(self.eid))
        l.snd_ctl_event_malloc(ctypes.byref(self.event))
        self.elements = {}  # name -> {numid, type, count, min, max}
        self._list()

    def _list(self):
        l = lib()
        lst = P()
        l.snd_ctl_elem_list_malloc(ctypes.byref(lst))
        try:
            if l.snd_ctl_elem_list(self.ctl, lst) < 0:
                raise Gone("list")
            n = l.snd_ctl_elem_list_get_count(lst)
            l.snd_ctl_elem_list_alloc_space(lst, n)
            l.snd_ctl_elem_list(self.ctl, lst)
            for i in range(l.snd_ctl_elem_list_get_used(lst)):
                numid = l.snd_ctl_elem_list_get_numid(lst, i)
                name = l.snd_ctl_elem_list_get_name(lst, i).decode()
                l.snd_ctl_elem_info_set_numid(self.info, numid)
                if l.snd_ctl_elem_info(self.ctl, self.info) < 0:
                    continue
                kind = l.snd_ctl_elem_info_get_type(self.info)
                if kind not in (BOOLEAN, INTEGER):
                    continue
                self.elements[name] = {
                    "numid": numid, "type": kind, "count": l.snd_ctl_elem_info_get_count(self.info),
                    "min": l.snd_ctl_elem_info_get_min(self.info) if kind == INTEGER else 0,
                    "max": l.snd_ctl_elem_info_get_max(self.info) if kind == INTEGER else 1,
                }
            l.snd_ctl_elem_list_free_space(lst)
        finally:
            l.snd_ctl_elem_list_free(lst)

    def close(self):
        l = lib()
        if self.ctl:
            l.snd_ctl_close(self.ctl)
            self.ctl = None
        for ptr, free in ((self.info, l.snd_ctl_elem_info_free), (self.value, l.snd_ctl_elem_value_free),
                          (self.eid, l.snd_ctl_elem_id_free), (self.event, l.snd_ctl_event_free)):
            if ptr:
                free(ptr)
        self.info = self.value = self.eid = self.event = None

    def has(self, name):
        return name in self.elements

    def get(self, name):
        """The values of an element (a list: one per channel)."""
        l = lib()
        e = self.elements[name]
        l.snd_ctl_elem_value_set_numid(self.value, e["numid"])
        if l.snd_ctl_elem_read(self.ctl, self.value) < 0:
            raise Gone(name)
        if e["type"] == BOOLEAN:
            return [bool(l.snd_ctl_elem_value_get_boolean(self.value, k)) for k in range(e["count"])]
        return [int(l.snd_ctl_elem_value_get_integer(self.value, k)) for k in range(e["count"])]

    def set(self, name, values):
        """Writes an element; a single value goes to every channel."""
        l = lib()
        e = self.elements[name]
        if not isinstance(values, (list, tuple)):
            values = [values] * e["count"]
        l.snd_ctl_elem_value_set_numid(self.value, e["numid"])
        for k in range(e["count"]):
            v = values[min(k, len(values) - 1)]
            if e["type"] == BOOLEAN:
                l.snd_ctl_elem_value_set_boolean(self.value, k, 1 if v else 0)
            else:
                l.snd_ctl_elem_value_set_integer(self.value, k, max(e["min"], min(e["max"], int(v))))
        if l.snd_ctl_elem_write(self.ctl, self.value) < 0:
            raise Gone(name)

    def db(self, name, step):
        """A step of an integer element in dB (None without a dB scale)."""
        l = lib()
        e = self.elements[name]
        l.snd_ctl_elem_info_set_numid(self.info, e["numid"])
        l.snd_ctl_elem_info(self.ctl, self.info)
        l.snd_ctl_elem_info_get_id(self.info, self.eid)
        out = ctypes.c_long()
        if l.snd_ctl_convert_to_dB(self.ctl, self.eid, int(step), ctypes.byref(out)) < 0:
            return None
        return out.value / 100.0

    def scale(self, name):
        """[min, max, dB at min, dB at max] of an integer element."""
        e = self.elements[name]
        return [e["min"], e["max"], self.db(name, e["min"]), self.db(name, e["max"])]

    # ── changes ─────────────────────────────────────────────────────────
    def watch_fd(self):
        """A file descriptor that turns readable on any change (then drain())."""
        l = lib()
        l.snd_ctl_nonblock(self.ctl, 1)
        l.snd_ctl_subscribe_events(self.ctl, 1)
        n = l.snd_ctl_poll_descriptors_count(self.ctl)
        fds = (ctypes.c_ubyte * (8 * max(1, n)))()  # struct pollfd {int fd; short events, revents;}
        l.snd_ctl_poll_descriptors(self.ctl, ctypes.cast(fds, P), n)
        return int.from_bytes(bytes(fds[0:4]), "little", signed=True)

    def drain(self):
        """Reads the pending change events; False when the card went away."""
        l = lib()
        while True:
            r = l.snd_ctl_read(self.ctl, self.event)
            if r == 0 or r == -11:  # nothing more (EAGAIN)
                return True
            if r < 0:
                return False
