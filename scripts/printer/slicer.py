"""Slicing in the shell: OrcaSlicer's presets and its command line.

The presets are Orca's own – the system ones it ships and the user's in
~/.config/OrcaSlicer/user/default – so a profile made or imported here is
there in Orca too, and the other way round. A preset only names what it
changes against its parent (`inherits`); the command line wants them
whole, so `Presets.flat()` walks the chain. The machine is the one Orca
has selected (its printer for this printer); a process or filament made for
another machine is turned into one for it: whole, then said to inherit from
the machine's own system preset, which is what Orca's compatibility check
looks at.

`slice()` runs `orca-slicer` on a model (STL, 3MF, OBJ, STEP) in a data
folder of its own (Orca's config is never written to) and returns the
G-code of each plate. Value options need `--opt=value`: with a space,
`--allow-newer-file 1` takes the 1 for the model.
"""

import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import zipfile

USER = os.path.expanduser("~/.config/OrcaSlicer/user/default")
CONF = os.path.expanduser("~/.config/OrcaSlicer/OrcaSlicer.conf")
MODELS = (".stl", ".3mf", ".obj", ".step", ".stp")
PROFILES = (".json", ".orca_printer", ".orca_filament", ".bbscfg", ".bbsflmt", ".zip")
# Orca's plates, by the index its config keeps
BEDS = ["Default Plate", "Cool Plate", "Engineering Plate", "High Temp Plate", "Textured PEI Plate", "Textured Cool Plate", "Supertack Plate"]
# the materials of the system's filament presets, longest first so "PLA Silk" wins over "PLA"
MATERIALS = ["PLA High Speed", "PLA Silk", "PLA+", "PLA", "PETG", "ABS", "ASA", "TPU", "PA6-CF", "PAHT-CF", "PC-CF", "PC-GF", "PA", "PC", "PEBA"]


def executable():
    return shutil.which("orca-slicer") or shutil.which("OrcaSlicer") or ""


def resources():
    """Orca's shipped profiles, wherever the package put them."""
    found = executable()
    candidates = []
    if found:
        base = os.path.dirname(os.path.realpath(found))
        candidates += [os.path.join(base, "resources", "profiles"), os.path.join(base, "..", "resources", "profiles"),
                       os.path.join(base, "..", "share", "OrcaSlicer", "resources", "profiles")]
    candidates += ["/opt/orca-slicer/resources/profiles", "/usr/share/OrcaSlicer/resources/profiles", "/usr/share/orca-slicer/resources/profiles"]
    for path in candidates:
        if os.path.isdir(path):
            return os.path.realpath(path)
    return ""


def _load(path):
    try:
        with open(path) as source:
            return json.load(source)
    except (OSError, ValueError):
        return None


def _first(value):
    return (value[0] if value else "") if isinstance(value, list) else (value or "")


def material_of(text):
    """The material a filament is sliced as: "PLA Matte" is PLA."""
    upper = str(text or "PLA").upper()
    return next((known for known in MATERIALS if upper.startswith(known.upper())), "PLA")


def user_stamp():
    """Changes whenever a preset of the user's is saved, made or removed."""
    stamp = []
    for kind in ("process", "filament", "machine"):
        for path in sorted(glob.glob(os.path.join(USER, kind, "*.json"))):
            try:
                stamp.append((path, os.stat(path).st_mtime_ns))
            except OSError:
                continue
    return stamp


