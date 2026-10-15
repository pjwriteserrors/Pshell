"""Windows programs: running them with Proton (outside Steam) or Wine, and
adding them to Steam as a non-Steam game, set to run with Proton.

Proton outside Steam gets a prefix of its own below
~/.local/share/pshell/proton; Wine uses the usual ~/.wine. Steam keeps its
shortcuts in a binary file per account and rewrites it when it quits, so it
is shut down before the file is changed and started again after.
"""
import os
import re
import shutil
import subprocess
import time
import zlib

HOME = os.path.expanduser("~")
DATA = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local/share")
STEAM_ROOTS = [os.path.join(DATA, "Steam"), os.path.join(HOME, ".steam/steam"), os.path.join(HOME, ".steam/root"),
               os.path.join(HOME, ".var/app/com.valvesoftware.Steam/data/Steam")]
PREFIXES = os.path.join(DATA, "pshell/proton")
LOG = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "pshell/windows.log")
WINDOWS = re.compile(r"\.(exe|msi|msix|bat|cmd|com|lnk|scr)$", re.I)
VERSION = re.compile(r"(\d+)")


def steam_root():
    for root in STEAM_ROOTS:
        if os.path.isdir(os.path.join(root, "steamapps")) or os.path.isdir(os.path.join(root, "userdata")):
            return os.path.realpath(root)
    return ""


def _version_key(name):
    return [int(part) for part in VERSION.findall(name)] or [0]


def protons():
    """Every Proton there is, the best first: GE-Proton (newest), then
    Valve's Experimental, then the numbered ones."""
    found = {}
    root = steam_root()
    places = []
    if root:
        places += [os.path.join(root, "compatibilitytools.d"), os.path.join(root, "steamapps/common")]
    places += ["/usr/share/steam/compatibilitytools.d", os.path.join(HOME, ".steam/root/compatibilitytools.d")]
    for place in places:
        try:
            names = os.listdir(place)
        except OSError:
            continue
        for name in names:
            path = os.path.join(place, name)
            if not os.path.isfile(os.path.join(path, "proton")):
                continue
            real = os.path.realpath(path)
            if real in found:
                continue
            found[real] = {"id": tool_name(path, name), "name": name.replace("-x86_64", ""), "path": real}

    def rank(tool):
        name = tool["name"].lower()
        if "ge-proton" in name or "proton-ge" in name:
            return (0, [-n for n in _version_key(name)])
        if "experimental" in name:
            return (1, [0])
        if "hotfix" in name:
            return (3, [0])
        return (2, [-n for n in _version_key(name)])

    return sorted(found.values(), key=rank)


def tool_name(path, folder):
    """The name Steam knows a compatibility tool by."""
    manifest = os.path.join(path, "compatibilitytool.vdf")
    if os.path.isfile(manifest):
        try:
            import vdf
            data = vdf.load(open(manifest, encoding="utf-8", errors="replace"))
            tools = data.get("compatibilitytools", {}).get("compat_tools", {})
            if tools:
                return next(iter(tools))
        except Exception:
            pass
        return folder
    lower = folder.lower()
    if "experimental" in lower:
        return "proton_experimental"
    if "hotfix" in lower:
        return "proton_hotfix"
    match = re.search(r"proton (\d+)", lower)
    return f"proton_{match.group(1)}" if match else folder


def runners():
    """What can run Windows programs here, for the menus."""
    out = [{"id": f"proton:{tool['path']}", "name": tool["name"], "kind": "proton"} for tool in protons()]
    if shutil.which("wine"):
        out.append({"id": "wine", "name": "Wine", "kind": "wine"})
    return {"runners": out, "steam": bool(steam_root()) and bool(shutil.which("steam"))}


def _command(path, wrapper):
    lower = path.lower()
    if lower.endswith(".msi"):
        return wrapper + ["msiexec", "/i", path]
    if lower.endswith((".bat", ".cmd", ".lnk")):
        return wrapper + ["start", "/unix", path]
    return wrapper + [path]


