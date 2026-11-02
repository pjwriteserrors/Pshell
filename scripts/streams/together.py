"""Watching together on the local network: one PC hosts with a six digit code,
others join by its address and that code. Only what plays and where it is goes
over the line; nothing else can be asked. It listens only while hosting."""
import json
import random
import socket
import threading

PORT = 47731


class Together:
    def __init__(self, on_state, on_change):
        self.on_state, self.on_change = on_state, on_change
        self.server = None
        self.peers = []
        self.code = ""
        self.role = ""  # "" | host | guest
        self.lock = threading.Lock()

    def status(self):
        return {"role": self.role, "code": self.code, "peers": len(self.peers)}

    def host(self):
        self.stop()
        self.code = f"{random.SystemRandom().randint(0, 999999):06d}"
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("0.0.0.0", PORT))
        self.server.listen(4)
        self.role = "host"
        threading.Thread(target=self.accept, args=(self.server,), daemon=True).start()
        self.on_change()

    def accept(self, server):
        wrong = 0
        while self.server is server:
            try:
                client, _ = server.accept()
            except OSError:
                return
            client.settimeout(5)
            try:
                hello = client.recv(64).decode("utf-8", "replace").strip()
            except OSError:
                client.close()
                continue
            if hello != self.code:
                client.close()
                wrong += 1
                # no guessing
                if wrong >= 5:
                    self.stop()
                    return
                continue
            client.sendall(b"ok\n")
            client.settimeout(None)
            with self.lock:
                self.peers.append(client)
            self.on_change()
            threading.Thread(target=self.listen, args=(client,), daemon=True).start()

    def join(self, address, code):
        self.stop()
        client = socket.create_connection((address, PORT), timeout=8)
        client.sendall((code.strip() + "\n").encode())
        client.settimeout(8)
        if client.recv(8).strip() != b"ok":
            client.close()
            raise OSError("wrong code")
        client.settimeout(None)
        self.role, self.code = "guest", code
        with self.lock:
            self.peers.append(client)
        threading.Thread(target=self.listen, args=(client,), daemon=True).start()
        self.on_change()

    def listen(self, client):
        buffer = b""
        try:
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    state = self.clean(line)
                    if state:
                        self.on_state(state)
                        # a host passes it on to the others
                        self.send(state, skip=client)
                if len(buffer) > 65536:
                    break
        except OSError:
            pass
        with self.lock:
            if client in self.peers:
                self.peers.remove(client)
        client.close()
        if self.role == "guest" and not self.peers:
            self.role, self.code = "", ""
        self.on_change()

    @staticmethod
    def clean(line):
        """Takes nothing on trust: a video's id, numbers, a title to show."""
        try:
            data = json.loads(line)
            video = str(data.get("video") or "")
            if len(video) != 11 or not all(c.isalnum() or c in "-_" for c in video):
                return None
            return {"video": video, "position": max(0.0, float(data.get("position") or 0)), "paused": bool(data.get("paused")), "title": str(data.get("title") or "")[:300], "rate": max(0.25, min(3.0, float(data.get("rate") or 1)))}
        except (ValueError, TypeError, AttributeError):
            return None

    def send(self, state, skip=None):
        line = (json.dumps(state) + "\n").encode()
        with self.lock:
            peers = list(self.peers)
        for peer in peers:
            if peer is not skip:
                try:
                    peer.sendall(line)
                except OSError:
                    pass

    def stop(self):
        server, self.server = self.server, None
        if server:
            try:
                server.close()
            except OSError:
                pass
        with self.lock:
            peers, self.peers = self.peers, []
        for peer in peers:
            try:
                peer.shutdown(socket.SHUT_RDWR)
                peer.close()
            except OSError:
                pass
        self.role, self.code = "", ""
        self.on_change()
