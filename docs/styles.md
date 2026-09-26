# Einen Style bauen

Diese Datei ist die vollständige Anleitung, um für Pshell einen neuen Style zu
erzeugen oder einen bestehenden nachzuziehen. Sie ist für eine AI geschrieben,
die im Repository arbeitet und Befehle ausführen kann.

## So benutzt du diese Datei

Starte eine AI-Sitzung in `~/.config/quickshell/shell` und schreib:

```
Lies docs/styles.md und bau danach einen neuen Style.

Name: <Name>
Theme: <Beschreibung: Stimmung, Material, Epoche, Formen, Typografie, wie es
       sich bewegen soll, was es auf keinen Fall sein soll>
Referenzen: <Bilder, Links, Screenshots, Spiele, Filme, UIs>
Extra: <Sonderwünsche, z. B. "Leiste links statt oben", "Launcher als Terminal">
```

Zum Nachziehen, wenn `main` sich geändert hat:

```
Lies docs/styles.md und zieh style/<name> auf den Stand von main nach.
```

---

## Auftrag

Du baust einen Style: einen Git-Branch `style/<name>`, der **nur das Aussehen**
der Shell ändert. Er muss am Ende:

1. jede Funktion der Shell genauso enthalten wie `main`. Nichts fehlt, nichts
   ist nur Attrappe, nichts ist fest verdrahtet, was `main` dynamisch macht;
2. **komplett neu erfunden sein**: Die Positionierung von allem, also Leiste,
   Popups, Text und Kacheln oder Knöpfe in den Popups, stammt aus dem Theme
   und nicht aus der Default-Shell (Abschnitt 3.4);
3. das beschriebene Theme konsequent umsetzen, bis in jedes Widget, jede
   Oberfläche und jede Bewegung;
4. komplexe, theme-abhängige Animationen haben (Abschnitt 5);
5. mindestens eine eigene niri-Animation für das Öffnen und Schließen von
   Fenstern mitbringen, die zum Theme passt (Abschnitt 6);
6. `scripts/check_style.py` und `quickshell -p ./Validate.qml` bestehen;
7. später automatisch nachgezogen werden können, wenn sich die Logik auf
   `main` ändert (Abschnitt 8).

Lies vor dem Schreiben `docs/architecture.md` und führe
`python3 scripts/check_style.py --contract` aus. Diese Ausgabe ist der
verbindliche, immer aktuelle Vertrag. Wo sie und diese Datei sich
widersprechen, gilt die Ausgabe.

## 1. Prinzip: Logik und Look sind getrennt

```
core/     Logik: Services (Zustand + Aktionen), IPC, welche Oberflächen es gibt,
          Host-Profile, Core-Views als Rückfall. Gehört main. Ein Style fasst
          es nie an.
style/    Look: Frame (was an den Bildschirmrändern hängt), Theme, Motion,
          Icons, Widgets, eigene Views, eigene Fenster-Animationen. Gehört
          dem Style.
```

Die Core-Views sind der Rückfall: Sie zeigen, **was** eine Oberfläche kann,
nicht **wie** ein Style sie anordnet. Ein Style zeichnet jede Oberfläche, die
der Vertrag als `replaceable` führt, als eigene View neu, mit eigener
Anordnung. Das Kit (`style/widgets`) gibt allem das Material: die Oberflächen,
die noch Logik tragen und deshalb nicht ersetzt werden können, sehen allein
dadurch anders aus.

Daraus folgt:

- Neue Funktionen entstehen auf `main` und erreichen jeden Style per Merge.
  Gezeichnet werden sie mit den Widgets des Styles.
- Braucht ein Style eine Funktion, die es nicht gibt, baust du sie **nicht**
  im Style. Du hältst an und meldest, was im Core fehlt.
- Ein Style liest Zustand aus Services und ruft deren Aktionen auf. Er startet
  keine Prozesse, liest keine Dateien und spricht kein D-Bus. Das prüft
  `check_style.py`.

## 2. Was ein Style ist

