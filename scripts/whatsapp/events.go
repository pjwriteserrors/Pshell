package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// What WhatsApp says: messages, receipts, the past the phone hands over,
// and what was done to chats on another device.

func (b *Bridge) handle(raw any) {
	switch evt := raw.(type) {
	case *events.Connected:
		b.setPhase("online", "")
		b.announce()
		go b.refreshGroups()
	case *events.Disconnected:
		b.mu.Lock()
		online := b.phase == "online"
		b.mu.Unlock()
		if online {
			b.setPhase("offline", "")
		}
	case *events.LoggedOut:
		b.forget()
		b.setPhase("signedOut", "This device was unlinked")
	case *events.StreamReplaced:
		b.setPhase("offline", "Another session took over this device")
	case *events.ClientOutdated:
		b.setPhase("offline", "WhatsApp asks for a newer client: run scripts/whatsapp/run.sh update")
	case *events.TemporaryBan:
		b.setPhase("offline", evt.String())
	case *events.ConnectFailure:
		b.setPhase("offline", evt.Message)
	case *events.Message:
		b.ingest(evt, true, statusSent)
	case *events.UndecryptableMessage:
		b.waiting(evt)
	case *events.Receipt:
		b.receipt(evt)
	case *events.HistorySync:
		b.history(evt)
	case *events.ChatPresence:
		b.chatPresence(evt)
	case *events.Presence:
		chat := b.canon(evt.From).String()
		b.mu.Lock()
		b.online[chat] = !evt.Unavailable
		if !evt.LastSeen.IsZero() {
			b.seen[chat] = evt.LastSeen.Unix()
		}
		b.mu.Unlock()
		b.touchChat(chat)
	case *events.JoinedGroup:
		b.keepGroup(&evt.GroupInfo)
		b.touchChats()
	case *events.GroupInfo:
		b.groupChanged(evt)
	case *events.Picture:
		jid := b.canon(evt.JID).String()
		b.store.set("avatar:"+jid, "")
		b.mu.Lock()
		delete(b.avatars, jid)
		b.mu.Unlock()
		b.avatar(jid, true)
	case *events.Contact, *events.PushName, *events.BusinessName:
		b.forgetNames()
	case *events.Pin:
		pinned := int64(0)
		if evt.Action.GetPinned() {
			pinned = evt.Timestamp.Unix()
		}
		b.store.chatSet(b.canon(evt.JID).String(), "pinned", pinned)
		b.touchChats()
	case *events.Mute:
		b.store.chatSet(b.canon(evt.JID).String(), "muted", mutedUntil(evt.Action.GetMuted(), evt.Action.GetMuteEndTimestamp()))
		b.touchChats()
	case *events.Archive:
		b.store.chatSet(b.canon(evt.JID).String(), "archived", evt.Action.GetArchived())
		b.touchChats()
	case *events.MarkChatAsRead:
		chat := b.canon(evt.JID).String()
		b.store.chatSet(chat, "marked", !evt.Action.GetRead())
		if evt.Action.GetRead() {
			b.store.chatSet(chat, "unread", 0)
		}
		b.touchChats()
	case *events.DeleteChat:
		b.store.dropChat(b.canon(evt.JID).String(), false)
		b.touchChats()
		b.touchChat("")
	case *events.ClearChat:
		b.store.dropChat(b.canon(evt.JID).String(), true)
		b.touchChats()
		b.touchChat("")
	case *events.Star:
		chat := b.canon(evt.ChatJID).String()
		if row := b.store.message(chat, evt.MessageID); row != nil {
			row.Extra.Starred = evt.Action.GetStarred()
			b.store.update(row)
			b.touchChat(chat)
		}
	case *events.DeleteForMe:
		chat := b.canon(evt.ChatJID).String()
		b.store.remove(chat, evt.MessageID)
		b.touchChats()
		b.touchChat(chat)
	case *events.CallOffer:
		b.call(evt.BasicCallMeta, false)
	case *events.CallOfferNotice:
		b.call(evt.BasicCallMeta, evt.Type == "group")
	}
}

