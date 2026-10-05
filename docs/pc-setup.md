# Übergabe: Pshell auf dem PC einrichten

Diese Datei ist für einen neuen AI-Chat auf dem PC. Gib ihr einfach:
„Lies `~/.config/quickshell/shell/docs/pc-setup.md` (bzw. die Datei auf GitHub) und hilf mir, das umzusetzen.“

## Kontext

- Pshell ist die Quickshell-Shell für niri, ein Repo für Laptop und PC:
  https://github.com/pjwriteserrors/Pshell. Den Aufbau erklärt `docs/architecture.md`,
  die bitte zuerst lesen.
- Am 2026-09-25/26 wurde die Shell neu aufgebaut. Basis ist die Laptop-Shell, dazu kam
  alles Brauchbare der alten PC-Shell: Studio, Wallpaper-Runtime, Style-Wechsler,
  Icons & Cursor, Kombinationen, die Theme-Hooks und OpenRGB.
  `main` ist der neue Stand. Die alten PC-Branches liegen als `archive/arcanum`,
  `archive/atelier` und `archive/filament` auf GitHub.
- Der Laptop läuft seit 2026-09-26 damit. Profil: `hosts/laptop.json`.
- Für den PC ist `hosts/pc.json` vorbereitet:
  - aktiv sind KDE Connect, Haptik, DDC-Helligkeit und Maus-Akku
  - Notizen, Todos, qtrack, RPG, SSH-Manager, Power-Profile und `>setup` sind aus
  - Theme-Hooks: sddm, betterdiscord, obsidian, spicetify, steam, kitty, pywalfox,
    telegram, oomox und openrgb (jeder ein Plugin `hook-<name>`, im Studio-Reiter
    von `>plugins` ein- und ausschaltbar)
  - Wallpaper-Bibliothek: `~/Scripts/themes/color_themes`
- Auf dem PC gilt vorerst der Default-Style (der Laptop-Look). Arcanum wird später als
  eigener Branch `style/arcanum` neu aufgebaut. Das ist **nicht** Teil dieser Aufgabe.

## Was auf dem PC anders ist

- Der Benutzer heißt `lu`, nicht `philippjung`. Nirgends Home-Pfade hart kodieren.
- Die alte PC-Shell liegt vermutlich schon in `~/.config/quickshell/shell`: ein Klon
  desselben GitHub-Repos, meist mit ausgechecktem `style/arcanum`. niri startet sie mit
  `quickshell -c shell`. Es kann lokale Style-Branches geben, die nie gepusht wurden
  (die README nennt `style/meridian` und `style/biopunk`). **Die dürfen nicht verloren
  gehen.**
- Die alte PC-Shell legt Laufzeitdateien ins Repo-Verzeichnis, z. B.
  `launcher-usage.json` und `launcher-ai-state.json`. Die neue Shell erwartet sie in
  `~/.local/state/pshell`.
- Der Theme-Zustand liegt wie am Laptop in `~/.local/state/quickshell-theme`
  (current-theme-dir, combinations.json, lighting-state.json usw.). Das bleibt so.

## Ablauf

Jeden Schritt erst prüfen und dann ausführen. Nichts löschen, was nicht gesichert ist.

### 1. Sichern

```
B=~/.local/share/pshell-backup-$(date +%Y%m%d-%H%M%S); mkdir -p "$B"
cd ~ && tar -cpzf "$B/files.tar.gz" --ignore-failed-read \
  .config/quickshell .config/niri .config/wallust .local/state/quickshell-theme .cache/wal \
  .config/systemd/user .config/gtk-3.0 .config/gtk-4.0 .local/bin Scripts/themes/changer \
  .config/spicetify .config/BetterDiscord/data/stable/custom.css
git -C ~/.config/quickshell/shell bundle create "$B/old-shell.bundle" --all
dconf dump /org/gnome/desktop/interface/ > "$B/gnome-interface.dconf"
sudo tar -cpzf "$B/sddm.tar.gz" /usr/share/sddm/themes /etc/sddm.conf /etc/sddm.conf.d 2>/dev/null
```

