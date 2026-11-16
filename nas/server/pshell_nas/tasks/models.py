"""The data files some tasks need: the face models (OpenCV zoo) and the
geonames cities for offline places. The Pi's image has them already; the PC
fetches them once into its cache."""
import os
import urllib.request
import zipfile
from pathlib import Path

from . import TaskError

FILES = {
    "face_detection_yunet_2023mar.onnx":
        "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx",
    "face_recognition_sface_2021dec.onnx":
        "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx",
    "cities1000.txt": "https://download.geonames.org/export/dump/cities1000.zip",
    "countryInfo.txt": "https://download.geonames.org/export/dump/countryInfo.txt",
}


def folder(ctx=None):
    for candidate in (getattr(ctx, "models", None), os.environ.get("NAS_MODELS"), "/app/models",
                      Path.home() / ".cache" / "pshell-nas" / "models"):
        if candidate and Path(candidate).is_dir() and any(Path(candidate).iterdir()):
            return Path(candidate)
    fallback = Path(getattr(ctx, "models", None) or Path.home() / ".cache" / "pshell-nas" / "models")
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback


def path(ctx, name):
    for base in (folder(ctx), Path("/app/models")):
        if (base / name).exists():
            return base / name
    target = folder(ctx) / name
    fetch(name, target)
    return target


def fetch(name, target):
    url = FILES[name]
    temp = target.with_suffix(".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as response, open(temp, "wb") as file:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                file.write(chunk)
    except OSError as error:
        raise TaskError(f"Could not download {name}: {error}")
    if url.endswith(".zip"):
        with zipfile.ZipFile(temp) as archive:
            with archive.open(name) as source, open(target, "wb") as out:
                while True:
                    chunk = source.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
        temp.unlink()
    else:
        os.replace(temp, target)
