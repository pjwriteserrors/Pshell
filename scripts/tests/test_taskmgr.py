#!/usr/bin/env python3
"""The task manager's daemon on a made-up process table: naming, grouping into
apps, the shell, terminal tabs and containers, and the rows the window gets.
Reads nothing of the running system except what Procs() looks at on start."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "taskmgr"))
import procs as P  # noqa: E402


def proc(table, pid, ppid, comm, cmd, unit, uid=None, cpu=0.0, private=0):
    p = P.Proc(pid, pid * 10)
    p.ppid = ppid
    p.comm = comm
    p.state = "S"
    p.uid = P.ME if uid is None else uid
    p.rss = private
    p.private = private
    p.threads = 1
    p.nice = 0
    p.kthread = False
    p.cmd = cmd
    p.cgroup = f"/user.slice/user-1000.slice/user@1000.service/app.slice/{unit}" if unit else ""
    p.unit = unit
    p.cpu = cpu
    p.ema = cpu
    table[pid] = p
    p.name = PROCS.pretty(p)
    return p


PROCS = P.Procs()


class Naming(unittest.TestCase):
    def test_rewritten_argv_is_split(self):
        cmd = ["chromium --change-stack-guard-on-fork=enable --no-first-run"]
        self.assertEqual(P.split_rewritten(cmd)[0], "chromium")
        self.assertEqual(P.split_rewritten(["/usr/bin/foo", "-x"]), ["/usr/bin/foo", "-x"])

    def test_interpreter_names_the_script(self):
        table = {}
        p = proc(table, 10, 1, "python3", ["/usr/bin/python3", "-u", "/x/scripts/taskmgr/daemon.py"], "")
        self.assertEqual(p.name, "taskmgr/daemon.py")
        q = proc(table, 11, 1, "python3", ["python3", "-m", "http.server"], "")
        self.assertNotEqual(q.name, "")


class Grouping(unittest.TestCase):
    def setUp(self):
        self.procs = P.Procs()
        t = self.procs.table
        # kitty with a shell in a tab scope of its own
        proc(t, 100, 1, "kitty", ["kitty"], "app-niri-kitty-100.scope", cpu=0.02, private=50 << 20)
        proc(t, 101, 100, "zsh", ["zsh"], "kitty-100-0.scope", cpu=0.0, private=5 << 20)
        proc(t, 102, 101, "make", ["make", "-j8"], "kitty-100-0.scope", cpu=0.4, private=20 << 20)
        # a container's scope
        proc(t, 200, 1, "node", ["node", "server.js"], "docker-0123456789abcdef0123.scope", cpu=0.1)
        # a user service
        proc(t, 300, 1, "pipewire", ["/usr/bin/pipewire"], "pipewire.service")
        self.procs.set_windows([{"id": 7, "pid": 100, "appId": "kitty", "title": "zsh"}])
        self.procs.build_groups()

    def test_window_app_takes_its_tabs(self):
        app = self.procs.groups["app:kitty"]
        self.assertEqual(sorted(app.members), [100, 101, 102])
        self.assertEqual([w["id"] for w in app.windows], [7])

    def test_container_gets_a_short_name(self):
        names = {g.name for g in self.procs.groups.values()}
        self.assertTrue(any(n.startswith("Container ") and len(n) == len("Container ") + 12 for n in names), names)

    def test_every_process_has_one_group(self):
        seen = [pid for g in self.procs.groups.values() for pid in g.members]
        self.assertEqual(sorted(seen), sorted(self.procs.table))

    def test_view_rows_and_order(self):
        view = P.View()
        view.configure({"mode": "apps", "sort": "cpu", "desc": True})
        rows, gone, order = view.build(self.procs, {})
        self.assertIn("app:kitty", rows)
        self.assertEqual(rows["app:kitty"]["t"], "group")
        self.assertIsNotNone(order)
        # sections come first, the app under its section
        self.assertLess(order.index("s:apps"), order.index("app:kitty"))
        # nothing changed: nothing is sent again
        rows2, gone2, order2 = view.build(self.procs, {})
        self.assertEqual(rows2, {})
        self.assertEqual(gone2, [])
        self.assertIsNone(order2)

    def test_filter(self):
        view = P.View()
        view.configure({"mode": "procs", "filter": "make"})
        rows, gone, order = view.build(self.procs, {})
        names = {row.get("n") for row in rows.values() if row.get("t") == "proc"}
        self.assertIn("make", names)
        self.assertNotIn("pipewire", names)


if __name__ == "__main__":
    unittest.main()