- Ein Branch `style/<name>`, abgezweigt von `main`.
- `.quickshell-style.json` im Wurzelverzeichnis:
  `{"api": 1, "name": "<Anzeigename>", "description": "<ein Satz>"}`.
  Studio → Style zeigt Name und Beschreibung.
- Änderungen gibt es nur unter `style/` und im Manifest. Alles andere kommt aus
  `main`.
- `style/BRIEF.md`: Halte dort das Theme fest, also Beschreibung, Referenzen,
  Entscheidungen, Farb- und Bewegungsregeln. Wer den Style später nachzieht,
  liest sie zuerst.

```
style/
  Frame.qml            was an den Bildschirmrändern hängt (Leiste, Rail, Ecken …)
  bar/ …               die Bausteine des Frames; Aufbau frei
  theme/Theme.qml      Farben, Typografie, Maße
  theme/Motion.qml     Bewegungssprache: Kurven und Dauern
  theme/Icons.qml      Symbole
  widgets/*.qml        das Kit, mit dem jede Oberfläche gezeichnet wird
  views/<Surface>.qml  optional: eine Oberfläche ganz selbst zeichnen
  animations/<name>/   niri-Fenster-Animationen dieses Styles
  BRIEF.md             das Theme in Worten
```

## 3. Der Vertrag

`python3 scripts/check_style.py --contract` zeigt:

- **Kit**: jede Datei in `style/theme` und `style/widgets` mit ihrem Grundtyp
  und den öffentlichen Members (Properties, Signale, Funktionen), die dein Style
  mindestens haben muss.
- **Surfaces**: jede Oberfläche, die `core/Surfaces.qml` erzeugt, mit Grundtyp,
  `panelId`/`modalId` und dem Hinweis, ob du sie ersetzen darf
  (`replaceable`) oder nur über das Kit umgestalten sollst (`keeps logic`).

### 3.1 Kit (theme/, widgets/)

- Starte bei jeder Datei **mit der Version von main** und ändere sie. Schreib
  sie nicht neu aus dem Gedächtnis.
- Name, Grundtyp, `pragma Singleton` und jedes öffentliche Member bleiben.
  Du darfst Members hinzufügen.
- Trenne Optik von Verhalten. **Verhalten bleibt wörtlich erhalten:**
  - alles, was Services liest oder aufruft (`Popups`, `Host`, `Media`, …),
  - Signale und wann sie ausgelöst werden,
  - Eingabe: MouseArea-Handler, `Keys.*`, Fokus, `acceptedButtons`,
  - Layer-Shell: `WlrLayershell.*`, `exclusiveZone`, `screen`, `anchors` von
    Fenstern,
  - in `Drawer` und `ModalWindow`: `shown`, `targetScreen`, `reveal`,
    `panelOpened`/`modalOpened`, `Popups.close()` beim Klick daneben und bei Esc,
    `Popups.anchorFor(...)`,
  - `Theme.qml`: `wal`, `reload()` und das Einlesen von
    `~/.cache/wal/colors.json`.
- **Frei** sind Form, Farbe, Material, Schatten, Tiefe, Typografie, Maße,
  Übergänge, Choreografie und Zusatzebenen (Texturen, Muster, Effekte).
