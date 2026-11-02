#!/usr/bin/env python3
"""Pshell Editor: the window around the web editor in web/ (plugin "editor").

A process of its own, one per session (Gtk.Application): `pe file[:line]`
opens a tab in the window that runs. Quickshell cannot host a web view, so
this is WebKitGTK; files, watching and the shell's tools are behind a bridge.

    pe [file[:line[:col]]...]    open
    pe --scratch                 the scratchpad comes or goes

The page runs at pe://app/, only its top frame knows the bridge's token.
Rendered code blocks live at pe://preview/ in a sandboxed iframe with a CSP of
their own: no network, no files, no bridge.
"""
import json
import mimetypes
import os
import secrets
import sys
import threading
import urllib.parse

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("WebKit", "6.0")
gi.require_version("JavaScriptCore", "6.0")
from gi.repository import Gdk, Gio, GLib, Gtk, JavaScriptCore, WebKit  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tools  # noqa: E402

APP_ID = "de.pshell.Editor"
DIST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "dist")
SCRATCH_LINGER = 600
IMAGES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".bmp"}
PREVIEW_CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
               "img-src data:; font-src data:; media-src data:")
PREVIEW_HEAD = f"""<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="{PREVIEW_CSP}">
<style>html,body{{margin:0;padding:12px;box-sizing:border-box;background:transparent;color:var(--fg);font:14px sans-serif}}</style>
<script>
addEventListener("error", e => parent.postMessage({{preview: ID, error: e.message}}, "*"));
const post = () => parent.postMessage({{preview: ID, height: document.documentElement.scrollHeight}}, "*");
addEventListener("load", () => {{ post(); new ResizeObserver(post).observe(document.documentElement); }});
</script>
"""


class Page:
    """One window: main or scratch."""

    def __init__(self, app, kind):
        self.app = app
        self.kind = kind
        self.ready = False
        self.queue = []
        self.token = secrets.token_urlsafe(32)

        content = WebKit.UserContentManager()
        content.add_script(WebKit.UserScript(
            f'window.__pe = {json.dumps({"token": self.token, "kind": kind})};',
            WebKit.UserContentInjectedFrames.TOP_FRAME,
            WebKit.UserScriptInjectionTime.START, None, None))
        content.register_script_message_handler_with_reply("bridge", None)
        content.connect("script-message-with-reply-received::bridge", self.on_message)

        self.view = WebKit.WebView(user_content_manager=content)
        settings = self.view.get_settings()
        settings.set_enable_developer_extras(bool(os.environ.get("PE_DEV")))
        settings.set_enable_write_console_messages_to_stdout(bool(os.environ.get("PE_DEV")))
        settings.set_enable_back_forward_navigation_gestures(False)
        settings.set_javascript_can_access_clipboard(True)
        settings.set_enable_smooth_scrolling(True)
        settings.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.ALWAYS)
        self.view.set_background_color(tools.background_rgba())
        self.view.connect("decide-policy", self.on_policy)
        self.view.connect("context-menu", lambda *_: True)
        self.view.connect("web-process-terminated", self.on_crash)

        self.window = Gtk.ApplicationWindow(application=app)
        self.window.set_decorated(False)
        self.window.set_title("Pshell Scratchpad" if kind == "scratch" else "Pshell Editor")
        self.window.set_default_size(*((720, 520) if kind == "scratch" else (1180, 780)))
        self.window.set_child(self.view)
        self.window.connect("close-request", self.on_close)
        self.view.load_uri("pe://app/index.html")

    # ── the page's calls ────────────────────────────────────────────────
    def on_message(self, _manager, value, reply):
        context = value.get_context()
        try:
            call = json.loads(value.to_json(0))
        except (TypeError, ValueError):
            call = {}
        # a frame that shows up without the token is a rendered code block
        if not secrets.compare_digest(str(call.get("token", "")), self.token):
            reply.return_error_message("denied")
            return True
        method, args = call.get("method", ""), call.get("args") or []
        answer = lambda data: reply.return_value(JavaScriptCore.Value.new_string(context, json.dumps(data)))
        own = getattr(self, f"do_{method}", None)
        if own is not None:
            answer(own(*args))
        elif method in tools.FAST:
            answer(tools.call(method, args))
        elif method in tools.SLOW:
            def work():
                data = tools.call(method, args)
                GLib.idle_add(lambda: (answer(data), False)[1])
            threading.Thread(target=work, daemon=True).start()
        else:
            reply.return_error_message("unknown")
        return True

    def emit(self, event, data):
        if not self.ready:
            self.queue.append((event, data))
            return
        script = f"window.peEvent && window.peEvent({json.dumps(event)}, {json.dumps(data)})"
        self.view.evaluate_javascript(script, -1, None, None, None, None, None)

    def do_ready(self):
        self.ready = True
        for event, data in self.queue:
            self.emit(event, data)
        self.queue.clear()
        return {"theme": tools.theme_tokens(), "kind": self.kind, "home": os.path.expanduser("~")}

    def do_watch(self, paths):
        self.app.watch(self, paths)
        return True

    def do_preview(self, html):
        return self.app.put_preview(html)

    def do_previewDrop(self, ids):
        for each in ids:
            self.app.previews.pop(each, None)
        return True

    def do_quit(self):
        self.window.destroy()
        return True

    def do_hide(self):
        self.app.hide_scratch()
        return True

    def do_title(self, title):
        self.window.set_title(title)
        return True

    def do_status(self, status):
        self.app.set_status(self, status)
        return True

    def do_openUri(self, uri):
        if urllib.parse.urlparse(uri).scheme in ("http", "https", "mailto"):
            Gio.AppInfo.launch_default_for_uri(uri, None)
            return True
        return False

    def do_copy(self, text):
        Gdk.Display.get_default().get_clipboard().set(text)
        return True

    # ── navigation ─────────────────────────────────────────────────────
    def on_policy(self, _view, decision, kind):
        if kind == WebKit.PolicyDecisionType.RESPONSE:
            return False
        uri = decision.get_navigation_action().get_request().get_uri()
        if uri.startswith("pe://app/index.html") or uri.startswith("pe://preview/") or uri == "about:blank":
            return False
        decision.ignore()
        return True

    def on_crash(self, _view, _reason):
        self.ready = False
        self.view.reload()

    def on_close(self, _window):
        if self.kind == "scratch":
            self.app.hide_scratch()
            return True
        if self.ready and not getattr(self, "closing", False):
            self.emit("closeRequested", {})
            return True
        return False

    def do_closeNow(self):
        self.closing = True
        self.window.close()
        return True


