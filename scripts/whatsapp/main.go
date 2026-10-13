// WhatsApp for the shell's Messages panel.
//
// core/services/WhatsApp.qml starts this and talks to it in JSON lines:
// commands on stdin, events on stdout. It is a linked device like WhatsApp
// Web (go.mau.fi/whatsmeow): signed in once with the QR code the phone
// scans, it keeps its keys in $XDG_STATE_HOME/pshell/whatsapp/session.db and
// stays signed in until it is unlinked on the phone or here. Chats and
// messages are kept beside it in chats.db, media in
// $XDG_CACHE_HOME/pshell/whatsapp.
//
// Commands ({"cmd": …}) are listed in commands.go.
// Events ({"event": …}): state, chats, chat, incoming, presence, info,
// contacts, checked, stickers, gifs, found, sent, saved, recording, error.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
	"rsc.io/qr"
)

// how many messages of a chat are shown at first, and how many more with every step back
const page = 60

type Bridge struct {
	ctx       context.Context
	cli       *whatsmeow.Client
	container *sqlstore.Container
	store     *Store
	state     string
	cache     string

	out sync.Mutex
	mu  sync.Mutex

	// state, as the panel is told
	phase    string
	problem  string
	qrFile   string
	pairCode string
	lastSync time.Time
	login    context.CancelFunc

	// the chat that is looked at, and how many of its messages
	opened string
	window int
	// no more history to be had from the phone
	exhausted map[string]bool
	asked     map[string]time.Time
	// the panel is on the screen
	active bool

	names   map[string]string
	groups  map[string]*types.GroupInfo
	typing  map[string]map[string]time.Time
	online  map[string]bool
	seen    map[string]int64
	avatars map[string]string
	wanted  chan string
	queued  map[string]bool

	dirtyChats chan struct{}
	dirtyChat  chan struct{}
	sends      chan func()

	recorder *recording
}

func (b *Bridge) emit(event string, fields map[string]any) {
	if fields == nil {
		fields = map[string]any{}
	}
	fields["event"] = event
	line, err := json.Marshal(fields)
	if err != nil {
		return
	}
	b.out.Lock()
	os.Stdout.Write(append(line, '\n'))
	b.out.Unlock()
}

func (b *Bridge) fail(text string, err error) {
	if err != nil {
		text = fmt.Sprintf("%s: %v", text, err)
	}
	if len(text) > 240 {
		text = text[:240]
	}
	b.emit("error", map[string]any{"text": text})
}

func dir(base, fallback string, parts ...string) string {
	root := os.Getenv(base)
	if root == "" {
		home, _ := os.UserHomeDir()
		root = filepath.Join(home, fallback)
	}
	path := filepath.Join(append([]string{root, "pshell", "whatsapp"}, parts...)...)
	_ = os.MkdirAll(path, 0o700)
	return path
}

// ── state ───────────────────────────────────────────────────────────────
func (b *Bridge) setPhase(phase, problem string) {
	b.mu.Lock()
	b.phase, b.problem = phase, problem
	if phase != "qr" {
		b.qrFile, b.pairCode = "", ""
	}
	b.mu.Unlock()
	b.publishState()
}

func (b *Bridge) publishState() {
	b.mu.Lock()
	fields := map[string]any{
		"state": b.phase, "error": b.problem, "qr": b.qrFile, "code": b.pairCode,
		"syncing": time.Since(b.lastSync) < 20*time.Second, "gifs": b.store.get("giphy") != "",
	}
	b.mu.Unlock()
	if id := b.cli.Store.ID; id != nil {
		fields["me"] = map[string]any{"id": id.ToNonAD().String(), "name": b.cli.Store.PushName, "phone": "+" + id.User}
	}
	b.emit("state", fields)
}

// the QR code as a picture the panel shows
func (b *Bridge) showQR(code string) {
	made, err := qr.Encode(code, qr.L)
	if err != nil {
		return
	}
	made.Scale = 8
	for _, old := range globbed(filepath.Join(b.cache, "qr-*.png")) {
		_ = os.Remove(old)
	}
	path := filepath.Join(b.cache, fmt.Sprintf("qr-%d.png", time.Now().UnixNano()))
	if os.WriteFile(path, made.PNG(), 0o600) != nil {
		return
	}
	b.mu.Lock()
	b.phase, b.problem, b.qrFile = "qr", "", path
	b.mu.Unlock()
	b.publishState()
}

func globbed(pattern string) []string {
	found, _ := filepath.Glob(pattern)
	return found
}