- **Farben kommen aus dem Wallpaper, Charakter aus dem Style.** Die Basis ist
  immer die wallust-Palette (`wal`, `palette`, `ranked`, `legible` …), damit
  der Style mit jedem Wallpaper mitgeht. wallust würfelt die Töne aber aus dem
  Bild. Braucht das Theme bestimmte Töne (Messing, Pergament, Neon-Cyan,
  Blutrot …), mischst du sie in die Palette, statt sie fest zu setzen:
  - **Signaturton als Ziel:** Leg die Töne, die das Theme ausmachen, als
    Konstanten in `Theme.qml` an und mische sie per RGB mit der Palette:
    `Qt.tint(paletteColor, Qt.alpha(signature, amount))` oder eine eigene
    `mix(a, b, t)`, die `r`, `g`, `b` linear überblendet. `amount` ist der
    Regler: 0 bedeutet reines Wallpaper, 1 den festen Ton. Rollen, die den
    Charakter tragen (Akzent, Metall, Leuchten), ziehen stark zum Signaturton,
    Flächen und Text schwach.
  - **Tönung statt Ersatz:** Hintergründe und Ebenen behalten die Helligkeit
    der Palette und bekommen nur den Farbstich des Themes. Die Nähe zum
    Wallpaper bleibt dadurch sichtbar.
  - **Lesbarkeit zuletzt sichern:** Jede gemischte Farbe, auf der Text steht
    oder die Text ist, geht am Ende durch `legible(color, ratio)` bzw. wird mit
    `contrast(a, b)` geprüft. Die Mischung darf den Kontrast nie unter den von
    `main` drücken.
  - **Hell und dunkel:** Signaturtöne brauchen je eine Fassung für
    `Theme.dark` und hell, oder einen Mischanteil, der mit der Helligkeit des
    Hintergrunds skaliert.
  - Reine feste Farben gibt es nur für Dinge, die bewusst unabhängig vom
    Wallpaper sind (Warnrot, Erfolgsgrün dürfen trotzdem leicht zur Palette
    getönt sein, wie auf `main`), und als Rückfall.

  Das Ergebnis muss mit jedem Wallpaper lesbar und erkennbar derselbe Style
  bleiben. Prüf es mit mindestens einem hellen, einem dunklen und einem
  knallbunten Wallpaper.
- **Schriften** müssen installiert sein (`fc-list`). Wähl sie passend zum Theme
  und nenn im Abschluss, welche du vorausgesetzt hast.

### 3.2 Frame

`style/Frame.qml` baut, was an den Bildschirmrändern hängt, meist eine Leiste
pro Bildschirm (`Variants { model: Quickshell.screens }`). Aufbau, Position und
Form sind frei: oben, unten, seitlich, schwebend, geteilt, als Ecken.

Pflicht:

- Jedes Panel und jedes Modal, das der Frame von `main` erreicht, muss auch
  dein Frame erreichen, samt der Bedingungen, unter denen es erscheint.
  `check_style.py` vergleicht das (`frame`).
- Knöpfe, die ein Panel öffnen, melden ihre Position mit
  `Popups.registerAnchor(screen, panelId, x)`, damit das Panel dort aufgeht.
  Wie das technisch geht, zeigt `style/bar/BarButton.qml`; übernimm nur die
  Mechanik, nicht die Optik.
- Legt sich der Frame an einen anderen Rand als oben, passen `Drawer` und
  `Theme.barHeight` dazu (Panels wachsen aus dem Frame).
- Die Workspaces, Tray, Status, Uhr, Medien usw. kommen aus Services
  (`Niri`, `SystemTray`, `SysStats`, `Media`, …). Wie auf `main` gilt:
  `Repeater` über die Modelle der Services, keine festen Listen.

### 3.3 Eigene Views

`style/views/<Surface>.qml` ersetzt die Core-View gleichen Namens. **Jede**
Oberfläche, die der Vertrag als `replaceable` führt, bekommt eine eigene View.
Die anderen tragen noch eigene Logik; sie bekommen ihren Look über das Kit,
bis ihre Logik in den Core gewandert ist. Danach führt der Vertrag sie als
`replaceable`, und der Style muss sie ebenfalls neu zeichnen.

Eine eigene View:

- hat denselben Grundtyp und dieselbe `panelId`/`modalId` wie die Core-View,
- bildet **alles** ab, was die Core-View kann. Lies die Core-View vollständig
  und geh jeden Zustand, jede Aktion und jeden Sonderfall durch: leer, lädt,
  Fehler, nicht verfügbar, sehr viele Einträge, Tastatursteuerung,
- setzt Core-Bausteine ein, statt sie nachzubauen (z. B. `LauncherContent`
  im Launcher, `AnimationStage` auf der Motion-Seite),
- enthält keine Logik (`Process`, `FileView`, `execDetached` …).

### 3.4 Neu erfinden, nicht umfärben

