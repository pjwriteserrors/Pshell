#!/usr/bin/python3
"""The AppImage installer's helper against AppImages made here: no desktop,
no network, a home of its own.

  python3 -m unittest scripts/tests/test_appimage.py

Each AppImage is a little ELF header with the AppImage magic and a squashfs
(mksquashfs) after its section headers, as a real one has; nothing runs it.
"""

import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
TEMP = Path(tempfile.mkdtemp(prefix="appimage-test-"))
HOME = TEMP / "home"
HOME.mkdir()
os.environ["HOME"] = str(HOME)
os.environ["XDG_DATA_HOME"] = str(HOME / ".local/share")
os.environ["XDG_CACHE_HOME"] = str(HOME / ".cache")
os.environ["XDG_STATE_HOME"] = str(HOME / ".local/state")
os.environ.pop("PSHELL_APPIMAGE_DIR", None)
os.environ.pop("PSHELL_APPIMAGE_BIN", None)
sys.path.insert(0, str(SCRIPTS / "appimage"))

import appimage  # noqa: E402

PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                    "1f15c4890000000d49444154789c6360f8cfc0f01f0005000201e2213cba0000000049454e44ae426082")


def make_appimage(path, name="Hello World", desktop="org.example.Hello", exec_line="hello %U", icon=True, magic=True, metainfo=True):
    root = TEMP / f"root-{Path(path).stem}"
    shutil.rmtree(root, ignore_errors=True)
    (root / "usr/bin").mkdir(parents=True)
    (root / "AppRun").write_text("#!/bin/sh\necho hello \"$@\"\n")
    (root / "AppRun").chmod(0o755)
    (root / "usr/bin/hello").write_text("#!/bin/sh\necho hi\n")
    entry = f"[Desktop Entry]\nType=Application\nName={name}\nName[de]=Hallo Welt\nComment=Says hello\nExec={exec_line}\n" \
            f"Icon={desktop}\nCategories=Utility;\nStartupWMClass=hello-world\nActions=New;\n\n" \
            f"[Desktop Action New]\nName=New window\nExec={exec_line.split()[0]} --new\n"
    (root / f"{desktop}.desktop").write_text(entry)
    if icon:
        (root / f"{desktop}.png").write_bytes(PNG)
        (root / ".DirIcon").symlink_to(f"{desktop}.png")
    if metainfo:
        (root / "usr/share/metainfo").mkdir(parents=True)
        (root / "usr/share/metainfo" / f"{desktop}.metainfo.xml").write_text(
            f"<component><id>{desktop}</id><summary>A friendly greeter</summary><developer_name>Example</developer_name>"
            "<description><p>It greets.</p><ul><li>Loudly</li></ul></description>"
            "<releases><release version=\"2.4.1\"/></releases></component>")
    squash = TEMP / f"{Path(path).stem}.squashfs"
    squash.unlink(missing_ok=True)
    subprocess.run(["mksquashfs", str(root), str(squash), "-quiet", "-no-progress", "-all-root"], check=True, capture_output=True)
    # an ELF64 header whose section headers end at 4096: there the squashfs starts
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2
    header[5] = 1
    if magic:
        header[8:11] = b"AI\x02"
    struct.pack_into("<Q", header, 0x28, 4096 - 64)
    struct.pack_into("<HH", header, 0x3A, 64, 1)
    with open(path, "wb") as file:
        file.write(bytes(header).ljust(4096, b"\0"))
        file.write(squash.read_bytes())
    return Path(path)


def steps(app):
    return app