func mutedUntil(muted bool, end int64) int64 {
	switch {
	case !muted:
		return 0
	case end <= 0:
		return -1
	case end > 1e12:
		return end / 1000
	}
	return end
}

// the phone keeps its notifications to itself while a linked device says it is looked at
func (b *Bridge) announce() {
	if !b.cli.IsConnected() || b.cli.Store.ID == nil {
		return
	}
	b.mu.Lock()
	state := types.PresenceUnavailable
	if b.active {
		state = types.PresenceAvailable
	}
	b.mu.Unlock()
	_ = b.cli.SendPresence(b.ctx, state)
}

// ── who and where ───────────────────────────────────────────────────────
func (b *Bridge) chatOf(info *types.MessageInfo) types.JID {
	chat := info.Chat.ToNonAD()
	if chat.Server == types.HiddenUserServer {
		other := info.SenderAlt
		if info.IsFromMe {
			other = info.RecipientAlt
		}
		if other.Server == types.DefaultUserServer {
			return other.ToNonAD()
		}
	}
	return b.canon(chat)
}

func (b *Bridge) senderOf(info *types.MessageInfo) types.JID {
	if info.IsFromMe && b.cli.Store.ID != nil {
		return b.cli.Store.ID.ToNonAD()
	}
	if info.Sender.Server == types.HiddenUserServer && info.SenderAlt.Server == types.DefaultUserServer {
		return info.SenderAlt.ToNonAD()
	}
	return b.canon(info.Sender)
}

func skipped(chat types.JID) bool {
	return chat.Server == types.BroadcastServer || chat.Server == types.NewsletterServer || chat.Server == types.BotServer || chat.IsEmpty()
}

// ── messages ────────────────────────────────────────────────────────────
func (b *Bridge) ingest(evt *events.Message, live bool, status int) {
	info := &evt.Info
	msg := evt.Message
	if msg == nil || skipped(info.Chat) {
		return
	}
	chat := b.chatOf(info).String()
	sender := b.senderOf(info).String()
	ts := info.Timestamp.Unix()

	if reaction := msg.GetReactionMessage(); reaction != nil {
		b.store.react(chat, reaction.GetKey().GetID(), sender, reaction.GetText(), ts)
		b.touchChat(chat)
		return
	}
	if msg.GetEncReactionMessage() != nil {
		if reaction, err := b.cli.DecryptReaction(b.ctx, evt); err == nil {
			b.store.react(chat, msg.GetEncReactionMessage().GetTargetMessageKey().GetID(), sender, reaction.GetText(), ts)
			b.touchChat(chat)
		}
		return
	}
	if update := msg.GetPollUpdateMessage(); update != nil {
		if vote, err := b.cli.DecryptPollVote(b.ctx, evt); err == nil {
			b.applyVote(chat, update.GetPollCreationMessageKey().GetID(), sender, vote.GetSelectedOptions(), ts)
		}
		return
	}
	if protocol := msg.GetProtocolMessage(); protocol != nil {
		b.protocol(chat, sender, info, protocol, live)
		return
	}

	parsed := b.parse(msg, info.ID)
	if parsed == nil {
		return
	}
	if evt.IsViewOnce && parsed.extra.Media != nil {
		parsed.extra.Media.ViewOnce = true
	}
	parsed.extra.Origin = info.Sender.ToNonAD().String()
	if evt.SourceWebMsg != nil {
		parsed.extra.Starred = evt.SourceWebMsg.GetStarred()
	}
	raw, _ := proto.Marshal(msg)
	row := &Row{Chat: chat, ID: info.ID, Sender: sender, TS: ts, Mine: info.IsFromMe, Kind: parsed.kind, Text: parsed.text, Extra: parsed.extra, Raw: raw, Status: status}
	fresh := b.store.put(row)
	if !fresh {
		// what could not be read at first, or was sent from here and comes back
		known := b.store.message(chat, info.ID)
		if known == nil || known.Kind != "waiting" {
			return
		}
		b.store.update(row)
	}
	if live {
		if info.IsFromMe {
			// answered on another device: nothing in it is new any more
			b.store.chatSet(chat, "unread", 0)
			b.store.chatSet(chat, "marked", false)
		} else if fresh {
			_, _ = b.store.db.Exec("update chats set unread = unread + 1 where jid = ?", chat)
			b.notify(row)
		}
		b.stopTyping(chat, sender)
		if parsed.ctx != nil && !strings.HasSuffix(chat, "@"+types.GroupServer) {
			b.store.chatSet(chat, "ephemeral", int64(parsed.ctx.GetExpiration()))
		}
		if wanted(row) {
			go b.fetch(chat, info.ID, false)
		}
		b.touchChats()
		b.touchChat(chat)
	}
}

