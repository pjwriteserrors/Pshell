"""Vaults: folders kept encrypted on disk (gocryptfs), open only while they
are unlocked. A vault is two folders: the encrypted one (hidden, it can lie
in a cloud folder) and the one it opens into.

The password can be kept in the keyring (secret-tool); the shell then asks
for a finger (on the PC or on the phone) before it opens the vault with it.

The vaults live in files-vaults.json beside the shell's other state.
"""
import json
import os
import shutil
import subprocess
import time

import lookup
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host  # noqa: E402

STATE = str(host.state_dir())
PATH = os.path.join(STATE, "files-vaults.json")


class VaultError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


def binary():
    return os.environ.get("PSHELL_GOCRYPTFS_BIN") or shutil.which("gocryptfs") or ""


def fusermount():
    return shutil.which("fusermount3") or shutil.which("fusermount") or ""


def install_command():
    if shutil.which("pacman"):
        return "sudo pacman -S --needed gocryptfs"
    if shutil.which("apt"):
        return "sudo apt install gocryptfs"
    if shutil.which("dnf"):
        return "sudo dnf install gocryptfs"
    return ""


def load():
    try:
        with open(PATH, encoding="utf-8") as file:
            return [vault for vault in json.load(file).get("vaults", []) if isinstance(vault, dict)]
    except (OSError, ValueError):
        return []


def save(vaults):
    os.makedirs(STATE, exist_ok=True)
    temp = PATH + ".tmp"
    with open(temp, "w", encoding="utf-8") as file:
        json.dump({"vaults": vaults}, file, indent="\t")
        file.write("\n")
    os.replace(temp, PATH)


def is_open(vault):
    mount = vault.get("mount", "")
    try:
        with open("/proc/self/mounts", encoding="utf-8") as file:
            for line in file:
                parts = line.split()
                if len(parts) > 2 and parts[1].replace("\\040", " ") == mount and "gocryptfs" in parts[2] + parts[0]:
                    return True
    except OSError:
        pass
    return False


def keyring_has(vault_id):
    if not shutil.which("secret-tool"):
        return False
    try:
        out = subprocess.run(["secret-tool", "lookup", "pshell-vault", vault_id], capture_output=True, timeout=10)
        return out.returncode == 0 and bool(out.stdout)
    except (OSError, subprocess.SubprocessError):
        return False


def status():
    vaults = load()
    for vault in vaults:
        vault["open"] = is_open(vault)
        vault["keyring"] = bool(vault.get("remember")) and keyring_has(vault["id"])
    return {"installed": bool(binary()), "install": install_command(), "vaults": vaults,
            "fingerprint": bool(shutil.which("fprintd-verify"))}


def run_with_password(options, cipher, mount, password, timeout=60):
    """gocryptfs reads the password from a pipe of its own, never the command line."""
    read, write = os.pipe()
    try:
        os.write(write, password.encode() + b"\n")
    finally:
        os.close(write)
    try:
        return subprocess.run([binary(), *options, "-passfile", f"/dev/fd/{read}", cipher, mount],
                              pass_fds=(read,), capture_output=True, text=True, timeout=timeout)
    finally:
        os.close(read)


def create(name, folder, password, remember):
    if not binary():
        raise VaultError("gocryptfs is not installed", "missing")
    if len(password) < 6:
        raise VaultError("The password needs at least 6 characters", "invalid")
    clean = "".join(ch for ch in name if ch not in "/\0").strip() or "Vault"
    mount = os.path.join(folder, clean)
    cipher = os.path.join(folder, f".{clean}.vault")
    if os.path.lexists(mount) or os.path.lexists(cipher):
        raise VaultError(f"{clean} is there already", "exists")
    os.makedirs(cipher)
    read, write = os.pipe()
    os.write(write, password.encode() + b"\n")
    os.close(write)
    try:
        out = subprocess.run([binary(), "-init", "-q", "-passfile", f"/dev/fd/{read}", cipher], pass_fds=(read,), capture_output=True, text=True, timeout=120)
    finally:
        os.close(read)
    if out.returncode != 0:
        shutil.rmtree(cipher, ignore_errors=True)
        raise VaultError((out.stderr.strip().splitlines() or ["gocryptfs failed"])[-1])
    os.makedirs(mount)
    vault = {"id": f"v{int(time.time() * 1000):x}", "name": clean, "cipher": cipher, "mount": mount, "remember": bool(remember), "created": time.time()}
    vaults = load()
    vaults.append(vault)
    save(vaults)
    if remember:
        remember_password(vault, password)
    open_vault(vault["id"], password, False)
    return vault