class AppImageTest(unittest.TestCase):
    def setUp(self):
        for folder in ("Downloads", "Applications", ".local", ".config", ".cache"):
            shutil.rmtree(HOME / folder, ignore_errors=True)
        (HOME / "Downloads").mkdir()

    def test_inspect(self):
        file = make_appimage(HOME / "Downloads/Hello_World-2.4.1-x86_64.AppImage")
        data = appimage.look(file)
        self.assertEqual(data["type"], 2)
        self.assertEqual(data["id"], "org.example.Hello")
        self.assertEqual(data["name"], "Hello World")
        self.assertEqual(data["version"], "2.4.1")
        self.assertEqual(data["summary"], "A friendly greeter")
        self.assertIn("• Loudly", data["description"])
        self.assertEqual(data["command"], "hello")
        self.assertTrue(data["icon"].endswith(".png"))
        self.assertEqual(Path(data["icon"]).read_bytes(), PNG)
        # nothing of the image is kept but what is needed
        self.assertFalse((Path(data["work"]) / "root").exists())

    def test_without_magic_and_icon(self):
        file = make_appimage(HOME / "Downloads/plain.AppImage", icon=False, magic=False, metainfo=False, exec_line="AppRun")
        data = appimage.look(file)
        self.assertEqual(data["type"], 2)
        self.assertEqual(data["icon"], "")
        # AppRun is nobody's command name: the entry's last word instead
        self.assertEqual(data["command"], "hello")

    def test_not_an_appimage(self):
        file = HOME / "Downloads/fake.AppImage"
        file.write_bytes(b"not an elf at all")
        with self.assertRaises(RuntimeError):
            appimage.look(file)

    def test_install_and_remove(self):
        file = make_appimage(HOME / "Downloads/Hello_World-2.4.1-x86_64.AppImage")
        app = appimage.install(file, command="hello-world")
        target = Path(app["file"])
        self.assertEqual(target, HOME / "Applications/org.example.Hello.AppImage")
        self.assertTrue(target.exists() and os.access(target, os.X_OK))
        # moved, not copied
        self.assertFalse(file.exists())
        entry = (HOME / ".local/share/applications/org.example.Hello.desktop").read_text()
        self.assertIn(f"Exec={target} %U", entry)
        self.assertIn(f"Exec={target} --new", entry)
        self.assertIn("X-Pshell-AppImage=org.example.Hello", entry)
        self.assertIn("Icon=" + str(HOME / ".local/share/pshell/appimages/icons/org.example.Hello/org.example.Hello.png"), entry)
        self.assertNotIn("Name[de]", entry)
        command = HOME / ".local/bin/hello-world"
        self.assertIn("# pshell-appimage org.example.Hello", command.read_text())
        self.assertEqual(appimage.check_command("hello-world", "org.example.Hello")["reason"], "same")
        self.assertFalse(appimage.check_command("hello-world", "other")["ok"])

        listed = appimage.list_all()
        self.assertEqual([item["id"] for item in listed["installed"]], ["org.example.Hello"])
        self.assertTrue(listed["installed"][0]["commandPresent"])

        # what it wrote: settings and a cache, found by its names
        (HOME / ".config/hello-world").mkdir(parents=True)
        (HOME / ".config/hello-world/settings.json").write_text("{}")
        (HOME / ".cache/org.example.Hello").mkdir(parents=True)
        (HOME / ".config/unrelated").mkdir(parents=True)
        found = appimage.leftovers("org.example.Hello")
        kinds = sorted(item["kind"] for item in found["items"])
        self.assertEqual(kinds, ["app", "cache", "command", "entry", "icon", "settings"])
        data = [item["path"] for item in found["items"] if not item["fixed"]]
        result = appimage.remove("org.example.Hello", data=data)
        self.assertEqual(result["failed"], [])
        for path in (target, command, HOME / ".config/hello-world", HOME / ".cache/org.example.Hello",
                     HOME / ".local/share/applications/org.example.Hello.desktop"):
            self.assertFalse(path.exists(), path)
        self.assertTrue((HOME / ".config/unrelated").exists())
        self.assertEqual(appimage.load_state(), {})

    def test_unpacked_and_update(self):
        file = make_appimage(HOME / "Downloads/hello.AppImage")
        app = appimage.install(file, command="hello", mode="unpacked", keep=True)
        self.assertTrue(file.exists())
        self.assertTrue((Path(app["file"]) / "AppRun").exists())
        self.assertIn("AppRun", (HOME / ".local/bin/hello").read_text())
        # installed again as one file: the folder goes, the command follows
        again = appimage.install(file, command="hi")
        self.assertTrue(again["updated"])
        self.assertFalse((HOME / "Applications/org.example.Hello").exists())
        self.assertFalse((HOME / ".local/bin/hello").exists())
        self.assertTrue((HOME / ".local/bin/hi").exists())

    def test_taken_command(self):
        (HOME / ".local/bin").mkdir(parents=True)
        (HOME / ".local/bin/mine").write_text("#!/bin/sh\n")
        self.assertEqual(appimage.check_command("mine")["reason"], "taken")
        self.assertEqual(appimage.check_command("ls")["reason"], "taken")
        self.assertEqual(appimage.check_command("bad name")["reason"], "invalid")
        file = make_appimage(HOME / "Downloads/hello.AppImage")
        with self.assertRaises(RuntimeError):
            appimage.install(file, command="mine")
        self.assertEqual((HOME / ".local/bin/mine").read_text(), "#!/bin/sh\n")

    def test_foreign_and_loose(self):
        other = HOME / "AppImages/Thing.AppImage"
        other.parent.mkdir()
        make_appimage(other, desktop="org.example.Thing")
        apps = HOME / ".local/share/applications"
        apps.mkdir(parents=True)
        (apps / "appimagekit-thing.desktop").write_text(f"[Desktop Entry]\nType=Application\nName=Thing\nExec={other} %U\nIcon=appimagekit-thing\n")
        icon = HOME / ".local/share/icons/hicolor/256x256/apps/appimagekit-thing.png"
        icon.parent.mkdir(parents=True)
        icon.write_bytes(PNG)
        make_appimage(HOME / "Downloads/Loose-1.0.AppImage", desktop="org.example.Loose")
        # a copy of an installed one is not listed again
        installed = make_appimage(HOME / "Downloads/Hello-2.4.1.AppImage")
        appimage.install(installed, keep=True)
        listed = appimage.list_all()
        self.assertEqual([item["name"] for item in listed["foreign"]], ["Thing"])
        self.assertEqual([item["name"] for item in listed["loose"]], ["Hello World"])
        self.assertTrue(listed["loose"][0]["icon"].endswith(".png"))
        (HOME / ".config/Thing").mkdir(parents=True)
        found = appimage.leftovers(str(other))
        self.assertEqual(sorted(item["kind"] for item in found["items"]), ["app", "entry", "icon", "settings"])
        appimage.remove(str(other), data=[str(HOME / ".config/Thing")])
        self.assertFalse(other.exists() or icon.exists() or (apps / "appimagekit-thing.desktop").exists())
        self.assertFalse((HOME / ".config/Thing").exists())

    def test_take_over(self):
        other = HOME / "AppImages/Thing.AppImage"
        other.parent.mkdir(exist_ok=True)
        make_appimage(other, desktop="org.example.Thing")
        apps = HOME / ".local/share/applications"
        apps.mkdir(parents=True)
        (apps / "appimagekit-thing.desktop").write_text(f"[Desktop Entry]\nType=Application\nName=Thing\nExec={other} %U\n")
        appimage.install(other)
        self.assertFalse((apps / "appimagekit-thing.desktop").exists())
        listed = appimage.list_all()
        self.assertEqual(listed["foreign"], [])
        self.assertEqual([item["id"] for item in listed["installed"]], ["org.example.Thing"])

    def test_data_outside_is_refused(self):
        file = make_appimage(HOME / "Downloads/hello.AppImage")
        appimage.install(file)
        keep = HOME / "Documents"
        keep.mkdir(exist_ok=True)
        result = appimage.remove("org.example.Hello", data=[str(keep), str(HOME / ".config")])
        self.assertTrue(keep.exists())
        self.assertEqual(len(result["failed"]), 2)

    def test_exec_rewrite(self):
        self.assertEqual(appimage.rewrite_exec("env A=1 AppRun --no-sandbox %U", "/x y/a.AppImage"), 'env A=1 "/x y/a.AppImage" --no-sandbox %U')
        self.assertEqual(appimage.exec_binary('"/opt/my app/run" %f'), "/opt/my app/run")

    def test_cli_install_prints_steps(self):
        file = make_appimage(HOME / "Downloads/hello.AppImage")
        out = subprocess.run([sys.executable, str(SCRIPTS / "appimage/appimage.py"), "install", str(file), "--keep", "--command", "hey"],
                             capture_output=True, text=True, env=os.environ)
        lines = [json.loads(line) for line in out.stdout.splitlines()]
        self.assertEqual([line["step"] for line in lines if "step" in line and line.get("progress") == 1][:1], ["check"])
        self.assertIn("done", lines[-1])
        self.assertEqual(lines[-1]["done"]["command"], "hey")