Ein Style ist ein neuer Entwurf. Die Default-Shell ist **keine Vorlage**:
Ihre Anordnung darf in keinem Teil des Styles wieder auftauchen, auch nicht in
anderen Farben, mit anderen Schriften oder runderen Ecken.

Das gilt für die Positionierung von allem:

- **Leiste bzw. Frame:** an welchem Rand oder frei schwebend, welche Form, was
  gruppiert wird, in welcher Reihenfolge, wie viel davon sichtbar ist und was
  erst auf Anfrage erscheint. Die Aufteilung der Default-Leiste (links
  Workspaces, Mitte Uhr, rechts Status) ist tabu.
- **Popups und Panels:** wo sie erscheinen, woraus sie entstehen, wie groß
  sie sind, welche Form sie haben, ob sie andocken, schweben, den Bildschirm
  teilen oder überlagern.
- **Inhalt der Popups:** Raster oder Liste oder Fläche, Kacheln, Knöpfe,
  Regler, Überschriften, Text, Werte: Anordnung, Hierarchie, Ausrichtung,
  Gruppierung und Reihenfolge folgen dem Theme.
- **Text:** wo Titel, Labels, Werte und Hinweise stehen, wie sie ausgerichtet
  und gesetzt sind.

So arbeitest du:

1. **Erst entwerfen, dann bauen.** Leg in `style/BRIEF.md` für den Frame und
   jede Oberfläche fest, wie sie in diesem Theme aufgebaut ist: eine kurze
   Beschreibung oder eine ASCII-Skizze. Die Metapher des Themes gibt die
   Anordnung vor (ein Grimoire blättert, eine Werkbank hat Schubladen, ein
   Cockpit hat Instrumente).
2. **Core-Views nur als Inventar lesen:** Welche Zustände, Aktionen, Werte und
   Sonderfälle gibt es? Schreib sie als Liste auf. Die Anordnung der Core-View
   nimmst du nicht mit.
3. **Views und Frame von Grund auf schreiben.** Kopier keine Core-View und
   keine Datei aus `style/bar/` als Ausgangspunkt. `check_style.py` misst die
   Ähnlichkeit zu `main` und lässt Kopien durchfallen (`layout`).

Nur die Kit-Dateien (`theme/`, `widgets/`) startest du mit der Version von
`main`, weil sie Verhalten enthalten, das bleiben muss (3.1). Ihr Inneres,
also Aufbau, Form und Anordnung der Teile, darfst und sollst du trotzdem neu
gestalten.

## 4. Die Funktion dynamisch widerspiegeln

Der Style zeigt, was die Shell gerade kann und was gerade los ist. Nichts
davon wird im Style festgelegt.

- **Features pro Rechner:** `Host.has("<feature>")` entscheidet, ob es etwas
  gibt (Akku, Helligkeit, KDE Connect, Notizen, …). Ist es aus, zeigt der Style
  keine Lücke und keinen toten Knopf. Die Liste der Features steht in
  `docs/architecture.md`, die Profile in `hosts/`.
- **Modelle statt Listen:** Workspaces, Fenster, Tray-Icons, Benachrichtigungen,
  Geräte, Medienspieler, Studio-Seiten (`Popups.studioPages`) kommen als Modelle
  aus Services. Zeichne sie mit `Repeater`/`ListView`, nie als feste Einträge.
- **Zustand live:** Lautstärke, Verbindung, Aufnahme, Timer, Updates … binden
  direkt an Service-Properties. Kein Zwischenspeichern, das veralten kann.
- **Auch die Grenzfälle gestalten:** leer, lädt, offline, Fehler, sehr lange
  Texte, sehr viele Einträge, mehrere Bildschirme, ein Bildschirm hinzugefügt
  oder entfernt.
- **Theme live:** Nach einem Wallpaper-Wechsel lädt `Theme` neu. Alles, was
  Farben nutzt, bindet an `Theme.*`, damit es ohne Neustart umschlägt.
- **Nichts erfinden:** Kein Knopf ohne Aktion, keine Anzeige ohne Datenquelle.

## 5. Bewegung: komplex und theme-abhängig

