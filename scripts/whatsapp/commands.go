package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// What the panel asks for:
//
//	login · cancelLogin · pairCode {phone} · logout     the QR code, a code to type on the phone instead, unlinking
//	active {value}                                      the panel is on the screen
//	open {chat, id?} · close · older · read {chat}      a chat's messages (around one of them), more of them, seen
//	send {chat, text, reply, mentions, files: [{path, as}]} · retry {chat, id}
//	sendFrom {chat, url, kind: gif|sticker, reply}      what a search found
//	react {chat, id, emoji} · edit {chat, id, text} · revoke {chat, id} · remove {chat, id}
//	forward {chat, id, to: [chat]} · star {chat, id, value}
//	fetch {chat, id, action: ""|open|save}              a message's file
//	typing {chat, value, kind: ""|audio} · record {action: start|stop|cancel, chat, reply}
//	poll {chat, text, options, multi} · vote {chat, id, options} · place {chat, lat, lng, name} · contact {chat, people}
//	pin|archive|markUnread {chat, value} · mute {chat, seconds} · ephemeral {chat, seconds} · deleteChat {chat} · block {chat, value}
//	info {chat} · group {chat, action: add|remove|promote|demote, people} · leave {chat} · subject|description {chat, text}
//	invite {chat, value} · createGroup {name, people} · join {link}
//	contacts · check {phone} · search {query} · starred
//	stickers · keepSticker {chat, id} | {path} · favorite {key, value} · dropSticker {key}
//	gifs {query, kind: gif|sticker} · settings {key}
type Command struct {
	Cmd      string     `json:"cmd"`
	Chat     string     `json:"chat"`
	ID       string     `json:"id"`
	Text     string     `json:"text"`
	Reply    string     `json:"reply"`
	Emoji    string     `json:"emoji"`
	Phone    string     `json:"phone"`
	Name     string     `json:"name"`
	Query    string     `json:"query"`
	Path     string     `json:"path"`
	Action   string     `json:"action"`
	Link     string     `json:"link"`
	Kind     string     `json:"kind"`
	URL      string     `json:"url"`
	Key      string     `json:"key"`
	Files    []FileSpec `json:"files"`
	Mentions []string   `json:"mentions"`
	People   []string   `json:"people"`
	To       []string   `json:"to"`
	Options  []string   `json:"options"`
	Value    bool       `json:"value"`
	Multi    bool       `json:"multi"`
	Seconds  int64      `json:"seconds"`
	Lat      float64    `json:"lat"`
	Lng      float64    `json:"lng"`
}

// what needs no connection
var offline = map[string]bool{
	"login": true, "cancelLogin": true, "active": true, "open": true, "close": true, "older": true, "search": true, "starred": true,
	"stickers": true, "favorite": true, "dropSticker": true, "settings": true, "remove": true, "contacts": true, "record": true, "keepSticker": true, "gifs": true,
}

func (b *Bridge) command(c *Command) {
	if demo && (c.Cmd == "login" || c.Cmd == "cancelLogin" || c.Cmd == "pairCode" || c.Cmd == "logout") {
		return
	}
	if !demo && !offline[c.Cmd] && (b.cli.Store.ID == nil || !b.cli.IsConnected()) {
		b.fail("WhatsApp is not connected", nil)
		return
	}
	switch c.Cmd {
	case "open":
		b.open(c)
	case "close":
		b.mu.Lock()
		b.opened = ""
		b.mu.Unlock()
	case "active":
		b.mu.Lock()
		b.active = c.Value
		b.mu.Unlock()
		go b.announce()
	case "typing":
		go b.sendTyping(c)
	default:
		// what talks to WhatsApp does not keep the next command waiting
		go b.slow(c)
	}
}