// signIn connects a device that is not linked yet and shows the codes the phone scans.
func (b *Bridge) signIn() {
	if b.cli.Store.ID != nil || b.cli.IsConnected() {
		return
	}
	b.mu.Lock()
	if b.login != nil {
		b.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(b.ctx)
	b.login = cancel
	b.mu.Unlock()
	codes, err := b.cli.GetQRChannel(ctx)
	if err == nil {
		err = b.cli.Connect()
	}
	if err != nil {
		cancel()
		b.mu.Lock()
		b.login = nil
		b.mu.Unlock()
		b.setPhase("signedOut", fmt.Sprintf("Offline (%v)", err))
		return
	}
	go func() {
		for item := range codes {
			switch item.Event {
			case "code":
				b.showQR(item.Code)
			case "success":
				b.setPhase("connecting", "")
			case "timeout":
				b.setPhase("signedOut", "")
			default:
				if item.Error != nil {
					b.setPhase("signedOut", item.Error.Error())
				}
			}
		}
		b.mu.Lock()
		b.login = nil
		b.mu.Unlock()
		cancel()
	}()
}

func (b *Bridge) cancelSignIn() {
	b.mu.Lock()
	cancel := b.login
	b.mu.Unlock()
	if cancel == nil || b.cli.Store.ID != nil {
		return
	}
	cancel()
	b.cli.Disconnect()
	b.setPhase("signedOut", "")
}

// a device that was unlinked: its keys and everything it knew go
func (b *Bridge) forget() {
	b.cli.Disconnect()
	if b.cli.Store.ID != nil {
		_ = b.cli.Store.Delete(b.ctx)
	}
	for _, chat := range b.store.chats() {
		b.store.dropChat(chat.JID, false)
	}
	_, _ = b.store.db.Exec("delete from messages; delete from reactions; delete from votes; delete from meta where key like 'avatar:%'")
	_ = os.RemoveAll(filepath.Join(b.cache, "media"))
	_ = os.RemoveAll(filepath.Join(b.cache, "thumbs"))
	_ = os.RemoveAll(filepath.Join(b.cache, "avatars"))
	b.mu.Lock()
	b.names, b.avatars, b.groups = map[string]string{}, map[string]string{}, map[string]*types.GroupInfo{}
	b.opened = ""
	b.mu.Unlock()
	b.newClient()
	b.touchChats()
}

func (b *Bridge) newClient() {
	device, err := b.container.GetFirstDevice(b.ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "whatsapp: no device store:", err)
		os.Exit(1)
	}
	if b.cli != nil {
		b.cli.RemoveEventHandlers()
	}
	b.cli = whatsmeow.NewClient(device, logger{"client"})
	b.cli.EnableAutoReconnect = true
	b.cli.InitialAutoReconnect = true
	b.cli.EmitAppStateEventsOnFullSync = true
	b.cli.AutomaticMessageRerequestFromPhone = true
	b.cli.AddEventHandler(b.handle)
}

// ── names ───────────────────────────────────────────────────────────────
func (b *Bridge) isMe(jid types.JID) bool {
	if id := b.cli.Store.ID; id != nil && id.User == jid.User && jid.Server == types.DefaultUserServer {
		return true
	}
	lid := b.cli.Store.LID
	return !lid.IsEmpty() && lid.User == jid.User && jid.Server == types.HiddenUserServer
}