// what is fetched without being asked for: what a chat shows in place
func wanted(row *Row) bool {
	media := row.Extra.Media
	if media == nil || media.Path != "" || media.Error != "" {
		return false
	}
	switch row.Kind {
	case "sticker":
		return true
	case "image", "voice":
		return media.Size < 16<<20
	case "gif":
		return media.Size < 8<<20
	}
	return false
}

func (b *Bridge) protocol(chat, sender string, info *types.MessageInfo, protocol *waE2E.ProtocolMessage, live bool) {
	target := protocol.GetKey().GetID()
	switch protocol.GetType() {
	case waE2E.ProtocolMessage_REVOKE:
		row := b.store.message(chat, target)
		if row == nil {
			return
		}
		row.Kind, row.Text, row.Raw = "deleted", "", nil
		row.Extra = Extra{Deleted: true, Origin: row.Extra.Origin}
		b.store.update(row)
	case waE2E.ProtocolMessage_MESSAGE_EDIT:
		row := b.store.message(chat, target)
		parsed := b.parse(protocol.GetEditedMessage(), target)
		if row == nil || parsed == nil || row.Kind == "deleted" {
			return
		}
		row.Text = parsed.text
		row.Extra.Edited = true
		row.Extra.Mentions = parsed.extra.Mentions
		if row.Extra.Media == nil {
			row.Kind = parsed.kind
			row.Raw, _ = proto.Marshal(protocol.GetEditedMessage())
		}
		b.store.update(row)
	case waE2E.ProtocolMessage_EPHEMERAL_SETTING:
		b.store.chatSet(chat, "ephemeral", int64(protocol.GetEphemeralExpiration()))
		text := "Disappearing messages were turned off"
		if seconds := protocol.GetEphemeralExpiration(); seconds > 0 {
			text = "Messages disappear after " + span(int64(seconds))
		}
		b.store.put(&Row{Chat: chat, ID: info.ID, Sender: sender, TS: info.Timestamp.Unix(), Mine: info.IsFromMe, Kind: "system", Text: text})
	default:
		return
	}
	if live {
		b.touchChats()
		b.touchChat(chat)
	}
}

func span(seconds int64) string {
	switch {
	case seconds >= 86400*30:
		return fmt.Sprintf("%d days", seconds/86400)
	case seconds >= 86400:
		return fmt.Sprintf("%d days", seconds/86400)
	case seconds >= 3600:
		return fmt.Sprintf("%d hours", seconds/3600)
	}
	return fmt.Sprintf("%d minutes", seconds/60)
}

