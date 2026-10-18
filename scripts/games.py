#!/usr/bin/env python3
"""The game library (`games` plugin, core/services/Games.qml).

    scripts/games.py list                 every game as JSON: Steam's installed ones, its
                                          non-Steam shortcuts and the ones added here
    scripts/games.py art [id …]           fetches the pictures a game lacks (cover, hero,
                                          logo); a JSON line per game that got some
    scripts/games.py search <name>        cover candidates for a name (Steam's store, and
                                          SteamGridDB when a key is kept)
    scripts/games.py guess <path>         a name and a runner for a program
    scripts/games.py add '<json>'         adds a game: { exe, name, runner, art }
    scripts/games.py update '<json>'      changes one: { id, name?, runner?, art?, favorite?,
                                          hidden?, args? }
    scripts/games.py remove <id>          forgets a game added here
    scripts/games.py launch <id> [runner] starts it: through Steam, Proton, Wine or as it is
    scripts/games.py steam-add <id> [tool] adds a game of here to Steam as a non-Steam game
                                          (Steam is restarted for it), progress as JSON lines
    scripts/games.py steam-pads           turns Steam's desktop layout off for every non-Steam
                                          game, so the controller reaches the game (Steam is
                                          restarted for it when it runs)
    scripts/games.py running              the ids of the games that run right now
    scripts/games.py key [<key>]          the SteamGridDB API key, kept in the keyring

Games added here live in ~/.local/state/pshell/games.json with what the user
set for any game (name, cover, favourite, hidden). Pictures come from
Steam's own library cache, its grid folder (custom art of shortcuts) or are
fetched into ~/.cache/pshell/games; Steam's store answers without a key.
"""

import concurrent.futures
import difflib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "files"))
import windows  # noqa: E402

HOME = Path.home()
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "pshell"
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "pshell/games"
STORE = STATE / "games.json"
ART = CACHE / "art"
FOUND = CACHE / "search"
RUNNING = CACHE / "running"
LOG = CACHE / "launch.log"

ASSETS = "https://shared.cloudflare.steamstatic.com/store_item_assets/"
CDN = "https://cdn.cloudflare.steamstatic.com/steam/apps/"
AGENT = "Mozilla/5.0 (X11; Linux x86_64) Pshell games"
# Steam's own tools are no games
TOOLS = re.compile(r"^(proton\b|steam linux runtime|steamworks common|proton easyanticheat|proton battleye|steamvr$|steam vr)", re.I)
WINDOWS = re.compile(r"\.(exe|msi|bat|cmd|lnk)$", re.I)
# folders that say nothing about the game they are in
GENERIC = {"bin", "bin32", "bin64", "binaries", "win32", "win64", "x64", "x86", "x86_64", "bin_ship", "game", "games",
           "release", "shipping", "retail", "app", "build", "windows", "windowsnoeditor", "common", "data"}
NOISE = re.compile(r"(soundtrack|\bost\b|artbook|\bdemo\b|\bdlc\b|season pass|playtest|dedicated server|\bsdk\b)", re.I)
ART_KINDS = ("cover", "hero", "logo", "header")


def out(data):
    print(json.dumps(data, separators=(",", ":")), flush=True)


def fail(message, code=1):
    out({"error": str(message)})
    sys.exit(code)


# ── what the user keeps ────────────────────────────────────────────────────
class Store:
    """games.json under a lock: read, changed, written back."""

    def __enter__(self):
        STATE.mkdir(parents=True, exist_ok=True)
        self.lock = open(STATE / ".games.lock", "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.data = load()
        return self.data

    def __exit__(self, kind, value, trace):
        if kind is None:
            temporary = STORE.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.data, indent="\t", ensure_ascii=False) + "\n")
            os.replace(temporary, STORE)
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()


def load():
    try:
        data = json.loads(STORE.read_text())
    except (OSError, ValueError):
        data = {}
    data.setdefault("custom", [])
    # by game id: name, art, favorite, hidden, runner, lastPlayed, playtime
    data.setdefault("games", {})
    return data


# ── Steam ──────────────────────────────────────────────────────────────────
def vdf_load(path):
    import vdf
    try:
        with open(path, encoding="utf-8", errors="replace") as file:
            return vdf.load(file)
    except (OSError, SyntaxError, ValueError):
        return {}


def lower_keys(mapping):
    return {str(key).lower(): value for key, value in (mapping or {}).items()}


