# Atelier — a new desktop composition

Eigenständige Quickshell-Arbeitskopie unter `main/atelier`.
Branch `main` heißt im Style-Picker **default**; `redesign/atelier` heißt **Atelier**.
Beide enthalten die Git-Branch-Auswahl, Details siehe [THEMES.md](THEMES.md).
Die originale `../shell.qml` ist unverändert. Der Original-Autostart bleibt erhalten.

## Gestaltung

Die zweite Gestaltung ersetzt ausdrücklich auch die bisherige Anordnung:

- 88 px breite, dunkle Seitenleiste links auf jedem Monitor; keine horizontale Statusbar.
- Live-Wallust-Palette mit abgeleiteten Flächen und kontrastkorrigierten Akzenten; C059 als Displayschrift,
  Adwaita Sans für Bedienung und Adwaita Mono für Metadaten.
- Kontext-Popups mit typografischer Seitenfläche und eigenständigem Inhalt.
- Launcher mit Fokusmotiv und Anwendungsmosaik, Rechner als Zahlenblatt,
  Dateien als Sammlung, Modellverwaltung mit eigener Bibliotheksansicht.
- Medien als Schallplattenmotiv mit Transport-, Positions-, Lautstärke- und Ausgabewahl.
- Verbindungen mit Statusmotiv, Live-Kurven und Gerätekacheln.
- Benachrichtigungen als chronologischer Verlauf; Toasts als separate Wayland-Flächen.
- Wallpaper als Bildgalerie mit sechs Farbstudien, Animationen mit eigener Bühne,
  Styles als Auswahl vollständiger lokaler Git-Branches.
- Sitzung mit vier Aktionskreisen und Bestätigung für Abmelden, Neustart und Ausschalten.

Die Shell-Palette folgt Wallust automatisch. Die alten Form-Styles und kombinierten
Presets sind entfernt; Wallpaper- und Animationsfunktionen bleiben erhalten. Animationen ohne vorhandenen Vorschaufilm
zeigen eine ausdrücklich beschriftete Bewegungsskizze, keinen echten Shader-Render.

## Laufendes Setup und Rückkehr

Die Atelier-Kopie wurde in der laufenden Sitzung gestartet. Niri-Tastenkürzel
verwenden `scripts/dispatch_ipc.sh`: solange Atelier läuft, wird diese Instanz
angesprochen; andernfalls das Original.

Zur Rückkehr zum Original, ausschließlich bei entsperrter Sitzung:

```sh
quickshell kill -p /home/lu/.config/quickshell/main/atelier
# Nach dem Beenden:
quickshell -p /home/lu/.config/quickshell/main --daemonize --no-duplicate
```

Kein systemweiter SDDM-Wechsel, kein neuer Autostart und kein Remote-Repository.
Die Quellensicherung ist lokal. Persönliche Chatverläufe und Nutzungsstatistiken
sind nicht versioniert.

## Prüfungen

```sh
bash scripts/review_atelier.sh validate
bash scripts/audit_desktop.sh capture
bash scripts/audit_desktop.sh small
bash scripts/audit_desktop.sh keyboard
bash scripts/audit_desktop.sh status
git diff --check
```

`validate` kompiliert die komplette Shell samt QML-Abhängigkeiten, ohne ihre
Systemdienste zu starten. `capture` öffnet 14 Hauptansichten auf dem fokussierten
Monitor. `small` führt denselben Test auf HDMI-A-1 aus und stellt den vorherigen
Monitorfokus wieder her. `keyboard` prüft Rechner, Dateien, Chat,
Modellverwaltung und Befehle mit Eingaben, ohne sie auszuführen.
Screenshots liegen ausschließlich unter `/tmp/atelier-audit`; sie können private
Desktop- und Zwischenablageinhalte zeigen und gehören deshalb nicht ins Git.

Visuell geprüft wurden große und kleine Desktopansichten (1920×1080 und
1360×768), Launcher-Untermodi, Medieninformationen, Kalender, Wetter,
Systemwerte, Verbindungen, Zwischenablage und Testbenachrichtigungen.
Dabei wurden fehlende Symbole, abgeschnittene Inhalte, ungültige Canvas-Größen,
eine leere Clipboard-Ansicht und unsichtbare Toasts korrigiert.

## Grenzen des Tests

Dies ist kein vollständiger End-to-End-Test aller Systemaktionen.
Nicht automatisch ausgeführt: Passwort-Anmeldung, Abmelden, Reboot, Ausschalten,
Bluetooth-Pairing, Netzwerk-Trennung, Modell-Downloads/-Löschung und echte
KI-Generierung. Das verhindert unbeabsichtigte Änderungen an der Sitzung.

Der Sperrbildschirm verwendet jetzt `WlSessionLock` statt einer bloßen
Layer-Shell-Überlagerung. Die PAM-Erfolgsprüfung bleibt Voraussetzung für das
Entsperren. Er wurde kompiliert, aber nicht durch Sperren der Benutzersitzung
authentifiziert. SDDM-Quellen sind nicht systemweit installiert oder als
Anmeldedienst geprüft. Die mitgelieferte Caelestia-Shell ist nicht aktiv;
die Haupt-Shell verwendet daraus nur die Fuzzy-Suche.

Bekannte externe Laufzeitmeldungen: ungültige Leerzeilen in zwei
Desktop-Einträgen und ein fehlendes `battery-080`-Tray-Symbol.
Beim Live-Neuladen meldet Quickshell gelegentlich verworfene FileView-Operationen.
Diese Meldungen sind von den behobenen QML-Layoutfehlern zu unterscheiden.
