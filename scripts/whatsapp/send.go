package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
	"google.golang.org/protobuf/proto"
)

// What is sent: text, files as what they are (photo, video, GIF, voice
// message, sticker, document), and what is done to a message that is there.

type FileSpec struct {
	Path string `json:"path"`
	// "" (what the file is) | "document" | "voice" | "sticker" | "gif"
	As string `json:"as"`
}

func (b *Bridge) scratch(name string) string {
	folder := filepath.Join(b.cache, "out")
	_ = os.MkdirAll(folder, 0o700)
	return filepath.Join(folder, fmt.Sprintf("%d-%s", time.Now().UnixNano(), name))
}

func ffmpeg(args ...string) error {
	command := exec.Command("ffmpeg", append([]string{"-y", "-loglevel", "error", "-nostdin"}, args...)...)
	var problem bytes.Buffer
	command.Stderr = &problem
	if err := command.Run(); err != nil {
		lines := strings.Split(strings.TrimSpace(problem.String()), "\n")
		return fmt.Errorf("ffmpeg: %s", lines[len(lines)-1])
	}
	return nil
}

// probe is what ffprobe knows of a file: width, height, seconds
func probe(path string) (int, int, int) {
	out, err := exec.Command("ffprobe", "-v", "error", "-show_entries", "stream=width,height:format=duration", "-of", "json", path).Output()
	if err != nil {
		return 0, 0, 0
	}
	var data struct {
		Streams []struct{ Width, Height int }
		Format  struct{ Duration string }
	}
	_ = json.Unmarshal(out, &data)
	width, height := 0, 0
	for _, stream := range data.Streams {
		if stream.Width > 0 {
			width, height = stream.Width, stream.Height
		}
	}
	seconds, _ := strconv.ParseFloat(data.Format.Duration, 64)
	return width, height, int(seconds + 0.5)
}

func small(picture image.Image, limit int) []byte {
	bounds := picture.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width == 0 || height == 0 {
		return nil
	}
	scale := float64(limit) / float64(max(width, height))
	if scale > 1 {
		scale = 1
	}
	target := image.NewRGBA(image.Rect(0, 0, max(1, int(float64(width)*scale)), max(1, int(float64(height)*scale))))
	draw.ApproxBiLinear.Scale(target, target.Bounds(), picture, bounds, draw.Src, nil)
	var out bytes.Buffer
	if jpeg.Encode(&out, target, &jpeg.Options{Quality: 55}) != nil {
		return nil
	}
	return out.Bytes()
}

func frame(path string) []byte {
	out, err := exec.Command("ffmpeg", "-loglevel", "error", "-nostdin", "-i", path, "-frames:v", "1", "-vf", "scale=100:-2", "-f", "image2pipe", "-vcodec", "mjpeg", "-").Output()
	if err != nil {
		return nil
	}
	return out
}

// how loud a voice message is over its length, in 64 steps
func waveform(path string) []byte {
	out, err := exec.Command("ffmpeg", "-loglevel", "error", "-nostdin", "-i", path, "-ac", "1", "-ar", "4000", "-f", "s8", "-").Output()
	if err != nil || len(out) < 64 {
		return nil
	}
	wave := make([]byte, 64)
	step := len(out) / 64
	loudest := 1
	levels := make([]int, 64)
	for index := range levels {
		for _, sample := range out[index*step : (index+1)*step] {
			level := int(int8(sample))
			if level < 0 {
				level = -level
			}
			levels[index] = max(levels[index], level)
		}
		loudest = max(loudest, levels[index])
	}
	for index, level := range levels {
		wave[index] = byte(level * 100 / loudest)
	}
	return wave
}

func typeOf(path string) string {
	if kind := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); kind != "" {
		return strings.SplitN(kind, ";", 2)[0]
	}
	file, err := os.Open(path)
	if err != nil {
		return "application/octet-stream"
	}
	defer file.Close()
	head := make([]byte, 512)
	count, _ := file.Read(head)
	return strings.SplitN(http.DetectContentType(head[:count]), ";", 2)[0]
}

func animatedWebp(data []byte) bool {
	return len(data) > 64 && bytes.Contains(data[:min(len(data), 256)], []byte("ANIM"))
}

