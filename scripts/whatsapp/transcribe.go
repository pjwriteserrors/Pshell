package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Voice messages written out by a speech model on this PC (whisper.cpp): its
// program `whisper-cli` and a ggml model, in ~/.local/share/pshell/whisper or
// where $PSHELL_WHISPER_MODEL points. What it heard is kept with the message.

// one at a time: it takes every core there is
var (
	listening    sync.Mutex
	transcribing = map[string]*hearing{}
	heard        sync.Mutex
)

// a voice message being written out: since when whisper works on it, and
// how long it is expected to take (nothing yet while it waits its turn)
type hearing struct {
	Since    int64   `json:"since,omitempty"`
	Expected float64 `json:"expected,omitempty"`
	stop     context.CancelFunc
}

// how fast a model is on this PC, in seconds: loading it, a 30 second window
// read by the encoder, and the words per second of sound
type pace struct {
	Load   float64 `json:"load"`
	Encode float64 `json:"encode"`
	Rate   float64 `json:"rate"`
}

// the better models first
var whisperModels = []string{
	"ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo.bin",
	"ggml-medium-q5_0.bin", "ggml-medium.bin", "ggml-small-q5_1.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin",
}

func whisperProgram() string {
	for _, name := range []string{"whisper-cli", "whisper-cpp", "whisper.cpp"} {
		if path, err := exec.LookPath(name); err == nil {
			return path
		}
	}
	return ""
}

func whisperModel() string {
	if path := os.Getenv("PSHELL_WHISPER_MODEL"); path != "" {
		return path
	}
	home, _ := os.UserHomeDir()
	data := os.Getenv("XDG_DATA_HOME")
	if data == "" {
		data = filepath.Join(home, ".local", "share")
	}
	folder := filepath.Join(data, "pshell", "whisper")
	for _, name := range whisperModels {
		if _, err := os.Stat(filepath.Join(folder, name)); err == nil {
			return filepath.Join(folder, name)
		}
	}
	// what packages put down (whisper.cpp-model-* in the AUR)
	for _, name := range whisperModels {
		if found := globbed("/usr/share/whisper.cpp-model-*/" + name); len(found) > 0 {
			return found[0]
		}
	}
	if found := globbed(filepath.Join(folder, "ggml-*.bin")); len(found) > 0 {
		return found[0]
	}
	return ""
}

func transcription(chat, id string) *hearing {
	heard.Lock()
	defer heard.Unlock()
	if state := transcribing[chat+"/"+id]; state != nil {
		copied := *state
		return &copied
	}
	return nil
}

// what is guessed for a model not timed yet
func guessedPace(model string) pace {
	name := filepath.Base(model)
	switch {
	case strings.Contains(name, "tiny"):
		return pace{Load: 0.5, Encode: 1, Rate: 0.3}
	case strings.Contains(name, "base"):
		return pace{Load: 0.7, Encode: 2, Rate: 0.5}
	case strings.Contains(name, "small"):
		return pace{Load: 1, Encode: 6, Rate: 1}
	case strings.Contains(name, "turbo"):
		return pace{Load: 2, Encode: 20, Rate: 1.5}
	}
	return pace{Load: 3, Encode: 30, Rate: 3}
}

func (b *Bridge) paceOf(model string) pace {
	known := guessedPace(model)
	_ = json.Unmarshal([]byte(b.store.get("whisper:"+filepath.Base(model))), &known)
	return known
}

func (p pace) expected(seconds float64) float64 {
	return p.Load + p.Encode*math.Max(1, math.Ceil(seconds/30)) + p.Rate*seconds
}