Bewegung ist ein Hauptmerkmal eines Styles, keine Zugabe. Sie muss aus dem
Theme folgen: Ein Style aus Papier faltet sich, einer aus Glas bricht Licht,
einer aus Metall rastet ein, einer aus Tinte zerfließt.

- **Bewegungssprache in `Motion.qml`:** Kurven und Dauern mit Namen, die dem
  Theme entsprechen. Die vorhandenen Namen (`spatial`, `emphasized`, `decel`,
  `accel`, `standard`, `micro` … `extraLong`) bleiben und bekommen die Werte
  deines Styles. Eigene Tokens darfst du ergänzen.
- **Choreografie statt einzelner Fades:** Öffnen und Schließen von Panels und
  Modals laufen in Stufen, z. B. Scrim, Körper, Inhalt versetzt (Stagger).
  Richtung und Ursprung ergeben sich aus dem Frame, also dem Knopf, aus dem das
  Panel kommt. Schließen ist kürzer als Öffnen.
- **Tiefe in den Widgets:** Hover, Druck, Auswahl, Umschalten, Laden, Fokus
  und neue Einträge haben eigene, zum Material passende Übergänge
  (`StateLayer`, `Clickable`, `Toggle`, `Segmented`, `ListItem`, `Spinner` …).
- **An Farbe und Zustand gekoppelt:** Glühen, Schatten, Verläufe und
  Partikel nehmen `Theme.primary`/`secondary`/`tertiary`. Die Intensität folgt
  `Theme.dark`. Zustände (Aufnahme läuft, Akku niedrig, Benachrichtigung) dürfen
  eigene Bewegungen haben.
- **Werkzeuge:** `Behavior`, `NumberAnimation`/`SpringAnimation` mit
  Bezier-Kurven, `SequentialAnimation`/`ParallelAnimation`, `MultiEffect`
  (Blur, Schatten, Colorize, Masken) aus `QtQuick.Effects`, `Shape` für Formen.
  Eigene `ShaderEffect`s gehen auch: Leg die Quelle unter
  `style/shaders/<name>.frag` und die kompilierte Fassung daneben
  (`/usr/lib/qt6/bin/qsb --qt6 -o <name>.frag.qsb <name>.frag`), beide
  committet.
- **Leistung:** Animiere bevorzugt `opacity`, `scale`, `x`/`y` und
  Shader-Uniforms. Endlosanimationen laufen nur, solange etwas sichtbar ist
  (`running: visible`). Kein `layer.enabled` dauerhaft auf großen Flächen. Ziel
  sind flüssige 60 fps auch am Laptop.

## 6. Fenster-Animation für niri

Jeder Style bringt mindestens eine eigene Animation für das Öffnen und
Schließen von Fenstern mit, entworfen für dieses Theme. Studio → Motion listet
sie als `style:<name>` ganz oben und spielt sie auf der Bühne live ab. Dabei
läuft der echte Shader, nicht eine Nachbildung.

```
style/animations/<name>/
  config       Timing, niri-Syntax
  open.glsl    vec4 open_color(vec3 coords_geo, vec3 size_geo)
  close.glsl   vec4 close_color(vec3 coords_geo, vec3 size_geo)
```

**config**, eins von beiden:

```
duration-ms 450
curve "ease-out-cubic"        // linear, ease-out-quad, ease-out-cubic, ease-out-expo
```
```
spring damping-ratio=0.8 stiffness=600 epsilon=0.0001
```

**Shader** (GLSL, niri-Dialekt). Verfügbar sind:

| Name | Bedeutung |
| --- | --- |
| `niri_tex` | das Fenster als Textur |
| `niri_geo_to_tex` | Geometrie → Texturkoordinaten: `texture2D(niri_tex, (niri_geo_to_tex * coords_geo).st)` |
| `niri_clamped_progress` | 0 → 1 über die Animation. Öffnen: 0 unsichtbar, 1 fertig. Schließen: 0 voll sichtbar, 1 weg |
| `niri_progress` | wie oben, kann bei Federn über 1 hinausschwingen |
| `niri_random_seed` | pro Durchlauf neu, für Zufallsmuster |
| `coords_geo.xy` | 0..1 über das Fenster |
| `size_geo.xy` | Fenstergröße in Pixeln (in der Studio-Vorschau 1×1, also nicht davon abhängig machen, ob etwas überhaupt sichtbar wird) |