func (b *Bridge) applyVote(chat, poll, sender string, hashes [][]byte, ts int64) {
	row := b.store.message(chat, poll)
	if row == nil || row.Extra.Poll == nil {
		return
	}
	chosen := []string{}
	for _, option := range row.Extra.Poll.Options {
		sum := sha256.Sum256([]byte(option))
		for _, hash := range hashes {
			if bytes.Equal(hash, sum[:]) {
				chosen = append(chosen, option)
			}
		}
	}
	b.store.vote(chat, poll, sender, chosen, ts)
	b.touchChat(chat)
}

// a message that could not be read yet; its sender is asked for it again
func (b *Bridge) waiting(evt *events.UndecryptableMessage) {
	if skipped(evt.Info.Chat) || evt.DecryptFailMode == events.DecryptFailHide {
		return
	}
	chat := b.chatOf(&evt.Info).String()
	kind := "waiting"
	if evt.UnavailableType == events.UnavailableTypeViewOnce {
		kind = "unsupported"
	}
	row := &Row{Chat: chat, ID: evt.Info.ID, Sender: b.senderOf(&evt.Info).String(), TS: evt.Info.Timestamp.Unix(), Mine: evt.Info.IsFromMe, Kind: kind, Status: statusSent}
	row.Extra.Origin = evt.Info.Sender.ToNonAD().String()
	if b.store.put(row) {
		b.touchChats()
		b.touchChat(chat)
	}
}

func (b *Bridge) notify(row *Row) {
	if time.Now().Unix()-row.TS > 90 {
		return
	}
	chat := b.store.chat(row.Chat)
	if chat.Archived || chat.Muted < 0 || chat.Muted > time.Now().Unix() {
		return
	}
	group := strings.HasSuffix(row.Chat, "@"+types.GroupServer)
	text := preview(row)
	if group {
		text = b.firstName(row.Sender) + ": " + text
	}
	b.emit("incoming", map[string]any{
		"chat": row.Chat, "name": strings.TrimPrefix(b.name(row.Chat), "~"), "text": text, "avatar": b.avatar(row.Chat, false), "group": group,
	})
}

func (b *Bridge) call(meta types.BasicCallMeta, group bool) {
	chat := b.canon(meta.From).String()
	if !meta.GroupJID.IsEmpty() {
		chat = meta.GroupJID.String()
	}
	sender := b.canon(meta.CallCreator).String()
	row := &Row{Chat: chat, ID: "call-" + meta.CallID, Sender: sender, TS: meta.Timestamp.Unix(), Kind: "system", Text: "Call from " + strings.TrimPrefix(b.name(sender), "~") + " – answered on the phone"}
	if !b.store.put(row) {
		return
	}
	b.emit("incoming", map[string]any{
		"chat": chat, "name": strings.TrimPrefix(b.name(chat), "~"), "text": "Calling – answer on the phone", "avatar": b.avatar(chat, false), "group": group, "call": true,
	})
	b.touchChats()
	b.touchChat(chat)
}

func (b *Bridge) receipt(evt *events.Receipt) {
	chat := b.canon(evt.Chat).String()
	status := 0
	switch evt.Type {
	case types.ReceiptTypeDelivered:
		status = statusDelivered
	case types.ReceiptTypeRead:
		status = statusRead
	case types.ReceiptTypePlayed:
		status = statusPlayed
	case types.ReceiptTypeReadSelf:
		// read on another device
		b.store.chatSet(chat, "unread", 0)
		b.store.chatSet(chat, "marked", false)
		b.touchChats()
		return
	default:
		return
	}
	if evt.IsFromMe {
		return
	}
	changed := false
	for _, id := range evt.MessageIDs {
		changed = b.store.setStatus(chat, id, status) || changed
	}
	if changed {
		b.touchChats()
		b.touchChat(chat)
	}
}