// canon is the address a person or chat is kept under: the phone number where it is known.
func (b *Bridge) canon(jid types.JID) types.JID {
	jid = jid.ToNonAD()
	if jid.Server == types.HiddenUserServer {
		if id := b.cli.Store.ID; id != nil && b.cli.Store.LID.User == jid.User {
			return id.ToNonAD()
		}
		if pn, err := b.cli.Store.LIDs.GetPNForLID(b.ctx, jid); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return jid
}

func (b *Bridge) canonString(text string) string {
	jid, err := types.ParseJID(text)
	if err != nil {
		return text
	}
	return b.canon(jid).String()
}

func (b *Bridge) name(text string) string {
	b.mu.Lock()
	known, ok := b.names[text]
	b.mu.Unlock()
	if ok {
		return known
	}
	jid, err := types.ParseJID(text)
	if err != nil {
		return text
	}
	name := ""
	if b.isMe(jid) {
		name = "You"
	} else if jid.Server == types.GroupServer {
		name = b.store.chat(text).Name
		if name == "" {
			name = "Group"
		}
	} else if demo {
		name = demoNames[text]
	} else {
		contact, _ := b.cli.Store.Contacts.GetContact(b.ctx, jid)
		switch {
		case contact.FullName != "":
			name = contact.FullName
		case contact.BusinessName != "":
			name = contact.BusinessName
		case contact.PushName != "":
			name = "~" + contact.PushName
		case jid.Server == types.HiddenUserServer && contact.RedactedPhone != "":
			name = contact.RedactedPhone
		case jid.Server == types.HiddenUserServer:
			name = "Unknown"
		default:
			name = "+" + jid.User
		}
	}
	b.mu.Lock()
	b.names[text] = name
	b.mu.Unlock()
	return name
}

func (b *Bridge) forgetNames() {
	b.mu.Lock()
	b.names = map[string]string{}
	b.mu.Unlock()
	b.touchChats()
	b.touchChat("")
}

// ── publishing ──────────────────────────────────────────────────────────
func (b *Bridge) touchChats() {
	select {
	case b.dirtyChats <- struct{}{}:
	default:
	}
}

// touchChat says a chat changed; "" for whichever is looked at
func (b *Bridge) touchChat(chat string) {
	b.mu.Lock()
	shown := b.opened != "" && (chat == "" || chat == b.opened)
	b.mu.Unlock()
	if !shown {
		return
	}
	select {
	case b.dirtyChat <- struct{}{}:
	default:
	}
}

func (b *Bridge) publisher() {
	for {
		select {
		case <-b.dirtyChats:
			time.Sleep(200 * time.Millisecond)
			select {
			case <-b.dirtyChats:
			default:
			}
			b.publishChats()
		case <-b.dirtyChat:
			time.Sleep(60 * time.Millisecond)
			select {
			case <-b.dirtyChat:
			default:
			}
			b.publishChat()
		}
	}
}

func (b *Bridge) typingIn(chat string) []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	var who []string
	for sender, when := range b.typing[chat] {
		if time.Since(when) < 25*time.Second {
			who = append(who, sender)
		}
	}
	sort.Strings(who)
	return who
}

func (b *Bridge) publishChats() {
	// a chat known by its hidden address goes on under the phone number once that is known
	for _, chat := range b.store.chats() {
		if strings.HasSuffix(chat.JID, "@"+types.HiddenUserServer) {
			if real := b.canonString(chat.JID); real != chat.JID {
				b.store.moveChat(chat.JID, real)
			}
		}
	}
	lasts := b.store.lasts()
	now := time.Now().Unix()
	chats := []map[string]any{}
	unread := 0
	for _, chat := range b.store.chats() {
		last := lasts[chat.JID]
		group := strings.HasSuffix(chat.JID, "@"+types.GroupServer)
		if last == nil && !(group && chat.Name != "") {
			continue
		}
		muted := chat.Muted < 0 || chat.Muted > now
		entry := map[string]any{
			"id": chat.JID, "name": b.name(chat.JID), "group": group, "avatar": b.avatar(chat.JID, true),
			"unread": chat.Unread, "marked": chat.Marked, "pinned": chat.Pinned > 0, "muted": muted, "archived": chat.Archived,
			"ephemeral": chat.Ephemeral, "date": 0, "preview": "", "kind": "", "mine": false, "status": 0, "sender": "",
		}
		if !group {
			jid, _ := types.ParseJID(chat.JID)
			entry["phone"] = ""
			if jid.Server == types.DefaultUserServer {
				entry["phone"] = "+" + jid.User
			}
			entry["self"] = b.isMe(jid)
		}
		if typing := b.typingIn(chat.JID); len(typing) > 0 {
			entry["typing"] = b.firstName(typing[0])
		}
		if last != nil {
			entry["date"] = last.TS
			entry["preview"] = preview(last)
			entry["kind"] = last.Kind
			entry["mine"] = last.Mine
			entry["status"] = last.Status
			if group && !last.Mine && last.Kind != "system" {
				entry["sender"] = b.firstName(last.Sender)
			}
		}
		if !muted && !chat.Archived {
			unread += chat.Unread
			if chat.Unread == 0 && chat.Marked {
				unread += 1
			}
		}
		chats = append(chats, entry)
	}
	b.emit("chats", map[string]any{"chats": chats, "unread": unread})
}

func (b *Bridge) firstName(jid string) string {
	name := strings.TrimPrefix(b.name(jid), "~")
	if cut := strings.IndexByte(name, ' '); cut > 0 && !strings.HasPrefix(name, "+") {
		return name[:cut]
	}
	return name
}

