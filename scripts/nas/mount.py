"""`rclone mount` of the NAS's WebDAV at ~/NAS (docs/nas.md "PC side").

The credentials go through rclone's environment (`RCLONE_WEBDAV_*`, the
token obscured with `rclone obscure` on stdin), never the command line.
Writes go through the VFS cache (`--vfs-cache-mode writes`) in a fixed
folder, so a write that had not reached the NAS when the mount went is sent
on the next mount. When the NAS goes away the daemon unmounts at once
(lazily when something holds a file open), so ~/NAS is an empty folder
instead of a hanging one.
"""
import os
import shutil
import signal
import subprocess
import time

import config

VFS_CACHE = config.CACHE / "nas-vfs"
LOG = config.CACHE / "nas-mount.log"
RC = config.RUNTIME / "nas-rclone.sock"


def mounted(path):
    """Whether something is mounted at path (a stale FUSE mount counts)."""
    path = os.path.abspath(path)
    try:
        with open("/proc/self/mounts") as mounts:
            for line in mounts:
                fields = line.split()
                if len(fields) > 1 and fields[1].replace("\\040", " ") == path:
                    return True
    except OSError:
        pass
    return False


def stale(path):
    try:
        os.stat(path)
        return False
    except OSError as error:
        return error.errno in (107, 5)  # ENOTCONN, EIO


def obscure(secret):
    out = subprocess.run(["rclone", "obscure", "-"], input=secret, capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise RuntimeError("rclone obscure did not work: " + out.stderr.strip())
    return out.stdout.strip()


def last_log_line():
    try:
        with open(LOG, "rb") as file:
            file.seek(max(0, os.path.getsize(LOG) - 2000))
            lines = [line for line in file.read().decode("utf-8", "replace").splitlines() if line.strip()]
        return lines[-1][-300:] if lines else ""
    except OSError:
        return ""


def unmount(path, wait=3.0):
    """Unmount quickly: a plain unmount, else a lazy one. True when gone."""
    if not mounted(path):
        return True
    for args in (["-u"], ["-uz"]):
        subprocess.run(["fusermount3", *args, path], capture_output=True, timeout=10)
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if not mounted(path):
                return True
            time.sleep(0.1)
    return not mounted(path)


class Mount:
    def __init__(self, path=None):
        self.path = os.path.abspath(path or config.mount_path())
        self.process = None
        self.address = ""
        self.error = ""

    @property
    def active(self):
        return self.process is not None and self.process.poll() is None and mounted(self.path)

    def command(self, address):
        return [
            "rclone", "mount", ":webdav:", self.path,
            "--vfs-cache-mode", "writes",
            "--cache-dir", str(VFS_CACHE),
            "--vfs-write-back", "3s",
            "--vfs-cache-max-age", "24h",
            "--dir-cache-time", "15s",
            "--attr-timeout", "2s",
            "--poll-interval", "0",
            "--timeout", "30s",
            "--contimeout", "3s",
            "--low-level-retries", "2",
            "--retries", "2",
            "--volname", "NAS",
            "--log-file", str(LOG),
            "--log-level", "NOTICE",
            "--rc", "--rc-addr", f"unix://{RC}", "--rc-no-auth",
        ]

    def start(self, address, device, token, timeout=15):
        """Mount; returns True when the mount is there."""
        if not shutil.which("rclone"):
            self.error = "rclone is not installed"
            return False
        if self.active and self.address == address:
            return True
        self.stop()
        if stale(self.path) or mounted(self.path):
            unmount(self.path)
        os.makedirs(self.path, exist_ok=True)
        if os.listdir(self.path):
            self.error = f"{self.path} is not empty"
            return False
        VFS_CACHE.mkdir(parents=True, exist_ok=True)
        LOG.parent.mkdir(parents=True, exist_ok=True)
        RC.parent.mkdir(parents=True, exist_ok=True)
        try:
            RC.unlink()
        except OSError:
            pass
        env = dict(os.environ)
        env.update({
            "RCLONE_WEBDAV_URL": address.rstrip("/") + "/dav/",
            "RCLONE_WEBDAV_VENDOR": "other",
            "RCLONE_WEBDAV_USER": device,
            "RCLONE_WEBDAV_PASS": obscure(token),
            "RCLONE_CONFIG": "/dev/null",
        })
        with open(LOG, "a") as log:
            self.process = subprocess.Popen(self.command(address), env=env, stdin=subprocess.DEVNULL,
                                            stdout=subprocess.DEVNULL, stderr=log, start_new_session=True)
        self.address = address
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if mounted(self.path):
                self.error = ""
                return True
            if self.process.poll() is not None:
                self.error = last_log_line() or "rclone stopped"
                self.process = None
                return False
            time.sleep(0.15)
        self.error = "the mount did not come up"
        self.stop()
        return False

    def stop(self):
        """Unmount and end rclone; never waits long."""
        if mounted(self.path):
            unmount(self.path)
        if self.process is not None:
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except OSError:
                    pass
                try:
                    self.process.wait(5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.process.pid, signal.SIGKILL)
                    except OSError:
                        pass
            self.process = None
        self.address = ""


def forget(nas_paths):
    """Tell the mount that these NAS paths changed behind its back (the API
    deleted or restored them), so the folder shows it at once."""
    folders = sorted({os.path.dirname(p.rstrip("/")).lstrip("/") or "" for p in nas_paths})
    args = ["rclone", "rc", "--unix-socket", str(RC), "vfs/forget"]
    for index, folder in enumerate(folders):
        args.append(f"dir{index or ''}={folder}" if folder else f"dir{index or ''}=")
    try:
        subprocess.run(args, capture_output=True, timeout=10)
        subprocess.run(["rclone", "rc", "--unix-socket", str(RC), "vfs/refresh",
                        *[f"dir{i or ''}={f}" for i, f in enumerate(folders)]], capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        pass
