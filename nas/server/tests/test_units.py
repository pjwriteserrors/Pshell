"""Small checks of the parts that decide safety: paths, passwords, TOTP,
face grouping. `python3 tests/test_units.py` (or pytest)."""
import base64
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pshell_nas import auth  # noqa: E402
from pshell_nas.areas import Areas, PathError, clean, unique  # noqa: E402


def test_paths():
    root = Path(tempfile.mkdtemp())
    (root / "data" / "a").mkdir(parents=True)
    (root / "vault").mkdir()
    (root / "outside").mkdir()
    os.symlink(root / "outside", root / "data" / "out")
    areas = Areas({"/": root / "data", "/Obsidian": root / "vault"})
    assert clean("a//b/./c/") == "/a/b/c"
    for bad in ("/a/../..", "../x", "/a/\0"):
        try:
            clean(bad)
            raise AssertionError(bad)
        except PathError:
            pass
    assert areas.real("/a") == str(root / "data" / "a")
    assert areas.real("/Obsidian/n.md") == str(root / "vault" / "n.md")
    assert areas.nas(str(root / "vault" / "x")) == "/Obsidian/x"
    try:
        areas.real("/out/secret")
        raise AssertionError("symlink out of the area")
    except PathError as error:
        assert error.status == 403
    assert areas.children("/") == ["/Obsidian"]
    (root / "data" / "f.txt").write_text("x")
    assert unique(str(root / "data" / "f.txt")).endswith("f (2).txt")


def test_passwords_and_totp():
    stored = auth.hash_password("secret", n=2 ** 10)
    assert auth.check_password("secret", stored) and not auth.check_password("Secret", stored)
    secret = auth.totp_secret()
    now = time.time()
    code = auth.totp_at(secret, int(now // 30))
    assert auth.totp_ok(secret, code, now) and not auth.totp_ok(secret, "000000" if code != "000000" else "111111", now)
    # RFC 6238 test vector (sha1, 8 digits there; the last 6 here)
    rfc = base64.b32encode(b"12345678901234567890").decode()
    assert auth.totp_at(rfc, 59 // 30) == "287082"


def test_faces_grouping():
    import numpy
    from pshell_nas.db import Db
    from pshell_nas.photos import add_faces

    class Nas:
        pass
    nas = Nas()
    nas.db = Db(Path(tempfile.mkdtemp()) / "nas.db")
    rng = numpy.random.default_rng(1)
    anna, ben = rng.normal(size=128), rng.normal(size=128)

    def face(base):
        vector = (base + rng.normal(scale=0.2, size=128)).astype(numpy.float32)
        return {"box": [0, 0, 0.1, 0.1], "vec": base64.b64encode(vector.tobytes()).decode()}
    for number in range(4):
        nas.db.run("INSERT INTO photos(path) VALUES (?)", f"/p{number}.jpg")
        add_faces(nas, {f"/p{number}.jpg": [face(anna), face(ben)]})
    people = nas.db.all("SELECT id, count FROM people ORDER BY id")
    assert [person["count"] for person in people] == [4, 4], people


if __name__ == "__main__":
    test_paths()
    test_passwords_and_totp()
    test_faces_grouping()
    print("all good")
