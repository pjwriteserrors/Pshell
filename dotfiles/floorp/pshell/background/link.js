// One native-messaging link to the shell. The browser starts the host
// (scripts/browser_host.py), which passes every message on to one of the
// shell's sockets and back; when the host ends (the shell went away for good,
// or the host is not installed) the link tries again a little later.
//
// Both parts of the extension use one: downloads.js the downloads socket,
// bridge.js everything else.

class ShellLink {
	constructor(host, handlers) {
		this.host = host;
		this.port = null;
		this.onMessage = handlers.onMessage || (() => {});
		this.onConnect = handlers.onConnect || (() => {});
		this.onDisconnect = handlers.onDisconnect || (() => {});
		this.retry = null;
	}

	get connected() {
		return this.port !== null;
	}

	connect() {
		clearTimeout(this.retry);
		try {
			this.port = browser.runtime.connectNative(this.host);
		} catch (error) {
			this.port = null;
			this.retry = setTimeout(() => this.connect(), 15000);
			return;
		}
		this.port.onMessage.addListener(message => {
			try {
				this.onMessage(message);
			} catch (error) {
				console.error(`[pshell] ${this.host}:`, error);
			}
		});
		this.port.onDisconnect.addListener(() => {
			this.port = null;
			this.onDisconnect();
			this.retry = setTimeout(() => this.connect(), 15000);
		});
		this.onConnect();
	}

	send(message) {
		if (!this.port) return false;
		try {
			this.port.postMessage(message);
			return true;
		} catch (error) {
			this.port = null;
			return false;
		}
	}
}