def libraries(root):
    data = lower_keys(vdf_load(os.path.join(root, "steamapps/libraryfolders.vdf")).get("libraryfolders"))
    paths = [root]
    for entry in data.values():
        if isinstance(entry, dict) and entry.get("path"):
            paths.append(entry["path"])
    seen, unique = set(), []
    for path in paths:
        real = os.path.realpath(path)
        if real not in seen:
            seen.add(real)
            unique.append(path)
    return unique


def steam_apps(root):
    """Installed Steam games: [{appid, name, size, lastPlayed, dir}]."""
    games = {}
    for library in libraries(root):
        steamapps = os.path.join(library, "steamapps")
        try:
            names = os.listdir(steamapps)
        except OSError:
            continue
        for name in names:
            if not (name.startswith("appmanifest_") and name.endswith(".acf")):
                continue
            state = lower_keys(vdf_load(os.path.join(steamapps, name)).get("AppState"))
            appid, title = str(state.get("appid", "")), str(state.get("name", ""))
            if not appid or not title or TOOLS.search(title):
                continue
            flags = int(state.get("stateflags") or 0)
            if not flags & 4:
                continue
            games[appid] = {
                "appid": appid, "name": title, "size": int(state.get("sizeondisk") or 0),
                "lastPlayed": int(state.get("lastplayed") or 0),
                "dir": os.path.join(steamapps, "common", str(state.get("installdir", ""))),
                "updating": bool(flags & 2) or bool(flags & 1024),
            }
    return list(games.values())


def playtimes(root, account):
    """{appid: (minutes, last played)} from the account's localconfig.vdf."""
    if not account:
        return {}
    data = vdf_load(os.path.join(root, "userdata", account, "config/localconfig.vdf"))
    node = data
    for key in ("UserLocalConfigStore", "Software", "Valve", "Steam"):
        node = lower_keys(node).get(key.lower(), {}) if isinstance(node, dict) else {}
    apps = lower_keys(node).get("apps", {})
    result = {}
    for appid, entry in apps.items():
        if isinstance(entry, dict):
            entry = lower_keys(entry)
            result[str(appid)] = (int(entry.get("playtime") or 0), int(entry.get("lastplayed") or 0))
    return result


def shortcuts(root, account):
    """Steam's non-Steam games: [{appid (unsigned), gameid, name, exe, dir, lastPlayed}]."""
    import vdf
    if not account:
        return []
    try:
        with open(os.path.join(root, "userdata", account, "config/shortcuts.vdf"), "rb") as file:
            data = vdf.binary_load(file)
    except Exception:
        return []
    result = []
    for entry in (data.get("shortcuts") or {}).values():
        entry = lower_keys(entry)
        appid = int(entry.get("appid") or 0) & 0xFFFFFFFF
        exe = str(entry.get("exe") or "").strip().strip('"')
        name = str(entry.get("appname") or "")
        if not appid or str(entry.get("ishidden") or 0) == "1":
            continue
        result.append({
            "appid": str(appid), "gameid": str((appid << 32) | 0x02000000), "name": name, "exe": exe,
            "dir": str(entry.get("startdir") or "").strip().strip('"'), "lastPlayed": int(entry.get("lastplaytime") or 0),
        })
    return result


def first_file(folder, names):
    """A file of one of `names` in `folder` or a folder below it (Steam keeps
    newer art in hashed subfolders)."""
    if not os.path.isdir(folder):
        return ""
    for name in names:
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            return path
    try:
        subs = [os.path.join(folder, sub) for sub in os.listdir(folder)]
    except OSError:
        return ""
    for name in names:
        for sub in subs:
            path = os.path.join(sub, name)
            if os.path.isfile(path):
                return path
    return ""


def steam_art(root, appid):
    """What Steam's library cache holds of an app."""
    folder = os.path.join(root, "appcache/librarycache", str(appid))
    return {
        "cover": first_file(folder, ["library_600x900_2x.jpg", "library_600x900.jpg", "library_capsule.jpg"]),
        "hero": first_file(folder, ["library_hero_2x.jpg", "library_hero.jpg"]),
        "logo": first_file(folder, ["logo_2x.png", "logo.png"]),
        "header": first_file(folder, ["header.jpg", "library_header.jpg"]),
    }