func (b *Bridge) transcribe(c *Command) {
	program, model := whisperProgram(), whisperModel()
	if program == "" {
		b.fail("Transcribing needs whisper.cpp (whisper-cli)", nil)
		return
	}
	if model == "" {
		b.fail("Transcribing needs a whisper model in ~/.local/share/pshell/whisper", nil)
		return
	}
	key := c.Chat + "/" + c.ID
	ctx, stop := context.WithCancel(b.ctx)
	defer stop()
	heard.Lock()
	if transcribing[key] != nil {
		heard.Unlock()
		return
	}
	transcribing[key] = &hearing{stop: stop}
	heard.Unlock()
	defer func() {
		heard.Lock()
		delete(transcribing, key)
		heard.Unlock()
		b.touchChat(c.Chat)
	}()
	b.touchChat(c.Chat)

	path := b.fetch(c.Chat, c.ID, true)
	if path == "" {
		return
	}
	listening.Lock()
	if ctx.Err() != nil {
		listening.Unlock()
		return
	}
	text, err := b.whisper(ctx, program, model, path, func(expected float64) {
		heard.Lock()
		transcribing[key] = &hearing{Since: time.Now().UnixMilli(), Expected: expected, stop: stop}
		heard.Unlock()
		b.touchChat(c.Chat)
	})
	listening.Unlock()
	if ctx.Err() != nil {
		return
	}
	if err != nil {
		b.fail("Transcribing", err)
		return
	}
	row := b.store.message(c.Chat, c.ID)
	if row == nil {
		return
	}
	if text == "" {
		text = "…"
	}
	row.Extra.Transcript = text
	b.store.update(row)
}

// stopTranscribing gives up on a voice message, whether whisper is at it or it waits.
func stopTranscribing(chat, id string) {
	heard.Lock()
	defer heard.Unlock()
	if state := transcribing[chat+"/"+id]; state != nil && state.stop != nil {
		state.stop()
	}
}

// the cores there are, not the threads: whisper is slower on the shared ones
func whisperThreads() int {
	if count := runtime.NumCPU(); count > 4 {
		return count / 2
	}
	return runtime.NumCPU()
}

var timing = regexp.MustCompile(`(load|encode) time =\s*([0-9.]+) ms(?: /\s*([0-9]+) runs)?`)

// whisper writes out a sound file; `started` is told how long that should take.
func (b *Bridge) whisper(ctx context.Context, program, model, path string, started func(float64)) (string, error) {
	base := b.scratch("heard")
	wav := base + ".wav"
	defer os.Remove(wav)
	defer os.Remove(base + ".txt")
	// what whisper reads: 16 kHz, one channel
	if err := ffmpeg("-i", path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav); err != nil {
		return "", err
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	info, err := os.Stat(wav)
	if err != nil {
		return "", err
	}
	seconds := float64(info.Size()-44) / 32000
	known := b.paceOf(model)
	started(known.expected(seconds))

	begun := time.Now()
	// one guess at a time instead of five: much faster, and hardly worse
	command := exec.CommandContext(ctx, program, "-m", model, "-f", wav, "-l", "auto", "-t", fmt.Sprint(whisperThreads()), "-bs", "1", "-bo", "1", "-nt", "-otxt", "-of", base)
	var problem bytes.Buffer
	command.Stderr = &problem
	if err := command.Run(); err != nil {
		lines := strings.Split(strings.TrimSpace(problem.String()), "\n")
		return "", fmt.Errorf("%s", lines[len(lines)-1])
	}
	b.learn(model, known, problem.String(), time.Since(begun).Seconds(), seconds)

	out, err := os.ReadFile(base + ".txt")
	if err != nil {
		return "", err
	}
	words := []string{}
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			words = append(words, line)
		}
	}
	return strings.Join(words, " "), nil
}

// learn keeps how long it took, from whisper's own timings, for the next guess.
func (b *Bridge) learn(model string, known pace, report string, wall, seconds float64) {
	measured := pace{Load: -1, Encode: -1}
	runs := 1.0
	for _, match := range timing.FindAllStringSubmatch(report, -1) {
		value, _ := strconv.ParseFloat(match[2], 64)
		switch match[1] {
		case "load":
			measured.Load = value / 1000
		case "encode":
			if count, err := strconv.ParseFloat(match[3], 64); err == nil && count > 0 {
				runs = count
			}
			measured.Encode = value / 1000 / runs
		}
	}
	if measured.Load < 0 || measured.Encode < 0 || seconds <= 0 {
		return
	}
	measured.Rate = math.Max(0, wall-measured.Load-measured.Encode*runs) / seconds
	blend := func(old, now float64) float64 { return old*0.4 + now*0.6 }
	next := pace{Load: blend(known.Load, measured.Load), Encode: blend(known.Encode, measured.Encode), Rate: blend(known.Rate, measured.Rate)}
	if data, err := json.Marshal(next); err == nil {
		b.store.set("whisper:"+filepath.Base(model), string(data))
	}
}