func setContext(msg *waE2E.Message, ctx *waE2E.ContextInfo) {
	if ctx == nil {
		return
	}
	switch {
	case msg.ExtendedTextMessage != nil:
		msg.ExtendedTextMessage.ContextInfo = ctx
	case msg.ImageMessage != nil:
		msg.ImageMessage.ContextInfo = ctx
	case msg.VideoMessage != nil:
		msg.VideoMessage.ContextInfo = ctx
	case msg.AudioMessage != nil:
		msg.AudioMessage.ContextInfo = ctx
	case msg.StickerMessage != nil:
		msg.StickerMessage.ContextInfo = ctx
	case msg.DocumentMessage != nil:
		msg.DocumentMessage.ContextInfo = ctx
	case msg.LocationMessage != nil:
		msg.LocationMessage.ContextInfo = ctx
	case msg.ContactMessage != nil:
		msg.ContactMessage.ContextInfo = ctx
	case msg.ContactsArrayMessage != nil:
		msg.ContactsArrayMessage.ContextInfo = ctx
	case pollOf(msg) != nil:
		pollOf(msg).ContextInfo = ctx
	}
}

// what a message carries besides itself: what it answers, who it names, when it disappears
func (b *Bridge) context(chat, reply string, mentions []string) *waE2E.ContextInfo {
	ctx := &waE2E.ContextInfo{}
	used := false
	if reply != "" {
		if row := b.store.message(chat, reply); row != nil {
			ctx.StanzaID = proto.String(row.ID)
			ctx.Participant = proto.String(b.info(row).Sender.String())
			quoted := &waE2E.Message{}
			if len(row.Raw) > 0 && proto.Unmarshal(row.Raw, quoted) == nil {
				setContext(quoted, &waE2E.ContextInfo{})
			} else {
				quoted = &waE2E.Message{Conversation: proto.String(row.Text)}
			}
			ctx.QuotedMessage = quoted
			used = true
		}
	}
	if len(mentions) > 0 {
		ctx.MentionedJID = mentions
		used = true
	}
	if seconds := b.store.chat(chat).Ephemeral; seconds > 0 {
		ctx.Expiration = proto.Uint32(uint32(seconds))
		used = true
	}
	if !used {
		return nil
	}
	return ctx
}

func textMessage(text string, ctx *waE2E.ContextInfo) *waE2E.Message {
	if ctx == nil {
		return &waE2E.Message{Conversation: proto.String(text)}
	}
	return &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ctx}}
}

// deliver shows a message in its chat at once and sends it; one that did not go out stays, to be sent again.
func (b *Bridge) deliver(chat string, msg *waE2E.Message, local string) {
	jid, err := types.ParseJID(chat)
	if err != nil || b.cli.Store.ID == nil {
		b.fail("Not signed in", nil)
		return
	}
	id := b.cli.GenerateMessageID()
	parsed := b.parse(msg, id)
	if parsed == nil {
		return
	}
	if parsed.extra.Media != nil && local != "" {
		parsed.extra.Media.Path = local
	}
	raw, _ := proto.Marshal(msg)
	row := &Row{Chat: chat, ID: id, Sender: b.cli.Store.ID.ToNonAD().String(), TS: time.Now().Unix(), Mine: true, Kind: parsed.kind, Text: parsed.text, Extra: parsed.extra, Raw: raw, Status: statusPending}
	b.store.put(row)
	b.store.chatSet(chat, "unread", 0)
	b.store.chatSet(chat, "marked", false)
	b.touchChats()
	b.touchChat(chat)
	if demo {
		time.AfterFunc(900*time.Millisecond, func() {
			b.store.setStatus(chat, id, statusRead)
			b.touchChats()
			b.touchChat(chat)
		})
		return
	}
	b.sends <- func() { b.transmit(jid, id, msg) }
}

func (b *Bridge) transmit(jid types.JID, id string, msg *waE2E.Message) {
	chat := jid.String()
	response, err := b.cli.SendMessage(b.ctx, jid, msg, whatsmeow.SendRequestExtra{ID: id})
	row := b.store.message(chat, id)
	if row == nil {
		return
	}
	if err != nil {
		row.Status = statusFailed
		row.Extra.Error = err.Error()
	} else {
		row.Extra.Error = ""
		if row.Status < statusSent {
			row.Status = statusSent
		}
		row.TS = response.Timestamp.Unix()
	}
	b.store.update(row)
	b.touchChats()
	b.touchChat(chat)
}

func (b *Bridge) retry(chat, id string) {
	row := b.store.message(chat, id)
	jid, err := types.ParseJID(chat)
	msg := &waE2E.Message{}
	if row == nil || err != nil || row.Status != statusFailed || proto.Unmarshal(row.Raw, msg) != nil {
		return
	}
	row.Status = statusPending
	row.Extra.Error = ""
	b.store.update(row)
	b.touchChat(chat)
	b.sends <- func() { b.transmit(jid, id, msg) }
}

