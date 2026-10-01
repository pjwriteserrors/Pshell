pragma Singleton

import QtQuick
import Quickshell

// The Ollama actions on a piece of text: launcher >ai (clipboard) and the
// shelves (dropped text) offer the same ones.
Singleton {
	readonly property var fixed: [
		{ id: "explain", icon: "lightbulb", title: "Explain", prompt: "Erkläre den Text aus der Zwischenablage verständlich. Antworte auf Deutsch." },
		{ id: "summarize", icon: "text_short", title: "Summarize", prompt: "Fasse den Text aus der Zwischenablage kurz und präzise zusammen. Antworte auf Deutsch." },
		{ id: "translate", icon: "translate", title: "Translate", prompt: "Übersetze den Text aus der Zwischenablage: Ist er auf Deutsch, übersetze ihn ins Englische, sonst ins Deutsche. Gib nur die Übersetzung aus." },
		{ id: "improve", icon: "auto_fix", title: "Improve wording", prompt: "Verbessere Formulierung, Rechtschreibung und Grammatik des Textes aus der Zwischenablage. Behalte Sprache, Bedeutung und Ton bei und gib nur den verbesserten Text aus." },
		{ id: "reply", icon: "reply", title: "Reply draft", prompt: "Schreibe einen passenden Antwortentwurf auf die Nachricht aus der Zwischenablage. Antworte auf Deutsch." }
	]
}