def grid_art(root, account, appid):
    """Custom art the user gave a shortcut in Steam."""
    folder = os.path.join(root, "userdata", account, "config/grid")
    found = {}
    for kind, stem in (("cover", f"{appid}p"), ("hero", f"{appid}_hero"), ("logo", f"{appid}_logo"), ("header", f"{appid}")):
        for ext in (".png", ".jpg", ".jpeg", ".webp"):
            path = os.path.join(folder, stem + ext)
            if os.path.isfile(path):
                found[kind] = path
                break
    return found


def cached_art(key):
    folder = ART / safe(key)
    found = {}
    for kind in ART_KINDS:
        for ext in (".jpg", ".png", ".webp"):
            path = folder / (kind + ext)
            if path.is_file() and path.stat().st_size > 0:
                found[kind] = str(path)
                break
    return found


def safe(text):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", str(text))


# ── names ──────────────────────────────────────────────────────────────────
def normal(name):
    name = re.sub(r"[™®©]", "", name.lower())
    name = re.sub(r"[^a-z0-9]+", " ", name)
    return re.sub(r"\s+", " ", name).strip()


def pretty(name):
    """tiny-glade.exe → Tiny Glade"""
    name = re.sub(r"\.(exe|bat|cmd|sh|x86_64|appimage)$", "", name, flags=re.I)
    name = re.sub(r"[_\-.]+", " ", name)
    # DragonAgeInquisition, but not PowerWash Simulator
    if " " not in name.strip():
        name = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:1].upper() + name[1:] if name.islower() else name


def guess_name(path):
    """The name of the game a program belongs to: its folder, unless that
    says nothing (Binaries/Win64), else the program."""
    parts = Path(path).parent.parts
    for part in reversed(parts):
        if part.lower() not in GENERIC and not re.fullmatch(r"[a-z]:|/|mnt|home|games|non-steam|steam", part.lower()):
            folder = part
            break
    else:
        folder = ""
    exe = pretty(Path(path).name)
    if not folder:
        return exe
    # "Dragon Age/Dragon Age II/bin_ship" → "Dragon Age II"; a folder that is
    # just the program's name is fine too
    return pretty(folder) if len(folder) > 2 else exe


def guess_runner(path):
    if WINDOWS.search(path):
        return "proton" if windows.protons() else ("wine" if shutil.which("wine") else "proton")
    return "native"


def similarity(a, b):
    a, b = normal(a), normal(b)
    if not a or not b:
        return 0
    if a == b:
        return 1
    ratio = difflib.SequenceMatcher(None, a, b).ratio()
    if a.startswith(b) or b.startswith(a):
        ratio = max(ratio, 0.8)
    # "Morrowind" is "The Elder Scrolls III: Morrowind GOTY"
    elif min(len(a), len(b)) >= 6 and (f" {a} " in f" {b} " or f" {b} " in f" {a} "):
        ratio = max(ratio, 0.74)
    return ratio