func (b *Bridge) send(c *Command) {
	text := strings.TrimSpace(c.Text)
	ctx := b.context(c.Chat, c.Reply, c.Mentions)
	if len(c.Files) == 0 {
		if text != "" {
			b.deliver(c.Chat, textMessage(text, ctx), "")
		}
		return
	}
	for _, file := range c.Files {
		msg, local, captioned, err := b.media(file, text)
		if err != nil {
			b.fail(filepath.Base(file.Path), err)
			continue
		}
		if captioned {
			text = ""
		}
		setContext(msg, ctx)
		b.deliver(c.Chat, msg, local)
	}
	// what was written beside a file that carries no words goes after it
	if text != "" {
		b.deliver(c.Chat, textMessage(text, b.context(c.Chat, "", c.Mentions)), "")
	}
}

// media makes the message a file is sent as; `local` is the file the chat shows for it.
func (b *Bridge) media(file FileSpec, caption string) (msg *waE2E.Message, local string, captioned bool, err error) {
	path := file.Path
	stat, err := os.Stat(path)
	if err != nil {
		return nil, "", false, fmt.Errorf("no such file")
	}
	if stat.Size() > 1<<30 {
		return nil, "", false, fmt.Errorf("too large")
	}
	kind := typeOf(path)
	as := file.As
	if as == "" {
		switch {
		case kind == "image/gif":
			as = "gif"
		case strings.HasPrefix(kind, "image/") && kind != "image/svg+xml":
			as = "image"
		case strings.HasPrefix(kind, "video/"):
			as = "video"
		case strings.HasPrefix(kind, "audio/"):
			as = "audio"
		default:
			as = "document"
		}
	}
	name := filepath.Base(path)
	switch as {
	case "gif", "video":
		if kind != "video/mp4" || as == "gif" {
			target := b.scratch("video.mp4")
			args := []string{"-i", path, "-movflags", "+faststart", "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-crf", "24"}
			if as == "gif" {
				args = append(args, "-an")
			} else {
				args = append(args, "-c:a", "aac")
			}
			if err := ffmpeg(append(args, target)...); err != nil {
				return nil, "", false, err
			}
			path, kind = target, "video/mp4"
		}
	case "voice":
		target := b.scratch("voice.ogg")
		if err := ffmpeg("-i", path, "-vn", "-c:a", "libopus", "-b:a", "32k", "-ac", "1", "-ar", "48000", "-application", "voip", target); err != nil {
			return nil, "", false, err
		}
		path, kind = target, "audio/ogg; codecs=opus"
	case "sticker":
		if kind != "image/webp" {
			target, err := b.toSticker(path, kind)
			if err != nil {
				return nil, "", false, err
			}
			path, kind = target, "image/webp"
		}
	case "image":
		if kind != "image/jpeg" && kind != "image/png" {
			target := b.scratch("image.jpg")
			if err := ffmpeg("-i", path, "-frames:v", "1", "-q:v", "3", target); err != nil {
				return nil, "", false, err
			}
			path, kind = target, "image/jpeg"
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", false, err
	}
	// a copy the chat keeps showing when the file itself moved on
	local = filepath.Join(b.cache, "media", fileKey(path, strconv.FormatInt(time.Now().UnixNano(), 10))+filepath.Ext(path))
	_ = os.MkdirAll(filepath.Dir(local), 0o700)
	if os.Link(path, local) != nil {
		if os.WriteFile(local, data, 0o600) != nil {
			local = path
		}
	}
	upload := func(as whatsmeow.MediaType) (whatsmeow.UploadResponse, error) {
		if demo {
			return whatsmeow.UploadResponse{FileLength: uint64(len(data))}, nil
		}
		return b.cli.Upload(b.ctx, data, as)
	}
	msg = &waE2E.Message{}
	switch as {
	case "image":
		sent, err := upload(whatsmeow.MediaImage)
		if err != nil {
			return nil, "", false, err
		}
		image := &waE2E.ImageMessage{
			URL: &sent.URL, DirectPath: &sent.DirectPath, MediaKey: sent.MediaKey, Mimetype: &kind,
			FileEncSHA256: sent.FileEncSHA256, FileSHA256: sent.FileSHA256, FileLength: &sent.FileLength,
		}
		if picture, _, err := imageOf(data); err == nil {
			image.Width, image.Height = proto.Uint32(uint32(picture.Bounds().Dx())), proto.Uint32(uint32(picture.Bounds().Dy()))
			image.JPEGThumbnail = small(picture, 100)
		}
		if caption != "" {
			image.Caption = &caption
		}
		msg.ImageMessage = image
		return msg, local, true, nil
	case "video", "gif":
		sent, err := upload(whatsmeow.MediaVideo)
		if err != nil {
			return nil, "", false, err
		}
		width, height, seconds := probe(path)
		video := &waE2E.VideoMessage{
			URL: &sent.URL, DirectPath: &sent.DirectPath, MediaKey: sent.MediaKey, Mimetype: &kind,
			FileEncSHA256: sent.FileEncSHA256, FileSHA256: sent.FileSHA256, FileLength: &sent.FileLength,
			Width: proto.Uint32(uint32(width)), Height: proto.Uint32(uint32(height)), Seconds: proto.Uint32(uint32(seconds)),
			JPEGThumbnail: frame(path),
		}
		if as == "gif" {
			video.GifPlayback = proto.Bool(true)
		}
		if caption != "" {
			video.Caption = &caption
		}
		msg.VideoMessage = video
		return msg, local, true, nil
	case "voice", "audio":
		sent, err := upload(whatsmeow.MediaAudio)
		if err != nil {
			return nil, "", false, err
		}
		_, _, seconds := probe(path)
		audio := &waE2E.AudioMessage{
			URL: &sent.URL, DirectPath: &sent.DirectPath, MediaKey: sent.MediaKey, Mimetype: &kind,
			FileEncSHA256: sent.FileEncSHA256, FileSHA256: sent.FileSHA256, FileLength: &sent.FileLength,
			Seconds: proto.Uint32(uint32(seconds)),
		}
		if as == "voice" {
			audio.PTT = proto.Bool(true)
			audio.Waveform = waveform(path)
		}
		msg.AudioMessage = audio
		return msg, local, false, nil
	case "sticker":
		sent, err := upload(whatsmeow.MediaImage)
		if err != nil {
			return nil, "", false, err
		}
		msg.StickerMessage = &waE2E.StickerMessage{
			URL: &sent.URL, DirectPath: &sent.DirectPath, MediaKey: sent.MediaKey, Mimetype: &kind,
			FileEncSHA256: sent.FileEncSHA256, FileSHA256: sent.FileSHA256, FileLength: &sent.FileLength,
			Width: proto.Uint32(512), Height: proto.Uint32(512), IsAnimated: proto.Bool(animatedWebp(data)),
		}
		b.keepSticker(path, false)
		return msg, shown(local, animatedWebp(data)), false, nil
	}
	sent, err := upload(whatsmeow.MediaDocument)
	if err != nil {
		return nil, "", false, err
	}
	document := &waE2E.DocumentMessage{
		URL: &sent.URL, DirectPath: &sent.DirectPath, MediaKey: sent.MediaKey, Mimetype: &kind,
		FileEncSHA256: sent.FileEncSHA256, FileSHA256: sent.FileSHA256, FileLength: &sent.FileLength,
		FileName: &name, Title: &name,
	}
	if caption != "" {
		document.Caption = &caption
	}
	msg.DocumentMessage = document
	return msg, local, true, nil
}

// toSticker makes the 512 pixel WebP a sticker is out of a picture, a GIF or a video.
func (b *Bridge) toSticker(path, kind string) (string, error) {
	target := b.scratch("sticker.webp")
	fit := "scale=512:512:force_original_aspect_ratio=decrease,format=rgba,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=#00000000"
	args := []string{"-i", path, "-vf", fit, "-c:v", "libwebp", "-q:v", "80", "-frames:v", "1"}
	if kind == "image/gif" || strings.HasPrefix(kind, "video/") {
		args = []string{"-t", "6", "-i", path, "-vf", "fps=15," + fit, "-c:v", "libwebp_anim", "-q:v", "60", "-loop", "0", "-an"}
	}
	return target, ffmpeg(append(args, target)...)
}

func imageOf(data []byte) (image.Image, string, error) {
	return image.Decode(bytes.NewReader(data))
}

// sendFrom sends what lies at an address (a GIF or sticker that was searched for).
func (b *Bridge) sendFrom(c *Command) {
	ending := ".mp4"
	if c.Kind == "sticker" {
		ending = filepath.Ext(strings.SplitN(c.URL, "?", 2)[0])
		if ending == "" {
			ending = ".webp"
		}
	}
	path := b.scratch("found" + ending)
	if err := download(c.URL, path); err != nil {
		b.fail("Download", err)
		return
	}
	c.Files = []FileSpec{{Path: path, As: c.Kind}}
	c.Text = ""
	b.send(c)
}

// ── what is done to a message ───────────────────────────────────────────
func (b *Bridge) quick(chat string, msg *waE2E.Message, what string) bool {
	if demo {
		return true
	}
	jid, err := types.ParseJID(chat)
	if err == nil {
		_, err = b.cli.SendMessage(b.ctx, jid, msg)
	}
	if err != nil {
		b.fail(what, err)
		return false
	}
	return true
}

func (b *Bridge) react(c *Command) {
	row := b.store.message(c.Chat, c.ID)
	if row == nil || b.cli.Store.ID == nil {
		return
	}
	info := b.info(row)
	me := b.cli.Store.ID.ToNonAD().String()
	before := ""
	for _, reaction := range b.store.reactions(c.Chat)[c.ID] {
		if reaction[0] == me {
			before = reaction[1]
		}
	}
	emoji := c.Emoji
	// the same once more takes it back
	if emoji == before {
		emoji = ""
	}
	b.store.react(c.Chat, c.ID, me, emoji, time.Now().Unix())
	b.touchChat(c.Chat)
	if !b.quick(c.Chat, b.cli.BuildReaction(info.Chat, info.Sender, row.ID, emoji), "Reaction") {
		b.store.react(c.Chat, c.ID, me, before, time.Now().Unix())
		b.touchChat(c.Chat)
	}
}

func (b *Bridge) edit(c *Command) {
	row := b.store.message(c.Chat, c.ID)
	text := strings.TrimSpace(c.Text)
	if row == nil || !row.Mine || text == "" {
		return
	}
	jid, _ := types.ParseJID(c.Chat)
	content := &waE2E.Message{}
	if row.Extra.Media != nil && proto.Unmarshal(row.Raw, content) == nil {
		// a caption
		switch {
		case content.ImageMessage != nil:
			content.ImageMessage.Caption = &text
		case content.VideoMessage != nil:
			content.VideoMessage.Caption = &text
		case content.DocumentMessage != nil:
			content.DocumentMessage.Caption = &text
		default:
			return
		}
	} else {
		content = textMessage(text, b.context(c.Chat, "", c.Mentions))
	}
	if !b.quick(c.Chat, b.cli.BuildEdit(jid, row.ID, content), "Edit") {
		return
	}
	row.Text = text
	row.Extra.Edited = true
	row.Extra.Mentions = c.Mentions
	b.store.update(row)
	b.touchChats()
	b.touchChat(c.Chat)
}

// revoke deletes a message for everyone
func (b *Bridge) revoke(c *Command) {
	row := b.store.message(c.Chat, c.ID)
	if row == nil {
		return
	}
	if row.Status == statusFailed || row.Status == statusPending {
		b.store.remove(c.Chat, c.ID)
	} else {
		info := b.info(row)
		sender := info.Sender
		if row.Mine {
			sender = types.EmptyJID
		}
		if !b.quick(c.Chat, b.cli.BuildRevoke(info.Chat, sender, row.ID), "Delete") {
			return
		}
		row.Kind, row.Text, row.Raw = "deleted", "", nil
		row.Extra = Extra{Deleted: true, Origin: row.Extra.Origin}
		b.store.update(row)
	}
	b.touchChats()
	b.touchChat(c.Chat)
}

func (b *Bridge) forward(c *Command) {
	row := b.store.message(c.Chat, c.ID)
	msg := &waE2E.Message{}
	if row == nil || len(row.Raw) == 0 || proto.Unmarshal(row.Raw, msg) != nil {
		b.fail("This message cannot be forwarded", nil)
		return
	}
	if text := msg.GetConversation(); text != "" {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: &text}}
	}
	local := ""
	if row.Extra.Media != nil {
		local = row.Extra.Media.Path
	}
	for _, target := range c.To {
		copied := proto.Clone(msg).(*waE2E.Message)
		copied.MessageContextInfo = nil
		ctx := &waE2E.ContextInfo{}
		if !row.Mine {
			ctx.IsForwarded = proto.Bool(true)
			ctx.ForwardingScore = proto.Uint32(contextOf(msg).GetForwardingScore() + 1)
		}
		if seconds := b.store.chat(target).Ephemeral; seconds > 0 {
			ctx.Expiration = proto.Uint32(uint32(seconds))
		}
		setContext(copied, ctx)
		b.deliver(target, copied, local)
	}
}

