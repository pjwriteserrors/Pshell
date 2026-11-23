#!/usr/bin/env python3
"""The words of a take, each with when it is said: faster-whisper, run with
the python of the video player's venv ($XDG_DATA_HOME/pshell/video-venv),
which the rhymes helper installs when it is not there.

    align_worker.py --path take.wav --model small --models dir --prompt "the lyrics"

Prints JSON lines: {"progress": 0..1, "text": "…"}, then {"words": [{w, t}]}
or {"error": "…"}.
"""
import argparse
import json
import subprocess
import sys


def say(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--models", default="")
    parser.add_argument("--prompt", default="")
    args = parser.parse_args()
    try:
        import numpy as np
        from faster_whisper import WhisperModel
        say({"progress": 0.0, "text": "Loading the speech model"})
        try:
            model = WhisperModel(args.model, device="auto", compute_type="auto", download_root=args.models or None)
        except Exception:  # noqa: BLE001
            model = WhisperModel(args.model, device="cpu", compute_type="int8", download_root=args.models or None)
        raw = subprocess.run(["ffmpeg", "-v", "quiet", "-nostdin", "-i", args.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"],
                             capture_output=True, check=True).stdout
        sound = np.frombuffer(raw[:len(raw) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768.0
        length = max(1.0, sound.size / 16000)
        segments, _ = model.transcribe(sound, language="en", word_timestamps=True, vad_filter=False,
                                       initial_prompt=args.prompt[:800] or None, condition_on_previous_text=False)
        words = []
        for segment in segments:
            for word in segment.words or []:
                words.append({"w": word.word.strip(), "t": round(word.start, 3), "e": round(word.end, 3)})
            say({"progress": min(0.99, segment.end / length), "text": segment.text.strip()[:60]})
        say({"words": words})
    except Exception as error:  # noqa: BLE001
        say({"error": str(error)[:300]})


if __name__ == "__main__":
    main()
