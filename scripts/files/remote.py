"""Sending files to a server of the SSH plugin (scripts/ssh-manager): its
folders are listed for the path field's completion, files and folders go
there with rsync (scp where the server has no rsync).

The logins, their passwords (asked through ssh's askpass) and keys are the
SSH manager's; this only adds a shared connection per server, so listing
folder after folder while a path is typed costs no new login each time.
"""
import importlib.machinery
import importlib.util
import os
import re
import shlex
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
MANAGER = os.path.join(os.path.dirname(HERE), "ssh-manager")
RUNTIME = os.environ.get("PSHELL_RUNTIME_DIR") or os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "pshell")
_manager = None


class RemoteError(Exception):
    pass


def manager():
    """The SSH manager script, loaded as a module."""
    global _manager
    if _manager is None:
        loader = importlib.machinery.SourceFileLoader("ssh_manager", MANAGER)
        spec = importlib.util.spec_from_loader("ssh_manager", loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        _manager = module
    return _manager


COMMON = ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]


def shared():
    return ["-o", "ControlMaster=auto", "-o", f"ControlPath={RUNTIME}/ssh-%C", "-o", "ControlPersist=300"]


def login(server):
    """(target, ssh options, env) of a server: a saved login of the SSH
    manager ({ entry: id }) or an address ({ address: "user@host:port" or
    an alias of ~/.ssh/config }), which logs in with the keys there are."""
    os.makedirs(RUNTIME, exist_ok=True)
    if server.get("entry"):
        ssh = manager()
        try:
            entry = ssh.find_entry(str(server["entry"]))
        except Exception as error:
            raise RemoteError(str(error) or "That login is gone")
        host = str(entry["host"])
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        return f"{entry['user']}@{host}", ssh.ssh_options(entry) + shared(), ssh.ssh_env(entry)
    address = str(server.get("address") or "").strip()
    match = re.fullmatch(r"(?:([^@\s]+)@)?(\[[^\]]+\]|[^:\s]+)(?::(\d+))?", address)
    if not match:
        raise RemoteError("Write the server as user@host (or host:port)")
    user, host, port = match.groups()
    options = COMMON + ["-o", "BatchMode=yes"] + shared() + (["-p", port] if port else [])
    return (f"{user}@{host}" if user else host), options, dict(os.environ)


def scp_options(options):
    """ssh's -p (port) is scp's -P."""
    out = list(options)
    for index, value in enumerate(out):
        if value == "-p" and index + 1 < len(out):
            out[index] = "-P"
    return out


def servers():
    """Where files can go: the SSH manager's logins, the hosts of
    ~/.ssh/config and the ones ssh knows from before."""
    out = []
    try:
        for entry in manager().read_entries():
            out.append({"kind": "entry", "id": str(entry["id"]), "name": str(entry.get("name") or entry.get("display_name") or f"{entry['user']}@{entry['host']}"),
                        "address": f"{entry['user']}@{entry['host']}", "used": float(entry.get("last_used_at") or 0)})
    except Exception:
        pass
    home = os.path.expanduser("~/.ssh")
    try:
        with open(os.path.join(home, "config"), encoding="utf-8", errors="replace") as file:
            for line in file:
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0].lower() == "host":
                    for alias in parts[1:]:
                        if "*" not in alias and "?" not in alias:
                            out.append({"kind": "alias", "id": alias, "name": alias, "address": alias, "used": 0})
    except OSError:
        pass
    known = []
    try:
        with open(os.path.join(home, "known_hosts"), encoding="utf-8", errors="replace") as file:
            for line in file:
                first = line.split(" ", 1)[0]
                if not first or first.startswith(("|", "#", "@")):
                    continue
                for host in first.split(","):
                    host = re.sub(r"^\[([^\]]+)\]:(\d+)$", r"\1:\2", host)
                    if host not in known:
                        known.append(host)
    except OSError:
        pass
    taken = {item["address"].split("@")[-1] for item in out}
    out += [{"kind": "known", "id": host, "name": host, "address": host, "used": 0} for host in known[:40] if host not in taken]
    return {"servers": out}


def remote_path(path):
    """A path as the server's shell takes it: "~/x" stays at home."""
    text = str(path or "").strip() or "~"
    if text == "~":
        return "."
    if text.startswith("~/"):
        return text[2:] or "."
    return text


