# Voice-Chat-Übersetzer (Prototyp für Windows)

Hört mit, was deine Mitspieler sagen, erkennt die Sprache automatisch,
übersetzt ins Deutsche (oder eine andere Zielsprache) und zeigt den Text an
bzw. liest ihn vor.

```
Ton vom PC  ->  Groq Speech-to-Text  ->  DeepL  ->  Text + Windows-Stimme
```

Erwartete Verzögerung: einige Sekunden nach Ende eines Satzes. Das ist ein
Prototyp, keine fertige App.

---

## Schritt 1: Konten und API-Keys

### Groq (für Speech-to-Text) – Gratis-Kontingent
1. Auf **console.groq.com** registrieren (z. B. mit Google-Konto oder E-Mail).
2. Links **API Keys → Create API Key**. Den Key (beginnt mit `gsk_`) sofort
   kopieren, er wird nur einmal angezeigt.

Das Gratis-Kontingent hat Grenzen pro Minute, Stunde und Tag. Jeder Satz wird
dabei als mindestens 10 Sekunden gezählt, auch wenn er kürzer ist. Die
aktuellen Zahlen stehen in der Groq-Konsole im Bereich **Limits**. Ist das Limit
erreicht, zeigt die App „Gratis-Limit erreicht“ an – dann kurz warten.

<details>
<summary>Alternative: OpenAI statt Groq (kostenpflichtig)</summary>

1. Auf **platform.openai.com** registrieren. Ein ChatGPT-Abo zählt hier nicht.
2. **Settings → Billing**: Zahlungsmittel hinterlegen, Guthaben aufladen.
3. **API keys → Create new secret key** (beginnt mit `sk-`).
4. In der App bei **Spracherkennung** „OpenAI“ wählen.
</details>

### DeepL API Free (für die Übersetzung) – gratis bis zum Monatslimit
1. Auf **deepl.com** unter „API“ den Tarif **DeepL API Free** wählen
   (nicht das normale DeepL Pro).
2. Nach der Anmeldung: **Account → API Keys**. Der Key endet auf `:fx`.

> Keys sind wie Passwörter: nirgends posten, nicht weitergeben.

## Schritt 2: Windows-App herunterladen (empfohlen)

Die App wird von GitHub automatisch gebaut. Python brauchst du dafür **nicht**.

1. Auf GitHub dein Repository öffnen und oben auf den Reiter **„Actions“** klicken.
2. Links **„Voice-Übersetzer Windows-App bauen“** wählen und dann den obersten
   Lauf mit grünem Haken anklicken.
3. Ganz unten bei **„Artifacts“** auf **VoiceTranslator-Windows** klicken.
   Es wird eine ZIP-Datei heruntergeladen (dafür musst du bei GitHub angemeldet sein).
4. ZIP in einen **eigenen Ordner** entpacken, z. B. `Dokumente\VoiceTranslator`.
   Dort speichert die App später auch deine Einstellungen.
5. **`VoiceTranslator.exe`** doppelklicken.
   - Windows zeigt wahrscheinlich **„Der Computer wurde durch Windows geschützt“**.
     Das liegt daran, dass die App nicht kostenpflichtig signiert ist.
     Auf **„Weitere Informationen“** und dann **„Trotzdem ausführen“** klicken.
   - Meldet dein Virenscanner die Datei, ist das bei solchen selbst gebauten
     Python-Apps ein bekannter Fehlalarm. Du kannst den Quellcode hier im
     Ordner selbst prüfen oder prüfen lassen.

Der Start dauert ein paar Sekunden, weil die App sich erst entpackt.

## Schritt 3: Keys eintragen und starten

1. **Spracherkennung**: „Groq“ lassen. Darunter den **Groq-Key** und den
   **DeepL-Key** einfügen (Strg+V).
2. Im Bereich **„Mitspieler → ich“**:
   - **Zuhören bei**: „Lautsprecher / Kopfhörer“.
   - **Gerät**: das, worüber du den Spiel-/Voice-Chat-Ton hörst, z. B. dein Headset.
   - **Übersetzen nach**: deine Sprache, z. B. `DE`.