func (b *Bridge) publishChat() {
	b.mu.Lock()
	chat, window := b.opened, b.window
	b.mu.Unlock()
	if chat == "" {
		return
	}
	rows := b.store.last(chat, window)
	reactions := b.store.reactions(chat)
	votes := b.store.votes(chat)
	people := map[string]any{}
	messages := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		messages = append(messages, b.view(row, reactions[row.ID], votes[row.ID]))
		if _, known := people[row.Sender]; !known && !row.Mine {
			people[row.Sender] = map[string]any{"name": b.name(row.Sender), "avatar": b.avatar(row.Sender, true)}
		}
	}
	b.mu.Lock()
	more := b.store.count(chat) > len(rows) || (!b.exhausted[chat] && !demo)
	online, seen := b.online[chat], b.seen[chat]
	b.mu.Unlock()
	typing := []string{}
	for _, sender := range b.typingIn(chat) {
		typing = append(typing, b.firstName(sender))
	}
	b.emit("chat", map[string]any{
		"id": chat, "messages": messages, "people": people, "more": more,
		"typing": typing, "online": online, "seen": seen,
	})
}

// ── commands ────────────────────────────────────────────────────────────
func (b *Bridge) read() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 16<<20)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var command Command
		if err := json.Unmarshal([]byte(line), &command); err != nil {
			continue
		}
		b.command(&command)
	}
}

type logger struct{ module string }

func (l logger) Warnf(msg string, args ...any) {
	fmt.Fprintf(os.Stderr, "whatsapp %s: "+msg+"\n", append([]any{l.module}, args...)...)
}
func (l logger) Errorf(msg string, args ...any) { l.Warnf(msg, args...) }
func (l logger) Infof(string, ...any)           {}
func (l logger) Debugf(string, ...any)          {}
func (l logger) Sub(module string) waLog.Logger { return logger{l.module + "/" + module} }

func main() {
	ctx := context.Background()
	state := dir("XDG_STATE_HOME", ".local/state")
	cache := dir("XDG_CACHE_HOME", ".cache")

	// how the phone names this device among the linked ones, and how much of the past it hands over
	store.DeviceProps.Os = proto.String("Pshell")
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()
	store.DeviceProps.RequireFullSync = proto.Bool(true)
	store.DeviceProps.HistorySyncConfig.FullSyncDaysLimit = proto.Uint32(365)
	store.DeviceProps.HistorySyncConfig.FullSyncSizeMbLimit = proto.Uint32(2048)

	demo = isDemo(state)
	if demo {
		// nothing of it lies beside what is real
		state = filepath.Join(cache, "demo")
		_ = os.RemoveAll(state)
		_ = os.MkdirAll(state, 0o700)
	}
	container, err := sqlstore.New(ctx, "sqlite", "file:"+filepath.Join(state, "session.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)", logger{"store"})
	if err != nil {
		fmt.Fprintln(os.Stderr, "whatsapp: session store:", err)
		os.Exit(1)
	}
	// the keys of the linked device are nobody else's
	_ = os.Chmod(filepath.Join(state, "session.db"), 0o600)
	chats, err := openStore(filepath.Join(state, "chats.db"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "whatsapp: chat store:", err)
		os.Exit(1)
	}
	b := &Bridge{
		ctx: ctx, container: container, store: chats, state: state, cache: cache, phase: "starting",
		exhausted: map[string]bool{}, asked: map[string]time.Time{},
		names: map[string]string{}, groups: map[string]*types.GroupInfo{}, typing: map[string]map[string]time.Time{},
		online: map[string]bool{}, seen: map[string]int64{}, avatars: map[string]string{},
		wanted: make(chan string, 4096), queued: map[string]bool{},
		dirtyChats: make(chan struct{}, 1), dirtyChat: make(chan struct{}, 1), sends: make(chan func(), 256),
	}
	b.newClient()
	go b.publisher()
	go b.avatarWorker()
	go func() {
		for job := range b.sends {
			job()
		}
	}()

	if demo {
		b.startDemo()
	} else if b.cli.Store.ID == nil {
		b.setPhase("signedOut", "")
	} else {
		b.setPhase("connecting", "")
		if err := b.cli.Connect(); err != nil {
			b.setPhase("offline", err.Error())
		}
	}
	b.touchChats()
	b.read()
	// the shell left
	b.stopRecording(false)
	b.cli.Disconnect()
}