def failure(stderr, fallback):
    lines = [line.strip() for line in (stderr or "").splitlines() if line.strip() and not line.startswith("Warning: Permanently added")]
    return lines[-1] if lines else fallback


def listing(server, folder):
    """What is in a folder of the server: { path (absolute), home, entries:
    [{ name, dir }] }."""
    target, options, env = login(server)
    text = str(folder or "").strip() or "~"
    if text in ("~", "~/"):
        cd = "cd"
    elif text.startswith("~/"):
        cd = f"cd -- ~/{shlex.quote(text[2:])}"
    else:
        cd = f"cd -- {shlex.quote(text)}"
    command = f"{cd} && pwd && printf '%s\\n' \"$HOME\" && LC_ALL=C ls -1ApL 2>/dev/null"
    try:
        result = subprocess.run(["ssh", "-T", *options, target, command], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, errors="replace", env=env, timeout=25)
    except subprocess.TimeoutExpired:
        raise RemoteError("The server takes too long to answer")
    lines = result.stdout.splitlines()
    if len(lines) < 2 or not lines[0].startswith("/"):
        detail = failure(result.stderr, "")
        if "No such file" in detail or "can't cd" in detail or result.returncode == 1:
            raise RemoteError("That folder is not on the server")
        if "Permission denied" in detail or "Host key verification" in detail:
            raise RemoteError("The server wants a password: save it as a login in the SSH manager (>ssh)" if "Permission denied" in detail else detail)
        raise RemoteError(detail or "The server cannot be reached")
    entries = [{"name": line.rstrip("/"), "dir": line.endswith("/")} for line in lines[2:] if line.rstrip("/") not in ("", ".", "..")]
    entries.sort(key=lambda item: (not item["dir"], item["name"].casefold()))
    return {"path": lines[0], "home": lines[1], "entries": entries}


def run(server, command, timeout=60):
    """One command on the server (a folder made, a share taken back)."""
    target, options, env = login(server)
    try:
        result = subprocess.run(["ssh", "-T", *options, target, command], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, errors="replace", env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RemoteError("The server takes too long to answer")
    if result.returncode != 0:
        raise RemoteError(failure(result.stderr, "The server refused it"))
    return result.stdout


PROGRESS = re.compile(r"^\s*([\d,.]+)\s+(\d+)%\s+(\S+)")


def send(job, server, sources, destination):
    """Copies files and folders into a folder of the server. Progress comes
    from rsync's --info=progress2; scp (no rsync there) runs without it."""
    host, options, env = login(server)
    destination = str(destination or "").strip()
    if not destination:
        raise RemoteError("Where on the server should they go?")
    target = f"{host}:{remote_path(destination).rstrip('/') or '/'}/"
    shell = " ".join(shlex.quote(part) for part in ["ssh", *options])
    command = ["rsync", "-a", "--info=progress2", "--no-inc-recursive", "--protect-args", "-e", shell, "--", *sources, target]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=env, start_new_session=True)
    job.process = process
    errors = b""
    try:
        buffer = b""
        while True:
            chunk = process.stdout.read1(4096) if hasattr(process.stdout, "read1") else process.stdout.read(4096)
            if not chunk:
                break
            buffer = (buffer + chunk)[-8192:]
            for part in re.split(rb"[\r\n]", chunk):
                match = PROGRESS.match(part.decode("utf-8", "replace"))
                if match:
                    done = int(match.group(1).replace(",", "").replace(".", ""))
                    job.bytes_done = min(job.bytes_total or done, done)
                    job.report()
            if job.cancellable.is_cancelled():
                break
        process.wait()
        errors = process.stderr.read()
    finally:
        job.process = None
        if process.poll() is None:
            process.kill()
            process.wait()
    job.check()
    text = errors.decode("utf-8", "replace")
    if process.returncode == 0:
        return
    # no rsync on the server: scp, all at once
    if "rsync: command not found" in text or "rsync: not found" in text or process.returncode == 127:
        job.current = "Sending with scp"
        job.report(True)
        command = ["scp", "-r", "-q", *scp_options(options), "--", *sources, target]
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                   env=env, start_new_session=True)
        job.process = process
        try:
            _, errors = process.communicate()
        finally:
            job.process = None
        job.check()
        if process.returncode == 0:
            return
        text = errors.decode("utf-8", "replace")
    raise RemoteError(failure(text, "The files could not be sent"))
