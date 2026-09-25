# Archiv der verlorenen Stunden

Das Productivity-RPG läuft vollständig lokal. Eine Expedition startet nur über
den Play-Button im Bar-Widget und endet jederzeit über Stop. Außerhalb einer
Expedition werden keine Eingaben gelesen oder gewertet.

## RPG-Fenster öffnen

Im App Launcher `/rpg` eingeben und Enter drücken. Das Spiel öffnet sich als
eigenständiges, frei verschiebbares Fenster. Die Buttons rechts in der
Titelleiste minimieren, maximieren, wechseln ins Vollbild oder schließen das
Fenster. Ein Doppelklick auf die Titelleiste maximiert es ebenfalls.

Die Oberfläche übernimmt automatisch die aktuellen Wallust-Farben der Shell.
Relikte und Shop-Kosmetik verwenden eigene lokal gespeicherte Illustrationen
unter `assets/rpg/icons/`; dafür ist nach der Generierung keine Netzwerkverbindung
notwendig.

## Einmaliger Zugriff auf Eingabegeräte

Wayland gibt globale Tastatur- und Mausklicks absichtlich nicht an normale
Fenster weiter. Der Monitor liest deshalb Linux-Inputgeräte direkt, benötigt
aber eine udev-Freigabe für die aktive lokale Sitzung:

```bash
./scripts/setup-rpg-input-access.sh
```

Das Skript installiert eine kleine `uaccess`-Regel für Keyboard- und
Mouse-Eventgeräte. Der laufende Monitor selbst hat keine Root-Rechte. Er zählt
nur Tastendrücke und Mausklicks; Keycodes, Text, Programme und einzelne
Zeitstempel werden weder ausgegeben noch gespeichert.

## Balancing

- Neun Tastenanschläge oder 2,5 Klicks entsprechen ungefähr einem Treffer.
- Eingabebatches sind gedeckelt, damit Makros und Event-Spikes die Balance nicht
  zerstören. Normales schnelles Tippen bleibt vollständig wirksam.
- Frühe Level dauern ungefähr 10–20 aktive Minuten, danach steigt die Kurve
  moderat. Jedes Level erhöht automatisch die Grundstärke.
- Gegner skalieren in Zehner-Ebenen. Jede zehnte Kammer ist ein Boss mit mehr
  HP, Splittern, XP und deutlich höherer Reliktchance.
- Relikte droppen zu 18 Prozent, spätestens aber nach sechs Gegnern. Bosse haben
  75 Prozent Chance. Duplikate steigen bis Rang 10 und Set-Paare geben Boni.
- Der Shop ist rein kosmetisch. Preise reichen von einer kurzen Sitzung bis zu
  mehreren produktiven Wochen (`60`, `220`, `750`, `2600`, `9000`).
- Inaktivität verursacht keinen Verlust. Der Streak sinkt langsam, aber Loot,
  Währung und Fortschritt bleiben erhalten.

Der Spielstand liegt in `rpg-state.json` (von Git ignoriert). Gespeichert wird
gebündelt und während einer Expedition zusätzlich alle 15 Sekunden. Tageswerte
enthalten Tasten, Klicks, Treffer, Gegner, aktive Minuten, Splitter sowie maximal
180 Minutenpunkte für Fokus- und Gegner-HP.