func (b *Bridge) slow(c *Command) {
	defer func() {
		if problem := recover(); problem != nil {
			b.fail(fmt.Sprintf("%s: %v", c.Cmd, problem), nil)
		}
	}()
	switch c.Cmd {
	case "login":
		b.signIn()
	case "cancelLogin":
		b.cancelSignIn()
	case "pairCode":
		b.pair(c.Phone)
	case "logout":
		if err := b.cli.Logout(b.ctx); err != nil {
			b.fail("Unlinking", err)
		}
		b.forget()
		b.setPhase("signedOut", "")
	case "older":
		b.older()
	case "read":
		b.markRead(c.Chat)
	case "send":
		b.send(c)
	case "sendFrom":
		b.sendFrom(c)
	case "retry":
		b.retry(c.Chat, c.ID)
	case "react":
		b.react(c)
	case "edit":
		b.edit(c)
	case "revoke":
		b.revoke(c)
	case "remove":
		b.store.remove(c.Chat, c.ID)
		b.touchChats()
		b.touchChat(c.Chat)
	case "forward":
		b.forward(c)
	case "star":
		b.star(c)
	case "fetch":
		b.fetchFor(c)
	case "record":
		b.record(c)
	case "poll":
		b.poll(c)
	case "vote":
		b.vote(c)
	case "place":
		b.place(c)
	case "contact":
		b.contact(c)
	case "pin", "archive", "markUnread", "mute", "deleteChat":
		b.chatState(c)
	case "ephemeral":
		jid, _ := types.ParseJID(c.Chat)
		if err := b.cli.SetDisappearingTimer(b.ctx, jid, time.Duration(c.Seconds)*time.Second, time.Now()); err != nil && !demo {
			b.fail("Disappearing messages", err)
			return
		}
		b.store.chatSet(c.Chat, "ephemeral", c.Seconds)
		b.touchChats()
		b.publishInfo(c.Chat, "")
	case "block":
		b.block(c)
	case "info":
		b.publishInfo(c.Chat, "")
	case "group", "leave", "subject", "description", "invite", "createGroup", "join":
		b.groupDo(c)
	case "contacts":
		b.contacts()
	case "check":
		b.check(c.Phone)
	case "search":
		b.search(c.Query)
	case "starred":
		b.found("", b.store.starred())
	case "stickers":
		b.publishStickers()
	case "keepSticker":
		path := c.Path
		if path == "" {
			path = b.fetch(c.Chat, c.ID, true)
		}
		if path != "" && c.Path != "" && typeOf(path) != "image/webp" {
			// a picture of another kind becomes one first
			made, err := b.toSticker(path, typeOf(path))
			if err != nil {
				b.fail("Sticker", err)
				return
			}
			path = made
		}
		if path != "" {
			b.keepSticker(path, true)
			b.publishStickers()
		}
	case "favorite", "dropSticker":
		b.changeSticker(c)
	case "gifs":
		b.gifs(c)
	case "settings":
		b.store.set("giphy", strings.TrimSpace(c.Key))
		b.publishState()
	}
}

