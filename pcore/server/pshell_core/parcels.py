"""Parcels (docs/core.md "Watches"): which carrier a tracking number belongs
to, the public page a person would open, and the status in a few words.

- DHL: the JSON behind dhl.de's own tracking page (no key).
- DPD: its public tracking page (server-rendered HTML, read by keywords).
- UPS, GLS, Hermes and any other: only with a 17TRACK key of the member
  (17track.net, a few hundred numbers free once); without it the parcel is
  listed with its link but no status (their pages need a browser or a paid key).

Status: unknown (nothing known yet), info (announced), transit, pickup (waits
at a shop or a locker), out (out for delivery), delivered, problem, manual
(core cannot ask this carrier).
"""
import json
import re

CARRIERS = ("dhl", "dpd", "hermes", "gls", "ups", "other")
NAMES = {"dhl": "DHL", "dpd": "DPD", "hermes": "Hermes", "gls": "GLS", "ups": "UPS", "other": "Parcel"}
PAGES = {
    "dhl": "https://www.dhl.de/de/privatkunden/pakete-empfangen/verfolgen.html?piececode={n}",
    "dpd": "https://tracking.dpd.de/status/de_DE/parcel/{n}",
    "hermes": "https://www.myhermes.de/empfangen/sendungsverfolgung/sendungsinformation#{n}",
    "gls": "https://www.gls-pakete.de/sendungsverfolgung?trackingNumber={n}",
    "ups": "https://www.ups.com/track?loc=de_DE&tracknum={n}",
    "other": "https://t.17track.net/en#nums={n}",
}
STATES = ("unknown", "info", "transit", "pickup", "out", "delivered", "problem", "manual")
DONE = ("delivered",)
NUMBER = re.compile(r"^[A-Z0-9]{8,35}$")
TRACK17 = "https://api.17track.net/track/v2.4"
DHL_API = "https://www.dhl.de/int-verfolgen/data/search?piececode={n}&language=de"
DPD_PAGE = "https://tracking.dpd.de/status/de_DE/parcel/{n}"


def clean(number):
    return re.sub(r"[\s-]", "", str(number or "")).upper()


def guess(number, hint=""):
    """→ the carrier of a number; `hint` is text around it (the page's host, the shop's words)"""
    n = clean(number)
    hint = str(hint or "").lower()
    for carrier in ("dhl", "dpd", "hermes", "gls", "ups"):
        if re.search(rf"(^|[^a-z]){carrier}([^a-z]|$)", hint) or (carrier == "hermes" and "myhermes" in hint):
            if fits(carrier, n):
                return carrier
    if re.fullmatch(r"1Z[0-9A-Z]{16}", n):
        return "ups"
    if re.fullmatch(r"H\d{19}", n):
        return "hermes"
    if re.fullmatch(r"(JJD|JVGL)\d{10,22}|00340\d{15}|\d{20}|[A-Z]{2}\d{9}DE", n):
        return "dhl"
    if re.fullmatch(r"\d{14}", n):
        return "dpd"
    if re.fullmatch(r"\d{12}", n):
        return "dhl"
    if re.fullmatch(r"\d{11}", n):
        return "gls"
    return "other"


def fits(carrier, n):
    return {
        "ups": lambda: bool(re.fullmatch(r"1Z[0-9A-Z]{16}", n)),
        "hermes": lambda: bool(re.fullmatch(r"H\d{19}|\d{14}|\d{16}", n)),
        "dhl": lambda: bool(re.fullmatch(r"(JJD|JVGL)\d{10,22}|\d{12}|\d{20}|00340\d{15}|[A-Z]{2}\d{9}DE", n)),
        "dpd": lambda: bool(re.fullmatch(r"\d{14}|0\d{13}", n)),
        "gls": lambda: bool(re.fullmatch(r"\d{11,12}|[A-Z0-9]{8}", n)),
    }.get(carrier, lambda: True)()


def page(carrier, number):
    return PAGES.get(carrier, PAGES["other"]).format(n=clean(number))