Rückgabe ist premultiplied RGBA: Wer ausblendet, multipliziert die ganze
Farbe, nicht nur Alpha.

**Farben aus dem Wallpaper:** `@background@`, `@foreground@`, `@cursor@`,
`@color0@` … `@color15@` werden beim Anwenden zu `vec3(...)` der aktuellen
wallust-Palette und bei jedem Theme-Wechsel neu geschrieben
(`scripts/shader_palette.py`). So kann ein Rand im Akzentton glühen oder eine
Tinte in der Hintergrundfarbe zerlaufen. Braucht der Effekt einen bestimmten
Ton, gilt dieselbe Regel wie im Theme: den Signaturton als Konstante
anlegen und mit der Palette mischen, z. B.
`vec3 ember = mix(@color1@, vec3(1.0, 0.45, 0.1), 0.6);`.

```glsl
vec4 open_color(vec3 coords_geo, vec3 size_geo) {
    float p = niri_clamped_progress;
    vec4 win = texture2D(niri_tex, (niri_geo_to_tex * coords_geo).st);
    float front = smoothstep(p - 0.12, p, 1.0 - coords_geo.y);
    vec3 ink = mix(@background@, @color4@, front);
    return vec4(mix(win.rgb, ink, front * (1.0 - p)), win.a) * smoothstep(0.0, 0.35, p);
}
```

Vorbilder liegen in `~/.config/niri/animations/shaders/*` und
`~/.config/niri/animations/nirimation/animations/*.kdl`. Anforderungen:
- Die Animation erzählt dasselbe wie das Theme, nicht einfach ein generischer
  Fade.
- Öffnen und Schließen sind als Paar gedacht, nicht gespiegelt.
- 300 bis 700 ms, das Fenster ist schnell benutzbar.
- Kein Flackern am Anfang oder Ende: p = 0 und p = 1 ergeben exakt
  unsichtbar bzw. exakt das Fenster.

`check_style.py` kompiliert jede Animation mit `qsb` und zeigt die Fehlerzeile.

## 7. Ablauf

```
git switch -c style/<name> main
python3 scripts/check_style.py --contract      # der Vertrag
```

1. `style/BRIEF.md` schreiben: Theme, Referenzen, Regeln für Farbe, Form,
   Typografie und Bewegung, dazu die Signaturtöne mit ihrem Mischanteil pro
   Rolle, und den Entwurf von Frame und jeder Oberfläche (3.4).
2. `.quickshell-style.json` anpassen.
3. `theme/Theme.qml`, `theme/Motion.qml`, danach die Widgets, zuerst
   `Drawer`, `ModalWindow`, `Clickable`, `StateLayer`, `ListItem`, `StyledText`.
   Damit sitzt der Großteil.
4. `Frame.qml` und die Bausteine des Frames, von Grund auf neu.
5. Eine eigene View für jede Oberfläche, die der Vertrag als `replaceable`
   führt, nach dem Entwurf aus dem Brief.
6. `style/animations/<name>/`.
7. Nach jedem Schritt:
   ```
   quickshell -p ./Validate.qml          # muss "VALIDATE: ok" ausgeben
   python3 scripts/check_style.py         # muss "contract ok" ausgeben
   ```
8. Committen (nur `style/`, `.quickshell-style.json`), dann live ansehen:
   Studio (Mod+Shift+S) → Style → deinen Style wählen. Zurück über dieselbe
   Seite zu „Default“. Der Wechsel verlangt einen sauberen Arbeitsbaum.
9. Am Schluss zusätzlich `python3 scripts/test_branch_styles.py`.

Nicht gegen den echten Zustand testen: `scripts/review_surfaces.sh` legt
Dateien in `~/.local/state/pshell` an, `wallust run` färbt alle offenen
Terminals um, die Wallpaper-Runtime startet Units auf dem echten Desktop.