def run(path, runner="auto"):
    """Starts a Windows program; returns what started it, or raises."""
    command, env, label = prepare(path, runner)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    log = open(LOG, "ab")
    log.write(f"\n=== {time.strftime('%F %T')} {' '.join(command)}\n".encode())
    log.flush()
    subprocess.Popen(command, cwd=os.path.dirname(path), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    return label


def prepare(path, runner="auto", prefix="default"):
    """What starts a Windows program: (command, environment, label). Proton
    gets the prefix `prefix` below PREFIXES (a game keeps one of its own)."""
    if not os.path.isfile(path):
        raise RuntimeError("It is not there any more")
    tools = protons()
    wine = shutil.which("wine")
    env = dict(os.environ)
    if runner == "auto":
        runner = f"proton:{tools[0]['path']}" if tools else ("wine" if wine else "")
    elif runner == "proton":
        runner = f"proton:{tools[0]['path']}" if tools else ""
    if runner.startswith("proton:"):
        tool = runner.split(":", 1)[1]
        prefix = os.path.join(PREFIXES, prefix)
        os.makedirs(prefix, exist_ok=True)
        env["STEAM_COMPAT_DATA_PATH"] = prefix
        env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = steam_root() or os.path.join(DATA, "Steam")
        env.setdefault("PROTON_LOG_DIR", os.path.dirname(LOG))
        if shutil.which("umu-run"):
            env["PROTONPATH"] = tool
            env["WINEPREFIX"] = prefix
            command = ["umu-run", path] if not path.lower().endswith(".msi") else ["umu-run", "msiexec", "/i", path]
        else:
            command = _command(path, [os.path.join(tool, "proton"), "run"])
        label = os.path.basename(tool).replace("-x86_64", "")
    elif runner == "wine" and wine:
        command = _command(path, [wine])
        label = "Wine"
    else:
        raise RuntimeError("Neither Proton nor Wine is installed")
    return command, env, label


# ── Steam ──────────────────────────────────────────────────────────────────
def steam_account(root):
    """The account folder of who last signed in to Steam."""
    try:
        import vdf
        users = vdf.load(open(os.path.join(root, "config/loginusers.vdf"), encoding="utf-8", errors="replace")).get("users", {})
    except Exception:
        users = {}
    best, when = None, -1
    for steam_id, user in users.items():
        lowered = {key.lower(): value for key, value in user.items()}
        stamp = int(lowered.get("timestamp") or 0) + (10**12 if str(lowered.get("mostrecent", "0")) == "1" else 0)
        if stamp > when:
            best, when = steam_id, stamp
    if best:
        account = str(int(best) - 76561197960265728)
        if os.path.isdir(os.path.join(root, "userdata", account)):
            return account
    # otherwise the account that was used last
    try:
        accounts = [name for name in os.listdir(os.path.join(root, "userdata")) if name.isdigit() and name != "0"]
    except OSError:
        return ""
    accounts.sort(key=lambda name: os.path.getmtime(os.path.join(root, "userdata", name)), reverse=True)
    return accounts[0] if accounts else ""


def steam_running():
    try:
        out = subprocess.run(["pgrep", "-x", "steam"], capture_output=True, text=True, timeout=3).stdout
        return bool(out.strip())
    except (OSError, subprocess.SubprocessError):
        return False


def shortcut_id(exe, name):
    """The id Steam gives a non-Steam game (and its big id for steam:// links)."""
    short = (zlib.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF) | 0x80000000
    return short, (short << 32) | 0x02000000


def add_to_steam(path, name, tool_id, wait=lambda: None, report=lambda text: None):
    """Adds a Windows program to Steam's library, run with `tool_id`
    (a compatibility tool's name). Steam is shut down first and started
    again after. Returns { appid, gameid, name }."""
    import vdf
    root = steam_root()
    if not root:
        raise RuntimeError("Steam is not installed")
    account = steam_account(root)
    if not account:
        raise RuntimeError("Sign in to Steam once first")
    exe = f'"{path}"'
    start = f'"{os.path.dirname(path)}"'
    appid, gameid = shortcut_id(exe, name)
    was_running = steam_running()
    if was_running:
        report("Closing Steam")
        subprocess.Popen(["steam", "-shutdown"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(240):
            wait()
            if not steam_running():
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Steam did not close")
        time.sleep(1)
    report("Adding the game")
    shortcuts_path = os.path.join(root, "userdata", account, "config/shortcuts.vdf")
    os.makedirs(os.path.dirname(shortcuts_path), exist_ok=True)
    try:
        with open(shortcuts_path, "rb") as file:
            data = vdf.binary_load(file)
    except (OSError, Exception):
        data = {"shortcuts": {}}
    shortcuts = data.setdefault("shortcuts", {})
    # the same program again replaces its old entry
    for key in [key for key, entry in shortcuts.items() if str(entry.get("Exe", entry.get("exe", ""))) == exe]:
        del shortcuts[key]
    entries = list(shortcuts.values())
    signed = appid - (1 << 32) if appid >= (1 << 31) else appid
    entries.append({
        "appid": signed, "AppName": name, "Exe": exe, "StartDir": start, "icon": "", "ShortcutPath": "",
        "LaunchOptions": "", "IsHidden": 0, "AllowDesktopConfig": 1, "AllowOverlay": 1, "OpenVR": 0, "Devkit": 0,
        "DevkitGameID": "", "DevkitOverrideAppID": 0, "LastPlayTime": 0, "FlatpakAppID": "", "tags": {},
    })
    data["shortcuts"] = {str(index): entry for index, entry in enumerate(entries)}
    if os.path.exists(shortcuts_path):
        shutil.copy2(shortcuts_path, shortcuts_path + ".pshell-backup")
    with open(shortcuts_path + ".tmp", "wb") as file:
        vdf.binary_dump(data, file)
    os.replace(shortcuts_path + ".tmp", shortcuts_path)
    if tool_id:
        _map_tool(root, appid, tool_id)
    if was_running:
        report("Starting Steam again")
        subprocess.Popen(["steam", "-silent"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return {"appid": appid, "gameid": str(gameid), "name": name, "restarted": was_running}


def _block_end(text, brace):
    """Where the block that opens at `brace` closes (quotes respected)."""
    depth, quoted, index = 0, False, brace
    while index < len(text):
        char = text[index]
        if char == '"' and text[index - 1] != "\\":
            quoted = not quoted
        elif not quoted and char == "{":
            depth += 1
        elif not quoted and char == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


def _map_tool(root, appid, tool_id):
    """Runs the shortcut with a compatibility tool. Steam's config.vdf is
    changed only where the mapping is, the rest stays byte for byte."""
    config_path = os.path.join(root, "config/config.vdf")
    try:
        with open(config_path, encoding="utf-8", errors="surrogateescape") as file:
            text = file.read()
    except OSError:
        return
    at = text.find('"CompatToolMapping"')
    if at < 0:
        return
    brace = text.find("{", at)
    end = _block_end(text, brace)
    if brace < 0 or end < 0:
        return
    line_start = text.rfind("\n", 0, at) + 1
    indent = text[line_start:at] + "\t"
    block = text[brace + 1:end]
    # an older mapping of the same id goes
    old = re.search(r'\n[ \t]*"' + str(appid) + r'"\s*\{', block)
    if old:
        open_at = brace + 1 + old.end() - 1
        close_at = _block_end(text, open_at)
        text = text[:brace + 1 + old.start()] + text[close_at + 1:]
    entry = (f'\n{indent}"{appid}"\n{indent}{{\n{indent}\t"name"\t\t"{tool_id}"\n'
             f'{indent}\t"config"\t\t""\n{indent}\t"priority"\t\t"250"\n{indent}}}')
    text = text[:brace + 1] + entry + text[brace + 1:]
    shutil.copy2(config_path, config_path + ".pshell-backup")
    with open(config_path + ".tmp", "w", encoding="utf-8", errors="surrogateescape") as file:
        file.write(text)
    os.replace(config_path + ".tmp", config_path)