// ── signing in with a code instead of the camera ────────────────────────
func (b *Bridge) pair(phone string) {
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	if len(digits) < 7 {
		b.fail("The phone number with its country code is needed", nil)
		return
	}
	b.signIn()
	// the code is asked for once the first QR code came
	for wait := 0; wait < 50; wait++ {
		b.mu.Lock()
		ready := b.phase == "qr"
		b.mu.Unlock()
		if ready {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	code, err := b.cli.PairPhone(b.ctx, digits, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		b.fail("Linking code", err)
		return
	}
	b.mu.Lock()
	b.pairCode = code
	b.mu.Unlock()
	b.publishState()
}

// ── a chat on the screen ────────────────────────────────────────────────
func (b *Bridge) open(c *Command) {
	b.mu.Lock()
	again := b.opened == c.Chat
	b.opened = c.Chat
	if !again {
		b.window = page
	}
	b.mu.Unlock()
	if c.ID != "" {
		// far enough back to show the message that is asked for
		if row := b.store.message(c.Chat, c.ID); row != nil {
			var newer int
			_ = b.store.db.QueryRow("select count(*) from messages where chat = ? and ts >= ?", c.Chat, row.TS).Scan(&newer)
			b.mu.Lock()
			b.window = max(b.window, newer+20)
			b.mu.Unlock()
		}
	}
	b.publishChat()
	if again {
		return
	}
	go func() {
		rows := b.store.last(c.Chat, page)
		for _, row := range rows {
			if wanted(row) {
				b.fetch(row.Chat, row.ID, false)
			}
		}
		if len(rows) < 25 {
			b.askHistory(c.Chat)
		}
		if jid, err := types.ParseJID(c.Chat); err == nil && jid.Server != types.GroupServer && b.cli.IsConnected() {
			_ = b.cli.SubscribePresence(b.ctx, jid)
		}
	}()
}

func (b *Bridge) older() {
	b.mu.Lock()
	chat := b.opened
	if chat != "" {
		b.window += page
	}
	window := b.window
	b.mu.Unlock()
	if chat == "" {
		return
	}
	if b.store.count(chat) < window {
		b.askHistory(chat)
	}
	b.publishChat()
	for _, row := range b.store.last(chat, window) {
		if wanted(row) {
			b.fetch(row.Chat, row.ID, false)
		}
	}
}

// markRead tells WhatsApp that what arrived in a chat was seen.
func (b *Bridge) markRead(chat string) {
	state := b.store.chat(chat)
	if state.Unread == 0 && !state.Marked {
		return
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return
	}
	bySender := map[types.JID][]types.MessageID{}
	for _, row := range b.store.unreadIncoming(chat, max(state.Unread, 1)) {
		if row.Kind == "system" {
			continue
		}
		sender := b.info(row).Sender
		bySender[sender] = append(bySender[sender], row.ID)
	}
	for sender, ids := range bySender {
		if jid.Server != types.GroupServer {
			sender = types.EmptyJID
		}
		_ = b.cli.MarkRead(b.ctx, ids, time.Now(), jid, sender)
	}
	if state.Marked {
		b.patch(appstate.BuildMarkChatAsRead(jid, true, time.Now(), nil), "")
	}
	b.store.chatSet(chat, "unread", 0)
	b.store.chatSet(chat, "marked", false)
	b.touchChats()
}

func (b *Bridge) sendTyping(c *Command) {
	jid, err := types.ParseJID(c.Chat)
	if err != nil {
		return
	}
	state, media := types.ChatPresencePaused, types.ChatPresenceMediaText
	if c.Value {
		state = types.ChatPresenceComposing
	}
	if c.Kind == "audio" {
		media = types.ChatPresenceMediaAudio
	}
	_ = b.cli.SendChatPresence(b.ctx, jid, state, media)
}

func (b *Bridge) record(c *Command) {
	switch c.Action {
	case "start":
		b.startRecording()
		if b.cli.IsConnected() {
			c.Value, c.Kind = true, "audio"
			b.sendTyping(c)
		}
	case "stop":
		if path := b.stopRecording(true); path != "" {
			c.Files, c.Text = []FileSpec{{Path: path, As: "voice"}}, ""
			b.send(c)
		}
	default:
		b.stopRecording(false)
	}
}

func (b *Bridge) fetchFor(c *Command) {
	path := b.fetch(c.Chat, c.ID, true)
	if path == "" {
		return
	}
	switch c.Action {
	case "open":
		command := exec.Command("xdg-open", path)
		if command.Start() == nil {
			go command.Wait()
		}
	case "save":
		row := b.store.message(c.Chat, c.ID)
		name := filepath.Base(path)
		if row != nil && row.Extra.Media != nil && row.Extra.Media.Name != "" {
			name = filepath.Base(row.Extra.Media.Name)
		} else if row != nil {
			name = "WhatsApp " + time.Unix(row.TS, 0).Format("2006-01-02 15.04.05") + filepath.Ext(path)
		}
		home, _ := os.UserHomeDir()
		folder := filepath.Join(home, "Downloads")
		_ = os.MkdirAll(folder, 0o755)
		target := filepath.Join(folder, name)
		for count := 1; ; count++ {
			if _, err := os.Stat(target); err != nil {
				break
			}
			target = filepath.Join(folder, fmt.Sprintf("%s (%d)%s", strings.TrimSuffix(name, filepath.Ext(name)), count, filepath.Ext(name)))
		}
		data, err := os.ReadFile(path)
		if err == nil {
			err = os.WriteFile(target, data, 0o644)
		}
		if err != nil {
			b.fail("Saving", err)
			return
		}
		b.emit("saved", map[string]any{"path": target})
	}
}

// ── what is kept in step between the devices ────────────────────────────
func (b *Bridge) patch(patch appstate.PatchInfo, what string) bool {
	if demo {
		return true
	}
	if err := b.cli.SendAppState(b.ctx, patch); err != nil {
		if what != "" {
			b.fail(what, err)
		}
		return false
	}
	return true
}

func (b *Bridge) lastKey(chat string) (time.Time, *waCommon.MessageKey) {
	rows := b.store.last(chat, 1)
	if len(rows) == 0 {
		return time.Now(), nil
	}
	row := rows[0]
	key := &waCommon.MessageKey{RemoteJID: proto.String(chat), FromMe: proto.Bool(row.Mine), ID: proto.String(row.ID)}
	if strings.HasSuffix(chat, "@"+types.GroupServer) && !row.Mine {
		key.Participant = proto.String(b.info(row).Sender.String())
	}
	return time.Unix(row.TS, 0), key
}

func (b *Bridge) chatState(c *Command) {
	jid, err := types.ParseJID(c.Chat)
	if err != nil {
		return
	}
	when, key := b.lastKey(c.Chat)
	switch c.Cmd {
	case "pin":
		if !b.patch(appstate.BuildPin(jid, c.Value), "Pinning") {
			return
		}
		pinned := int64(0)
		if c.Value {
			pinned = time.Now().Unix()
		}
		b.store.chatSet(c.Chat, "pinned", pinned)
	case "archive":
		if !b.patch(appstate.BuildArchive(jid, c.Value, when, key), "Archiving") {
			return
		}
		b.store.chatSet(c.Chat, "archived", c.Value)
		if c.Value {
			b.store.chatSet(c.Chat, "pinned", 0)
		}
	case "markUnread":
		if !c.Value {
			b.markRead(c.Chat)
			return
		}
		if !b.patch(appstate.BuildMarkChatAsRead(jid, false, when, key), "Marking") {
			return
		}
		b.store.chatSet(c.Chat, "marked", true)
	case "mute":
		// seconds: 0 lifts it, below 0 is for good
		muted, until := c.Seconds != 0, int64(-1)
		patch := appstate.BuildMute(jid, muted, 0)
		if c.Seconds > 0 {
			patch = appstate.BuildMute(jid, true, time.Duration(c.Seconds)*time.Second)
			until = time.Now().Unix() + c.Seconds
		}
		if !b.patch(patch, "Muting") {
			return
		}
		if !muted {
			until = 0
		}
		b.store.chatSet(c.Chat, "muted", until)
	case "deleteChat":
		if !b.patch(appstate.BuildDeleteChat(jid, when, key, true), "Deleting") {
			return
		}
		b.store.dropChat(c.Chat, false)
		b.mu.Lock()
		if b.opened == c.Chat {
			b.opened = ""
		}
		b.mu.Unlock()
	}
	b.touchChats()
}

func (b *Bridge) star(c *Command) {
	row := b.store.message(c.Chat, c.ID)
	if row == nil {
		return
	}
	info := b.info(row)
	// only what somebody else wrote in a group names its sender; the chat itself
	// stands for "0" there, and an empty one costs the device its link
	sender := info.Sender.ToNonAD()
	if info.Chat.Server != types.GroupServer || row.Mine || sender.IsEmpty() {
		sender = info.Chat
	}
	if !b.patch(appstate.BuildStar(info.Chat, sender, row.ID, row.Mine, c.Value), "Starring") {
		return
	}
	row.Extra.Starred = c.Value
	b.store.update(row)
	b.touchChat(c.Chat)
}

func (b *Bridge) block(c *Command) {
	jid, err := types.ParseJID(c.Chat)
	if err != nil {
		return
	}
	action := events.BlocklistChangeActionUnblock
	if c.Value {
		action = events.BlocklistChangeActionBlock
	}
	if _, err := b.cli.UpdateBlocklist(b.ctx, jid, action, ""); err != nil {
		b.fail("Blocking", err)
		return
	}
	b.publishInfo(c.Chat, "")
}

// ── who a chat is with ──────────────────────────────────────────────────
func (b *Bridge) publishInfo(chat, invite string) {
	jid, err := types.ParseJID(chat)
	if err != nil {
		return
	}
	state := b.store.chat(chat)
	out := map[string]any{
		"id": chat, "name": strings.TrimPrefix(b.name(chat), "~"), "avatar": b.avatar(chat, true), "group": jid.Server == types.GroupServer,
		"ephemeral": state.Ephemeral, "invite": invite,
	}
	if demo && jid.Server != types.GroupServer {
		out["phone"], out["about"], out["blocked"], out["groups"] = "+"+jid.User, "At the harbour", false, []any{map[string]any{"id": demoGroup, "name": "Offsite in June"}}
		b.emit("info", out)
		return
	}
	if jid.Server == types.GroupServer {
		if !demo {
			b.mu.Lock()
			delete(b.groups, chat)
			b.mu.Unlock()
		}
		group := b.group(chat)
		if group == nil {
			b.fail("The group is out of reach", nil)
			return
		}
		people := []map[string]any{}
		admin := false
		for _, participant := range group.Participants {
			person := participant.JID
			if !participant.PhoneNumber.IsEmpty() {
				person = participant.PhoneNumber
			}
			id := b.canon(person).String()
			me := b.isMe(person) || b.isMe(participant.LID)
			if me {
				admin = participant.IsAdmin || participant.IsSuperAdmin
			}
			people = append(people, map[string]any{
				"id": id, "name": strings.TrimPrefix(b.name(id), "~"), "avatar": b.avatar(id, true),
				"admin": participant.IsAdmin || participant.IsSuperAdmin, "me": me,
			})
		}
		sort.SliceStable(people, func(i, j int) bool {
			if people[i]["admin"] != people[j]["admin"] {
				return people[i]["admin"].(bool)
			}
			return strings.ToLower(people[i]["name"].(string)) < strings.ToLower(people[j]["name"].(string))
		})
		out["people"] = people
		out["admin"] = admin
		out["description"] = group.Topic
		out["created"] = group.GroupCreated.Unix()
		out["announce"] = group.IsAnnounce
		out["locked"] = group.IsLocked
	} else {
		out["phone"] = ""
		if jid.Server == types.DefaultUserServer {
			out["phone"] = "+" + jid.User
		}
		if found, err := b.cli.GetUserInfo(b.ctx, []types.JID{jid}); err == nil && !demo {
			out["about"] = found[jid].Status
		}
		blocked := false
		if list, err := b.cli.GetBlocklist(b.ctx, ""); err == nil && list != nil && !demo {
			for _, item := range list.Items {
				if b.canon(item.PN).String() == chat || b.canon(item.LID).String() == chat {
					blocked = true
				}
			}
		}
		out["blocked"] = blocked
		// the groups both are in
		shared := []map[string]any{}
		b.mu.Lock()
		groups := make([]*types.GroupInfo, 0, len(b.groups))
		for _, group := range b.groups {
			groups = append(groups, group)
		}
		b.mu.Unlock()
		for _, group := range groups {
			for _, participant := range group.Participants {
				person := participant.JID
				if !participant.PhoneNumber.IsEmpty() {
					person = participant.PhoneNumber
				}
				if b.canon(person).String() == chat {
					shared = append(shared, map[string]any{"id": group.JID.String(), "name": group.Name})
					break
				}
			}
		}
		out["groups"] = shared
	}
	b.emit("info", out)
}

func (b *Bridge) jids(people []string) []types.JID {
	out := []types.JID{}
	for _, person := range people {
		if jid, err := types.ParseJID(person); err == nil {
			out = append(out, jid)
		}
	}
	return out
}

func (b *Bridge) groupDo(c *Command) {
	jid, _ := types.ParseJID(c.Chat)
	var err error
	invite := ""
	switch c.Cmd {
	case "group":
		_, err = b.cli.UpdateGroupParticipants(b.ctx, jid, b.jids(c.People), whatsmeow.ParticipantChange(c.Action))
	case "leave":
		err = b.cli.LeaveGroup(b.ctx, jid)
	case "subject":
		err = b.cli.SetGroupName(b.ctx, jid, strings.TrimSpace(c.Text))
		if err == nil {
			b.store.chatSet(c.Chat, "name", strings.TrimSpace(c.Text))
		}
	case "description":
		err = b.cli.SetGroupDescription(b.ctx, jid, strings.TrimSpace(c.Text))
	case "invite":
		invite, err = b.cli.GetGroupInviteLink(b.ctx, jid, c.Value)
	case "createGroup":
		var made *types.GroupInfo
		made, err = b.cli.CreateGroup(b.ctx, whatsmeow.ReqCreateGroup{Name: strings.TrimSpace(c.Name), Participants: b.jids(c.People)})
		if err == nil {
			b.keepGroup(made)
			b.touchChats()
			b.emit("made", map[string]any{"chat": made.JID.String()})
			return
		}
	case "join":
		code := c.Link[strings.LastIndex(c.Link, "/")+1:]
		var joined types.JID
		joined, err = b.cli.JoinGroupWithLink(b.ctx, code)
		if err == nil {
			b.refreshGroups()
			b.emit("made", map[string]any{"chat": joined.String()})
			return
		}
	}
	if err != nil {
		b.fail("Group", err)
		return
	}
	b.mu.Lock()
	delete(b.groups, c.Chat)
	delete(b.names, c.Chat)
	b.mu.Unlock()
	b.touchChats()
	if c.Cmd != "leave" {
		b.publishInfo(c.Chat, invite)
	}
}

func (b *Bridge) contacts() {
	out := []map[string]any{}
	if demo {
		for id, name := range demoNames {
			out = append(out, map[string]any{"id": id, "name": name, "saved": true, "phone": "+" + strings.SplitN(id, "@", 2)[0], "avatar": ""})
		}
		sort.Slice(out, func(i, j int) bool { return out[i]["name"].(string) < out[j]["name"].(string) })
		b.emit("contacts", map[string]any{"contacts": out})
		return
	}
	if b.cli.Store.Contacts == nil {
		return
	}
	all, err := b.cli.Store.Contacts.GetAllContacts(b.ctx)
	if err != nil {
		return
	}
	for jid, contact := range all {
		if jid.Server != types.DefaultUserServer || b.isMe(jid) || (contact.FullName == "" && contact.BusinessName == "" && contact.PushName == "") {
			continue
		}
		id := jid.String()
		out = append(out, map[string]any{"id": id, "name": strings.TrimPrefix(b.name(id), "~"), "saved": contact.FullName != "", "phone": "+" + jid.User, "avatar": b.avatar(id, false)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i]["saved"] != out[j]["saved"] {
			return out[i]["saved"].(bool)
		}
		return strings.ToLower(out[i]["name"].(string)) < strings.ToLower(out[j]["name"].(string))
	})
	b.emit("contacts", map[string]any{"contacts": out})
}

// check looks up whether a phone number is on WhatsApp
func (b *Bridge) check(phone string) {
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	found, err := b.cli.IsOnWhatsApp(b.ctx, []string{"+" + digits})
	if err != nil || len(found) == 0 || !found[0].IsIn {
		b.emit("checked", map[string]any{"phone": phone, "ok": false})
		return
	}
	jid := found[0].JID
	if !found[0].PhoneNumber.IsEmpty() {
		jid = found[0].PhoneNumber
	}
	id := b.canon(jid).String()
	b.emit("checked", map[string]any{"phone": phone, "ok": true, "id": id, "name": strings.TrimPrefix(b.name(id), "~")})
}

func (b *Bridge) search(query string) {
	query = strings.TrimSpace(query)
	if len([]rune(query)) < 2 {
		b.found(query, nil)
		return
	}
	b.found(query, b.store.search(query, 120))
}

func (b *Bridge) found(query string, rows []*Row) {
	hits := []map[string]any{}
	for _, row := range rows {
		if row.Kind == "system" || row.Kind == "deleted" {
			continue
		}
		hits = append(hits, map[string]any{
			"chat": row.Chat, "chatName": strings.TrimPrefix(b.name(row.Chat), "~"), "id": row.ID, "name": strings.TrimPrefix(b.name(row.Sender), "~"),
			"text": preview(row), "date": row.TS, "mine": row.Mine,
		})
	}
	b.emit("found", map[string]any{"query": query, "hits": hits})
}

// ── stickers that are kept ──────────────────────────────────────────────
type Sticker struct {
	Key      string `json:"key"`
	File     string `json:"file"`
	Path     string `json:"path"`
	Animated bool   `json:"animated"`
	Favorite bool   `json:"favorite"`
	Used     int64  `json:"used"`
}

func (b *Bridge) stickers() []Sticker {
	var kept []Sticker
	_ = json.Unmarshal([]byte(b.store.get("stickers")), &kept)
	return kept
}

func (b *Bridge) saveStickers(kept []Sticker) {
	data, _ := json.Marshal(kept)
	b.store.set("stickers", string(data))
}

// keepSticker puts a sticker among the ones that are offered: the favourites, or the ones sent last.
func (b *Bridge) keepSticker(path string, favorite bool) {
	if !strings.HasSuffix(path, ".webp") {
		// what is shown of it is a copy: the sticker lies beside it
		original := strings.TrimSuffix(path, filepath.Ext(path)) + ".webp"
		if _, err := os.Stat(original); err != nil {
			return
		}
		path = original
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 2<<20 {
		return
	}
	sum := sha1.Sum(data)
	key := hex.EncodeToString(sum[:])[:20]
	kept := b.stickers()
	for index := range kept {
		if kept[index].Key == key {
			kept[index].Used = time.Now().Unix()
			kept[index].Favorite = kept[index].Favorite || favorite
			b.saveStickers(kept)
			return
		}
	}
	folder := filepath.Join(b.state, "stickers")
	_ = os.MkdirAll(folder, 0o700)
	file := filepath.Join(folder, key+".webp")
	if os.WriteFile(file, data, 0o600) != nil {
		return
	}
	animated := animatedWebp(data)
	kept = append(kept, Sticker{Key: key, File: file, Path: shown(file, animated), Animated: animated, Favorite: favorite, Used: time.Now().Unix()})
	// the ones sent last are not kept for ever
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].Used > kept[j].Used })
	recent := 0
	trimmed := kept[:0]
	for _, sticker := range kept {
		if !sticker.Favorite {
			if recent++; recent > 60 {
				_ = os.Remove(sticker.File)
				if sticker.Path != sticker.File {
					_ = os.Remove(sticker.Path)
				}
				continue
			}
		}
		trimmed = append(trimmed, sticker)
	}
	b.saveStickers(trimmed)
}