class Editor(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.main = None
        self.scratch = None
        self.scratch_timer = 0
        self.previews = {}
        self.monitors = {}
        self.statuses = {}
        self.theme_monitor = None
        self.connect("command-line", self.on_command_line)
        self.connect("startup", self.on_startup)

    def on_startup(self, _app):
        context = WebKit.WebContext.get_default()
        context.register_uri_scheme("pe", self.on_scheme)
        context.get_security_manager().register_uri_scheme_as_secure("pe")
        path = tools.theme_path()
        self.theme_monitor = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.NONE, None)
        self.theme_monitor.connect("changed", self.on_theme)

    def on_theme(self, _monitor, _file, _other, event):
        if event in (Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.CREATED):
            tokens = tools.theme_tokens()
            for page in (self.main, self.scratch):
                if page:
                    page.view.set_background_color(tools.background_rgba())
                    page.emit("theme", tokens)

    def page(self, kind):
        if kind == "scratch":
            if self.scratch is None:
                self.scratch = Page(self, "scratch")
            return self.scratch
        if self.main is None:
            self.main = Page(self, "main")
            self.main.window.connect("destroy", self.on_main_gone)
        return self.main

    def on_main_gone(self, _window):
        self.main = None
        self.set_status(None, None)

    def on_command_line(self, _app, command_line):
        args = command_line.get_arguments()[1:]
        cwd = command_line.get_cwd() or os.path.expanduser("~")
        flags = [each for each in args if each.startswith("--")]
        files = [each for each in args if not each.startswith("--")]
        if "--scratch" in flags:
            self.toggle_scratch()
            return 0
        main = self.page("main")
        for each in files:
            main.emit("open", tools.parse_target(each, cwd))
        self.bring(main.window, "Pshell Editor")
        return 0

    @staticmethod
    def bring(window, title):
        """GTK asks for focus without a token when a key started this: niri is told too."""
        window.present()
        GLib.timeout_add(60, lambda: (tools.focus_window(title), False)[1])

    # ── the scratchpad stays warm a while after it is put away ─────────
    def toggle_scratch(self):
        page = self.page("scratch")
        if page.window.get_visible() and page.window.is_active():
            self.hide_scratch()
            return
        if self.scratch_timer:
            GLib.source_remove(self.scratch_timer)
            self.scratch_timer = 0
        self.bring(page.window, "Pshell Scratchpad")
        page.emit("shown", {})

    def hide_scratch(self):
        page = self.scratch
        if page is None:
            return
        page.emit("hiding", {})
        GLib.timeout_add(170, lambda: (page.window.set_visible(False), False)[1])
        if not self.scratch_timer:
            self.scratch_timer = GLib.timeout_add_seconds(SCRATCH_LINGER, self.drop_scratch)

    def drop_scratch(self):
        self.scratch_timer = 0
        if self.scratch is not None:
            self.scratch.window.destroy()
            self.scratch = None
        return False

    # ── pe:// ──────────────────────────────────────────────────────────
    def on_scheme(self, request):
        uri = urllib.parse.urlparse(request.get_uri())
        try:
            if uri.netloc == "app":
                self.serve_app(request, uri.path.lstrip("/") or "index.html")
            elif uri.netloc == "preview":
                self.serve_bytes(request, self.previews[uri.path.lstrip("/")], "text/html; charset=utf-8")
            elif uri.netloc == "file":
                self.serve_image(request, urllib.parse.unquote(uri.path))
            else:
                raise KeyError(uri.netloc)
        except (OSError, KeyError) as error:
            request.finish_error(GLib.Error.new_literal(GLib.quark_from_string("pe"), str(error), 1))

    def serve_app(self, request, relative):
        path = os.path.normpath(os.path.join(DIST, relative))
        if not path.startswith(DIST + os.sep):
            raise KeyError(relative)
        with open(path, "rb") as file:
            self.serve_bytes(request, file.read(), mimetypes.guess_type(path)[0] or "application/octet-stream")

    def serve_image(self, request, path):
        # only pictures: this is what a document's ![](…) may reach
        if os.path.splitext(path)[1].lower() not in IMAGES:
            raise KeyError(path)
        with open(path, "rb") as file:
            self.serve_bytes(request, file.read(), mimetypes.guess_type(path)[0] or "image/png")

    @staticmethod
    def serve_bytes(request, data, mime):
        stream = Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(data))
        response = WebKit.URISchemeResponse.new(stream, len(data))
        response.set_content_type(mime)
        request.finish_with_response(response)

    def put_preview(self, html):
        key = secrets.token_urlsafe(12)
        document = PREVIEW_HEAD.replace("ID", json.dumps(key)) + html
        self.previews[key] = document.encode()
        return key

    # ── files that change on disk ──────────────────────────────────────
    def watch(self, page, paths):
        wanted = set(paths)
        for path in list(self.monitors):
            pages, monitor = self.monitors[path]
            pages.discard(page.kind)
            if not pages and path not in wanted:
                monitor.cancel()
                del self.monitors[path]
        for path in wanted:
            if path in self.monitors:
                self.monitors[path][0].add(page.kind)
                continue
            monitor = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, None)
            monitor.connect("changed", self.on_file_changed, path)
            self.monitors[path] = ({page.kind}, monitor)

    def on_file_changed(self, _monitor, _file, _other, event, path):
        if event not in (Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.DELETED,
                         Gio.FileMonitorEvent.RENAMED, Gio.FileMonitorEvent.MOVED_OUT, Gio.FileMonitorEvent.CREATED):
            return
        info = tools.call("stat", [path])
        for page in (self.main, self.scratch):
            if page and path in self.monitors and page.kind in self.monitors[path][0]:
                page.emit("fileChanged", {"path": path, **info})

    def set_status(self, page, status):
        self.statuses["main"] = status if page is None or page.kind == "main" else self.statuses.get("main")
        tools.write_status(self.statuses.get("main"))


if __name__ == "__main__":
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("Pshell Editor")
    sys.exit(Editor().run(sys.argv))
