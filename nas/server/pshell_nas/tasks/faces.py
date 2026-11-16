"""Faces in photos: OpenCV's YuNet finds them, SFace turns each into 128
numbers; the server groups those into people."""
import base64

from . import TaskError, models
from .media import open_picture

LONGEST = 1280
_nets = {}


def nets(ctx):
    if "detector" not in _nets:
        try:
            import cv2
        except ImportError:
            raise TaskError("OpenCV is not installed")
        detector = cv2.FaceDetectorYN.create(str(models.path(ctx, "face_detection_yunet_2023mar.onnx")), "", (320, 320),
                                             0.85, 0.3, 5000)
        recognizer = cv2.FaceRecognizerSF.create(str(models.path(ctx, "face_recognition_sface_2021dec.onnx")), "")
        _nets.update(detector=detector, recognizer=recognizer)
    return _nets["detector"], _nets["recognizer"]


def run(ctx, inputs, options):
    import numpy
    detector, recognizer = nets(ctx)
    found = {}
    for number, item in enumerate(inputs):
        ctx.check()
        try:
            image = open_picture(ctx.fetch(item["path"]), LONGEST).convert("RGB")
        except Exception:  # noqa: BLE001 – unreadable: no faces
            found[item["path"]] = []
            continue
        pixels = numpy.asarray(image)[:, :, ::-1].copy()      # RGB → BGR
        height, width = pixels.shape[:2]
        detector.setInputSize((width, height))
        _, faces = detector.detect(pixels)
        items = []
        for face in faces if faces is not None else []:
            if face[2] < 40 or face[3] < 40:
                continue                                       # too small to tell anyone apart
            aligned = recognizer.alignCrop(pixels, face)
            vector = recognizer.feature(aligned).astype(numpy.float32).flatten()
            items.append({"box": [round(float(face[0]) / width, 4), round(float(face[1]) / height, 4),
                                  round(float(face[2]) / width, 4), round(float(face[3]) / height, 4)],
                          "score": round(float(face[-1]), 3),
                          "vec": base64.b64encode(vector.tobytes()).decode()})
        found[item["path"]] = items
        ctx.progress((number + 1) / len(inputs))
    return {"faces": found, "count": sum(len(items) for items in found.values())}