func (b *Bridge) changeSticker(c *Command) {
	kept := b.stickers()
	out := kept[:0]
	for _, sticker := range kept {
		if sticker.Key == c.Key {
			if c.Cmd == "dropSticker" {
				_ = os.Remove(sticker.File)
				if sticker.Path != sticker.File {
					_ = os.Remove(sticker.Path)
				}
				continue
			}
			sticker.Favorite = c.Value
		}
		out = append(out, sticker)
	}
	b.saveStickers(out)
	b.publishStickers()
}

func (b *Bridge) publishStickers() {
	kept := b.stickers()
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].Used > kept[j].Used })
	if kept == nil {
		kept = []Sticker{}
	}
	b.emit("stickers", map[string]any{"stickers": kept})
}

// ── GIFs and stickers that are searched for (Giphy) ─────────────────────
// giphyFile is one size of a find; Giphy writes the measures as text.
type giphyFile struct {
	URL    string `json:"url"`
	WebP   string `json:"webp"`
	MP4    string `json:"mp4"`
	Width  string `json:"width"`
	Height string `json:"height"`
}

func (b *Bridge) gifs(c *Command) {
	key := b.store.get("giphy")
	kind := "gif"
	if c.Kind == "sticker" {
		kind = "sticker"
	}
	answer := map[string]any{"query": c.Query, "kind": kind, "results": []any{}}
	if key == "" {
		answer["error"] = "key"
		b.emit("gifs", answer)
		return
	}
	query := strings.TrimSpace(c.Query)
	address := fmt.Sprintf("https://api.giphy.com/v1/%ss/", kind)
	values := url.Values{"api_key": {key}, "limit": {"36"}}
	if query == "" {
		address += "trending"
	} else {
		address += "search"
		values.Set("q", query)
	}
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Get(address + "?" + values.Encode())
	if err != nil {
		answer["error"] = "Offline"
		b.emit("gifs", answer)
		return
	}
	defer response.Body.Close()
	var data struct {
		Data []struct {
			ID     string               `json:"id"`
			Title  string               `json:"title"`
			Images map[string]giphyFile `json:"images"`
		} `json:"data"`
	}
	if response.StatusCode != 200 || json.NewDecoder(response.Body).Decode(&data) != nil {
		answer["error"] = fmt.Sprintf("Giphy answered %d", response.StatusCode)
		b.emit("gifs", answer)
		return
	}
	results := []map[string]any{}
	for _, item := range data.Data {
		small, whole := item.Images["fixed_width"], item.Images["original"]
		preview := small.URL
		if qtReadsWebp && small.WebP != "" {
			preview = small.WebP
		}
		address := whole.MP4
		if kind == "sticker" {
			address = whole.WebP
			if address == "" {
				address = whole.URL
			}
		}
		if preview == "" || address == "" {
			continue
		}
		width, _ := strconv.Atoi(small.Width)
		height, _ := strconv.Atoi(small.Height)
		results = append(results, map[string]any{"id": item.ID, "title": item.Title, "preview": preview, "width": width, "height": height, "url": address})
	}
	answer["results"] = results
	b.emit("gifs", answer)
}
