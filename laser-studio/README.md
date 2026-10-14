# Goose Village Laser Studio

Lokale Windows-Software zum Konstruieren von Laser-Holzkisten mit SVG-Export
(später ergänzt um KI-Motivgenerator, Zuschnittplan und Motivplatzierung).

**Stand: Phase 1, Version 0.1.0**

## Was funktioniert (Phase 1)

| Funktion | Stand |
|---|---|
| Kiste mit stumpfen Verbindungen (verleimen) | ✅ umgesetzt, automatisch getestet |
| Deckel: offen / eingesetzt / aufgelegt | ✅ umgesetzt, automatisch getestet |
| Außen- und Innenmaße, Materialstärke | ✅ umgesetzt, automatisch getestet |
| Kerf-Ausgleich (Außenkontur um Kerf/2 nach außen) | ✅ umgesetzt, automatisch getestet |
| Prüfung unmöglicher Eingaben, kein Export bei Fehlern | ✅ umgesetzt, automatisch getestet |
| Einfache Reihenanordnung auf einer Platte | ✅ umgesetzt, **nicht optimiert** |
| SVG-Export in mm | ✅ umgesetzt, automatisch getestet |
| 2D-Vorschau der Platte | ✅ umgesetzt |
| Probe an einem echten Laser | ❌ **noch nicht erfolgt** |
| Import in xTool Creative Space | ❌ **noch nicht ausprobiert** |
| Fingerzinken, Schiebedeckel, Fächer, 3D-Vorschau | geplant (Phase 4) |
| Optimierter Zuschnittplan, mehrere Platten, Drehen | geplant (Phase 5) |
| KI-Motivgenerator, Vektorisierung | geplant (Phase 6) |
| Projekte speichern, Materialprofile, PNG/DXF | geplant (spätere Phasen) |

## Installation (Windows)

1. **Python 3.10 oder neuer** installieren: <https://www.python.org/downloads/>
   Bei der Installation **„Add python.exe to PATH“** anhaken.
2. Den Ordner `laser-studio` auf den PC kopieren (oder das Repository klonen).

Weitere Pakete sind **nicht** nötig. Phase 1 verwendet nur die
Python-Standardbibliothek und braucht keine Internetverbindung.

## Starten

- **Doppelklick auf `start.bat`.**
  Es öffnet sich ein schwarzes Fenster und danach der Browser mit der Oberfläche.
- Alternativ in der Eingabeaufforderung im Ordner `laser-studio`:
  `py -3 run.py` (oder `python run.py`)
- Beenden: das schwarze Fenster schließen oder dort `Strg+C` drücken.

Die Oberfläche läuft unter `http://127.0.0.1:8765/` und ist nur vom eigenen
PC aus erreichbar. Ist der Port belegt, nimmt das Programm automatisch den
nächsten freien (8766, 8767, …). Die verwendete Adresse steht im schwarzen Fenster.

## Bedienung

1. Links **„Kisten- und Boxenkonstrukteur“** wählen.
2. Außenmaße, Materialstärke, Kerf, Deckeltyp und Plattengröße eintragen.
   Die Berechnung läuft automatisch.
3. Grüner Status = Konstruktion rechnerisch geprüft. Roter Status = Fehler.
   In diesem Fall wird **keine** Datei erzeugt, und das fehlerhafte Feld ist rot markiert.
4. **„SVG herunterladen“** speichert die Datei im Download-Ordner des Browsers.

## So prüfen Sie das Ergebnis

1. SVG in xTool Creative Space importieren und die Teile nachmessen. Die Maße
   müssen der Spalte „Schnittlinie inkl. Kerf“ entsprechen.
2. **Kerf ermitteln:** Ein Quadrat (z. B. 20 × 20 mm) mit Kerf 0 schneiden und
   nachmessen. Kerf = 20 mm − gemessenes Maß. Diesen Wert eintragen.
3. Zuerst eine kleine Kiste aus Restmaterial schneiden und zusammenstecken.

