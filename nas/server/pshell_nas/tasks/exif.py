"""When and where a photo was taken, and its size. The place is the
nearest geonames city with 1000+ people – offline, nothing leaves the house.
A photo without a date gets its file time, so it still sorts in."""
import datetime
import math

from . import models

_places = {}


def load_places(ctx):
    if "lat" in _places:
        return _places
    import numpy
    countries = {}
    try:
        with open(models.path(ctx, "countryInfo.txt"), encoding="utf-8") as file:
            for line in file:
                if not line.startswith("#"):
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) > 4:
                        countries[parts[0]] = parts[4]
    except Exception:  # noqa: BLE001 – the code alone will do
        pass
    names, codes, lats, lons = [], [], [], []
    with open(models.path(ctx, "cities1000.txt"), encoding="utf-8") as file:
        for line in file:
            parts = line.split("\t")
            if len(parts) < 9:
                continue
            names.append(parts[1])
            codes.append(parts[8])
            lats.append(float(parts[4]))
            lons.append(float(parts[5]))
    _places.update({"names": names, "codes": codes, "countries": countries,
                    "lat": numpy.radians(numpy.array(lats)), "lon": numpy.radians(numpy.array(lons))})
    return _places


def place_of(ctx, lat, lon):
    import numpy
    data = load_places(ctx)
    la, lo = math.radians(lat), math.radians(lon)
    # equirectangular distance is plenty to pick the nearest town
    x = (data["lon"] - lo) * numpy.cos((data["lat"] + la) / 2)
    y = data["lat"] - la
    index = int(numpy.argmin(x * x + y * y))
    code = data["codes"][index]
    return data["names"][index], data["countries"].get(code, code)


def ratio(value):
    try:
        return float(value)
    except (TypeError, ValueError, ZeroDivisionError):
        try:
            return value[0] / value[1]
        except (TypeError, IndexError, ZeroDivisionError):
            return None


def gps(info):
    try:
        lat = info[2]
        lon = info[4]
        lat = ratio(lat[0]) + ratio(lat[1]) / 60 + ratio(lat[2]) / 3600
        lon = ratio(lon[0]) + ratio(lon[1]) / 60 + ratio(lon[2]) / 3600
        if info.get(1) in ("S", b"S"):
            lat = -lat
        if info.get(3) in ("W", b"W"):
            lon = -lon
        if abs(lat) < 1e-6 and abs(lon) < 1e-6:
            return None, None
        return round(lat, 6), round(lon, 6)
    except (KeyError, TypeError, IndexError, ZeroDivisionError):
        return None, None


def read(path):
    from PIL import Image
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except ImportError:
        pass
    with Image.open(path) as image:
        width, height = image.size
        exif = image.getexif()
        orientation = exif.get(0x0112)
        if orientation in (5, 6, 7, 8):
            width, height = height, width
        detail = exif.get_ifd(0x8769)
        taken = detail.get(0x9003) or detail.get(0x9004) or exif.get(0x0132)
        lat, lon = gps(exif.get_ifd(0x8825))
    when = None
    if taken:
        try:
            when = datetime.datetime.strptime(str(taken).strip("\0 ")[:19], "%Y:%m:%d %H:%M:%S").timestamp()
        except ValueError:
            when = None
    return {"taken": when, "lat": lat, "lon": lon, "width": width, "height": height}


def run(ctx, inputs, options):
    photos = {}
    for number, item in enumerate(inputs):
        ctx.check()
        try:
            value = read(ctx.fetch(item["path"]))
        except Exception:  # noqa: BLE001 – unreadable: still a row, so it is not asked again
            value = {"taken": None, "lat": None, "lon": None, "width": None, "height": None}
        value["mtime"] = item.get("mtime")
        if not value["taken"]:
            value["taken"] = item.get("mtime")
        value["place"], value["country"] = None, None
        if value["lat"] is not None:
            try:
                value["place"], value["country"] = place_of(ctx, value["lat"], value["lon"])
            except Exception:  # noqa: BLE001 – no geonames: coordinates only
                pass
        photos[item["path"]] = value
        ctx.progress((number + 1) / len(inputs))
    return {"photos": photos}