## 8. Nachziehen, wenn main sich ändert

```
scripts/sync_styles.sh style/<name>
```

Das merged `main` in einem temporären Worktree, committet nur, wenn alles
kompiliert, und meldet dann:

| Zeile | Bedeutung | Was zu tun ist |
| --- | --- | --- |
| `port style/views/X.qml ← core/…/X.qml changed` | Die Core-View, die dein Style ersetzt, hat sich geändert | `git log -p <since>..main -- <core-pfad>` lesen und dieselbe Funktion in deine View übernehmen |
| `port style/<datei> ← main changed it, this style kept its own` | main hat eine Kit- oder Frame-Datei geändert, dein Style hat seine behalten | die Änderung von main ansehen und das Verhalten übernehmen, den Look behalten |
| `new style/<datei>` | main hat eine Datei unter `style/` hinzugefügt | einbinden bzw. gestalten |
| `new surface X` | es gibt eine neue Oberfläche | ansehen, ob sie im Style gut aussieht, und im Frame erreichbar machen |
| `FAIL kit …` | ein neues Token oder Member auf main | ergänzen |
| `FAIL frame …` | main erreicht ein Panel, das dein Style nicht erreicht | einen Zugang im Frame bauen |

Bei Konflikten unter `style/` gewinnt der Style (`.gitattributes`). Deshalb
meldet der Sync diese Dateien als `port`: Die Änderung von main ist nicht
automatisch drin.

Fertig nachgezogen ist ein Style, wenn `check_style.py --since <alter-stand>`
keine offene `port`-Zeile mehr hat, die du nicht bewusst geprüft hast, und
`contract ok` meldet.

## 9. Nie

- Dateien außerhalb von `style/` und dem Manifest ändern. Fehlt Logik, meldest
  du das.
- Logik im Style: Prozesse, Dateien, Sockets, D-Bus, eigene Zustände, die ein
  Service schon hat.
- Features, Workspaces, Panels, Tray-Einträge oder Studio-Seiten als feste
  Liste.
- Eine Funktion weglassen, weil sie nicht ins Theme passt. Dann findet das
  Theme eine Form dafür.
- Absolute Home-Pfade. Nimm `Paths`, `Quickshell.env("HOME")`.
- Erklärtexte in der UI. Labels sind kurz und selbsterklärend.
- Den Arbeitsbaum dreckig lassen. Der Style-Wechsler verweigert dann.
- Die Default-Shell als Vorlage nehmen: ihre Leiste, ihre Popup-Positionen,
  ihre Anordnung von Kacheln, Knöpfen und Text, auch nicht umgefärbt.

## 10. Abnahme

- [ ] `quickshell -p ./Validate.qml` → `VALIDATE: ok`
- [ ] `python3 scripts/check_style.py` → `contract ok`, jede Animation `compiles`,
      kein `layout`-Fehler
- [ ] Nebeneinander mit der Default-Shell verglichen: Keine Oberfläche ist
      an derselben Stelle gleich aufgebaut
- [ ] `python3 scripts/test_branch_styles.py` → OK
- [ ] Jede Oberfläche aus dem Vertrag live angesehen: Launcher, alle Panels,
      Studio (alle Seiten), Power-Menü, Sperrbildschirm, Screenshot, OSD,
      Benachrichtigungen, Tray-Menü
- [ ] Mit einem hellen, einem dunklen und einem knallbunten Wallpaper geprüft:
      lesbar, und erkennbar derselbe Style
- [ ] Signaturtöne sind mit der Palette gemischt, nicht fest gesetzt
- [ ] Features, die der Host nicht hat, hinterlassen keine Lücken
- [ ] Die eigene Fenster-Animation in Studio → Motion angesehen und angewendet
- [ ] `style/BRIEF.md` beschreibt das Theme so, dass jemand anderes den Style
      nachziehen kann
- [ ] Abschlussbericht: was wie umgesetzt ist, welche Schriften vorausgesetzt
      werden, welche Views ersetzt wurden, was im Core fehlen würde
