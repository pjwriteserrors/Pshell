package main

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"html"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
)

// A message as WhatsApp sends it, taken apart into what the panel shows.
type parsed struct {
	kind  string
	text  string
	extra Extra
	ctx   *waE2E.ContextInfo
	thumb []byte
}

func fileKey(parts ...string) string {
	sum := sha1.Sum([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(sum[:])[:24]
}

// the part of a message that is a file on WhatsApp's servers, and the ending its file gets
func downloadable(msg *waE2E.Message) (whatsmeow.DownloadableMessage, string) {
	switch {
	case msg.GetImageMessage() != nil:
		return msg.GetImageMessage(), extension(msg.GetImageMessage().GetMimetype(), ".jpg")
	case msg.GetVideoMessage() != nil:
		return msg.GetVideoMessage(), extension(msg.GetVideoMessage().GetMimetype(), ".mp4")
	case msg.GetPtvMessage() != nil:
		return msg.GetPtvMessage(), ".mp4"
	case msg.GetAudioMessage() != nil:
		return msg.GetAudioMessage(), extension(msg.GetAudioMessage().GetMimetype(), ".ogg")
	case msg.GetStickerMessage() != nil:
		return msg.GetStickerMessage(), ".webp"
	case msg.GetDocumentMessage() != nil:
		document := msg.GetDocumentMessage()
		ending := filepath.Ext(document.GetFileName())
		if ending == "" {
			ending = extension(document.GetMimetype(), ".bin")
		}
		return document, ending
	}
	return nil, ""
}

var endings = map[string]string{
	"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif",
	"video/mp4": ".mp4", "video/3gpp": ".3gp", "video/quicktime": ".mov", "video/webm": ".webm",
	"audio/ogg": ".ogg", "audio/mpeg": ".mp3", "audio/mp4": ".m4a", "audio/aac": ".aac", "audio/amr": ".amr", "audio/wav": ".wav",
	"application/pdf": ".pdf",
}

func extension(mime, fallback string) string {
	mime = strings.TrimSpace(strings.SplitN(mime, ";", 2)[0])
	if ending, ok := endings[mime]; ok {
		return ending
	}
	return fallback
}

func contextOf(msg *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case msg.GetExtendedTextMessage() != nil:
		return msg.GetExtendedTextMessage().GetContextInfo()
	case msg.GetImageMessage() != nil:
		return msg.GetImageMessage().GetContextInfo()
	case msg.GetVideoMessage() != nil:
		return msg.GetVideoMessage().GetContextInfo()
	case msg.GetPtvMessage() != nil:
		return msg.GetPtvMessage().GetContextInfo()
	case msg.GetAudioMessage() != nil:
		return msg.GetAudioMessage().GetContextInfo()
	case msg.GetStickerMessage() != nil:
		return msg.GetStickerMessage().GetContextInfo()
	case msg.GetDocumentMessage() != nil:
		return msg.GetDocumentMessage().GetContextInfo()
	case msg.GetLocationMessage() != nil:
		return msg.GetLocationMessage().GetContextInfo()
	case msg.GetLiveLocationMessage() != nil:
		return msg.GetLiveLocationMessage().GetContextInfo()
	case msg.GetContactMessage() != nil:
		return msg.GetContactMessage().GetContextInfo()
	case msg.GetContactsArrayMessage() != nil:
		return msg.GetContactsArrayMessage().GetContextInfo()
	case pollOf(msg) != nil:
		return pollOf(msg).GetContextInfo()
	}
	return nil
}

func pollOf(msg *waE2E.Message) *waE2E.PollCreationMessage {
	for _, poll := range []*waE2E.PollCreationMessage{msg.GetPollCreationMessage(), msg.GetPollCreationMessageV2(), msg.GetPollCreationMessageV3()} {
		if poll != nil {
			return poll
		}
	}
	return nil
}

var telephone = regexp.MustCompile(`(?im)^TEL[^:\n]*:(.+)$`)

func card(name, vcard string) Card {
	entry := Card{Name: name, Vcard: vcard, Phones: []string{}}
	for _, found := range telephone.FindAllStringSubmatch(vcard, -1) {
		entry.Phones = append(entry.Phones, strings.TrimSpace(found[1]))
	}
	return entry
}

// parse returns nil for what is not shown as a message of its own.
func (b *Bridge) parse(msg *waE2E.Message, id string) *parsed {
	if msg == nil {
		return nil
	}
	out := &parsed{ctx: contextOf(msg)}
	switch {
	case msg.GetConversation() != "":
		out.kind, out.text = "text", msg.GetConversation()
	case msg.GetExtendedTextMessage() != nil:
		text := msg.GetExtendedTextMessage()
		out.kind, out.text = "text", text.GetText()
		if text.GetTitle() != "" || len(text.GetJPEGThumbnail()) > 0 {
			address := text.GetMatchedText()
			if address != "" {
				out.extra.Link = &Link{URL: address, Title: text.GetTitle(), Description: text.GetDescription()}
				out.thumb = text.GetJPEGThumbnail()
			}
		}
	case msg.GetImageMessage() != nil:
		image := msg.GetImageMessage()
		out.kind, out.text = "image", image.GetCaption()
		out.extra.Media = &Media{Mime: image.GetMimetype(), Size: image.GetFileLength(), Width: int(image.GetWidth()), Height: int(image.GetHeight()), ViewOnce: image.GetViewOnce()}
		out.thumb = image.GetJPEGThumbnail()
	case msg.GetVideoMessage() != nil || msg.GetPtvMessage() != nil:
		video := msg.GetVideoMessage()
		if video == nil {
			video = msg.GetPtvMessage()
		}
		out.kind, out.text = "video", video.GetCaption()
		if video.GetGifPlayback() {
			out.kind = "gif"
		}
		out.extra.Media = &Media{Mime: video.GetMimetype(), Size: video.GetFileLength(), Width: int(video.GetWidth()), Height: int(video.GetHeight()), Seconds: int(video.GetSeconds()), ViewOnce: video.GetViewOnce()}
		out.thumb = video.GetJPEGThumbnail()
	case msg.GetAudioMessage() != nil:
		audio := msg.GetAudioMessage()
		out.kind = "audio"
		if audio.GetPTT() {
			out.kind = "voice"
		}
		out.extra.Media = &Media{Mime: audio.GetMimetype(), Size: audio.GetFileLength(), Seconds: int(audio.GetSeconds()), ViewOnce: audio.GetViewOnce()}
	case msg.GetStickerMessage() != nil:
		sticker := msg.GetStickerMessage()
		out.kind = "sticker"
		out.extra.Media = &Media{Mime: sticker.GetMimetype(), Size: sticker.GetFileLength(), Width: int(sticker.GetWidth()), Height: int(sticker.GetHeight()), Animated: sticker.GetIsAnimated()}
		if sticker.GetIsLottie() || strings.Contains(sticker.GetMimetype(), "was") {
			out.extra.Media.Error = "Animated sticker – shown on the phone"
		}
	case msg.GetDocumentMessage() != nil:
		document := msg.GetDocumentMessage()
		out.kind, out.text = "document", document.GetCaption()
		name := document.GetFileName()
		if name == "" {
			name = document.GetTitle()
		}
		out.extra.Media = &Media{Mime: document.GetMimetype(), Size: document.GetFileLength(), Name: name}
		out.thumb = document.GetJPEGThumbnail()
	case msg.GetLocationMessage() != nil:
		place := msg.GetLocationMessage()
		out.kind, out.text = "location", place.GetComment()
		out.extra.Place = &Place{Lat: place.GetDegreesLatitude(), Lng: place.GetDegreesLongitude(), Name: place.GetName(), Address: place.GetAddress()}
		out.thumb = place.GetJPEGThumbnail()
	case msg.GetLiveLocationMessage() != nil:
		place := msg.GetLiveLocationMessage()
		out.kind, out.text = "location", place.GetCaption()
		out.extra.Place = &Place{Lat: place.GetDegreesLatitude(), Lng: place.GetDegreesLongitude(), Live: true}
		out.thumb = place.GetJPEGThumbnail()
	case msg.GetContactMessage() != nil:
		contact := msg.GetContactMessage()
		out.kind = "contact"
		out.extra.Cards = []Card{card(contact.GetDisplayName(), contact.GetVcard())}
	case msg.GetContactsArrayMessage() != nil:
		out.kind = "contact"
		for _, contact := range msg.GetContactsArrayMessage().GetContacts() {
			out.extra.Cards = append(out.extra.Cards, card(contact.GetDisplayName(), contact.GetVcard()))
		}
	case pollOf(msg) != nil:
		poll := pollOf(msg)
		out.kind, out.text = "poll", poll.GetName()
		out.extra.Poll = &Poll{Multi: poll.GetSelectableOptionsCount() != 1, Options: []string{}}
		for _, option := range poll.GetOptions() {
			out.extra.Poll.Options = append(out.extra.Poll.Options, option.GetOptionName())
		}
	case msg.GetGroupInviteMessage() != nil:
		invite := msg.GetGroupInviteMessage()
		out.kind = "text"
		out.text = strings.TrimSpace(fmt.Sprintf("Invitation to the group “%s”\n%s", invite.GetGroupName(), invite.GetCaption()))
	case msg.GetButtonsMessage() != nil:
		out.kind, out.text = "text", msg.GetButtonsMessage().GetContentText()
	case msg.GetListMessage() != nil:
		out.kind, out.text = "text", strings.TrimSpace(msg.GetListMessage().GetTitle()+"\n"+msg.GetListMessage().GetDescription())
	case msg.GetTemplateMessage() != nil:
		out.kind, out.text = "text", msg.GetTemplateMessage().GetHydratedTemplate().GetHydratedContentText()
	case msg.GetInteractiveMessage() != nil:
		out.kind, out.text = "text", msg.GetInteractiveMessage().GetBody().GetText()
	case msg.GetEventMessage() != nil:
		event := msg.GetEventMessage()
		out.kind, out.text = "text", strings.TrimSpace("Event: "+event.GetName()+"\n"+event.GetDescription())
	case msg.GetCall() != nil || msg.GetBcallMessage() != nil || msg.GetCallLogMesssage() != nil:
		out.kind, out.text = "system", "Call"
	case msg.GetSenderKeyDistributionMessage() != nil, msg.GetMessageContextInfo() != nil && isBare(msg), msg.GetKeepInChatMessage() != nil,
		msg.GetPinInChatMessage() != nil, msg.GetPollUpdateMessage() != nil, msg.GetReactionMessage() != nil, msg.GetProtocolMessage() != nil:
		return nil
	default:
		if isBare(msg) {
			return nil
		}
		out.kind, out.text = "unsupported", ""
	}
	if out.kind == "text" && strings.TrimSpace(out.text) == "" {
		out.kind = "unsupported"
	}
	if out.ctx != nil {
		out.extra.Forwarded = out.ctx.GetIsForwarded()
		out.extra.Mentions = out.ctx.GetMentionedJID()
		if quoted := out.ctx.GetStanzaID(); quoted != "" {
			quote := &Quote{ID: quoted, Sender: b.canonString(out.ctx.GetParticipant())}
			if inner := b.parse(out.ctx.GetQuotedMessage(), ""); inner != nil {
				quote.Text = preview(&Row{Kind: inner.kind, Text: inner.text, Extra: inner.extra})
			}
			out.extra.Quote = quote
		}
	}
	if len(out.thumb) > 0 && id != "" {
		path := filepath.Join(b.cache, "thumbs", fileKey(id)+".jpg")
		if _, err := os.Stat(path); err != nil {
			_ = os.MkdirAll(filepath.Dir(path), 0o700)
			_ = os.WriteFile(path, out.thumb, 0o600)
		}
		if out.extra.Link != nil {
			out.extra.Link.Thumb = path
		} else if out.extra.Media != nil {
			out.extra.Media.Thumb = path
		}
	}
	return out
}

// nothing in it but what travels along with every message
func isBare(msg *waE2E.Message) bool {
	bare := &waE2E.Message{MessageContextInfo: msg.GetMessageContextInfo(), SenderKeyDistributionMessage: msg.GetSenderKeyDistributionMessage()}
	return len(msg.String()) == len(bare.String())
}

func clock(seconds int) string {
	return fmt.Sprintf("%d:%02d", seconds/60, seconds%60)
}

// preview is a message in a line: in the chat list, in a quote, in a notification.
func preview(row *Row) string {
	text := strings.Join(strings.Fields(row.Text), " ")
	if len([]rune(text)) > 160 {
		text = string([]rune(text)[:160]) + "…"
	}
	label := ""
	switch row.Kind {
	case "text", "system":
		return text
	case "image":
		label = "Photo"
	case "video":
		label = "Video"
	case "gif":
		label = "GIF"
	case "voice":
		label = "Voice message"
		if row.Extra.Media != nil && row.Extra.Media.Seconds > 0 {
			label += " (" + clock(row.Extra.Media.Seconds) + ")"
		}
	case "audio":
		label = "Audio"
	case "sticker":
		label = "Sticker"
	case "document":
		label = "Document"
		if row.Extra.Media != nil && row.Extra.Media.Name != "" {
			label = row.Extra.Media.Name
		}
	case "location":
		label = "Location"
		if row.Extra.Place != nil && row.Extra.Place.Name != "" {
			label = row.Extra.Place.Name
		}
	case "contact":
		label = "Contact"
		if len(row.Extra.Cards) == 1 {
			label = row.Extra.Cards[0].Name
		}
	case "poll":
		return "Poll: " + text
	case "deleted":
		return "Message deleted"
	case "waiting":
		return "Waiting for this message"
	default:
		return "Message – shown on the phone"
	}
	if text != "" {
		return label + ": " + text
	}
	return label
}

// ── text as WhatsApp marks it up ────────────────────────────────────────
func boundary(r rune) bool {
	return !unicode.IsLetter(r) && !unicode.IsDigit(r)
}

var marks = map[rune][2]string{
	'*': {"<b>", "</b>"}, '_': {"<i>", "</i>"}, '~': {"<s>", "</s>"}, '`': {"<code>", "</code>"},
}

func markup(text string, mentions map[string]string) string {
	var out strings.Builder
	parts := strings.Split(text, "```")
	for index, part := range parts {
		// between two fences, and only where the second one is there
		if index%2 == 1 && index < len(parts)-1 {
			out.WriteString("<code>" + strings.ReplaceAll(html.EscapeString(strings.Trim(part, "\n")), "\n", "<br>") + "</code>")
			continue
		}
		if index%2 == 1 {
			part = "```" + part
		}
		inline(&out, []rune(part), mentions)
	}
	return out.String()
}

func inline(out *strings.Builder, runes []rune, mentions map[string]string) {
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		free := i == 0 || boundary(runes[i-1])
		if tags, ok := marks[r]; ok && free && i+1 < len(runes) && !unicode.IsSpace(runes[i+1]) {
			end := -1
			for j := i + 2; j < len(runes); j++ {
				if runes[j] == '\n' {
					break
				}
				if runes[j] == r && !unicode.IsSpace(runes[j-1]) && (j+1 == len(runes) || boundary(runes[j+1])) {
					end = j
					break
				}
			}
			if end > 0 {
				out.WriteString(tags[0])
				if r == '`' {
					out.WriteString(html.EscapeString(string(runes[i+1 : end])))
				} else {
					inline(out, runes[i+1:end], mentions)
				}
				out.WriteString(tags[1])
				i = end
				continue
			}
		}
		rest := string(runes[i:min(i+8, len(runes))])
		if free && (strings.HasPrefix(rest, "http://") || strings.HasPrefix(rest, "https://") || strings.HasPrefix(rest, "www.")) {
			end := i
			for end < len(runes) && !unicode.IsSpace(runes[end]) {
				end++
			}
			for end > i && strings.ContainsRune(".,;:!?)\"'", runes[end-1]) {
				end--
			}
			address := string(runes[i:end])
			target := address
			if strings.HasPrefix(target, "www.") {
				target = "https://" + target
			}
			out.WriteString(`<a href="` + html.EscapeString(target) + `">` + html.EscapeString(address) + "</a>")
			i = end - 1
			continue
		}
		if r == '@' && len(mentions) > 0 {
			end := i + 1
			for end < len(runes) && unicode.IsDigit(runes[end]) {
				end++
			}
			if name, ok := mentions[string(runes[i+1:end])]; ok {
				out.WriteString("<b>@" + html.EscapeString(name) + "</b>")
				i = end - 1
				continue
			}
		}
		switch r {
		case '\n':
			out.WriteString("<br>")
		case '<':
			out.WriteString("&lt;")
		case '>':
			out.WriteString("&gt;")
		case '&':
			out.WriteString("&amp;")
		default:
			out.WriteRune(r)
		}
	}
}