class Presets:
    def __init__(self):
        self.root = resources()
        self.vendors = {}  # vendor → {name: path}
        for index in glob.glob(os.path.join(self.root, "*.json")):
            data = _load(index)
            if not isinstance(data, dict):
                continue
            vendor = os.path.basename(index)[:-5]
            names = {}
            for key in ("process_list", "filament_list", "machine_list", "machine_model_list"):
                for entry in data.get(key, []):
                    names[entry["name"]] = os.path.join(self.root, vendor, entry["sub_path"])
            self.vendors[vendor] = names
        conf = _load(CONF) or {}
        self.machine_name = (conf.get("presets") or {}).get("machine") or "Anycubic Kobra S1 0.4 nozzle"
        # what Orca last used with this printer
        used = next((entry for entry in conf.get("orca_presets") or [] if entry.get("machine") == self.machine_name), {})
        self.process = used.get("process", "")
        self.filament = used.get("filament", "")
        try:
            self.bed = BEDS[int(used.get("curr_bed_type") or (conf.get("app") or {}).get("curr_bed_type", 3))]
        except (ValueError, IndexError):
            self.bed = "High Temp Plate"

    # ── the inheritance ──────────────────────────────────────────────────
    def _vendor_of(self, path):
        if self.root and path.startswith(self.root + os.sep):
            return path[len(self.root) + 1:].split(os.sep)[0]
        return None

    def find(self, name, vendor=None, kind=None):
        """The file of a preset by name: the user's first, then the system's."""
        if kind:
            user = os.path.join(USER, kind, f"{name}.json")
            if os.path.exists(user):
                return user
        for candidate in ([vendor] if vendor else []) + ["OrcaFilamentLibrary"] + list(self.vendors):
            if candidate in self.vendors and name in self.vendors[candidate]:
                return self.vendors[candidate][name]
        return None

    def chain(self, path):
        """The preset and its parents, the preset first."""
        out = []
        vendor = self._vendor_of(path)
        while path and len(out) < 20:
            data = _load(path) or {}
            out.append((path, data))
            parent = data.get("inherits")
            if not parent:
                break
            kind = os.path.basename(os.path.dirname(path))
            path = self.find(parent, vendor, kind if kind in ("process", "filament", "machine") else None)
            vendor = self._vendor_of(path) if path else vendor
        return out

    def flat(self, path):
        merged = {}
        for _path, data in reversed(self.chain(path)):
            merged.update(data)
        merged.pop("inherits", None)
        return merged

    def system_root(self, path):
        """The nearest system preset in a chain (what Orca checks against)."""
        for item, data in self.chain(path):
            if data.get("from") == "system" or (self.root and item.startswith(self.root)):
                if str(data.get("instantiation", "true")) == "true":
                    return data.get("name")
        return None

    def machine_path(self):
        return self.find(self.machine_name, kind="machine") or self.find("Anycubic Kobra S1 0.4 nozzle")

    def machine_system(self):
        return self.system_root(self.machine_path()) or "Anycubic Kobra S1 0.4 nozzle"

    # ── what there is ────────────────────────────────────────────────────
    def processes(self):
        """[{name, layer, user, fits}] – the user's first, those for this machine before the others."""
        system_machine = self.machine_system()
        out = []
        for path in sorted(glob.glob(os.path.join(USER, "process", "*.json"))):
            data = _load(path) or {}
            whole = self.flat(path)
            fits = system_machine in (whole.get("compatible_printers") or []) or not whole.get("compatible_printers")
            out.append({"name": data.get("name") or os.path.basename(path)[:-5], "layer": whole.get("layer_height", ""),
                        "user": True, "fits": fits, "made": (whole.get("compatible_printers") or [""])[0]})
        for vendor, names in self.vendors.items():
            for name, path in names.items():
                if os.path.basename(os.path.dirname(path)) != "process":
                    continue
                data = _load(path) or {}
                if str(data.get("instantiation", "true")) != "true":
                    continue
                if system_machine in (data.get("compatible_printers") or []):
                    out.append({"name": name, "layer": self.flat(path).get("layer_height", ""), "user": False, "fits": True, "made": system_machine})
        out.sort(key=lambda p: (not p["fits"], not p["user"], p["name"]))
        return out

    def filaments(self):
        """[{name, type, user}] – the filament presets for this machine, the user's first."""
        system_machine = self.machine_system()
        out = []
        for path in sorted(glob.glob(os.path.join(USER, "filament", "*.json"))):
            data = _load(path) or {}
            whole = self.flat(path)
            if (whole.get("compatible_printers") or []) and system_machine not in whole["compatible_printers"]:
                continue
            out.append({"name": data.get("name") or os.path.basename(path)[:-5], "type": _first(whole.get("filament_type")), "user": True})
        for vendor in ("Anycubic", "OrcaFilamentLibrary"):
            for name, path in self.vendors.get(vendor, {}).items():
                if os.path.basename(os.path.dirname(path)) == "filament" and name.endswith(f"@{system_machine}"):
                    out.append({"name": name, "type": _first(self.flat(path).get("filament_type")), "user": False})
        out.sort(key=lambda f: (not f["user"], f["name"]))
        return out

    def filament_for(self, material, chosen=""):
        """The filament preset a material is sliced with: the one chosen, else the one Orca
        last used with this printer – each only when it is of that material – else the
        system's for this machine ("PLA Matte" → PLA)."""
        system_machine = self.machine_system()
        wanted = material_of(material)
        for name in (chosen, self.filament):
            path = self.find(name, kind="filament") if name else None
            if path and material_of(_first(self.flat(path).get("filament_type"))) == wanted:
                return path
        for vendor in ("Anycubic", "OrcaFilamentLibrary"):
            for name, path in self.vendors.get(vendor, {}).items():
                if name.startswith(f"Anycubic {wanted} @") and system_machine in name:
                    return path
        for vendor, names in self.vendors.items():
            for name, path in names.items():
                if name.startswith("Anycubic PLA @") and system_machine in name:
                    return path
        return self.find("Generic PLA") or ""

    # ── writing a set for the command line ───────────────────────────────
    def build_set(self, process, filaments, overrides, chosen=""):
        """(machine, process, [filament]) as the command line gets them."""
        system_machine = self.machine_system()
        machine = self.flat(self.machine_path())
        machine.update({"inherits": system_machine, "from": "User", "type": "machine"})

        process_path = self.find(process, kind="process")
        if not process_path:
            raise ValueError(f"no profile named {process}")
        whole = self.flat(process_path)
        base = next((p["name"] for p in self.processes() if not p["user"]), None)
        whole.update({"inherits": self.system_root(process_path) if whole.get("compatible_printers") and system_machine in whole["compatible_printers"] else (base or ""),
                      "from": "User", "type": "process", "compatible_printers": [system_machine], "compatible_printers_condition": ""})
        whole.update({key: value for key, value in overrides.items() if value is not None})

        out = []
        for filament in filaments:
            source = self.filament_for(filament.get("type"), chosen)
            data = self.flat(source)
            colour = "#" + "".join(f"{int(c):02X}" for c in (filament.get("color") or [200, 200, 200])[:3])
            data.update({"inherits": self.system_root(source) or "", "from": "User", "type": "filament",
                         "compatible_printers": [system_machine], "compatible_printers_condition": "",
                         "filament_colour": [colour], "default_filament_colour": [colour]})
            out.append(data)
        return machine, whole, out

    def write_set(self, folder, process, filaments, overrides, chosen=""):
        """machine.json, process.json, filament-N.json in folder; returns their paths."""
        os.makedirs(folder, exist_ok=True)
        machine, whole, datas = self.build_set(process, filaments, overrides, chosen)
        paths = {"machine": os.path.join(folder, "machine.json"), "process": os.path.join(folder, "process.json"), "filaments": []}
        for path, data in ((paths["machine"], machine), (paths["process"], whole)):
            with open(path, "w") as target:
                json.dump(data, target, indent=1)
        for index, data in enumerate(datas):
            path = os.path.join(folder, f"filament-{index}.json")
            with open(path, "w") as target:
                json.dump(data, target, indent=1)
            paths["filaments"].append(path)
        return paths

    # ── importing ────────────────────────────────────────────────────────
    def import_file(self, path):
        """A preset (.json) or a bundle (.orca_printer, .orca_filament, .bbscfg, .bbsflmt, .zip) into
        Orca's user folder; returns [(kind, name)]. A machine preset is left out: the machine is Orca's."""
        found = []
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as bundle:
                for member in bundle.namelist():
                    if member.endswith(".json") and not member.endswith("bundle_structure.json"):
                        try:
                            found.append(json.loads(bundle.read(member)))
                        except ValueError:
                            continue
        else:
            data = _load(path)
            if isinstance(data, dict):
                found.append(data)
        out = []
        for data in found:
            kind = data.get("type") or ("process" if "print_settings_id" in data or "layer_height" in data else
                                        ("filament" if "filament_settings_id" in data or "filament_type" in data else ""))
            name = data.get("name") or data.get("print_settings_id") or data.get("filament_settings_id")
            if isinstance(name, list):
                name = name[0] if name else ""
            if kind not in ("process", "filament") or not name:
                continue
            name = re.sub(r"[/\\]", "-", str(name))
            data["name"] = name
            data["from"] = "User"
            folder = os.path.join(USER, kind)
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, f"{name}.json"), "w") as target:
                json.dump(data, target, indent=4)
            out.append((kind, name))
        return out