func (b *Bridge) chatPresence(evt *events.ChatPresence) {
	chat := b.canon(evt.Chat).String()
	sender := b.canon(evt.Sender).String()
	if evt.State != types.ChatPresenceComposing {
		b.stopTyping(chat, sender)
		return
	}
	b.mu.Lock()
	if b.typing[chat] == nil {
		b.typing[chat] = map[string]time.Time{}
	}
	b.typing[chat][sender] = time.Now()
	b.mu.Unlock()
	b.touchChats()
	b.touchChat(chat)
	// who stops without saying so
	time.AfterFunc(26*time.Second, func() {
		b.touchChats()
		b.touchChat(chat)
	})
}

func (b *Bridge) stopTyping(chat, sender string) {
	b.mu.Lock()
	_, was := b.typing[chat][sender]
	delete(b.typing[chat], sender)
	b.mu.Unlock()
	if was {
		b.touchChats()
		b.touchChat(chat)
	}
}

// ── the past ────────────────────────────────────────────────────────────
func (b *Bridge) history(evt *events.HistorySync) {
	kind := evt.Data.GetSyncType()
	if kind == waHistorySync.HistorySync_PUSH_NAME || kind == waHistorySync.HistorySync_NON_BLOCKING_DATA {
		b.forgetNames()
		return
	}
	demanded := kind == waHistorySync.HistorySync_ON_DEMAND
	if !demanded {
		b.mu.Lock()
		b.lastSync = time.Now()
		b.mu.Unlock()
		b.publishState()
		time.AfterFunc(21*time.Second, b.publishState)
	}
	for _, conversation := range evt.Data.GetConversations() {
		jid, err := types.ParseJID(conversation.GetID())
		if err != nil || skipped(jid) {
			continue
		}
		chat := b.canon(jid).String()
		before := b.store.count(chat)
		b.store.touch(chat)
		if conversation.GetName() != "" && jid.Server == types.GroupServer {
			b.store.chatSet(chat, "name", conversation.GetName())
		}
		if !demanded {
			b.store.chatSet(chat, "unread", int(conversation.GetUnreadCount()))
			b.store.chatSet(chat, "archived", conversation.GetArchived())
			b.store.chatSet(chat, "pinned", int64(conversation.GetPinned()))
			b.store.chatSet(chat, "marked", conversation.GetMarkedAsUnread())
			b.store.chatSet(chat, "ephemeral", int64(conversation.GetEphemeralExpiration()))
			if end := int64(conversation.GetMuteEndTime()); end != 0 {
				b.store.chatSet(chat, "muted", mutedUntil(true, end))
			}
		}
		for _, entry := range conversation.GetMessages() {
			web := entry.GetMessage()
			parsed, err := b.cli.ParseWebMessage(jid, web)
			if err != nil {
				continue
			}
			status := int(web.GetStatus()) - 1
			if !parsed.Info.IsFromMe || status < statusSent {
				status = statusSent
			}
			b.ingest(parsed, false, status)
			b.pastExtras(chat, web)
		}
		if demanded {
			b.mu.Lock()
			if b.store.count(chat) == before {
				b.exhausted[chat] = true
			}
			if b.opened == chat {
				b.window += b.store.count(chat) - before
			}
			b.mu.Unlock()
			b.touchChat(chat)
		}
	}
	b.touchChats()
	b.touchChat("")
}

// reactions and votes the past brings along with a message
func (b *Bridge) pastExtras(chat string, web *waWeb.WebMessageInfo) {
	who := func(fromMe bool, participant, remote string) string {
		if fromMe && b.cli.Store.ID != nil {
			return b.cli.Store.ID.ToNonAD().String()
		}
		if participant != "" {
			return b.canonString(participant)
		}
		return b.canonString(remote)
	}
	id := web.GetKey().GetID()
	for _, reaction := range web.GetReactions() {
		key := reaction.GetKey()
		b.store.react(chat, id, who(key.GetFromMe(), key.GetParticipant(), key.GetRemoteJID()), reaction.GetText(), reaction.GetSenderTimestampMS()/1000)
	}
	for _, update := range web.GetPollUpdates() {
		key := update.GetPollUpdateMessageKey()
		b.applyVote(chat, id, who(key.GetFromMe(), key.GetParticipant(), key.GetRemoteJID()), update.GetVote().GetSelectedOptions(), update.GetSenderTimestampMS()/1000)
	}
}

