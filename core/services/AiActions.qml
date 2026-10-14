pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Ollama actions on a piece of text: launcher >ai (clipboard) and the
// shelves (dropped text) offer the same ones. They run with their own model
// (ai-actions.json) or, when none is picked, with the chat's.
Singleton {
	id: root

	property string model: ""

	function setModel(name) {
		root.model = String(name || "");
		file.setText(JSON.stringify({ model: root.model }, null, "\t") + "\n");
	}

	FileView {
		id: file

		path: Paths.stateFile("ai-actions.json")
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.model = String(JSON.parse(String(text() || "{}")).model ?? "");
			} catch (error) {}
		}
	}

	readonly property var fixed: [
		{ id: "explain", icon: "lightbulb", title: "Explain", prompt: "Erkläre den Text aus der Zwischenablage verständlich. Antworte auf Deutsch.", words: ["erklär", "erklaer", "explain", "versteh", "bedeut", "meaning", "was heißt", "was ist"] },
		{ id: "summarize", icon: "text_short", title: "Summarize", prompt: "Fasse den Text aus der Zwischenablage kurz und präzise zusammen. Antworte auf Deutsch.", words: ["zusammenfass", "zusammen", "summar", "kurz", "short", "tldr", "kernpunkt", "key points"] },
		{ id: "translate", icon: "translate", title: "Translate", prompt: "Übersetze den Text aus der Zwischenablage: Ist er auf Deutsch, übersetze ihn ins Englische, sonst ins Deutsche. Gib nur die Übersetzung aus.", words: ["übersetz", "uebersetz", "translat"] },
		{ id: "improve", icon: "auto_fix", title: "Improve wording", prompt: "Verbessere Formulierung, Rechtschreibung und Grammatik des Textes aus der Zwischenablage. Behalte Sprache, Bedeutung und Ton bei und gib nur den verbesserten Text aus.", words: ["verbesser", "korrigier", "improve", "fix", "rechtschreib", "grammat", "spelling", "formulier", "umformulier", "rewrite", "schöner"] },
		{ id: "reply", icon: "reply", title: "Reply draft", prompt: "Schreibe einen passenden Antwortentwurf auf die Nachricht aus der Zwischenablage. Antworte auf Deutsch.", words: ["antwort", "reply", "answer", "zurückschreib", "respond"] }
	]
}
