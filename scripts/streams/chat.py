"""A Twitch channel's chat, read without an account: Twitch's chat server lets
anyone read as "justinfan" followed by a number. It never writes."""
import random
import re
import threading

try:
    from websockets.sync.client import connect
except ImportError:
    connect = None

SERVER = "wss://irc-ws.chat.twitch.tv:443"
LINE = re.compile(r"^(?:@(?P<tags>\S+) )?:(?P<nick>[^!]+)!\S+ PRIVMSG #\S+ :(?P<text>.*)$")


class Chat:
    def __init__(self, on_message):
        self.on_message = on_message
        self.login = ""
        self.generation = 0

    def join(self, login):
        self.generation += 1
        self.login = login
        if connect and login:
            threading.Thread(target=self.run, args=(login, self.generation), daemon=True).start()

    def leave(self):
        self.generation += 1
        self.login = ""

    def run(self, login, generation):
        try:
            with connect(SERVER, open_timeout=15) as socket_:
                socket_.send("CAP REQ :twitch.tv/tags")
                socket_.send("PASS SCHMOOPIIE")
                socket_.send(f"NICK justinfan{random.randint(10000, 99999)}")
                socket_.send(f"JOIN #{login}")
                while generation == self.generation:
                    try:
                        raw = socket_.recv(timeout=2)
                    except TimeoutError:
                        continue
                    for line in str(raw).split("\r\n"):
                        if line.startswith("PING"):
                            socket_.send("PONG :tmi.twitch.tv")
                            continue
                        found = LINE.match(line)
                        if found:
                            tags = dict(item.split("=", 1) for item in (found.group("tags") or "").split(";") if "=" in item)
                            self.on_message({"name": tags.get("display-name") or found.group("nick"), "color": tags.get("color", ""), "text": found.group("text")})
        except Exception as error:  # noqa: BLE001 – a chat that goes away is only a chat
            print("chat:", repr(error), flush=True)