# the words of tracking pages, German and English, most telling first
WORDS = [
    ("info", r"noch nicht (an uns |an \w+ )?übergeben|not yet (been )?(handed|received)"),
    ("delivered", r"\bzugestellt\b(?!.{0,20}(versuch|nicht))|wurde zugestellt|erfolgreich zugestellt|ausgeliefert|\bdelivered\b"),
    ("problem", r"nicht zugestellt|zustellversuch|rücksendung|ruecksendung|retoure|not delivered|delivery attempt|exception|beschädigt"),
    ("pickup", r"abholbereit|zur abholung|liegt .{0,40}(filiale|paketshop|packstation|station)|ready for pick ?up|available for pick ?up"),
    ("out", r"in zustellung|zustellfahrzeug|wird heute zugestellt|heute zugestellt|out for delivery|on vehicle for delivery"),
    ("transit", r"paketzentrum|depot|unterwegs|in transit|bearbeitet|sortier|abgeholt|picked up|übergeben|ubergeben|on the way"),
    ("info", r"elektronisch angekündigt|daten .{0,30}übermittelt|angekündigt|label created|shipment information received|auftragsdaten"),
    ("unknown", r"keine daten|nicht finden|nicht gefunden|no data|not found|keine informationen"),
]


# the common stages every carrier's status maps onto (the shell draws them as a track)
STAGES = ("announced", "handed", "transit", "depot", "out", "delivered")
HANDED = r"übergeben|ubergeben|eingeliefert|abgeholt|übernommen|angenommen|picked up|received by|drop.?off|eingeliefert"
HUB = r"paketzentrum|hub|sortier|in transit|unterwegs|transport|export|import|zoll|customs|weitergeleitet|departed|arrived at (the )?(sort|hub|facility)"
DEPOT = r"zustellbasis|zustelldepot|zielpaketzentrum|ziel-paketzentrum|depot|delivery (station|facility|depot|center|centre)|lokal|local (facility|depot)|nächsten werktag zugestellt"


def stage_of(state, texts=(), was=None):
    """→ 0…5 (STAGES), or None while nothing is known; a problem keeps the stage it had"""
    if state == "delivered":
        return 5
    if state in ("out", "pickup"):
        return 4
    if state in ("problem", "manual"):
        return was
    if state in ("unknown",):
        return was
    if state == "info":
        return 0
    low = " ".join(str(t or "") for t in texts).lower()
    first = str(texts[0] if texts else "").lower()
    if re.search(DEPOT, first):
        return 3
    if re.search(HUB, first):
        return max(2, was or 0) if was != 3 else 3
    if re.search(HANDED, low):
        return max(1, was or 0) if not re.search(HUB, low) else max(2, was or 0)
    return max(2, was or 0)


def state_of(text):
    low = str(text or "").lower()
    for state, pattern in WORDS:
        if re.search(pattern, low):
            return state
    return "unknown"


def dhl_result(data):
    shipment = (data.get("sendungen") or [{}])[0]
    details = shipment.get("sendungsdetails") or {}
    course = details.get("sendungsverlauf") or {}
    events = []
    for event in course.get("events") or []:
        if isinstance(event, dict):
            events.append({"at": str(event.get("datum") or ""), "text": str(event.get("status") or event.get("ruecksendung") or "")[:300],
                           "place": str(event.get("ort") or "")[:120]})
    text = str(course.get("aktuellerStatus") or course.get("kurzStatus") or (events[-1]["text"] if events else ""))[:300]
    progress = course.get("fortschritt") or 0
    if details.get("istZugestellt"):
        state = "delivered"
    elif shipment.get("sendungNichtGefunden") and not events:
        state = "unknown"
    else:
        state = state_of(text)
        if state == "unknown":
            state = {1: "info", 2: "transit", 3: "transit", 4: "out", 5: "delivered"}.get(int(progress or 0), "unknown")
    delivery = details.get("zustellung") or {}
    expected = str(delivery.get("zustellzeitfensterVon") or delivery.get("voraussichtlicheZustellung")
                   or details.get("voraussichtlicheZustellung") or "")[:40]
    out = {"state": state, "text": text, "events": events[-12:][::-1], "expected": expected}
    if state not in ("delivered", "out", "pickup", "problem", "unknown"):
        texts = [text] + [e["text"] for e in out["events"]]
        out["stage"] = stage_of(state, texts, {1: 0, 2: 1, 3: 2}.get(int(progress or 0)))
    return out