Danach `gzip -t` und `git bundle verify` auf das Backup anwenden. Außerdem eine
`restore.sh` ins Backup legen, nach dem Vorbild von
`~/.local/share/pshell-backup-20260926-125200/restore.sh` am Laptop. Sie ist unten
unter „Zurück“ beschrieben.

### 2. Alte Daten aus dem Repo retten

```
cd ~/.config/quickshell/shell
git status --short --ignored
mkdir -p ~/.local/state/pshell
```

Ignorierte `*.json` im Repo-Stamm, etwa `launcher-usage.json` oder
`launcher-ai-state.json`, nach `~/.local/state/pshell/` **kopieren**, falls es dort noch
keine gleichnamige Datei gibt. Das Format kann sich vom Laptop unterscheiden. Beim
Launcher-Chat-Zustand also prüfen, ob die neue Shell ihn lesen kann; sonst bei Seite
legen. Nicht committete Änderungen im alten Repo nicht wegwerfen, sondern als Commit auf
einem eigenen Branch sichern, z. B. `archive/pc-wip`.

### 3. Lokale Branches sichern

`git branch -vv` zeigt alle lokalen Branches. Jeden lokalen `style/*`-Branch und den
alten lokalen `main` nach `archive/<name>` umbenennen. Dabei **nichts löschen**; nur
pushen, wenn der Benutzer es will.

### 4. Neuen Stand holen

```
git fetch origin
git switch -C main origin/main
git clean -n     # nur anzeigen; übrig gebliebene Dateien der alten Shell einzeln entscheiden
```

`main` hat eine neue Historie ohne gemeinsamen Vorfahren mit den alten Branches. Das ist
so gewollt.

### 5. Maschine eintragen und installieren

```
hostnamectl hostname
./install.sh --host pc --dry-run --migrate-from ~/.local/share/pshell-backup-…/entpackt/.config/quickshell/shell
./install.sh --host pc
```

- `--host pc` trägt den Hostnamen in `hosts/machines.json` ein. Diese Änderung
  committen.
- `--migrate-from` nur, wenn in Schritt 2 noch nicht alles kopiert wurde.
- `install.sh` legt Links für die Dotfiles aus `dotfiles/manifest` an und sichert
  vorhandene Dateien als `*.pre-pshell-<datum>`.
- Danach `python3 scripts/setup.py doctor` ausführen und jeden Punkt abarbeiten.

### 6. niri

- In `~/.config/niri/config.kdl` die Zeile `include "pshell.kdl"` eintragen.
- `dotfiles/niri/pshell.kdl` enthält Autostart und Tastenkürzel der Shell:
  `quickshell -c shell`, den cliphist-Watcher, Mod+D, Sperre, Clipboard, Mod+Shift+S
  (Studio), Lautstärke, Helligkeit, Screenshot und Aufnahme.
- Aus `config.kdl` alles entfernen, was das doppelt macht oder die alte Shell aufruft:
  - `dispatch_ipc.sh`
  - den alten Autostart `restore_theme_wallpaper.sh` und `wallpaper_watch.sh`; den
    Watcher startet jetzt die Shell selbst
  - swayosd, das die Shell jetzt selbst übernimmt
  - Studio-Binds wie Mod+Shift+M
- Vorher mit `niri validate -c <kopie>` prüfen und auf doppelte Tastenkürzel
  kontrollieren. Erst dann übernehmen.

### 7. Dateien, die es nur auf dem PC gibt, ins Repo holen

Sie gehören nach `dotfiles/` mit einem Eintrag in `dotfiles/manifest` und `when` =
`host:pc` bzw. `hook:<name>`:

- `~/Scripts/themes/changer/spicetify_maker.py` und `update_steam_theme.py`. Die
  Pfade in `hosts/pc.json` unter `hookConfig` danach auf das verlinkte Ziel prüfen.
- `~/.config/niri/animations/` (Shader und nirimation-Presets) für die Studio-Seite
  „Motion“. Am Laptop gibt es das nicht; mit `when` = `all` bekommen beide Rechner die
  Animationen.