func (b *Bridge) info(row *Row) *types.MessageInfo {
	chat, _ := types.ParseJID(row.Chat)
	sender, _ := types.ParseJID(row.Sender)
	if origin, err := types.ParseJID(row.Extra.Origin); err == nil && !origin.IsEmpty() {
		sender = origin
	}
	return &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: chat, Sender: sender, IsFromMe: row.Mine, IsGroup: chat.Server == types.GroupServer},
		ID:            row.ID, Timestamp: time.Unix(row.TS, 0),
	}
}

// askHistory asks the phone for what came before the oldest message that is known.
func (b *Bridge) askHistory(chat string) {
	b.mu.Lock()
	recently := time.Since(b.asked[chat]) < 8*time.Second
	if !recently {
		b.asked[chat] = time.Now()
	}
	b.mu.Unlock()
	oldest := b.store.oldest(chat)
	if recently || oldest == nil || !b.cli.IsConnected() {
		return
	}
	if _, err := b.cli.SendPeerMessage(b.ctx, b.cli.BuildHistorySyncRequest(b.info(oldest), 50)); err != nil {
		return
	}
	// a phone that does not answer has nothing more
	time.AfterFunc(20*time.Second, func() {
		b.mu.Lock()
		silent := time.Since(b.asked[chat]) >= 19*time.Second && b.store.oldest(chat) != nil && b.store.oldest(chat).ID == oldest.ID
		if silent {
			b.exhausted[chat] = true
		}
		b.mu.Unlock()
		if silent {
			b.touchChat(chat)
		}
	})
}

// ── media ───────────────────────────────────────────────────────────────
var qtReadsWebp = func() bool {
	for _, folder := range []string{"/usr/lib/qt6/plugins", "/usr/lib/qt/plugins", "/usr/lib64/qt6/plugins", "/usr/lib/x86_64-linux-gnu/qt6/plugins"} {
		if _, err := os.Stat(filepath.Join(folder, "imageformats", "libqwebp.so")); err == nil {
			return true
		}
	}
	return false
}()

// shown returns the file Qt can draw of a sticker: itself, or a copy in a format it reads.
func shown(path string, animated bool) string {
	if qtReadsWebp || !strings.HasSuffix(path, ".webp") {
		return path
	}
	if animated {
		target := strings.TrimSuffix(path, ".webp") + ".gif"
		filter := "split[a][b];[a]palettegen=reserve_transparent=1[p];[b][p]paletteuse=alpha_threshold=128"
		if exec.Command("ffmpeg", "-y", "-loglevel", "error", "-i", path, "-vf", filter, target).Run() == nil {
			return target
		}
	}
	target := strings.TrimSuffix(path, ".webp") + ".png"
	if exec.Command("ffmpeg", "-y", "-loglevel", "error", "-i", path, "-frames:v", "1", target).Run() == nil {
		return target
	}
	return path
}