def dpd_result(page_html):
    from .htmlsel import parse
    root = parse(page_html)
    main = None
    for node in root.walk():
        if node.attrs.get("id", "").startswith("ContentPlaceHolder1") and node.tag in ("div", "section", "form"):
            main = node
            break
    text = (main or root).inner_text(20000)
    state = state_of(text)
    sentence = ""
    for state_name, pattern in WORDS:
        if state_name != state:
            continue
        m = re.search(r"[^.!?\n]{0,80}(" + pattern + r")[^.!?\n]{0,80}", text, re.I)
        if m:
            sentence = m.group(0).strip()
        break
    return {"state": state, "text": sentence[:300], "events": [], "expected": ""}


TRACK17_STATES = {"NotFound": "unknown", "InfoReceived": "info", "InTransit": "transit", "Expired": "problem",
                  "AvailableForPickup": "pickup", "OutForDelivery": "out", "DeliveryFailure": "problem",
                  "Delivered": "delivered", "Exception": "problem"}


def track17_result(item):
    info = item.get("track_info") or {}
    latest = (info.get("latest_status") or {}).get("status") or "NotFound"
    event = info.get("latest_event") or {}
    events = []
    for provider in (info.get("tracking") or {}).get("providers") or []:
        for e in provider.get("events") or []:
            events.append({"at": str(e.get("time_iso") or ""), "text": str(e.get("description") or "")[:300],
                           "place": str(e.get("location") or "")[:120]})
    expected = ((info.get("time_metrics") or {}).get("estimated_delivery_date") or {}).get("from") or ""
    out = {"state": TRACK17_STATES.get(latest, "unknown"), "text": str(event.get("description") or latest)[:300],
           "events": events[:12], "expected": str(expected)[:40]}
    sub = str((info.get("latest_status") or {}).get("sub_status") or "")
    if sub == "InTransit_PickedUp":
        out["stage"] = 1
    elif sub == "InTransit_Arrival":
        out["stage"] = 3
    return out


async def track(fetch_json, fetch_text, carrier, number, track17_key="", registered=False):
    """→ {state, text, events, expected, registered?}; raises on a network error.
    fetch_json(method, url, headers, body) / fetch_text(url) are core's fetchers."""
    n = clean(number)
    if carrier == "dhl":
        data = await fetch_json("GET", DHL_API.format(n=n), {}, None)
        return dhl_result(data)
    if carrier == "dpd":
        return dpd_result(await fetch_text(DPD_PAGE.format(n=n)))
    if not track17_key:
        return {"state": "manual", "text": "", "events": [], "expected": ""}
    headers = {"17token": track17_key, "Content-Type": "application/json"}
    if not registered:
        data = await fetch_json("POST", f"{TRACK17}/register", headers, [{"number": n}])
        rejected = ((data or {}).get("data") or {}).get("rejected") or []
        if rejected and (rejected[0].get("error") or {}).get("code") != -18019901:
            raise RuntimeError(str((rejected[0].get("error") or {}).get("message") or "17TRACK refused the number"))
    data = await fetch_json("POST", f"{TRACK17}/gettrackinfo", headers, [{"number": n}])
    accepted = ((data or {}).get("data") or {}).get("accepted") or []
    if not accepted:
        rejected = ((data or {}).get("data") or {}).get("rejected") or [{}]
        raise RuntimeError(str((rejected[0].get("error") or {}).get("message") or "17TRACK has nothing"))
    out = track17_result(accepted[0])
    out["registered"] = True
    return out


def parse_json(text):
    return json.loads(text)