// a few emoji and nothing else are shown large
func onlyEmoji(text string) bool {
	runes := []rune(strings.TrimSpace(text))
	if len(runes) == 0 || len(runes) > 12 {
		return false
	}
	for _, r := range runes {
		if r < 0x2000 && r != 0xa9 && r != 0xae {
			return false
		}
		if unicode.IsLetter(r) {
			return false
		}
	}
	return true
}

func (b *Bridge) mentionNames(mentions []string) map[string]string {
	if len(mentions) == 0 {
		return nil
	}
	names := map[string]string{}
	for _, mention := range mentions {
		jid, err := types.ParseJID(mention)
		if err != nil {
			continue
		}
		names[jid.User] = strings.TrimPrefix(b.name(b.canon(jid).String()), "~")
	}
	return names
}

// view is a message as the panel is told of it.
func (b *Bridge) view(row *Row, reactions [][2]string, votes map[string][]string) map[string]any {
	extra := row.Extra
	out := map[string]any{
		"id": row.ID, "sender": row.Sender, "name": b.name(row.Sender), "mine": row.Mine, "date": row.TS,
		"kind": row.Kind, "text": row.Text, "html": markup(row.Text, b.mentionNames(extra.Mentions)), "status": row.Status,
		"big":    row.Kind == "text" && onlyEmoji(row.Text),
		"edited": extra.Edited, "forwarded": extra.Forwarded, "starred": extra.Starred, "error": extra.Error,
	}
	if extra.Media != nil {
		out["media"] = extra.Media
	}
	if extra.Transcript != "" {
		out["transcript"] = extra.Transcript
	}
	if row.Kind == "voice" || row.Kind == "audio" {
		if state := transcription(row.Chat, row.ID); state != nil {
			out["transcribing"] = state
		}
	}
	if extra.Quote != nil {
		out["quote"] = map[string]any{"id": extra.Quote.ID, "name": strings.TrimPrefix(b.name(extra.Quote.Sender), "~"), "text": extra.Quote.Text}
	}
	if extra.Place != nil {
		out["place"] = extra.Place
	}
	if extra.Cards != nil {
		out["cards"] = extra.Cards
	}
	if extra.Link != nil {
		out["link"] = extra.Link
	}
	if extra.Poll != nil {
		options := []map[string]any{}
		for _, option := range extra.Poll.Options {
			voters := []string{}
			mine := false
			for sender, chosen := range votes {
				for _, name := range chosen {
					if name != option {
						continue
					}
					if jid, err := types.ParseJID(sender); err == nil && b.isMe(jid) {
						mine = true
					}
					voters = append(voters, strings.TrimPrefix(b.name(sender), "~"))
				}
			}
			options = append(options, map[string]any{"name": option, "count": len(voters), "mine": mine, "voters": voters})
		}
		out["poll"] = map[string]any{"options": options, "multi": extra.Poll.Multi, "voters": len(votes)}
	}
	if len(reactions) > 0 {
		byEmoji := map[string]map[string]any{}
		order := []string{}
		for _, reaction := range reactions {
			entry := byEmoji[reaction[1]]
			if entry == nil {
				entry = map[string]any{"emoji": reaction[1], "count": 0, "mine": false, "names": []string{}}
				byEmoji[reaction[1]] = entry
				order = append(order, reaction[1])
			}
			entry["count"] = entry["count"].(int) + 1
			entry["names"] = append(entry["names"].([]string), strings.TrimPrefix(b.name(reaction[0]), "~"))
			if jid, err := types.ParseJID(reaction[0]); err == nil && b.isMe(jid) {
				entry["mine"] = true
			}
		}
		list := []map[string]any{}
		for _, emoji := range order {
			list = append(list, byEmoji[emoji])
		}
		out["reactions"] = list
	}
	return out
}