def model_filaments(path):
    """The filaments a model brings: a 3MF names its colours and materials; anything else has one."""
    if path.lower().endswith(".3mf") and zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path) as project:
                names = project.namelist()
                if "Metadata/project_settings.config" in names:
                    data = json.loads(project.read("Metadata/project_settings.config"))
                    colours = data.get("filament_colour") or []
                    types = data.get("filament_type") or []
                    out = []
                    for index, colour in enumerate(colours):
                        text = str(colour).lstrip("#")
                        rgb = [int(text[i:i + 2], 16) for i in (0, 2, 4)] if len(text) >= 6 else [200, 200, 200]
                        out.append({"tool": index, "color": rgb, "type": types[index] if index < len(types) else "PLA"})
                    if out:
                        return out
        except (OSError, ValueError, KeyError, zipfile.BadZipFile):
            pass
    return [{"tool": 0, "color": [220, 220, 220], "type": "PLA"}]


def sliced_plates(path, folder):
    """The G-code of each plate in a sliced 3MF (Orca's "export plate sliced file")."""
    out = []
    with zipfile.ZipFile(path) as project:
        for member in sorted(project.namelist()):
            match = re.fullmatch(r"Metadata/plate_(\d+)\.gcode", member)
            if match:
                target = os.path.join(folder, f"plate_{match.group(1)}.gcode")
                with project.open(member) as source, open(target, "wb") as sink:
                    shutil.copyfileobj(source, sink)
                out.append(target)
    return out