// fetch brings a message's file from WhatsApp's servers into the cache.
func (b *Bridge) fetch(chat, id string, asked bool) string {
	row := b.store.message(chat, id)
	if row == nil || row.Extra.Media == nil {
		return ""
	}
	if path := row.Extra.Media.Path; path != "" {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	if len(row.Raw) == 0 {
		return ""
	}
	msg := &waE2E.Message{}
	if proto.Unmarshal(row.Raw, msg) != nil {
		return ""
	}
	part, ending := downloadable(msg)
	if part == nil {
		return ""
	}
	folder := filepath.Join(b.cache, "media")
	_ = os.MkdirAll(folder, 0o700)
	path := filepath.Join(folder, fileKey(chat, id)+ending)
	file, err := os.Create(path + ".part")
	if err == nil {
		err = b.cli.DownloadToFile(b.ctx, part, file)
		_ = file.Close()
	}
	// the message may have changed meanwhile
	row = b.store.message(chat, id)
	if row == nil || row.Extra.Media == nil {
		_ = os.Remove(path + ".part")
		return ""
	}
	if err != nil {
		_ = os.Remove(path + ".part")
		if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith403) {
			row.Extra.Media.Error = "No longer on WhatsApp's servers – it is still on the phone"
		} else if asked {
			b.fail("Download", err)
			return ""
		} else {
			return ""
		}
		b.store.update(row)
		b.touchChat(chat)
		return ""
	}
	_ = os.Rename(path+".part", path)
	if row.Kind == "sticker" {
		path = shown(path, row.Extra.Media.Animated)
	}
	row.Extra.Media.Path = path
	row.Extra.Media.Error = ""
	b.store.update(row)
	b.touchChat(chat)
	return path
}

// ── pictures of people and groups ───────────────────────────────────────
type portrait struct {
	ID      string `json:"id"`
	Path    string `json:"path"`
	Checked int64  `json:"checked"`
}

// avatar is the picture that is known; with `want` a newer one is looked for in the background.
func (b *Bridge) avatar(jid string, want bool) string {
	b.mu.Lock()
	path, known := b.avatars[jid]
	b.mu.Unlock()
	var kept portrait
	if !known {
		_ = json.Unmarshal([]byte(b.store.get("avatar:"+jid)), &kept)
		path = kept.Path
		if path != "" {
			if _, err := os.Stat(path); err != nil {
				path, kept = "", portrait{}
			}
		}
		b.mu.Lock()
		b.avatars[jid] = path
		b.mu.Unlock()
		if want && time.Now().Unix()-kept.Checked > 86400 {
			b.mu.Lock()
			if !b.queued[jid] {
				b.queued[jid] = true
				select {
				case b.wanted <- jid:
				default:
					delete(b.queued, jid)
				}
			}
			b.mu.Unlock()
		}
	}
	return path
}

func (b *Bridge) avatarWorker() {
	for text := range b.wanted {
		for !b.cli.IsConnected() || !b.cli.IsLoggedIn() {
			time.Sleep(3 * time.Second)
		}
		b.loadAvatar(text)
		b.mu.Lock()
		delete(b.queued, text)
		b.mu.Unlock()
		time.Sleep(350 * time.Millisecond)
	}
}

func (b *Bridge) loadAvatar(text string) {
	jid, err := types.ParseJID(text)
	if err != nil {
		return
	}
	var kept portrait
	_ = json.Unmarshal([]byte(b.store.get("avatar:"+text)), &kept)
	if kept.Path != "" {
		if _, err := os.Stat(kept.Path); err != nil {
			kept = portrait{}
		}
	}
	found, err := b.cli.GetProfilePictureInfo(b.ctx, jid, &whatsmeow.GetProfilePictureParams{Preview: true, ExistingID: kept.ID})
	kept.Checked = time.Now().Unix()
	if errors.Is(err, whatsmeow.ErrProfilePictureNotSet) || errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized) {
		kept.ID, kept.Path = "", ""
	} else if err == nil && found != nil && found.URL != "" {
		folder := filepath.Join(b.cache, "avatars")
		_ = os.MkdirAll(folder, 0o700)
		path := filepath.Join(folder, fileKey(text, found.ID)+".jpg")
		if download(found.URL, path) == nil {
			if kept.Path != "" && kept.Path != path {
				_ = os.Remove(kept.Path)
			}
			kept.ID, kept.Path = found.ID, path
		}
	} else if err != nil {
		// asked again another time
		return
	}
	data, _ := json.Marshal(kept)
	b.store.set("avatar:"+text, string(data))
	b.mu.Lock()
	changed := b.avatars[text] != kept.Path
	b.avatars[text] = kept.Path
	b.mu.Unlock()
	if changed {
		b.touchChats()
		b.touchChat("")
	}
}

