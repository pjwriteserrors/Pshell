package main

import "testing"

func TestMarkup(t *testing.T) {
	cases := map[string]string{
		"*bold* and _italic_":      "<b>bold</b> and <i>italic</i>",
		"2*3*4 stays":              "2*3*4 stays",
		"a < b & c":                "a &lt; b &amp; c",
		"see https://x.org/a_b_c.": `see <a href="https://x.org/a_b_c">https://x.org/a_b_c</a>.`,
		"~gone~ `x*y*`":            "<s>gone</s> <code>x*y*</code>",
		"line\nbreak":              "line<br>break",
		"```a\nb``` end":           "<code>a<br>b</code> end",
		"*open only":               "*open only",
	}
	for text, want := range cases {
		if got := markup(text, nil); got != want {
			t.Errorf("markup(%q) = %q, want %q", text, got, want)
		}
	}
	if got := markup("hi @4915111", map[string]string{"4915111": "Anna"}); got != "hi <b>@Anna</b>" {
		t.Errorf("mention: %q", got)
	}
}

func TestOnlyEmoji(t *testing.T) {
	if !onlyEmoji("😍") || onlyEmoji("ok 😍") || onlyEmoji("") {
		t.Error("onlyEmoji")
	}
}

func TestPreview(t *testing.T) {
	if got := preview(&Row{Kind: "voice", Extra: Extra{Media: &Media{Seconds: 72}}}); got != "Voice message (1:12)" {
		t.Errorf("voice: %q", got)
	}
	if got := preview(&Row{Kind: "image", Text: "at  the\nsea"}); got != "Photo: at the sea" {
		t.Errorf("image: %q", got)
	}
}