3. Beim Bereich **„Ich → Mitspieler“** den Haken **„aktiv“** vorerst weglassen
   (Einrichtung siehe unten, [Gegenrichtung](#gegenrichtung-deine-stimme-übersetzt-an-die-mitspieler)).
4. **▶ Start** drücken.

Die Einstellungen werden in der Datei `.env` neben der `.exe` gespeichert,
**inklusive deiner Keys**. Den Ordner deshalb nicht weitergeben.

### Die Knöpfe im Fenster

| Element | Bedeutung |
|---|---|
| aktiv | Diese Richtung beim Start mitlaufen lassen. Beide Richtungen können gleichzeitig laufen. |
| Mindest-Lautstärke | Gibt es für jede Richtung einzeln. Ab dieser Lautstärke gilt etwas als Sprache. Der **Pegel**-Balken darunter zeigt live, wie laut es gerade ist. Regler so stellen, dass „● Sprache“ bei Stimmen aufleuchtet, aber nicht bei reinem Spielsound. Wirkt sofort, auch während es läuft. |
| am PC vorlesen | Übersetzung der Mitspieler mit der Windows-Stimme vorlesen |
| Handy-Anzeige | Übersetzungen der Mitspieler zusätzlich im Handy-Browser (Adresse steht nach Start im Textfeld) |
| Immer im Vordergrund | Fenster bleibt über anderen Fenstern. Klappt über Spielen nur im **Fenster-** oder **randlosen Fenstermodus**, nicht im exklusiven Vollbild. |

## Schritt 4: Testen

1. **▶ Start** drücken.
2. Im Browser ein Video in einer Fremdsprache abspielen (z. B. ein englisches
   oder spanisches YouTube-Video).
3. Nach jedem Satz erscheint Original + Übersetzung, und die Windows-Stimme
   liest vor.

Funktioniert das, dann im Spiel ausprobieren.

---

## Gegenrichtung: deine Stimme übersetzt an die Mitspieler

Du sprichst Deutsch, die Mitspieler hören eine Windows-Stimme in ihrer Sprache.

```
Dein Mikrofon → App (Groq + DeepL + Windows-Stimme) → „CABLE Input“
                                                         ║ (virtuelles Kabel)
Spiel / Discord nimmt als Mikrofon ◄════════════════ „CABLE Output“
```

### 1. VB-Cable installieren (einmalig, kostenlos)
1. Auf **vb-audio.com** → „VB-CABLE Virtual Audio Device“ die ZIP-Datei für
   Windows herunterladen und entpacken.
2. **Rechtsklick auf `VBCABLE_Setup_x64.exe` → „Als Administrator ausführen“**
   → „Install Driver“.
3. **PC neu starten.**
4. Danach prüfen: Windows-Einstellungen → System → Sound.
   - **Ausgabe** muss weiter dein Headset/Lautsprecher sein.
     (Manchmal stellt sich VB-Cable selbst als Standard ein – dann hörst du nichts mehr.)
   - **Eingabe** bleibt dein echtes Mikrofon.

### 2. Im Spiel bzw. in Discord
- Als **Mikrofon / Eingabegerät**: **„CABLE Output (VB-Audio Virtual Cable)“** wählen.
- **Sprachaktivierung** statt Push-to-Talk verwenden, sonst müsstest du die
  Taste gedrückt halten, während die App spricht.
- Falls die Ansage abgehackt oder gar nicht ankommt: Rauschunterdrückung des
  Voice-Chats (bei Discord z. B. „Krisp“) testweise ausschalten.

### 3. In der App
Im Bereich **„Ich → Mitspieler“**:
- **aktiv** anhaken.
- **Mein Mikrofon**: dein echtes Headset-Mikrofon (nicht „CABLE Output“!).
- **Übersetzen nach**: `AUTO` nimmt die Sprache, die die Mitspieler zuletzt
  gesprochen haben (am Anfang Englisch). Oder fest z. B. `EN`.
- **Ausgabe an**: **„CABLE Input (VB-Audio Virtual Cable)“**.
- **Mindest-Lautstärke** so einstellen, dass „● Sprache“ nur leuchtet, wenn du redest.

### Testen
In Discord unter Einstellungen → Sprache & Video → „Mikrofontest“ bzw. im
Voice-Chat-Test des Spiels: Wenn du etwas sagst, sollte nach ein paar Sekunden
die übersetzte Windows-Stimme ankommen.

### Wichtig zu wissen
- **Die Mitspieler hören nur noch die übersetzte Stimme**, nicht mehr deine
  echte. Wenn du wieder normal reden willst: im Spiel/Discord das Mikrofon
  zurück auf dein Headset stellen.
- Sprichst du schon in der Zielsprache, wird dein Satz ohne Übersetzung
  vorgelesen, damit er trotzdem ankommt.
- Kurze Sätze und kleine Pausen funktionieren am besten. Es dauert einige
  Sekunden, bis die Ansage kommt.
- **Headset empfohlen.** Mit Lautsprechern hört das Mikrofon die Ansagen mit;
  die App hört zwar nicht zu, solange sie selbst am PC vorliest, aber Ton aus
  dem Spiel kann trotzdem ins Mikrofon gelangen.
- **Stimmen:** Windows braucht eine Stimme in der Zielsprache. Fehlt sie, spricht
  die Standardstimme den fremden Text mit falscher Aussprache. Stimmen
  hinzufügen: Einstellungen → Zeit und Sprache → Sprache und Region → Sprache
  hinzufügen (mit **Sprachausgabe**). Achtung: Nicht jede so installierte Stimme
  ist für die App sichtbar – das liegt an der älteren Windows-Sprachschnittstelle,
  die die App nutzt. Welche Stimmen genau erscheinen, konnte ich nicht auf einem
  echten Windows prüfen.
- Beide Richtungen teilen sich das Groq-Gratis-Kontingent.

---

## Alternative: als Python-Skript starten

Falls die `.exe` nicht startet oder du am Code etwas ändern willst.

1. **python.org → Downloads** → aktuelle Python-3-Version für Windows laden.
   Beim Installieren das Häkchen **„Add python.exe to PATH“** setzen!
2. Ordner `voice-translator` auf den PC holen (auf GitHub „Code → Download ZIP“).
3. **`install.bat`** doppelklicken (installiert die Pakete).
4. **`start-fenster.bat`** startet dasselbe Fenster wie die `.exe`.
   **`start.bat`** startet die Konsolen-Version; die liest ihre Einstellungen aus
   `.env` (Vorlage: `.env.example`, mit Notepad bearbeiten).

---

## Handy als zweiter Bildschirm (optional)

Nach dem Start steht im Textfeld eine Zeile wie
`Handy-Anzeige: http://192.168.178.23:8765`.

1. Handy mit **demselben WLAN** verbinden wie den PC (nicht mit dem Gäste-WLAN).
2. Diese Adresse im Handy-Browser (z. B. Chrome) eintippen. Als Lesezeichen
   speichern, dann musst du sie nur einmal tippen.
3. Beim **ersten Start** fragt Windows eventuell per „Windows-Sicherheitswarnung“,
   ob Python ins Netzwerk darf: **„Private Netzwerke“ erlauben**.

Neue Übersetzungen erscheinen oben und sind blau umrandet.

**Tipp gegen Rückkopplung:** Oben rechts auf der Handy-Seite **„Vorlesen: an“**
tippen und in der App den Haken **„Am PC vorlesen“** entfernen. Dann liest das Handy vor statt der PC.
Der PC hört sich nicht mehr selbst, und du verpasst nichts, während vorgelesen wird.

Wenn das Handy „keine Verbindung zum PC“ anzeigt:
- Ist der PC-Übersetzer gestartet?
- Sind beide Geräte im selben WLAN?
- Ist das WLAN in Windows als **„Öffentlich“** eingestuft? Dann blockiert die
  Firewall. Umstellen: Einstellungen → Netzwerk und Internet → WLAN → dein Netz
  → Netzwerkprofil **„Privat“**.
- Stimmt die Adresse? Sie kann sich ändern, wenn der Router dem PC eine neue gibt.

Die Seite zeigt nur Übersetzungen an, keine Keys. Jeder in deinem WLAN, der die
Adresse kennt, könnte sie aber mitlesen. Ausschalten: Haken **„Handy-Anzeige“** entfernen.

---

## Weitere Einstellungen (in `.env`, für Fortgeschrittene)

| Einstellung | Bedeutung |
|---|---|
| `TARGET_LANG` | Zielsprache, z. B. `DE`, `EN`, `FR`. Die Ausgangssprache wird automatisch erkannt. Was schon in der Zielsprache ist, wird nur angezeigt, nicht vorgelesen. |
| `AUDIO_SOURCE` | `loopback` = was aus Lautsprecher/Kopfhörer kommt, `mic` = dein Mikrofon |
| `AUDIO_DEVICE` | Leer = Windows-Standard. Sonst ein Teil des Gerätenamens. Liste: `start.bat --geraete` bzw. `python translator.py --geraete` |
| `SPEAK` | `1` = vorlesen, `0` = nur Text |
| `TTS_RATE` | Sprechtempo −10 bis 10 |
| `VOLUME_THRESHOLD` | Ab welcher Lautstärke „gesprochen“ wird (siehe unten) |
| `SILENCE_SECONDS` | So lange Stille beendet einen Satz |
| `PHONE_VIEW` | `1` = Handy-Anzeige an, `0` = aus |
| `PHONE_PORT` | Port der Handy-Anzeige (Standard `8765`). Nur ändern, wenn beim Start ein Fehler kommt |

### Lautstärke-Schwelle einstellen (Konsolen-Version)
In der App: Regler „Mindest-Lautstärke“ (siehe oben). In der Konsolen-Version:
**`pegel.bat`** doppelklicken. Du siehst live Zahlen. Lass jemanden reden
bzw. spiel ein Video ab und schau, welche Werte bei Sprache kommen und welche
bei reinem Spielsound. Setze `VOLUME_THRESHOLD` knapp über den Spielsound.

---

## Häufige Probleme

| Meldung / Problem | Lösung |
|---|---|
| „Der Computer wurde durch Windows geschützt“ | „Weitere Informationen“ → „Trotzdem ausführen“ |
| `.exe` startet gar nicht / verschwindet sofort | Die Python-Variante probieren (`start.bat`), die zeigt die Fehlermeldung an – und mir schicken |
| „FEHLER bei der Tonaufnahme“ | Anderes Gerät in der Liste wählen, „Neu laden“ drücken |
| `python` wird nicht gefunden | Python neu installieren, Häkchen „Add to PATH“ setzen |
| `Fehlendes Paket` | `install.bat` erneut ausführen |
| „Key für die Spracherkennung ungültig“ / „DeepL-Key ungültig“ | Key neu kopieren und einfügen (keine Leerzeichen) |
| „Gratis-Limit der Spracherkennung erreicht“ | Groq-Limit erreicht: kurz warten. Kommt es oft, `SILENCE_SECONDS` erhöhen (weniger, dafür längere Stücke) |
| „OpenAI-Guthaben aufgebraucht“ | Nur bei OpenAI: unter platform.openai.com → Billing aufladen |
| Übersetzt ständig Spielgeräusche | „Mindest-Lautstärke“ höher stellen |
| Sätze werden mitten drin zerschnitten | `SILENCE_SECONDS` erhöhen, z. B. auf `1.2` |
| „Ausgabegerät … nicht gefunden. Ist VB-Cable installiert?“ | VB-Cable installieren und PC neu starten, dann „Neu laden“ und bei „Ausgabe an“ CABLE Input wählen |
| Mitspieler hören nichts | Im Spiel/Discord als Mikrofon „CABLE Output“ wählen; Sprachaktivierung statt Push-to-Talk |
| Nach VB-Cable-Installation hörst du nichts mehr | Windows-Sound-Ausgabe zurück auf dein Headset stellen |
| Ansage in falscher Aussprache | Es fehlt eine Windows-Stimme für die Zielsprache (siehe Gegenrichtung → Stimmen) |
| Nichts passiert, Pegel bleibt leer | Falsches Gerät gewählt – das Gerät nehmen, über das du den Ton hörst |
| Fehler mit `numpy`/`fromstring` beim Start | `python -m pip install --upgrade soundcard` |
| Fehler „model not found“ | Das Modell gibt es beim Anbieter nicht mehr: in `.env` bei `STT_MODEL` ein aktuelles Whisper-Modell des Anbieters eintragen |
| Keine deutsche Stimme | Windows-Einstellungen → Zeit und Sprache → Sprache → Deutsch → Sprachausgabe installieren |

## Bekannte Grenzen dieses Prototyps

- **Loopback hört alles**: Spielsound, Musik, YouTube. Besser wird es, wenn der
  Voice-Chat (z. B. Discord) auf ein eigenes Ausgabegerät gelegt wird –
  dafür später **VB-Cable**.
- Während die Übersetzung vorgelesen wird, hört das Programm nicht zu
  (sonst würde es sich selbst übersetzen). Was in dieser Zeit gesagt wird, fehlt.
- Reden zwei Leute gleichzeitig, wird es ungenau.
- Die Windows-Stimmen klingen deutlich nach Computer.
- Es wird nichts gespeichert; die Audio-Stücke werden aber an Groq (bzw. OpenAI) und der
  Text an DeepL geschickt.
