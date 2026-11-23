"""Hearing the microphone while recording: a PipeWire filter-chain of its own
(`pipewire -c`), the microphone through a track's effects into the headphones,
with a small quantum so it comes back as soon as it can.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path

import fx
from beat import RUNTIME
from music import die_with_parent


class Monitor:
    def __init__(self):
        self.process = None
        self.chain = None
        self.settings = None

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def start(self, chain: list, source: str = "", sink: str = "", level: float = 1.0, quantum: int = 64) -> dict:
        settings = (source, sink, round(level, 3), quantum)
        if self.running and self.chain == chain and self.settings == settings:
            return self.state()
        self.stop()
        RUNTIME.mkdir(parents=True, exist_ok=True)
        config = RUNTIME / f"monitor-{os.getpid()}.conf"
        config.write_text(fx.pipewire_config(chain, source, sink, level, quantum))
        self.process = subprocess.Popen(["pipewire", "-c", str(config)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, preexec_fn=die_with_parent)
        self.chain, self.settings = chain, settings
        # a config it cannot play ends it at once
        time.sleep(0.25)
        if not self.running:
            error = (self.process.stderr.read() or b"").decode(errors="replace").strip().splitlines()
            self.process = None
            raise RuntimeError(error[-1] if error else "The monitor did not start")
        return self.state()

    def stop(self) -> dict:
        if self.process:
            try:
                self.process.send_signal(signal.SIGTERM)
                self.process.wait(2)
            except (OSError, subprocess.SubprocessError):
                self.process.kill()
        self.process = None
        self.chain = None
        return self.state()

    def state(self) -> dict:
        return {"on": self.running, "latency": round(self.settings[3] / 48, 2) if self.running and self.settings else 0}