- die systemd-User-Units `openrgb-theme.service` und `quickshell-lighting.service`.
  `quickshell-lighting.service` muss `scripts/apply_lighting.py --restore` aus dem neuen
  Repo aufrufen. Die Lighting-Config liegt jetzt in `hosts/pc-lighting.json`.
- die wallust-Templates des PCs, falls sie von `dotfiles/wallust/templates` abweichen
  (swayosd-CSS, kitty `colors.conf` usw.). Zusammenführen statt überschreiben.
- `~/.config/oomox/colors/wal`, falls vorhanden; der oomox-Hook braucht es.

### 8. SDDM

Die neue Shell nutzt das Greeter-Theme „silent“ aus `system/sddm`, nicht mehr
`quickshell-lock`. Installiert wird es mit `system/install-sddm-silent-theme.sh` (braucht
sudo, also vorher fragen). `install-fingerprint-auth.sh` ist **nur für den Laptop**.

### 9. Umschalten

```
quickshell kill -p ~/.config/quickshell/shell   # oder die PID aus `quickshell list --all`
niri msg action spawn -- quickshell -c shell
```

Dann prüfen:
- `quickshell log` auf Warnungen und Fehler durchsehen
- `qs -c shell ipc call styleSession state`
- `systemctl --user list-units 'quickshell-*'`: swaybg und awww bzw. mpvpaper sollten
  laufen
- `fuser ~/.local/state/quickshell-theme/theme-startup.lock` sollte leer sein
- per Studio einmal ein Theme anwenden und das neueste
  `~/.local/state/quickshell-theme/apply-*.log` lesen: jede Zeile OK oder SKIP, kein
  FAIL

## Bekannte Fallstricke

- **Aufrufe der alten Shell von außen.** Befehle wie `qs -c main …` oder Pfade in die alte
  Shell stehen auch außerhalb der niri-Config, z. B. in den KDE-Connect-Befehlen
  (`~/.config/kdeconnect/*/kdeconnect_runcommand/config`). Suchen mit
  `grep -rIl -e '-c main' -e 'quickshell/' ~/.config ~/.local/bin`. Nach dem Ändern
  `kdeconnectd` neu starten, denn die Befehle hält er im Speicher.

- **Tests nie gegen den echten Zustand laufen lassen.**
  - `scripts/review_surfaces.sh` startet die Shell in einem verschachtelten niri, legt
    aber Dateien in `~/.local/state/pshell` an. Das ist am Laptop einmal passiert, und
    Testdateien hätten fast den echten RPG-Spielstand verdeckt.
  - `wallust run` setzt die Farben in allen offenen Terminals.
  - Die Wallpaper-Runtime startet systemd-User-Units, die auf dem echten Desktop landen,
    auch aus einem verschachtelten niri heraus.
- **Alte Wallpaper-Prozesse.** `swaybg` oder `awww-daemon` aus der alten Shell können
  den Start-Lock geerbt haben. Einmal `bash scripts/restore_theme_wallpaper.sh`
  ausführen; das startet sie als Units neu.
- **Sauberer Arbeitsbaum.** Der Style-Wechsler (Studio → Style) verweigert den Wechsel,
  solange es nicht committete Änderungen gibt.
- **Checks vor jedem Commit:**
  - `quickshell -p ./Validate.qml` muss `VALIDATE: ok` ausgeben
  - `python3 scripts/test_branch_styles.py` für den Style-Wechsler
- **Keine unnötigen Hilfetexte in der UI.** Der Benutzer will kurze, selbsterklärende
  Labels.

## Zurück

`restore.sh` im Backup soll Folgendes tun:
1. `quickshell -c shell` beenden und die Links aus `dotfiles/manifest` entfernen.
2. `files.tar.gz` zurückspielen und die dconf-Sicherung laden.
3. Im Repo die alte Arbeitskopie wiederherstellen: den gesicherten Branch auschecken,
   etwa `archive/arcanum` bzw. das Bundle.
4. `niri msg action spawn -- quickshell -c shell` ausführen.