func (b *Bridge) poll(c *Command) {
	options := []string{}
	for _, option := range c.Options {
		if option = strings.TrimSpace(option); option != "" {
			options = append(options, option)
		}
	}
	if strings.TrimSpace(c.Text) == "" || len(options) < 2 {
		b.fail("A poll needs a question and two answers", nil)
		return
	}
	selectable := 1
	if c.Multi {
		selectable = 0
	}
	b.deliver(c.Chat, b.cli.BuildPollCreation(strings.TrimSpace(c.Text), options, selectable), "")
}

func (b *Bridge) vote(c *Command) {
	row := b.store.message(c.Chat, c.ID)
	if row == nil || row.Extra.Poll == nil || b.cli.Store.ID == nil {
		return
	}
	msg, err := b.cli.BuildPollVote(b.ctx, b.info(row), c.Options)
	if err != nil {
		b.fail("Vote", err)
		return
	}
	if b.quick(c.Chat, msg, "Vote") {
		b.store.vote(c.Chat, c.ID, b.cli.Store.ID.ToNonAD().String(), c.Options, time.Now().Unix())
		b.touchChat(c.Chat)
	}
}

func (b *Bridge) place(c *Command) {
	place := &waE2E.LocationMessage{DegreesLatitude: &c.Lat, DegreesLongitude: &c.Lng}
	if c.Name != "" {
		place.Name = &c.Name
	}
	msg := &waE2E.Message{LocationMessage: place}
	setContext(msg, b.context(c.Chat, c.Reply, nil))
	b.deliver(c.Chat, msg, "")
}