class UpdateTest(unittest.TestCase):
    """A plain link served from here: fetched, installed, checked, updated."""

    @classmethod
    def setUpClass(cls):
        import functools
        import http.server
        import threading
        cls.www = TEMP / "www"
        cls.www.mkdir(exist_ok=True)
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass
        handler = functools.partial(Quiet, directory=str(cls.www))
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        for folder in ("Applications", ".local", ".cache"):
            shutil.rmtree(HOME / folder, ignore_errors=True)

    def test_link_check_update(self):
        make_appimage(self.www / "Hello.AppImage")
        fetched = appimage.fetch(f"{self.base}/Hello.AppImage")
        self.assertEqual(fetched["origin"]["kind"], "url")
        self.assertEqual(fetched["look"]["name"], "Hello World")
        appimage.install(fetched["fetched"], command="hello", origin=fetched["origin"])
        self.assertEqual(appimage.check()["updates"], [])
        # the server has a new one: other length, other date
        import time as clock
        clock.sleep(1.1)
        make_appimage(self.www / "Hello.AppImage", name="Hello World", exec_line="hello --two %U")
        with open(self.www / "Hello.AppImage", "ab") as file:
            file.write(b"\0" * 4096)
        found = appimage.check()
        self.assertEqual([entry["id"] for entry in found["updates"]], ["org.example.Hello"])
        new = appimage.update("org.example.Hello")
        self.assertEqual(new["command"], "hello")
        self.assertIn("--two", (HOME / ".local/share/applications/org.example.Hello.desktop").read_text())
        self.assertEqual(appimage.check()["updates"], [])

    def test_not_an_appimage_link(self):
        (self.www / "page.html").write_text("<html></html>")
        with self.assertRaises(RuntimeError):
            appimage.fetch(f"{self.base}/page.html")

    def test_github_links(self):
        origin = appimage.origin_from_url("https://github.com/o/r/releases/download/v1.2.3/App-1.2.3-x86_64.AppImage")
        self.assertEqual((origin["kind"], origin["owner"], origin["repo"], origin["pattern"]), ("github", "o", "r", "App-*-x86_64.AppImage"))
        self.assertEqual(appimage.origin_from_url("https://github.com/o/r")["pattern"], "")
        self.assertEqual(appimage.origin_from_info("gh-releases-zsync|o|r|latest|A-*.AppImage.zsync")["pattern"], "A-*.AppImage")
        self.assertTrue(appimage.newer("1.10.0", "1.9.9"))
        self.assertTrue(appimage.newer("2.0", "2.0-beta3"))
        self.assertFalse(appimage.newer("1.2", "1.2"))


def tearDownModule():
    shutil.rmtree(TEMP, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
