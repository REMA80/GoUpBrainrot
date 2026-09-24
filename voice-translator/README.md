# Voice-Chat-Übersetzer (Prototyp für Windows)

Hört mit, was deine Mitspieler sagen, erkennt die Sprache automatisch,
übersetzt ins Deutsche (oder eine andere Zielsprache) und zeigt den Text an
bzw. liest ihn vor.

```
Ton vom PC  ->  OpenAI Speech-to-Text  ->  DeepL  ->  Text + Windows-Stimme
```

Erwartete Verzögerung: einige Sekunden nach Ende eines Satzes. Das ist ein
Prototyp, keine fertige App.

---

## Schritt 1: Konten und API-Keys

### OpenAI (für Speech-to-Text) – kostenpflichtig
1. Auf **platform.openai.com** registrieren.
   *Achtung:* Ein ChatGPT-Abo zählt hier nicht, die API wird separat bezahlt.
2. Links **Settings → Billing**: Zahlungsmittel hinterlegen, kleines Guthaben aufladen.
3. **API keys → Create new secret key**. Den Key (beginnt mit `sk-`) sofort
   kopieren, er wird nur einmal angezeigt.

### DeepL API Free (für die Übersetzung) – gratis bis zum Monatslimit
1. Auf **deepl.com** unter „API“ den Tarif **DeepL API Free** wählen
   (nicht das normale DeepL Pro).
2. Nach der Anmeldung: **Account → API Keys**. Der Key endet auf `:fx`.

> Keys sind wie Passwörter: nirgends posten, nicht weitergeben.

## Schritt 2: Python installieren

1. **python.org → Downloads** → aktuelle Python-3-Version für Windows laden.
2. Beim Installieren unten das Häkchen **„Add python.exe to PATH“** setzen!
3. Ordner `voice-translator` auf deinen PC holen (z. B. auf GitHub
   „Code → Download ZIP“, dann entpacken).
4. Im Ordner doppelt auf **`install.bat`** klicken. Das installiert alle
   Pakete und legt die Datei `.env` an.

## Schritt 3: Keys eintragen

1. Die Datei **`.env`** im Ordner mit Notepad öffnen
   (Rechtsklick → Öffnen mit → Editor). Falls du sie nicht siehst: im Explorer
   unter „Anzeigen“ die **Dateinamenerweiterungen** und **ausgeblendete Elemente** einschalten.
2. Hinter `OPENAI_API_KEY=` und `DEEPL_API_KEY=` die Keys einfügen,
   ohne Leerzeichen und ohne Anführungszeichen. Speichern.

## Schritt 4: Testen

1. **`start.bat`** doppelklicken.
2. Im Browser ein Video in einer Fremdsprache abspielen (z. B. ein englisches
   oder spanisches YouTube-Video).
3. Nach jedem Satz erscheint Original + Übersetzung, und die Windows-Stimme
   liest vor. Beenden mit **Strg+C** oder Fenster schließen.

Funktioniert das, dann im Spiel ausprobieren.

---

## Einstellungen (in `.env`)

| Einstellung | Bedeutung |
|---|---|
| `TARGET_LANG` | Zielsprache, z. B. `DE`, `EN`, `FR`. Die Ausgangssprache wird automatisch erkannt. Was schon in der Zielsprache ist, wird nur angezeigt, nicht vorgelesen. |
| `AUDIO_SOURCE` | `loopback` = was aus Lautsprecher/Kopfhörer kommt, `mic` = dein Mikrofon |
| `AUDIO_DEVICE` | Leer = Windows-Standard. Sonst ein Teil des Gerätenamens. Liste: `start.bat --geraete` bzw. `python translator.py --geraete` |
| `SPEAK` | `1` = vorlesen, `0` = nur Text |
| `TTS_RATE` | Sprechtempo −10 bis 10 |
| `VOLUME_THRESHOLD` | Ab welcher Lautstärke „gesprochen“ wird (siehe unten) |
| `SILENCE_SECONDS` | So lange Stille beendet einen Satz |

### Lautstärke-Schwelle einstellen
**`pegel.bat`** doppelklicken. Du siehst live Zahlen. Lass jemanden reden
bzw. spiel ein Video ab und schau, welche Werte bei Sprache kommen und welche
bei reinem Spielsound. Setze `VOLUME_THRESHOLD` knapp über den Spielsound.

---

## Häufige Probleme

| Meldung / Problem | Lösung |
|---|---|
| `python` wird nicht gefunden | Python neu installieren, Häkchen „Add to PATH“ setzen |
| `Fehlendes Paket` | `install.bat` erneut ausführen |
| `OpenAI-Key ungültig` / `DeepL-Key ungültig` | Key in `.env` prüfen (keine Leerzeichen) |
| `OpenAI-Guthaben aufgebraucht` | Unter platform.openai.com → Billing aufladen |
| Übersetzt ständig Spielgeräusche | `VOLUME_THRESHOLD` erhöhen (mit `pegel.bat` ermitteln) |
| Sätze werden mitten drin zerschnitten | `SILENCE_SECONDS` erhöhen, z. B. auf `1.2` |
| Nichts passiert | Richtiges Ausgabegerät? `AUDIO_DEVICE` setzen (Namen mit `--geraete`) |
| Fehler mit `numpy`/`fromstring` beim Start | `python -m pip install --upgrade soundcard` |
| `whisper-1` nicht (mehr) verfügbar | In `.env` bei `STT_MODEL` ein aktuelles Transkriptionsmodell von OpenAI eintragen |
| Keine deutsche Stimme | Windows-Einstellungen → Zeit und Sprache → Sprache → Deutsch → Sprachausgabe installieren |

## Bekannte Grenzen dieses Prototyps

- **Loopback hört alles**: Spielsound, Musik, YouTube. Besser wird es, wenn der
  Voice-Chat (z. B. Discord) auf ein eigenes Ausgabegerät gelegt wird –
  dafür später **VB-Cable**.
- Während die Übersetzung vorgelesen wird, hört das Programm nicht zu
  (sonst würde es sich selbst übersetzen). Was in dieser Zeit gesagt wird, fehlt.
- Reden zwei Leute gleichzeitig, wird es ungenau.
- Nur eine Richtung: Mitspieler → du. Deine eigene Stimme für andere zu
  übersetzen ist ein späterer Schritt.
- Es wird nichts gespeichert; die Audio-Stücke werden aber an OpenAI und der
  Text an DeepL geschickt.