// contact sends people as cards
func (b *Bridge) contact(c *Command) {
	cards := []*waE2E.ContactMessage{}
	for _, person := range c.People {
		jid, err := types.ParseJID(person)
		if err != nil || jid.Server != types.DefaultUserServer {
			continue
		}
		name := strings.TrimPrefix(b.name(person), "~")
		vcard := fmt.Sprintf("BEGIN:VCARD\nVERSION:3.0\nFN:%s\nTEL;type=CELL;waid=%s:+%s\nEND:VCARD", name, jid.User, jid.User)
		cards = append(cards, &waE2E.ContactMessage{DisplayName: &name, Vcard: &vcard})
	}
	if len(cards) == 0 {
		return
	}
	msg := &waE2E.Message{ContactMessage: cards[0]}
	if len(cards) > 1 {
		msg = &waE2E.Message{ContactsArrayMessage: &waE2E.ContactsArrayMessage{DisplayName: proto.String(fmt.Sprintf("%d contacts", len(cards))), Contacts: cards}}
	}
	setContext(msg, b.context(c.Chat, c.Reply, nil))
	b.deliver(c.Chat, msg, "")
}

// ── voice messages ──────────────────────────────────────────────────────
type recording struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	path    string
	started time.Time
}

func (b *Bridge) startRecording() {
	b.mu.Lock()
	busy := b.recorder != nil
	b.mu.Unlock()
	if busy {
		return
	}
	path := b.scratch("voice.ogg")
	command := exec.Command("ffmpeg", "-y", "-loglevel", "error", "-f", "pulse", "-i", "default", "-ac", "1", "-ar", "48000", "-c:a", "libopus", "-b:a", "32k", "-application", "voip", path)
	stdin, err := command.StdinPipe()
	if err == nil {
		err = command.Start()
	}
	if err != nil {
		b.fail("Recording", err)
		return
	}
	b.mu.Lock()
	b.recorder = &recording{command: command, stdin: stdin, path: path, started: time.Now()}
	b.mu.Unlock()
	b.emit("recording", map[string]any{"on": true})
}

// stopRecording ends the recording; with `keep` its file is returned.
func (b *Bridge) stopRecording(keep bool) string {
	b.mu.Lock()
	recorder := b.recorder
	b.recorder = nil
	b.mu.Unlock()
	if recorder == nil {
		return ""
	}
	// ffmpeg finishes the file when it is told to quit
	_, _ = recorder.stdin.Write([]byte("q"))
	_ = recorder.stdin.Close()
	done := make(chan struct{})
	go func() {
		_ = recorder.command.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		_ = recorder.command.Process.Kill()
	}
	b.emit("recording", map[string]any{"on": false})
	if !keep || time.Since(recorder.started) < 700*time.Millisecond {
		_ = os.Remove(recorder.path)
		return ""
	}
	return recorder.path
}