func download(address, path string) error {
	client := &http.Client{Timeout: 60 * time.Second}
	response, err := client.Get(address)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", response.StatusCode)
	}
	file, err := os.Create(path + ".part")
	if err != nil {
		return err
	}
	_, err = io.Copy(file, io.LimitReader(response.Body, 64<<20))
	_ = file.Close()
	if err != nil {
		_ = os.Remove(path + ".part")
		return err
	}
	return os.Rename(path+".part", path)
}

// ── groups ──────────────────────────────────────────────────────────────
func (b *Bridge) keepGroup(group *types.GroupInfo) {
	chat := group.JID.String()
	b.store.chatSet(chat, "name", group.Name)
	if group.IsEphemeral {
		b.store.chatSet(chat, "ephemeral", int64(group.DisappearingTimer))
	}
	b.mu.Lock()
	b.groups[chat] = group
	delete(b.names, chat)
	b.mu.Unlock()
}

func (b *Bridge) refreshGroups() {
	groups, err := b.cli.GetJoinedGroups(b.ctx)
	if err != nil {
		return
	}
	for _, group := range groups {
		b.keepGroup(group)
	}
	b.touchChats()
}

func (b *Bridge) group(chat string) *types.GroupInfo {
	b.mu.Lock()
	known := b.groups[chat]
	b.mu.Unlock()
	if known != nil {
		return known
	}
	jid, err := types.ParseJID(chat)
	if err != nil || jid.Server != types.GroupServer {
		return nil
	}
	group, err := b.cli.GetGroupInfo(b.ctx, jid)
	if err != nil {
		return nil
	}
	b.keepGroup(group)
	return group
}

func (b *Bridge) listed(people []types.JID) string {
	names := []string{}
	for _, person := range people {
		names = append(names, strings.TrimPrefix(b.name(b.canon(person).String()), "~"))
	}
	return strings.Join(names, ", ")
}

// what happened to a group is a line in its chat
func (b *Bridge) groupChanged(evt *events.GroupInfo) {
	chat := evt.JID.String()
	who := "Someone"
	sender := ""
	if evt.Sender != nil {
		actor := *evt.Sender
		if evt.SenderPN != nil && !evt.SenderPN.IsEmpty() {
			actor = *evt.SenderPN
		}
		sender = b.canon(actor).String()
		who = strings.TrimPrefix(b.name(sender), "~")
	}
	lines := []string{}
	if evt.Name != nil {
		b.store.chatSet(chat, "name", evt.Name.Name)
		lines = append(lines, fmt.Sprintf("%s named the group “%s”", who, evt.Name.Name))
	}
	if evt.Topic != nil {
		lines = append(lines, who+" changed the description")
	}
	if evt.Ephemeral != nil {
		b.store.chatSet(chat, "ephemeral", int64(evt.Ephemeral.DisappearingTimer))
	}
	if len(evt.Join) > 0 {
		lines = append(lines, b.listed(evt.Join)+" joined")
	}
	if len(evt.Leave) > 0 {
		lines = append(lines, b.listed(evt.Leave)+" left")
	}
	if len(evt.Promote) > 0 {
		lines = append(lines, b.listed(evt.Promote)+" became admin")
	}
	if len(evt.Demote) > 0 {
		lines = append(lines, b.listed(evt.Demote)+" is no admin any more")
	}
	b.mu.Lock()
	delete(b.groups, chat)
	delete(b.names, chat)
	b.mu.Unlock()
	for index, line := range lines {
		b.store.put(&Row{Chat: chat, ID: fmt.Sprintf("group-%d-%d", evt.Timestamp.UnixNano(), index), Sender: sender, TS: evt.Timestamp.Unix(), Kind: "system", Text: line})
	}
	b.touchChats()
	b.touchChat(chat)
}