# ── fetching ───────────────────────────────────────────────────────────────
def get(url, timeout=12, headers=None):
    request = urllib.request.Request(url, headers={"User-Agent": AGENT, **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def get_json(url, timeout=12, headers=None):
    return json.loads(get(url, timeout, headers).decode("utf-8", "replace"))


def download(url, target):
    """Fetches `url` into `target` (atomically); True when it is there."""
    try:
        data = get(url, 20)
    except Exception:
        return False
    if len(data) < 512:
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".part")
    temporary.write_bytes(data)
    os.replace(temporary, target)
    return True


def store_search(term, limit=8):
    """Steam's store search: [{appid, name}], the best first, without
    soundtracks and demos unless asked for."""
    query = urllib.parse.urlencode({"term": term, "l": "english", "cc": "US"})
    try:
        items = get_json(f"https://store.steampowered.com/api/storesearch/?{query}").get("items", [])
    except Exception:
        return []
    wants_noise = bool(NOISE.search(term))
    found = []
    for item in items:
        if item.get("type") != "app" or (not wants_noise and NOISE.search(item.get("name", ""))):
            continue
        found.append({"appid": str(item["id"]), "name": item.get("name", "")})
    return found[:limit]


def store_assets(appids):
    """The library pictures Steam's store has for apps: {appid: {cover, hero, logo, header}} as URLs."""
    if not appids:
        return {}
    payload = {"ids": [{"appid": int(appid)} for appid in appids], "context": {"language": "english", "country_code": "US"},
               "data_request": {"include_assets": True}}
    url = "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?" + urllib.parse.urlencode({"input_json": json.dumps(payload)})
    try:
        items = get_json(url).get("response", {}).get("store_items", [])
    except Exception:
        items = []
    result = {}
    for item in items:
        appid = str(item.get("appid") or item.get("id") or "")
        assets = item.get("assets") or {}
        pattern = assets.get("asset_url_format", "")
        if not appid or not pattern:
            continue

        def url_of(*names):
            for name in names:
                if assets.get(name):
                    return ASSETS + pattern.replace("${FILENAME}", assets[name])
            return ""
        result[appid] = {
            "cover": url_of("library_capsule_2x", "library_capsule"),
            "hero": url_of("library_hero_2x", "library_hero"),
            "logo": url_of("library_logo_2x", "library_logo") or f"{CDN}{appid}/logo.png",
            "header": url_of("header_2x", "header"),
            "name": item.get("name", ""),
        }
    for appid in appids:
        result.setdefault(str(appid), {"cover": f"{CDN}{appid}/library_600x900_2x.jpg", "hero": f"{CDN}{appid}/library_hero.jpg",
                                       "logo": f"{CDN}{appid}/logo.png", "header": f"{CDN}{appid}/header.jpg", "name": ""})
    return result


# ── SteamGridDB (optional, needs a key) ────────────────────────────────────
def sgdb_key():
    # the keyring is asked only when a key was kept: without one it may hang
    if not load().get("gridKey") or not shutil.which("secret-tool"):
        return ""
    try:
        return subprocess.run(["secret-tool", "lookup", "service", "pshell-steamgriddb"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def sgdb(path, key):
    return get_json(f"https://www.steamgriddb.com/api/v2/{path}", headers={"Authorization": f"Bearer {key}"})


def sgdb_search(term, key, limit=4):
    try:
        games = sgdb(f"search/autocomplete/{urllib.parse.quote(term)}", key).get("data", [])[:limit]
    except Exception:
        return []

    def pictures(game):
        found = {"id": f"sgdb:{game['id']}", "name": game.get("name", ""), "source": "SteamGridDB"}
        for kind, path in (("cover", f"grids/game/{game['id']}?dimensions=600x900,342x482,660x930"),
                           ("hero", f"heroes/game/{game['id']}"), ("logo", f"logos/game/{game['id']}")):
            try:
                data = sgdb(path, key).get("data", [])
                found[kind] = data[0]["url"] if data else ""
            except Exception:
                found[kind] = ""
        return found
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        return [entry for entry in pool.map(pictures, games) if entry.get("cover")]


# ── art ────────────────────────────────────────────────────────────────────
def art_urls(art):
    """Where the pictures of an art choice ("steam:<appid>", "sgdb:<id>") are."""
    if not art or art == "none":
        return {}
    kind, _, ident = art.partition(":")
    if kind == "steam":
        return store_assets([ident]).get(ident, {})
    if kind == "sgdb":
        key = sgdb_key()
        if not key:
            return {}
        found = {}
        for name, path in (("cover", f"grids/game/{ident}?dimensions=600x900,342x482,660x930"), ("hero", f"heroes/game/{ident}"), ("logo", f"logos/game/{ident}")):
            try:
                data = sgdb(path, key).get("data", [])
                found[name] = data[0]["url"] if data else ""
            except Exception:
                found[name] = ""
        return found
    return {}


def fetch_art(key, urls, kinds=ART_KINDS):
    """Downloads what `urls` has into the cache of `key`; returns what is there."""
    folder = ART / safe(key)
    have = cached_art(key)
    jobs = []
    for kind in kinds:
        url = urls.get(kind)
        if not url or kind in have:
            continue
        ext = ".png" if kind == "logo" or url.lower().split("?")[0].endswith(".png") else ".jpg"
        jobs.append((kind, url, folder / (kind + ext)))
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        list(pool.map(lambda job: download(job[1], job[2]), jobs))
    return cached_art(key)


def drop_art(key):
    shutil.rmtree(ART / safe(key), ignore_errors=True)


def auto_art(name):
    """The store's game for a name when it is clearly that one."""
    best, score = None, 0
    for entry in store_search(name, 5):
        value = similarity(name, entry["name"])
        if value > score:
            best, score = entry, value
    return f"steam:{best['appid']}" if best and score >= 0.72 else ""


# ── the library ────────────────────────────────────────────────────────────
def collect():
    data = load()
    kept = data["games"]
    root = windows.steam_root()
    account = windows.steam_account(root) if root else ""
    games = []
    times = playtimes(root, account) if root else {}

    def merged(game):
        own = kept.get(game["id"], {})
        if own.get("name"):
            game["name"] = own["name"]
        game["favorite"] = bool(own.get("favorite"))
        game["hidden"] = bool(own.get("hidden"))
        game["lastPlayed"] = max(int(game.get("lastPlayed") or 0), int(own.get("lastPlayed") or 0))
        game["playtime"] = int(game.get("playtime") or 0) + int(own.get("playtime") or 0)
        game["artChoice"] = own.get("art", "")
        # what the user picked wins over Steam's pictures
        if own.get("art"):
            picked = cached_art(game["id"])
            if picked:
                game["art"] = {**game.get("art", {}), **picked}
        return game

    owned_exes = {}
    for entry in data["custom"]:
        owned_exes[os.path.realpath(entry.get("exe", ""))] = entry

    if root:
        for app in steam_apps(root):
            minutes, last = times.get(app["appid"], (0, 0))
            art = steam_art(root, app["appid"])
            missing = {kind: path for kind, path in cached_art(f"steam:{app['appid']}").items() if not art.get(kind)}
            games.append(merged({
                "id": f"steam:{app['appid']}", "kind": "steam", "name": app["name"], "appid": app["appid"],
                "gameid": app["appid"], "dir": app["dir"], "size": app["size"], "updating": app["updating"],
                "lastPlayed": max(app["lastPlayed"], last), "playtime": minutes, "art": {**art, **missing},
                "runner": "steam",
            }))
        for shortcut in shortcuts(root, account):
            exe = os.path.realpath(shortcut["exe"]) if shortcut["exe"] else ""
            own = owned_exes.get(exe)
            if own is not None:
                own["_steam"] = shortcut
                continue
            name = shortcut["name"]
            if WINDOWS.search(name) or name.lower() == Path(shortcut["exe"]).name.lower():
                name = guess_name(shortcut["exe"]) or pretty(name)
            game_id = f"shortcut:{shortcut['appid']}"
            art = {**cached_art(game_id), **grid_art(root, account, shortcut["appid"])}
            games.append(merged({
                "id": game_id, "kind": "shortcut", "name": name, "appid": shortcut["appid"], "gameid": shortcut["gameid"],
                "exe": shortcut["exe"], "dir": shortcut["dir"], "lastPlayed": shortcut["lastPlayed"], "art": art,
                "runner": "steam", "windows": bool(WINDOWS.search(shortcut["exe"])),
            }))

    for entry in data["custom"]:
        steam = entry.pop("_steam", None)
        game_id = entry["id"]
        art = cached_art(game_id)
        if steam and root:
            art = {**art, **grid_art(root, account, steam["appid"])}
        games.append(merged({
            "id": game_id, "kind": "custom", "name": entry.get("name") or guess_name(entry.get("exe", "")),
            "exe": entry.get("exe", ""), "dir": os.path.dirname(entry.get("exe", "")), "args": entry.get("args", ""),
            "runner": entry.get("runner") or guess_runner(entry.get("exe", "")), "added": entry.get("added", 0),
            "gameid": steam["gameid"] if steam else entry.get("gameid", ""), "inSteam": bool(steam),
            "lastPlayed": max(int(entry.get("lastPlayed") or 0), int(steam["lastPlayed"]) if steam else 0),
            "art": art, "missing": not os.path.exists(entry.get("exe", "")), "windows": bool(WINDOWS.search(entry.get("exe", ""))),
        }))

    for game in games:
        game.setdefault("art", {})
        game["needsArt"] = not game["art"].get("cover") and game.get("artChoice") != "none"
    return {
        "steam": bool(root) and bool(shutil.which("steam")), "steamRunning": windows.steam_running() if root else False,
        "games": games, "runners": windows.runners()["runners"], "gridKey": bool(data.get("gridKey")),
    }


def cmd_list(_args):
    out(collect())


def cmd_art(args):
    """Fetches what is missing, a line per game that got something."""
    library = collect()["games"]
    wanted = set(args)
    todo = [game for game in library if (not wanted or game["id"] in wanted) and (game["needsArt"] or not game["art"].get("hero") or not game["art"].get("logo"))]
    with Store() as data:
        kept = data["games"]
        choices = {}
        for game in todo:
            choice = kept.get(game["id"], {}).get("art", "")
            if not choice and game["kind"] == "steam":
                choice = f"steam:{game['appid']}"
            choices[game["id"]] = choice
    now = int(time.time())

    def tried(game_id):
        with Store() as data:
            data["games"].setdefault(game_id, {})["artTried"] = now

    def work(game):
        choice = choices.get(game["id"], "")
        if choice == "none":
            return None
        # what found nothing is asked again a week later
        if not wanted and now - int(load()["games"].get(game["id"], {}).get("artTried") or 0) < 7 * 86400:
            return None
        if not choice:
            choice = auto_art(game["name"])
            with Store() as data:
                own = data["games"].setdefault(game["id"], {})
                if choice:
                    own["art"] = choice
                else:
                    own["artTried"] = now
            if not choice:
                return None
        kinds = [kind for kind in ART_KINDS if not game["art"].get(kind)]
        if not kinds:
            return None
        before = cached_art(game["id"])
        found = fetch_art(game["id"], art_urls(choice), kinds)
        if found != before:
            return {"id": game["id"], "art": {**game["art"], **found}, "artChoice": choice}
        tried(game["id"])
        return None

    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        for result in pool.map(work, todo):
            if result:
                out(result)
    out({"done": True})


def cmd_search(args):
    term = " ".join(args).strip()
    if not term:
        out({"results": []})
        return
    hits = store_search(term, 8)
    assets = store_assets([hit["appid"] for hit in hits])
    results = []
    for hit in hits:
        urls = assets.get(hit["appid"], {})
        results.append({"id": f"steam:{hit['appid']}", "name": hit["name"], "source": "Steam", **{kind: urls.get(kind, "") for kind in ART_KINDS}})
    key = sgdb_key()
    if key:
        results += sgdb_search(term, key)
    results.sort(key=lambda entry: -similarity(term, entry["name"]) if similarity(term, entry["name"]) >= 0.95 else 0)

    # the covers are fetched here, so the sheet shows them at once
    def thumb(entry):
        url = entry.get("cover") or entry.get("header")
        if not url:
            return entry
        target = FOUND / (safe(entry["id"]) + (".png" if url.lower().split("?")[0].endswith(".png") else ".jpg"))
        if (target.is_file() and target.stat().st_size > 0) or download(url, target):
            entry["preview"] = str(target)
            entry["wide"] = not entry.get("cover")
        return entry
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        results = [entry for entry in pool.map(thumb, results) if entry.get("preview")]
    out({"query": term, "results": results})


def cmd_guess(args):
    path = args[0] if args else ""
    out({"name": guess_name(path), "runner": guess_runner(path), "windows": bool(WINDOWS.search(path))})


def apply_art(game_id, choice):
    """A new art choice: the old pictures go, the new ones come."""
    drop_art(game_id)
    if choice and choice != "none":
        fetch_art(game_id, art_urls(choice))


def cmd_add(args):
    request = json.loads(args[0])
    exe = os.path.realpath(os.path.expanduser(request.get("exe", "")))
    if not os.path.isfile(exe):
        fail("That program is not there")
    with Store() as data:
        for entry in data["custom"]:
            if os.path.realpath(entry.get("exe", "")) == exe:
                game_id = entry["id"]
                entry.update({key: request[key] for key in ("name", "runner", "args") if key in request})
                break
        else:
            game_id = f"custom:{uuid.uuid4().hex[:10]}"
            data["custom"].append({
                "id": game_id, "exe": exe, "name": request.get("name") or guess_name(exe),
                "runner": request.get("runner") or guess_runner(exe), "args": request.get("args", ""), "added": int(time.time()),
            })
        if "art" in request:
            data["games"].setdefault(game_id, {})["art"] = request["art"]
    if "art" in request:
        apply_art(game_id, request["art"])
    game = next((game for game in collect()["games"] if game["id"] == game_id), None)
    out({"game": game})


def cmd_update(args):
    request = json.loads(args[0])
    game_id = request.get("id", "")
    with Store() as data:
        own = data["games"].setdefault(game_id, {})
        for key in ("favorite", "hidden"):
            if key in request:
                own[key] = bool(request[key])
        if "name" in request:
            own.pop("name", None)
        custom = next((entry for entry in data["custom"] if entry["id"] == game_id), None)
        if custom is not None:
            for key in ("name", "runner", "args"):
                if key in request:
                    custom[key] = request[key]
        elif request.get("name"):
            own["name"] = request["name"]
        if "art" in request:
            own["art"] = request["art"]
            own.pop("artTried", None)
    if "art" in request:
        apply_art(game_id, request["art"])
    game = next((game for game in collect()["games"] if game["id"] == game_id), None)
    out({"game": game})


def cmd_remove(args):
    game_id = args[0]
    with Store() as data:
        data["custom"] = [entry for entry in data["custom"] if entry["id"] != game_id]
        data["games"].pop(game_id, None)
    drop_art(game_id)
    out({"removed": game_id})


# ── playing ────────────────────────────────────────────────────────────────
def find(game_id):
    game = next((game for game in collect()["games"] if game["id"] == game_id), None)
    if not game:
        fail("That game is gone")
    return game


def steam_url(gameid):
    return f"steam://rungameid/{gameid}"


def pads():
    """How many controllers are plugged in and on (each has a joystick node)."""
    try:
        with open("/proc/bus/input/devices") as file:
            text = file.read()
    except OSError:
        return -1
    return len(re.findall(r"^H: Handlers=.*\bjs\d+", text, re.M))


def cmd_launch(args):
    game = find(args[0])
    runner = args[1] if len(args) > 1 and args[1] else game.get("runner", "")
    if game["kind"] in ("steam", "shortcut") or (runner == "steam" and game.get("gameid")):
        if not shutil.which("steam"):
            fail("Steam is not installed")
        # a closed Steam can take the controller fix for its non-Steam games on the way
        if game["kind"] != "steam" and not windows.steam_running():
            try:
                windows.pads_to_games()
            except Exception:  # noqa: BLE001 – the game starts anyway
                pass
        subprocess.Popen(["steam", steam_url(game["gameid"])], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        out({"via": "Steam", "id": game["id"], "pads": pads()})
        return
    exe = game.get("exe", "")
    if not os.path.isfile(exe):
        fail("The game's program is not there any more")
    # the game runs under a watcher that keeps its time
    watcher = subprocess.Popen([sys.executable, os.path.abspath(__file__), "_play", game["id"], runner or "auto"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    line = watcher.stdout.readline().decode("utf-8", "replace").strip()
    try:
        answer = json.loads(line)
    except ValueError:
        answer = {"error": "The game did not start"}
    if answer.get("error"):
        fail(answer["error"])
    out({"via": answer.get("via", ""), "id": game["id"], "pid": answer.get("pid"), "pads": pads()})


def cmd_play(args):
    """(the watcher) starts the game, waits for it and keeps the time it ran."""
    game_id, runner = args[0], args[1] if len(args) > 1 else "auto"
    game = find(game_id)
    exe = game["exe"]
    try:
        if game.get("windows") or runner in ("wine", "proton") or runner.startswith("proton:"):
            if runner in ("native", "steam", ""):
                runner = "auto"
            command, env, via = windows.prepare(exe, runner, prefix=safe(game_id.split(":", 1)[-1]))
        else:
            if not os.access(exe, os.X_OK) and not exe.endswith(".sh"):
                os.chmod(exe, os.stat(exe).st_mode | 0o100)
            command, env, via = ([exe] if not exe.endswith(".sh") else ["sh", exe]), windows.clean_env(), "Linux"
        if game.get("args"):
            import shlex
            command += shlex.split(game["args"])
        LOG.parent.mkdir(parents=True, exist_ok=True)
        log = open(LOG, "ab")
        log.write(f"\n=== {time.strftime('%F %T')} {game['name']}: {' '.join(command)}\n".encode())
        log.flush()
        process = subprocess.Popen(command, cwd=os.path.dirname(exe), env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    except Exception as error:  # noqa: BLE001 – any failure is the answer
        out({"error": str(error)})
        return
    RUNNING.mkdir(parents=True, exist_ok=True)
    marker = RUNNING / (safe(game_id) + ".json")
    started = int(time.time())
    marker.write_text(json.dumps({"id": game_id, "pid": os.getpid(), "started": started, "name": game["name"]}))
    out({"via": via, "pid": process.pid})
    sys.stdout.close()
    with Store() as data:
        data["games"].setdefault(game_id, {})["lastPlayed"] = started
    process.wait()
    # Proton's own wine processes may outlive the launcher; the time counts
    # until the launcher is gone, which is when the game's window closed
    minutes = max(0, int(time.time()) - started) // 60
    with Store() as data:
        own = data["games"].setdefault(game_id, {})
        own["playtime"] = int(own.get("playtime") or 0) + minutes
        own["lastPlayed"] = int(time.time())
    marker.unlink(missing_ok=True)


def cmd_running(_args):
    running = set()
    # Steam starts each game under its reaper: `reaper SteamLaunch AppId=<id> …`
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as file:
                parts = file.read().split(b"\0")
        except OSError:
            continue
        if len(parts) > 2 and parts[0].endswith(b"reaper") and b"SteamLaunch" in parts:
            for part in parts:
                if part.startswith(b"AppId="):
                    appid = part[6:].decode()
                    running.add(f"steam:{appid}")
                    running.add(f"shortcut:{appid}")
    if RUNNING.is_dir():
        for marker in RUNNING.glob("*.json"):
            try:
                entry = json.loads(marker.read_text())
                os.kill(int(entry["pid"]), 0)
                running.add(entry["id"])
            except (OSError, ValueError, KeyError):
                marker.unlink(missing_ok=True)
    # a custom game in Steam runs as its shortcut
    data = load()
    root = windows.steam_root()
    if root:
        account = windows.steam_account(root)
        exes = {os.path.realpath(entry.get("exe", "")): entry["id"] for entry in data["custom"]}
        for shortcut in shortcuts(root, account):
            own = exes.get(os.path.realpath(shortcut["exe"])) if shortcut["exe"] else None
            if own and f"shortcut:{shortcut['appid']}" in running:
                running.add(own)
    out({"running": sorted(running)})


def cmd_steam_add(args):
    game = find(args[0])
    if game["kind"] != "custom":
        fail("Only a game added here can be added to Steam")
    tools = windows.protons()
    tool = args[1] if len(args) > 1 and args[1] else ""
    if not tool and game.get("windows"):
        wanted = game.get("runner", "")
        if wanted.startswith("proton:"):
            tool = next((each["id"] for each in tools if each["path"] == wanted.split(":", 1)[1]), "")
        tool = tool or (tools[0]["id"] if tools else "")
    report = lambda text: out({"progress": text})  # noqa: E731
    try:
        result = windows.add_to_steam(game["exe"], game["name"], tool, report=report)
    except Exception as error:  # noqa: BLE001
        fail(error)
    # the pictures of here become the shortcut's in Steam
    root = windows.steam_root()
    account = windows.steam_account(root)
    grid = Path(root, "userdata", account, "config/grid")
    grid.mkdir(parents=True, exist_ok=True)
    appid = result["appid"]
    for kind, stem in (("cover", f"{appid}p"), ("hero", f"{appid}_hero"), ("logo", f"{appid}_logo"), ("header", f"{appid}")):
        source = game["art"].get(kind)
        if source and os.path.isfile(source):
            shutil.copyfile(source, grid / (stem + Path(source).suffix))
    with Store() as data:
        for entry in data["custom"]:
            if entry["id"] == game["id"]:
                entry["runner"] = "steam"
    out({"done": True, "gameid": result["gameid"], "restarted": result.get("restarted", False)})


def cmd_steam_pads(_args):
    report = lambda text: out({"progress": text})  # noqa: E731
    try:
        result = windows.pads_to_games(report=report)
    except Exception as error:  # noqa: BLE001
        fail(error)
    out({"done": True, **result})


def cmd_key(args):
    if not args:
        out({"key": bool(load().get("gridKey"))})
        return
    key = args[0].strip()
    if not shutil.which("secret-tool"):
        fail("secret-tool is not installed")
    if not key:
        subprocess.run(["secret-tool", "clear", "service", "pshell-steamgriddb"], timeout=5)
        with Store() as data:
            data["gridKey"] = False
        out({"key": False})
        return
    try:
        sgdb("search/autocomplete/portal", key)
    except Exception:
        fail("SteamGridDB does not take that key")
    subprocess.run(["secret-tool", "store", "--label", "Pshell SteamGridDB", "service", "pshell-steamgriddb"], input=key, text=True, timeout=10, check=True)
    with Store() as data:
        data["gridKey"] = True
    out({"key": True})


COMMANDS = {
    "list": cmd_list, "art": cmd_art, "search": cmd_search, "guess": cmd_guess, "add": cmd_add, "update": cmd_update,
    "remove": cmd_remove, "launch": cmd_launch, "_play": cmd_play, "running": cmd_running, "steam-add": cmd_steam_add,
    "steam-pads": cmd_steam_pads, "key": cmd_key,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(2)
    try:
        COMMANDS[sys.argv[1]](sys.argv[2:])
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 – the shell gets the reason
        fail(error)


if __name__ == "__main__":
    main()