def _overrides(presets, options):
    return {
        "curr_bed_type": options.get("bed") or presets.bed,
        "enable_support": None if options.get("supports") is None else ("1" if options.get("supports") else "0"),
        "sparse_infill_density": None if not options.get("infill") else f"{int(options['infill'])}%",
        "brim_type": None if options.get("brim") is None else ("auto_brim" if options.get("brim") else "no_brim"),
    }


def signature(presets, process, filaments, options):
    """What the presets make of these settings, as a short hash: another one after
    a preset was saved in Orca means the slice is old. The colours are left out
    (another colour only paints the part)."""
    plain = [dict(filament, color=None) for filament in filaments]
    try:
        made = presets.build_set(process, plain, _overrides(presets, options), options.get("filament") or "")
    except ValueError:
        return ""
    return hashlib.sha1(json.dumps(made, sort_keys=True).encode()).hexdigest()[:16]


def slice_model(presets, model, folder, process, filaments, options):
    """Slices a model into folder/plate_N.gcode; returns (plates, error)."""
    work = tempfile.mkdtemp(prefix="pshell-slice-")
    try:
        paths = presets.write_set(os.path.join(work, "set"), process, filaments, _overrides(presets, options), options.get("filament") or "")
        out = os.path.join(work, "out")
        os.makedirs(out)
        command = [executable(), f"--datadir={os.path.join(work, 'data')}", "--allow-newer-file=1",
                   f"--load-settings={paths['machine']};{paths['process']}",
                   f"--load-filaments={';'.join(paths['filaments'])}", "--load-defaultfila=1",
                   f"--arrange={1 if options.get('arrange', True) else 0}",
                   f"--orient={1 if options.get('orient') else 0}",
                   "--slice=0", f"--outputdir={out}", model]
        # in its own folder: the slicer leaves logs (00000.log) where it runs
        run = subprocess.run(command, capture_output=True, text=True, timeout=900, cwd=work, env=dict(os.environ, LC_ALL="C"))
        result = _load(os.path.join(out, "result.json")) or {}
        plates = sorted(glob.glob(os.path.join(out, "plate_*.gcode")), key=lambda p: int(re.findall(r"\d+", os.path.basename(p))[0]))
        if not plates:
            message = result.get("error_string") or (run.stderr or run.stdout or "").strip().splitlines()[-1:] or ["slicing failed"]
            return [], message if isinstance(message, str) else message[0]
        os.makedirs(folder, exist_ok=True)
        for old in glob.glob(os.path.join(folder, "plate_*.gcode")):
            os.remove(old)
        kept = []
        for plate in plates:
            target = os.path.join(folder, os.path.basename(plate))
            shutil.move(plate, target)
            kept.append(target)
        return kept, ""
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return [], str(error)
    finally:
        shutil.rmtree(work, ignore_errors=True)