## Konstruktionsregeln

- Vorder- und Rückwand: volle Außenlänge.
- Seitenwände: zwischen Vorder- und Rückwand (Außenbreite − 2 × Stärke).
- Boden: zwischen allen vier Wänden eingesetzt.
- Deckel *eingesetzt*: wie der Boden, oben zwischen den Wänden.
- Deckel *aufgelegt*: volle Außenmaße, liegt auf den Wänden (Wände = Höhe − Stärke).
- Innenhöhe: offen = H − t, mit Deckel = H − 2t.

Bei jeder Berechnung wird geprüft, dass alle Teile innerhalb der Außenmaße
liegen, keines in den Innenraum ragt, sich keine zwei Teile überschneiden
und die Teile die Kistenwand **lückenlos** ausfüllen (Volumenvergleich).

## SVG-Format

- `width`/`height` in `mm`, `viewBox` mit denselben Zahlen (1 Einheit = 1 mm).
- Schnittlinien: rot `#ff0000`, keine Füllung, geschlossene Pfade, Gruppe `schnitt`.
- Jedes Teil ist ein eigener Pfad (`id="teil-…"`, Name im `<title>`).
- Zwischen den Teilen bleibt der eingestellte Abstand, damit keine doppelten
  Schnittlinien entstehen.
- Keine sichtbaren Texte und kein Plattenrand in der Exportdatei. Beides
  erscheint nur in der Vorschau. Text wird noch nicht in Pfade umgewandelt.
- Laserleistung und Geschwindigkeit stehen bewusst **nicht** in der Datei.
  Sie hängen von Laser und Material ab und werden im Laserprogramm eingestellt.

## Automatische Tests

Im Ordner `laser-studio`:

```
py -3 -m unittest discover -s tests -t .
```

Getestet werden: Kombinationen aus 4 Außenmaßen × 4 Materialstärken × 4 Kerf-Werten
× 3 Deckeltypen, Innenmaße, Teilmaße, Ablehnung unmöglicher Eingaben,
überschneidungsfreie Anordnung, SVG-Einheiten und Parsebarkeit (XML-Parser),
geschlossene Pfade, Übereinstimmung der SVG-Rechtecke mit den Schnittmaßen
sowie die Server-Schnittstelle (inkl. Ablehnung des Exports bei Fehlern).

Die Tests ersetzen **nicht** die Probe am Laser.

## Projektstruktur

```
laser-studio/
  start.bat              Start unter Windows (Doppelklick)
  run.py                 Startet den lokalen Server und öffnet den Browser
  goose_laser/
    geometry/box.py      Kistenkonstruktion und Prüfung (reine Berechnung)
    layout/simple.py     Einfache Anordnung auf der Platte und Überschneidungsprüfung
    export/svg.py        SVG-Erzeugung
    service.py           Ablauf Eingabe → Konstruktion → Anordnung → SVG
    server/app.py        Lokaler HTTP-Server + JSON-API
  web/                   Oberfläche (HTML, CSS, JavaScript)
  tests/                 Automatische Tests
  logs/app.log           Protokoll (wird beim Start angelegt, nicht versioniert)
```

Die Berechnung (`geometry`, `layout`, `export`, `service`) ist unabhängig von
Server und Oberfläche. Für eine spätere Webversion kann der Server ersetzt
werden, ohne die Berechnung zu ändern.

## Bekannte Einschränkungen

- Stumpfe Verbindungen haben keine Steckverbindung. Die Kiste muss verleimt werden.
- Die Anordnung auf der Platte ist einfach (zeilenweise, ohne Drehen) und nicht optimal.
- Alles muss auf eine Platte passen, sonst erscheint eine Fehlermeldung.
- `start.bat` wurde in der Entwicklungsumgebung (Linux) nicht ausgeführt.
  Der Python-Teil wurde getestet, die Batchdatei selbst noch nicht unter Windows.
