#!/usr/bin/env python3
"""Subtitles made by listening: faster-whisper on a video's sound, as an SRT.

Run by scripts/video/video.py with the python of its venv
($XDG_DATA_HOME/pshell/video-venv), never with the system's:

    whisper_worker.py --path video --lang de|"" --model small --out file.srt --models dir

Prints JSON lines: {"progress": 0..1, "text": "…"}, {"lang": "de"} once it
knows, {"error": "…"} when it fails; the SRT is written only at the end.
"""
import argparse
import json
import os
import sys


def say(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def srt_time(seconds):
    ms = int(round(max(0.0, seconds) * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def sound_of(path):
    """The sound as whisper hears it (16 kHz, one channel), decoded by ffmpeg:
    faster-whisper's own decoding (PyAV) breaks with newer PyAV releases."""
    import subprocess
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-nostdin", "-i", path, "-map", "0:a:0", "-vn", "-sn", "-ac", "1", "-ar", "16000",
                          "-f", "s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768.0


def model_of(name, folder):
    from faster_whisper import WhisperModel
    # a graphics card when ctranslate2 finds one that works, else the processor
    try:
        return WhisperModel(name, device="auto", compute_type="auto", download_root=folder)
    except Exception:  # noqa: BLE001
        return WhisperModel(name, device="cpu", compute_type="int8", download_root=folder)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True)
    parser.add_argument("--lang", default="")
    parser.add_argument("--model", default="small")
    parser.add_argument("--out", required=True)
    parser.add_argument("--models", default="")
    args = parser.parse_args()
    try:
        say({"progress": 0.0, "text": "Loading the speech model (downloaded the first time)"})
        if args.models:
            os.makedirs(args.models, exist_ok=True)
        model = model_of(args.model, args.models or None)
        say({"progress": 0.02, "text": "Taking the sound out"})
        segments, info = model.transcribe(sound_of(args.path), language=args.lang or None, vad_filter=True, beam_size=5)
        say({"lang": info.language})
        duration = float(info.duration or 0) or 1.0
        blocks = []
        for segment in segments:
            words = segment.text.strip()
            if words:
                blocks.append(f"{len(blocks) + 1}\n{srt_time(segment.start)} --> {srt_time(segment.end)}\n{words}\n")
            say({"progress": min(0.99, segment.end / duration), "text": f"Listening – {int(segment.end // 60)} of {int(duration // 60)} min"})
        tmp = args.out + ".part"
        with open(tmp, "w", encoding="utf-8") as file:
            file.write("\n".join(blocks))
        os.replace(tmp, args.out)
        say({"progress": 1.0, "text": "Done"})
        return 0
    except Exception as error:  # noqa: BLE001
        say({"error": f"Listening failed: {error}"})
        return 1


if __name__ == "__main__":
    sys.exit(main())
