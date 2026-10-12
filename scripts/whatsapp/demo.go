package main

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// An account that does not exist: a handful of chats for the plugin's
// preview picture and for trying the panel without a phone
// (PSHELL_WHATSAPP_DEMO=1, or a file `demo` in the state folder). Nothing
// reaches WhatsApp; what is sent stays in the chat.

var demo = false

const (
	demoMe    = "4915100000000@s.whatsapp.net"
	demoAnna  = "4915111111111@s.whatsapp.net"
	demoTom   = "4915122222222@s.whatsapp.net"
	demoMira  = "4915133333333@s.whatsapp.net"
	demoGroup = "120363000000000001@g.us"
)

var demoNames = map[string]string{demoAnna: "Anna Weber", demoTom: "Tom Becker", demoMira: "Mira Lang"}

func isDemo(state string) bool {
	if os.Getenv("PSHELL_WHATSAPP_DEMO") != "" {
		return true
	}
	_, err := os.Stat(filepath.Join(state, "demo"))
	return err == nil
}

func (b *Bridge) demoPicture(name string, from, to color.RGBA) string {
	folder := filepath.Join(b.cache, "media")
	_ = os.MkdirAll(folder, 0o700)
	path := filepath.Join(folder, name)
	picture := image.NewRGBA(image.Rect(0, 0, 640, 420))
	for y := 0; y < 420; y++ {
		for x := 0; x < 640; x++ {
			mix := float64(x+y) / 1060
			picture.Set(x, y, color.RGBA{
				uint8(float64(from.R)*(1-mix) + float64(to.R)*mix), uint8(float64(from.G)*(1-mix) + float64(to.G)*mix),
				uint8(float64(from.B)*(1-mix) + float64(to.B)*mix), 255,
			})
		}
	}
	file, err := os.Create(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	_ = png.Encode(file, picture)
	return path
}

func (b *Bridge) startDemo() {
	me, _ := types.ParseJID(demoMe)
	b.cli.Store.ID = &me
	b.cli.Store.PushName = "You"
	people := []types.GroupParticipant{}
	for index, jid := range []string{demoMe, demoAnna, demoTom, demoMira} {
		parsed, _ := types.ParseJID(jid)
		people = append(people, types.GroupParticipant{JID: parsed, PhoneNumber: parsed, IsAdmin: index < 2})
	}
	group, _ := types.ParseJID(demoGroup)
	b.keepGroup(&types.GroupInfo{
		JID: group, GroupName: types.GroupName{Name: "Offsite in June"}, GroupTopic: types.GroupTopic{Topic: "Trains, rooms and who brings what"},
		GroupCreated: time.Now().Add(-40 * 24 * time.Hour), Participants: people,
	})

	now := time.Now().Unix()
	photo := b.demoPicture("demo-harbour.png", color.RGBA{0x4b, 0x6c, 0xb7, 255}, color.RGBA{0xf2, 0xa6, 0x5a, 255})
	voice := filepath.Join(b.cache, "media", "demo-voice.ogg")
	if _, err := os.Stat(voice); err != nil {
		_ = exec.Command("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=330:duration=7", "-c:a", "libopus", voice).Run()
	}
	put := func(chat, id, sender string, ago int64, kind, text string, extra Extra) {
		mine := sender == demoMe
		status := statusRead
		if !mine {
			status = statusSent
		}
		b.store.put(&Row{Chat: chat, ID: id, Sender: sender, TS: now - ago*60, Mine: mine, Kind: kind, Text: text, Extra: extra, Status: status})
	}
	put(demoGroup, "g1", demoAnna, 190, "text", "Who is taking the early train on *Friday*?", Extra{})
	put(demoGroup, "g2", demoTom, 184, "text", "Me. 7:12 from platform 4 🚆", Extra{})
	put(demoGroup, "g3", demoMira, 170, "poll", "Dinner on the first evening?", Extra{Poll: &Poll{Options: []string{"Italian", "Harbour grill", "Cook together"}}})
	put(demoGroup, "g4", demoMe, 160, "text", "I can bring the projector.", Extra{Quote: &Quote{ID: "g1", Sender: demoAnna, Text: "Who is taking the early train on Friday?"}})
	put(demoGroup, "g5", demoAnna, 44, "image", "The view from the house", Extra{Media: &Media{Mime: "image/png", Width: 640, Height: 420, Path: photo, Thumb: photo}})
	put(demoGroup, "g6", demoTom, 30, "voice", "", Extra{Media: &Media{Mime: "audio/ogg; codecs=opus", Seconds: 7, Path: voice}})
	put(demoGroup, "g7", demoMira, 12, "text", "😍", Extra{})
	b.store.react(demoGroup, "g5", demoTom, "❤️", now)
	b.store.react(demoGroup, "g5", demoMira, "❤️", now)
	b.store.react(demoGroup, "g4", demoAnna, "👍", now)
	b.store.vote(demoGroup, "g3", demoAnna, []string{"Harbour grill"}, now)
	b.store.vote(demoGroup, "g3", demoTom, []string{"Harbour grill"}, now)
	b.store.vote(demoGroup, "g3", demoMe, []string{"Italian"}, now)
	b.store.chatSet(demoGroup, "unread", 2)
	b.store.chatSet(demoGroup, "pinned", now)

	put(demoAnna, "a1", demoAnna, 1500, "text", "Did the invoice arrive?", Extra{})
	put(demoAnna, "a2", demoMe, 1490, "text", "Yes, paid it this morning ✔", Extra{})
	put(demoAnna, "a3", demoAnna, 95, "document", "", Extra{Media: &Media{Mime: "application/pdf", Name: "Offsite-plan.pdf", Size: 482133}})
	put(demoAnna, "a4", demoAnna, 94, "text", "Here is the plan. Have a look at page 2: https://example.org/offsite", Extra{})
	b.store.chatSet(demoAnna, "unread", 2)

	put(demoTom, "t1", demoMe, 4300, "location", "", Extra{Place: &Place{Lat: 51.7189, Lng: 8.7575, Name: "Market square", Address: "Markt 1, Paderborn"}})
	put(demoTom, "t2", demoTom, 4200, "text", "On my way.", Extra{Forwarded: false})
	put(demoTom, "t3", demoMe, 300, "text", "Lunch on Thursday?", Extra{})
	b.store.chatSet(demoTom, "muted", -1)

	put(demoMira, "m1", demoMira, 7000, "contact", "", Extra{Cards: []Card{{Name: "Papeterie Nord", Phones: []string{"+49 5251 000000"}}}})
	put(demoMira, "m2", demoMe, 6900, "text", "Thanks!", Extra{})

	b.setPhase("online", "")
	b.touchChats()
}