def find(vault_id):
    vault = next((v for v in load() if v.get("id") == vault_id), None)
    if vault is None:
        raise VaultError("This vault is gone", "invalid")
    return vault


def remember_password(vault, password):
    if not shutil.which("secret-tool"):
        raise VaultError("secret-tool (libsecret) is missing for keeping the password")
    out = subprocess.run(["secret-tool", "store", "--label", f"Pshell vault {vault['name']}", "pshell-vault", vault["id"]],
                         input=password, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise VaultError("The keyring did not take the password")


def open_vault(vault_id, password, from_keyring, remember=False):
    if not binary():
        raise VaultError("gocryptfs is not installed", "missing")
    vault = find(vault_id)
    if is_open(vault):
        return vault["mount"]
    if from_keyring:
        out = subprocess.run(["secret-tool", "lookup", "pshell-vault", vault_id], capture_output=True, text=True, timeout=30)
        if out.returncode != 0 or not out.stdout:
            raise VaultError("The keyring has no password for it", "password")
        password = out.stdout.rstrip("\n")
    os.makedirs(vault["mount"], exist_ok=True)
    out = run_with_password(["-q"], vault["cipher"], vault["mount"], password)
    if out.returncode != 0:
        if out.returncode == 12:
            raise VaultError("Wrong password", "password")
        raise VaultError((out.stderr.strip().splitlines() or ["gocryptfs failed"])[-1])
    if remember and not from_keyring:
        try:
            remember_password(vault, password)
            vaults = load()
            for each in vaults:
                if each["id"] == vault_id:
                    each["remember"] = True
            save(vaults)
        except VaultError:
            pass
    return vault["mount"]


def close_vault(vault_id):
    vault = find(vault_id)
    if not is_open(vault):
        return
    out = subprocess.run([fusermount(), "-u", vault["mount"]], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        detail = out.stderr.strip()
        raise VaultError("Something still uses a file in it" if "busy" in detail else (detail or "It could not be locked"), "busy")


def forget(vault_id, delete_files):
    """Takes the vault off the list; with delete_files the encrypted folder
    goes to the trash too."""
    vault = find(vault_id)
    if is_open(vault):
        close_vault(vault_id)
    if shutil.which("secret-tool"):
        subprocess.run(["secret-tool", "clear", "pshell-vault", vault_id], capture_output=True, timeout=10)
    save([v for v in load() if v.get("id") != vault_id])
    return vault


def adopt(cipher, name):
    """An encrypted folder made elsewhere (gocryptfs.conf in it) joins the list."""
    if not os.path.isfile(os.path.join(cipher, "gocryptfs.conf")):
        raise VaultError("This is not a gocryptfs folder", "invalid")
    parent = os.path.dirname(cipher.rstrip("/"))
    base = name or os.path.basename(cipher.rstrip("/")).lstrip(".").removesuffix(".vault") or "Vault"
    mount = os.path.join(parent, base)
    if os.path.lexists(mount) and os.listdir(mount):
        mount = os.path.join(parent, base + " (open)")
    vault = {"id": f"v{int(time.time() * 1000):x}", "name": base, "cipher": cipher, "mount": mount, "remember": False, "created": time.time()}
    vaults = load()
    vaults.append(vault)
    save(vaults)
    return vault


def lock_all():
    for vault in load():
        if is_open(vault):
            try:
                close_vault(vault["id"])
            except VaultError:
                pass
